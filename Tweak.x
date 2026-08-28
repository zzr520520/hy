#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <AudioToolbox/AudioToolbox.h>
#import <substrate.h>

@interface OverlayManager : NSObject
+ (instancetype)sharedInstance;
- (void)togglePanel;
- (void)onMicSwitchChanged:(UISwitch *)sender;
- (void)onBoostSwitchChanged:(UISwitch *)sender;
- (void)updateStatusText;
@end

static BOOL g_forceOpenMic = YES;
static BOOL g_superBoost = YES;
static float g_boostFactor = 3.5f;
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
            g_overlayWindow = [[UIWindow alloc] initWithFrame:CGRectMake(25, 120, 280, 260)];
            g_overlayWindow.backgroundColor = [UIColor colorWithRed:0.12 green:0.12 blue:0.15 alpha:0.96];
            g_overlayWindow.layer.cornerRadius = 14;
            g_overlayWindow.layer.borderWidth = 1.0;
            g_overlayWindow.layer.borderColor = [UIColor colorWithWhite:0.4 alpha:0.8].CGColor;
            g_overlayWindow.clipsToBounds = YES;
            g_overlayWindow.windowLevel = UIWindowLevelAlert + 999;

            UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
            [g_overlayWindow addGestureRecognizer:pan];

            UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(10, 10, 260, 25)];
            title.text = @"Wespy 终极控制面板 (可拖动)";
            title.textColor = [UIColor whiteColor];
            title.textAlignment = NSTextAlignmentCenter;
            title.font = [UIFont boldSystemFontOfSize:13];
            [g_overlayWindow addSubview:title];

            // 1. 强制开麦开关
            UILabel *micLbl = [[UILabel alloc] initWithFrame:CGRectMake(15, 45, 150, 30)];
            micLbl.text = @"强开麦/禁麦绕过";
            micLbl.textColor = [UIColor whiteColor];
            micLbl.font = [UIFont systemFontOfSize:13];
            [g_overlayWindow addSubview:micLbl];

            g_micSwitch = [[UISwitch alloc] initWithFrame:CGRectMake(210, 45, 50, 30)];
            g_micSwitch.on = g_forceOpenMic;
            [g_micSwitch addTarget:self action:@selector(onMicSwitchChanged:) forControlEvents:UIControlEventValueChanged];
            [g_overlayWindow addSubview:g_micSwitch];

            // 2. 增益放大开关
            UILabel *boostLbl = [[UILabel alloc] initWithFrame:CGRectMake(15, 90, 150, 30)];
            boostLbl.text = @"全场声音压制(3.5X)";
            boostLbl.textColor = [UIColor whiteColor];
            boostLbl.font = [UIFont systemFontOfSize:13];
            [g_overlayWindow addSubview:boostLbl];

            g_boostSwitch = [[UISwitch alloc] initWithFrame:CGRectMake(210, 90, 50, 30)];
            g_boostSwitch.on = g_superBoost;
            [g_boostSwitch addTarget:self action:@selector(onBoostSwitchChanged:) forControlEvents:UIControlEventValueChanged];
            [g_overlayWindow addSubview:g_boostSwitch];

            // 状态显示
            g_statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(10, 135, 260, 45)];
            g_statusLabel.numberOfLines = 2;
            g_statusLabel.textColor = [UIColor colorWithRed:0.2 green:0.8 blue:1.0 alpha:1];
            g_statusLabel.font = [UIFont systemFontOfSize:11];
            g_statusLabel.textAlignment = NSTextAlignmentCenter;
            [self updateStatusText];
            [g_overlayWindow addSubview:g_statusLabel];

            // 隐藏面板按钮
            UIButton *hideBtn = [UIButton buttonWithType:UIButtonTypeSystem];
            hideBtn.frame = CGRectMake(20, 200, 240, 36);
            hideBtn.backgroundColor = [UIColor colorWithWhite:0.25 alpha:0.9];
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

- (void)updateStatusText {
    if (!g_statusLabel) return;
    g_statusLabel.text = [NSString stringWithFormat:@"强开麦: %@ | 声音压制: %@",
                          g_forceOpenMic ? @"开启" : @"关闭",
                          g_superBoost ? @"开启 (3.5X)" : @"关闭"];
}
@end

// ==================== 核心底层突破：声网(Agora)与音视频引擎底裤级劫持 ====================

// 1. 劫持声网 Agora RTC 引擎
%hook AgoraRtcEngineKit
- (int)muteLocalAudioStream:(BOOL)mute {
    if (g_forceOpenMic) {
        return %orig(NO);
    }
    return %orig(mute);
}

- (int)enableLocalAudio:(BOOL)enabled {
    if (g_forceOpenMic) {
        return %orig(YES);
    }
    return %orig(enabled);
}

- (int)adjustRecordingSignalVolume:(NSInteger)volume {
    if (g_superBoost) {
        return %orig(400);
    }
    return %orig(volume);
}
%end

// 2. 业务房强制不自闭麦
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

// 3. PCM 缓冲区硬件级直接倍乘放大（绕过普通API限制）
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

// ==================== 手势唤起与构造函数 ====================
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
