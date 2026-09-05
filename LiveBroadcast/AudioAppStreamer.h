#import <CoreMedia/CoreMedia.h>
#import <Foundation/Foundation.h>

typedef void (^LTAudioPCMHandler)(NSData *pcm, uint32_t sampleRate, uint16_t channels,
                                  uint64_t timestampMicroseconds);

@interface AudioAppStreamer : NSObject
- (instancetype)initWithPCMHandler:(LTAudioPCMHandler)handler;
- (void)processSampleBuffer:(CMSampleBufferRef)sampleBuffer;
- (void)reset;
@end
