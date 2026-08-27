#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <AudioUnit/AudioUnit.h>
#import <dlfcn.h>
#import <substrate.h>

@interface OverlayManager : NSObject
+ (instancetype)sharedInstance;
- (void)togglePanel;
@end

static BOOL g_forceUnmute = NO;
static BOOL g_audioBoost = NO;
static float g_boostMultiplier = 3.5f; // 数字放大倍率

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
            // 初始化可拖拽窗口
            g_overlayWindow = [[UIWindow alloc] initWithFrame:CGRectMake(40, 150, 260, 240)];
            g_overlayWindow.backgroundColor = [UIColor colorWithRed:0.1 green:0.1 blue:0.12 alpha:0.92];
            g_overlayWindow.layer.cornerRadius = 14;
            g_overlayWindow.layer.borderWidth = 1.0;
            g_overlayWindow.layer.borderColor = [UIColor colorWithWhite:0.3 alpha:0.8].CGColor;
            g_overlayWindow.clipsToBounds = YES;
            g_overlayWindow.windowLevel = UIWindowLevelAlert + 100;

            // 添加拖拽手势
            UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
            [g_overlayWindow addGestureRecognizer:pan];

            // 标题
            UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(10, 10, 240, 24)];
            title.text = @"Wespy 控制面板 (可拖动)";
            title.textColor = [UIColor whiteColor];
            title.textAlignment = NSTextAlignmentCenter;
            title.font = [UIFont boldSystemFontOfSize:14];
            [g_overlayWindow addSubview:title];

            // 开麦开关
            UILabel *micLabel = [[UILabel alloc] initWithFrame:CGRectMake(15, 45, 140, 30)];
            micLabel.text = @"强制闭麦推流";
            micLabel.textColor = [UIColor whiteColor];
            micLabel.font = [UIFont systemFontOfSize:13];
            [g_overlayWindow addSubview:micLabel];

            g_micSwitch = [[UISwitch alloc] initWithFrame:CGRectMake(190, 45, 50, 30)];
            g_micSwitch.on = g_forceUnmute;
            [g_micSwitch addTarget:self action:@selector(onMicSwitchChanged:) forControlEvents:UIControlEventValueChanged];
            [g_overlayWindow addSubview:g_micSwitch];

            // 增益超频开关
            UILabel *boostLabel = [[UILabel alloc] initWithFrame:CGRectMake(15, 90, 140, 30)];
            boostLabel.text = @"全场音量压制";
            boostLabel.textColor = [UIColor whiteColor];
            boostLabel.font = [UIFont systemFontOfSize:13];
            [g_overlayWindow addSubview:boostLabel];

            g_boostSwitch = [[UISwitch alloc] initWithFrame:CGRectMake(190, 90, 50, 30)];
            g_boostSwitch.on = g_audioBoost;
            [g_boostSwitch addTarget:self action:@selector(onBoostSwitchChanged:) forControlEvents:UIControlEventValueChanged];
            [g_overlayWindow addSubview:g_boostSwitch];

            // 状态标签
            g_statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(10, 135, 240, 35)];
            g_statusLabel.numberOfLines = 2;
            g_statusLabel.textColor = [UIColor colorWithRed:0.2 green:0.8 blue:1.0 alpha:1];
            g_statusLabel.font = [UIFont systemFontOfSize:11];
            g_statusLabel.textAlignment = NSTextAlignmentCenter;
            [self updateStatusText];
            [g_overlayWindow addSubview:g_statusLabel];

            // 收起按钮
            UIButton *hideBtn = [UIButton buttonWithType:UIButtonTypeSystem];
            hideBtn.frame = CGRectMake(15, 180, 230, 34);
            hideBtn.backgroundColor = [UIColor colorWithWhite:0.25 alpha:0.9];
            hideBtn.layer.cornerRadius = 6;
            [hideBtn setTitle:@"收起 (双指双击再呼出)" forState:UIControlStateNormal];
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
    g_forceUnmute = sender.isOn;
    [self updateStatusText];
}

- (void)onBoostSwitchChanged:(UISwitch *)sender {
    g_audioBoost = sender.isOn;
    [self updateStatusText];
}

- (void)updateStatusText {
    if (!g_statusLabel) return;
    g_statusLabel.text = [NSString stringWithFormat:@"强制推流: %@ | 增益放大: %@",
                          g_forceUnmute ? @"开启" : @"关闭",
                          g_audioBoost ? @"开启 (3.5x)" : @"关闭"];
}

@end

// ==================== 1. 业务层与麦位状态拦截 ====================

// 拦截语音房闭麦/静音业务逻辑 (报告 3.4 & 5.5 核心模块)
%hook HWVoiceRoomCommon
- (void)muteSelfAudio:(BOOL)mute {
    if (g_forceUnmute) {
        %orig(NO);
        return;
    }
    %orig(mute);
}
%end

// ==================== 2. Zego 引擎底层 Hook ====================

%hook ZegoExpressEngine

- (void)mutePublishStreamAudio:(BOOL)mute {
    if (g_forceUnmute) {
        %orig(NO);
        return;
    }
    %orig(mute);
}

- (void)enableAudioCapture:(BOOL)enable {
    if (g_forceUnmute) {
        %orig(YES);
        return;
    }
    %orig(enable);
}

- (void)stopPublishingStream {
    if (g_forceUnmute) {
        return; // 阻止业务层在闭麦时销毁推流通道
    }
    %orig;
}

- (void)setCaptureVolume:(int)volume {
    if (g_audioBoost) {
        %orig(100); // 维持底层满幅
        return;
    }
    %orig(volume);
}

%end

// ==================== 3. TRTC 引擎底层 Hook ====================

%hook TRTCCloud

- (void)muteLocalAudio:(BOOL)mute {
    if (g_forceUnmute) {
        %orig(NO);
        return;
    }
    %orig(mute);
}

- (void)stopLocalAudio {
    if (g_forceUnmute) {
        return; // 阻止停止采集
    }
    %orig;
}

- (void)setAudioCaptureVolume:(NSInteger)volume {
    if (g_audioBoost) {
        %orig(100);
        return;
    }
    %orig(volume);
}

%end

// ==================== 4. 底层 AudioUnit / PCM 线性增益处理 ====================

// Hook AudioUnitRender 采集通道进行硬核数字放大 (压制平台音量关键)
static OSStatus (*orig_AudioUnitRender)(AudioUnit inUnit,
                                       AudioUnitRenderActionFlags *ioActionFlags,
                                       const AudioTimeStamp *inTimeStamp,
                                       UInt32 inOutputBusNumber,
                                       UInt32 inNumberFrames,
                                       AudioBufferList *ioData);

static OSStatus my_AudioUnitRender(AudioUnit inUnit,
                                   AudioUnitRenderActionFlags *ioActionFlags,
                                   const AudioTimeStamp *inTimeStamp,
                                   UInt32 inOutputBusNumber,
                                   UInt32 inNumberFrames,
                                   AudioBufferList *ioData) {
    OSStatus status = orig_AudioUnitRender(inUnit, ioActionFlags, inTimeStamp, inOutputBusNumber, inNumberFrames, ioData);

    if (status == noErr && g_audioBoost && ioData) {
        for (UInt32 i = 0; i < ioData->mNumberBuffers; i++) {
            AudioBuffer buffer = ioData->mBuffers[i];
            SInt16 *samples = (SInt16 *)buffer.mData;
            UInt32 sampleCount = buffer.mDataByteSize / sizeof(SInt16);

            for (UInt32 j = 0; j < sampleCount; j++) {
                float sampleVal = samples[j] * g_boostMultiplier;
                // 防止溢出爆音硬截断 (Soft Clipping)
                if (sampleVal > 32767.0f) sampleVal = 32767.0f;
                else if (sampleVal < -32768.0f) sampleVal = -32768.0f;
                samples[j] = (SInt16)sampleVal;
            }
        }
    }
    return status;
}

%ctor {
    // 动态查找 AudioUnit 符号并完成 Hook
    void *symbol = dlsym(RTLD_DEFAULT, "AudioUnitRender");
    if (symbol) {
        MSHookFunction(symbol, (void *)my_AudioUnitRender, (void **)&orig_AudioUnitRender);
    }
}

// ==================== 5. 手势唤起 ====================

%hook UIWindow
- (instancetype)initWithFrame:(CGRect)frame {
    id orig = %orig;
    if (orig) {
        UITapGestureRecognizer *doubleTap = [[UITapGestureRecognizer alloc]
            initWithTarget:[OverlayManager sharedInstance]
            action:@selector(togglePanel)];
        doubleTap.numberOfTouchesRequired = 2;
        doubleTap.numberOfTapsRequired = 2;
        [self addGestureRecognizer:doubleTap];
    }
    return orig;
}
%end
