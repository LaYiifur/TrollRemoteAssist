#import "AppDelegate.h"
#import "BackgroundKeeper.h"
#import "TouchIPCServer.h"
#import "ViewController.h"

@interface AppDelegate ()
@property (nonatomic, strong) TouchIPCServer *touchServer;
@property (nonatomic, strong) BackgroundKeeper *backgroundKeeper;
@end

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = [[UINavigationController alloc]
                                      initWithRootViewController:[ViewController new]];
    [self.window makeKeyAndVisible];
    self.touchServer = [TouchIPCServer new];
    [self.touchServer start];
    self.backgroundKeeper = [BackgroundKeeper new];
    [self.backgroundKeeper start];
    return YES;
}

@end
