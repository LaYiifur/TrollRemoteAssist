#import "MJPEGServer.h"
#import "WebRTCStreamer.h"
#import <Network/Network.h>
#import <ifaddrs.h>
#import <arpa/inet.h>
#import <string.h>

static NSString * const SettingsSuite = @"group.com.layii.live";
static NSString * const PreferredCodecKey = @"stream.preferredCodec";
static NSString * const DeviceNameKey = @"network.deviceName";
static NSString * const PortKey = @"network.port";

@interface LTAudioHTTPClient : NSObject
@property (nonatomic, strong) nw_connection_t connection;
@property (nonatomic, strong) NSData *pendingPacket;
@property (nonatomic) BOOL headerReady;
@property (nonatomic) BOOL sending;
@end
@implementation LTAudioHTTPClient
@end

@interface MJPEGServer ()
@property (nonatomic, strong) dispatch_queue_t queue;
@property (nonatomic, strong) nw_listener_t listener;
@property (nonatomic, strong) NSMutableArray *connections;
@property (nonatomic, strong) NSMutableArray<LTAudioHTTPClient *> *audioClients;
@property (nonatomic, strong) WebRTCStreamer *streamer;
@property (nonatomic, strong) NSUserDefaults *sharedDefaults;
@property (atomic, readwrite) BOOL hasAudioClients;
@property (atomic) BOOL stopping;
@end

@implementation MJPEGServer {
    uint32_t _audioSequence;
    NSUInteger _audioDroppedPackets;
}

- (instancetype)initWithWebRTCStreamer:(WebRTCStreamer *)streamer {
    if ((self = [super init])) {
        _queue = dispatch_queue_create("com.layii.live.http", DISPATCH_QUEUE_SERIAL);
        _connections = [NSMutableArray array];
        _audioClients = [NSMutableArray array];
        _streamer = streamer;
        _sharedDefaults = [[NSUserDefaults alloc] initWithSuiteName:SettingsSuite];
        [_sharedDefaults registerDefaults:@{
            PreferredCodecKey: @"H264",
            DeviceNameKey: @"iPhone",
            PortKey: @8080
        }];
    }
    return self;
}

- (void)start {
    if (self.listener) return;
    self.stopping = NO;
    self.hasAudioClients = NO;
    _audioSequence = 0;
    _audioDroppedPackets = 0;

    nw_parameters_t parameters = nw_parameters_create_secure_tcp(NW_PARAMETERS_DISABLE_PROTOCOL,
                                                                   NW_PARAMETERS_DEFAULT_CONFIGURATION);
    [self.sharedDefaults synchronize];
    NSInteger configuredPort = [self.sharedDefaults integerForKey:PortKey];
    if (configuredPort < 1 || configuredPort > 65535) configuredPort = 8080;
    NSString *portString = [NSString stringWithFormat:@"%ld", (long)configuredPort];
    self.listener = nw_listener_create_with_port(portString.UTF8String, parameters);
    if (!self.listener) {
        NSLog(@"[LiveBroadcast] 无法创建 HTTP 服务");
        return;
    }

    NSString *deviceName = [self.sharedDefaults stringForKey:DeviceNameKey];
    const char *bonjourName = deviceName.length ? deviceName.UTF8String : NULL;
    nw_advertise_descriptor_t descriptor =
        nw_advertise_descriptor_create_bonjour_service(bonjourName, "_http._tcp", NULL);
    if (descriptor) nw_listener_set_advertise_descriptor(self.listener, descriptor);

    nw_listener_set_queue(self.listener, self.queue);
    __weak typeof(self) weakSelf = self;
    nw_listener_set_state_changed_handler(self.listener, ^(nw_listener_state_t state, nw_error_t error) {
        if (state == nw_listener_state_ready) {
            NSLog(@"[LiveBroadcast] WebRTC 观看地址：http://%@:%@/", [weakSelf localIPAddress], portString);
            NSLog(@"[LiveBroadcast] Bonjour 服务名：%@", deviceName);
        } else if (state == nw_listener_state_failed) {
            NSLog(@"[LiveBroadcast] HTTP 服务失败：%@", error);
        }
    });
    nw_listener_set_new_connection_handler(self.listener, ^(nw_connection_t connection) {
        [weakSelf acceptConnection:connection];
    });
    nw_listener_start(self.listener);
}

- (void)stop {
    if (self.stopping) return;
    self.stopping = YES;
    self.hasAudioClients = NO;

    nw_listener_t listener = self.listener;
    self.listener = nil;
    if (listener) nw_listener_cancel(listener);

    // 不在 ReplayKit 的 broadcastFinished 回调里同步等待网络队列。
    dispatch_async(self.queue, ^{
        for (nw_connection_t connection in self.connections) nw_connection_cancel(connection);
        [self.connections removeAllObjects];
        [self.audioClients removeAllObjects];
    });
}

- (void)acceptConnection:(nw_connection_t)connection {
    if (!connection || self.stopping) {
        if (connection) nw_connection_cancel(connection);
        return;
    }
    [self.connections addObject:connection];
    nw_connection_set_queue(connection, self.queue);
    __weak typeof(self) weakSelf = self;
    nw_connection_set_state_changed_handler(connection, ^(nw_connection_state_t state, nw_error_t error) {
        (void)error;
        if (state == nw_connection_state_failed || state == nw_connection_state_cancelled) {
            [weakSelf.connections removeObject:connection];
            [weakSelf removeAudioClientForConnection:connection];
        }
    });
    nw_connection_start(connection);
    [self receiveRequest:connection buffer:[NSMutableData data]];
}

- (void)receiveRequest:(nw_connection_t)connection buffer:(NSMutableData *)buffer {
    __weak typeof(self) weakSelf = self;
    nw_connection_receive(connection, 1, 16384, ^(dispatch_data_t content, nw_content_context_t context,
                                                   bool isComplete, nw_error_t error) {
        (void)context;
        if (error || weakSelf.stopping) {
            nw_connection_cancel(connection);
            return;
        }
        const void *bytes = NULL;
        size_t length = 0;
        dispatch_data_t mapped = content ? dispatch_data_create_map(content, &bytes, &length) : nil;
        if (length) [buffer appendBytes:bytes length:length];
        (void)mapped;

        if (![weakSelf requestIsComplete:buffer] && !isComplete && buffer.length < 262144) {
            [weakSelf receiveRequest:connection buffer:buffer];
            return;
        }
        NSString *request = [[NSString alloc] initWithData:buffer encoding:NSUTF8StringEncoding] ?: @"";
        [weakSelf handleRequest:request connection:connection];
    });
}

- (BOOL)requestIsComplete:(NSData *)data {
    NSData *separator = [@"\r\n\r\n" dataUsingEncoding:NSASCIIStringEncoding];
    NSRange separatorRange = [data rangeOfData:separator options:0 range:NSMakeRange(0, data.length)];
    if (separatorRange.location == NSNotFound) return NO;

    NSUInteger bodyStart = NSMaxRange(separatorRange);
    NSString *headers = [[NSString alloc] initWithData:[data subdataWithRange:NSMakeRange(0, separatorRange.location)]
                                               encoding:NSUTF8StringEncoding];
    NSUInteger contentLength = 0;
    for (NSString *line in [headers componentsSeparatedByString:@"\r\n"]) {
        if ([line rangeOfString:@"Content-Length:" options:NSCaseInsensitiveSearch].location == 0) {
            contentLength = [[[line componentsSeparatedByString:@":"] lastObject] integerValue];
            break;
        }
    }
    return data.length >= bodyStart + contentLength;
}

- (void)handleRequest:(NSString *)request connection:(nw_connection_t)connection {
    if ([request hasPrefix:@"POST /webrtc/offer "]) {
        [self.sharedDefaults synchronize];
        NSString *savedCodec = [[self.sharedDefaults stringForKey:PreferredCodecKey] uppercaseString];
        NSString *preferredCodec = [savedCodec isEqualToString:@"VP8"] ? @"VP8" : @"H264";
        NSRange separator = [request rangeOfString:@"\r\n\r\n"];
        NSString *offer = separator.location == NSNotFound ? @"" : [request substringFromIndex:NSMaxRange(separator)];
        __weak typeof(self) weakSelf = self;
        [self.streamer createAnswerForOffer:offer preferredCodec:preferredCodec
                                  completion:^(NSString *answerSDP, NSError *error) {
            dispatch_async(weakSelf.queue, ^{
                if (error || !answerSDP.length) {
                    NSData *body = [[NSString stringWithFormat:@"WebRTC error: %@", error.localizedDescription]
                                    dataUsingEncoding:NSUTF8StringEncoding];
                    [weakSelf sendResponse:500 contentType:@"text/plain; charset=utf-8" body:body connection:connection];
                } else {
                    [weakSelf sendResponse:200 contentType:@"application/sdp"
                                      body:[answerSDP dataUsingEncoding:NSUTF8StringEncoding]
                                connection:connection];
                }
            });
        }];
        return;
    }

    if ([request hasPrefix:@"GET /audio "]) {
        [self beginAudioStreamForConnection:connection];
        return;
    }

    if ([request hasPrefix:@"GET /audio-worklet.js "]) {
        NSData *script = [self resourceDataNamed:@"audio-worklet" extension:@"js"];
        [self sendResponse:script.length ? 200 : 500
               contentType:@"application/javascript; charset=utf-8"
                      body:script ?: [@"resource missing" dataUsingEncoding:NSUTF8StringEncoding]
                connection:connection];
        return;
    }

    [self sendResponse:200 contentType:@"text/html; charset=utf-8"
                  body:[[self viewerHTML] dataUsingEncoding:NSUTF8StringEncoding] connection:connection];
}

- (void)beginAudioStreamForConnection:(nw_connection_t)connection {
    if (self.stopping) {
        nw_connection_cancel(connection);
        return;
    }

    LTAudioHTTPClient *client = [LTAudioHTTPClient new];
    client.connection = connection;
    [self.audioClients addObject:client];
    self.hasAudioClients = self.audioClients.count > 0;

    NSString *header = @"HTTP/1.1 200 OK\r\n"
                        "Content-Type: application/octet-stream\r\n"
                        "Cache-Control: no-store, no-cache\r\n"
                        "Transfer-Encoding: chunked\r\n"
                        "Connection: keep-alive\r\n\r\n";
    NSData *headerData = [header dataUsingEncoding:NSASCIIStringEncoding];
    dispatch_data_t content = dispatch_data_create(headerData.bytes, headerData.length, self.queue, ^{ (void)headerData; });
    __weak typeof(self) weakSelf = self;
    __weak LTAudioHTTPClient *weakClient = client;
    nw_connection_send(connection, content, NW_CONNECTION_DEFAULT_MESSAGE_CONTEXT, false, ^(nw_error_t error) {
        LTAudioHTTPClient *strongClient = weakClient;
        if (!strongClient) return;
        if (error || weakSelf.stopping) {
            [weakSelf removeAudioClient:strongClient];
            nw_connection_cancel(connection);
            return;
        }
        strongClient.headerReady = YES;
        [weakSelf sendPendingAudioForClient:strongClient];
        NSLog(@"[AudioHTTP] viewer connected, clients=%lu", (unsigned long)weakSelf.audioClients.count);
    });
}

- (void)publishAudioPCM:(NSData *)pcm
             sampleRate:(uint32_t)sampleRate
               channels:(uint16_t)channels
              timestamp:(uint64_t)timestampMicroseconds {
    if (!pcm.length || !sampleRate || !channels || channels > 2 || self.stopping || !self.hasAudioClients) return;
    NSUInteger bytesPerFrame = (NSUInteger)channels * sizeof(int16_t);
    if (pcm.length < bytesPerFrame || pcm.length % bytesPerFrame != 0) return;
    NSUInteger frames = pcm.length / bytesPerFrame;
    if (frames > UINT32_MAX || pcm.length > UINT32_MAX) return;

    NSMutableData *packet = [NSMutableData dataWithLength:32];
    uint8_t *header = packet.mutableBytes;
    memcpy(header, "LTAU", 4);
    header[4] = 1;
    header[5] = (uint8_t)channels;
    header[6] = 16;
    header[7] = 0;
    uint32_t littleRate = CFSwapInt32HostToLittle(sampleRate);
    uint32_t littleSequence = CFSwapInt32HostToLittle(++_audioSequence);
    uint64_t littleTimestamp = CFSwapInt64HostToLittle(timestampMicroseconds);
    uint32_t littleFrames = CFSwapInt32HostToLittle((uint32_t)frames);
    uint32_t littleLength = CFSwapInt32HostToLittle((uint32_t)pcm.length);
    memcpy(header + 8, &littleRate, sizeof(littleRate));
    memcpy(header + 12, &littleSequence, sizeof(littleSequence));
    memcpy(header + 16, &littleTimestamp, sizeof(littleTimestamp));
    memcpy(header + 24, &littleFrames, sizeof(littleFrames));
    memcpy(header + 28, &littleLength, sizeof(littleLength));
    [packet appendData:pcm];
    NSData *immutablePacket = packet.copy;

    dispatch_async(self.queue, ^{
        if (self.stopping || !self.audioClients.count) return;
        for (LTAudioHTTPClient *client in self.audioClients.copy) {
            if (client.pendingPacket) _audioDroppedPackets++;
            client.pendingPacket = immutablePacket;
            [self sendPendingAudioForClient:client];
        }
        if (_audioSequence == 1 || _audioSequence % 200 == 0) {
            NSLog(@"[AudioHTTP] packets=%u dropped=%lu clients=%lu",
                  _audioSequence, (unsigned long)_audioDroppedPackets,
                  (unsigned long)self.audioClients.count);
        }
    });
}

- (void)sendPendingAudioForClient:(LTAudioHTTPClient *)client {
    if (!client || !client.headerReady || client.sending || !client.pendingPacket || self.stopping) return;

    NSData *packet = client.pendingPacket;
    client.pendingPacket = nil;
    client.sending = YES;

    NSData *prefix = [[NSString stringWithFormat:@"%lX\r\n", (unsigned long)packet.length]
                      dataUsingEncoding:NSASCIIStringEncoding];
    static NSData *suffix;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ suffix = [@"\r\n" dataUsingEncoding:NSASCIIStringEncoding]; });
    NSMutableData *wire = [NSMutableData dataWithCapacity:prefix.length + packet.length + suffix.length];
    [wire appendData:prefix];
    [wire appendData:packet];
    [wire appendData:suffix];

    dispatch_data_t content = dispatch_data_create(wire.bytes, wire.length, self.queue, ^{ (void)wire; });
    __weak typeof(self) weakSelf = self;
    __weak LTAudioHTTPClient *weakClient = client;
    nw_connection_send(client.connection, content, NW_CONNECTION_DEFAULT_MESSAGE_CONTEXT, false, ^(nw_error_t error) {
        LTAudioHTTPClient *strongClient = weakClient;
        if (!strongClient) return;
        strongClient.sending = NO;
        if (error || weakSelf.stopping) {
            nw_connection_t connection = strongClient.connection;
            [weakSelf removeAudioClient:strongClient];
            if (connection) nw_connection_cancel(connection);
            return;
        }
        [weakSelf sendPendingAudioForClient:strongClient];
    });
}

- (void)removeAudioClientForConnection:(nw_connection_t)connection {
    for (LTAudioHTTPClient *client in self.audioClients.copy) {
        if (client.connection == connection) [self removeAudioClient:client];
    }
}

- (void)removeAudioClient:(LTAudioHTTPClient *)client {
    if (!client) return;
    client.pendingPacket = nil;
    [self.audioClients removeObject:client];
    self.hasAudioClients = self.audioClients.count > 0;
}

- (NSString *)viewerHTML {
    NSData *data = [self resourceDataNamed:@"viewer" extension:@"html"];
    NSString *html = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
    if (html.length) return html;
    return @"<!doctype html><meta name='viewport' content='width=device-width'><body style='background:#000;color:#fff'>viewer.html missing</body>";
}

- (NSData *)resourceDataNamed:(NSString *)name extension:(NSString *)extension {
    NSBundle *bundle = [NSBundle bundleForClass:self.class];
    NSString *path = [bundle pathForResource:name ofType:extension];
    return path ? [NSData dataWithContentsOfFile:path] : nil;
}

- (void)sendResponse:(NSInteger)statusCode contentType:(NSString *)contentType body:(NSData *)body
          connection:(nw_connection_t)connection {
    NSString *reason = statusCode == 200 ? @"OK" : @"Internal Server Error";
    NSString *header = [NSString stringWithFormat:
                        @"HTTP/1.1 %ld %@\r\nContent-Type: %@\r\n"
                         "Cache-Control: no-store, no-cache\r\nContent-Length: %lu\r\nConnection: close\r\n\r\n",
                        (long)statusCode, reason, contentType, (unsigned long)body.length];
    NSMutableData *response = [NSMutableData dataWithData:[header dataUsingEncoding:NSUTF8StringEncoding]];
    [response appendData:body];
    dispatch_data_t content = dispatch_data_create(response.bytes, response.length, self.queue, ^{ (void)response; });
    nw_connection_send(connection, content, NW_CONNECTION_DEFAULT_MESSAGE_CONTEXT, true, ^(nw_error_t error) {
        (void)error;
        nw_connection_cancel(connection);
    });
}

- (NSString *)localIPAddress {
    struct ifaddrs *interfaces = NULL;
    NSString *address = @"iPhone-IP";
    if (getifaddrs(&interfaces) == 0) {
        for (struct ifaddrs *item = interfaces; item; item = item->ifa_next) {
            if (!item->ifa_addr || item->ifa_addr->sa_family != AF_INET) continue;
            if (strcmp(item->ifa_name, "en0") == 0) {
                char host[INET_ADDRSTRLEN] = {0};
                struct sockaddr_in *socketAddress = (struct sockaddr_in *)item->ifa_addr;
                if (inet_ntop(AF_INET, &socketAddress->sin_addr, host, sizeof(host)))
                    address = [NSString stringWithUTF8String:host];
                break;
            }
        }
        freeifaddrs(interfaces);
    }
    return address;
}

@end
