#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <AudioToolbox/AudioToolbox.h>
#import <substrate.h>

@interface OverlayManager : NSObject
+ (instancetype)sharedInstance;
- (void)togglePanel;
- (void)onMicSwitchChanged:(UISwitch *)sender;
- (void)onBoostSwitchChanged:(UISwitch *)sender;
- (void)updateStatusText;
@end

// 全局控制开关
static BOOL g_forceOpenMic = YES;
static BOOL g_superBoost = YES;
static float g_boostFactor = 4.0f; // 4倍硬核数字增益
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
            g_overlayWindow = [[UIWindow alloc] initWithFrame:CGRectMake(25, 120, 270, 280)];
            g_overlayWindow.backgroundColor = [UIColor colorWithRed:0.1 green:0.1 blue:0.12 alpha:0.95];
            g_overlayWindow.layer.cornerRadius = 14;
            g_overlayWindow.layer.borderWidth = 1.0;
            g_overlayWindow.layer.borderColor = [UIColor colorWithWhite:0.4 alpha:0.6].CGColor;
            g_overlayWindow.clipsToBounds = YES;
            g_overlayWindow.windowLevel = UIWindowLevelAlert + 999;

            UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
            [g_overlayWindow addGestureRecognizer:pan];

            UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(10, 10, 250, 25)];
            title.text = @"Wespy 终极防线突破";
            title.textColor = [UIColor whiteColor];
            title.textAlignment = NSTextAlignmentCenter;
            title.font = [UIFont boldSystemFontOfSize:14];
            [g_overlayWindow addSubview:title];

            // 强制开麦开关
            UILabel *micLabel = [[UILabel alloc] initWithFrame:CGRectMake(15, 45, 160, 30)];
            micLabel.text = @"强制开麦推流";
            micLabel.textColor = [UIColor whiteColor];
            micLabel.font = [UIFont systemFontOfSize:13];
            [g_overlayWindow addSubview:micLabel];

            g_micSwitch = [[UISwitch alloc] initWithFrame:CGRectMake(190, 45, 50, 30)];
            g_micSwitch.on = g_forceOpenMic;
            [g_micSwitch addTarget:self action:@selector(onMicSwitchChanged:) forControlEvents:UIControlEventValueChanged];
            [g_overlayWindow addSubview:g_micSwitch];

            // 音量增益开关
            UILabel *boostLabel = [[UILabel alloc] initWithFrame:CGRectMake(15, 90, 160, 30)];
            boostLabel.text = @"全场音量压制";
            boostLabel.textColor = [UIColor whiteColor];
            boostLabel.font = [UIFont systemFontOfSize:13];
            [g_overlayWindow addSubview:boostLabel];

            g_boostSwitch = [[UISwitch alloc] initWithFrame:CGRectMake(190, 90, 50, 30)];
            g_boostSwitch.on = g_superBoost;
            [g_boostSwitch addTarget:self action:@selector(onBoostSwitchChanged:) forControlEvents:UIControlEventValueChanged];
            [g_overlayWindow addSubview:g_boostSwitch];

            // 状态标签
            g_statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(15, 135, 240, 40)];
            g_statusLabel.numberOfLines = 2;
            g_statusLabel.textColor = [UIColor colorWithRed:0.2 green:0.9 blue:1.0 alpha:1];
            g_statusLabel.font = [UIFont systemFontOfSize:11];
            g_statusLabel.textAlignment = NSTextAlignmentCenter;
            [self updateStatusText];
            [g_overlayWindow addSubview:g_statusLabel];

            // 收起按钮
            UIButton *hideBtn = [UIButton buttonWithType:UIButtonTypeSystem];
            hideBtn.frame = CGRectMake(20, 195, 230, 36);
            hideBtn.backgroundColor = [UIColor colorWithWhite:0.25 alpha:0.9];
            hideBtn.layer.cornerRadius = 8;
            [hideBtn setTitle:@"收起面板 (双指双击呼出)" forState:UIControlStateNormal];
            [hideBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
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

- (void)updateStatusText {
    if (!g_statusLabel) return;
    g_statusLabel.text = [NSString stringWithFormat:@"强制开麦: %@ | 增益放大: %@",
                          g_forceOpenMic ? @"ON" : @"OFF",
                          g_superBoost ? @"ON(4.0X)" : @"OFF"];
}
@end

// ==================== 1. 业务层麦位与语音房强制劫持 ====================

%hook HWVoiceRoomCommon
- (void)muteSelfAudio:(BOOL)mute {
    if (g_forceOpenMic) {
        %orig(NO);
        return;
    }
    %orig(mute);
}
- (BOOL)isSelfMuted {
    if (g_forceOpenMic) {
        return NO;
    }
    return %orig();
}
%end

%hook RoomInfoManager
- (void)updateMemberMuteState:(id)arg1 mute:(BOOL)arg2 {
    if (g_forceOpenMic) {
        %orig(arg1, NO);
        return;
    }
    %orig();
}
%end

// ==================== 2. RTC 引擎层状态机与信令免疫 ====================

%hook ZegoExpressEngine
- (void)mutePublishStreamAudio:(BOOL)mute {
    if (g_forceOpenMic) {
        %orig(NO);
        return;
    }
    %orig(mute);
}
- (void)enableAudioCapture:(BOOL)enable {
    if (g_forceOpenMic) {
        %orig(YES);
        return;
    }
    %orig(enable);
}
%end

%hook TRTCCloud
- (void)muteLocalAudio:(BOOL)mute {
    if (g_forceOpenMic) {
        %orig(NO);
        return;
    }
    %orig(mute);
}
%end

// ==================== 3. 终极音频缓冲区硬核增益（免AGC抑制） ====================

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
                float val = samples[i] * g_boostFactor;
                if (val > 32767.0f) val = 32767.0f;
                if (val < -32768.0f) val = -32768.0f;
                samples[i] = (SInt16)val;
            }
        }
    }
    return orig_AudioQueueEnqueueBuffer(inAQ, inBuffer, inNumPacketDescs, inPacketDescs);
}

// ==================== 初始化与手势挂载 ====================

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
    void *aqHandle = dlopen("/System/Library/Frameworks/AudioToolbox.framework/AudioToolbox", RTLD_NOW);
    if (aqHandle) {
        void *sym = dlsym(aqHandle, "AudioQueueEnqueueBuffer");
        if (sym) {
            MSHookFunction(sym, (void *)my_AudioQueueEnqueueBuffer, (void **)&orig_AudioQueueEnqueueBuffer);
        }
    }
}
