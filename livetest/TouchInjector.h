#import <Foundation/Foundation.h>

@interface TouchInjector : NSObject
- (void)touchDownAtNormalizedX:(double)x y:(double)y;
- (void)touchMoveAtNormalizedX:(double)x y:(double)y;
- (void)touchUpAtNormalizedX:(double)x y:(double)y;
- (void)touchCancel;
@end
