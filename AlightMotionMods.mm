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
// 3. Custom XML Effects Importer: `+` button in Effects -> Other category.
//    Creates each custom effect with a unique `com.alightcreative.effects.custom_*`
//    ID and its own selectable box in `Other` (auto-wraps raw GLSL or normalizes
//    `<effect>` XML, strips hidden flags, and renders custom PNG thumbnails).

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
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
static IMP gOrigEditSpeedVCViewDidLoad = NULL;
static IMP gOrigEditSpeedVCViewWillAppear = NULL;
static IMP gOrigEditSpeedVCViewDidLayout = NULL;
static IMP gOrigEditSpeedPanelViewDidLoad = NULL;
static IMP gOrigCompTrackInsertTimeRange = NULL;
static IMP gOrigCompTrackScaleTimeRange = NULL;
static IMP gOrigKeyframeViewDrawRect = NULL;

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

static void AMTrackPlayerIfPreview(AVPlayer *player, AVPlayerItem *item) {
    if (!player) return;
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
// it as its own standalone box inside category="other" (usable on any layer).
static NSString *AMPrepareEffectXML(NSString *rawXML, NSString *displayName, NSString *slug, NSError **outError) {
    NSString *trimmed = [rawXML stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0) {
        if (outError) {
            *outError = [NSError errorWithDomain:@"AMCustomEffects" code:1
                                        userInfo:@{NSLocalizedDescriptionKey: @"XML or GLSL code is empty."}];
        }
        return nil;
    }

    // If user pasted raw GLSL fragment code (void main()) without <effect> wrapper, auto-wrap it!
    NSRange openStart = [trimmed rangeOfString:@"<effect" options:NSCaseInsensitiveSearch];
    if (openStart.location == NSNotFound) {
        if ([trimmed containsString:@"void main"] || [trimmed containsString:@"gl_FragColor"]) {
            NSString *wrapped = [NSString stringWithFormat:
                @"<?xml version='1.0' encoding='UTF-8' ?>\n"
                @"<effect id=\"com.alightcreative.effects.custom_%@\" compat=\"acScreenNorm-y\" name=\"%@\" desc=\"Custom Effect\" category=\"other\" tags=\"custom\" thumb=\"thumb/copy-bg.webp\">\n"
                @"    <params>\n"
                @"        <texture id=\"inputImg\" srcType=\"content\" />\n"
                @"    </params>\n"
                @"    <shader type=\"fragment\" precision=\"high\"><![CDATA[\n%@\n    ]]></shader>\n"
                @"</effect>\n",
                slug, AMXmlEscapeAttr(displayName), trimmed];
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
    setAttr(@"category", @"other");
    setAttr(@"name", displayName);
    setAttr(@"desc", @"Custom Effect");
    setAttr(@"tags", @"custom");
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

static IMP gOrigURLsForResources = NULL;

static NSArray<NSURL *> *AMHook_URLsForResourcesWithExtension(id self, SEL _cmd, NSString *ext, NSString *subpath) {
    NSArray<NSURL *> *orig = nil;
    if (gOrigURLsForResources) {
        orig = ((NSArray<NSURL *> *(*)(id, SEL, NSString *, NSString *))gOrigURLsForResources)(self, _cmd, ext, subpath);
    }
    if (self == [NSBundle mainBundle] &&
        ext && [ext caseInsensitiveCompare:@"xml"] == NSOrderedSame &&
        subpath && [subpath isEqualToString:@"BuiltinEffects"]) {
        NSString *dir = AMCustomEffectsDir();
        NSArray<NSString *> *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:nil];
        if (files.count > 0) {
            NSMutableArray<NSURL *> *merged = orig ? [orig mutableCopy] : [NSMutableArray array];
            for (NSString *fn in files) {
                if ([[fn pathExtension] caseInsensitiveCompare:@"xml"] == NSOrderedSame) {
                    [merged addObject:[NSURL fileURLWithPath:[dir stringByAppendingPathComponent:fn]]];
                }
            }
            return merged;
        }
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
// Module 3: Custom XML Effect Importer Modal UI & '+' in Other Category
// ============================================================================

@interface AMCustomEffectImporterVC : UIViewController <UIDocumentPickerDelegate, UIImagePickerControllerDelegate, UINavigationControllerDelegate>
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
    self.xmlTextView.text =
        @"<?xml version='1.0' encoding='UTF-8' ?>\n"
        @"<effect id=\"com.alightcreative.effects.custom_invert\" compat=\"acScreenNorm-y\" name=\"Custom Invert\" desc=\"Inverts layer colors\" category=\"other\" tags=\"custom\" thumb=\"thumb/copy-bg.webp\">\n"
        @"    <params>\n"
        @"        <texture id=\"inputImg\" srcType=\"content\" />\n"
        @"        <spinner id=\"strength\" default=\"1.0\" min=\"0.0\" max=\"1.0\" step=\"0.01\" label=\"Strength\" type=\"percent\" />\n"
        @"    </params>\n"
        @"    <shader type=\"fragment\" precision=\"high\"><![CDATA[\n"
        @"        void main() {\n"
        @"            vec4 c = texture2DCv(inputImg.texture, acScreenNorm);\n"
        @"            vec3 inv = vec3(1.0) - c.rgb;\n"
        @"            gl_FragColor = vec4(mix(c.rgb, inv, strength), c.a);\n"
        @"        }\n"
        @"    ]]></shader>\n"
        @"</effect>\n";
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
    NSString *prepared = AMPrepareEffectXML(self.xmlTextView.text, name, slug, &err);
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
                                                                  message:[NSString stringWithFormat:@"'%@' is saved. Reopen Alight Motion so its own effect box loads in Effects > Other, then tap it to apply to any layer.", name]
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

static BOOL AMViewHierarchyContainsOtherTitle(UIView *v, NSInteger depth) {
    if (!v || depth > 5) return NO;
    if ([v isKindOfClass:[UILabel class]]) {
        NSString *t = ((UILabel *)v).text;
        if (t && [t caseInsensitiveCompare:@"Other"] == NSOrderedSame) return YES;
    }
    for (UIView *sub in v.subviews) {
        if (AMViewHierarchyContainsOtherTitle(sub, depth + 1)) return YES;
    }
    return NO;
}

static BOOL AMIsOtherEffectCategoryVC(UIViewController *vc) {
    if (vc.title && [vc.title caseInsensitiveCompare:@"Other"] == NSOrderedSame) return YES;
    if (vc.navigationItem.title && [vc.navigationItem.title caseInsensitiveCompare:@"Other"] == NSOrderedSame) return YES;
    if (vc.navigationController && AMViewHierarchyContainsOtherTitle(vc.navigationController.navigationBar, 0)) return YES;
    if (AMViewHierarchyContainsOtherTitle(vc.view, 0)) return YES;
    return NO;
}

@interface AMEffectImportPresenter : NSObject
+ (void)onTapPlus:(UIButton *)btn;
@end

@implementation AMEffectImportPresenter

+ (void)onTapPlus:(UIButton *)btn {
    UIViewController *vc = objc_getAssociatedObject(btn, kAMImportPlusBtnKey);
    if (!vc) return;
    AMCustomEffectImporterVC *importer = [[AMCustomEffectImporterVC alloc] init];
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
        BOOL isOther = AMIsOtherEffectCategoryVC(vc);
        UIButton *existing = objc_getAssociatedObject(vc, kAMImportPlusBtnKey);
        if (!isOther) {
            if (existing) existing.hidden = YES;
            return;
        }
        if (existing) {
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

static BOOL AMVCTreeContainsEditor(UIViewController *vc, NSInteger depth) {
    if (!vc || depth > 10) return NO;
    NSString *clsName = NSStringFromClass([vc class]) ?: @"";
    if ([clsName containsString:@"ProjectEdit"] ||
        [clsName containsString:@"PreviewControlBar"] ||
        [clsName containsString:@"EffectPicker"] ||
        [clsName containsString:@"SettingsVC"] ||
        [clsName containsString:@"AMProjectSearchVC"]) {
        return YES;
    }
    for (UIViewController *child in vc.childViewControllers) {
        if (AMVCTreeContainsEditor(child, depth + 1)) return YES;
    }
    return NO;
}

static BOOL AMIsOnHomepage(UIWindow *win) {
    if (!win || !win.rootViewController) return NO;
    if (gAMSearchModalOpen) return NO;
    UIViewController *root = win.rootViewController;
    if (root.presentedViewController != nil) return NO;
    if ([root isKindOfClass:[UINavigationController class]]) {
        UINavigationController *nav = (UINavigationController *)root;
        if (nav.viewControllers.count > 1) return NO;
    }
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

@interface AMHomepageSearchOverlayManager : NSObject
@property (nonatomic, strong, nullable) UIButton *searchButton;
@property (nonatomic, strong, nullable) NSTimer *pollTimer;
+ (instancetype)shared;
- (void)start;
@end

@implementation AMHomepageSearchOverlayManager

+ (instancetype)shared {
    static AMHomepageSearchOverlayManager *inst = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        inst = [[AMHomepageSearchOverlayManager alloc] init];
    });
    return inst;
}

- (void)start {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.pollTimer) return;
        self.pollTimer = [NSTimer scheduledTimerWithTimeInterval:0.45
                                                          target:self
                                                        selector:@selector(tick)
                                                        userInfo:nil
                                                         repeats:YES];
    });
}

- (void)ensureButtonInWindow:(UIWindow *)win {
    if (!self.searchButton) {
        UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
        btn.accessibilityLabel = @"Search Projects";
        btn.backgroundColor = [UIColor colorWithRed:0.933 green:0.941 blue:0.969 alpha:1.0]; // #EEF0F7
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
    if (self.searchButton.superview != win) {
        [win addSubview:self.searchButton];
    }
    [win bringSubviewToFront:self.searchButton];
}

- (void)tick {
    UIWindow *win = AMKeyWindow();
    if (!win) return;
    if (!AMIsOnHomepage(win)) {
        self.searchButton.hidden = YES;
        return;
    }
    [self ensureButtonInWindow:win];
    CGFloat size = 34.0;
    CGFloat x = win.bounds.size.width - 16.0 - 36.0 - 10.0 - size;
    CGFloat y = win.safeAreaInsets.top + 8.0;
    self.searchButton.frame = CGRectMake(x, y, size, size);
    self.searchButton.hidden = NO;
}

- (void)onTapSearch {
    NSArray<NSDictionary *> *projects = AMLoadUserProjectsFromDisk();
    UIViewController *top = AMTopMostViewController();
    if (!top) return;
    AMProjectSearchVC *vc = [[AMProjectSearchVC alloc] init];
    vc.allProjects = projects;
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    if (@available(iOS 13.0, *)) {
        nav.overrideUserInterfaceStyle = UIUserInterfaceStyleLight;
    }
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    [top presentViewController:nav animated:YES completion:nil];
}

@end

// ============================================================================
// Module 5: Suppress "CRACKED BY BLATANT" First-Launch Popup
// ============================================================================

static IMP gOrigPresentViewController = NULL;

static BOOL AMStringContainsBlatantPopupText(NSString *s) {
    if (s.length == 0) return NO;
    return [s localizedCaseInsensitiveContainsString:@"CRACKED BY BLATANT"] ||
           [s localizedCaseInsensitiveContainsString:@"BLATANT"];
}

static BOOL AMViewHierarchyContainsBlatantText(UIView *view, int depth) {
    if (!view || depth > 8) return NO;
    if ([view isKindOfClass:[UILabel class]]) {
        if (AMStringContainsBlatantPopupText(((UILabel *)view).text)) return YES;
    } else if ([view isKindOfClass:[UITextView class]]) {
        if (AMStringContainsBlatantPopupText(((UITextView *)view).text)) return YES;
    }
    for (UIView *sub in view.subviews) {
        if (AMViewHierarchyContainsBlatantText(sub, depth + 1)) return YES;
    }
    return NO;
}

static void AMHook_presentViewController(id self, SEL _cmd, UIViewController *vcToPresent, BOOL flag, void (^completion)(void)) {
    if ([vcToPresent isKindOfClass:[UIAlertController class]]) {
        UIAlertController *ac = (UIAlertController *)vcToPresent;
        if (AMStringContainsBlatantPopupText(ac.title) || AMStringContainsBlatantPopupText(ac.message)) {
            if (completion) completion();
            return;
        }
    } else if (vcToPresent && AMViewHierarchyContainsBlatantText(vcToPresent.view, 0)) {
        if (completion) completion();
        return;
    }
    if (gOrigPresentViewController) {
        ((void (*)(id, SEL, UIViewController *, BOOL, void (^)(void)))gOrigPresentViewController)(self, _cmd, vcToPresent, flag, completion);
    }
}

// ============================================================================
// Module 6: Speed Graph Editor (EditSpeedVC / EditSpeedControlPanelVC)
// ============================================================================

static const void *kAMSpeedGraphBtnAssocKey = &kAMSpeedGraphBtnAssocKey;
static const void *kAMSpeedGraphPanelAssocKey = &kAMSpeedGraphPanelAssocKey;
static const void *kAMSpeedKfBarAssocKey = &kAMSpeedKfBarAssocKey;
static const void *kAMSpeedKfBtnAssocKey = &kAMSpeedKfBtnAssocKey;
static const void *kAMSpeedKfPrevBtnAssocKey = &kAMSpeedKfPrevBtnAssocKey;
static const void *kAMSpeedKfNextBtnAssocKey = &kAMSpeedKfNextBtnAssocKey;
static const void *kAMSpeedKfCountLblAssocKey = &kAMSpeedKfCountLblAssocKey;

typedef struct {
    CGFloat x1;
    CGFloat y1;
    CGFloat x2;
    CGFloat y2;
} AMSpeedBezierCurve;

typedef struct {
    const char *name;
    AMSpeedBezierCurve curve;
} AMSpeedPreset;

static const AMSpeedPreset kAMBezierPresets[] = {
    {"Linear",            {0.00, 0.00, 1.00, 1.00}},
    {"Ease In",           {0.42, 0.00, 1.00, 1.00}},
    {"Ease Out",          {0.00, 0.00, 0.58, 1.00}},
    {"Cubic Bezier Easing",{0.42, 0.00, 0.58, 1.00}},
    {"Fast Ramp",         {0.85, 0.00, 0.15, 1.00}},
    {"Slow-Mo Dip",       {0.10, 0.85, 0.90, 0.15}},
    {"Whip In-Out",       {0.78, 0.00, 0.22, 1.00}},
};
static const NSInteger kAMBezierPresetCount = sizeof(kAMBezierPresets) / sizeof(kAMBezierPresets[0]);

static const AMSpeedPreset kAMRampPresets[] = {
    {"Velocity Peak",     {0.90, 0.05, 0.10, 0.95}},
    {"Flash In",          {0.05, 0.90, 0.30, 1.00}},
    {"Flash Out",         {0.70, 0.00, 0.95, 0.10}},
    {"Freeze Dip",        {0.15, 0.50, 0.85, 0.50}},
    {"Overshoot Snap",    {0.34, 1.35, 0.64, 1.00}},
};
static const NSInteger kAMRampPresetCount = sizeof(kAMRampPresets) / sizeof(kAMRampPresets[0]);

static const AMSpeedPreset kAMStepPresets[] = {
    {"Hold Start",        {0.95, 0.00, 0.95, 1.00}},
    {"Hold End",          {0.05, 0.00, 0.05, 1.00}},
    {"Mid Snap",          {0.90, 0.00, 0.10, 1.00}},
    {"Pulse Step",        {0.50, 0.00, 0.50, 1.00}},
};
static const NSInteger kAMStepPresetCount = sizeof(kAMStepPresets) / sizeof(kAMStepPresets[0]);

static AMSpeedBezierCurve gCopiedSpeedCurve = {0.42, 0.00, 0.58, 1.00};
static BOOL gHasCopiedSpeedCurve = NO;

static AMSpeedBezierCurve gActiveSpeedCurve = {0.00, 0.00, 1.00, 1.00};
static BOOL gActiveSpeedCurveEnabled = NO;
static CGFloat gActiveSpeedBase = 1.0;
static NSArray<NSDictionary *> *gActiveSpeedKeyframes = nil;
static BOOL gInSpeedRampScale = NO;
static const void *kAMCompTrackSrcInfoAssocKey = &kAMCompTrackSrcInfoAssocKey;

static void *AMGetRawIvarPtr(id obj, const char *ivarName) {
    if (!obj || !ivarName) return NULL;
    Class cls = object_getClass(obj);
    while (cls) {
        Ivar iv = class_getInstanceVariable(cls, ivarName);
        if (iv) {
            ptrdiff_t off = ivar_getOffset(iv);
            return *(void **)((uint8_t *)(__bridge void *)obj + off);
        }
        cls = class_getSuperclass(cls);
    }
    return NULL;
}

static id AMCallObjCGetter(id obj, NSString *selName) {
    if (!obj || !selName.length) return nil;
    SEL sel = NSSelectorFromString(selName);
    if (![obj respondsToSelector:sel]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(obj, sel);
}

static void AMCallEditSpeedVMSetSpeed(void *vmPtr, int64_t milliSpeed) {
    if (!vmPtr) return;
    intptr_t slide = _dyld_get_image_vmaddr_slide(0);
    uintptr_t fnAddr = (uintptr_t)slide + 0x1006d3bc0ULL;
    register int64_t x0_arg __asm__("x0") = milliSpeed;
    register void *x20_self __asm__("x20") = vmPtr;
    register uintptr_t x16_fn __asm__("x16") = fnAddr;
    __asm__ volatile(
        "blr x16"
        : "+r"(x0_arg), "+r"(x20_self)
        : "r"(x16_fn)
        : "x1", "x2", "x3", "x4", "x5", "x6", "x7", "x8", "x9", "x10", "x11",
          "x12", "x13", "x14", "x15", "x17", "lr", "cc", "memory",
          "v0", "v1", "v2", "v3", "v4", "v5", "v6", "v7",
          "v16", "v17", "v18", "v19", "v20", "v21", "v22", "v23",
          "v24", "v25", "v26", "v27", "v28", "v29", "v30", "v31"
    );
}

static void AMCallEditSpeedVMRefreshUI(void *vmPtr) {
    if (!vmPtr) return;
    intptr_t slide = _dyld_get_image_vmaddr_slide(0);
    uintptr_t fnAddr = (uintptr_t)slide + 0x1006d4120ULL;
    register void *x20_self __asm__("x20") = vmPtr;
    register uintptr_t x16_fn __asm__("x16") = fnAddr;
    __asm__ volatile(
        "blr x16"
        : "+r"(x20_self)
        : "r"(x16_fn)
        : "x0", "x1", "x2", "x3", "x4", "x5", "x6", "x7", "x8", "x9", "x10", "x11",
          "x12", "x13", "x14", "x15", "x17", "lr", "cc", "memory",
          "v0", "v1", "v2", "v3", "v4", "v5", "v6", "v7",
          "v16", "v17", "v18", "v19", "v20", "v21", "v22", "v23",
          "v24", "v25", "v26", "v27", "v28", "v29", "v30", "v31"
    );
}

static UIImage *AMBezierCurveIconImage(AMSpeedBezierCurve c, CGSize size, UIColor *strokeColor, UIColor *dotColor, BOOL drawBox);

static UIImage *AMNativeEasingIcon(NSString *preferredName, AMSpeedBezierCurve fallbackCurve, CGSize size, UIColor *tint) {
    UIImage *img = preferredName.length ? [UIImage imageNamed:preferredName] : nil;
    if (img) {
        return [img imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    }
    return [AMBezierCurveIconImage(fallbackCurve, size, tint, tint, YES) imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
}

static NSString *AMSpeedGraphsFilePath(void) {
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    return [docs stringByAppendingPathComponent:@"AMSpeedGraphs.json"];
}

static NSMutableDictionary *AMLoadSpeedGraphsDict(void) {
    NSData *data = [NSData dataWithContentsOfFile:AMSpeedGraphsFilePath()];
    if (!data) return [NSMutableDictionary dictionary];
    id obj = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:nil];
    return [obj isKindOfClass:[NSMutableDictionary class]] ? obj : [NSMutableDictionary dictionary];
}

static void AMSaveSpeedGraphForKey(NSString *key, AMSpeedBezierCurve curve, CGFloat baseSpeed, NSString *presetName) {
    if (!key.length) return;
    NSMutableDictionary *dict = AMLoadSpeedGraphsDict();
    dict[key] = @{
        @"x1": @(curve.x1),
        @"y1": @(curve.y1),
        @"x2": @(curve.x2),
        @"y2": @(curve.y2),
        @"baseSpeed": @(baseSpeed),
        @"preset": presetName ?: @"Cubic Bezier Easing",
    };
    NSData *json = [NSJSONSerialization dataWithJSONObject:dict options:0 error:nil];
    if (json) [json writeToFile:AMSpeedGraphsFilePath() atomically:YES];
}

static BOOL AMLoadSpeedGraphForKey(NSString *key, AMSpeedBezierCurve *outCurve, CGFloat *outBaseSpeed, NSString **outPreset) {
    if (!key.length) return NO;
    NSDictionary *dict = AMLoadSpeedGraphsDict();
    NSDictionary *entry = [dict[key] isKindOfClass:[NSDictionary class]] ? dict[key] : nil;
    if (!entry) return NO;
    if (outCurve) {
        outCurve->x1 = [entry[@"x1"] doubleValue];
        outCurve->y1 = [entry[@"y1"] doubleValue];
        outCurve->x2 = [entry[@"x2"] doubleValue];
        outCurve->y2 = [entry[@"y2"] doubleValue];
    }
    if (outBaseSpeed) {
        CGFloat bs = [entry[@"baseSpeed"] doubleValue];
        *outBaseSpeed = (bs > 0.05 && bs <= 10.0) ? bs : 1.0;
    }
    if (outPreset) {
        *outPreset = [entry[@"preset"] isKindOfClass:[NSString class]] ? entry[@"preset"] : @"Cubic Bezier Easing";
    }
    return YES;
}

// ============================================================================
// Speed Keyframes Model & Persistence
// ============================================================================

static NSString *AMSpeedKeyframesFilePath(void) {
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    return [docs stringByAppendingPathComponent:@"AMSpeedKeyframes.json"];
}

static NSMutableDictionary *AMLoadSpeedKeyframesRoot(void) {
    NSData *data = [NSData dataWithContentsOfFile:AMSpeedKeyframesFilePath()];
    if (!data) return [NSMutableDictionary dictionary];
    id obj = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:nil];
    return [obj isKindOfClass:[NSMutableDictionary class]] ? obj : [NSMutableDictionary dictionary];
}

static NSMutableArray<NSDictionary *> *AMGetSpeedKeyframesForKey(NSString *key) {
    if (!key.length) return [NSMutableArray array];
    NSDictionary *root = AMLoadSpeedKeyframesRoot();
    NSArray *arr = [root[key] isKindOfClass:[NSArray class]] ? root[key] : nil;
    if (!arr) return [NSMutableArray array];
    NSMutableArray *sorted = [arr mutableCopy];
    [sorted sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        double ta = [a[@"t"] doubleValue];
        double tb = [b[@"t"] doubleValue];
        if (ta < tb) return NSOrderedAscending;
        if (ta > tb) return NSOrderedDescending;
        return NSOrderedSame;
    }];
    return sorted;
}

static void AMSaveSpeedKeyframesForKey(NSString *key, NSArray<NSDictionary *> *kfs) {
    if (!key.length) return;
    NSMutableDictionary *root = AMLoadSpeedKeyframesRoot();
    if (kfs.count == 0) {
        [root removeObjectForKey:key];
    } else {
        root[key] = kfs;
    }
    NSData *json = [NSJSONSerialization dataWithJSONObject:root options:0 error:nil];
    if (json) [json writeToFile:AMSpeedKeyframesFilePath() atomically:YES];
}

static double AMCurrentPlayheadSeconds(void) {
    AVPlayer *player = gActivePreviewPlayer;
    if (!player) return 0.0;
    CMTime ct = player.currentTime;
    if (CMTIME_IS_INVALID(ct) || CMTIME_IS_INDEFINITE(ct)) return 0.0;
    double sec = CMTimeGetSeconds(ct);
    return (isfinite(sec) && sec >= 0.0) ? sec : 0.0;
}

static double AMReadCurrentSpeedFromVC(UIViewController *speedVC) {
    UILabel *lbl = (UILabel *)AMCallObjCGetter(speedVC, @"speedValueLabel");
    if ([lbl isKindOfClass:[UILabel class]] && lbl.text.length > 0) {
        double val = [lbl.text doubleValue];
        if (isfinite(val) && val >= 0.05 && val <= 10.0) return val;
    }
    return 1.0;
}

static NSString *AMSpeedLayerKeyForVC(UIViewController *speedVC) {
    void *holderPtr = AMGetRawIvarPtr(speedVC, "holder");
    return [NSString stringWithFormat:@"speed_%p", holderPtr];
}

static NSInteger AMFindKeyframeIndexNearTime(NSArray<NSDictionary *> *kfs, double tSec, double tol) {
    NSInteger bestIdx = NSNotFound;
    double bestDist = tol;
    for (NSInteger i = 0; i < (NSInteger)kfs.count; i++) {
        double dt = fabs([kfs[i][@"t"] doubleValue] - tSec);
        if (dt <= bestDist) {
            bestDist = dt;
            bestIdx = i;
        }
    }
    return bestIdx;
}

static CGFloat AMEvalCubic1D(CGFloat t, CGFloat p1, CGFloat p2) {
    CGFloat u = 1.0 - t;
    return 3.0 * u * u * t * p1 + 3.0 * u * t * t * p2 + t * t * t;
}

static CGFloat AMEvalCubicDerivative1D(CGFloat t, CGFloat p1, CGFloat p2) {
    CGFloat u = 1.0 - t;
    return 3.0 * u * u * p1 + 6.0 * u * t * (p2 - p1) + 3.0 * t * t * (1.0 - p2);
}

// Compute instantaneous speed multiplier (dy/dx) at normalized layer progress u in [0, 1]
static CGFloat AMComputeSpeedMultiplierAtProgress(AMSpeedBezierCurve c, CGFloat u);

static CGFloat AMEvalCubicBezierYForX(AMSpeedBezierCurve c, CGFloat u) {
    if (u <= 0.0) return 0.0;
    if (u >= 1.0) return 1.0;
    CGFloat t = u;
    for (int i = 0; i < 8; i++) {
        CGFloat x = AMEvalCubic1D(t, c.x1, c.x2) - u;
        CGFloat dx = AMEvalCubicDerivative1D(t, c.x1, c.x2);
        if (fabs(dx) < 1e-5) break;
        t -= x / dx;
        if (t < 0.0) t = 0.0;
        if (t > 1.0) t = 1.0;
    }
    return AMEvalCubic1D(t, c.y1, c.y2);
}

// Evaluate effective instantaneous speed at normalized clip progress u in [0, 1]
static double AMEvaluateActiveSpeedAtNormU(double u, double clipDurationSec) {
    if (u < 0.0) u = 0.0;
    if (u > 1.0) u = 1.0;
    NSArray<NSDictionary *> *kfs = gActiveSpeedKeyframes;
    if (kfs.count >= 2) {
        double tSec = u * MAX(0.01, clipDurationSec);
        // Find segment [k, k+1]
        NSDictionary *first = kfs.firstObject;
        NSDictionary *last = kfs.lastObject;
        if (tSec <= [first[@"t"] doubleValue]) return MAX(0.1, [first[@"speed"] doubleValue]);
        if (tSec >= [last[@"t"] doubleValue]) return MAX(0.1, [last[@"speed"] doubleValue]);
        for (NSUInteger i = 0; i + 1 < kfs.count; i++) {
            double t0 = [kfs[i][@"t"] doubleValue];
            double t1 = [kfs[i + 1][@"t"] doubleValue];
            if (tSec >= t0 && tSec <= t1 && t1 > t0 + 1e-4) {
                double localU = (tSec - t0) / (t1 - t0);
                AMSpeedBezierCurve segCurve = {
                    [kfs[i][@"x1"] doubleValue],
                    [kfs[i][@"y1"] doubleValue],
                    [kfs[i][@"x2"] doubleValue],
                    [kfs[i][@"y2"] doubleValue],
                };
                double eased = AMEvalCubicBezierYForX(segCurve, localU);
                double s0 = [kfs[i][@"speed"] doubleValue];
                double s1 = [kfs[i + 1][@"speed"] doubleValue];
                double spd = s0 + (s1 - s0) * eased;
                if (spd < 0.1) spd = 0.1;
                if (spd > 8.0) spd = 8.0;
                return spd;
            }
        }
    }
    if (gActiveSpeedCurveEnabled) {
        double mult = AMComputeSpeedMultiplierAtProgress(gActiveSpeedCurve, u);
        double spd = gActiveSpeedBase * mult;
        if (spd < 0.1) spd = 0.1;
        if (spd > 8.0) spd = 8.0;
        return spd;
    }
    return MAX(0.1, gActiveSpeedBase);
}

static BOOL AMIsCurveNonLinear(AMSpeedBezierCurve c) {
    return (fabs(c.x1 - c.y1) > 0.02 || fabs(c.x2 - c.y2) > 0.02);
}

static BOOL AMHook_compTrackInsertTimeRange(id self, SEL _cmd, CMTimeRange timeRange, AVAssetTrack *track, CMTime startTime, NSError **outError) {
    BOOL ok = gOrigCompTrackInsertTimeRange
        ? ((BOOL (*)(id, SEL, CMTimeRange, AVAssetTrack *, CMTime, NSError **))gOrigCompTrackInsertTimeRange)(self, _cmd, timeRange, track, startTime, outError)
        : NO;
    if (ok && !gInSpeedRampScale && track) {
        NSDictionary *info = @{
            @"track": track,
            @"srcStart": [NSValue valueWithCMTime:timeRange.start],
            @"srcDur": [NSValue valueWithCMTime:timeRange.duration],
            @"atTime": [NSValue valueWithCMTime:startTime],
        };
        objc_setAssociatedObject(self, kAMCompTrackSrcInfoAssocKey, info, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return ok;
}

static void AMHook_compTrackScaleTimeRange(id self, SEL _cmd, CMTimeRange timeRange, CMTime duration) {
    BOOL hasRamp = (!gInSpeedRampScale) &&
                   (gActiveSpeedKeyframes.count >= 2 || (gActiveSpeedCurveEnabled && AMIsCurveNonLinear(gActiveSpeedCurve)));
    NSDictionary *info = hasRamp ? objc_getAssociatedObject(self, kAMCompTrackSrcInfoAssocKey) : nil;
    AVAssetTrack *srcTrack = info[@"track"];
    if (!hasRamp || !srcTrack || CMTIME_IS_INVALID(duration) || CMTimeGetSeconds(duration) <= 0.05) {
        if (gOrigCompTrackScaleTimeRange) {
            ((void (*)(id, SEL, CMTimeRange, CMTime))gOrigCompTrackScaleTimeRange)(self, _cmd, timeRange, duration);
        }
        return;
    }

    CMTime srcStart = [info[@"srcStart"] CMTimeValue];
    CMTime srcDur = [info[@"srcDur"] CMTimeValue];
    double srcDurSec = CMTimeGetSeconds(srcDur);
    double targetTotalSec = CMTimeGetSeconds(duration);
    if (!isfinite(srcDurSec) || srcDurSec <= 0.05 || !isfinite(targetTotalSec) || targetTotalSec <= 0.05) {
        if (gOrigCompTrackScaleTimeRange) {
            ((void (*)(id, SEL, CMTimeRange, CMTime))gOrigCompTrackScaleTimeRange)(self, _cmd, timeRange, duration);
        }
        return;
    }

    const int kSegments = 32;
    double weights[kSegments];
    double weightSum = 0.0;
    for (int i = 0; i < kSegments; i++) {
        double u = (i + 0.5) / (double)kSegments;
        double spd = AMEvaluateActiveSpeedAtNormU(u, targetTotalSec);
        weights[i] = 1.0 / MAX(0.1, spd);
        weightSum += weights[i];
    }
    if (weightSum <= 0.0) {
        if (gOrigCompTrackScaleTimeRange) {
            ((void (*)(id, SEL, CMTimeRange, CMTime))gOrigCompTrackScaleTimeRange)(self, _cmd, timeRange, duration);
        }
        return;
    }

    gInSpeedRampScale = YES;
    AVMutableCompositionTrack *compTrack = (AVMutableCompositionTrack *)self;
    [compTrack removeTimeRange:timeRange];

    CMTimeScale ts = (duration.timescale > 0) ? duration.timescale : 600;
    CMTime cursor = timeRange.start;
    double segSrcSec = srcDurSec / (double)kSegments;
    double srcStartSec = CMTimeGetSeconds(srcStart);

    for (int i = 0; i < kSegments; i++) {
        double s0 = srcStartSec + i * segSrcSec;
        double s1 = (i == kSegments - 1) ? (srcStartSec + srcDurSec) : (srcStartSec + (i + 1) * segSrcSec);
        CMTime segStart = CMTimeMakeWithSeconds(s0, ts);
        CMTime segDur = CMTimeMakeWithSeconds(MAX(0.002, s1 - s0), ts);
        CMTimeRange srcRange = CMTimeRangeMake(segStart, segDur);

        double dstSec = targetTotalSec * (weights[i] / weightSum);
        CMTime dstDur = CMTimeMakeWithSeconds(MAX(0.002, dstSec), ts);

        NSError *err = nil;
        BOOL inserted = ((BOOL (*)(id, SEL, CMTimeRange, AVAssetTrack *, CMTime, NSError **))gOrigCompTrackInsertTimeRange)(
            compTrack, @selector(insertTimeRange:ofTrack:atTime:error:), srcRange, srcTrack, cursor, &err);
        if (inserted) {
            CMTimeRange insertedRange = CMTimeRangeMake(cursor, segDur);
            ((void (*)(id, SEL, CMTimeRange, CMTime))gOrigCompTrackScaleTimeRange)(
                compTrack, _cmd, insertedRange, dstDur);
            cursor = CMTimeAdd(cursor, dstDur);
        }
    }
    gInSpeedRampScale = NO;
}

static void AMRedrawAllKeyframeViewsInView(UIView *v) {
    if (!v) return;
    if ([NSStringFromClass([v class]) isEqualToString:@"_TtC12AlightMotion12KeyframeView"]) {
        [v setNeedsDisplay];
    }
    for (UIView *sub in v.subviews) {
        AMRedrawAllKeyframeViewsInView(sub);
    }
}

static void AMRedrawAllKeyframeViews(void) {
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in ((UIWindowScene *)scene).windows) {
            AMRedrawAllKeyframeViewsInView(w);
        }
    }
}

static float AMGetFloatIvar(id obj, const char *ivarName, float fallback) {
    if (!obj || !ivarName) return fallback;
    Class cls = object_getClass(obj);
    while (cls) {
        Ivar iv = class_getInstanceVariable(cls, ivarName);
        if (iv) {
            ptrdiff_t off = ivar_getOffset(iv);
            float val = *(float *)((uint8_t *)(__bridge void *)obj + off);
            return isfinite(val) ? val : fallback;
        }
        cls = class_getSuperclass(cls);
    }
    return fallback;
}

static void AMHook_keyframeViewDrawRect(id self, SEL _cmd, CGRect rect) {
    if (gOrigKeyframeViewDrawRect) {
        ((void (*)(id, SEL, CGRect))gOrigKeyframeViewDrawRect)(self, _cmd, rect);
    }
    NSArray<NSDictionary *> *kfs = gActiveSpeedKeyframes;
    if (kfs.count == 0) return;

    UIView *kfView = (UIView *)self;
    CGFloat w = kfView.bounds.size.width;
    CGFloat h = kfView.bounds.size.height;
    if (w < 8.0 || h < 8.0) return;

    float scale = AMGetFloatIvar(self, "timeScaleFactor", 1.0f);
    float offset = AMGetFloatIvar(self, "timeOffset", 0.0f);
    if (scale <= 0.0001f) scale = 1.0f;

    CGContextRef cg = UIGraphicsGetCurrentContext();
    if (!cg) return;

    double totalDur = 1.0;
    AVPlayer *player = gActivePreviewPlayer;
    if (player && player.currentItem) {
        double d = CMTimeGetSeconds(player.currentItem.duration);
        if (isfinite(d) && d > 0.05) totalDur = d;
    }

    double now = AMCurrentPlayheadSeconds();
    CGContextSaveGState(cg);
    for (NSDictionary *kf in kfs) {
        double tSec = [kf[@"t"] doubleValue];
        double u = (kf[@"u"] != nil) ? [kf[@"u"] doubleValue] : (tSec / totalDur);
        if (u < 0.0) u = 0.0;
        if (u > 1.0) u = 1.0;
        CGFloat x = (CGFloat)(u * scale + offset) * w;
        if (x < 6.0) x = 6.0;
        if (x > w - 6.0) x = w - 6.0;
        CGFloat cy = h * 0.5;
        CGFloat rx = 5.5;
        CGFloat ry = 7.5;

        UIBezierPath *diamond = [UIBezierPath bezierPath];
        [diamond moveToPoint:CGPointMake(x, cy - ry)];
        [diamond addLineToPoint:CGPointMake(x + rx, cy)];
        [diamond addLineToPoint:CGPointMake(x, cy + ry)];
        [diamond addLineToPoint:CGPointMake(x - rx, cy)];
        [diamond closePath];

        BOOL active = fabs(tSec - now) <= 0.04;
        [(active ? AMAccentGreenColor() : [UIColor whiteColor]) setFill];
        [diamond fill];
        [[UIColor colorWithRed:0.08 green:0.09 blue:0.13 alpha:0.9] setStroke];
        diamond.lineWidth = 1.2;
        [diamond stroke];
    }
    CGContextRestoreGState(cg);
}

static void AMTriggerSpeedCompositionRebuild(UIViewController *speedVC, double targetSpeed) {
    void *vmPtr = AMGetRawIvarPtr(speedVC, "vm");
    if (!vmPtr) return;
    if (targetSpeed < 0.10) targetSpeed = 0.10;
    if (targetSpeed > 8.00) targetSpeed = 8.00;
    int64_t milli = (int64_t)llround(targetSpeed * 1000.0);
    // Nudge by 1 milliSpeed if unchanged so Alight Motion rebuilds AVMutableComposition via our scaleTimeRange hook
    int64_t nudge = (milli > 110) ? (milli - 1) : (milli + 1);
    AMCallEditSpeedVMSetSpeed(vmPtr, nudge);
    AMCallEditSpeedVMSetSpeed(vmPtr, milli);
    AMCallEditSpeedVMRefreshUI(vmPtr);
    AMForceImmediatePreviewRedraw();
}

static CGFloat AMComputeSpeedMultiplierAtProgress(AMSpeedBezierCurve c, CGFloat u) {
    if (u < 0.0) u = 0.0;
    if (u > 1.0) u = 1.0;
    CGFloat t = u;
    for (int i = 0; i < 8; i++) {
        CGFloat x = AMEvalCubic1D(t, c.x1, c.x2) - u;
        CGFloat dx = AMEvalCubicDerivative1D(t, c.x1, c.x2);
        if (fabs(dx) < 1e-5) break;
        t -= x / dx;
        if (t < 0.0) t = 0.0;
        if (t > 1.0) t = 1.0;
    }
    CGFloat dx = AMEvalCubicDerivative1D(t, c.x1, c.x2);
    CGFloat dy = AMEvalCubicDerivative1D(t, c.y1, c.y2);
    if (fabs(dx) < 0.05) dx = (dx >= 0) ? 0.05 : -0.05;
    CGFloat slope = dy / dx;
    if (slope < 0.1) slope = 0.1;
    if (slope > 8.0) slope = 8.0;
    return slope;
}

static UIImage *AMBezierCurveIconImage(AMSpeedBezierCurve c, CGSize size, UIColor *strokeColor, UIColor *dotColor, BOOL drawBox) {
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        CGContextRef cg = ctx.CGContext;
        CGFloat pad = 4.0;
        CGRect r = CGRectInset((CGRect){CGPointZero, size}, pad, pad);
        if (drawBox) {
            CGContextSaveGState(cg);
            CGFloat dash[] = {2.0, 2.0};
            CGContextSetLineDash(cg, 0, dash, 2);
            CGContextSetStrokeColorWithColor(cg, [UIColor colorWithWhite:1.0 alpha:0.25].CGColor);
            CGContextSetLineWidth(cg, 1.0);
            CGContextStrokeRect(cg, r);
            CGContextRestoreGState(cg);
        }
        CGPoint p0 = CGPointMake(CGRectGetMinX(r), CGRectGetMaxY(r));
        CGPoint p3 = CGPointMake(CGRectGetMaxX(r), CGRectGetMinY(r));
        CGPoint p1 = CGPointMake(CGRectGetMinX(r) + c.x1 * r.size.width, CGRectGetMaxY(r) - c.y1 * r.size.height);
        CGPoint p2 = CGPointMake(CGRectGetMinX(r) + c.x2 * r.size.width, CGRectGetMaxY(r) - c.y2 * r.size.height);

        UIBezierPath *path = [UIBezierPath bezierPath];
        [path moveToPoint:p0];
        [path addCurveToPoint:p3 controlPoint1:p1 controlPoint2:p2];
        path.lineWidth = 2.0;
        path.lineCapStyle = kCGLineCapRound;
        [strokeColor setStroke];
        [path stroke];

        [dotColor setFill];
        CGFloat dr = 2.2;
        CGContextFillEllipseInRect(cg, CGRectMake(p0.x - dr, p0.y - dr, dr * 2, dr * 2));
        CGContextFillEllipseInRect(cg, CGRectMake(p3.x - dr, p3.y - dr, dr * 2, dr * 2));
    }];
}

@interface AMSpeedGraphCanvasView : UIView
@property (nonatomic, assign) AMSpeedBezierCurve curve;
@property (nonatomic, assign) BOOL allowOvershoot;
@property (nonatomic, assign) CGFloat baseSpeed;
@property (nonatomic, assign) CGFloat playheadU;
@property (nonatomic, assign) NSInteger activeHandle; // 0=none, 1=P1, 2=P2
@property (nonatomic, copy) void (^onCurveChanged)(AMSpeedBezierCurve curve, BOOL finished);
@end

@implementation AMSpeedGraphCanvasView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor colorWithRed:0.176 green:0.188 blue:0.267 alpha:1.0];
        self.opaque = YES;
        self.curve = (AMSpeedBezierCurve){0.42, 0.00, 0.58, 1.00};
        self.allowOvershoot = YES;
        self.baseSpeed = 1.0;
        self.playheadU = 0.5;
        self.activeHandle = 0;
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
        pan.maximumNumberOfTouches = 1;
        [self addGestureRecognizer:pan];
    }
    return self;
}

- (CGRect)plotRect {
    CGFloat topPad = self.allowOvershoot ? 32.0 : 18.0;
    CGFloat botPad = self.allowOvershoot ? 32.0 : 18.0;
    CGFloat sidePad = 24.0;
    return CGRectMake(sidePad, topPad, MAX(40.0, self.bounds.size.width - sidePad * 2.0), MAX(40.0, self.bounds.size.height - topPad - botPad));
}

- (CGPoint)viewPointForNormX:(CGFloat)nx normY:(CGFloat)ny {
    CGRect r = [self plotRect];
    return CGPointMake(CGRectGetMinX(r) + nx * r.size.width, CGRectGetMaxY(r) - ny * r.size.height);
}

- (void)handlePan:(UIPanGestureRecognizer *)pan {
    CGPoint loc = [pan locationInView:self];
    CGRect r = [self plotRect];
    if (pan.state == UIGestureRecognizerStateBegan) {
        CGPoint h1 = [self viewPointForNormX:self.curve.x1 normY:self.curve.y1];
        CGPoint h2 = [self viewPointForNormX:self.curve.x2 normY:self.curve.y2];
        CGFloat d1 = hypot(loc.x - h1.x, loc.y - h1.y);
        CGFloat d2 = hypot(loc.x - h2.x, loc.y - h2.y);
        if (d1 <= d2 && d1 <= 44.0) {
            self.activeHandle = 1;
        } else if (d2 <= 44.0) {
            self.activeHandle = 2;
        } else {
            self.activeHandle = 0;
        }
    }
    if (self.activeHandle == 0) return;

    CGFloat nx = (loc.x - CGRectGetMinX(r)) / MAX(1.0, r.size.width);
    CGFloat ny = (CGRectGetMaxY(r) - loc.y) / MAX(1.0, r.size.height);
    nx = MIN(1.0, MAX(0.0, nx));
    CGFloat minY = self.allowOvershoot ? -0.45 : 0.0;
    CGFloat maxY = self.allowOvershoot ? 1.45 : 1.0;
    ny = MIN(maxY, MAX(minY, ny));

    AMSpeedBezierCurve c = self.curve;
    if (self.activeHandle == 1) {
        c.x1 = nx;
        c.y1 = ny;
    } else {
        c.x2 = nx;
        c.y2 = ny;
    }
    self.curve = c;
    [self setNeedsDisplay];

    BOOL finished = (pan.state == UIGestureRecognizerStateEnded || pan.state == UIGestureRecognizerStateCancelled);
    if (finished) self.activeHandle = 0;
    if (self.onCurveChanged) self.onCurveChanged(c, finished);
}

- (void)drawRect:(CGRect)rect {
    CGContextRef cg = UIGraphicsGetCurrentContext();
    if (!cg) return;

    CGRect r = [self plotRect];
    // 1. Fine gridlines
    CGContextSaveGState(cg);
    CGContextSetStrokeColorWithColor(cg, [UIColor colorWithWhite:1.0 alpha:0.055].CGColor);
    CGContextSetLineWidth(cg, 1.0);
    NSInteger cols = 10;
    NSInteger rows = 8;
    for (NSInteger i = 0; i <= cols; i++) {
        CGFloat x = CGRectGetMinX(r) + (r.size.width * i) / cols;
        CGContextMoveToPoint(cg, x, 10.0);
        CGContextAddLineToPoint(cg, x, self.bounds.size.height - 10.0);
    }
    for (NSInteger j = 0; j <= rows; j++) {
        CGFloat y = CGRectGetMinY(r) + (r.size.height * j) / rows;
        CGContextMoveToPoint(cg, CGRectGetMinX(r), y);
        CGContextAddLineToPoint(cg, CGRectGetMaxX(r), y);
    }
    CGContextStrokePath(cg);
    CGContextRestoreGState(cg);

    // 2. Dashed horizontal y=0 and y=1 lines
    CGContextSaveGState(cg);
    CGFloat dash[] = {3.5, 3.5};
    CGContextSetLineDash(cg, 0, dash, 2);
    CGContextSetStrokeColorWithColor(cg, [UIColor colorWithWhite:1.0 alpha:0.35].CGColor);
    CGContextSetLineWidth(cg, 1.0);
    CGContextMoveToPoint(cg, CGRectGetMinX(r), CGRectGetMinY(r));
    CGContextAddLineToPoint(cg, CGRectGetMaxX(r), CGRectGetMinY(r));
    CGContextMoveToPoint(cg, CGRectGetMinX(r), CGRectGetMaxY(r));
    CGContextAddLineToPoint(cg, CGRectGetMaxX(r), CGRectGetMaxY(r));
    CGContextStrokePath(cg);

    // Vertical dashed guide line at P1.x (matching screenshot)
    CGPoint p0 = [self viewPointForNormX:0.0 normY:0.0];
    CGPoint p1 = [self viewPointForNormX:self.curve.x1 normY:self.curve.y1];
    CGPoint p2 = [self viewPointForNormX:self.curve.x2 normY:self.curve.y2];
    CGPoint p3 = [self viewPointForNormX:1.0 normY:1.0];

    CGContextSetStrokeColorWithColor(cg, [UIColor colorWithWhite:1.0 alpha:0.45].CGColor);
    CGContextMoveToPoint(cg, p1.x, CGRectGetMinY(r));
    CGContextAddLineToPoint(cg, p1.x, CGRectGetMaxY(r));
    CGContextStrokePath(cg);
    CGContextRestoreGState(cg);

    // 3. Handle tangent arms (white) + Curve (white outer + green middle)
    CGContextSaveGState(cg);
    CGContextSetLineCap(cg, kCGLineCapRound);
    CGContextSetLineWidth(cg, 3.0);

    // Draw full curve in mint green first, then outer handle segments in white
    UIBezierPath *curvePath = [UIBezierPath bezierPath];
    [curvePath moveToPoint:p0];
    [curvePath addCurveToPoint:p3 controlPoint1:p1 controlPoint2:p2];
    curvePath.lineWidth = 3.2;
    curvePath.lineCapStyle = kCGLineCapRound;
    [AMAccentGreenColor() setStroke];
    [curvePath stroke];

    CGContextSetStrokeColorWithColor(cg, [UIColor whiteColor].CGColor);
    CGContextSetLineWidth(cg, 3.2);
    CGContextMoveToPoint(cg, p0.x, p0.y);
    CGContextAddLineToPoint(cg, p1.x, p1.y);
    CGContextMoveToPoint(cg, p3.x, p3.y);
    CGContextAddLineToPoint(cg, p2.x, p2.y);
    CGContextStrokePath(cg);
    CGContextRestoreGState(cg);

    // 4. Endpoint green dots
    [AMAccentGreenColor() setFill];
    CGFloat er = 3.5;
    CGContextFillEllipseInRect(cg, CGRectMake(p0.x - er, p0.y - er, er * 2, er * 2));
    CGContextFillEllipseInRect(cg, CGRectMake(p3.x - er, p3.y - er, er * 2, er * 2));

    // 5. White draggable handles
    CGFloat hr = 11.0;
    [[UIColor whiteColor] setFill];
    CGContextFillEllipseInRect(cg, CGRectMake(p1.x - hr, p1.y - hr, hr * 2, hr * 2));
    CGContextFillEllipseInRect(cg, CGRectMake(p2.x - hr, p2.y - hr, hr * 2, hr * 2));
}

@end

@interface AMSpeedGraphPanelVC : UIViewController
@property (nonatomic, weak) UIViewController *speedVC;
@property (nonatomic, weak) UIViewController *panelVC;
@property (nonatomic, copy) NSString *layerKey;
@property (nonatomic, assign) NSInteger categoryIndex; // 0=Bezier, 1=Ramp, 2=Step
@property (nonatomic, assign) NSInteger presetIndex;
@property (nonatomic, strong) AMSpeedGraphCanvasView *canvasView;
@property (nonatomic, strong) UILabel *presetTitleLabel;
@property (nonatomic, strong) UILabel *speedReadoutLabel;
@property (nonatomic, strong) NSMutableArray<UIButton *> *presetButtons;
@property (nonatomic, strong) NSMutableArray<UIButton *> *categoryButtons;
@property (nonatomic, strong) UIView *categoryPointerView;
@end

@implementation AMSpeedGraphPanelVC

- (const AMSpeedPreset *)currentPresetsArray:(NSInteger *)outCount {
    if (self.categoryIndex == 1) {
        if (outCount) *outCount = kAMRampPresetCount;
        return kAMRampPresets;
    } else if (self.categoryIndex == 2) {
        if (outCount) *outCount = kAMStepPresetCount;
        return kAMStepPresets;
    }
    if (outCount) *outCount = kAMBezierPresetCount;
    return kAMBezierPresets;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithRed:0.125 green:0.133 blue:0.192 alpha:1.0];

    AMSpeedBezierCurve initialCurve = {0.42, 0.00, 0.58, 1.00};
    CGFloat baseSpeed = 1.0;
    NSString *savedPreset = @"Cubic Bezier Easing";
    AMLoadSpeedGraphForKey(self.layerKey, &initialCurve, &baseSpeed, &savedPreset);

    // Left bar (54pt)
    UIView *leftBar = [[UIView alloc] init];
    leftBar.translatesAutoresizingMaskIntoConstraints = NO;
    leftBar.backgroundColor = [UIColor colorWithRed:0.125 green:0.133 blue:0.192 alpha:1.0];
    [self.view addSubview:leftBar];

    UIButton *backBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    backBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [backBtn setImage:[UIImage systemImageNamed:@"chevron.left"] forState:UIControlStateNormal];
    backBtn.tintColor = [UIColor whiteColor];
    [backBtn addTarget:self action:@selector(onTapBack) forControlEvents:UIControlEventTouchUpInside];
    [leftBar addSubview:backBtn];

    UIButton *swapBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    swapBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [swapBtn setImage:[UIImage systemImageNamed:@"arrow.left.arrow.right"] forState:UIControlStateNormal];
    swapBtn.tintColor = [UIColor colorWithWhite:1.0 alpha:0.65];
    [swapBtn addTarget:self action:@selector(onTapSwap) forControlEvents:UIControlEventTouchUpInside];
    [leftBar addSubview:swapBtn];

    UIButton *moreBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    moreBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [moreBtn setImage:[UIImage systemImageNamed:@"ellipsis"] forState:UIControlStateNormal];
    moreBtn.tintColor = [UIColor whiteColor];
    [moreBtn addTarget:self action:@selector(onTapOverflow) forControlEvents:UIControlEventTouchUpInside];
    [leftBar addSubview:moreBtn];

    // Center Graph Canvas
    self.canvasView = [[AMSpeedGraphCanvasView alloc] initWithFrame:CGRectZero];
    self.canvasView.translatesAutoresizingMaskIntoConstraints = NO;
    self.canvasView.curve = initialCurve;
    self.canvasView.baseSpeed = baseSpeed;
    __weak AMSpeedGraphPanelVC *weakSelf = self;
    self.canvasView.onCurveChanged = ^(AMSpeedBezierCurve c, BOOL finished) {
        [weakSelf applyCurveToLayer:c commit:finished];
    };
    [self.view addSubview:self.canvasView];

    // Top-left live speed readout inside canvas
    self.speedReadoutLabel = [[UILabel alloc] init];
    self.speedReadoutLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.speedReadoutLabel.font = AMThemeFont(10.5, UIFontWeightMedium);
    self.speedReadoutLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.55];
    [self.canvasView addSubview:self.speedReadoutLabel];

    // Bottom preset cycler inside canvas: <  Cubic Bezier Easing  >
    UIButton *prevPresetBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    prevPresetBtn.translatesAutoresizingMaskIntoConstraints = NO;
    prevPresetBtn.backgroundColor = [UIColor colorWithRed:0.141 green:0.149 blue:0.212 alpha:0.85];
    prevPresetBtn.layer.cornerRadius = 5.0;
    [prevPresetBtn setImage:[UIImage systemImageNamed:@"chevron.left"] forState:UIControlStateNormal];
    prevPresetBtn.tintColor = [UIColor colorWithWhite:1.0 alpha:0.75];
    [prevPresetBtn addTarget:self action:@selector(onTapPrevPreset) forControlEvents:UIControlEventTouchUpInside];
    [self.canvasView addSubview:prevPresetBtn];

    UIButton *nextPresetBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    nextPresetBtn.translatesAutoresizingMaskIntoConstraints = NO;
    nextPresetBtn.backgroundColor = [UIColor colorWithRed:0.141 green:0.149 blue:0.212 alpha:0.85];
    nextPresetBtn.layer.cornerRadius = 5.0;
    [nextPresetBtn setImage:[UIImage systemImageNamed:@"chevron.right"] forState:UIControlStateNormal];
    nextPresetBtn.tintColor = [UIColor colorWithWhite:1.0 alpha:0.75];
    [nextPresetBtn addTarget:self action:@selector(onTapNextPreset) forControlEvents:UIControlEventTouchUpInside];
    [self.canvasView addSubview:nextPresetBtn];

    self.presetTitleLabel = [[UILabel alloc] init];
    self.presetTitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.presetTitleLabel.font = AMThemeFont(12.0, UIFontWeightMedium);
    self.presetTitleLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.65];
    self.presetTitleLabel.textAlignment = NSTextAlignmentCenter;
    self.presetTitleLabel.text = savedPreset;
    [self.canvasView addSubview:self.presetTitleLabel];

    // Right Preset Column (56pt)
    UIStackView *presetStack = [[UIStackView alloc] init];
    presetStack.translatesAutoresizingMaskIntoConstraints = NO;
    presetStack.axis = UILayoutConstraintAxisVertical;
    presetStack.distribution = UIStackViewDistributionFillEqually;
    presetStack.spacing = 6.0;
    [self.view addSubview:presetStack];

    self.presetButtons = [NSMutableArray array];
    for (NSInteger i = 0; i < 4; i++) {
        UIButton *pb = [UIButton buttonWithType:UIButtonTypeCustom];
        pb.tag = i;
        pb.layer.cornerRadius = 6.0;
        pb.backgroundColor = [UIColor clearColor];
        [pb addTarget:self action:@selector(onTapPresetButton:) forControlEvents:UIControlEventTouchUpInside];
        [presetStack addArrangedSubview:pb];
        [self.presetButtons addObject:pb];
    }

    // Far-right Category Column (56pt)
    UIView *catBar = [[UIView alloc] init];
    catBar.translatesAutoresizingMaskIntoConstraints = NO;
    catBar.backgroundColor = [UIColor colorWithRed:0.125 green:0.133 blue:0.192 alpha:1.0];
    [self.view addSubview:catBar];

    UIStackView *catStack = [[UIStackView alloc] init];
    catStack.translatesAutoresizingMaskIntoConstraints = NO;
    catStack.axis = UILayoutConstraintAxisVertical;
    catStack.distribution = UIStackViewDistributionFillEqually;
    catStack.spacing = 8.0;
    [catBar addSubview:catStack];

    self.categoryButtons = [NSMutableArray array];
    for (NSInteger i = 0; i < 3; i++) {
        UIButton *cb = [UIButton buttonWithType:UIButtonTypeCustom];
        cb.tag = i;
        cb.layer.cornerRadius = 8.0;
        [cb addTarget:self action:@selector(onTapCategory:) forControlEvents:UIControlEventTouchUpInside];
        [catStack addArrangedSubview:cb];
        [self.categoryButtons addObject:cb];
    }

    [NSLayoutConstraint activateConstraints:@[
        [leftBar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [leftBar.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [leftBar.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [leftBar.widthAnchor constraintEqualToConstant:52.0],

        [backBtn.topAnchor constraintEqualToAnchor:leftBar.topAnchor constant:12.0],
        [backBtn.centerXAnchor constraintEqualToAnchor:leftBar.centerXAnchor],
        [backBtn.widthAnchor constraintEqualToConstant:40.0],
        [backBtn.heightAnchor constraintEqualToConstant:36.0],

        [swapBtn.centerYAnchor constraintEqualToAnchor:leftBar.centerYAnchor],
        [swapBtn.centerXAnchor constraintEqualToAnchor:leftBar.centerXAnchor],
        [swapBtn.widthAnchor constraintEqualToConstant:40.0],
        [swapBtn.heightAnchor constraintEqualToConstant:36.0],

        [moreBtn.bottomAnchor constraintEqualToAnchor:leftBar.bottomAnchor constant:-12.0],
        [moreBtn.centerXAnchor constraintEqualToAnchor:leftBar.centerXAnchor],
        [moreBtn.widthAnchor constraintEqualToConstant:40.0],
        [moreBtn.heightAnchor constraintEqualToConstant:36.0],

        [catBar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [catBar.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [catBar.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [catBar.widthAnchor constraintEqualToConstant:54.0],

        [catStack.topAnchor constraintEqualToAnchor:catBar.topAnchor constant:10.0],
        [catStack.bottomAnchor constraintEqualToAnchor:catBar.bottomAnchor constant:-10.0],
        [catStack.leadingAnchor constraintEqualToAnchor:catBar.leadingAnchor constant:4.0],
        [catStack.trailingAnchor constraintEqualToAnchor:catBar.trailingAnchor constant:-4.0],

        [presetStack.trailingAnchor constraintEqualToAnchor:catBar.leadingAnchor constant:-6.0],
        [presetStack.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:8.0],
        [presetStack.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor constant:-8.0],
        [presetStack.widthAnchor constraintEqualToConstant:50.0],

        [self.canvasView.leadingAnchor constraintEqualToAnchor:leftBar.trailingAnchor],
        [self.canvasView.trailingAnchor constraintEqualToAnchor:presetStack.leadingAnchor constant:-6.0],
        [self.canvasView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.canvasView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],

        [self.speedReadoutLabel.topAnchor constraintEqualToAnchor:self.canvasView.topAnchor constant:6.0],
        [self.speedReadoutLabel.leadingAnchor constraintEqualToAnchor:self.canvasView.leadingAnchor constant:10.0],

        [prevPresetBtn.leadingAnchor constraintEqualToAnchor:self.canvasView.leadingAnchor constant:8.0],
        [prevPresetBtn.bottomAnchor constraintEqualToAnchor:self.canvasView.bottomAnchor constant:-6.0],
        [prevPresetBtn.widthAnchor constraintEqualToConstant:28.0],
        [prevPresetBtn.heightAnchor constraintEqualToConstant:24.0],

        [nextPresetBtn.trailingAnchor constraintEqualToAnchor:self.canvasView.trailingAnchor constant:-8.0],
        [nextPresetBtn.bottomAnchor constraintEqualToAnchor:self.canvasView.bottomAnchor constant:-6.0],
        [nextPresetBtn.widthAnchor constraintEqualToConstant:28.0],
        [nextPresetBtn.heightAnchor constraintEqualToConstant:24.0],

        [self.presetTitleLabel.centerYAnchor constraintEqualToAnchor:prevPresetBtn.centerYAnchor],
        [self.presetTitleLabel.leadingAnchor constraintEqualToAnchor:prevPresetBtn.trailingAnchor constant:6.0],
        [self.presetTitleLabel.trailingAnchor constraintEqualToAnchor:nextPresetBtn.leadingAnchor constant:-6.0],
    ]];

    [self refreshPresetAndCategoryIcons];
    [self updateReadout];
}

- (void)refreshPresetAndCategoryIcons {
    NSInteger count = 0;
    const AMSpeedPreset *presets = [self currentPresetsArray:&count];
    NSArray<NSString *> *cubicPresetNames = @[
        @"ic_easingcurve_linear",
        @"ic_easingcurve_easein",
        @"ic_easingcurve_easeout",
        @"ic_easingcurve_easeinout",
    ];
    for (NSInteger i = 0; i < (NSInteger)self.presetButtons.count; i++) {
        UIButton *pb = self.presetButtons[i];
        if (i < count) {
            pb.hidden = NO;
            pb.tintColor = [UIColor whiteColor];
            NSString *asset = (self.categoryIndex == 0 && i < (NSInteger)cubicPresetNames.count) ? cubicPresetNames[i] : nil;
            UIImage *img = AMNativeEasingIcon(asset, presets[i].curve, CGSizeMake(34.0, 34.0), [UIColor whiteColor]);
            [pb setImage:img forState:UIControlStateNormal];
        } else {
            pb.hidden = YES;
        }
    }

    NSArray<NSString *> *catAssetNames = @[
        @"ic_easingcurve_category_cubic",
        @"ic_easingcurve_category_physical",
        @"ic_easingcurve_category_step",
    ];
    AMSpeedBezierCurve catCurves[3] = {
        {0.42, 0.00, 0.58, 1.00},
        {0.90, 0.05, 0.10, 0.95},
        {0.95, 0.00, 0.95, 1.00},
    };
    for (NSInteger i = 0; i < (NSInteger)self.categoryButtons.count; i++) {
        UIButton *cb = self.categoryButtons[i];
        BOOL active = (i == self.categoryIndex);
        cb.backgroundColor = active ? [UIColor colorWithRed:0.075 green:0.082 blue:0.122 alpha:1.0] : [UIColor clearColor];
        UIColor *col = active ? AMAccentGreenColor() : [UIColor colorWithWhite:1.0 alpha:0.75];
        cb.tintColor = col;
        UIImage *img = AMNativeEasingIcon(catAssetNames[i], catCurves[i], CGSizeMake(32.0, 32.0), col);
        [cb setImage:img forState:UIControlStateNormal];
    }
}

- (void)updateReadout {
    AMSpeedBezierCurve c = self.canvasView.curve;
    CGFloat midMult = AMComputeSpeedMultiplierAtProgress(c, 0.5);
    CGFloat eff = self.canvasView.baseSpeed * midMult;
    self.speedReadoutLabel.text = [NSString stringWithFormat:@"%.2fx  (%.2f, %.2f) (%.2f, %.2f)",
                                   eff, c.x1, c.y1, c.x2, c.y2];
}

- (void)applyCurveToLayer:(AMSpeedBezierCurve)curve commit:(BOOL)commit {
    [self updateReadout];
    AMSaveSpeedGraphForKey(self.layerKey, curve, self.canvasView.baseSpeed, self.presetTitleLabel.text);

    gActiveSpeedCurve = curve;
    gActiveSpeedCurveEnabled = AMIsCurveNonLinear(curve);
    gActiveSpeedBase = self.canvasView.baseSpeed;

    NSMutableArray<NSDictionary *> *kfs = AMGetSpeedKeyframesForKey(self.layerKey);
    if (kfs.count >= 2) {
        double now = AMCurrentPlayheadSeconds();
        NSInteger segIdx = 0;
        for (NSInteger i = 0; i + 1 < (NSInteger)kfs.count; i++) {
            if (now >= [kfs[i][@"t"] doubleValue]) segIdx = i;
        }
        NSMutableDictionary *mut = [kfs[segIdx] mutableCopy];
        mut[@"x1"] = @(curve.x1);
        mut[@"y1"] = @(curve.y1);
        mut[@"x2"] = @(curve.x2);
        mut[@"y2"] = @(curve.y2);
        kfs[segIdx] = mut;
        AMSaveSpeedKeyframesForKey(self.layerKey, kfs);
        gActiveSpeedKeyframes = [kfs copy];
    }

    if (!commit) return;
    // Rebuild AVMutableComposition via our 32-segment variable-speed scaleTimeRange hook
    // while keeping total clip duration locked to baseSpeed.
    AMTriggerSpeedCompositionRebuild(self.speedVC, self.canvasView.baseSpeed);
    AMRedrawAllKeyframeViews();
}

- (void)onTapPresetButton:(UIButton *)sender {
    NSInteger count = 0;
    const AMSpeedPreset *presets = [self currentPresetsArray:&count];
    if (sender.tag < 0 || sender.tag >= count) return;
    self.presetIndex = sender.tag;
    AMSpeedPreset p = presets[sender.tag];
    self.canvasView.curve = p.curve;
    [self.canvasView setNeedsDisplay];
    self.presetTitleLabel.text = [NSString stringWithUTF8String:p.name];
    [self applyCurveToLayer:p.curve commit:YES];
}

- (void)onTapPrevPreset {
    NSInteger count = 0;
    const AMSpeedPreset *presets = [self currentPresetsArray:&count];
    if (count <= 0) return;
    self.presetIndex = (self.presetIndex - 1 + count) % count;
    AMSpeedPreset p = presets[self.presetIndex];
    self.canvasView.curve = p.curve;
    [self.canvasView setNeedsDisplay];
    self.presetTitleLabel.text = [NSString stringWithUTF8String:p.name];
    [self applyCurveToLayer:p.curve commit:YES];
}

- (void)onTapNextPreset {
    NSInteger count = 0;
    const AMSpeedPreset *presets = [self currentPresetsArray:&count];
    if (count <= 0) return;
    self.presetIndex = (self.presetIndex + 1) % count;
    AMSpeedPreset p = presets[self.presetIndex];
    self.canvasView.curve = p.curve;
    [self.canvasView setNeedsDisplay];
    self.presetTitleLabel.text = [NSString stringWithUTF8String:p.name];
    [self applyCurveToLayer:p.curve commit:YES];
}

- (void)onTapCategory:(UIButton *)sender {
    self.categoryIndex = sender.tag;
    self.presetIndex = 0;
    [self refreshPresetAndCategoryIcons];
}

- (void)onTapSwap {
    AMSpeedBezierCurve c = self.canvasView.curve;
    AMSpeedBezierCurve swapped = {1.0 - c.x2, 1.0 - c.y2, 1.0 - c.x1, 1.0 - c.y1};
    self.canvasView.curve = swapped;
    [self.canvasView setNeedsDisplay];
    self.presetTitleLabel.text = @"Reversed Curve";
    [self applyCurveToLayer:swapped commit:YES];
}

- (void)onTapOverflow {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Speed Graph"
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    __weak AMSpeedGraphPanelVC *weakSelf = self;
    [sheet addAction:[UIAlertAction actionWithTitle:@"Reset to Linear (1.0x)" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        AMSpeedBezierCurve lin = {0.0, 0.0, 1.0, 1.0};
        weakSelf.canvasView.baseSpeed = 1.0;
        weakSelf.canvasView.curve = lin;
        [weakSelf.canvasView setNeedsDisplay];
        weakSelf.presetTitleLabel.text = @"Linear";
        [weakSelf applyCurveToLayer:lin commit:YES];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Copy Curve" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        gCopiedSpeedCurve = weakSelf.canvasView.curve;
        gHasCopiedSpeedCurve = YES;
    }]];
    if (gHasCopiedSpeedCurve) {
        [sheet addAction:[UIAlertAction actionWithTitle:@"Paste Curve" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
            weakSelf.canvasView.curve = gCopiedSpeedCurve;
            [weakSelf.canvasView setNeedsDisplay];
            weakSelf.presetTitleLabel.text = @"Pasted Curve";
            [weakSelf applyCurveToLayer:gCopiedSpeedCurve commit:YES];
        }]];
    }
    NSString *ovTitle = self.canvasView.allowOvershoot ? @"Clamp Handles to [0, 1]" : @"Allow Overshoot Handles";
    [sheet addAction:[UIAlertAction actionWithTitle:ovTitle style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        weakSelf.canvasView.allowOvershoot = !weakSelf.canvasView.allowOvershoot;
        [weakSelf.canvasView setNeedsDisplay];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    if (sheet.popoverPresentationController) {
        sheet.popoverPresentationController.sourceView = self.view;
        sheet.popoverPresentationController.sourceRect = CGRectMake(26.0, self.view.bounds.size.height - 30.0, 1.0, 1.0);
    }
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)onTapBack {
    [self willMoveToParentViewController:nil];
    [self.view removeFromSuperview];
    [self removeFromParentViewController];
}

@end

@interface AMSpeedGraphButtonHelper : NSObject
+ (void)openGraphForSpeedVC:(UIViewController *)speedVC;
+ (void)refreshKeyframeUIForSpeedVC:(UIViewController *)speedVC;
+ (void)toggleKeyframeForSpeedVC:(UIViewController *)speedVC;
+ (void)jumpKeyframeForSpeedVC:(UIViewController *)speedVC direction:(NSInteger)dir;
@end

@implementation AMSpeedGraphButtonHelper

+ (void)refreshKeyframeUIForSpeedVC:(UIViewController *)speedVC {
    if (!speedVC) return;
    UIButton *kfBtn = objc_getAssociatedObject(speedVC, kAMSpeedKfBtnAssocKey);
    UILabel *countLbl = objc_getAssociatedObject(speedVC, kAMSpeedKfCountLblAssocKey);
    UIButton *prevBtn = objc_getAssociatedObject(speedVC, kAMSpeedKfPrevBtnAssocKey);
    UIButton *nextBtn = objc_getAssociatedObject(speedVC, kAMSpeedKfNextBtnAssocKey);
    if (!kfBtn) return;

    NSString *key = AMSpeedLayerKeyForVC(speedVC);
    NSArray<NSDictionary *> *kfs = AMGetSpeedKeyframesForKey(key);
    double now = AMCurrentPlayheadSeconds();
    BOOL onKf = (AMFindKeyframeIndexNearTime(kfs, now, 0.03) != NSNotFound);

    UIImage *kfIcon = [UIImage imageNamed:(onKf ? @"ic_keyframe_sign_select" : @"ic_keyframe_sign")]
                   ?: [UIImage imageNamed:@"ic_keyframe"]
                   ?: [UIImage systemImageNamed:(onKf ? @"diamond.fill" : @"diamond")];
    if (kfIcon) {
        [kfBtn setImage:[kfIcon imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate] forState:UIControlStateNormal];
    }
    kfBtn.tintColor = onKf ? AMAccentGreenColor() : [UIColor whiteColor];

    if (countLbl) {
        countLbl.text = kfs.count > 0 ? [NSString stringWithFormat:@"%lu", (unsigned long)kfs.count] : @"";
        countLbl.hidden = (kfs.count == 0);
    }
    BOOL hasNav = (kfs.count > 0);
    if (prevBtn) prevBtn.alpha = hasNav ? 0.9 : 0.35;
    if (nextBtn) nextBtn.alpha = hasNav ? 0.9 : 0.35;
}

+ (void)toggleKeyframeForSpeedVC:(UIViewController *)speedVC {
    if (!speedVC) return;
    NSString *key = AMSpeedLayerKeyForVC(speedVC);
    NSMutableArray<NSDictionary *> *kfs = AMGetSpeedKeyframesForKey(key);
    double now = AMCurrentPlayheadSeconds();
    double totalDur = 1.0;
    if (gActivePreviewPlayer && gActivePreviewPlayer.currentItem) {
        double d = CMTimeGetSeconds(gActivePreviewPlayer.currentItem.duration);
        if (isfinite(d) && d > 0.05) totalDur = d;
    }
    double normU = MIN(1.0, MAX(0.0, now / totalDur));
    double spd = AMReadCurrentSpeedFromVC(speedVC);

    NSInteger existing = AMFindKeyframeIndexNearTime(kfs, now, 0.04);
    if (existing != NSNotFound) {
        [kfs removeObjectAtIndex:existing];
    } else {
        [kfs addObject:@{
            @"t": @(now),
            @"u": @(normU),
            @"speed": @(spd),
            @"x1": @(gActiveSpeedCurveEnabled ? gActiveSpeedCurve.x1 : 0.42),
            @"y1": @(gActiveSpeedCurveEnabled ? gActiveSpeedCurve.y1 : 0.00),
            @"x2": @(gActiveSpeedCurveEnabled ? gActiveSpeedCurve.x2 : 0.58),
            @"y2": @(gActiveSpeedCurveEnabled ? gActiveSpeedCurve.y2 : 1.00),
        }];
        [kfs sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            double ta = [a[@"t"] doubleValue];
            double tb = [b[@"t"] doubleValue];
            if (ta < tb) return NSOrderedAscending;
            if (ta > tb) return NSOrderedDescending;
            return NSOrderedSame;
        }];
    }
    AMSaveSpeedKeyframesForKey(key, kfs);
    gActiveSpeedKeyframes = [kfs copy];
    gActiveSpeedBase = spd;
    [self refreshKeyframeUIForSpeedVC:speedVC];
    AMRedrawAllKeyframeViews();
    if (kfs.count >= 2) {
        AMTriggerSpeedCompositionRebuild(speedVC, spd);
    }
    UIImpactFeedbackGenerator *haptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [haptic impactOccurred];
}

+ (void)jumpKeyframeForSpeedVC:(UIViewController *)speedVC direction:(NSInteger)dir {
    if (!speedVC) return;
    NSString *key = AMSpeedLayerKeyForVC(speedVC);
    NSArray<NSDictionary *> *kfs = AMGetSpeedKeyframesForKey(key);
    if (kfs.count == 0) return;

    double now = AMCurrentPlayheadSeconds();
    NSDictionary *target = nil;
    if (dir < 0) {
        for (NSInteger i = (NSInteger)kfs.count - 1; i >= 0; i--) {
            if ([kfs[i][@"t"] doubleValue] < now - 0.03) {
                target = kfs[i];
                break;
            }
        }
        if (!target) target = kfs.lastObject;
    } else {
        for (NSInteger i = 0; i < (NSInteger)kfs.count; i++) {
            if ([kfs[i][@"t"] doubleValue] > now + 0.03) {
                target = kfs[i];
                break;
            }
        }
        if (!target) target = kfs.firstObject;
    }
    if (!target) return;

    double tSec = [target[@"t"] doubleValue];
    double spd = [target[@"speed"] doubleValue];
    AVPlayer *player = gActivePreviewPlayer;
    if (player) {
        CMTime seekT = CMTimeMakeWithSeconds(tSec, 600);
        [player seekToTime:seekT toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero completionHandler:^(BOOL finished) {
            (void)finished;
            dispatch_async(dispatch_get_main_queue(), ^{
                void *vmPtr = AMGetRawIvarPtr(speedVC, "vm");
                if (vmPtr && spd >= 0.05 && spd <= 10.0) {
                    AMCallEditSpeedVMSetSpeed(vmPtr, (int64_t)llround(spd * 1000.0));
                    AMCallEditSpeedVMRefreshUI(vmPtr);
                }
                AMForceImmediatePreviewRedraw();
                [self refreshKeyframeUIForSpeedVC:speedVC];
            });
        }];
    } else {
        void *vmPtr = AMGetRawIvarPtr(speedVC, "vm");
        if (vmPtr && spd >= 0.05 && spd <= 10.0) {
            AMCallEditSpeedVMSetSpeed(vmPtr, (int64_t)llround(spd * 1000.0));
            AMCallEditSpeedVMRefreshUI(vmPtr);
            AMForceImmediatePreviewRedraw();
        }
        [self refreshKeyframeUIForSpeedVC:speedVC];
    }
}

+ (void)openGraphForSpeedVC:(UIViewController *)speedVC {
    if (!speedVC) return;
    UIViewController *panelVC = speedVC.parentViewController;
    while (panelVC && ![NSStringFromClass([panelVC class]) containsString:@"EditSpeedControlPanelVC"]) {
        panelVC = panelVC.parentViewController;
    }
    UIViewController *hostVC = panelVC ?: speedVC;

    // Avoid duplicate presentation
    for (UIViewController *child in hostVC.childViewControllers) {
        if ([child isKindOfClass:[AMSpeedGraphPanelVC class]]) {
            return;
        }
    }

    AMSpeedGraphPanelVC *graphVC = [[AMSpeedGraphPanelVC alloc] init];
    graphVC.speedVC = speedVC;
    graphVC.panelVC = hostVC;
    graphVC.layerKey = AMSpeedLayerKeyForVC(speedVC);

    [hostVC addChildViewController:graphVC];
    graphVC.view.frame = hostVC.view.bounds;
    graphVC.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [hostVC.view addSubview:graphVC.view];
    [graphVC didMoveToParentViewController:hostVC];
}

@end

static void AMEnsureSpeedGraphButton(UIViewController *speedVC) {
    if (!speedVC || !speedVC.view) return;

    UIViewController *panelVC = speedVC.parentViewController;
    while (panelVC && ![NSStringFromClass([panelVC class]) containsString:@"EditSpeedControlPanelVC"]) {
        panelVC = panelVC.parentViewController;
    }

    UIView *targetHost = (panelVC && panelVC.view) ? panelVC.view : speedVC.view;
    if (!targetHost) {
        return;
    }

    UIButton *btn = objc_getAssociatedObject(speedVC, kAMSpeedGraphBtnAssocKey);
    UIView *existingToolbar = objc_getAssociatedObject(speedVC, kAMSpeedKfBarAssocKey);
    if (existingToolbar && existingToolbar.superview != targetHost) {
        [existingToolbar removeFromSuperview];
        [targetHost addSubview:existingToolbar];
        [NSLayoutConstraint activateConstraints:@[
            [existingToolbar.trailingAnchor constraintEqualToAnchor:targetHost.trailingAnchor constant:-14.0],
            [existingToolbar.topAnchor constraintEqualToAnchor:targetHost.topAnchor constant:4.0],
            [existingToolbar.heightAnchor constraintEqualToConstant:32.0],
        ]];
    }

    if (!btn) {
        UIView *hostView = targetHost;

        // Compact horizontal toolbar: [<] [◇] [N] [>] [Graph]
        UIStackView *toolbar = [[UIStackView alloc] init];
        toolbar.translatesAutoresizingMaskIntoConstraints = NO;
        toolbar.axis = UILayoutConstraintAxisHorizontal;
        toolbar.alignment = UIStackViewAlignmentCenter;
        toolbar.spacing = 6.0;
        [hostView addSubview:toolbar];

        UIButton *prevBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        prevBtn.translatesAutoresizingMaskIntoConstraints = NO;
        prevBtn.accessibilityLabel = @"Previous Speed Keyframe";
        [prevBtn setImage:[UIImage systemImageNamed:@"chevron.left"] forState:UIControlStateNormal];
        prevBtn.tintColor = [UIColor whiteColor];

        UIButton *kfBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        kfBtn.translatesAutoresizingMaskIntoConstraints = NO;
        kfBtn.accessibilityLabel = @"Add or Remove Speed Keyframe";
        kfBtn.tintColor = [UIColor whiteColor];
        kfBtn.imageView.contentMode = UIViewContentModeScaleAspectFit;

        UILabel *countLbl = [[UILabel alloc] init];
        countLbl.translatesAutoresizingMaskIntoConstraints = NO;
        countLbl.font = AMThemeFont(10.5, UIFontWeightSemibold);
        countLbl.textColor = AMAccentGreenColor();
        countLbl.hidden = YES;

        UIButton *nextBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        nextBtn.translatesAutoresizingMaskIntoConstraints = NO;
        nextBtn.accessibilityLabel = @"Next Speed Keyframe";
        [nextBtn setImage:[UIImage systemImageNamed:@"chevron.right"] forState:UIControlStateNormal];
        nextBtn.tintColor = [UIColor whiteColor];

        btn = [UIButton buttonWithType:UIButtonTypeSystem];
        btn.translatesAutoresizingMaskIntoConstraints = NO;
        btn.accessibilityLabel = @"Speed Graph Editor";
        btn.backgroundColor = [UIColor clearColor];
        btn.tintColor = [UIColor whiteColor];
        btn.imageView.contentMode = UIViewContentModeScaleAspectFit;

        UIImage *nativeIcon = [UIImage imageNamed:@"ic_easing"]
                           ?: [UIImage imageNamed:@"icon_easing"]
                           ?: [UIImage imageNamed:@"ic_easingcurve_category_cubic"];
        if (nativeIcon) {
            nativeIcon = [nativeIcon imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
        } else {
            nativeIcon = AMBezierCurveIconImage((AMSpeedBezierCurve){0.42, 0.00, 0.58, 1.00},
                                                CGSizeMake(24.0, 24.0),
                                                [UIColor whiteColor],
                                                [UIColor whiteColor],
                                                YES);
        }
        [btn setImage:nativeIcon forState:UIControlStateNormal];

        __weak UIViewController *weakSpeedVC = speedVC;
        [prevBtn addAction:[UIAction actionWithHandler:^(__kindof UIAction * _Nonnull action) {
            (void)action;
            [AMSpeedGraphButtonHelper jumpKeyframeForSpeedVC:weakSpeedVC direction:-1];
        }] forControlEvents:UIControlEventTouchUpInside];
        [kfBtn addAction:[UIAction actionWithHandler:^(__kindof UIAction * _Nonnull action) {
            (void)action;
            [AMSpeedGraphButtonHelper toggleKeyframeForSpeedVC:weakSpeedVC];
        }] forControlEvents:UIControlEventTouchUpInside];
        [nextBtn addAction:[UIAction actionWithHandler:^(__kindof UIAction * _Nonnull action) {
            (void)action;
            [AMSpeedGraphButtonHelper jumpKeyframeForSpeedVC:weakSpeedVC direction:1];
        }] forControlEvents:UIControlEventTouchUpInside];
        [btn addAction:[UIAction actionWithHandler:^(__kindof UIAction * _Nonnull action) {
            (void)action;
            [AMSpeedGraphButtonHelper openGraphForSpeedVC:weakSpeedVC];
        }] forControlEvents:UIControlEventTouchUpInside];

        [toolbar addArrangedSubview:prevBtn];
        [toolbar addArrangedSubview:kfBtn];
        [toolbar addArrangedSubview:countLbl];
        [toolbar addArrangedSubview:nextBtn];
        [toolbar addArrangedSubview:btn];

        [NSLayoutConstraint activateConstraints:@[
            [prevBtn.widthAnchor constraintEqualToConstant:24.0],
            [prevBtn.heightAnchor constraintEqualToConstant:28.0],
            [kfBtn.widthAnchor constraintEqualToConstant:28.0],
            [kfBtn.heightAnchor constraintEqualToConstant:28.0],
            [nextBtn.widthAnchor constraintEqualToConstant:24.0],
            [nextBtn.heightAnchor constraintEqualToConstant:28.0],
            [btn.widthAnchor constraintEqualToConstant:30.0],
            [btn.heightAnchor constraintEqualToConstant:30.0],
            [toolbar.trailingAnchor constraintEqualToAnchor:hostView.trailingAnchor constant:-14.0],
            [toolbar.topAnchor constraintEqualToAnchor:hostView.topAnchor constant:4.0],
            [toolbar.heightAnchor constraintEqualToConstant:32.0],
        ]];

        objc_setAssociatedObject(speedVC, kAMSpeedKfBarAssocKey, toolbar, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(speedVC, kAMSpeedKfPrevBtnAssocKey, prevBtn, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(speedVC, kAMSpeedKfBtnAssocKey, kfBtn, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(speedVC, kAMSpeedKfCountLblAssocKey, countLbl, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(speedVC, kAMSpeedKfNextBtnAssocKey, nextBtn, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(speedVC, kAMSpeedGraphBtnAssocKey, btn, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    UIView *toolbar = objc_getAssociatedObject(speedVC, kAMSpeedKfBarAssocKey);
    UIView *cover = (UIView *)AMCallObjCGetter(speedVC, @"speedControlCover");
    BOOL disabled = (cover && !cover.hidden && cover.alpha > 0.01);
    if (toolbar) {
        toolbar.hidden = disabled;
        if (toolbar.superview) [toolbar.superview bringSubviewToFront:toolbar];
    }
    [AMSpeedGraphButtonHelper refreshKeyframeUIForSpeedVC:speedVC];
}

static void AMHook_editSpeedVCViewDidLoad(id self, SEL _cmd) {
    if (gOrigEditSpeedVCViewDidLoad) {
        ((void (*)(id, SEL))gOrigEditSpeedVCViewDidLoad)(self, _cmd);
    }
    AMEnsureSpeedGraphButton((UIViewController *)self);
}

static void AMHook_editSpeedVCViewWillAppear(id self, SEL _cmd, BOOL animated) {
    if (gOrigEditSpeedVCViewWillAppear) {
        ((void (*)(id, SEL, BOOL))gOrigEditSpeedVCViewWillAppear)(self, _cmd, animated);
    }
    AMEnsureSpeedGraphButton((UIViewController *)self);
}

static void AMHook_editSpeedVCViewDidLayout(id self, SEL _cmd) {
    if (gOrigEditSpeedVCViewDidLayout) {
        ((void (*)(id, SEL))gOrigEditSpeedVCViewDidLayout)(self, _cmd);
    }
    AMEnsureSpeedGraphButton((UIViewController *)self);
}

static void AMHook_editSpeedPanelViewDidLoad(id self, SEL _cmd) {
    if (gOrigEditSpeedPanelViewDidLoad) {
        ((void (*)(id, SEL))gOrigEditSpeedPanelViewDidLoad)(self, _cmd);
    }
}

// ============================================================================
// Constructor: Install All Hooks Safely on Launch
// ============================================================================

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

    AMSwizzleMethod(@"_TtC12AlightMotion22EffectPickerCategoryVC",
                    @"viewWillAppear:",
                    (IMP)AMHook_effectCategoryViewWillAppear,
                    &gOrigEffectCatViewWillAppear);

    AMSwizzleMethod(@"_TtC12AlightMotion22EffectPickerCategoryVC",
                    @"collectionView:willDisplayCell:forItemAtIndexPath:",
                    (IMP)AMHook_effectCatWillDisplayCell,
                    &gOrigEffectCatWillDisplayCell);

    AMSwizzleMethod(@"UIViewController",
                    @"presentViewController:animated:completion:",
                    (IMP)AMHook_presentViewController,
                    &gOrigPresentViewController);

    AMSwizzleMethod(@"_TtC12AlightMotion11EditSpeedVC",
                    @"viewDidLoad",
                    (IMP)AMHook_editSpeedVCViewDidLoad,
                    &gOrigEditSpeedVCViewDidLoad);

    AMSwizzleMethod(@"_TtC12AlightMotion11EditSpeedVC",
                    @"viewWillAppear:",
                    (IMP)AMHook_editSpeedVCViewWillAppear,
                    &gOrigEditSpeedVCViewWillAppear);

    AMSwizzleMethod(@"_TtC12AlightMotion11EditSpeedVC",
                    @"viewDidLayoutSubviews",
                    (IMP)AMHook_editSpeedVCViewDidLayout,
                    &gOrigEditSpeedVCViewDidLayout);

    AMSwizzleMethod(@"_TtC12AlightMotion23EditSpeedControlPanelVC",
                    @"viewDidLoad",
                    (IMP)AMHook_editSpeedPanelViewDidLoad,
                    &gOrigEditSpeedPanelViewDidLoad);

    AMSwizzleMethod(@"AVMutableCompositionTrack",
                    @"insertTimeRange:ofTrack:atTime:error:",
                    (IMP)AMHook_compTrackInsertTimeRange,
                    &gOrigCompTrackInsertTimeRange);

    AMSwizzleMethod(@"AVMutableCompositionTrack",
                    @"scaleTimeRange:toDuration:",
                    (IMP)AMHook_compTrackScaleTimeRange,
                    &gOrigCompTrackScaleTimeRange);

    AMSwizzleMethod(@"_TtC12AlightMotion12KeyframeView",
                    @"drawRect:",
                    (IMP)AMHook_keyframeViewDrawRect,
                    &gOrigKeyframeViewDrawRect);

    [[AMHomepageSearchOverlayManager shared] start];
}
