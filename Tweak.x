#import <UIKit/UIKit.h>
#import <objc/runtime.h>

@interface OverlayManager : NSObject
+ (instancetype)sharedInstance;
- (void)togglePanel;
@end

// 全局状态控制
static BOOL g_forceUnmuteEnabled = NO;
static BOOL g_audioBoostEnabled = NO;
static UIWindow *g_overlayWindow = nil;
static UISwitch *g_micSwitch = nil;
static UISwitch *g_boostSwitch = nil;
static UILabel *g_statusLabel = nil;

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
            // 创建浮窗
            g_overlayWindow = [[UIWindow alloc] initWithFrame:CGRectMake(30, 120, 300, 290)];
            g_overlayWindow.backgroundColor = [UIColor colorWithRed:0.12 green:0.12 blue:0.14 alpha:0.95];
            g_overlayWindow.layer.cornerRadius = 14;
            g_overlayWindow.layer.borderWidth = 1;
            g_overlayWindow.layer.borderColor = [UIColor colorWithWhite:0.3 alpha:0.6].CGColor;
            g_overlayWindow.clipsToBounds = YES;
            g_overlayWindow.windowLevel = UIWindowLevelAlert + 100;

            // 标题
            UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(15, 12, 270, 22)];
            title.text = @"Wespy 控制面板";
            title.textColor = [UIColor whiteColor];
            title.textAlignment = NSTextAlignmentCenter;
            title.font = [UIFont boldSystemFontOfSize:16];
            [g_overlayWindow addSubview:title];

            // 1. 强制开麦开关项
            UILabel *micLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, 50, 180, 30)];
            micLabel.text = @"强制闭麦推流";
            micLabel.textColor = [UIColor whiteColor];
            micLabel.font = [UIFont systemFontOfSize:14];
            [g_overlayWindow addSubview:micLabel];

            g_micSwitch = [[UISwitch alloc] initWithFrame:CGRectMake(220, 50, 50, 30)];
            g_micSwitch.on = g_forceUnmuteEnabled;
            [g_micSwitch addTarget:self action:@selector(onMicSwitchChanged:) forControlEvents:UIControlEventValueChanged];
            [g_overlayWindow addSubview:g_micSwitch];

            // 2. 音量压制超频开关项
            UILabel *boostLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, 100, 180, 30)];
            boostLabel.text = @"超频增益压制 (MAX)";
            boostLabel.textColor = [UIColor whiteColor];
            boostLabel.font = [UIFont systemFontOfSize:14];
            [g_overlayWindow addSubview:boostLabel];

            g_boostSwitch = [[UISwitch alloc] initWithFrame:CGRectMake(220, 100, 50, 30)];
            g_boostSwitch.on = g_audioBoostEnabled;
            [g_boostSwitch addTarget:self action:@selector(onBoostSwitchChanged:) forControlEvents:UIControlEventValueChanged];
            [g_overlayWindow addSubview:g_boostSwitch];

            // 状态描述
            g_statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(15, 150, 270, 45)];
            g_statusLabel.numberOfLines = 2;
            g_statusLabel.textColor = [UIColor colorWithRed:0.4 green:0.8 blue:1 alpha:1];
            g_statusLabel.font = [UIFont systemFontOfSize:12];
            g_statusLabel.textAlignment = NSTextAlignmentCenter;
            [self updateStatusText];
            [g_overlayWindow addSubview:g_statusLabel];

            // 隐藏面板按钮
            UIButton *hideBtn = [UIButton buttonWithType:UIButtonTypeSystem];
            hideBtn.frame = CGRectMake(20, 215, 260, 38);
            hideBtn.backgroundColor = [UIColor colorWithWhite:0.25 alpha:0.8];
            hideBtn.layer.cornerRadius = 8;
            [hideBtn setTitle:@"收起面板 (双指双击再次呼出)" forState:UIControlStateNormal];
            [hideBtn setTitleColor:[UIColor lightGrayColor] forState:UIControlStateNormal];
            hideBtn.titleLabel.font = [UIFont systemFontOfSize:13];
            [hideBtn addTarget:self action:@selector(togglePanel) forControlEvents:UIControlEventTouchUpInside];
            [g_overlayWindow addSubview:hideBtn];
        }

        g_overlayWindow.hidden = !g_overlayWindow.hidden;
    });
}

- (void)onMicSwitchChanged:(UISwitch *)sender {
    g_forceUnmuteEnabled = sender.isOn;
    [self updateStatusText];
}

- (void)onBoostSwitchChanged:(UISwitch *)sender {
    g_audioBoostEnabled = sender.isOn;
    [self updateStatusText];
}

- (void)updateStatusText {
    if (!g_statusLabel) return;
    NSString *micStatus = g_forceUnmuteEnabled ? @"强制开麦: 开启" : @"强制开麦: 正常";
    NSString *boostStatus = g_audioBoostEnabled ? @"增益压制: 开启(超限)" : @"增益压制: 正常";
    g_statusLabel.text = [NSString stringWithFormat:@"%@\n%@", micStatus, boostStatus];
}

@end

// ==================== 底层 Hook 逻辑 (避免主动调用非法 Selector) ====================

// Hook ZegoExpressEngine 音频推流与音量控制
%hook ZegoExpressEngine

- (void)mutePublishStreamAudio:(BOOL)mute {
    if (g_forceUnmuteEnabled) {
        %orig(NO); // 强制不闭麦，保持推流
        return;
    }
    %orig(mute);
}

- (void)enableAudioCapture:(BOOL)enable {
    if (g_forceUnmuteEnabled) {
        %orig(YES); // 强制开启硬件采集
        return;
    }
    %orig(enable);
}

- (void)setCaptureVolume:(int)volume {
    if (g_audioBoostEnabled) {
        %orig(400); // 注入超限采集音量
        return;
    }
    %orig(volume);
}

%end

// Hook TXLiteAV / TRTC 音频推流与音量控制
%hook TRTCCloud

- (void)muteLocalAudio:(BOOL)mute {
    if (g_forceUnmuteEnabled) {
        %orig(NO); // 腾讯引擎强制不闭麦
        return;
    }
    %orig(mute);
}

- (void)setAudioCaptureVolume:(NSInteger)volume {
    if (g_audioBoostEnabled) {
        %orig(400); // 腾讯引擎超频音量
        return;
    }
    %orig(volume);
}

%end

// ==================== 手势注册 ====================

%hook UIWindow

- (instancetype)initWithFrame:(CGRect)frame {
    id orig = %orig;
    if (orig) {
        UITapGestureRecognizer *doubleTouchDoubleTap = [[UITapGestureRecognizer alloc]
            initWithTarget:[OverlayManager sharedInstance]
            action:@selector(togglePanel)];
        doubleTouchDoubleTap.numberOfTouchesRequired = 2; // 双指
        doubleTouchDoubleTap.numberOfTapsRequired = 2;    // 双击
        [self addGestureRecognizer:doubleTouchDoubleTap];
    }
    return orig;
}

%end
