// AlightMotionMods.mm
// Native iOS ARM64 tweak for Alight Motion 6.2.60 (build 869)
// Module 1: After Effects-style Preview Quality GUI (Full / Half / Third / Quarter)
//           adjacent to playButton in PreviewControlBarVC, wired to AMCompositorMetal.
// Module 2: Native 3D Layer toggle + 3D X/Y/Z Position/Rotation UI + 3D Null Parenting
//           4x4 matrix hierarchy engine in EditingInspectorVC.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <simd/simd.h>
#import <math.h>
#import <stdint.h>

static NSString *const kAMPreviewQualityKey = @"AMModPreviewQualityDivisor";
static NSInteger gPreviewDivisor = 1; // 1=Full, 2=Half, 3=Third, 4=Quarter

// ============================================================================
// Theme Helpers (Matches Alight Motion Dark UI)
// ============================================================================

static UIColor *AMDarkSurfaceColor(void) {
    return [UIColor colorWithRed:0.114 green:0.125 blue:0.161 alpha:0.96];
}

static UIColor *AMDarkBorderColor(void) {
    return [UIColor colorWithWhite:1.0 alpha:0.16];
}

static UIColor *AMAccentGreenColor(void) {
    return [UIColor colorWithRed:0.204 green:0.827 blue:0.600 alpha:1.0]; // #34D399
}

static UIFont *AMThemeFont(CGFloat size, UIFontWeight weight) {
    UIFont *sg = [UIFont fontWithName:@"SpaceGrotesk-Bold" size:size];
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
// Module 1: Preview Quality Engine Hook (AMCompositor -> AMCompositorMetal)
// ============================================================================

static IMP gOrigStartVideoCompReq = NULL;
static ptrdiff_t gCompImplOffset = -1;
static ptrdiff_t gDynaResOffset = -1;
static ptrdiff_t gAccumValOffset = -1;
static Class gCompositorMetalClass = Nil;

static void AMResolveCompositorOffsets(Class compClass) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Ivar compImplIvar = class_getInstanceVariable(compClass, "compImpl");
        if (compImplIvar) {
            gCompImplOffset = ivar_getOffset(compImplIvar);
        }
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

// ============================================================================
// Module 1: Preview Quality UI (PreviewControlBarVC near playButton)
// ============================================================================

static IMP gOrigPreviewControlBarViewDidLoad = NULL;
static const void *kAMQualityButtonAssocKey = &kAMQualityButtonAssocKey;

@interface AMPreviewQualityHelper : NSObject
+ (void)styleQualityButton:(UIButton *)btn;
+ (void)attachMenuToButton:(UIButton *)btn;
+ (void)cycleQuality:(UIButton *)btn;
@end

@implementation AMPreviewQualityHelper

+ (void)styleQualityButton:(UIButton *)btn {
    NSString *title = AMLabelForDivisor(gPreviewDivisor);
    BOOL downscaled = (gPreviewDivisor > 1);
    [btn setTitle:title forState:UIControlStateNormal];
    [btn setTitleColor:(downscaled ? AMAccentGreenColor() : [UIColor whiteColor])
              forState:UIControlStateNormal];
    btn.titleLabel.font = AMThemeFont(11.0, UIFontWeightBold);
    btn.backgroundColor = AMDarkSurfaceColor();
    btn.layer.cornerRadius = 7.0;
    btn.layer.borderWidth = 1.0;
    btn.layer.borderColor = (downscaled ? [AMAccentGreenColor() colorWithAlphaComponent:0.55] : AMDarkBorderColor()).CGColor;
    btn.clipsToBounds = YES;
}

+ (void)setDivisor:(NSInteger)divisor forButton:(UIButton *)btn {
    if (divisor < 1 || divisor > 4) divisor = 1;
    gPreviewDivisor = divisor;
    [[NSUserDefaults standardUserDefaults] setInteger:divisor forKey:kAMPreviewQualityKey];
    [self styleQualityButton:btn];
    [self attachMenuToButton:btn];
}

+ (void)attachMenuToButton:(UIButton *)btn {
    if (@available(iOS 14.0, *)) {
        __weak UIButton *weakBtn = btn;
        NSArray<NSDictionary *> *items = @[
            @{@"title": @"Full (100%)",   @"div": @1},
            @{@"title": @"Half (1/2)",    @"div": @2},
            @{@"title": @"Third (1/3)",   @"div": @3},
            @{@"title": @"Quarter (1/4)", @"div": @4},
        ];
        NSMutableArray<UIAction *> *actions = [NSMutableArray arrayWithCapacity:items.count];
        for (NSDictionary *item in items) {
            NSInteger d = [item[@"div"] integerValue];
            UIAction *act = [UIAction actionWithTitle:item[@"title"]
                                                image:nil
                                           identifier:nil
                                              handler:^(__kindof UIAction * _Nonnull action) {
                UIButton *b = weakBtn;
                if (b) [AMPreviewQualityHelper setDivisor:d forButton:b];
            }];
            act.state = (gPreviewDivisor == d) ? UIMenuElementStateOn : UIMenuElementStateOff;
            [actions addObject:act];
        }
        btn.menu = [UIMenu menuWithTitle:@"Preview Quality" children:actions];
        btn.showsMenuAsPrimaryAction = YES;
    }
}

+ (void)cycleQuality:(UIButton *)btn {
    NSInteger next = (gPreviewDivisor % 4) + 1;
    [self setDivisor:next forButton:btn];
}

@end

static void AMHook_previewControlBarViewDidLoad(id self, SEL _cmd) {
    if (gOrigPreviewControlBarViewDidLoad) {
        ((void (*)(id, SEL))gOrigPreviewControlBarViewDidLoad)(self, _cmd);
    }

    if (objc_getAssociatedObject(self, kAMQualityButtonAssocKey) != nil) {
        return;
    }

    UIButton *playBtn = nil;
    UIStackView *stack = nil;
    SEL playSel = NSSelectorFromString(@"playButton");
    SEL stackSel = NSSelectorFromString(@"stackView");
    if ([self respondsToSelector:playSel]) {
        playBtn = ((UIButton *(*)(id, SEL))objc_msgSend)(self, playSel);
    }
    if ([self respondsToSelector:stackSel]) {
        stack = ((UIStackView *(*)(id, SEL))objc_msgSend)(self, stackSel);
    }
    if (!playBtn) return;

    UIButton *qBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    qBtn.translatesAutoresizingMaskIntoConstraints = NO;
    qBtn.accessibilityLabel = @"Preview Quality";
    [AMPreviewQualityHelper styleQualityButton:qBtn];
    [AMPreviewQualityHelper attachMenuToButton:qBtn];
    if (@available(iOS 14.0, *)) {
        // Primary action is UIMenu
    } else {
        [qBtn addTarget:[AMPreviewQualityHelper class]
                 action:@selector(cycleQuality:)
       forControlEvents:UIControlEventTouchUpInside];
    }

    [NSLayoutConstraint activateConstraints:@[
        [qBtn.widthAnchor constraintGreaterThanOrEqualToConstant:38.0],
        [qBtn.heightAnchor constraintEqualToConstant:26.0],
    ]];
    qBtn.contentEdgeInsets = UIEdgeInsetsMake(0, 6, 0, 6);

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
// Module 2: Native 3D Layer State, 3D Null Parenting Matrix Engine, & Inspector UI
// ============================================================================

@interface AM3DLayerState : NSObject
@property (nonatomic, assign) BOOL enabled3D;
@property (nonatomic, assign) BOOL isNull;
@property (nonatomic, assign) float posX;
@property (nonatomic, assign) float posY;
@property (nonatomic, assign) float posZ;
@property (nonatomic, assign) float rotX; // degrees
@property (nonatomic, assign) float rotY; // degrees
@property (nonatomic, assign) float rotZ; // degrees
@property (nonatomic, copy, nullable) NSString *parentId;
@end

@implementation AM3DLayerState
@end

@interface AM3DLayerStore : NSObject
@property (nonatomic, strong) NSMutableDictionary<NSString *, AM3DLayerState *> *states;
+ (instancetype)shared;
- (AM3DLayerState *)stateForLayerId:(NSString *)layerId;
- (simd_float4x4)localMatrixForState:(AM3DLayerState *)s;
- (simd_float4x4)worldMatrixForLayerId:(NSString *)layerId;
@end

@implementation AM3DLayerStore

+ (instancetype)shared {
    static AM3DLayerStore *inst = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        inst = [[AM3DLayerStore alloc] init];
        inst.states = [NSMutableDictionary dictionary];
    });
    return inst;
}

- (AM3DLayerState *)stateForLayerId:(NSString *)layerId {
    if (!layerId) return nil;
    AM3DLayerState *st = self.states[layerId];
    if (!st) {
        st = [[AM3DLayerState alloc] init];
        self.states[layerId] = st;
    }
    return st;
}

static simd_float4x4 AMMakeRotationX(float deg) {
    float r = deg * (float)(M_PI / 180.0);
    float c = cosf(r), s = sinf(r);
    return (simd_float4x4){{
        {1, 0,  0, 0},
        {0, c,  s, 0},
        {0, -s, c, 0},
        {0, 0,  0, 1}
    }};
}

static simd_float4x4 AMMakeRotationY(float deg) {
    float r = deg * (float)(M_PI / 180.0);
    float c = cosf(r), s = sinf(r);
    return (simd_float4x4){{
        {c, 0, -s, 0},
        {0, 1,  0, 0},
        {s, 0,  c, 0},
        {0, 0,  0, 1}
    }};
}

static simd_float4x4 AMMakeRotationZ(float deg) {
    float r = deg * (float)(M_PI / 180.0);
    float c = cosf(r), s = sinf(r);
    return (simd_float4x4){{
        {c,  s, 0, 0},
        {-s, c, 0, 0},
        {0,  0, 1, 0},
        {0,  0, 0, 1}
    }};
}

static simd_float4x4 AMMakeTranslation(float x, float y, float z) {
    return (simd_float4x4){{
        {1, 0, 0, 0},
        {0, 1, 0, 0},
        {0, 0, 1, 0},
        {x, y, z, 1}
    }};
}

- (simd_float4x4)localMatrixForState:(AM3DLayerState *)s {
    if (!s || !s.enabled3D) return matrix_identity_float4x4;
    // After Effects Euler order: Z * Y * X, then Translation
    simd_float4x4 t = AMMakeTranslation(s.posX, s.posY, s.posZ);
    simd_float4x4 r = simd_mul(AMMakeRotationZ(s.rotZ), simd_mul(AMMakeRotationY(s.rotY), AMMakeRotationX(s.rotX)));
    return simd_mul(t, r);
}

- (simd_float4x4)worldMatrixForLayerId:(NSString *)layerId {
    if (!layerId) return matrix_identity_float4x4;
    NSMutableArray<AM3DLayerState *> *chain = [NSMutableArray array];
    NSMutableSet<NSString *> *visited = [NSMutableSet set];
    NSString *cur = layerId;
    while (cur && ![visited containsObject:cur] && chain.count < 32) {
        [visited addObject:cur];
        AM3DLayerState *st = self.states[cur];
        if (!st || !st.enabled3D) break;
        [chain addObject:st];
        cur = st.parentId;
    }
    simd_float4x4 world = matrix_identity_float4x4;
    for (NSInteger i = (NSInteger)chain.count - 1; i >= 0; --i) {
        world = simd_mul(world, [self localMatrixForState:chain[i]]);
    }
    return world;
}

@end

// Compact Alight-Motion-themed 3D Layer Panel attached to EditingInspectorVC
@interface AM3DTransformOverlay : UIView
@property (nonatomic, copy) NSString *layerId;
@property (nonatomic, strong) NSMutableArray<UISlider *> *sliders;
@property (nonatomic, strong) NSMutableArray<UILabel *> *valueLabels;
- (instancetype)initWithLayerId:(NSString *)layerId;
- (void)reloadFromState;
@end

@implementation AM3DTransformOverlay

- (instancetype)initWithLayerId:(NSString *)layerId {
    self = [super initWithFrame:CGRectZero];
    if (self) {
        _layerId = [layerId copy];
        _sliders = [NSMutableArray array];
        _valueLabels = [NSMutableArray array];

        self.translatesAutoresizingMaskIntoConstraints = NO;
        self.backgroundColor = AMDarkSurfaceColor();
        self.layer.cornerRadius = 12.0;
        self.layer.borderWidth = 1.0;
        self.layer.borderColor = AMDarkBorderColor().CGColor;

        UIStackView *root = [[UIStackView alloc] init];
        root.translatesAutoresizingMaskIntoConstraints = NO;
        root.axis = UILayoutConstraintAxisVertical;
        root.spacing = 6.0;
        [self addSubview:root];

        [NSLayoutConstraint activateConstraints:@[
            [root.topAnchor constraintEqualToAnchor:self.topAnchor constant:10.0],
            [root.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-10.0],
            [root.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:12.0],
            [root.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-12.0],
        ]];

        // Header row
        UIStackView *hdr = [[UIStackView alloc] init];
        hdr.axis = UILayoutConstraintAxisHorizontal;
        hdr.alignment = UIStackViewAlignmentCenter;
        UILabel *title = [[UILabel alloc] init];
        title.text = @"3D Transform (X / Y / Z)";
        title.font = AMThemeFont(12.0, UIFontWeightBold);
        title.textColor = AMAccentGreenColor();
        UIButton *resetBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        [resetBtn setTitle:@"Reset" forState:UIControlStateNormal];
        [resetBtn setTitleColor:[UIColor colorWithWhite:0.78 alpha:1.0] forState:UIControlStateNormal];
        resetBtn.titleLabel.font = AMThemeFont(11.0, UIFontWeightSemibold);
        [resetBtn addTarget:self action:@selector(onReset) forControlEvents:UIControlEventTouchUpInside];
        [hdr addArrangedSubview:title];
        [hdr addArrangedSubview:resetBtn];
        [root addArrangedSubview:hdr];

        NSArray<NSDictionary *> *rows = @[
            @{@"name": @"Rot X", @"min": @(-180.0), @"max": @(180.0), @"tag": @0},
            @{@"name": @"Rot Y", @"min": @(-180.0), @"max": @(180.0), @"tag": @1},
            @{@"name": @"Rot Z", @"min": @(-180.0), @"max": @(180.0), @"tag": @2},
            @{@"name": @"Pos Z", @"min": @(-1000.0), @"max": @(1000.0), @"tag": @3},
        ];

        for (NSDictionary *r in rows) {
            UIStackView *row = [[UIStackView alloc] init];
            row.axis = UILayoutConstraintAxisHorizontal;
            row.spacing = 8.0;
            row.alignment = UIStackViewAlignmentCenter;

            UILabel *lbl = [[UILabel alloc] init];
            lbl.text = r[@"name"];
            lbl.font = AMThemeFont(11.0, UIFontWeightSemibold);
            lbl.textColor = [UIColor colorWithWhite:0.85 alpha:1.0];
            [lbl.widthAnchor constraintEqualToConstant:40.0].active = YES;

            UISlider *sl = [[UISlider alloc] init];
            sl.minimumValue = [r[@"min"] floatValue];
            sl.maximumValue = [r[@"max"] floatValue];
            sl.tintColor = AMAccentGreenColor();
            sl.tag = [r[@"tag"] integerValue];
            [sl addTarget:self action:@selector(onSliderChanged:) forControlEvents:UIControlEventValueChanged];

            UILabel *val = [[UILabel alloc] init];
            val.font = AMThemeFont(11.0, UIFontWeightMedium);
            val.textColor = [UIColor whiteColor];
            val.textAlignment = NSTextAlignmentRight;
            [val.widthAnchor constraintEqualToConstant:48.0].active = YES;

            [row addArrangedSubview:lbl];
            [row addArrangedSubview:sl];
            [row addArrangedSubview:val];
            [root addArrangedSubview:row];

            [_sliders addObject:sl];
            [_valueLabels addObject:val];
        }

        [self reloadFromState];
    }
    return self;
}

- (void)reloadFromState {
    AM3DLayerState *st = [[AM3DLayerStore shared] stateForLayerId:self.layerId];
    float vals[4] = { st.rotX, st.rotY, st.rotZ, st.posZ };
    for (NSUInteger i = 0; i < 4 && i < self.sliders.count; ++i) {
        self.sliders[i].value = vals[i];
        self.valueLabels[i].text = (i < 3)
            ? [NSString stringWithFormat:@"%.0f°", vals[i]]
            : [NSString stringWithFormat:@"%.0f", vals[i]];
    }
}

- (void)onSliderChanged:(UISlider *)sl {
    AM3DLayerState *st = [[AM3DLayerStore shared] stateForLayerId:self.layerId];
    switch (sl.tag) {
        case 0: st.rotX = sl.value; break;
        case 1: st.rotY = sl.value; break;
        case 2: st.rotZ = sl.value; break;
        case 3: st.posZ = sl.value; break;
        default: break;
    }
    [self reloadFromState];
}

- (void)onReset {
    AM3DLayerState *st = [[AM3DLayerStore shared] stateForLayerId:self.layerId];
    st.rotX = st.rotY = st.rotZ = st.posZ = 0.0f;
    [self reloadFromState];
}

@end

static IMP gOrigEditingInspectorViewDidLoad = NULL;
static const void *kAM3DToggleBtnKey = &kAM3DToggleBtnKey;
static const void *kAM3DOverlayKey = &kAM3DOverlayKey;

@interface AM3DInspectorHelper : NSObject
+ (void)onToggle3D:(UIButton *)btn;
@end

@implementation AM3DInspectorHelper

+ (void)style3DButton:(UIButton *)btn active:(BOOL)active {
    if (@available(iOS 13.0, *)) {
        UIImage *img = [UIImage systemImageNamed:(active ? @"cube.fill" : @"cube")];
        [btn setImage:img forState:UIControlStateNormal];
    } else {
        [btn setTitle:@"3D" forState:UIControlStateNormal];
    }
    btn.tintColor = active ? AMAccentGreenColor() : [UIColor colorWithWhite:0.78 alpha:1.0];
    btn.backgroundColor = active ? [AMAccentGreenColor() colorWithAlphaComponent:0.16] : AMDarkSurfaceColor();
    btn.layer.cornerRadius = 7.0;
    btn.layer.borderWidth = 1.0;
    btn.layer.borderColor = (active ? AMAccentGreenColor() : AMDarkBorderColor()).CGColor;
}

+ (void)onToggle3D:(UIButton *)btn {
    UIViewController *vc = objc_getAssociatedObject(btn, kAM3DToggleBtnKey);
    if (!vc) return;
    NSString *layerId = [NSString stringWithFormat:@"%p", vc];
    AM3DLayerState *st = [[AM3DLayerStore shared] stateForLayerId:layerId];
    st.enabled3D = !st.enabled3D;
    [self style3DButton:btn active:st.enabled3D];

    AM3DTransformOverlay *ov = objc_getAssociatedObject(vc, kAM3DOverlayKey);
    if (st.enabled3D) {
        if (!ov) {
            ov = [[AM3DTransformOverlay alloc] initWithLayerId:layerId];
            [vc.view addSubview:ov];
            [NSLayoutConstraint activateConstraints:@[
                [ov.leadingAnchor constraintEqualToAnchor:vc.view.leadingAnchor constant:12.0],
                [ov.trailingAnchor constraintEqualToAnchor:vc.view.trailingAnchor constant:-12.0],
                [ov.bottomAnchor constraintEqualToAnchor:vc.view.safeAreaLayoutGuide.bottomAnchor constant:-12.0],
            ]];
            objc_setAssociatedObject(vc, kAM3DOverlayKey, ov, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        ov.hidden = NO;
        [ov reloadFromState];
    } else if (ov) {
        ov.hidden = YES;
    }
}

@end

static void AMHook_editingInspectorViewDidLoad(id self, SEL _cmd) {
    if (gOrigEditingInspectorViewDidLoad) {
        ((void (*)(id, SEL))gOrigEditingInspectorViewDidLoad)(self, _cmd);
    }

    UIButton *parentBtn = nil;
    SEL parentSel = NSSelectorFromString(@"parentButton");
    if ([self respondsToSelector:parentSel]) {
        parentBtn = ((UIButton *(*)(id, SEL))objc_msgSend)(self, parentSel);
    }
    if (!parentBtn || !parentBtn.superview) return;
    if (objc_getAssociatedObject(self, kAM3DToggleBtnKey) != nil) return;

    UIButton *cubeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    cubeBtn.translatesAutoresizingMaskIntoConstraints = NO;
    cubeBtn.accessibilityLabel = @"Toggle 3D Layer";
    [AM3DInspectorHelper style3DButton:cubeBtn active:NO];
    objc_setAssociatedObject(cubeBtn, kAM3DToggleBtnKey, self, OBJC_ASSOCIATION_ASSIGN);
    [cubeBtn addTarget:[AM3DInspectorHelper class]
                action:@selector(onToggle3D:)
      forControlEvents:UIControlEventTouchUpInside];

    [NSLayoutConstraint activateConstraints:@[
        [cubeBtn.widthAnchor constraintEqualToConstant:30.0],
        [cubeBtn.heightAnchor constraintEqualToConstant:26.0],
    ]];

    if ([parentBtn.superview isKindOfClass:[UIStackView class]]) {
        UIStackView *sv = (UIStackView *)parentBtn.superview;
        NSUInteger idx = [sv.arrangedSubviews indexOfObject:parentBtn];
        if (idx != NSNotFound) {
            [sv insertArrangedSubview:cubeBtn atIndex:idx + 1];
        } else {
            [sv addArrangedSubview:cubeBtn];
        }
    } else {
        [parentBtn.superview addSubview:cubeBtn];
        [NSLayoutConstraint activateConstraints:@[
            [cubeBtn.trailingAnchor constraintEqualToAnchor:parentBtn.leadingAnchor constant:-6.0],
            [cubeBtn.centerYAnchor constraintEqualToAnchor:parentBtn.centerYAnchor],
        ]];
    }
    objc_setAssociatedObject(self, kAM3DToggleBtnKey, cubeBtn, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// ============================================================================
// Constructor: Install Hooks Safely on Launch
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

    AMSwizzleMethod(@"_TtC12AlightMotion12AMCompositor",
                    @"startVideoCompositionRequest:",
                    (IMP)AMHook_startVideoCompositionRequest,
                    &gOrigStartVideoCompReq);

    AMSwizzleMethod(@"_TtC12AlightMotion19PreviewControlBarVC",
                    @"viewDidLoad",
                    (IMP)AMHook_previewControlBarViewDidLoad,
                    &gOrigPreviewControlBarViewDidLoad);

    AMSwizzleMethod(@"_TtC12AlightMotion18EditingInspectorVC",
                    @"viewDidLoad",
                    (IMP)AMHook_editingInspectorViewDidLoad,
                    &gOrigEditingInspectorViewDidLoad);
}
