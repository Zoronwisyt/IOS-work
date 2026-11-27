// AlightMotionMods.mm
// Native iOS ARM64 tweak for Alight Motion 6.2.60 (build 869)
// 1. Preview Quality Button: Seamless white flat toolbar button next to playButton.
//    Single-tap ladder cycle: Full -> 1/2 -> 1/3 -> 1/4 -> Full.
//    Immediately re-renders paused frame via AVPlayer without pressing Play.
//    Wired to AMCompositor -> AMCompositorMetal (preview only; exports stay Full).
// 2. Open Alight Motion Link: Light compact pill in SettingsVC.
//    Supports direct sign-in-free Firebase Storage `projectfiles.zip` download for
//    any alightcreative.com/am/share/u/<uid>/p/<pid> or alight.link URL (even >100MB),
//    plus native dispatch (with client sign-in/size gates bypassed).
// 3. Custom Effect Category & XML Effects Importer: dedicated `Custom` effect
//    category bar in Effects (injected into EffectCategory.all) with `+` button
//    inside Effects -> Custom. Creates each custom effect with a unique
//    `com.alightcreative.effects.custom_*` ID and `category="custom"` (auto-wraps
//    raw GLSL or normalizes `<effect>` XML, strips hidden flags, migrates prior
//    `category="other"` custom XMLs, and renders custom PNG thumbnails).

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <Metal/Metal.h>
#import <os/lock.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <math.h>
#import <stdint.h>
#import <stdlib.h>
#import <dlfcn.h>
#import <sys/xattr.h>
#import <mach-o/dyld.h>

static NSString *const kAMPreviewQualityKey = @"AMModPreviewQualityDivisor";
static NSInteger gPreviewDivisor = 1; // 1=Full, 2=Half, 3=Third, 4=Quarter

static __weak AVPlayer *gActivePreviewPlayer = nil;
static IMP gOrigReplaceCurrentItem = NULL;
static IMP gOrigInitWithPlayerItem = NULL;
static IMP gOrigGTMBeginFetch = NULL;
static IMP gOrigFIRCallableResultData = NULL;

// ============================================================================
// Theme Helpers
// ============================================================================

static UIColor *AMBgColor(void) {
    return [UIColor colorWithRed:0.141 green:0.149 blue:0.212 alpha:1.0];
}

static UIColor *AMSurfaceColor(void) {
    return [UIColor colorWithRed:0.180 green:0.192 blue:0.271 alpha:1.0];
}

static UIColor *AMInputSurfaceColor(void) {
    return [UIColor colorWithRed:0.114 green:0.122 blue:0.176 alpha:1.0];
}

static UIColor *AMCircleBtnColor(void) {
    return [UIColor colorWithRed:0.243 green:0.255 blue:0.345 alpha:0.85];
}

static UIColor *AMBorderColor(void) {
    return [UIColor colorWithWhite:1.0 alpha:0.15];
}

static UIColor *AMAccentGreenColor(void) {
    return [UIColor colorWithRed:0.204 green:0.827 blue:0.600 alpha:1.0];
}

static UIColor *AMSettingsPillColor(void) {
    return [UIColor colorWithRed:0.918 green:0.922 blue:0.933 alpha:1.0]; // #EAEBF0
}

static UIColor *AMSettingsTextColor(void) {
    return [UIColor colorWithRed:0.09 green:0.10 blue:0.14 alpha:1.0];
}

static UIFont *AMThemeFont(CGFloat size, UIFontWeight weight) {
    UIFont *sg = nil;
    if (weight >= UIFontWeightSemibold) {
        sg = [UIFont fontWithName:@"SpaceGrotesk-Bold" size:size];
    }
    if (!sg) sg = [UIFont fontWithName:@"SpaceGrotesk-Medium" size:size];
    if (!sg) sg = [UIFont systemFontOfSize:size weight:weight];
    return sg;
}

static NSString *AMLabelForDivisor(NSInteger d) {
    switch (d) {
        case 2: return @"1/2";
        case 3: return @"1/3";
        case 4: return @"1/4";
        default: return @"Full";
    }
}

// ============================================================================
// Module 1: Preview Quality Engine Hook + Immediate Paused-Frame Refresh
// ============================================================================

static BOOL AMItemUsesAMCompositor(AVPlayerItem *item) {
    if (!item) return NO;
    AVVideoComposition *vc = item.videoComposition;
    if (!vc) return NO;
    Class compCls = NSClassFromString(@"_TtC12AlightMotion12AMCompositor");
    return (compCls != Nil && vc.customVideoCompositorClass == compCls);
}

static BOOL gAMIntroActive = NO;

static void AMTrackPlayerIfPreview(AVPlayer *player, AVPlayerItem *item) {
    if (!player || gAMIntroActive) return;
    if (AMItemUsesAMCompositor(item)) {
        item.audioTimePitchAlgorithm = AVAudioTimePitchAlgorithmVarispeed;
    }
    if (AMItemUsesAMCompositor(item) || AMItemUsesAMCompositor(player.currentItem)) {
        gActivePreviewPlayer = player;
    } else if (item && gActivePreviewPlayer == nil) {
        gActivePreviewPlayer = player;
    }
}

static void AMHook_replaceCurrentItem(id self, SEL _cmd, AVPlayerItem *item) {
    if (gOrigReplaceCurrentItem) {
        ((void (*)(id, SEL, AVPlayerItem *))gOrigReplaceCurrentItem)(self, _cmd, item);
    }
    AMTrackPlayerIfPreview((AVPlayer *)self, item);
}

static id AMHook_initWithPlayerItem(id self, SEL _cmd, AVPlayerItem *item) {
    id res = self;
    if (gOrigInitWithPlayerItem) {
        res = ((id (*)(id, SEL, AVPlayerItem *))gOrigInitWithPlayerItem)(self, _cmd, item);
    }
    if (res) {
        AMTrackPlayerIfPreview((AVPlayer *)res, item);
    }
    return res;
}

static void AMForceImmediatePreviewRedraw(void) {
    AVPlayer *player = gActivePreviewPlayer;
    if (!player) return;
    AVPlayerItem *item = player.currentItem;
    if (!item) return;

    AVVideoComposition *vc = item.videoComposition;
    if (vc) {
        AVVideoComposition *copied = [vc copy];
        if (copied) {
            item.videoComposition = copied;
        }
    }
    if (player.rate == 0.0f) {
        CMTime cur = player.currentTime;
        if (CMTIME_IS_NUMERIC(cur)) {
            [player seekToTime:cur toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero];
        }
    }
}

static BOOL gAMLiveRedrawInFlight = NO;
static BOOL gAMLiveRedrawPending = NO;
static uint64_t gAMLiveRedrawSeq = 0;

static void AMRequestCoalescedPreviewRedraw(void) {
    AVPlayer *player = gActivePreviewPlayer;
    if (!player) return;
    AVPlayerItem *item = player.currentItem;
    if (!item) return;

    // If playing, AVPlayer already pulls new frames continuously (no seek needed).
    if (player.rate != 0.0f) return;

    if (gAMLiveRedrawInFlight) {
        gAMLiveRedrawPending = YES;
        return;
    }

    gAMLiveRedrawInFlight = YES;
    gAMLiveRedrawPending = NO;
    uint64_t seq = ++gAMLiveRedrawSeq;

    AVVideoComposition *vc = item.videoComposition;
    if (vc) {
        AVVideoComposition *copied = [vc copy];
        if (copied) {
            item.videoComposition = copied;
        }
    }

    CMTime cur = player.currentTime;
    if (!CMTIME_IS_NUMERIC(cur)) {
        gAMLiveRedrawInFlight = NO;
        return;
    }

    // Safety timeout so in-flight gate can never stall if AVPlayer drops a callback
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(120 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
        if (gAMLiveRedrawInFlight && gAMLiveRedrawSeq == seq) {
            gAMLiveRedrawInFlight = NO;
            if (gAMLiveRedrawPending) {
                gAMLiveRedrawPending = NO;
                AMRequestCoalescedPreviewRedraw();
            }
        }
    });

    [player seekToTime:cur
       toleranceBefore:kCMTimeZero
        toleranceAfter:kCMTimeZero
     completionHandler:^(BOOL finished) {
        (void)finished;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (gAMLiveRedrawSeq != seq) return;
            gAMLiveRedrawInFlight = NO;
            if (gAMLiveRedrawPending) {
                gAMLiveRedrawPending = NO;
                AMRequestCoalescedPreviewRedraw();
            }
        });
    }];
}

static IMP gOrigStartVideoCompReq = NULL;
static ptrdiff_t gCompImplOffset = -1;
static ptrdiff_t gDynaResOffset = -1;
static ptrdiff_t gAccumValOffset = -1;
static Class gCompositorMetalClass = Nil;

static void AMResolveCompositorOffsets(Class compClass) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Ivar compImplIvar = class_getInstanceVariable(compClass, "compImpl");
        if (compImplIvar) gCompImplOffset = ivar_getOffset(compImplIvar);
        gCompositorMetalClass = NSClassFromString(@"_TtC12AlightMotion17AMCompositorMetal");
        if (gCompositorMetalClass) {
            Ivar dynaIvar = class_getInstanceVariable(gCompositorMetalClass, "dynaResMode");
            Ivar accumIvar = class_getInstanceVariable(gCompositorMetalClass, "accumVal");
            if (dynaIvar) gDynaResOffset = ivar_getOffset(dynaIvar);
            if (accumIvar) gAccumValOffset = ivar_getOffset(accumIvar);
        }
    });
}

static void AMHook_startVideoCompositionRequest(id self, SEL _cmd, id request) {
    AMResolveCompositorOffsets(object_getClass(self));
    if (gCompImplOffset >= 0 && gDynaResOffset >= 0 && gAccumValOffset >= 0 && gCompositorMetalClass != Nil) {
        void *compImplPtr = *(void **)((uint8_t *)(__bridge void *)self + gCompImplOffset);
        if (compImplPtr != NULL) {
            id compObj = (__bridge id)compImplPtr;
            if (object_getClass(compObj) == gCompositorMetalClass) {
                NSInteger div = gPreviewDivisor;
                if (div < 1 || div > 4) div = 1;
                uint8_t *base = (uint8_t *)compImplPtr;
                *(uint8_t *)(base + gDynaResOffset) = (div > 1) ? 1 : 0;
                *(int64_t *)(base + gAccumValOffset) = (int64_t)div;
            }
        }
    }
    if (gOrigStartVideoCompReq) {
        ((void (*)(id, SEL, id))gOrigStartVideoCompReq)(self, _cmd, request);
    }
}

static IMP gOrigPreviewControlBarViewDidLoad = NULL;
static const void *kAMQualityButtonAssocKey = &kAMQualityButtonAssocKey;

@interface AMPreviewQualityHelper : NSObject
+ (void)styleQualityButton:(UIButton *)btn;
+ (void)cycleQuality:(UIButton *)btn;
@end

@implementation AMPreviewQualityHelper

+ (void)styleQualityButton:(UIButton *)btn {
    NSString *title = AMLabelForDivisor(gPreviewDivisor);
    [UIView performWithoutAnimation:^{
        [btn setTitle:title forState:UIControlStateNormal];
        [btn layoutIfNeeded];
    }];
    [btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [btn setTitleColor:[UIColor colorWithWhite:1.0 alpha:0.55] forState:UIControlStateHighlighted];
    btn.titleLabel.font = AMThemeFont(13.0, UIFontWeightSemibold);
    btn.backgroundColor = [UIColor clearColor];
    btn.layer.borderWidth = 0.0;
    btn.layer.cornerRadius = 0.0;
    btn.tintColor = [UIColor whiteColor];
}

+ (void)cycleQuality:(UIButton *)btn {
    gPreviewDivisor = (gPreviewDivisor % 4) + 1;
    [[NSUserDefaults standardUserDefaults] setInteger:gPreviewDivisor forKey:kAMPreviewQualityKey];
    [self styleQualityButton:btn];
    AMForceImmediatePreviewRedraw();
    UIImpactFeedbackGenerator *haptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [haptic impactOccurred];
}

@end

static void AMHook_previewControlBarViewDidLoad(id self, SEL _cmd) {
    if (gOrigPreviewControlBarViewDidLoad) {
        ((void (*)(id, SEL))gOrigPreviewControlBarViewDidLoad)(self, _cmd);
    }
    if (objc_getAssociatedObject(self, kAMQualityButtonAssocKey) != nil) return;

    UIButton *playBtn = nil;
    UIStackView *stack = nil;
    SEL playSel = NSSelectorFromString(@"playButton");
    SEL stackSel = NSSelectorFromString(@"stackView");
    if ([self respondsToSelector:playSel]) playBtn = ((UIButton *(*)(id, SEL))objc_msgSend)(self, playSel);
    if ([self respondsToSelector:stackSel]) stack = ((UIStackView *(*)(id, SEL))objc_msgSend)(self, stackSel);
    if (!playBtn) return;

    UIButton *qBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    qBtn.translatesAutoresizingMaskIntoConstraints = NO;
    qBtn.accessibilityLabel = @"Preview Quality";
    [AMPreviewQualityHelper styleQualityButton:qBtn];
    [qBtn addTarget:[AMPreviewQualityHelper class]
             action:@selector(cycleQuality:)
   forControlEvents:UIControlEventTouchUpInside];

    [NSLayoutConstraint activateConstraints:@[
        [qBtn.widthAnchor constraintGreaterThanOrEqualToConstant:34.0],
        [qBtn.heightAnchor constraintEqualToConstant:30.0],
    ]];

    if (stack && [stack.arrangedSubviews containsObject:playBtn]) {
        NSUInteger idx = [stack.arrangedSubviews indexOfObject:playBtn];
        [stack insertArrangedSubview:qBtn atIndex:idx + 1];
    } else if (playBtn.superview) {
        [playBtn.superview addSubview:qBtn];
        [NSLayoutConstraint activateConstraints:@[
            [qBtn.leadingAnchor constraintEqualToAnchor:playBtn.trailingAnchor constant:6.0],
            [qBtn.centerYAnchor constraintEqualToAnchor:playBtn.centerYAnchor],
        ]];
    }

    objc_setAssociatedObject(self, kAMQualityButtonAssocKey, qBtn, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// ============================================================================
// Module 2A: Fix `getProjectMetadata` INTERNAL / sub-required-size via GTMSessionFetcher
// ============================================================================
// FirebaseFunctions & FirebaseStorage use GTMSessionFetcher (`beginFetchWithCompletionHandler:`),
// not `NSURLSession dataTaskWithRequest:completionHandler:`. On sideloaded IPAs, invalid
// AppCheck / Auth headers cause `getProjectMetadata` to fail with `INTERNAL`.

static id AMHook_firCallableResultData(id self, SEL _cmd) {
    id res = gOrigFIRCallableResultData ? ((id (*)(id, SEL))gOrigFIRCallableResultData)(self, _cmd) : nil;
    if ([res isKindOfClass:[NSDictionary class]]) {
        NSDictionary *d = (NSDictionary *)res;
        id dl = d[@"download"];
        if ([dl isKindOfClass:[NSString class]] && ![(NSString *)dl isEqualToString:@"allowed"]) {
            NSMutableDictionary *mut = [d mutableCopy];
            mut[@"download"] = @"allowed";
            mut[@"message"] = [NSNull null];
            if ([mut[@"info"] isKindOfClass:[NSDictionary class]]) {
                NSMutableDictionary *info = [mut[@"info"] mutableCopy];
                info[@"size"] = @(1000000);
                mut[@"info"] = info;
            }
            return mut;
        }
    }
    return res;
}

static NSData *AMRewriteProjectMetadataJSON(NSData *data) {
    if (data.length == 0) return data;
    id obj = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:nil];
    if ([obj isKindOfClass:[NSMutableDictionary class]]) {
        NSMutableDictionary *root = (NSMutableDictionary *)obj;
        NSMutableDictionary *res = [root[@"result"] isKindOfClass:[NSMutableDictionary class]] ? root[@"result"] : nil;
        if (res && [res[@"result"] isEqualToString:@"success"]) {
            res[@"download"] = @"allowed";
            res[@"message"] = [NSNull null];
            NSMutableDictionary *info = [res[@"info"] isKindOfClass:[NSMutableDictionary class]] ? res[@"info"] : nil;
            if (info) {
                info[@"size"] = @(1000000);
            }
            NSData *reencoded = [NSJSONSerialization dataWithJSONObject:root options:0 error:nil];
            if (reencoded) return reencoded;
        }
    }
    return data;
}

static void AMClearFetcherAuthHeaders(id fetcher) {
    SEL setHdrSel = NSSelectorFromString(@"setRequestValue:forHTTPHeaderField:");
    if (![fetcher respondsToSelector:setHdrSel]) return;
    ((void (*)(id, SEL, NSString *, NSString *))objc_msgSend)(fetcher, setHdrSel, nil, @"Authorization");
    ((void (*)(id, SEL, NSString *, NSString *))objc_msgSend)(fetcher, setHdrSel, nil, @"X-Firebase-AppCheck");
    ((void (*)(id, SEL, NSString *, NSString *))objc_msgSend)(fetcher, setHdrSel, nil, @"Firebase-Instance-ID-Token");
}

static NSData *AMSynthesizeProjectDownloadJSON(NSData *reqBody) {
    if (reqBody.length == 0) return nil;
    id obj = [NSJSONSerialization JSONObjectWithData:reqBody options:0 error:nil];
    if (![obj isKindOfClass:[NSDictionary class]]) return nil;
    NSDictionary *root = (NSDictionary *)obj;
    NSDictionary *d = [root[@"data"] isKindOfClass:[NSDictionary class]] ? root[@"data"] : root;
    NSString *uid = [d[@"uid"] isKindOfClass:[NSString class]] ? d[@"uid"] : nil;
    NSString *pid = [d[@"pid"] isKindOfClass:[NSString class]] ? d[@"pid"] : nil;
    if (uid.length == 0 || pid.length == 0) return nil;
    BOOL lite = [d[@"liteVersion"] respondsToSelector:@selector(boolValue)] ? [d[@"liteVersion"] boolValue] : NO;
    NSString *fileName = lite ? @"projectfiles-lite.zip" : @"projectfiles.zip";
    NSString *storagePath = [NSString stringWithFormat:@"share/u/%@/p/%@/%@", uid, pid, fileName];
    NSDictionary *synth = @{
        @"result": @{
            @"result": @"success",
            @"downloadUri": storagePath
        }
    };
    return [NSJSONSerialization dataWithJSONObject:synth options:0 error:nil];
}

static BOOL AMResponseHasValidDownloadUri(NSData *data) {
    if (data.length == 0) return NO;
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![obj isKindOfClass:[NSDictionary class]]) return NO;
    NSDictionary *res = [obj[@"result"] isKindOfClass:[NSDictionary class]] ? obj[@"result"] : nil;
    NSString *uri = [res[@"downloadUri"] isKindOfClass:[NSString class]] ? res[@"downloadUri"] : nil;
    return uri.length > 0;
}

static void AMHook_gtmBeginFetchWithCompletionHandler(id self, SEL _cmd, void (^handler)(NSData * _Nullable, NSError * _Nullable)) {
    NSURLRequest *req = nil;
    SEL reqSel = NSSelectorFromString(@"request");
    if ([self respondsToSelector:reqSel]) {
        req = ((NSURLRequest *(*)(id, SEL))objc_msgSend)(self, reqSel);
    }
    NSString *urlStr = req.URL.absoluteString ?: @"";

    if ([urlStr containsString:@"/getProjectMetadata"] && handler != nil) {
        AMClearFetcherAuthHeaders(self);
        void (^wrapped)(NSData * _Nullable, NSError * _Nullable) = ^(NSData * _Nullable data, NSError * _Nullable err) {
            NSData *patched = (!err && data.length > 0) ? AMRewriteProjectMetadataJSON(data) : data;
            handler(patched, err);
        };
        if (gOrigGTMBeginFetch) {
            ((void (*)(id, SEL, id))gOrigGTMBeginFetch)(self, _cmd, wrapped);
        }
        return;
    }

    if ([urlStr containsString:@"/requestProjectDownload"] && handler != nil) {
        NSData *reqBody = nil;
        SEL bodySel = NSSelectorFromString(@"bodyData");
        if ([self respondsToSelector:bodySel]) {
            reqBody = ((NSData *(*)(id, SEL))objc_msgSend)(self, bodySel);
        }
        if (reqBody.length == 0) {
            reqBody = req.HTTPBody;
        }
        NSData *fallbackData = AMSynthesizeProjectDownloadJSON(reqBody);
        AMClearFetcherAuthHeaders(self);
        void (^wrapped)(NSData * _Nullable, NSError * _Nullable) = ^(NSData * _Nullable data, NSError * _Nullable err) {
            if (!err && AMResponseHasValidDownloadUri(data)) {
                handler(data, nil);
                return;
            }
            if (fallbackData.length > 0) {
                handler(fallbackData, nil);
                return;
            }
            handler(data, err);
        };
        if (gOrigGTMBeginFetch) {
            ((void (*)(id, SEL, id))gOrigGTMBeginFetch)(self, _cmd, wrapped);
        }
        return;
    }

    if ([urlStr containsString:@"firebasestorage.googleapis.com"] && [urlStr containsString:@"projectfiles"]) {
        AMClearFetcherAuthHeaders(self);
    }

    if (gOrigGTMBeginFetch) {
        ((void (*)(id, SEL, id))gOrigGTMBeginFetch)(self, _cmd, handler);
    }
}

// ============================================================================
// Module 2: Open Alight Link inside SettingsVC (Sign-in-Free Share Download)
// ============================================================================

static IMP gOrigSettingsVCViewDidLoad = NULL;
static const void *kAMSettingsLinkBtnKey = &kAMSettingsLinkBtnKey;

static void AMDispatchAlightLink(NSURL *url) {
    if (!url) return;
    UIApplication *app = [UIApplication sharedApplication];
    id<UIApplicationDelegate> del = app.delegate;
    if (!del) return;

    NSString *scheme = url.scheme.lowercaseString;
    BOOL handled = NO;

    if ([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"]) {
        SEL uaSel = @selector(application:continueUserActivity:restorationHandler:);
        if ([del respondsToSelector:uaSel]) {
            NSUserActivity *ua = [[NSUserActivity alloc] initWithActivityType:NSUserActivityTypeBrowsingWeb];
            ua.webpageURL = url;
            handled = [del application:app
                  continueUserActivity:ua
                    restorationHandler:^(NSArray<id<UIUserActivityRestoring>> * _Nullable restorableObjects) {
                        (void)restorableObjects;
                    }];
        }
    }

    if (!handled) {
        SEL openSel = @selector(application:openURL:options:);
        if ([del respondsToSelector:openSel]) {
            [del application:app openURL:url options:@{}];
        }
    }
}

static void AMOpenLocalFileInApp(NSURL *fileURL) {
    if (!fileURL) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIApplication *app = [UIApplication sharedApplication];
        id<UIApplicationDelegate> del = app.delegate;
        if (del && [del respondsToSelector:@selector(application:openURL:options:)]) {
            [del application:app openURL:fileURL options:@{}];
        }
    });
}

static NSURL *AMNormalizeAlightLink(NSString *raw) {
    if (!raw) return nil;
    NSString *s = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (s.length == 0) return nil;
    if (![s containsString:@"://"]) {
        s = [@"https://" stringByAppendingString:s];
    }
    return [NSURL URLWithString:s];
}

// Extracts direct public Firebase Storage projectfiles.zip URL from an Alight Motion share URL:
//   https://alightcreative.com/am/share/u/<UID>/p/<PID>
// -> https://firebasestorage.googleapis.com/v0/b/alight-creative.appspot.com/o/share%2Fu%2F<UID>%2Fp%2F<PID>%2Fprojectfiles.zip?alt=media
static NSURL *AMFirebasePackageURLFromShareString(NSString *urlString) {
    if (urlString.length == 0) return nil;
    NSRegularExpression *rx = [NSRegularExpression regularExpressionWithPattern:@"/share/u/([^/?#&]+)/p/([^/?#&]+)"
                                                                        options:NSRegularExpressionCaseInsensitive
                                                                          error:nil];
    NSTextCheckingResult *m = [rx firstMatchInString:urlString options:0 range:NSMakeRange(0, urlString.length)];
    if (!m || m.numberOfRanges < 3) return nil;
    NSString *uid = [urlString substringWithRange:[m rangeAtIndex:1]];
    NSString *pid = [urlString substringWithRange:[m rangeAtIndex:2]];
    NSString *fb = [NSString stringWithFormat:
        @"https://firebasestorage.googleapis.com/v0/b/alight-creative.appspot.com/o/share%%2Fu%%2F%@%%2Fp%%2F%@%%2Fprojectfiles.zip?alt=media",
        uid, pid];
    return [NSURL URLWithString:fb];
}

static NSURL *AMProxyURLForTarget(NSString *targetURLString) {
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~"];
    NSString *enc = [targetURLString stringByAddingPercentEncodingWithAllowedCharacters:allowed];
    if (!enc) return nil;
    return [NSURL URLWithString:[@"https://am-proxy.zoronwisyt.workers.dev/?url=" stringByAppendingString:enc]];
}

static void AMDownloadProjectFileDirect(NSURL *downloadURL, void (^completion)(NSURL * _Nullable localFile, NSError * _Nullable err)) {
    if (!downloadURL) {
        completion(nil, [NSError errorWithDomain:@"AMLinkImport" code:1 userInfo:@{NSLocalizedDescriptionKey: @"Invalid download URL."}]);
        return;
    }
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:downloadURL cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:120.0];
    [req setValue:@"AlightMotion/6.2.60" forHTTPHeaderField:@"User-Agent"];

    NSURLSessionDownloadTask *task = [[NSURLSession sharedSession] downloadTaskWithRequest:req
        completionHandler:^(NSURL * _Nullable location, NSURLResponse * _Nullable response, NSError * _Nullable error) {
            NSHTTPURLResponse *http = [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)response : nil;
            if (error || !location || (http && http.statusCode >= 400)) {
                completion(nil, error ?: [NSError errorWithDomain:@"AMLinkImport" code:(http ? http.statusCode : 500)
                                                         userInfo:@{NSLocalizedDescriptionKey: @"Download failed."}]);
                return;
            }
            // Peek first 4 bytes to verify ZIP (.amproj) or XML
            NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:location.path];
            NSData *head = [fh readDataOfLength:256];
            [fh closeFile];
            if (head.length < 4) {
                completion(nil, [NSError errorWithDomain:@"AMLinkImport" code:2 userInfo:@{NSLocalizedDescriptionKey: @"Empty file."}]);
                return;
            }
            const uint8_t *b = (const uint8_t *)head.bytes;
            BOOL isZip = (b[0] == 'P' && b[1] == 'K' && b[2] == 0x03 && b[3] == 0x04);
            NSString *prefix = [[NSString alloc] initWithData:head encoding:NSUTF8StringEncoding];
            BOOL isXML = (prefix && ([prefix containsString:@"<scene"] || [prefix containsString:@"<effect"] || [prefix containsString:@"<?xml"]));
            if (!isZip && !isXML) {
                completion(nil, [NSError errorWithDomain:@"AMLinkImport" code:3 userInfo:@{NSLocalizedDescriptionKey: @"Not a valid .amproj or .xml file."}]);
                return;
            }
            NSString *ext = isZip ? @"amproj" : @"xml";
            NSString *dest = [NSTemporaryDirectory() stringByAppendingPathComponent:
                              [NSString stringWithFormat:@"AMImport_%lld.%@", (long long)[[NSDate date] timeIntervalSince1970], ext]];
            [[NSFileManager defaultManager] removeItemAtPath:dest error:nil];
            NSError *merr = nil;
            if ([[NSFileManager defaultManager] moveItemAtURL:location toURL:[NSURL fileURLWithPath:dest] error:&merr]) {
                completion([NSURL fileURLWithPath:dest], nil);
            } else {
                completion(nil, merr);
            }
        }];
    [task resume];
}

static void AMResolveAndDirectDownload(NSURL *origURL, void (^completion)(NSURL * _Nullable localFile, NSError * _Nullable err)) {
    // 1. Direct alightcreative.com/am/share/u/<uid>/p/<pid> link -> Firebase Storage projectfiles.zip (no auth!)
    NSURL *fbDirect = AMFirebasePackageURLFromShareString(origURL.absoluteString);
    if (fbDirect) {
        AMDownloadProjectFileDirect(fbDirect, completion);
        return;
    }

    // 2. Short link (alight.link) or direct .amproj/.xml -> resolve via Cloudflare proxy first
    NSURL *proxyURL = AMProxyURLForTarget(origURL.absoluteString);
    if (!proxyURL) {
        completion(nil, [NSError errorWithDomain:@"AMLinkImport" code:4 userInfo:@{NSLocalizedDescriptionKey: @"Invalid URL."}]);
        return;
    }
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:proxyURL cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:25.0];
    [req setValue:@"AlightMotion/6.2.60" forHTTPHeaderField:@"User-Agent"];
    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable resp, NSError * _Nullable err) {
        if (err || data.length < 4) {
            completion(nil, err ?: [NSError errorWithDomain:@"AMLinkImport" code:5 userInfo:@{NSLocalizedDescriptionKey: @"Proxy failed."}]);
            return;
        }
        // Check if proxy redirected to share/u/.../p/...
        if (resp.URL) {
            NSURL *fb = AMFirebasePackageURLFromShareString(resp.URL.absoluteString);
            if (fb) { AMDownloadProjectFileDirect(fb, completion); return; }
        }
        const uint8_t *b = (const uint8_t *)data.bytes;
        BOOL isZip = (b[0] == 'P' && b[1] == 'K' && b[2] == 0x03 && b[3] == 0x04);
        NSString *body = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if (isZip || (body && ([body containsString:@"<scene"] || [body containsString:@"<effect"]))) {
            NSString *ext = isZip ? @"amproj" : @"xml";
            NSString *dest = [NSTemporaryDirectory() stringByAppendingPathComponent:
                              [NSString stringWithFormat:@"AMImport_%lld.%@", (long long)[[NSDate date] timeIntervalSince1970], ext]];
            if ([data writeToFile:dest atomically:YES]) {
                completion([NSURL fileURLWithPath:dest], nil);
                return;
            }
        }
        // Look for share/u/<uid>/p/<pid> embedded inside HTML/redirect page
        if (body) {
            NSURL *fb = AMFirebasePackageURLFromShareString(body);
            if (fb) { AMDownloadProjectFileDirect(fb, completion); return; }
        }
        completion(nil, [NSError errorWithDomain:@"AMLinkImport" code:6 userInfo:@{NSLocalizedDescriptionKey: @"Could not resolve project package."}]);
    }] resume];
}

static void AMHandleUserLinkFromVC(UIViewController *vc, NSURL *u, BOOL directBypass) {
    (void)directBypass;
    if (!u) return;

    // If short link (e.g. alight.link), resolve canonical alightcreative.com/am/share/... URL via proxy,
    // then hand the real share URL to Alight Motion's native Universal Link importer (with sign-in/size gates patched).
    NSString *host = u.host.lowercaseString ?: @"";
    if ([host containsString:@"alight.link"] || [host containsString:@"page.link"]) {
        UIAlertController *loading = [UIAlertController alertControllerWithTitle:@"Resolving Link..."
                                                                         message:@"Opening project link..."
                                                                  preferredStyle:UIAlertControllerStyleAlert];
        [vc presentViewController:loading animated:YES completion:^{
            NSURL *proxyURL = AMProxyURLForTarget(u.absoluteString);
            NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:proxyURL cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:15.0];
            [req setValue:@"AlightMotion/6.2.60" forHTTPHeaderField:@"User-Agent"];
            [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable resp, NSError * _Nullable err) {
                (void)err;
                NSURL *resolved = u;
                NSString *body = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
                if (resp.URL && [resp.URL.absoluteString containsString:@"/share/u/"]) {
                    resolved = resp.URL;
                } else if (body) {
                    NSRegularExpression *rx = [NSRegularExpression regularExpressionWithPattern:@"https://alightcreative\\.com/am/share/u/[^\"'\\s<>]+"
                                                                                        options:NSRegularExpressionCaseInsensitive
                                                                                          error:nil];
                    NSTextCheckingResult *m = [rx firstMatchInString:body options:0 range:NSMakeRange(0, body.length)];
                    if (m && m.range.location != NSNotFound) {
                        NSURL *parsed = [NSURL URLWithString:[body substringWithRange:m.range]];
                        if (parsed) resolved = parsed;
                    }
                }
                dispatch_async(dispatch_get_main_queue(), ^{
                    [loading dismissViewControllerAnimated:YES completion:^{
                        UIViewController *presenter = vc.presentingViewController;
                        if (presenter) {
                            [vc dismissViewControllerAnimated:YES completion:^{ AMDispatchAlightLink(resolved); }];
                        } else {
                            AMDispatchAlightLink(resolved);
                        }
                    }];
                });
            }] resume];
        }];
        return;
    }

    UIViewController *presenter = vc.presentingViewController;
    if (presenter) {
        [vc dismissViewControllerAnimated:YES completion:^{
            AMDispatchAlightLink(u);
        }];
    } else {
        AMDispatchAlightLink(u);
    }
}

@interface AMSettingsLinkHandler : NSObject
+ (void)onTapOpenLink:(UIButton *)btn;
@end

@implementation AMSettingsLinkHandler

+ (void)onTapOpenLink:(UIButton *)btn {
    UIViewController *vc = objc_getAssociatedObject(btn, kAMSettingsLinkBtnKey);
    if (!vc) return;

    NSString *clip = [UIPasteboard generalPasteboard].string ?: @"";
    NSString *trimmedClip = [clip stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    BOOL clipLooksLikeLink = ([trimmedClip localizedCaseInsensitiveContainsString:@"alight.link"] ||
                              [trimmedClip localizedCaseInsensitiveContainsString:@"alightmotion"] ||
                              [trimmedClip localizedCaseInsensitiveContainsString:@"alightcreative"]);

    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Open Alight Link"
                                                                message:@"Paste an alightcreative.com or alight.link URL. Imports directly without sign-in."
                                                         preferredStyle:UIAlertControllerStyleAlert];
    [ac addTextFieldWithConfigurationHandler:^(UITextField * _Nonnull tf) {
        tf.placeholder = @"https://alightcreative.com/am/share/...";
        tf.keyboardType = UIKeyboardTypeURL;
        tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
        tf.autocorrectionType = UITextAutocorrectionTypeNo;
        tf.clearButtonMode = UITextFieldViewModeWhileEditing;
        if (clipLooksLikeLink) {
            tf.text = trimmedClip;
        }
    }];

    [ac addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [ac addAction:[UIAlertAction actionWithTitle:@"Paste & Import" style:UIAlertActionStyleDefault handler:^(__kindof UIAlertAction * _Nonnull a) {
        (void)a;
        NSURL *u = AMNormalizeAlightLink([UIPasteboard generalPasteboard].string);
        AMHandleUserLinkFromVC(vc, u, YES);
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"Import Link" style:UIAlertActionStyleDefault handler:^(__kindof UIAlertAction * _Nonnull a) {
        (void)a;
        NSURL *u = AMNormalizeAlightLink(ac.textFields.firstObject.text);
        AMHandleUserLinkFromVC(vc, u, YES);
    }]];

    [vc presentViewController:ac animated:YES completion:nil];
}

@end

static void AMHook_settingsVCViewDidLoad(id self, SEL _cmd) {
    if (gOrigSettingsVCViewDidLoad) {
        ((void (*)(id, SEL))gOrigSettingsVCViewDidLoad)(self, _cmd);
    }

    UIViewController *vc = (UIViewController *)self;
    if (objc_getAssociatedObject(vc, kAMSettingsLinkBtnKey) != nil) return;

    UITableView *tv = nil;
    SEL tvSel = NSSelectorFromString(@"sTableView");
    if ([self respondsToSelector:tvSel]) {
        tv = ((UITableView *(*)(id, SEL))objc_msgSend)(self, tvSel);
    }
    if (!tv) return;

    CGFloat w = tv.bounds.size.width > 0 ? tv.bounds.size.width : 280.0;
    UIView *existingHdr = tv.tableHeaderView;
    CGFloat existingH = existingHdr ? existingHdr.frame.size.height : 0.0;
    CGFloat pillContainerH = 50.0;

    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, existingH + pillContainerH)];
    header.backgroundColor = [UIColor clearColor];

    if (existingHdr) {
        existingHdr.frame = CGRectMake(0, 0, w, existingH);
        existingHdr.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        [header addSubview:existingHdr];
    }

    UIButton *pill = [UIButton buttonWithType:UIButtonTypeSystem];
    pill.translatesAutoresizingMaskIntoConstraints = NO;
    pill.backgroundColor = AMSettingsPillColor();
    pill.layer.cornerRadius = 14.0;
    pill.clipsToBounds = YES;
    [header addSubview:pill];

    UILabel *lbl = [[UILabel alloc] init];
    lbl.translatesAutoresizingMaskIntoConstraints = NO;
    lbl.text = @"Open Alight Link";
    lbl.font = AMThemeFont(14.0, UIFontWeightMedium);
    lbl.textColor = AMSettingsTextColor();
    lbl.userInteractionEnabled = NO;
    [pill addSubview:lbl];

    UIImageView *icon = [[UIImageView alloc] init];
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    icon.userInteractionEnabled = NO;
    if (@available(iOS 13.0, *)) {
        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:13.0 weight:UIImageSymbolWeightMedium];
        icon.image = [UIImage systemImageNamed:@"link" withConfiguration:cfg];
    }
    icon.tintColor = AMSettingsTextColor();
    [pill addSubview:icon];

    [NSLayoutConstraint activateConstraints:@[
        [pill.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:16.0],
        [pill.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-16.0],
        [pill.topAnchor constraintEqualToAnchor:header.topAnchor constant:existingH + 4.0],
        [pill.heightAnchor constraintEqualToConstant:42.0],

        [lbl.leadingAnchor constraintEqualToAnchor:pill.leadingAnchor constant:16.0],
        [lbl.centerYAnchor constraintEqualToAnchor:pill.centerYAnchor],

        [icon.trailingAnchor constraintEqualToAnchor:pill.trailingAnchor constant:-15.0],
        [icon.centerYAnchor constraintEqualToAnchor:pill.centerYAnchor],
    ]];

    objc_setAssociatedObject(pill, kAMSettingsLinkBtnKey, vc, OBJC_ASSOCIATION_ASSIGN);
    [pill addTarget:[AMSettingsLinkHandler class]
             action:@selector(onTapOpenLink:)
   forControlEvents:UIControlEventTouchUpInside];

    tv.tableHeaderView = header;
    objc_setAssociatedObject(vc, kAMSettingsLinkBtnKey, pill, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// ============================================================================
// Module 3: Custom XML Effects Storage, NSBundle Loader Hooks, & Custom Boxes
// ============================================================================

static NSString *AMCustomEffectsDir(void) {
    NSArray<NSString *> *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *dir = [docs.firstObject stringByAppendingPathComponent:@"CustomEffects"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}

static NSString *AMCustomThumbsDir(void) {
    NSString *dir = [AMCustomEffectsDir() stringByAppendingPathComponent:@"thumbs"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}

static NSString *AMSanitizeSlug(NSString *name) {
    NSString *lower = [name lowercaseString];
    NSMutableString *out = [NSMutableString string];
    for (NSUInteger i = 0; i < lower.length; ++i) {
        unichar c = [lower characterAtIndex:i];
        if ((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')) {
            [out appendFormat:@"%C", c];
        } else if (c == ' ' || c == '-' || c == '_') {
            if (out.length > 0 && [out characterAtIndex:out.length - 1] != '_') {
                [out appendString:@"_"];
            }
        }
    }
    if (out.length == 0) {
        [out appendFormat:@"fx_%lld", (long long)[[NSDate date] timeIntervalSince1970]];
    }
    return out;
}

static NSString *AMXmlEscapeAttr(NSString *s) {
    NSString *r = [s stringByReplacingOccurrencesOfString:@"&" withString:@"&amp;"];
    r = [r stringByReplacingOccurrencesOfString:@"\"" withString:@"&quot;"];
    r = [r stringByReplacingOccurrencesOfString:@"<" withString:@"&lt;"];
    r = [r stringByReplacingOccurrencesOfString:@">" withString:@"&gt;"];
    return r;
}

// Prepares valid Alight Motion <effect> XML so VisualEffectParser always registers
// it as its own standalone box inside the chosen category (usable on any layer).
static NSString *AMPrepareEffectXML(NSString *rawXML, NSString *displayName, NSString *slug, NSString *categorySlug, NSError **outError) {
    NSString *trimmed = [rawXML stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0) {
        if (outError) {
            *outError = [NSError errorWithDomain:@"AMCustomEffects" code:1
                                        userInfo:@{NSLocalizedDescriptionKey: @"XML or GLSL code is empty."}];
        }
        return nil;
    }
    NSString *cat = (categorySlug.length > 0) ? categorySlug : @"custom";

    // If user pasted raw GLSL fragment code (void main()) without <effect> wrapper, auto-wrap it!
    NSRange openStart = [trimmed rangeOfString:@"<effect" options:NSCaseInsensitiveSearch];
    if (openStart.location == NSNotFound) {
        if ([trimmed containsString:@"void main"] || [trimmed containsString:@"gl_FragColor"]) {
            NSString *wrapped = [NSString stringWithFormat:
                @"<?xml version='1.0' encoding='UTF-8' ?>\n"
                @"<effect id=\"com.alightcreative.effects.custom_%@\" compat=\"acScreenNorm-y\" name=\"%@\" desc=\"Custom Effect\" category=\"%@\" tags=\"custom,%@\" thumb=\"thumb/copy-bg.webp\">\n"
                @"    <params>\n"
                @"        <texture id=\"inputImg\" srcType=\"content\" />\n"
                @"    </params>\n"
                @"    <shader type=\"fragment\" precision=\"high\"><![CDATA[\n%@\n    ]]></shader>\n"
                @"</effect>\n",
                slug, AMXmlEscapeAttr(displayName), AMXmlEscapeAttr(cat), AMXmlEscapeAttr(cat), trimmed];
            return wrapped;
        }
        if (outError) {
            *outError = [NSError errorWithDomain:@"AMCustomEffects" code:2
                                        userInfo:@{NSLocalizedDescriptionKey: @"Paste a valid <effect>...</effect> XML or GLSL void main() shader."}];
        }
        return nil;
    }

    NSRange searchRange = NSMakeRange(openStart.location, trimmed.length - openStart.location);
    NSRange openEnd = [trimmed rangeOfString:@">" options:0 range:searchRange];
    if (openEnd.location == NSNotFound) {
        if (outError) {
            *outError = [NSError errorWithDomain:@"AMCustomEffects" code:3
                                        userInfo:@{NSLocalizedDescriptionKey: @"Malformed <effect> opening tag."}];
        }
        return nil;
    }

    NSRange tagRange = NSMakeRange(openStart.location, (openEnd.location - openStart.location) + 1);
    NSMutableString *openTag = [[trimmed substringWithRange:tagRange] mutableCopy];

    void (^removeAttr)(NSString *) = ^(NSString *attrName) {
        NSString *pattern = [NSString stringWithFormat:@"\\s*\\b%@\\s*=\\s*\"[^\"]*\"", attrName];
        NSRegularExpression *rx = [NSRegularExpression regularExpressionWithPattern:pattern options:NSRegularExpressionCaseInsensitive error:nil];
        [rx replaceMatchesInString:openTag options:0 range:NSMakeRange(0, openTag.length) withTemplate:@""];
    };

    void (^setAttr)(NSString *, NSString *) = ^(NSString *attrName, NSString *attrVal) {
        NSString *escaped = AMXmlEscapeAttr(attrVal);
        NSString *pattern = [NSString stringWithFormat:@"\\b%@\\s*=\\s*\"[^\"]*\"", attrName];
        NSRegularExpression *rx = [NSRegularExpression regularExpressionWithPattern:pattern options:0 error:nil];
        NSRange match = [rx rangeOfFirstMatchInString:openTag options:0 range:NSMakeRange(0, openTag.length)];
        NSString *replacement = [NSString stringWithFormat:@"%@=\"%@\"", attrName, escaped];
        if (match.location != NSNotFound) {
            [openTag replaceCharactersInRange:match withString:replacement];
        } else {
            NSUInteger insertPos = openTag.length - 1;
            [openTag insertString:[NSString stringWithFormat:@" %@", replacement] atIndex:insertPos];
        }
    };

    // Strip flags that hide an effect from the picker grid
    removeAttr(@"internal");
    removeAttr(@"deprecated");
    removeAttr(@"experimental");

    // Always assign a unique com.alightcreative.effects.custom_<slug> ID so it gets its own box
    // and never collides with a built-in effect
    setAttr(@"id", [NSString stringWithFormat:@"com.alightcreative.effects.custom_%@", slug]);
    setAttr(@"category", cat);
    setAttr(@"name", displayName);
    setAttr(@"desc", @"Custom Effect");
    setAttr(@"tags", [NSString stringWithFormat:@"custom,%@", cat]);
    // Use a guaranteed-valid built-in WebP thumb for Alight Motion's WebP loader;
    // our cell willDisplayCell hook overlays any custom user PNG thumbnail cleanly!
    setAttr(@"thumb", @"thumb/copy-bg.webp");

    NSMutableString *result = [trimmed mutableCopy];
    [result replaceCharactersInRange:tagRange withString:openTag];
    if (![result hasPrefix:@"<?xml"]) {
        [result insertString:@"<?xml version='1.0' encoding='UTF-8' ?>\n" atIndex:0];
    }
    return result;
}

static NSMutableDictionary<NSString *, NSString *> *AMLoadCustomThumbMap(void) {
    NSString *mapPath = [AMCustomEffectsDir() stringByAppendingPathComponent:@"thumb_map.plist"];
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:mapPath];
    return d ? [d mutableCopy] : [NSMutableDictionary dictionary];
}

static void AMSaveCustomThumbMap(NSDictionary<NSString *, NSString *> *map) {
    NSString *mapPath = [AMCustomEffectsDir() stringByAppendingPathComponent:@"thumb_map.plist"];
    [map writeToFile:mapPath atomically:YES];
}

static intptr_t AMMainBinarySlide(void);

// ============================================================================
// Module 3A: Inject Dedicated "Custom" Effect Category Bar (EffectCategory.all)
// Verified against AlightMotion 6.2.60 (build 869) ARM64:
//   - 0x10330acb0: swift_once predicate for EffectCategory.all
//   - 0x100466580: EffectCategory.all initializer (13 x 0x38-byte elements)
//   - 0x1033e5650: global pointer to _ContiguousArrayStorage<EffectCategory>
//   - 0x10045b298: Effect type metadata accessor (catOff +0x48, expOff +0x44)
//   - 0x1025b7bb8: Swift._stringCompareWithSmolCheck
//   - 0x1025bb380: swift_allocObject
//   - 0x1025bb41c: swift_bridgeObjectRetain
//   - 0x1025bb824: swift_retain
//   - 0x1025bb7e8: swift_once
// ============================================================================

struct AMEffectCategoryEntry {
    int64_t  catId;      // +0x00 (0 = Other, 500 = Experimental, 113 = Custom)
    uint64_t nameLo;     // +0x08 Swift String
    uint64_t nameHi;     // +0x10
    uint64_t thumbLo;    // +0x18 Swift String?
    uint64_t thumbHi;    // +0x20
    void    *filterFn;   // +0x28 (Effect) -> Bool
    void    *filterCtx;  // +0x30 closure context (NULL for thin fn)
};
static_assert(sizeof(AMEffectCategoryEntry) == 0x38, "EffectCategory size mismatch");

struct AMSwiftArrayHeader {
    void    *isa;              // +0x00
    uint64_t refCounts;        // +0x08
    int64_t  count;            // +0x10
    int64_t  capacityAndFlags; // +0x18
};
static_assert(sizeof(AMSwiftArrayHeader) == 0x20, "Swift array header size mismatch");

struct AMSwiftString {
    uint64_t lo;
    uint64_t hi;
};

static AMSwiftString AMMakeSwiftString(NSString *ns) {
    AMSwiftString res = { 0, 0xe000000000000000ULL };
    if (!ns || ns.length == 0) return res;
    const char *utf8 = [ns UTF8String];
    if (!utf8) return res;
    size_t len = strlen(utf8);
    BOOL ascii = YES;
    for (size_t i = 0; i < len; ++i) {
        if (((unsigned char)utf8[i]) >= 0x80) { ascii = NO; break; }
    }
    if (ascii && len <= 15) {
        uint64_t lo = 0, hi = 0;
        for (size_t i = 0; i < len && i < 8; ++i) {
            lo |= ((uint64_t)(unsigned char)utf8[i]) << (i * 8);
        }
        for (size_t i = 8; i < len && i < 15; ++i) {
            hi |= ((uint64_t)(unsigned char)utf8[i]) << ((i - 8) * 8);
        }
        hi |= ((uint64_t)(0xE0 | (len & 0x0F))) << 56;
        res.lo = lo;
        res.hi = hi;
        return res;
    }
    typedef AMSwiftString (*AMBridgeStrFn)(NSString *);
    static AMBridgeStrFn bridgeFn = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        bridgeFn = (AMBridgeStrFn)dlsym(RTLD_DEFAULT, "$sSS10FoundationE36_unconditionallyBridgeFromObjectiveCySSSo8NSStringCSgFZ");
    });
    if (bridgeFn) {
        return bridgeFn(ns);
    }
    size_t n = len > 15 ? 15 : len;
    uint64_t lo = 0, hi = 0;
    for (size_t i = 0; i < n && i < 8; ++i) lo |= ((uint64_t)(unsigned char)utf8[i]) << (i * 8);
    for (size_t i = 8; i < n && i < 15; ++i) hi |= ((uint64_t)(unsigned char)utf8[i]) << ((i - 8) * 8);
    hi |= ((uint64_t)(0xE0 | (n & 0x0F))) << 56;
    res.lo = lo;
    res.hi = hi;
    return res;
}

static NSString *AMCustomCategoryThumbsDir(void) {
    NSString *dir = [AMCustomEffectsDir() stringByAppendingPathComponent:@"cat_thumbs"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}

static NSString *AMCategoriesConfigPath(void) {
    return [AMCustomEffectsDir() stringByAppendingPathComponent:@"categories_config.plist"];
}

static NSMutableDictionary *AMLoadCategoriesConfig(void) {
    NSDictionary *raw = [NSDictionary dictionaryWithContentsOfFile:AMCategoriesConfigPath()];
    NSMutableDictionary *cfg = raw ? [raw mutableCopy] : [NSMutableDictionary dictionary];
    if (![cfg[@"deletedIds"] isKindOfClass:[NSArray class]]) {
        cfg[@"deletedIds"] = [NSMutableArray array];
    } else {
        cfg[@"deletedIds"] = [cfg[@"deletedIds"] mutableCopy];
    }
    if (![cfg[@"overrides"] isKindOfClass:[NSDictionary class]]) {
        cfg[@"overrides"] = [NSMutableDictionary dictionary];
    } else {
        cfg[@"overrides"] = [cfg[@"overrides"] mutableCopy];
    }
    if (![cfg[@"userCategories"] isKindOfClass:[NSArray class]]) {
        cfg[@"userCategories"] = [NSMutableArray array];
    } else {
        cfg[@"userCategories"] = [cfg[@"userCategories"] mutableCopy];
    }
    return cfg;
}

static void AMSaveCategoriesConfig(NSDictionary *cfg) {
    [cfg writeToFile:AMCategoriesConfigPath() atomically:YES];
}

static NSArray<NSDictionary *> *AMBuiltinCategoryCatalog(void) {
    return @[
        @{@"id": @103, @"name": @"Color & Light",      @"slug": @"color",      @"thumb": @"ic_category_thumbnail_colorlight.png"},
        @{@"id": @102, @"name": @"Drawing & Edge",     @"slug": @"drawing",    @"thumb": @"ic_category_thumbnail_drawingedge.png"},
        @{@"id": @104, @"name": @"Blur",               @"slug": @"blur",       @"thumb": @"ic_category_thumbnail_blur.png"},
        @{@"id": @106, @"name": @"Distortion/Warp",    @"slug": @"distort",    @"thumb": @"ic_category_thumbnail_warp.png"},
        @{@"id": @105, @"name": @"Procedural",         @"slug": @"procedural", @"thumb": @"ic_category_thumbnail_procedural.png"},
        @{@"id": @112, @"name": @"3D",                 @"slug": @"3d",         @"thumb": @"ic_category_thumbnail_3d.png"},
        @{@"id": @107, @"name": @"Move/Transform",     @"slug": @"transform",  @"thumb": @"ic_category_thumbnail_movetransform.png"},
        @{@"id": @111, @"name": @"Repeat",             @"slug": @"repeat",     @"thumb": @"ic_category_thumbnail_repeat.png"},
        @{@"id": @108, @"name": @"Matte/Mask/Key",     @"slug": @"matte",      @"thumb": @"ic_category_thumbnail_mask.png"},
        @{@"id": @109, @"name": @"Opacity/Visibility", @"slug": @"opacity",    @"thumb": @"ic_category_thumbnail_opacity.png"},
        @{@"id": @101, @"name": @"Text",               @"slug": @"text",       @"thumb": @"ic_category_thumbnail_text.png"},
        @{@"id": @0,   @"name": @"Other",              @"slug": @"other",      @"thumb": @""},
        @{@"id": @113, @"name": @"Custom",             @"slug": @"custom",     @"thumb": @""},
    ];
}

static NSCache<NSString *, UIImage *> *AMCategoryThumbCache(void) {
    static NSCache<NSString *, UIImage *> *cache = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cache = [[NSCache alloc] init];
        cache.countLimit = 48;
    });
    return cache;
}

static UIImage *AMLoadCategoryThumbImage(NSString *filename) {
    if (filename.length == 0) return nil;
    UIImage *cached = [AMCategoryThumbCache() objectForKey:filename];
    if (cached) return cached;
    NSString *path = [AMCustomCategoryThumbsDir() stringByAppendingPathComponent:filename];
    UIImage *img = [UIImage imageWithContentsOfFile:path];
    if (img) [AMCategoryThumbCache() setObject:img forKey:filename];
    return img;
}

static uint8_t AMCategoryMatchSwiftString(void *effectPtr, AMSwiftString target) {
    if (!effectPtr) return 0;
    intptr_t slide = AMMainBinarySlide();
    typedef void *(*AMMetaFn)(uintptr_t);
    typedef uint8_t (*AMStrEqFn)(uint64_t, uint64_t, uint64_t, uint64_t, uint8_t);

    AMMetaFn getEffectMeta = (AMMetaFn)(0x10045b298ULL + slide);
    uint8_t *meta = (uint8_t *)getEffectMeta(0);
    if (!meta) return 0;

    int32_t catOff = *(int32_t *)(meta + 0x48);
    int32_t expOff = *(int32_t *)(meta + 0x44);
    uint64_t strLo = *(uint64_t *)((uint8_t *)effectPtr + catOff);
    uint64_t strHi = *(uint64_t *)((uint8_t *)effectPtr + catOff + 8);

    BOOL matched = (strLo == target.lo && strHi == target.hi);
    if (!matched) {
        AMStrEqFn strEq = (AMStrEqFn)(0x1025b7bb8ULL + slide);
        matched = (strEq(strLo, strHi, target.lo, target.hi, 0) & 1) != 0;
    }
    if (!matched) return 0;
    uint8_t isExp = *((uint8_t *)effectPtr + expOff);
    return (uint8_t)((isExp ^ 1) & 1);
}

static uint8_t AMCustomCategoryFilter(void *effectPtr) {
    AMSwiftString target = { 0x00006d6f74737563ULL, 0xe600000000000000ULL };
    return AMCategoryMatchSwiftString(effectPtr, target);
}

static const int kAMMaxUserCategories = 32;
static AMSwiftString gAMUserCatSlugStr[kAMMaxUserCategories];
static BOOL gAMUserCatSlugValid[kAMMaxUserCategories];

#define AM_DEF_USER_CAT_FILTER(N) \
static uint8_t AMUserCategoryFilter_##N(void *effectPtr) { \
    if (!gAMUserCatSlugValid[N]) return 0; \
    return AMCategoryMatchSwiftString(effectPtr, gAMUserCatSlugStr[N]); \
}

AM_DEF_USER_CAT_FILTER(0)  AM_DEF_USER_CAT_FILTER(1)  AM_DEF_USER_CAT_FILTER(2)  AM_DEF_USER_CAT_FILTER(3)
AM_DEF_USER_CAT_FILTER(4)  AM_DEF_USER_CAT_FILTER(5)  AM_DEF_USER_CAT_FILTER(6)  AM_DEF_USER_CAT_FILTER(7)
AM_DEF_USER_CAT_FILTER(8)  AM_DEF_USER_CAT_FILTER(9)  AM_DEF_USER_CAT_FILTER(10) AM_DEF_USER_CAT_FILTER(11)
AM_DEF_USER_CAT_FILTER(12) AM_DEF_USER_CAT_FILTER(13) AM_DEF_USER_CAT_FILTER(14) AM_DEF_USER_CAT_FILTER(15)
AM_DEF_USER_CAT_FILTER(16) AM_DEF_USER_CAT_FILTER(17) AM_DEF_USER_CAT_FILTER(18) AM_DEF_USER_CAT_FILTER(19)
AM_DEF_USER_CAT_FILTER(20) AM_DEF_USER_CAT_FILTER(21) AM_DEF_USER_CAT_FILTER(22) AM_DEF_USER_CAT_FILTER(23)
AM_DEF_USER_CAT_FILTER(24) AM_DEF_USER_CAT_FILTER(25) AM_DEF_USER_CAT_FILTER(26) AM_DEF_USER_CAT_FILTER(27)
AM_DEF_USER_CAT_FILTER(28) AM_DEF_USER_CAT_FILTER(29) AM_DEF_USER_CAT_FILTER(30) AM_DEF_USER_CAT_FILTER(31)

static void *const kAMUserCatFilters[kAMMaxUserCategories] = {
    (void *)&AMUserCategoryFilter_0,  (void *)&AMUserCategoryFilter_1,
    (void *)&AMUserCategoryFilter_2,  (void *)&AMUserCategoryFilter_3,
    (void *)&AMUserCategoryFilter_4,  (void *)&AMUserCategoryFilter_5,
    (void *)&AMUserCategoryFilter_6,  (void *)&AMUserCategoryFilter_7,
    (void *)&AMUserCategoryFilter_8,  (void *)&AMUserCategoryFilter_9,
    (void *)&AMUserCategoryFilter_10, (void *)&AMUserCategoryFilter_11,
    (void *)&AMUserCategoryFilter_12, (void *)&AMUserCategoryFilter_13,
    (void *)&AMUserCategoryFilter_14, (void *)&AMUserCategoryFilter_15,
    (void *)&AMUserCategoryFilter_16, (void *)&AMUserCategoryFilter_17,
    (void *)&AMUserCategoryFilter_18, (void *)&AMUserCategoryFilter_19,
    (void *)&AMUserCategoryFilter_20, (void *)&AMUserCategoryFilter_21,
    (void *)&AMUserCategoryFilter_22, (void *)&AMUserCategoryFilter_23,
    (void *)&AMUserCategoryFilter_24, (void *)&AMUserCategoryFilter_25,
    (void *)&AMUserCategoryFilter_26, (void *)&AMUserCategoryFilter_27,
    (void *)&AMUserCategoryFilter_28, (void *)&AMUserCategoryFilter_29,
    (void *)&AMUserCategoryFilter_30, (void *)&AMUserCategoryFilter_31,
};

static uint8_t AMEditCategoriesDummyFilter(void *effectPtr) {
    (void)effectPtr;
    return 0;
}

static const int64_t kAMEditCategoriesSentinelId = 999;

static NSMutableArray<NSDictionary *> *gAMActiveRuntimeCategories = nil;

static void AMMigrateCustomEffectXMLCategories(void) {
    NSString *dir = AMCustomEffectsDir();
    NSArray<NSString *> *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:nil];
    for (NSString *fn in files) {
        if ([[fn pathExtension] caseInsensitiveCompare:@"xml"] != NSOrderedSame) continue;
        NSString *p = [dir stringByAppendingPathComponent:fn];
        NSString *xml = [NSString stringWithContentsOfFile:p encoding:NSUTF8StringEncoding error:nil];
        if (!xml) continue;
        if ([xml rangeOfString:@"category=\"other\"" options:NSCaseInsensitiveSearch].location != NSNotFound) {
            NSString *updated = [xml stringByReplacingOccurrencesOfString:@"category=\"other\""
                                                               withString:@"category=\"custom\""
                                                                  options:NSCaseInsensitiveSearch
                                                                    range:NSMakeRange(0, xml.length)];
            [updated writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:nil];
        }
    }
}

static void AMInstallCustomEffectCategoryIfNeeded(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        AMMigrateCustomEffectXMLCategories();

        intptr_t slide = AMMainBinarySlide();
        uintptr_t *swiftOncePred = (uintptr_t *)(0x10330acb0ULL + slide);
        void (*initCategories)(void *) = (void (*)(void *))(0x100466580ULL + slide);
        void (*swiftOnce)(uintptr_t *, void (*)(void *), void *) =
            (void (*)(uintptr_t *, void (*)(void *), void *))(0x1025bb7e8ULL + slide);
        void *(*swiftAllocObject)(void *, size_t, size_t) =
            (void *(*)(void *, size_t, size_t))(0x1025bb380ULL + slide);
        void *(*swiftBridgeRetain)(void *) =
            (void *(*)(void *))(0x1025bb41cULL + slide);
        void *(*swiftRetain)(void *) =
            (void *(*)(void *))(0x1025bb824ULL + slide);

        // Ensure original 13-element EffectCategory.all array is initialized first
        swiftOnce(swiftOncePred, initCategories, NULL);

        void **globalSlot = (void **)(0x1033e5650ULL + slide);
        AMSwiftArrayHeader *origHdr = (AMSwiftArrayHeader *)(*globalSlot);
        if (!origHdr || origHdr->count < 1 || origHdr->count > 64) return;

        NSDictionary *cfg = AMLoadCategoriesConfig();
        NSSet<NSNumber *> *deletedSet = [NSSet setWithArray:(cfg[@"deletedIds"] ?: @[])];
        NSDictionary *overrides = cfg[@"overrides"] ?: @{};
        NSArray<NSDictionary *> *userCats = cfg[@"userCategories"] ?: @[];

        NSMutableDictionary<NSNumber *, NSDictionary *> *catalogById = [NSMutableDictionary dictionary];
        for (NSDictionary *item in AMBuiltinCategoryCatalog()) {
            catalogById[item[@"id"]] = item;
        }

        AMEffectCategoryEntry *origItems = (AMEffectCategoryEntry *)((uint8_t *)origHdr + sizeof(AMSwiftArrayHeader));
        int64_t origCount = origHdr->count;

        AMEffectCategoryEntry finalEntries[64];
        int64_t finalCount = 0;
        gAMActiveRuntimeCategories = [NSMutableArray array];

        BOOL hasExp = NO;
        AMEffectCategoryEntry expEntry;

        for (int64_t i = 0; i < origCount && finalCount < 60; ++i) {
            AMEffectCategoryEntry e = origItems[i];
            if (e.catId == 500) {
                hasExp = YES;
                expEntry = e;
                continue;
            }
            if ([deletedSet containsObject:@(e.catId)]) {
                continue;
            }
            NSString *idKey = [NSString stringWithFormat:@"%lld", (long long)e.catId];
            NSDictionary *ov = overrides[idKey];
            NSString *ovName = [ov[@"name"] isKindOfClass:[NSString class]] ? ov[@"name"] : nil;
            NSString *ovImg = [ov[@"image"] isKindOfClass:[NSString class]] ? ov[@"image"] : @"";
            NSDictionary *catInfo = catalogById[@(e.catId)];
            NSString *dispName = (ovName.length > 0) ? ovName : (catInfo[@"name"] ?: @"Category");
            NSString *slug = catInfo[@"slug"] ?: @"other";

            if (ovName.length > 0) {
                AMSwiftString sw = AMMakeSwiftString(ovName);
                e.nameLo = sw.lo;
                e.nameHi = sw.hi;
            } else if (e.nameHi) {
                swiftBridgeRetain((void *)e.nameHi);
            }
            if (e.thumbHi) swiftBridgeRetain((void *)e.thumbHi);
            if (e.filterCtx) swiftRetain(e.filterCtx);

            finalEntries[finalCount++] = e;
            [gAMActiveRuntimeCategories addObject:@{
                @"id": @(e.catId),
                @"name": dispName,
                @"slug": slug,
                @"image": ovImg ?: @"",
                @"isUser": @NO,
                @"isCustom": @NO,
            }];
        }

        if (![deletedSet containsObject:@(0x71)] && finalCount < 60) {
            NSDictionary *ov = overrides[@"113"];
            NSString *ovName = [ov[@"name"] isKindOfClass:[NSString class]] ? ov[@"name"] : nil;
            NSString *ovImg = [ov[@"image"] isKindOfClass:[NSString class]] ? ov[@"image"] : @"";
            NSString *dispName = (ovName.length > 0) ? ovName : @"Custom";
            AMSwiftString sw = AMMakeSwiftString(dispName);

            AMEffectCategoryEntry customEntry;
            customEntry.catId = 0x71;
            customEntry.nameLo = sw.lo;
            customEntry.nameHi = sw.hi;
            customEntry.thumbLo = 0;
            customEntry.thumbHi = 0;
            customEntry.filterFn = (void *)&AMCustomCategoryFilter;
            customEntry.filterCtx = NULL;
            finalEntries[finalCount++] = customEntry;

            [gAMActiveRuntimeCategories addObject:@{
                @"id": @(0x71),
                @"name": dispName,
                @"slug": @"custom",
                @"image": ovImg ?: @"",
                @"isUser": @YES,
                @"isCustom": @YES,
            }];
        }

        int slot = 0;
        for (NSDictionary *uc in userCats) {
            if (slot >= kAMMaxUserCategories || finalCount >= 62) break;
            NSString *name = [uc[@"name"] isKindOfClass:[NSString class]] ? uc[@"name"] : nil;
            NSString *slug = [uc[@"slug"] isKindOfClass:[NSString class]] ? uc[@"slug"] : nil;
            NSNumber *idNum = [uc[@"id"] isKindOfClass:[NSNumber class]] ? uc[@"id"] : nil;
            NSString *img = [uc[@"image"] isKindOfClass:[NSString class]] ? uc[@"image"] : @"";
            if (name.length == 0 || slug.length == 0 || !idNum) continue;

            int64_t cid = idNum.longLongValue;
            if (cid <= 0 || cid == 500 || cid == 0x71) continue;

            AMSwiftString nameSw = AMMakeSwiftString(name);
            gAMUserCatSlugStr[slot] = AMMakeSwiftString(slug.lowercaseString);
            gAMUserCatSlugValid[slot] = YES;

            AMEffectCategoryEntry uEntry;
            uEntry.catId = cid;
            uEntry.nameLo = nameSw.lo;
            uEntry.nameHi = nameSw.hi;
            uEntry.thumbLo = 0;
            uEntry.thumbHi = 0;
            uEntry.filterFn = kAMUserCatFilters[slot];
            uEntry.filterCtx = NULL;
            finalEntries[finalCount++] = uEntry;

            [gAMActiveRuntimeCategories addObject:@{
                @"id": @(cid),
                @"name": name,
                @"slug": slug.lowercaseString,
                @"image": img ?: @"",
                @"isUser": @YES,
                @"isCustom": @NO,
            }];
            slot++;
        }

        // 3B. Append native "Edit Categories" rectangle cell at the bottom of the categories grid
        if (finalCount < 63) {
            AMSwiftString editNameSw = AMMakeSwiftString(@"Edit Categories");
            AMEffectCategoryEntry editEntry;
            editEntry.catId = kAMEditCategoriesSentinelId;
            editEntry.nameLo = editNameSw.lo;
            editEntry.nameHi = editNameSw.hi;
            editEntry.thumbLo = 0;
            editEntry.thumbHi = 0;
            editEntry.filterFn = (void *)&AMEditCategoriesDummyFilter;
            editEntry.filterCtx = NULL;
            finalEntries[finalCount++] = editEntry;

            [gAMActiveRuntimeCategories addObject:@{
                @"id": @(kAMEditCategoriesSentinelId),
                @"name": @"Edit Categories",
                @"slug": @"__edit_categories__",
                @"image": @"",
                @"isUser": @NO,
                @"isCustom": @NO,
                @"isEditAction": @YES,
            }];
        }

        if (hasExp && finalCount < 64) {
            if (expEntry.nameHi) swiftBridgeRetain((void *)expEntry.nameHi);
            if (expEntry.thumbHi) swiftBridgeRetain((void *)expEntry.thumbHi);
            if (expEntry.filterCtx) swiftRetain(expEntry.filterCtx);
            finalEntries[finalCount++] = expEntry;
        }

        if (finalCount <= 0) return;

        size_t newBytes = sizeof(AMSwiftArrayHeader) + (size_t)finalCount * sizeof(AMEffectCategoryEntry);
        AMSwiftArrayHeader *newHdr = (AMSwiftArrayHeader *)swiftAllocObject(origHdr->isa, newBytes, 7);
        if (!newHdr) return;
        newHdr->count = finalCount;
        newHdr->capacityAndFlags = finalCount << 1;

        AMEffectCategoryEntry *newItems = (AMEffectCategoryEntry *)((uint8_t *)newHdr + sizeof(AMSwiftArrayHeader));
        for (int64_t i = 0; i < finalCount; ++i) {
            newItems[i] = finalEntries[i];
        }

        *globalSlot = newHdr;
    });
}

static UILabel *AMFindFirstLabelInView(UIView *v);
static UIImageView *AMFindLargestImageViewInView(UIView *v);
static IMP gOrigEffectMainWillDisplayCell = NULL;
static IMP gOrigEffectMainDidSelectItem = NULL;
static const void *kAMCustomCatGradKey = &kAMCustomCatGradKey;

static UICollectionView *AMCategoriesCollectionViewOfMainVC(id vc) {
    if (!vc) return nil;
    SEL sel = NSSelectorFromString(@"categoriesCollectionView");
    if ([vc respondsToSelector:sel]) {
        id obj = ((id (*)(id, SEL))objc_msgSend)(vc, sel);
        if ([obj isKindOfClass:[UICollectionView class]]) return (UICollectionView *)obj;
    }
    return nil;
}

static UIImageView *AMMainCellThumbnailImageView(UICollectionViewCell *cell) {
    if (!cell) return nil;
    @try {
        id iv = [cell valueForKey:@"thumbnailImageView"];
        if ([iv isKindOfClass:[UIImageView class]]) return (UIImageView *)iv;
    } @catch (NSException *ex) { (void)ex; }
    return AMFindLargestImageViewInView(cell.contentView);
}

static NSDictionary *AMRuntimeCategoryForCell(UICollectionViewCell *cell, NSIndexPath *indexPath) {
    if (indexPath && indexPath.item >= 0 && (NSUInteger)indexPath.item < gAMActiveRuntimeCategories.count) {
        return gAMActiveRuntimeCategories[(NSUInteger)indexPath.item];
    }
    UILabel *titleLbl = nil;
    SEL titleSel = NSSelectorFromString(@"titleLabel");
    if ([cell respondsToSelector:titleSel]) {
        titleLbl = ((UILabel *(*)(id, SEL))objc_msgSend)(cell, titleSel);
    }
    if (!titleLbl) titleLbl = AMFindFirstLabelInView(cell.contentView);
    NSString *txt = titleLbl.text;
    if (txt.length > 0) {
        for (NSDictionary *d in gAMActiveRuntimeCategories) {
            if ([d[@"name"] caseInsensitiveCompare:txt] == NSOrderedSame) return d;
        }
    }
    return nil;
}

static void AMHook_effectMainWillDisplayCell(id self, SEL _cmd, UICollectionView *cv, UICollectionViewCell *cell, NSIndexPath *indexPath) {
    AMInstallCustomEffectCategoryIfNeeded();
    if (gOrigEffectMainWillDisplayCell) {
        ((void (*)(id, SEL, UICollectionView *, UICollectionViewCell *, NSIndexPath *))gOrigEffectMainWillDisplayCell)(self, _cmd, cv, cell, indexPath);
    }
    if (!cell) return;
    UICollectionView *catCV = AMCategoriesCollectionViewOfMainVC(self);
    if (catCV && cv != catCV) return;

    NSDictionary *catInfo = AMRuntimeCategoryForCell(cell, indexPath);
    NSString *imgFile = catInfo[@"image"];
    BOOL isEditAction = [catInfo[@"isEditAction"] boolValue];
    if (!isEditAction && catInfo[@"id"]) {
        NSDictionary *liveCfg = AMLoadCategoriesConfig();
        NSString *idKey = [NSString stringWithFormat:@"%@", catInfo[@"id"]];
        NSDictionary *ov = liveCfg[@"overrides"][idKey];
        if ([ov[@"image"] isKindOfClass:[NSString class]]) {
            imgFile = ov[@"image"];
        } else {
            for (NSDictionary *uc in (liveCfg[@"userCategories"] ?: @[])) {
                if ([uc[@"id"] isEqual:catInfo[@"id"]]) {
                    imgFile = [uc[@"image"] isKindOfClass:[NSString class]] ? uc[@"image"] : @"";
                    break;
                }
            }
        }
    }

    UIImage *customBg = (!isEditAction && imgFile.length > 0) ? AMLoadCategoryThumbImage(imgFile) : nil;
    BOOL isUserOrCustom = [catInfo[@"isUser"] boolValue];
    UIImageView *thumbIV = AMMainCellThumbnailImageView(cell);
    CAGradientLayer *grad = objc_getAssociatedObject(cell, kAMCustomCatGradKey);

    if (customBg) {
        if (thumbIV) {
            thumbIV.image = customBg;
            thumbIV.contentMode = UIViewContentModeScaleAspectFill;
            thumbIV.clipsToBounds = YES;
            thumbIV.hidden = NO;
        }
        if (grad) grad.hidden = YES;
    } else if (isEditAction || isUserOrCustom) {
        if (thumbIV) {
            thumbIV.image = nil;
        }
        if (!grad) {
            grad = [CAGradientLayer layer];
            grad.startPoint = CGPointMake(0.0, 0.0);
            grad.endPoint = CGPointMake(1.0, 1.0);
            [cell.contentView.layer insertSublayer:grad atIndex:0];
            objc_setAssociatedObject(cell, kAMCustomCatGradKey, grad, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        if (isEditAction) {
            // Subtle native Alight Motion dark slate gradient matching Other/Custom bars
            grad.colors = @[
                (id)[UIColor colorWithRed:0.165 green:0.176 blue:0.251 alpha:1.0].CGColor,
                (id)[UIColor colorWithRed:0.125 green:0.133 blue:0.192 alpha:1.0].CGColor,
            ];
        } else if ([catInfo[@"isCustom"] boolValue]) {
            grad.colors = @[
                (id)[UIColor colorWithRed:0.15 green:0.20 blue:0.35 alpha:1.0].CGColor,
                (id)[UIColor colorWithRed:0.12 green:0.30 blue:0.28 alpha:1.0].CGColor,
            ];
        } else {
            NSInteger cid = [catInfo[@"id"] integerValue];
            CGFloat hue = fmod((cid * 0.173), 1.0);
            UIColor *c1 = [UIColor colorWithHue:hue saturation:0.42 brightness:0.28 alpha:1.0];
            UIColor *c2 = [UIColor colorWithHue:fmod(hue + 0.12, 1.0) saturation:0.48 brightness:0.22 alpha:1.0];
            grad.colors = @[(id)c1.CGColor, (id)c2.CGColor];
        }
        grad.hidden = NO;
        grad.frame = cell.contentView.bounds;
    } else {
        if (grad) grad.hidden = YES;
    }
}

static IMP gOrigURLsForResources = NULL;
static NSArray<NSURL *> *AMEnsurePuppetSlotXMLs(void);

static NSArray<NSURL *> *AMHook_URLsForResourcesWithExtension(id self, SEL _cmd, NSString *ext, NSString *subpath) {
    NSArray<NSURL *> *orig = nil;
    if (gOrigURLsForResources) {
        orig = ((NSArray<NSURL *> *(*)(id, SEL, NSString *, NSString *))gOrigURLsForResources)(self, _cmd, ext, subpath);
    }
    if (self == [NSBundle mainBundle] &&
        ext && [ext caseInsensitiveCompare:@"xml"] == NSOrderedSame &&
        subpath && [subpath isEqualToString:@"BuiltinEffects"]) {
        AMInstallCustomEffectCategoryIfNeeded();
        NSMutableArray<NSURL *> *merged = orig ? [orig mutableCopy] : [NSMutableArray array];
        NSArray<NSURL *> *puppetURLs = AMEnsurePuppetSlotXMLs();
        if (puppetURLs.count > 0) {
            [merged addObjectsFromArray:puppetURLs];
        }
        NSString *dir = AMCustomEffectsDir();
        NSArray<NSString *> *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:nil];
        for (NSString *fn in files) {
            if ([[fn pathExtension] caseInsensitiveCompare:@"xml"] == NSOrderedSame) {
                [merged addObject:[NSURL fileURLWithPath:[dir stringByAppendingPathComponent:fn]]];
            }
        }
        return merged;
    }
    return orig;
}

// Overlay custom user PNG thumbnail onto the custom effect's box in EffectPickerCategoryVC
static IMP gOrigEffectCatWillDisplayCell = NULL;

static UILabel *AMFindFirstLabelInView(UIView *v) {
    if ([v isKindOfClass:[UILabel class]]) {
        UILabel *l = (UILabel *)v;
        if (l.text.length > 0) return l;
    }
    for (UIView *sub in v.subviews) {
        UILabel *found = AMFindFirstLabelInView(sub);
        if (found) return found;
    }
    return nil;
}

static UIImageView *AMFindLargestImageViewInView(UIView *v) {
    UIImageView *best = nil;
    CGFloat bestArea = 0;
    if ([v isKindOfClass:[UIImageView class]]) {
        best = (UIImageView *)v;
        bestArea = v.bounds.size.width * v.bounds.size.height;
    }
    for (UIView *sub in v.subviews) {
        UIImageView *cand = AMFindLargestImageViewInView(sub);
        if (cand) {
            CGFloat area = cand.bounds.size.width * cand.bounds.size.height;
            if (!best || area >= bestArea) {
                best = cand;
                bestArea = area;
            }
        }
    }
    return best;
}

static void AMCollectLabelsInView(UIView *v, NSMutableArray<UILabel *> *out) {
    if (!v) return;
    if ([v isKindOfClass:[UILabel class]]) {
        [out addObject:(UILabel *)v];
    }
    for (UIView *sub in v.subviews) {
        AMCollectLabelsInView(sub, out);
    }
}

static NSString *AMFindMatchingThumbFileForCell(UICollectionViewCell *cell, NSDictionary<NSString *, NSString *> *map) {
    if (!cell || map.count == 0) return nil;
    NSMutableArray<NSString *> *candidates = [NSMutableArray array];

    SEL titleSel = NSSelectorFromString(@"titleLabel");
    SEL textSel = NSSelectorFromString(@"textLabel");
    if ([cell respondsToSelector:titleSel]) {
        UILabel *tl = ((UILabel *(*)(id, SEL))objc_msgSend)(cell, titleSel);
        if (tl.text.length > 0) [candidates addObject:tl.text];
    }
    if ([cell respondsToSelector:textSel]) {
        UILabel *tx = ((UILabel *(*)(id, SEL))objc_msgSend)(cell, textSel);
        if (tx.text.length > 0) [candidates addObject:tx.text];
    }
    NSMutableArray<UILabel *> *allLabels = [NSMutableArray array];
    AMCollectLabelsInView(cell.contentView, allLabels);
    for (UILabel *l in allLabels) {
        if (l.text.length > 0) [candidates addObject:l.text];
    }

    for (NSString *raw in candidates) {
        NSString *hit = map[raw];
        if (hit.length > 0) return hit;
        NSString *trimmed = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        hit = map[trimmed];
        if (hit.length > 0) return hit;
        hit = map[trimmed.lowercaseString];
        if (hit.length > 0) return hit;
    }
    return nil;
}

static UIImageView *AMImageViewForEffectCell(UICollectionViewCell *cell) {
    SEL ivSel = NSSelectorFromString(@"imageView");
    if ([cell respondsToSelector:ivSel]) {
        UIImageView *iv = ((UIImageView *(*)(id, SEL))objc_msgSend)(cell, ivSel);
        if ([iv isKindOfClass:[UIImageView class]]) return iv;
    }
    return AMFindLargestImageViewInView(cell.contentView);
}

static void AMApplyThumbToCell(UICollectionViewCell *cell, UIImage *img) {
    UIImageView *iv = AMImageViewForEffectCell(cell);
    if (!iv || !img) return;
    iv.image = img;
    iv.contentMode = UIViewContentModeScaleAspectFill;
    iv.clipsToBounds = YES;
}

static void AMHook_effectCatWillDisplayCell(id self, SEL _cmd, UICollectionView *cv, UICollectionViewCell *cell, NSIndexPath *indexPath) {
    if (gOrigEffectCatWillDisplayCell) {
        ((void (*)(id, SEL, UICollectionView *, UICollectionViewCell *, NSIndexPath *))gOrigEffectCatWillDisplayCell)(self, _cmd, cv, cell, indexPath);
    }
    NSDictionary<NSString *, NSString *> *map = AMLoadCustomThumbMap();
    NSString *thumbFile = AMFindMatchingThumbFileForCell(cell, map);
    if (thumbFile.length > 0) {
        NSString *p = [AMCustomThumbsDir() stringByAppendingPathComponent:thumbFile];
        UIImage *img = [UIImage imageWithContentsOfFile:p];
        if (img) {
            AMApplyThumbToCell(cell, img);
            // Re-apply after async thumbnail load ticks so built-in WebP decode cannot overwrite custom PNG
            __weak UICollectionViewCell *weakCell = cell;
            dispatch_async(dispatch_get_main_queue(), ^{
                UICollectionViewCell *c = weakCell;
                if (c) AMApplyThumbToCell(c, img);
            });
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                UICollectionViewCell *c = weakCell;
                if (c) AMApplyThumbToCell(c, img);
            });
        }
    }
}

// ============================================================================
// Module 3B: Effect Categories Manager UI (Create, Delete, Rename, Picture)
// ============================================================================

@interface AMEffectCategoryEditorVC : UIViewController <UIImagePickerControllerDelegate, UINavigationControllerDelegate>
@property (nonatomic, assign) BOOL isCreating;
@property (nonatomic, assign) BOOL isUserCategory;
@property (nonatomic, assign) int64_t categoryId;
@property (nonatomic, copy) NSString *initialName;
@property (nonatomic, copy, nullable) NSString *initialImageFile;
@property (nonatomic, copy, nullable) NSString *builtinThumbName;
@property (nonatomic, copy, nullable) void (^onSaved)(void);

@property (nonatomic, strong) UITextField *nameField;
@property (nonatomic, strong) UIImageView *barPreviewIV;
@property (nonatomic, strong) UILabel *barPreviewLabel;
@property (nonatomic, strong) UIButton *clearPicBtn;
@property (nonatomic, strong, nullable) UIImage *pickedImage;
@property (nonatomic, assign) BOOL clearedImage;
@end

@implementation AMEffectCategoryEditorVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = AMBgColor();

    UIScrollView *scroll = [[UIScrollView alloc] init];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    [self.view addSubview:scroll];

    UIStackView *stack = [[UIStackView alloc] init];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 14.0;
    [scroll addSubview:stack];

    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:16.0],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-28.0],
        [stack.leadingAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.leadingAnchor constant:18.0],
        [stack.trailingAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.trailingAnchor constant:-18.0],
    ]];

    UIStackView *topRow = [[UIStackView alloc] init];
    topRow.axis = UILayoutConstraintAxisHorizontal;
    topRow.alignment = UIStackViewAlignmentCenter;

    UIButton *cancelBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [cancelBtn setTitle:@"Cancel" forState:UIControlStateNormal];
    [cancelBtn setTitleColor:[UIColor colorWithWhite:0.78 alpha:1.0] forState:UIControlStateNormal];
    cancelBtn.titleLabel.font = AMThemeFont(15.0, UIFontWeightMedium);
    [cancelBtn addTarget:self action:@selector(onCancel) forControlEvents:UIControlEventTouchUpInside];

    UILabel *hdr = [[UILabel alloc] init];
    hdr.text = self.isCreating ? @"New Category" : @"Edit Category";
    hdr.textAlignment = NSTextAlignmentCenter;
    hdr.textColor = [UIColor whiteColor];
    hdr.font = AMThemeFont(17.0, UIFontWeightBold);

    UIButton *saveBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [saveBtn setTitle:@"Save" forState:UIControlStateNormal];
    [saveBtn setTitleColor:AMAccentGreenColor() forState:UIControlStateNormal];
    saveBtn.titleLabel.font = AMThemeFont(15.0, UIFontWeightBold);
    [saveBtn addTarget:self action:@selector(onSave) forControlEvents:UIControlEventTouchUpInside];

    [topRow addArrangedSubview:cancelBtn];
    [topRow addArrangedSubview:hdr];
    [topRow addArrangedSubview:saveBtn];
    [cancelBtn.widthAnchor constraintEqualToConstant:64.0].active = YES;
    [saveBtn.widthAnchor constraintEqualToConstant:64.0].active = YES;
    [stack addArrangedSubview:topRow];

    UILabel *prevLbl = [[UILabel alloc] init];
    prevLbl.text = @"CATEGORY BAR PREVIEW";
    prevLbl.font = AMThemeFont(11.0, UIFontWeightBold);
    prevLbl.textColor = [UIColor colorWithWhite:0.65 alpha:1.0];
    [stack addArrangedSubview:prevLbl];

    UIView *previewBox = [[UIView alloc] init];
    previewBox.backgroundColor = [UIColor colorWithRed:0.15 green:0.19 blue:0.30 alpha:1.0];
    previewBox.layer.cornerRadius = 8.0;
    previewBox.layer.borderWidth = 1.0;
    previewBox.layer.borderColor = AMBorderColor().CGColor;
    previewBox.clipsToBounds = YES;
    [previewBox.heightAnchor constraintEqualToConstant:72.0].active = YES;

    self.barPreviewIV = [[UIImageView alloc] init];
    self.barPreviewIV.translatesAutoresizingMaskIntoConstraints = NO;
    self.barPreviewIV.contentMode = UIViewContentModeScaleAspectFill;
    self.barPreviewIV.clipsToBounds = YES;
    [previewBox addSubview:self.barPreviewIV];

    UIView *dimm = [[UIView alloc] init];
    dimm.translatesAutoresizingMaskIntoConstraints = NO;
    dimm.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.32];
    [previewBox addSubview:dimm];

    self.barPreviewLabel = [[UILabel alloc] init];
    self.barPreviewLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.barPreviewLabel.text = self.initialName.length > 0 ? self.initialName : @"New Category";
    self.barPreviewLabel.textColor = [UIColor whiteColor];
    self.barPreviewLabel.font = AMThemeFont(16.0, UIFontWeightBold);
    self.barPreviewLabel.textAlignment = NSTextAlignmentCenter;
    self.barPreviewLabel.shadowColor = [UIColor colorWithWhite:0.0 alpha:0.6];
    self.barPreviewLabel.shadowOffset = CGSizeMake(0, 1);
    [previewBox addSubview:self.barPreviewLabel];

    [NSLayoutConstraint activateConstraints:@[
        [self.barPreviewIV.topAnchor constraintEqualToAnchor:previewBox.topAnchor],
        [self.barPreviewIV.bottomAnchor constraintEqualToAnchor:previewBox.bottomAnchor],
        [self.barPreviewIV.leadingAnchor constraintEqualToAnchor:previewBox.leadingAnchor],
        [self.barPreviewIV.trailingAnchor constraintEqualToAnchor:previewBox.trailingAnchor],
        [dimm.topAnchor constraintEqualToAnchor:previewBox.topAnchor],
        [dimm.bottomAnchor constraintEqualToAnchor:previewBox.bottomAnchor],
        [dimm.leadingAnchor constraintEqualToAnchor:previewBox.leadingAnchor],
        [dimm.trailingAnchor constraintEqualToAnchor:previewBox.trailingAnchor],
        [self.barPreviewLabel.centerXAnchor constraintEqualToAnchor:previewBox.centerXAnchor],
        [self.barPreviewLabel.centerYAnchor constraintEqualToAnchor:previewBox.centerYAnchor],
        [self.barPreviewLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:previewBox.leadingAnchor constant:12.0],
        [self.barPreviewLabel.trailingAnchor constraintLessThanOrEqualToAnchor:previewBox.trailingAnchor constant:-12.0],
    ]];
    [stack addArrangedSubview:previewBox];

    UILabel *nameLbl = [[UILabel alloc] init];
    nameLbl.text = @"CATEGORY NAME";
    nameLbl.font = AMThemeFont(11.0, UIFontWeightBold);
    nameLbl.textColor = [UIColor colorWithWhite:0.65 alpha:1.0];
    [stack addArrangedSubview:nameLbl];

    self.nameField = [[UITextField alloc] init];
    self.nameField.backgroundColor = AMInputSurfaceColor();
    self.nameField.textColor = [UIColor whiteColor];
    self.nameField.font = AMThemeFont(15.0, UIFontWeightMedium);
    self.nameField.layer.cornerRadius = 10.0;
    self.nameField.layer.borderWidth = 1.0;
    self.nameField.layer.borderColor = AMBorderColor().CGColor;
    self.nameField.text = self.initialName ?: @"";
    self.nameField.attributedPlaceholder = [[NSAttributedString alloc] initWithString:@"e.g. Shaders, Glitch, Transitions"
                                                                           attributes:@{NSForegroundColorAttributeName: [UIColor colorWithWhite:0.55 alpha:1.0]}];
    self.nameField.leftView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 12, 42)];
    self.nameField.leftViewMode = UITextFieldViewModeAlways;
    [self.nameField.heightAnchor constraintEqualToConstant:44.0].active = YES;
    [self.nameField addTarget:self action:@selector(onNameChanged) forControlEvents:UIControlEventEditingChanged];
    [stack addArrangedSubview:self.nameField];

    UILabel *picLbl = [[UILabel alloc] init];
    picLbl.text = @"BACKGROUND PICTURE";
    picLbl.font = AMThemeFont(11.0, UIFontWeightBold);
    picLbl.textColor = [UIColor colorWithWhite:0.65 alpha:1.0];
    [stack addArrangedSubview:picLbl];

    UIStackView *picBtns = [[UIStackView alloc] init];
    picBtns.axis = UILayoutConstraintAxisHorizontal;
    picBtns.spacing = 10.0;
    picBtns.distribution = UIStackViewDistributionFillEqually;

    UIButton *pickBtn = [self makeBtn:@"Choose Picture" action:@selector(onPickPicture)];
    self.clearPicBtn = [self makeBtn:@"Reset Picture" action:@selector(onClearPicture)];
    [picBtns addArrangedSubview:pickBtn];
    [picBtns addArrangedSubview:self.clearPicBtn];
    [stack addArrangedSubview:picBtns];

    [self refreshPreviewImage];
}

- (UIButton *)makeBtn:(NSString *)title action:(SEL)sel {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    b.titleLabel.font = AMThemeFont(13.0, UIFontWeightSemibold);
    b.backgroundColor = AMSurfaceColor();
    b.layer.cornerRadius = 9.0;
    b.layer.borderWidth = 1.0;
    b.layer.borderColor = AMBorderColor().CGColor;
    b.contentEdgeInsets = UIEdgeInsetsMake(10, 12, 10, 12);
    [b addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (void)refreshPreviewImage {
    if (self.pickedImage) {
        self.barPreviewIV.image = self.pickedImage;
        return;
    }
    if (!self.clearedImage && self.initialImageFile.length > 0) {
        UIImage *img = AMLoadCategoryThumbImage(self.initialImageFile);
        if (img) {
            self.barPreviewIV.image = img;
            return;
        }
    }
    if (self.builtinThumbName.length > 0) {
        NSString *p = [[[NSBundle mainBundle] resourcePath] stringByAppendingPathComponent:
                       [@"BuiltinCategory/thumb" stringByAppendingPathComponent:self.builtinThumbName]];
        UIImage *img = [UIImage imageWithContentsOfFile:p];
        self.barPreviewIV.image = img;
        return;
    }
    self.barPreviewIV.image = nil;
}

- (void)onNameChanged {
    NSString *t = [self.nameField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    self.barPreviewLabel.text = t.length > 0 ? t : @"New Category";
}

- (void)onCancel {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)onPickPicture {
    UIImagePickerController *picker = [[UIImagePickerController alloc] init];
    picker.sourceType = UIImagePickerControllerSourceTypePhotoLibrary;
    picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)onClearPicture {
    self.pickedImage = nil;
    self.clearedImage = YES;
    [self refreshPreviewImage];
}

- (void)imagePickerController:(UIImagePickerController *)picker didFinishPickingMediaWithInfo:(NSDictionary<UIImagePickerControllerInfoKey, id> *)info {
    UIImage *img = info[UIImagePickerControllerOriginalImage];
    if (img) {
        CGSize target = CGSizeMake(600.0, 200.0);
        CGFloat scaleX = target.width / MAX(img.size.width, 1.0);
        CGFloat scaleY = target.height / MAX(img.size.height, 1.0);
        CGFloat scale = MAX(scaleX, scaleY);
        CGSize drawSz = CGSizeMake(img.size.width * scale, img.size.height * scale);
        CGRect drawRect = CGRectMake((target.width - drawSz.width) * 0.5, (target.height - drawSz.height) * 0.5, drawSz.width, drawSz.height);
        UIGraphicsBeginImageContextWithOptions(target, YES, 1.0);
        [img drawInRect:drawRect];
        UIImage *resized = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
        self.pickedImage = resized ?: img;
        self.clearedImage = NO;
        [self refreshPreviewImage];
    }
    [picker dismissViewControllerAnimated:YES completion:nil];
}

- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker {
    [picker dismissViewControllerAnimated:YES completion:nil];
}

- (void)onSave {
    NSString *name = [self.nameField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (name.length == 0) {
        UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Missing Name" message:@"Enter a category name." preferredStyle:UIAlertControllerStyleAlert];
        [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:ac animated:YES completion:nil];
        return;
    }

    NSMutableDictionary *cfg = AMLoadCategoriesConfig();
    NSMutableArray *userCats = cfg[@"userCategories"];
    NSMutableDictionary *overrides = cfg[@"overrides"];

    int64_t cid = self.categoryId;
    if (self.isCreating) {
        if ((int)userCats.count >= kAMMaxUserCategories) {
            UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Limit Reached" message:@"Maximum of 32 custom categories reached." preferredStyle:UIAlertControllerStyleAlert];
            [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:ac animated:YES completion:nil];
            return;
        }
        int64_t maxId = 113;
        for (NSDictionary *uc in userCats) {
            int64_t v = [uc[@"id"] longLongValue];
            if (v > maxId) maxId = v;
        }
        cid = maxId + 1;
    }

    NSString *imgFile = self.clearedImage ? @"" : (self.initialImageFile ?: @"");
    if (self.pickedImage) {
        NSString *fn = [NSString stringWithFormat:@"cat_%lld_%lld.png", (long long)cid, (long long)[[NSDate date] timeIntervalSince1970]];
        NSData *png = UIImagePNGRepresentation(self.pickedImage);
        if (png) {
            if (self.initialImageFile.length > 0) {
                [[NSFileManager defaultManager] removeItemAtPath:[AMCustomCategoryThumbsDir() stringByAppendingPathComponent:self.initialImageFile] error:nil];
                [AMCategoryThumbCache() removeObjectForKey:self.initialImageFile];
            }
            [png writeToFile:[AMCustomCategoryThumbsDir() stringByAppendingPathComponent:fn] atomically:YES];
            imgFile = fn;
        }
    } else if (self.clearedImage && self.initialImageFile.length > 0) {
        [[NSFileManager defaultManager] removeItemAtPath:[AMCustomCategoryThumbsDir() stringByAppendingPathComponent:self.initialImageFile] error:nil];
        [AMCategoryThumbCache() removeObjectForKey:self.initialImageFile];
    }

    if (self.isCreating) {
        NSString *slug = AMSanitizeSlug(name);
        NSMutableSet<NSString *> *usedSlugs = [NSMutableSet setWithObjects:@"color", @"drawing", @"blur", @"distort", @"procedural", @"3d", @"transform", @"repeat", @"matte", @"opacity", @"text", @"other", @"custom", nil];
        for (NSDictionary *uc in userCats) {
            if (uc[@"slug"]) [usedSlugs addObject:uc[@"slug"]];
        }
        NSString *finalSlug = slug;
        int suffix = 2;
        while ([usedSlugs containsObject:finalSlug]) {
            finalSlug = [NSString stringWithFormat:@"%@_%d", slug, suffix++];
        }
        [userCats addObject:@{
            @"id": @(cid),
            @"slug": finalSlug,
            @"name": name,
            @"image": imgFile ?: @"",
        }];
    } else if (self.isUserCategory) {
        for (NSUInteger i = 0; i < userCats.count; ++i) {
            if ([userCats[i][@"id"] longLongValue] == cid) {
                NSMutableDictionary *m = [userCats[i] mutableCopy];
                m[@"name"] = name;
                m[@"image"] = imgFile ?: @"";
                userCats[i] = m;
                break;
            }
        }
    } else {
        NSString *idKey = [NSString stringWithFormat:@"%lld", (long long)cid];
        overrides[idKey] = @{
            @"name": name,
            @"image": imgFile ?: @"",
        };
    }

    AMSaveCategoriesConfig(cfg);
    if (self.onSaved) self.onSaved();
    [self dismissViewControllerAnimated:YES completion:nil];
}

@end

@interface AMEffectCategoriesManagerVC : UIViewController
@property (nonatomic, copy, nullable) void (^onDidChange)(void);
@property (nonatomic, strong) UIStackView *listStack;
@property (nonatomic, strong) UIStackView *deletedStack;
@property (nonatomic, strong) UILabel *deletedHeaderLabel;
@end

@implementation AMEffectCategoriesManagerVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = AMBgColor();

    UIScrollView *scroll = [[UIScrollView alloc] init];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:scroll];

    UIStackView *stack = [[UIStackView alloc] init];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 12.0;
    [scroll addSubview:stack];

    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:16.0],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-28.0],
        [stack.leadingAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.leadingAnchor constant:16.0],
        [stack.trailingAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.trailingAnchor constant:-16.0],
    ]];

    UIStackView *topRow = [[UIStackView alloc] init];
    topRow.axis = UILayoutConstraintAxisHorizontal;
    topRow.alignment = UIStackViewAlignmentCenter;

    UIButton *closeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [closeBtn setTitle:@"Done" forState:UIControlStateNormal];
    [closeBtn setTitleColor:[UIColor colorWithWhite:0.78 alpha:1.0] forState:UIControlStateNormal];
    closeBtn.titleLabel.font = AMThemeFont(15.0, UIFontWeightMedium);
    [closeBtn addTarget:self action:@selector(onClose) forControlEvents:UIControlEventTouchUpInside];

    UILabel *hdr = [[UILabel alloc] init];
    hdr.text = @"Effect Categories";
    hdr.textAlignment = NSTextAlignmentCenter;
    hdr.textColor = [UIColor whiteColor];
    hdr.font = AMThemeFont(17.0, UIFontWeightBold);

    UIButton *addBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [addBtn setTitle:@"+ New" forState:UIControlStateNormal];
    [addBtn setTitleColor:AMAccentGreenColor() forState:UIControlStateNormal];
    addBtn.titleLabel.font = AMThemeFont(15.0, UIFontWeightBold);
    [addBtn addTarget:self action:@selector(onAddNew) forControlEvents:UIControlEventTouchUpInside];

    [topRow addArrangedSubview:closeBtn];
    [topRow addArrangedSubview:hdr];
    [topRow addArrangedSubview:addBtn];
    [closeBtn.widthAnchor constraintEqualToConstant:62.0].active = YES;
    [addBtn.widthAnchor constraintEqualToConstant:62.0].active = YES;
    [stack addArrangedSubview:topRow];

    UIView *banner = [[UIView alloc] init];
    banner.backgroundColor = AMSurfaceColor();
    banner.layer.cornerRadius = 10.0;
    banner.layer.borderWidth = 1.0;
    banner.layer.borderColor = AMBorderColor().CGColor;

    UIStackView *bRow = [[UIStackView alloc] init];
    bRow.translatesAutoresizingMaskIntoConstraints = NO;
    bRow.axis = UILayoutConstraintAxisHorizontal;
    bRow.alignment = UIStackViewAlignmentCenter;
    bRow.spacing = 10.0;
    [banner addSubview:bRow];
    [NSLayoutConstraint activateConstraints:@[
        [bRow.topAnchor constraintEqualToAnchor:banner.topAnchor constant:10.0],
        [bRow.bottomAnchor constraintEqualToAnchor:banner.bottomAnchor constant:-10.0],
        [bRow.leadingAnchor constraintEqualToAnchor:banner.leadingAnchor constant:12.0],
        [bRow.trailingAnchor constraintEqualToAnchor:banner.trailingAnchor constant:-12.0],
    ]];

    UILabel *note = [[UILabel alloc] init];
    note.text = @"Restart Alight Motion to load new or deleted categories.";
    note.textColor = [UIColor colorWithWhite:0.78 alpha:1.0];
    note.font = AMThemeFont(12.0, UIFontWeightRegular);
    note.numberOfLines = 0;

    UIButton *restartBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [restartBtn setTitle:@"Close App" forState:UIControlStateNormal];
    [restartBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    restartBtn.titleLabel.font = AMThemeFont(12.0, UIFontWeightBold);
    restartBtn.backgroundColor = [UIColor colorWithRed:0.20 green:0.56 blue:0.44 alpha:1.0];
    restartBtn.layer.cornerRadius = 7.0;
    restartBtn.contentEdgeInsets = UIEdgeInsetsMake(6, 10, 6, 10);
    [restartBtn setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [restartBtn addTarget:self action:@selector(onRestartApp) forControlEvents:UIControlEventTouchUpInside];

    [bRow addArrangedSubview:note];
    [bRow addArrangedSubview:restartBtn];
    [stack addArrangedSubview:banner];

    UILabel *activeLbl = [[UILabel alloc] init];
    activeLbl.text = @"ACTIVE CATEGORIES";
    activeLbl.font = AMThemeFont(11.0, UIFontWeightBold);
    activeLbl.textColor = [UIColor colorWithWhite:0.65 alpha:1.0];
    [stack addArrangedSubview:activeLbl];

    self.listStack = [[UIStackView alloc] init];
    self.listStack.axis = UILayoutConstraintAxisVertical;
    self.listStack.spacing = 8.0;
    [stack addArrangedSubview:self.listStack];

    self.deletedHeaderLabel = [[UILabel alloc] init];
    self.deletedHeaderLabel.text = @"DELETED BUILT-IN CATEGORIES (TAP TO RESTORE)";
    self.deletedHeaderLabel.font = AMThemeFont(11.0, UIFontWeightBold);
    self.deletedHeaderLabel.textColor = [UIColor colorWithWhite:0.65 alpha:1.0];
    [stack addArrangedSubview:self.deletedHeaderLabel];

    self.deletedStack = [[UIStackView alloc] init];
    self.deletedStack.axis = UILayoutConstraintAxisVertical;
    self.deletedStack.spacing = 8.0;
    [stack addArrangedSubview:self.deletedStack];

    [self reloadLists];
}

- (void)onClose {
    if (self.onDidChange) self.onDidChange();
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)onRestartApp {
    exit(0);
}

- (void)onAddNew {
    AMEffectCategoryEditorVC *ed = [[AMEffectCategoryEditorVC alloc] init];
    ed.isCreating = YES;
    ed.isUserCategory = YES;
    ed.modalPresentationStyle = UIModalPresentationPageSheet;
    __weak AMEffectCategoriesManagerVC *weakSelf = self;
    ed.onSaved = ^{
        [weakSelf reloadLists];
    };
    [self presentViewController:ed animated:YES completion:nil];
}

- (UIView *)makeCategoryCardWithId:(int64_t)cid name:(NSString *)name slug:(NSString *)slug imageFile:(NSString *)imgFile builtinThumb:(NSString *)builtinThumb isUser:(BOOL)isUser {
    UIView *card = [[UIView alloc] init];
    card.backgroundColor = AMSurfaceColor();
    card.layer.cornerRadius = 10.0;
    card.layer.borderWidth = 1.0;
    card.layer.borderColor = AMBorderColor().CGColor;

    UIStackView *row = [[UIStackView alloc] init];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    row.axis = UILayoutConstraintAxisHorizontal;
    row.alignment = UIStackViewAlignmentCenter;
    row.spacing = 10.0;
    [card addSubview:row];
    [NSLayoutConstraint activateConstraints:@[
        [row.topAnchor constraintEqualToAnchor:card.topAnchor constant:8.0],
        [row.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-8.0],
        [row.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:10.0],
        [row.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-10.0],
    ]];

    UIImageView *thumb = [[UIImageView alloc] init];
    thumb.backgroundColor = AMInputSurfaceColor();
    thumb.contentMode = UIViewContentModeScaleAspectFill;
    thumb.clipsToBounds = YES;
    thumb.layer.cornerRadius = 6.0;
    [thumb.widthAnchor constraintEqualToConstant:64.0].active = YES;
    [thumb.heightAnchor constraintEqualToConstant:36.0].active = YES;
    if (imgFile.length > 0) {
        thumb.image = AMLoadCategoryThumbImage(imgFile);
    } else if (builtinThumb.length > 0) {
        NSString *p = [[[NSBundle mainBundle] resourcePath] stringByAppendingPathComponent:
                       [@"BuiltinCategory/thumb" stringByAppendingPathComponent:builtinThumb]];
        thumb.image = [UIImage imageWithContentsOfFile:p];
    }

    UIStackView *txtCol = [[UIStackView alloc] init];
    txtCol.axis = UILayoutConstraintAxisVertical;
    txtCol.spacing = 2.0;

    UILabel *titleLbl = [[UILabel alloc] init];
    titleLbl.text = name;
    titleLbl.textColor = [UIColor whiteColor];
    titleLbl.font = AMThemeFont(14.0, UIFontWeightSemibold);

    UILabel *subLbl = [[UILabel alloc] init];
    subLbl.text = isUser ? [NSString stringWithFormat:@"Custom • slug: %@", slug] : [NSString stringWithFormat:@"Built-in • slug: %@", slug];
    subLbl.textColor = [UIColor colorWithWhite:0.58 alpha:1.0];
    subLbl.font = AMThemeFont(11.0, UIFontWeightRegular);

    [txtCol addArrangedSubview:titleLbl];
    [txtCol addArrangedSubview:subLbl];

    UIButton *editBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [editBtn setTitle:@"Edit" forState:UIControlStateNormal];
    [editBtn setTitleColor:AMAccentGreenColor() forState:UIControlStateNormal];
    editBtn.titleLabel.font = AMThemeFont(13.0, UIFontWeightSemibold);
    editBtn.tag = (NSInteger)cid;
    editBtn.accessibilityValue = isUser ? @"user" : @"builtin";
    [editBtn setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [editBtn addTarget:self action:@selector(onEditCategory:) forControlEvents:UIControlEventTouchUpInside];

    UIButton *delBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [delBtn setTitle:@"Delete" forState:UIControlStateNormal];
    [delBtn setTitleColor:[UIColor colorWithRed:0.95 green:0.38 blue:0.42 alpha:1.0] forState:UIControlStateNormal];
    delBtn.titleLabel.font = AMThemeFont(13.0, UIFontWeightSemibold);
    delBtn.tag = (NSInteger)cid;
    delBtn.accessibilityValue = isUser ? @"user" : @"builtin";
    [delBtn setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [delBtn addTarget:self action:@selector(onDeleteCategory:) forControlEvents:UIControlEventTouchUpInside];

    [row addArrangedSubview:thumb];
    [row addArrangedSubview:txtCol];
    [row addArrangedSubview:editBtn];
    [row addArrangedSubview:delBtn];
    return card;
}

- (void)reloadLists {
    for (UIView *v in [self.listStack.arrangedSubviews copy]) {
        [self.listStack removeArrangedSubview:v];
        [v removeFromSuperview];
    }
    for (UIView *v in [self.deletedStack.arrangedSubviews copy]) {
        [self.deletedStack removeArrangedSubview:v];
        [v removeFromSuperview];
    }

    NSDictionary *cfg = AMLoadCategoriesConfig();
    NSSet<NSNumber *> *deletedSet = [NSSet setWithArray:(cfg[@"deletedIds"] ?: @[])];
    NSDictionary *overrides = cfg[@"overrides"] ?: @{};
    NSArray<NSDictionary *> *userCats = cfg[@"userCategories"] ?: @[];

    NSInteger deletedCount = 0;
    for (NSDictionary *b in AMBuiltinCategoryCatalog()) {
        int64_t cid = [b[@"id"] longLongValue];
        NSString *idKey = [NSString stringWithFormat:@"%lld", (long long)cid];
        NSDictionary *ov = overrides[idKey];
        NSString *name = ([ov[@"name"] isKindOfClass:[NSString class]] && [ov[@"name"] length] > 0) ? ov[@"name"] : b[@"name"];
        NSString *imgFile = [ov[@"image"] isKindOfClass:[NSString class]] ? ov[@"image"] : @"";
        if ([deletedSet containsObject:@(cid)]) {
            deletedCount++;
            UIButton *restoreBtn = [UIButton buttonWithType:UIButtonTypeSystem];
            [restoreBtn setTitle:[NSString stringWithFormat:@"Restore \"%@\"", name] forState:UIControlStateNormal];
            [restoreBtn setTitleColor:[UIColor colorWithWhite:0.85 alpha:1.0] forState:UIControlStateNormal];
            restoreBtn.titleLabel.font = AMThemeFont(13.0, UIFontWeightMedium);
            restoreBtn.backgroundColor = AMInputSurfaceColor();
            restoreBtn.layer.cornerRadius = 8.0;
            restoreBtn.layer.borderWidth = 1.0;
            restoreBtn.layer.borderColor = AMBorderColor().CGColor;
            restoreBtn.contentEdgeInsets = UIEdgeInsetsMake(9, 12, 9, 12);
            restoreBtn.tag = (NSInteger)cid;
            [restoreBtn addTarget:self action:@selector(onRestoreBuiltin:) forControlEvents:UIControlEventTouchUpInside];
            [self.deletedStack addArrangedSubview:restoreBtn];
            continue;
        }
        [self.listStack addArrangedSubview:[self makeCategoryCardWithId:cid name:name slug:b[@"slug"] imageFile:imgFile builtinThumb:b[@"thumb"] isUser:NO]];
    }

    for (NSDictionary *uc in userCats) {
        int64_t cid = [uc[@"id"] longLongValue];
        NSString *name = uc[@"name"] ?: @"Category";
        NSString *slug = uc[@"slug"] ?: @"custom";
        NSString *imgFile = [uc[@"image"] isKindOfClass:[NSString class]] ? uc[@"image"] : @"";
        [self.listStack addArrangedSubview:[self makeCategoryCardWithId:cid name:name slug:slug imageFile:imgFile builtinThumb:@"" isUser:YES]];
    }

    self.deletedHeaderLabel.hidden = (deletedCount == 0);
    self.deletedStack.hidden = (deletedCount == 0);
}

- (void)onEditCategory:(UIButton *)btn {
    int64_t cid = (int64_t)btn.tag;
    BOOL isUser = [btn.accessibilityValue isEqualToString:@"user"];
    NSDictionary *cfg = AMLoadCategoriesConfig();

    AMEffectCategoryEditorVC *ed = [[AMEffectCategoryEditorVC alloc] init];
    ed.isCreating = NO;
    ed.isUserCategory = isUser;
    ed.categoryId = cid;
    if (isUser) {
        for (NSDictionary *uc in (cfg[@"userCategories"] ?: @[])) {
            if ([uc[@"id"] longLongValue] == cid) {
                ed.initialName = uc[@"name"];
                ed.initialImageFile = uc[@"image"];
                break;
            }
        }
    } else {
        NSString *idKey = [NSString stringWithFormat:@"%lld", (long long)cid];
        NSDictionary *ov = cfg[@"overrides"][idKey];
        for (NSDictionary *b in AMBuiltinCategoryCatalog()) {
            if ([b[@"id"] longLongValue] == cid) {
                ed.initialName = ([ov[@"name"] isKindOfClass:[NSString class]] && [ov[@"name"] length] > 0) ? ov[@"name"] : b[@"name"];
                ed.initialImageFile = [ov[@"image"] isKindOfClass:[NSString class]] ? ov[@"image"] : @"";
                ed.builtinThumbName = b[@"thumb"];
                break;
            }
        }
    }
    ed.modalPresentationStyle = UIModalPresentationPageSheet;
    __weak AMEffectCategoriesManagerVC *weakSelf = self;
    ed.onSaved = ^{
        [weakSelf reloadLists];
    };
    [self presentViewController:ed animated:YES completion:nil];
}

- (void)onDeleteCategory:(UIButton *)btn {
    int64_t cid = (int64_t)btn.tag;
    BOOL isUser = [btn.accessibilityValue isEqualToString:@"user"];
    NSMutableDictionary *cfg = AMLoadCategoriesConfig();
    if (isUser) {
        NSMutableArray *userCats = cfg[@"userCategories"];
        for (NSUInteger i = 0; i < userCats.count; ++i) {
            if ([userCats[i][@"id"] longLongValue] == cid) {
                NSString *imgFile = userCats[i][@"image"];
                if (imgFile.length > 0) {
                    [[NSFileManager defaultManager] removeItemAtPath:[AMCustomCategoryThumbsDir() stringByAppendingPathComponent:imgFile] error:nil];
                    [AMCategoryThumbCache() removeObjectForKey:imgFile];
                }
                [userCats removeObjectAtIndex:i];
                break;
            }
        }
    } else {
        NSMutableArray *delIds = cfg[@"deletedIds"];
        if (![delIds containsObject:@(cid)]) {
            [delIds addObject:@(cid)];
        }
    }
    AMSaveCategoriesConfig(cfg);
    [self reloadLists];
}

- (void)onRestoreBuiltin:(UIButton *)btn {
    int64_t cid = (int64_t)btn.tag;
    NSMutableDictionary *cfg = AMLoadCategoriesConfig();
    NSMutableArray *delIds = cfg[@"deletedIds"];
    [delIds removeObject:@(cid)];
    AMSaveCategoriesConfig(cfg);
    [self reloadLists];
}

@end

static void AMHook_effectMainDidSelectItem(id self, SEL _cmd, UICollectionView *cv, NSIndexPath *indexPath) {
    UICollectionView *catCV = AMCategoriesCollectionViewOfMainVC(self);
    if (catCV && cv == catCV && indexPath && indexPath.item >= 0 && (NSUInteger)indexPath.item < gAMActiveRuntimeCategories.count) {
        NSDictionary *catInfo = gAMActiveRuntimeCategories[(NSUInteger)indexPath.item];
        if ([catInfo[@"isEditAction"] boolValue]) {
            [cv deselectItemAtIndexPath:indexPath animated:YES];
            UIViewController *vc = (UIViewController *)self;
            AMEffectCategoriesManagerVC *mgr = [[AMEffectCategoriesManagerVC alloc] init];
            mgr.modalPresentationStyle = UIModalPresentationPageSheet;
            [vc presentViewController:mgr animated:YES completion:nil];
            return;
        }
    }
    if (gOrigEffectMainDidSelectItem) {
        ((void (*)(id, SEL, UICollectionView *, NSIndexPath *))gOrigEffectMainDidSelectItem)(self, _cmd, cv, indexPath);
    }
}

// ============================================================================
// Module 3C: Custom XML Effect Importer Modal UI, AI Downloads, & '+' Button
// ============================================================================

@interface AMCustomEffectImporterVC : UIViewController <UIDocumentPickerDelegate, UIImagePickerControllerDelegate, UINavigationControllerDelegate>
@property (nonatomic, copy, nullable) NSString *initialCategorySlug;
@property (nonatomic, copy, nullable) NSString *initialCategoryName;
@property (nonatomic, copy) NSString *selectedCategorySlug;
@property (nonatomic, copy) NSString *selectedCategoryName;
@property (nonatomic, strong) UIButton *categoryPickBtn;
@property (nonatomic, strong) UIButton *downloadAllBtn;
@property (nonatomic, strong) UITextField *nameField;
@property (nonatomic, strong) UITextView *xmlTextView;
@property (nonatomic, strong) UIImageView *thumbPreview;
@property (nonatomic, strong) UIButton *clearThumbBtn;
@property (nonatomic, strong) UIStackView *installedListStack;
@property (nonatomic, strong, nullable) UIImage *selectedThumb;
@end

@implementation AMCustomEffectImporterVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = AMBgColor();
    self.title = @"Import XML Effect";
    self.selectedCategorySlug = self.initialCategorySlug.length > 0 ? self.initialCategorySlug : @"custom";
    self.selectedCategoryName = self.initialCategoryName.length > 0 ? self.initialCategoryName : @"Custom";

    UIScrollView *scroll = [[UIScrollView alloc] init];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    [self.view addSubview:scroll];

    UIStackView *stack = [[UIStackView alloc] init];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 14.0;
    [scroll addSubview:stack];

    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],

        [stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:16.0],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-28.0],
        [stack.leadingAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.leadingAnchor constant:18.0],
        [stack.trailingAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.trailingAnchor constant:-18.0],
    ]];

    UIStackView *topRow = [[UIStackView alloc] init];
    topRow.axis = UILayoutConstraintAxisHorizontal;
    topRow.alignment = UIStackViewAlignmentCenter;

    UIButton *closeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [closeBtn setTitle:@"Close" forState:UIControlStateNormal];
    [closeBtn setTitleColor:[UIColor colorWithWhite:0.78 alpha:1.0] forState:UIControlStateNormal];
    closeBtn.titleLabel.font = AMThemeFont(15.0, UIFontWeightMedium);
    [closeBtn addTarget:self action:@selector(onClose) forControlEvents:UIControlEventTouchUpInside];

    UILabel *hdrLabel = [[UILabel alloc] init];
    hdrLabel.text = @"Create Custom Effect";
    hdrLabel.textAlignment = NSTextAlignmentCenter;
    hdrLabel.textColor = [UIColor whiteColor];
    hdrLabel.font = AMThemeFont(17.0, UIFontWeightBold);

    UIButton *importBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [importBtn setTitle:@"Create" forState:UIControlStateNormal];
    [importBtn setTitleColor:AMAccentGreenColor() forState:UIControlStateNormal];
    importBtn.titleLabel.font = AMThemeFont(15.0, UIFontWeightBold);
    [importBtn addTarget:self action:@selector(onImport) forControlEvents:UIControlEventTouchUpInside];

    [topRow addArrangedSubview:closeBtn];
    [topRow addArrangedSubview:hdrLabel];
    [topRow addArrangedSubview:importBtn];
    [closeBtn.widthAnchor constraintEqualToConstant:60.0].active = YES;
    [importBtn.widthAnchor constraintEqualToConstant:60.0].active = YES;
    [stack addArrangedSubview:topRow];

    [stack addArrangedSubview:[self makeSectionLabel:@"AI EFFECT AUTHORING RESOURCES"]];
    UIStackView *aiRow = [[UIStackView alloc] init];
    aiRow.axis = UILayoutConstraintAxisHorizontal;
    aiRow.spacing = 10.0;
    aiRow.distribution = UIStackViewDistributionFillEqually;

    UIButton *guideBtn = [self makeActionButton:@"Effects Guide (.md)" action:@selector(onDownloadGuide:)];
    self.downloadAllBtn = [self makeActionButton:@"All Effects (.md)" action:@selector(onDownloadAllEffects:)];
    if (@available(iOS 13.0, *)) {
        UIImageSymbolConfiguration *symCfg = [UIImageSymbolConfiguration configurationWithPointSize:12.5 weight:UIImageSymbolWeightSemibold];
        [guideBtn setImage:[UIImage systemImageNamed:@"doc.text" withConfiguration:symCfg] forState:UIControlStateNormal];
        guideBtn.tintColor = AMAccentGreenColor();
        guideBtn.imageEdgeInsets = UIEdgeInsetsMake(0, -4, 0, 4);
        [self.downloadAllBtn setImage:[UIImage systemImageNamed:@"arrow.down.doc" withConfiguration:symCfg] forState:UIControlStateNormal];
        self.downloadAllBtn.tintColor = AMAccentGreenColor();
        self.downloadAllBtn.imageEdgeInsets = UIEdgeInsetsMake(0, -4, 0, 4);
    }
    [aiRow addArrangedSubview:guideBtn];
    [aiRow addArrangedSubview:self.downloadAllBtn];
    [stack addArrangedSubview:aiRow];

    [stack addArrangedSubview:[self makeSectionLabel:@"EFFECT NAME"]];
    self.nameField = [[UITextField alloc] init];
    self.nameField.backgroundColor = AMInputSurfaceColor();
    self.nameField.textColor = [UIColor whiteColor];
    self.nameField.font = AMThemeFont(15.0, UIFontWeightMedium);
    self.nameField.layer.cornerRadius = 10.0;
    self.nameField.layer.borderWidth = 1.0;
    self.nameField.layer.borderColor = AMBorderColor().CGColor;
    self.nameField.attributedPlaceholder = [[NSAttributedString alloc] initWithString:@"e.g. Custom Glow"
                                                                           attributes:@{NSForegroundColorAttributeName: [UIColor colorWithWhite:0.55 alpha:1.0]}];
    UIView *pad = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 12, 42)];
    self.nameField.leftView = pad;
    self.nameField.leftViewMode = UITextFieldViewModeAlways;
    [self.nameField.heightAnchor constraintEqualToConstant:44.0].active = YES;
    [stack addArrangedSubview:self.nameField];

    [stack addArrangedSubview:[self makeSectionLabel:@"CATEGORY"]];
    UIStackView *catRow = [[UIStackView alloc] init];
    catRow.axis = UILayoutConstraintAxisHorizontal;
    catRow.spacing = 10.0;

    self.categoryPickBtn = [self makeActionButton:[NSString stringWithFormat:@"Category: %@", self.selectedCategoryName] action:@selector(onChooseCategory:)];
    UIButton *manageCatsBtn = [self makeActionButton:@"Manage Categories" action:@selector(onOpenManageCategories)];
    [manageCatsBtn setTitleColor:AMAccentGreenColor() forState:UIControlStateNormal];
    [manageCatsBtn setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [catRow addArrangedSubview:self.categoryPickBtn];
    [catRow addArrangedSubview:manageCatsBtn];
    [stack addArrangedSubview:catRow];

    [stack addArrangedSubview:[self makeSectionLabel:@"THUMBNAIL (OPTIONAL)"]];
    UIStackView *thumbRow = [[UIStackView alloc] init];
    thumbRow.axis = UILayoutConstraintAxisHorizontal;
    thumbRow.spacing = 12.0;
    thumbRow.alignment = UIStackViewAlignmentCenter;

    self.thumbPreview = [[UIImageView alloc] init];
    self.thumbPreview.backgroundColor = AMInputSurfaceColor();
    self.thumbPreview.contentMode = UIViewContentModeScaleAspectFill;
    self.thumbPreview.clipsToBounds = YES;
    self.thumbPreview.layer.cornerRadius = 10.0;
    self.thumbPreview.layer.borderWidth = 1.0;
    self.thumbPreview.layer.borderColor = AMBorderColor().CGColor;
    [self.thumbPreview.widthAnchor constraintEqualToConstant:58.0].active = YES;
    [self.thumbPreview.heightAnchor constraintEqualToConstant:58.0].active = YES;

    UIButton *pickThumbBtn = [self makeActionButton:@"Choose Image" action:@selector(onPickThumb)];
    self.clearThumbBtn = [self makeActionButton:@"Clear" action:@selector(onClearThumb)];
    self.clearThumbBtn.hidden = YES;

    [thumbRow addArrangedSubview:self.thumbPreview];
    [thumbRow addArrangedSubview:pickThumbBtn];
    [thumbRow addArrangedSubview:self.clearThumbBtn];
    [stack addArrangedSubview:thumbRow];

    UIStackView *xmlHdr = [[UIStackView alloc] init];
    xmlHdr.axis = UILayoutConstraintAxisHorizontal;
    xmlHdr.spacing = 6.0;
    xmlHdr.alignment = UIStackViewAlignmentCenter;
    [xmlHdr addArrangedSubview:[self makeSectionLabel:@"XML / GLSL CODE"]];
    [xmlHdr addArrangedSubview:[self makeCompactPill:@"Sample" action:@selector(onInsertSample)]];
    [xmlHdr addArrangedSubview:[self makeCompactPill:@"Open File" action:@selector(onPickXMLFile)]];
    [xmlHdr addArrangedSubview:[self makeCompactPill:@"Paste" action:@selector(onPasteXML)]];
    [stack addArrangedSubview:xmlHdr];

    self.xmlTextView = [[UITextView alloc] init];
    self.xmlTextView.backgroundColor = AMInputSurfaceColor();
    self.xmlTextView.textColor = [UIColor colorWithWhite:0.93 alpha:1.0];
    self.xmlTextView.font = [UIFont monospacedSystemFontOfSize:12.0 weight:UIFontWeightRegular];
    self.xmlTextView.layer.cornerRadius = 10.0;
    self.xmlTextView.layer.borderWidth = 1.0;
    self.xmlTextView.layer.borderColor = AMBorderColor().CGColor;
    self.xmlTextView.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.xmlTextView.autocorrectionType = UITextAutocorrectionTypeNo;
    self.xmlTextView.smartQuotesType = UITextSmartQuotesTypeNo;
    self.xmlTextView.textContainerInset = UIEdgeInsetsMake(10, 10, 10, 10);
    [self.xmlTextView.heightAnchor constraintEqualToConstant:200.0].active = YES;
    [stack addArrangedSubview:self.xmlTextView];

    [stack addArrangedSubview:[self makeSectionLabel:@"INSTALLED CUSTOM EFFECTS"]];
    self.installedListStack = [[UIStackView alloc] init];
    self.installedListStack.axis = UILayoutConstraintAxisVertical;
    self.installedListStack.spacing = 8.0;
    [stack addArrangedSubview:self.installedListStack];
    [self reloadInstalledList];
}

- (UILabel *)makeSectionLabel:(NSString *)text {
    UILabel *l = [[UILabel alloc] init];
    l.text = text;
    l.font = AMThemeFont(11.0, UIFontWeightBold);
    l.textColor = [UIColor colorWithWhite:0.65 alpha:1.0];
    return l;
}

- (UIButton *)makeActionButton:(NSString *)title action:(SEL)sel {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    b.titleLabel.font = AMThemeFont(13.0, UIFontWeightSemibold);
    b.backgroundColor = AMSurfaceColor();
    b.layer.cornerRadius = 8.0;
    b.layer.borderWidth = 1.0;
    b.layer.borderColor = AMBorderColor().CGColor;
    b.contentEdgeInsets = UIEdgeInsetsMake(8, 12, 8, 12);
    [b addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (UIButton *)makeCompactPill:(NSString *)title action:(SEL)sel {
    UIButton *b = [self makeActionButton:title action:sel];
    b.titleLabel.font = AMThemeFont(11.0, UIFontWeightBold);
    b.contentEdgeInsets = UIEdgeInsetsMake(5, 8, 5, 8);
    return b;
}

- (void)presentShareForFileURL:(NSURL *)url sourceButton:(UIButton *)btn {
    if (!url) return;
    UIActivityViewController *avc = [[UIActivityViewController alloc] initWithActivityItems:@[url] applicationActivities:nil];
    if (avc.popoverPresentationController && btn) {
        avc.popoverPresentationController.sourceView = btn;
        avc.popoverPresentationController.sourceRect = btn.bounds;
    }
    [self presentViewController:avc animated:YES completion:nil];
}

- (void)onDownloadGuide:(UIButton *)btn {
    NSString *srcPath = [[NSBundle mainBundle] pathForResource:@"AlightMotion_Effects_Guide" ofType:@"md"];
    NSString *dstPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"AlightMotion_Effects_Guide.md"];
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm removeItemAtPath:dstPath error:nil];

    if (srcPath && [fm fileExistsAtPath:srcPath]) {
        NSError *err = nil;
        if (![fm copyItemAtPath:srcPath toPath:dstPath error:&err]) {
            [self showAlertTitle:@"Export Failed" message:(err.localizedDescription ?: @"Could not copy guide file.")];
            return;
        }
        [self presentShareForFileURL:[NSURL fileURLWithPath:dstPath] sourceButton:btn];
        return;
    }

    NSString *fallback = @"# Alight Motion Custom Effects Guide\n\nBundle file AlightMotion_Effects_Guide.md not found in app bundle.\n";
    [fallback writeToFile:dstPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [self presentShareForFileURL:[NSURL fileURLWithPath:dstPath] sourceButton:btn];
}

- (void)onDownloadAllEffects:(UIButton *)btn {
    btn.enabled = NO;
    [btn setTitle:@"Packing..." forState:UIControlStateNormal];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *builtinDir = [[[NSBundle mainBundle] resourcePath] stringByAppendingPathComponent:@"BuiltinEffects"];
        NSArray<NSString *> *builtinFiles = [[fm contentsOfDirectoryAtPath:builtinDir error:nil]
                                             sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
        NSMutableArray<NSString *> *xmlNames = [NSMutableArray array];
        for (NSString *fn in builtinFiles) {
            if ([[fn pathExtension] caseInsensitiveCompare:@"xml"] == NSOrderedSame) {
                [xmlNames addObject:fn];
            }
        }

        NSString *customDir = AMCustomEffectsDir();
        NSArray<NSString *> *customFiles = [[fm contentsOfDirectoryAtPath:customDir error:nil]
                                            sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
        NSMutableArray<NSString *> *customXmlNames = [NSMutableArray array];
        for (NSString *fn in customFiles) {
            if ([[fn pathExtension] caseInsensitiveCompare:@"xml"] == NSOrderedSame) {
                [customXmlNames addObject:fn];
            }
        }

        NSMutableString *md = [NSMutableString stringWithCapacity:1500000];
        [md appendString:@"# Alight Motion — Complete Effects XML Reference\n\n"];
        [md appendFormat:@"Exported from Alight Motion iOS bundle. Contains **%lu built-in effects** and **%lu custom effects**.\n",
                         (unsigned long)xmlNames.count, (unsigned long)customXmlNames.count];
        [md appendString:@"Use alongside `AlightMotion_Effects_Guide.md` as real reference implementations for AI custom effect authoring.\n\n"];

        [md appendString:@"## Built-in Effects\n\n"];
        for (NSString *fn in xmlNames) {
            @autoreleasepool {
                NSString *p = [builtinDir stringByAppendingPathComponent:fn];
                NSString *xml = [NSString stringWithContentsOfFile:p encoding:NSUTF8StringEncoding error:nil];
                if (!xml) continue;
                [md appendFormat:@"### %@\n\n```xml\n%@\n```\n\n", fn, xml];
            }
        }

        if (customXmlNames.count > 0) {
            [md appendString:@"## Installed Custom Effects\n\n"];
            for (NSString *fn in customXmlNames) {
                @autoreleasepool {
                    NSString *p = [customDir stringByAppendingPathComponent:fn];
                    NSString *xml = [NSString stringWithContentsOfFile:p encoding:NSUTF8StringEncoding error:nil];
                    if (!xml) continue;
                    [md appendFormat:@"### %@\n\n```xml\n%@\n```\n\n", fn, xml];
                }
            }
        }

        NSString *dstPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"AlightMotion_All_Effects.md"];
        NSError *writeErr = nil;
        BOOL ok = [md writeToFile:dstPath atomically:YES encoding:NSUTF8StringEncoding error:&writeErr];

        dispatch_async(dispatch_get_main_queue(), ^{
            btn.enabled = YES;
            [btn setTitle:@"All Effects (.md)" forState:UIControlStateNormal];
            if (!ok) {
                [self showAlertTitle:@"Export Failed" message:(writeErr.localizedDescription ?: @"Could not write effects bundle.")];
                return;
            }
            [self presentShareForFileURL:[NSURL fileURLWithPath:dstPath] sourceButton:btn];
        });
    });
}

- (void)onChooseCategory:(UIButton *)btn {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Effect Category"
                                                                   message:@"Choose which category this custom effect will appear in."
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    NSDictionary *cfg = AMLoadCategoriesConfig();
    NSSet<NSNumber *> *deletedSet = [NSSet setWithArray:(cfg[@"deletedIds"] ?: @[])];
    NSDictionary *overrides = cfg[@"overrides"] ?: @{};

    if (![deletedSet containsObject:@(113)]) {
        NSDictionary *ov = overrides[@"113"];
        NSString *cname = ([ov[@"name"] isKindOfClass:[NSString class]] && [ov[@"name"] length] > 0) ? ov[@"name"] : @"Custom";
        [sheet addAction:[UIAlertAction actionWithTitle:cname style:UIAlertActionStyleDefault handler:^(__kindof UIAlertAction * _Nonnull a) {
            (void)a;
            self.selectedCategorySlug = @"custom";
            self.selectedCategoryName = cname;
            [self.categoryPickBtn setTitle:[NSString stringWithFormat:@"Category: %@", cname] forState:UIControlStateNormal];
        }]];
    }
    for (NSDictionary *uc in (cfg[@"userCategories"] ?: @[])) {
        NSString *uname = uc[@"name"];
        NSString *uslug = uc[@"slug"];
        if (uname.length == 0 || uslug.length == 0) continue;
        [sheet addAction:[UIAlertAction actionWithTitle:uname style:UIAlertActionStyleDefault handler:^(__kindof UIAlertAction * _Nonnull a) {
            (void)a;
            self.selectedCategorySlug = uslug;
            self.selectedCategoryName = uname;
            [self.categoryPickBtn setTitle:[NSString stringWithFormat:@"Category: %@", uname] forState:UIControlStateNormal];
        }]];
    }
    for (NSDictionary *b in AMBuiltinCategoryCatalog()) {
        int64_t cid = [b[@"id"] longLongValue];
        if (cid == 113 || [deletedSet containsObject:@(cid)]) continue;
        NSString *idKey = [NSString stringWithFormat:@"%lld", (long long)cid];
        NSDictionary *ov = overrides[idKey];
        NSString *bname = ([ov[@"name"] isKindOfClass:[NSString class]] && [ov[@"name"] length] > 0) ? ov[@"name"] : b[@"name"];
        NSString *bslug = b[@"slug"];
        [sheet addAction:[UIAlertAction actionWithTitle:bname style:UIAlertActionStyleDefault handler:^(__kindof UIAlertAction * _Nonnull a) {
            (void)a;
            self.selectedCategorySlug = bslug;
            self.selectedCategoryName = bname;
            [self.categoryPickBtn setTitle:[NSString stringWithFormat:@"Category: %@", bname] forState:UIControlStateNormal];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    if (sheet.popoverPresentationController) {
        sheet.popoverPresentationController.sourceView = btn;
        sheet.popoverPresentationController.sourceRect = btn.bounds;
    }
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)onOpenManageCategories {
    AMEffectCategoriesManagerVC *mgr = [[AMEffectCategoriesManagerVC alloc] init];
    mgr.modalPresentationStyle = UIModalPresentationPageSheet;
    [self presentViewController:mgr animated:YES completion:nil];
}

- (void)reloadInstalledList {
    for (UIView *v in [self.installedListStack.arrangedSubviews copy]) {
        [self.installedListStack removeArrangedSubview:v];
        [v removeFromSuperview];
    }
    NSString *dir = AMCustomEffectsDir();
    NSArray<NSString *> *files = [[[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:nil]
                                  sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
    NSInteger shown = 0;
    for (NSString *fn in files) {
        if ([[fn pathExtension] caseInsensitiveCompare:@"xml"] != NSOrderedSame) continue;
        shown++;
        UIView *card = [[UIView alloc] init];
        card.backgroundColor = AMSurfaceColor();
        card.layer.cornerRadius = 9.0;

        UIStackView *row = [[UIStackView alloc] init];
        row.translatesAutoresizingMaskIntoConstraints = NO;
        row.axis = UILayoutConstraintAxisHorizontal;
        row.alignment = UIStackViewAlignmentCenter;
        row.spacing = 8.0;
        [card addSubview:row];
        [NSLayoutConstraint activateConstraints:@[
            [row.topAnchor constraintEqualToAnchor:card.topAnchor constant:8],
            [row.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-8],
            [row.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:12],
            [row.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-10],
        ]];

        UILabel *lbl = [[UILabel alloc] init];
        lbl.text = [fn stringByDeletingPathExtension];
        lbl.textColor = [UIColor whiteColor];
        lbl.font = AMThemeFont(13.0, UIFontWeightMedium);

        UIButton *delBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        [delBtn setTitle:@"Delete" forState:UIControlStateNormal];
        [delBtn setTitleColor:[UIColor colorWithRed:0.95 green:0.38 blue:0.42 alpha:1.0] forState:UIControlStateNormal];
        delBtn.titleLabel.font = AMThemeFont(12.0, UIFontWeightSemibold);
        delBtn.accessibilityIdentifier = fn;
        [delBtn addTarget:self action:@selector(onDeleteEffect:) forControlEvents:UIControlEventTouchUpInside];

        [row addArrangedSubview:lbl];
        [row addArrangedSubview:delBtn];
        [self.installedListStack addArrangedSubview:card];
    }
    if (shown == 0) {
        UILabel *empty = [[UILabel alloc] init];
        empty.text = @"No custom XML effects created yet.";
        empty.textColor = [UIColor colorWithWhite:0.55 alpha:1.0];
        empty.font = AMThemeFont(13.0, UIFontWeightRegular);
        [self.installedListStack addArrangedSubview:empty];
    }
}

- (void)onClose {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)onInsertSample {
    if (self.nameField.text.length == 0) {
        self.nameField.text = @"Custom Invert";
    }
    self.xmlTextView.text = [NSString stringWithFormat:
        @"<?xml version='1.0' encoding='UTF-8' ?>\n"
        @"<effect id=\"com.alightcreative.effects.custom_invert\" compat=\"acScreenNorm-y\" name=\"Custom Invert\" desc=\"Inverts layer colors\" category=\"%@\" tags=\"custom\" thumb=\"thumb/copy-bg.webp\">\n"
        @"    <params>\n"
        @"        <texture id=\"inputImg\" srcType=\"content\" />\n"
        @"        <spinner id=\"strength\" default=\"1.0\" min=\"0.0\" max=\"1.0\" step=\"0.01\" label=\"Strength\" type=\"percent\" />\n"
        @"    </params>\n"
        @"    <shader type=\"fragment\" precision=\"high\"><![CDATA[\n"
        @"        void main() {\n"
        @"            vec4 c = texture2DCv(inputImg.texture, acScreenNorm);\n"
        @"            vec3 rgb = (c.a > 0.0001) ? (c.rgb / c.a) : vec3(0.0);\n"
        @"            vec3 inv = vec3(1.0) - rgb;\n"
        @"            gl_FragColor = vec4(mix(rgb, inv, strength) * c.a, c.a);\n"
        @"        }\n"
        @"    ]]></shader>\n"
        @"</effect>\n",
        AMXmlEscapeAttr(self.selectedCategorySlug ?: @"custom")];
}

- (void)onPasteXML {
    NSString *clip = [UIPasteboard generalPasteboard].string;
    if (clip.length > 0) self.xmlTextView.text = clip;
}

- (void)onPickXMLFile {
    UIDocumentPickerViewController *picker = nil;
    if (@available(iOS 14.0, *)) {
        picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeXML, UTTypePlainText, UTTypeText]
                                                                             asCopy:YES];
    } else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        picker = [[UIDocumentPickerViewController alloc] initWithDocumentTypes:@[@"public.xml", @"public.plain-text"]
                                                                        inMode:UIDocumentPickerModeImport];
#pragma clang diagnostic pop
    }
    picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    (void)controller;
    NSURL *u = urls.firstObject;
    if (!u) return;
    NSString *txt = [NSString stringWithContentsOfURL:u encoding:NSUTF8StringEncoding error:nil];
    if (txt.length > 0) {
        self.xmlTextView.text = txt;
        if (self.nameField.text.length == 0) {
            self.nameField.text = [[u lastPathComponent] stringByDeletingPathExtension];
        }
    }
}

- (void)onPickThumb {
    UIImagePickerController *picker = [[UIImagePickerController alloc] init];
    picker.sourceType = UIImagePickerControllerSourceTypePhotoLibrary;
    picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)onClearThumb {
    self.selectedThumb = nil;
    self.thumbPreview.image = nil;
    self.clearThumbBtn.hidden = YES;
}

- (void)imagePickerController:(UIImagePickerController *)picker didFinishPickingMediaWithInfo:(NSDictionary<UIImagePickerControllerInfoKey, id> *)info {
    UIImage *img = info[UIImagePickerControllerOriginalImage];
    if (img) {
        CGSize target = CGSizeMake(256, 256);
        UIGraphicsBeginImageContextWithOptions(target, NO, 1.0);
        [img drawInRect:CGRectMake(0, 0, target.width, target.height)];
        UIImage *resized = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
        self.selectedThumb = resized ?: img;
        self.thumbPreview.image = self.selectedThumb;
        self.clearThumbBtn.hidden = NO;
    }
    [picker dismissViewControllerAnimated:YES completion:nil];
}

- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker {
    [picker dismissViewControllerAnimated:YES completion:nil];
}

- (void)onDeleteEffect:(UIButton *)btn {
    NSString *fn = btn.accessibilityIdentifier;
    if (!fn) return;
    NSString *slug = [fn stringByDeletingPathExtension];
    [[NSFileManager defaultManager] removeItemAtPath:[AMCustomEffectsDir() stringByAppendingPathComponent:fn] error:nil];
    [[NSFileManager defaultManager] removeItemAtPath:[AMCustomThumbsDir() stringByAppendingPathComponent:[NSString stringWithFormat:@"custom_%@.png", slug]] error:nil];
    [self reloadInstalledList];
}

- (void)showAlertTitle:(NSString *)t message:(NSString *)m {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:t message:m preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)onImport {
    NSString *name = [self.nameField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (name.length == 0) {
        [self showAlertTitle:@"Missing Name" message:@"Enter a name for the custom effect."];
        return;
    }
    NSString *slug = AMSanitizeSlug(name);
    NSError *err = nil;
    NSString *prepared = AMPrepareEffectXML(self.xmlTextView.text, name, slug, self.selectedCategorySlug, &err);
    if (!prepared) {
        [self showAlertTitle:@"Invalid Effect Code" message:(err.localizedDescription ?: @"Could not parse XML/GLSL.")];
        return;
    }

    NSString *xmlPath = [AMCustomEffectsDir() stringByAppendingPathComponent:[slug stringByAppendingPathExtension:@"xml"]];
    if (![prepared writeToFile:xmlPath atomically:YES encoding:NSUTF8StringEncoding error:&err]) {
        [self showAlertTitle:@"Save Failed" message:(err.localizedDescription ?: @"Could not write XML file.")];
        return;
    }

    if (self.selectedThumb) {
        NSData *png = UIImagePNGRepresentation(self.selectedThumb);
        if (png) {
            NSString *thumbFn = [NSString stringWithFormat:@"custom_%@.png", slug];
            [png writeToFile:[AMCustomThumbsDir() stringByAppendingPathComponent:thumbFn] atomically:YES];
            NSMutableDictionary *map = AMLoadCustomThumbMap();
            map[name] = thumbFn;
            map[name.lowercaseString] = thumbFn;
            AMSaveCustomThumbMap(map);
        }
    }

    [self reloadInstalledList];
    UIAlertController *done = [UIAlertController alertControllerWithTitle:@"Custom Effect Created"
                                                                  message:[NSString stringWithFormat:@"'%@' is saved to %@. Reopen Alight Motion so its effect box loads, then tap it to apply to any layer.", name, self.selectedCategoryName ?: @"Custom"]
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [done addAction:[UIAlertAction actionWithTitle:@"Later" style:UIAlertActionStyleCancel handler:^(__kindof UIAlertAction * _Nonnull a) {
        (void)a;
        [self dismissViewControllerAnimated:YES completion:nil];
    }]];
    [done addAction:[UIAlertAction actionWithTitle:@"Close App Now" style:UIAlertActionStyleDefault handler:^(__kindof UIAlertAction * _Nonnull a) {
        (void)a;
        exit(0);
    }]];
    [self presentViewController:done animated:YES completion:nil];
}

@end

static IMP gOrigEffectCatViewWillAppear = NULL;
static const void *kAMImportPlusBtnKey = &kAMImportPlusBtnKey;
static const void *kAMImportPlusCatInfoKey = &kAMImportPlusCatInfoKey;

static NSDictionary *AMMatchingUserCategoryForTitle(NSString *t) {
    if (t.length == 0) return nil;
    for (NSDictionary *d in gAMActiveRuntimeCategories) {
        if ([d[@"isUser"] boolValue] && [d[@"name"] caseInsensitiveCompare:t] == NSOrderedSame) {
            return d;
        }
    }
    if ([t caseInsensitiveCompare:@"Custom"] == NSOrderedSame) {
        return @{@"name": @"Custom", @"slug": @"custom", @"isUser": @YES};
    }
    return nil;
}

static NSDictionary *AMFindUserCategoryInHierarchy(UIView *v, NSInteger depth) {
    if (!v || depth > 5) return nil;
    if ([v isKindOfClass:[UILabel class]]) {
        NSDictionary *hit = AMMatchingUserCategoryForTitle(((UILabel *)v).text);
        if (hit) return hit;
    }
    for (UIView *sub in v.subviews) {
        NSDictionary *hit = AMFindUserCategoryInHierarchy(sub, depth + 1);
        if (hit) return hit;
    }
    return nil;
}

static NSDictionary *AMUserCategoryForCategoryVC(UIViewController *vc) {
    NSDictionary *hit = AMMatchingUserCategoryForTitle(vc.title);
    if (hit) return hit;
    hit = AMMatchingUserCategoryForTitle(vc.navigationItem.title);
    if (hit) return hit;
    if (vc.navigationController) {
        hit = AMFindUserCategoryInHierarchy(vc.navigationController.navigationBar, 0);
        if (hit) return hit;
    }
    return AMFindUserCategoryInHierarchy(vc.view, 0);
}

@interface AMEffectImportPresenter : NSObject
+ (void)onTapPlus:(UIButton *)btn;
@end

@implementation AMEffectImportPresenter

+ (void)onTapPlus:(UIButton *)btn {
    UIViewController *vc = objc_getAssociatedObject(btn, kAMImportPlusBtnKey);
    if (!vc) return;
    NSDictionary *catInfo = objc_getAssociatedObject(btn, kAMImportPlusCatInfoKey);
    AMCustomEffectImporterVC *importer = [[AMCustomEffectImporterVC alloc] init];
    importer.initialCategorySlug = catInfo[@"slug"] ?: @"custom";
    importer.initialCategoryName = catInfo[@"name"] ?: @"Custom";
    importer.modalPresentationStyle = UIModalPresentationPageSheet;
    [vc presentViewController:importer animated:YES completion:nil];
}

@end

static void AMHook_effectCategoryViewWillAppear(id self, SEL _cmd, BOOL animated) {
    if (gOrigEffectCatViewWillAppear) {
        ((void (*)(id, SEL, BOOL))gOrigEffectCatViewWillAppear)(self, _cmd, animated);
    }

    UIViewController *vc = (UIViewController *)self;
    dispatch_async(dispatch_get_main_queue(), ^{
        NSDictionary *catInfo = AMUserCategoryForCategoryVC(vc);
        UIButton *existing = objc_getAssociatedObject(vc, kAMImportPlusBtnKey);
        if (!catInfo) {
            if (existing) existing.hidden = YES;
            return;
        }
        if (existing) {
            objc_setAssociatedObject(existing, kAMImportPlusCatInfoKey, catInfo, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            existing.hidden = NO;
            return;
        }

        UIButton *plusBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        plusBtn.translatesAutoresizingMaskIntoConstraints = NO;
        plusBtn.accessibilityLabel = @"Create Custom XML Effect";
        if (@available(iOS 13.0, *)) {
            UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:18.0 weight:UIImageSymbolWeightMedium];
            [plusBtn setImage:[UIImage systemImageNamed:@"plus" withConfiguration:cfg] forState:UIControlStateNormal];
        } else {
            [plusBtn setTitle:@"+" forState:UIControlStateNormal];
            plusBtn.titleLabel.font = AMThemeFont(22.0, UIFontWeightMedium);
        }
        plusBtn.tintColor = [UIColor whiteColor];
        plusBtn.backgroundColor = AMCircleBtnColor();
        plusBtn.layer.cornerRadius = 19.0;
        plusBtn.layer.borderWidth = 0.75;
        plusBtn.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.22].CGColor;
        [NSLayoutConstraint activateConstraints:@[
            [plusBtn.widthAnchor constraintEqualToConstant:38.0],
            [plusBtn.heightAnchor constraintEqualToConstant:38.0],
        ]];

        objc_setAssociatedObject(plusBtn, kAMImportPlusBtnKey, vc, OBJC_ASSOCIATION_ASSIGN);
        objc_setAssociatedObject(plusBtn, kAMImportPlusCatInfoKey, catInfo, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [plusBtn addTarget:[AMEffectImportPresenter class]
                    action:@selector(onTapPlus:)
          forControlEvents:UIControlEventTouchUpInside];

        if (vc.navigationController && !vc.navigationController.navigationBarHidden) {
            UIBarButtonItem *item = [[UIBarButtonItem alloc] initWithCustomView:plusBtn];
            vc.navigationItem.rightBarButtonItem = item;
        } else {
            [vc.view addSubview:plusBtn];
            [NSLayoutConstraint activateConstraints:@[
                [plusBtn.trailingAnchor constraintEqualToAnchor:vc.view.safeAreaLayoutGuide.trailingAnchor constant:-16.0],
                [plusBtn.topAnchor constraintEqualToAnchor:vc.view.safeAreaLayoutGuide.topAnchor constant:8.0],
            ]];
        }

        objc_setAssociatedObject(vc, kAMImportPlusBtnKey, plusBtn, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    });
}

// ============================================================================
// Module 4: Homepage Top-Bar Search Project Button
// ============================================================================

static BOOL gAMSearchModalOpen = NO;
static BOOL gAMFoldersModalOpen = NO;
static BOOL gAMImportModalOpen = NO;

static UIWindow *AMKeyWindow(void) {
    UIApplication *app = [UIApplication sharedApplication];
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in app.connectedScenes) {
            if (scene.activationState != UISceneActivationStateForegroundActive) continue;
            if ([scene isKindOfClass:[UIWindowScene class]]) {
                UIWindowScene *ws = (UIWindowScene *)scene;
                for (UIWindow *w in ws.windows) {
                    if (w.isKeyWindow) return w;
                }
                if (ws.windows.firstObject) return ws.windows.firstObject;
            }
        }
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    return app.keyWindow ?: app.windows.firstObject;
#pragma clang diagnostic pop
}

static UIViewController *AMTopMostViewController(void) {
    UIViewController *vc = AMKeyWindow().rootViewController;
    while (vc.presentedViewController) {
        vc = vc.presentedViewController;
    }
    return vc;
}

static UIViewController *AMFindMainVCInHierarchy(UIViewController *vc, NSInteger depth);

static BOOL AMVCTreeContainsEditor(UIViewController *vc, NSInteger depth) {
    if (!vc || depth > 10) return NO;
    NSString *clsName = NSStringFromClass([vc class]) ?: @"";
    if ([clsName containsString:@"ProjectEdit"] ||
        [clsName containsString:@"PreviewControlBar"] ||
        [clsName containsString:@"EffectPicker"] ||
        [clsName containsString:@"SettingsVC"] ||
        [clsName containsString:@"AMProjectSearchVC"] ||
        [clsName containsString:@"AMProjectFoldersVC"] ||
        [clsName containsString:@"AMFolderDetailVC"] ||
        [clsName containsString:@"AMAssignFolderVC"] ||
        [clsName containsString:@"AMProjectMultiPickerVC"] ||
        [clsName containsString:@"AMOriginalProjectsImporterVC"] ||
        [clsName containsString:@"Loading"] ||
        [clsName containsString:@"Splash"] ||
        [clsName containsString:@"Launch"]) {
        return YES;
    }
    for (UIViewController *child in vc.childViewControllers) {
        if (AMVCTreeContainsEditor(child, depth + 1)) return YES;
    }
    return NO;
}

static BOOL AMVCTreeHasPresentedModal(UIViewController *vc, NSInteger depth) {
    if (!vc || depth > 10) return NO;
    if (vc.presentedViewController != nil) return YES;
    for (UIViewController *child in vc.childViewControllers) {
        if (AMVCTreeHasPresentedModal(child, depth + 1)) return YES;
    }
    return NO;
}

static BOOL AMHomepageModalCovering(UIWindow *win, UIViewController *mainVC) {
    if (!win || !mainVC) return NO;
    if (AMVCTreeHasPresentedModal(win.rootViewController, 0)) return YES;
    UIView *hostView = mainVC.view;
    while (hostView && hostView.superview != win) {
        hostView = hostView.superview;
    }
    if (hostView) {
        NSArray<UIView *> *subs = win.subviews;
        NSUInteger hostIdx = [subs indexOfObject:hostView];
        if (hostIdx != NSNotFound) {
            for (NSUInteger i = hostIdx + 1; i < subs.count; i++) {
                UIView *sib = subs[i];
                if (sib.hidden || sib.alpha < 0.02) continue;
                return YES;
            }
        }
    }
    return NO;
}

static BOOL AMIsOnHomepage(UIWindow *win) {
    if (!win || !win.rootViewController) return NO;
    if (gAMIntroActive || gAMSearchModalOpen || gAMFoldersModalOpen || gAMImportModalOpen) return NO;
    UIViewController *root = win.rootViewController;
    if ([root isKindOfClass:[UINavigationController class]]) {
        UINavigationController *nav = (UINavigationController *)root;
        if (nav.viewControllers.count > 1) return NO;
    }
    UIViewController *mainVC = AMFindMainVCInHierarchy(root, 0);
    if (!mainVC || !mainVC.isViewLoaded || mainVC.view.window != win) return NO;
    if (AMVCTreeContainsEditor(root, 0)) return NO;
    return YES;
}

static NSString *AMExtractXMLAttr(NSString *tag, NSString *attrName) {
    NSString *pattern = [NSString stringWithFormat:@"\\b%@\\s*=\\s*[\"']([^\"']+)[\"']", attrName];
    NSRegularExpression *rx = [NSRegularExpression regularExpressionWithPattern:pattern options:NSRegularExpressionCaseInsensitive error:nil];
    NSTextCheckingResult *m = [rx firstMatchInString:tag options:0 range:NSMakeRange(0, tag.length)];
    if (!m || m.numberOfRanges < 2) return nil;
    NSString *val = [tag substringWithRange:[m rangeAtIndex:1]];
    val = [val stringByReplacingOccurrencesOfString:@"&amp;" withString:@"&"];
    val = [val stringByReplacingOccurrencesOfString:@"&quot;" withString:@"\""];
    val = [val stringByReplacingOccurrencesOfString:@"&lt;" withString:@"<"];
    val = [val stringByReplacingOccurrencesOfString:@"&gt;" withString:@">"];
    val = [val stringByReplacingOccurrencesOfString:@"&#39;" withString:@"'"];
    return [val stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

// Read-only SQLite3 loader via dlopen (no extra linker flags needed)
typedef struct sqlite3 sqlite3;
typedef struct sqlite3_stmt sqlite3_stmt;
typedef int (*am_sqlite3_open_v2_fn)(const char *, sqlite3 **, int, const char *);
typedef int (*am_sqlite3_prepare_v2_fn)(sqlite3 *, const char *, int, sqlite3_stmt **, const char **);
typedef int (*am_sqlite3_step_fn)(sqlite3_stmt *);
typedef const unsigned char *(*am_sqlite3_column_text_fn)(sqlite3_stmt *, int);
typedef int (*am_sqlite3_finalize_fn)(sqlite3_stmt *);
typedef int (*am_sqlite3_close_fn)(sqlite3 *);

static void AMScanSQLiteForProjects(NSString *dbPath,
                                    NSMutableArray<NSDictionary<NSString *, NSString *> *> *results,
                                    NSMutableSet<NSString *> *seenTitles) {
    static void *lib = NULL;
    static am_sqlite3_open_v2_fn p_open = NULL;
    static am_sqlite3_prepare_v2_fn p_prep = NULL;
    static am_sqlite3_step_fn p_step = NULL;
    static am_sqlite3_column_text_fn p_text = NULL;
    static am_sqlite3_finalize_fn p_fin = NULL;
    static am_sqlite3_close_fn p_close = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        lib = dlopen("/usr/lib/libsqlite3.dylib", RTLD_LAZY);
        if (lib) {
            p_open  = (am_sqlite3_open_v2_fn)dlsym(lib, "sqlite3_open_v2");
            p_prep  = (am_sqlite3_prepare_v2_fn)dlsym(lib, "sqlite3_prepare_v2");
            p_step  = (am_sqlite3_step_fn)dlsym(lib, "sqlite3_step");
            p_text  = (am_sqlite3_column_text_fn)dlsym(lib, "sqlite3_column_text");
            p_fin   = (am_sqlite3_finalize_fn)dlsym(lib, "sqlite3_finalize");
            p_close = (am_sqlite3_close_fn)dlsym(lib, "sqlite3_close");
        }
    });
    if (!p_open || !p_prep || !p_step || !p_text || !p_fin || !p_close) return;

    sqlite3 *db = NULL;
    // SQLITE_OPEN_READONLY = 1
    if (p_open(dbPath.UTF8String, &db, 1, NULL) != 0 || !db) {
        if (db) p_close(db);
        return;
    }

    // 1. Enumerate tables
    NSMutableArray<NSString *> *tables = [NSMutableArray array];
    sqlite3_stmt *st = NULL;
    if (p_prep(db, "SELECT name FROM sqlite_master WHERE type='table';", -1, &st, NULL) == 0 && st) {
        while (p_step(st) == 100) { // SQLITE_ROW = 100
            const unsigned char *tn = p_text(st, 0);
            if (tn) {
                NSString *tname = [NSString stringWithUTF8String:(const char *)tn];
                NSString *low = tname.lowercaseString;
                if ([low containsString:@"project"] || [low containsString:@"scene"]) {
                    [tables addObject:tname];
                }
            }
        }
        p_fin(st);
    }

    // 2. For each candidate table, find title/name + optional width/height/fps columns
    for (NSString *table in tables) {
        NSString *pragma = [NSString stringWithFormat:@"PRAGMA table_info(\"%@\");", table];
        sqlite3_stmt *pst = NULL;
        NSString *titleCol = nil;
        NSString *wCol = nil;
        NSString *hCol = nil;
        NSString *fpsCol = nil;
        if (p_prep(db, pragma.UTF8String, -1, &pst, NULL) == 0 && pst) {
            while (p_step(pst) == 100) {
                const unsigned char *cn = p_text(pst, 1);
                if (!cn) continue;
                NSString *col = [NSString stringWithUTF8String:(const char *)cn];
                NSString *low = col.lowercaseString;
                if (!titleCol && ([low isEqualToString:@"title"] || [low isEqualToString:@"ztitle"] ||
                                  [low isEqualToString:@"name"] || [low isEqualToString:@"zname"] ||
                                  [low isEqualToString:@"projectname"] || [low isEqualToString:@"zprojectname"])) {
                    titleCol = col;
                } else if (!wCol && ([low isEqualToString:@"width"] || [low isEqualToString:@"zwidth"])) {
                    wCol = col;
                } else if (!hCol && ([low isEqualToString:@"height"] || [low isEqualToString:@"zheight"])) {
                    hCol = col;
                } else if (!fpsCol && ([low isEqualToString:@"fps"] || [low isEqualToString:@"zfps"] || [low isEqualToString:@"framerate"])) {
                    fpsCol = col;
                }
            }
            p_fin(pst);
        }
        if (!titleCol) continue;

        NSMutableArray<NSString *> *selCols = [NSMutableArray arrayWithObject:[NSString stringWithFormat:@"\"%@\"", titleCol]];
        if (wCol) [selCols addObject:[NSString stringWithFormat:@"\"%@\"", wCol]];
        if (hCol) [selCols addObject:[NSString stringWithFormat:@"\"%@\"", hCol]];
        if (fpsCol) [selCols addObject:[NSString stringWithFormat:@"\"%@\"", fpsCol]];

        NSString *q = [NSString stringWithFormat:@"SELECT %@ FROM \"%@\" LIMIT 500;", [selCols componentsJoinedByString:@", "], table];
        sqlite3_stmt *qst = NULL;
        if (p_prep(db, q.UTF8String, -1, &qst, NULL) == 0 && qst) {
            while (p_step(qst) == 100) {
                const unsigned char *tv = p_text(qst, 0);
                if (!tv) continue;
                NSString *title = [[NSString stringWithUTF8String:(const char *)tv]
                                   stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                if (title.length == 0 || [seenTitles containsObject:title]) continue;
                [seenTitles addObject:title];

                int idx = 1;
                NSString *wv = nil, *hv = nil, *fv = nil;
                if (wCol) { const unsigned char *c = p_text(qst, idx++); if (c) wv = [NSString stringWithUTF8String:(const char *)c]; }
                if (hCol) { const unsigned char *c = p_text(qst, idx++); if (c) hv = [NSString stringWithUTF8String:(const char *)c]; }
                if (fpsCol) { const unsigned char *c = p_text(qst, idx++); if (c) fv = [NSString stringWithUTF8String:(const char *)c]; }
                NSMutableArray<NSString *> *parts = [NSMutableArray array];
                if (wv.length > 0 && hv.length > 0) [parts addObject:[NSString stringWithFormat:@"%@x%@", wv, hv]];
                if (fv.length > 0) [parts addObject:[NSString stringWithFormat:@"%@fps", fv]];
                NSString *meta = parts.count > 0 ? [parts componentsJoinedByString:@"  •  "] : @"Alight Motion Project";
                [results addObject:@{@"title": title, @"meta": meta, @"path": dbPath}];
            }
            p_fin(qst);
        }
    }

    p_close(db);
}

// Reads Alight Motion's `com.alightcreative.motion.sceneinfo` extended attribute (JSON or plist)
static NSString *AMFindThumbnailForProjectPath(NSString *projPath) {
    if (projPath.length == 0) return nil;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *stem = [[projPath lastPathComponent] stringByDeletingPathExtension];
    if (stem.length == 0) return nil;

    NSString *lib = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES).firstObject;
    NSArray<NSString *> *exts = @[@"jpg", @"jpeg", @"png", @"webp"];
    NSMutableArray<NSString *> *dirs = [NSMutableArray array];
    if (lib) {
        [dirs addObject:[lib stringByAppendingPathComponent:@"Caches/projectThumbnails"]];
        [dirs addObject:[lib stringByAppendingPathComponent:@"projectThumbnails"]];
    }
    NSString *parent = [projPath stringByDeletingLastPathComponent];
    if (parent.length > 0) [dirs addObject:parent];

    for (NSString *dir in dirs) {
        for (NSString *ext in exts) {
            NSString *cand = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.%@", stem, ext]];
            if ([fm fileExistsAtPath:cand]) return cand;
        }
        // Also check prefix match (e.g., <uuid>_thumb.jpg or <uuid>.xml.jpg)
        NSArray<NSString *> *files = [fm contentsOfDirectoryAtPath:dir error:nil];
        for (NSString *fn in files) {
            if ([fn hasPrefix:stem]) {
                NSString *e = fn.pathExtension.lowercaseString;
                if ([e isEqualToString:@"jpg"] || [e isEqualToString:@"jpeg"] || [e isEqualToString:@"png"] || [e isEqualToString:@"webp"]) {
                    return [dir stringByAppendingPathComponent:fn];
                }
            }
        }
    }
    return nil;
}

static NSDictionary *AMMakeProjectEntry(NSString *title, NSString *meta, NSString *filePath) {
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:filePath error:nil];
    NSDate *modDate = attrs[NSFileModificationDate] ?: [NSDate distantPast];
    NSString *thumb = AMFindThumbnailForProjectPath(filePath) ?: @"";

    static NSDateFormatter *df = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        df = [[NSDateFormatter alloc] init];
        df.dateStyle = NSDateFormatterMediumStyle;
        df.timeStyle = NSDateFormatterNoStyle;
    });
    NSString *dateStr = [modDate isEqualToDate:[NSDate distantPast]] ? @"" : [df stringFromDate:modDate];
    NSString *fullMeta = (dateStr.length > 0 && meta.length > 0)
        ? [NSString stringWithFormat:@"%@  •  %@", meta, dateStr]
        : (meta.length > 0 ? meta : dateStr);

    return @{
        @"title": title ?: @"",
        @"meta": fullMeta ?: @"Alight Motion Project",
        @"path": filePath ?: @"",
        @"thumb": thumb,
        @"date": modDate
    };
}

// Reads Alight Motion's `com.alightcreative.motion.sceneinfo` extended attribute (JSON or plist)
static NSDictionary *AMReadSceneInfoXattr(NSString *filePath) {
    const char *path = filePath.UTF8String;
    if (!path) return nil;
    ssize_t sz = getxattr(path, "com.alightcreative.motion.sceneinfo", NULL, 0, 0, 0);
    if (sz <= 0 || sz > 65536) return nil;
    NSMutableData *buf = [NSMutableData dataWithLength:(NSUInteger)sz];
    ssize_t got = getxattr(path, "com.alightcreative.motion.sceneinfo", buf.mutableBytes, (size_t)sz, 0, 0);
    if (got <= 0) return nil;

    id obj = [NSJSONSerialization JSONObjectWithData:buf options:0 error:nil];
    if (![obj isKindOfClass:[NSDictionary class]]) {
        obj = [NSPropertyListSerialization propertyListWithData:buf options:NSPropertyListImmutable format:NULL error:nil];
    }
    if (![obj isKindOfClass:[NSDictionary class]]) return nil;
    NSDictionary *d = (NSDictionary *)obj;
    NSString *title = [d[@"title"] isKindOfClass:[NSString class]] ? d[@"title"] :
                      ([d[@"name"] isKindOfClass:[NSString class]] ? d[@"name"] : nil);
    title = [title stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (title.length == 0) return nil;

    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    if (d[@"width"] && d[@"height"]) {
        [parts addObject:[NSString stringWithFormat:@"%@x%@", d[@"width"], d[@"height"]]];
    }
    if (d[@"fps"]) {
        [parts addObject:[NSString stringWithFormat:@"%@fps", d[@"fps"]]];
    }
    NSString *meta = parts.count > 0 ? [parts componentsJoinedByString:@"  •  "] : @"";
    return AMMakeProjectEntry(title, meta, filePath);
}

// Scans Alight Motion's real local project storage (`Library/` + `Documents/`)
static NSArray<NSDictionary *> *AMLoadUserProjectsFromDisk(void) {
    NSMutableArray<NSDictionary *> *results = [NSMutableArray array];
    NSMutableSet<NSString *> *seenPaths = [NSMutableSet set];
    NSMutableSet<NSString *> *seenTitles = [NSMutableSet set];
    NSFileManager *fm = [NSFileManager defaultManager];

    NSMutableArray<NSString *> *roots = [NSMutableArray array];
    NSString *lib = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES).firstObject;
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    if (lib) [roots addObject:lib];
    if (docs) [roots addObject:docs];

    NSSet<NSString *> *skipTopDirs = [NSSet setWithArray:@[
        @"Caches", @"Preferences", @"Cookies", @"SplashBoard", @"Saved Application State",
        @"HTTPStorages", @"WebKit", @"CustomEffects", @"ProjectFolders", @"Firebase",
        @"Google", @"Amplitude", @"Logs", @"Crashlytics", @"com.apple.nsurlsessiond", @"Inbox"
    ]];

    for (NSString *root in roots) {
        NSDirectoryEnumerator<NSString *> *en = [fm enumeratorAtPath:root];
        NSString *rel = nil;
        NSInteger scanned = 0;
        while ((rel = [en nextObject]) != nil && scanned < 6000) {
            scanned++;
            NSString *firstComp = rel.pathComponents.firstObject ?: @"";
            if ([skipTopDirs containsObject:firstComp]) {
                [en skipDescendants];
                continue;
            }
            NSString *full = [root stringByAppendingPathComponent:rel];
            if ([seenPaths containsObject:full]) continue;

            BOOL isDir = NO;
            if (![fm fileExistsAtPath:full isDirectory:&isDir] || isDir) continue;

            NSString *ext = rel.pathExtension.lowercaseString;
            if ([ext isEqualToString:@"xml"] || ext.length == 0 || [ext isEqualToString:@"amproj"]) {
                NSDictionary *xinfo = AMReadSceneInfoXattr(full);
                if (xinfo) {
                    NSString *t = xinfo[@"title"];
                    if (t.length > 0 && ![seenTitles containsObject:t]) {
                        [seenTitles addObject:t];
                        [seenPaths addObject:full];
                        [results addObject:xinfo];
                        continue;
                    }
                }
            }

            if ([ext isEqualToString:@"xml"] || ext.length == 0) {
                NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:full];
                NSData *head = [fh readDataOfLength:8192];
                [fh closeFile];
                if (head.length < 16) continue;
                NSString *txt = [[NSString alloc] initWithData:head encoding:NSUTF8StringEncoding];
                if (!txt || ![txt containsString:@"<scene"]) continue;
                NSRange sStart = [txt rangeOfString:@"<scene"];
                NSRange sEnd = [txt rangeOfString:@">" options:0 range:NSMakeRange(sStart.location, txt.length - sStart.location)];
                if (sEnd.location == NSNotFound) continue;
                NSString *tag = [txt substringWithRange:NSMakeRange(sStart.location, (sEnd.location - sStart.location) + 1)];
                NSString *title = AMExtractXMLAttr(tag, @"title");
                if (title.length == 0 || [seenTitles containsObject:title]) continue;
                [seenTitles addObject:title];
                [seenPaths addObject:full];

                NSString *w = AMExtractXMLAttr(tag, @"width");
                NSString *h = AMExtractXMLAttr(tag, @"height");
                NSString *fps = AMExtractXMLAttr(tag, @"fps");
                NSMutableArray<NSString *> *parts = [NSMutableArray array];
                if (w.length > 0 && h.length > 0) [parts addObject:[NSString stringWithFormat:@"%@x%@", w, h]];
                if (fps.length > 0) [parts addObject:[NSString stringWithFormat:@"%@fps", fps]];
                NSString *meta = parts.count > 0 ? [parts componentsJoinedByString:@"  •  "] : @"";
                [results addObject:AMMakeProjectEntry(title, meta, full)];
            } else if ([ext isEqualToString:@"amproj"]) {
                NSString *title = [[rel lastPathComponent] stringByDeletingPathExtension];
                if (title.length == 0 || [seenTitles containsObject:title]) continue;
                [seenTitles addObject:title];
                [seenPaths addObject:full];
                [results addObject:AMMakeProjectEntry(title, @".amproj", full)];
            }
        }
    }
    return results;
}

typedef NS_ENUM(NSInteger, AMProjectSortMode) {
    AMProjectSortDateNewest = 0,
    AMProjectSortDateOldest = 1,
    AMProjectSortNameAsc    = 2,
    AMProjectSortNameDesc   = 3
};

// ============================================================================
// Native Local Project Opener (AlightMotion 6.2.60 build 869 ARM64)
// Calls verified Swift entry points:
//   - 0x1025b55cc: String._unconditionallyBridgeFromObjectiveC(NSString?)
//   - 0x100245cd0: Load SceneInfo by project filename stem (<UUID>.xml -> <UUID>)
//   - 0x100514ea0: MainVC.openProjectEdit(sceneInfo:onDismiss:)
// ============================================================================

static intptr_t AMMainBinarySlide(void) {
    uint32_t cnt = _dyld_image_count();
    for (uint32_t i = 0; i < cnt; ++i) {
        const char *nm = _dyld_get_image_name(i);
        if (nm && strstr(nm, "/AlightMotion.app/AlightMotion") != NULL) {
            return _dyld_get_image_vmaddr_slide(i);
        }
    }
    return _dyld_get_image_vmaddr_slide(0);
}

static UIViewController *AMFindMainVCInHierarchy(UIViewController *vc, NSInteger depth) {
    if (!vc || depth > 10) return nil;
    Class mainCls = NSClassFromString(@"_TtC12AlightMotion6MainVC");
    if (mainCls && [vc isKindOfClass:mainCls]) return vc;
    if ([vc isKindOfClass:[UINavigationController class]]) {
        for (UIViewController *c in ((UINavigationController *)vc).viewControllers) {
            UIViewController *hit = AMFindMainVCInHierarchy(c, depth + 1);
            if (hit) return hit;
        }
    }
    if ([vc isKindOfClass:[UITabBarController class]]) {
        for (UIViewController *c in ((UITabBarController *)vc).viewControllers) {
            UIViewController *hit = AMFindMainVCInHierarchy(c, depth + 1);
            if (hit) return hit;
        }
    }
    for (UIViewController *c in vc.childViewControllers) {
        UIViewController *hit = AMFindMainVCInHierarchy(c, depth + 1);
        if (hit) return hit;
    }
    if (vc.presentedViewController) {
        UIViewController *hit = AMFindMainVCInHierarchy(vc.presentedViewController, depth + 1);
        if (hit) return hit;
    }
    return nil;
}

static BOOL AMOpenLocalProjectInMainVC(NSString *projectPath) {
    if (projectPath.length == 0) return NO;
#if defined(__arm64__)
    UIWindow *win = AMKeyWindow();
    UIViewController *mainVC = AMFindMainVCInHierarchy(win.rootViewController, 0);
    if (!mainVC) return NO;

    NSString *stem = [[projectPath lastPathComponent] stringByDeletingPathExtension];
    if (stem.length == 0) return NO;

    intptr_t slide = AMMainBinarySlide();
    uintptr_t fnBridgeString  = (uintptr_t)(0x1025b55ccULL + slide);
    uintptr_t fnLoadSceneInfo = (uintptr_t)(0x100245cd0ULL + slide);
    uintptr_t fnBridgeRelease = (uintptr_t)(0x1025bb404ULL + slide);
    uintptr_t fnErrorRelease  = (uintptr_t)(0x1025bb56cULL + slide);
    uintptr_t fnOpenProject   = (uintptr_t)(0x100514ea0ULL + slide);
    uintptr_t fnSceneInfoMeta = (uintptr_t)(0x1003c5d54ULL + slide);

    // Query SceneInfo metadata and allocate properly sized/aligned buffer
    void *meta = ((void *(*)(uintptr_t))fnSceneInfoMeta)(0);
    if (!meta) return NO;
    void *vwt = *(void **)((uintptr_t)meta - 8);
    size_t sz = *(size_t *)((uintptr_t)vwt + 0x40);
    if (sz == 0 || sz > 4096) sz = 1024;
    uint8_t *sceneInfoBuf = (uint8_t *)calloc(1, sz + 64);
    if (!sceneInfoBuf) return NO;

    // 1. Bridge NSString stem -> Swift String (a, b)
    typedef struct { uint64_t a; uint64_t b; } AMSwiftStr;
    AMSwiftStr s = ((AMSwiftStr (*)(void *))fnBridgeString)((__bridge void *)stem);

    // 2. Call 0x100245cd0(x0=s.a, x1=s.b, w2=1, x8=sceneInfoBuf, x21=0) -> x21=err
    struct { uint64_t s0, s1, buf, fn, err; } loadArgs = { s.a, s.b, (uint64_t)sceneInfoBuf, fnLoadSceneInfo, 0 };
    asm volatile(
        "stp x19, x20, [sp, #-32]!\n"
        "str x21, [sp, #16]\n"
        "mov x19, %[args]\n"
        "ldp x0, x1, [x19, #0]\n"
        "mov w2, #1\n"
        "ldp x8, x9, [x19, #16]\n"
        "mov x21, #0\n"
        "blr x9\n"
        "str x21, [x19, #32]\n"
        "ldr x21, [sp, #16]\n"
        "ldp x19, x20, [sp], #32\n"
        :
        : [args] "r"(&loadArgs)
        : "x0", "x1", "x2", "x3", "x4", "x5", "x6", "x7", "x8", "x9", "x10", "x11", "x12", "x13", "x14", "x15", "x16", "x17", "x30",
          "v0", "v1", "v2", "v3", "v4", "v5", "v6", "v7", "v16", "v17", "v18", "v19", "v20", "v21", "v22", "v23",
          "v24", "v25", "v26", "v27", "v28", "v29", "v30", "v31", "cc", "memory"
    );

    // Release bridged Swift String object
    ((void (*)(uint64_t))fnBridgeRelease)(s.b);

    if (loadArgs.err != 0) {
        ((void (*)(uint64_t))fnErrorRelease)(loadArgs.err);
        free(sceneInfoBuf);
        return NO;
    }

    // 3. Call MainVC.openProjectEdit(x0=sceneInfoBuf, x1=0, x2=0, x20=mainVC)
    struct { uint64_t info, selfObj, fn; } openArgs = {
        (uint64_t)sceneInfoBuf, (uint64_t)(__bridge void *)mainVC, fnOpenProject
    };
    asm volatile(
        "stp x19, x20, [sp, #-16]!\n"
        "mov x19, %[args]\n"
        "ldp x0, x20, [x19, #0]\n"
        "ldr x9, [x19, #16]\n"
        "mov x1, #0\n"
        "mov x2, #0\n"
        "blr x9\n"
        "ldp x19, x20, [sp], #16\n"
        :
        : [args] "r"(&openArgs)
        : "x0", "x1", "x2", "x3", "x4", "x5", "x6", "x7", "x8", "x9", "x10", "x11", "x12", "x13", "x14", "x15", "x16", "x17", "x30",
          "v0", "v1", "v2", "v3", "v4", "v5", "v6", "v7", "v16", "v17", "v18", "v19", "v20", "v21", "v22", "v23",
          "v24", "v25", "v26", "v27", "v28", "v29", "v30", "v31", "cc", "memory"
    );

    // Destroy temporary SceneInfo value via its Value Witness Table
    typedef void (*AMDestroyFn)(void *, void *);
    AMDestroyFn destroyFn = *(AMDestroyFn *)((uintptr_t)vwt + 8);
    if (destroyFn) destroyFn(sceneInfoBuf, meta);
    free(sceneInfoBuf);
    return YES;
#else
    return NO;
#endif
}

@interface AMProjectSearchVC : UIViewController <UITableViewDataSource, UITableViewDelegate, UITextFieldDelegate>
@property (nonatomic, copy) NSArray<NSDictionary *> *allProjects;
@property (nonatomic, strong) NSArray<NSDictionary *> *filteredProjects;
@property (nonatomic, strong) UITextField *searchField;
@property (nonatomic, strong) UIButton *filterButton;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, assign) AMProjectSortMode sortMode;
@property (nonatomic, strong) NSCache<NSString *, UIImage *> *thumbCache;
@end

@implementation AMProjectSearchVC

- (void)viewDidLoad {
    [super viewDidLoad];
    if (@available(iOS 13.0, *)) {
        self.overrideUserInterfaceStyle = UIUserInterfaceStyleLight;
    }
    self.thumbCache = [[NSCache alloc] init];
    self.sortMode = AMProjectSortDateNewest;

    UIColor *bgColor = [UIColor colorWithRed:0.965 green:0.969 blue:0.984 alpha:1.0]; // #F6F7FB
    UIColor *navy = [UIColor colorWithRed:0.114 green:0.118 blue:0.173 alpha:1.0];    // #1D1E2C
    UIColor *muted = [UIColor colorWithRed:0.557 green:0.573 blue:0.643 alpha:1.0];   // #8E92A4

    self.view.backgroundColor = bgColor;
    self.title = @"Search Projects";

    if (@available(iOS 13.0, *)) {
        UINavigationBarAppearance *app = [[UINavigationBarAppearance alloc] init];
        [app configureWithOpaqueBackground];
        app.backgroundColor = bgColor;
        app.shadowColor = [UIColor clearColor];
        app.titleTextAttributes = @{
            NSForegroundColorAttributeName: navy,
            NSFontAttributeName: AMThemeFont(17.0, UIFontWeightBold)
        };
        self.navigationController.navigationBar.standardAppearance = app;
        self.navigationController.navigationBar.scrollEdgeAppearance = app;
    }

    UIBarButtonItem *closeItem = [[UIBarButtonItem alloc] initWithTitle:@"Close"
                                                                  style:UIBarButtonItemStylePlain
                                                                 target:self
                                                                 action:@selector(onClose)];
    closeItem.tintColor = navy;
    self.navigationItem.leftBarButtonItem = closeItem;

    // Rounded white search bar
    UIView *searchBox = [[UIView alloc] init];
    searchBox.translatesAutoresizingMaskIntoConstraints = NO;
    searchBox.backgroundColor = [UIColor whiteColor];
    searchBox.layer.cornerRadius = 14.0;
    searchBox.layer.borderWidth = 1.0;
    searchBox.layer.borderColor = [UIColor colorWithRed:0.114 green:0.118 blue:0.173 alpha:0.08].CGColor;
    searchBox.layer.shadowColor = [UIColor blackColor].CGColor;
    searchBox.layer.shadowOpacity = 0.04;
    searchBox.layer.shadowRadius = 8.0;
    searchBox.layer.shadowOffset = CGSizeMake(0, 2);
    [self.view addSubview:searchBox];

    UIImageView *mag = [[UIImageView alloc] init];
    mag.translatesAutoresizingMaskIntoConstraints = NO;
    if (@available(iOS 13.0, *)) {
        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:15.0 weight:UIImageSymbolWeightMedium];
        mag.image = [UIImage systemImageNamed:@"magnifyingglass" withConfiguration:cfg];
    }
    mag.tintColor = muted;
    [searchBox addSubview:mag];

    self.searchField = [[UITextField alloc] init];
    self.searchField.translatesAutoresizingMaskIntoConstraints = NO;
    self.searchField.font = AMThemeFont(15.0, UIFontWeightMedium);
    self.searchField.textColor = navy;
    self.searchField.tintColor = navy;
    self.searchField.clearButtonMode = UITextFieldViewModeWhileEditing;
    self.searchField.returnKeyType = UIReturnKeySearch;
    self.searchField.autocorrectionType = UITextAutocorrectionTypeNo;
    self.searchField.delegate = self;
    self.searchField.attributedPlaceholder = [[NSAttributedString alloc] initWithString:@"Search your projects..."
                                                                             attributes:@{NSForegroundColorAttributeName: muted}];
    [self.searchField addTarget:self action:@selector(onSearchTextChanged:) forControlEvents:UIControlEventEditingChanged];
    [searchBox addSubview:self.searchField];

    // Filter / Sort button right next to the search bar
    self.filterButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.filterButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.filterButton.accessibilityLabel = @"Filter Projects";
    self.filterButton.backgroundColor = [UIColor whiteColor];
    self.filterButton.tintColor = navy;
    self.filterButton.layer.cornerRadius = 14.0;
    self.filterButton.layer.borderWidth = 1.0;
    self.filterButton.layer.borderColor = [UIColor colorWithRed:0.114 green:0.118 blue:0.173 alpha:0.08].CGColor;
    self.filterButton.layer.shadowColor = [UIColor blackColor].CGColor;
    self.filterButton.layer.shadowOpacity = 0.04;
    self.filterButton.layer.shadowRadius = 8.0;
    self.filterButton.layer.shadowOffset = CGSizeMake(0, 2);
    if (@available(iOS 13.0, *)) {
        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:17.0 weight:UIImageSymbolWeightMedium];
        [self.filterButton setImage:[UIImage systemImageNamed:@"line.3.horizontal.decrease.circle" withConfiguration:cfg] forState:UIControlStateNormal];
    } else {
        [self.filterButton setTitle:@"Sort" forState:UIControlStateNormal];
    }
    if (@available(iOS 14.0, *)) {
        self.filterButton.showsMenuAsPrimaryAction = YES;
        [self rebuildFilterMenu];
    } else {
        [self.filterButton addTarget:self action:@selector(onTapFilterFallback) forControlEvents:UIControlEventTouchUpInside];
    }
    [self.view addSubview:self.filterButton];

    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.tableView.backgroundColor = bgColor;
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    self.tableView.contentInset = UIEdgeInsetsMake(6.0, 0.0, 20.0, 0.0);
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    [self.view addSubview:self.tableView];

    [NSLayoutConstraint activateConstraints:@[
        [searchBox.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:8.0],
        [searchBox.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16.0],
        [searchBox.trailingAnchor constraintEqualToAnchor:self.filterButton.leadingAnchor constant:-10.0],
        [searchBox.heightAnchor constraintEqualToConstant:46.0],

        [self.filterButton.topAnchor constraintEqualToAnchor:searchBox.topAnchor],
        [self.filterButton.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16.0],
        [self.filterButton.widthAnchor constraintEqualToConstant:46.0],
        [self.filterButton.heightAnchor constraintEqualToConstant:46.0],

        [mag.leadingAnchor constraintEqualToAnchor:searchBox.leadingAnchor constant:14.0],
        [mag.centerYAnchor constraintEqualToAnchor:searchBox.centerYAnchor],
        [mag.widthAnchor constraintEqualToConstant:18.0],
        [mag.heightAnchor constraintEqualToConstant:18.0],

        [self.searchField.leadingAnchor constraintEqualToAnchor:mag.trailingAnchor constant:10.0],
        [self.searchField.trailingAnchor constraintEqualToAnchor:searchBox.trailingAnchor constant:-10.0],
        [self.searchField.topAnchor constraintEqualToAnchor:searchBox.topAnchor],
        [self.searchField.bottomAnchor constraintEqualToAnchor:searchBox.bottomAnchor],

        [self.tableView.topAnchor constraintEqualToAnchor:searchBox.bottomAnchor constant:10.0],
        [self.tableView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
    ]];

    [self applyFilterAndSort];
}

- (void)rebuildFilterMenu {
    if (@available(iOS 14.0, *)) {
        __weak AMProjectSearchVC *weakSelf = self;
        UIAction *(^mk)(NSString *, AMProjectSortMode) = ^UIAction *(NSString *title, AMProjectSortMode mode) {
            UIAction *a = [UIAction actionWithTitle:title image:nil identifier:nil handler:^(__kindof UIAction * _Nonnull action) {
                (void)action;
                weakSelf.sortMode = mode;
                [weakSelf rebuildFilterMenu];
                [weakSelf applyFilterAndSort];
            }];
            a.state = (self.sortMode == mode) ? UIMenuElementStateOn : UIMenuElementStateOff;
            return a;
        };
        self.filterButton.menu = [UIMenu menuWithTitle:@"Filter & Sort" children:@[
            mk(@"Date (Newest First)", AMProjectSortDateNewest),
            mk(@"Date (Oldest First)", AMProjectSortDateOldest),
            mk(@"Name (A → Z)", AMProjectSortNameAsc),
            mk(@"Name (Z → A)", AMProjectSortNameDesc),
        ]];
    }
}

- (void)onTapFilterFallback {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Filter & Sort" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    void (^addOpt)(NSString *, AMProjectSortMode) = ^(NSString *t, AMProjectSortMode m) {
        [ac addAction:[UIAlertAction actionWithTitle:t style:UIAlertActionStyleDefault handler:^(__kindof UIAlertAction * _Nonnull a) {
            (void)a;
            self.sortMode = m;
            [self applyFilterAndSort];
        }]];
    };
    addOpt(@"Date (Newest First)", AMProjectSortDateNewest);
    addOpt(@"Date (Oldest First)", AMProjectSortDateOldest);
    addOpt(@"Name (A → Z)", AMProjectSortNameAsc);
    addOpt(@"Name (Z → A)", AMProjectSortNameDesc);
    [ac addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)applyFilterAndSort {
    NSString *q = [self.searchField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSMutableArray<NSDictionary *> *list = [NSMutableArray array];
    for (NSDictionary *item in (self.allProjects ?: @[])) {
        NSString *title = item[@"title"] ?: @"";
        if (q.length == 0 || [title localizedCaseInsensitiveContainsString:q]) {
            [list addObject:item];
        }
    }
    AMProjectSortMode mode = self.sortMode;
    [list sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        if (mode == AMProjectSortNameAsc) {
            return [a[@"title"] localizedCaseInsensitiveCompare:b[@"title"]];
        } else if (mode == AMProjectSortNameDesc) {
            return [b[@"title"] localizedCaseInsensitiveCompare:a[@"title"]];
        } else if (mode == AMProjectSortDateOldest) {
            NSDate *da = a[@"date"] ?: [NSDate distantPast];
            NSDate *db = b[@"date"] ?: [NSDate distantPast];
            return [da compare:db];
        } else {
            NSDate *da = a[@"date"] ?: [NSDate distantPast];
            NSDate *db = b[@"date"] ?: [NSDate distantPast];
            return [db compare:da];
        }
    }];
    self.filteredProjects = list;
    [self.tableView reloadData];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    gAMSearchModalOpen = YES;
    [self.searchField becomeFirstResponder];
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    if (self.isBeingDismissed || self.navigationController.isBeingDismissed) {
        gAMSearchModalOpen = NO;
    }
}

- (void)onClose {
    gAMSearchModalOpen = NO;
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)onSearchTextChanged:(UITextField *)tf {
    (void)tf;
    [self applyFilterAndSort];
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView; (void)section;
    return self.filteredProjects.count > 0 ? self.filteredProjects.count : 1;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView; (void)indexPath;
    return 82.0;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"AMSearchCardCell"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"AMSearchCardCell"];
        cell.backgroundColor = [UIColor clearColor];
        cell.contentView.backgroundColor = [UIColor clearColor];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;

        UIView *card = [[UIView alloc] init];
        card.tag = 101;
        card.translatesAutoresizingMaskIntoConstraints = NO;
        card.backgroundColor = [UIColor whiteColor];
        card.layer.cornerRadius = 14.0;
        card.layer.shadowColor = [UIColor blackColor].CGColor;
        card.layer.shadowOpacity = 0.04;
        card.layer.shadowRadius = 8.0;
        card.layer.shadowOffset = CGSizeMake(0, 2);
        [cell.contentView addSubview:card];

        UIImageView *thumbIV = [[UIImageView alloc] init];
        thumbIV.tag = 103;
        thumbIV.translatesAutoresizingMaskIntoConstraints = NO;
        thumbIV.backgroundColor = [UIColor colorWithRed:0.933 green:0.941 blue:0.969 alpha:1.0]; // #EEF0F7
        thumbIV.layer.cornerRadius = 10.0;
        thumbIV.clipsToBounds = YES;
        thumbIV.contentMode = UIViewContentModeScaleAspectFill;
        [card addSubview:thumbIV];

        UILabel *titleLbl = [[UILabel alloc] init];
        titleLbl.tag = 104;
        titleLbl.translatesAutoresizingMaskIntoConstraints = NO;
        titleLbl.font = AMThemeFont(15.0, UIFontWeightBold);
        titleLbl.textColor = [UIColor colorWithRed:0.114 green:0.118 blue:0.173 alpha:1.0];
        [card addSubview:titleLbl];

        UILabel *metaLbl = [[UILabel alloc] init];
        metaLbl.tag = 105;
        metaLbl.translatesAutoresizingMaskIntoConstraints = NO;
        metaLbl.font = AMThemeFont(12.0, UIFontWeightRegular);
        metaLbl.textColor = [UIColor colorWithRed:0.557 green:0.573 blue:0.643 alpha:1.0];
        [card addSubview:metaLbl];

        [NSLayoutConstraint activateConstraints:@[
            [card.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:5.0],
            [card.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-5.0],
            [card.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:16.0],
            [card.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-16.0],

            [thumbIV.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:10.0],
            [thumbIV.centerYAnchor constraintEqualToAnchor:card.centerYAnchor],
            [thumbIV.widthAnchor constraintEqualToConstant:54.0],
            [thumbIV.heightAnchor constraintEqualToConstant:54.0],

            [titleLbl.leadingAnchor constraintEqualToAnchor:thumbIV.trailingAnchor constant:12.0],
            [titleLbl.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-14.0],
            [titleLbl.topAnchor constraintEqualToAnchor:card.topAnchor constant:16.0],

            [metaLbl.leadingAnchor constraintEqualToAnchor:titleLbl.leadingAnchor],
            [metaLbl.trailingAnchor constraintEqualToAnchor:titleLbl.trailingAnchor],
            [metaLbl.topAnchor constraintEqualToAnchor:titleLbl.bottomAnchor constant:4.0],
        ]];
    }

    UIImageView *thumbIV = (UIImageView *)[cell.contentView viewWithTag:103];
    UILabel *titleLbl = (UILabel *)[cell.contentView viewWithTag:104];
    UILabel *metaLbl = (UILabel *)[cell.contentView viewWithTag:105];

    if (self.filteredProjects.count == 0) {
        titleLbl.text = self.allProjects.count == 0 ? @"No local projects found" : @"No matching projects";
        metaLbl.text = self.allProjects.count == 0 ? @"Create or import a project first" : @"Try a different search term";
        thumbIV.contentMode = UIViewContentModeCenter;
        if (@available(iOS 13.0, *)) {
            thumbIV.image = [UIImage systemImageNamed:@"magnifyingglass"];
            thumbIV.tintColor = [UIColor colorWithRed:0.557 green:0.573 blue:0.643 alpha:1.0];
        }
        return cell;
    }

    NSDictionary *item = self.filteredProjects[indexPath.row];
    titleLbl.text = item[@"title"];
    metaLbl.text = item[@"meta"];

    NSString *thumbPath = item[@"thumb"];
    UIImage *img = nil;
    if (thumbPath.length > 0) {
        img = [self.thumbCache objectForKey:thumbPath];
        if (!img) {
            img = [UIImage imageWithContentsOfFile:thumbPath];
            if (img) [self.thumbCache setObject:img forKey:thumbPath];
        }
    }
    if (img) {
        thumbIV.contentMode = UIViewContentModeScaleAspectFill;
        thumbIV.image = img;
    } else {
        thumbIV.contentMode = UIViewContentModeCenter;
        if (@available(iOS 13.0, *)) {
            UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:20.0 weight:UIImageSymbolWeightMedium];
            thumbIV.image = [UIImage systemImageNamed:@"film.stack" withConfiguration:cfg];
            thumbIV.tintColor = [UIColor colorWithRed:0.114 green:0.118 blue:0.173 alpha:1.0];
        }
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (self.filteredProjects.count == 0) return;
    NSDictionary *item = self.filteredProjects[indexPath.row];
    NSString *path = item[@"path"];
    gAMSearchModalOpen = NO;
    [self dismissViewControllerAnimated:YES completion:^{
        if (path.length > 0) {
            if (!AMOpenLocalProjectInMainVC(path)) {
                AMOpenLocalFileInApp([NSURL fileURLWithPath:path]);
            }
        }
    }];
}

@end

// ============================================================================
// Module 4B: Homepage Project Folders & Selection-Mode Assign Folder
// ============================================================================

static NSString *AMProjectFoldersFilePath(void) {
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    if (docs.length == 0) return nil;
    NSString *dir = [docs stringByAppendingPathComponent:@"ProjectFolders"];
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:dir]) {
        [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    }
    return [dir stringByAppendingPathComponent:@"folders.json"];
}

static NSArray<NSString *> *AMFolderColorPalette(void) {
    return @[@"#34D399", @"#6366F1", @"#F59E0B", @"#EC4899", @"#3B82F6", @"#1D1E2C"];
}

static UIColor *AMColorFromHex(NSString *hex) {
    NSString *clean = [[hex stringByReplacingOccurrencesOfString:@"#" withString:@""] uppercaseString];
    if (clean.length != 6) return [UIColor colorWithRed:0.204 green:0.827 blue:0.600 alpha:1.0];
    unsigned int rgb = 0;
    [[NSScanner scannerWithString:clean] scanHexInt:&rgb];
    return [UIColor colorWithRed:((rgb >> 16) & 0xFF) / 255.0
                           green:((rgb >> 8) & 0xFF) / 255.0
                            blue:(rgb & 0xFF) / 255.0
                           alpha:1.0];
}

static NSMutableArray<NSMutableDictionary *> *AMLoadProjectFolders(void) {
    NSMutableArray<NSMutableDictionary *> *out = [NSMutableArray array];
    NSString *path = AMProjectFoldersFilePath();
    if (path.length == 0) return out;
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) return out;
    id json = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:nil];
    if (![json isKindOfClass:[NSArray class]]) return out;
    for (id item in (NSArray *)json) {
        if (![item isKindOfClass:[NSDictionary class]]) continue;
        NSMutableDictionary *d = [item mutableCopy];
        if (![d[@"projects"] isKindOfClass:[NSMutableArray class]]) {
            NSArray *orig = [d[@"projects"] isKindOfClass:[NSArray class]] ? d[@"projects"] : @[];
            d[@"projects"] = [orig mutableCopy];
        }
        [out addObject:d];
    }
    return out;
}

static void AMSaveProjectFolders(NSArray<NSDictionary *> *folders) {
    NSString *path = AMProjectFoldersFilePath();
    if (path.length == 0) return;
    NSData *data = [NSJSONSerialization dataWithJSONObject:(folders ?: @[]) options:NSJSONWritingPrettyPrinted error:nil];
    if (data) {
        [data writeToFile:path atomically:YES];
    }
}

static NSMutableDictionary *AMCreateProjectFolder(NSString *name, NSString * _Nullable colorHex) {
    NSString *trimmed = [name stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0) return nil;
    NSMutableArray<NSMutableDictionary *> *folders = AMLoadProjectFolders();
    NSArray<NSString *> *palette = AMFolderColorPalette();
    NSString *hex = colorHex.length > 0 ? colorHex : palette[folders.count % palette.count];
    NSMutableDictionary *folder = [@{
        @"id": [[NSUUID UUID] UUIDString],
        @"name": trimmed,
        @"colorHex": hex,
        @"projects": [NSMutableArray array]
    } mutableCopy];
    [folders insertObject:folder atIndex:0];
    AMSaveProjectFolders(folders);
    return folder;
}

static NSString *AMFolderProjectTitle(id entry) {
    if ([entry isKindOfClass:[NSDictionary class]]) return ((NSDictionary *)entry)[@"title"] ?: @"";
    if ([entry isKindOfClass:[NSString class]]) return (NSString *)entry;
    return @"";
}

static NSString *AMFolderProjectPath(id entry) {
    if ([entry isKindOfClass:[NSDictionary class]]) return ((NSDictionary *)entry)[@"path"] ?: @"";
    return @"";
}

static NSInteger AMAssignProjectsToFolder(NSString *folderId, NSArray<NSDictionary *> *projects) {
    if (folderId.length == 0 || projects.count == 0) return 0;
    NSMutableArray<NSMutableDictionary *> *folders = AMLoadProjectFolders();
    NSMutableDictionary *target = nil;
    for (NSMutableDictionary *f in folders) {
        if ([f[@"id"] isEqualToString:folderId]) {
            target = f;
            break;
        }
    }
    if (!target) return 0;
    NSMutableArray *list = target[@"projects"];
    NSMutableSet<NSString *> *existingPaths = [NSMutableSet set];
    NSMutableSet<NSString *> *existingTitles = [NSMutableSet set];
    for (id entry in list) {
        NSString *p = AMFolderProjectPath(entry);
        NSString *t = AMFolderProjectTitle(entry);
        if (p.length > 0) [existingPaths addObject:p];
        if (t.length > 0) [existingTitles addObject:t];
    }
    NSInteger added = 0;
    for (NSDictionary *proj in projects) {
        NSString *p = proj[@"path"] ?: @"";
        NSString *t = proj[@"title"] ?: @"";
        NSString *m = proj[@"meta"] ?: @"";
        if (t.length == 0 && p.length == 0) continue;
        if ((p.length > 0 && [existingPaths containsObject:p]) ||
            (p.length == 0 && [existingTitles containsObject:t])) {
            continue;
        }
        [list addObject:@{@"title": t, @"path": p, @"meta": m}];
        if (p.length > 0) [existingPaths addObject:p];
        if (t.length > 0) [existingTitles addObject:t];
        added++;
    }
    if (added > 0) {
        AMSaveProjectFolders(folders);
    }
    return added;
}

static NSDictionary *AMResolveFolderProject(id entry, NSArray<NSDictionary *> *diskProjects) {
    NSString *title = AMFolderProjectTitle(entry);
    NSString *path = AMFolderProjectPath(entry);
    for (NSDictionary *dp in diskProjects) {
        if (path.length > 0 && [dp[@"path"] isEqualToString:path]) return dp;
    }
    for (NSDictionary *dp in diskProjects) {
        if (title.length > 0 && [dp[@"title"] isEqualToString:title]) return dp;
    }
    NSString *thumb = path.length > 0 ? (AMFindThumbnailForProjectPath(path) ?: @"") : @"";
    NSString *meta = [entry isKindOfClass:[NSDictionary class]] ? (((NSDictionary *)entry)[@"meta"] ?: @"") : @"";
    return @{
        @"title": title.length > 0 ? title : @"Untitled Project",
        @"meta": meta,
        @"path": path,
        @"thumb": thumb
    };
}

// ============================================================================
// Accessibility & Visual Selection Probe for SwiftUI Homepage
// ============================================================================

typedef struct {
    BOOL hasYourProjects;
    CGRect yourProjectsFrame;
    BOOL isSelectionMode;
    BOOL isModalSheetOpen;
    NSInteger nativeSelectedCount;
    CGRect bottomBarFrame;
} AMHomepageProbeInfo;

static void AMWalkAccessibilityElements(id obj,
                                        NSInteger depth,
                                        NSMutableSet<NSValue *> *visited,
                                        void (^visitor)(id elem, NSString *label, CGRect screenFrame)) {
    if (!obj || depth > 20) return;
    if ([obj isKindOfClass:[UIView class]]) {
        UIView *v = (UIView *)obj;
        if (v.hidden || v.alpha < 0.02) return;
    }
    NSValue *ptrVal = [NSValue valueWithPointer:(__bridge const void *)obj];
    if ([visited containsObject:ptrVal]) return;
    [visited addObject:ptrVal];

    if ([obj respondsToSelector:@selector(accessibilityLabel)] &&
        [obj respondsToSelector:@selector(accessibilityFrame)]) {
        NSString *lbl = [obj accessibilityLabel];
        if ([lbl isKindOfClass:[NSString class]] && lbl.length > 0) {
            CGRect f = [obj accessibilityFrame];
            if (!CGRectIsEmpty(f)) {
                visitor(obj, lbl, f);
            }
        }
    }

    if ([obj respondsToSelector:@selector(accessibilityElements)]) {
        NSArray *elems = [obj accessibilityElements];
        if ([elems isKindOfClass:[NSArray class]] && elems.count > 0) {
            for (id child in elems) {
                AMWalkAccessibilityElements(child, depth + 1, visited, visitor);
            }
        }
    }

    if ([obj respondsToSelector:@selector(accessibilityElementCount)] &&
        [obj respondsToSelector:@selector(accessibilityElementAtIndex:)]) {
        NSInteger cnt = [obj accessibilityElementCount];
        if (cnt > 0 && cnt != NSNotFound && cnt < 400) {
            for (NSInteger i = 0; i < cnt; i++) {
                id child = [obj accessibilityElementAtIndex:i];
                AMWalkAccessibilityElements(child, depth + 1, visited, visitor);
            }
        }
    }

    if ([obj isKindOfClass:[UIView class]]) {
        UIView *v = (UIView *)obj;
        if (v.hidden || v.alpha < 0.02) return;
        for (UIView *sub in v.subviews) {
            AMWalkAccessibilityElements(sub, depth + 1, visited, visitor);
        }
    }
}

static BOOL AMIsRowRadioDotSelectedInWindow(UIWindow *win, CGRect rowWinFrame) {
    if (!win || CGRectIsEmpty(rowWinFrame)) return NO;
    CGFloat sampleW = 40.0;
    CGFloat sampleH = 3.0;
    CGFloat originX = 8.0;
    CGFloat originY = CGRectGetMidY(rowWinFrame) - 1.0;
    if (originY < 0 || originY + sampleH > win.bounds.size.height) return NO;

    uint8_t buf[40 * 3 * 4];
    memset(buf, 255, sizeof(buf));
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(buf,
                                             (size_t)sampleW,
                                             (size_t)sampleH,
                                             8,
                                             (size_t)sampleW * 4,
                                             cs,
                                             kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(cs);
    if (!ctx) return NO;

    CGContextTranslateCTM(ctx, -originX, -originY);
    [win.layer renderInContext:ctx];
    CGContextRelease(ctx);

    // Check middle row (y = 1) for a solid filled dark-navy dot (>= 5 contiguous dark px)
    NSInteger run = 0;
    NSInteger maxRun = 0;
    for (NSInteger x = 0; x < (NSInteger)sampleW; x++) {
        size_t idx = ((size_t)sampleW * 1 + (size_t)x) * 4;
        uint8_t r = buf[idx + 0];
        uint8_t g = buf[idx + 1];
        uint8_t b = buf[idx + 2];
        BOOL isDark = (r < 90 && g < 90 && b < 115);
        if (isDark) {
            run++;
            if (run > maxRun) maxRun = run;
        } else {
            run = 0;
        }
    }
    return maxRun >= 5;
}

static AMHomepageProbeInfo AMProbeHomepageAndTrackSelection(UIWindow *win,
                                                            NSSet<NSString *> *knownTitles,
                                                            NSMutableSet<NSString *> *trackedSelectedTitles) {
    __block AMHomepageProbeInfo info;
    memset(&info, 0, sizeof(info));
    if (!win) return info;

    __block BOOL sawSelectedHeader = NO;
    __block BOOL sawCancelOrAction = NO;
    __block CGRect barUnion = CGRectNull;
    NSMutableArray<NSDictionary *> *visibleRows = [NSMutableArray array];
    NSMutableArray<NSDictionary *> *selectedTraitNodes = [NSMutableArray array];
    NSMutableSet<NSValue *> *visited = [NSMutableSet set];

    AMWalkAccessibilityElements(win, 0, visited, ^(id elem, NSString *label, CGRect screenFrame) {
        CGRect winRect = [win convertRect:screenFrame fromWindow:nil];
        NSString *lower = label.lowercaseString;

        if ([lower isEqualToString:@"create from scratch"] ||
            [lower isEqualToString:@"composition size"] ||
            [lower isEqualToString:@"frame rate"]) {
            info.isModalSheetOpen = YES;
        }

        if ([lower isEqualToString:@"your projects"]) {
            info.hasYourProjects = YES;
            info.yourProjectsFrame = winRect;
        }

        if ([lower hasSuffix:@" selected"] && winRect.origin.y < 140.0) {
            sawSelectedHeader = YES;
            info.nativeSelectedCount = [lower integerValue];
        }
        if ([lower isEqualToString:@"cancel"] && winRect.origin.y < 140.0) {
            sawCancelOrAction = YES;
        }
        if (([lower isEqualToString:@"duplicate"] || [lower isEqualToString:@"delete"] || [lower isEqualToString:@"export"]) &&
            winRect.origin.y > win.bounds.size.height - 140.0) {
            sawCancelOrAction = YES;
            barUnion = CGRectIsNull(barUnion) ? winRect : CGRectUnion(barUnion, winRect);
        }

        if ([elem respondsToSelector:@selector(accessibilityTraits)]) {
            UIAccessibilityTraits traits = [elem accessibilityTraits];
            if ((traits & UIAccessibilityTraitSelected) != 0) {
                [selectedTraitNodes addObject:@{@"frame": [NSValue valueWithCGRect:winRect], @"label": label}];
            }
        }

        if ([knownTitles containsObject:label] &&
            CGRectGetMidY(winRect) > 100.0 &&
            CGRectGetMidY(winRect) < win.bounds.size.height - 80.0) {
            [visibleRows addObject:@{@"title": label, @"frame": [NSValue valueWithCGRect:winRect]}];
        }
    });

    info.isSelectionMode = (sawSelectedHeader && sawCancelOrAction);
    info.bottomBarFrame = CGRectIsNull(barUnion) ? CGRectZero : barUnion;

    if (!info.isSelectionMode) {
        [trackedSelectedTitles removeAllObjects];
        return info;
    }

    for (NSDictionary *row in visibleRows) {
        NSString *title = row[@"title"];
        CGRect rowRect = [row[@"frame"] CGRectValue];
        BOOL isSel = NO;

        for (NSDictionary *sn in selectedTraitNodes) {
            CGRect sf = [sn[@"frame"] CGRectValue];
            if (fabs(CGRectGetMidY(sf) - CGRectGetMidY(rowRect)) < 42.0) {
                isSel = YES;
                break;
            }
        }
        if (!isSel) {
            isSel = AMIsRowRadioDotSelectedInWindow(win, rowRect);
        }
        if (isSel) {
            [trackedSelectedTitles addObject:title];
        } else {
            [trackedSelectedTitles removeObject:title];
        }
    }

    return info;
}

// ============================================================================
// Folder UI: Multi-Project Picker, Folder Detail, Folders List, Assign Folder
// ============================================================================

@interface AMProjectMultiPickerVC : UIViewController <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, copy) NSArray<NSDictionary *> *allProjects;
@property (nonatomic, copy) NSSet<NSString *> *preselectedPaths;
@property (nonatomic, copy) void (^onConfirm)(NSArray<NSDictionary *> *picked);
@property (nonatomic, strong) NSMutableSet<NSNumber *> *selectedIndices;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) NSCache<NSString *, UIImage *> *thumbCache;
@end

@implementation AMProjectMultiPickerVC

- (void)viewDidLoad {
    [super viewDidLoad];
    if (@available(iOS 13.0, *)) {
        self.overrideUserInterfaceStyle = UIUserInterfaceStyleLight;
    }
    self.thumbCache = [[NSCache alloc] init];
    self.selectedIndices = [NSMutableSet set];
    for (NSUInteger i = 0; i < self.allProjects.count; i++) {
        NSString *p = self.allProjects[i][@"path"] ?: @"";
        if (p.length > 0 && [self.preselectedPaths containsObject:p]) {
            [self.selectedIndices addObject:@(i)];
        }
    }

    UIColor *bgColor = [UIColor colorWithRed:0.965 green:0.969 blue:0.984 alpha:1.0];
    UIColor *navy = [UIColor colorWithRed:0.114 green:0.118 blue:0.173 alpha:1.0];
    self.view.backgroundColor = bgColor;
    self.title = @"Add Projects";

    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Cancel"
                                                                             style:UIBarButtonItemStylePlain
                                                                            target:self
                                                                            action:@selector(onCancel)];
    self.navigationItem.leftBarButtonItem.tintColor = navy;

    UIBarButtonItem *doneItem = [[UIBarButtonItem alloc] initWithTitle:@"Add"
                                                                 style:UIBarButtonItemStyleDone
                                                                target:self
                                                                action:@selector(onDone)];
    doneItem.tintColor = navy;
    self.navigationItem.rightBarButtonItem = doneItem;

    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.tableView.backgroundColor = bgColor;
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.tableView.contentInset = UIEdgeInsetsMake(8.0, 0.0, 24.0, 0.0);
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    [self.view addSubview:self.tableView];

    [NSLayoutConstraint activateConstraints:@[
        [self.tableView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.tableView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];
}

- (void)onCancel {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)onDone {
    NSMutableArray<NSDictionary *> *picked = [NSMutableArray array];
    for (NSNumber *idx in self.selectedIndices) {
        NSUInteger i = idx.unsignedIntegerValue;
        if (i < self.allProjects.count) [picked addObject:self.allProjects[i]];
    }
    [self dismissViewControllerAnimated:YES completion:^{
        if (self.onConfirm) self.onConfirm(picked);
    }];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView; (void)section;
    return self.allProjects.count;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView; (void)indexPath;
    return 78.0;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"AMPickerCell"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"AMPickerCell"];
        cell.backgroundColor = [UIColor clearColor];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;

        UIView *card = [[UIView alloc] init];
        card.tag = 201;
        card.translatesAutoresizingMaskIntoConstraints = NO;
        card.backgroundColor = [UIColor whiteColor];
        card.layer.cornerRadius = 14.0;
        card.layer.shadowColor = [UIColor blackColor].CGColor;
        card.layer.shadowOpacity = 0.04;
        card.layer.shadowRadius = 8.0;
        card.layer.shadowOffset = CGSizeMake(0, 2);
        [cell.contentView addSubview:card];

        UIImageView *checkIV = [[UIImageView alloc] init];
        checkIV.tag = 202;
        checkIV.translatesAutoresizingMaskIntoConstraints = NO;
        [card addSubview:checkIV];

        UIImageView *thumbIV = [[UIImageView alloc] init];
        thumbIV.tag = 203;
        thumbIV.translatesAutoresizingMaskIntoConstraints = NO;
        thumbIV.backgroundColor = [UIColor colorWithRed:0.933 green:0.941 blue:0.969 alpha:1.0];
        thumbIV.layer.cornerRadius = 10.0;
        thumbIV.clipsToBounds = YES;
        [card addSubview:thumbIV];

        UILabel *titleLbl = [[UILabel alloc] init];
        titleLbl.tag = 204;
        titleLbl.translatesAutoresizingMaskIntoConstraints = NO;
        titleLbl.font = AMThemeFont(15.0, UIFontWeightBold);
        titleLbl.textColor = [UIColor colorWithRed:0.114 green:0.118 blue:0.173 alpha:1.0];
        [card addSubview:titleLbl];

        UILabel *metaLbl = [[UILabel alloc] init];
        metaLbl.tag = 205;
        metaLbl.translatesAutoresizingMaskIntoConstraints = NO;
        metaLbl.font = AMThemeFont(12.0, UIFontWeightRegular);
        metaLbl.textColor = [UIColor colorWithRed:0.557 green:0.573 blue:0.643 alpha:1.0];
        [card addSubview:metaLbl];

        [NSLayoutConstraint activateConstraints:@[
            [card.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:4.0],
            [card.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-4.0],
            [card.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:16.0],
            [card.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-16.0],

            [checkIV.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:12.0],
            [checkIV.centerYAnchor constraintEqualToAnchor:card.centerYAnchor],
            [checkIV.widthAnchor constraintEqualToConstant:22.0],
            [checkIV.heightAnchor constraintEqualToConstant:22.0],

            [thumbIV.leadingAnchor constraintEqualToAnchor:checkIV.trailingAnchor constant:10.0],
            [thumbIV.centerYAnchor constraintEqualToAnchor:card.centerYAnchor],
            [thumbIV.widthAnchor constraintEqualToConstant:50.0],
            [thumbIV.heightAnchor constraintEqualToConstant:50.0],

            [titleLbl.leadingAnchor constraintEqualToAnchor:thumbIV.trailingAnchor constant:12.0],
            [titleLbl.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-12.0],
            [titleLbl.topAnchor constraintEqualToAnchor:card.topAnchor constant:15.0],

            [metaLbl.leadingAnchor constraintEqualToAnchor:titleLbl.leadingAnchor],
            [metaLbl.trailingAnchor constraintEqualToAnchor:titleLbl.trailingAnchor],
            [metaLbl.topAnchor constraintEqualToAnchor:titleLbl.bottomAnchor constant:4.0],
        ]];
    }

    NSDictionary *item = self.allProjects[indexPath.row];
    BOOL isSel = [self.selectedIndices containsObject:@(indexPath.row)];
    UIImageView *checkIV = (UIImageView *)[cell.contentView viewWithTag:202];
    UIImageView *thumbIV = (UIImageView *)[cell.contentView viewWithTag:203];
    UILabel *titleLbl = (UILabel *)[cell.contentView viewWithTag:204];
    UILabel *metaLbl = (UILabel *)[cell.contentView viewWithTag:205];

    titleLbl.text = item[@"title"];
    metaLbl.text = item[@"meta"];
    if (@available(iOS 13.0, *)) {
        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:20.0 weight:UIImageSymbolWeightMedium];
        checkIV.image = [UIImage systemImageNamed:(isSel ? @"checkmark.circle.fill" : @"circle") withConfiguration:cfg];
        checkIV.tintColor = isSel
            ? [UIColor colorWithRed:0.114 green:0.118 blue:0.173 alpha:1.0]
            : [UIColor colorWithRed:0.78 green:0.80 blue:0.85 alpha:1.0];
    }

    NSString *thumbPath = item[@"thumb"];
    UIImage *img = nil;
    if (thumbPath.length > 0) {
        img = [self.thumbCache objectForKey:thumbPath];
        if (!img) {
            img = [UIImage imageWithContentsOfFile:thumbPath];
            if (img) [self.thumbCache setObject:img forKey:thumbPath];
        }
    }
    if (img) {
        thumbIV.contentMode = UIViewContentModeScaleAspectFill;
        thumbIV.image = img;
    } else {
        thumbIV.contentMode = UIViewContentModeCenter;
        if (@available(iOS 13.0, *)) {
            thumbIV.image = [UIImage systemImageNamed:@"film.stack"];
            thumbIV.tintColor = [UIColor colorWithRed:0.114 green:0.118 blue:0.173 alpha:1.0];
        }
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    NSNumber *key = @(indexPath.row);
    if ([self.selectedIndices containsObject:key]) {
        [self.selectedIndices removeObject:key];
    } else {
        [self.selectedIndices addObject:key];
    }
    [tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
    NSString *title = self.selectedIndices.count > 0
        ? [NSString stringWithFormat:@"Add (%lu)", (unsigned long)self.selectedIndices.count]
        : @"Add";
    self.navigationItem.rightBarButtonItem.title = title;
}

@end

@interface AMFolderDetailVC : UIViewController <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, copy) NSString *folderId;
@property (nonatomic, copy) void (^onFoldersChanged)(void);
@property (nonatomic, strong) NSMutableDictionary *folderDict;
@property (nonatomic, strong) NSArray<NSDictionary *> *diskProjects;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UILabel *emptyLabel;
@property (nonatomic, strong) NSCache<NSString *, UIImage *> *thumbCache;
@end

@implementation AMFolderDetailVC

- (void)viewDidLoad {
    [super viewDidLoad];
    if (@available(iOS 13.0, *)) {
        self.overrideUserInterfaceStyle = UIUserInterfaceStyleLight;
    }
    self.thumbCache = [[NSCache alloc] init];
    self.diskProjects = AMLoadUserProjectsFromDisk();

    UIColor *bgColor = [UIColor colorWithRed:0.965 green:0.969 blue:0.984 alpha:1.0];
    UIColor *navy = [UIColor colorWithRed:0.114 green:0.118 blue:0.173 alpha:1.0];
    self.view.backgroundColor = bgColor;

    UIBarButtonItem *addBtn = [[UIBarButtonItem alloc] initWithTitle:@"+ Add"
                                                               style:UIBarButtonItemStyleDone
                                                              target:self
                                                              action:@selector(onTapAdd)];
    addBtn.tintColor = navy;
    self.navigationItem.rightBarButtonItem = addBtn;

    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.tableView.backgroundColor = bgColor;
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.tableView.contentInset = UIEdgeInsetsMake(8.0, 0.0, 24.0, 0.0);
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    [self.view addSubview:self.tableView];

    self.emptyLabel = [[UILabel alloc] init];
    self.emptyLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.emptyLabel.numberOfLines = 0;
    self.emptyLabel.textAlignment = NSTextAlignmentCenter;
    self.emptyLabel.font = AMThemeFont(14.0, UIFontWeightMedium);
    self.emptyLabel.textColor = [UIColor colorWithRed:0.557 green:0.573 blue:0.643 alpha:1.0];
    self.emptyLabel.text = @"This folder is empty.\nHold any project on the Homepage and tap Assign Folder, or tap + Add above.";
    [self.view addSubview:self.emptyLabel];

    [NSLayoutConstraint activateConstraints:@[
        [self.tableView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.tableView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],

        [self.emptyLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.emptyLabel.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor constant:-20.0],
        [self.emptyLabel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:32.0],
        [self.emptyLabel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-32.0],
    ]];

    [self reloadFolderData];
}

- (void)reloadFolderData {
    NSMutableArray<NSMutableDictionary *> *folders = AMLoadProjectFolders();
    self.folderDict = nil;
    for (NSMutableDictionary *f in folders) {
        if ([f[@"id"] isEqualToString:self.folderId]) {
            self.folderDict = f;
            break;
        }
    }
    self.title = self.folderDict[@"name"] ?: @"Folder";
    NSArray *items = self.folderDict[@"projects"];
    self.emptyLabel.hidden = (items.count > 0);
    [self.tableView reloadData];
}

- (void)onTapAdd {
    AMProjectMultiPickerVC *picker = [[AMProjectMultiPickerVC alloc] init];
    picker.allProjects = self.diskProjects;
    NSMutableSet *existing = [NSMutableSet set];
    for (id entry in (self.folderDict[@"projects"] ?: @[])) {
        NSString *p = AMFolderProjectPath(entry);
        if (p.length > 0) [existing addObject:p];
    }
    picker.preselectedPaths = existing;
    __weak AMFolderDetailVC *weakSelf = self;
    picker.onConfirm = ^(NSArray<NSDictionary *> *picked) {
        AMAssignProjectsToFolder(weakSelf.folderId, picked);
        [weakSelf reloadFolderData];
        if (weakSelf.onFoldersChanged) weakSelf.onFoldersChanged();
    };
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:picker];
    if (@available(iOS 13.0, *)) nav.overrideUserInterfaceStyle = UIUserInterfaceStyleLight;
    [self presentViewController:nav animated:YES completion:nil];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView; (void)section;
    NSArray *items = self.folderDict[@"projects"];
    return items.count;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView; (void)indexPath;
    return 82.0;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"AMFolderProjCell"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"AMFolderProjCell"];
        cell.backgroundColor = [UIColor clearColor];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;

        UIView *card = [[UIView alloc] init];
        card.translatesAutoresizingMaskIntoConstraints = NO;
        card.backgroundColor = [UIColor whiteColor];
        card.layer.cornerRadius = 14.0;
        card.layer.shadowColor = [UIColor blackColor].CGColor;
        card.layer.shadowOpacity = 0.04;
        card.layer.shadowRadius = 8.0;
        card.layer.shadowOffset = CGSizeMake(0, 2);
        [cell.contentView addSubview:card];

        UIImageView *thumbIV = [[UIImageView alloc] init];
        thumbIV.tag = 303;
        thumbIV.translatesAutoresizingMaskIntoConstraints = NO;
        thumbIV.backgroundColor = [UIColor colorWithRed:0.933 green:0.941 blue:0.969 alpha:1.0];
        thumbIV.layer.cornerRadius = 10.0;
        thumbIV.clipsToBounds = YES;
        [card addSubview:thumbIV];

        UILabel *titleLbl = [[UILabel alloc] init];
        titleLbl.tag = 304;
        titleLbl.translatesAutoresizingMaskIntoConstraints = NO;
        titleLbl.font = AMThemeFont(15.0, UIFontWeightBold);
        titleLbl.textColor = [UIColor colorWithRed:0.114 green:0.118 blue:0.173 alpha:1.0];
        [card addSubview:titleLbl];

        UILabel *metaLbl = [[UILabel alloc] init];
        metaLbl.tag = 305;
        metaLbl.translatesAutoresizingMaskIntoConstraints = NO;
        metaLbl.font = AMThemeFont(12.0, UIFontWeightRegular);
        metaLbl.textColor = [UIColor colorWithRed:0.557 green:0.573 blue:0.643 alpha:1.0];
        [card addSubview:metaLbl];

        [NSLayoutConstraint activateConstraints:@[
            [card.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:5.0],
            [card.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-5.0],
            [card.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:16.0],
            [card.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-16.0],

            [thumbIV.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:10.0],
            [thumbIV.centerYAnchor constraintEqualToAnchor:card.centerYAnchor],
            [thumbIV.widthAnchor constraintEqualToConstant:54.0],
            [thumbIV.heightAnchor constraintEqualToConstant:54.0],

            [titleLbl.leadingAnchor constraintEqualToAnchor:thumbIV.trailingAnchor constant:12.0],
            [titleLbl.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-14.0],
            [titleLbl.topAnchor constraintEqualToAnchor:card.topAnchor constant:16.0],

            [metaLbl.leadingAnchor constraintEqualToAnchor:titleLbl.leadingAnchor],
            [metaLbl.trailingAnchor constraintEqualToAnchor:titleLbl.trailingAnchor],
            [metaLbl.topAnchor constraintEqualToAnchor:titleLbl.bottomAnchor constant:4.0],
        ]];
    }

    NSArray *items = self.folderDict[@"projects"];
    NSDictionary *resolved = AMResolveFolderProject(items[indexPath.row], self.diskProjects);
    UIImageView *thumbIV = (UIImageView *)[cell.contentView viewWithTag:303];
    UILabel *titleLbl = (UILabel *)[cell.contentView viewWithTag:304];
    UILabel *metaLbl = (UILabel *)[cell.contentView viewWithTag:305];

    titleLbl.text = resolved[@"title"];
    metaLbl.text = resolved[@"meta"];

    NSString *thumbPath = resolved[@"thumb"];
    UIImage *img = nil;
    if (thumbPath.length > 0) {
        img = [self.thumbCache objectForKey:thumbPath];
        if (!img) {
            img = [UIImage imageWithContentsOfFile:thumbPath];
            if (img) [self.thumbCache setObject:img forKey:thumbPath];
        }
    }
    if (img) {
        thumbIV.contentMode = UIViewContentModeScaleAspectFill;
        thumbIV.image = img;
    } else {
        thumbIV.contentMode = UIViewContentModeCenter;
        if (@available(iOS 13.0, *)) {
            thumbIV.image = [UIImage systemImageNamed:@"film.stack"];
            thumbIV.tintColor = [UIColor colorWithRed:0.114 green:0.118 blue:0.173 alpha:1.0];
        }
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSArray *items = self.folderDict[@"projects"];
    if (indexPath.row >= (NSInteger)items.count) return;
    NSDictionary *resolved = AMResolveFolderProject(items[indexPath.row], self.diskProjects);
    NSString *path = resolved[@"path"];
    if (path.length == 0) return;
    gAMFoldersModalOpen = NO;
    [self.navigationController dismissViewControllerAnimated:YES completion:^{
        if (!AMOpenLocalProjectInMainVC(path)) {
            AMOpenLocalFileInApp([NSURL fileURLWithPath:path]);
        }
    }];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView
trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView;
    __weak AMFolderDetailVC *weakSelf = self;
    UIContextualAction *remove = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
                                                                         title:@"Remove"
                                                                       handler:^(UIContextualAction *action, UIView *sourceView, void (^completionHandler)(BOOL)) {
        (void)action; (void)sourceView;
        NSMutableArray<NSMutableDictionary *> *folders = AMLoadProjectFolders();
        for (NSMutableDictionary *f in folders) {
            if ([f[@"id"] isEqualToString:weakSelf.folderId]) {
                NSMutableArray *list = f[@"projects"];
                if (indexPath.row < (NSInteger)list.count) {
                    [list removeObjectAtIndex:indexPath.row];
                    AMSaveProjectFolders(folders);
                }
                break;
            }
        }
        [weakSelf reloadFolderData];
        if (weakSelf.onFoldersChanged) weakSelf.onFoldersChanged();
        completionHandler(YES);
    }];
    return [UISwipeActionsConfiguration configurationWithActions:@[remove]];
}

@end

@interface AMProjectFoldersVC : UIViewController <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) NSMutableArray<NSMutableDictionary *> *folders;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UILabel *emptyLabel;
@end

@implementation AMProjectFoldersVC

- (void)viewDidLoad {
    [super viewDidLoad];
    if (@available(iOS 13.0, *)) {
        self.overrideUserInterfaceStyle = UIUserInterfaceStyleLight;
    }
    UIColor *bgColor = [UIColor colorWithRed:0.965 green:0.969 blue:0.984 alpha:1.0];
    UIColor *navy = [UIColor colorWithRed:0.114 green:0.118 blue:0.173 alpha:1.0];
    self.view.backgroundColor = bgColor;
    self.title = @"Project Folders";

    if (@available(iOS 13.0, *)) {
        UINavigationBarAppearance *app = [[UINavigationBarAppearance alloc] init];
        [app configureWithOpaqueBackground];
        app.backgroundColor = bgColor;
        app.shadowColor = [UIColor clearColor];
        app.titleTextAttributes = @{
            NSForegroundColorAttributeName: navy,
            NSFontAttributeName: AMThemeFont(17.0, UIFontWeightBold)
        };
        self.navigationController.navigationBar.standardAppearance = app;
        self.navigationController.navigationBar.scrollEdgeAppearance = app;
    }

    UIBarButtonItem *closeItem = [[UIBarButtonItem alloc] initWithTitle:@"Close"
                                                                  style:UIBarButtonItemStylePlain
                                                                 target:self
                                                                 action:@selector(onClose)];
    closeItem.tintColor = navy;
    self.navigationItem.leftBarButtonItem = closeItem;

    UIBarButtonItem *newItem = [[UIBarButtonItem alloc] initWithTitle:@"+ New"
                                                                style:UIBarButtonItemStyleDone
                                                               target:self
                                                               action:@selector(onTapNewFolder)];
    newItem.tintColor = navy;
    self.navigationItem.rightBarButtonItem = newItem;

    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.tableView.backgroundColor = bgColor;
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.tableView.contentInset = UIEdgeInsetsMake(8.0, 0.0, 24.0, 0.0);
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    [self.view addSubview:self.tableView];

    self.emptyLabel = [[UILabel alloc] init];
    self.emptyLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.emptyLabel.numberOfLines = 0;
    self.emptyLabel.textAlignment = NSTextAlignmentCenter;
    self.emptyLabel.font = AMThemeFont(14.0, UIFontWeightMedium);
    self.emptyLabel.textColor = [UIColor colorWithRed:0.557 green:0.573 blue:0.643 alpha:1.0];
    self.emptyLabel.text = @"No folders yet.\nTap + New to create a folder, then hold any project on the Homepage and tap Assign Folder.";
    [self.view addSubview:self.emptyLabel];

    [NSLayoutConstraint activateConstraints:@[
        [self.tableView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.tableView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],

        [self.emptyLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.emptyLabel.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor constant:-20.0],
        [self.emptyLabel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:32.0],
        [self.emptyLabel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-32.0],
    ]];

    [self reloadFolders];
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    if (self.isBeingDismissed || self.navigationController.isBeingDismissed) {
        gAMFoldersModalOpen = NO;
    }
}

- (void)reloadFolders {
    self.folders = AMLoadProjectFolders();
    self.emptyLabel.hidden = (self.folders.count > 0);
    [self.tableView reloadData];
}

- (void)onClose {
    gAMFoldersModalOpen = NO;
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)onTapNewFolder {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"New Folder"
                                                                message:@"Enter a name for your project folder."
                                                         preferredStyle:UIAlertControllerStyleAlert];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"Folder name (e.g. Edits, Shakes)";
        tf.autocapitalizationType = UITextAutocapitalizationTypeWords;
    }];
    __weak AMProjectFoldersVC *weakSelf = self;
    [ac addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [ac addAction:[UIAlertAction actionWithTitle:@"Create" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        (void)action;
        NSString *name = ac.textFields.firstObject.text ?: @"";
        if (AMCreateProjectFolder(name, nil)) {
            [weakSelf reloadFolders];
        }
    }]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView; (void)section;
    return self.folders.count;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView; (void)indexPath;
    return 76.0;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"AMFolderCardCell"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"AMFolderCardCell"];
        cell.backgroundColor = [UIColor clearColor];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;

        UIView *card = [[UIView alloc] init];
        card.translatesAutoresizingMaskIntoConstraints = NO;
        card.backgroundColor = [UIColor whiteColor];
        card.layer.cornerRadius = 14.0;
        card.layer.shadowColor = [UIColor blackColor].CGColor;
        card.layer.shadowOpacity = 0.04;
        card.layer.shadowRadius = 8.0;
        card.layer.shadowOffset = CGSizeMake(0, 2);
        [cell.contentView addSubview:card];

        UIView *iconBg = [[UIView alloc] init];
        iconBg.tag = 401;
        iconBg.translatesAutoresizingMaskIntoConstraints = NO;
        iconBg.layer.cornerRadius = 12.0;
        [card addSubview:iconBg];

        UIImageView *iconIV = [[UIImageView alloc] init];
        iconIV.tag = 402;
        iconIV.translatesAutoresizingMaskIntoConstraints = NO;
        iconIV.tintColor = [UIColor whiteColor];
        [iconBg addSubview:iconIV];

        UILabel *nameLbl = [[UILabel alloc] init];
        nameLbl.tag = 403;
        nameLbl.translatesAutoresizingMaskIntoConstraints = NO;
        nameLbl.font = AMThemeFont(16.0, UIFontWeightBold);
        nameLbl.textColor = [UIColor colorWithRed:0.114 green:0.118 blue:0.173 alpha:1.0];
        [card addSubview:nameLbl];

        UILabel *countLbl = [[UILabel alloc] init];
        countLbl.tag = 404;
        countLbl.translatesAutoresizingMaskIntoConstraints = NO;
        countLbl.font = AMThemeFont(12.0, UIFontWeightRegular);
        countLbl.textColor = [UIColor colorWithRed:0.557 green:0.573 blue:0.643 alpha:1.0];
        [card addSubview:countLbl];

        UIImageView *chev = [[UIImageView alloc] init];
        chev.translatesAutoresizingMaskIntoConstraints = NO;
        if (@available(iOS 13.0, *)) {
            chev.image = [UIImage systemImageNamed:@"chevron.right"];
        }
        chev.tintColor = [UIColor colorWithRed:0.75 green:0.77 blue:0.82 alpha:1.0];
        [card addSubview:chev];

        [NSLayoutConstraint activateConstraints:@[
            [card.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:5.0],
            [card.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-5.0],
            [card.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:16.0],
            [card.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-16.0],

            [iconBg.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:12.0],
            [iconBg.centerYAnchor constraintEqualToAnchor:card.centerYAnchor],
            [iconBg.widthAnchor constraintEqualToConstant:44.0],
            [iconBg.heightAnchor constraintEqualToConstant:44.0],

            [iconIV.centerXAnchor constraintEqualToAnchor:iconBg.centerXAnchor],
            [iconIV.centerYAnchor constraintEqualToAnchor:iconBg.centerYAnchor],
            [iconIV.widthAnchor constraintEqualToConstant:22.0],
            [iconIV.heightAnchor constraintEqualToConstant:22.0],

            [nameLbl.leadingAnchor constraintEqualToAnchor:iconBg.trailingAnchor constant:12.0],
            [nameLbl.trailingAnchor constraintEqualToAnchor:chev.leadingAnchor constant:-10.0],
            [nameLbl.topAnchor constraintEqualToAnchor:card.topAnchor constant:14.0],

            [countLbl.leadingAnchor constraintEqualToAnchor:nameLbl.leadingAnchor],
            [countLbl.trailingAnchor constraintEqualToAnchor:nameLbl.trailingAnchor],
            [countLbl.topAnchor constraintEqualToAnchor:nameLbl.bottomAnchor constant:3.0],

            [chev.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-14.0],
            [chev.centerYAnchor constraintEqualToAnchor:card.centerYAnchor],
            [chev.widthAnchor constraintEqualToConstant:12.0],
            [chev.heightAnchor constraintEqualToConstant:16.0],
        ]];
    }

    NSDictionary *f = self.folders[indexPath.row];
    UIView *iconBg = [cell.contentView viewWithTag:401];
    UIImageView *iconIV = (UIImageView *)[cell.contentView viewWithTag:402];
    UILabel *nameLbl = (UILabel *)[cell.contentView viewWithTag:403];
    UILabel *countLbl = (UILabel *)[cell.contentView viewWithTag:404];

    iconBg.backgroundColor = AMColorFromHex(f[@"colorHex"]);
    if (@available(iOS 13.0, *)) {
        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:18.0 weight:UIImageSymbolWeightSemibold];
        iconIV.image = [UIImage systemImageNamed:@"folder.fill" withConfiguration:cfg];
    }
    nameLbl.text = f[@"name"] ?: @"Folder";
    NSArray *projs = f[@"projects"];
    NSUInteger c = projs.count;
    countLbl.text = (c == 1) ? @"1 project" : [NSString stringWithFormat:@"%lu projects", (unsigned long)c];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.row >= (NSInteger)self.folders.count) return;
    NSDictionary *f = self.folders[indexPath.row];
    AMFolderDetailVC *detail = [[AMFolderDetailVC alloc] init];
    detail.folderId = f[@"id"];
    __weak AMProjectFoldersVC *weakSelf = self;
    detail.onFoldersChanged = ^{
        [weakSelf reloadFolders];
    };
    [self.navigationController pushViewController:detail animated:YES];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView
trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView;
    __weak AMProjectFoldersVC *weakSelf = self;
    UIContextualAction *del = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
                                                                      title:@"Delete"
                                                                    handler:^(UIContextualAction *action, UIView *sourceView, void (^completionHandler)(BOOL)) {
        (void)action; (void)sourceView;
        if (indexPath.row < (NSInteger)weakSelf.folders.count) {
            [weakSelf.folders removeObjectAtIndex:indexPath.row];
            AMSaveProjectFolders(weakSelf.folders);
            [weakSelf reloadFolders];
        }
        completionHandler(YES);
    }];
    UIContextualAction *rename = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal
                                                                         title:@"Rename"
                                                                       handler:^(UIContextualAction *action, UIView *sourceView, void (^completionHandler)(BOOL)) {
        (void)action; (void)sourceView;
        if (indexPath.row >= (NSInteger)weakSelf.folders.count) {
            completionHandler(NO);
            return;
        }
        NSMutableDictionary *f = weakSelf.folders[indexPath.row];
        UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Rename Folder" message:nil preferredStyle:UIAlertControllerStyleAlert];
        [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
            tf.text = f[@"name"];
        }];
        [ac addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
        [ac addAction:[UIAlertAction actionWithTitle:@"Save" style:UIAlertActionStyleDefault handler:^(UIAlertAction *act) {
            (void)act;
            NSString *n = [ac.textFields.firstObject.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (n.length > 0) {
                f[@"name"] = n;
                AMSaveProjectFolders(weakSelf.folders);
                [weakSelf reloadFolders];
            }
        }]];
        [weakSelf presentViewController:ac animated:YES completion:nil];
        completionHandler(YES);
    }];
    rename.backgroundColor = [UIColor colorWithRed:0.114 green:0.118 blue:0.173 alpha:1.0];
    return [UISwipeActionsConfiguration configurationWithActions:@[del, rename]];
}

@end

@interface AMAssignFolderVC : UIViewController <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, copy) NSArray<NSDictionary *> *selectedProjects;
@property (nonatomic, strong) NSMutableArray<NSMutableDictionary *> *folders;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UILabel *summaryLabel;
@end

@implementation AMAssignFolderVC

- (void)viewDidLoad {
    [super viewDidLoad];
    if (@available(iOS 13.0, *)) {
        self.overrideUserInterfaceStyle = UIUserInterfaceStyleLight;
    }
    UIColor *bgColor = [UIColor colorWithRed:0.965 green:0.969 blue:0.984 alpha:1.0];
    UIColor *navy = [UIColor colorWithRed:0.114 green:0.118 blue:0.173 alpha:1.0];
    self.view.backgroundColor = bgColor;
    self.title = @"Assign to Folder";

    if (@available(iOS 13.0, *)) {
        UINavigationBarAppearance *app = [[UINavigationBarAppearance alloc] init];
        [app configureWithOpaqueBackground];
        app.backgroundColor = bgColor;
        app.shadowColor = [UIColor clearColor];
        app.titleTextAttributes = @{
            NSForegroundColorAttributeName: navy,
            NSFontAttributeName: AMThemeFont(17.0, UIFontWeightBold)
        };
        self.navigationController.navigationBar.standardAppearance = app;
        self.navigationController.navigationBar.scrollEdgeAppearance = app;
    }

    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Cancel"
                                                                             style:UIBarButtonItemStylePlain
                                                                            target:self
                                                                            action:@selector(onCancel)];
    self.navigationItem.leftBarButtonItem.tintColor = navy;

    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"+ New Folder"
                                                                              style:UIBarButtonItemStyleDone
                                                                             target:self
                                                                             action:@selector(onTapNewFolder)];
    self.navigationItem.rightBarButtonItem.tintColor = navy;

    UIView *banner = [[UIView alloc] init];
    banner.translatesAutoresizingMaskIntoConstraints = NO;
    banner.backgroundColor = [UIColor whiteColor];
    banner.layer.cornerRadius = 14.0;
    banner.layer.borderWidth = 1.0;
    banner.layer.borderColor = [UIColor colorWithRed:0.114 green:0.118 blue:0.173 alpha:0.08].CGColor;
    [self.view addSubview:banner];

    self.summaryLabel = [[UILabel alloc] init];
    self.summaryLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.summaryLabel.numberOfLines = 2;
    self.summaryLabel.font = AMThemeFont(13.0, UIFontWeightSemibold);
    self.summaryLabel.textColor = navy;
    [banner addSubview:self.summaryLabel];

    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.tableView.backgroundColor = bgColor;
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.tableView.contentInset = UIEdgeInsetsMake(6.0, 0.0, 24.0, 0.0);
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    [self.view addSubview:self.tableView];

    [NSLayoutConstraint activateConstraints:@[
        [banner.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:8.0],
        [banner.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16.0],
        [banner.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16.0],

        [self.summaryLabel.topAnchor constraintEqualToAnchor:banner.topAnchor constant:12.0],
        [self.summaryLabel.bottomAnchor constraintEqualToAnchor:banner.bottomAnchor constant:-12.0],
        [self.summaryLabel.leadingAnchor constraintEqualToAnchor:banner.leadingAnchor constant:14.0],
        [self.summaryLabel.trailingAnchor constraintEqualToAnchor:banner.trailingAnchor constant:-14.0],

        [self.tableView.topAnchor constraintEqualToAnchor:banner.bottomAnchor constant:8.0],
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.tableView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];

    [self updateSummary];
    self.folders = AMLoadProjectFolders();
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    if (self.isBeingDismissed || self.navigationController.isBeingDismissed) {
        gAMFoldersModalOpen = NO;
    }
}

- (void)updateSummary {
    if (self.selectedProjects.count == 0) {
        self.summaryLabel.text = @"Select a folder below, or tap + New Folder to create one.";
        return;
    }
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (NSDictionary *p in self.selectedProjects) {
        NSString *t = p[@"title"];
        if (t.length > 0) [names addObject:t];
    }
    NSString *joined = [names componentsJoinedByString:@", "];
    self.summaryLabel.text = [NSString stringWithFormat:@"Selected (%lu): %@",
                              (unsigned long)self.selectedProjects.count,
                              joined];
}

- (void)onCancel {
    gAMFoldersModalOpen = NO;
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)onTapNewFolder {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"New Folder & Assign"
                                                                message:@"Create a folder and assign the selected projects to it."
                                                         preferredStyle:UIAlertControllerStyleAlert];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"Folder name";
        tf.autocapitalizationType = UITextAutocapitalizationTypeWords;
    }];
    __weak AMAssignFolderVC *weakSelf = self;
    [ac addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [ac addAction:[UIAlertAction actionWithTitle:@"Create & Assign" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        (void)action;
        NSString *name = ac.textFields.firstObject.text ?: @"";
        NSMutableDictionary *created = AMCreateProjectFolder(name, nil);
        if (created) {
            AMAssignProjectsToFolder(created[@"id"], weakSelf.selectedProjects);
            gAMFoldersModalOpen = NO;
            [weakSelf dismissViewControllerAnimated:YES completion:nil];
        }
    }]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView; (void)section;
    return MAX((NSInteger)self.folders.count, 1);
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView; (void)indexPath;
    return 74.0;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"AMAssignFolderCell"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"AMAssignFolderCell"];
        cell.backgroundColor = [UIColor clearColor];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;

        UIView *card = [[UIView alloc] init];
        card.translatesAutoresizingMaskIntoConstraints = NO;
        card.backgroundColor = [UIColor whiteColor];
        card.layer.cornerRadius = 14.0;
        card.layer.shadowColor = [UIColor blackColor].CGColor;
        card.layer.shadowOpacity = 0.04;
        card.layer.shadowRadius = 8.0;
        card.layer.shadowOffset = CGSizeMake(0, 2);
        [cell.contentView addSubview:card];

        UIView *iconBg = [[UIView alloc] init];
        iconBg.tag = 501;
        iconBg.translatesAutoresizingMaskIntoConstraints = NO;
        iconBg.layer.cornerRadius = 11.0;
        [card addSubview:iconBg];

        UIImageView *iconIV = [[UIImageView alloc] init];
        iconIV.tag = 502;
        iconIV.translatesAutoresizingMaskIntoConstraints = NO;
        iconIV.tintColor = [UIColor whiteColor];
        [iconBg addSubview:iconIV];

        UILabel *nameLbl = [[UILabel alloc] init];
        nameLbl.tag = 503;
        nameLbl.translatesAutoresizingMaskIntoConstraints = NO;
        nameLbl.font = AMThemeFont(15.0, UIFontWeightBold);
        nameLbl.textColor = [UIColor colorWithRed:0.114 green:0.118 blue:0.173 alpha:1.0];
        [card addSubview:nameLbl];

        UILabel *subLbl = [[UILabel alloc] init];
        subLbl.tag = 504;
        subLbl.translatesAutoresizingMaskIntoConstraints = NO;
        subLbl.font = AMThemeFont(12.0, UIFontWeightRegular);
        subLbl.textColor = [UIColor colorWithRed:0.557 green:0.573 blue:0.643 alpha:1.0];
        [card addSubview:subLbl];

        [NSLayoutConstraint activateConstraints:@[
            [card.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:4.0],
            [card.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-4.0],
            [card.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:16.0],
            [card.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-16.0],

            [iconBg.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:12.0],
            [iconBg.centerYAnchor constraintEqualToAnchor:card.centerYAnchor],
            [iconBg.widthAnchor constraintEqualToConstant:42.0],
            [iconBg.heightAnchor constraintEqualToConstant:42.0],

            [iconIV.centerXAnchor constraintEqualToAnchor:iconBg.centerXAnchor],
            [iconIV.centerYAnchor constraintEqualToAnchor:iconBg.centerYAnchor],
            [iconIV.widthAnchor constraintEqualToConstant:20.0],
            [iconIV.heightAnchor constraintEqualToConstant:20.0],

            [nameLbl.leadingAnchor constraintEqualToAnchor:iconBg.trailingAnchor constant:12.0],
            [nameLbl.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-14.0],
            [nameLbl.topAnchor constraintEqualToAnchor:card.topAnchor constant:14.0],

            [subLbl.leadingAnchor constraintEqualToAnchor:nameLbl.leadingAnchor],
            [subLbl.trailingAnchor constraintEqualToAnchor:nameLbl.trailingAnchor],
            [subLbl.topAnchor constraintEqualToAnchor:nameLbl.bottomAnchor constant:3.0],
        ]];
    }

    UIView *iconBg = [cell.contentView viewWithTag:501];
    UIImageView *iconIV = (UIImageView *)[cell.contentView viewWithTag:502];
    UILabel *nameLbl = (UILabel *)[cell.contentView viewWithTag:503];
    UILabel *subLbl = (UILabel *)[cell.contentView viewWithTag:504];

    if (self.folders.count == 0) {
        iconBg.backgroundColor = [UIColor colorWithRed:0.114 green:0.118 blue:0.173 alpha:1.0];
        if (@available(iOS 13.0, *)) {
            iconIV.image = [UIImage systemImageNamed:@"folder.badge.plus"];
        }
        nameLbl.text = @"Create First Folder";
        subLbl.text = @"Tap to create a folder and assign selected projects";
        return cell;
    }

    NSDictionary *f = self.folders[indexPath.row];
    iconBg.backgroundColor = AMColorFromHex(f[@"colorHex"]);
    if (@available(iOS 13.0, *)) {
        iconIV.image = [UIImage systemImageNamed:@"folder.fill"];
    }
    nameLbl.text = f[@"name"] ?: @"Folder";
    NSUInteger c = ((NSArray *)f[@"projects"]).count;
    subLbl.text = (c == 1) ? @"1 project • Tap to assign" : [NSString stringWithFormat:@"%lu projects • Tap to assign", (unsigned long)c];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (self.folders.count == 0) {
        [self onTapNewFolder];
        return;
    }
    if (indexPath.row >= (NSInteger)self.folders.count) return;
    NSDictionary *f = self.folders[indexPath.row];
    AMAssignProjectsToFolder(f[@"id"], self.selectedProjects);
    gAMFoldersModalOpen = NO;
    [self dismissViewControllerAnimated:YES completion:nil];
}

@end

// ============================================================================
// Unified Homepage Overlay Manager (Search, Folders Pill, Assign Folder)
// ============================================================================

// ============================================================================
// Inline Expandable Folders View (Right Under "Your projects")
// ============================================================================

@interface AMHomepageFoldersInlineView : UIView
@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) UIStackView *stackView;
@property (nonatomic, strong) NSMutableArray<NSMutableDictionary *> *folders;
@property (nonatomic, strong) NSMutableSet<NSString *> *expandedFolderIds;
@property (nonatomic, copy) NSArray<NSDictionary *> *diskProjects;
@property (nonatomic, strong) NSCache<NSString *, UIImage *> *thumbCache;
@property (nonatomic, strong) NSDate *lastFileMtime;
@property (nonatomic, assign) CGFloat lastContentHeight;
@property (nonatomic, assign) BOOL isDropdownExpanded;
- (void)reloadForce:(BOOL)force diskProjects:(NSArray<NSDictionary *> *)diskProjects;
- (CGFloat)desiredHeightWithMaxHeight:(CGFloat)maxH;
@end

@implementation AMHomepageFoldersInlineView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor colorWithRed:0.965 green:0.969 blue:0.984 alpha:1.0]; // #F6F7FB
        self.clipsToBounds = YES;
        self.expandedFolderIds = [NSMutableSet set];
        self.thumbCache = [[NSCache alloc] init];

        self.scrollView = [[UIScrollView alloc] init];
        self.scrollView.translatesAutoresizingMaskIntoConstraints = NO;
        self.scrollView.showsVerticalScrollIndicator = YES;
        self.scrollView.alwaysBounceVertical = NO;
        [self addSubview:self.scrollView];

        self.stackView = [[UIStackView alloc] init];
        self.stackView.translatesAutoresizingMaskIntoConstraints = NO;
        self.stackView.axis = UILayoutConstraintAxisVertical;
        self.stackView.spacing = 6.0;
        [self.scrollView addSubview:self.stackView];

        UIView *divider = [[UIView alloc] init];
        divider.translatesAutoresizingMaskIntoConstraints = NO;
        divider.backgroundColor = [UIColor colorWithRed:0.114 green:0.118 blue:0.173 alpha:0.08];
        [self addSubview:divider];

        [NSLayoutConstraint activateConstraints:@[
            [self.scrollView.topAnchor constraintEqualToAnchor:self.topAnchor],
            [self.scrollView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
            [self.scrollView.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
            [self.scrollView.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-1.0],

            [self.stackView.topAnchor constraintEqualToAnchor:self.scrollView.topAnchor constant:2.0],
            [self.stackView.leadingAnchor constraintEqualToAnchor:self.scrollView.leadingAnchor constant:16.0],
            [self.stackView.trailingAnchor constraintEqualToAnchor:self.scrollView.trailingAnchor constant:-16.0],
            [self.stackView.bottomAnchor constraintEqualToAnchor:self.scrollView.bottomAnchor constant:-6.0],
            [self.stackView.widthAnchor constraintEqualToAnchor:self.scrollView.widthAnchor constant:-32.0],

            [divider.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:16.0],
            [divider.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-16.0],
            [divider.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
            [divider.heightAnchor constraintEqualToConstant:1.0],
        ]];
    }
    return self;
}

- (void)reloadForce:(BOOL)force diskProjects:(NSArray<NSDictionary *> *)diskProjects {
    if (diskProjects) self.diskProjects = diskProjects;

    NSString *path = AMProjectFoldersFilePath();
    NSDate *mtime = nil;
    if (path.length > 0) {
        NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
        mtime = attrs[NSFileModificationDate];
    }
    if (!force && self.folders != nil) {
        if ((mtime == nil && self.lastFileMtime == nil) || (mtime && self.lastFileMtime && [mtime isEqualToDate:self.lastFileMtime])) {
            return;
        }
    }
    self.lastFileMtime = mtime;
    self.folders = AMLoadProjectFolders();
    [self rebuildUI];
}

- (CGFloat)desiredHeightWithMaxHeight:(CGFloat)maxH {
    if (self.folders.count == 0) return 0.0;
    CGFloat h = self.lastContentHeight;
    if (h <= 0.0) h = 56.0;
    return MIN(h, maxH);
}

- (void)rebuildUI {
    for (UIView *sub in [self.stackView.arrangedSubviews copy]) {
        [self.stackView removeArrangedSubview:sub];
        [sub removeFromSuperview];
    }

    UIColor *navy = [UIColor colorWithRed:0.114 green:0.118 blue:0.173 alpha:1.0];
    UIColor *muted = [UIColor colorWithRed:0.557 green:0.573 blue:0.643 alpha:1.0];
    CGFloat totalH = 8.0; // top 2 + bottom 6

    // Collapsible "Folders (N)" dropdown header bar
    UIView *dropBar = [[UIView alloc] init];
    dropBar.translatesAutoresizingMaskIntoConstraints = NO;
    dropBar.backgroundColor = [UIColor whiteColor];
    dropBar.layer.cornerRadius = 11.0;
    dropBar.layer.borderWidth = 1.0;
    dropBar.layer.borderColor = [UIColor colorWithRed:0.114 green:0.118 blue:0.173 alpha:0.08].CGColor;
    [dropBar.heightAnchor constraintEqualToConstant:36.0].active = YES;
    UITapGestureRecognizer *dropTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(onTapDropdownToggle)];
    [dropBar addGestureRecognizer:dropTap];

    UIImageView *dropIcon = [[UIImageView alloc] init];
    dropIcon.translatesAutoresizingMaskIntoConstraints = NO;
    dropIcon.tintColor = navy;
    if (@available(iOS 13.0, *)) {
        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:13.0 weight:UIImageSymbolWeightSemibold];
        dropIcon.image = [UIImage systemImageNamed:@"folder.fill" withConfiguration:cfg];
    }
    [dropBar addSubview:dropIcon];

    UILabel *dropTitle = [[UILabel alloc] init];
    dropTitle.translatesAutoresizingMaskIntoConstraints = NO;
    dropTitle.font = AMThemeFont(13.5, UIFontWeightBold);
    dropTitle.textColor = navy;
    dropTitle.text = @"Folders";
    [dropBar addSubview:dropTitle];

    UILabel *dropCount = [[UILabel alloc] init];
    dropCount.translatesAutoresizingMaskIntoConstraints = NO;
    dropCount.backgroundColor = [UIColor colorWithRed:0.933 green:0.941 blue:0.969 alpha:1.0];
    dropCount.textColor = navy;
    dropCount.font = AMThemeFont(11.0, UIFontWeightBold);
    dropCount.textAlignment = NSTextAlignmentCenter;
    dropCount.layer.cornerRadius = 8.5;
    dropCount.clipsToBounds = YES;
    dropCount.text = [NSString stringWithFormat:@" %lu ", (unsigned long)self.folders.count];
    [dropBar addSubview:dropCount];

    UIImageView *dropChev = [[UIImageView alloc] init];
    dropChev.translatesAutoresizingMaskIntoConstraints = NO;
    dropChev.tintColor = muted;
    if (@available(iOS 13.0, *)) {
        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:12.0 weight:UIImageSymbolWeightBold];
        dropChev.image = [UIImage systemImageNamed:(self.isDropdownExpanded ? @"chevron.up" : @"chevron.down") withConfiguration:cfg];
    }
    [dropBar addSubview:dropChev];

    [NSLayoutConstraint activateConstraints:@[
        [dropIcon.leadingAnchor constraintEqualToAnchor:dropBar.leadingAnchor constant:12.0],
        [dropIcon.centerYAnchor constraintEqualToAnchor:dropBar.centerYAnchor],
        [dropIcon.widthAnchor constraintEqualToConstant:16.0],
        [dropIcon.heightAnchor constraintEqualToConstant:16.0],

        [dropTitle.leadingAnchor constraintEqualToAnchor:dropIcon.trailingAnchor constant:8.0],
        [dropTitle.centerYAnchor constraintEqualToAnchor:dropBar.centerYAnchor],

        [dropCount.leadingAnchor constraintEqualToAnchor:dropTitle.trailingAnchor constant:7.0],
        [dropCount.centerYAnchor constraintEqualToAnchor:dropBar.centerYAnchor],
        [dropCount.heightAnchor constraintEqualToConstant:17.0],
        [dropCount.widthAnchor constraintGreaterThanOrEqualToConstant:22.0],

        [dropChev.trailingAnchor constraintEqualToAnchor:dropBar.trailingAnchor constant:-12.0],
        [dropChev.centerYAnchor constraintEqualToAnchor:dropBar.centerYAnchor],
        [dropChev.widthAnchor constraintEqualToConstant:14.0],
        [dropChev.heightAnchor constraintEqualToConstant:14.0],
    ]];

    [self.stackView addArrangedSubview:dropBar];
    totalH += 36.0 + 6.0;

    if (!self.isDropdownExpanded) {
        self.lastContentHeight = totalH;
        return;
    }

    for (NSUInteger fi = 0; fi < self.folders.count; fi++) {
        NSDictionary *folder = self.folders[fi];
        NSString *fid = folder[@"id"] ?: @"";
        BOOL isExpanded = [self.expandedFolderIds containsObject:fid];
        NSArray *projs = [folder[@"projects"] isKindOfClass:[NSArray class]] ? folder[@"projects"] : @[];

        // Folder Header Card
        UIView *card = [[UIView alloc] init];
        card.translatesAutoresizingMaskIntoConstraints = NO;
        card.backgroundColor = [UIColor whiteColor];
        card.layer.cornerRadius = 12.0;
        card.layer.borderWidth = 1.0;
        card.layer.borderColor = [UIColor colorWithRed:0.114 green:0.118 blue:0.173 alpha:0.08].CGColor;
        card.layer.shadowColor = [UIColor blackColor].CGColor;
        card.layer.shadowOpacity = 0.04;
        card.layer.shadowRadius = 6.0;
        card.layer.shadowOffset = CGSizeMake(0, 2);
        card.tag = (NSInteger)fi;
        [card.heightAnchor constraintEqualToConstant:46.0].active = YES;

        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(onTapFolderCard:)];
        [card addGestureRecognizer:tap];

        UIView *iconBg = [[UIView alloc] init];
        iconBg.translatesAutoresizingMaskIntoConstraints = NO;
        iconBg.backgroundColor = AMColorFromHex(folder[@"colorHex"]);
        iconBg.layer.cornerRadius = 8.0;
        [card addSubview:iconBg];

        UIImageView *iconIV = [[UIImageView alloc] init];
        iconIV.translatesAutoresizingMaskIntoConstraints = NO;
        iconIV.tintColor = [UIColor whiteColor];
        if (@available(iOS 13.0, *)) {
            UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:13.0 weight:UIImageSymbolWeightSemibold];
            iconIV.image = [UIImage systemImageNamed:@"folder.fill" withConfiguration:cfg];
        }
        [iconBg addSubview:iconIV];

        UILabel *nameLbl = [[UILabel alloc] init];
        nameLbl.translatesAutoresizingMaskIntoConstraints = NO;
        nameLbl.font = AMThemeFont(14.0, UIFontWeightBold);
        nameLbl.textColor = navy;
        nameLbl.text = folder[@"name"] ?: @"Folder";
        [card addSubview:nameLbl];

        UILabel *countBadge = [[UILabel alloc] init];
        countBadge.translatesAutoresizingMaskIntoConstraints = NO;
        countBadge.backgroundColor = [UIColor colorWithRed:0.933 green:0.941 blue:0.969 alpha:1.0];
        countBadge.textColor = navy;
        countBadge.font = AMThemeFont(11.0, UIFontWeightBold);
        countBadge.textAlignment = NSTextAlignmentCenter;
        countBadge.layer.cornerRadius = 9.0;
        countBadge.clipsToBounds = YES;
        countBadge.text = [NSString stringWithFormat:@" %lu ", (unsigned long)projs.count];
        [card addSubview:countBadge];

        UIButton *moreBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        moreBtn.translatesAutoresizingMaskIntoConstraints = NO;
        moreBtn.tintColor = muted;
        moreBtn.tag = (NSInteger)fi;
        if (@available(iOS 13.0, *)) {
            UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:14.0 weight:UIImageSymbolWeightSemibold];
            [moreBtn setImage:[UIImage systemImageNamed:@"ellipsis" withConfiguration:cfg] forState:UIControlStateNormal];
        } else {
            [moreBtn setTitle:@"..." forState:UIControlStateNormal];
        }
        [moreBtn addTarget:self action:@selector(onTapFolderMore:) forControlEvents:UIControlEventTouchUpInside];
        [card addSubview:moreBtn];

        UIImageView *chev = [[UIImageView alloc] init];
        chev.translatesAutoresizingMaskIntoConstraints = NO;
        chev.tintColor = muted;
        if (@available(iOS 13.0, *)) {
            UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:12.0 weight:UIImageSymbolWeightBold];
            chev.image = [UIImage systemImageNamed:(isExpanded ? @"chevron.down" : @"chevron.right") withConfiguration:cfg];
        }
        [card addSubview:chev];

        [NSLayoutConstraint activateConstraints:@[
            [iconBg.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:10.0],
            [iconBg.centerYAnchor constraintEqualToAnchor:card.centerYAnchor],
            [iconBg.widthAnchor constraintEqualToConstant:28.0],
            [iconBg.heightAnchor constraintEqualToConstant:28.0],

            [iconIV.centerXAnchor constraintEqualToAnchor:iconBg.centerXAnchor],
            [iconIV.centerYAnchor constraintEqualToAnchor:iconBg.centerYAnchor],
            [iconIV.widthAnchor constraintEqualToConstant:15.0],
            [iconIV.heightAnchor constraintEqualToConstant:15.0],

            [nameLbl.leadingAnchor constraintEqualToAnchor:iconBg.trailingAnchor constant:10.0],
            [nameLbl.centerYAnchor constraintEqualToAnchor:card.centerYAnchor],

            [countBadge.leadingAnchor constraintEqualToAnchor:nameLbl.trailingAnchor constant:8.0],
            [countBadge.centerYAnchor constraintEqualToAnchor:card.centerYAnchor],
            [countBadge.heightAnchor constraintEqualToConstant:18.0],
            [countBadge.widthAnchor constraintGreaterThanOrEqualToConstant:22.0],

            [chev.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-12.0],
            [chev.centerYAnchor constraintEqualToAnchor:card.centerYAnchor],
            [chev.widthAnchor constraintEqualToConstant:14.0],
            [chev.heightAnchor constraintEqualToConstant:14.0],

            [moreBtn.trailingAnchor constraintEqualToAnchor:chev.leadingAnchor constant:-6.0],
            [moreBtn.centerYAnchor constraintEqualToAnchor:card.centerYAnchor],
            [moreBtn.widthAnchor constraintEqualToConstant:28.0],
            [moreBtn.heightAnchor constraintEqualToConstant:28.0],

            [nameLbl.trailingAnchor constraintLessThanOrEqualToAnchor:moreBtn.leadingAnchor constant:-36.0],
        ]];

        [self.stackView addArrangedSubview:card];
        totalH += 46.0 + 6.0;

        if (isExpanded) {
            if (projs.count == 0) {
                UILabel *emptyLbl = [[UILabel alloc] init];
                emptyLbl.translatesAutoresizingMaskIntoConstraints = NO;
                emptyLbl.text = @"  Empty — hold a project & tap Assign Folder";
                emptyLbl.font = AMThemeFont(12.0, UIFontWeightMedium);
                emptyLbl.textColor = muted;
                [emptyLbl.heightAnchor constraintEqualToConstant:30.0].active = YES;
                [self.stackView addArrangedSubview:emptyLbl];
                totalH += 30.0 + 6.0;
            } else {
                for (NSUInteger pi = 0; pi < projs.count; pi++) {
                    NSDictionary *resolved = AMResolveFolderProject(projs[pi], self.diskProjects ?: @[]);
                    UIView *pRow = [[UIView alloc] init];
                    pRow.translatesAutoresizingMaskIntoConstraints = NO;
                    pRow.backgroundColor = [UIColor whiteColor];
                    pRow.layer.cornerRadius = 11.0;
                    pRow.layer.borderWidth = 1.0;
                    pRow.layer.borderColor = [UIColor colorWithRed:0.114 green:0.118 blue:0.173 alpha:0.06].CGColor;
                    pRow.tag = (NSInteger)((fi << 16) | (pi & 0xFFFF));
                    [pRow.heightAnchor constraintEqualToConstant:54.0].active = YES;

                    UITapGestureRecognizer *pTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(onTapAssignedProject:)];
                    [pRow addGestureRecognizer:pTap];

                    UIImageView *thumbIV = [[UIImageView alloc] init];
                    thumbIV.translatesAutoresizingMaskIntoConstraints = NO;
                    thumbIV.backgroundColor = [UIColor colorWithRed:0.933 green:0.941 blue:0.969 alpha:1.0];
                    thumbIV.layer.cornerRadius = 8.0;
                    thumbIV.clipsToBounds = YES;
                    [pRow addSubview:thumbIV];

                    NSString *thumbPath = resolved[@"thumb"];
                    UIImage *img = nil;
                    if (thumbPath.length > 0) {
                        img = [self.thumbCache objectForKey:thumbPath];
                        if (!img) {
                            img = [UIImage imageWithContentsOfFile:thumbPath];
                            if (img) [self.thumbCache setObject:img forKey:thumbPath];
                        }
                    }
                    if (img) {
                        thumbIV.contentMode = UIViewContentModeScaleAspectFill;
                        thumbIV.image = img;
                    } else {
                        thumbIV.contentMode = UIViewContentModeCenter;
                        if (@available(iOS 13.0, *)) {
                            thumbIV.image = [UIImage systemImageNamed:@"film.stack"];
                            thumbIV.tintColor = navy;
                        }
                    }

                    UILabel *pTitle = [[UILabel alloc] init];
                    pTitle.translatesAutoresizingMaskIntoConstraints = NO;
                    pTitle.font = AMThemeFont(13.5, UIFontWeightBold);
                    pTitle.textColor = navy;
                    pTitle.text = resolved[@"title"];
                    [pRow addSubview:pTitle];

                    UILabel *pMeta = [[UILabel alloc] init];
                    pMeta.translatesAutoresizingMaskIntoConstraints = NO;
                    pMeta.font = AMThemeFont(11.0, UIFontWeightRegular);
                    pMeta.textColor = muted;
                    pMeta.text = resolved[@"meta"];
                    [pRow addSubview:pMeta];

                    UIButton *remBtn = [UIButton buttonWithType:UIButtonTypeSystem];
                    remBtn.translatesAutoresizingMaskIntoConstraints = NO;
                    remBtn.tintColor = muted;
                    remBtn.tag = (NSInteger)((fi << 16) | (pi & 0xFFFF));
                    if (@available(iOS 13.0, *)) {
                        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:15.0 weight:UIImageSymbolWeightMedium];
                        [remBtn setImage:[UIImage systemImageNamed:@"xmark.circle.fill" withConfiguration:cfg] forState:UIControlStateNormal];
                    } else {
                        [remBtn setTitle:@"×" forState:UIControlStateNormal];
                    }
                    [remBtn addTarget:self action:@selector(onTapRemoveProject:) forControlEvents:UIControlEventTouchUpInside];
                    [pRow addSubview:remBtn];

                    [NSLayoutConstraint activateConstraints:@[
                        [thumbIV.leadingAnchor constraintEqualToAnchor:pRow.leadingAnchor constant:16.0],
                        [thumbIV.centerYAnchor constraintEqualToAnchor:pRow.centerYAnchor],
                        [thumbIV.widthAnchor constraintEqualToConstant:38.0],
                        [thumbIV.heightAnchor constraintEqualToConstant:38.0],

                        [pTitle.leadingAnchor constraintEqualToAnchor:thumbIV.trailingAnchor constant:10.0],
                        [pTitle.trailingAnchor constraintEqualToAnchor:remBtn.leadingAnchor constant:-6.0],
                        [pTitle.topAnchor constraintEqualToAnchor:pRow.topAnchor constant:9.0],

                        [pMeta.leadingAnchor constraintEqualToAnchor:pTitle.leadingAnchor],
                        [pMeta.trailingAnchor constraintEqualToAnchor:pTitle.trailingAnchor],
                        [pMeta.topAnchor constraintEqualToAnchor:pTitle.bottomAnchor constant:2.0],

                        [remBtn.trailingAnchor constraintEqualToAnchor:pRow.trailingAnchor constant:-10.0],
                        [remBtn.centerYAnchor constraintEqualToAnchor:pRow.centerYAnchor],
                        [remBtn.widthAnchor constraintEqualToConstant:26.0],
                        [remBtn.heightAnchor constraintEqualToConstant:26.0],
                    ]];

                    [self.stackView addArrangedSubview:pRow];
                    totalH += 54.0 + 6.0;
                }
            }
        }
    }
    self.lastContentHeight = totalH;
}

- (void)onTapDropdownToggle {
    self.isDropdownExpanded = !self.isDropdownExpanded;
    [self rebuildUI];
}

- (void)onTapFolderCard:(UITapGestureRecognizer *)gr {
    NSInteger idx = gr.view.tag;
    if (idx < 0 || idx >= (NSInteger)self.folders.count) return;
    NSString *fid = self.folders[idx][@"id"];
    if (fid.length == 0) return;
    if ([self.expandedFolderIds containsObject:fid]) {
        [self.expandedFolderIds removeObject:fid];
    } else {
        [self.expandedFolderIds addObject:fid];
    }
    [self rebuildUI];
}

- (void)onTapFolderMore:(UIButton *)sender {
    NSInteger idx = sender.tag;
    if (idx < 0 || idx >= (NSInteger)self.folders.count) return;
    NSMutableDictionary *f = self.folders[idx];
    UIViewController *top = AMTopMostViewController();
    if (!top) return;

    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:f[@"name"]
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    __weak AMHomepageFoldersInlineView *weakSelf = self;
    [sheet addAction:[UIAlertAction actionWithTitle:@"Rename Folder" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        (void)a;
        UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Rename Folder" message:nil preferredStyle:UIAlertControllerStyleAlert];
        [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) { tf.text = f[@"name"]; }];
        [ac addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
        [ac addAction:[UIAlertAction actionWithTitle:@"Save" style:UIAlertActionStyleDefault handler:^(UIAlertAction *act) {
            (void)act;
            NSString *n = [ac.textFields.firstObject.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (n.length > 0) {
                f[@"name"] = n;
                AMSaveProjectFolders(weakSelf.folders);
                [weakSelf reloadForce:YES diskProjects:nil];
            }
        }]];
        [top presentViewController:ac animated:YES completion:nil];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Delete Folder" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        (void)a;
        if (idx < (NSInteger)weakSelf.folders.count) {
            [weakSelf.folders removeObjectAtIndex:idx];
            AMSaveProjectFolders(weakSelf.folders);
            [weakSelf reloadForce:YES diskProjects:nil];
        }
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [top presentViewController:sheet animated:YES completion:nil];
}

- (void)onTapAssignedProject:(UITapGestureRecognizer *)gr {
    NSUInteger fi = (NSUInteger)(gr.view.tag >> 16);
    NSUInteger pi = (NSUInteger)(gr.view.tag & 0xFFFF);
    if (fi >= self.folders.count) return;
    NSArray *projs = self.folders[fi][@"projects"];
    if (pi >= projs.count) return;
    NSDictionary *resolved = AMResolveFolderProject(projs[pi], self.diskProjects ?: @[]);
    NSString *path = resolved[@"path"];
    if (path.length == 0) return;
    if (!AMOpenLocalProjectInMainVC(path)) {
        AMOpenLocalFileInApp([NSURL fileURLWithPath:path]);
    }
}

- (void)onTapRemoveProject:(UIButton *)sender {
    NSUInteger fi = (NSUInteger)(sender.tag >> 16);
    NSUInteger pi = (NSUInteger)(sender.tag & 0xFFFF);
    if (fi >= self.folders.count) return;
    NSMutableArray *projs = self.folders[fi][@"projects"];
    if (pi >= projs.count) return;
    [projs removeObjectAtIndex:pi];
    AMSaveProjectFolders(self.folders);
    [self reloadForce:YES diskProjects:nil];
}

@end

// ============================================================================
// Module 4B: Homepage Original Alight Motion / Batch Project Importer
// ============================================================================

static NSString *AMFindThumbnailInContainer(NSString *projPath, NSString * _Nullable containerRoot) {
    if (projPath.length == 0) return nil;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *stem = [[projPath lastPathComponent] stringByDeletingPathExtension];
    if (stem.length == 0) return nil;

    NSArray<NSString *> *exts = @[@"jpg", @"jpeg", @"png", @"webp"];
    NSMutableArray<NSString *> *dirs = [NSMutableArray array];
    if (containerRoot.length > 0) {
        [dirs addObject:[containerRoot stringByAppendingPathComponent:@"Library/Caches/projectThumbnails"]];
        [dirs addObject:[containerRoot stringByAppendingPathComponent:@"Library/projectThumbnails"]];
    }
    NSString *parent = [projPath stringByDeletingLastPathComponent];
    if (parent.length > 0) [dirs addObject:parent];

    for (NSString *dir in dirs) {
        for (NSString *ext in exts) {
            NSString *cand = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.%@", stem, ext]];
            if ([fm fileExistsAtPath:cand]) return cand;
        }
        NSArray<NSString *> *files = [fm contentsOfDirectoryAtPath:dir error:nil];
        for (NSString *fn in files) {
            if ([fn hasPrefix:stem]) {
                NSString *e = fn.pathExtension.lowercaseString;
                if ([e isEqualToString:@"jpg"] || [e isEqualToString:@"jpeg"] ||
                    [e isEqualToString:@"png"] || [e isEqualToString:@"webp"]) {
                    return [dir stringByAppendingPathComponent:fn];
                }
            }
        }
    }
    return nil;
}

static NSDictionary * _Nullable AMParseProjectFileEntry(NSString *fullPath, NSString * _Nullable containerRoot) {
    if (fullPath.length == 0) return nil;
    NSString *ext = fullPath.pathExtension.lowercaseString ?: @"";

    NSString *title = nil;
    NSString *meta = @"";
    BOOL isAmproj = NO;

    if ([ext isEqualToString:@"amproj"] || [ext isEqualToString:@"zip"]) {
        NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:fullPath];
        NSData *head = [fh readDataOfLength:4];
        [fh closeFile];
        if (head.length < 4) return nil;
        const uint8_t *b = (const uint8_t *)head.bytes;
        if (!(b[0] == 'P' && b[1] == 'K' && b[2] == 0x03 && b[3] == 0x04)) return nil;
        title = [[fullPath lastPathComponent] stringByDeletingPathExtension];
        meta = @".amproj package";
        isAmproj = YES;
    } else if ([ext isEqualToString:@"xml"] || ext.length == 0) {
        NSDictionary *xinfo = AMReadSceneInfoXattr(fullPath);
        if (xinfo && [xinfo[@"title"] length] > 0) {
            title = xinfo[@"title"];
            meta = xinfo[@"meta"] ?: @"";
        } else {
            NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:fullPath];
            NSData *head = [fh readDataOfLength:16384];
            [fh closeFile];
            if (head.length < 16) return nil;
            NSString *txt = [[NSString alloc] initWithData:head encoding:NSUTF8StringEncoding];
            if (!txt || ![txt containsString:@"<scene"]) return nil;
            NSRange sStart = [txt rangeOfString:@"<scene"];
            NSRange sEnd = [txt rangeOfString:@">" options:0 range:NSMakeRange(sStart.location, txt.length - sStart.location)];
            if (sEnd.location == NSNotFound) return nil;
            NSString *tag = [txt substringWithRange:NSMakeRange(sStart.location, (sEnd.location - sStart.location) + 1)];
            title = AMExtractXMLAttr(tag, @"title");
            if (title.length == 0) {
                title = [[fullPath lastPathComponent] stringByDeletingPathExtension];
            }
            NSString *w = AMExtractXMLAttr(tag, @"width");
            NSString *h = AMExtractXMLAttr(tag, @"height");
            NSString *fps = AMExtractXMLAttr(tag, @"fps");
            NSMutableArray<NSString *> *parts = [NSMutableArray array];
            if (w.length > 0 && h.length > 0) [parts addObject:[NSString stringWithFormat:@"%@x%@", w, h]];
            if (fps.length > 0) [parts addObject:[NSString stringWithFormat:@"%@fps", fps]];
            meta = parts.count > 0 ? [parts componentsJoinedByString:@"  •  "] : @"XML Project";
        }
    } else {
        return nil;
    }

    if (title.length == 0) return nil;
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:fullPath error:nil];
    NSDate *modDate = attrs[NSFileModificationDate] ?: [NSDate distantPast];
    NSString *thumb = AMFindThumbnailInContainer(fullPath, containerRoot) ?: @"";

    static NSDateFormatter *df = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        df = [[NSDateFormatter alloc] init];
        df.dateStyle = NSDateFormatterMediumStyle;
        df.timeStyle = NSDateFormatterNoStyle;
    });
    NSString *dateStr = [modDate isEqualToDate:[NSDate distantPast]] ? @"" : [df stringFromDate:modDate];
    NSString *fullMeta = (dateStr.length > 0 && meta.length > 0 && ![meta containsString:dateStr])
        ? [NSString stringWithFormat:@"%@  •  %@", meta, dateStr]
        : (meta.length > 0 ? meta : dateStr);

    return @{
        @"title": title,
        @"meta": fullMeta ?: @"Alight Motion Project",
        @"path": fullPath,
        @"thumb": thumb,
        @"date": modDate,
        @"isAmproj": @(isAmproj),
        @"containerRoot": containerRoot ?: @""
    };
}

static NSArray<NSDictionary *> *AMScanProjectsInDirectory(NSString *rootDir, NSString * _Nullable containerRoot) {
    if (rootDir.length == 0) return @[];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray<NSDictionary *> *results = [NSMutableArray array];
    NSMutableSet<NSString *> *seenPaths = [NSMutableSet set];

    NSSet<NSString *> *skipTopDirs = [NSSet setWithArray:@[
        @"Caches", @"Preferences", @"Cookies", @"SplashBoard", @"Saved Application State",
        @"HTTPStorages", @"WebKit", @"CustomEffects", @"ProjectFolders", @"Firebase",
        @"Google", @"Amplitude", @"Logs", @"Crashlytics", @"com.apple.nsurlsessiond", @"Inbox"
    ]];

    NSDirectoryEnumerator<NSString *> *en = [fm enumeratorAtPath:rootDir];
    NSString *rel = nil;
    NSInteger scanned = 0;
    while ((rel = [en nextObject]) != nil && scanned < 4000) {
        scanned++;
        NSString *firstComp = rel.pathComponents.firstObject ?: @"";
        if ([skipTopDirs containsObject:firstComp]) {
            [en skipDescendants];
            continue;
        }
        NSString *full = [rootDir stringByAppendingPathComponent:rel];
        if ([seenPaths containsObject:full]) continue;
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:full isDirectory:&isDir] || isDir) continue;

        NSDictionary *entry = AMParseProjectFileEntry(full, containerRoot);
        if (entry) {
            [seenPaths addObject:full];
            [results addObject:entry];
        }
    }

    [results sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSDate *da = a[@"date"] ?: [NSDate distantPast];
        NSDate *db = b[@"date"] ?: [NSDate distantPast];
        return [db compare:da];
    }];
    return results;
}

// Attempts to locate the Original App Store Alight Motion container (succeeds on TrollStore / jailbroken devices;
// reports sandboxBlocked=YES cleanly on stock non-jailbroken sideloads).
static NSArray<NSDictionary *> *AMFindOriginalAlightMotionProjects(NSString **outContainerPath, BOOL *outSandboxBlocked) {
    if (outContainerPath) *outContainerPath = nil;
    if (outSandboxBlocked) *outSandboxBlocked = NO;

    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *appsRoot = @"/var/mobile/Containers/Data/Application";
    NSError *err = nil;
    NSArray<NSString *> *uuids = [fm contentsOfDirectoryAtPath:appsRoot error:&err];
    if (!uuids || uuids.count == 0) {
        if (outSandboxBlocked) *outSandboxBlocked = YES;
        return @[];
    }

    NSString *myHome = [NSHomeDirectory() stringByStandardizingPath] ?: @"";
    NSString *matchedContainer = nil;
    NSMutableArray<NSDictionary *> *found = [NSMutableArray array];

    for (NSString *u in uuids) {
        NSString *cDir = [[appsRoot stringByAppendingPathComponent:u] stringByStandardizingPath];
        if ([cDir isEqualToString:myHome]) continue;

        NSString *metaPlist = [cDir stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"];
        NSDictionary *meta = [NSDictionary dictionaryWithContentsOfFile:metaPlist];
        NSString *bid = [meta[@"MCMMetadataIdentifier"] isKindOfClass:[NSString class]] ? meta[@"MCMMetadataIdentifier"] : @"";
        BOOL isAlight = [bid isEqualToString:@"com.alightcreative.motion"] ||
                        ([bid localizedCaseInsensitiveContainsString:@"alightcreative.motion"]);

        if (!isAlight && bid.length > 0) continue;

        NSString *libDir = [cDir stringByAppendingPathComponent:@"Library"];
        if (![fm fileExistsAtPath:libDir]) continue;

        NSArray<NSDictionary *> *libProjs = AMScanProjectsInDirectory(libDir, cDir);
        if (libProjs.count > 0 || isAlight) {
            matchedContainer = cDir;
            [found addObjectsFromArray:libProjs];
            NSString *docsDir = [cDir stringByAppendingPathComponent:@"Documents"];
            if ([fm fileExistsAtPath:docsDir]) {
                [found addObjectsFromArray:AMScanProjectsInDirectory(docsDir, cDir)];
            }
            if (isAlight) break;
        }
    }

    if (outContainerPath) *outContainerPath = matchedContainer;
    return found;
}

static NSString * _Nullable AMImportXMLProjectFileToLibrary(NSString *srcPath,
                                                            NSString * _Nullable srcContainerRoot,
                                                            NSString * _Nullable optionalThumbPath,
                                                            NSError **outErr) {
    NSFileManager *fm = [NSFileManager defaultManager];
    if (srcPath.length == 0 || ![fm fileExistsAtPath:srcPath]) {
        if (outErr) *outErr = [NSError errorWithDomain:@"AMProjectImport" code:1 userInfo:@{NSLocalizedDescriptionKey: @"Source file not found."}];
        return nil;
    }

    NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:srcPath];
    NSData *head = [fh readDataOfLength:16384];
    [fh closeFile];
    NSString *prefix = head ? [[NSString alloc] initWithData:head encoding:NSUTF8StringEncoding] : nil;
    if (!prefix || ![prefix containsString:@"<scene"]) {
        if (outErr) *outErr = [NSError errorWithDomain:@"AMProjectImport" code:2 userInfo:@{NSLocalizedDescriptionKey: @"Not a valid Alight Motion <scene> XML project."}];
        return nil;
    }

    NSString *libDir = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES).firstObject;
    if (libDir.length == 0) {
        if (outErr) *outErr = [NSError errorWithDomain:@"AMProjectImport" code:3 userInfo:@{NSLocalizedDescriptionKey: @"Library directory unavailable."}];
        return nil;
    }

    NSString *newUUID = [[NSUUID UUID] UUIDString];
    NSString *dstPath = [libDir stringByAppendingPathComponent:[newUUID stringByAppendingString:@".xml"]];
    NSError *cpErr = nil;
    if (![fm copyItemAtPath:srcPath toPath:dstPath error:&cpErr]) {
        if (outErr) *outErr = cpErr;
        return nil;
    }

    // Preserve com.alightcreative.motion.sceneinfo xattr if present on source
    ssize_t xsz = getxattr(srcPath.UTF8String, "com.alightcreative.motion.sceneinfo", NULL, 0, 0, 0);
    if (xsz > 0 && xsz <= 65536) {
        NSMutableData *xbuf = [NSMutableData dataWithLength:(NSUInteger)xsz];
        if (getxattr(srcPath.UTF8String, "com.alightcreative.motion.sceneinfo", xbuf.mutableBytes, (size_t)xsz, 0, 0) > 0) {
            setxattr(dstPath.UTF8String, "com.alightcreative.motion.sceneinfo", xbuf.bytes, xbuf.length, 0, 0);
        }
    }

    // Copy project thumbnail if available
    NSString *thumbSrc = optionalThumbPath.length > 0 ? optionalThumbPath : AMFindThumbnailInContainer(srcPath, srcContainerRoot);
    if (thumbSrc.length > 0 && [fm fileExistsAtPath:thumbSrc]) {
        NSString *thumbDir = [libDir stringByAppendingPathComponent:@"Caches/projectThumbnails"];
        [fm createDirectoryAtPath:thumbDir withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *ext = thumbSrc.pathExtension.length > 0 ? thumbSrc.pathExtension : @"jpg";
        NSString *thumbDst = [thumbDir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.%@", newUUID, ext]];
        [fm removeItemAtPath:thumbDst error:nil];
        [fm copyItemAtPath:thumbSrc toPath:thumbDst error:nil];
    }

    // Best-effort copy of referenced local media files when importing from another Alight Motion container
    if (srcContainerRoot.length > 0) {
        NSString *srcMediaDir = [srcContainerRoot stringByAppendingPathComponent:@"Library/media"];
        if ([fm fileExistsAtPath:srcMediaDir]) {
            NSString *fullXML = [NSString stringWithContentsOfFile:dstPath encoding:NSUTF8StringEncoding error:nil];
            if (fullXML.length > 0) {
                NSString *dstMediaDir = [libDir stringByAppendingPathComponent:@"media"];
                [fm createDirectoryAtPath:dstMediaDir withIntermediateDirectories:YES attributes:nil error:nil];
                NSArray<NSString *> *mediaFiles = [fm contentsOfDirectoryAtPath:srcMediaDir error:nil];
                for (NSString *mf in mediaFiles) {
                    if ([fullXML containsString:mf]) {
                        NSString *ms = [srcMediaDir stringByAppendingPathComponent:mf];
                        NSString *md = [dstMediaDir stringByAppendingPathComponent:mf];
                        if (![fm fileExistsAtPath:md]) {
                            [fm copyItemAtPath:ms toPath:md error:nil];
                        }
                    }
                }
            }
        }
    }

    return dstPath;
}

static NSInteger AMImportInboxProjectsIfAny(void) {
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    if (docs.length == 0) return 0;
    NSString *inbox = [docs stringByAppendingPathComponent:@"Inbox"];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray<NSString *> *files = [fm contentsOfDirectoryAtPath:inbox error:nil];
    if (files.count == 0) return 0;

    NSInteger imported = 0;
    for (NSString *fn in files) {
        NSString *full = [inbox stringByAppendingPathComponent:fn];
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:full isDirectory:&isDir] || isDir) continue;
        NSString *ext = fn.pathExtension.lowercaseString ?: @"";
        if ([ext isEqualToString:@"xml"]) {
            if (AMImportXMLProjectFileToLibrary(full, nil, nil, nil) != nil) {
                imported++;
                [fm removeItemAtPath:full error:nil];
            }
        }
    }
    return imported;
}

static void AMQueueSequentialAmprojImports(NSArray<NSURL *> *urls) {
    if (urls.count == 0) return;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray<NSURL *> *staged = [NSMutableArray array];
    long long ts = (long long)[[NSDate date] timeIntervalSince1970];
    NSUInteger idx = 0;
    for (NSURL *u in urls) {
        BOOL scoped = [u startAccessingSecurityScopedResource];
        NSString *ext = u.pathExtension.length > 0 ? u.pathExtension : @"amproj";
        NSString *dst = [NSTemporaryDirectory() stringByAppendingPathComponent:
                         [NSString stringWithFormat:@"AMBatchImport_%lld_%lu.%@", ts, (unsigned long)idx++, ext]];
        [fm removeItemAtPath:dst error:nil];
        if ([fm copyItemAtPath:u.path toPath:dst error:nil]) {
            [staged addObject:[NSURL fileURLWithPath:dst]];
        }
        if (scoped) [u stopAccessingSecurityScopedResource];
    }
    for (NSUInteger i = 0; i < staged.count; i++) {
        NSURL *fileURL = staged[i];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * 1.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            AMOpenLocalFileInApp(fileURL);
        });
    }
}

@interface AMOriginalProjectsImporterVC : UIViewController <UITableViewDataSource, UITableViewDelegate, UIDocumentPickerDelegate>
@property (nonatomic, copy) void (^onProjectsImported)(NSInteger count);
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UILabel *statusTitleLabel;
@property (nonatomic, strong) UILabel *statusBodyLabel;
@property (nonatomic, strong) UIView *statusCard;
@property (nonatomic, strong) UIButton *importSelectedButton;
@property (nonatomic, strong) UILabel *emptyListLabel;
@property (nonatomic, copy) NSArray<NSDictionary *> *candidateProjects;
@property (nonatomic, strong) NSMutableSet<NSNumber *> *selectedIndices;
@property (nonatomic, strong) NSCache<NSString *, UIImage *> *thumbCache;
@property (nonatomic, assign) BOOL pickingFolderMode;
@property (nonatomic, strong, nullable) NSURL *activeScopedFolderURL;
@end

@implementation AMOriginalProjectsImporterVC

- (void)dealloc {
    if (self.activeScopedFolderURL) {
        [self.activeScopedFolderURL stopAccessingSecurityScopedResource];
        self.activeScopedFolderURL = nil;
    }
}

- (void)viewDidLoad {
    [super viewDidLoad];
    if (@available(iOS 13.0, *)) {
        self.overrideUserInterfaceStyle = UIUserInterfaceStyleLight;
    }
    self.thumbCache = [[NSCache alloc] init];
    self.selectedIndices = [NSMutableSet set];
    self.candidateProjects = @[];

    UIColor *bgColor = [UIColor colorWithRed:0.965 green:0.969 blue:0.984 alpha:1.0];
    UIColor *navy = [UIColor colorWithRed:0.114 green:0.118 blue:0.173 alpha:1.0];
    UIColor *muted = [UIColor colorWithRed:0.45 green:0.47 blue:0.55 alpha:1.0];
    self.view.backgroundColor = bgColor;
    self.title = @"Import Projects";

    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Close"
                                                                             style:UIBarButtonItemStylePlain
                                                                            target:self
                                                                            action:@selector(onClose)];
    self.navigationItem.leftBarButtonItem.tintColor = navy;

    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Select All"
                                                                              style:UIBarButtonItemStylePlain
                                                                             target:self
                                                                             action:@selector(onToggleSelectAll)];
    self.navigationItem.rightBarButtonItem.tintColor = navy;

    // Header container (status + 3 quick batch-import actions)
    UIView *headerWrap = [[UIView alloc] init];
    headerWrap.translatesAutoresizingMaskIntoConstraints = NO;
    headerWrap.backgroundColor = bgColor;
    [self.view addSubview:headerWrap];

    self.statusCard = [[UIView alloc] init];
    self.statusCard.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusCard.backgroundColor = [UIColor whiteColor];
    self.statusCard.layer.cornerRadius = 14.0;
    self.statusCard.layer.borderWidth = 1.0;
    self.statusCard.layer.borderColor = [UIColor colorWithRed:0.114 green:0.118 blue:0.173 alpha:0.08].CGColor;
    [headerWrap addSubview:self.statusCard];

    self.statusTitleLabel = [[UILabel alloc] init];
    self.statusTitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusTitleLabel.font = AMThemeFont(13.5, UIFontWeightBold);
    self.statusTitleLabel.textColor = navy;
    self.statusTitleLabel.numberOfLines = 1;
    [self.statusCard addSubview:self.statusTitleLabel];

    self.statusBodyLabel = [[UILabel alloc] init];
    self.statusBodyLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusBodyLabel.font = AMThemeFont(12.0, UIFontWeightRegular);
    self.statusBodyLabel.textColor = muted;
    self.statusBodyLabel.numberOfLines = 0;
    [self.statusCard addSubview:self.statusBodyLabel];

    UIStackView *btnRow = [[UIStackView alloc] init];
    btnRow.translatesAutoresizingMaskIntoConstraints = NO;
    btnRow.axis = UILayoutConstraintAxisHorizontal;
    btnRow.spacing = 8.0;
    btnRow.distribution = UIStackViewDistributionFillEqually;
    [headerWrap addSubview:btnRow];

    UIButton *filesBtn = [self makeActionPill:@"Files (.xml/.amproj)" symbol:@"doc.on.doc" action:@selector(onTapPickFiles)];
    UIButton *folderBtn = [self makeActionPill:@"Pick Folder" symbol:@"folder" action:@selector(onTapPickFolder)];
    UIButton *linksBtn = [self makeActionPill:@"Alight Links" symbol:@"link" action:@selector(onTapBatchLinks)];
    [btnRow addArrangedSubview:filesBtn];
    [btnRow addArrangedSubview:folderBtn];
    [btnRow addArrangedSubview:linksBtn];

    // Table view for multi-selecting Original Alight Motion / Folder projects
    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.tableView.backgroundColor = bgColor;
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.tableView.contentInset = UIEdgeInsetsMake(4.0, 0.0, 92.0, 0.0);
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    [self.view addSubview:self.tableView];

    self.emptyListLabel = [[UILabel alloc] init];
    self.emptyListLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.emptyListLabel.font = AMThemeFont(13.0, UIFontWeightMedium);
    self.emptyListLabel.textColor = muted;
    self.emptyListLabel.textAlignment = NSTextAlignmentCenter;
    self.emptyListLabel.numberOfLines = 0;
    self.emptyListLabel.text = @"Tip: In Original Alight Motion, export projects as XML or Project Package to Files (or Share XML directly to this app), then pick them above.";
    [self.view addSubview:self.emptyListLabel];

    // Sticky bottom import button
    self.importSelectedButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.importSelectedButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.importSelectedButton.backgroundColor = navy;
    [self.importSelectedButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.importSelectedButton.titleLabel.font = AMThemeFont(15.0, UIFontWeightBold);
    self.importSelectedButton.layer.cornerRadius = 24.0;
    self.importSelectedButton.layer.shadowColor = [UIColor blackColor].CGColor;
    self.importSelectedButton.layer.shadowOpacity = 0.18;
    self.importSelectedButton.layer.shadowRadius = 10.0;
    self.importSelectedButton.layer.shadowOffset = CGSizeMake(0, 4);
    [self.importSelectedButton addTarget:self action:@selector(onTapImportSelected) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.importSelectedButton];

    [NSLayoutConstraint activateConstraints:@[
        [headerWrap.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [headerWrap.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [headerWrap.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],

        [self.statusCard.topAnchor constraintEqualToAnchor:headerWrap.topAnchor constant:10.0],
        [self.statusCard.leadingAnchor constraintEqualToAnchor:headerWrap.leadingAnchor constant:16.0],
        [self.statusCard.trailingAnchor constraintEqualToAnchor:headerWrap.trailingAnchor constant:-16.0],

        [self.statusTitleLabel.topAnchor constraintEqualToAnchor:self.statusCard.topAnchor constant:11.0],
        [self.statusTitleLabel.leadingAnchor constraintEqualToAnchor:self.statusCard.leadingAnchor constant:14.0],
        [self.statusTitleLabel.trailingAnchor constraintEqualToAnchor:self.statusCard.trailingAnchor constant:-14.0],

        [self.statusBodyLabel.topAnchor constraintEqualToAnchor:self.statusTitleLabel.bottomAnchor constant:4.0],
        [self.statusBodyLabel.leadingAnchor constraintEqualToAnchor:self.statusCard.leadingAnchor constant:14.0],
        [self.statusBodyLabel.trailingAnchor constraintEqualToAnchor:self.statusCard.trailingAnchor constant:-14.0],
        [self.statusBodyLabel.bottomAnchor constraintEqualToAnchor:self.statusCard.bottomAnchor constant:-11.0],

        [btnRow.topAnchor constraintEqualToAnchor:self.statusCard.bottomAnchor constant:10.0],
        [btnRow.leadingAnchor constraintEqualToAnchor:headerWrap.leadingAnchor constant:16.0],
        [btnRow.trailingAnchor constraintEqualToAnchor:headerWrap.trailingAnchor constant:-16.0],
        [btnRow.heightAnchor constraintEqualToConstant:44.0],
        [btnRow.bottomAnchor constraintEqualToAnchor:headerWrap.bottomAnchor constant:-8.0],

        [self.tableView.topAnchor constraintEqualToAnchor:headerWrap.bottomAnchor],
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.tableView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],

        [self.emptyListLabel.centerYAnchor constraintEqualToAnchor:self.tableView.centerYAnchor constant:-20.0],
        [self.emptyListLabel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:28.0],
        [self.emptyListLabel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-28.0],

        [self.importSelectedButton.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:20.0],
        [self.importSelectedButton.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-20.0],
        [self.importSelectedButton.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-14.0],
        [self.importSelectedButton.heightAnchor constraintEqualToConstant:48.0],
    ]];

    [self scanOriginalAppContainer];
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    if (self.isBeingDismissed || self.navigationController.isBeingDismissed) {
        gAMImportModalOpen = NO;
    }
}

- (UIButton *)makeActionPill:(NSString *)title symbol:(NSString *)sym action:(SEL)sel {
    UIColor *navy = [UIColor colorWithRed:0.114 green:0.118 blue:0.173 alpha:1.0];
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.backgroundColor = [UIColor whiteColor];
    b.tintColor = navy;
    [b setTitleColor:navy forState:UIControlStateNormal];
    b.titleLabel.font = AMThemeFont(11.5, UIFontWeightSemibold);
    b.titleLabel.adjustsFontSizeToFitWidth = YES;
    b.titleLabel.minimumScaleFactor = 0.8;
    b.layer.cornerRadius = 12.0;
    b.layer.borderWidth = 1.0;
    b.layer.borderColor = [UIColor colorWithRed:0.114 green:0.118 blue:0.173 alpha:0.08].CGColor;
    [b setTitle:[@" " stringByAppendingString:title] forState:UIControlStateNormal];
    if (@available(iOS 13.0, *)) {
        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:12.5 weight:UIImageSymbolWeightSemibold];
        [b setImage:[UIImage systemImageNamed:sym withConfiguration:cfg] forState:UIControlStateNormal];
    }
    [b addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (void)scanOriginalAppContainer {
    NSString *container = nil;
    BOOL sandboxBlocked = NO;
    NSArray<NSDictionary *> *projs = AMFindOriginalAlightMotionProjects(&container, &sandboxBlocked);
    self.candidateProjects = projs;
    [self.selectedIndices removeAllObjects];

    if (projs.count > 0) {
        for (NSUInteger i = 0; i < projs.count; i++) {
            [self.selectedIndices addObject:@(i)];
        }
        self.statusTitleLabel.text = [NSString stringWithFormat:@"Original Alight Motion Found (%lu projects)", (unsigned long)projs.count];
        self.statusTitleLabel.textColor = [UIColor colorWithRed:0.07 green:0.55 blue:0.38 alpha:1.0];
        self.statusBodyLabel.text = @"Select the projects you want below and tap Import Selected to copy them into this IPA.";
    } else if (sandboxBlocked) {
        self.statusTitleLabel.text = @"iOS Sandbox Active (Standard Sideload)";
        self.statusTitleLabel.textColor = [UIColor colorWithRed:0.114 green:0.118 blue:0.173 alpha:1.0];
        self.statusBodyLabel.text = @"iOS blocks reading the App Store Alight Motion container directly. Export your projects as XML / Project Package (.amproj) or copy Alight Links, then batch-import below.";
    } else {
        self.statusTitleLabel.text = @"Original Alight Motion Not Found";
        self.statusTitleLabel.textColor = [UIColor colorWithRed:0.114 green:0.118 blue:0.173 alpha:1.0];
        self.statusBodyLabel.text = @"No projects were found in another Alight Motion container. Use Files, Pick Folder, or Alight Links below.";
    }

    [self updateSelectionUI];
    [self.tableView reloadData];
}

- (void)updateSelectionUI {
    BOOL hasList = self.candidateProjects.count > 0;
    self.emptyListLabel.hidden = hasList;
    self.importSelectedButton.hidden = !hasList;
    self.navigationItem.rightBarButtonItem.enabled = hasList;

    NSUInteger selCount = self.selectedIndices.count;
    if (hasList && selCount == self.candidateProjects.count) {
        self.navigationItem.rightBarButtonItem.title = @"Clear";
    } else {
        self.navigationItem.rightBarButtonItem.title = @"Select All";
    }

    [self.importSelectedButton setTitle:[NSString stringWithFormat:@"Import Selected (%lu)", (unsigned long)selCount]
                               forState:UIControlStateNormal];
    self.importSelectedButton.enabled = (selCount > 0);
    self.importSelectedButton.alpha = (selCount > 0) ? 1.0 : 0.45;
}

- (void)onClose {
    gAMImportModalOpen = NO;
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)onToggleSelectAll {
    if (self.candidateProjects.count == 0) return;
    if (self.selectedIndices.count == self.candidateProjects.count) {
        [self.selectedIndices removeAllObjects];
    } else {
        for (NSUInteger i = 0; i < self.candidateProjects.count; i++) {
            [self.selectedIndices addObject:@(i)];
        }
    }
    [self updateSelectionUI];
    [self.tableView reloadData];
}

- (void)onTapPickFiles {
    self.pickingFolderMode = NO;
    UIDocumentPickerViewController *picker = nil;
    if (@available(iOS 14.0, *)) {
        NSArray<UTType *> *types = @[UTTypeXML, UTTypeZIP, UTTypeItem, UTTypeData];
        picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:types asCopy:NO];
    } else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        picker = [[UIDocumentPickerViewController alloc] initWithDocumentTypes:@[@"public.xml", @"public.zip-archive", @"public.item"]
                                                                        inMode:UIDocumentPickerModeImport];
#pragma clang diagnostic pop
    }
    picker.allowsMultipleSelection = YES;
    picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)onTapPickFolder {
    self.pickingFolderMode = YES;
    UIDocumentPickerViewController *picker = nil;
    if (@available(iOS 14.0, *)) {
        picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeFolder] asCopy:NO];
    } else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        picker = [[UIDocumentPickerViewController alloc] initWithDocumentTypes:@[@"public.folder"]
                                                                        inMode:UIDocumentPickerModeOpen];
#pragma clang diagnostic pop
    }
    picker.allowsMultipleSelection = NO;
    picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)onTapBatchLinks {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Batch Import Alight Links"
                                                                message:@"Paste one or more alight.link / alightcreative.com/am/share URLs separated by spaces or commas."
                                                         preferredStyle:UIAlertControllerStyleAlert];
    NSString *clip = [UIPasteboard generalPasteboard].string ?: @"";
    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"https://alight.link/...";
        tf.keyboardType = UIKeyboardTypeURL;
        tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
        tf.autocorrectionType = UITextAutocorrectionTypeNo;
        if ([clip localizedCaseInsensitiveContainsString:@"alight.link"] ||
            [clip localizedCaseInsensitiveContainsString:@"alightcreative.com/am/share"]) {
            tf.text = clip;
        }
    }];
    __weak AMOriginalProjectsImporterVC *weakSelf = self;
    [ac addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [ac addAction:[UIAlertAction actionWithTitle:@"Import" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        (void)a;
        NSString *raw = ac.textFields.firstObject.text ?: @"";
        NSCharacterSet *seps = [NSCharacterSet characterSetWithCharactersInString:@",\n\r \t"];
        NSArray<NSString *> *tokens = [raw componentsSeparatedByCharactersInSet:seps];
        NSMutableArray<NSURL *> *urls = [NSMutableArray array];
        for (NSString *tok in tokens) {
            NSString *t = [tok stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (t.length < 8) continue;
            if ([t localizedCaseInsensitiveContainsString:@"alight.link"] ||
                [t localizedCaseInsensitiveContainsString:@"alightcreative.com"]) {
                NSURL *u = AMNormalizeAlightLink(t);
                if (u) [urls addObject:u];
            }
        }
        if (urls.count == 0) {
            [weakSelf showMessage:@"No valid Alight Motion links found." title:@"Import Links"];
            return;
        }
        gAMImportModalOpen = NO;
        [weakSelf dismissViewControllerAnimated:YES completion:^{
            for (NSUInteger i = 0; i < urls.count; i++) {
                NSURL *u = urls[i];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * 2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    UIViewController *top = AMTopMostViewController();
                    if (top) {
                        AMHandleUserLinkFromVC(top, u, YES);
                    } else {
                        AMDispatchAlightLink(u);
                    }
                });
            }
        }];
    }]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    (void)controller;
    if (urls.count == 0) return;

    if (self.pickingFolderMode) {
        NSURL *folderURL = urls.firstObject;
        if (self.activeScopedFolderURL) {
            [self.activeScopedFolderURL stopAccessingSecurityScopedResource];
            self.activeScopedFolderURL = nil;
        }
        BOOL scoped = [folderURL startAccessingSecurityScopedResource];
        if (scoped) self.activeScopedFolderURL = folderURL;

        NSArray<NSDictionary *> *found = AMScanProjectsInDirectory(folderURL.path, nil);
        self.candidateProjects = found;
        [self.selectedIndices removeAllObjects];
        for (NSUInteger i = 0; i < found.count; i++) {
            [self.selectedIndices addObject:@(i)];
        }
        self.statusTitleLabel.text = [NSString stringWithFormat:@"Folder: %@ (%lu found)",
                                      folderURL.lastPathComponent ?: @"Selected", (unsigned long)found.count];
        self.statusTitleLabel.textColor = found.count > 0
            ? [UIColor colorWithRed:0.07 green:0.55 blue:0.38 alpha:1.0]
            : [UIColor colorWithRed:0.114 green:0.118 blue:0.173 alpha:1.0];
        self.statusBodyLabel.text = found.count > 0
            ? @"Select the projects you want and tap Import Selected below."
            : @"No .xml or .amproj project files found in that folder.";
        [self updateSelectionUI];
        [self.tableView reloadData];
        return;
    }

    // Multi-file direct import
    NSInteger xmlImported = 0;
    NSMutableArray<NSURL *> *amprojURLs = [NSMutableArray array];
    NSInteger skipped = 0;

    for (NSURL *u in urls) {
        BOOL scoped = [u startAccessingSecurityScopedResource];
        NSString *ext = u.pathExtension.lowercaseString ?: @"";
        if ([ext isEqualToString:@"amproj"] || [ext isEqualToString:@"zip"]) {
            [amprojURLs addObject:u];
        } else {
            if (AMImportXMLProjectFileToLibrary(u.path, nil, nil, nil) != nil) {
                xmlImported++;
            } else {
                skipped++;
            }
        }
        if (scoped) [u stopAccessingSecurityScopedResource];
    }

    if (xmlImported > 0 && self.onProjectsImported) {
        self.onProjectsImported(xmlImported);
    }

    if (amprojURLs.count > 0) {
        gAMImportModalOpen = NO;
        [self dismissViewControllerAnimated:YES completion:^{
            AMQueueSequentialAmprojImports(amprojURLs);
        }];
        return;
    }

    NSString *msg = [NSString stringWithFormat:@"Imported %ld XML project(s) into this IPA.%@\n\nSwitch tabs or reopen the app if the native project grid does not refresh immediately.",
                     (long)xmlImported,
                     skipped > 0 ? [NSString stringWithFormat:@" (%ld file(s) skipped)", (long)skipped] : @""];
    [self showMessage:msg title:xmlImported > 0 ? @"Import Complete" : @"Nothing Imported"];
}

- (void)onTapImportSelected {
    if (self.selectedIndices.count == 0) return;

    NSInteger xmlImported = 0;
    NSInteger failed = 0;
    NSMutableArray<NSURL *> *amprojURLs = [NSMutableArray array];

    NSArray<NSNumber *> *sortedIdx = [[self.selectedIndices allObjects] sortedArrayUsingSelector:@selector(compare:)];
    for (NSNumber *n in sortedIdx) {
        NSUInteger i = n.unsignedIntegerValue;
        if (i >= self.candidateProjects.count) continue;
        NSDictionary *proj = self.candidateProjects[i];
        NSString *path = proj[@"path"];
        if (path.length == 0) continue;

        if ([proj[@"isAmproj"] boolValue]) {
            [amprojURLs addObject:[NSURL fileURLWithPath:path]];
        } else {
            NSString *cRoot = [proj[@"containerRoot"] length] > 0 ? proj[@"containerRoot"] : nil;
            NSString *thumb = [proj[@"thumb"] length] > 0 ? proj[@"thumb"] : nil;
            if (AMImportXMLProjectFileToLibrary(path, cRoot, thumb, nil) != nil) {
                xmlImported++;
            } else {
                failed++;
            }
        }
    }

    if (xmlImported > 0 && self.onProjectsImported) {
        self.onProjectsImported(xmlImported);
    }

    if (amprojURLs.count > 0) {
        gAMImportModalOpen = NO;
        [self dismissViewControllerAnimated:YES completion:^{
            AMQueueSequentialAmprojImports(amprojURLs);
        }];
        return;
    }

    NSString *msg = [NSString stringWithFormat:@"Imported %ld project(s) into this IPA.%@\n\nOpen them right away from Search/Folders, or switch tabs / reopen the app to refresh the native grid.",
                     (long)xmlImported,
                     failed > 0 ? [NSString stringWithFormat:@" (%ld failed)", (long)failed] : @""];
    __weak AMOriginalProjectsImporterVC *weakSelf = self;
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:xmlImported > 0 ? @"Import Complete" : @"Import Failed"
                                                                message:msg
                                                         preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"Done" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        (void)a;
        if (xmlImported > 0) [weakSelf onClose];
    }]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)showMessage:(NSString *)msg title:(NSString *)title {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:title
                                                                message:msg
                                                         preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView; (void)section;
    return self.candidateProjects.count;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView; (void)indexPath;
    return 76.0;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"AMOrigImportCell"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"AMOrigImportCell"];
        cell.backgroundColor = [UIColor clearColor];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;

        UIView *card = [[UIView alloc] init];
        card.tag = 301;
        card.translatesAutoresizingMaskIntoConstraints = NO;
        card.backgroundColor = [UIColor whiteColor];
        card.layer.cornerRadius = 14.0;
        card.layer.borderWidth = 1.0;
        card.layer.borderColor = [UIColor colorWithRed:0.114 green:0.118 blue:0.173 alpha:0.07].CGColor;
        [cell.contentView addSubview:card];

        UIImageView *thumb = [[UIImageView alloc] init];
        thumb.tag = 302;
        thumb.translatesAutoresizingMaskIntoConstraints = NO;
        thumb.backgroundColor = [UIColor colorWithRed:0.933 green:0.941 blue:0.969 alpha:1.0];
        thumb.layer.cornerRadius = 9.0;
        thumb.clipsToBounds = YES;
        [card addSubview:thumb];

        UILabel *titleLbl = [[UILabel alloc] init];
        titleLbl.tag = 303;
        titleLbl.translatesAutoresizingMaskIntoConstraints = NO;
        titleLbl.font = AMThemeFont(14.5, UIFontWeightBold);
        titleLbl.textColor = [UIColor colorWithRed:0.114 green:0.118 blue:0.173 alpha:1.0];
        [card addSubview:titleLbl];

        UILabel *metaLbl = [[UILabel alloc] init];
        metaLbl.tag = 304;
        metaLbl.translatesAutoresizingMaskIntoConstraints = NO;
        metaLbl.font = AMThemeFont(11.5, UIFontWeightRegular);
        metaLbl.textColor = [UIColor colorWithRed:0.45 green:0.47 blue:0.55 alpha:1.0];
        [card addSubview:metaLbl];

        UIImageView *checkIV = [[UIImageView alloc] init];
        checkIV.tag = 305;
        checkIV.translatesAutoresizingMaskIntoConstraints = NO;
        checkIV.contentMode = UIViewContentModeScaleAspectFit;
        [card addSubview:checkIV];

        [NSLayoutConstraint activateConstraints:@[
            [card.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:4.0],
            [card.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-4.0],
            [card.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:16.0],
            [card.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-16.0],

            [thumb.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:10.0],
            [thumb.centerYAnchor constraintEqualToAnchor:card.centerYAnchor],
            [thumb.widthAnchor constraintEqualToConstant:48.0],
            [thumb.heightAnchor constraintEqualToConstant:48.0],

            [titleLbl.leadingAnchor constraintEqualToAnchor:thumb.trailingAnchor constant:12.0],
            [titleLbl.trailingAnchor constraintEqualToAnchor:checkIV.leadingAnchor constant:-10.0],
            [titleLbl.topAnchor constraintEqualToAnchor:card.topAnchor constant:14.0],

            [metaLbl.leadingAnchor constraintEqualToAnchor:titleLbl.leadingAnchor],
            [metaLbl.trailingAnchor constraintEqualToAnchor:titleLbl.trailingAnchor],
            [metaLbl.topAnchor constraintEqualToAnchor:titleLbl.bottomAnchor constant:3.0],

            [checkIV.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-14.0],
            [checkIV.centerYAnchor constraintEqualToAnchor:card.centerYAnchor],
            [checkIV.widthAnchor constraintEqualToConstant:24.0],
            [checkIV.heightAnchor constraintEqualToConstant:24.0],
        ]];
    }

    NSDictionary *p = self.candidateProjects[indexPath.row];
    UIImageView *thumb = [cell.contentView viewWithTag:302];
    UILabel *titleLbl = [cell.contentView viewWithTag:303];
    UILabel *metaLbl = [cell.contentView viewWithTag:304];
    UIImageView *checkIV = [cell.contentView viewWithTag:305];

    titleLbl.text = p[@"title"] ?: @"Untitled";
    metaLbl.text = p[@"meta"] ?: @"";

    NSString *tp = p[@"thumb"];
    UIImage *img = nil;
    if (tp.length > 0) {
        img = [self.thumbCache objectForKey:tp];
        if (!img) {
            img = [UIImage imageWithContentsOfFile:tp];
            if (img) [self.thumbCache setObject:img forKey:tp];
        }
    }
    if (img) {
        thumb.contentMode = UIViewContentModeScaleAspectFill;
        thumb.image = img;
    } else {
        thumb.contentMode = UIViewContentModeCenter;
        if (@available(iOS 13.0, *)) {
            thumb.image = [UIImage systemImageNamed:[p[@"isAmproj"] boolValue] ? @"shippingbox" : @"film.stack"];
            thumb.tintColor = [UIColor colorWithRed:0.114 green:0.118 blue:0.173 alpha:0.65];
        }
    }

    BOOL sel = [self.selectedIndices containsObject:@(indexPath.row)];
    if (@available(iOS 13.0, *)) {
        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:20.0 weight:UIImageSymbolWeightSemibold];
        checkIV.image = [UIImage systemImageNamed:(sel ? @"checkmark.circle.fill" : @"circle") withConfiguration:cfg];
        checkIV.tintColor = sel ? AMAccentGreenColor() : [UIColor colorWithRed:0.75 green:0.77 blue:0.83 alpha:1.0];
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    NSNumber *key = @(indexPath.row);
    if ([self.selectedIndices containsObject:key]) {
        [self.selectedIndices removeObject:key];
    } else {
        [self.selectedIndices addObject:key];
    }
    [self updateSelectionUI];
    [tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
}

@end

// ============================================================================
// Unified Homepage Overlay Manager (Search, Import, + Folder, Inline Folders, Assign)
// ============================================================================

@interface AMHomepageSearchOverlayManager : NSObject
@property (nonatomic, strong, nullable) UIButton *searchButton;
@property (nonatomic, strong, nullable) UIButton *importProjectsButton;
@property (nonatomic, strong, nullable) UIButton *foldersButton;
@property (nonatomic, strong, nullable) UIButton *assignFolderButton;
@property (nonatomic, strong, nullable) AMHomepageFoldersInlineView *inlineFoldersView;
@property (nonatomic, strong, nullable) NSTimer *pollTimer;
@property (nonatomic, strong) NSMutableSet<NSString *> *trackedSelectedTitles;
@property (nonatomic, copy) NSArray<NSDictionary *> *cachedDiskProjects;
@property (nonatomic, copy) NSSet<NSString *> *cachedProjectTitles;
@property (nonatomic, assign) NSTimeInterval lastDiskRefresh;
+ (instancetype)shared;
- (void)start;
- (void)tick;
- (void)scheduleImmediateTick;
@end

@implementation AMHomepageSearchOverlayManager

+ (instancetype)shared {
    static AMHomepageSearchOverlayManager *inst = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        inst = [[AMHomepageSearchOverlayManager alloc] init];
        inst.trackedSelectedTitles = [NSMutableSet set];
    });
    return inst;
}

- (void)start {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.pollTimer) return;
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(onAppDidBecomeActive)
                                                     name:UIApplicationDidBecomeActiveNotification
                                                   object:nil];
        [self onAppDidBecomeActive];
        self.pollTimer = [NSTimer scheduledTimerWithTimeInterval:0.15
                                                          target:self
                                                        selector:@selector(tick)
                                                        userInfo:nil
                                                         repeats:YES];
    });
}

- (void)scheduleImmediateTick {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self tick];
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self tick];
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self tick];
    });
}

- (void)onAppDidBecomeActive {
    NSInteger imported = AMImportInboxProjectsIfAny();
    if (imported > 0) {
        [self refreshProjectCacheIfNeeded:YES];
        [self.inlineFoldersView reloadForce:YES diskProjects:self.cachedDiskProjects ?: @[]];
    }
}

- (void)refreshProjectCacheIfNeeded:(BOOL)force {
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (!force && self.cachedDiskProjects && (now - self.lastDiskRefresh) < 4.0) return;
    self.lastDiskRefresh = now;
    self.cachedDiskProjects = AMLoadUserProjectsFromDisk();
    NSMutableSet<NSString *> *titles = [NSMutableSet set];
    for (NSDictionary *p in self.cachedDiskProjects) {
        NSString *t = p[@"title"];
        if (t.length > 0) [titles addObject:t];
    }
    self.cachedProjectTitles = titles;
}

- (void)ensureButtonsInHostView:(UIView *)hostView {
    if (!self.searchButton) {
        UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
        btn.accessibilityLabel = @"Search Projects";
        btn.backgroundColor = [UIColor colorWithRed:0.114 green:0.118 blue:0.173 alpha:0.08]; // subtle gray matching header
        btn.tintColor = [UIColor colorWithRed:0.114 green:0.118 blue:0.173 alpha:1.0]; // #1D1E2C
        btn.layer.cornerRadius = 17.0;
        btn.layer.borderWidth = 0.5;
        btn.layer.borderColor = [UIColor colorWithRed:0.114 green:0.118 blue:0.173 alpha:0.08].CGColor;
        if (@available(iOS 13.0, *)) {
            UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:15.0 weight:UIImageSymbolWeightSemibold];
            [btn setImage:[UIImage systemImageNamed:@"magnifyingglass" withConfiguration:cfg] forState:UIControlStateNormal];
        } else {
            [btn setTitle:@"Q" forState:UIControlStateNormal];
        }
        [btn addTarget:self action:@selector(onTapSearch) forControlEvents:UIControlEventTouchUpInside];
        self.searchButton = btn;
    }

    if (!self.importProjectsButton) {
        UIButton *ibtn = [UIButton buttonWithType:UIButtonTypeSystem];
        ibtn.accessibilityLabel = @"Import Projects";
        ibtn.backgroundColor = [UIColor colorWithRed:0.114 green:0.118 blue:0.173 alpha:0.08];
        ibtn.tintColor = [UIColor colorWithRed:0.114 green:0.118 blue:0.173 alpha:1.0];
        ibtn.layer.cornerRadius = 17.0;
        ibtn.layer.borderWidth = 0.5;
        ibtn.layer.borderColor = [UIColor colorWithRed:0.114 green:0.118 blue:0.173 alpha:0.08].CGColor;
        if (@available(iOS 13.0, *)) {
            UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:14.5 weight:UIImageSymbolWeightSemibold];
            [ibtn setImage:[UIImage systemImageNamed:@"square.and.arrow.down" withConfiguration:cfg] forState:UIControlStateNormal];
        } else {
            [ibtn setTitle:@"+" forState:UIControlStateNormal];
        }
        [ibtn addTarget:self action:@selector(onTapImportProjects) forControlEvents:UIControlEventTouchUpInside];
        self.importProjectsButton = ibtn;
    }

    if (!self.foldersButton) {
        UIButton *fbtn = [UIButton buttonWithType:UIButtonTypeSystem];
        fbtn.accessibilityLabel = @"Create Folder";
        fbtn.backgroundColor = [UIColor whiteColor];
        fbtn.tintColor = [UIColor colorWithRed:0.114 green:0.118 blue:0.173 alpha:1.0];
        [fbtn setTitleColor:[UIColor colorWithRed:0.114 green:0.118 blue:0.173 alpha:1.0] forState:UIControlStateNormal];
        fbtn.titleLabel.font = AMThemeFont(13.0, UIFontWeightSemibold);
        fbtn.layer.cornerRadius = 15.0;
        fbtn.layer.borderWidth = 1.0;
        fbtn.layer.borderColor = [UIColor colorWithRed:0.114 green:0.118 blue:0.173 alpha:0.08].CGColor;
        fbtn.layer.shadowColor = [UIColor blackColor].CGColor;
        fbtn.layer.shadowOpacity = 0.05;
        fbtn.layer.shadowRadius = 6.0;
        fbtn.layer.shadowOffset = CGSizeMake(0, 2);
        [fbtn setTitle:@" + Folder" forState:UIControlStateNormal];
        if (@available(iOS 13.0, *)) {
            UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:13.0 weight:UIImageSymbolWeightSemibold];
            [fbtn setImage:[UIImage systemImageNamed:@"folder.badge.plus" withConfiguration:cfg] forState:UIControlStateNormal];
        }
        [fbtn addTarget:self action:@selector(onTapCreateFolder) forControlEvents:UIControlEventTouchUpInside];
        self.foldersButton = fbtn;
    }

    if (!self.assignFolderButton) {
        UIButton *abtn = [UIButton buttonWithType:UIButtonTypeSystem];
        abtn.accessibilityLabel = @"Assign Folder";
        abtn.backgroundColor = [UIColor colorWithRed:0.114 green:0.118 blue:0.173 alpha:1.0]; // #1D1E2C
        abtn.tintColor = [UIColor whiteColor];
        [abtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        abtn.titleLabel.font = AMThemeFont(14.0, UIFontWeightSemibold);
        abtn.layer.cornerRadius = 21.0;
        abtn.layer.borderWidth = 1.0;
        abtn.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.16].CGColor;
        abtn.layer.shadowColor = [UIColor blackColor].CGColor;
        abtn.layer.shadowOpacity = 0.22;
        abtn.layer.shadowRadius = 10.0;
        abtn.layer.shadowOffset = CGSizeMake(0, 4);
        [abtn setTitle:@" Assign Folder" forState:UIControlStateNormal];
        if (@available(iOS 13.0, *)) {
            UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:14.0 weight:UIImageSymbolWeightSemibold];
            [abtn setImage:[UIImage systemImageNamed:@"folder.badge.plus" withConfiguration:cfg] forState:UIControlStateNormal];
        }
        [abtn addTarget:self action:@selector(onTapAssignFolder) forControlEvents:UIControlEventTouchUpInside];
        self.assignFolderButton = abtn;
    }

    if (!self.inlineFoldersView) {
        self.inlineFoldersView = [[AMHomepageFoldersInlineView alloc] initWithFrame:CGRectZero];
    }

    for (UIView *v in @[self.inlineFoldersView, self.importProjectsButton, self.searchButton, self.foldersButton, self.assignFolderButton]) {
        if (v.superview != hostView) [hostView addSubview:v];
        [hostView bringSubviewToFront:v];
    }
}

- (void)tick {
    UIWindow *win = AMKeyWindow();
    if (!win) return;
    if (!AMIsOnHomepage(win)) {
        self.searchButton.hidden = YES;
        self.importProjectsButton.hidden = YES;
        self.foldersButton.hidden = YES;
        self.assignFolderButton.hidden = YES;
        self.inlineFoldersView.hidden = YES;
        return;
    }

    UIViewController *mainVC = AMFindMainVCInHierarchy(win.rootViewController, 0);
    UIView *hostView = (mainVC && mainVC.isViewLoaded && mainVC.view.window == win) ? mainVC.view : win;

    // When a native modal sheet (e.g. Create Project) covers the homepage, leave our HUD
    // subviews attached inside mainVC.view untouched so they stay naturally behind the sheet
    // and dim with the backdrop instead of disappearing.
    if (AMHomepageModalCovering(win, mainVC)) {
        return;
    }

    [self refreshProjectCacheIfNeeded:NO];
    [self ensureButtonsInHostView:hostView];

    AMHomepageProbeInfo probe = AMProbeHomepageAndTrackSelection(win,
                                                                 self.cachedProjectTitles ?: [NSSet set],
                                                                 self.trackedSelectedTitles);

    if (probe.isModalSheetOpen) {
        return;
    }

    if (probe.isSelectionMode) {
        self.searchButton.hidden = YES;
        self.importProjectsButton.hidden = YES;
        self.foldersButton.hidden = YES;
        self.inlineFoldersView.hidden = YES;

        CGFloat w = 164.0;
        CGFloat h = 42.0;
        CGFloat x = (win.bounds.size.width - w) * 0.5;
        CGFloat barTopY = !CGRectIsEmpty(probe.bottomBarFrame)
            ? (CGRectGetMinY(probe.bottomBarFrame) - 14.0)
            : (win.bounds.size.height - win.safeAreaInsets.bottom - 72.0);
        CGFloat y = barTopY - h - 10.0;
        self.assignFolderButton.frame = [hostView convertRect:CGRectMake(x, y, w, h) fromView:win];
        self.assignFolderButton.hidden = NO;
        return;
    }

    self.assignFolderButton.hidden = YES;

    CGFloat size = 34.0;
    CGFloat sx = win.bounds.size.width - 16.0 - 36.0 - 10.0 - size;
    CGFloat sy = win.safeAreaInsets.top + 8.0;
    self.searchButton.frame = [hostView convertRect:CGRectMake(sx, sy, size, size) fromView:win];
    self.searchButton.hidden = NO;

    CGFloat ix = sx - 8.0 - size;
    self.importProjectsButton.frame = [hostView convertRect:CGRectMake(ix, sy, size, size) fromView:win];
    self.importProjectsButton.hidden = NO;

    if (probe.hasYourProjects) {
        CGFloat midY = CGRectGetMidY(probe.yourProjectsFrame);
        CGFloat midX = CGRectGetMidX(probe.yourProjectsFrame);
        CGFloat minVisY = win.safeAreaInsets.top + 58.0;
        CGFloat maxVisY = win.bounds.size.height - win.safeAreaInsets.bottom - 75.0;
        if (midY > minVisY && midY < maxVisY && midX > 0.0 && midX < win.bounds.size.width) {
            CGFloat fw = 102.0;
            CGFloat fh = 30.0;
            CGFloat fx = win.bounds.size.width - 16.0 - fw;
            CGFloat fy = midY - (fh * 0.5);
            self.foldersButton.frame = [hostView convertRect:CGRectMake(fx, fy, fw, fh) fromView:win];
            self.foldersButton.hidden = NO;

            [self.inlineFoldersView reloadForce:NO diskProjects:self.cachedDiskProjects ?: @[]];
            CGFloat topY = CGRectGetMaxY(probe.yourProjectsFrame) + 6.0;
            CGFloat maxH = MAX(0.0, (win.bounds.size.height - win.safeAreaInsets.bottom - 78.0) - topY);
            CGFloat h = [self.inlineFoldersView desiredHeightWithMaxHeight:maxH];
            if (h > 10.0) {
                self.inlineFoldersView.frame = [hostView convertRect:CGRectMake(0.0, topY, win.bounds.size.width, h) fromView:win];
                self.inlineFoldersView.hidden = NO;
            } else {
                self.inlineFoldersView.hidden = YES;
            }
        } else {
            self.foldersButton.hidden = YES;
            self.inlineFoldersView.hidden = YES;
        }
    } else {
        self.foldersButton.hidden = YES;
        self.inlineFoldersView.hidden = YES;
    }
}

- (void)onTapSearch {
    [self refreshProjectCacheIfNeeded:YES];
    UIViewController *top = AMTopMostViewController();
    if (!top) return;
    gAMSearchModalOpen = YES;
    AMProjectSearchVC *vc = [[AMProjectSearchVC alloc] init];
    vc.allProjects = self.cachedDiskProjects ?: @[];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    if (@available(iOS 13.0, *)) {
        nav.overrideUserInterfaceStyle = UIUserInterfaceStyleLight;
    }
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    [top presentViewController:nav animated:YES completion:nil];
}

- (void)onTapImportProjects {
    UIViewController *top = AMTopMostViewController();
    if (!top) return;
    gAMImportModalOpen = YES;
    AMOriginalProjectsImporterVC *vc = [[AMOriginalProjectsImporterVC alloc] init];
    __weak AMHomepageSearchOverlayManager *weakSelf = self;
    vc.onProjectsImported = ^(NSInteger count) {
        (void)count;
        [weakSelf refreshProjectCacheIfNeeded:YES];
        [weakSelf.inlineFoldersView reloadForce:YES diskProjects:weakSelf.cachedDiskProjects ?: @[]];
    };
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    if (@available(iOS 13.0, *)) {
        nav.overrideUserInterfaceStyle = UIUserInterfaceStyleLight;
    }
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    [top presentViewController:nav animated:YES completion:nil];
}

- (void)onTapCreateFolder {
    UIViewController *top = AMTopMostViewController();
    if (!top) return;
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"New Folder"
                                                                message:@"Create a folder to group your projects right under Your projects."
                                                         preferredStyle:UIAlertControllerStyleAlert];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"Folder name (e.g. Edits, Shakes)";
        tf.autocapitalizationType = UITextAutocapitalizationTypeWords;
    }];
    __weak AMHomepageSearchOverlayManager *weakSelf = self;
    [ac addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [ac addAction:[UIAlertAction actionWithTitle:@"Create" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        (void)action;
        NSString *name = ac.textFields.firstObject.text ?: @"";
        if (AMCreateProjectFolder(name, nil)) {
            weakSelf.inlineFoldersView.isDropdownExpanded = YES;
            [weakSelf.inlineFoldersView reloadForce:YES diskProjects:weakSelf.cachedDiskProjects ?: @[]];
            [weakSelf tick];
        }
    }]];
    [top presentViewController:ac animated:YES completion:nil];
}

- (void)onTapAssignFolder {
    UIWindow *win = AMKeyWindow();
    [self refreshProjectCacheIfNeeded:YES];
    if (win) {
        AMProbeHomepageAndTrackSelection(win,
                                         self.cachedProjectTitles ?: [NSSet set],
                                         self.trackedSelectedTitles);
    }

    NSMutableArray<NSDictionary *> *selectedProjects = [NSMutableArray array];
    for (NSDictionary *proj in (self.cachedDiskProjects ?: @[])) {
        NSString *title = proj[@"title"];
        if (title.length > 0 && [self.trackedSelectedTitles containsObject:title]) {
            [selectedProjects addObject:proj];
        }
    }

    UIViewController *top = AMTopMostViewController();
    if (!top) return;
    gAMFoldersModalOpen = YES;
    AMAssignFolderVC *vc = [[AMAssignFolderVC alloc] init];
    vc.selectedProjects = selectedProjects;
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    if (@available(iOS 13.0, *)) {
        nav.overrideUserInterfaceStyle = UIUserInterfaceStyleLight;
    }
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    [top presentViewController:nav animated:YES completion:nil];
}

@end

// ============================================================================
// Launch Intro Video -> Loading Screen -> Fade Out to Alight Motion
// ============================================================================

@interface AMLaunchIntroManager : NSObject
@property (nonatomic, strong, nullable) UIWindow *overlayWindow;
@property (nonatomic, strong, nullable) AVPlayer *player;
@property (nonatomic, strong, nullable) AVPlayerLayer *playerLayer;
@property (nonatomic, strong, nullable) UIView *loadingView;
@property (nonatomic, assign) BOOL didStart;
@property (nonatomic, assign) BOOL didTransitionToLoading;
@property (nonatomic, assign) BOOL didFadeOut;
@property (nonatomic, assign) NSTimeInterval loadingStartTime;
+ (instancetype)shared;
- (void)startIfNeeded;
@end

@implementation AMLaunchIntroManager

+ (instancetype)shared {
    static AMLaunchIntroManager *inst = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        inst = [[AMLaunchIntroManager alloc] init];
    });
    return inst;
}

- (void)startIfNeeded {
    if (self.didStart) return;
    UIWindow *keyWin = AMKeyWindow();
    if (!keyWin) return;

    NSURL *videoURL = [[NSBundle mainBundle] URLForResource:@"AMIntro" withExtension:@"mp4"];
    if (!videoURL) return;

    self.didStart = YES;
    gAMIntroActive = YES;

    [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryAmbient error:nil];

    UIWindow *win = nil;
    if (@available(iOS 13.0, *)) {
        if (keyWin.windowScene) {
            win = [[UIWindow alloc] initWithWindowScene:keyWin.windowScene];
        }
    }
    if (!win) {
        win = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    }
    win.frame = [UIScreen mainScreen].bounds;
    win.windowLevel = UIWindowLevelAlert + 50.0;
    win.backgroundColor = [UIColor colorWithRed:0.055 green:0.067 blue:0.090 alpha:1.0];
    win.rootViewController = [[UIViewController alloc] init];
    win.rootViewController.view.backgroundColor = win.backgroundColor;
    win.hidden = NO;
    self.overlayWindow = win;

    AVPlayer *player = [AVPlayer playerWithURL:videoURL];
    player.actionAtItemEnd = AVPlayerActionAtItemEndPause;
    self.player = player;

    AVPlayerLayer *layer = [AVPlayerLayer playerLayerWithPlayer:player];
    layer.frame = win.bounds;
    layer.videoGravity = AVLayerVideoGravityResizeAspectFill;
    [win.rootViewController.view.layer addSublayer:layer];
    self.playerLayer = layer;

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(onVideoDidFinish:)
                                                 name:AVPlayerItemDidPlayToEndTimeNotification
                                               object:player.currentItem];

    [player play];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self transitionToLoadingScreen];
    });
}

- (void)onVideoDidFinish:(NSNotification *)note {
    (void)note;
    dispatch_async(dispatch_get_main_queue(), ^{
        [self transitionToLoadingScreen];
    });
}

- (void)transitionToLoadingScreen {
    if (self.didTransitionToLoading) return;
    self.didTransitionToLoading = YES;

    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:AVPlayerItemDidPlayToEndTimeNotification
                                                  object:nil];

    UIWindow *win = self.overlayWindow;
    if (!win) {
        [self fadeOutToAlightMotion];
        return;
    }

    UIView *loading = [[UIView alloc] initWithFrame:win.bounds];
    loading.backgroundColor = [UIColor colorWithRed:0.055 green:0.067 blue:0.090 alpha:1.0];
    loading.alpha = 0.0;

    UIActivityIndicatorView *spinner = nil;
    if (@available(iOS 13.0, *)) {
        spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
    } else {
        spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhiteLarge];
    }
    spinner.color = [UIColor whiteColor];
    spinner.center = CGPointMake(loading.bounds.size.width * 0.5, loading.bounds.size.height * 0.5 - 12.0);
    [spinner startAnimating];
    [loading addSubview:spinner];

    UILabel *lbl = [[UILabel alloc] initWithFrame:CGRectMake(24.0, CGRectGetMaxY(spinner.frame) + 14.0, loading.bounds.size.width - 48.0, 22.0)];
    lbl.text = @"Loading...";
    lbl.textColor = [UIColor colorWithWhite:1.0 alpha:0.75];
    lbl.font = AMThemeFont(14.0, UIFontWeightMedium);
    lbl.textAlignment = NSTextAlignmentCenter;
    [loading addSubview:lbl];

    [win.rootViewController.view addSubview:loading];
    self.loadingView = loading;
    self.loadingStartTime = [NSDate timeIntervalSinceReferenceDate];

    [UIView animateWithDuration:0.25 animations:^{
        loading.alpha = 1.0;
    } completion:^(BOOL finished) {
        (void)finished;
        [self.player pause];
        [self.playerLayer removeFromSuperlayer];
        self.playerLayer = nil;
        self.player = nil;
    }];

    [self checkReadyToFadeOut];
}

- (void)checkReadyToFadeOut {
    if (self.didFadeOut) return;
    NSTimeInterval elapsed = [NSDate timeIntervalSinceReferenceDate] - self.loadingStartTime;
    UIWindow *keyWin = AMKeyWindow();
    UIViewController *mainVC = keyWin ? AMFindMainVCInHierarchy(keyWin.rootViewController, 0) : nil;
    BOOL appReady = (mainVC && mainVC.isViewLoaded && mainVC.view.window == keyWin && !AMVCTreeContainsEditor(keyWin.rootViewController, 0));

    if ((elapsed >= 0.80 && appReady) || elapsed >= 3.5) {
        [self fadeOutToAlightMotion];
        return;
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.10 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self checkReadyToFadeOut];
    });
}

- (void)fadeOutToAlightMotion {
    if (self.didFadeOut) return;
    self.didFadeOut = YES;

    gAMIntroActive = NO;
    [[AMHomepageSearchOverlayManager shared] scheduleImmediateTick];

    UIWindow *win = self.overlayWindow;
    if (!win) return;

    [UIView animateWithDuration:0.45
                          delay:0.0
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{
        win.alpha = 0.0;
    } completion:^(BOOL finished) {
        (void)finished;
        win.hidden = YES;
        self.loadingView = nil;
        self.overlayWindow = nil;
    }];
}

@end

// ============================================================================
// Multi-Layer Parenting (Timeline Multi-Select Toolbar)
// ============================================================================

static const NSInteger kAMMultiParentBtnTag = 0x414D5052; // 'AMPR'
static const void *kAMMultiParentNavKey = &kAMMultiParentNavKey;
static const void *kAMMultiParentFirstIdKey = &kAMMultiParentFirstIdKey;

static IMP gOrigMultiSelectorNavViewDidLoad = NULL;
static IMP gOrigLayerParentingWillDisplayCell = NULL;
static IMP gOrigLayerParentingDidSelectRow = NULL;

@interface AMMultiParentPopoverDelegate : NSObject <UIPopoverPresentationControllerDelegate>
+ (instancetype)shared;
@end

@implementation AMMultiParentPopoverDelegate
+ (instancetype)shared {
    static AMMultiParentPopoverDelegate *inst = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ inst = [AMMultiParentPopoverDelegate new]; });
    return inst;
}
- (UIModalPresentationStyle)adaptivePresentationStyleForPresentationController:(UIPresentationController *)controller {
    return UIModalPresentationNone;
}
@end

typedef struct {
    const uint64_t *selectedIds;
    NSUInteger selectedCount;
    uint64_t targetParentId;
    BOOL hasParent;
    int64_t currentTime;
} AMMultiParentEditContext;

static AMMultiParentEditContext gAMMultiParentCtx;

static void *AMSwiftWeakLoadHolder(id navVC, intptr_t slide) {
    if (!navVC) return NULL;
    Ivar iv = class_getInstanceVariable([navVC class], "holder");
    if (!iv) return NULL;
    ptrdiff_t off = ivar_getOffset(iv);
    void *weakSlot = (uint8_t *)(__bridge void *)navVC + off;
    typedef void *(*WeakLoadStrongFn)(void *);
    return ((WeakLoadStrongFn)(0x1025bba7cULL + slide))(weakSlot);
}

static void AMSwiftRetain(void *obj, intptr_t slide) {
    if (!obj) return;
    typedef void *(*RetainFn)(void *);
    ((RetainFn)(0x1025bb824ULL + slide))(obj);
}

static void AMSwiftRelease(void *obj, intptr_t slide) {
    if (!obj) return;
    typedef void (*ReleaseFn)(void *);
    ((ReleaseFn)(0x1025bb80cULL + slide))(obj);
}

static BOOL AMReadHolderSelectedIds(void *holder, intptr_t slide, uint64_t **outIds, NSUInteger *outCount) {
    if (outIds) *outIds = NULL;
    if (outCount) *outCount = 0;
    if (!holder || !outIds || !outCount) return NO;

    ptrdiff_t selOff = *(ptrdiff_t *)(0x103332390ULL + slide);
    const uint8_t *selSlot = (const uint8_t *)holder + selOff;
    uint64_t rawVal = *(const uint64_t *)selSlot;
    uint8_t tag = selSlot[8];
    uint8_t kind = tag >> 6;

    if (kind == 0) {
        // Single selection: rawVal is the ElementId
        uint64_t *buf = (uint64_t *)malloc(sizeof(uint64_t));
        if (!buf) return NO;
        buf[0] = rawVal;
        *outIds = buf;
        *outCount = 1;
        return YES;
    } else if (kind == 1 && rawVal != 0) {
        // Multi selection: rawVal is Swift._ContiguousArrayStorage<ElementId> *
        const uint8_t *arr = (const uint8_t *)rawVal;
        int64_t cnt = *(const int64_t *)(arr + 0x10);
        if (cnt <= 0 || cnt > 100000) return NO;
        uint64_t *buf = (uint64_t *)malloc((size_t)cnt * sizeof(uint64_t));
        if (!buf) return NO;
        memcpy(buf, arr + 0x20, (size_t)cnt * sizeof(uint64_t));
        *outIds = buf;
        *outCount = (NSUInteger)cnt;
        return YES;
    }
    return NO;
}

static void *AMSwiftArrayStorageForObj(id obj, const char *ivarName) {
    if (!obj || !ivarName) return NULL;
    Ivar iv = class_getInstanceVariable([obj class], ivarName);
    if (!iv) return NULL;
    ptrdiff_t off = ivar_getOffset(iv);
    return *(void **)((uint8_t *)(__bridge void *)obj + off);
}

static BOOL AMIsIdInList(uint64_t eid, const uint64_t *ids, NSUInteger count) {
    for (NSUInteger i = 0; i < count; i++) {
        if (ids[i] == eid) return YES;
    }
    return NO;
}

static BOOL AMWouldCreateParentCycle(uint64_t childId,
                                     uint64_t candidateParentId,
                                     const uint8_t *basePtr,
                                     int64_t count,
                                     size_t stride,
                                     ptrdiff_t parentIdOff) {
    if (childId == candidateParentId) return YES;
    uint64_t cur = candidateParentId;
    for (int depth = 0; depth < 64; depth++) {
        BOOL found = NO;
        for (int64_t i = 0; i < count; i++) {
            const uint8_t *el = basePtr + (size_t)i * stride;
            uint64_t eid = *(const uint64_t *)(el + 0x18);
            if (eid == cur) {
                uint8_t isNil = *(const uint8_t *)(el + parentIdOff + 8);
                if (isNil & 1) return NO;
                uint64_t nextParent = *(const uint64_t *)(el + parentIdOff);
                if (nextParent == childId) return YES;
                cur = nextParent;
                found = YES;
                break;
            }
        }
        if (!found) break;
    }
    return NO;
}

static void AMMultiParentEditCallback(void *scenePtr) {
    if (!scenePtr || !gAMMultiParentCtx.selectedIds || gAMMultiParentCtx.selectedCount == 0) return;
    intptr_t slide = AMMainBinarySlide();

    typedef void *(*MetaFn)(uintptr_t);
    typedef void *(*CopyFn)(void *, void *, void *);
    typedef void (*DestroyFn)(void *, void *);
    typedef void (*SetParentFn)(void *, uint64_t, uint32_t, int64_t);

    void *sceneMeta = ((MetaFn)(0x1003c6b10ULL + slide))(0);
    void *elMeta = ((MetaFn)(0x1003e0404ULL + slide))(0);
    if (!sceneMeta || !elMeta) return;

    void *sceneVWT = *(void **)((uint8_t *)sceneMeta - 8);
    size_t sceneSize = *(size_t *)((uint8_t *)sceneVWT + 0x40);
    int32_t elementsOff = *(int32_t *)((uint8_t *)sceneMeta + 0x1c);

    void *elVWT = *(void **)((uint8_t *)elMeta - 8);
    uint8_t elAlignMask = *(uint8_t *)((uint8_t *)elVWT + 0x50);
    size_t elStride = *(size_t *)((uint8_t *)elVWT + 0x48);
    int32_t parentIdOff = *(int32_t *)((uint8_t *)elMeta + 0x94);

    void *sceneCopy = calloc(1, sceneSize + 32);
    if (!sceneCopy) return;
    ((CopyFn)(0x100019e78ULL + slide))(scenePtr, sceneCopy, (void *)(0x1003c6b10ULL + slide));

    // Ensure COW uniqueness on scene.elements before mutating elements in-place
    void *makeUnique = dlsym(RTLD_DEFAULT, "$sSa36_makeUniqueAndReserveCapacityIfNotUniqueyyF");
    void **elementsField = (void **)((uint8_t *)scenePtr + elementsOff);
    if (makeUnique && *elementsField) {
        struct { uint64_t selfPtr, metaPtr, fnPtr; } uArgs = {
            (uint64_t)elementsField, (uint64_t)elMeta, (uint64_t)makeUnique
        };
        __asm__ volatile(
            "mov x9, %0\n"
            "ldr x20, [x9, #0]\n"
            "ldr x0,  [x9, #8]\n"
            "ldr x16, [x9, #16]\n"
            "blr x16\n"
            :
            : "r"(&uArgs)
            : "x0", "x1", "x2", "x3", "x4", "x5", "x6", "x7",
              "x8", "x9", "x10", "x11", "x12", "x13", "x14", "x15",
              "x16", "x17", "x20", "x30", "memory"
        );
    }

    void *arrStorage = *elementsField;
    if (arrStorage) {
        int64_t count = *(int64_t *)((uint8_t *)arrStorage + 0x10);
        size_t headerOffset = (0x20 + (size_t)elAlignMask) & ~(size_t)elAlignMask;
        uint8_t *basePtr = (uint8_t *)arrStorage + headerOffset;

        uintptr_t setParentAddr = (uintptr_t)(0x1003ebba4ULL + slide);
        uint64_t parentId = gAMMultiParentCtx.hasParent ? gAMMultiParentCtx.targetParentId : 0;
        uint64_t isNil = gAMMultiParentCtx.hasParent ? 0 : 1;
        int64_t curTime = gAMMultiParentCtx.currentTime;

        for (int64_t i = 0; i < count; i++) {
            uint8_t *elPtr = basePtr + (size_t)i * elStride;
            uint64_t eid = *(uint64_t *)(elPtr + 0x18);
            if (!AMIsIdInList(eid, gAMMultiParentCtx.selectedIds, gAMMultiParentCtx.selectedCount)) {
                continue;
            }
            if (gAMMultiParentCtx.hasParent &&
                AMWouldCreateParentCycle(eid, parentId, basePtr, count, elStride, parentIdOff)) {
                continue;
            }
            struct { uint64_t a0, a1, a2, a3, a20, fn; } spArgs = {
                (uint64_t)sceneCopy, parentId, isNil, (uint64_t)curTime, (uint64_t)elPtr, (uint64_t)setParentAddr
            };
            __asm__ volatile(
                "mov x9, %0\n"
                "ldr x0,  [x9, #0]\n"
                "ldr x1,  [x9, #8]\n"
                "ldr x2,  [x9, #16]\n"
                "ldr x3,  [x9, #24]\n"
                "ldr x20, [x9, #32]\n"
                "ldr x16, [x9, #40]\n"
                "blr x16\n"
                :
                : "r"(&spArgs)
                : "x0", "x1", "x2", "x3", "x4", "x5", "x6", "x7",
                  "x8", "x9", "x10", "x11", "x12", "x13", "x14", "x15",
                  "x16", "x17", "x20", "x30", "memory",
                  "v0", "v1", "v2", "v3", "v4", "v5", "v6", "v7"
            );
        }
    }

    ((DestroyFn)(0x1000199c0ULL + slide))(sceneCopy, (void *)(0x1003c6b10ULL + slide));
    free(sceneCopy);
}

static int64_t AMReadHolderCurrentTime(void *holder, intptr_t slide) {
    if (!holder) return 0;
    uint8_t *h = (uint8_t *)holder;
    ptrdiff_t flagOff = *(ptrdiff_t *)(0x1033e54d0ULL + slide);
    ptrdiff_t t1Off = *(ptrdiff_t *)(0x1033e54e8ULL + slide);
    ptrdiff_t t2Off = *(ptrdiff_t *)(0x1033e5500ULL + slide);
    uint8_t flag = *(uint8_t *)(h + flagOff);
    int64_t t2 = *(int64_t *)(h + t2Off);
    if (flag == 1) {
        int64_t t1 = *(int64_t *)(h + t1Off);
        return (t2 > t1) ? t2 : t1;
    }
    return t2;
}

static void AMOnTapMultiParent(id self, SEL _cmd, UIButton *sender) {
    (void)_cmd;
    intptr_t slide = AMMainBinarySlide();
    void *holder = AMSwiftWeakLoadHolder(self, slide);
    if (!holder) return;

    // Grab first selected layer ID directly from holder.selection so LayerParentingVC.willDisplayCell populates cells
    uint64_t firstSelId = 0;
    BOOL hasFirstSel = NO;
    uint64_t *selIds = NULL;
    NSUInteger selCount = 0;
    if (AMReadHolderSelectedIds(holder, slide, &selIds, &selCount) && selCount > 0) {
        firstSelId = selIds[0];
        hasFirstSel = YES;
    }
    if (selIds) free(selIds);

    // Instantiate LayerParentingVC via native factory 0x10099e2c0(x0=holder, x20=LayerParentingVC.Type)
    typedef void *(*MetaFn)(uintptr_t);
    void *lpMeta = ((MetaFn)(0x10085e230ULL + slide))(0);
    void *lpvcRaw = NULL;
    if (lpMeta) {
        AMSwiftRetain(holder, slide);
        struct { uint64_t a0, a20, fn, ret; } fArgs = {
            (uint64_t)holder, (uint64_t)lpMeta, (uint64_t)(0x10099e2c0ULL + slide), 0
        };
        __asm__ volatile(
            "mov x9, %0\n"
            "ldr x0,  [x9, #0]\n"
            "ldr x20, [x9, #8]\n"
            "ldr x16, [x9, #16]\n"
            "blr x16\n"
            "mov x9, %0\n"
            "str x0,  [x9, #24]\n"
            :
            : "r"(&fArgs)
            : "x0", "x1", "x2", "x3", "x4", "x5", "x6", "x7",
              "x8", "x9", "x10", "x11", "x12", "x13", "x14", "x15",
              "x16", "x17", "x20", "x30", "memory"
        );
        lpvcRaw = (void *)fArgs.ret;
        AMSwiftRelease(holder, slide);
    }
    AMSwiftRelease(holder, slide);

    if (!lpvcRaw) return;
    UIViewController *lpvc = (__bridge_transfer UIViewController *)lpvcRaw;

    objc_setAssociatedObject(lpvc, kAMMultiParentNavKey, self, OBJC_ASSOCIATION_ASSIGN);
    if (hasFirstSel) {
        objc_setAssociatedObject(lpvc, kAMMultiParentFirstIdKey, @(firstSelId), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    lpvc.modalPresentationStyle = UIModalPresentationPopover;
    lpvc.preferredContentSize = CGSizeMake(280.0, 340.0);
    UIPopoverPresentationController *pop = lpvc.popoverPresentationController;
    if (pop && sender) {
        pop.sourceView = sender;
        pop.sourceRect = sender.bounds;
        pop.permittedArrowDirections = UIPopoverArrowDirectionUp | UIPopoverArrowDirectionAny;
        pop.delegate = [AMMultiParentPopoverDelegate shared];
    }
    [(UIViewController *)self presentViewController:lpvc animated:YES completion:nil];
}

static void AMHook_multiSelectorNavViewDidLoad(id self, SEL _cmd) {
    if (gOrigMultiSelectorNavViewDidLoad) {
        ((void (*)(id, SEL))gOrigMultiSelectorNavViewDidLoad)(self, _cmd);
    }
    if (![self respondsToSelector:@selector(basicStackView)]) return;
    UIStackView *stack = ((UIStackView *(*)(id, SEL))objc_msgSend)(self, @selector(basicStackView));
    if (![stack isKindOfClass:[UIStackView class]]) return;
    if ([stack viewWithTag:kAMMultiParentBtnTag]) return;

    // Locate the first group button (onTapGroup:) so the 3 group icons stay together
    // and the multi-parent button sits directly to the left of them.
    NSUInteger groupIdx = NSNotFound;
    UIButton *groupBtn = nil;
    NSArray<UIView *> *arranged = stack.arrangedSubviews;
    for (NSUInteger i = 0; i < arranged.count; i++) {
        UIView *v = arranged[i];
        if ([v isKindOfClass:[UIButton class]]) {
            UIButton *b = (UIButton *)v;
            NSArray<NSString *> *actions = [b actionsForTarget:self forControlEvent:UIControlEventTouchUpInside];
            if ([actions containsObject:@"onTapGroup:"]) {
                groupIdx = i;
                groupBtn = b;
                break;
            }
        }
    }
    if (groupIdx == NSNotFound) {
        for (NSUInteger i = 0; i < arranged.count; i++) {
            if ([arranged[i] isKindOfClass:[UIButton class]]) {
                groupIdx = i;
                groupBtn = (UIButton *)arranged[i];
                break;
            }
        }
    }
    if (groupIdx == NSNotFound) groupIdx = 0;

    UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
    btn.tag = kAMMultiParentBtnTag;
    btn.translatesAutoresizingMaskIntoConstraints = NO;
    UIImage *img = [UIImage imageNamed:@"ic_parent_of_layer"];
    if (!img) {
        if (@available(iOS 13.0, *)) {
            img = [UIImage systemImageNamed:@"square.on.square.dashed"];
        }
    }
    if (img) {
        img = [img imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
        [btn setImage:img forState:UIControlStateNormal];
    }
    btn.tintColor = groupBtn.tintColor ?: [UIColor blackColor];
    btn.imageView.contentMode = UIViewContentModeScaleAspectFit;
    [btn setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [btn setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];

    [btn addTarget:self action:@selector(am_onTapMultiParent:) forControlEvents:UIControlEventTouchUpInside];
    [stack insertArrangedSubview:btn atIndex:groupIdx];

    if (groupBtn) {
        [NSLayoutConstraint activateConstraints:@[
            [btn.widthAnchor constraintEqualToAnchor:groupBtn.widthAnchor],
            [btn.heightAnchor constraintEqualToAnchor:groupBtn.heightAnchor]
        ]];
    } else {
        [NSLayoutConstraint activateConstraints:@[
            [btn.widthAnchor constraintEqualToConstant:30.0],
            [btn.heightAnchor constraintEqualToConstant:30.0]
        ]];
    }
}

static void AMHook_layerParentingWillDisplayCell(id self, SEL _cmd, UITableView *tableView, UITableViewCell *cell, NSIndexPath *indexPath) {
    id navVC = objc_getAssociatedObject(self, kAMMultiParentNavKey);
    NSNumber *firstIdNum = objc_getAssociatedObject(self, kAMMultiParentFirstIdKey);
    if (!navVC || !firstIdNum) {
        if (gOrigLayerParentingWillDisplayCell) {
            ((void (*)(id, SEL, UITableView *, UITableViewCell *, NSIndexPath *))gOrigLayerParentingWillDisplayCell)(self, _cmd, tableView, cell, indexPath);
        }
        return;
    }

    intptr_t slide = AMMainBinarySlide();
    Ivar iv = class_getInstanceVariable([self class], "holder");
    void *holder = iv ? *(void **)((uint8_t *)(__bridge void *)self + ivar_getOffset(iv)) : NULL;
    if (!holder) {
        if (gOrigLayerParentingWillDisplayCell) {
            ((void (*)(id, SEL, UITableView *, UITableViewCell *, NSIndexPath *))gOrigLayerParentingWillDisplayCell)(self, _cmd, tableView, cell, indexPath);
        }
        return;
    }

    ptrdiff_t selOff = *(ptrdiff_t *)(0x103332390ULL + slide);
    uint8_t *selSlot = (uint8_t *)holder + selOff;
    uint8_t savedSel[9];
    memcpy(savedSel, selSlot, 9);

    uint64_t dummyId = [firstIdNum unsignedLongLongValue];
    memcpy(selSlot, &dummyId, 8);
    selSlot[8] = 0; // single-layer selection tag so willDisplayCell populates row UI

    if (gOrigLayerParentingWillDisplayCell) {
        ((void (*)(id, SEL, UITableView *, UITableViewCell *, NSIndexPath *))gOrigLayerParentingWillDisplayCell)(self, _cmd, tableView, cell, indexPath);
    }

    memcpy(selSlot, savedSel, 9);

    // Keep all rows interactive in multi-parent mode (other selected layers can still parent to it)
    cell.userInteractionEnabled = YES;
    cell.contentView.alpha = 1.0;
}

static void AMHook_layerParentingDidSelectRow(id self, SEL _cmd, UITableView *tableView, NSIndexPath *indexPath) {
    id navVC = objc_getAssociatedObject(self, kAMMultiParentNavKey);
    if (!navVC) {
        if (gOrigLayerParentingDidSelectRow) {
            ((void (*)(id, SEL, UITableView *, NSIndexPath *))gOrigLayerParentingDidSelectRow)(self, _cmd, tableView, indexPath);
        }
        return;
    }

    intptr_t slide = AMMainBinarySlide();
    BOOL hasParent = NO;
    uint64_t targetParentId = 0;

    if (indexPath.section == 1) {
        void *elementsStorage = AMSwiftArrayStorageForObj(self, "elements");
        if (elementsStorage) {
            typedef void *(*MetaFn)(uintptr_t);
            void *elMeta = ((MetaFn)(0x1003e0404ULL + slide))(0);
            void *elVWT = *(void **)((uint8_t *)elMeta - 8);
            uint8_t elAlignMask = *(uint8_t *)((uint8_t *)elVWT + 0x50);
            size_t elStride = *(size_t *)((uint8_t *)elVWT + 0x48);
            int64_t count = *(int64_t *)((uint8_t *)elementsStorage + 0x10);
            if (indexPath.row >= 0 && indexPath.row < count) {
                size_t headerOffset = (0x20 + (size_t)elAlignMask) & ~(size_t)elAlignMask;
                const uint8_t *elPtr = (const uint8_t *)elementsStorage + headerOffset + (size_t)indexPath.row * elStride;
                targetParentId = *(const uint64_t *)(elPtr + 0x18);
                hasParent = YES;
            }
        }
    }

    void *holder = AMSwiftWeakLoadHolder(navVC, slide);
    if (holder) {
        uint64_t *selIds = NULL;
        NSUInteger selCount = 0;
        if (AMReadHolderSelectedIds(holder, slide, &selIds, &selCount) && selCount > 0) {
            gAMMultiParentCtx.selectedIds = selIds;
            gAMMultiParentCtx.selectedCount = selCount;
            gAMMultiParentCtx.targetParentId = targetParentId;
            gAMMultiParentCtx.hasParent = hasParent;
            gAMMultiParentCtx.currentTime = AMReadHolderCurrentTime(holder, slide);

            struct { uint64_t cb, holderPtr, fn; } peArgs = {
                (uint64_t)AMMultiParentEditCallback, (uint64_t)holder, (uint64_t)(0x100392588ULL + slide)
            };
            __asm__ volatile(
                "mov x9, %0\n"
                "mov w0, #4\n"
                "mov x1, #0\n"
                "mov w2, #2\n"
                "ldr x3,  [x9, #0]\n"
                "mov x4, #0\n"
                "ldr x20, [x9, #8]\n"
                "ldr x16, [x9, #16]\n"
                "blr x16\n"
                :
                : "r"(&peArgs)
                : "x0", "x1", "x2", "x3", "x4", "x5", "x6", "x7",
                  "x8", "x9", "x10", "x11", "x12", "x13", "x14", "x15",
                  "x16", "x17", "x20", "x30", "memory",
                  "v0", "v1", "v2", "v3", "v4", "v5", "v6", "v7"
            );

            gAMMultiParentCtx.selectedIds = NULL;
            gAMMultiParentCtx.selectedCount = 0;
        }
        if (selIds) free(selIds);
        AMSwiftRelease(holder, slide);
    }

    [(UIViewController *)self dismissViewControllerAnimated:YES completion:nil];
}

// ============================================================================
// Constructor: Install All Hooks Safely on Launch
// ============================================================================

// ============================================================================
// Audio Layer Speed Scaling + Varispeed Pitch Shifting (Preview & Export)
// ============================================================================
// Binary patches in inject_mods.py:
//   - 0x006D4D44: bypass EditSpeedVM "audio" speed_control_not_avail_audio gate
//   - 0x00222C70: bypass audio composition speed!=1.0 skip so s8 (element.speed)
//                 proceeds into [AVAsset tracksWithMediaType:AVMediaTypeAudio]
//                 (0x100222d24) and [AVMutableCompositionTrack insertTimeRange:
//                 ofTrack:atTime:error:] (0x100224004).
// Here we capture s8 (callee-saved element.speed) at 0x100222d28, scale the
// inserted audio segment by 1/speed at 0x100224008, and force
// AVAudioTimePitchAlgorithmVarispeed on AVPlayerItem, AVAssetReaderAudioMixOutput,
// and AVAssetExportSession so speed changes shift pitch in both preview & export.

static thread_local float gPendingAudioSpeed = 1.0f;

static IMP gOrigAVAssetTracksWithMediaType = NULL;
static IMP gOrigAVURLAssetTracksWithMediaType = NULL;
static IMP gOrigCompTrackInsertTimeRange = NULL;
static IMP gOrigPlayerItemSetAudioMix = NULL;
static IMP gOrigAudioMixOutputInit = NULL;
static IMP gOrigAudioMixOutputSetAudioMix = NULL;
static IMP gOrigExportSessionSetAudioMix = NULL;

static __attribute__((noinline))
NSArray<AVAssetTrack *> *AMHandleTracksWithMediaType(
    id self, SEL _cmd, AVMediaType mediaType, IMP origImp, uintptr_t retAddr, float s8Val)
{
    static uintptr_t kAudioTracksRet = 0;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        kAudioTracksRet = 0x100222d28ULL + (uintptr_t)AMMainBinarySlide();
    });
    if (retAddr == kAudioTracksRet) {
        if (isfinite(s8Val) && s8Val > 0.01f && s8Val < 100.0f) {
            gPendingAudioSpeed = s8Val;
        } else {
            gPendingAudioSpeed = 1.0f;
        }
    }
    return ((NSArray<AVAssetTrack *> *(*)(id, SEL, AVMediaType))origImp)(self, _cmd, mediaType);
}

static NSArray<AVAssetTrack *> *AMHook_avAssetTracksWithMediaType(id self, SEL _cmd, AVMediaType mediaType) {
    float s8Val = 1.0f;
#if defined(__aarch64__)
    __asm__ volatile("fmov %s0, s8" : "=w"(s8Val));
#endif
    uintptr_t retAddr = (uintptr_t)__builtin_return_address(0);
    return AMHandleTracksWithMediaType(self, _cmd, mediaType, gOrigAVAssetTracksWithMediaType, retAddr, s8Val);
}

static NSArray<AVAssetTrack *> *AMHook_avURLAssetTracksWithMediaType(id self, SEL _cmd, AVMediaType mediaType) {
    float s8Val = 1.0f;
#if defined(__aarch64__)
    __asm__ volatile("fmov %s0, s8" : "=w"(s8Val));
#endif
    uintptr_t retAddr = (uintptr_t)__builtin_return_address(0);
    return AMHandleTracksWithMediaType(self, _cmd, mediaType, gOrigAVURLAssetTracksWithMediaType, retAddr, s8Val);
}

static BOOL AMHook_compTrackInsertTimeRange(
    id self, SEL _cmd, CMTimeRange timeRange, AVAssetTrack *track, CMTime startTime, NSError **outError)
{
    uintptr_t retAddr = (uintptr_t)__builtin_return_address(0);
    BOOL ok = ((BOOL (*)(id, SEL, CMTimeRange, AVAssetTrack *, CMTime, NSError **))gOrigCompTrackInsertTimeRange)(
        self, _cmd, timeRange, track, startTime, outError);

    static uintptr_t kAudioInsertRet = 0;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        kAudioInsertRet = 0x100224008ULL + (uintptr_t)AMMainBinarySlide();
    });

    if (retAddr == kAudioInsertRet) {
        float spd = gPendingAudioSpeed;
        gPendingAudioSpeed = 1.0f;
        if (ok && isfinite(spd) && fabsf(spd - 1.0f) > 1e-6f && spd > 0.01f && spd < 100.0f) {
            if (CMTIME_IS_VALID(timeRange.duration) && CMTimeCompare(timeRange.duration, kCMTimeZero) > 0) {
                CMTime scaledDur = CMTimeMultiplyByFloat64(timeRange.duration, 1.0 / (double)spd);
                if (CMTIME_IS_VALID(scaledDur) && CMTimeCompare(scaledDur, kCMTimeZero) > 0) {
                    [(AVMutableCompositionTrack *)self scaleTimeRange:CMTimeRangeMake(startTime, timeRange.duration)
                                                           toDuration:scaledDur];
                }
            }
        }
    }
    return ok;
}

static void AMHook_playerItemSetAudioMix(id self, SEL _cmd, AVAudioMix *audioMix) {
    if (gOrigPlayerItemSetAudioMix) {
        ((void (*)(id, SEL, AVAudioMix *))gOrigPlayerItemSetAudioMix)(self, _cmd, audioMix);
    }
    [(AVPlayerItem *)self setAudioTimePitchAlgorithm:AVAudioTimePitchAlgorithmVarispeed];
}

static id AMHook_audioMixOutputInit(id self, SEL _cmd, NSArray<AVAssetTrack *> *audioTracks, NSDictionary<NSString *, id> *audioSettings) {
    id res = self;
    if (gOrigAudioMixOutputInit) {
        res = ((id (*)(id, SEL, NSArray<AVAssetTrack *> *, NSDictionary<NSString *, id> *))gOrigAudioMixOutputInit)(
            self, _cmd, audioTracks, audioSettings);
    }
    if (res) {
        [(AVAssetReaderAudioMixOutput *)res setAudioTimePitchAlgorithm:AVAudioTimePitchAlgorithmVarispeed];
    }
    return res;
}

static void AMHook_audioMixOutputSetAudioMix(id self, SEL _cmd, AVAudioMix *audioMix) {
    if (gOrigAudioMixOutputSetAudioMix) {
        ((void (*)(id, SEL, AVAudioMix *))gOrigAudioMixOutputSetAudioMix)(self, _cmd, audioMix);
    }
    [(AVAssetReaderAudioMixOutput *)self setAudioTimePitchAlgorithm:AVAudioTimePitchAlgorithmVarispeed];
}

static void AMHook_exportSessionSetAudioMix(id self, SEL _cmd, AVAudioMix *audioMix) {
    if (gOrigExportSessionSetAudioMix) {
        ((void (*)(id, SEL, AVAudioMix *))gOrigExportSessionSetAudioMix)(self, _cmd, audioMix);
    }
    [(AVAssetExportSession *)self setAudioTimePitchAlgorithm:AVAudioTimePitchAlgorithmVarispeed];
}

static IMP gOrigWindowSendEvent = NULL;
static void AMHook_windowSendEvent(id self, SEL _cmd, UIEvent *event) {
    if (gOrigWindowSendEvent) {
        ((void (*)(id, SEL, UIEvent *))gOrigWindowSendEvent)(self, _cmd, event);
    }
    if (event.type == UIEventTypeTouches && [self isKindOfClass:[UIWindow class]]) {
        UIWindow *win = (UIWindow *)self;
        CGFloat barTop = win.bounds.size.height - win.safeAreaInsets.bottom - 95.0;
        for (UITouch *t in [event touchesForWindow:win]) {
            if (t.phase == UITouchPhaseBegan || t.phase == UITouchPhaseEnded) {
                if ([t locationInView:win].y >= barTop) {
                    [[AMHomepageSearchOverlayManager shared] scheduleImmediateTick];
                    break;
                }
            }
        }
    }
}

static IMP gOrigTabBarControllerSetSelectedIndex = NULL;
static void AMHook_tabBarControllerSetSelectedIndex(id self, SEL _cmd, NSUInteger idx) {
    if (gOrigTabBarControllerSetSelectedIndex) {
        ((void (*)(id, SEL, NSUInteger))gOrigTabBarControllerSetSelectedIndex)(self, _cmd, idx);
    }
    [[AMHomepageSearchOverlayManager shared] scheduleImmediateTick];
}

static IMP gOrigTabBarControllerSetSelectedVC = NULL;
static void AMHook_tabBarControllerSetSelectedVC(id self, SEL _cmd, UIViewController *vc) {
    if (gOrigTabBarControllerSetSelectedVC) {
        ((void (*)(id, SEL, UIViewController *))gOrigTabBarControllerSetSelectedVC)(self, _cmd, vc);
    }
    [[AMHomepageSearchOverlayManager shared] scheduleImmediateTick];
}

static IMP gOrigTabBarSetSelectedItem = NULL;
static void AMHook_tabBarSetSelectedItem(id self, SEL _cmd, UITabBarItem *item) {
    if (gOrigTabBarSetSelectedItem) {
        ((void (*)(id, SEL, UITabBarItem *))gOrigTabBarSetSelectedItem)(self, _cmd, item);
    }
    [[AMHomepageSearchOverlayManager shared] scheduleImmediateTick];
}

// ============================================================================
// Module 7: After Effects-Style Puppet Pin Tool (GPU MLS + Keyframes + Graphs)
// ============================================================================

static const int kAMPuppetMaxSlots = 16;
static const int kAMPuppetMaxPins = 16;
static const int kAMPuppetMaxKeyframesPerPin = 64;
static const float kAMPuppetMagicFloat = 133742.25f;

typedef struct {
    int64_t timeMs;
    float x;
    float y;
    int easingType; // 0 = Cubic Bezier, 1 = Step, 2 = Overshoot/Elastic, 3 = Bounce
    float p1x;
    float p1y;
    float p2x;
    float p2y;
    float stepCount;
} AMPuppetKeyframeC;

typedef struct {
    int pinId;
    float restX;
    float restY;
    float currX;
    float currY;
    int keyframeCount;
    AMPuppetKeyframeC keyframes[kAMPuppetMaxKeyframesPerPin];
} AMPuppetPinC;

typedef struct {
    BOOL active;
    uint64_t elementId;
    int64_t startTimeMs;
    int64_t endTimeMs;
    float rigidity;
    int deformMode; // 0 = Rigid MLS, 1 = Similarity/Stretch MLS, 2 = Smooth RBF
    BOOL showMesh;
    int pinCount;
    AMPuppetPinC pins[kAMPuppetMaxPins];
} AMPuppetSlotRuntime;

typedef struct {
    BOOL valid;
    float screenToLayer[16];
    float layerToScreen[16];
    float screenSize[2];
    float layerSize[2];
    float lastShaderTime;
    int timeMode; // 0 = unknown, 1 = layer-local sec, 2 = scene sec
} AMPuppetTransformSnapshot;

static os_unfair_lock gAMPuppetRuntimeLock = OS_UNFAIR_LOCK_INIT;
static AMPuppetSlotRuntime gAMPuppetSlots[kAMPuppetMaxSlots + 1];
static AMPuppetTransformSnapshot gAMPuppetTransforms[kAMPuppetMaxSlots + 1];
static volatile int64_t gAMPuppetEditorCurrentTimeMs = 0;
static volatile uint64_t gAMPuppetActiveElementId = 0;
static volatile int gAMPuppetActivePinIndex = -1;
static volatile BOOL gAMPuppetPanelVisible = NO;
static volatile int gAMPuppetLastTransformSlotNotified = 0;

// Clipboard for Copy/Paste Easing Curve inside Puppet Graph Editor
static int gAMPuppetCopiedEasingType = 0;
static float gAMPuppetCopiedP1X = 0.42f, gAMPuppetCopiedP1Y = 0.0f;
static float gAMPuppetCopiedP2X = 0.58f, gAMPuppetCopiedP2Y = 1.0f;
static float gAMPuppetCopiedStepCount = 4.0f;
static BOOL gAMPuppetHasCopiedCurve = NO;

static NSString *const kAMPuppetTransformUpdatedNotification = @"AMPuppetTransformUpdatedNotification";

// --- Cubic Bezier / Easing Evaluator (exact Newton-Raphson + bisection) ---

static float AMPuppetEvalCubic1D(float p1, float p2, float s) {
    float inv = 1.0f - s;
    return 3.0f * inv * inv * s * p1 + 3.0f * inv * s * s * p2 + s * s * s;
}

static float AMPuppetEvalCubicDeriv(float p1, float p2, float s) {
    float inv = 1.0f - s;
    return 3.0f * inv * inv * p1 + 6.0f * inv * s * (p2 - p1) + 3.0f * s * s * (1.0f - p2);
}

static float AMPuppetEvalEasing(int easingType, float p1x, float p1y, float p2x, float p2y, float stepCount, float u) {
    if (u <= 0.0f) return 0.0f;
    if (u >= 1.0f) return 1.0f;
    if (easingType == 1) {
        // Step easing
        float steps = fmaxf(1.0f, roundf(stepCount));
        if (steps <= 1.0f) return 0.0f; // Hold until next keyframe
        return floorf(u * steps) / steps;
    }
    if (easingType == 2) {
        // Elastic overshoot
        float freq = fmaxf(1.0f, p1x * 6.0f + 1.5f);
        float damp = fmaxf(1.0f, p2x * 8.0f + 3.0f);
        return 1.0f - expf(-damp * u) * cosf(u * freq * (float)M_PI * 2.0f);
    }
    if (easingType == 3) {
        // Bounce Out
        float n1 = 7.5625f;
        float d1 = 2.75f;
        float t = u;
        if (t < 1.0f / d1) {
            return n1 * t * t;
        } else if (t < 2.0f / d1) {
            t -= 1.5f / d1;
            return n1 * t * t + 0.75f;
        } else if (t < 2.5f / d1) {
            t -= 2.25f / d1;
            return n1 * t * t + 0.9375f;
        } else {
            t -= 2.625f / d1;
            return n1 * t * t + 0.984375f;
        }
    }
    // Type 0: Cubic Bezier (p0=(0,0), p1=(p1x,p1y), p2=(p2x,p2y), p3=(1,1))
    float cx1 = fminf(fmaxf(p1x, 0.0f), 1.0f);
    float cx2 = fminf(fmaxf(p2x, 0.0f), 1.0f);
    if (fabsf(cx1 - p1y) < 1e-4f && fabsf(cx2 - p2y) < 1e-4f) {
        return u; // Fast path: Linear
    }
    float lo = 0.0f, hi = 1.0f, s = u;
    for (int i = 0; i < 6; ++i) {
        float x = AMPuppetEvalCubic1D(cx1, cx2, s) - u;
        if (fabsf(x) < 1e-5f) break;
        float dx = AMPuppetEvalCubicDeriv(cx1, cx2, s);
        if (fabsf(dx) < 1e-5f) break;
        float ns = s - x / dx;
        if (ns < lo || ns > hi) break;
        s = ns;
    }
    for (int i = 0; i < 8; ++i) {
        float x = AMPuppetEvalCubic1D(cx1, cx2, s);
        if (fabsf(x - u) < 1e-5f) break;
        if (x < u) lo = s; else hi = s;
        s = 0.5f * (lo + hi);
    }
    return AMPuppetEvalCubic1D(p1y, p2y, s);
}

static void AMPuppetEvalPinAtMs(const AMPuppetPinC *pin, int64_t timeMs, float *outX, float *outY) {
    if (!pin) { *outX = 0.5f; *outY = 0.5f; return; }
    int n = pin->keyframeCount;
    if (n <= 0) {
        *outX = pin->currX;
        *outY = pin->currY;
        return;
    }
    if (n == 1 || timeMs <= pin->keyframes[0].timeMs) {
        *outX = pin->keyframes[0].x;
        *outY = pin->keyframes[0].y;
        return;
    }
    if (timeMs >= pin->keyframes[n - 1].timeMs) {
        *outX = pin->keyframes[n - 1].x;
        *outY = pin->keyframes[n - 1].y;
        return;
    }
    for (int i = 0; i < n - 1; ++i) {
        const AMPuppetKeyframeC *k0 = &pin->keyframes[i];
        const AMPuppetKeyframeC *k1 = &pin->keyframes[i + 1];
        if (timeMs >= k0->timeMs && timeMs <= k1->timeMs) {
            int64_t dt = k1->timeMs - k0->timeMs;
            if (dt <= 0) {
                *outX = k1->x;
                *outY = k1->y;
                return;
            }
            float u = (float)((double)(timeMs - k0->timeMs) / (double)dt);
            float e = AMPuppetEvalEasing(k0->easingType, k0->p1x, k0->p1y, k0->p2x, k0->p2y, k0->stepCount, u);
            *outX = k0->x + (k1->x - k0->x) * e;
            *outY = k0->y + (k1->y - k0->y) * e;
            return;
        }
    }
    *outX = pin->currX;
    *outY = pin->currY;
}

// --- Built-in Internal Puppet Slot XMLs (1..16) with GPU MLS Shader ---

static NSString *AMPuppetSlotsDir(void) {
    NSString *dir = [AMCustomEffectsDir() stringByAppendingPathComponent:@"PuppetSlots"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}

static NSString *AMPuppetEffectIdForSlot(int slot) {
    return [NSString stringWithFormat:@"com.alightcreative.effects.am_puppet_slot_%d", slot];
}

static NSString *AMPuppetBuildSlotXML(int slot) {
    NSMutableString *params = [NSMutableString string];
    [params appendString:@"        <texture id=\"inputImg\" srcType=\"content\" />\n"];
    [params appendFormat:@"        <float id=\"amPuppetMagic\" value=\"133742.25\" />\n"];
    [params appendFormat:@"        <float id=\"puppetSlot\" value=\"%d.0\" />\n", slot];
    [params appendString:@"        <float id=\"pinCount\" value=\"0.0\" />\n"];
    [params appendString:@"        <float id=\"rigidity\" value=\"1.5\" />\n"];
    [params appendString:@"        <float id=\"deformMode\" value=\"0.0\" />\n"];
    [params appendString:@"        <float id=\"showMesh\" value=\"0.0\" />\n"];
    for (int i = 0; i < kAMPuppetMaxPins; ++i) {
        [params appendFormat:@"        <float id=\"r%dx\" value=\"0.5\" />\n", i];
        [params appendFormat:@"        <float id=\"r%dy\" value=\"0.5\" />\n", i];
        [params appendFormat:@"        <float id=\"c%dx\" value=\"0.5\" />\n", i];
        [params appendFormat:@"        <float id=\"c%dy\" value=\"0.5\" />\n", i];
    }

    NSMutableString *assigns = [NSMutableString string];
    for (int i = 0; i < kAMPuppetMaxPins; ++i) {
        [assigns appendFormat:@"            pRest[%d] = vec2(r%dx, r%dy) * aspect;\n", i, i, i];
        [assigns appendFormat:@"            pCurr[%d] = vec2(c%dx, c%dy) * aspect;\n", i, i, i];
    }

    return [NSString stringWithFormat:
        @"<?xml version='1.0' encoding='UTF-8' ?>\n"
        @"<effect id=\"com.alightcreative.effects.am_puppet_slot_%d\" compat=\"acScreenNorm-y\" name=\"Puppet\" desc=\"After Effects-style Puppet Pin Deformation.\" category=\"distort\" tags=\"distort,warp,puppet\" thumb=\"thumb/bend.webp\" internal=\"true\" overdraw=\"true\" max-overdraw=\"0.5\" maxOverdraw=\"0.5\">\n"
        @"    <params>\n%@    </params>\n"
        @"    <shader type=\"fragment\" precision=\"high\"><![CDATA[\n"
        @"        void main() {\n"
        @"            float keepTime = acTime * 0.0 + amPuppetMagic * 0.0 + puppetSlot * 0.0;\n"
        @"            int nPins = int(pinCount + 0.5);\n"
        @"            if (nPins <= 0) {\n"
        @"                gl_FragColor = texture2DCv(inputImg.texture, acScreenNorm + vec2(keepTime, 0.0));\n"
        @"                return;\n"
        @"            }\n"
        @"            vec2 aspect = vec2(acLayerSize.x / max(acLayerSize.y, 1.0), 1.0);\n"
        @"            vec2 invAspect = vec2(1.0 / max(aspect.x, 0.0001), 1.0);\n"
        @"            vec2 v = acLayerNorm * aspect;\n"
        @"            vec2 pRest[16];\n"
        @"            vec2 pCurr[16];\n"
        @"%@"
        @"            vec2 srcA = v;\n"
        @"            if (nPins == 1) {\n"
        @"                srcA = v - (pCurr[0] - pRest[0]);\n"
        @"            } else {\n"
        @"                float wArr[16];\n"
        @"                float wSum = 0.0;\n"
        @"                vec2 qStar = vec2(0.0, 0.0);\n"
        @"                vec2 pStar = vec2(0.0, 0.0);\n"
        @"                float alpha = clamp(rigidity, 0.5, 4.0);\n"
        @"                for (int i = 0; i < 16; i++) {\n"
        @"                    if (i >= nPins) break;\n"
        @"                    vec2 d = v - pCurr[i];\n"
        @"                    float d2 = dot(d, d) + 0.0006;\n"
        @"                    float w = pow(max(d2, 0.0006), -alpha);\n"
        @"                    wArr[i] = w;\n"
        @"                    wSum += w;\n"
        @"                    qStar += w * pCurr[i];\n"
        @"                    pStar += w * pRest[i];\n"
        @"                }\n"
        @"                float invW = 1.0 / max(wSum, 0.00001);\n"
        @"                qStar *= invW;\n"
        @"                pStar *= invW;\n"
        @"                if (deformMode >= 1.5) {\n"
        @"                    srcA = v + (pStar - qStar);\n"
        @"                } else {\n"
        @"                    float mu = 0.0;\n"
        @"                    float mx = 0.0;\n"
        @"                    float my = 0.0;\n"
        @"                    for (int i = 0; i < 16; i++) {\n"
        @"                        if (i >= nPins) break;\n"
        @"                        vec2 qh = pCurr[i] - qStar;\n"
        @"                        vec2 ph = pRest[i] - pStar;\n"
        @"                        float w = wArr[i];\n"
        @"                        mu += w * dot(qh, qh);\n"
        @"                        mx += w * (ph.x * qh.x + ph.y * qh.y);\n"
        @"                        my += w * (ph.y * qh.x - ph.x * qh.y);\n"
        @"                    }\n"
        @"                    vec2 dv = v - qStar;\n"
        @"                    if (deformMode < 0.5) {\n"
        @"                        float mLen = sqrt(max(mx * mx + my * my, 0.0000001));\n"
        @"                        float rx = mx / mLen;\n"
        @"                        float ry = my / mLen;\n"
        @"                        srcA = vec2(rx * dv.x - ry * dv.y, ry * dv.x + rx * dv.y) + pStar;\n"
        @"                    } else {\n"
        @"                        float invMu = 1.0 / max(mu, 0.00001);\n"
        @"                        float sx = mx * invMu;\n"
        @"                        float sy = my * invMu;\n"
        @"                        srcA = vec2(sx * dv.x - sy * dv.y, sy * dv.x + sx * dv.y) + pStar;\n"
        @"                    }\n"
        @"                }\n"
        @"            }\n"
        @"            vec2 srcNorm = srcA * invAspect;\n"
        @"            vec2 pxFeather = 1.0 / max(acLayerSize, vec2(1.0, 1.0));\n"
        @"            float inX = smoothstep(-pxFeather.x, pxFeather.x, srcNorm.x) * (1.0 - smoothstep(1.0 - pxFeather.x, 1.0 + pxFeather.x, srcNorm.x));\n"
        @"            float inY = smoothstep(-pxFeather.y, pxFeather.y, srcNorm.y) * (1.0 - smoothstep(1.0 - pxFeather.y, 1.0 + pxFeather.y, srcNorm.y));\n"
        @"            float insideMask = inX * inY;\n"
        @"            vec2 sampleScreen = (vec4(srcNorm, 0.0, 1.0) * acLayerToScreen).xy;\n"
        @"            vec4 col = texture2DCv(inputImg.texture, sampleScreen + vec2(keepTime, 0.0)) * insideMask;\n"
        @"            if (showMesh > 0.5 && insideMask > 0.01 && col.a > 0.02) {\n"
        @"                float cells = 8.0;\n"
        @"                vec2 g = fract(srcNorm * cells);\n"
        @"                float dGrid = min(min(g.x, 1.0 - g.x), min(g.y, 1.0 - g.y));\n"
        @"                float dDiag = abs(g.x - g.y) * 0.7071;\n"
        @"                float edge = 1.0 - smoothstep(0.018, 0.048, min(dGrid, dDiag));\n"
        @"                vec3 meshCol = vec3(0.204, 0.827, 0.600) * col.a;\n"
        @"                col.rgb = mix(col.rgb, meshCol, edge * 0.62);\n"
        @"            }\n"
        @"            gl_FragColor = col;\n"
        @"        }\n"
        @"    ]]></shader>\n"
        @"</effect>\n",
        slot, params, assigns];
}

static NSArray<NSURL *> *AMEnsurePuppetSlotXMLs(void) {
    static NSArray<NSURL *> *cached = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *dir = AMPuppetSlotsDir();
        NSString *verFile = [dir stringByAppendingPathComponent:@".puppet_xml_v1"];
        BOOL needsWrite = ![[NSFileManager defaultManager] fileExistsAtPath:verFile];
        NSMutableArray<NSURL *> *urls = [NSMutableArray arrayWithCapacity:kAMPuppetMaxSlots];
        for (int s = 1; s <= kAMPuppetMaxSlots; ++s) {
            NSString *p = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"am_puppet_slot_%d.xml", s]];
            if (needsWrite || ![[NSFileManager defaultManager] fileExistsAtPath:p]) {
                NSString *xml = AMPuppetBuildSlotXML(s);
                [xml writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:nil];
            }
            [urls addObject:[NSURL fileURLWithPath:p]];
        }
        if (needsWrite) {
            [@"1" writeToFile:verFile atomically:YES encoding:NSUTF8StringEncoding error:nil];
        }
        cached = [urls copy];
    });
    return cached;
}

// --- Metal setFragmentBytes Hook (Live Preview + Full-Res Video Export!) ---

typedef struct {
    __unsafe_unretained id encoder;
    int magicIdx;
    int slot;
    NSUInteger length;
    float headerFloats[16];
} AMPuppetPendingEncoder;

static thread_local AMPuppetPendingEncoder gAMPendingPuppetEnc = { nil, -1, 0, 0, {0} };
static IMP gOrigMTLSetFragmentBytes = NULL;

static void AMHook_mtlSetFragmentBytes(id self, SEL _cmd, const void *bytes, NSUInteger length, NSUInteger index) {
    if (index == 0 && bytes != NULL && length >= 276 && length <= 512) {
        const float *f = (const float *)bytes;
        int maxScan = (int)(length / sizeof(float));
        if (maxScan > 10) maxScan = 10;
        int foundIdx = -1;
        for (int i = 0; i < maxScan - 1; ++i) {
            if (f[i] == kAMPuppetMagicFloat) {
                foundIdx = i;
                break;
            }
        }
        if (foundIdx >= 0) {
            int slot = (int)roundf(f[foundIdx + 1]);
            if (slot >= 1 && slot <= kAMPuppetMaxSlots) {
                gAMPendingPuppetEnc.encoder = self;
                gAMPendingPuppetEnc.magicIdx = foundIdx;
                gAMPendingPuppetEnc.slot = slot;
                gAMPendingPuppetEnc.length = length;
                int copyHdr = (foundIdx < 16) ? foundIdx : 16;
                for (int k = 0; k < copyHdr; ++k) gAMPendingPuppetEnc.headerFloats[k] = f[k];
            } else {
                gAMPendingPuppetEnc.encoder = nil;
            }
        } else if (gAMPendingPuppetEnc.encoder == self) {
            gAMPendingPuppetEnc.encoder = nil;
        }
    } else if (index == 1 && bytes != NULL && length == 0x140 && gAMPendingPuppetEnc.encoder == self) {
        int slot = gAMPendingPuppetEnc.slot;
        int magicIdx = gAMPendingPuppetEnc.magicIdx;
        NSUInteger pLen = gAMPendingPuppetEnc.length;
        gAMPendingPuppetEnc.encoder = nil;

        const uint8_t *inBytes = (const uint8_t *)bytes;
        float shaderTimeSec = *(const float *)(inBytes + 0x110);

        float outBuf[128];
        memset(outBuf, 0, sizeof(outBuf));
        for (int k = 0; k < magicIdx && k < 16; ++k) {
            outBuf[k] = gAMPendingPuppetEnc.headerFloats[k];
        }
        outBuf[magicIdx + 0] = kAMPuppetMagicFloat;
        outBuf[magicIdx + 1] = (float)slot;

        BOOL notifyTransform = NO;
        os_unfair_lock_lock(&gAMPuppetRuntimeLock);
        AMPuppetTransformSnapshot *tr = &gAMPuppetTransforms[slot];
        BOOL wasValid = tr->valid;
        BOOL matrixChanged = (!wasValid || memcmp(tr->layerToScreen, inBytes + 0x80, 16 * sizeof(float)) != 0);
        memcpy(tr->screenToLayer, inBytes + 0x40, 16 * sizeof(float));
        memcpy(tr->layerToScreen, inBytes + 0x80, 16 * sizeof(float));
        memcpy(tr->screenSize, inBytes + 0xD0, 2 * sizeof(float));
        memcpy(tr->layerSize, inBytes + 0xE0, 2 * sizeof(float));
        tr->lastShaderTime = shaderTimeSec;
        tr->valid = YES;

        AMPuppetSlotRuntime *rt = &gAMPuppetSlots[slot];
        if (matrixChanged && (!wasValid || (gAMPuppetPanelVisible && rt->active && rt->elementId == gAMPuppetActiveElementId))) {
            notifyTransform = YES;
        }

        // Auto-calibrate acTime origin (layer-local sec vs scene sec)
        if (rt->active && rt->startTimeMs > 50 && gAMPuppetPanelVisible && rt->elementId == gAMPuppetActiveElementId) {
            double edSec = (double)gAMPuppetEditorCurrentTimeMs / 1000.0;
            double edLocalSec = (double)(gAMPuppetEditorCurrentTimeMs - rt->startTimeMs) / 1000.0;
            if (fabs((double)shaderTimeSec - edLocalSec) + 0.02 < fabs((double)shaderTimeSec - edSec)) {
                tr->timeMode = 1; // layer-local
            } else if (fabs((double)shaderTimeSec - edSec) + 0.02 < fabs((double)shaderTimeSec - edLocalSec)) {
                tr->timeMode = 2; // scene
            }
        }

        int64_t evalTimeMs = (int64_t)llround((double)shaderTimeSec * 1000.0);
        if (tr->timeMode != 2 && rt->startTimeMs > 0) {
            // Default assumption in Alight Motion: acTime is layer-local seconds unless proven scene seconds
            evalTimeMs = rt->startTimeMs + (int64_t)llround((double)shaderTimeSec * 1000.0);
        }

        if (rt->active && rt->pinCount > 0) {
            int n = rt->pinCount;
            if (n > kAMPuppetMaxPins) n = kAMPuppetMaxPins;
            outBuf[magicIdx + 2] = (float)n;
            outBuf[magicIdx + 3] = rt->rigidity;
            outBuf[magicIdx + 4] = (float)rt->deformMode;
            outBuf[magicIdx + 5] = (rt->showMesh && gAMPuppetPanelVisible && rt->elementId == gAMPuppetActiveElementId) ? 1.0f : 0.0f;
            int baseIdx = magicIdx + 6;
            for (int i = 0; i < n; ++i) {
                float cx = rt->pins[i].currX;
                float cy = rt->pins[i].currY;
                AMPuppetEvalPinAtMs(&rt->pins[i], evalTimeMs, &cx, &cy);
                outBuf[baseIdx + i * 4 + 0] = rt->pins[i].restX;
                outBuf[baseIdx + i * 4 + 1] = rt->pins[i].restY;
                outBuf[baseIdx + i * 4 + 2] = cx;
                outBuf[baseIdx + i * 4 + 3] = cy;
            }
        } else {
            outBuf[magicIdx + 2] = 0.0f;
            outBuf[magicIdx + 3] = 1.5f;
            outBuf[magicIdx + 4] = 0.0f;
            outBuf[magicIdx + 5] = 0.0f;
        }
        os_unfair_lock_unlock(&gAMPuppetRuntimeLock);

        if (gOrigMTLSetFragmentBytes) {
            NSUInteger uploadLen = (pLen <= sizeof(outBuf)) ? pLen : sizeof(outBuf);
            ((void (*)(id, SEL, const void *, NSUInteger, NSUInteger))gOrigMTLSetFragmentBytes)(self, _cmd, outBuf, uploadLen, 0);
        }
        if (notifyTransform) {
            int prev = gAMPuppetLastTransformSlotNotified;
            if (prev != slot) {
                gAMPuppetLastTransformSlotNotified = slot;
                dispatch_async(dispatch_get_main_queue(), ^{
                    gAMPuppetLastTransformSlotNotified = 0;
                    [[NSNotificationCenter defaultCenter] postNotificationName:kAMPuppetTransformUpdatedNotification object:@(slot)];
                });
            }
        }
    }

    if (gOrigMTLSetFragmentBytes) {
        ((void (*)(id, SEL, const void *, NSUInteger, NSUInteger))gOrigMTLSetFragmentBytes)(self, _cmd, bytes, length, index);
    }
}

static void AMInstallPuppetMetalHook(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        if (!dev) return;
        id<MTLCommandQueue> q = [dev newCommandQueue];
        if (!q) return;
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                      width:4
                                                                                     height:4
                                                                                  mipmapped:NO];
        td.usage = MTLTextureUsageRenderTarget;
        id<MTLTexture> tex = [dev newTextureWithDescriptor:td];
        if (!tex) return;
        MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
        rpd.colorAttachments[0].texture = tex;
        rpd.colorAttachments[0].loadAction = MTLLoadActionDontCare;
        rpd.colorAttachments[0].storeAction = MTLStoreActionDontCare;
        id<MTLCommandBuffer> cb = [q commandBuffer];
        id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rpd];
        if (!enc) return;
        Class encCls = object_getClass(enc);
        [enc endEncoding];
        SEL sel = @selector(setFragmentBytes:length:atIndex:);
        Method m = class_getInstanceMethod(encCls, sel);
        if (m) {
            gOrigMTLSetFragmentBytes = method_setImplementation(m, (IMP)AMHook_mtlSetFragmentBytes);
        }
    });
}

// --- Puppet Persistent Store (Documents/AMPuppetData.json) ---

@interface AMPuppetStore : NSObject
+ (instancetype)shared;
- (NSMutableDictionary *)layerDictForSlot:(int)slot create:(BOOL)create elementId:(uint64_t)elementId;
- (NSMutableDictionary *)layerDictForElementId:(uint64_t)elementId;
- (int)slotForElementId:(uint64_t)elementId;
- (void)bindSlot:(int)slot toElementId:(uint64_t)elementId startTimeMs:(int64_t)startMs endTimeMs:(int64_t)endMs;
- (void)syncAllToRuntime;
- (void)save;
@end

@implementation AMPuppetStore {
    NSMutableDictionary<NSString *, NSMutableDictionary *> *_slots; // "1".."16" -> layer dict
}

+ (instancetype)shared {
    static AMPuppetStore *inst = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        inst = [[AMPuppetStore alloc] init];
    });
    return inst;
}

- (NSString *)storePath {
    NSArray<NSString *> *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    return [docs.firstObject stringByAppendingPathComponent:@"AMPuppetData.json"];
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _slots = [NSMutableDictionary dictionary];
        [self loadFromDisk];
        [self syncAllToRuntime];
    }
    return self;
}

- (void)loadFromDisk {
    NSData *data = [NSData dataWithContentsOfFile:[self storePath]];
    if (!data) return;
    id obj = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:nil];
    if ([obj isKindOfClass:[NSDictionary class]]) {
        NSDictionary *root = (NSDictionary *)obj;
        NSDictionary *slots = root[@"slots"];
        if ([slots isKindOfClass:[NSDictionary class]]) {
            for (NSString *k in slots) {
                if ([slots[k] isKindOfClass:[NSMutableDictionary class]]) {
                    _slots[k] = slots[k];
                } else if ([slots[k] isKindOfClass:[NSDictionary class]]) {
                    _slots[k] = [slots[k] mutableCopy];
                }
            }
        }
    }
}

- (void)save {
    [self syncAllToRuntime];
    NSDictionary *root = @{@"version": @1, @"slots": _slots ?: @{}};
    NSData *data = [NSJSONSerialization dataWithJSONObject:root options:0 error:nil];
    if (data) {
        [data writeToFile:[self storePath] atomically:YES];
    }
}

- (NSMutableDictionary *)layerDictForSlot:(int)slot create:(BOOL)create elementId:(uint64_t)elementId {
    if (slot < 1 || slot > kAMPuppetMaxSlots) return nil;
    NSString *key = [NSString stringWithFormat:@"%d", slot];
    NSMutableDictionary *d = _slots[key];
    if (!d && create) {
        d = [NSMutableDictionary dictionaryWithDictionary:@{
            @"slot": @(slot),
            @"elementId": @(elementId),
            @"startTimeMs": @(0),
            @"endTimeMs": @(5000),
            @"rigidity": @(1.5),
            @"deformMode": @(0),
            @"showMesh": @(YES),
            @"nextPinId": @(1),
            @"pins": [NSMutableArray array]
        }];
        _slots[key] = d;
    }
    return d;
}

- (NSMutableDictionary *)layerDictForElementId:(uint64_t)elementId {
    if (elementId == 0) return nil;
    for (int s = 1; s <= kAMPuppetMaxSlots; ++s) {
        NSMutableDictionary *d = _slots[[NSString stringWithFormat:@"%d", s]];
        if (d && [d[@"elementId"] unsignedLongLongValue] == elementId) {
            return d;
        }
    }
    return nil;
}

- (int)slotForElementId:(uint64_t)elementId {
    NSMutableDictionary *d = [self layerDictForElementId:elementId];
    return d ? [d[@"slot"] intValue] : 0;
}

- (void)bindSlot:(int)slot toElementId:(uint64_t)elementId startTimeMs:(int64_t)startMs endTimeMs:(int64_t)endMs {
    NSMutableDictionary *d = [self layerDictForSlot:slot create:YES elementId:elementId];
    if (!d) return;
    d[@"slot"] = @(slot);
    d[@"elementId"] = @(elementId);
    if (startMs >= 0) d[@"startTimeMs"] = @(startMs);
    if (endMs > startMs) d[@"endTimeMs"] = @(endMs);
    if (![d[@"pins"] isKindOfClass:[NSMutableArray class]]) {
        d[@"pins"] = d[@"pins"] ? [d[@"pins"] mutableCopy] : [NSMutableArray array];
    }
    [self save];
}

- (void)syncAllToRuntime {
    os_unfair_lock_lock(&gAMPuppetRuntimeLock);
    for (int s = 1; s <= kAMPuppetMaxSlots; ++s) {
        AMPuppetSlotRuntime *rt = &gAMPuppetSlots[s];
        memset(rt, 0, sizeof(*rt));
        NSDictionary *d = _slots[[NSString stringWithFormat:@"%d", s]];
        if (!d) continue;
        rt->active = YES;
        rt->elementId = [d[@"elementId"] unsignedLongLongValue];
        rt->startTimeMs = [d[@"startTimeMs"] longLongValue];
        rt->endTimeMs = [d[@"endTimeMs"] longLongValue];
        rt->rigidity = [d[@"rigidity"] floatValue];
        if (rt->rigidity < 0.5f || rt->rigidity > 4.0f) rt->rigidity = 1.5f;
        rt->deformMode = [d[@"deformMode"] intValue];
        rt->showMesh = [d[@"showMesh"] boolValue];
        NSArray *pins = [d[@"pins"] isKindOfClass:[NSArray class]] ? d[@"pins"] : @[];
        int pn = (int)pins.count;
        if (pn > kAMPuppetMaxPins) pn = kAMPuppetMaxPins;
        rt->pinCount = pn;
        for (int i = 0; i < pn; ++i) {
            NSDictionary *pd = pins[i];
            AMPuppetPinC *pc = &rt->pins[i];
            pc->pinId = [pd[@"id"] intValue];
            pc->restX = [pd[@"restX"] floatValue];
            pc->restY = [pd[@"restY"] floatValue];
            pc->currX = [pd[@"currX"] floatValue];
            pc->currY = [pd[@"currY"] floatValue];
            NSArray *kfs = [pd[@"keyframes"] isKindOfClass:[NSArray class]] ? pd[@"keyframes"] : @[];
            int kn = (int)kfs.count;
            if (kn > kAMPuppetMaxKeyframesPerPin) kn = kAMPuppetMaxKeyframesPerPin;
            pc->keyframeCount = kn;
            for (int k = 0; k < kn; ++k) {
                NSDictionary *kd = kfs[k];
                AMPuppetKeyframeC *kc = &pc->keyframes[k];
                kc->timeMs = [kd[@"t"] longLongValue];
                kc->x = [kd[@"x"] floatValue];
                kc->y = [kd[@"y"] floatValue];
                kc->easingType = [kd[@"easingType"] intValue];
                kc->p1x = kd[@"p1x"] ? [kd[@"p1x"] floatValue] : 0.42f;
                kc->p1y = kd[@"p1y"] ? [kd[@"p1y"] floatValue] : 0.0f;
                kc->p2x = kd[@"p2x"] ? [kd[@"p2x"] floatValue] : 0.58f;
                kc->p2y = kd[@"p2y"] ? [kd[@"p2y"] floatValue] : 1.0f;
                kc->stepCount = kd[@"stepCount"] ? [kd[@"stepCount"] floatValue] : 4.0f;
            }
        }
    }
    os_unfair_lock_unlock(&gAMPuppetRuntimeLock);
}

@end

// --- Native Swift SceneElement Effect Attachment & Playhead Seek Helpers ---

typedef struct {
    uint64_t targetElementId;
    int assignedSlot;
    int64_t startTimeMs;
    int64_t endTimeMs;
    BOOL shouldAttachIfMissing;
    BOOL didAttach;
} AMPuppetAttachCtx;

static AMPuppetAttachCtx gAMPuppetAttachCtx;

static int AMPuppetMatchSlotFromSwiftString(uint64_t strLo, uint64_t strHi, intptr_t slide) {
    typedef uint8_t (*AMStrEqFn)(uint64_t, uint64_t, uint64_t, uint64_t, uint8_t);
    AMStrEqFn strEq = (AMStrEqFn)(0x1025b7bb8ULL + slide);
    static AMSwiftString slotStrs[kAMPuppetMaxSlots + 1];
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        for (int s = 1; s <= kAMPuppetMaxSlots; ++s) {
            slotStrs[s] = AMMakeSwiftString(AMPuppetEffectIdForSlot(s));
        }
    });
    for (int s = 1; s <= kAMPuppetMaxSlots; ++s) {
        if (strLo == slotStrs[s].lo && strHi == slotStrs[s].hi) return s;
        if (strEq && (strEq(strLo, strHi, slotStrs[s].lo, slotStrs[s].hi, 0) & 1)) return s;
    }
    return 0;
}

static void AMPuppetAttachEditCallback(void *scenePtr) {
    if (!scenePtr || gAMPuppetAttachCtx.targetElementId == 0) return;
    intptr_t slide = AMMainBinarySlide();

    typedef void *(*MetaFn)(uintptr_t);
    typedef void (*DestroyFn)(void *, void *);
    typedef void *(*BridgeRetainFn)(void *);

    void *sceneMeta = ((MetaFn)(0x1003c6b10ULL + slide))(0);
    void *elMeta = ((MetaFn)(0x1003e0404ULL + slide))(0);
    void *efMeta = ((MetaFn)(0x100459f90ULL + slide))(0);
    if (!sceneMeta || !elMeta || !efMeta) return;

    int32_t elementsOff = *(int32_t *)((uint8_t *)sceneMeta + 0x1c);
    void *elVWT = *(void **)((uint8_t *)elMeta - 8);
    uint8_t elAlignMask = *(uint8_t *)((uint8_t *)elVWT + 0x50);
    size_t elStride = *(size_t *)((uint8_t *)elVWT + 0x48);
    int32_t startOff = *(int32_t *)((uint8_t *)elMeta + 0x14);
    int32_t endOff = *(int32_t *)((uint8_t *)elMeta + 0x18);
    int32_t vfxOff = *(int32_t *)((uint8_t *)elMeta + 0x78);

    void *efVWT = *(void **)((uint8_t *)efMeta - 8);
    uint8_t efAlignMask = *(uint8_t *)((uint8_t *)efVWT + 0x50);
    size_t efSize = *(size_t *)((uint8_t *)efVWT + 0x40);
    size_t efStride = *(size_t *)((uint8_t *)efVWT + 0x48);
    int32_t efIdOff = *(int32_t *)((uint8_t *)efMeta + 0x14);
    int32_t efParamsOff = *(int32_t *)((uint8_t *)efMeta + 0x18);
    int32_t efRenderGroupOff = *(int32_t *)((uint8_t *)efMeta + 0x1c);
    int32_t efDisabledOff = *(int32_t *)((uint8_t *)efMeta + 0x20);
    int32_t efLocalOff = *(int32_t *)((uint8_t *)efMeta + 0x24);
    int32_t efHiddenOff = *(int32_t *)((uint8_t *)efMeta + 0x28);

    void *makeUnique = dlsym(RTLD_DEFAULT, "$sSa36_makeUniqueAndReserveCapacityIfNotUniqueyyF");
    void **elementsField = (void **)((uint8_t *)scenePtr + elementsOff);
    if (makeUnique && *elementsField) {
        struct { uint64_t selfPtr, metaPtr, fnPtr; } uArgs = {
            (uint64_t)elementsField, (uint64_t)elMeta, (uint64_t)makeUnique
        };
        __asm__ volatile(
            "mov x9, %0\n"
            "ldr x20, [x9, #0]\n"
            "ldr x0,  [x9, #8]\n"
            "ldr x16, [x9, #16]\n"
            "blr x16\n"
            :
            : "r"(&uArgs)
            : "x0", "x1", "x2", "x3", "x4", "x5", "x6", "x7",
              "x8", "x9", "x10", "x11", "x12", "x13", "x14", "x15",
              "x16", "x17", "x20", "x30", "memory"
        );
    }

    void *arrStorage = *elementsField;
    if (!arrStorage) return;
    int64_t count = *(int64_t *)((uint8_t *)arrStorage + 0x10);
    size_t elHdrOff = (0x20 + (size_t)elAlignMask) & ~(size_t)elAlignMask;
    uint8_t *basePtr = (uint8_t *)arrStorage + elHdrOff;
    size_t efHdrOff = (0x20 + (size_t)efAlignMask) & ~(size_t)efAlignMask;

    BOOL usedSlots[kAMPuppetMaxSlots + 1];
    memset(usedSlots, 0, sizeof(usedSlots));
    uint8_t *targetEl = NULL;
    int existingSlot = 0;

    for (int64_t i = 0; i < count; ++i) {
        uint8_t *elPtr = basePtr + (size_t)i * elStride;
        uint64_t eid = *(uint64_t *)(elPtr + 0x18);
        void *vfxArr = *(void **)(elPtr + vfxOff);
        if (vfxArr) {
            int64_t vcnt = *(int64_t *)((uint8_t *)vfxArr + 0x10);
            if (vcnt > 0 && vcnt < 256) {
                uint8_t *efBase = (uint8_t *)vfxArr + efHdrOff;
                for (int64_t j = 0; j < vcnt; ++j) {
                    uint8_t *efPtr = efBase + (size_t)j * efStride;
                    uint64_t slo = *(uint64_t *)(efPtr + efIdOff);
                    uint64_t shi = *(uint64_t *)(efPtr + efIdOff + 8);
                    int matched = AMPuppetMatchSlotFromSwiftString(slo, shi, slide);
                    if (matched >= 1 && matched <= kAMPuppetMaxSlots) {
                        usedSlots[matched] = YES;
                        if (eid == gAMPuppetAttachCtx.targetElementId && existingSlot == 0) {
                            existingSlot = matched;
                        }
                    }
                }
            }
        }
        if (eid == gAMPuppetAttachCtx.targetElementId) {
            targetEl = elPtr;
        }
    }

    if (!targetEl) return;
    gAMPuppetAttachCtx.startTimeMs = *(int64_t *)(targetEl + startOff);
    gAMPuppetAttachCtx.endTimeMs = *(int64_t *)(targetEl + endOff);

    if (existingSlot > 0) {
        gAMPuppetAttachCtx.assignedSlot = existingSlot;
        return;
    }
    if (!gAMPuppetAttachCtx.shouldAttachIfMissing) return;

    // Pick preferred slot from store if unused, otherwise first unused slot 1..16
    int chosenSlot = [[AMPuppetStore shared] slotForElementId:gAMPuppetAttachCtx.targetElementId];
    if (chosenSlot < 1 || chosenSlot > kAMPuppetMaxSlots || usedSlots[chosenSlot]) {
        chosenSlot = 0;
        for (int s = 1; s <= kAMPuppetMaxSlots; ++s) {
            if (!usedSlots[s]) { chosenSlot = s; break; }
        }
    }
    if (chosenSlot == 0) chosenSlot = 1;

    // Construct KeyableVisualEffectRef cleanly and append via Alight Motion's native 0x1006e89dc!
    void *emptyDict = dlsym(RTLD_DEFAULT, "_swiftEmptyDictionarySingleton");
    void *emptySet = dlsym(RTLD_DEFAULT, "_swiftEmptySetSingleton");
    if (!emptyDict || !emptySet) return;
    BridgeRetainFn bridgeRetain = (BridgeRetainFn)(0x1025bb41cULL + slide);

    uint8_t *efBuf = (uint8_t *)calloc(1, efSize + 32);
    if (!efBuf) return;

    // 1. instanceId: UUID v4 (16 bytes at +0x00)
    arc4random_buf(efBuf, 16);
    efBuf[6] = (efBuf[6] & 0x0F) | 0x40;
    efBuf[8] = (efBuf[8] & 0x3F) | 0x80;

    // 2. id: Swift String
    AMSwiftString idStr = AMMakeSwiftString(AMPuppetEffectIdForSlot(chosenSlot));
    *(uint64_t *)(efBuf + efIdOff) = idStr.lo;
    *(uint64_t *)(efBuf + efIdOff + 8) = idStr.hi;

    // 3. parameters: empty Swift Dictionary
    bridgeRetain(emptyDict);
    *(void **)(efBuf + efParamsOff) = emptyDict;

    // 4. renderGroup: 0
    *(int64_t *)(efBuf + efRenderGroupOff) = 0;

    // 5. disabledRenderGroups: empty Swift Set
    bridgeRetain(emptySet);
    *(void **)(efBuf + efDisabledOff) = emptySet;

    // 6. isLocallyApplied = true, hidden = false
    *(uint8_t *)(efBuf + efLocalOff) = 1;
    *(uint8_t *)(efBuf + efHiddenOff) = 0;

    // Append using native 0x1006e89dc(x0 = inout SceneElement *, x5 = const KeyableVisualEffectRef *)
    uintptr_t addEfAddr = (uintptr_t)(0x1006e89dcULL + slide);
    struct { uint64_t elPtr, efPtr, fn; } aeArgs = {
        (uint64_t)targetEl, (uint64_t)efBuf, (uint64_t)addEfAddr
    };
    __asm__ volatile(
        "mov x9, %0\n"
        "ldr x0,  [x9, #0]\n"
        "mov x1,  #0\n"
        "mov x2,  #0\n"
        "mov x3,  #0\n"
        "mov x4,  #0\n"
        "ldr x5,  [x9, #8]\n"
        "ldr x16, [x9, #16]\n"
        "blr x16\n"
        :
        : "r"(&aeArgs)
        : "x0", "x1", "x2", "x3", "x4", "x5", "x6", "x7",
          "x8", "x9", "x10", "x11", "x12", "x13", "x14", "x15",
          "x16", "x17", "x20", "x30", "memory",
          "v0", "v1", "v2", "v3", "v4", "v5", "v6", "v7"
    );

    // Destroy our temporary efBuf (0x1006e89dc copied it via initializeWithCopy)
    ((DestroyFn)(0x1000199c0ULL + slide))(efBuf, (void *)(0x100459f90ULL + slide));
    free(efBuf);

    gAMPuppetAttachCtx.assignedSlot = chosenSlot;
    gAMPuppetAttachCtx.didAttach = YES;
}

static int AMPuppetSyncOrAttachEffect(void *holder, uint64_t elementId, BOOL attachIfMissing, int64_t *outStartMs, int64_t *outEndMs) {
    if (!holder || elementId == 0) return 0;
    intptr_t slide = AMMainBinarySlide();

    memset(&gAMPuppetAttachCtx, 0, sizeof(gAMPuppetAttachCtx));
    gAMPuppetAttachCtx.targetElementId = elementId;
    gAMPuppetAttachCtx.shouldAttachIfMissing = attachIfMissing;

    struct { uint64_t cb, holderPtr, fn; } peArgs = {
        (uint64_t)AMPuppetAttachEditCallback, (uint64_t)holder, (uint64_t)(0x100392588ULL + slide)
    };
    __asm__ volatile(
        "mov x9, %0\n"
        "mov w0, #4\n"
        "mov x1, #0\n"
        "mov w2, #2\n"
        "ldr x3,  [x9, #0]\n"
        "mov x4, #0\n"
        "ldr x20, [x9, #8]\n"
        "ldr x16, [x9, #16]\n"
        "blr x16\n"
        :
        : "r"(&peArgs)
        : "x0", "x1", "x2", "x3", "x4", "x5", "x6", "x7",
          "x8", "x9", "x10", "x11", "x12", "x13", "x14", "x15",
          "x16", "x17", "x20", "x30", "memory",
          "v0", "v1", "v2", "v3", "v4", "v5", "v6", "v7"
    );

    if (outStartMs) *outStartMs = gAMPuppetAttachCtx.startTimeMs;
    if (outEndMs) *outEndMs = gAMPuppetAttachCtx.endTimeMs;
    int slot = gAMPuppetAttachCtx.assignedSlot;
    if (slot >= 1 && slot <= kAMPuppetMaxSlots) {
        [[AMPuppetStore shared] bindSlot:slot
                             toElementId:elementId
                             startTimeMs:gAMPuppetAttachCtx.startTimeMs
                               endTimeMs:gAMPuppetAttachCtx.endTimeMs];
    }
    return slot;
}

static void AMPuppetSeekHolderToTimeMs(void *holder, int64_t timeMs) {
    if (!holder) return;
    if (timeMs < 0) timeMs = 0;
    intptr_t slide = AMMainBinarySlide();
    ptrdiff_t flagOff = *(ptrdiff_t *)(0x1033e54d8ULL + slide);
    ptrdiff_t timeOff = *(ptrdiff_t *)(0x1033e5508ULL + slide);
    uint8_t *h = (uint8_t *)holder;
    *(uint8_t *)(h + flagOff) = 1;
    *(int64_t *)(h + timeOff) = timeMs;

    AMSwiftRetain(holder, slide);
    struct { uint64_t hPtr, fn; } sArgs = {
        (uint64_t)holder, (uint64_t)(0x100395650ULL + slide)
    };
    __asm__ volatile(
        "mov x9, %0\n"
        "ldr x20, [x9, #0]\n"
        "ldr x16, [x9, #8]\n"
        "blr x16\n"
        :
        : "r"(&sArgs)
        : "x0", "x1", "x2", "x3", "x4", "x5", "x6", "x7",
          "x8", "x9", "x10", "x11", "x12", "x13", "x14", "x15",
          "x16", "x17", "x20", "x30", "memory",
          "v0", "v1", "v2", "v3", "v4", "v5", "v6", "v7"
    );

    // Notify time observers (updates timeline playhead & AVPlayer)
    ptrdiff_t obsOff = *(ptrdiff_t *)(0x103332370ULL + slide);
    void *obsArr = *(void **)(h + obsOff);
    if (obsArr && (((uintptr_t)obsArr >> 62) == 0)) {
        int64_t cnt = *(int64_t *)((uint8_t *)obsArr + 0x10);
        if (cnt > 0 && cnt < 64) {
            typedef void *(*WeakLoadObjFn)(void *);
            WeakLoadObjFn weakLoad = (WeakLoadObjFn)(0x1025bb9ecULL + slide);
            uintptr_t notifyFn = (uintptr_t)(0x10021c7dcULL + slide);
            for (int64_t i = 0; i < cnt; ++i) {
                void *box = *(void **)((uint8_t *)obsArr + 0x20 + i * 8);
                if (!box) continue;
                void *obs = weakLoad((uint8_t *)box + 0x10);
                if (!obs) continue;
                struct { uint64_t t, o, fn; } nArgs = { (uint64_t)timeMs, (uint64_t)obs, (uint64_t)notifyFn };
                __asm__ volatile(
                    "mov x9, %0\n"
                    "ldr x0,  [x9, #0]\n"
                    "ldr x20, [x9, #8]\n"
                    "ldr x16, [x9, #16]\n"
                    "blr x16\n"
                    :
                    : "r"(&nArgs)
                    : "x0", "x1", "x2", "x3", "x4", "x5", "x6", "x7",
                      "x8", "x9", "x10", "x11", "x12", "x13", "x14", "x15",
                      "x16", "x17", "x20", "x30", "memory"
                );
                AMSwiftRelease(obs, slide);
            }
        }
    }
    AMSwiftRelease(holder, slide);

    AVPlayer *player = gActivePreviewPlayer;
    if (player) {
        [player seekToTime:CMTimeMake(timeMs, 1000) toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero];
    }
}

static void AMRedrawAllKeyframeViewsInView(UIView *v, Class kfCls) {
    if (!v) return;
    if ([v isKindOfClass:kfCls]) {
        [v setNeedsDisplay];
    }
    for (UIView *sub in v.subviews) {
        AMRedrawAllKeyframeViewsInView(sub, kfCls);
    }
}

static void AMPuppetRedrawAllKeyframeViews(void) {
    Class kfCls = NSClassFromString(@"_TtC12AlightMotion12KeyframeView");
    if (!kfCls) return;
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if ([scene isKindOfClass:[UIWindowScene class]]) {
            for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                AMRedrawAllKeyframeViewsInView(w, kfCls);
            }
        }
    }
}

static UIView *AMFindProjectPreviewViewInView(UIView *v, Class cls) {
    if (!v) return nil;
    if ([v isKindOfClass:cls]) return v;
    for (UIView *sub in v.subviews) {
        UIView *found = AMFindProjectPreviewViewInView(sub, cls);
        if (found) return found;
    }
    return nil;
}

static UIView *AMPuppetFindProjectPreviewView(UIView *anchorView) {
    Class pvCls = NSClassFromString(@"_TtC12AlightMotion18ProjectPreviewView");
    if (!pvCls) return nil;
    if (anchorView.window) {
        UIView *found = AMFindProjectPreviewViewInView(anchorView.window, pvCls);
        if (found) return found;
    }
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if ([scene isKindOfClass:[UIWindowScene class]]) {
            for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                if (w.hidden) continue;
                UIView *found = AMFindProjectPreviewViewInView(w, pvCls);
                if (found) return found;
            }
        }
    }
    return nil;
}

// --- Custom Crisp Alight Motion Vector Icons ---

static UIImage *AMPuppetTabIcon(void) {
    static UIImage *img = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        CGSize sz = CGSizeMake(28.0, 28.0);
        UIGraphicsBeginImageContextWithOptions(sz, NO, 0.0);
        CGContextRef ctx = UIGraphicsGetCurrentContext();
        [[UIColor whiteColor] setStroke];
        [[UIColor whiteColor] setFill];
        CGContextSetLineWidth(ctx, 1.7);
        CGContextSetLineCap(ctx, kCGLineCapRound);
        CGContextSetLineJoin(ctx, kCGLineJoinRound);

        // Subtle curved mesh arcs beneath the pushpin (iconic AE Puppet Pin look, native AM stroke weight)
        UIBezierPath *mesh = [UIBezierPath bezierPath];
        [mesh moveToPoint:CGPointMake(3.5, 22.5)];
        [mesh addQuadCurveToPoint:CGPointMake(24.5, 22.5) controlPoint:CGPointMake(14.0, 17.5)];
        [mesh moveToPoint:CGPointMake(6.0, 25.0)];
        [mesh addQuadCurveToPoint:CGPointMake(22.0, 25.0) controlPoint:CGPointMake(14.0, 21.5)];
        mesh.lineWidth = 1.4;
        [mesh stroke];

        // Tilted Puppet Pushpin (head, neck, collar, needle touching mesh apex)
        UIBezierPath *pinHead = [UIBezierPath bezierPath];
        [pinHead moveToPoint:CGPointMake(15.5, 4.0)];
        [pinHead addLineToPoint:CGPointMake(22.0, 10.5)];
        [pinHead addLineToPoint:CGPointMake(19.5, 13.0)];
        [pinHead addLineToPoint:CGPointMake(17.5, 11.5)];
        [pinHead addLineToPoint:CGPointMake(15.0, 14.0)];
        [pinHead addLineToPoint:CGPointMake(16.8, 15.8)];
        [pinHead addLineToPoint:CGPointMake(14.5, 18.0)];
        [pinHead addLineToPoint:CGPointMake(8.0, 11.5)];
        [pinHead addLineToPoint:CGPointMake(10.2, 9.2)];
        [pinHead addLineToPoint:CGPointMake(12.0, 11.0)];
        [pinHead addLineToPoint:CGPointMake(14.5, 8.5)];
        [pinHead addLineToPoint:CGPointMake(13.0, 6.5)];
        [pinHead closePath];
        pinHead.lineWidth = 1.65;
        [pinHead stroke];

        // Needle down to anchor point
        UIBezierPath *needle = [UIBezierPath bezierPath];
        [needle moveToPoint:CGPointMake(11.2, 14.8)];
        [needle addLineToPoint:CGPointMake(7.2, 19.6)];
        needle.lineWidth = 1.8;
        [needle stroke];

        // Anchor pin dot
        UIBezierPath *dot = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(5.3, 18.0, 3.6, 3.6)];
        [dot fill];

        img = [UIGraphicsGetImageFromCurrentImageContext() imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
        UIGraphicsEndImageContext();
    });
    return img;
}

static UIImage *AMPuppetDiamondIcon(BOOL filled) {
    CGSize sz = CGSizeMake(22.0, 22.0);
    UIGraphicsBeginImageContextWithOptions(sz, NO, 0.0);
    UIBezierPath *p = [UIBezierPath bezierPath];
    [p moveToPoint:CGPointMake(11.0, 3.0)];
    [p addLineToPoint:CGPointMake(19.0, 11.0)];
    [p addLineToPoint:CGPointMake(11.0, 19.0)];
    [p addLineToPoint:CGPointMake(3.0, 11.0)];
    [p closePath];
    p.lineWidth = 1.8;
    if (filled) {
        [[UIColor whiteColor] setFill];
        [p fill];
    } else {
        [[UIColor whiteColor] setStroke];
        [p stroke];
        UIBezierPath *plus = [UIBezierPath bezierPath];
        [plus moveToPoint:CGPointMake(8.0, 11.0)];
        [plus addLineToPoint:CGPointMake(14.0, 11.0)];
        [plus moveToPoint:CGPointMake(11.0, 8.0)];
        [plus addLineToPoint:CGPointMake(11.0, 14.0)];
        plus.lineWidth = 1.6;
        [plus stroke];
    }
    UIImage *res = [UIGraphicsGetImageFromCurrentImageContext() imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    UIGraphicsEndImageContext();
    return res;
}

// --- Matrix Helpers (row-vector * column-major Metal float4x4) ---

static CGPoint AMPuppetMulRowMat4(CGPoint pt, const float m[16]) {
    float x = (float)pt.x;
    float y = (float)pt.y;
    float ox = x * m[0] + y * m[1] + m[3];
    float oy = x * m[4] + y * m[5] + m[7];
    float ow = x * m[12] + y * m[13] + m[15];
    if (fabsf(ow) > 1e-5f) {
        ox /= ow;
        oy /= ow;
    }
    return CGPointMake(ox, oy);
}

// --- Interactive Canvas Overlay on ProjectPreviewView ---

@protocol AMPuppetCanvasOverlayDelegate <NSObject>
- (void)puppetCanvasDidTapAddPinAtLayerNorm:(CGPoint)layerNorm;
- (void)puppetCanvasDidSelectPinIndex:(NSInteger)pinIndex;
- (void)puppetCanvasDidDragPinIndex:(NSInteger)pinIndex toLayerNorm:(CGPoint)layerNorm ended:(BOOL)ended;
@end

@interface AMPuppetCanvasOverlayView : UIView
@property (nonatomic, weak) id<AMPuppetCanvasOverlayDelegate> delegate;
@property (nonatomic, weak) UIView *previewView;
@property (nonatomic, assign) int slot;
@property (nonatomic, assign) int64_t currentTimeMs;
@property (nonatomic, assign) NSInteger selectedPinIndex;
@property (nonatomic, assign) BOOL addPinMode;
@end

@implementation AMPuppetCanvasOverlayView {
    NSInteger _draggingPinIndex;
    CGPoint _touchStartViewPt;
    BOOL _didMoveDuringDrag;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        self.opaque = NO;
        self.multipleTouchEnabled = YES;
        _draggingPinIndex = -1;
        _selectedPinIndex = -1;
        _addPinMode = YES;
    }
    return self;
}

- (AVPlayerLayer *)hostPlayerLayer {
    UIView *pv = self.previewView;
    if (!pv) return nil;
    if ([pv respondsToSelector:@selector(playerLayer)]) {
        AVPlayerLayer *pl = ((AVPlayerLayer *(*)(id, SEL))objc_msgSend)(pv, @selector(playerLayer));
        if ([pl isKindOfClass:[AVPlayerLayer class]]) return pl;
    }
    for (CALayer *sub in pv.layer.sublayers) {
        if ([sub isKindOfClass:[AVPlayerLayer class]]) return (AVPlayerLayer *)sub;
    }
    return nil;
}

- (BOOL)getTransformSnapshot:(AMPuppetTransformSnapshot *)outSnap {
    if (self.slot < 1 || self.slot > kAMPuppetMaxSlots) return NO;
    os_unfair_lock_lock(&gAMPuppetRuntimeLock);
    *outSnap = gAMPuppetTransforms[self.slot];
    os_unfair_lock_unlock(&gAMPuppetRuntimeLock);
    return outSnap->valid;
}

- (CGPoint)viewPointFromLayerNorm:(CGPoint)ln {
    AVPlayerLayer *pl = [self hostPlayerLayer];
    UIView *pv = self.previewView;
    if (!pl || !pv) return CGPointMake(self.bounds.size.width * ln.x, self.bounds.size.height * (1.0 - ln.y));
    CGRect vr = pl.videoRect;
    if (vr.size.width < 1.0 || vr.size.height < 1.0) vr = pl.bounds;
    if (vr.size.width < 1.0 || vr.size.height < 1.0) return CGPointMake(self.bounds.size.width * ln.x, self.bounds.size.height * (1.0 - ln.y));

    AMPuppetTransformSnapshot snap;
    CGPoint screenUV = ln;
    if ([self getTransformSnapshot:&snap]) {
        screenUV = AMPuppetMulRowMat4(ln, snap.layerToScreen);
    }
    CGPoint ptPL = CGPointMake(vr.origin.x + screenUV.x * vr.size.width,
                               vr.origin.y + (1.0 - screenUV.y) * vr.size.height);
    CGPoint ptPV = [pv.layer convertPoint:ptPL fromLayer:pl];
    return [self convertPoint:ptPV fromView:pv];
}

- (CGPoint)layerNormFromViewPoint:(CGPoint)vp {
    AVPlayerLayer *pl = [self hostPlayerLayer];
    UIView *pv = self.previewView;
    if (!pl || !pv) {
        return CGPointMake(vp.x / fmax(self.bounds.size.width, 1.0),
                           1.0 - vp.y / fmax(self.bounds.size.height, 1.0));
    }
    CGRect vr = pl.videoRect;
    if (vr.size.width < 1.0 || vr.size.height < 1.0) vr = pl.bounds;
    if (vr.size.width < 1.0 || vr.size.height < 1.0) {
        return CGPointMake(vp.x / fmax(self.bounds.size.width, 1.0),
                           1.0 - vp.y / fmax(self.bounds.size.height, 1.0));
    }
    CGPoint ptPV = [pv convertPoint:vp fromView:self];
    CGPoint ptPL = [pl convertPoint:ptPV fromLayer:pv.layer];
    CGPoint screenUV = CGPointMake((ptPL.x - vr.origin.x) / vr.size.width,
                                   1.0 - (ptPL.y - vr.origin.y) / vr.size.height);
    AMPuppetTransformSnapshot snap;
    if ([self getTransformSnapshot:&snap]) {
        return AMPuppetMulRowMat4(screenUV, snap.screenToLayer);
    }
    return screenUV;
}

- (NSInteger)hitTestPinAtViewPoint:(CGPoint)vp {
    if (self.slot < 1 || self.slot > kAMPuppetMaxSlots) return -1;
    AMPuppetSlotRuntime rt;
    os_unfair_lock_lock(&gAMPuppetRuntimeLock);
    rt = gAMPuppetSlots[self.slot];
    os_unfair_lock_unlock(&gAMPuppetRuntimeLock);
    if (!rt.active || rt.pinCount <= 0) return -1;

    NSInteger bestIdx = -1;
    CGFloat bestDist = 28.0; // comfortable finger hit target
    for (int i = 0; i < rt.pinCount; ++i) {
        float cx = rt.pins[i].currX, cy = rt.pins[i].currY;
        AMPuppetEvalPinAtMs(&rt.pins[i], self.currentTimeMs, &cx, &cy);
        CGPoint p = [self viewPointFromLayerNorm:CGPointMake(cx, cy)];
        CGFloat d = hypot(vp.x - p.x, vp.y - p.y);
        if (d < bestDist) {
            bestDist = d;
            bestIdx = i;
        }
    }
    return bestIdx;
}

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (self.hidden || self.alpha < 0.01 || !self.userInteractionEnabled) return nil;
    if (!CGRectContainsPoint(self.bounds, point)) return nil;
    // Let 2+ finger zoom/pan pass through to ProjectPreviewView
    if (event && event.allTouches.count >= 2) return nil;
    // Check if touching a pin OR inside/near the layer bounds in Add Pin mode
    if ([self hitTestPinAtViewPoint:point] >= 0) return self;
    if (self.addPinMode) {
        CGPoint ln = [self layerNormFromViewPoint:point];
        if (ln.x >= -0.25 && ln.x <= 1.25 && ln.y >= -0.25 && ln.y <= 1.25) {
            return self;
        }
    }
    return nil;
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (event.allTouches.count >= 2) {
        _draggingPinIndex = -1;
        [super touchesBegan:touches withEvent:event];
        return;
    }
    UITouch *t = [touches anyObject];
    if (!t) return;
    CGPoint pt = [t locationInView:self];
    _touchStartViewPt = pt;
    _didMoveDuringDrag = NO;

    NSInteger hit = [self hitTestPinAtViewPoint:pt];
    if (hit >= 0) {
        _draggingPinIndex = hit;
        self.selectedPinIndex = hit;
        [self.delegate puppetCanvasDidSelectPinIndex:hit];
        [self setNeedsDisplay];
    } else if (self.addPinMode) {
        CGPoint ln = [self layerNormFromViewPoint:pt];
        if (ln.x >= -0.15 && ln.x <= 1.15 && ln.y >= -0.15 && ln.y <= 1.15) {
            ln.x = fmin(fmax(ln.x, 0.0), 1.0);
            ln.y = fmin(fmax(ln.y, 0.0), 1.0);
            [self.delegate puppetCanvasDidTapAddPinAtLayerNorm:ln];
            // Newly added pin becomes active immediately so user can keep dragging!
            _draggingPinIndex = self.selectedPinIndex;
            [self setNeedsDisplay];
        }
    }
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (event.allTouches.count >= 2 || _draggingPinIndex < 0) return;
    UITouch *t = [touches anyObject];
    if (!t) return;
    CGPoint pt = [t locationInView:self];
    if (!_didMoveDuringDrag && hypot(pt.x - _touchStartViewPt.x, pt.y - _touchStartViewPt.y) < 2.0) {
        return;
    }
    _didMoveDuringDrag = YES;
    CGPoint ln = [self layerNormFromViewPoint:pt];
    ln.x = fmin(fmax(ln.x, -0.5), 1.5);
    ln.y = fmin(fmax(ln.y, -0.5), 1.5);
    [self.delegate puppetCanvasDidDragPinIndex:_draggingPinIndex toLayerNorm:ln ended:NO];
    [self setNeedsDisplay];
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)event;
    if (_draggingPinIndex >= 0 && _didMoveDuringDrag) {
        UITouch *t = [touches anyObject];
        CGPoint pt = t ? [t locationInView:self] : _touchStartViewPt;
        CGPoint ln = [self layerNormFromViewPoint:pt];
        ln.x = fmin(fmax(ln.x, -0.5), 1.5);
        ln.y = fmin(fmax(ln.y, -0.5), 1.5);
        [self.delegate puppetCanvasDidDragPinIndex:_draggingPinIndex toLayerNorm:ln ended:YES];
    }
    _draggingPinIndex = -1;
    _didMoveDuringDrag = NO;
    [self setNeedsDisplay];
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)touches; (void)event;
    _draggingPinIndex = -1;
    _didMoveDuringDrag = NO;
    [self setNeedsDisplay];
}

- (void)drawRect:(CGRect)rect {
    (void)rect;
    if (self.slot < 1 || self.slot > kAMPuppetMaxSlots) return;
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (!ctx) return;

    AMPuppetSlotRuntime rt;
    AMPuppetTransformSnapshot snap;
    os_unfair_lock_lock(&gAMPuppetRuntimeLock);
    rt = gAMPuppetSlots[self.slot];
    snap = gAMPuppetTransforms[self.slot];
    os_unfair_lock_unlock(&gAMPuppetRuntimeLock);

    // 1. Subtle dashed mint border around the target media layer
    if (snap.valid) {
        CGPoint c00 = [self viewPointFromLayerNorm:CGPointMake(0.0, 0.0)];
        CGPoint c10 = [self viewPointFromLayerNorm:CGPointMake(1.0, 0.0)];
        CGPoint c11 = [self viewPointFromLayerNorm:CGPointMake(1.0, 1.0)];
        CGPoint c01 = [self viewPointFromLayerNorm:CGPointMake(0.0, 1.0)];
        CGContextSaveGState(ctx);
        CGFloat dash[] = {5.0, 4.0};
        CGContextSetLineDash(ctx, 0.0, dash, 2);
        CGContextSetLineWidth(ctx, 1.2);
        [[AMAccentGreenColor() colorWithAlphaComponent:0.55] setStroke];
        CGContextMoveToPoint(ctx, c00.x, c00.y);
        CGContextAddLineToPoint(ctx, c10.x, c10.y);
        CGContextAddLineToPoint(ctx, c11.x, c11.y);
        CGContextAddLineToPoint(ctx, c01.x, c01.y);
        CGContextClosePath(ctx);
        CGContextStrokePath(ctx);
        CGContextRestoreGState(ctx);
    }

    if (!rt.active || rt.pinCount <= 0) return;

    // 2. Motion path for the selected pin (AE-style dotted motion trajectory across keyframes)
    if (self.selectedPinIndex >= 0 && self.selectedPinIndex < rt.pinCount) {
        const AMPuppetPinC *selPin = &rt.pins[self.selectedPinIndex];
        if (selPin->keyframeCount >= 2) {
            CGContextSaveGState(ctx);
            [[AMAccentGreenColor() colorWithAlphaComponent:0.75] setStroke];
            CGContextSetLineWidth(ctx, 1.6);
            CGFloat dash[] = {3.0, 3.0};
            CGContextSetLineDash(ctx, 0.0, dash, 2);
            int64_t tStart = selPin->keyframes[0].timeMs;
            int64_t tEnd = selPin->keyframes[selPin->keyframeCount - 1].timeMs;
            int samples = 48;
            for (int s = 0; s <= samples; ++s) {
                int64_t ts = tStart + (int64_t)llround((double)(tEnd - tStart) * ((double)s / (double)samples));
                float px, py;
                AMPuppetEvalPinAtMs(selPin, ts, &px, &py);
                CGPoint vp = [self viewPointFromLayerNorm:CGPointMake(px, py)];
                if (s == 0) CGContextMoveToPoint(ctx, vp.x, vp.y);
                else CGContextAddLineToPoint(ctx, vp.x, vp.y);
            }
            CGContextStrokePath(ctx);

            // Keyframe dots along path
            CGContextSetLineDash(ctx, 0.0, NULL, 0);
            [[UIColor whiteColor] setFill];
            for (int k = 0; k < selPin->keyframeCount; ++k) {
                CGPoint kp = [self viewPointFromLayerNorm:CGPointMake(selPin->keyframes[k].x, selPin->keyframes[k].y)];
                CGContextFillEllipseInRect(ctx, CGRectMake(kp.x - 3.0, kp.y - 3.0, 6.0, 6.0));
            }
            CGContextRestoreGState(ctx);
        }
    }

    // 3. Draw Puppet Pins (AE-style yellow/mint rings + subtle rest-to-current tether)
    NSDictionary *badgeAttrs = @{
        NSFontAttributeName: AMThemeFont(9.5, UIFontWeightBold),
        NSForegroundColorAttributeName: [UIColor whiteColor]
    };

    for (int i = 0; i < rt.pinCount; ++i) {
        const AMPuppetPinC *pin = &rt.pins[i];
        float cx = pin->currX, cy = pin->currY;
        AMPuppetEvalPinAtMs(pin, self.currentTimeMs, &cx, &cy);
        CGPoint vp = [self viewPointFromLayerNorm:CGPointMake(cx, cy)];
        CGPoint rp = [self viewPointFromLayerNorm:CGPointMake(pin->restX, pin->restY)];
        BOOL isSel = (i == self.selectedPinIndex);

        // Faint rest anchor dot + tether line when deformed
        if (hypot(vp.x - rp.x, vp.y - rp.y) > 4.0) {
            CGContextSaveGState(ctx);
            [[UIColor colorWithWhite:1.0 alpha:0.32] setStroke];
            CGContextSetLineWidth(ctx, 1.0);
            CGContextMoveToPoint(ctx, rp.x, rp.y);
            CGContextAddLineToPoint(ctx, vp.x, vp.y);
            CGContextStrokePath(ctx);
            [[UIColor colorWithWhite:1.0 alpha:0.4] setFill];
            CGContextFillEllipseInRect(ctx, CGRectMake(rp.x - 2.5, rp.y - 2.5, 5.0, 5.0));
            CGContextRestoreGState(ctx);
        }

        UIColor *pinColor = isSel ? AMAccentGreenColor() : [UIColor colorWithRed:1.0 green:0.84 blue:0.04 alpha:1.0];
        CGFloat outerR = isSel ? 12.0 : 9.0;
        CGFloat innerR = isSel ? 5.0 : 4.0;

        // Dark contrast halo
        [[UIColor colorWithWhite:0.0 alpha:0.55] setFill];
        CGContextFillEllipseInRect(ctx, CGRectMake(vp.x - outerR - 1.5, vp.y - outerR - 1.5, (outerR + 1.5) * 2.0, (outerR + 1.5) * 2.0));

        // Colored translucent halo
        [[pinColor colorWithAlphaComponent:0.28] setFill];
        CGContextFillEllipseInRect(ctx, CGRectMake(vp.x - outerR, vp.y - outerR, outerR * 2.0, outerR * 2.0));

        // Crisp ring stroke
        [(isSel ? [UIColor whiteColor] : pinColor) setStroke];
        CGContextSetLineWidth(ctx, isSel ? 2.0 : 1.6);
        CGContextStrokeEllipseInRect(ctx, CGRectMake(vp.x - outerR, vp.y - outerR, outerR * 2.0, outerR * 2.0));

        // Center solid pin dot
        [pinColor setFill];
        CGContextFillEllipseInRect(ctx, CGRectMake(vp.x - innerR, vp.y - innerR, innerR * 2.0, innerR * 2.0));

        // Pin number badge
        NSString *numStr = [NSString stringWithFormat:@"%d", i + 1];
        CGSize tsz = [numStr sizeWithAttributes:badgeAttrs];
        CGRect bRect = CGRectMake(vp.x + outerR - 2.0, vp.y - outerR - tsz.height * 0.65, tsz.width + 6.0, tsz.height + 2.0);
        UIBezierPath *bp = [UIBezierPath bezierPathWithRoundedRect:bRect cornerRadius:4.0];
        [[UIColor colorWithRed:0.09 green:0.10 blue:0.15 alpha:0.88] setFill];
        [bp fill];
        [numStr drawAtPoint:CGPointMake(bRect.origin.x + 3.0, bRect.origin.y + 1.0) withAttributes:badgeAttrs];
    }
}

@end

// --- Native Alight Motion Easing Graph Editor for Puppet Pin Segments ---

@interface AMPuppetGraphCanvasView : UIView
@property (nonatomic, assign) int easingType; // 0=Cubic, 1=Step, 2=Elastic, 3=Bounce
@property (nonatomic, assign) float p1x;
@property (nonatomic, assign) float p1y;
@property (nonatomic, assign) float p2x;
@property (nonatomic, assign) float p2y;
@property (nonatomic, assign) float stepCount;
@property (nonatomic, assign) float playheadU; // 0..1 within segment, <0 if outside
@property (nonatomic, assign) BOOL allowOvershoot;
@property (nonatomic, copy) void (^onCurveChanged)(BOOL ended);
@end

@implementation AMPuppetGraphCanvasView {
    int _dragHandle; // 0 = none, 1 = P1, 2 = P2
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = AMInputSurfaceColor();
        self.layer.cornerRadius = 8.0;
        self.clipsToBounds = YES;
        _p1x = 0.42f; _p1y = 0.0f;
        _p2x = 0.58f; _p2y = 1.0f;
        _stepCount = 4.0f;
        _playheadU = -1.0f;
        _allowOvershoot = YES;
    }
    return self;
}

- (CGRect)plotRect {
    CGFloat padX = 18.0;
    CGFloat padY = self.allowOvershoot ? 34.0 : 16.0;
    return CGRectInset(self.bounds, padX, padY);
}

- (CGPoint)ptForNormX:(float)nx y:(float)ny {
    CGRect r = [self plotRect];
    return CGPointMake(r.origin.x + nx * r.size.width,
                       r.origin.y + (1.0f - ny) * r.size.height);
}

- (CGPoint)normForPt:(CGPoint)pt {
    CGRect r = [self plotRect];
    float nx = (float)((pt.x - r.origin.x) / fmax(r.size.width, 1.0));
    float ny = (float)(1.0 - (pt.y - r.origin.y) / fmax(r.size.height, 1.0));
    nx = fminf(fmaxf(nx, 0.0f), 1.0f);
    float yMin = self.allowOvershoot ? -0.55f : 0.0f;
    float yMax = self.allowOvershoot ? 1.55f : 1.0f;
    ny = fminf(fmaxf(ny, yMin), yMax);
    return CGPointMake(nx, ny);
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)event;
    if (self.easingType != 0 && self.easingType != 2) return;
    UITouch *t = [touches anyObject];
    if (!t) return;
    CGPoint pt = [t locationInView:self];
    CGPoint h1 = [self ptForNormX:self.p1x y:self.p1y];
    CGPoint h2 = [self ptForNormX:self.p2x y:self.p2y];
    CGFloat d1 = hypot(pt.x - h1.x, pt.y - h1.y);
    CGFloat d2 = hypot(pt.x - h2.x, pt.y - h2.y);
    if (d1 <= 32.0 && d1 <= d2) _dragHandle = 1;
    else if (d2 <= 32.0) _dragHandle = 2;
    else _dragHandle = (d1 < d2) ? 1 : 2;
    [self updateHandleFromPoint:pt ended:NO];
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)event;
    if (_dragHandle == 0) return;
    UITouch *t = [touches anyObject];
    if (!t) return;
    [self updateHandleFromPoint:[t locationInView:self] ended:NO];
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)event;
    if (_dragHandle == 0) return;
    UITouch *t = [touches anyObject];
    if (t) [self updateHandleFromPoint:[t locationInView:self] ended:YES];
    _dragHandle = 0;
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)touches; (void)event;
    _dragHandle = 0;
}

- (void)updateHandleFromPoint:(CGPoint)pt ended:(BOOL)ended {
    CGPoint n = [self normForPt:pt];
    if (_dragHandle == 1) {
        self.p1x = (float)n.x;
        self.p1y = (float)n.y;
    } else if (_dragHandle == 2) {
        self.p2x = (float)n.x;
        self.p2y = (float)n.y;
    }
    [self setNeedsDisplay];
    if (self.onCurveChanged) self.onCurveChanged(ended);
}

- (void)drawRect:(CGRect)rect {
    (void)rect;
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (!ctx) return;
    CGRect r = [self plotRect];

    // Gridlines (4x4 matching Alight Motion EasingGraphView)
    [[UIColor colorWithWhite:1.0 alpha:0.08] setStroke];
    CGContextSetLineWidth(ctx, 1.0);
    for (int i = 0; i <= 4; ++i) {
        CGFloat f = (CGFloat)i / 4.0;
        CGFloat x = r.origin.x + f * r.size.width;
        CGFloat y = r.origin.y + f * r.size.height;
        CGContextMoveToPoint(ctx, x, self.bounds.origin.y);
        CGContextAddLineToPoint(ctx, x, CGRectGetMaxY(self.bounds));
        CGContextMoveToPoint(ctx, r.origin.x, y);
        CGContextAddLineToPoint(ctx, CGRectGetMaxX(r), y);
    }
    CGContextStrokePath(ctx);

    // Dashed y=0 and y=1 overshoot bounds
    CGContextSaveGState(ctx);
    CGFloat dash[] = {4.0, 4.0};
    CGContextSetLineDash(ctx, 0.0, dash, 2);
    [[UIColor colorWithWhite:1.0 alpha:0.25] setStroke];
    CGContextMoveToPoint(ctx, r.origin.x, r.origin.y);
    CGContextAddLineToPoint(ctx, CGRectGetMaxX(r), r.origin.y);
    CGContextMoveToPoint(ctx, r.origin.x, CGRectGetMaxY(r));
    CGContextAddLineToPoint(ctx, CGRectGetMaxX(r), CGRectGetMaxY(r));
    CGContextStrokePath(ctx);
    CGContextRestoreGState(ctx);

    // Vertical playhead progress guide
    if (self.playheadU >= 0.0f && self.playheadU <= 1.0f) {
        CGFloat px = r.origin.x + self.playheadU * r.size.width;
        CGContextSaveGState(ctx);
        CGFloat pdash[] = {3.0, 3.0};
        CGContextSetLineDash(ctx, 0.0, pdash, 2);
        [[AMAccentGreenColor() colorWithAlphaComponent:0.85] setStroke];
        CGContextSetLineWidth(ctx, 1.4);
        CGContextMoveToPoint(ctx, px, 0.0);
        CGContextAddLineToPoint(ctx, px, self.bounds.size.height);
        CGContextStrokePath(ctx);
        CGContextRestoreGState(ctx);
    }

    // Easing Curve
    CGContextSaveGState(ctx);
    [[UIColor whiteColor] setStroke];
    CGContextSetLineWidth(ctx, 2.4);
    CGContextSetLineCap(ctx, kCGLineCapRound);
    CGContextSetLineJoin(ctx, kCGLineJoinRound);
    int steps = 72;
    for (int i = 0; i <= steps; ++i) {
        float u = (float)i / (float)steps;
        float e = AMPuppetEvalEasing(self.easingType, self.p1x, self.p1y, self.p2x, self.p2y, self.stepCount, u);
        CGPoint p = [self ptForNormX:u y:e];
        if (i == 0) CGContextMoveToPoint(ctx, p.x, p.y);
        else CGContextAddLineToPoint(ctx, p.x, p.y);
    }
    CGContextStrokePath(ctx);
    CGContextRestoreGState(ctx);

    // Endpoints (mint green like Alight Motion EasingGraphView)
    CGPoint p0 = [self ptForNormX:0.0f y:0.0f];
    CGPoint p3 = [self ptForNormX:1.0f y:1.0f];
    [AMAccentGreenColor() setFill];
    CGContextFillEllipseInRect(ctx, CGRectMake(p0.x - 4.5, p0.y - 4.5, 9.0, 9.0));
    CGContextFillEllipseInRect(ctx, CGRectMake(p3.x - 4.5, p3.y - 4.5, 9.0, 9.0));

    // Draggable P1/P2 Tangent Handles (for Cubic Bezier & Elastic modes)
    if (self.easingType == 0 || self.easingType == 2) {
        CGPoint h1 = [self ptForNormX:self.p1x y:self.p1y];
        CGPoint h2 = [self ptForNormX:self.p2x y:self.p2y];

        [[AMAccentGreenColor() colorWithAlphaComponent:0.85] setStroke];
        CGContextSetLineWidth(ctx, 1.6);
        CGContextMoveToPoint(ctx, p0.x, p0.y);
        CGContextAddLineToPoint(ctx, h1.x, h1.y);
        CGContextMoveToPoint(ctx, p3.x, p3.y);
        CGContextAddLineToPoint(ctx, h2.x, h2.y);
        CGContextStrokePath(ctx);

        for (int h = 1; h <= 2; ++h) {
            CGPoint hp = (h == 1) ? h1 : h2;
            BOOL active = (_dragHandle == h);
            CGFloat rad = active ? 9.0 : 7.5;
            [[UIColor whiteColor] setFill];
            CGContextFillEllipseInRect(ctx, CGRectMake(hp.x - rad, hp.y - rad, rad * 2.0, rad * 2.0));
            [AMAccentGreenColor() setStroke];
            CGContextSetLineWidth(ctx, 2.0);
            CGContextStrokeEllipseInRect(ctx, CGRectMake(hp.x - rad, hp.y - rad, rad * 2.0, rad * 2.0));
        }
    }
}

@end

@interface AMPuppetGraphPanelVC : UIViewController
@property (nonatomic, assign) int slot;
@property (nonatomic, assign) NSInteger pinIndex;
@property (nonatomic, assign) NSInteger keyframeIndex;
@property (nonatomic, assign) void *holder;
@property (nonatomic, copy) void (^onDidModify)(void);
@property (nonatomic, copy) void (^onRequestSeekMs)(int64_t timeMs);
@end

@implementation AMPuppetGraphPanelVC {
    AMPuppetGraphCanvasView *_graphView;
    UILabel *_infoLabel;
    UIButton *_prevBtn;
    UIButton *_nextBtn;
    UIStackView *_presetStack;
    NSTimer *_syncTimer;
}

- (NSMutableDictionary *)currentPinDict {
    NSMutableDictionary *ld = [[AMPuppetStore shared] layerDictForSlot:self.slot create:NO elementId:0];
    NSArray *pins = ld[@"pins"];
    if (self.pinIndex >= 0 && self.pinIndex < (NSInteger)pins.count) {
        return pins[self.pinIndex];
    }
    return nil;
}

- (NSMutableDictionary *)currentKeyframeDict {
    NSMutableDictionary *pd = [self currentPinDict];
    NSArray *kfs = pd[@"keyframes"];
    if (self.keyframeIndex >= 0 && self.keyframeIndex + 1 < (NSInteger)kfs.count) {
        return kfs[self.keyframeIndex];
    }
    return nil;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = AMBgColor();

    // Left vertical tool rail (matching EditEasingPanelVC: Back, Reverse, Overflow)
    UIView *leftRail = [[UIView alloc] init];
    leftRail.translatesAutoresizingMaskIntoConstraints = NO;
    leftRail.backgroundColor = [UIColor colorWithRed:0.114 green:0.122 blue:0.176 alpha:1.0];
    [self.view addSubview:leftRail];

    UIButton *backBtn = [self makeIconButton:@"ic_back" fallback:@"chevron.left" action:@selector(onTapBack)];
    UIButton *revBtn = [self makeIconButton:@"ic_reverse" fallback:@"arrow.left.arrow.right" action:@selector(onTapReverse)];
    UIButton *moreBtn = [self makeIconButton:@"ic_overflow" fallback:@"ellipsis" action:@selector(onTapOverflow:)];

    UIStackView *leftStack = [[UIStackView alloc] initWithArrangedSubviews:@[backBtn, revBtn, moreBtn]];
    leftStack.translatesAutoresizingMaskIntoConstraints = NO;
    leftStack.axis = UILayoutConstraintAxisVertical;
    leftStack.distribution = UIStackViewDistributionEqualSpacing;
    leftStack.alignment = UIStackViewAlignmentCenter;
    [leftRail addSubview:leftStack];

    // Right preset column (Linear, Ease In, Ease Out, Ease In-Out, Overshoot, Bounce, Step)
    UIScrollView *rightScroll = [[UIScrollView alloc] init];
    rightScroll.translatesAutoresizingMaskIntoConstraints = NO;
    rightScroll.showsVerticalScrollIndicator = NO;
    [self.view addSubview:rightScroll];

    _presetStack = [[UIStackView alloc] init];
    _presetStack.translatesAutoresizingMaskIntoConstraints = NO;
    _presetStack.axis = UILayoutConstraintAxisVertical;
    _presetStack.spacing = 6.0;
    [rightScroll addSubview:_presetStack];

    NSArray<NSDictionary *> *presets = @[
        @{@"t": @"Linear",   @"type": @0, @"p1x": @0.0,  @"p1y": @0.0,  @"p2x": @1.0,  @"p2y": @1.0},
        @{@"t": @"Ease In",  @"type": @0, @"p1x": @0.42, @"p1y": @0.0,  @"p2x": @1.0,  @"p2y": @1.0},
        @{@"t": @"Ease Out", @"type": @0, @"p1x": @0.0,  @"p1y": @0.0,  @"p2x": @0.58, @"p2y": @1.0},
        @{@"t": @"In-Out",   @"type": @0, @"p1x": @0.42, @"p1y": @0.0,  @"p2x": @0.58, @"p2y": @1.0},
        @{@"t": @"Snap",     @"type": @0, @"p1x": @0.16, @"p1y": @1.0,  @"p2x": @0.30, @"p2y": @1.0},
        @{@"t": @"Overshoot",@"type": @0, @"p1x": @0.34, @"p1y": @1.45, @"p2x": @0.64, @"p2y": @1.0},
        @{@"t": @"Elastic",  @"type": @2, @"p1x": @0.35, @"p1y": @0.0,  @"p2x": @0.45, @"p2y": @1.0},
        @{@"t": @"Bounce",   @"type": @3, @"p1x": @0.0,  @"p1y": @0.0,  @"p2x": @1.0,  @"p2y": @1.0},
        @{@"t": @"Hold",     @"type": @1, @"p1x": @0.0,  @"p1y": @0.0,  @"p2x": @1.0,  @"p2y": @1.0, @"steps": @1.0},
        @{@"t": @"Steps 4",  @"type": @1, @"p1x": @0.0,  @"p1y": @0.0,  @"p2x": @1.0,  @"p2y": @1.0, @"steps": @4.0},
    ];
    for (NSUInteger i = 0; i < presets.count; ++i) {
        UIButton *pb = [UIButton buttonWithType:UIButtonTypeSystem];
        pb.tag = (NSInteger)i;
        pb.backgroundColor = AMSurfaceColor();
        pb.layer.cornerRadius = 6.0;
        [pb setTitle:presets[i][@"t"] forState:UIControlStateNormal];
        [pb setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        pb.titleLabel.font = AMThemeFont(11.0, UIFontWeightSemibold);
        [pb.heightAnchor constraintEqualToConstant:28.0].active = YES;
        objc_setAssociatedObject(pb, @selector(onTapPreset:), presets[i], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [pb addTarget:self action:@selector(onTapPreset:) forControlEvents:UIControlEventTouchUpInside];
        [_presetStack addArrangedSubview:pb];
    }

    // Center Graph Canvas + Bottom Segment Navigator (< Segment 1/2 >)
    _graphView = [[AMPuppetGraphCanvasView alloc] init];
    _graphView.translatesAutoresizingMaskIntoConstraints = NO;
    __weak __typeof__(self) weakSelf = self;
    _graphView.onCurveChanged = ^(BOOL ended) {
        [weakSelf persistGraphToCurrentKeyframe:ended];
    };
    [self.view addSubview:_graphView];

    UIView *bottomBar = [[UIView alloc] init];
    bottomBar.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:bottomBar];

    _prevBtn = [self makeIconButton:nil fallback:@"chevron.left" action:@selector(onTapPrevSeg)];
    _nextBtn = [self makeIconButton:nil fallback:@"chevron.right" action:@selector(onTapNextSeg)];
    _infoLabel = [[UILabel alloc] init];
    _infoLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _infoLabel.font = AMThemeFont(11.5, UIFontWeightSemibold);
    _infoLabel.textColor = [UIColor colorWithWhite:0.88 alpha:1.0];
    _infoLabel.textAlignment = NSTextAlignmentCenter;

    [bottomBar addSubview:_prevBtn];
    [bottomBar addSubview:_infoLabel];
    [bottomBar addSubview:_nextBtn];

    [NSLayoutConstraint activateConstraints:@[
        [leftRail.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [leftRail.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [leftRail.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [leftRail.widthAnchor constraintEqualToConstant:46.0],

        [leftStack.topAnchor constraintEqualToAnchor:leftRail.topAnchor constant:12.0],
        [leftStack.bottomAnchor constraintEqualToAnchor:leftRail.bottomAnchor constant:-12.0],
        [leftStack.centerXAnchor constraintEqualToAnchor:leftRail.centerXAnchor],

        [rightScroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-8.0],
        [rightScroll.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:8.0],
        [rightScroll.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor constant:-8.0],
        [rightScroll.widthAnchor constraintEqualToConstant:78.0],

        [_presetStack.topAnchor constraintEqualToAnchor:rightScroll.topAnchor],
        [_presetStack.bottomAnchor constraintEqualToAnchor:rightScroll.bottomAnchor],
        [_presetStack.leadingAnchor constraintEqualToAnchor:rightScroll.leadingAnchor],
        [_presetStack.trailingAnchor constraintEqualToAnchor:rightScroll.trailingAnchor],
        [_presetStack.widthAnchor constraintEqualToAnchor:rightScroll.widthAnchor],

        [_graphView.leadingAnchor constraintEqualToAnchor:leftRail.trailingAnchor constant:10.0],
        [_graphView.trailingAnchor constraintEqualToAnchor:rightScroll.leadingAnchor constant:-10.0],
        [_graphView.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:10.0],
        [_graphView.bottomAnchor constraintEqualToAnchor:bottomBar.topAnchor constant:-6.0],

        [bottomBar.leadingAnchor constraintEqualToAnchor:_graphView.leadingAnchor],
        [bottomBar.trailingAnchor constraintEqualToAnchor:_graphView.trailingAnchor],
        [bottomBar.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-4.0],
        [bottomBar.heightAnchor constraintEqualToConstant:30.0],

        [_prevBtn.leadingAnchor constraintEqualToAnchor:bottomBar.leadingAnchor],
        [_prevBtn.centerYAnchor constraintEqualToAnchor:bottomBar.centerYAnchor],
        [_nextBtn.trailingAnchor constraintEqualToAnchor:bottomBar.trailingAnchor],
        [_nextBtn.centerYAnchor constraintEqualToAnchor:bottomBar.centerYAnchor],
        [_infoLabel.leadingAnchor constraintEqualToAnchor:_prevBtn.trailingAnchor constant:4.0],
        [_infoLabel.trailingAnchor constraintEqualToAnchor:_nextBtn.leadingAnchor constant:-4.0],
        [_infoLabel.centerYAnchor constraintEqualToAnchor:bottomBar.centerYAnchor],
    ]];

    [self loadCurrentKeyframeIntoGraph];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self loadCurrentKeyframeIntoGraph];
    [_syncTimer invalidate];
    _syncTimer = [NSTimer scheduledTimerWithTimeInterval:0.05 target:self selector:@selector(onSyncTick) userInfo:nil repeats:YES];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [_syncTimer invalidate];
    _syncTimer = nil;
}

- (UIButton *)makeIconButton:(NSString *)assetName fallback:(NSString *)sfName action:(SEL)sel {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.translatesAutoresizingMaskIntoConstraints = NO;
    UIImage *img = assetName ? [UIImage imageNamed:assetName] : nil;
    if (!img && sfName) {
        if (@available(iOS 13.0, *)) {
            UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:15.0 weight:UIImageSymbolWeightMedium];
            img = [UIImage systemImageNamed:sfName withConfiguration:cfg];
        }
    }
    if (img) [b setImage:[img imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate] forState:UIControlStateNormal];
    b.tintColor = [UIColor whiteColor];
    [b.widthAnchor constraintEqualToConstant:34.0].active = YES;
    [b.heightAnchor constraintEqualToConstant:34.0].active = YES;
    [b addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (void)loadCurrentKeyframeIntoGraph {
    NSMutableDictionary *pd = [self currentPinDict];
    NSArray *kfs = pd[@"keyframes"];
    NSInteger segCount = MAX(0, (NSInteger)kfs.count - 1);
    if (segCount == 0) {
        _infoLabel.text = @"Add 2+ Keyframes";
        _prevBtn.enabled = NO;
        _nextBtn.enabled = NO;
        return;
    }
    if (self.keyframeIndex < 0) self.keyframeIndex = 0;
    if (self.keyframeIndex >= segCount) self.keyframeIndex = segCount - 1;

    NSDictionary *kf = kfs[self.keyframeIndex];
    _graphView.easingType = [kf[@"easingType"] intValue];
    _graphView.p1x = kf[@"p1x"] ? [kf[@"p1x"] floatValue] : 0.42f;
    _graphView.p1y = kf[@"p1y"] ? [kf[@"p1y"] floatValue] : 0.0f;
    _graphView.p2x = kf[@"p2x"] ? [kf[@"p2x"] floatValue] : 0.58f;
    _graphView.p2y = kf[@"p2y"] ? [kf[@"p2y"] floatValue] : 1.0f;
    _graphView.stepCount = kf[@"stepCount"] ? [kf[@"stepCount"] floatValue] : 4.0f;

    _prevBtn.enabled = (self.keyframeIndex > 0);
    _nextBtn.enabled = (self.keyframeIndex + 1 < segCount);
    _prevBtn.alpha = _prevBtn.enabled ? 1.0 : 0.35;
    _nextBtn.alpha = _nextBtn.enabled ? 1.0 : 0.35;

    [self updateInfoLabel];
    [self onSyncTick];
    [_graphView setNeedsDisplay];
}

- (void)updateInfoLabel {
    NSMutableDictionary *pd = [self currentPinDict];
    NSArray *kfs = pd[@"keyframes"];
    NSInteger segCount = MAX(0, (NSInteger)kfs.count - 1);
    NSString *modeName = @"Cubic";
    if (_graphView.easingType == 1) modeName = (_graphView.stepCount <= 1.0f) ? @"Hold" : @"Step";
    else if (_graphView.easingType == 2) modeName = @"Elastic";
    else if (_graphView.easingType == 3) modeName = @"Bounce";
    _infoLabel.text = [NSString stringWithFormat:@"Pin %ld • %@ (%ld/%ld)",
                       (long)(self.pinIndex + 1), modeName, (long)(self.keyframeIndex + 1), (long)segCount];
}

- (void)onSyncTick {
    if (!self.holder) return;
    int64_t tMs = AMReadHolderCurrentTime(self.holder, AMMainBinarySlide());
    gAMPuppetEditorCurrentTimeMs = tMs;
    NSMutableDictionary *pd = [self currentPinDict];
    NSArray *kfs = pd[@"keyframes"];
    if (self.keyframeIndex >= 0 && self.keyframeIndex + 1 < (NSInteger)kfs.count) {
        int64_t t0 = [kfs[self.keyframeIndex][@"t"] longLongValue];
        int64_t t1 = [kfs[self.keyframeIndex + 1][@"t"] longLongValue];
        if (t1 > t0 && tMs >= t0 && tMs <= t1) {
            _graphView.playheadU = (float)((double)(tMs - t0) / (double)(t1 - t0));
        } else {
            _graphView.playheadU = -1.0f;
        }
        [_graphView setNeedsDisplay];
    }
}

- (void)persistGraphToCurrentKeyframe:(BOOL)saveDisk {
    NSMutableDictionary *kf = [self currentKeyframeDict];
    if (!kf) return;
    kf[@"easingType"] = @(_graphView.easingType);
    kf[@"p1x"] = @(_graphView.p1x);
    kf[@"p1y"] = @(_graphView.p1y);
    kf[@"p2x"] = @(_graphView.p2x);
    kf[@"p2y"] = @(_graphView.p2y);
    kf[@"stepCount"] = @(_graphView.stepCount);
    if (saveDisk) {
        [[AMPuppetStore shared] save];
    } else {
        [[AMPuppetStore shared] syncAllToRuntime];
    }
    [self updateInfoLabel];
    AMRequestCoalescedPreviewRedraw();
    if (self.onDidModify) self.onDidModify();
}

- (void)onTapPreset:(UIButton *)sender {
    NSDictionary *p = objc_getAssociatedObject(sender, @selector(onTapPreset:));
    if (!p) return;
    _graphView.easingType = [p[@"type"] intValue];
    _graphView.p1x = [p[@"p1x"] floatValue];
    _graphView.p1y = [p[@"p1y"] floatValue];
    _graphView.p2x = [p[@"p2x"] floatValue];
    _graphView.p2y = [p[@"p2y"] floatValue];
    if (p[@"steps"]) _graphView.stepCount = [p[@"steps"] floatValue];
    [_graphView setNeedsDisplay];
    [self persistGraphToCurrentKeyframe:YES];
}

- (void)onTapReverse {
    float np1x = 1.0f - _graphView.p2x;
    float np1y = 1.0f - _graphView.p2y;
    float np2x = 1.0f - _graphView.p1x;
    float np2y = 1.0f - _graphView.p1y;
    _graphView.p1x = np1x; _graphView.p1y = np1y;
    _graphView.p2x = np2x; _graphView.p2y = np2y;
    [_graphView setNeedsDisplay];
    [self persistGraphToCurrentKeyframe:YES];
}

- (void)onTapOverflow:(UIButton *)sender {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Puppet Easing Curve" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    [ac addAction:[UIAlertAction actionWithTitle:@"Reset to Linear" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        (void)a;
        self->_graphView.easingType = 0;
        self->_graphView.p1x = 0.0f; self->_graphView.p1y = 0.0f;
        self->_graphView.p2x = 1.0f; self->_graphView.p2y = 1.0f;
        [self->_graphView setNeedsDisplay];
        [self persistGraphToCurrentKeyframe:YES];
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"Copy Curve" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        (void)a;
        gAMPuppetCopiedEasingType = self->_graphView.easingType;
        gAMPuppetCopiedP1X = self->_graphView.p1x; gAMPuppetCopiedP1Y = self->_graphView.p1y;
        gAMPuppetCopiedP2X = self->_graphView.p2x; gAMPuppetCopiedP2Y = self->_graphView.p2y;
        gAMPuppetCopiedStepCount = self->_graphView.stepCount;
        gAMPuppetHasCopiedCurve = YES;
    }]];
    if (gAMPuppetHasCopiedCurve) {
        [ac addAction:[UIAlertAction actionWithTitle:@"Paste Curve" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            (void)a;
            self->_graphView.easingType = gAMPuppetCopiedEasingType;
            self->_graphView.p1x = gAMPuppetCopiedP1X; self->_graphView.p1y = gAMPuppetCopiedP1Y;
            self->_graphView.p2x = gAMPuppetCopiedP2X; self->_graphView.p2y = gAMPuppetCopiedP2Y;
            self->_graphView.stepCount = gAMPuppetCopiedStepCount;
            [self->_graphView setNeedsDisplay];
            [self persistGraphToCurrentKeyframe:YES];
        }]];
    }
    [ac addAction:[UIAlertAction actionWithTitle:(self->_graphView.allowOvershoot ? @"Clamp Overshoot (0..1)" : @"Allow Overshoot")
                                          style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        (void)a;
        self->_graphView.allowOvershoot = !self->_graphView.allowOvershoot;
        [self->_graphView setNeedsDisplay];
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    if (ac.popoverPresentationController) {
        ac.popoverPresentationController.sourceView = sender;
        ac.popoverPresentationController.sourceRect = sender.bounds;
    }
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)onTapPrevSeg {
    if (self.keyframeIndex > 0) {
        self.keyframeIndex -= 1;
        [self loadCurrentKeyframeIntoGraph];
        [self seekToSegmentMidpoint];
    }
}

- (void)onTapNextSeg {
    NSMutableDictionary *pd = [self currentPinDict];
    NSArray *kfs = pd[@"keyframes"];
    if (self.keyframeIndex + 2 < (NSInteger)kfs.count) {
        self.keyframeIndex += 1;
        [self loadCurrentKeyframeIntoGraph];
        [self seekToSegmentMidpoint];
    }
}

- (void)seekToSegmentMidpoint {
    NSMutableDictionary *pd = [self currentPinDict];
    NSArray *kfs = pd[@"keyframes"];
    if (self.keyframeIndex >= 0 && self.keyframeIndex + 1 < (NSInteger)kfs.count) {
        int64_t t0 = [kfs[self.keyframeIndex][@"t"] longLongValue];
        int64_t t1 = [kfs[self.keyframeIndex + 1][@"t"] longLongValue];
        if (self.onRequestSeekMs) self.onRequestSeekMs((t0 + t1) / 2);
    }
}

- (void)onTapBack {
    [self.navigationController popViewControllerAnimated:YES];
}

@end

// --- Native Alight Motion Bottom Puppet Tool Panel (pushed onto EditingPanelNC) ---

@interface AMPuppetTouchPadView : UIView
@property (nonatomic, copy) void (^onDeltaNorm)(CGPoint deltaNorm, BOOL ended);
@end

@implementation AMPuppetTouchPadView {
    CGPoint _lastPt;
}
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = AMInputSurfaceColor();
        self.layer.cornerRadius = 8.0;
        self.layer.borderWidth = 1.0;
        self.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.09].CGColor;
    }
    return self;
}
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)event;
    UITouch *t = [touches anyObject];
    if (t) _lastPt = [t locationInView:self];
}
- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)event;
    UITouch *t = [touches anyObject];
    if (!t) return;
    CGPoint p = [t locationInView:self];
    CGPoint d = CGPointMake((p.x - _lastPt.x) / 260.0, -(p.y - _lastPt.y) / 260.0);
    _lastPt = p;
    if (self.onDeltaNorm) self.onDeltaNorm(d, NO);
}
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)touches; (void)event;
    if (self.onDeltaNorm) self.onDeltaNorm(CGPointZero, YES);
}
@end

@interface AMPuppetPanelVC : UIViewController <AMPuppetCanvasOverlayDelegate>
@property (nonatomic, assign) void *holder;
@property (nonatomic, assign) uint64_t elementId;
@end

@implementation AMPuppetPanelVC {
    int _slot;
    int64_t _startTimeMs;
    int64_t _endTimeMs;
    NSInteger _selectedPinIndex;
    BOOL _addPinMode;
    BOOL _pushingGraph;

    AMPuppetCanvasOverlayView *_canvasOverlay;
    NSTimer *_syncTimer;
    int64_t _lastPolledTimeMs;

    // Left rail controls (CompactSideToolVC style)
    UIButton *_keyframeBtn;
    UIButton *_prevKfBtn;
    UIButton *_nextKfBtn;
    UIButton *_graphBtn;

    // Top pin chips & tools
    UIScrollView *_pinScroll;
    UIStackView *_pinStack;
    UIButton *_addModeBtn;
    UIButton *_meshBtn;
    UIButton *_resetPinBtn;
    UIButton *_delPinBtn;

    // Center touch pad + mode + stiffness
    AMPuppetTouchPadView *_touchPad;
    UILabel *_coordLabel;
    UILabel *_hintLabel;
    UISegmentedControl *_modeSegment;
    UISlider *_stiffnessSlider;
    UILabel *_stiffnessLabel;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_syncTimer invalidate];
    [_canvasOverlay removeFromSuperview];
    gAMPuppetPanelVisible = NO;
    gAMPuppetActiveElementId = 0;
    gAMPuppetActivePinIndex = -1;
    if (_holder) {
        AMSwiftRelease(_holder, AMMainBinarySlide());
        _holder = NULL;
    }
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = AMBgColor();
    _addPinMode = YES;
    _selectedPinIndex = -1;
    _lastPolledTimeMs = -1;

    AMInstallPuppetMetalHook();
    if (_holder) {
        AMSwiftRetain(_holder, AMMainBinarySlide());
        _slot = AMPuppetSyncOrAttachEffect(_holder, self.elementId, YES, &_startTimeMs, &_endTimeMs);
        _lastPolledTimeMs = AMReadHolderCurrentTime(_holder, AMMainBinarySlide());
        gAMPuppetEditorCurrentTimeMs = _lastPolledTimeMs;
    }
    if (_slot < 1) {
        _slot = [[AMPuppetStore shared] slotForElementId:self.elementId];
        if (_slot < 1) _slot = 1;
        [[AMPuppetStore shared] bindSlot:_slot toElementId:self.elementId startTimeMs:_startTimeMs endTimeMs:_endTimeMs];
    }

    NSMutableDictionary *ld = [self layerDict];
    NSArray *pins = ld[@"pins"];
    if (pins.count > 0) _selectedPinIndex = 0;

    [self buildUI];
    [self rebuildPinChips];
    [self refreshControls];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(onTransformUpdated:)
                                                 name:kAMPuppetTransformUpdatedNotification
                                               object:nil];

    AMForceImmediatePreviewRedraw();
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    _pushingGraph = NO;
    gAMPuppetPanelVisible = YES;
    gAMPuppetActiveElementId = self.elementId;
    gAMPuppetActivePinIndex = (int)_selectedPinIndex;
    [self attachCanvasOverlayIfNeeded];
    [self startSyncTimer];
    [self refreshControls];
    AMForceImmediatePreviewRedraw();
    AMPuppetRedrawAllKeyframeViews();
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self attachCanvasOverlayIfNeeded];
    AMForceImmediatePreviewRedraw();
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    if (!_pushingGraph) {
        [_syncTimer invalidate];
        _syncTimer = nil;
        [_canvasOverlay removeFromSuperview];
        _canvasOverlay = nil;
        gAMPuppetPanelVisible = NO;
        gAMPuppetActiveElementId = 0;
        gAMPuppetActivePinIndex = -1;
        AMForceImmediatePreviewRedraw();
        AMPuppetRedrawAllKeyframeViews();
    }
}

- (NSMutableDictionary *)layerDict {
    return [[AMPuppetStore shared] layerDictForSlot:_slot create:YES elementId:self.elementId];
}

- (NSMutableArray *)pinsArray {
    NSMutableDictionary *ld = [self layerDict];
    if (![ld[@"pins"] isKindOfClass:[NSMutableArray class]]) {
        ld[@"pins"] = ld[@"pins"] ? [ld[@"pins"] mutableCopy] : [NSMutableArray array];
    }
    return ld[@"pins"];
}

- (NSMutableDictionary *)selectedPinDict {
    NSMutableArray *pins = [self pinsArray];
    if (_selectedPinIndex >= 0 && _selectedPinIndex < (NSInteger)pins.count) {
        return pins[_selectedPinIndex];
    }
    return nil;
}

- (int64_t)currentTimeMs {
    if (_holder) {
        int64_t t = AMReadHolderCurrentTime(_holder, AMMainBinarySlide());
        gAMPuppetEditorCurrentTimeMs = t;
        return t;
    }
    return gAMPuppetEditorCurrentTimeMs;
}

- (void)attachCanvasOverlayIfNeeded {
    UIView *pv = AMPuppetFindProjectPreviewView(self.view);
    if (!pv) return;
    if (_canvasOverlay && _canvasOverlay.superview == pv) {
        _canvasOverlay.frame = pv.bounds;
        _canvasOverlay.slot = _slot;
        _canvasOverlay.selectedPinIndex = _selectedPinIndex;
        _canvasOverlay.addPinMode = _addPinMode;
        _canvasOverlay.currentTimeMs = [self currentTimeMs];
        [_canvasOverlay setNeedsDisplay];
        return;
    }
    [_canvasOverlay removeFromSuperview];
    _canvasOverlay = [[AMPuppetCanvasOverlayView alloc] initWithFrame:pv.bounds];
    _canvasOverlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _canvasOverlay.delegate = self;
    _canvasOverlay.previewView = pv;
    _canvasOverlay.slot = _slot;
    _canvasOverlay.selectedPinIndex = _selectedPinIndex;
    _canvasOverlay.addPinMode = _addPinMode;
    _canvasOverlay.currentTimeMs = [self currentTimeMs];
    [pv addSubview:_canvasOverlay];
    [_canvasOverlay setNeedsDisplay];
}

- (void)startSyncTimer {
    [_syncTimer invalidate];
    _syncTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 / 30.0 target:self selector:@selector(onSyncTick) userInfo:nil repeats:YES];
}

- (void)onSyncTick {
    if (!_holder) return;
    // Auto-close cleanly if user switched/deselected layer
    uint64_t *selIds = NULL;
    NSUInteger selCount = 0;
    BOOL stillSelected = NO;
    if (AMReadHolderSelectedIds(_holder, AMMainBinarySlide(), &selIds, &selCount)) {
        if (selCount == 1 && selIds[0] == self.elementId) stillSelected = YES;
    }
    if (selIds) free(selIds);
    if (!stillSelected) {
        [self.navigationController popViewControllerAnimated:NO];
        return;
    }

    int64_t t = [self currentTimeMs];
    if (_canvasOverlay) {
        _canvasOverlay.currentTimeMs = t;
        if (t != _lastPolledTimeMs) {
            [_canvasOverlay setNeedsDisplay];
        }
    }
    if (t != _lastPolledTimeMs) {
        _lastPolledTimeMs = t;
        [self refreshControls];
    }
}

- (void)onTransformUpdated:(NSNotification *)note {
    int s = [note.object intValue];
    if (s == _slot && _canvasOverlay) {
        [_canvasOverlay setNeedsDisplay];
    }
}

- (UIButton *)makeRailButton:(NSString *)assetName fallback:(NSString *)sfName action:(SEL)sel {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.translatesAutoresizingMaskIntoConstraints = NO;
    UIImage *img = assetName ? [UIImage imageNamed:assetName] : nil;
    if (!img && sfName) {
        if (@available(iOS 13.0, *)) {
            UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:15.0 weight:UIImageSymbolWeightMedium];
            img = [UIImage systemImageNamed:sfName withConfiguration:cfg];
        }
    }
    if (img) [b setImage:[img imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate] forState:UIControlStateNormal];
    b.tintColor = [UIColor whiteColor];
    [b.widthAnchor constraintEqualToConstant:36.0].active = YES;
    [b.heightAnchor constraintEqualToConstant:32.0].active = YES;
    [b addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (UIButton *)makeActionPill:(NSString *)title sf:(NSString *)sf action:(SEL)sel {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.translatesAutoresizingMaskIntoConstraints = NO;
    b.backgroundColor = AMSurfaceColor();
    b.layer.cornerRadius = 6.0;
    b.tintColor = [UIColor whiteColor];
    [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    b.titleLabel.font = AMThemeFont(11.0, UIFontWeightSemibold);
    if (title.length > 0) [b setTitle:title forState:UIControlStateNormal];
    if (sf.length > 0) {
        if (@available(iOS 13.0, *)) {
            UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:12.0 weight:UIImageSymbolWeightMedium];
            [b setImage:[UIImage systemImageNamed:sf withConfiguration:cfg] forState:UIControlStateNormal];
        }
    }
    b.contentEdgeInsets = UIEdgeInsetsMake(4.0, 8.0, 4.0, 8.0);
    [b addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (void)buildUI {
    // Left vertical keyframe sidebar (identical layout & dimensions to CompactSideToolVC)
    UIView *rail = [[UIView alloc] init];
    rail.translatesAutoresizingMaskIntoConstraints = NO;
    rail.backgroundColor = AMInputSurfaceColor();
    [self.view addSubview:rail];

    UIButton *backBtn = [self makeRailButton:@"ic_back" fallback:@"chevron.left" action:@selector(onTapBack)];
    _keyframeBtn = [self makeRailButton:@"ic_add keyframe" fallback:nil action:@selector(onTapToggleKeyframe)];
    if (![_keyframeBtn imageForState:UIControlStateNormal]) {
        [_keyframeBtn setImage:AMPuppetDiamondIcon(NO) forState:UIControlStateNormal];
    }
    _prevKfBtn = [self makeRailButton:nil fallback:@"chevron.left.to.line" action:@selector(onTapPrevKeyframe)];
    _nextKfBtn = [self makeRailButton:nil fallback:@"chevron.right.to.line" action:@selector(onTapNextKeyframe)];
    _graphBtn = [self makeRailButton:@"ic_easing curve" fallback:@"point.topleft.down.curvedto.point.bottomright.up" action:@selector(onTapGraph)];

    UIStackView *kfNav = [[UIStackView alloc] initWithArrangedSubviews:@[_prevKfBtn, _nextKfBtn]];
    kfNav.axis = UILayoutConstraintAxisHorizontal;
    kfNav.distribution = UIStackViewDistributionFillEqually;
    kfNav.spacing = 0.0;
    [_prevKfBtn.widthAnchor constraintEqualToConstant:22.0].active = YES;
    [_nextKfBtn.widthAnchor constraintEqualToConstant:22.0].active = YES;

    UIStackView *railStack = [[UIStackView alloc] initWithArrangedSubviews:@[backBtn, _keyframeBtn, kfNav, _graphBtn]];
    railStack.translatesAutoresizingMaskIntoConstraints = NO;
    railStack.axis = UILayoutConstraintAxisVertical;
    railStack.distribution = UIStackViewDistributionEqualSpacing;
    railStack.alignment = UIStackViewAlignmentCenter;
    [rail addSubview:railStack];

    // Right main content container
    UIView *content = [[UIView alloc] init];
    content.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:content];

    // Row 1: Pin chips bar + quick tool buttons (Add Pin, Mesh, Reset, Delete)
    _pinScroll = [[UIScrollView alloc] init];
    _pinScroll.translatesAutoresizingMaskIntoConstraints = NO;
    _pinScroll.showsHorizontalScrollIndicator = NO;
    [content addSubview:_pinScroll];

    _pinStack = [[UIStackView alloc] init];
    _pinStack.translatesAutoresizingMaskIntoConstraints = NO;
    _pinStack.axis = UILayoutConstraintAxisHorizontal;
    _pinStack.spacing = 6.0;
    [_pinScroll addSubview:_pinStack];

    _addModeBtn = [self makeActionPill:@"+ Pin" sf:nil action:@selector(onTapAddPinMode)];
    _meshBtn = [self makeActionPill:@"Mesh" sf:nil action:@selector(onTapToggleMesh)];
    _resetPinBtn = [self makeActionPill:nil sf:@"arrow.counterclockwise" action:@selector(onTapResetPin)];
    _delPinBtn = [self makeActionPill:nil sf:@"trash" action:@selector(onTapDeletePin)];
    _delPinBtn.tintColor = [UIColor colorWithRed:1.0 green:0.42 blue:0.42 alpha:1.0];

    UIStackView *toolRow = [[UIStackView alloc] initWithArrangedSubviews:@[_addModeBtn, _meshBtn, _resetPinBtn, _delPinBtn]];
    toolRow.translatesAutoresizingMaskIntoConstraints = NO;
    toolRow.axis = UILayoutConstraintAxisHorizontal;
    toolRow.spacing = 5.0;
    [content addSubview:toolRow];

    // Row 2 Left: Compact Alight Motion Touch Control Pad (fine pin nudge + X/Y readout)
    _touchPad = [[AMPuppetTouchPadView alloc] init];
    _touchPad.translatesAutoresizingMaskIntoConstraints = NO;
    __weak __typeof__(self) weakSelf = self;
    _touchPad.onDeltaNorm = ^(CGPoint d, BOOL ended) {
        [weakSelf nudgeSelectedPinByDelta:d ended:ended];
    };
    [content addSubview:_touchPad];

    _coordLabel = [[UILabel alloc] init];
    _coordLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _coordLabel.font = AMThemeFont(12.0, UIFontWeightSemibold);
    _coordLabel.textColor = [UIColor whiteColor];
    _coordLabel.textAlignment = NSTextAlignmentCenter;
    [_touchPad addSubview:_coordLabel];

    _hintLabel = [[UILabel alloc] init];
    _hintLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _hintLabel.font = AMThemeFont(10.5, UIFontWeightRegular);
    _hintLabel.textColor = [UIColor colorWithWhite:0.65 alpha:1.0];
    _hintLabel.textAlignment = NSTextAlignmentCenter;
    _hintLabel.numberOfLines = 2;
    [_touchPad addSubview:_hintLabel];

    // Row 2 Right: Deformation Mode (Rigid / Stretch / Smooth) + Stiffness Slider
    UIView *rightCtrl = [[UIView alloc] init];
    rightCtrl.translatesAutoresizingMaskIntoConstraints = NO;
    rightCtrl.backgroundColor = AMSurfaceColor();
    rightCtrl.layer.cornerRadius = 8.0;
    [content addSubview:rightCtrl];

    UILabel *modeTitle = [[UILabel alloc] init];
    modeTitle.translatesAutoresizingMaskIntoConstraints = NO;
    modeTitle.text = @"DEFORM MODE";
    modeTitle.font = AMThemeFont(9.5, UIFontWeightBold);
    modeTitle.textColor = [UIColor colorWithWhite:0.62 alpha:1.0];
    [rightCtrl addSubview:modeTitle];

    _modeSegment = [[UISegmentedControl alloc] initWithItems:@[@"Rigid", @"Stretch", @"Smooth"]];
    _modeSegment.translatesAutoresizingMaskIntoConstraints = NO;
    _modeSegment.selectedSegmentIndex = [[self layerDict][@"deformMode"] integerValue];
    _modeSegment.backgroundColor = AMInputSurfaceColor();
    if (@available(iOS 13.0, *)) {
        _modeSegment.selectedSegmentTintColor = AMAccentGreenColor();
    }
    [_modeSegment setTitleTextAttributes:@{NSForegroundColorAttributeName: [UIColor colorWithWhite:0.82 alpha:1.0],
                                           NSFontAttributeName: AMThemeFont(10.5, UIFontWeightSemibold)}
                                forState:UIControlStateNormal];
    [_modeSegment setTitleTextAttributes:@{NSForegroundColorAttributeName: [UIColor colorWithRed:0.06 green:0.08 blue:0.12 alpha:1.0],
                                           NSFontAttributeName: AMThemeFont(10.5, UIFontWeightBold)}
                                forState:UIControlStateSelected];
    [_modeSegment addTarget:self action:@selector(onChangeMode:) forControlEvents:UIControlEventValueChanged];
    [rightCtrl addSubview:_modeSegment];

    _stiffnessLabel = [[UILabel alloc] init];
    _stiffnessLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _stiffnessLabel.font = AMThemeFont(10.5, UIFontWeightSemibold);
    _stiffnessLabel.textColor = [UIColor colorWithWhite:0.85 alpha:1.0];
    [rightCtrl addSubview:_stiffnessLabel];

    _stiffnessSlider = [[UISlider alloc] init];
    _stiffnessSlider.translatesAutoresizingMaskIntoConstraints = NO;
    _stiffnessSlider.minimumValue = 0.8f;
    _stiffnessSlider.maximumValue = 3.2f;
    float savedRig = [[self layerDict][@"rigidity"] floatValue];
    _stiffnessSlider.value = (savedRig >= 0.8f && savedRig <= 3.2f) ? savedRig : 1.5f;
    _stiffnessSlider.minimumTrackTintColor = AMAccentGreenColor();
    _stiffnessSlider.maximumTrackTintColor = AMInputSurfaceColor();
    [_stiffnessSlider addTarget:self action:@selector(onStiffnessChanged:) forControlEvents:UIControlEventValueChanged];
    [_stiffnessSlider addTarget:self action:@selector(onStiffnessEnded:) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside];
    [rightCtrl addSubview:_stiffnessSlider];

    [NSLayoutConstraint activateConstraints:@[
        [rail.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [rail.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [rail.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [rail.widthAnchor constraintEqualToConstant:46.0],

        [railStack.topAnchor constraintEqualToAnchor:rail.topAnchor constant:10.0],
        [railStack.bottomAnchor constraintEqualToAnchor:rail.safeAreaLayoutGuide.bottomAnchor constant:-10.0],
        [railStack.centerXAnchor constraintEqualToAnchor:rail.centerXAnchor],

        [content.leadingAnchor constraintEqualToAnchor:rail.trailingAnchor constant:8.0],
        [content.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-8.0],
        [content.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:8.0],
        [content.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-6.0],

        [toolRow.topAnchor constraintEqualToAnchor:content.topAnchor],
        [toolRow.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
        [toolRow.heightAnchor constraintEqualToConstant:28.0],

        [_pinScroll.topAnchor constraintEqualToAnchor:content.topAnchor],
        [_pinScroll.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
        [_pinScroll.trailingAnchor constraintEqualToAnchor:toolRow.leadingAnchor constant:-6.0],
        [_pinScroll.heightAnchor constraintEqualToConstant:28.0],

        [_pinStack.topAnchor constraintEqualToAnchor:_pinScroll.topAnchor],
        [_pinStack.bottomAnchor constraintEqualToAnchor:_pinScroll.bottomAnchor],
        [_pinStack.leadingAnchor constraintEqualToAnchor:_pinScroll.leadingAnchor],
        [_pinStack.trailingAnchor constraintEqualToAnchor:_pinScroll.trailingAnchor],
        [_pinStack.heightAnchor constraintEqualToAnchor:_pinScroll.heightAnchor],

        [_touchPad.topAnchor constraintEqualToAnchor:toolRow.bottomAnchor constant:8.0],
        [_touchPad.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
        [_touchPad.bottomAnchor constraintEqualToAnchor:content.bottomAnchor],
        [_touchPad.widthAnchor constraintEqualToAnchor:content.widthAnchor multiplier:0.46],

        [_coordLabel.topAnchor constraintEqualToAnchor:_touchPad.topAnchor constant:10.0],
        [_coordLabel.leadingAnchor constraintEqualToAnchor:_touchPad.leadingAnchor constant:6.0],
        [_coordLabel.trailingAnchor constraintEqualToAnchor:_touchPad.trailingAnchor constant:-6.0],

        [_hintLabel.centerYAnchor constraintEqualToAnchor:_touchPad.centerYAnchor constant:12.0],
        [_hintLabel.leadingAnchor constraintEqualToAnchor:_touchPad.leadingAnchor constant:8.0],
        [_hintLabel.trailingAnchor constraintEqualToAnchor:_touchPad.trailingAnchor constant:-8.0],

        [rightCtrl.topAnchor constraintEqualToAnchor:toolRow.bottomAnchor constant:8.0],
        [rightCtrl.leadingAnchor constraintEqualToAnchor:_touchPad.trailingAnchor constant:8.0],
        [rightCtrl.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
        [rightCtrl.bottomAnchor constraintEqualToAnchor:content.bottomAnchor],

        [modeTitle.topAnchor constraintEqualToAnchor:rightCtrl.topAnchor constant:8.0],
        [modeTitle.leadingAnchor constraintEqualToAnchor:rightCtrl.leadingAnchor constant:10.0],

        [_modeSegment.topAnchor constraintEqualToAnchor:modeTitle.bottomAnchor constant:5.0],
        [_modeSegment.leadingAnchor constraintEqualToAnchor:rightCtrl.leadingAnchor constant:8.0],
        [_modeSegment.trailingAnchor constraintEqualToAnchor:rightCtrl.trailingAnchor constant:-8.0],
        [_modeSegment.heightAnchor constraintEqualToConstant:26.0],

        [_stiffnessLabel.topAnchor constraintEqualToAnchor:_modeSegment.bottomAnchor constant:10.0],
        [_stiffnessLabel.leadingAnchor constraintEqualToAnchor:rightCtrl.leadingAnchor constant:10.0],
        [_stiffnessLabel.trailingAnchor constraintEqualToAnchor:rightCtrl.trailingAnchor constant:-10.0],

        [_stiffnessSlider.topAnchor constraintEqualToAnchor:_stiffnessLabel.bottomAnchor constant:2.0],
        [_stiffnessSlider.leadingAnchor constraintEqualToAnchor:rightCtrl.leadingAnchor constant:10.0],
        [_stiffnessSlider.trailingAnchor constraintEqualToAnchor:rightCtrl.trailingAnchor constant:-10.0],
    ]];
}

- (void)rebuildPinChips {
    for (UIView *v in [_pinStack.arrangedSubviews copy]) {
        [_pinStack removeArrangedSubview:v];
        [v removeFromSuperview];
    }
    NSMutableArray *pins = [self pinsArray];
    if (pins.count == 0) {
        UILabel *empty = [[UILabel alloc] init];
        empty.text = @"No Pins — Tap Media";
        empty.font = AMThemeFont(11.0, UIFontWeightMedium);
        empty.textColor = [UIColor colorWithWhite:0.55 alpha:1.0];
        [_pinStack addArrangedSubview:empty];
        return;
    }
    for (NSUInteger i = 0; i < pins.count; ++i) {
        BOOL sel = ((NSInteger)i == _selectedPinIndex);
        UIButton *chip = [UIButton buttonWithType:UIButtonTypeSystem];
        chip.tag = (NSInteger)i;
        NSArray *kfs = pins[i][@"keyframes"];
        NSString *title = (kfs.count > 0)
            ? [NSString stringWithFormat:@"Pin %lu ◆%lu", (unsigned long)(i + 1), (unsigned long)kfs.count]
            : [NSString stringWithFormat:@"Pin %lu", (unsigned long)(i + 1)];
        [chip setTitle:title forState:UIControlStateNormal];
        chip.titleLabel.font = AMThemeFont(11.0, sel ? UIFontWeightBold : UIFontWeightSemibold);
        chip.backgroundColor = sel ? AMAccentGreenColor() : AMSurfaceColor();
        [chip setTitleColor:(sel ? [UIColor colorWithRed:0.06 green:0.08 blue:0.12 alpha:1.0] : [UIColor whiteColor])
                   forState:UIControlStateNormal];
        chip.layer.cornerRadius = 6.0;
        chip.contentEdgeInsets = UIEdgeInsetsMake(4.0, 9.0, 4.0, 9.0);
        [chip addTarget:self action:@selector(onSelectPinChip:) forControlEvents:UIControlEventTouchUpInside];
        [_pinStack addArrangedSubview:chip];
    }
}

- (NSInteger)keyframeIndexAtTimeMs:(int64_t)tMs forPin:(NSDictionary *)pd {
    NSArray *kfs = pd[@"keyframes"];
    for (NSUInteger i = 0; i < kfs.count; ++i) {
        int64_t kt = [kfs[i][@"t"] longLongValue];
        if (llabs(kt - tMs) <= 20) return (NSInteger)i;
    }
    return -1;
}

- (void)evalCurrentPin:(CGPoint *)outPt {
    NSMutableDictionary *pd = [self selectedPinDict];
    if (!pd) { *outPt = CGPointMake(0.5, 0.5); return; }
    AMPuppetSlotRuntime rt;
    os_unfair_lock_lock(&gAMPuppetRuntimeLock);
    rt = gAMPuppetSlots[_slot];
    os_unfair_lock_unlock(&gAMPuppetRuntimeLock);
    if (rt.active && _selectedPinIndex >= 0 && _selectedPinIndex < rt.pinCount) {
        float cx = rt.pins[_selectedPinIndex].currX;
        float cy = rt.pins[_selectedPinIndex].currY;
        AMPuppetEvalPinAtMs(&rt.pins[_selectedPinIndex], [self currentTimeMs], &cx, &cy);
        *outPt = CGPointMake(cx, cy);
    } else {
        *outPt = CGPointMake([pd[@"currX"] floatValue], [pd[@"currY"] floatValue]);
    }
}

- (void)refreshControls {
    gAMPuppetActivePinIndex = (int)_selectedPinIndex;
    NSMutableDictionary *ld = [self layerDict];
    NSMutableDictionary *pd = [self selectedPinDict];
    int64_t tMs = [self currentTimeMs];

    // Add Pin toggle highlight
    _addModeBtn.backgroundColor = _addPinMode ? AMAccentGreenColor() : AMSurfaceColor();
    [_addModeBtn setTitleColor:(_addPinMode ? [UIColor colorWithRed:0.06 green:0.08 blue:0.12 alpha:1.0] : [UIColor whiteColor])
                      forState:UIControlStateNormal];

    // Mesh toggle highlight
    BOOL meshOn = [ld[@"showMesh"] boolValue];
    _meshBtn.backgroundColor = meshOn ? [AMAccentGreenColor() colorWithAlphaComponent:0.25] : AMSurfaceColor();
    _meshBtn.layer.borderWidth = meshOn ? 1.0 : 0.0;
    _meshBtn.layer.borderColor = AMAccentGreenColor().CGColor;

    // Stiffness label
    float rig = _stiffnessSlider.value;
    _stiffnessLabel.text = [NSString stringWithFormat:@"Stiffness: %.2f", rig];

    if (!pd) {
        _coordLabel.text = @"Puppet Tool";
        _hintLabel.text = @"Tap media on canvas to drop pins.\nDrag any pin to deform.";
        _keyframeBtn.enabled = NO; _keyframeBtn.alpha = 0.35;
        _prevKfBtn.enabled = NO; _prevKfBtn.alpha = 0.35;
        _nextKfBtn.enabled = NO; _nextKfBtn.alpha = 0.35;
        _graphBtn.enabled = NO; _graphBtn.alpha = 0.35;
        _resetPinBtn.enabled = NO; _resetPinBtn.alpha = 0.35;
        _delPinBtn.enabled = NO; _delPinBtn.alpha = 0.35;
        return;
    }

    _keyframeBtn.enabled = YES; _keyframeBtn.alpha = 1.0;
    _resetPinBtn.enabled = YES; _resetPinBtn.alpha = 1.0;
    _delPinBtn.enabled = YES; _delPinBtn.alpha = 1.0;

    CGPoint pt;
    [self evalCurrentPin:&pt];
    _coordLabel.text = [NSString stringWithFormat:@"Pin %ld   X: %.0f%%  Y: %.0f%%",
                        (long)(_selectedPinIndex + 1), pt.x * 100.0, pt.y * 100.0];

    NSArray *kfs = pd[@"keyframes"];
    NSInteger onKf = [self keyframeIndexAtTimeMs:tMs forPin:pd];
    if (onKf >= 0) {
        UIImage *remImg = [UIImage imageNamed:@"ic_remove keyframe"] ?: AMPuppetDiamondIcon(YES);
        [_keyframeBtn setImage:[remImg imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate] forState:UIControlStateNormal];
        _keyframeBtn.tintColor = AMAccentGreenColor();
    } else {
        UIImage *addImg = [UIImage imageNamed:@"ic_add keyframe"] ?: AMPuppetDiamondIcon(NO);
        [_keyframeBtn setImage:[addImg imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate] forState:UIControlStateNormal];
        _keyframeBtn.tintColor = [UIColor whiteColor];
    }

    BOOL hasPrev = NO, hasNext = NO;
    for (NSDictionary *kf in kfs) {
        int64_t kt = [kf[@"t"] longLongValue];
        if (kt < tMs - 20) hasPrev = YES;
        if (kt > tMs + 20) hasNext = YES;
    }
    _prevKfBtn.enabled = hasPrev; _prevKfBtn.alpha = hasPrev ? 1.0 : 0.35;
    _nextKfBtn.enabled = hasNext; _nextKfBtn.alpha = hasNext ? 1.0 : 0.35;

    BOOL canGraph = (kfs.count >= 2);
    _graphBtn.enabled = canGraph;
    _graphBtn.alpha = canGraph ? 1.0 : 0.35;
    _graphBtn.tintColor = canGraph ? AMAccentGreenColor() : [UIColor whiteColor];

    _hintLabel.text = (kfs.count > 0)
        ? [NSString stringWithFormat:@"Swipe pad to nudge • %lu keyframe%@", (unsigned long)kfs.count, kfs.count == 1 ? @"" : @"s"]
        : @"Drag pin on canvas or swipe pad.\nTap ◆ to animate.";

    if (_canvasOverlay) {
        _canvasOverlay.selectedPinIndex = _selectedPinIndex;
        _canvasOverlay.addPinMode = _addPinMode;
        _canvasOverlay.currentTimeMs = tMs;
        [_canvasOverlay setNeedsDisplay];
    }
}

- (void)upsertKeyframeOnPin:(NSMutableDictionary *)pd timeMs:(int64_t)tMs x:(float)x y:(float)y {
    if (![pd[@"keyframes"] isKindOfClass:[NSMutableArray class]]) {
        pd[@"keyframes"] = pd[@"keyframes"] ? [pd[@"keyframes"] mutableCopy] : [NSMutableArray array];
    }
    NSMutableArray *kfs = pd[@"keyframes"];
    NSInteger existing = [self keyframeIndexAtTimeMs:tMs forPin:pd];
    if (existing >= 0) {
        NSMutableDictionary *kf = kfs[existing];
        kf[@"x"] = @(x);
        kf[@"y"] = @(y);
    } else if (kfs.count < kAMPuppetMaxKeyframesPerPin) {
        NSMutableDictionary *kf = [NSMutableDictionary dictionaryWithDictionary:@{
            @"t": @(tMs),
            @"x": @(x),
            @"y": @(y),
            @"easingType": @(0),
            @"p1x": @(0.42),
            @"p1y": @(0.0),
            @"p2x": @(0.58),
            @"p2y": @(1.0),
            @"stepCount": @(4.0)
        }];
        [kfs addObject:kf];
        [kfs sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            return [a[@"t"] compare:b[@"t"]];
        }];
    }
}

static void AMPuppetFastUpdatePinInRuntime(int slot, NSInteger pinIdx, float x, float y, int64_t timeMs) {
    if (slot < 1 || slot > kAMPuppetMaxSlots || pinIdx < 0 || pinIdx >= kAMPuppetMaxPins) return;
    os_unfair_lock_lock(&gAMPuppetRuntimeLock);
    AMPuppetSlotRuntime *rt = &gAMPuppetSlots[slot];
    if (rt->active && pinIdx < rt->pinCount) {
        AMPuppetPinC *pc = &rt->pins[pinIdx];
        pc->currX = x;
        pc->currY = y;
        if (pc->keyframeCount > 0) {
            int match = -1;
            for (int k = 0; k < pc->keyframeCount; ++k) {
                if (llabs(pc->keyframes[k].timeMs - timeMs) <= 20) {
                    match = k;
                    break;
                }
            }
            if (match >= 0) {
                pc->keyframes[match].x = x;
                pc->keyframes[match].y = y;
            } else if (pc->keyframeCount < kAMPuppetMaxKeyframesPerPin) {
                int ins = pc->keyframeCount;
                while (ins > 0 && pc->keyframes[ins - 1].timeMs > timeMs) {
                    pc->keyframes[ins] = pc->keyframes[ins - 1];
                    ins--;
                }
                AMPuppetKeyframeC kf = { timeMs, x, y, 0, 0.42f, 0.0f, 0.58f, 1.0f, 4.0f };
                pc->keyframes[ins] = kf;
                pc->keyframeCount++;
            }
        }
    }
    os_unfair_lock_unlock(&gAMPuppetRuntimeLock);
}

static void AMPuppetFastUpdateRigidityInRuntime(int slot, float rigidity) {
    if (slot < 1 || slot > kAMPuppetMaxSlots) return;
    os_unfair_lock_lock(&gAMPuppetRuntimeLock);
    if (gAMPuppetSlots[slot].active) {
        gAMPuppetSlots[slot].rigidity = rigidity;
    }
    os_unfair_lock_unlock(&gAMPuppetRuntimeLock);
}

- (void)setPinIndex:(NSInteger)idx position:(CGPoint)ln ended:(BOOL)ended {
    NSMutableArray *pins = [self pinsArray];
    if (idx < 0 || idx >= (NSInteger)pins.count) return;
    NSMutableDictionary *pd = pins[idx];
    float x = (float)ln.x, y = (float)ln.y;
    int64_t tMs = [self currentTimeMs];
    pd[@"currX"] = @(x);
    pd[@"currY"] = @(y);
    NSArray *kfs = pd[@"keyframes"];
    // Exact AE + Alight Motion auto-keyframe: if pin is already animated (>=1 keyframe), moving at new time records a keyframe!
    if (kfs.count > 0) {
        [self upsertKeyframeOnPin:pd timeMs:tMs x:x y:y];
    }
    if (ended) {
        [[AMPuppetStore shared] save];
        [self rebuildPinChips];
        AMPuppetRedrawAllKeyframeViews();
        [self refreshControls];
        AMRequestCoalescedPreviewRedraw();
    } else {
        AMPuppetFastUpdatePinInRuntime(_slot, idx, x, y, tMs);
        _coordLabel.text = [NSString stringWithFormat:@"Pin %ld   X: %.0f%%  Y: %.0f%%",
                            (long)(_selectedPinIndex + 1), x * 100.0, y * 100.0];
        if (_canvasOverlay) {
            _canvasOverlay.selectedPinIndex = _selectedPinIndex;
            _canvasOverlay.currentTimeMs = tMs;
            [_canvasOverlay setNeedsDisplay];
        }
        AMRequestCoalescedPreviewRedraw();
    }
}

- (void)nudgeSelectedPinByDelta:(CGPoint)d ended:(BOOL)ended {
    if (_selectedPinIndex < 0) return;
    CGPoint cur;
    [self evalCurrentPin:&cur];
    CGPoint next = CGPointMake(fmin(fmax(cur.x + d.x, -0.5), 1.5),
                               fmin(fmax(cur.y + d.y, -0.5), 1.5));
    [self setPinIndex:_selectedPinIndex position:next ended:ended];
}

// --- AMPuppetCanvasOverlayDelegate ---

- (void)puppetCanvasDidTapAddPinAtLayerNorm:(CGPoint)layerNorm {
    NSMutableArray *pins = [self pinsArray];
    if (pins.count >= kAMPuppetMaxPins) return;
    NSMutableDictionary *ld = [self layerDict];
    int nextId = [ld[@"nextPinId"] intValue] ?: ((int)pins.count + 1);
    ld[@"nextPinId"] = @(nextId + 1);

    // Compute rest coordinate by inverse-evaluating? If no deformation yet, rest == layerNorm;
    // when adding a pin to already-deformed media, place rest at layerNorm so it pins cleanly where tapped.
    NSMutableDictionary *pin = [NSMutableDictionary dictionaryWithDictionary:@{
        @"id": @(nextId),
        @"restX": @(layerNorm.x),
        @"restY": @(layerNorm.y),
        @"currX": @(layerNorm.x),
        @"currY": @(layerNorm.y),
        @"keyframes": [NSMutableArray array]
    }];
    [pins addObject:pin];
    _selectedPinIndex = (NSInteger)pins.count - 1;
    if (_canvasOverlay) _canvasOverlay.selectedPinIndex = _selectedPinIndex;

    [[AMPuppetStore shared] save];
    [self rebuildPinChips];
    [self refreshControls];
    AMForceImmediatePreviewRedraw();
    UIImpactFeedbackGenerator *h = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [h impactOccurred];
}

- (void)puppetCanvasDidSelectPinIndex:(NSInteger)pinIndex {
    _selectedPinIndex = pinIndex;
    [self rebuildPinChips];
    [self refreshControls];
    AMPuppetRedrawAllKeyframeViews();
}

- (void)puppetCanvasDidDragPinIndex:(NSInteger)pinIndex toLayerNorm:(CGPoint)layerNorm ended:(BOOL)ended {
    _selectedPinIndex = pinIndex;
    [self setPinIndex:pinIndex position:layerNorm ended:ended];
}

// --- Actions ---

- (void)onSelectPinChip:(UIButton *)sender {
    _selectedPinIndex = sender.tag;
    [self rebuildPinChips];
    [self refreshControls];
    AMPuppetRedrawAllKeyframeViews();
}

- (void)onTapAddPinMode {
    _addPinMode = !_addPinMode;
    [self refreshControls];
}

- (void)onTapToggleMesh {
    NSMutableDictionary *ld = [self layerDict];
    ld[@"showMesh"] = @(![ld[@"showMesh"] boolValue]);
    [[AMPuppetStore shared] save];
    [self refreshControls];
    AMForceImmediatePreviewRedraw();
}

- (void)onTapResetPin {
    NSMutableDictionary *pd = [self selectedPinDict];
    if (!pd) return;
    CGPoint rest = CGPointMake([pd[@"restX"] floatValue], [pd[@"restY"] floatValue]);
    [self setPinIndex:_selectedPinIndex position:rest ended:YES];
}

- (void)onTapDeletePin {
    NSMutableArray *pins = [self pinsArray];
    if (_selectedPinIndex < 0 || _selectedPinIndex >= (NSInteger)pins.count) return;
    [pins removeObjectAtIndex:(NSUInteger)_selectedPinIndex];
    if (_selectedPinIndex >= (NSInteger)pins.count) _selectedPinIndex = (NSInteger)pins.count - 1;
    [[AMPuppetStore shared] save];
    [self rebuildPinChips];
    [self refreshControls];
    AMForceImmediatePreviewRedraw();
    AMPuppetRedrawAllKeyframeViews();
}

- (void)onTapToggleKeyframe {
    NSMutableDictionary *pd = [self selectedPinDict];
    if (!pd) return;
    int64_t tMs = [self currentTimeMs];
    if (![pd[@"keyframes"] isKindOfClass:[NSMutableArray class]]) {
        pd[@"keyframes"] = pd[@"keyframes"] ? [pd[@"keyframes"] mutableCopy] : [NSMutableArray array];
    }
    NSMutableArray *kfs = pd[@"keyframes"];
    NSInteger existing = [self keyframeIndexAtTimeMs:tMs forPin:pd];
    if (existing >= 0) {
        [kfs removeObjectAtIndex:(NSUInteger)existing];
    } else {
        CGPoint cur;
        [self evalCurrentPin:&cur];
        [self upsertKeyframeOnPin:pd timeMs:tMs x:(float)cur.x y:(float)cur.y];
    }
    [[AMPuppetStore shared] save];
    [self rebuildPinChips];
    [self refreshControls];
    AMForceImmediatePreviewRedraw();
    AMPuppetRedrawAllKeyframeViews();
    UIImpactFeedbackGenerator *h = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [h impactOccurred];
}

- (void)onTapPrevKeyframe {
    NSMutableDictionary *pd = [self selectedPinDict];
    if (!pd) return;
    int64_t tMs = [self currentTimeMs];
    int64_t best = -1;
    for (NSDictionary *kf in pd[@"keyframes"]) {
        int64_t kt = [kf[@"t"] longLongValue];
        if (kt < tMs - 20 && kt > best) best = kt;
    }
    if (best >= 0) {
        AMPuppetSeekHolderToTimeMs(_holder, best);
        _lastPolledTimeMs = best;
        [self refreshControls];
    }
}

- (void)onTapNextKeyframe {
    NSMutableDictionary *pd = [self selectedPinDict];
    if (!pd) return;
    int64_t tMs = [self currentTimeMs];
    int64_t best = INT64_MAX;
    for (NSDictionary *kf in pd[@"keyframes"]) {
        int64_t kt = [kf[@"t"] longLongValue];
        if (kt > tMs + 20 && kt < best) best = kt;
    }
    if (best < INT64_MAX) {
        AMPuppetSeekHolderToTimeMs(_holder, best);
        _lastPolledTimeMs = best;
        [self refreshControls];
    }
}

- (void)onTapGraph {
    NSMutableDictionary *pd = [self selectedPinDict];
    NSArray *kfs = pd[@"keyframes"];
    if (kfs.count < 2) return;

    int64_t tMs = [self currentTimeMs];
    NSInteger segIdx = 0;
    for (NSInteger i = 0; i + 1 < (NSInteger)kfs.count; ++i) {
        int64_t t0 = [kfs[i][@"t"] longLongValue];
        int64_t t1 = [kfs[i + 1][@"t"] longLongValue];
        if (tMs >= t0 && tMs <= t1) { segIdx = i; break; }
        if (tMs > t1) segIdx = i;
    }

    AMPuppetGraphPanelVC *gvc = [[AMPuppetGraphPanelVC alloc] init];
    gvc.slot = _slot;
    gvc.pinIndex = _selectedPinIndex;
    gvc.keyframeIndex = segIdx;
    gvc.holder = _holder;
    __weak __typeof__(self) weakSelf = self;
    gvc.onDidModify = ^{
        [weakSelf refreshControls];
    };
    gvc.onRequestSeekMs = ^(int64_t targetMs) {
        AMPuppetSeekHolderToTimeMs(weakSelf.holder, targetMs);
        [weakSelf refreshControls];
    };
    _pushingGraph = YES;
    [self.navigationController pushViewController:gvc animated:YES];
}

- (void)onChangeMode:(UISegmentedControl *)seg {
    NSMutableDictionary *ld = [self layerDict];
    ld[@"deformMode"] = @(seg.selectedSegmentIndex);
    [[AMPuppetStore shared] save];
    AMForceImmediatePreviewRedraw();
}

- (void)onStiffnessChanged:(UISlider *)slider {
    NSMutableDictionary *ld = [self layerDict];
    ld[@"rigidity"] = @(slider.value);
    AMPuppetFastUpdateRigidityInRuntime(_slot, slider.value);
    _stiffnessLabel.text = [NSString stringWithFormat:@"Stiffness: %.2f", slider.value];
    AMRequestCoalescedPreviewRedraw();
}

- (void)onStiffnessEnded:(UISlider *)slider {
    (void)slider;
    [[AMPuppetStore shared] save];
}

- (void)onTapBack {
    [self.navigationController popViewControllerAnimated:YES];
}

@end

// --- Native EditingPanelVC Hooks (Adds exact Alight Motion 'Puppet' Card!) ---

static IMP gOrigEditingPanelNumItems = NULL;
static IMP gOrigEditingPanelCellForItem = NULL;
static IMP gOrigEditingPanelSizeForItem = NULL;
static IMP gOrigEditingPanelDidSelectItem = NULL;

static NSInteger AMEditingPanelOrigCount(id self, UICollectionView *cv, NSInteger section) {
    if (!gOrigEditingPanelNumItems) return 0;
    return ((NSInteger (*)(id, SEL, UICollectionView *, NSInteger))gOrigEditingPanelNumItems)(
        self, @selector(collectionView:numberOfItemsInSection:), cv, section);
}

static NSInteger AMHook_editingPanelNumItems(id self, SEL _cmd, UICollectionView *cv, NSInteger section) {
    NSInteger orig = gOrigEditingPanelNumItems
        ? ((NSInteger (*)(id, SEL, UICollectionView *, NSInteger))gOrigEditingPanelNumItems)(self, _cmd, cv, section)
        : 0;
    if (orig >= 4) return orig + 1;
    return orig;
}

static CGSize AMHook_editingPanelSizeForItem(id self, SEL _cmd, UICollectionView *cv, UICollectionViewLayout *layout, NSIndexPath *indexPath) {
    NSInteger orig = AMEditingPanelOrigCount(self, cv, indexPath.section);
    if (orig < 4) {
        if (gOrigEditingPanelSizeForItem) {
            return ((CGSize (*)(id, SEL, UICollectionView *, UICollectionViewLayout *, NSIndexPath *))gOrigEditingPanelSizeForItem)(
                self, _cmd, cv, layout, indexPath);
        }
        return CGSizeMake(80.0, 64.0);
    }
    NSInteger total = orig + 1;
    NSInteger topCols = total / 2;
    NSInteger botCols = total - topCols;
    NSInteger cols = (indexPath.row < topCols) ? topCols : botCols;
    NSInteger rows = 2;

    CGFloat interSpacing = 8.0;
    CGFloat lineSpacing = 8.0;
    UIEdgeInsets inset = UIEdgeInsetsZero;
    if ([layout isKindOfClass:[UICollectionViewFlowLayout class]]) {
        UICollectionViewFlowLayout *fl = (UICollectionViewFlowLayout *)layout;
        interSpacing = fl.minimumInteritemSpacing;
        lineSpacing = fl.minimumLineSpacing;
        inset = fl.sectionInset;
    }
    CGFloat availW = cv.bounds.size.width - inset.left - inset.right - interSpacing * (CGFloat)(cols - 1) - 1.0;
    CGFloat availH = cv.bounds.size.height - inset.top - inset.bottom - lineSpacing * (CGFloat)(rows - 1) - 1.0;
    CGFloat w = floor(fmax(availW / (CGFloat)cols, 44.0));
    CGFloat h = floor(fmax(availH / (CGFloat)rows, 44.0));
    return CGSizeMake(w, h);
}

static UICollectionViewCell *AMHook_editingPanelCellForItem(id self, SEL _cmd, UICollectionView *cv, NSIndexPath *indexPath) {
    NSInteger orig = AMEditingPanelOrigCount(self, cv, indexPath.section);
    if (orig >= 4 && indexPath.row == orig) {
        UICollectionViewCell *cell = [cv dequeueReusableCellWithReuseIdentifier:@"EditingPanelCell" forIndexPath:indexPath];
        cell.layer.cornerRadius = 5.3;
        cell.layer.masksToBounds = YES;
        SEL labelSel = NSSelectorFromString(@"label");
        if ([cell respondsToSelector:labelSel]) {
            UILabel *lbl = ((UILabel *(*)(id, SEL))objc_msgSend)(cell, labelSel);
            if ([lbl isKindOfClass:[UILabel class]]) {
                lbl.text = @"Puppet";
            }
        }
        SEL imgSel = NSSelectorFromString(@"imageView");
        if ([cell respondsToSelector:imgSel]) {
            UIImageView *iv = ((UIImageView *(*)(id, SEL))objc_msgSend)(cell, imgSel);
            if ([iv isKindOfClass:[UIImageView class]]) {
                iv.image = AMPuppetTabIcon();
                iv.tintColor = [UIColor whiteColor];
                iv.contentMode = UIViewContentModeScaleAspectFit;
            }
        }
        SEL newTagSel = NSSelectorFromString(@"newTag");
        if ([cell respondsToSelector:newTagSel]) {
            UIView *nt = ((UIView *(*)(id, SEL))objc_msgSend)(cell, newTagSel);
            if ([nt isKindOfClass:[UIView class]]) {
                nt.alpha = 0.0;
            }
        }
        return cell;
    }
    if (gOrigEditingPanelCellForItem) {
        return ((UICollectionViewCell *(*)(id, SEL, UICollectionView *, NSIndexPath *))gOrigEditingPanelCellForItem)(self, _cmd, cv, indexPath);
    }
    return [[UICollectionViewCell alloc] init];
}

static void AMHook_editingPanelDidSelectItem(id self, SEL _cmd, UICollectionView *cv, NSIndexPath *indexPath) {
    NSInteger orig = AMEditingPanelOrigCount(self, cv, indexPath.section);
    if (orig >= 4 && indexPath.row == orig) {
        [cv deselectItemAtIndexPath:indexPath animated:YES];
        intptr_t slide = AMMainBinarySlide();
        Ivar holderIvar = class_getInstanceVariable([self class], "holder");
        void *holder = holderIvar ? *(void **)((uint8_t *)(__bridge void *)self + ivar_getOffset(holderIvar)) : NULL;
        if (!holder) return;

        uint64_t *selIds = NULL;
        NSUInteger selCount = 0;
        uint64_t targetId = 0;
        if (AMReadHolderSelectedIds(holder, slide, &selIds, &selCount) && selCount > 0) {
            targetId = selIds[0];
        }
        if (selIds) free(selIds);
        if (targetId == 0) return;

        AMPuppetPanelVC *pvc = [[AMPuppetPanelVC alloc] init];
        pvc.holder = holder;
        pvc.elementId = targetId;
        UIViewController *vc = (UIViewController *)self;
        if (vc.navigationController) {
            [vc.navigationController pushViewController:pvc animated:YES];
        }
        return;
    }
    if (gOrigEditingPanelDidSelectItem) {
        ((void (*)(id, SEL, UICollectionView *, NSIndexPath *))gOrigEditingPanelDidSelectItem)(self, _cmd, cv, indexPath);
    }
}

// --- Native Timeline KeyframeView Diamonds Hook ---

static IMP gOrigKeyframeViewDrawRect = NULL;

static void AMHook_keyframeViewDrawRect(id self, SEL _cmd, CGRect rect) {
    if (gOrigKeyframeViewDrawRect) {
        ((void (*)(id, SEL, CGRect))gOrigKeyframeViewDrawRect)(self, _cmd, rect);
    }
    Class cls = [self class];
    Ivar ivId = class_getInstanceVariable(cls, "elementId");
    Ivar ivScale = class_getInstanceVariable(cls, "timeScaleFactor");
    Ivar ivOff = class_getInstanceVariable(cls, "timeOffset");
    if (!ivId || !ivScale || !ivOff) return;

    uint8_t *base = (uint8_t *)(__bridge void *)self;
    uint64_t eid = *(uint64_t *)(base + ivar_getOffset(ivId));
    float scaleF = *(float *)(base + ivar_getOffset(ivScale));
    float offsetF = *(float *)(base + ivar_getOffset(ivOff));
    if (eid == 0) return;

    // Collect puppet keyframe times for this elementId under lock
    int64_t startMs = 0, endMs = 0;
    int selPin = (gAMPuppetPanelVisible && eid == gAMPuppetActiveElementId) ? gAMPuppetActivePinIndex : -1;
    int64_t kfTimes[256];
    uint8_t kfIsSel[256];
    int kfTotal = 0;

    os_unfair_lock_lock(&gAMPuppetRuntimeLock);
    for (int s = 1; s <= kAMPuppetMaxSlots; ++s) {
        const AMPuppetSlotRuntime *rt = &gAMPuppetSlots[s];
        if (!rt->active || rt->elementId != eid) continue;
        startMs = rt->startTimeMs;
        endMs = rt->endTimeMs;
        for (int p = 0; p < rt->pinCount; ++p) {
            for (int k = 0; k < rt->pins[p].keyframeCount && kfTotal < 256; ++k) {
                kfTimes[kfTotal] = rt->pins[p].keyframes[k].timeMs;
                kfIsSel[kfTotal] = (p == selPin) ? 1 : 0;
                kfTotal++;
            }
        }
        break;
    }
    os_unfair_lock_unlock(&gAMPuppetRuntimeLock);

    if (kfTotal <= 0 || endMs <= startMs) return;
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (!ctx) return;

    UIView *v = (UIView *)self;
    CGFloat w = v.bounds.size.width;
    CGFloat cy = v.bounds.size.height * 0.5;
    double dur = (double)(endMs - startMs);

    CGContextSaveGState(ctx);
    for (int i = 0; i < kfTotal; ++i) {
        float tNorm = (float)((double)(kfTimes[i] - startMs) / dur);
        CGFloat x = (CGFloat)(tNorm * scaleF + offsetF) * w;
        if (x < -8.0 || x > w + 8.0) continue;

        CGFloat r = kfIsSel[i] ? 5.2 : 4.2;
        UIBezierPath *d = [UIBezierPath bezierPath];
        [d moveToPoint:CGPointMake(x, cy - r)];
        [d addLineToPoint:CGPointMake(x + r, cy)];
        [d addLineToPoint:CGPointMake(x, cy + r)];
        [d addLineToPoint:CGPointMake(x - r, cy)];
        [d closePath];

        if (kfIsSel[i]) {
            [AMAccentGreenColor() setFill];
            [d fill];
            [[UIColor whiteColor] setStroke];
            d.lineWidth = 1.2;
            [d stroke];
        } else {
            [[UIColor colorWithRed:0.14 green:0.16 blue:0.24 alpha:0.95] setFill];
            [d fill];
            [[UIColor whiteColor] setStroke];
            d.lineWidth = 1.3;
            [d stroke];
        }
    }
    CGContextRestoreGState(ctx);
}

static void AMSwizzleMethod(NSString *className, NSString *selName, IMP replacement, IMP *outOrig) {
    Class cls = NSClassFromString(className);
    if (!cls) return;
    SEL sel = NSSelectorFromString(selName);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    *outOrig = method_setImplementation(m, replacement);
}

__attribute__((constructor))
static void AlightMotionModsInit(void) {
    NSInteger saved = [[NSUserDefaults standardUserDefaults] integerForKey:kAMPreviewQualityKey];
    if (saved >= 1 && saved <= 4) {
        gPreviewDivisor = saved;
    }

    AMSwizzleMethod(@"FIRHTTPSCallableResult",
                    @"data",
                    (IMP)AMHook_firCallableResultData,
                    &gOrigFIRCallableResultData);

    AMSwizzleMethod(@"GTMSessionFetcher",
                    @"beginFetchWithCompletionHandler:",
                    (IMP)AMHook_gtmBeginFetchWithCompletionHandler,
                    &gOrigGTMBeginFetch);

    AMSwizzleMethod(@"AVPlayer",
                    @"replaceCurrentItemWithPlayerItem:",
                    (IMP)AMHook_replaceCurrentItem,
                    &gOrigReplaceCurrentItem);

    AMSwizzleMethod(@"AVPlayer",
                    @"initWithPlayerItem:",
                    (IMP)AMHook_initWithPlayerItem,
                    &gOrigInitWithPlayerItem);

    // Audio speed scaling + varispeed pitch shift hooks
    {
        SEL tracksSel = @selector(tracksWithMediaType:);
        Method mAsset = class_getInstanceMethod([AVAsset class], tracksSel);
        Method mURLAsset = class_getInstanceMethod([AVURLAsset class], tracksSel);
        if (mAsset) {
            gOrigAVAssetTracksWithMediaType = method_setImplementation(mAsset, (IMP)AMHook_avAssetTracksWithMediaType);
        }
        if (mURLAsset && mURLAsset != mAsset) {
            gOrigAVURLAssetTracksWithMediaType = method_setImplementation(mURLAsset, (IMP)AMHook_avURLAssetTracksWithMediaType);
        }
    }
    AMSwizzleMethod(@"AVMutableCompositionTrack",
                    @"insertTimeRange:ofTrack:atTime:error:",
                    (IMP)AMHook_compTrackInsertTimeRange,
                    &gOrigCompTrackInsertTimeRange);
    AMSwizzleMethod(@"AVPlayerItem",
                    @"setAudioMix:",
                    (IMP)AMHook_playerItemSetAudioMix,
                    &gOrigPlayerItemSetAudioMix);
    AMSwizzleMethod(@"AVAssetReaderAudioMixOutput",
                    @"initWithAudioTracks:audioSettings:",
                    (IMP)AMHook_audioMixOutputInit,
                    &gOrigAudioMixOutputInit);
    AMSwizzleMethod(@"AVAssetReaderAudioMixOutput",
                    @"setAudioMix:",
                    (IMP)AMHook_audioMixOutputSetAudioMix,
                    &gOrigAudioMixOutputSetAudioMix);
    AMSwizzleMethod(@"AVAssetExportSession",
                    @"setAudioMix:",
                    (IMP)AMHook_exportSessionSetAudioMix,
                    &gOrigExportSessionSetAudioMix);

    AMSwizzleMethod(@"_TtC12AlightMotion12AMCompositor",
                    @"startVideoCompositionRequest:",
                    (IMP)AMHook_startVideoCompositionRequest,
                    &gOrigStartVideoCompReq);

    AMSwizzleMethod(@"_TtC12AlightMotion19PreviewControlBarVC",
                    @"viewDidLoad",
                    (IMP)AMHook_previewControlBarViewDidLoad,
                    &gOrigPreviewControlBarViewDidLoad);

    AMSwizzleMethod(@"_TtC12AlightMotion10SettingsVC",
                    @"viewDidLoad",
                    (IMP)AMHook_settingsVCViewDidLoad,
                    &gOrigSettingsVCViewDidLoad);

    AMSwizzleMethod(@"NSBundle",
                    @"URLsForResourcesWithExtension:subdirectory:",
                    (IMP)AMHook_URLsForResourcesWithExtension,
                    &gOrigURLsForResources);

    AMSwizzleMethod(@"_TtC12AlightMotion18EffectPickerMainVC",
                    @"collectionView:willDisplayCell:forItemAtIndexPath:",
                    (IMP)AMHook_effectMainWillDisplayCell,
                    &gOrigEffectMainWillDisplayCell);

    AMSwizzleMethod(@"_TtC12AlightMotion18EffectPickerMainVC",
                    @"collectionView:didSelectItemAtIndexPath:",
                    (IMP)AMHook_effectMainDidSelectItem,
                    &gOrigEffectMainDidSelectItem);

    AMSwizzleMethod(@"_TtC12AlightMotion22EffectPickerCategoryVC",
                    @"viewWillAppear:",
                    (IMP)AMHook_effectCategoryViewWillAppear,
                    &gOrigEffectCatViewWillAppear);

    AMSwizzleMethod(@"_TtC12AlightMotion22EffectPickerCategoryVC",
                    @"collectionView:willDisplayCell:forItemAtIndexPath:",
                    (IMP)AMHook_effectCatWillDisplayCell,
                    &gOrigEffectCatWillDisplayCell);

    Class multiNavCls = NSClassFromString(@"_TtC12AlightMotion18MultiSelectorNavVC");
    if (multiNavCls) {
        class_addMethod(multiNavCls, @selector(am_onTapMultiParent:), (IMP)AMOnTapMultiParent, "v@:@");
    }
    AMSwizzleMethod(@"_TtC12AlightMotion18MultiSelectorNavVC",
                    @"viewDidLoad",
                    (IMP)AMHook_multiSelectorNavViewDidLoad,
                    &gOrigMultiSelectorNavViewDidLoad);
    AMSwizzleMethod(@"_TtC12AlightMotion16LayerParentingVC",
                    @"tableView:willDisplayCell:forRowAtIndexPath:",
                    (IMP)AMHook_layerParentingWillDisplayCell,
                    &gOrigLayerParentingWillDisplayCell);
    AMSwizzleMethod(@"_TtC12AlightMotion16LayerParentingVC",
                    @"tableView:didSelectRowAtIndexPath:",
                    (IMP)AMHook_layerParentingDidSelectRow,
                    &gOrigLayerParentingDidSelectRow);

    // Module 7: Puppet Tool (EditingPanelVC native card, Timeline KeyframeView diamonds, Metal uniform hook)
    [AMPuppetStore shared];
    AMInstallPuppetMetalHook();
    AMSwizzleMethod(@"_TtC12AlightMotion14EditingPanelVC",
                    @"collectionView:numberOfItemsInSection:",
                    (IMP)AMHook_editingPanelNumItems,
                    &gOrigEditingPanelNumItems);
    AMSwizzleMethod(@"_TtC12AlightMotion14EditingPanelVC",
                    @"collectionView:layout:sizeForItemAtIndexPath:",
                    (IMP)AMHook_editingPanelSizeForItem,
                    &gOrigEditingPanelSizeForItem);
    AMSwizzleMethod(@"_TtC12AlightMotion14EditingPanelVC",
                    @"collectionView:cellForItemAtIndexPath:",
                    (IMP)AMHook_editingPanelCellForItem,
                    &gOrigEditingPanelCellForItem);
    AMSwizzleMethod(@"_TtC12AlightMotion14EditingPanelVC",
                    @"collectionView:didSelectItemAtIndexPath:",
                    (IMP)AMHook_editingPanelDidSelectItem,
                    &gOrigEditingPanelDidSelectItem);
    AMSwizzleMethod(@"_TtC12AlightMotion12KeyframeView",
                    @"drawRect:",
                    (IMP)AMHook_keyframeViewDrawRect,
                    &gOrigKeyframeViewDrawRect);

    dispatch_async(dispatch_get_main_queue(), ^{
        AMInstallCustomEffectCategoryIfNeeded();
    });

    AMSwizzleMethod(@"UIWindow",
                    @"sendEvent:",
                    (IMP)AMHook_windowSendEvent,
                    &gOrigWindowSendEvent);
    AMSwizzleMethod(@"UITabBarController",
                    @"setSelectedIndex:",
                    (IMP)AMHook_tabBarControllerSetSelectedIndex,
                    &gOrigTabBarControllerSetSelectedIndex);
    AMSwizzleMethod(@"UITabBarController",
                    @"setSelectedViewController:",
                    (IMP)AMHook_tabBarControllerSetSelectedVC,
                    &gOrigTabBarControllerSetSelectedVC);
    AMSwizzleMethod(@"UITabBar",
                    @"setSelectedItem:",
                    (IMP)AMHook_tabBarSetSelectedItem,
                    &gOrigTabBarSetSelectedItem);

    [[AMHomepageSearchOverlayManager shared] start];

    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *note) {
        (void)note;
        [[AMLaunchIntroManager shared] startIfNeeded];
    }];
    [[NSNotificationCenter defaultCenter] addObserverForName:UIWindowDidBecomeKeyNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *note) {
        (void)note;
        [[AMLaunchIntroManager shared] startIfNeeded];
    }];
}
