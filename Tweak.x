#import <UIKit/UIKit.h>
#import <objc/runtime.h>

struct SBIconCoordinate { long long row; long long col; };

@interface SBIconView : UIView
+ (CGSize)defaultIconSize;
@end
@interface SBIconImageView : UIView
@end
@interface SBIconListView : UIView
- (unsigned long long)iconColumnsForCurrentOrientation;
- (CGFloat)topIconInset;
- (NSArray *)icons;
@end
@interface SBRootFolderView : UIView
@end
@interface SBIconListModel : NSObject
- (NSArray *)icons;
- (void)addIcon:(id)icon;
- (void)removeIcon:(id)icon;
@end
@interface SBFolder : NSObject
- (NSArray *)lists;
- (void)removeEmptyLists;
@end
@interface SBIconController : NSObject
+ (instancetype)sharedInstance;
- (SBFolder *)rootFolder;
- (id)grabbedIcon;
@end
@interface SpringBoard : UIApplication
@end
@interface SBSearchGesture : NSObject
+ (instancetype)sharedInstance;
- (void)setEnabled:(BOOL)enabled;
@end

@protocol CIRTouchDelegate <NSObject>
- (void)cirTouchBegan;
@end

static BOOL gEnabled = YES;
static NSInteger gFirstRow = 4; // 4 -> 4-3-4-3, 3 -> 3-4-3-4

#pragma mark - utils

static void CIRLog(NSString *fmt, ...) {
    va_list a; va_start(a, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:a];
    va_end(a);
    NSString *line = [s stringByAppendingString:@"\n"];
    NSString *path = @"/var/mobile/circular.log";
    NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!h) { [line writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil]; return; }
    [h seekToEndOfFile];
    [h writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
    [h closeFile];
}

static void loadPrefs(void) {
    NSDictionary *p = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/Preferences/com.cursorus.circular.plist"];
    gEnabled = p[@"enabled"] ? [p[@"enabled"] boolValue] : YES;
    NSInteger f = p[@"firstRow"] ? [p[@"firstRow"] integerValue] : 4;
    gFirstRow = (f == 3) ? 3 : 4;
}

static void prefsChanged(CFNotificationCenterRef c, void *o, CFStringRef n, const void *obj, CFDictionaryRef u) {
    loadPrefs();
}

// only the home screen pages, not the dock and not folders
static BOOL isRootList(UIView *v) {
    NSString *n = NSStringFromClass([v class]);
    return ![n containsString:@"Dock"] && ![n containsString:@"Folder"];
}

// linear index -> row / column / icons in that row
static void slotFor(unsigned long long idx, NSInteger *row, NSInteger *col, NSInteger *count) {
    NSInteger a = gFirstRow;
    NSInteger b = (a == 4) ? 3 : 4;
    NSInteger pair = (NSInteger)(idx / 7), r = (NSInteger)(idx % 7);
    if (r < a) { *row = pair * 2;     *col = r;     *count = a; }
    else       { *row = pair * 2 + 1; *col = r - a; *count = b; }
}

static CGFloat topInsetFor(SBIconListView *list) {
    return [list respondsToSelector:@selector(topIconInset)] ? [list topIconInset] : 30.0;
}

static CGPoint circularOrigin(SBIconListView *list, unsigned long long idx) {
    NSInteger row, col, count;
    slotFor(idx, &row, &col, &count);
    CGFloat W = list.bounds.size.width;
    CGFloat pitch = W / 4.0;                       // 80 on 5s
    CGSize isz = [%c(SBIconView) defaultIconSize]; // 60x60 on 5s
    CGFloat x = (W - count * pitch) / 2.0 + col * pitch + (pitch - isz.width) / 2.0;
    CGFloat y = topInsetFor(list) + row * pitch;
    return CGPointMake(x, y);
}

static CGFloat contentHeightFor(SBIconListView *list) {
    NSUInteger n = [list respondsToSelector:@selector(icons)] ? [[list icons] count] : 0;
    if (n == 0) return 0;
    NSInteger row, col, count;
    slotFor(n - 1, &row, &col, &count);
    return topInsetFor(list) + (row + 1) * (list.bounds.size.width / 4.0) + 30.0;
}

static BOOL gSearchApi = NO;

static void setSearchEnabled(BOOL on) {
    Class c = NSClassFromString(@"SBSearchGesture");
    if (!c || ![c respondsToSelector:@selector(sharedInstance)]) return;
    id g = [c sharedInstance];
    if ([g respondsToSelector:@selector(setEnabled:)]) { [g setEnabled:on]; gSearchApi = YES; }
}

// diagnostics: methods/ivars whose names look related to page capacity
static void dumpClass(NSString *name) {
    Class c = NSClassFromString(name);
    if (!c) { CIRLog(@"dump %@: class not found", name); return; }
    NSArray *keys = @[@"max", @"full", @"room", @"free", @"empty", @"page", @"overflow", @"capacity", @"slot"];
    NSMutableArray *out = [NSMutableArray array];
    for (int meta = 0; meta < 2; meta++) {
        Class k = meta ? object_getClass(c) : c;
        unsigned int n = 0;
        Method *ms = class_copyMethodList(k, &n);
        for (unsigned int i = 0; i < n; i++) {
            NSString *sel = NSStringFromSelector(method_getName(ms[i]));
            NSString *low = sel.lowercaseString;
            for (NSString *key in keys) if ([low containsString:key]) { [out addObject:[NSString stringWithFormat:@"%@%@", meta ? @"+" : @"-", sel]]; break; }
        }
        free(ms);
    }
    unsigned int n = 0;
    Ivar *iv = class_copyIvarList(c, &n);
    NSMutableArray *ivs = [NSMutableArray array];
    for (unsigned int i = 0; i < n; i++) {
        const char *nm = ivar_getName(iv[i]); const char *t = ivar_getTypeEncoding(iv[i]);
        [ivs addObject:[NSString stringWithFormat:@"%s(%s)", nm ? nm : "?", t ? t : "?"]];
    }
    free(iv);
    CIRLog(@"dump %@ methods: %@", name, [out componentsJoinedByString:@" "]);
    CIRLog(@"dump %@ ivars: %@", name, [ivs componentsJoinedByString:@" "]);
}

// raise every integer ivar named *max* on a list model (page capacity)
static void raiseMaxIvars(id obj) {
    if (!obj) return;
    for (Class c = [obj class]; c && c != [NSObject class]; c = class_getSuperclass(c)) {
        unsigned int n = 0;
        Ivar *iv = class_copyIvarList(c, &n);
        for (unsigned int i = 0; i < n; i++) {
            const char *nm = ivar_getName(iv[i]); const char *t = ivar_getTypeEncoding(iv[i]);
            if (!nm || !t) continue;
            NSString *name = [[NSString stringWithUTF8String:nm] lowercaseString];
            if (![name containsString:@"max"]) continue;
            char *base = (char *)(__bridge void *)obj + ivar_getOffset(iv[i]);
            if (t[0] == 'Q' || t[0] == 'q') {
                CIRLog(@"raise %s: %llu -> 1000", nm, *(unsigned long long *)base);
                *(unsigned long long *)base = 1000;
            } else if (t[0] == 'I' || t[0] == 'i') {
                CIRLog(@"raise %s: %u -> 1000", nm, *(unsigned int *)base);
                *(unsigned int *)base = 1000;
            }
        }
        free(iv);
    }
}

#pragma mark - vertical scroll

@interface CIRPan : UIPanGestureRecognizer
@end

@implementation CIRPan {
    BOOL _decided;
    CGPoint _start;
}
- (void)reset { [super reset]; _decided = NO; }
- (void)touchesBegan:(NSSet *)t withEvent:(UIEvent *)e {
    _decided = NO;
    _start = [[t anyObject] locationInView:nil];
    id d = self.delegate;
    if ([d respondsToSelector:@selector(cirTouchBegan)]) [(id<CIRTouchDelegate>)d cirTouchBegan];
    [super touchesBegan:t withEvent:e];
}
- (void)touchesMoved:(NSSet *)t withEvent:(UIEvent *)e {
    if (!_decided) {
        CGPoint p = [[t anyObject] locationInView:nil];
        CGFloat dx = fabs(p.x - _start.x), dy = fabs(p.y - _start.y);
        if (dx + dy < 8) return;
        _decided = YES;
        if (dx > dy) { self.state = UIGestureRecognizerStateFailed; return; } // horizontal -> let pages/Today work
    }
    [super touchesMoved:t withEvent:e];
}
@end

static char kScrollerKey;

@interface CIRScroller : NSObject <UIGestureRecognizerDelegate, CIRTouchDelegate>
- (instancetype)initWithList:(UIView *)list;
@end

@implementation CIRScroller {
    __weak UIView *_list;
    CADisplayLink *_link;
    CGFloat _vel, _startY;
    CFTimeInterval _last;
}

- (instancetype)initWithList:(UIView *)list {
    if ((self = [super init])) {
        _list = list;
        CIRPan *p = [[CIRPan alloc] initWithTarget:self action:@selector(pan:)];
        p.delegate = self;
        p.cancelsTouchesInView = NO;
        [list addGestureRecognizer:p];
    }
    return self;
}

- (CGFloat)maxY {
    UIView *l = _list;
    if (!l) return 0;
    return MAX(0, contentHeightFor((SBIconListView *)l) - l.bounds.size.height);
}

- (void)setY:(CGFloat)y {
    UIView *l = _list;
    if (!l) return;
    CGRect b = l.bounds;
    b.origin.y = y;
    l.bounds = b;
}

- (void)stop {
    [_link invalidate];
    _link = nil;
    _last = 0;
}

- (BOOL)atTop {
    UIView *l = _list;
    return !l || l.bounds.origin.y <= 0.5;
}

// finger down: stop inertia; Spotlight pull-down only allowed when already at the top
- (void)cirTouchBegan {
    [self stop];
    setSearchEnabled([self atTop]);
}

- (void)finished {
    setSearchEnabled([self atTop]);
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)g {
    if (!gEnabled) return NO;
    SBIconController *c = [%c(SBIconController) sharedInstance];
    if ([c respondsToSelector:@selector(grabbedIcon)] && [c grabbedIcon]) return NO; // dragging an icon
    UIView *l = _list;
    if (!l) return NO;
    CGFloat ty = [(UIPanGestureRecognizer *)g translationInView:(l.superview ?: l)].y;
    if ([self atTop] && ty > 0) return NO; // already at the top and pulling down -> that is Spotlight
    return YES;
}

- (void)pan:(UIPanGestureRecognizer *)g {
    UIView *list = _list;
    if (!list || !gEnabled) return;
    UIView *sup = list.superview ?: list;
    switch (g.state) {
        case UIGestureRecognizerStateBegan:
            [self stop];
            _startY = list.bounds.origin.y;
            break;
        case UIGestureRecognizerStateChanged: {
            CGFloat y = _startY - [g translationInView:sup].y;
            [self setY:MAX(0, MIN([self maxY], y))];
            break;
        }
        case UIGestureRecognizerStateEnded:
            _vel = -[g velocityInView:sup].y;
            if (fabs(_vel) < 15) { [self finished]; break; }
            _link = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick:)];
            [_link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
            break;
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed:
            [self finished];
            break;
        default: break;
    }
}

- (void)tick:(CADisplayLink *)l {
    UIView *list = _list;
    if (!list) { [self stop]; return; }
    CFTimeInterval now = l.timestamp;
    CGFloat dt = _last ? (CGFloat)(now - _last) : (CGFloat)l.duration;
    _last = now;
    CGFloat y = list.bounds.origin.y + _vel * dt;
    CGFloat mx = [self maxY];
    BOOL hit = NO;
    if (y < 0)  { y = 0;  hit = YES; }
    if (y > mx) { y = mx; hit = YES; }
    [self setY:y];
    _vel *= expf(-3.2f * (float)dt);
    if (hit || fabs(_vel) < 15) { [self stop]; [self finished]; }
}
@end

#pragma mark - merge all pages into one

static void circularMerge(void) {
    SBIconController *ctrl = [%c(SBIconController) sharedInstance];
    SBFolder *folder = [ctrl respondsToSelector:@selector(rootFolder)] ? [ctrl rootFolder] : nil;
    NSArray *lists = [folder respondsToSelector:@selector(lists)] ? [folder lists] : nil;
    CIRLog(@"merge: folder=%@ lists=%lu", folder, (unsigned long)lists.count);
    dumpClass(@"SBIconListModel");
    dumpClass(@"SBFolder");
    dumpClass(@"SBRootFolder");
    dumpClass(@"SBIconController");
    dumpClass(@"SBSearchGesture");
    for (id m in lists) raiseMaxIvars(m);
    CIRLog(@"search gesture api=%d", gSearchApi);
    if (lists.count < 2) return;

    SBIconListModel *first = lists[0];
    for (NSUInteger i = 1; i < lists.count; i++) {
        SBIconListModel *m = lists[i];
        for (id icon in [[m icons] copy]) {
            [m removeIcon:icon];
            [first addIcon:icon];
        }
    }
    if ([folder respondsToSelector:@selector(removeEmptyLists)]) [folder removeEmptyLists];
    CIRLog(@"merge done: first list now has %lu icons", (unsigned long)[[first icons] count]);
}

#pragma mark - hooks

%hook SBIconListView

- (CGPoint)originForIconAtCoordinate:(struct SBIconCoordinate)c {
    if (!gEnabled || !isRootList(self)) return %orig;
    unsigned long long cols = [self iconColumnsForCurrentOrientation];
    if (cols == 0) cols = 4;
    long long r = c.row - 1, k = c.col - 1;   // coordinates are 1-based
    if (r < 0) r = 0;
    if (k < 0) k = 0;
    return circularOrigin(self, (unsigned long long)(r * cols + k));
}

- (CGPoint)originForIconAtIndex:(unsigned long long)idx {
    if (!gEnabled || !isRootList(self)) return %orig;
    return circularOrigin(self, idx);
}

- (void)didMoveToWindow {
    %orig;
    if (gEnabled && self.window && isRootList(self) && !objc_getAssociatedObject(self, &kScrollerKey)) {
        CIRScroller *s = [[CIRScroller alloc] initWithList:self];
        objc_setAssociatedObject(self, &kScrollerKey, s, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

%end

%hook SBIconImageView

- (void)layoutSubviews {
    %orig;
    if (!gEnabled) return;
    CGFloat d = MIN(self.bounds.size.width, self.bounds.size.height);
    self.layer.cornerRadius = d / 2.0;
    self.layer.masksToBounds = YES;
}

%end

// hide dock + page dots
%hook SBRootFolderView

- (void)layoutSubviews {
    %orig;
    if (!gEnabled) return;
    for (NSString *k in @[@"dockView", @"pageControl"]) {
        @try {
            id v = [self valueForKey:k];
            if ([v isKindOfClass:[UIView class]]) {
                [(UIView *)v setHidden:YES];
                [(UIView *)v setAlpha:0];
            }
        } @catch (NSException *e) {}
    }
    @try {
        id sv = [self valueForKey:@"scrollView"];
        if ([sv isKindOfClass:[UIScrollView class]]) ((UIScrollView *)sv).directionalLockEnabled = YES;
    } @catch (NSException *e) {}
}

%end

%hook SpringBoard

- (void)applicationDidFinishLaunching:(id)app {
    %orig;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (gEnabled) circularMerge();
    });
}

%end

// no page limit (hooked only if the selector exists on this iOS)
%group ModelMaxInst
%hook SBIconListModel
- (unsigned long long)maxNumberOfIcons { return gEnabled ? 1000 : %orig; }
%end
%end

%group ModelMaxClass
%hook SBIconListModel
+ (unsigned long long)maxIcons { return gEnabled ? 1000 : %orig; }
%end
%end

%ctor {
    loadPrefs();
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, prefsChanged,
        CFSTR("com.cursorus.circular/prefschanged"), NULL, CFNotificationSuspensionBehaviorCoalesce);

    %init;

    Class lm = NSClassFromString(@"SBIconListModel");
    Class lv = NSClassFromString(@"SBIconListView");
    BOOL inst = lm && class_getInstanceMethod(lm, @selector(maxNumberOfIcons));
    BOOL cls  = lm && class_getClassMethod(lm, @selector(maxIcons));
    CIRLog(@"--- circular loaded --- maxNumberOfIcons=%d +maxIcons=%d rootIconListView=%d rootFolderView=%d "
           @"originAtCoordinate=%d originAtIndex=%d icons=%d removeEmptyLists=%d",
           inst, cls,
           NSClassFromString(@"SBRootIconListView") != nil,
           NSClassFromString(@"SBRootFolderView") != nil,
           lv && class_getInstanceMethod(lv, @selector(originForIconAtCoordinate:)) != NULL,
           lv && class_getInstanceMethod(lv, @selector(originForIconAtIndex:)) != NULL,
           lv && class_getInstanceMethod(lv, @selector(icons)) != NULL,
           NSClassFromString(@"SBFolder") && class_getInstanceMethod(NSClassFromString(@"SBFolder"), @selector(removeEmptyLists)) != NULL);
    if (inst) { %init(ModelMaxInst); }
    if (cls)  { %init(ModelMaxClass); }
}
