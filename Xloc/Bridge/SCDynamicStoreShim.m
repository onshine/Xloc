//
//  SCDynamicStoreShim.m
//  Xloc
//
//  SCDynamicStore* 在 iOS SDK 里被标记为 API_UNAVAILABLE(ios)，
//  但符号实际存在于 SystemConfiguration.framework 中（系统内部在用）。
//
//  这里用 dlsym 取符号，既避免和 SDK 头文件的可用性标注冲突，
//  也不会在符号缺失时链接失败（返回 false，上层如实报错）。
//

#import <Foundation/Foundation.h>
#import <dlfcn.h>

typedef void *(*XLSCreateFn)(CFAllocatorRef, CFStringRef, void *, void *);
typedef Boolean (*XLSetFn)(void *, CFStringRef, CFPropertyListRef);
typedef Boolean (*XLRemoveFn)(void *, CFStringRef);
typedef Boolean (*XLNotifyFn)(void *, CFStringRef);

static void *gStore = NULL;
static XLSetFn gSet = NULL;
static XLRemoveFn gRemove = NULL;
static XLNotifyFn gNotify = NULL;

static BOOL XLLoadSC(void) {
    static dispatch_once_t once;
    static BOOL ok = NO;
    dispatch_once(&once, ^{
        void *h = dlopen("/System/Library/Frameworks/SystemConfiguration.framework/SystemConfiguration",
                         RTLD_LAZY | RTLD_LOCAL);
        if (!h) {
            h = dlopen("/usr/lib/libSystemConfiguration.dylib", RTLD_LAZY | RTLD_LOCAL);
        }
        if (!h) return;

        XLSCreateFn create = (XLSCreateFn)dlsym(h, "SCDynamicStoreCreate");
        gSet    = (XLSetFn)dlsym(h, "SCDynamicStoreSetValue");
        gRemove = (XLRemoveFn)dlsym(h, "SCDynamicStoreRemoveValue");
        gNotify = (XLNotifyFn)dlsym(h, "SCDynamicStoreNotifyValue");

        if (create) {
            gStore = create(kCFAllocatorDefault, CFSTR("Xloc"), NULL, NULL);
        }
        ok = (gStore != NULL && gSet != NULL);
    });
    return ok;
}

BOOL XLSCSetValue(CFStringRef key, CFPropertyListRef value) {
    if (!XLLoadSC()) return false;
    Boolean ok = gSet(gStore, key, value);
    if (ok && gNotify) gNotify(gStore, key);
    return ok;
}

BOOL XLSCRemoveValue(CFStringRef key) {
    if (!XLLoadSC() || !gRemove) return false;
    Boolean ok = gRemove(gStore, key);
    if (ok && gNotify) gNotify(gStore, key);
    return ok;
}

BOOL XLSCAvailable(void) {
    return XLLoadSC();
}
