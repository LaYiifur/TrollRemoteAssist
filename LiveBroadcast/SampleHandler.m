#import "SampleHandler.h"
#import "MJPEGServer.h"
#import "WebRTCStreamer.h"
#import <QuartzCore/QuartzCore.h>

@implementation SampleHandler {
    NSUInteger _videoFrameCount;
    NSUInteger _windowFrameCount;
    NSUInteger _appAudioBufferCount;
    NSUInteger _micAudioBufferCount;
    CFTimeInterval _windowStart;
    MJPEGServer *_server;
    WebRTCStreamer *_streamer;
}

- (void)broadcastStartedWithSetupInfo:(NSDictionary<NSString *, NSObject *> *)setupInfo {
    _videoFrameCount = 0;
    _windowFrameCount = 0;
    _appAudioBufferCount = 0;
    _micAudioBufferCount = 0;
    _windowStart = CACurrentMediaTime();
    _streamer = [WebRTCStreamer new];
    _server = [[MJPEGServer alloc] initWithWebRTCStreamer:_streamer];
    [_server start];
    __weak WebRTCStreamer *weakStreamer = _streamer;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [weakStreamer start];
    });
    NSLog(@"[LiveBroadcast] started");
}

- (void)broadcastPaused { NSLog(@"[LiveBroadcast] paused"); }
- (void)broadcastResumed { NSLog(@"[LiveBroadcast] resumed"); }
- (void)broadcastFinished {
    [_server stop];
    _server = nil;
    [_streamer stop];
    _streamer = nil;
    NSLog(@"[LiveBroadcast] finished, frames=%lu", (unsigned long)_videoFrameCount);
}

- (void)processSampleBuffer:(CMSampleBufferRef)sampleBuffer
                   withType:(RPSampleBufferType)sampleBufferType {
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
    (void)sampleBuffer;
    _appAudioBufferCount++;
}

- (void)handleMicAudio:(CMSampleBufferRef)sampleBuffer {
    (void)sampleBuffer;
    _micAudioBufferCount++;
    if (_micAudioBufferCount % 200 == 0)
        NSLog(@"[AudioMic] buffers=%lu (kept separate, not streamed)",
              (unsigned long)_micAudioBufferCount);
}

@end
