#import "WebRTCStreamer.h"
#import "AudioAppStreamer.h"
#import "TouchIPCClient.h"
#import "VTH264EncoderFactory.h"
#import <ImageIO/ImageIO.h>
#import <QuartzCore/QuartzCore.h>
#import <ReplayKit/ReplayKit.h>
#import <UIKit/UIKit.h>
#import <WebRTC/WebRTC.h>
#import <math.h>
#import <stdlib.h>
#import <string.h>

static NSString * const WebRTCStreamerErrorDomain = @"com.layii.live.webrtc";
static NSString * const ResolutionDefaultsSuite = @"group.com.layii.live";
static NSString * const UseMaximumResolutionKey = @"resolution.useMaximum";
static NSString * const ResolutionWidthKey = @"resolution.width";
static NSString * const ResolutionHeightKey = @"resolution.height";
static NSString * const HighQualityHighFPSKey = @"stream.highQualityHighFPS";
enum {
    kMotionGridWidth = 16,
    kMotionGridHeight = 9,
    kMotionGridSize = kMotionGridWidth * kMotionGridHeight
};

@interface LTViewerSession : NSObject
@property (nonatomic) NSUInteger identifier;
@property (nonatomic, copy) NSString *codec;
@property (nonatomic, strong) RTCPeerConnection *peerConnection;
@property (nonatomic, strong) RTCRtpSender *videoSender;
@property (nonatomic, strong) RTCRtpTransceiver *videoTransceiver;
@property (nonatomic, strong) RTCDataChannel *controlChannel;
@property (nonatomic, strong) RTCDataChannel *audioChannel;
@property (nonatomic, copy) WebRTCAnswerCompletion pendingAnswer;
@property (nonatomic) BOOL controlEnabled;
@property (nonatomic) BOOL audioEnabled;
@property (nonatomic) BOOL statisticsQueryInFlight;
@property (nonatomic) NSUInteger lastTouchSequence;
@property (nonatomic) NSInteger lastControlPointerID;
@property (nonatomic) unsigned long long packetsSent;
@property (nonatomic) unsigned long long bytesSent;
@property (nonatomic) NSUInteger encodedFrameCount;
@property (nonatomic) BOOL retired;
@end
@implementation LTViewerSession
@end

@interface WebRTCStreamer () <RTCPeerConnectionDelegate, RTCDataChannelDelegate>
@property (nonatomic, strong) RTCPeerConnectionFactory *factory;
@property (nonatomic, strong) VTH264EncoderFactory *encoderFactory;
@property (nonatomic, strong) RTCVideoSource *videoSource;
@property (nonatomic, strong) RTCVideoCapturer *capturer;
@property (nonatomic, strong) RTCVideoTrack *videoTrack;
@property (nonatomic, strong) TouchIPCClient *touchIPC;
@property (nonatomic, strong) AudioAppStreamer *audioStreamer;
@property (nonatomic, strong) NSMutableArray<LTViewerSession *> *sessions;
@property (nonatomic, weak) LTViewerSession *touchOwner;
@property (atomic, readwrite) NSUInteger inputFrameCount;
@property (atomic, readwrite) NSUInteger submittedFrameCount;
@property (atomic, readwrite) NSUInteger droppedFrameCount;
@property (atomic, readwrite) NSUInteger encodedFrameCount;
@property (atomic, readwrite) unsigned long long packetsSent;
@property (atomic, readwrite) unsigned long long bytesSent;
@property (atomic, readwrite, copy) NSString *connectionStatus;
@property (atomic, readwrite, copy) NSString *captureStatus;
@property (atomic, readwrite, copy) NSString *negotiatedCodec;
@property (atomic, readwrite, copy) NSString *sendStatus;
@property (atomic, readwrite, copy) NSString *controlStatus;
@property (atomic, readwrite, copy) NSString *audioStatus;
@property (atomic, readwrite, copy) NSString *orientationName;
@property (atomic, readwrite) NSInteger captureWidth;
@property (atomic, readwrite) NSInteger captureHeight;
@property (atomic, readwrite) NSInteger deviceWidth;
@property (atomic, readwrite) NSInteger deviceHeight;
@property (atomic, readwrite) NSInteger cropWidth;
@property (atomic, readwrite) NSInteger cropHeight;
@property (atomic, readwrite) NSInteger cropX;
@property (atomic, readwrite) NSInteger cropY;
@property (atomic, readwrite) NSInteger rotationDegrees;
@property (atomic, readwrite) NSUInteger audioPacketCount;
@property (atomic, readwrite) NSUInteger audioDroppedCount;
@property (nonatomic) NSUInteger nextSessionIdentifier;
@property (nonatomic) CFTimeInterval lastSubmittedTime;
@property (atomic) BOOL useMaximumResolution;
@property (atomic) NSInteger requestedWidth;
@property (atomic) NSInteger requestedHeight;
@property (atomic) NSInteger targetFrameRate;
@property (atomic) BOOL highQualityHighFPS;
@property (nonatomic, strong) dispatch_queue_t frameQueue;
@property (nonatomic, strong) dispatch_queue_t audioQueue;
@property (nonatomic, strong) dispatch_source_t keepaliveTimer;
@property (atomic) BOOL stopping;
- (NSArray<LTViewerSession *> *)sessionSnapshot;
- (NSArray<LTViewerSession *> *)audioSessionSnapshot;
- (NSUInteger)sessionCount;
- (LTViewerSession *)sessionForPeerConnection:(RTCPeerConnection *)peerConnection;
- (LTViewerSession *)sessionForDataChannel:(RTCDataChannel *)dataChannel;
- (void)removeSession:(LTViewerSession *)session;
- (void)removeSessionAfterDelegateCallback:(LTViewerSession *)session;
- (void)cancelTouchForSession:(LTViewerSession *)session;
- (void)finishSession:(LTViewerSession *)session;
- (void)failSession:(LTViewerSession *)session error:(NSError *)error;
- (void)applyVideoSenderParametersForSession:(LTViewerSession *)session;
- (void)reloadStreamingPreferences;
- (void)handleControlMessage:(NSDictionary *)message session:(LTViewerSession *)session;
- (void)drainPendingAudioSamples;
@end

@implementation WebRTCStreamer {
    CMSampleBufferRef _pendingSampleBuffer;
    CMSampleBufferRef _lastSampleBuffer;
    BOOL _frameWorkerScheduled;
    BOOL _hasLumaHistory;
    uint8_t _lumaHistory[kMotionGridSize];
    CFTimeInterval _motionUntilTime;
    int64_t _lastTimestampNs;
    int _adaptedWidth;
    int _adaptedHeight;
    int _adaptedFPS;
    RTCVideoRotation _lastRotation;
    uint32_t _audioSequence;
    CMSampleBufferRef _pendingAudioSampleBuffer;
    BOOL _audioWorkerScheduled;
}

- (instancetype)init {
    if ((self = [super init])) {
        _frameQueue = dispatch_queue_create("com.layii.live.webrtc.frames", DISPATCH_QUEUE_SERIAL);
        _audioQueue = dispatch_queue_create("com.layii.live.webrtc.audio", DISPATCH_QUEUE_SERIAL);
        _connectionStatus = @"正在准备 WebRTC";
        _captureStatus = @"等待 ReplayKit 画面";
        _negotiatedCodec = @"未协商";
        _sendStatus = @"尚未连接";
        _controlStatus = @"控制未连接";
        _audioStatus = @"声音未启用";
        _orientationName = @"portrait";
        _touchIPC = [TouchIPCClient new];
        _sessions = [NSMutableArray array];
    }
    return self;
}

- (void)start {
    @synchronized (self) {
        if (self.factory) return;
        self.stopping = NO;
        RTCInitializeSSL();
        RTCSetMinDebugLogLevel(RTCLoggingSeverityError);

        self.encoderFactory = [VTH264EncoderFactory new];
        RTCDefaultVideoDecoderFactory *decoder = [RTCDefaultVideoDecoderFactory new];
        self.factory = [[RTCPeerConnectionFactory alloc] initWithEncoderFactory:self.encoderFactory
                                                                 decoderFactory:decoder];
        RTCPeerConnectionFactoryOptions *options = [RTCPeerConnectionFactoryOptions new];
        options.disableNetworkMonitor = YES;
        [self.factory setOptions:options];
        self.videoSource = [self.factory videoSource];
        self.capturer = [[RTCVideoCapturer alloc] initWithDelegate:self.videoSource];
        self.videoTrack = [self.factory videoTrackWithSource:self.videoSource trackId:@"screen-video"];
        CGSize nativeSize = UIScreen.mainScreen.nativeBounds.size;
        self.deviceWidth = (NSInteger)nativeSize.width;
        self.deviceHeight = (NSInteger)nativeSize.height;
        __weak typeof(self) weakSelf = self;
        self.audioStreamer = [[AudioAppStreamer alloc]
            initWithPCMHandler:^(NSData *pcm, uint32_t sampleRate, uint16_t channels,
                                 uint64_t timestampMicroseconds) {
                [weakSelf sendAudioPCM:pcm sampleRate:sampleRate channels:channels
                             timestamp:timestampMicroseconds];
            }];
        NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:ResolutionDefaultsSuite];
        [defaults registerDefaults:@{
            UseMaximumResolutionKey: @YES,
            ResolutionWidthKey: @720,
            ResolutionHeightKey: @1280,
            HighQualityHighFPSKey: @YES
        }];
        self.useMaximumResolution = [defaults boolForKey:UseMaximumResolutionKey];
        NSInteger width = MAX(160, MIN(4096, [defaults integerForKey:ResolutionWidthKey]));
        NSInteger height = MAX(160, MIN(4096, [defaults integerForKey:ResolutionHeightKey]));
        self.requestedWidth = width & ~1;
        self.requestedHeight = height & ~1;
        self.highQualityHighFPS = [defaults boolForKey:HighQualityHighFPSKey];
        self.targetFrameRate = self.highQualityHighFPS ? 30 : 24;
        self.connectionStatus = @"等待浏览器连接";
        [self startKeepaliveTimer];
        NSLog(@"[LiveBroadcast] WebRTC sender ready");
    }
}

- (void)stop {
    self.stopping = YES;
    LTViewerSession *touchOwner = self.touchOwner;
    if (touchOwner) [self cancelTouchForSession:touchOwner];
    NSArray<LTViewerSession *> *sessions;
    @synchronized (self) {
        sessions = self.sessions.copy;
        [self.sessions removeAllObjects];
        self.touchOwner = nil;
    }
    for (LTViewerSession *session in sessions) {
        if (session.pendingAnswer) {
            WebRTCAnswerCompletion completion = session.pendingAnswer;
            session.pendingAnswer = nil;
            completion(nil, [self errorWithMessage:@"直播已停止"]);
        }
        session.controlChannel.delegate = nil;
        session.audioChannel.delegate = nil;
        [session.peerConnection close];
    }
    dispatch_sync(self.audioQueue, ^{
        @synchronized (self) {
            if (self->_pendingAudioSampleBuffer) {
                CFRelease(self->_pendingAudioSampleBuffer);
                self->_pendingAudioSampleBuffer = NULL;
            }
            self->_audioWorkerScheduled = NO;
        }
    });
    [self.audioStreamer reset];
    self.audioStreamer = nil;
    if (self.keepaliveTimer) {
        dispatch_source_cancel(self.keepaliveTimer);
        self.keepaliveTimer = nil;
    }
    dispatch_sync(self.frameQueue, ^{
        @synchronized (self) {
            if (self->_pendingSampleBuffer) {
                CFRelease(self->_pendingSampleBuffer);
                self->_pendingSampleBuffer = NULL;
            }
            if (self->_lastSampleBuffer) {
                CFRelease(self->_lastSampleBuffer);
                self->_lastSampleBuffer = NULL;
            }
            self->_frameWorkerScheduled = NO;
        }
    });
    self.videoTrack = nil;
    self.capturer = nil;
    self.videoSource = nil;
    self.factory = nil;
    self.encoderFactory = nil;
    self.connectionStatus = @"已停止";
    self.captureStatus = @"已停止";
    self.sendStatus = @"已停止";
    self.controlStatus = @"已停止";
    self.audioStatus = @"已停止";
}

- (void)createAnswerForOffer:(NSString *)offerSDP
              preferredCodec:(NSString *)preferredCodec
                   completion:(WebRTCAnswerCompletion)completion {
    if (!offerSDP.length) {
        completion(nil, [self errorWithMessage:@"浏览器 Offer 为空"]);
        return;
    }
    if (!self.factory) [self start];
    [self reloadStreamingPreferences];

    // 稳定单观看端模式：新连接完全替换旧连接。
    for (LTViewerSession *oldSession in [self sessionSnapshot])
        [self removeSession:oldSession];

    NSString *requestedCodec = [[preferredCodec uppercaseString] isEqualToString:@"VP8"] ? @"VP8" : @"H264";
    NSError *filterError = nil;
    NSString *filteredOffer = [self offerSDP:offerSDP limitedToCodec:requestedCodec error:&filterError];
    if (!filteredOffer) {
        completion(nil, filterError ?: [self errorWithMessage:@"浏览器不支持请求的编码"]);
        return;
    }
    BOOL useVP8 = [requestedCodec isEqualToString:@"VP8"];
    self.negotiatedCodec = [requestedCodec isEqualToString:@"H264"] ? @"H.264（协商中）" : @"VP8（协商中）";
    self.sendStatus = @"等待发送轨道建立";

    LTViewerSession *session = [LTViewerSession new];
    session.identifier = ++self.nextSessionIdentifier;
    session.codec = useVP8 ? @"VP8 兼容模式" : @"H.264 VideoToolbox";
    session.controlEnabled = YES;
    // 音频是否真正共享由被控端 App 的开关决定；浏览器不再负责“启动”发送。
    session.audioEnabled = YES;
    session.lastControlPointerID = NSNotFound;
    RTCConfiguration *configuration = [RTCConfiguration new];
    configuration.iceServers = @[];
    configuration.iceTransportPolicy = RTCIceTransportPolicyAll;
    configuration.sdpSemantics = RTCSdpSemanticsUnifiedPlan;
    configuration.continualGatheringPolicy = RTCContinualGatheringPolicyGatherOnce;
    configuration.enableDscp = YES;
    RTCMediaConstraints *peerConstraints = [[RTCMediaConstraints alloc]
        initWithMandatoryConstraints:nil
                 optionalConstraints:@{@"DtlsSrtpKeyAgreement": @"true"}];
    session.peerConnection = [self.factory peerConnectionWithConfiguration:configuration
                                                                 constraints:peerConstraints
                                                                    delegate:self];

    self.videoTrack.isEnabled = YES;
    session.videoSender = [session.peerConnection addTrack:self.videoTrack streamIds:@[@"screen"]];
    if (!session.videoSender) {
        [session.peerConnection close];
        completion(nil, [self errorWithMessage:@"无法创建 WebRTC 视频发送轨道"]);
        return;
    }
    for (RTCRtpTransceiver *transceiver in session.peerConnection.transceivers) {
        if (![transceiver.sender.senderId isEqualToString:session.videoSender.senderId]) continue;
        NSError *directionError = nil;
        [transceiver setDirection:RTCRtpTransceiverDirectionSendOnly error:&directionError];
        if (directionError) {
            [session.peerConnection close];
            completion(nil, [self errorWithMessage:[NSString stringWithFormat:
                @"无法启用视频发送方向：%@", directionError.localizedDescription]]);
            return;
        }
        session.videoTransceiver = transceiver;
        break;
    }

    session.pendingAnswer = completion;
    @synchronized (self) { [self.sessions addObject:session]; }
    self.connectionStatus = [NSString stringWithFormat:@"正在协商连接 · %lu 个观看端",
                             (unsigned long)[self sessionCount]];
    RTCSessionDescription *offer = [[RTCSessionDescription alloc] initWithType:RTCSdpTypeOffer sdp:filteredOffer];
    __weak typeof(self) weakSelf = self;
    __weak LTViewerSession *weakSession = session;
    [session.peerConnection setRemoteDescription:offer completionHandler:^(NSError *error) {
        LTViewerSession *strongSession = weakSession;
        if (!strongSession) return;
        if (error) {
            [weakSelf failSession:strongSession error:error];
            return;
        }
        RTCMediaConstraints *answerConstraints = [[RTCMediaConstraints alloc]
            initWithMandatoryConstraints:nil optionalConstraints:nil];
        [strongSession.peerConnection answerForConstraints:answerConstraints
                                         completionHandler:^(RTCSessionDescription *answer, NSError *answerError) {
            if (answerError || !answer) {
                [weakSelf failSession:strongSession
                                error:answerError ?: [weakSelf errorWithMessage:@"无法创建 Answer"]];
                return;
            }
            [strongSession.peerConnection setLocalDescription:answer completionHandler:^(NSError *localError) {
                if (localError) {
                    [weakSelf failSession:strongSession error:localError];
                    return;
                }
                NSString *actualCodec = [weakSelf codecNameFromSDP:answer.sdp];
                if (actualCodec.length) weakSelf.negotiatedCodec = actualCodec;
                [weakSelf applyVideoSenderParametersForSession:strongSession];
                [weakSelf refreshStatistics];
                if (strongSession.peerConnection.iceGatheringState == RTCIceGatheringStateComplete) {
                    [weakSelf finishSession:strongSession];
                }
            }];
        }];
    }];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 6 * NSEC_PER_SEC),
                   dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        LTViewerSession *strongSession = weakSession;
        if (strongSession) [weakSelf finishSession:strongSession];
    });
}

- (NSString *)offerSDP:(NSString *)offerSDP
         limitedToCodec:(NSString *)codec
                  error:(NSError **)error {
    NSString *normalized = [[offerSDP stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"]
                            stringByReplacingOccurrencesOfString:@"\r" withString:@"\n"];
    NSMutableArray<NSString *> *lines = [[normalized componentsSeparatedByString:@"\n"] mutableCopy];
    NSInteger videoStart = NSNotFound;
    NSInteger videoEnd = lines.count;
    for (NSInteger index = 0; index < (NSInteger)lines.count; index++) {
        if ([lines[index] hasPrefix:@"m=video "]) {
            videoStart = index;
            break;
        }
    }
    if (videoStart == NSNotFound) {
        if (error) *error = [self errorWithMessage:@"Offer 中没有视频轨道"];
        return nil;
    }
    for (NSInteger index = videoStart + 1; index < (NSInteger)lines.count; index++) {
        if ([lines[index] hasPrefix:@"m="]) {
            videoEnd = index;
            break;
        }
    }

    NSMutableDictionary<NSString *, NSString *> *codecByPayload = [NSMutableDictionary dictionary];
    for (NSInteger index = videoStart + 1; index < videoEnd; index++) {
        NSString *line = lines[index];
        if (![line hasPrefix:@"a=rtpmap:"]) continue;
        NSString *payload = [self payloadTypeFromAttributeLine:line];
        NSRange space = [line rangeOfString:@" "];
        if (!payload.length || space.location == NSNotFound) continue;
        NSString *description = [line substringFromIndex:NSMaxRange(space)];
        NSString *name = [[description componentsSeparatedByString:@"/"] firstObject];
        if (name.length) codecByPayload[payload] = [name uppercaseString];
    }

    NSMutableSet<NSString *> *allowedPayloads = [NSMutableSet set];
    [codecByPayload enumerateKeysAndObjectsUsingBlock:^(NSString *payload, NSString *name, BOOL *stop) {
        if ([name isEqualToString:codec]) [allowedPayloads addObject:payload];
    }];
    if (!allowedPayloads.count) {
        if (error) {
            NSString *display = [codec isEqualToString:@"H264"] ? @"H.264" : codec;
            *error = [self errorWithMessage:[NSString stringWithFormat:@"浏览器 Offer 不包含 %@", display]];
        }
        return nil;
    }

    // 保留与所选主编码绑定的 RTX payload，其他视频编码从 Offer 中彻底移除。
    for (NSInteger index = videoStart + 1; index < videoEnd; index++) {
        NSString *line = lines[index];
        if (![line hasPrefix:@"a=fmtp:"]) continue;
        NSString *payload = [self payloadTypeFromAttributeLine:line];
        NSString *apt = [self aptPayloadFromFmtpLine:line];
        if (payload.length && apt.length && [allowedPayloads containsObject:apt])
            [allowedPayloads addObject:payload];
    }

    NSArray<NSString *> *mTokens = [self nonEmptyTokensFromLine:lines[videoStart]];
    if (mTokens.count < 4) {
        if (error) *error = [self errorWithMessage:@"Offer 的视频描述无效"];
        return nil;
    }
    NSMutableArray<NSString *> *newMTokens = [[mTokens subarrayWithRange:NSMakeRange(0, 3)] mutableCopy];
    for (NSInteger index = 3; index < (NSInteger)mTokens.count; index++) {
        if ([allowedPayloads containsObject:mTokens[index]]) [newMTokens addObject:mTokens[index]];
    }
    lines[videoStart] = [newMTokens componentsJoinedByString:@" "];

    for (NSInteger index = videoEnd - 1; index > videoStart; index--) {
        NSString *line = lines[index];
        if (![line hasPrefix:@"a=rtpmap:"] && ![line hasPrefix:@"a=fmtp:"] &&
            ![line hasPrefix:@"a=rtcp-fb:"]) continue;
        NSString *payload = [self payloadTypeFromAttributeLine:line];
        if (payload.length && ![allowedPayloads containsObject:payload]) {
            [lines removeObjectAtIndex:index];
        }
    }
    while (lines.lastObject.length == 0) [lines removeLastObject];
    return [[lines componentsJoinedByString:@"\r\n"] stringByAppendingString:@"\r\n"];
}

- (NSArray<NSString *> *)nonEmptyTokensFromLine:(NSString *)line {
    NSMutableArray<NSString *> *tokens = [NSMutableArray array];
    for (NSString *token in [line componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet])
        if (token.length) [tokens addObject:token];
    return tokens;
}

- (NSString *)payloadTypeFromAttributeLine:(NSString *)line {
    NSRange colon = [line rangeOfString:@":"];
    if (colon.location == NSNotFound) return nil;
    NSString *tail = [line substringFromIndex:NSMaxRange(colon)];
    NSString *payload = [[tail componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet]
                         firstObject];
    if (!payload.length || [payload isEqualToString:@"*"]) return nil;
    NSCharacterSet *nonDigits = NSCharacterSet.decimalDigitCharacterSet.invertedSet;
    return [payload rangeOfCharacterFromSet:nonDigits].location == NSNotFound ? payload : nil;
}

- (NSString *)aptPayloadFromFmtpLine:(NSString *)line {
    NSRange aptRange = [line rangeOfString:@"apt=" options:NSCaseInsensitiveSearch];
    if (aptRange.location == NSNotFound) return nil;
    NSString *tail = [line substringFromIndex:NSMaxRange(aptRange)];
    NSScanner *scanner = [NSScanner scannerWithString:tail];
    NSInteger payload = -1;
    return [scanner scanInteger:&payload] && payload >= 0 ? [NSString stringWithFormat:@"%ld", (long)payload] : nil;
}

- (NSString *)codecNameFromSDP:(NSString *)sdp {
    NSString *normalized = [sdp stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"];
    NSArray<NSString *> *lines = [normalized componentsSeparatedByString:@"\n"];
    BOOL inVideo = NO;
    for (NSString *line in lines) {
        if ([line hasPrefix:@"m="]) inVideo = [line hasPrefix:@"m=video "];
        if (!inVideo || ![line hasPrefix:@"a=rtpmap:"]) continue;
        NSString *upper = line.uppercaseString;
        if ([upper containsString:@" H264/90000"]) return @"H.264";
        if ([upper containsString:@" VP8/90000"]) return @"VP8";
    }
    return nil;
}

- (void)reloadStreamingPreferences {
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:ResolutionDefaultsSuite];
    [defaults registerDefaults:@{HighQualityHighFPSKey: @YES}];
    self.highQualityHighFPS = [defaults boolForKey:HighQualityHighFPSKey];
    self.targetFrameRate = self.highQualityHighFPS ? 30 : 24;
}

- (void)applyVideoSenderParametersForSession:(LTViewerSession *)session {
    RTCRtpSender *sender = session.videoSender;
    if (!sender) return;

    [self reloadStreamingPreferences];

    BOOL useVP8 = [session.codec hasPrefix:@"VP8"];
    BOOL highQuality = self.highQualityHighFPS;
    NSNumber *maxBitrate = nil;
    NSNumber *currentBitrate = nil;
    NSNumber *minBitrate = nil;
    NSInteger maxFPS = 0;

    if (highQuality) {
        maxBitrate = useVP8 ? @25000000 : @40000000;
        currentBitrate = useVP8 ? @12000000 : @24000000;
        minBitrate = useVP8 ? @4000000 : @8000000;
        maxFPS = 30;
    } else {
        maxBitrate = useVP8 ? @5000000 : @12000000;
        currentBitrate = useVP8 ? @2500000 : @6000000;
        minBitrate = @300000;
        maxFPS = useVP8 ? 20 : 24;
    }

    RTCRtpParameters *parameters = sender.parameters;
    parameters.degradationPreference = @(highQuality ?
        RTCDegradationPreferenceDisabled : RTCDegradationPreferenceBalanced);

    for (RTCRtpEncodingParameters *encoding in parameters.encodings) {
        encoding.isActive = YES;
        encoding.maxBitrateBps = maxBitrate;
        encoding.maxFramerate = @(maxFPS);
        encoding.bitratePriority = highQuality ? 2.0 : 1.0;
        encoding.networkPriority = RTCPriorityHigh;
    }
    sender.parameters = parameters;

    BOOL bandwidthSet = [session.peerConnection setBweMinBitrateBps:minBitrate
                                                   currentBitrateBps:currentBitrate
                                                       maxBitrateBps:maxBitrate];

    if (highQuality) {
        self.sendStatus = bandwidthSet ?
            @"尽量不降低画质 · 30fps · 高码率" :
            @"尽量不降低画质已启用（码率设置未采用）";
    } else {
        self.sendStatus = bandwidthSet ?
            @"标准压缩模式 · 自适应带宽" :
            @"标准压缩模式（码率设置未采用）";
    }
}

- (void)refreshStatistics {
    NSArray<LTViewerSession *> *sessions = [self sessionSnapshot];
    __weak typeof(self) weakSelf = self;
    for (LTViewerSession *session in sessions) {
        if (!session.videoSender || session.statisticsQueryInFlight) continue;
        session.statisticsQueryInFlight = YES;
        RTCPeerConnection *peerConnection = session.peerConnection;
        [peerConnection statisticsForSender:session.videoSender completionHandler:^(RTCStatisticsReport *report) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        session.statisticsQueryInFlight = NO;
        if ([strongSelf sessionForPeerConnection:peerConnection] != session) return;

        unsigned long long packets = 0;
        unsigned long long bytes = 0;
        NSUInteger encoded = 0;
        NSString *codecID = nil;
        for (RTCStatistics *statistics in report.statistics.allValues) {
            if (![statistics.type isEqualToString:@"outbound-rtp"]) continue;
            NSObject *kind = statistics.values[@"kind"] ?: statistics.values[@"mediaType"];
            if ([kind isKindOfClass:NSString.class] && ![(NSString *)kind isEqualToString:@"video"]) continue;
            packets += [strongSelf unsignedValue:statistics.values[@"packetsSent"]];
            bytes += [strongSelf unsignedValue:statistics.values[@"bytesSent"]];
            NSUInteger candidate = (NSUInteger)[strongSelf unsignedValue:statistics.values[@"framesEncoded"]];
            if (!candidate) candidate = (NSUInteger)[strongSelf unsignedValue:statistics.values[@"framesSent"]];
            encoded = MAX(encoded, candidate);
            NSObject *candidateCodecID = statistics.values[@"codecId"];
            if ([candidateCodecID isKindOfClass:NSString.class]) codecID = (NSString *)candidateCodecID;
        }
        if (codecID.length) {
            RTCStatistics *codecStats = report.statistics[codecID];
            NSObject *mime = codecStats.values[@"mimeType"];
            if ([mime isKindOfClass:NSString.class]) {
                NSString *upper = [(NSString *)mime uppercaseString];
                if ([upper containsString:@"H264"]) session.codec = @"H.264 VideoToolbox";
                else if ([upper containsString:@"VP8"]) session.codec = @"VP8 兼容模式";
            }
        }
        session.packetsSent = packets;
        session.bytesSent = bytes;
        session.encodedFrameCount = encoded;
        [strongSelf updateAggregateStatistics];
        }];
    }
}

- (void)updateAggregateStatistics {
    unsigned long long packets = 0;
    unsigned long long bytes = 0;
    NSUInteger encoded = 0;
    NSArray<LTViewerSession *> *sessions = [self sessionSnapshot];
    for (LTViewerSession *session in sessions) {
        packets += session.packetsSent;
        bytes += session.bytesSent;
        encoded += session.encodedFrameCount;
    }
    self.packetsSent = packets;
    self.bytesSent = bytes;
    self.encodedFrameCount = MAX(encoded, self.encoderFactory.outputFrameCount);
    if (packets > 0) self.sendStatus = [NSString stringWithFormat:@"视频正在上传 · %lu 个观看端",
                                        (unsigned long)sessions.count];
    else if (self.encodedFrameCount > 0) self.sendStatus = @"已编码，但 RTP 尚未发出";
    else if (sessions.count && self.submittedFrameCount > 0)
        self.sendStatus = self.encoderFactory.status.length ? self.encoderFactory.status : @"连接正常，但编码器没有输出";
}

- (unsigned long long)unsignedValue:(NSObject *)value {
    return [value respondsToSelector:@selector(unsignedLongLongValue)] ?
        [(NSNumber *)value unsignedLongLongValue] : 0;
}

- (void)processVideoSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    if (!sampleBuffer || CMSampleBufferGetNumSamples(sampleBuffer) != 1 ||
        !CMSampleBufferIsValid(sampleBuffer) ||
        !CMSampleBufferDataIsReady(sampleBuffer)) return;
    CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (!pixelBuffer || self.stopping) return;
    NSInteger width = (NSInteger)CVPixelBufferGetWidth(pixelBuffer);
    NSInteger height = (NSInteger)CVPixelBufferGetHeight(pixelBuffer);
    RTCVideoRotation rotation = [self rotationForSampleBuffer:sampleBuffer];
    if (width != self.captureWidth || height != self.captureHeight ||
        rotation != self.rotationDegrees) {
        self.captureWidth = width;
        self.captureHeight = height;
        self.rotationDegrees = rotation;
        self.orientationName = [self orientationNameForRotation:rotation];
        NSLog(@"[Video] capture=%ldx%ld orientation=%@ rotation=%ld",
              (long)width, (long)height, self.orientationName, (long)rotation);
    }
    self.inputFrameCount++;
    CMSampleBufferRef retained = (CMSampleBufferRef)CFRetain(sampleBuffer);
    BOOL scheduleWorker = NO;
    @synchronized (self) {
        if (self.stopping) {
            CFRelease(retained);
            return;
        }
        if (_pendingSampleBuffer) {
            CFRelease(_pendingSampleBuffer);
            self.droppedFrameCount++;
        }
        _pendingSampleBuffer = retained;
        if (!_frameWorkerScheduled) {
            _frameWorkerScheduled = YES;
            scheduleWorker = YES;
        }
    }
    if (scheduleWorker) {
        __weak typeof(self) weakSelf = self;
        dispatch_async(self.frameQueue, ^{ [weakSelf drainPendingFrames]; });
    }
}

- (void)drainPendingFrames {
    while (!self.stopping) {
        CMSampleBufferRef sampleBuffer = NULL;
        @synchronized (self) {
            sampleBuffer = _pendingSampleBuffer;
            _pendingSampleBuffer = NULL;
            if (!sampleBuffer) {
                _frameWorkerScheduled = NO;
                return;
            }
        }
        [self consumeVideoSampleBuffer:sampleBuffer retransmission:NO];
        CFRelease(sampleBuffer);
    }
}

- (void)consumeVideoSampleBuffer:(CMSampleBufferRef)sampleBuffer retransmission:(BOOL)retransmission {
    CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    RTCVideoSource *source = self.videoSource;
    if (!pixelBuffer || !source || self.stopping) return;

    CFTimeInterval now = CACurrentMediaTime();
    BOOL moving = retransmission ? NO : [self pixelBufferHasMotion:pixelBuffer atTime:now];
    NSInteger fullFPS = MAX(1, self.targetFrameRate);
    NSInteger staticFPS = self.highQualityHighFPS ? fullFPS : 10;
    NSInteger desiredFPS = moving ? fullFPS : MIN(fullFPS, staticFPS);
    if (!retransmission && now - self.lastSubmittedTime < (1.0 / desiredFPS)) {
        self.droppedFrameCount++;
        return;
    }

    OSType pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer);
    if (![[RTCCVPixelBuffer supportedPixelFormats] containsObject:@(pixelFormat)]) {
        self.droppedFrameCount++;
        self.captureStatus = [NSString stringWithFormat:@"不支持的像素格式 %@",
                              [self fourCCString:pixelFormat]];
        return;
    }

    int sourceWidth = (int)CVPixelBufferGetWidth(pixelBuffer);
    int sourceHeight = (int)CVPixelBufferGetHeight(pixelBuffer);
    int cropWidth = MAX(2, sourceWidth & ~1);
    int cropHeight = MAX(2, sourceHeight & ~1);
    int cropX = 0;
    int cropY = 0;
    int outputWidth = self.useMaximumResolution ? cropWidth : (int)self.requestedWidth;
    int outputHeight = self.useMaximumResolution ? cropHeight : (int)self.requestedHeight;

    if (!self.useMaximumResolution) {
        double sourceAspect = (double)cropWidth / cropHeight;
        double targetAspect = (double)outputWidth / outputHeight;
        if (sourceAspect > targetAspect) {
            cropWidth = MAX(2, ((int)floor(cropHeight * targetAspect)) & ~1);
            cropX = MAX(0, ((sourceWidth - cropWidth) / 2) & ~1);
        } else if (sourceAspect < targetAspect) {
            cropHeight = MAX(2, ((int)floor(cropWidth / targetAspect)) & ~1);
            cropY = MAX(0, ((sourceHeight - cropHeight) / 2) & ~1);
        }
    }
    self.cropWidth = cropWidth;
    self.cropHeight = cropHeight;
    self.cropX = cropX;
    self.cropY = cropY;
    if (_adaptedWidth != outputWidth || _adaptedHeight != outputHeight || _adaptedFPS != fullFPS) {
        [source adaptOutputFormatToWidth:outputWidth height:outputHeight fps:(int)fullFPS];
        _adaptedWidth = outputWidth;
        _adaptedHeight = outputHeight;
        _adaptedFPS = (int)fullFPS;
    }

    RTCVideoRotation rotation = retransmission ? _lastRotation : [self rotationForSampleBuffer:sampleBuffer];
    int64_t timestampNs;
    if (retransmission) {
        timestampNs = MAX(_lastTimestampNs + 1000000, (int64_t)llround(now * NSEC_PER_SEC));
    } else {
        CMTime presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
        Float64 seconds = CMTIME_IS_VALID(presentationTime) ? CMTimeGetSeconds(presentationTime) : now;
        if (!isfinite(seconds)) seconds = now;
        timestampNs = (int64_t)llround(seconds * NSEC_PER_SEC);
        if (timestampNs <= _lastTimestampNs) timestampNs = _lastTimestampNs + 1000000;
    }

    RTCCVPixelBuffer *buffer;
    if (outputWidth == sourceWidth && outputHeight == sourceHeight &&
        cropWidth == sourceWidth && cropHeight == sourceHeight && cropX == 0 && cropY == 0) {
        buffer = [[RTCCVPixelBuffer alloc] initWithPixelBuffer:pixelBuffer];
    } else {
        buffer = [[RTCCVPixelBuffer alloc] initWithPixelBuffer:pixelBuffer
                                                  adaptedWidth:outputWidth
                                                 adaptedHeight:outputHeight
                                                     cropWidth:cropWidth
                                                    cropHeight:cropHeight
                                                         cropX:cropX
                                                         cropY:cropY];
    }
    RTCVideoFrame *frame = [[RTCVideoFrame alloc] initWithBuffer:buffer
                                                       rotation:rotation
                                                    timeStampNs:timestampNs];
    [source capturer:self.capturer didCaptureVideoFrame:frame];
    self.lastSubmittedTime = now;
    _lastTimestampNs = timestampNs;
    _lastRotation = rotation;
    self.submittedFrameCount++;
    self.captureStatus = [NSString stringWithFormat:@"%dx%d · %@ · %@ · %@%ldfps",
                          outputWidth, outputHeight, [self fourCCString:pixelFormat],
                          self.useMaximumResolution ? @"最大" : @"自定义",
                          moving ? @"动态 " : @"静态 ", (long)desiredFPS];

    if (!retransmission) {
        if (_lastSampleBuffer) CFRelease(_lastSampleBuffer);
        _lastSampleBuffer = (CMSampleBufferRef)CFRetain(sampleBuffer);
    }
}

- (BOOL)pixelBufferHasMotion:(CVPixelBufferRef)pixelBuffer atTime:(CFTimeInterval)now {
    if (CVPixelBufferLockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess)
        return YES;

    uint8_t samples[kMotionGridSize] = {0};
    BOOL sampled = NO;
    if (CVPixelBufferIsPlanar(pixelBuffer) && CVPixelBufferGetPlaneCount(pixelBuffer) > 0) {
        uint8_t *base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0);
        size_t width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0);
        size_t height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0);
        size_t stride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0);
        if (base && width && height) {
            for (int y = 0; y < kMotionGridHeight; y++) {
                size_t py = MIN(height - 1, ((size_t)y * height + height / 2) / kMotionGridHeight);
                for (int x = 0; x < kMotionGridWidth; x++) {
                    size_t px = MIN(width - 1, ((size_t)x * width + width / 2) / kMotionGridWidth);
                    samples[y * kMotionGridWidth + x] = base[py * stride + px];
                }
            }
            sampled = YES;
        }
    } else if (CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA) {
        uint8_t *base = CVPixelBufferGetBaseAddress(pixelBuffer);
        size_t width = CVPixelBufferGetWidth(pixelBuffer);
        size_t height = CVPixelBufferGetHeight(pixelBuffer);
        size_t stride = CVPixelBufferGetBytesPerRow(pixelBuffer);
        if (base && width && height) {
            for (int y = 0; y < kMotionGridHeight; y++) {
                size_t py = MIN(height - 1, ((size_t)y * height + height / 2) / kMotionGridHeight);
                for (int x = 0; x < kMotionGridWidth; x++) {
                    size_t px = MIN(width - 1, ((size_t)x * width + width / 2) / kMotionGridWidth);
                    uint8_t *pixel = base + py * stride + px * 4;
                    samples[y * kMotionGridWidth + x] = pixel[1]; // 绿色近似亮度，成本最低。
                }
            }
            sampled = YES;
        }
    }
    CVPixelBufferUnlockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
    if (!sampled) return YES;

    NSUInteger difference = 0;
    if (_hasLumaHistory) {
        for (int index = 0; index < kMotionGridSize; index++)
            difference += (NSUInteger)abs((int)samples[index] - (int)_lumaHistory[index]);
    }
    memcpy(_lumaHistory, samples, sizeof(samples));
    BOOL changed = !_hasLumaHistory || ((double)difference / kMotionGridSize) >= 2.5;
    _hasLumaHistory = YES;
    if (changed) _motionUntilTime = now + 1.0;
    return now < _motionUntilTime;
}

- (void)processAppAudioSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    if (!sampleBuffer || self.stopping || ![self audioSessionSnapshot].count) return;

    // ReplayKit 的视频和音频回调不能在这里做 AVAudioConverter / DataChannel 发送。
    // 只保留最新一块音频，立刻返回，避免系统音频把视频/触控链路拖死。
    CMSampleBufferRef retained = (CMSampleBufferRef)CFRetain(sampleBuffer);
    BOOL scheduleWorker = NO;
    @synchronized (self) {
        if (self.stopping) {
            CFRelease(retained);
            return;
        }
        if (_pendingAudioSampleBuffer) {
            CFRelease(_pendingAudioSampleBuffer);
            _pendingAudioSampleBuffer = NULL;
            self.audioDroppedCount++;
        }
        _pendingAudioSampleBuffer = retained;
        if (!_audioWorkerScheduled) {
            _audioWorkerScheduled = YES;
            scheduleWorker = YES;
        }
    }
    if (scheduleWorker) {
        __weak typeof(self) weakSelf = self;
        dispatch_async(self.audioQueue, ^{ [weakSelf drainPendingAudioSamples]; });
    }
}

- (void)drainPendingAudioSamples {
    while (!self.stopping) {
        CMSampleBufferRef sampleBuffer = NULL;
        @synchronized (self) {
            sampleBuffer = _pendingAudioSampleBuffer;
            _pendingAudioSampleBuffer = NULL;
            if (!sampleBuffer) {
                _audioWorkerScheduled = NO;
                return;
            }
        }
        [self.audioStreamer processSampleBuffer:sampleBuffer];
        CFRelease(sampleBuffer);
    }

    @synchronized (self) {
        if (_pendingAudioSampleBuffer) {
            CFRelease(_pendingAudioSampleBuffer);
            _pendingAudioSampleBuffer = NULL;
        }
        _audioWorkerScheduled = NO;
    }
}

- (void)sendAudioPCM:(NSData *)pcm sampleRate:(uint32_t)sampleRate
             channels:(uint16_t)channels timestamp:(uint64_t)timestamp {
    NSArray<LTViewerSession *> *targets = [self audioSessionSnapshot];
    if (!targets.count || !pcm.length) return;
    NSUInteger bytesPerFrame = MAX(1, channels) * sizeof(int16_t);
    NSUInteger totalFrames = pcm.length / bytesPerFrame;
    if (!totalFrames || !sampleRate) return;

    // ReplayKit 在旧系统可能一次交付约半秒音频；只保留最新 100ms，防止延迟累积。
    NSUInteger keepFrames = MAX(1U, sampleRate / 10);
    NSUInteger firstFrame = totalFrames > keepFrames ? totalFrames - keepFrames : 0;
    if (firstFrame) {
        self.audioDroppedCount++;
        if (timestamp) timestamp += (uint64_t)llround(firstFrame * 1000000.0 / sampleRate);
    }

    NSUInteger maximumPacketFrames = MAX(1U, sampleRate / 50); // 约 20ms，降低 DataChannel 单包占用。
    for (NSUInteger frameOffset = firstFrame; frameOffset < totalFrames;
         frameOffset += maximumPacketFrames) {
        NSUInteger frames = MIN(maximumPacketFrames, totalFrames - frameOffset);
        NSUInteger byteOffset = frameOffset * bytesPerFrame;
        NSUInteger byteCount = frames * bytesPerFrame;
        NSMutableData *packet = [NSMutableData dataWithLength:32];
        uint8_t *header = packet.mutableBytes;
        memcpy(header, "LTAU", 4);
        header[4] = 1;
        header[5] = (uint8_t)channels;
        header[6] = 16;
        uint32_t littleRate = CFSwapInt32HostToLittle(sampleRate);
        uint32_t littleSequence = CFSwapInt32HostToLittle(++_audioSequence);
        uint64_t chunkTimestamp = timestamp ? timestamp +
            (uint64_t)llround((frameOffset - firstFrame) * 1000000.0 / sampleRate) : 0;
        uint64_t littleTimestamp = CFSwapInt64HostToLittle(chunkTimestamp);
        uint32_t littleFrames = CFSwapInt32HostToLittle((uint32_t)frames);
        uint32_t littleLength = CFSwapInt32HostToLittle((uint32_t)byteCount);
        memcpy(header + 8, &littleRate, sizeof(littleRate));
        memcpy(header + 12, &littleSequence, sizeof(littleSequence));
        memcpy(header + 16, &littleTimestamp, sizeof(littleTimestamp));
        memcpy(header + 24, &littleFrames, sizeof(littleFrames));
        memcpy(header + 28, &littleLength, sizeof(littleLength));
        [packet appendBytes:(const uint8_t *)pcm.bytes + byteOffset length:byteCount];

        RTCDataBuffer *buffer = [[RTCDataBuffer alloc] initWithData:packet isBinary:YES];
        BOOL sentToAnyViewer = NO;
        for (LTViewerSession *session in targets) {
            RTCDataChannel *channel = session.audioChannel;
            if (!session.audioEnabled || channel.readyState != RTCDataChannelStateOpen) continue;
            if (channel.bufferedAmount >= 8192) { // 最多只留很短的音频队列，优先保证触控通道。
                self.audioDroppedCount++;
                continue;
            }
            if ([channel sendData:buffer]) {
                sentToAnyViewer = YES;
                self.audioPacketCount++;
            } else {
                self.audioDroppedCount++;
            }
        }
        if (sentToAnyViewer) {
            self.audioStatus = [NSString stringWithFormat:@"设备内部声音正在发送 · %lu 个观看端",
                                (unsigned long)targets.count];
            if (self.audioPacketCount == 1 || self.audioPacketCount % 100 == 0)
                NSLog(@"[Audio] sampleRate=%u channels=%u packets=%lu dropped=%lu viewers=%lu",
                      sampleRate, channels, (unsigned long)self.audioPacketCount,
                      (unsigned long)self.audioDroppedCount, (unsigned long)targets.count);
        }
    }
}

- (void)handleControlMessage:(NSDictionary *)message session:(LTViewerSession *)session {
    NSString *type = message[@"type"];
    if ([type isEqualToString:@"control"]) {
        session.controlEnabled = [message[@"enabled"] boolValue];
        if (!session.controlEnabled && self.touchOwner == session) [self cancelTouchForSession:session];
        self.controlStatus = session.controlEnabled ? @"远程控制已启用" : @"该观看端已关闭控制";
        NSLog(@"[Input] viewer=%lu control=%@", (unsigned long)session.identifier,
              session.controlEnabled ? @"YES" : @"NO");
        return;
    }
    if ([type isEqualToString:@"audio"]) {
        session.audioEnabled = [message[@"enabled"] boolValue];
        if (![self audioSessionSnapshot].count) [self.audioStreamer reset];
        self.audioStatus = session.audioEnabled ? @"声音已启用，等待设备音频" : @"该观看端已关闭声音";
        return;
    }
    if (![type isEqualToString:@"touch"] || !session.controlEnabled) return;
    NSString *phase = message[@"phase"];
    if (![@[@"down", @"move", @"up", @"cancel"] containsObject:phase]) return;
    double x = [message[@"x"] doubleValue];
    double y = [message[@"y"] doubleValue];
    NSUInteger sequence = [message[@"seq"] unsignedIntegerValue];
    if (!isfinite(x) || !isfinite(y) || x < 0 || x > 1 || y < 0 || y > 1 ||
        !sequence || sequence <= session.lastTouchSequence) return;

    @synchronized (self) {
        if ([phase isEqualToString:@"down"]) {
            if (self.touchOwner && self.touchOwner != session) {
                self.controlStatus = @"另一个观看端正在控制";
                return;
            }
            self.touchOwner = session;
        } else if (self.touchOwner != session) {
            return;
        }
    }
    session.lastTouchSequence = sequence;
    session.lastControlPointerID = [message[@"pointerId"] integerValue];

    NSMutableDictionary *forward = [message mutableCopy];
    forward[@"captureWidth"] = @(self.captureWidth);
    forward[@"captureHeight"] = @(self.captureHeight);
    forward[@"cropWidth"] = @(self.cropWidth ?: self.captureWidth);
    forward[@"cropHeight"] = @(self.cropHeight ?: self.captureHeight);
    forward[@"cropX"] = @(self.cropX);
    forward[@"cropY"] = @(self.cropY);
    forward[@"rotation"] = @(self.rotationDegrees);
    forward[@"orientation"] = self.orientationName ?: @"portrait";
    BOOL sent = [self.touchIPC sendTouchEvent:forward];
    self.controlStatus = sent ?
        [NSString stringWithFormat:@"触摸已转发 #%lu", (unsigned long)sequence] :
        @"主 App 控制服务未运行";
    if (![phase isEqualToString:@"move"])
        NSLog(@"[Input] phase=%@ normalized=(%.6f,%.6f) orientation=%@",
              phase, x, y, self.orientationName);
    if ([phase isEqualToString:@"up"] || [phase isEqualToString:@"cancel"]) {
        @synchronized (self) {
            if (self.touchOwner == session) self.touchOwner = nil;
        }
    }
}

- (void)cancelTouchForSession:(LTViewerSession *)session {
    if (!session) return;
    NSDictionary *cancel = @{
        @"type": @"touch", @"phase": @"cancel",
        @"pointerId": @(session.lastControlPointerID), @"x": @0, @"y": @0,
        @"seq": @(MAX(session.lastTouchSequence + 1, 1U)),
        @"captureWidth": @(self.captureWidth), @"captureHeight": @(self.captureHeight),
        @"cropWidth": @(self.cropWidth ?: self.captureWidth),
        @"cropHeight": @(self.cropHeight ?: self.captureHeight),
        @"cropX": @(self.cropX), @"cropY": @(self.cropY),
        @"rotation": @(self.rotationDegrees), @"orientation": self.orientationName ?: @"portrait"
    };
    session.lastTouchSequence = [cancel[@"seq"] unsignedIntegerValue];
    [self.touchIPC sendTouchEvent:cancel];
    @synchronized (self) {
        if (self.touchOwner == session) self.touchOwner = nil;
    }
}

- (void)startKeepaliveTimer {
    if (self.keepaliveTimer) return;
    self.keepaliveTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self.frameQueue);
    dispatch_source_set_timer(self.keepaliveTimer,
                              dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC),
                              250 * NSEC_PER_MSEC, 20 * NSEC_PER_MSEC);
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(self.keepaliveTimer, ^{
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf || strongSelf.stopping || !strongSelf->_lastSampleBuffer) return;
        if (CACurrentMediaTime() - strongSelf.lastSubmittedTime < 0.24) return;
        [strongSelf consumeVideoSampleBuffer:strongSelf->_lastSampleBuffer retransmission:YES];
    });
    dispatch_resume(self.keepaliveTimer);
}

- (NSString *)fourCCString:(OSType)value {
    char text[5] = {(char)(value >> 24), (char)(value >> 16), (char)(value >> 8), (char)value, 0};
    for (int index = 0; index < 4; index++)
        if (text[index] < 32 || text[index] > 126) text[index] = '?';
    return [NSString stringWithUTF8String:text];
}

- (RTCVideoRotation)rotationForSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    NSNumber *value = (__bridge NSNumber *)CMGetAttachment(sampleBuffer,
                                                            (__bridge CFStringRef)RPVideoSampleOrientationKey,
                                                            NULL);
    if (!value) return (RTCVideoRotation)self.rotationDegrees;
    switch (value.integerValue) {
        case kCGImagePropertyOrientationRight: return RTCVideoRotation_270;
        case kCGImagePropertyOrientationDown: return RTCVideoRotation_180;
        case kCGImagePropertyOrientationLeft: return RTCVideoRotation_90;
        default: return RTCVideoRotation_0;
    }
}

- (NSString *)orientationNameForRotation:(RTCVideoRotation)rotation {
    switch (rotation) {
        case RTCVideoRotation_90: return @"landscapeLeft";
        case RTCVideoRotation_180: return @"portraitUpsideDown";
        case RTCVideoRotation_270: return @"landscapeRight";
        default: return @"portrait";
    }
}

- (NSArray<LTViewerSession *> *)sessionSnapshot {
    @synchronized (self) { return self.sessions.copy; }
}

- (NSUInteger)sessionCount {
    @synchronized (self) { return self.sessions.count; }
}

- (LTViewerSession *)sessionForPeerConnection:(RTCPeerConnection *)peerConnection {
    @synchronized (self) {
        for (LTViewerSession *session in self.sessions)
            if (session.peerConnection == peerConnection) return session;
    }
    return nil;
}

- (LTViewerSession *)sessionForDataChannel:(RTCDataChannel *)dataChannel {
    @synchronized (self) {
        for (LTViewerSession *session in self.sessions)
            if (session.controlChannel == dataChannel || session.audioChannel == dataChannel) return session;
    }
    return nil;
}

- (NSArray<LTViewerSession *> *)audioSessionSnapshot {
    NSMutableArray<LTViewerSession *> *result = [NSMutableArray array];
    @synchronized (self) {
        for (LTViewerSession *session in self.sessions) {
            if (session.audioEnabled && session.audioChannel.readyState == RTCDataChannelStateOpen)
                [result addObject:session];
        }
    }
    return result;
}

- (void)removeSession:(LTViewerSession *)session {
    if (!session) return;

    RTCPeerConnection *peerConnection = nil;
    WebRTCAnswerCompletion pendingCompletion = nil;
    BOOL removed = NO;
    @synchronized (self) {
        if (!session.retired && [self.sessions containsObject:session]) {
            session.retired = YES;
            [self.sessions removeObject:session];
            removed = YES;
            peerConnection = session.peerConnection;
            pendingCompletion = session.pendingAnswer;
            session.pendingAnswer = nil;
        }
    }
    if (!removed) return;

    if (self.touchOwner == session) [self cancelTouchForSession:session];
    session.controlChannel.delegate = nil;
    session.audioChannel.delegate = nil;
    session.controlChannel = nil;
    session.audioChannel = nil;
    session.videoSender = nil;
    session.videoTransceiver = nil;
    session.peerConnection = nil;

    if (pendingCompletion) {
        pendingCompletion(nil, [self errorWithMessage:@"旧观看连接已被新的连接替换"]);
    }

    // Do not synchronously close an RTCPeerConnection from inside one of its own
    // delegate callbacks. libwebrtc may already be on its signaling/network thread;
    // re-entering -close there can wedge the factory, which makes later refreshes hang.
    if (peerConnection) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            [peerConnection close];
        });
    }

    if (![self audioSessionSnapshot].count) [self.audioStreamer reset];
    NSUInteger count = [self sessionCount];
    self.connectionStatus = count ? [NSString stringWithFormat:@"WebRTC 已连接 · %lu 个观看端",
                                     (unsigned long)count] : @"等待浏览器连接";
    [self updateAggregateStatistics];
    NSLog(@"[WebRTC] retired viewer session #%lu, remaining=%lu",
          (unsigned long)session.identifier, (unsigned long)count);
}

- (void)removeSessionAfterDelegateCallback:(LTViewerSession *)session {
    if (!session) return;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        [weakSelf removeSession:session];
    });
}

- (void)finishSession:(LTViewerSession *)session {
    NSString *sdp = session.peerConnection.localDescription.sdp;
    if (!sdp.length) {
        [self failSession:session error:[self errorWithMessage:@"Answer SDP 为空"]];
        return;
    }
    WebRTCAnswerCompletion completion = nil;
    @synchronized (self) {
        if (![self.sessions containsObject:session] || !session.pendingAnswer) return;
        completion = session.pendingAnswer;
        session.pendingAnswer = nil;
    }
    self.sendStatus = @"SDP 已建立，等待网络连接";
    completion(sdp, nil);
}

- (void)failSession:(LTViewerSession *)session error:(NSError *)error {
    WebRTCAnswerCompletion completion = nil;
    @synchronized (self) {
        if (![self.sessions containsObject:session] || !session.pendingAnswer) return;
        completion = session.pendingAnswer;
        session.pendingAnswer = nil;
    }
    self.connectionStatus = [NSString stringWithFormat:@"连接失败：%@", error.localizedDescription];
    self.sendStatus = self.connectionStatus;
    [self removeSession:session];
    completion(nil, error);
}

- (NSError *)errorWithMessage:(NSString *)message {
    return [NSError errorWithDomain:WebRTCStreamerErrorDomain
                               code:1
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

#pragma mark - RTCPeerConnectionDelegate

- (void)peerConnection:(RTCPeerConnection *)peerConnection didChangeSignalingState:(RTCSignalingState)stateChanged {}
- (void)peerConnection:(RTCPeerConnection *)peerConnection didAddStream:(RTCMediaStream *)stream {}
- (void)peerConnection:(RTCPeerConnection *)peerConnection didRemoveStream:(RTCMediaStream *)stream {}
- (void)peerConnectionShouldNegotiate:(RTCPeerConnection *)peerConnection {}
- (void)peerConnection:(RTCPeerConnection *)peerConnection didChangeIceConnectionState:(RTCIceConnectionState)newState {
    LTViewerSession *session = [self sessionForPeerConnection:peerConnection];
    if (!session) return;
    switch (newState) {
        case RTCIceConnectionStateConnected:
        case RTCIceConnectionStateCompleted:
            self.connectionStatus = [NSString stringWithFormat:@"WebRTC 已连接 · %lu 个观看端",
                                     (unsigned long)[self sessionCount]];
            [self applyVideoSenderParametersForSession:session];
            [self refreshStatistics];
            break;
        case RTCIceConnectionStateChecking: self.connectionStatus = @"正在检查网络路径"; break;
        case RTCIceConnectionStateFailed:
            self.connectionStatus = @"ICE 连接失败";
            [self removeSessionAfterDelegateCallback:session];
            break;
        case RTCIceConnectionStateDisconnected:
            self.connectionStatus = @"有观看端连接中断";
            break;
        case RTCIceConnectionStateClosed:
            [self removeSessionAfterDelegateCallback:session];
            break;
        default: break;
    }
}
- (void)peerConnection:(RTCPeerConnection *)peerConnection didChangeIceGatheringState:(RTCIceGatheringState)newState {
    LTViewerSession *session = [self sessionForPeerConnection:peerConnection];
    if (session && newState == RTCIceGatheringStateComplete) [self finishSession:session];
}
- (void)peerConnection:(RTCPeerConnection *)peerConnection didGenerateIceCandidate:(RTCIceCandidate *)candidate {}
- (void)peerConnection:(RTCPeerConnection *)peerConnection didRemoveIceCandidates:(NSArray<RTCIceCandidate *> *)candidates {}
- (void)peerConnection:(RTCPeerConnection *)peerConnection didOpenDataChannel:(RTCDataChannel *)dataChannel {
    LTViewerSession *session = [self sessionForPeerConnection:peerConnection];
    if (!session) return;
    dataChannel.delegate = self;
    if ([dataChannel.label isEqualToString:@"control"]) {
        session.controlChannel = dataChannel;
        self.controlStatus = @"控制通道已连接（默认开启）";
    } else if ([dataChannel.label isEqualToString:@"audio"]) {
        session.audioChannel = dataChannel;
        session.audioEnabled = YES;
        self.audioStatus = @"声音通道已连接，等待设备音频";
    }
}

#pragma mark - RTCDataChannelDelegate

- (void)dataChannelDidChangeState:(RTCDataChannel *)dataChannel {
    LTViewerSession *session = [self sessionForDataChannel:dataChannel];
    if (!session) return;
    if (dataChannel == session.controlChannel) {
        if (dataChannel.readyState == RTCDataChannelStateOpen) {
            self.controlStatus = @"控制通道已连接（默认开启）";
        } else if (dataChannel.readyState == RTCDataChannelStateClosed) {
            if (self.touchOwner == session) [self cancelTouchForSession:session];
            session.controlEnabled = NO;
            self.controlStatus = @"控制通道已关闭";
            [self removeSessionAfterDelegateCallback:session];
        }
    } else if (dataChannel == session.audioChannel) {
        if (dataChannel.readyState == RTCDataChannelStateOpen) {
            session.audioEnabled = YES;
            self.audioStatus = @"声音通道已连接，等待设备音频";
        } else if (dataChannel.readyState == RTCDataChannelStateClosed) {
            session.audioEnabled = NO;
            if (![self audioSessionSnapshot].count) [self.audioStreamer reset];
            self.audioStatus = @"声音通道已关闭";
        }
    }
}

- (void)dataChannel:(RTCDataChannel *)dataChannel
    didReceiveMessageWithBuffer:(RTCDataBuffer *)buffer {
    LTViewerSession *session = [self sessionForDataChannel:dataChannel];
    if (!session || dataChannel != session.controlChannel || buffer.isBinary || !buffer.data.length) return;
    NSDictionary *message = [NSJSONSerialization JSONObjectWithData:buffer.data options:0 error:nil];
    if ([message isKindOfClass:NSDictionary.class]) [self handleControlMessage:message session:session];
}

@end
