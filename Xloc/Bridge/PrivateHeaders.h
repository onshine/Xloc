//
//  PrivateHeaders.h
//  Xloc
//
//  私有 API 声明。仅在 TrollStore（带 com.apple.locationd.simulation 权限）下有效。
//  这里只声明"我们需要用到"的最小集合，不做任何运行时替换（swizzling）。
//
//  CLSimulationManager 位于 CoreLocation.framework 内部，是 Xcode「Simulate Location」
//  背后的同一套实现。它把模拟位置交给 locationd，因此其他 App 看到的是系统级定位，
//  而不是本进程伪造的对象。
//

#import <Foundation/Foundation.h>
#import <CoreLocation/CoreLocation.h>

NS_ASSUME_NONNULL_BEGIN

/// 位置交付行为
typedef NS_ENUM(uint8_t, CLSimulationLocationDeliveryBehavior) {
    CLSimulationDeliveryFixed = 0,   // 固定点（默认）
    CLSimulationDeliveryRoute = 1,   // 沿追加的点顺序播放
};

/// 私有 Security 接口（SecTask.h 不公开，手动声明）
CFTypeRef SecTaskCreateFromSelf(CFAllocatorRef allocator);
CFTypeRef SecTaskCopyValueForEntitlement(CFTypeRef task, CFStringRef entitlement, CFErrorRef *error);

@interface CLSimulationManager : NSObject

/// 交付行为：Static 只交付最后一个点；Route 按 append 顺序播放
@property (assign, nonatomic) uint8_t locationDeliveryBehavior;
/// Route 模式下相邻两点的距离（米），0 = 自动
@property (assign, nonatomic) double locationDistance;
/// Route 模式下相邻两点的间隔（秒）
@property (assign, nonatomic) double locationInterval;
/// Route 模式下的移动速度（m/s），与 interval 二选一
@property (assign, nonatomic) double locationSpeed;
/// 播放结束后是否循环
@property (assign, nonatomic) uint8_t locationRepeatBehavior;

- (void)clearSimulatedLocations;
- (void)appendSimulatedLocation:(CLLocation *)location;
- (void)flush;

- (void)startLocationSimulation;
- (void)stopLocationSimulation;

/// 从 .scenario 文件加载（Xcode 的 Location Scenario 格式）
- (void)loadScenarioFromURL:(NSURL *)url;

/// Wi-Fi 模拟：只控制"模拟 Wi-Fi 开关"，不负责 SSID/BSSID 内容
- (void)setSimulatedWifiPower:(BOOL)on;
- (void)startWifiSimulation;
- (void)stopWifiSimulation;

/// 蜂窝模拟（需要一个符合 CLSimulatedCell 结构的对象）
- (void)setSimulatedCell:(nullable id)cell;
- (void)startCellSimulation;
- (void)stopCellSimulation;

@end

/// CLLocation 的私有构造器：直接喂一个 CLClientLocation 结构体。
/// 用它可以把所有字段（精度/速度/航向/完整性）一次性填好，
/// 避免公开构造器留下"字段缺失"的特征。
@interface CLLocation (XlocPrivate)
- (instancetype)initWithClientLocation:(void *)clientLocation
                      coarseMetaData:(nullable id)metaData;
@end

NS_ASSUME_NONNULL_END
