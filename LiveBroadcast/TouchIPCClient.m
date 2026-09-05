#import "TouchIPCClient.h"
#import <errno.h>
#import <stdio.h>
#import <sys/socket.h>
#import <sys/un.h>
#import <unistd.h>

static NSString * const LTAppGroup = @"group.com.layii.live";
static NSString * const LTSocketName = @"touch-control.sock";

@interface TouchIPCClient ()
@property (nonatomic) int socketFD;
@property (nonatomic, copy) NSString *socketPath;
@end

@implementation TouchIPCClient

- (instancetype)init {
    if ((self = [super init])) {
        _socketFD = socket(AF_UNIX, SOCK_DGRAM, 0);
        NSURL *container = [[NSFileManager defaultManager]
            containerURLForSecurityApplicationGroupIdentifier:LTAppGroup];
        _socketPath = [[container URLByAppendingPathComponent:LTSocketName] path];
    }
    return self;
}

- (void)dealloc {
    if (_socketFD >= 0) close(_socketFD);
}

- (BOOL)sendTouchEvent:(NSDictionary *)event {
    if (self.socketFD < 0 || !self.socketPath.length ||
        ![NSJSONSerialization isValidJSONObject:event]) return NO;
    NSData *data = [NSJSONSerialization dataWithJSONObject:event options:0 error:nil];
    if (!data.length || data.length > 4096) return NO;
    NSData *pathData = [self.socketPath dataUsingEncoding:NSUTF8StringEncoding];
    if (pathData.length >= sizeof(((struct sockaddr_un *)0)->sun_path)) return NO;
    struct sockaddr_un address = {0};
    address.sun_family = AF_UNIX;
    snprintf(address.sun_path, sizeof(address.sun_path), "%s", self.socketPath.fileSystemRepresentation);
    ssize_t sent = sendto(self.socketFD, data.bytes, data.length, MSG_DONTWAIT,
                          (struct sockaddr *)&address, sizeof(address));
    if (sent != (ssize_t)data.length && errno != ENOENT)
        NSLog(@"[Input] IPC send failed errno=%d", errno);
    return sent == (ssize_t)data.length;
}

@end
