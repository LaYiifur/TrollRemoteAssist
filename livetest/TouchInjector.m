#import "TouchInjector.h"
#import <CoreFoundation/CoreFoundation.h>
#import <dlfcn.h>
#import <mach/mach_time.h>
#import <math.h>

typedef struct __IOHIDEvent *IOHIDEventRef;
typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;
typedef uint32_t IOHIDDigitizerEventMask;

enum {
    LTHIDRange = 1 << 0,
    LTHIDTouch = 1 << 1,
    LTHIDPosition = 1 << 2,
    LTHIDIdentity = 1 << 5,
    LTHIDAttribute = 1 << 6,
    LTHIDCancel = 1 << 7,
    LTHIDTransducerFinger = 2,
    LTHIDTransducerHand = 3,
    LTHIDFieldIsBuiltIn = 4,
    LTHIDFieldMajorRadius = (11 << 16) + 20,
    LTHIDFieldMinorRadius = (11 << 16) + 21,
    LTHIDFieldDisplayIntegrated = (11 << 16) + 25
};

typedef IOHIDEventSystemClientRef (*LTCreateClient)(CFAllocatorRef);
typedef IOHIDEventRef (*LTCreateDigitizer)(CFAllocatorRef, uint64_t, uint32_t, uint32_t,
                                            uint32_t, IOHIDDigitizerEventMask, uint32_t,
                                            double, double, double, double, double,
                                            uint32_t, uint32_t, uint32_t);
typedef IOHIDEventRef (*LTCreateFinger)(CFAllocatorRef, uint64_t, uint32_t, uint32_t,
                                        IOHIDDigitizerEventMask, double, double, double,
                                        double, double, uint32_t, uint32_t, uint32_t);
typedef void (*LTSetInteger)(IOHIDEventRef, uint32_t, CFIndex);
typedef void (*LTSetFloat)(IOHIDEventRef, uint32_t, double);
typedef void (*LTAppendEvent)(IOHIDEventRef, IOHIDEventRef, uint32_t);
typedef void (*LTSetSenderID)(IOHIDEventRef, uint64_t);
typedef void (*LTDispatchEvent)(IOHIDEventSystemClientRef, IOHIDEventRef);

@interface TouchInjector ()
@property (nonatomic) void *ioKit;
@property (nonatomic) IOHIDEventSystemClientRef client;
@property (nonatomic) LTCreateClient createClient;
@property (nonatomic) LTCreateDigitizer createDigitizer;
@property (nonatomic) LTCreateFinger createFinger;
@property (nonatomic) LTSetInteger setInteger;
@property (nonatomic) LTSetFloat setFloat;
@property (nonatomic) LTAppendEvent appendEvent;
@property (nonatomic) LTSetSenderID setSenderID;
@property (nonatomic) LTDispatchEvent dispatchEvent;
@property (nonatomic) dispatch_queue_t queue;
@property (nonatomic) BOOL active;
@property (nonatomic) double lastX;
@property (nonatomic) double lastY;
@end

@implementation TouchInjector

- (instancetype)init {
    if ((self = [super init])) {
        _queue = dispatch_queue_create("com.layii.live.touch-injector", DISPATCH_QUEUE_SERIAL);
        _ioKit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW | RTLD_LOCAL);
        if (!_ioKit) {
            NSLog(@"[Input] unable to load IOKit: %s", dlerror());
            return self;
        }
        _createClient = (LTCreateClient)dlsym(_ioKit, "IOHIDEventSystemClientCreate");
        _createDigitizer = (LTCreateDigitizer)dlsym(_ioKit, "IOHIDEventCreateDigitizerEvent");
        _createFinger = (LTCreateFinger)dlsym(_ioKit, "IOHIDEventCreateDigitizerFingerEvent");
        _setInteger = (LTSetInteger)dlsym(_ioKit, "IOHIDEventSetIntegerValue");
        _setFloat = (LTSetFloat)dlsym(_ioKit, "IOHIDEventSetFloatValue");
        _appendEvent = (LTAppendEvent)dlsym(_ioKit, "IOHIDEventAppendEvent");
        _setSenderID = (LTSetSenderID)dlsym(_ioKit, "IOHIDEventSetSenderID");
        _dispatchEvent = (LTDispatchEvent)dlsym(_ioKit, "IOHIDEventSystemClientDispatchEvent");
        if ([self symbolsAvailable]) {
            _client = _createClient(kCFAllocatorDefault);
            NSLog(@"[Input] IOHID injector ready=%@", _client ? @"YES" : @"NO");
        } else {
            NSLog(@"[Input] required IOHID symbols are unavailable");
        }
    }
    return self;
}

- (void)dealloc {
    if (_client) CFRelease(_client);
    if (_ioKit) dlclose(_ioKit);
}

- (BOOL)symbolsAvailable {
    return self.ioKit && self.createClient && self.createDigitizer && self.createFinger &&
           self.setInteger && self.setFloat && self.appendEvent && self.setSenderID &&
           self.dispatchEvent;
}

- (void)touchDownAtNormalizedX:(double)x y:(double)y {
    [self enqueuePhase:0 x:x y:y];
}

- (void)touchMoveAtNormalizedX:(double)x y:(double)y {
    [self enqueuePhase:1 x:x y:y];
}

- (void)touchUpAtNormalizedX:(double)x y:(double)y {
    [self enqueuePhase:2 x:x y:y];
}

- (void)touchCancel {
    dispatch_async(self.queue, ^{
        if (!self.active) return;
        [self dispatchPhase:3 x:self.lastX y:self.lastY];
        self.active = NO;
    });
}

- (void)enqueuePhase:(NSInteger)phase x:(double)x y:(double)y {
    if (!isfinite(x) || !isfinite(y)) return;
    x = fmin(1.0, fmax(0.0, x));
    y = fmin(1.0, fmax(0.0, y));
    dispatch_async(self.queue, ^{
        if (phase == 0 && self.active)
            [self dispatchPhase:3 x:self.lastX y:self.lastY];
        if (phase != 0 && !self.active) return;
        self.lastX = x;
        self.lastY = y;
        [self dispatchPhase:phase x:x y:y];
        self.active = phase == 0 || phase == 1;
    });
}

- (void)dispatchPhase:(NSInteger)phase x:(double)x y:(double)y {
    if (!self.client || ![self symbolsAvailable]) return;
    BOOL touching = phase == 0 || phase == 1;
    IOHIDDigitizerEventMask mask;
    if (phase == 0) mask = LTHIDTouch | LTHIDIdentity;
    else if (phase == 1) mask = LTHIDPosition | LTHIDAttribute;
    else if (phase == 3) mask = LTHIDTouch | LTHIDIdentity | LTHIDCancel;
    else mask = LTHIDTouch | LTHIDIdentity;

    uint64_t timestamp = mach_absolute_time();
    IOHIDEventRef parent = self.createDigitizer(kCFAllocatorDefault, timestamp,
        LTHIDTransducerHand, 0, 0, mask, 0, 0, 0, 0, 0, 0, NO, touching, 0);
    IOHIDEventRef finger = self.createFinger(kCFAllocatorDefault, timestamp, 2, 2, mask,
        x, y, 0, 0, 90.0, touching, touching, 0);
    if (!parent || !finger) {
        if (finger) CFRelease(finger);
        if (parent) CFRelease(parent);
        return;
    }
    self.setInteger(parent, LTHIDFieldIsBuiltIn, 1);
    self.setInteger(parent, LTHIDFieldDisplayIntegrated, 1);
    self.setFloat(finger, LTHIDFieldMajorRadius, 5.0);
    self.setFloat(finger, LTHIDFieldMinorRadius, 5.0);
    self.appendEvent(parent, finger, 0);
    self.setSenderID(parent, 0x8000000817319371ULL);
    self.dispatchEvent(self.client, parent);
    CFRelease(finger);
    CFRelease(parent);
}

@end
