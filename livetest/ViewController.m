#import "ViewController.h"
#import <ReplayKit/ReplayKit.h>
#import <arpa/inet.h>
#import <ifaddrs.h>
#import <net/if.h>
#import <string.h>

static NSString * const LTSettingsSuite = @"group.com.layii.live";
static NSString * const LTUseMaximumKey = @"resolution.useMaximum";
static NSString * const LTWidthKey = @"resolution.width";
static NSString * const LTHeightKey = @"resolution.height";
static NSString * const LTCodecKey = @"stream.preferredCodec";
static NSString * const LTHighQualityHighFPSKey = @"stream.highQualityHighFPS";
static NSString * const LTShareDeviceAudioKey = @"audio.shareDeviceAudio";
static NSString * const LTDeviceNameKey = @"network.deviceName";
static NSString * const LTAddressModeKey = @"network.addressMode";
static NSString * const LTNetworkModeKey = @"network.mode";
static NSString * const LTPortKey = @"network.port";
static NSString * const LTCustomServerKey = @"network.customServer";

@interface ViewController () <UITextFieldDelegate>
@property (nonatomic, strong) UITextField *widthField;
@property (nonatomic, strong) UITextField *heightField;
@property (nonatomic, strong) UISwitch *maximumSwitch;
@property (nonatomic, strong) UISegmentedControl *codecControl;
@property (nonatomic, strong) UISwitch *highQualitySwitch;
@property (nonatomic, strong) UISwitch *deviceAudioSwitch;
@property (nonatomic, strong) NSUserDefaults *streamDefaults;
@property (nonatomic, strong) RPSystemBroadcastPickerView *broadcastPicker;
@property (nonatomic, strong) UITextField *deviceNameField;
@property (nonatomic, strong) UISegmentedControl *addressControl;
@property (nonatomic, strong) UISegmentedControl *networkModeControl;
@property (nonatomic, strong) UITextField *portField;
@property (nonatomic, strong) UIStackView *lanContainer;
@property (nonatomic, strong) UIStackView *wanContainer;
@property (nonatomic, strong) UIStackView *customServerContainer;
@property (nonatomic, strong) UITextField *customServerField;
@property (nonatomic, strong) UILabel *urlLabel;
@property (nonatomic, strong) UIButton *localCopyButton;
@property (nonatomic, strong) UILabel *externalURLLabel;
@property (nonatomic, strong) UIButton *externalCopyButton;
@property (nonatomic, strong) UILabel *customServerURLLabel;
@property (nonatomic, strong) UIButton *customServerCopyButton;
@property (nonatomic, copy) NSString *ipURL;
@property (nonatomic, copy) NSString *deviceURL;
@property (nonatomic, copy) NSString *localURL;
@property (nonatomic, copy) NSString *externalURL;
@property (nonatomic, copy) NSString *customServerURL;
@property (nonatomic) NSUInteger ipRetryGeneration;
@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"直播远程控制";
    self.view.backgroundColor = UIColor.blackColor;
    UINavigationBar *navigationBar = self.navigationController.navigationBar;
    navigationBar.barStyle = UIBarStyleBlack;
    navigationBar.tintColor = UIColor.whiteColor;
    navigationBar.barTintColor = UIColor.blackColor;
    navigationBar.titleTextAttributes = @{NSForegroundColorAttributeName: UIColor.whiteColor};
    if (@available(iOS 13.0, *)) {
        UINavigationBarAppearance *appearance = [UINavigationBarAppearance new];
        [appearance configureWithOpaqueBackground];
        appearance.backgroundColor = UIColor.blackColor;
        appearance.titleTextAttributes = @{NSForegroundColorAttributeName: UIColor.whiteColor};
        navigationBar.standardAppearance = appearance;
        navigationBar.scrollEdgeAppearance = appearance;
    }
    self.streamDefaults = [[NSUserDefaults alloc] initWithSuiteName:LTSettingsSuite];
    NSString *savedDeviceName = [self.streamDefaults stringForKey:LTDeviceNameKey];
    NSString *defaultDeviceName = [self normalizedDeviceName:UIDevice.currentDevice.name];
    [self.streamDefaults registerDefaults:@{
        LTUseMaximumKey: @YES,
        LTWidthKey: @720,
        LTHeightKey: @1280,
        LTCodecKey: @"H264",
        LTHighQualityHighFPSKey: @YES,
        LTShareDeviceAudioKey: @YES,
        LTDeviceNameKey: defaultDeviceName,
        LTAddressModeKey: @0,
        LTNetworkModeKey: @0,
        LTPortKey: @8080,
        LTCustomServerKey: @""
    }];
    if (!savedDeviceName.length) {
        [self.streamDefaults setObject:defaultDeviceName forKey:LTDeviceNameKey];
        [self.streamDefaults synchronize];
    }

    UILabel *titleLabel = [self labelWithText:@"ReplayKit 远程桌面" size:22 weight:UIFontWeightBold];
    titleLabel.textAlignment = NSTextAlignmentCenter;

    UIButton *startButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [startButton setTitle:@"开启远程控制" forState:UIControlStateNormal];
    [startButton setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    startButton.titleLabel.font = [UIFont systemFontOfSize:18 weight:UIFontWeightBold];
    startButton.backgroundColor = [self accentColor];
    startButton.layer.cornerRadius = 12;
    startButton.clipsToBounds = YES;
    [startButton addTarget:self action:@selector(startRemoteControl:)
          forControlEvents:UIControlEventTouchUpInside];

    self.broadcastPicker = [RPSystemBroadcastPickerView new];
    self.broadcastPicker.translatesAutoresizingMaskIntoConstraints = NO;
    self.broadcastPicker.preferredExtension = @"com.layii.live.LiveBroadcast";
    self.broadcastPicker.showsMicrophoneButton = NO;
    self.broadcastPicker.alpha = 0.02;
    self.broadcastPicker.userInteractionEnabled = NO;
    [startButton addSubview:self.broadcastPicker];
    [NSLayoutConstraint activateConstraints:@[
        [startButton.heightAnchor constraintEqualToConstant:54],
        [self.broadcastPicker.leadingAnchor constraintEqualToAnchor:startButton.leadingAnchor],
        [self.broadcastPicker.trailingAnchor constraintEqualToAnchor:startButton.trailingAnchor],
        [self.broadcastPicker.topAnchor constraintEqualToAnchor:startButton.topAnchor],
        [self.broadcastPicker.bottomAnchor constraintEqualToAnchor:startButton.bottomAnchor]
    ]];

    UILabel *launchHint = [self labelWithText:@"点击后在系统窗口中确认“开始直播”"
                                          size:13 weight:UIFontWeightRegular];
    launchHint.textAlignment = NSTextAlignmentCenter;
    launchHint.textColor = [self secondaryTextColor];

    UILabel *deviceAudioLabel = [self labelWithText:@"共享设备音频" size:16 weight:UIFontWeightMedium];
    self.deviceAudioSwitch = [UISwitch new];
    self.deviceAudioSwitch.on = [self.streamDefaults boolForKey:LTShareDeviceAudioKey];
    self.deviceAudioSwitch.onTintColor = [self accentColor];
    [self.deviceAudioSwitch addTarget:self action:@selector(deviceAudioChanged:)
                        forControlEvents:UIControlEventValueChanged];
    UIStackView *deviceAudioRow = [[UIStackView alloc] initWithArrangedSubviews:@[
        deviceAudioLabel, self.deviceAudioSwitch
    ]];
    deviceAudioRow.axis = UILayoutConstraintAxisHorizontal;
    deviceAudioRow.alignment = UIStackViewAlignmentCenter;
    deviceAudioRow.distribution = UIStackViewDistributionEqualSpacing;
    deviceAudioRow.layoutMargins = UIEdgeInsetsMake(12, 16, 12, 16);
    deviceAudioRow.layoutMarginsRelativeArrangement = YES;
    deviceAudioRow.backgroundColor = [self cardBackgroundColor];
    deviceAudioRow.layer.cornerRadius = 12;

    UILabel *resolutionTitle = [self labelWithText:@"自定义编码分辨率" size:16 weight:UIFontWeightSemibold];
    self.widthField = [self resolutionFieldWithValue:[self.streamDefaults integerForKey:LTWidthKey]];
    self.heightField = [self resolutionFieldWithValue:[self.streamDefaults integerForKey:LTHeightKey]];
    self.widthField.accessibilityLabel = @"X 分辨率";
    self.heightField.accessibilityLabel = @"Y 分辨率";
    UILabel *xLabel = [self labelWithText:@"X" size:17 weight:UIFontWeightSemibold];
    UILabel *yLabel = [self labelWithText:@"Y" size:17 weight:UIFontWeightSemibold];
    UIStackView *resolutionRow = [[UIStackView alloc] initWithArrangedSubviews:@[
        xLabel, self.widthField, yLabel, self.heightField
    ]];
    resolutionRow.axis = UILayoutConstraintAxisHorizontal;
    resolutionRow.alignment = UIStackViewAlignmentCenter;
    resolutionRow.spacing = 8;
    [self.widthField.widthAnchor constraintEqualToConstant:100].active = YES;
    [self.heightField.widthAnchor constraintEqualToConstant:100].active = YES;
    [self.widthField.heightAnchor constraintEqualToConstant:44].active = YES;
    [self.heightField.heightAnchor constraintEqualToConstant:44].active = YES;
    
    UILabel *maximumLabel = [self labelWithText:@"使用 ReplayKit 最大分辨率" size:16 weight:UIFontWeightMedium];
    self.maximumSwitch = [UISwitch new];
    self.maximumSwitch.on = [self.streamDefaults boolForKey:LTUseMaximumKey];
    self.maximumSwitch.onTintColor = [self accentColor];
    [self.maximumSwitch addTarget:self action:@selector(maximumChanged:) forControlEvents:UIControlEventValueChanged];
    UIStackView *maximumRow = [[UIStackView alloc] initWithArrangedSubviews:@[maximumLabel, self.maximumSwitch]];
    maximumRow.axis = UILayoutConstraintAxisHorizontal;
    maximumRow.alignment = UIStackViewAlignmentCenter;
    maximumRow.distribution = UIStackViewDistributionEqualSpacing;

    UILabel *highQualityLabel = [self labelWithText:@"尽量不降低画质" size:16 weight:UIFontWeightMedium];
    self.highQualitySwitch = [UISwitch new];
    self.highQualitySwitch.on = [self.streamDefaults boolForKey:LTHighQualityHighFPSKey];
    self.highQualitySwitch.onTintColor = [self accentColor];
    [self.highQualitySwitch addTarget:self action:@selector(highQualityChanged:)
                       forControlEvents:UIControlEventValueChanged];
    UIStackView *highQualityRow = [[UIStackView alloc] initWithArrangedSubviews:@[
        highQualityLabel, self.highQualitySwitch
    ]];
    highQualityRow.axis = UILayoutConstraintAxisHorizontal;
    highQualityRow.alignment = UIStackViewAlignmentCenter;
    highQualityRow.distribution = UIStackViewDistributionEqualSpacing;

    UILabel *codecLabel = [self labelWithText:@"直播编码" size:16 weight:UIFontWeightMedium];
    self.codecControl = [[UISegmentedControl alloc] initWithItems:@[@"H.264", @"VP8"]];
    self.codecControl.backgroundColor = [self fieldBackgroundColor];
    self.codecControl.tintColor = [self accentColor];
    [self.codecControl setTitleTextAttributes:@{NSForegroundColorAttributeName: UIColor.whiteColor}
                                    forState:UIControlStateNormal];
    [self.codecControl setTitleTextAttributes:@{NSForegroundColorAttributeName: UIColor.whiteColor}
                                    forState:UIControlStateSelected];
    if (@available(iOS 13.0, *)) self.codecControl.selectedSegmentTintColor = [self accentColor];
    NSString *savedCodec = [[self.streamDefaults stringForKey:LTCodecKey] uppercaseString];
    self.codecControl.selectedSegmentIndex = [savedCodec isEqualToString:@"VP8"] ? 1 : 0;
    [self.codecControl addTarget:self action:@selector(codecChanged:)
                forControlEvents:UIControlEventValueChanged];
    UIStackView *codecRow = [[UIStackView alloc] initWithArrangedSubviews:@[codecLabel, self.codecControl]];
    codecRow.axis = UILayoutConstraintAxisHorizontal;
    codecRow.alignment = UIStackViewAlignmentCenter;
    codecRow.distribution = UIStackViewDistributionEqualSpacing;

    UILabel *hint = [self labelWithText:@"“尽量不降低画质”默认开启：30fps、高码率，并关闭 WebRTC 主动降分辨率/帧率；关闭后使用带宽自适应压缩。切换画质模式或编码后，刷新观看网页生效。分辨率在下次开始直播时生效。"
                                      size:13 weight:UIFontWeightRegular];
    hint.textColor = [self secondaryTextColor];
    hint.numberOfLines = 0;

    UIStackView *settings = [[UIStackView alloc] initWithArrangedSubviews:@[
        highQualityRow, codecRow, resolutionTitle, resolutionRow, maximumRow, hint
    ]];
    settings.axis = UILayoutConstraintAxisVertical;
    settings.spacing = 12;
    settings.layoutMargins = UIEdgeInsetsMake(18, 18, 18, 18);
    settings.layoutMarginsRelativeArrangement = YES;
    settings.backgroundColor = [self cardBackgroundColor];
    settings.layer.cornerRadius = 14;

    UILabel *instructions = [self labelWithText:@"开始后保持本 App 在后台运行"
                                             size:15 weight:UIFontWeightRegular];
    instructions.numberOfLines = 0;
    instructions.textAlignment = NSTextAlignmentCenter;

    UILabel *networkModeLabel = [self labelWithText:@"网络模式" size:15 weight:UIFontWeightMedium];
    self.networkModeControl = [[UISegmentedControl alloc] initWithItems:@[@"局域网", @"IPv6", @"自定义服务器"]];
    NSInteger savedNetworkMode = [self.streamDefaults integerForKey:LTNetworkModeKey];
    if (savedNetworkMode < 0 || savedNetworkMode > 2) savedNetworkMode = 0;
    self.networkModeControl.selectedSegmentIndex = savedNetworkMode;
    self.networkModeControl.backgroundColor = [self fieldBackgroundColor];
    self.networkModeControl.tintColor = [self accentColor];
    [self.networkModeControl setTitleTextAttributes:@{NSForegroundColorAttributeName: UIColor.whiteColor}
                                           forState:UIControlStateNormal];
    [self.networkModeControl setTitleTextAttributes:@{NSForegroundColorAttributeName: UIColor.whiteColor}
                                           forState:UIControlStateSelected];
    if (@available(iOS 13.0, *)) self.networkModeControl.selectedSegmentTintColor = [self accentColor];
    [self.networkModeControl addTarget:self action:@selector(networkModeChanged:)
                      forControlEvents:UIControlEventValueChanged];
    UIStackView *networkModeRow = [[UIStackView alloc] initWithArrangedSubviews:@[
        networkModeLabel, self.networkModeControl
    ]];
    networkModeRow.axis = UILayoutConstraintAxisHorizontal;
    networkModeRow.alignment = UIStackViewAlignmentCenter;
    networkModeRow.spacing = 12;
    [networkModeLabel setContentHuggingPriority:UILayoutPriorityRequired
                                        forAxis:UILayoutConstraintAxisHorizontal];

    UILabel *deviceNameLabel = [self labelWithText:@"设备名称" size:15 weight:UIFontWeightMedium];
    [deviceNameLabel setContentHuggingPriority:UILayoutPriorityRequired
                                      forAxis:UILayoutConstraintAxisHorizontal];
    self.deviceNameField = [UITextField new];
    self.deviceNameField.text = [self.streamDefaults stringForKey:LTDeviceNameKey];
    self.deviceNameField.placeholder = @"iPhone15Pro";
    self.deviceNameField.borderStyle = UITextBorderStyleNone;
    self.deviceNameField.layer.cornerRadius = 8;
    self.deviceNameField.layer.borderWidth = 1;
    self.deviceNameField.layer.borderColor = [UIColor colorWithWhite:0.28 alpha:1.0].CGColor;
    self.deviceNameField.backgroundColor = [self fieldBackgroundColor];
    self.deviceNameField.textColor = [self primaryTextColor];
    self.deviceNameField.tintColor = [self accentColor];
    self.deviceNameField.keyboardAppearance = UIKeyboardAppearanceDark;
    self.deviceNameField.keyboardType = UIKeyboardTypeASCIICapable;
    self.deviceNameField.autocorrectionType = UITextAutocorrectionTypeNo;
    self.deviceNameField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.deviceNameField.clearButtonMode = UITextFieldViewModeWhileEditing;
    self.deviceNameField.textAlignment = NSTextAlignmentCenter;
    self.deviceNameField.font = [UIFont monospacedDigitSystemFontOfSize:16 weight:UIFontWeightMedium];
    self.deviceNameField.delegate = self;
    [self.deviceNameField addTarget:self action:@selector(deviceNameChanged:)
                   forControlEvents:UIControlEventEditingChanged];
    [self.deviceNameField addTarget:self action:@selector(deviceNameEditingEnded:)
                   forControlEvents:UIControlEventEditingDidEnd];
    [self.deviceNameField.heightAnchor constraintEqualToConstant:44].active = YES;
    UIStackView *deviceNameRow = [[UIStackView alloc] initWithArrangedSubviews:@[
        deviceNameLabel, self.deviceNameField
    ]];
    deviceNameRow.axis = UILayoutConstraintAxisHorizontal;
    deviceNameRow.alignment = UIStackViewAlignmentCenter;
    deviceNameRow.spacing = 12;

    UILabel *addressModeLabel = [self labelWithText:@"访问方式" size:15 weight:UIFontWeightMedium];
    self.addressControl = [[UISegmentedControl alloc] initWithItems:@[@"IP 地址", @"设备名称"]];
    self.addressControl.selectedSegmentIndex = [self.streamDefaults integerForKey:LTAddressModeKey] == 1 ? 1 : 0;
    self.addressControl.backgroundColor = [self fieldBackgroundColor];
    self.addressControl.tintColor = [self accentColor];
    [self.addressControl setTitleTextAttributes:@{NSForegroundColorAttributeName: UIColor.whiteColor}
                                       forState:UIControlStateNormal];
    [self.addressControl setTitleTextAttributes:@{NSForegroundColorAttributeName: UIColor.whiteColor}
                                       forState:UIControlStateSelected];
    if (@available(iOS 13.0, *)) self.addressControl.selectedSegmentTintColor = [self accentColor];
    [self.addressControl addTarget:self action:@selector(addressModeChanged:)
                  forControlEvents:UIControlEventValueChanged];
    UIStackView *addressModeRow = [[UIStackView alloc] initWithArrangedSubviews:@[
        addressModeLabel, self.addressControl
    ]];
    addressModeRow.axis = UILayoutConstraintAxisHorizontal;
    addressModeRow.alignment = UIStackViewAlignmentCenter;
    addressModeRow.spacing = 12;
    [addressModeLabel setContentHuggingPriority:UILayoutPriorityRequired
                                       forAxis:UILayoutConstraintAxisHorizontal];

    UILabel *portLabel = [self labelWithText:@"监听端口" size:15 weight:UIFontWeightMedium];
    [portLabel setContentHuggingPriority:UILayoutPriorityRequired
                                 forAxis:UILayoutConstraintAxisHorizontal];
    self.portField = [UITextField new];
    self.portField.text = [NSString stringWithFormat:@"%ld", (long)[self configuredPort]];
    self.portField.borderStyle = UITextBorderStyleNone;
    self.portField.layer.cornerRadius = 8;
    self.portField.layer.borderWidth = 1;
    self.portField.layer.borderColor = [UIColor colorWithWhite:0.28 alpha:1.0].CGColor;
    self.portField.backgroundColor = [self fieldBackgroundColor];
    self.portField.textColor = [self primaryTextColor];
    self.portField.tintColor = [self accentColor];
    self.portField.keyboardAppearance = UIKeyboardAppearanceDark;
    self.portField.keyboardType = UIKeyboardTypeNumberPad;
    self.portField.textAlignment = NSTextAlignmentCenter;
    self.portField.font = [UIFont monospacedDigitSystemFontOfSize:16 weight:UIFontWeightMedium];
    self.portField.delegate = self;
    [self.portField.heightAnchor constraintEqualToConstant:44].active = YES;
    [self.portField.widthAnchor constraintEqualToConstant:110].active = YES;
    UIButton *applyPortButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [applyPortButton setTitle:@"应用" forState:UIControlStateNormal];
    [applyPortButton setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    applyPortButton.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    applyPortButton.backgroundColor = [self accentColor];
    applyPortButton.layer.cornerRadius = 9;
    [applyPortButton addTarget:self action:@selector(applyPortSetting:)
              forControlEvents:UIControlEventTouchUpInside];
    [applyPortButton.widthAnchor constraintEqualToConstant:68].active = YES;
    [applyPortButton.heightAnchor constraintEqualToConstant:42].active = YES;

    UIStackView *portRow = [[UIStackView alloc] initWithArrangedSubviews:@[
        portLabel, self.portField, applyPortButton
    ]];
    portRow.axis = UILayoutConstraintAxisHorizontal;
    portRow.alignment = UIStackViewAlignmentCenter;
    portRow.distribution = UIStackViewDistributionEqualSpacing;
    portRow.spacing = 10;

    self.urlLabel = [self urlValueLabel];
    self.localCopyButton = [self copyButtonWithAction:@selector(copyLocalURL:)];
    UIStackView *urlRow = [[UIStackView alloc] initWithArrangedSubviews:@[self.urlLabel, self.localCopyButton]];
    urlRow.axis = UILayoutConstraintAxisHorizontal;
    urlRow.alignment = UIStackViewAlignmentCenter;
    urlRow.spacing = 10;

    UILabel *addressNotice = [self labelWithText:@"局域网可用 IP 地址或设备名称访问。修改端口后点击“应用”；如果直播已经开始，需要重新开启直播才能让监听端口切换。"
                                               size:12 weight:UIFontWeightRegular];
    addressNotice.textColor = [self secondaryTextColor];
    addressNotice.numberOfLines = 0;

    UILabel *lanTitle = [self labelWithText:@"局域网访问" size:16 weight:UIFontWeightSemibold];
    self.lanContainer = [[UIStackView alloc] initWithArrangedSubviews:@[
        lanTitle, deviceNameRow, addressModeRow, urlRow, addressNotice
    ]];
    self.lanContainer.axis = UILayoutConstraintAxisVertical;
    self.lanContainer.spacing = 12;

    UILabel *externalTitle = [self labelWithText:@"IPv6 访问" size:16 weight:UIFontWeightSemibold];
    self.externalURLLabel = [self urlValueLabel];
    self.externalCopyButton = [self copyButtonWithAction:@selector(copyExternalURL:)];
    UIStackView *externalURLRow = [[UIStackView alloc] initWithArrangedSubviews:@[
        self.externalURLLabel, self.externalCopyButton
    ]];
    externalURLRow.axis = UILayoutConstraintAxisHorizontal;
    externalURLRow.alignment = UIStackViewAlignmentCenter;
    externalURLRow.spacing = 10;

    UILabel *externalNotice = [self labelWithText:@"显示当前检测到的 IPv6 地址，并与局域网共用同一个监听端口。IPv6 地址存在不代表一定能从其他网络直接访问，是否可达仍取决于当前网络和入站策略。"
                                                size:12 weight:UIFontWeightRegular];
    externalNotice.textColor = [self secondaryTextColor];
    externalNotice.numberOfLines = 0;
    self.wanContainer = [[UIStackView alloc] initWithArrangedSubviews:@[
        externalTitle, externalURLRow, externalNotice
    ]];
    self.wanContainer.axis = UILayoutConstraintAxisVertical;
    self.wanContainer.spacing = 12;

    UILabel *customServerTitle = [self labelWithText:@"自定义服务器" size:16 weight:UIFontWeightSemibold];
    UILabel *customServerLabel = [self labelWithText:@"服务器地址" size:15 weight:UIFontWeightMedium];
    [customServerLabel setContentHuggingPriority:UILayoutPriorityRequired
                                        forAxis:UILayoutConstraintAxisHorizontal];
    self.customServerField = [UITextField new];
    self.customServerField.text = [self.streamDefaults stringForKey:LTCustomServerKey];
    self.customServerField.placeholder = @"https://example.com";
    self.customServerField.borderStyle = UITextBorderStyleNone;
    self.customServerField.layer.cornerRadius = 8;
    self.customServerField.layer.borderWidth = 1;
    self.customServerField.layer.borderColor = [UIColor colorWithWhite:0.28 alpha:1.0].CGColor;
    self.customServerField.backgroundColor = [self fieldBackgroundColor];
    self.customServerField.textColor = [self primaryTextColor];
    self.customServerField.tintColor = [self accentColor];
    self.customServerField.keyboardAppearance = UIKeyboardAppearanceDark;
    self.customServerField.keyboardType = UIKeyboardTypeURL;
    self.customServerField.autocorrectionType = UITextAutocorrectionTypeNo;
    self.customServerField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.customServerField.clearButtonMode = UITextFieldViewModeWhileEditing;
    self.customServerField.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    self.customServerField.delegate = self;
    [self.customServerField addTarget:self action:@selector(customServerChanged:)
                     forControlEvents:UIControlEventEditingChanged];
    [self.customServerField addTarget:self action:@selector(customServerEditingEnded:)
                     forControlEvents:UIControlEventEditingDidEnd];
    [self.customServerField.heightAnchor constraintEqualToConstant:44].active = YES;

    UIStackView *customServerInputRow = [[UIStackView alloc] initWithArrangedSubviews:@[
        customServerLabel, self.customServerField
    ]];
    customServerInputRow.axis = UILayoutConstraintAxisHorizontal;
    customServerInputRow.alignment = UIStackViewAlignmentCenter;
    customServerInputRow.spacing = 12;

    UILabel *customAccessLabel = [self labelWithText:@"访问地址" size:15 weight:UIFontWeightMedium];
    [customAccessLabel setContentHuggingPriority:UILayoutPriorityRequired
                                        forAxis:UILayoutConstraintAxisHorizontal];
    self.customServerURLLabel = [self urlValueLabel];
    self.customServerCopyButton = [self copyButtonWithAction:@selector(copyCustomServerURL:)];
    UIStackView *customURLValueRow = [[UIStackView alloc] initWithArrangedSubviews:@[
        self.customServerURLLabel, self.customServerCopyButton
    ]];
    customURLValueRow.axis = UILayoutConstraintAxisHorizontal;
    customURLValueRow.alignment = UIStackViewAlignmentCenter;
    customURLValueRow.spacing = 10;

    UIStackView *customURLRow = [[UIStackView alloc] initWithArrangedSubviews:@[
        customAccessLabel, customURLValueRow
    ]];
    customURLRow.axis = UILayoutConstraintAxisVertical;
    customURLRow.spacing = 8;

    UILabel *customServerNotice = [self labelWithText:@"用于填写内网穿透、反向代理或自定义域名的访问地址。这里只保存并复制该地址，不会把视频自动转发到服务器。"
                                                    size:12 weight:UIFontWeightRegular];
    customServerNotice.textColor = [self secondaryTextColor];
    customServerNotice.numberOfLines = 0;
    self.customServerContainer = [[UIStackView alloc] initWithArrangedSubviews:@[
        customServerTitle, customServerInputRow, customURLRow, customServerNotice
    ]];
    self.customServerContainer.axis = UILayoutConstraintAxisVertical;
    self.customServerContainer.spacing = 12;

    UIStackView *accessCard = [[UIStackView alloc] initWithArrangedSubviews:@[
        networkModeRow, portRow, self.lanContainer, self.wanContainer, self.customServerContainer
    ]];
    accessCard.axis = UILayoutConstraintAxisVertical;
    accessCard.spacing = 14;
    accessCard.layoutMargins = UIEdgeInsetsMake(18, 18, 18, 18);
    accessCard.layoutMarginsRelativeArrangement = YES;
    accessCard.backgroundColor = [self cardBackgroundColor];
    accessCard.layer.cornerRadius = 14;

    UILabel *creditLabel = [self labelWithText:@"本工具由 AI 编写" size:12 weight:UIFontWeightRegular];
    creditLabel.textColor = [self secondaryTextColor];
    creditLabel.textAlignment = NSTextAlignmentCenter;

    UIStackView *content = [[UIStackView alloc] initWithArrangedSubviews:@[
        titleLabel, startButton, deviceAudioRow, launchHint, settings, instructions, accessCard, creditLabel
    ]];
    content.translatesAutoresizingMaskIntoConstraints = NO;
    content.axis = UILayoutConstraintAxisVertical;
    content.spacing = 16;

    UIScrollView *scrollView = [UIScrollView new];
    scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    scrollView.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    [self.view addSubview:scrollView];
    [scrollView addSubview:content];
    [NSLayoutConstraint activateConstraints:@[
        [scrollView.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor],
        [scrollView.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor],
        [scrollView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [scrollView.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor],
        [content.leadingAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.leadingAnchor constant:24],
        [content.trailingAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.trailingAnchor constant:-24],
        [content.topAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.topAnchor constant:16],
        [content.bottomAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.bottomAnchor constant:-16],
        [content.widthAnchor constraintEqualToAnchor:scrollView.frameLayoutGuide.widthAnchor constant:-48]
    ]];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self.view
                                                                          action:@selector(endEditing:)];
    tap.cancelsTouchesInView = NO;
    [self.view addGestureRecognizer:tap];
    [self updateResolutionFields];
    [self updateNetworkModeUI];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(applicationDidBecomeActive:)
                                                 name:UIApplicationDidBecomeActiveNotification
                                               object:nil];
    [self refreshAccessURLWithIPRetry];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refreshAccessURLWithIPRetry];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)applicationDidBecomeActive:(NSNotification *)notification {
    (void)notification;
    [self refreshAccessURLWithIPRetry];
}

- (UILabel *)labelWithText:(NSString *)text size:(CGFloat)size weight:(UIFontWeight)weight {
    UILabel *label = [UILabel new];
    label.text = text;
    label.font = [UIFont systemFontOfSize:size weight:weight];
    label.textColor = [self primaryTextColor];
    return label;
}

- (UITextField *)resolutionFieldWithValue:(NSInteger)value {
    UITextField *field = [UITextField new];
    field.text = [NSString stringWithFormat:@"%ld", (long)value];
    field.borderStyle = UITextBorderStyleNone;
    field.layer.cornerRadius = 8;
    field.layer.borderWidth = 1;
    field.layer.borderColor = [UIColor colorWithWhite:0.28 alpha:1.0].CGColor;
    field.keyboardType = UIKeyboardTypeNumberPad;
    field.keyboardAppearance = UIKeyboardAppearanceDark;
    field.textAlignment = NSTextAlignmentCenter;
    field.tintColor = [self accentColor];
    field.font = [UIFont monospacedDigitSystemFontOfSize:18 weight:UIFontWeightMedium];
    field.delegate = self;
    [field addTarget:self action:@selector(resolutionChanged:) forControlEvents:UIControlEventEditingChanged];
    [field addTarget:self action:@selector(resolutionEditingEnded:) forControlEvents:UIControlEventEditingDidEnd];
    return field;
}

- (void)maximumChanged:(UISwitch *)sender {
    [self.streamDefaults setBool:sender.isOn forKey:LTUseMaximumKey];
    [self.streamDefaults synchronize];
    [self updateResolutionFields];
}

- (void)highQualityChanged:(UISwitch *)sender {
    [self.streamDefaults setBool:sender.isOn forKey:LTHighQualityHighFPSKey];
    [self.streamDefaults synchronize];
}

- (void)deviceAudioChanged:(UISwitch *)sender {
    [self.streamDefaults setBool:sender.isOn forKey:LTShareDeviceAudioKey];
    [self.streamDefaults synchronize];
}

- (void)codecChanged:(UISegmentedControl *)sender {
    [self.streamDefaults setObject:sender.selectedSegmentIndex == 1 ? @"VP8" : @"H264"
                            forKey:LTCodecKey];
    [self.streamDefaults synchronize];
}

- (void)startRemoteControl:(UIButton *)sender {
    (void)sender;
    [self.broadcastPicker layoutIfNeeded];
    UIButton *systemButton = [self systemBroadcastButtonInView:self.broadcastPicker];
    if (systemButton) {
        [systemButton sendActionsForControlEvents:UIControlEventTouchUpInside];
        return;
    }

    [RPBroadcastActivityViewController loadBroadcastActivityViewControllerWithHandler:
     ^(RPBroadcastActivityViewController *activityViewController, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (activityViewController) {
                [self presentViewController:activityViewController animated:YES completion:nil];
                return;
            }
            NSString *message = error.localizedDescription ?: @"请确认直播远程控制扩展已安装。";
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"无法打开系统直播"
                                                                           message:message
                                                                    preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:alert animated:YES completion:nil];
        });
    }];
}

- (UIButton *)systemBroadcastButtonInView:(UIView *)view {
    for (UIView *subview in view.subviews) {
        if ([subview isKindOfClass:UIButton.class]) return (UIButton *)subview;
        UIButton *button = [self systemBroadcastButtonInView:subview];
        if (button) return button;
    }
    return nil;
}

- (void)networkModeChanged:(UISegmentedControl *)sender {
    [self.streamDefaults setInteger:sender.selectedSegmentIndex forKey:LTNetworkModeKey];
    [self.streamDefaults synchronize];
    [self updateNetworkModeUI];
    [self updateAccessURL];
}

- (void)addressModeChanged:(UISegmentedControl *)sender {
    [self.streamDefaults setInteger:sender.selectedSegmentIndex forKey:LTAddressModeKey];
    [self.streamDefaults synchronize];
    [self refreshAccessURLWithIPRetry];
}

- (void)deviceNameChanged:(UITextField *)sender {
    (void)sender;
    [self updateAccessURL];
}

- (void)deviceNameEditingEnded:(UITextField *)sender {
    NSString *name = [self normalizedDeviceName:sender.text];
    sender.text = name;
    [self.streamDefaults setObject:name forKey:LTDeviceNameKey];
    [self.streamDefaults synchronize];
    [self updateAccessURL];
}

- (void)customServerChanged:(UITextField *)sender {
    (void)sender;
    [self updateAccessURL];
}

- (void)customServerEditingEnded:(UITextField *)sender {
    NSString *url = [self normalizedCustomServerURL:sender.text];
    sender.text = url ?: @"";
    [self.streamDefaults setObject:sender.text forKey:LTCustomServerKey];
    [self.streamDefaults synchronize];
    [self updateAccessURL];
}

- (void)applyPortSetting:(UIButton *)sender {
    NSInteger port = [self normalizedPort:self.portField.text.integerValue];
    self.portField.text = [NSString stringWithFormat:@"%ld", (long)port];
    [self.streamDefaults setInteger:port forKey:LTPortKey];
    [self.streamDefaults synchronize];
    [self.view endEditing:YES];
    [self refreshAccessURLWithIPRetry];

    [sender setTitle:@"已应用" forState:UIControlStateNormal];
    sender.enabled = NO;
    __weak UIButton *weakButton = sender;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        UIButton *button = weakButton;
        [button setTitle:@"应用" forState:UIControlStateNormal];
        button.enabled = YES;
    });
}

- (NSInteger)configuredPort {
    NSInteger port = [self.streamDefaults integerForKey:LTPortKey];
    return [self normalizedPort:port];
}

- (NSInteger)normalizedPort:(NSInteger)port {
    if (port < 1 || port > 65535) return 8080;
    return port;
}

- (void)updateNetworkModeUI {
    NSInteger mode = self.networkModeControl.selectedSegmentIndex;
    self.lanContainer.hidden = mode != 0;
    self.wanContainer.hidden = mode != 1;
    self.customServerContainer.hidden = mode != 2;
}

- (void)refreshAccessURLWithIPRetry {
    NSUInteger generation = ++self.ipRetryGeneration;
    [self updateAccessURL];
    if (self.ipURL.length) return;

    NSArray<NSNumber *> *delays = @[@0.4, @0.8, @1.5, @2.5, @4.0];
    __weak typeof(self) weakSelf = self;
    for (NSNumber *delay in delays) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            ViewController *strongSelf = weakSelf;
            if (!strongSelf || strongSelf.ipRetryGeneration != generation) return;
            [strongSelf updateAccessURL];
            if (strongSelf.ipURL.length) strongSelf.ipRetryGeneration++;
        });
    }
}

- (void)updateAccessURL {
    NSInteger port = [self configuredPort];
    NSString *deviceName = [self normalizedDeviceName:self.deviceNameField.text];
    NSString *localIP = [self localIPAddress];
    self.ipURL = localIP.length ? [NSString stringWithFormat:@"http://%@:%ld/", localIP, (long)port] : nil;
    self.deviceURL = [NSString stringWithFormat:@"http://%@.local:%ld/", deviceName, (long)port];

    BOOL useDeviceName = self.addressControl.selectedSegmentIndex == 1;
    self.localURL = useDeviceName ? self.deviceURL : self.ipURL;
    if (self.localURL.length) {
        self.urlLabel.text = self.localURL;
        self.localCopyButton.enabled = YES;
        self.localCopyButton.alpha = 1.0;
    } else {
        self.urlLabel.text = @"正在获取 IP…";
        self.localCopyButton.enabled = NO;
        self.localCopyButton.alpha = 0.45;
    }

    NSString *ipv6 = [self globalIPv6Address];
    if (ipv6.length) {
        self.externalURL = [NSString stringWithFormat:@"http://[%@]:%ld/", ipv6, (long)port];
        self.externalURLLabel.text = self.externalURL;
        self.externalCopyButton.enabled = YES;
        self.externalCopyButton.alpha = 1.0;
    } else {
        self.externalURL = nil;
        self.externalURLLabel.text = @"未检测到 IPv6";
        self.externalCopyButton.enabled = NO;
        self.externalCopyButton.alpha = 0.45;
    }

    self.customServerURL = [self normalizedCustomServerURL:self.customServerField.text];
    if (self.customServerURL.length) {
        self.customServerURLLabel.text = self.customServerURL;
        self.customServerCopyButton.enabled = YES;
        self.customServerCopyButton.alpha = 1.0;
    } else {
        self.customServerURLLabel.text = @"请填写服务器地址";
        self.customServerCopyButton.enabled = NO;
        self.customServerCopyButton.alpha = 0.45;
    }
}

- (NSString *)normalizedCustomServerURL:(NSString *)value {
    NSString *trimmed = [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!trimmed.length) return nil;
    if ([trimmed rangeOfString:@"://"].location == NSNotFound)
        return [@"http://" stringByAppendingString:trimmed];
    return trimmed;
}

- (NSString *)normalizedDeviceName:(NSString *)name {
    NSString *trimmed = [name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSMutableString *result = [NSMutableString string];
    BOOL previousWasSeparator = NO;
    for (NSUInteger index = 0; index < trimmed.length && result.length < 63; index++) {
        unichar character = [trimmed characterAtIndex:index];
        BOOL allowed = (character >= 'a' && character <= 'z') ||
                       (character >= 'A' && character <= 'Z') ||
                       (character >= '0' && character <= '9');
        if (allowed) {
            [result appendFormat:@"%C", character];
            previousWasSeparator = NO;
        } else if (result.length && !previousWasSeparator) {
            [result appendString:@"-"];
            previousWasSeparator = YES;
        }
    }
    while ([result hasSuffix:@"-"]) [result deleteCharactersInRange:NSMakeRange(result.length - 1, 1)];
    return result.length ? result : @"iPhone";
}

- (void)copyLocalURL:(UIButton *)sender {
    [self copyURL:self.localURL withButton:sender];
}

- (void)copyExternalURL:(UIButton *)sender {
    [self copyURL:self.externalURL withButton:sender];
}

- (void)copyCustomServerURL:(UIButton *)sender {
    [self copyURL:self.customServerURL withButton:sender];
}

- (void)copyURL:(NSString *)url withButton:(UIButton *)sender {
    if (!url.length) return;
    UIPasteboard.generalPasteboard.string = url;
    [sender setTitle:@"已复制" forState:UIControlStateNormal];
    sender.enabled = NO;
    __weak UIButton *weakButton = sender;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        UIButton *button = weakButton;
        [button setTitle:@"复制" forState:UIControlStateNormal];
        button.enabled = YES;
    });
}

- (UILabel *)urlValueLabel {
    UILabel *label = [self labelWithText:@"" size:15 weight:UIFontWeightMedium];
    if (@available(iOS 13.0, *)) {
        label.font = [UIFont monospacedSystemFontOfSize:15 weight:UIFontWeightMedium];
    } else {
        label.font = [UIFont fontWithName:@"Menlo" size:15];
    }
    label.adjustsFontSizeToFitWidth = YES;
    label.minimumScaleFactor = 0.5;
    label.textAlignment = NSTextAlignmentCenter;
    label.numberOfLines = 1;
    [label setContentCompressionResistancePriority:UILayoutPriorityDefaultLow
                                           forAxis:UILayoutConstraintAxisHorizontal];
    return label;
}

- (UIButton *)copyButtonWithAction:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:@"复制" forState:UIControlStateNormal];
    [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    button.backgroundColor = [self accentColor];
    button.layer.cornerRadius = 9;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [button.widthAnchor constraintEqualToConstant:68].active = YES;
    [button.heightAnchor constraintEqualToConstant:40].active = YES;
    return button;
}

- (void)resolutionChanged:(UITextField *)sender {
    (void)sender;
    [self.streamDefaults setInteger:[self normalizedResolution:self.widthField.text.integerValue] forKey:LTWidthKey];
    [self.streamDefaults setInteger:[self normalizedResolution:self.heightField.text.integerValue] forKey:LTHeightKey];
    [self.streamDefaults synchronize];
}

- (void)resolutionEditingEnded:(UITextField *)sender {
    NSInteger value = [self normalizedResolution:sender.text.integerValue];
    sender.text = [NSString stringWithFormat:@"%ld", (long)value];
    [self resolutionChanged:sender];
}

- (NSInteger)normalizedResolution:(NSInteger)value {
    value = MIN(4096, MAX(160, value));
    return value & ~1;
}

- (void)updateResolutionFields {
    BOOL enabled = !self.maximumSwitch.isOn;
    UIColor *background = enabled ? [self fieldBackgroundColor] : [self disabledFieldColor];
    UIColor *text = enabled ? [self primaryTextColor] : [self disabledTextColor];
    for (UITextField *field in @[self.widthField, self.heightField]) {
        field.enabled = enabled;
        field.backgroundColor = background;
        field.textColor = text;
    }
    if (!enabled) [self.view endEditing:YES];
}

- (UIColor *)primaryTextColor {
    return UIColor.whiteColor;
}

- (UIColor *)secondaryTextColor {
    return [UIColor colorWithWhite:0.72 alpha:1.0];
}

- (UIColor *)disabledTextColor {
    return [UIColor colorWithWhite:0.42 alpha:1.0];
}

- (UIColor *)cardBackgroundColor {
    return [UIColor colorWithWhite:0.10 alpha:1.0];
}

- (UIColor *)fieldBackgroundColor {
    return [UIColor colorWithWhite:0.16 alpha:1.0];
}

- (UIColor *)disabledFieldColor {
    return [UIColor colorWithWhite:0.08 alpha:1.0];
}

- (UIColor *)accentColor {
    if (@available(iOS 13.0, *)) return UIColor.systemBlueColor;
    return [UIColor colorWithRed:0.0 green:0.48 blue:1.0 alpha:1.0];
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}

- (NSString *)localIPAddress {
    struct ifaddrs *interfaces = NULL;
    NSString *address = nil;
    if (getifaddrs(&interfaces) != 0) return nil;

    for (struct ifaddrs *item = interfaces; item; item = item->ifa_next) {
        if (!item->ifa_addr || item->ifa_addr->sa_family != AF_INET) continue;
        if (strcmp(item->ifa_name, "en0") != 0) continue;
        if (!(item->ifa_flags & IFF_UP) || !(item->ifa_flags & IFF_RUNNING) ||
            (item->ifa_flags & IFF_LOOPBACK)) continue;

        struct sockaddr_in *socketAddress = (struct sockaddr_in *)item->ifa_addr;
        uint32_t ipv4 = ntohl(socketAddress->sin_addr.s_addr);
        if (ipv4 == 0 || (ipv4 >> 24) == 127 || (ipv4 & 0xFFFF0000U) == 0xA9FE0000U) continue;

        char host[INET_ADDRSTRLEN] = {0};
        if (!inet_ntop(AF_INET, &socketAddress->sin_addr, host, sizeof(host))) continue;
        address = [NSString stringWithUTF8String:host];
        if (address.length) break;
    }

    freeifaddrs(interfaces);
    return address;
}

- (NSString *)globalIPv6Address {
    struct ifaddrs *interfaces = NULL;
    NSString *wifiAddress = nil;
    NSString *cellularAddress = nil;

    if (getifaddrs(&interfaces) == 0) {
        for (struct ifaddrs *item = interfaces; item; item = item->ifa_next) {
            if (!item->ifa_addr || item->ifa_addr->sa_family != AF_INET6) continue;

            struct sockaddr_in6 *socketAddress = (struct sockaddr_in6 *)item->ifa_addr;
            const struct in6_addr *addr = &socketAddress->sin6_addr;
            if (IN6_IS_ADDR_UNSPECIFIED(addr) || IN6_IS_ADDR_LOOPBACK(addr) ||
                IN6_IS_ADDR_LINKLOCAL(addr) || IN6_IS_ADDR_MULTICAST(addr)) continue;

            // 只把 2000::/3 视作可直接展示的公网 IPv6；排除 ULA、链路本地和隧道私网地址。
            if ((addr->s6_addr[0] & 0xE0) != 0x20) continue;

            char host[INET6_ADDRSTRLEN] = {0};
            if (!inet_ntop(AF_INET6, addr, host, sizeof(host))) continue;
            NSString *candidate = [NSString stringWithUTF8String:host];
            if (!candidate.length) continue;

            if (strcmp(item->ifa_name, "en0") == 0) {
                wifiAddress = candidate;
                break;
            }
            if (!cellularAddress && strncmp(item->ifa_name, "pdp_ip", 6) == 0)
                cellularAddress = candidate;
        }
        freeifaddrs(interfaces);
    }
    return wifiAddress ?: cellularAddress;
}

@end
