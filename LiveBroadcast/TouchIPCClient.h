#import <Foundation/Foundation.h>

@interface TouchIPCClient : NSObject
- (BOOL)sendTouchEvent:(NSDictionary *)event;
@end
