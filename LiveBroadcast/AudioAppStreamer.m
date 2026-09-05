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

        size_t listSize = offsetof(AudioBufferList, mBuffers) +
                          sizeof(AudioBuffer) * MAX(1U, asbd->mChannelsPerFrame);
        AudioBufferList *sourceList = calloc(1, listSize);
        if (!sourceList) return;
        CMBlockBufferRef retainedBlock = NULL;
        OSStatus status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, &listSize, sourceList, listSize, kCFAllocatorDefault,
            kCFAllocatorDefault, kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            &retainedBlock);
        if (status != noErr) {
            free(sourceList);
            NSLog(@"[Audio] unable to read AudioBufferList status=%d", (int)status);
            return;
        }

        AVAudioPCMBuffer *input = [[AVAudioPCMBuffer alloc] initWithPCMFormat:_inputFormat
                                                               frameCapacity:frameCount];
        input.frameLength = frameCount;
        AudioBufferList *targetList = input.mutableAudioBufferList;
        BOOL copied = targetList->mNumberBuffers == sourceList->mNumberBuffers;
        if (copied) {
            for (UInt32 index = 0; index < sourceList->mNumberBuffers; index++) {
                AudioBuffer source = sourceList->mBuffers[index];
                AudioBuffer *target = &targetList->mBuffers[index];
                if (!source.mData || source.mDataByteSize > target->mDataByteSize) {
                    copied = NO;
                    break;
                }
                memcpy(target->mData, source.mData, source.mDataByteSize);
                target->mDataByteSize = source.mDataByteSize;
            }
        }
        if (retainedBlock) CFRelease(retainedBlock);
        free(sourceList);
        if (!copied) {
            NSLog(@"[Audio] unsupported input buffer layout");
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
