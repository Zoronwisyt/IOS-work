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
}
