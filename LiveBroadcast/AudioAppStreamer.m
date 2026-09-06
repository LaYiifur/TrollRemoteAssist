#import "AudioAppStreamer.h"
#import <AVFoundation/AVFoundation.h>
#import <math.h>
#import <stddef.h>
#import <stdlib.h>
#import <string.h>

static const double LTOutputSampleRate = 48000.0;
static const AVAudioChannelCount LTOutputChannels = 2;

@implementation AudioAppStreamer {
    LTAudioPCMHandler _handler;
    AVAudioConverter *_converter;
    AVAudioFormat *_inputFormat;
    AVAudioFormat *_outputFormat;
    AudioStreamBasicDescription _inputDescription;
    BOOL _hasInputDescription;
}

- (instancetype)initWithPCMHandler:(LTAudioPCMHandler)handler {
    if ((self = [super init])) {
        _handler = [handler copy];
        _outputFormat = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatInt16
                                                        sampleRate:LTOutputSampleRate
                                                          channels:LTOutputChannels
                                                       interleaved:YES];
    }
    return self;
}

- (void)reset {
    @synchronized (self) {
        [_converter reset];
        _converter = nil;
        _inputFormat = nil;
        _hasInputDescription = NO;
    }
}

- (void)processSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    if (!sampleBuffer || !_handler || !CMSampleBufferIsValid(sampleBuffer) ||
        !CMSampleBufferDataIsReady(sampleBuffer)) return;
    @synchronized (self) {
        CMAudioFormatDescriptionRef description = CMSampleBufferGetFormatDescription(sampleBuffer);
        const AudioStreamBasicDescription *asbd = description ?
            CMAudioFormatDescriptionGetStreamBasicDescription(description) : NULL;
        AVAudioFrameCount frameCount = (AVAudioFrameCount)CMSampleBufferGetNumSamples(sampleBuffer);
        if (!asbd || !frameCount || asbd->mSampleRate <= 0 || !asbd->mChannelsPerFrame) return;
        if (![self ensureConverterForDescription:asbd]) return;

        AVAudioPCMBuffer *input = [[AVAudioPCMBuffer alloc] initWithPCMFormat:_inputFormat
                                                               frameCapacity:frameCount];
        if (!input) return;
        input.frameLength = frameCount;

        // ReplayKit hands us PCM CMSampleBuffer objects. Copy directly into an
        // AVAudioPCMBuffer instead of guessing the AudioBufferList allocation size.
        // The previous fixed-size AudioBufferList could be too small for the actual
        // sample layout and CoreMedia returned kCMSampleBufferError_ArrayTooSmall
        // (-12737) for every audio callback.
        OSStatus copyStatus = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, 0, (int32_t)frameCount, input.mutableAudioBufferList);
        if (copyStatus != noErr) {
            NSLog(@"[Audio] unable to copy PCM status=%d frames=%u rate=%.0f channels=%u",
                  (int)copyStatus, (unsigned)frameCount, asbd->mSampleRate,
                  (unsigned)asbd->mChannelsPerFrame);
            return;
        }

        AVAudioFrameCount capacity = (AVAudioFrameCount)ceil(
            frameCount * LTOutputSampleRate / asbd->mSampleRate) + 256;
        AVAudioPCMBuffer *output = [[AVAudioPCMBuffer alloc] initWithPCMFormat:_outputFormat
                                                                frameCapacity:capacity];
        __block BOOL supplied = NO;
        NSError *error = nil;
        AVAudioConverterOutputStatus convertStatus = [_converter convertToBuffer:output
            error:&error withInputFromBlock:^AVAudioBuffer *(AVAudioPacketCount requestedPackets,
                                                             AVAudioConverterInputStatus *inputStatus) {
                (void)requestedPackets;
                if (!supplied) {
                    supplied = YES;
                    *inputStatus = AVAudioConverterInputStatus_HaveData;
                    return input;
                }
                *inputStatus = AVAudioConverterInputStatus_NoDataNow;
                return nil;
            }];
        if (convertStatus == AVAudioConverterOutputStatus_Error || error || !output.frameLength) {
            if (error) NSLog(@"[Audio] conversion failed: %@", error.localizedDescription);
            return;
        }
        AudioBuffer buffer = output.audioBufferList->mBuffers[0];
        NSUInteger byteCount = (NSUInteger)output.frameLength * _outputFormat.streamDescription->mBytesPerFrame;
        byteCount = MIN(byteCount, (NSUInteger)buffer.mDataByteSize);
        if (!buffer.mData || !byteCount) return;

        CMTime presentation = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
        Float64 seconds = CMTIME_IS_VALID(presentation) ? CMTimeGetSeconds(presentation) : 0;
        uint64_t timestamp = isfinite(seconds) && seconds > 0 ?
            (uint64_t)llround(seconds * 1000000.0) : 0;
        _handler([NSData dataWithBytes:buffer.mData length:byteCount],
                 (uint32_t)LTOutputSampleRate, (uint16_t)LTOutputChannels, timestamp);
    }
}

- (BOOL)ensureConverterForDescription:(const AudioStreamBasicDescription *)asbd {
    if (_hasInputDescription && memcmp(&_inputDescription, asbd, sizeof(*asbd)) == 0)
        return _converter != nil;
    _inputDescription = *asbd;
    _hasInputDescription = YES;
    _inputFormat = [[AVAudioFormat alloc] initWithStreamDescription:&_inputDescription];
    _converter = _inputFormat ? [[AVAudioConverter alloc] initFromFormat:_inputFormat
                                                                toFormat:_outputFormat] : nil;
    if (_converter && asbd->mChannelsPerFrame == 1)
        _converter.channelMap = @[@0, @0];
    NSLog(@"[Audio] input=%.0fHz/%uch output=48000Hz/2ch converter=%@",
          asbd->mSampleRate, (unsigned)asbd->mChannelsPerFrame, _converter ? @"ready" : @"failed");
    return _converter != nil;
}

@end
