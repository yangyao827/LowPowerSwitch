#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>

@interface NSObject (LPCCPrivate)
+ (NSString *)identifier;
- (BOOL)isEnabled;
- (id)module;
- (UIColor *)selectedStateColor;
- (void)setMaxButtonsPerPage:(NSUInteger)count;
@end

static Class lowPowerClass;
static Class settingsSectionClass;
static NSString *lowPowerIdentifier;
static void (*HookMessage)(Class, SEL, IMP, IMP *);
static char badgeKey;

static BOOL Supported(id self, SEL cmd, int layoutStyle) { return YES; }
static BOOL NotInternal(id self, SEL cmd) { return NO; }
static BOOL EnabledByDefault(id self, SEL cmd) { return YES; }
static NSString *StatusOn(id self, SEL cmd) { return @"低电量模式：打开"; }
static NSString *StatusOff(id self, SEL cmd) { return @"低电量模式：关闭"; }

@interface LPCCBatteryBadge : UIView
@property (nonatomic, weak) id module;
@end
@implementation LPCCBatteryBadge
- (void)drawRect:(CGRect)rect {
    BOOL active = [self.module isEnabled];
    UIColor *ink = active ? [UIColor whiteColor] : [UIColor blackColor];
    [ink setStroke];
    [ink setFill];
    CGFloat width = MIN(26, MIN(self.bounds.size.width, self.bounds.size.height) * 0.52);
    CGFloat height = width * 0.53;
    CGFloat x = CGRectGetMidX(self.bounds) - (width + 3.5) / 2;
    CGFloat y = CGRectGetMidY(self.bounds) - height / 2;
    UIBezierPath *outline = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(x, y, width, height) cornerRadius:2.7];
    outline.lineWidth = 1.9;
    [outline stroke];
    [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(x + width + 2.4, y + height * 0.30, 1.9, height * 0.4) cornerRadius:0.9] fill];
    [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(x + 2.6, y + 2.6, 4.2, height - 5.2) cornerRadius:0.7] fill];
}
@end

static void LayoutBattery(UIView *button) {
    LPCCBatteryBadge *badge = objc_getAssociatedObject(button, &badgeKey);
    if (!badge) return;
    badge.frame = button.bounds;
    for (NSString *name in @[@"_glyphImageView", @"_alteredStateGlyphImageView"]) {
        Ivar ivar = class_getInstanceVariable([button class], name.UTF8String);
        UIView *glyph = ivar ? object_getIvar(button, ivar) : nil;
        glyph.hidden = YES;
    }
    [button bringSubviewToFront:badge];
    [badge setNeedsDisplay];
}

static UIImage *Glyph(id self, SEL cmd, int state) {
    // Keep native button materials; an overlay preserves the two glyph colors
    // through iOS 10's tint and punch-out compositor.
    static UIImage *transparent;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        UIGraphicsBeginImageContextWithOptions(CGSizeMake(32, 28), NO, 0);
        transparent = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
    });
    return transparent;
}

static UIColor *SelectedColor(id self, SEL cmd) {
    // Read the native airplane module's selected color, so the two buttons
    // use exactly the same fill rather than approximating it from a screenshot.
    static UIColor *color;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class airplane = objc_getClass("CCUIAirplaneModeSetting");
        id module = airplane ? [airplane new] : nil;
        if ([module respondsToSelector:@selector(selectedStateColor)])
            color = [module selectedStateColor];
        if (!color) color = [UIColor colorWithRed:1 green:149.0 / 255.0 blue:0 alpha:1];
    });
    return color;
}

static id (*originalCreateButton)(id, SEL);
static id CreateButton(id self, SEL cmd) {
    UIView *button = originalCreateButton(self, cmd);
    id module = [self module];
    if (button && [module isKindOfClass:lowPowerClass]) {
        LPCCBatteryBadge *badge = [[LPCCBatteryBadge alloc] initWithFrame:button.bounds];
        badge.module = module;
        badge.backgroundColor = [UIColor clearColor];
        badge.opaque = NO;
        badge.userInteractionEnabled = NO;
        badge.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        badge.contentMode = UIViewContentModeRedraw;
        objc_setAssociatedObject(button, &badgeKey, badge, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [button addSubview:badge];
        LayoutBattery(button);
    }
    return button;
}

static void (*originalButtonLayout)(id, SEL);
static void ButtonLayout(id self, SEL cmd) {
    originalButtonLayout(self, cmd);
    LayoutBattery(self);
}

static void (*originalUpdateButtonState)(id, SEL);
static void UpdateButtonState(id self, SEL cmd) {
    originalUpdateButtonState(self, cmd);
    if ([[self module] isKindOfClass:lowPowerClass])
        LayoutBattery([(UIViewController *)self view]);
}

static NSArray *(*originalSupportedClasses)(id, SEL);
static NSArray *SupportedClasses(id self, SEL cmd) {
    NSArray *classes = originalSupportedClasses(self, cmd);
    if ([classes containsObject:lowPowerClass]) return classes;
    return [(classes ?: @[]) arrayByAddingObject:lowPowerClass];
}

static BOOL (*originalButtonEnabled)(id, SEL, NSString *);
static BOOL ButtonEnabled(id self, SEL cmd, NSString *identifier) {
    if ([identifier isEqualToString:lowPowerIdentifier]) return YES;
    return originalButtonEnabled(self, cmd, identifier);
}

static void (*originalViewWillAppear)(id, SEL, BOOL);
static void ViewWillAppear(id self, SEL cmd, BOOL animated) {
    originalViewWillAppear(self, cmd, animated);
    // The native settings section resets this to five each presentation.
    // Restrict the extra slot to this section; shortcut buttons are separate.
    UIView *view = [(UIViewController *)self view];
    if ([view respondsToSelector:@selector(setMaxButtonsPerPage:)])
        [(id)view setMaxButtonsPerPage:6];
}

static void Hook(Class cls, const char *name, IMP replacement, IMP *original) {
    HookMessage(cls, sel_registerName(name), replacement, original);
}

__attribute__((constructor)) static void Init(void) {
    @autoreleasepool {
        if (![[NSBundle mainBundle].bundleIdentifier isEqualToString:@"com.apple.springboard"]) return;
        if (!dlopen("/System/Library/PrivateFrameworks/ControlCenterUI.framework/ControlCenterUI", RTLD_NOW)) return;
        lowPowerClass = objc_getClass("CCUILowPowerModeSetting");
        settingsSectionClass = objc_getClass("CCUISettingsSectionController");
        if (!lowPowerClass || !settingsSectionClass) return;
        Class meta = object_getClass(lowPowerClass);
        for (NSString *name in @[@"isSupported:", @"isInternalButton", @"enabledByDefault", @"identifier", @"statusOnString", @"statusOffString"])
            if (!class_getInstanceMethod(meta, NSSelectorFromString(name))) return;
        for (NSString *name in @[@"_supportedButtonModuleClasses", @"_buttonEnabledForIdentifier:", @"viewWillAppear:"])
            if (!class_getInstanceMethod(settingsSectionClass, NSSelectorFromString(name))) return;
        lowPowerIdentifier = [lowPowerClass identifier];
        if (!lowPowerIdentifier.length) return;
        if (!class_getInstanceMethod(lowPowerClass, @selector(glyphImageForState:)) ||
            !class_getInstanceMethod(lowPowerClass, sel_registerName("selectedStateColor")) ||
            !class_getInstanceMethod(lowPowerClass, sel_registerName("statusUpdate"))) return;
        Class controller = objc_getClass("CCUISettingButtonController");
        Class button = objc_getClass("CCUIControlCenterButton");
        if (!controller || !button ||
            !class_getInstanceMethod(controller, sel_registerName("_createButtonView")) ||
            !class_getInstanceMethod(controller, sel_registerName("_updateButtonState")) ||
            !class_getInstanceMethod(button, sel_registerName("layoutSubviews"))) return;
        void *substrate = dlopen("/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate", RTLD_NOW);
        if (!substrate) substrate = dlopen("/usr/lib/libsubstrate.dylib", RTLD_NOW);
        if (!substrate) return;
        HookMessage = dlsym(substrate, "MSHookMessageEx");
        if (!HookMessage) return;
        Hook(meta, "isSupported:", (IMP)Supported, NULL);
        Hook(meta, "isInternalButton", (IMP)NotInternal, NULL);
        Hook(meta, "enabledByDefault", (IMP)EnabledByDefault, NULL);
        // The native status publisher chooses the message from current state.
        Hook(meta, "statusOnString", (IMP)StatusOn, NULL);
        Hook(meta, "statusOffString", (IMP)StatusOff, NULL);
        Hook(lowPowerClass, "glyphImageForState:", (IMP)Glyph, NULL);
        Hook(lowPowerClass, "selectedStateColor", (IMP)SelectedColor, NULL);
        Hook(controller, "_createButtonView", (IMP)CreateButton, (IMP *)&originalCreateButton);
        Hook(controller, "_updateButtonState", (IMP)UpdateButtonState, (IMP *)&originalUpdateButtonState);
        Hook(button, "layoutSubviews", (IMP)ButtonLayout, (IMP *)&originalButtonLayout);
        Hook(settingsSectionClass, "_supportedButtonModuleClasses", (IMP)SupportedClasses, (IMP *)&originalSupportedClasses);
        Hook(settingsSectionClass, "_buttonEnabledForIdentifier:", (IMP)ButtonEnabled, (IMP *)&originalButtonEnabled);
        Hook(settingsSectionClass, "viewWillAppear:", (IMP)ViewWillAppear, (IMP *)&originalViewWillAppear);
    }
}
