#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <AudioToolbox/AudioToolbox.h>
#import <substrate.h>

// ==================== 前向声明 ====================

@interface OverlayManager : NSObject
+ (instancetype)sharedInstance;
- (void)togglePanel;
- (void)onMicSwitchChanged:(UISwitch *)sender;
- (void)onBoostSwitchChanged:(UISwitch *)sender;
- (void)onKickSwitchChanged:(UISwitch *)sender;
- (void)updateStatusText;
@end

// 全局开关
static BOOL g_forceOpenMic = YES;       // 强开麦/禁麦绕过
static BOOL g_superBoost = YES;          // PCM 增益放大
static BOOL g_blockKickSignal = YES;     // 拦截 Kick 信令/网络请求
static float g_boostFactor = 3.5f;

static UIWindow *g_overlayWindow = nil;
static UISwitch *g_micSwitch = nil;
static UISwitch *g_boostSwitch = nil;
static UISwitch *g_kickSwitch = nil;
static UILabel *g_statusLabel = nil;

// ==================== UI 控制面板 ====================

@implementation OverlayManager
+ (instancetype)sharedInstance {
    static OverlayManager *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[OverlayManager alloc] init];
    });
    return instance;
}

- (void)togglePanel {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!g_overlayWindow) {
            g_overlayWindow = [[UIWindow alloc] initWithFrame:CGRectMake(25, 100, 280, 300)];
            g_overlayWindow.backgroundColor = [UIColor colorWithRed:0.10 green:0.10 blue:0.13 alpha:0.97];
            g_overlayWindow.layer.cornerRadius = 14;
            g_overlayWindow.layer.borderWidth = 1.0;
            g_overlayWindow.layer.borderColor = [UIColor colorWithWhite:0.35 alpha:0.8].CGColor;
            g_overlayWindow.clipsToBounds = YES;
            g_overlayWindow.windowLevel = UIWindowLevelAlert + 999;
            g_overlayWindow.rootViewController = [UIViewController new];

            UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
            [g_overlayWindow addGestureRecognizer:pan];

            UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(10, 8, 260, 25)];
            title.text = @"Wespy 终极控制面板";
            title.textColor = [UIColor whiteColor];
            title.textAlignment = NSTextAlignmentCenter;
            title.font = [UIFont boldSystemFontOfSize:14];
            [g_overlayWindow addSubview:title];

            // 1. 强开麦开关
            UILabel *micLbl = [[UILabel alloc] initWithFrame:CGRectMake(15, 42, 150, 30)];
            micLbl.text = @"强开麦/禁麦绕过";
            micLbl.textColor = [UIColor whiteColor];
            micLbl.font = [UIFont systemFontOfSize:13];
            [g_overlayWindow addSubview:micLbl];

            g_micSwitch = [[UISwitch alloc] initWithFrame:CGRectMake(210, 42, 50, 30)];
            g_micSwitch.on = g_forceOpenMic;
            [g_micSwitch addTarget:self action:@selector(onMicSwitchChanged:) forControlEvents:UIControlEventValueChanged];
            [g_overlayWindow addSubview:g_micSwitch];

            // 2. 增益放大开关
            UILabel *boostLbl = [[UILabel alloc] initWithFrame:CGRectMake(15, 80, 150, 30)];
            boostLbl.text = @"全场声音压制(3.5X)";
            boostLbl.textColor = [UIColor whiteColor];
            boostLbl.font = [UIFont systemFontOfSize:13];
            [g_overlayWindow addSubview:boostLbl];

            g_boostSwitch = [[UISwitch alloc] initWithFrame:CGRectMake(210, 80, 50, 30)];
            g_boostSwitch.on = g_superBoost;
            [g_boostSwitch addTarget:self action:@selector(onBoostSwitchChanged:) forControlEvents:UIControlEventValueChanged];
            [g_overlayWindow addSubview:g_boostSwitch];

            // 3. Kick 信令拦截开关
            UILabel *kickLbl = [[UILabel alloc] initWithFrame:CGRectMake(15, 118, 150, 30)];
            kickLbl.text = @"Kick/信令拦截";
            kickLbl.textColor = [UIColor whiteColor];
            kickLbl.font = [UIFont systemFontOfSize:13];
            [g_overlayWindow addSubview:kickLbl];

            g_kickSwitch = [[UISwitch alloc] initWithFrame:CGRectMake(210, 118, 50, 30)];
            g_kickSwitch.on = g_blockKickSignal;
            [g_kickSwitch addTarget:self action:@selector(onKickSwitchChanged:) forControlEvents:UIControlEventValueChanged];
            [g_overlayWindow addSubview:g_kickSwitch];

            // 状态显示
            g_statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(10, 158, 260, 50)];
            g_statusLabel.numberOfLines = 3;
            g_statusLabel.textColor = [UIColor colorWithRed:0.2 green:0.8 blue:1.0 alpha:1];
            g_statusLabel.font = [UIFont systemFontOfSize:10];
            g_statusLabel.textAlignment = NSTextAlignmentCenter;
            [self updateStatusText];
            [g_overlayWindow addSubview:g_statusLabel];

            // 隐藏面板按钮
            UIButton *hideBtn = [UIButton buttonWithType:UIButtonTypeSystem];
            hideBtn.frame = CGRectMake(20, 226, 240, 36);
            hideBtn.backgroundColor = [UIColor colorWithWhite:0.22 alpha:0.9];
            hideBtn.layer.cornerRadius = 8;
            [hideBtn setTitle:@"隐藏面板 (双指双击呼出)" forState:UIControlStateNormal];
            [hideBtn setTitleColor:[UIColor lightGrayColor] forState:UIControlStateNormal];
            hideBtn.titleLabel.font = [UIFont systemFontOfSize:12];
            [hideBtn addTarget:self action:@selector(togglePanel) forControlEvents:UIControlEventTouchUpInside];
            [g_overlayWindow addSubview:hideBtn];
        }
        g_overlayWindow.hidden = !g_overlayWindow.hidden;
    });
}

- (void)handlePan:(UIPanGestureRecognizer *)pan {
    CGPoint translation = [pan translationInView:g_overlayWindow];
    g_overlayWindow.center = CGPointMake(g_overlayWindow.center.x + translation.x, g_overlayWindow.center.y + translation.y);
    [pan setTranslation:CGPointZero inView:g_overlayWindow];
}

- (void)onMicSwitchChanged:(UISwitch *)sender {
    g_forceOpenMic = sender.isOn;
    [self updateStatusText];
}

- (void)onBoostSwitchChanged:(UISwitch *)sender {
    g_superBoost = sender.isOn;
    [self updateStatusText];
}

- (void)onKickSwitchChanged:(UISwitch *)sender {
    g_blockKickSignal = sender.isOn;
    [self updateStatusText];
}

- (void)updateStatusText {
    if (!g_statusLabel) return;
    g_statusLabel.text = [NSString stringWithFormat:
        @"开麦: %@ | 增益: %@\nKick拦截: %@",
        g_forceOpenMic ? @"ON" : @"OFF",
        g_superBoost ? @"3.5X" : @"OFF",
        g_blockKickSignal ? @"ON" : @"OFF"];
}
@end

// ==================== 1. 声网 Agora RTC 引擎 ====================
// 拦截所有静音指令，强制保持发流状态

%hook AgoraRtcEngineKit

// 阻止本地音频静音
- (int)muteLocalAudioStream:(BOOL)mute {
    if (g_forceOpenMic) {
        return %orig(NO);
    }
    return %orig(mute);
}

// 强制开启本地音频采集
- (int)enableLocalAudio:(BOOL)enabled {
    if (g_forceOpenMic) {
        return %orig(YES);
    }
    return %orig(enabled);
}

// 强制保持主播/发流角色
- (int)setClientRole:(NSInteger)role {
    if (g_forceOpenMic) {
        return %orig(1); // AgoraClientRoleBroadcaster = 1
    }
    return %orig(role);
}

// 录音信号音量增益
- (int)adjustRecordingSignalVolume:(NSInteger)volume {
    if (g_superBoost) {
        return %orig(400);
    }
    return %orig(volume);
}

// 阻止静音所有远端音频（防止被一键全静音）
- (int)muteAllRemoteAudioStreams:(BOOL)mute {
    if (g_forceOpenMic) {
        return %orig(NO);
    }
    return %orig(mute);
}

// 阻止静音特定远端用户
- (int)muteRemoteAudioStream:(NSInteger)uid mute:(BOOL)mute {
    if (g_forceOpenMic) {
        return %orig(uid, NO);
    }
    return %orig(uid, mute);
}

// 强制提升远端用户播放音量
- (int)adjustUserPlaybackSignalVolume:(NSInteger)uid volume:(NSInteger)volume {
    if (g_superBoost) {
        return %orig(uid, 400);
    }
    return %orig(uid, volume);
}

// 确保音频模块始终开启
- (int)enableAudio {
    return %orig();
}

// 强制扬声器外放
- (int)setEnableSpeakerphone:(BOOL)enable {
    if (g_forceOpenMic) {
        return %orig(YES);
    }
    return %orig(enable);
}

// 阻止禁用音频
- (int)disableAudio {
    if (g_forceOpenMic) {
        return 0; // 直接返回成功但不执行
    }
    return %orig();
}

%end

// ==================== 2. 腾讯云 LiteAV / TRTC 引擎 ====================

%hook TRTCCloud

// 阻止本地音频静音
- (void)muteLocalAudio:(BOOL)mute {
    if (g_forceOpenMic) {
        %orig(NO);
        return;
    }
    %orig(mute);
}

// 阻止停止本地音频采集
- (void)stopLocalAudio {
    if (g_forceOpenMic) {
        return;
    }
    %orig();
}

// 确保启动本地音频
- (void)startLocalAudio:(NSInteger)quality {
    %orig(quality);
}

// 阻止静音远端用户
- (void)muteRemoteAudio:(NSString *)userId mute:(BOOL)mute {
    if (g_forceOpenMic) {
        %orig(userId, NO);
        return;
    }
    %orig(userId, mute);
}

// 强制设置音频质量为最高
- (void)setAudioQuality:(NSInteger)quality {
    if (g_superBoost) {
        %orig(2); // TRTCAudioQualityMusic
        return;
    }
    %orig(quality);
}

// 确保音量评估始终开启（用于光圈动画驱动）
- (void)enableAudioVolumeEvaluation:(BOOL)enabled {
    %orig(YES);
}

// 强制扬声器路由
- (void)setAudioRoute:(NSInteger)route {
    if (g_forceOpenMic) {
        %orig(0); // TRTCAudioModeSpeakerphone = 0
        return;
    }
    %orig(route);
}

%end

// ==================== 3. ZegoExpressEngine（即构 SDK） ====================

%hook ZegoExpressEngine

- (void)muteMicrophone:(BOOL)mute channel:(NSString *)channel {
    if (g_forceOpenMic) {
        %orig(NO, channel);
        return;
    }
    %orig(mute, channel);
}

- (void)mutePublishStreamAudio:(BOOL)mute channel:(NSString *)channel {
    if (g_forceOpenMic) {
        %orig(NO, channel);
        return;
    }
    %orig(mute, channel);
}

- (void)enableMicrophone:(BOOL)enable channel:(NSString *)channel {
    if (g_forceOpenMic) {
        %orig(YES, channel);
        return;
    }
    %orig(enable, channel);
}

- (void)setAudioCaptureVolume:(NSInteger)volume channel:(NSString *)channel {
    if (g_superBoost) {
        %orig(150, channel);
        return;
    }
    %orig(volume, channel);
}

%end

// ==================== 4. 业务层麦位状态拦截 ====================

%hook HWVoiceRoomCommon
- (void)muteSelfAudio:(BOOL)mute {
    if (g_forceOpenMic) {
        %orig(NO);
        return;
    }
    %orig(mute);
}
- (BOOL)isSelfMuted {
    if (g_forceOpenMic) return NO;
    return %orig();
}
%end

// ==================== 5. 房间状态模型属性锁死 ====================

%hook WESVoiceRoomManager
- (BOOL)isMuted {
    if (g_forceOpenMic) return NO;
    return %orig();
}
- (BOOL)isForbidden {
    if (g_forceOpenMic) return NO;
    return %orig();
}
- (BOOL)isBanned {
    if (g_forceOpenMic) return NO;
    return %orig();
}
- (BOOL)isMicMuted {
    if (g_forceOpenMic) return NO;
    return %orig();
}
- (BOOL)isMicForbidden {
    if (g_forceOpenMic) return NO;
    return %orig();
}
- (BOOL)isMicBanned {
    if (g_forceOpenMic) return NO;
    return %orig();
}
- (BOOL)canSpeak {
    if (g_forceOpenMic) return YES;
    return %orig();
}
- (BOOL)hasMicPermission {
    if (g_forceOpenMic) return YES;
    return %orig();
}
%end

%hook WESMicService
- (BOOL)isMuted {
    if (g_forceOpenMic) return NO;
    return %orig();
}
- (BOOL)isForbidden {
    if (g_forceOpenMic) return NO;
    return %orig();
}
- (BOOL)isBanned {
    if (g_forceOpenMic) return NO;
    return %orig();
}
- (BOOL)isMicMuted {
    if (g_forceOpenMic) return NO;
    return %orig();
}
- (BOOL)isMicForbidden {
    if (g_forceOpenMic) return NO;
    return %orig();
}
- (BOOL)canSpeak {
    if (g_forceOpenMic) return YES;
    return %orig();
}
%end

%hook WESSeatModel
- (BOOL)isMuted {
    if (g_forceOpenMic) return NO;
    return %orig();
}
- (BOOL)isForbidden {
    if (g_forceOpenMic) return NO;
    return %orig();
}
- (BOOL)isBanned {
    if (g_forceOpenMic) return NO;
    return %orig();
}
- (BOOL)isMicMuted {
    if (g_forceOpenMic) return NO;
    return %orig();
}
- (BOOL)isMicForbidden {
    if (g_forceOpenMic) return NO;
    return %orig();
}
- (NSInteger)micStatus {
    if (g_forceOpenMic) return 0; // 0 = 正常开麦
    return %orig();
}
- (NSInteger)seatStatus {
    if (g_forceOpenMic) return 1; // 1 = 已上麦
    return %orig();
}
- (BOOL)isOnSeat {
    if (g_forceOpenMic) return YES;
    return %orig();
}
%end

// ==================== 6. 网络层拦截 Kick 请求 ====================
// 拦截发往 huiwan-api.afunapp.com/util_api/kick_agora_user 的请求

%hook NSURLSession

- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request
                            completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler {
    if (g_blockKickSignal && request.URL.absoluteString) {
        NSString *urlStr = request.URL.absoluteString;
        // 拦截 kick_agora_user 请求
        if ([urlStr containsString:@"kick_agora_user"] ||
            [urlStr containsString:@"kick_user"] ||
            [urlStr containsString:@"mute_user"] ||
            [urlStr containsString:@"forbid_mic"]) {
            // 返回一个空的 mock 响应，不实际发送请求
            dispatch_async(dispatch_get_main_queue(), ^{
                NSData *mockData = [@"{\"code\":0,\"msg\":\"success\",\"data\":{}}" dataUsingEncoding:NSUTF8StringEncoding];
                NSHTTPURLResponse *mockResponse = [[NSHTTPURLResponse alloc] initWithURL:request.URL
                                                                               statusCode:200
                                                                              HTTPVersion:@"HTTP/1.1"
                                                                             headerFields:@{@"Content-Type": @"application/json"}];
                if (completionHandler) {
                    completionHandler(mockData, mockResponse, nil);
                }
            });
            return nil;
        }
    }
    return %orig(request, completionHandler);
}

- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request {
    if (g_blockKickSignal && request.URL.absoluteString) {
        NSString *urlStr = request.URL.absoluteString;
        if ([urlStr containsString:@"kick_agora_user"] ||
            [urlStr containsString:@"kick_user"] ||
            [urlStr containsString:@"mute_user"] ||
            [urlStr containsString:@"forbid_mic"]) {
            return nil;
        }
    }
    return %orig(request);
}

%end

// ==================== 7. PCM 缓冲区硬件级倍乘放大 ====================

static void *(*orig_AudioQueueEnqueueBuffer)(void *, void *, UInt32, void *);

void *my_AudioQueueEnqueueBuffer(void *inAQ, void *inBuffer, UInt32 inNumPacketDescs, void *inPacketDescs) {
    if (g_superBoost && inBuffer) {
        struct AudioQueueBuffer {
            UInt32 mAudioDataBytesCapacity;
            void *mAudioData;
            UInt32 mAudioDataByteSize;
            void *mPacketDescription;
            UInt32 mPacketDescriptionCount;
        } *buf = (struct AudioQueueBuffer *)inBuffer;

        if (buf && buf->mAudioData && buf->mAudioDataByteSize > 0) {
            SInt16 *samples = (SInt16 *)buf->mAudioData;
            int numSamples = buf->mAudioDataByteSize / sizeof(SInt16);
            for (int i = 0; i < numSamples; i++) {
                float val = (float)samples[i] * g_boostFactor;
                if (val > 32767.0f) val = 32767.0f;
                if (val < -32768.0f) val = -32768.0f;
                samples[i] = (SInt16)val;
            }
        }
    }
    return orig_AudioQueueEnqueueBuffer(inAQ, inBuffer, inNumPacketDescs, inPacketDescs);
}

// ==================== 9. 信号防崩溃保护 ====================

static void safe_signal_handler(int sig) {
    // 空实现，阻止 App 自毁信号中断
}

static void install_signal_handlers() {
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = safe_signal_handler;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = 0;

    sigaction(SIGSEGV, &sa, NULL);
    sigaction(SIGBUS, &sa, NULL);
    sigaction(SIGILL, &sa, NULL);
    sigaction(SIGABRT, &sa, NULL);
    sigaction(SIGFPE, &sa, NULL);
}

// 定时器重新注册信号处理器（防止被 RTC SDK 覆盖）
static void reinstall_timer_cb(CFRunLoopTimerRef timer, void *info) {
    install_signal_handlers();
}

// ==================== 10. 手势唤起与构造函数 ====================

%hook UIWindow
- (instancetype)initWithFrame:(CGRect)frame {
    id orig = %orig;
    if (orig) {
        UITapGestureRecognizer *gesture = [[UITapGestureRecognizer alloc] initWithTarget:[OverlayManager sharedInstance] action:@selector(togglePanel)];
        gesture.numberOfTouchesRequired = 2;
        gesture.numberOfTapsRequired = 2;
        [self addGestureRecognizer:gesture];
    }
    return orig;
}
%end

%ctor {
    @autoreleasepool {
        // 1. 安装信号处理器
        install_signal_handlers();

        // 2. 定时器每 5 秒重新注册信号处理器
        CFRunLoopTimerRef timer = CFRunLoopTimerCreate(
            kCFAllocatorDefault,
            CFAbsoluteTimeGetCurrent() + 5.0,
            5.0,  // 每 5 秒
            0,
            0,
            reinstall_timer_cb,
            NULL
        );
        CFRunLoopAddTimer(CFRunLoopGetMain(), timer, kCFRunLoopCommonModes);
        CFRelease(timer);

        // 3. Hook AudioQueueEnqueueBuffer
        void *aqHandle = dlopen("/System/Library/Frameworks/AudioToolbox.framework/AudioToolbox", RTLD_NOW);
        if (aqHandle) {
            void *sym = dlsym(aqHandle, "AudioQueueEnqueueBuffer");
            if (sym) {
                MSHookFunction(sym, (void *)my_AudioQueueEnqueueBuffer, (void **)&orig_AudioQueueEnqueueBuffer);
            }
        }

        // 4. 延迟 3 秒显示控制面板
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [[OverlayManager sharedInstance] togglePanel];
        });
    }
}
