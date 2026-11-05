//
//  XlocPlugin.m
//  Xloc
//
//  注入到目标 App 内的钩子。
//
//  原理：
//    系统模拟通道下发的定位，locationd 会打上 isSimulatedBySoftware = true。
//    而在目标进程内**自己构造**的 CLLocation，压根没有 sourceInformation，
//    App 读到的就是 nil —— 和真实定位无法区分。
//
//  做法：
//    1. 把 -[CLLocationManager startUpdatingLocation] 换成自己的实现，不真的开定位
//    2. 用定时器按配置的坐标回调 delegate 的 locationManager:didUpdateLocations:
//    3. 伪造授权状态，避免 App 卡在"未授权"
//
//  配置从主 App 的 bundle 里读（XlocConfig.plist），随注入一起带过去。
//

#import <Foundation/Foundation.h>
#import <CoreLocation/CoreLocation.h>
#import <objc/runtime.h>
#import <UIKit/UIKit.h>
#import <stdlib.h>

static NSDictionary *gConfig = nil;
static NSTimer *gTimer = nil;
static __weak id gDelegate = nil;
static __weak CLLocationManager *gManager = nil;
static double gDriftLat = 0, gDriftLon = 0;

#pragma mark - 配置

static NSDictionary *XLConfig(void) {
    if (gConfig) return gConfig;
    NSString *path = [[NSBundle mainBundle] pathForResource:@"XlocConfig" ofType:@"plist"];
    if (path) gConfig = [NSDictionary dictionaryWithContentsOfFile:path];
    if (!gConfig) gConfig = @{};
    return gConfig;
}

static BOOL XLEnabled(void) {
    return [XLConfig()[@"enabled"] boolValue];
}

#pragma mark - 构造定位

static CLLocation *XLMakeLocation(void) {
    NSDictionary *c = XLConfig();
    double lat = [c[@"latitude"] doubleValue] + gDriftLat;
    double lon = [c[@"longitude"] doubleValue] + gDriftLon;
    double alt = [c[@"altitude"] doubleValue];
    double acc = [c[@"accuracy"] doubleValue];
    if (acc <= 0) acc = 5.0;

    // 轻微漂移，避免"绝对静止"
    gDriftLat += ((double)arc4random_uniform(2000) / 1000000.0 - 0.001) * 0.00001;
    gDriftLon += ((double)arc4random_uniform(2000) / 1000000.0 - 0.001) * 0.00001;
    gDriftLat *= 0.92;
    gDriftLon *= 0.92;

    CLLocationCoordinate2D coord = CLLocationCoordinate2DMake(lat, lon);
    return [[CLLocation alloc] initWithCoordinate:coord
                                         altitude:alt
                               horizontalAccuracy:acc
                                 verticalAccuracy:MAX(3.0, acc * 0.6)
                                        timestamp:[NSDate date]];
}

#pragma mark - 定时投递

static void XLTick(void) {
    if (!XLEnabled()) return;
    id delegate = gDelegate ?: gManager.delegate;
    if (!delegate) return;

    CLLocation *loc = XLMakeLocation();
    SEL sel = @selector(locationManager:didUpdateLocations:);
    if ([delegate respondsToSelector:sel]) {
        NSMethodSignature *sig = [(NSObject *)delegate methodSignatureForSelector:sel];
        if (sig) {
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            inv.target = delegate;
            inv.selector = sel;
            CLLocationManager *m = gManager;
            NSArray *arr = @[loc];
            [inv setArgument:&m atIndex:2];
            [inv setArgument:&arr atIndex:3];
            [inv invoke];
        }
    }
}

static void XLStartTimer(void) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ XLStartTimer(); });
        return;
    }
    if (gTimer) return;
    gTimer = [NSTimer timerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) {
        XLTick();
    }];
    [[NSRunLoop mainRunLoop] addTimer:gTimer forMode:NSRunLoopCommonModes];
}

static void XLStopTimer(void) {
    [gTimer invalidate];
    gTimer = nil;
}

#pragma mark - 替换实现

static void (*orig_startUpdating)(id, SEL);
static void (*orig_stopUpdating)(id, SEL);
static void (*orig_requestWhenInUse)(id, SEL);
static void (*orig_requestAlways)(id, SEL);
static void (*orig_requestLocation)(id, SEL);

static void xl_startUpdating(id self, SEL _cmd) {
    if (!XLEnabled()) {
        if (orig_startUpdating) orig_startUpdating(self, _cmd);
        return;
    }
    gManager = (CLLocationManager *)self;
    gDelegate = [(CLLocationManager *)self delegate];
    XLStartTimer();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ XLTick(); });
}

static void xl_stopUpdating(id self, SEL _cmd) {
    XLStopTimer();
    if (orig_stopUpdating) orig_stopUpdating(self, _cmd);
}

static void xl_requestWhenInUse(id self, SEL _cmd) {
    if (orig_requestWhenInUse) orig_requestWhenInUse(self, _cmd);
    id d = [(CLLocationManager *)self delegate];
    if ([d respondsToSelector:@selector(locationManagerDidChangeAuthorization:)]) {
        [(id<CLLocationManagerDelegate>)d locationManagerDidChangeAuthorization:(CLLocationManager *)self];
    }
}

static void xl_requestLocation(id self, SEL _cmd) {
    gManager = (CLLocationManager *)self;
    gDelegate = [(CLLocationManager *)self delegate];
    XLStartTimer();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ XLTick(); });
}

static void xl_requestAlways(id self, SEL _cmd) {
    if (orig_requestAlways) orig_requestAlways(self, _cmd);
    id d = [(CLLocationManager *)self delegate];
    if ([d respondsToSelector:@selector(locationManagerDidChangeAuthorization:)]) {
        [(id<CLLocationManagerDelegate>)d locationManagerDidChangeAuthorization:(CLLocationManager *)self];
    }
}

static CLAuthorizationStatus (*orig_classAuthStatus)(id, SEL);
static CLAuthorizationStatus (*orig_instAuthStatus)(id, SEL);

static CLAuthorizationStatus xl_classAuthStatus(id self, SEL _cmd) {
    return XLEnabled() ? kCLAuthorizationStatusAuthorizedAlways
                       : (orig_classAuthStatus ? orig_classAuthStatus(self, _cmd) : kCLAuthorizationStatusNotDetermined);
}

static CLAuthorizationStatus xl_instAuthStatus(id self, SEL _cmd) {
    return XLEnabled() ? kCLAuthorizationStatusAuthorizedAlways
                       : (orig_instAuthStatus ? orig_instAuthStatus(self, _cmd) : kCLAuthorizationStatusNotDetermined);
}

static void XLSwizzleClass(Class cls, SEL sel, void *replacement, void **original) {
    Method m = class_getClassMethod(cls, sel);
    if (!m) return;
    if (original) *original = (void *)method_getImplementation(m);
    method_setImplementation(m, (IMP)replacement);
}

static void XLSwizzle(Class cls, SEL sel, void *replacement, void **original) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    if (original) *original = (void *)method_getImplementation(m);
    method_setImplementation(m, (IMP)replacement);
}

#pragma mark - 入口

__attribute__((constructor))
static void XlocPluginInit(void) {
    if (!XLEnabled()) return;

    Class mgr = [CLLocationManager class];
    XLSwizzle(mgr, @selector(startUpdatingLocation), (void *)xl_startUpdating, (void **)&orig_startUpdating);
    XLSwizzle(mgr, @selector(stopUpdatingLocation), (void *)xl_stopUpdating, (void **)&orig_stopUpdating);
    XLSwizzle(mgr, @selector(requestWhenInUseAuthorization), (void *)xl_requestWhenInUse, (void **)&orig_requestWhenInUse);
    XLSwizzle(mgr, @selector(requestAlwaysAuthorization), (void *)xl_requestAlways, (void **)&orig_requestAlways);
    XLSwizzle(mgr, @selector(requestLocation), (void *)xl_requestLocation, (void **)&orig_requestLocation);
    XLSwizzle(mgr, @selector(authorizationStatus), (void *)xl_instAuthStatus, (void **)&orig_instAuthStatus);
    XLSwizzleClass(mgr, @selector(authorizationStatus), (void *)xl_classAuthStatus, (void **)&orig_classAuthStatus);

    NSLog(@"[Xloc] plugin loaded, lat=%@ lon=%@",
          XLConfig()[@"latitude"], XLConfig()[@"longitude"]);
}
