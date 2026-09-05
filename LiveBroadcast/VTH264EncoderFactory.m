#import "VTH264EncoderFactory.h"
#import <dispatch/dispatch.h>
#import <QuartzCore/QuartzCore.h>
#import <VideoToolbox/VideoToolbox.h>
#import <WebRTC/WebRTC.h>

static const uint8_t kAnnexBStartCode[4] = {0, 0, 0, 1};

@interface VTH264FrameContext : NSObject
@property (nonatomic) uint32_t timestamp;
@property (nonatomic) int64_t captureTimeMs;
@property (nonatomic) int64_t encodeStartMs;
@property (nonatomic) RTCVideoRotation rotation;
@end
@implementation VTH264FrameContext
@end

@class VTH264Encoder;

@interface VTH264EncoderFactory ()
@property (atomic, readwrite, copy) NSString *status;
@property (atomic, readwrite) NSUInteger outputFrameCount;
- (void)reportStatus:(NSString *)status;
- (void)reportOutputFrame;
@end

@interface VTH264Encoder : NSObject <RTCVideoEncoder>
- (instancetype)initWithCodecInfo:(RTCVideoCodecInfo *)codecInfo
                          observer:(VTH264EncoderFactory *)observer;
- (void)handleSampleBuffer:(CMSampleBufferRef)sampleBuffer
                    status:(OSStatus)status
                     flags:(VTEncodeInfoFlags)flags
                   context:(VTH264FrameContext *)context;
@end

static void VTH264OutputCallback(void *outputCallbackRefCon,
                                 void *sourceFrameRefCon,
                                 OSStatus status,
                                 VTEncodeInfoFlags infoFlags,
                                 CMSampleBufferRef sampleBuffer) {
    VTH264Encoder *encoder = (__bridge VTH264Encoder *)outputCallbackRefCon;
    VTH264FrameContext *context = (__bridge_transfer VTH264FrameContext *)sourceFrameRefCon;
    [encoder handleSampleBuffer:sampleBuffer status:status flags:infoFlags context:context];
}

@implementation VTH264EncoderFactory

- (instancetype)init {
    if ((self = [super init])) _status = @"等待 VideoToolbox";
    return self;
}

- (NSArray<RTCVideoCodecInfo *> *)supportedCodecs {
    RTCVideoCodecInfo *h264 = [[RTCVideoCodecInfo alloc] initWithName:@"H264" parameters:@{
        @"profile-level-id": @"42e01f",
        @"level-asymmetry-allowed": @"1",
        @"packetization-mode": @"1"
    }];
    RTCVideoCodecInfo *vp8 = [[RTCVideoCodecInfo alloc] initWithName:@"VP8"];
    return @[h264, vp8];
}

- (id<RTCVideoEncoder>)createEncoder:(RTCVideoCodecInfo *)info {
    if ([info.name caseInsensitiveCompare:@"H264"] == NSOrderedSame) {
        [self resetDiagnostics];
        self.status = @"正在创建 VideoToolbox 编码器";
        return [[VTH264Encoder alloc] initWithCodecInfo:info observer:self];
    }
    if ([info.name caseInsensitiveCompare:@"VP8"] == NSOrderedSame) {
        self.status = @"VP8 使用 WebRTC 软件编码";
        return [RTCVideoEncoderVP8 vp8Encoder];
    }
    self.status = [NSString stringWithFormat:@"不支持的编码 %@", info.name];
    return nil;
}

- (void)resetDiagnostics {
    self.outputFrameCount = 0;
    self.status = @"等待 VideoToolbox";
}

- (void)reportStatus:(NSString *)status { self.status = status; }
- (void)reportOutputFrame { self.outputFrameCount++; }

@end

@implementation VTH264Encoder {
    __weak VTH264EncoderFactory *_observer;
    RTCVideoEncoderCallback _callback;
    VTCompressionSessionRef _session;
    int32_t _width;
    int32_t _height;
    uint32_t _bitrateBps;
    uint32_t _framerate;
    RTCVideoCodecMode _mode;
    OSType _inputPixelFormat;
    NSMutableData *_scaleScratch;
}

- (instancetype)initWithCodecInfo:(RTCVideoCodecInfo *)codecInfo
                          observer:(VTH264EncoderFactory *)observer {
    if ((self = [super init])) {
        (void)codecInfo;
        _observer = observer;
    }
    return self;
}

- (void)dealloc { [self destroyCompressionSession]; }

- (void)setCallback:(RTCVideoEncoderCallback)callback {
    @synchronized (self) { _callback = [callback copy]; }
}

- (NSInteger)startEncodeWithSettings:(RTCVideoEncoderSettings *)settings
                       numberOfCores:(int)numberOfCores {
    (void)numberOfCores;
    [self destroyCompressionSession];
    _width = settings.width;
    _height = settings.height;
    _bitrateBps = MAX(300000U, settings.startBitrate * 1000U);
    _framerate = MAX(1U, settings.maxFramerate);
    _mode = settings.mode;
    [_observer reportStatus:[NSString stringWithFormat:@"VideoToolbox 等待首帧 %dx%d",
                             _width, _height]];
    return (_width > 0 && _height > 0) ? 0 : -1;
}

- (NSInteger)releaseEncoder {
    [self destroyCompressionSession];
    return 0;
}

- (NSInteger)encode:(RTCVideoFrame *)frame
    codecSpecificInfo:(id<RTCCodecSpecificInfo>)info
           frameTypes:(NSArray<NSNumber *> *)frameTypes {
    (void)info;
    if (![frame.buffer isKindOfClass:RTCCVPixelBuffer.class]) {
        [_observer reportStatus:@"VideoToolbox 收到非 CVPixelBuffer 帧"];
        return -1;
    }

    RTCCVPixelBuffer *rtcBuffer = (RTCCVPixelBuffer *)frame.buffer;
    CVPixelBufferRef inputBuffer = rtcBuffer.pixelBuffer;
    OSType pixelFormat = CVPixelBufferGetPixelFormatType(inputBuffer);
    if (![self ensureCompressionSessionForPixelFormat:pixelFormat]) return -1;

    CVPixelBufferRef encodeBuffer = inputBuffer;
    CVPixelBufferRef scaledBuffer = NULL;
    if ([rtcBuffer requiresCropping] ||
        [rtcBuffer requiresScalingToWidth:_width height:_height]) {
        CVPixelBufferPoolRef pool = VTCompressionSessionGetPixelBufferPool(_session);
        CVReturn result = pool ? CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault,
                                                                     pool, &scaledBuffer)
                               : kCVReturnInvalidPixelBufferAttributes;
        if (result != kCVReturnSuccess || !scaledBuffer) {
            [_observer reportStatus:[NSString stringWithFormat:@"VideoToolbox 缩放缓冲区失败 %d", result]];
            return -1;
        }
        int temporarySize = [rtcBuffer bufferSizeForCroppingAndScalingToWidth:_width height:_height];
        if (temporarySize > (int)_scaleScratch.length)
            _scaleScratch = [NSMutableData dataWithLength:temporarySize];
        if (![rtcBuffer cropAndScaleTo:scaledBuffer withTempBuffer:_scaleScratch.mutableBytes]) {
            CVPixelBufferRelease(scaledBuffer);
            [_observer reportStatus:@"VideoToolbox 画面缩放失败"];
            return -1;
        }
        encodeBuffer = scaledBuffer;
    }

    BOOL forceKeyFrame = [frameTypes containsObject:@(RTCFrameTypeVideoFrameKey)];
    NSDictionary *frameProperties = forceKeyFrame ?
        @{(__bridge NSString *)kVTEncodeFrameOptionKey_ForceKeyFrame: @YES} : nil;
    VTH264FrameContext *context = [VTH264FrameContext new];
    context.timestamp = (uint32_t)frame.timeStamp;
    context.captureTimeMs = frame.timeStampNs / NSEC_PER_MSEC;
    context.encodeStartMs = (int64_t)(CACurrentMediaTime() * 1000.0);
    context.rotation = frame.rotation;

    VTEncodeInfoFlags flags = 0;
    void *contextReference = (__bridge_retained void *)context;
    OSStatus status = VTCompressionSessionEncodeFrame(
        _session, encodeBuffer, CMTimeMake(frame.timeStampNs, NSEC_PER_SEC),
        CMTimeMake(1, (int32_t)_framerate), (__bridge CFDictionaryRef)frameProperties,
        contextReference, &flags);
    if (scaledBuffer) CVPixelBufferRelease(scaledBuffer);
    if (status != noErr) {
        VTH264FrameContext *releasedContext = (__bridge_transfer VTH264FrameContext *)contextReference;
        (void)releasedContext;
        [_observer reportStatus:[NSString stringWithFormat:@"VideoToolbox 提交失败 %d", (int)status]];
        [self destroyCompressionSession];
        return -1;
    }
    return 0;
}

- (int)setBitrate:(uint32_t)bitrateKbit framerate:(uint32_t)framerate {
    _bitrateBps = MAX(300000U, bitrateKbit * 1000U);
    _framerate = MAX(1U, framerate);
    if (_session) [self applyRateProperties];
    return 0;
}

- (NSString *)implementationName { return @"com.layii.live.VideoToolbox.H264"; }
- (RTCVideoEncoderQpThresholds *)scalingSettings { return nil; }

- (BOOL)ensureCompressionSessionForPixelFormat:(OSType)pixelFormat {
    if (_session && _inputPixelFormat == pixelFormat) return YES;
    [self destroyCompressionSession];

    NSDictionary *encoderSpecification = @{
        (__bridge NSString *)kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: @YES
    };
    NSDictionary *sourceAttributes = @{
        (__bridge NSString *)kCVPixelBufferPixelFormatTypeKey: @(pixelFormat),
        (__bridge NSString *)kCVPixelBufferWidthKey: @(_width),
        (__bridge NSString *)kCVPixelBufferHeightKey: @(_height),
        (__bridge NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{}
    };
    OSStatus status = VTCompressionSessionCreate(
        kCFAllocatorDefault, _width, _height, kCMVideoCodecType_H264,
        (__bridge CFDictionaryRef)encoderSpecification,
        (__bridge CFDictionaryRef)sourceAttributes, NULL,
        VTH264OutputCallback, (__bridge void *)self, &_session);
    if (status != noErr || !_session) {
        [_observer reportStatus:[NSString stringWithFormat:@"VideoToolbox 硬编创建失败 %d", (int)status]];
        _session = NULL;
        return NO;
    }

    _inputPixelFormat = pixelFormat;
    VTSessionSetProperty(_session, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue);
    VTSessionSetProperty(_session, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse);
    VTSessionSetProperty(_session, kVTCompressionPropertyKey_ProfileLevel,
                         kVTProfileLevel_H264_ConstrainedBaseline_AutoLevel);
    NSNumber *zero = @0;
    VTSessionSetProperty(_session, kVTCompressionPropertyKey_MaxFrameDelayCount,
                         (__bridge CFNumberRef)zero);
    [self applyRateProperties];
    status = VTCompressionSessionPrepareToEncodeFrames(_session);
    if (status != noErr) {
        [_observer reportStatus:[NSString stringWithFormat:@"VideoToolbox 准备失败 %d", (int)status]];
        [self destroyCompressionSession];
        return NO;
    }
    [_observer reportStatus:[NSString stringWithFormat:@"VideoToolbox 硬编已启动 %dx%d",
                             _width, _height]];
    return YES;
}

- (void)applyRateProperties {
    if (!_session) return;
    NSNumber *bitrate = @(_bitrateBps);
    NSNumber *framerate = @(_framerate);
    NSNumber *keyFrameInterval = @(MAX(1U, _framerate * 2U));
    NSNumber *keyFrameSeconds = @2;
    NSArray *dataRateLimits = @[@(MAX(1U, (_bitrateBps * 3U) / 16U)), @1];
    VTSessionSetProperty(_session, kVTCompressionPropertyKey_AverageBitRate,
                         (__bridge CFNumberRef)bitrate);
    VTSessionSetProperty(_session, kVTCompressionPropertyKey_DataRateLimits,
                         (__bridge CFArrayRef)dataRateLimits);
    VTSessionSetProperty(_session, kVTCompressionPropertyKey_ExpectedFrameRate,
                         (__bridge CFNumberRef)framerate);
    VTSessionSetProperty(_session, kVTCompressionPropertyKey_MaxKeyFrameInterval,
                         (__bridge CFNumberRef)keyFrameInterval);
    VTSessionSetProperty(_session, kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration,
                         (__bridge CFNumberRef)keyFrameSeconds);
}

- (void)destroyCompressionSession {
    if (!_session) return;
    VTCompressionSessionCompleteFrames(_session, kCMTimeInvalid);
    VTCompressionSessionInvalidate(_session);
    CFRelease(_session);
    _session = NULL;
    _inputPixelFormat = 0;
}

- (void)handleSampleBuffer:(CMSampleBufferRef)sampleBuffer
                    status:(OSStatus)status
                     flags:(VTEncodeInfoFlags)flags
                   context:(VTH264FrameContext *)context {
    if (status != noErr || !sampleBuffer || (flags & kVTEncodeInfo_FrameDropped) ||
        !CMSampleBufferDataIsReady(sampleBuffer)) {
        [_observer reportStatus:[NSString stringWithFormat:@"VideoToolbox 输出失败 %d", (int)status]];
        return;
    }

    BOOL keyFrame = [self sampleBufferIsKeyFrame:sampleBuffer];
    NSMutableData *annexB = [NSMutableData data];
    RTCRtpFragmentationHeader *header = [RTCRtpFragmentationHeader new];
    if (![self copySampleBuffer:sampleBuffer keyFrame:keyFrame toAnnexB:annexB header:header]) {
        [_observer reportStatus:@"VideoToolbox NAL 转换失败"];
        return;
    }

    RTCVideoEncoderCallback callback;
    @synchronized (self) { callback = [_callback copy]; }
    if (!callback) {
        [_observer reportStatus:@"WebRTC 没有设置编码回调"];
        return;
    }

    RTCEncodedImage *image = [RTCEncodedImage new];
    image.buffer = annexB;
    image.encodedWidth = _width;
    image.encodedHeight = _height;
    image.timeStamp = context.timestamp;
    image.captureTimeMs = context.captureTimeMs;
    image.encodeStartMs = context.encodeStartMs;
    image.encodeFinishMs = (int64_t)(CACurrentMediaTime() * 1000.0);
    image.rotation = context.rotation;
    image.completeFrame = YES;
    image.frameType = keyFrame ? RTCFrameTypeVideoFrameKey : RTCFrameTypeVideoFrameDelta;
    image.contentType = _mode == RTCVideoCodecModeScreensharing ?
        RTCVideoContentTypeScreenshare : RTCVideoContentTypeUnspecified;
    image.flags = UINT8_MAX;
    image.qp = @(-1);

    RTCCodecSpecificInfoH264 *codecInfo = [RTCCodecSpecificInfoH264 new];
    codecInfo.packetizationMode = RTCH264PacketizationModeNonInterleaved;
    if (callback(image, codecInfo, header)) {
        [_observer reportOutputFrame];
        [_observer reportStatus:@"VideoToolbox 正在硬件编码"];
    } else {
        [_observer reportStatus:@"WebRTC 拒绝 VideoToolbox 输出"];
    }
}

- (BOOL)sampleBufferIsKeyFrame:(CMSampleBufferRef)sampleBuffer {
    CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, false);
    if (!attachments || CFArrayGetCount(attachments) == 0) return YES;
    CFDictionaryRef values = CFArrayGetValueAtIndex(attachments, 0);
    CFBooleanRef notSync = CFDictionaryGetValue(values, kCMSampleAttachmentKey_NotSync);
    return !notSync || !CFBooleanGetValue(notSync);
}

- (BOOL)copySampleBuffer:(CMSampleBufferRef)sampleBuffer
                keyFrame:(BOOL)keyFrame
                toAnnexB:(NSMutableData *)annexB
                  header:(RTCRtpFragmentationHeader *)header {
    CMVideoFormatDescriptionRef format = CMSampleBufferGetFormatDescription(sampleBuffer);
    if (!format) return NO;

    size_t parameterSetCount = 0;
    int nalHeaderLength = 0;
    OSStatus status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
        format, 0, NULL, NULL, &parameterSetCount, &nalHeaderLength);
    if (status != noErr || nalHeaderLength < 1 || nalHeaderLength > 4) return NO;

    NSMutableArray<NSNumber *> *offsets = [NSMutableArray array];
    NSMutableArray<NSNumber *> *lengths = [NSMutableArray array];
    if (keyFrame) {
        for (size_t index = 0; index < parameterSetCount; index++) {
            const uint8_t *bytes = NULL;
            size_t length = 0;
            status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format, index, &bytes, &length, NULL, NULL);
            if (status != noErr || !bytes || !length) return NO;
            [annexB appendBytes:kAnnexBStartCode length:sizeof(kAnnexBStartCode)];
            [offsets addObject:@(annexB.length)];
            [lengths addObject:@(length)];
            [annexB appendBytes:bytes length:length];
        }
    }

    CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sampleBuffer);
    if (!block) return NO;
    size_t dataLength = CMBlockBufferGetDataLength(block);
    char *directBytes = NULL;
    size_t lengthAtOffset = 0;
    size_t totalLength = 0;
    status = CMBlockBufferGetDataPointer(block, 0, &lengthAtOffset, &totalLength, &directBytes);
    NSMutableData *contiguousCopy = nil;
    if (status != kCMBlockBufferNoErr || lengthAtOffset != dataLength || totalLength != dataLength) {
        contiguousCopy = [NSMutableData dataWithLength:dataLength];
        status = CMBlockBufferCopyDataBytes(block, 0, dataLength, contiguousCopy.mutableBytes);
        if (status != kCMBlockBufferNoErr) return NO;
        directBytes = contiguousCopy.mutableBytes;
    }

    const uint8_t *bytes = (const uint8_t *)directBytes;
    size_t cursor = 0;
    while (cursor + nalHeaderLength <= dataLength) {
        uint32_t nalLength = 0;
        for (int index = 0; index < nalHeaderLength; index++)
            nalLength = (nalLength << 8) | bytes[cursor + index];
        cursor += nalHeaderLength;
        if (!nalLength || cursor + nalLength > dataLength) return NO;
        [annexB appendBytes:kAnnexBStartCode length:sizeof(kAnnexBStartCode)];
        [offsets addObject:@(annexB.length)];
        [lengths addObject:@(nalLength)];
        [annexB appendBytes:bytes + cursor length:nalLength];
        cursor += nalLength;
    }
    if (cursor != dataLength || !offsets.count) return NO;

    NSMutableArray<NSNumber *> *zeros = [NSMutableArray arrayWithCapacity:offsets.count];
    for (NSUInteger index = 0; index < offsets.count; index++) [zeros addObject:@0];
    header.fragmentationOffset = offsets;
    header.fragmentationLength = lengths;
    header.fragmentationTimeDiff = zeros;
    header.fragmentationPlType = zeros;
    return YES;
}

@end
