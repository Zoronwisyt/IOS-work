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
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *relThumbDir = [dir stringByAppendingPathComponent:@"thumb"];
    [fm createDirectoryAtPath:relThumbDir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *dstWebp = [relThumbDir stringByAppendingPathComponent:@"box.webp"];
    if (![fm fileExistsAtPath:dstWebp]) {
        NSString *srcWebp = [[[[NSBundle mainBundle] bundlePath] stringByAppendingPathComponent:@"BuiltinEffects/thumb"] stringByAppendingPathComponent:@"box.webp"];
        if ([fm fileExistsAtPath:srcWebp]) {
            [fm copyItemAtPath:srcWebp toPath:dstWebp error:nil];
        }
    }
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
// it as its own standalone box inside category="custom" (usable on any layer).
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
                @"<effect id=\"com.alightcreative.effects.custom_%@\" compat=\"acScreenNorm-y\" name=\"%@\" desc=\"Custom Effect\" category=\"custom\" tags=\"custom\" thumb=\"thumb/box.webp\">\n"
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

    // Strip flags that hide an effect from the picker grid and non-iOS <effect> attributes
    // that trigger XMLPullParser "Did not consume all element contents for <effect>" try! crash
    removeAttr(@"internal");
    removeAttr(@"deprecated");
    removeAttr(@"experimental");
    removeAttr(@"description");
    removeAttr(@"author");
    removeAttr(@"version");
    removeAttr(@"type");

    // Always assign a unique com.alightcreative.effects.custom_<slug> ID so it gets its own box
    // and never collides with a built-in effect
    setAttr(@"id", [NSString stringWithFormat:@"com.alightcreative.effects.custom_%@", slug]);
    setAttr(@"category", @"custom");
    setAttr(@"name", displayName);
    setAttr(@"desc", @"Custom Effect");
    setAttr(@"tags", @"custom");
    // Use a guaranteed-valid built-in WebP thumb copied into CustomEffects/thumb/box.webp;
    // our cell willDisplayCell hook overlays any custom user PNG thumbnail cleanly!
    setAttr(@"thumb", @"thumb/box.webp");

    NSMutableString *result = [trimmed mutableCopy];
    [result replaceCharactersInRange:tagRange withString:openTag];

    // Reject pure-JS <script> effects that lack <shader> (unsupported V8 JS runtime on iOS)
    if ([result rangeOfString:@"<shader" options:NSCaseInsensitiveSearch].location == NSNotFound) {
        if (outError) {
            *outError = [NSError errorWithDomain:@"AMCustomEffects" code:4
                                        userInfo:@{NSLocalizedDescriptionKey: @"JavaScript-only <script> effects without a <shader> are not supported by iOS Metal."}];
        }
        return nil;
    }

    // Strip non-external <script> blocks if present alongside <shader>
    {
        NSRegularExpression *scriptRx = [NSRegularExpression regularExpressionWithPattern:@"<script(?![^>]*\\bexternal\\s*=)[^>]*>[\\s\\S]*?</script>"
                                                                                  options:NSRegularExpressionCaseInsensitive
                                                                                    error:nil];
        [scriptRx replaceMatchesInString:result options:0 range:NSMakeRange(0, result.length) withTemplate:@""];
    }

    // Normalize <shader precision="medium"> -> precision="high" and <spinner type="integer"> -> snap="true"
    {
        NSRegularExpression *precRx = [NSRegularExpression regularExpressionWithPattern:@"(<shader\\b[^>]*\\bprecision\\s*=\\s*\")medium(\")"
                                                                                options:NSRegularExpressionCaseInsensitive
                                                                                  error:nil];
        [precRx replaceMatchesInString:result options:0 range:NSMakeRange(0, result.length) withTemplate:@"$1high$2"];

        NSRegularExpression *intSpinRx = [NSRegularExpression regularExpressionWithPattern:@"(<spinner\\b[^>]*)\\btype\\s*=\\s*\"integer\""
                                                                                   options:NSRegularExpressionCaseInsensitive
                                                                                     error:nil];
        [intSpinRx replaceMatchesInString:result options:0 range:NSMakeRange(0, result.length) withTemplate:@"$1snap=\"true\""];
    }

    // Normalize bare <shader> tags missing type="fragment" (common in Android/Gold Motion XMLs)
    {
        NSRegularExpression *bareShaderRx = [NSRegularExpression regularExpressionWithPattern:@"<shader(?![^>]*\\btype\\s*=)([^>]*)>"
                                                                                      options:NSRegularExpressionCaseInsensitive
                                                                                        error:nil];
        [bareShaderRx replaceMatchesInString:result options:0 range:NSMakeRange(0, result.length) withTemplate:@"<shader type=\"fragment\"$1>"];
    }

    // Fallback missing Android bundled image textures (<texture ... srcType="image" .../>) to srcType="content"
    // if the referenced image file does not exist inside AlightMotion.app/BuiltinEffects.
    {
        NSRegularExpression *imgTexRx = [NSRegularExpression regularExpressionWithPattern:@"<texture\\b[^>]*\\bsrcType\\s*=\\s*\"image\"[^>]*>"
                                                                                  options:NSRegularExpressionCaseInsensitive
                                                                                    error:nil];
        NSArray<NSTextCheckingResult *> *matches = [imgTexRx matchesInString:result options:0 range:NSMakeRange(0, result.length)];
        NSString *builtinDir = [[[NSBundle mainBundle] bundlePath] stringByAppendingPathComponent:@"BuiltinEffects"];
        NSRegularExpression *srcAttrRx = [NSRegularExpression regularExpressionWithPattern:@"\\bsrc\\s*=\\s*\"([^\"]+)\""
                                                                                   options:NSRegularExpressionCaseInsensitive
                                                                                     error:nil];
        for (NSTextCheckingResult *m in [matches reverseObjectEnumerator]) {
            NSString *tag = [result substringWithRange:m.range];
            NSTextCheckingResult *srcM = [srcAttrRx firstMatchInString:tag options:0 range:NSMakeRange(0, tag.length)];
            BOOL exists = NO;
            if (srcM && srcM.numberOfRanges > 1) {
                NSString *rel = [tag substringWithRange:[srcM rangeAtIndex:1]];
                exists = [[NSFileManager defaultManager] fileExistsAtPath:[builtinDir stringByAppendingPathComponent:rel]];
            }
            if (!exists) {
                NSMutableString *fixedTag = [tag mutableCopy];
                NSRegularExpression *stRx = [NSRegularExpression regularExpressionWithPattern:@"\\bsrcType\\s*=\\s*\"image\""
                                                                                      options:NSRegularExpressionCaseInsensitive
                                                                                        error:nil];
                [stRx replaceMatchesInString:fixedTag options:0 range:NSMakeRange(0, fixedTag.length) withTemplate:@"srcType=\"content\""];
                [srcAttrRx replaceMatchesInString:fixedTag options:0 range:NSMakeRange(0, fixedTag.length) withTemplate:@""];
                [result replaceCharactersInRange:m.range withString:fixedTag];
            }
        }
    }

    if (![result hasPrefix:@"<?xml"]) {
        [result insertString:@"<?xml version='1.0' encoding='UTF-8' ?>\n" atIndex:0];
    }
    return result;
}

// ============================================================================
// Module 3B: GLSL-ES-to-MSL Shader Compatibility Engine (Android -> iOS)
// Hooks MTLDevice -newLibraryWithSource:options:error: with zero overhead on
// shaders that already compile cleanly. When an AC_ShaderWrapper effect fails
// Metal compilation, injects missing GLSL ES 2.0/3.0 built-ins/overloads and
// rewrites GLSL-only syntax (precision, out/inout, sampler2D, const int,
// struct/array constructors, stpq swizzles, uniform/varying, not()) to MSL.
// ============================================================================

typedef void *(*AMNewLibOrigFn)(id, SEL, NSString *, MTLCompileOptions *, NSError * __autoreleasing *);
static AMNewLibOrigFn gOrigNewLibraryWithSource = NULL;

// AM_METAL_COMPAT_BEGIN
static NSString *AMGLSLGlobalCompatPreamble(void) {
    return @"\n"
    "// --- AMMod GLSL-ES-to-MSL Compatibility Preamble ---\n"
    "typedef bool2 bvec2; typedef bool3 bvec3; typedef bool4 bvec4;\n"
    "typedef int2 ivec2; typedef int3 ivec3; typedef int4 ivec4;\n"
    "typedef uint2 uvec2; typedef uint3 uvec3; typedef uint4 uvec4;\n"
    "typedef texture2d<half> sampler2D;\n"
    "\n"
    "inline float radians(float d) { return d * 0.017453292519943295f; }\n"
    "inline vec2  radians(vec2  d) { return d * 0.017453292519943295f; }\n"
    "inline vec3  radians(vec3  d) { return d * 0.017453292519943295f; }\n"
    "inline vec4  radians(vec4  d) { return d * 0.017453292519943295f; }\n"
    "inline float degrees(float r) { return r * 57.29577951308232f; }\n"
    "inline vec2  degrees(vec2  r) { return r * 57.29577951308232f; }\n"
    "inline vec3  degrees(vec3  r) { return r * 57.29577951308232f; }\n"
    "inline vec4  degrees(vec4  r) { return r * 57.29577951308232f; }\n"
    "\n"
    "inline float inversesqrt(float x) { return metal::rsqrt(x); }\n"
    "inline vec2  inversesqrt(vec2  x) { return metal::rsqrt(x); }\n"
    "inline vec3  inversesqrt(vec3  x) { return metal::rsqrt(x); }\n"
    "inline vec4  inversesqrt(vec4  x) { return metal::rsqrt(x); }\n"
    "\n"
    "inline float dFdx(float x) { return metal::dfdx(x); }\n"
    "inline vec2  dFdx(vec2  x) { return metal::dfdx(x); }\n"
    "inline vec3  dFdx(vec3  x) { return metal::dfdx(x); }\n"
    "inline vec4  dFdx(vec4  x) { return metal::dfdx(x); }\n"
    "inline float dFdy(float x) { return metal::dfdy(x); }\n"
    "inline vec2  dFdy(vec2  x) { return metal::dfdy(x); }\n"
    "inline vec3  dFdy(vec3  x) { return metal::dfdy(x); }\n"
    "inline vec4  dFdy(vec4  x) { return metal::dfdy(x); }\n"
    "\n"
    "inline vec2 mod(vec2 x, float y) { return x - y * metal::floor(x / y); }\n"
    "inline vec3 mod(vec3 x, float y) { return x - y * metal::floor(x / y); }\n"
    "inline vec4 mod(vec4 x, float y) { return x - y * metal::floor(x / y); }\n"
    "inline vec2 mod(float x, vec2 y) { return x - y * metal::floor(x / y); }\n"
    "inline vec3 mod(float x, vec3 y) { return x - y * metal::floor(x / y); }\n"
    "inline vec4 mod(float x, vec4 y) { return x - y * metal::floor(x / y); }\n"
    "\n"
    "inline vec2 atan(vec2 y, vec2 x) { return metal::atan2(y, x); }\n"
    "inline vec3 atan(vec3 y, vec3 x) { return metal::atan2(y, x); }\n"
    "inline vec4 atan(vec4 y, vec4 x) { return metal::atan2(y, x); }\n"
    "\n"
    "inline vec2  min(vec2  a, float b) { return metal::min(a, vec2(b)); }\n"
    "inline vec3  min(vec3  a, float b) { return metal::min(a, vec3(b)); }\n"
    "inline vec4  min(vec4  a, float b) { return metal::min(a, vec4(b)); }\n"
    "inline vec2  min(float a, vec2  b) { return metal::min(vec2(a), b); }\n"
    "inline vec3  min(float a, vec3  b) { return metal::min(vec3(a), b); }\n"
    "inline vec4  min(float a, vec4  b) { return metal::min(vec4(a), b); }\n"
    "inline float min(float a, int   b) { return metal::min(a, float(b)); }\n"
    "inline float min(int   a, float b) { return metal::min(float(a), b); }\n"
    "\n"
    "inline vec2  max(vec2  a, float b) { return metal::max(a, vec2(b)); }\n"
    "inline vec3  max(vec3  a, float b) { return metal::max(a, vec3(b)); }\n"
    "inline vec4  max(vec4  a, float b) { return metal::max(a, vec4(b)); }\n"
    "inline vec2  max(float a, vec2  b) { return metal::max(vec2(a), b); }\n"
    "inline vec3  max(float a, vec3  b) { return metal::max(vec3(a), b); }\n"
    "inline vec4  max(float a, vec4  b) { return metal::max(vec4(a), b); }\n"
    "inline float max(float a, int   b) { return metal::max(a, float(b)); }\n"
    "inline float max(int   a, float b) { return metal::max(float(a), b); }\n"
    "\n"
    "inline vec2  pow(vec2  x, float y) { return metal::pow(x, vec2(y)); }\n"
    "inline vec3  pow(vec3  x, float y) { return metal::pow(x, vec3(y)); }\n"
    "inline vec4  pow(vec4  x, float y) { return metal::pow(x, vec4(y)); }\n"
    "inline float pow(float x, int   y) { return metal::pow(x, float(y)); }\n"
    "\n"
    "inline vec2 step(float e, vec2 x) { return metal::step(vec2(e), x); }\n"
    "inline vec3 step(float e, vec3 x) { return metal::step(vec3(e), x); }\n"
    "inline vec4 step(float e, vec4 x) { return metal::step(vec4(e), x); }\n"
    "inline vec2 smoothstep(float e0, float e1, vec2 x) { return metal::smoothstep(vec2(e0), vec2(e1), x); }\n"
    "inline vec3 smoothstep(float e0, float e1, vec3 x) { return metal::smoothstep(vec3(e0), vec3(e1), x); }\n"
    "inline vec4 smoothstep(float e0, float e1, vec4 x) { return metal::smoothstep(vec4(e0), vec4(e1), x); }\n"
    "\n"
    "inline float mix(float x, float y, bool  a) { return a ? y : x; }\n"
    "inline vec2  mix(vec2  x, vec2  y, bool  a) { return a ? y : x; }\n"
    "inline vec3  mix(vec3  x, vec3  y, bool  a) { return a ? y : x; }\n"
    "inline vec4  mix(vec4  x, vec4  y, bool  a) { return a ? y : x; }\n"
    "inline vec2  mix(vec2  x, vec2  y, bvec2 a) { return metal::select(x, y, a); }\n"
    "inline vec3  mix(vec3  x, vec3  y, bvec3 a) { return metal::select(x, y, a); }\n"
    "inline vec4  mix(vec4  x, vec4  y, bvec4 a) { return metal::select(x, y, a); }\n"
    "\n"
    "inline bvec2 lessThan(vec2 a, vec2 b) { return a < b; }\n"
    "inline bvec3 lessThan(vec3 a, vec3 b) { return a < b; }\n"
    "inline bvec4 lessThan(vec4 a, vec4 b) { return a < b; }\n"
    "inline bvec2 lessThan(ivec2 a, ivec2 b) { return a < b; }\n"
    "inline bvec3 lessThan(ivec3 a, ivec3 b) { return a < b; }\n"
    "inline bvec4 lessThan(ivec4 a, ivec4 b) { return a < b; }\n"
    "inline bvec2 lessThanEqual(vec2 a, vec2 b) { return a <= b; }\n"
    "inline bvec3 lessThanEqual(vec3 a, vec3 b) { return a <= b; }\n"
    "inline bvec4 lessThanEqual(vec4 a, vec4 b) { return a <= b; }\n"
    "inline bvec2 lessThanEqual(ivec2 a, ivec2 b) { return a <= b; }\n"
    "inline bvec3 lessThanEqual(ivec3 a, ivec3 b) { return a <= b; }\n"
    "inline bvec4 lessThanEqual(ivec4 a, ivec4 b) { return a <= b; }\n"
    "inline bvec2 greaterThan(vec2 a, vec2 b) { return a > b; }\n"
    "inline bvec3 greaterThan(vec3 a, vec3 b) { return a > b; }\n"
    "inline bvec4 greaterThan(vec4 a, vec4 b) { return a > b; }\n"
    "inline bvec2 greaterThan(ivec2 a, ivec2 b) { return a > b; }\n"
    "inline bvec3 greaterThan(ivec3 a, ivec3 b) { return a > b; }\n"
    "inline bvec4 greaterThan(ivec4 a, ivec4 b) { return a > b; }\n"
    "inline bvec2 greaterThanEqual(vec2 a, vec2 b) { return a >= b; }\n"
    "inline bvec3 greaterThanEqual(vec3 a, vec3 b) { return a >= b; }\n"
    "inline bvec4 greaterThanEqual(vec4 a, vec4 b) { return a >= b; }\n"
    "inline bvec2 greaterThanEqual(ivec2 a, ivec2 b) { return a >= b; }\n"
    "inline bvec3 greaterThanEqual(ivec3 a, ivec3 b) { return a >= b; }\n"
    "inline bvec4 greaterThanEqual(ivec4 a, ivec4 b) { return a >= b; }\n"
    "inline bvec2 equal(vec2 a, vec2 b) { return a == b; }\n"
    "inline bvec3 equal(vec3 a, vec3 b) { return a == b; }\n"
    "inline bvec4 equal(vec4 a, vec4 b) { return a == b; }\n"
    "inline bvec2 equal(ivec2 a, ivec2 b) { return a == b; }\n"
    "inline bvec3 equal(ivec3 a, ivec3 b) { return a == b; }\n"
    "inline bvec4 equal(ivec4 a, ivec4 b) { return a == b; }\n"
    "inline bvec2 equal(bvec2 a, bvec2 b) { return a == b; }\n"
    "inline bvec3 equal(bvec3 a, bvec3 b) { return a == b; }\n"
    "inline bvec4 equal(bvec4 a, bvec4 b) { return a == b; }\n"
    "inline bvec2 notEqual(vec2 a, vec2 b) { return a != b; }\n"
    "inline bvec3 notEqual(vec3 a, vec3 b) { return a != b; }\n"
    "inline bvec4 notEqual(vec4 a, vec4 b) { return a != b; }\n"
    "inline bvec2 notEqual(ivec2 a, ivec2 b) { return a != b; }\n"
    "inline bvec3 notEqual(ivec3 a, ivec3 b) { return a != b; }\n"
    "inline bvec4 notEqual(ivec4 a, ivec4 b) { return a != b; }\n"
    "inline bvec2 notEqual(bvec2 a, bvec2 b) { return a != b; }\n"
    "inline bvec3 notEqual(bvec3 a, bvec3 b) { return a != b; }\n"
    "inline bvec4 notEqual(bvec4 a, bvec4 b) { return a != b; }\n"
    "inline bvec2 am_bnot(bvec2 a) { return !a; }\n"
    "inline bvec3 am_bnot(bvec3 a) { return !a; }\n"
    "inline bvec4 am_bnot(bvec4 a) { return !a; }\n"
    "\n"
    "inline mat2 matrixCompMult(mat2 a, mat2 b) { return mat2(a[0]*b[0], a[1]*b[1]); }\n"
    "inline mat3 matrixCompMult(mat3 a, mat3 b) { return mat3(a[0]*b[0], a[1]*b[1], a[2]*b[2]); }\n"
    "inline mat4 matrixCompMult(mat4 a, mat4 b) { return mat4(a[0]*b[0], a[1]*b[1], a[2]*b[2], a[3]*b[3]); }\n"
    "inline mat2 outerProduct(vec2 c, vec2 r) { return mat2(c*r.x, c*r.y); }\n"
    "inline mat3 outerProduct(vec3 c, vec3 r) { return mat3(c*r.x, c*r.y, c*r.z); }\n"
    "inline mat4 outerProduct(vec4 c, vec4 r) { return mat4(c*r.x, c*r.y, c*r.z, c*r.w); }\n"
    "inline mat2 inverse(mat2 m) {\n"
    "    float d = m[0][0]*m[1][1] - m[1][0]*m[0][1];\n"
    "    return mat2(m[1][1], -m[0][1], -m[1][0], m[0][0]) * (1.0f / d);\n"
    "}\n"
    "inline mat3 inverse(mat3 m) {\n"
    "    float a00=m[0][0],a01=m[0][1],a02=m[0][2],a10=m[1][0],a11=m[1][1],a12=m[1][2],a20=m[2][0],a21=m[2][1],a22=m[2][2];\n"
    "    float b01=a22*a11-a12*a21, b11=-a22*a10+a12*a20, b21=a21*a10-a11*a20;\n"
    "    float invD = 1.0f / (a00*b01 + a01*b11 + a02*b21);\n"
    "    return mat3(\n"
    "        vec3(b01, (-a22*a01+a02*a21), (a12*a01-a02*a11)) * invD,\n"
    "        vec3(b11, (a22*a00-a02*a20), (-a12*a00+a02*a10)) * invD,\n"
    "        vec3(b21, (-a21*a00+a01*a20), (a11*a00-a01*a10)) * invD);\n"
    "}\n"
    "inline mat4 inverse(mat4 m) {\n"
    "    float c00=m[2][2]*m[3][3]-m[3][2]*m[2][3], c02=m[1][2]*m[3][3]-m[3][2]*m[1][3], c03=m[1][2]*m[2][3]-m[2][2]*m[1][3];\n"
    "    float c04=m[2][1]*m[3][3]-m[3][1]*m[2][3], c06=m[1][1]*m[3][3]-m[3][1]*m[1][3], c07=m[1][1]*m[2][3]-m[2][1]*m[1][3];\n"
    "    float c08=m[2][1]*m[3][2]-m[3][1]*m[2][2], c10=m[1][1]*m[3][2]-m[3][1]*m[1][2], c11=m[1][1]*m[2][2]-m[2][1]*m[1][2];\n"
    "    float c12=m[2][0]*m[3][3]-m[3][0]*m[2][3], c14=m[1][0]*m[3][3]-m[3][0]*m[1][3], c15=m[1][0]*m[2][3]-m[2][0]*m[1][3];\n"
    "    float c16=m[2][0]*m[3][2]-m[3][0]*m[2][2], c18=m[1][0]*m[3][2]-m[3][0]*m[1][2], c19=m[1][0]*m[2][2]-m[2][0]*m[1][2];\n"
    "    float c20=m[2][0]*m[3][1]-m[3][0]*m[2][1], c22=m[1][0]*m[3][1]-m[3][0]*m[1][1], c23=m[1][0]*m[2][1]-m[2][0]*m[1][1];\n"
    "    vec4 f0(c00,c00,c02,c03), f1(c04,c04,c06,c07), f2(c08,c08,c10,c11);\n"
    "    vec4 f3(c12,c12,c14,c15), f4(c16,c16,c18,c19), f5(c20,c20,c22,c23);\n"
    "    vec4 v0(m[1][0],m[0][0],m[0][0],m[0][0]), v1(m[1][1],m[0][1],m[0][1],m[0][1]);\n"
    "    vec4 v2(m[1][2],m[0][2],m[0][2],m[0][2]), v3(m[1][3],m[0][3],m[0][3],m[0][3]);\n"
    "    vec4 i0(v1*f0 - v2*f1 + v3*f2), i1(v0*f0 - v2*f3 + v3*f4), i2(v0*f1 - v1*f3 + v3*f5), i3(v0*f2 - v1*f4 + v2*f5);\n"
    "    vec4 sA(+1,-1,+1,-1), sB(-1,+1,-1,+1);\n"
    "    mat4 inv(i0*sA, i1*sB, i2*sA, i3*sB);\n"
    "    vec4 r0(inv[0][0], inv[1][0], inv[2][0], inv[3][0]);\n"
    "    return inv * (1.0f / metal::dot(m[0], r0));\n"
    "}\n"
    "// --- End AMMod GLSL-ES-to-MSL Compatibility Preamble ---\n\n";
}

static NSString *AMGLSLWrapperExtraMethods(void) {
    return @"\n"
    "    vec2 am_texSize(AC_ImageInfo info) { return info.size; }\n"
    "    template<typename T, typename U> inline T am_mix(T a, T b, U t) { return mix(a, b, t); }\n"
    "    vec4 texture2D(texture2d<half> t, vec2 p, float bias) { (void)bias; return vec4(t.sample(textureSampler, p)); }\n"
    "    vec4 texture2DCv(texture2d<half> t, vec2 p, float bias) { (void)bias; return texture2DCv(t, p); }\n"
    "    vec4 texture2D(AC_ImageInfo info, vec2 p) { return texture2D(info.texture, p); }\n"
    "    vec4 texture2DCv(AC_ImageInfo info, vec2 p) { return texture2DCv(info.texture, p); }\n"
    "    vec4 texture(texture2d<half> t, vec2 p) { return texture2D(t, p); }\n"
    "    vec4 texture(texture2d<half> t, vec2 p, float bias) { (void)bias; return texture2D(t, p); }\n"
    "    vec4 texture(AC_ImageInfo info, vec2 p) { return texture2D(info.texture, p); }\n";
}

static NSString *AMSanitizeUserGLSLBody(NSString *body) {
    NSMutableString *s = [body mutableCopy];

    // 1. Strip #version and #extension directives
    {
        NSRegularExpression *rx = [NSRegularExpression regularExpressionWithPattern:@"^[ \\t]*#(?:version|extension)\\b[^\\n]*$"
                                                                            options:NSRegularExpressionAnchorsMatchLines
                                                                              error:nil];
        [rx replaceMatchesInString:s options:0 range:NSMakeRange(0, s.length) withTemplate:@""];
    }

    // 2. Strip `precision highp/mediump/lowp float/int/sampler2D;` statements
    {
        NSRegularExpression *rx = [NSRegularExpression regularExpressionWithPattern:@"\\bprecision\\s+(?:highp|mediump|lowp)\\s+\\w+\\s*;"
                                                                            options:0
                                                                              error:nil];
        [rx replaceMatchesInString:s options:0 range:NSMakeRange(0, s.length) withTemplate:@""];
    }

    // 3. Strip standalone top-level `uniform ...;`, `varying ...;`, `attribute ...;` declarations
    {
        NSRegularExpression *rx = [NSRegularExpression regularExpressionWithPattern:@"^[ \\t]*(?:uniform|varying|attribute)\\s+[^;\\n]+;"
                                                                            options:NSRegularExpressionAnchorsMatchLines
                                                                              error:nil];
        [rx replaceMatchesInString:s options:0 range:NSMakeRange(0, s.length) withTemplate:@""];
    }

    // 4. Preserve compile-time `const int NAME = INT_EXPR;` (valid at both struct & function scope in Metal)
    {
        NSRegularExpression *rx = [NSRegularExpression regularExpressionWithPattern:@"\\bconst\\s+int\\s+([A-Za-z_]\\w*)\\s*=\\s*([0-9+\\-*/()\\s]+);"
                                                                            options:0
                                                                              error:nil];
        [rx replaceMatchesInString:s options:0 range:NSMakeRange(0, s.length) withTemplate:@"enum { $1 = $2 };"];
    }

    // 4b. Avoid `#define size (ac__p.size)` breaking `inputImg.size` and `#define mix (ac__p.mix)` breaking `mix(...)`
    if ([s containsString:@"#define size (ac__p.size)"]) {
        NSRegularExpression *rx = [NSRegularExpression regularExpressionWithPattern:@"\\b(?!ac__p\\b)([A-Za-z_]\\w*)\\.size\\b"
                                                                            options:0
                                                                              error:nil];
        [rx replaceMatchesInString:s options:0 range:NSMakeRange(0, s.length) withTemplate:@"am_texSize($1)"];
    }
    if ([s containsString:@"#define mix (ac__p.mix)"]) {
        NSRegularExpression *rx = [NSRegularExpression regularExpressionWithPattern:@"\\bmix\\s*\\("
                                                                            options:0
                                                                              error:nil];
        [rx replaceMatchesInString:s options:0 range:NSMakeRange(0, s.length) withTemplate:@"am_mix("];
    }

    // 5. Rewrite GLSL `out` / `inout` function parameters to MSL `thread T&`
    {
        NSRegularExpression *rx = [NSRegularExpression regularExpressionWithPattern:@"\\b(?:inout|out)\\s+(?:(?:highp|mediump|lowp)\\s+)?(float|int|uint|bool|vec[234]|ivec[234]|uvec[234]|bvec[234]|mat[234])\\s+([A-Za-z_]\\w*)"
                                                                            options:0
                                                                              error:nil];
        [rx replaceMatchesInString:s options:0 range:NSMakeRange(0, s.length) withTemplate:@"thread $1& $2"];
    }

    // 6. Rewrite GLSL array constructors `float[N](...)` / `vec2[](...)` -> `{...}`
    {
        NSRegularExpression *rx = [NSRegularExpression regularExpressionWithPattern:@"\\b(?:float|int|uint|bool|vec[234]|ivec[234]|mat[234])\\s*\\[\\s*\\d*\\s*\\]\\s*\\(([^()]*)\\)"
                                                                            options:0
                                                                              error:nil];
        [rx replaceMatchesInString:s options:0 range:NSMakeRange(0, s.length) withTemplate:@"{$1}"];
    }

    // 7. Rewrite GLSL struct aggregate constructor calls `MyStruct(a, b)` -> `MyStruct{a, b}`
    {
        NSRegularExpression *structDeclRx = [NSRegularExpression regularExpressionWithPattern:@"\\bstruct\\s+([A-Za-z_]\\w*)\\s*\\{"
                                                                                      options:0
                                                                                        error:nil];
        NSArray<NSTextCheckingResult *> *decls = [structDeclRx matchesInString:s options:0 range:NSMakeRange(0, s.length)];
        NSMutableSet<NSString *> *structNames = [NSMutableSet set];
        for (NSTextCheckingResult *m in decls) {
            if (m.numberOfRanges > 1) {
                [structNames addObject:[s substringWithRange:[m rangeAtIndex:1]]];
            }
        }
        for (NSString *sname in structNames) {
            NSString *pat = [NSString stringWithFormat:@"(?<!struct\\s)\\b%@\\s*\\(([^()]*)\\)", [NSRegularExpression escapedPatternForString:sname]];
            NSRegularExpression *callRx = [NSRegularExpression regularExpressionWithPattern:pat options:0 error:nil];
            [callRx replaceMatchesInString:s options:0 range:NSMakeRange(0, s.length)
                              withTemplate:[NSString stringWithFormat:@"%@{$1}", sname]];
        }
    }

    // 8. Rewrite GLSL `not(...)` boolean vector built-in (C++ keyword collision)
    {
        NSRegularExpression *rx = [NSRegularExpression regularExpressionWithPattern:@"\\bnot\\s*\\(" options:0 error:nil];
        [rx replaceMatchesInString:s options:0 range:NSMakeRange(0, s.length) withTemplate:@"am_bnot("];
    }

    // 9. Rewrite extra GLSL multi-component `.stpq` swizzles missed by iOS's `.st/.s/.t` regex
    NSDictionary<NSString *, NSString *> *swizzles = @{
        @"\\.stpq(?![A-Za-z0-9_])": @".xyzw",
        @"\\.stp(?![A-Za-z0-9_])":  @".xyz",
        @"\\.ts(?![A-Za-z0-9_])":   @".yx",
        @"\\.ss(?![A-Za-z0-9_])":   @".xx",
        @"\\.tt(?![A-Za-z0-9_])":   @".yy",
        @"\\.pq(?![A-Za-z0-9_])":   @".zw",
    };
    for (NSString *pat in swizzles) {
        NSRegularExpression *rx = [NSRegularExpression regularExpressionWithPattern:pat options:0 error:nil];
        [rx replaceMatchesInString:s options:0 range:NSMakeRange(0, s.length) withTemplate:swizzles[pat]];
    }

    return s;
}

static NSString *AMTranspileGLSLWrapperToMSL(NSString *source) {
    if (!source || ![source containsString:@"AC_ShaderWrapper"]) return nil;
    NSMutableString *out = [source mutableCopy];

    // A. Inject global GLSL compatibility preamble right before `struct AC_ShaderWrapper`
    NSRange wrapperRange = [out rangeOfString:@"struct AC_ShaderWrapper"];
    if (wrapperRange.location == NSNotFound) return nil;
    [out insertString:AMGLSLGlobalCompatPreamble() atIndex:wrapperRange.location];

    // B. Inject extra texture2D / texture2DCv / texture overloads inside AC_ShaderWrapper
    NSRange getTexRange = [out rangeOfString:@"vec2 getTexSize("];
    if (getTexRange.location != NSNotFound) {
        [out insertString:AMGLSLWrapperExtraMethods() atIndex:getTexRange.location];
    }

    // C. Inject extra Android uniform & precision #defines right after `#define acPass`
    NSRange acPassRange = [out rangeOfString:@"#define acPass"];
    if (acPassRange.location != NSNotFound) {
        NSRange nl = [out rangeOfString:@"\n" options:0 range:NSMakeRange(acPassRange.location, out.length - acPassRange.location)];
        if (nl.location != NSNotFound) {
            NSString *extraDefines =
                @"#define acProjectSize (acScreenSize)\n"
                @"#define acLayerSizeNorm (acLayerSize / max(acScreenSize, vec2(1.0)))\n"
                @"#define acLTS (acLayerToScreen)\n"
                @"#define highp\n"
                @"#define mediump\n"
                @"#define lowp\n";
            [out insertString:extraDefines atIndex:nl.location + 1];
        }
    }

    // D. Sanitize user GLSL body between `#define discard` line and `#undef acScreenToLayer`
    NSRange discardDef = [out rangeOfString:@"#define discard"];
    NSRange undefStart = [out rangeOfString:@"#undef acScreenToLayer"];
    if (discardDef.location != NSNotFound && undefStart.location != NSNotFound && undefStart.location > discardDef.location) {
        NSRange nl = [out rangeOfString:@"\n" options:0 range:NSMakeRange(discardDef.location, undefStart.location - discardDef.location)];
        if (nl.location != NSNotFound && nl.location + 1 < undefStart.location) {
            NSRange bodyRange = NSMakeRange(nl.location + 1, undefStart.location - (nl.location + 1));
            NSString *rawBody = [out substringWithRange:bodyRange];
            NSString *fixedBody = AMSanitizeUserGLSLBody(rawBody);
            [out replaceCharactersInRange:bodyRange withString:fixedBody];
        }
    }

    // E. Undefine our extra macros right after `#undef discard`
    NSRange undefDiscard = [out rangeOfString:@"#undef discard"];
    if (undefDiscard.location != NSNotFound) {
        NSUInteger pos = NSMaxRange(undefDiscard);
        [out insertString:@"\n#undef acProjectSize\n#undef acLayerSizeNorm\n#undef acLTS\n#undef highp\n#undef mediump\n#undef lowp\n" atIndex:pos];
    }

    return out;
}

static NSString *AMBuildSafePassthroughMSL(NSString *source) {
    if (!source || ![source containsString:@"AC_ShaderWrapper"]) return nil;
    NSRange discardDef = [source rangeOfString:@"#define discard"];
    NSRange undefStart = [source rangeOfString:@"#undef acScreenToLayer"];
    if (discardDef.location == NSNotFound || undefStart.location == NSNotFound || undefStart.location <= discardDef.location) {
        return nil;
    }
    NSRange nl = [source rangeOfString:@"\n" options:0 range:NSMakeRange(discardDef.location, undefStart.location - discardDef.location)];
    if (nl.location == NSNotFound || nl.location + 1 >= undefStart.location) return nil;

    NSRange bodyRange = NSMakeRange(nl.location + 1, undefStart.location - (nl.location + 1));
    BOOL hasInputImg = ([source rangeOfString:@"AC_ImageInfo inputImg"].location != NSNotFound);
    NSString *safeBody = hasInputImg
        ? @"\n    void main() { gl_FragColor = texture2DCv(ac__img.inputImg.texture, acScreenNorm); }\n"
        : @"\n    void main() { gl_FragColor = vec4(0.0, 0.0, 0.0, 0.0); }\n";
    NSMutableString *out = [source mutableCopy];
    [out replaceCharactersInRange:bodyRange withString:safeBody];
    return out;
}
// AM_METAL_COMPAT_END

static void AMLogShaderCompileFailure(NSError *err, NSString *mslSource) {
    @try {
        NSString *logPath = [AMCustomEffectsDir() stringByAppendingPathComponent:@"last_shader_error.txt"];
        NSString *msg = [NSString stringWithFormat:@"=== Metal Compile Error ===\n%@\n\n=== Transpiled MSL ===\n%@\n",
                         err.localizedDescription ?: @"(no error)", mslSource ?: @""];
        [msg writeToFile:logPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    } @catch (NSException *ignored) {}
}

// IMPORTANT: -newLibraryWithSource:options:error: begins with "new" so Objective-C/Swift callers
// expect a +1 retained object (NS_RETURNS_RETAINED). Using raw void* avoids ARC autoreleasing it
// and causing a double-free EXC_BAD_ACCESS when Swift releases its +1 reference.
static void *AMHook_newLibraryWithSource(id self, SEL _cmd, NSString *source, MTLCompileOptions *options, NSError * __autoreleasing *error) {
    if (!gOrigNewLibraryWithSource) return NULL;

    NSError *firstErr = nil;
    void *rawLib = gOrigNewLibraryWithSource(self, _cmd, source, options, &firstErr);
    if (rawLib != NULL) {
        if (error) *error = firstErr;
        return rawLib;
    }

    if (source && [source containsString:@"AC_ShaderWrapper"]) {
        NSString *transpiled = AMTranspileGLSLWrapperToMSL(source);
        if (transpiled && ![transpiled isEqualToString:source]) {
            NSError *retryErr = nil;
            void *retryLib = gOrigNewLibraryWithSource(self, _cmd, transpiled, options, &retryErr);
            if (retryLib != NULL) {
                if (error) *error = nil;
                return retryLib;
            }
            AMLogShaderCompileFailure(retryErr ?: firstErr, transpiled);
        }

        // Guaranteed crash-proof passthrough fallback so AlightEffectShader.init never fails with nil
        NSString *fallback = AMBuildSafePassthroughMSL(source);
        if (fallback) {
            NSError *fbErr = nil;
            void *fbLib = gOrigNewLibraryWithSource(self, _cmd, fallback, options, &fbErr);
            if (fbLib != NULL) {
                if (error) *error = nil;
                return fbLib;
            }
        }
    }

    if (error) *error = firstErr;
    return NULL;
}

static void AMInstallMetalShaderCompatHook(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        if (!dev) return;
        Class devCls = object_getClass(dev);
        if (!devCls) return;
        SEL sel = @selector(newLibraryWithSource:options:error:);
        Method m = class_getInstanceMethod(devCls, sel);
        if (!m) return;
        gOrigNewLibraryWithSource = (AMNewLibOrigFn)method_setImplementation(m, (IMP)AMHook_newLibraryWithSource);
    });
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

static uint8_t AMCustomCategoryFilter(void *effectPtr) {
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

    // Swift 5 small inline ASCII string "custom" (6 bytes: 'c','u','s','t','o','m')
    const uint64_t kCustomLo = 0x00006d6f74737563ULL;
    const uint64_t kCustomHi = 0xe600000000000000ULL;

    BOOL matched = (strLo == kCustomLo && strHi == kCustomHi);
    if (!matched) {
        AMStrEqFn strEq = (AMStrEqFn)(0x1025b7bb8ULL + slide);
        matched = (strEq(strLo, strHi, kCustomLo, kCustomHi, 0) & 1) != 0;
    }
    if (!matched) return 0;
    uint8_t isExp = *((uint8_t *)effectPtr + expOff);
    return (uint8_t)((isExp ^ 1) & 1);
}

static uint8_t AMGoldMotionCategoryFilter(void *effectPtr) {
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

    // Swift 5 small inline ASCII string "goldmotion" (10 bytes)
    const uint64_t kGMLo = 0x69746f6d646c6f67ULL;
    const uint64_t kGMHi = 0xea00000000006e6fULL;

    BOOL matched = (strLo == kGMLo && strHi == kGMHi);
    if (!matched) {
        AMStrEqFn strEq = (AMStrEqFn)(0x1025b7bb8ULL + slide);
        matched = (strEq(strLo, strHi, kGMLo, kGMHi, 0) & 1) != 0;
    }
    if (!matched) return 0;
    uint8_t isExp = *((uint8_t *)effectPtr + expOff);
    return (uint8_t)((isExp ^ 1) & 1);
}

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

        // Guard against duplicate insertion
        AMEffectCategoryEntry *origItems = (AMEffectCategoryEntry *)((uint8_t *)origHdr + sizeof(AMSwiftArrayHeader));
        for (int64_t i = 0; i < origHdr->count; ++i) {
            if (origItems[i].catId == 0x71) return;
        }

        int64_t origCount = origHdr->count;
        int64_t newCount = origCount + 2;
        size_t newBytes = sizeof(AMSwiftArrayHeader) + (size_t)newCount * sizeof(AMEffectCategoryEntry);

        AMSwiftArrayHeader *newHdr = (AMSwiftArrayHeader *)swiftAllocObject(origHdr->isa, newBytes, 7);
        if (!newHdr) return;
        newHdr->count = newCount;
        newHdr->capacityAndFlags = newCount << 1;

        AMEffectCategoryEntry *newItems = (AMEffectCategoryEntry *)((uint8_t *)newHdr + sizeof(AMSwiftArrayHeader));

        // Insert "Custom" right before Experimental (id == 500), i.e. right after "Other"
        int64_t insertIdx = origCount;
        for (int64_t i = 0; i < origCount; ++i) {
            if (origItems[i].catId == 500) {
                insertIdx = i;
                break;
            }
        }

        int64_t dst = 0;
        for (int64_t i = 0; i < origCount; ++i) {
            if (i == insertIdx) {
                AMEffectCategoryEntry customEntry;
                customEntry.catId = 0x71; // 113: unique, non-zero (excluded by Other), != 500 (always visible)
                customEntry.nameLo = 0x00006d6f74737543ULL; // Swift small ASCII String "Custom" (6 bytes)
                customEntry.nameHi = 0xe600000000000000ULL;
                customEntry.thumbLo = 0;
                customEntry.thumbHi = 0;
                customEntry.filterFn = (void *)&AMCustomCategoryFilter;
                customEntry.filterCtx = NULL;
                newItems[dst++] = customEntry;

                AMEffectCategoryEntry gmEntry;
                gmEntry.catId = 0x72; // 114: unique, non-zero (excluded by Other), != 500 (always visible)
                gmEntry.nameLo = 0x746f4d20646c6f47ULL; // Swift small ASCII String "Gold Motion" (11 bytes)
                gmEntry.nameHi = 0xeb000000006e6f69ULL;
                gmEntry.thumbLo = 0;
                gmEntry.thumbHi = 0;
                gmEntry.filterFn = (void *)&AMGoldMotionCategoryFilter;
                gmEntry.filterCtx = NULL;
                newItems[dst++] = gmEntry;
            }
            AMEffectCategoryEntry e = origItems[i];
            if (e.nameHi) swiftBridgeRetain((void *)e.nameHi);
            if (e.thumbHi) swiftBridgeRetain((void *)e.thumbHi);
            if (e.filterCtx) swiftRetain(e.filterCtx);
            newItems[dst++] = e;
        }
        if (insertIdx == origCount) {
            AMEffectCategoryEntry customEntry;
            customEntry.catId = 0x71;
            customEntry.nameLo = 0x00006d6f74737543ULL;
            customEntry.nameHi = 0xe600000000000000ULL;
            customEntry.thumbLo = 0;
            customEntry.thumbHi = 0;
            customEntry.filterFn = (void *)&AMCustomCategoryFilter;
            customEntry.filterCtx = NULL;
            newItems[dst++] = customEntry;

            AMEffectCategoryEntry gmEntry;
            gmEntry.catId = 0x72;
            gmEntry.nameLo = 0x746f4d20646c6f47ULL;
            gmEntry.nameHi = 0xeb000000006e6f69ULL;
            gmEntry.thumbLo = 0;
            gmEntry.thumbHi = 0;
            gmEntry.filterFn = (void *)&AMGoldMotionCategoryFilter;
            gmEntry.filterCtx = NULL;
            newItems[dst++] = gmEntry;
        }

        // Publish new array globally (intentionally keep origHdr retained for safety)
        *globalSlot = newHdr;
    });
}

static UILabel *AMFindFirstLabelInView(UIView *v);
static IMP gOrigEffectMainWillDisplayCell = NULL;
static const void *kAMCustomCatGradKey = &kAMCustomCatGradKey;

static void AMHook_effectMainWillDisplayCell(id self, SEL _cmd, UICollectionView *cv, UICollectionViewCell *cell, NSIndexPath *indexPath) {
    AMInstallCustomEffectCategoryIfNeeded();
    if (gOrigEffectMainWillDisplayCell) {
        ((void (*)(id, SEL, UICollectionView *, UICollectionViewCell *, NSIndexPath *))gOrigEffectMainWillDisplayCell)(self, _cmd, cv, cell, indexPath);
    }
    if (!cell) return;
    UILabel *titleLbl = nil;
    SEL titleSel = NSSelectorFromString(@"titleLabel");
    if ([cell respondsToSelector:titleSel]) {
        titleLbl = ((UILabel *(*)(id, SEL))objc_msgSend)(cell, titleSel);
    }
    if (!titleLbl) titleLbl = AMFindFirstLabelInView(cell.contentView);
    BOOL isCustom = (titleLbl.text && [titleLbl.text caseInsensitiveCompare:@"Custom"] == NSOrderedSame);
    BOOL isGoldMotion = (titleLbl.text && [titleLbl.text caseInsensitiveCompare:@"Gold Motion"] == NSOrderedSame);
    CAGradientLayer *grad = objc_getAssociatedObject(cell, kAMCustomCatGradKey);
    if (isCustom || isGoldMotion) {
        if (!grad) {
            grad = [CAGradientLayer layer];
            grad.startPoint = CGPointMake(0.0, 0.0);
            grad.endPoint = CGPointMake(1.0, 1.0);
            [cell.contentView.layer insertSublayer:grad atIndex:0];
            objc_setAssociatedObject(cell, kAMCustomCatGradKey, grad, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        if (isGoldMotion) {
            grad.colors = @[
                (id)[UIColor colorWithRed:0.26 green:0.18 blue:0.04 alpha:1.0].CGColor,
                (id)[UIColor colorWithRed:0.46 green:0.32 blue:0.06 alpha:1.0].CGColor,
            ];
        } else {
            grad.colors = @[
                (id)[UIColor colorWithRed:0.15 green:0.20 blue:0.35 alpha:1.0].CGColor,
                (id)[UIColor colorWithRed:0.12 green:0.30 blue:0.28 alpha:1.0].CGColor,
            ];
        }
        grad.hidden = NO;
        grad.frame = cell.contentView.bounds;
    } else if (grad) {
        grad.hidden = YES;
    }
}

static IMP gOrigURLsForResources = NULL;

@interface AMEffectXMLSafetyValidator : NSObject <NSXMLParserDelegate>
@property (nonatomic, assign) BOOL valid;
@property (nonatomic, assign) BOOL sawEffectRoot;
@property (nonatomic, assign) BOOL sawShader;
@end

@implementation AMEffectXMLSafetyValidator

+ (NSDictionary<NSString *, NSSet<NSString *> *> *)allowedSchema {
    static NSDictionary<NSString *, NSSet<NSString *> *> *schema = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        schema = @{
            @"effect":     [NSSet setWithArray:@[@"affinity", @"afxver", @"auto-transform", @"category", @"compat", @"deprecated", @"desc", @"experimental", @"id", @"internal", @"max-overdraw", @"maxOverdraw", @"name", @"overdraw", @"tags", @"thumb", @"type"]],
            @"params":     [NSSet set],
            @"spinner":    [NSSet setWithArray:@[@"id", @"default", @"min", @"max", @"label", @"step", @"ticks", @"type", @"snap", @"enabled", @"multiplier", @"logscale", @"originValue", @"valueOrigin"]],
            @"slider":     [NSSet setWithArray:@[@"id", @"default", @"min", @"max", @"label", @"step", @"ticks", @"type", @"snap", @"logscale", @"enabled", @"originValue"]],
            @"switch":     [NSSet setWithArray:@[@"id", @"default", @"label", @"enableTargets", @"enabled"]],
            @"color":      [NSSet setWithArray:@[@"id", @"default", @"label", @"alpha", @"enabled"]],
            @"point":      [NSSet setWithArray:@[@"id", @"label", @"default", @"min", @"max", @"step", @"enabled"]],
            @"selector":   [NSSet setWithArray:@[@"id", @"style", @"default", @"label", @"enabled"]],
            @"choice":     [NSSet setWithArray:@[@"label", @"value", @"enableTargets"]],
            @"section":    [NSSet setWithArray:@[@"text", @"hintType", @"label", @"enabled"]],
            @"texture":    [NSSet setWithArray:@[@"id", @"srcType", @"downsample", @"src", @"label", @"enabled"]],
            @"shader":     [NSSet setWithArray:@[@"type", @"precision", @"group", @"fastMath"]],
            @"passes":     [NSSet set],
            @"pass":       [NSSet setWithArray:@[@"target", @"blend", @"effect", @"src"]],
            @"iterations": [NSSet setWithArray:@[@"param", @"count"]],
            @"strings":    [NSSet set],
            @"locale":     [NSSet setWithArray:@[@"lang"]],
            @"string":     [NSSet setWithArray:@[@"name"]],
            @"tip":        [NSSet setWithArray:@[@"text"]],
            @"xyz":        [NSSet setWithArray:@[@"id", @"label", @"type", @"applyto", @"default", @"step", @"ticks", @"enabled"]],
            @"orient":     [NSSet setWithArray:@[@"id", @"label", @"invert", @"default", @"enabled"]],
            @"hue-disc":   [NSSet setWithArray:@[@"id", @"label", @"bias", @"default", @"enabled"]],
            @"hue-ring":   [NSSet setWithArray:@[@"id", @"label", @"default", @"enabled"]],
            @"presets":    [NSSet set],
            @"preset":     [NSSet setWithArray:@[@"id", @"label", @"timescale", @"timing", @"short-code", @"group"]],
            @"property":   [NSSet setWithArray:@[@"name", @"type", @"value"]],
            @"kf":         [NSSet setWithArray:@[@"t", @"v"]],
            @"float":      [NSSet setWithArray:@[@"id", @"value"]],
            @"script":     [NSSet setWithArray:@[@"external"]],
        };
    });
    return schema;
}

- (instancetype)init {
    if ((self = [super init])) {
        _valid = YES;
    }
    return self;
}

- (void)parser:(NSXMLParser *)parser didStartElement:(NSString *)elementName
  namespaceURI:(NSString *)namespaceURI qualifiedName:(NSString *)qName
    attributes:(NSDictionary<NSString *, NSString *> *)attributeDict {
    (void)namespaceURI; (void)qName;
    NSDictionary<NSString *, NSSet<NSString *> *> *schema = [AMEffectXMLSafetyValidator allowedSchema];
    NSSet<NSString *> *allowedAttrs = schema[elementName];
    if (!allowedAttrs) {
        self.valid = NO;
        [parser abortParsing];
        return;
    }
    for (NSString *attr in attributeDict) {
        if (![allowedAttrs containsObject:attr]) {
            self.valid = NO;
            [parser abortParsing];
            return;
        }
    }
    if ([elementName isEqualToString:@"effect"]) {
        self.sawEffectRoot = YES;
        if (attributeDict[@"id"].length == 0 || attributeDict[@"name"].length == 0) {
            self.valid = NO;
            [parser abortParsing];
            return;
        }
        NSString *effType = [attributeDict[@"type"] uppercaseString];
        if (effType && ![effType isEqualToString:@"SHADER"] && ![effType isEqualToString:@"TEXT"] && ![effType isEqualToString:@"DRAWING"]) {
            self.valid = NO;
            [parser abortParsing];
            return;
        }
    } else if ([elementName isEqualToString:@"shader"]) {
        self.sawShader = YES;
        NSString *st = attributeDict[@"type"];
        if (![st isEqualToString:@"fragment"] && ![st isEqualToString:@"vertex"]) {
            self.valid = NO;
            [parser abortParsing];
            return;
        }
        NSString *pr = attributeDict[@"precision"];
        if (pr && ![pr isEqualToString:@"low"] && ![pr isEqualToString:@"medium"] && ![pr isEqualToString:@"high"]) {
            self.valid = NO;
            [parser abortParsing];
            return;
        }
    }
}

@end

static BOOL AMIsEffectXMLSafeForIOSParser(NSString *path, NSMutableSet<NSString *> *seenIds) {
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data || data.length == 0) return NO;
    NSXMLParser *parser = [[NSXMLParser alloc] initWithData:data];
    AMEffectXMLSafetyValidator *val = [[AMEffectXMLSafetyValidator alloc] init];
    parser.delegate = val;
    BOOL ok = [parser parse];
    if (!ok || !val.valid || !val.sawEffectRoot || !val.sawShader) return NO;

    // Prevent duplicate effect IDs across external XMLs
    NSString *str = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (str) {
        static NSRegularExpression *idRx = nil;
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            idRx = [NSRegularExpression regularExpressionWithPattern:@"<effect\\b[^>]*\\bid\\s*=\\s*\"([^\"]+)\""
                                                             options:0 error:nil];
        });
        NSTextCheckingResult *m = [idRx firstMatchInString:str options:0 range:NSMakeRange(0, MIN((NSUInteger)1024, str.length))];
        if (m && m.numberOfRanges > 1) {
            NSString *eid = [str substringWithRange:[m rangeAtIndex:1]];
            if ([seenIds containsObject:eid]) return NO;
            [seenIds addObject:eid];
        }
    }
    return YES;
}

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
        NSMutableSet<NSString *> *seenIds = [NSMutableSet set];

        NSString *dir = AMCustomEffectsDir();
        NSArray<NSString *> *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:nil];
        for (NSString *fn in files) {
            if ([[fn pathExtension] caseInsensitiveCompare:@"xml"] == NSOrderedSame) {
                NSString *full = [dir stringByAppendingPathComponent:fn];
                if (AMIsEffectXMLSafeForIOSParser(full, seenIds)) {
                    [merged addObject:[NSURL fileURLWithPath:full]];
                }
            }
        }
        NSString *gmDir = [[[NSBundle mainBundle] bundlePath] stringByAppendingPathComponent:@"GoldMotionEffects"];
        NSArray<NSString *> *gmFiles = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:gmDir error:nil];
        for (NSString *fn in gmFiles) {
            if ([[fn pathExtension] caseInsensitiveCompare:@"xml"] == NSOrderedSame) {
                NSString *full = [gmDir stringByAppendingPathComponent:fn];
                if (AMIsEffectXMLSafeForIOSParser(full, seenIds)) {
                    [merged addObject:[NSURL fileURLWithPath:full]];
                }
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
        @"<effect id=\"com.alightcreative.effects.custom_invert\" compat=\"acScreenNorm-y\" name=\"Custom Invert\" desc=\"Inverts layer colors\" category=\"custom\" tags=\"custom\" thumb=\"thumb/box.webp\">\n"
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
                                                                  message:[NSString stringWithFormat:@"'%@' is saved. Reopen Alight Motion so its own effect box loads in Effects > Custom, then tap it to apply to any layer.", name]
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

static BOOL AMViewHierarchyContainsCustomTitle(UIView *v, NSInteger depth) {
    if (!v || depth > 5) return NO;
    if ([v isKindOfClass:[UILabel class]]) {
        NSString *t = ((UILabel *)v).text;
        if (t && [t caseInsensitiveCompare:@"Custom"] == NSOrderedSame) return YES;
    }
    for (UIView *sub in v.subviews) {
        if (AMViewHierarchyContainsCustomTitle(sub, depth + 1)) return YES;
    }
    return NO;
}

static BOOL AMIsCustomEffectCategoryVC(UIViewController *vc) {
    if (vc.title && [vc.title caseInsensitiveCompare:@"Custom"] == NSOrderedSame) return YES;
    if (vc.navigationItem.title && [vc.navigationItem.title caseInsensitiveCompare:@"Custom"] == NSOrderedSame) return YES;
    if (vc.navigationController && AMViewHierarchyContainsCustomTitle(vc.navigationController.navigationBar, 0)) return YES;
    if (AMViewHierarchyContainsCustomTitle(vc.view, 0)) return YES;
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
        BOOL isCustom = AMIsCustomEffectCategoryVC(vc);
        UIButton *existing = objc_getAssociatedObject(vc, kAMImportPlusBtnKey);
        if (!isCustom) {
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
static BOOL gAMFoldersModalOpen = NO;

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

static BOOL AMIsOnHomepage(UIWindow *win) {
    if (!win || !win.rootViewController) return NO;
    if (gAMSearchModalOpen || gAMFoldersModalOpen) return NO;
    UIViewController *root = win.rootViewController;
    if (root.presentedViewController != nil) return NO;
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
    NSInteger nativeSelectedCount;
    CGRect bottomBarFrame;
} AMHomepageProbeInfo;

static void AMWalkAccessibilityElements(id obj,
                                        NSInteger depth,
                                        NSMutableSet<NSValue *> *visited,
                                        void (^visitor)(id elem, NSString *label, CGRect screenFrame)) {
    if (!obj || depth > 20) return;
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
// Unified Homepage Overlay Manager (Search, + Folder, Inline Folders, Assign)
// ============================================================================

@interface AMHomepageSearchOverlayManager : NSObject
@property (nonatomic, strong, nullable) UIButton *searchButton;
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
        self.pollTimer = [NSTimer scheduledTimerWithTimeInterval:0.35
                                                          target:self
                                                        selector:@selector(tick)
                                                        userInfo:nil
                                                         repeats:YES];
    });
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

- (void)ensureButtonsInWindow:(UIWindow *)win {
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

    for (UIView *v in @[self.inlineFoldersView, self.searchButton, self.foldersButton, self.assignFolderButton]) {
        if (v.superview != win) [win addSubview:v];
        [win bringSubviewToFront:v];
    }
}

- (void)tick {
    UIWindow *win = AMKeyWindow();
    if (!win) return;
    if (!AMIsOnHomepage(win)) {
        self.searchButton.hidden = YES;
        self.foldersButton.hidden = YES;
        self.assignFolderButton.hidden = YES;
        self.inlineFoldersView.hidden = YES;
        return;
    }

    [self refreshProjectCacheIfNeeded:NO];
    [self ensureButtonsInWindow:win];

    AMHomepageProbeInfo probe = AMProbeHomepageAndTrackSelection(win,
                                                                 self.cachedProjectTitles ?: [NSSet set],
                                                                 self.trackedSelectedTitles);

    if (probe.isSelectionMode) {
        self.searchButton.hidden = YES;
        self.foldersButton.hidden = YES;
        self.inlineFoldersView.hidden = YES;

        CGFloat w = 164.0;
        CGFloat h = 42.0;
        CGFloat x = (win.bounds.size.width - w) * 0.5;
        CGFloat barTopY = !CGRectIsEmpty(probe.bottomBarFrame)
            ? (CGRectGetMinY(probe.bottomBarFrame) - 14.0)
            : (win.bounds.size.height - win.safeAreaInsets.bottom - 72.0);
        CGFloat y = barTopY - h - 10.0;
        self.assignFolderButton.frame = CGRectMake(x, y, w, h);
        self.assignFolderButton.hidden = NO;
        return;
    }

    self.assignFolderButton.hidden = YES;

    CGFloat size = 34.0;
    CGFloat sx = win.bounds.size.width - 16.0 - 36.0 - 10.0 - size;
    CGFloat sy = win.safeAreaInsets.top + 8.0;
    self.searchButton.frame = CGRectMake(sx, sy, size, size);
    self.searchButton.hidden = NO;

    if (probe.hasYourProjects) {
        CGFloat midY = CGRectGetMidY(probe.yourProjectsFrame);
        CGFloat minVisY = win.safeAreaInsets.top + 58.0;
        CGFloat maxVisY = win.bounds.size.height - win.safeAreaInsets.bottom - 75.0;
        if (midY > minVisY && midY < maxVisY) {
            CGFloat fw = 102.0;
            CGFloat fh = 30.0;
            CGFloat fx = win.bounds.size.width - 16.0 - fw;
            CGFloat fy = midY - (fh * 0.5);
            self.foldersButton.frame = CGRectMake(fx, fy, fw, fh);
            self.foldersButton.hidden = NO;

            [self.inlineFoldersView reloadForce:NO diskProjects:self.cachedDiskProjects ?: @[]];
            CGFloat topY = CGRectGetMaxY(probe.yourProjectsFrame) + 6.0;
            CGFloat maxH = MAX(0.0, (win.bounds.size.height - win.safeAreaInsets.bottom - 78.0) - topY);
            CGFloat h = [self.inlineFoldersView desiredHeightWithMaxHeight:maxH];
            if (h > 10.0) {
                self.inlineFoldersView.frame = CGRectMake(0.0, topY, win.bounds.size.width, h);
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

    AMSwizzleMethod(@"_TtC12AlightMotion18EffectPickerMainVC",
                    @"collectionView:willDisplayCell:forItemAtIndexPath:",
                    (IMP)AMHook_effectMainWillDisplayCell,
                    &gOrigEffectMainWillDisplayCell);

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

    dispatch_async(dispatch_get_main_queue(), ^{
        AMInstallCustomEffectCategoryIfNeeded();
        AMInstallMetalShaderCompatHook();
    });

    [[AMHomepageSearchOverlayManager shared] start];
}
