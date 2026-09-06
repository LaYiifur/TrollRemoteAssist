#import <CoreMedia/CoreMedia.h>
#import <Foundation/Foundation.h>

typedef void (^WebRTCAnswerCompletion)(NSString *answerSDP, NSError *error);

@interface WebRTCStreamer : NSObject
@property (atomic, readonly) NSUInteger inputFrameCount;
@property (atomic, readonly) NSUInteger submittedFrameCount;
@property (atomic, readonly) NSUInteger droppedFrameCount;
@property (atomic, readonly) NSUInteger encodedFrameCount;
@property (atomic, readonly) unsigned long long packetsSent;
@property (atomic, readonly) unsigned long long bytesSent;
@property (atomic, readonly, copy) NSString *connectionStatus;
@property (atomic, readonly, copy) NSString *captureStatus;
@property (atomic, readonly, copy) NSString *negotiatedCodec;
@property (atomic, readonly, copy) NSString *sendStatus;
@property (atomic, readonly, copy) NSString *controlStatus;
@property (atomic, readonly, copy) NSString *audioStatus;
@property (atomic, readonly, copy) NSString *orientationName;
@property (atomic, readonly) NSInteger captureWidth;
@property (atomic, readonly) NSInteger captureHeight;
@property (atomic, readonly) NSInteger deviceWidth;
@property (atomic, readonly) NSInteger deviceHeight;
@property (atomic, readonly) NSInteger cropWidth;
@property (atomic, readonly) NSInteger cropHeight;
@property (atomic, readonly) NSInteger cropX;
@property (atomic, readonly) NSInteger cropY;
@property (atomic, readonly) NSInteger rotationDegrees;
@property (atomic, readonly) NSUInteger audioPacketCount;
@property (atomic, readonly) NSUInteger audioDroppedCount;
- (void)start;
- (void)stop;
- (void)processVideoSampleBuffer:(CMSampleBufferRef)sampleBuffer;
- (void)processAppAudioSampleBuffer:(CMSampleBufferRef)sampleBuffer;
- (void)createAnswerForOffer:(NSString *)offerSDP
              preferredCodec:(NSString *)preferredCodec
                   completion:(WebRTCAnswerCompletion)completion;
- (void)refreshStatistics;
@end
