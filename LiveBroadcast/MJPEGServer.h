#import <Foundation/Foundation.h>
#include <stdint.h>

@class WebRTCStreamer;

// 保留原类名以避免破坏既有工程引用；现在负责网页、WebRTC 信令与独立设备音频流。
@interface MJPEGServer : NSObject
@property (atomic, readonly) BOOL hasAudioClients;
- (instancetype)initWithWebRTCStreamer:(WebRTCStreamer *)streamer;
- (void)start;
- (void)stop;
- (void)publishAudioPCM:(NSData *)pcm
             sampleRate:(uint32_t)sampleRate
               channels:(uint16_t)channels
              timestamp:(uint64_t)timestampMicroseconds;
@end
