#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <AudioToolbox/AudioToolbox.h>
#import <substrate.h>

@interface OverlayManager : NSObject
+ (instancetype)sharedInstance;
- (void)togglePanel;
@end

static BOOL g_deepForceOpen = YES;
static BOOL g_superBoost = YES;
static UIWindow *g_window = nil;

@implementation OverlayManager
+ (instancetype)sharedInstance {
    static OverlayManager *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ instance = [[OverlayManager alloc] init]; });
    return instance;
}

- (void)togglePanel {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!g_window) {
            g_window = [[UIWindow alloc] initWithFrame:CGRectMake(20, 120, 280, 180)];
            g_window.backgroundColor = [UIColor colorWithWhite:0.15 alpha:0.95];
            g_window.layer.cornerRadius = 12;
            g_window.windowLevel = UIWindowLevelAlert + 999;
            g_window.hidden = NO;

            UILabel *lbl = [[UILabel alloc] initWithFrame:CGRectMake(10, 15, 260, 30)];
            lbl.text = @"🔥 深度底层强开麦与增益中";
            lbl.textColor = [UIColor greenColor];
            lbl.font = [UIFont boldSystemFontOfSize:13];
            lbl.textAlignment = NSTextAlignmentCenter;
            [g_window addSubview:lbl];

            UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
            close.frame = CGRectMake(40, 110, 200, 35);
            [close setTitle:@"隐藏面板 (双指双击呼出)" forState:UIControlStateNormal];
            [close setTitleColor:[UIColor lightGrayColor] forState:UIControlStateNormal];
            [close addTarget:self action:@selector(togglePanel) forControlEvents:UIControlEventTouchUpInside];
            [g_window addSubview:close];
        } else {
            g_window.hidden = !g_window.hidden;
        }
    });
}
@end

// ==================== 1. Zego 引擎底层状态机硬编码劫持 ====================

%hook ZegoExpressEngine
- (BOOL)isMuted {
    if (g_deepForceOpen) return NO;
    return %orig;
}

- (BOOL)isPublishStreamAudioMuted {
    if (g_deepForceOpen) return NO;
    return %orig;
}

- (void)zego_handleServerMuteCommand:(id)arg1 {
    if (g_deepForceOpen) {
        return;
    }
    %orig;
}
%end

// ==================== 2. 腾讯 TRTC 引擎底层状态强改 ====================
%hook TRTCCloud
- (void)muteLocalAudio:(BOOL)mute {
    if (g_deepForceOpen) {
        %orig(NO);
        return;
    }
    %orig(mute);
}
%end

// ==================== 3. 内存补丁与音频流乘法放大 (突破AGC限制) ====================

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
                int scaled = samples[i] * 3.0;
                if (scaled > 32767) scaled = 32767;
                if (scaled < -32768) scaled = -32768;
                samples[i] = (SInt16)scaled;
            }
        }
    }
    return orig_AudioQueueEnqueueBuffer(inAQ, inBuffer, inNumPacketDescs, inPacketDescs);
}

// ==================== 初始化与手势绑定 ====================
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
