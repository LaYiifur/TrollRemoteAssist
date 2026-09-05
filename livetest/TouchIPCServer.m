#import "TouchIPCServer.h"
#import "TouchInjector.h"
#import <UIKit/UIKit.h>
#import <errno.h>
#import <fcntl.h>
#import <math.h>
#import <stdio.h>
#import <sys/socket.h>
#import <sys/stat.h>
#import <sys/un.h>
#import <unistd.h>

static NSString * const LTAppGroup = @"group.com.layii.live";
static NSString * const LTSocketName = @"touch-control.sock";

@interface TouchIPCServer ()
@property (nonatomic) int socketFD;
@property (nonatomic, copy) NSString *socketPath;
@property (nonatomic) dispatch_queue_t queue;
@property (nonatomic) dispatch_source_t source;
@property (nonatomic, strong) TouchInjector *injector;
@property (nonatomic) NSInteger activePointerID;
@property (nonatomic) NSInteger activeRotation;
@end

@implementation TouchIPCServer

- (instancetype)init {
    if ((self = [super init])) {
        _socketFD = -1;
        _activePointerID = NSNotFound;
        _queue = dispatch_queue_create("com.layii.live.touch-ipc", DISPATCH_QUEUE_SERIAL);
        _injector = [TouchInjector new];
    }
    return self;
}

- (void)dealloc { [self stop]; }

- (BOOL)start {
    if (self.source) return YES;
    NSURL *container = [[NSFileManager defaultManager]
        containerURLForSecurityApplicationGroupIdentifier:LTAppGroup];
    if (!container) {
        NSLog(@"[Input] App Group container unavailable");
        return NO;
    }
    NSString *path = [[container URLByAppendingPathComponent:LTSocketName] path];
    NSData *pathData = [path dataUsingEncoding:NSUTF8StringEncoding];
    if (pathData.length >= sizeof(((struct sockaddr_un *)0)->sun_path)) {
        NSLog(@"[Input] IPC socket path is too long");
        return NO;
    }

    int fd = socket(AF_UNIX, SOCK_DGRAM, 0);
    if (fd < 0) return NO;
    fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK);
    unlink(path.fileSystemRepresentation);
    struct sockaddr_un address = {0};
    address.sun_family = AF_UNIX;
    snprintf(address.sun_path, sizeof(address.sun_path), "%s", path.fileSystemRepresentation);
    if (bind(fd, (struct sockaddr *)&address, sizeof(address)) != 0) {
        NSLog(@"[Input] IPC bind failed errno=%d", errno);
        close(fd);
        return NO;
    }
    chmod(path.fileSystemRepresentation, 0600);
    self.socketFD = fd;
    self.socketPath = path;
    self.source = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)fd, 0, self.queue);
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(self.source, ^{ [weakSelf drainMessages]; });
    dispatch_source_set_cancel_handler(self.source, ^{ close(fd); });
    dispatch_resume(self.source);
    NSLog(@"[Input] control IPC ready");
    return YES;
}

- (void)stop {
    if (self.source) {
        dispatch_source_cancel(self.source);
        self.source = nil;
        self.socketFD = -1;
    } else if (self.socketFD >= 0) {
        close(self.socketFD);
        self.socketFD = -1;
    }
    if (self.socketPath.length) unlink(self.socketPath.fileSystemRepresentation);
    self.socketPath = nil;
    [self.injector touchCancel];
    self.activePointerID = NSNotFound;
}

- (void)drainMessages {
    uint8_t bytes[4096];
    while (self.socketFD >= 0) {
        ssize_t length = recv(self.socketFD, bytes, sizeof(bytes), 0);
        if (length <= 0) break;
        NSData *data = [NSData dataWithBytes:bytes length:(NSUInteger)length];
        NSDictionary *message = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if ([message isKindOfClass:NSDictionary.class]) [self handleMessage:message];
    }
}

- (void)handleMessage:(NSDictionary *)message {
    if (![message[@"type"] isEqual:@"touch"]) return;
    NSString *phase = message[@"phase"];
    NSInteger pointerID = [message[@"pointerId"] integerValue];
    NSInteger rotation = [message[@"rotation"] integerValue];
    double nx = [message[@"x"] doubleValue];
    double ny = [message[@"y"] doubleValue];
    if (!phase.length || !isfinite(nx) || !isfinite(ny)) return;

    if (self.activePointerID != NSNotFound && rotation != self.activeRotation) {
        [self.injector touchCancel];
        self.activePointerID = NSNotFound;
        NSLog(@"[Input] orientation changed during gesture; cancelled");
    }

    double bufferX = nx;
    double bufferY = ny;
    switch (rotation) {
        case 90:  bufferX = ny;       bufferY = 1.0 - nx; break;
        case 180: bufferX = 1.0 - nx; bufferY = 1.0 - ny; break;
        case 270: bufferX = 1.0 - ny; bufferY = nx;       break;
        default: break;
    }

    double captureWidth = MAX(1.0, [message[@"captureWidth"] doubleValue]);
    double captureHeight = MAX(1.0, [message[@"captureHeight"] doubleValue]);
    double cropWidth = MAX(1.0, [message[@"cropWidth"] doubleValue]);
    double cropHeight = MAX(1.0, [message[@"cropHeight"] doubleValue]);
    double cropX = [message[@"cropX"] doubleValue];
    double cropY = [message[@"cropY"] doubleValue];
    double finalX = (cropX + bufferX * MAX(0.0, cropWidth - 1.0)) /
                    MAX(1.0, captureWidth - 1.0);
    double finalY = (cropY + bufferY * MAX(0.0, cropHeight - 1.0)) /
                    MAX(1.0, captureHeight - 1.0);
    finalX = fmin(1.0, fmax(0.0, finalX));
    finalY = fmin(1.0, fmax(0.0, finalY));

    CGSize nativeSize = UIScreen.mainScreen.nativeBounds.size;
    double px = finalX * MAX(0.0, nativeSize.width - 1.0);
    double py = finalY * MAX(0.0, nativeSize.height - 1.0);
    if (![phase isEqualToString:@"move"])
        NSLog(@"[Input] phase=%@ rotation=%ld final=(%.6f,%.6f) device=(%.2f,%.2f)",
              phase, (long)rotation, finalX, finalY, px, py);

    if ([phase isEqualToString:@"down"]) {
        if (self.activePointerID != NSNotFound) [self.injector touchCancel];
        self.activePointerID = pointerID;
        self.activeRotation = rotation;
        [self.injector touchDownAtNormalizedX:finalX y:finalY];
    } else if ([phase isEqualToString:@"move"] && pointerID == self.activePointerID) {
        [self.injector touchMoveAtNormalizedX:finalX y:finalY];
    } else if ([phase isEqualToString:@"up"] && pointerID == self.activePointerID) {
        [self.injector touchUpAtNormalizedX:finalX y:finalY];
        self.activePointerID = NSNotFound;
    } else if ([phase isEqualToString:@"cancel"] &&
               (self.activePointerID == NSNotFound || pointerID == self.activePointerID)) {
        [self.injector touchCancel];
        self.activePointerID = NSNotFound;
    }
}

@end
