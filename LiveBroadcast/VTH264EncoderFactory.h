#import <Foundation/Foundation.h>
#import <WebRTC/RTCVideoEncoderFactory.h>

NS_ASSUME_NONNULL_BEGIN

@interface VTH264EncoderFactory : NSObject <RTCVideoEncoderFactory>
@property (atomic, readonly, copy) NSString *status;
@property (atomic, readonly) NSUInteger outputFrameCount;
- (void)resetDiagnostics;
@end

NS_ASSUME_NONNULL_END
