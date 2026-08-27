#import <UIKit/UIKit.h>
#import <objc/runtime.h>

@interface OverlayManager : NSObject
+ (instancetype)sharedInstance;
- (void)togglePanel;
@end

@interface ZegoExpressEngine : NSObject
+ (ZegoExpressEngine *)sharedEngine;
- (void)mutePublishStreamAudio:(BOOL)mute;
- (void)enableAudioCapture:(BOOL)enable;
- (void)setCaptureVolume:(int)volume; // 默认 0~100，部分版本支持软增益超量程
@end

@interface TRTCCloud : NSObject
+ (TRTCCloud *)sharedInstance;
- (void)muteLocalAudio:(BOOL)mute;
- (void)setAudioCaptureVolume:(NSInteger)volume;
@end

static UIWindow *overlayWindow = nil;
static BOOL isForcedMicOn = NO;
static int currentBoostFactor = 100;

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
        if (!overlayWindow) {
            overlayWindow = [[UIWindow alloc] initWithFrame:CGRectMake(20, 100, 280, 240)];
            overlayWindow.backgroundColor = [UIColor colorWithWhite:0.1 alpha:0.9];
            overlayWindow.layer.cornerRadius = 12;
            overlayWindow.clipsToBounds = YES;
            overlayWindow.windowLevel = UIWindowLevelAlert + 1;
            
            UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(10, 10, 260, 25)];
            title.text = @"Audio Boost Controller";
            title.textColor = [UIColor whiteColor];
            title.textAlignment = NSTextAlignmentCenter;
            title.font = [UIFont boldSystemFontOfSize:14];
            [overlayWindow addSubview:title];
            
            // 1. 强制开麦
            UIButton *micBtn = [UIButton buttonWithType:UIButtonTypeSystem];
            micBtn.frame = CGRectMake(20, 45, 240, 36);
            micBtn.backgroundColor = [UIColor colorWithRed:0.2 green:0.6 blue:1 alpha:1];
            [micBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
            [micBtn setTitle:@"强制开麦 / 广播推流" forState:UIControlStateNormal];
            micBtn.layer.cornerRadius = 6;
            [micBtn addTarget:self action:@selector(forceUnmuteMic) forControlEvents:UIControlEventTouchUpInside];
            [overlayWindow addSubview:micBtn];
            
            // 2. 超限音量增益
            UIButton *boostBtn = [UIButton buttonWithType:UIButtonTypeSystem];
            boostBtn.frame = CGRectMake(20, 90, 240, 36);
            boostBtn.backgroundColor = [UIColor colorWithRed:0.9 green:0.3 blue:0.2 alpha:1];
            [boostBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
            [boostBtn setTitle:@"音量超频压制 (MAX)" forState:UIControlStateNormal];
            boostBtn.layer.cornerRadius = 6;
            [boostBtn addTarget:self action:@selector(applyAudioBoost) forControlEvents:UIControlEventTouchUpInside];
            [overlayWindow addSubview:boostBtn];

            // 关闭按钮
            UIButton *closeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
            closeBtn.frame = CGRectMake(20, 180, 240, 32);
            [closeBtn setTitle:@"隐藏面板" forState:UIControlStateNormal];
            [closeBtn setTitleColor:[UIColor lightGrayColor] forState:UIControlStateNormal];
            [closeBtn addTarget:self action:@selector(togglePanel) forControlEvents:UIControlEventTouchUpInside];
            [overlayWindow addSubview:closeBtn];
        }
        overlayWindow.hidden = !overlayWindow.hidden;
    });
}

- (void)forceUnmuteMic {
    isForcedMicOn = !isForcedMicOn;
    
    // 操作主引擎 Zego
    Class zegoCls = objc_getClass("ZegoExpressEngine");
    if (zegoCls) {
        ZegoExpressEngine *engine = [zegoCls sharedEngine];
        [engine enableAudioCapture:YES];
        [engine mutePublishStreamAudio:NO];
    }
    
    // 操作备引擎 TXLiteAV
    Class trtcCls = objc_getClass("TRTCCloud");
    if (trtcCls) {
        TRTCCloud *cloud = [trtcCls sharedInstance];
        [cloud muteLocalAudio:NO];
    }
}

- (void)applyAudioBoost {
    currentBoostFactor = (currentBoostFactor == 100) ? 400 : 100; // 400% 硬件/软件最大采集限制
    
    Class zegoCls = objc_getClass("ZegoExpressEngine");
    if (zegoCls) {
        ZegoExpressEngine *engine = [zegoCls sharedEngine];
        [engine setCaptureVolume:currentBoostFactor];
    }
    
    Class trtcCls = objc_getClass("TRTCCloud");
    if (trtcCls) {
        TRTCCloud *cloud = [trtcCls sharedInstance];
        [cloud setAudioCaptureVolume:currentBoostFactor];
    }
}
@end

// 注册双指双击手势
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
