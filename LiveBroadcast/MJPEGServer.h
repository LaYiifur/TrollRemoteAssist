#import <Foundation/Foundation.h>

@class WebRTCStreamer;

// 保留原类名以避免破坏既有工程引用；现在负责网页与 WebRTC 信令，不再传输 JPEG。
@interface MJPEGServer : NSObject
- (instancetype)initWithWebRTCStreamer:(WebRTCStreamer *)streamer;
- (void)start;
- (void)stop;
@end
