#import "BackgroundKeeper.h"
#import <AVFoundation/AVFoundation.h>
#import <string.h>

@interface BackgroundKeeper ()
@property (nonatomic, strong) AVAudioEngine *engine;
@property (nonatomic, strong) AVAudioPlayerNode *player;
@property (nonatomic, strong) AVAudioPCMBuffer *silence;
@end

@implementation BackgroundKeeper

- (BOOL)start {
    if (self.engine.isRunning) return YES;
    NSError *error = nil;
    AVAudioSession *session = AVAudioSession.sharedInstance;
    [session setCategory:AVAudioSessionCategoryPlayback
             withOptions:AVAudioSessionCategoryOptionMixWithOthers
                   error:&error];
    if (!error) [session setActive:YES error:&error];
    if (error) {
        NSLog(@"[Input] background audio session failed: %@", error.localizedDescription);
        return NO;
    }

    self.engine = [AVAudioEngine new];
    self.player = [AVAudioPlayerNode new];
    [self.engine attachNode:self.player];
    AVAudioFormat *format = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32
                                                            sampleRate:44100
                                                              channels:1
                                                           interleaved:NO];
    self.silence = [[AVAudioPCMBuffer alloc] initWithPCMFormat:format frameCapacity:4096];
    self.silence.frameLength = 4096;
    memset(self.silence.floatChannelData[0], 0, sizeof(float) * self.silence.frameLength);
    [self.engine connect:self.player to:self.engine.mainMixerNode format:format];
    self.player.volume = 0.0;
    [self.player scheduleBuffer:self.silence
                         atTime:nil
                        options:AVAudioPlayerNodeBufferLoops
              completionHandler:nil];
    if (![self.engine startAndReturnError:&error]) {
        NSLog(@"[Input] background keeper failed: %@", error.localizedDescription);
        [self stop];
        return NO;
    }
    [self.player play];
    NSLog(@"[Input] main app background control service enabled");
    return YES;
}

- (void)stop {
    [self.player stop];
    [self.engine stop];
    self.silence = nil;
    self.player = nil;
    self.engine = nil;
}

@end
