#import "SampleHandler.h"
#import <ReplayKit/ReplayKit.h>
#import "AudioAppStreamer.h"
#import "MJPEGServer.h"
#import "WebRTCStreamer.h"
#import <QuartzCore/QuartzCore.h>
#import <math.h>

static NSString * const LTSettingsSuite = @"group.com.layii.live";
static NSString * const LTShareDeviceAudioKey = @"audio.shareDeviceAudio";

@interface SampleHandler ()
- (void)startAudioPreferenceTimer;
- (void)drainPendingAudioSamples;
- (void)logPCMIfNeeded:(NSData *)pcm sampleRate:(uint32_t)sampleRate channels:(uint16_t)channels;
@end

@implementation SampleHandler {
    NSUInteger _videoFrameCount;
    NSUInteger _windowFrameCount;
    NSUInteger _appAudioBufferCount;
    NSUInteger _micAudioBufferCount;
    NSUInteger _audioPCMBufferCount;
    NSUInteger _audioDroppedBufferCount;
    CFTimeInterval _windowStart;
    BOOL _shareDeviceAudio;
    BOOL _stopping;
    dispatch_source_t _audioPreferenceTimer;
    dispatch_queue_t _audioQueue;
    CMSampleBufferRef _pendingAudioSampleBuffer;
    BOOL _audioWorkerScheduled;
    NSUserDefaults *_streamDefaults;
    AudioAppStreamer *_audioStreamer;
    MJPEGServer *_server;
    WebRTCStreamer *_streamer;
}

- (void)broadcastStartedWithSetupInfo:(NSDictionary<NSString *, NSObject *> *)setupInfo {
    (void)setupInfo;
    _videoFrameCount = 0;
    _windowFrameCount = 0;
    _appAudioBufferCount = 0;
    _micAudioBufferCount = 0;
    _audioPCMBufferCount = 0;
    _audioDroppedBufferCount = 0;
    _windowStart = CACurrentMediaTime();
    _stopping = NO;
    _pendingAudioSampleBuffer = NULL;
    _audioWorkerScheduled = NO;
    _audioQueue = dispatch_queue_create("com.layii.live.audio.capture", DISPATCH_QUEUE_SERIAL);

    _streamDefaults = [[NSUserDefaults alloc] initWithSuiteName:LTSettingsSuite];
    [_streamDefaults registerDefaults:@{LTShareDeviceAudioKey: @YES}];
    [_streamDefaults synchronize];
    _shareDeviceAudio = [_streamDefaults boolForKey:LTShareDeviceAudioKey];
    [self startAudioPreferenceTimer];

    _streamer = [WebRTCStreamer new];
    _server = [[MJPEGServer alloc] initWithWebRTCStreamer:_streamer];

    __weak typeof(self) weakSelf = self;
    _audioStreamer = [[AudioAppStreamer alloc]
        initWithPCMHandler:^(NSData *pcm, uint32_t sampleRate, uint16_t channels,
                             uint64_t timestampMicroseconds) {
            SampleHandler *strongSelf = weakSelf;
            if (!strongSelf || strongSelf->_stopping) return;
            [strongSelf logPCMIfNeeded:pcm sampleRate:sampleRate channels:channels];
            [strongSelf->_server publishAudioPCM:pcm
                                      sampleRate:sampleRate
                                        channels:channels
                                       timestamp:timestampMicroseconds];
        }];

    [_server start];
    __weak WebRTCStreamer *weakStreamer = _streamer;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [weakStreamer start];
    });
    NSLog(@"[LiveBroadcast] started");
}

- (void)broadcastPaused {
    NSLog(@"[LiveBroadcast] paused");
}

- (void)broadcastResumed {
    NSLog(@"[LiveBroadcast] resumed");
}

- (void)broadcastFinished {
    _stopping = YES;
    if (_audioPreferenceTimer) {
        dispatch_source_cancel(_audioPreferenceTimer);
        _audioPreferenceTimer = nil;
    }

    @synchronized (self) {
        if (_pendingAudioSampleBuffer) {
            CFRelease(_pendingAudioSampleBuffer);
            _pendingAudioSampleBuffer = NULL;
        }
    }

    // 音频清理不阻塞 ReplayKit 的结束回调。
    AudioAppStreamer *audioStreamer = _audioStreamer;
    dispatch_queue_t audioQueue = _audioQueue;
    _audioStreamer = nil;
    _audioQueue = nil;
    if (audioStreamer && audioQueue) {
        dispatch_async(audioQueue, ^{
            [audioStreamer reset];
        });
    }

    MJPEGServer *server = _server;
    WebRTCStreamer *streamer = _streamer;
    _server = nil;
    _streamer = nil;
    [server stop];
    [streamer stop];

    NSLog(@"[LiveBroadcast] finished, frames=%lu audioBuffers=%lu pcm=%lu droppedAudio=%lu",
          (unsigned long)_videoFrameCount,
          (unsigned long)_appAudioBufferCount,
          (unsigned long)_audioPCMBufferCount,
          (unsigned long)_audioDroppedBufferCount);
}

- (void)processSampleBuffer:(CMSampleBufferRef)sampleBuffer
                   withType:(RPSampleBufferType)sampleBufferType {
    if (_stopping) return;
    switch (sampleBufferType) {
        case RPSampleBufferTypeVideo:
            [self handleVideo:sampleBuffer];
            break;
        case RPSampleBufferTypeAudioApp:
            [self handleAppAudio:sampleBuffer];
            break;
        case RPSampleBufferTypeAudioMic:
            [self handleMicAudio:sampleBuffer];
            break;
    }
}

- (void)handleVideo:(CMSampleBufferRef)sampleBuffer {
    CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (!pixelBuffer) return;

    _videoFrameCount++;
    _windowFrameCount++;
    CFTimeInterval now = CACurrentMediaTime();
    CFTimeInterval elapsed = now - _windowStart;
    if (elapsed >= 2.0) {
        NSLog(@"[LiveBroadcast] frame=%lu resolution=%zux%zu fps=%.1f",
              (unsigned long)_videoFrameCount,
              CVPixelBufferGetWidth(pixelBuffer),
              CVPixelBufferGetHeight(pixelBuffer),
              _windowFrameCount / elapsed);
        _windowFrameCount = 0;
        _windowStart = now;
    }

    [_streamer processVideoSampleBuffer:sampleBuffer];
}

- (void)handleAppAudio:(CMSampleBufferRef)sampleBuffer {
    _appAudioBufferCount++;
    if (!sampleBuffer || _stopping) return;

    BOOL shareDeviceAudio = NO;
    @synchronized (self) {
        shareDeviceAudio = _shareDeviceAudio;
    }
    if (!shareDeviceAudio || !_server.hasAudioClients || !_audioQueue || !_audioStreamer) return;

    // ReplayKit 回调里只保留“最新一块”系统音频，转换和网络发送全部放到独立队列。
    CMSampleBufferRef retained = (CMSampleBufferRef)CFRetain(sampleBuffer);
    BOOL scheduleWorker = NO;
    @synchronized (self) {
        if (_stopping) {
            CFRelease(retained);
            return;
        }
        if (_pendingAudioSampleBuffer) {
            CFRelease(_pendingAudioSampleBuffer);
            _pendingAudioSampleBuffer = NULL;
            _audioDroppedBufferCount++;
        }
        _pendingAudioSampleBuffer = retained;
        if (!_audioWorkerScheduled) {
            _audioWorkerScheduled = YES;
            scheduleWorker = YES;
        }
    }

    if (scheduleWorker) {
        __weak typeof(self) weakSelf = self;
        dispatch_async(_audioQueue, ^{
            [weakSelf drainPendingAudioSamples];
        });
    }
}

- (void)drainPendingAudioSamples {
    while (!_stopping) {
        CMSampleBufferRef sampleBuffer = NULL;
        @synchronized (self) {
            sampleBuffer = _pendingAudioSampleBuffer;
            _pendingAudioSampleBuffer = NULL;
            if (!sampleBuffer) {
                _audioWorkerScheduled = NO;
                return;
            }
        }

        BOOL shareDeviceAudio = NO;
        @synchronized (self) {
            shareDeviceAudio = _shareDeviceAudio;
        }
        MJPEGServer *server = _server;
        AudioAppStreamer *audioStreamer = _audioStreamer;
        if (shareDeviceAudio && server.hasAudioClients && audioStreamer)
            [audioStreamer processSampleBuffer:sampleBuffer];
        CFRelease(sampleBuffer);
    }

    @synchronized (self) {
        if (_pendingAudioSampleBuffer) {
            CFRelease(_pendingAudioSampleBuffer);
            _pendingAudioSampleBuffer = NULL;
        }
        _audioWorkerScheduled = NO;
    }
}

- (void)startAudioPreferenceTimer {
    dispatch_queue_t queue = dispatch_queue_create("com.layii.live.audio.preferences", DISPATCH_QUEUE_SERIAL);
    _audioPreferenceTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
    if (!_audioPreferenceTimer) return;
    dispatch_source_set_timer(_audioPreferenceTimer,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                              (uint64_t)(0.5 * NSEC_PER_SEC),
                              (uint64_t)(0.1 * NSEC_PER_SEC));
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(_audioPreferenceTimer, ^{
        SampleHandler *strongSelf = weakSelf;
        if (!strongSelf || strongSelf->_stopping) return;
        [strongSelf->_streamDefaults synchronize];
        BOOL enabled = [strongSelf->_streamDefaults boolForKey:LTShareDeviceAudioKey];
        BOOL changed = NO;
        @synchronized (strongSelf) {
            changed = strongSelf->_shareDeviceAudio != enabled;
            strongSelf->_shareDeviceAudio = enabled;
            if (!enabled && strongSelf->_pendingAudioSampleBuffer) {
                CFRelease(strongSelf->_pendingAudioSampleBuffer);
                strongSelf->_pendingAudioSampleBuffer = NULL;
            }
        }
        if (changed)
            NSLog(@"[Audio] shareDeviceAudio=%@", enabled ? @"YES" : @"NO");
    });
    dispatch_resume(_audioPreferenceTimer);
}

- (void)logPCMIfNeeded:(NSData *)pcm sampleRate:(uint32_t)sampleRate channels:(uint16_t)channels {
    _audioPCMBufferCount++;
    if (_audioPCMBufferCount != 1 && _audioPCMBufferCount % 100 != 0) return;

    const int16_t *samples = pcm.bytes;
    NSUInteger sampleCount = pcm.length / sizeof(int16_t);
    if (!samples || !sampleCount) return;

    int peak = 0;
    double sumSquares = 0;
    for (NSUInteger index = 0; index < sampleCount; index++) {
        int value = samples[index];
        int magnitude = value < 0 ? -value : value;
        if (magnitude > peak) peak = magnitude;
        double normalized = (double)value / 32768.0;
        sumSquares += normalized * normalized;
    }
    double rms = sqrt(sumSquares / sampleCount);
    double peakNormalized = (double)peak / 32768.0;
    NSLog(@"[AudioPCM] buffers=%lu rate=%u channels=%u bytes=%lu peak=%.4f rms=%.4f",
          (unsigned long)_audioPCMBufferCount, sampleRate, channels,
          (unsigned long)pcm.length, peakNormalized, rms);
}

- (void)handleMicAudio:(CMSampleBufferRef)sampleBuffer {
    (void)sampleBuffer;
    _micAudioBufferCount++;
    if (_micAudioBufferCount % 200 == 0)
        NSLog(@"[AudioMic] buffers=%lu (kept separate, not streamed)",
              (unsigned long)_micAudioBufferCount);
}

@end
