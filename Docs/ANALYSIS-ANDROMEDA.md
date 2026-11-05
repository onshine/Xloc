# Andromeda 代码分析

> 对象：`onshine/Andromeda`（上游 `Sonerbt/Andromeda`，源头是 c22dev 的 **Geranium**）
> 结论仅针对 LocSim 部分，不评价它的清理器/守护进程等其他模块。

---

## 1. 它怎么实现定位模拟

核心只有 20 行（`Geranium/LocSim/LocSimManager.swift`）：

```swift
class LocSimManager {
    static let simManager = CLSimulationManager()

    static func startLocSim(location: CLLocation) {
        simManager.stopLocationSimulation()
        simManager.clearSimulatedLocations()
        simManager.appendSimulatedLocation(location)
        simManager.flush()
        simManager.startLocationSimulation()
        CFNotificationCenterPostNotification(..., "AutomaticTimeZoneUpdateNeeded", ...)
    }
}
```

**这是对的**：走 `CLSimulationManager` → locationd，是 TrollStore 环境下最干净的路子。

---

## 2. 问题清单

### 2.1 每秒重建一次模拟（最严重）

`RouteSimulator` 的 tick 是 1 s，每次调用 `updateLocation(at:)` 都会走一遍
`stop → clear → append → flush → start`。

后果：

| 影响 | 说明 |
|---|---|
| 定位跳变 | 目标 App 可能先收到"清除"再收到"新点" |
| 系统日志 | 每秒建立一次模拟会话，特征极其明显 |
| 后台 | 锁屏后 timer 被挂起，恢复时状态可能错乱 |
| 性能 | 每秒一次 XPC + flush，纯浪费 |

**Xloc**：默认 `append + flush` 原地更新，节流 0.45 s；`restart` 作为兼容回退。

### 2.2 抖动是白噪声

```swift
let latJitter = Double.random(in: -0.00001...0.00001)
coord.latitude += latJitter
```

- 幅度固定 ≈ 1.1 m，不随环境变化
- 每帧独立 → 白噪声，自相关为 0
- 叠加在插值点上，导致轨迹呈"锯齿"

真实的 GPS 漂移是**相关**的（这一秒偏东，下一秒还在东边），且幅度随环境变化。

**Xloc**：OU 过程（τ = 18 s，σ 由环境决定），输出在统计上与真实漂移同分布。

### 2.3 精度是固定区间随机

```swift
horizontalAccuracy: Double.random(in: 3.0...6.0)
```

每帧独立均匀分布 → `horizontalAccuracy` 的时序方差远大于真实值（真实是慢变的）。

**Xloc**：一阶慢变 + 环境基准（空旷 4 m / 城市 9 m / 室内 22 m）。

### 2.4 速度是匀速

`interpolateRoute` 用固定 `stepDistance = speed × interval` 生成点，
没有加速度、没有转弯减速、没有起停。

输出的 `speed` 字段实际由 `CLLocation` 构造器决定——它根本没传 speed/course，
所以 `speed` 恒为 -1（无效）。

**Xloc**：加速度受限的速度剖面 + 转弯减速 + 真实 `speed`/`course`。

### 2.5 Wi-Fi 模拟完全没做

`LocSimPrivateHeaders.h` 里明明声明了：

```objc
-(void)setSimulatedWifiPower:(BOOL)arg1;
-(void)startWifiSimulation;
-(void)stopWifiSimulation;
-(void)setSimulatedCell:(id)arg1;
-(void)startCellSimulation;
-(void)stopCellSimulation;
-(void)loadScenarioFromURL:(id)arg1;
```

但没有任何地方调用。而 Wi-Fi 指纹恰恰是风控的第一道交叉校验。

**Xloc**：完整的 Wi-Fi 指纹模块（读取 → 校验 → 伪造 → 还原）。

### 2.6 没有自检

用户不知道模拟到底生效没有、目标 App 会不会一眼看穿。
`isSimulatedBySoftware` 这类信息它完全没有暴露。

**Xloc**：自检面板（权限 / 模拟标记 / Wi-Fi 一致性 / 越狱 / 代理 / VPN）。

### 2.7 权限过宽

```xml
<key>com.apple.security.exception.files.absolute-path.read-write</key>
<array><string>/</string></array>
```

整个根目录可写。对一个定位工具来说没有必要，而且放大了被利用的风险。

**Xloc**：只给 `/private/var/preferences/SystemConfiguration/` 与偏好目录。

---

## 3. 值得保留的设计

- **`CLSimulationManager` 而非注入**：方向正确，Xloc 沿用。
- **`AutomaticTimeZoneUpdateNeeded` 通知**：细节到位，Xloc 沿用并补充了"停止时也发一次"。
- **MapKit 算路 + GCJ-02 转换**：思路正确；Xloc 把转换收敛到 Core 层，并补了 BD-09。
- **GPX 导入**：Xloc 重写了解析器并加了 Douglas–Peucker 抽稀（原实现点数多时渲染卡顿）。

---

## 4. 对比总结

| 维度 | Andromeda | Xloc |
|---|---|---|
| 模拟通道 | `CLSimulationManager` | 同 |
| 更新策略 | 每次重启 | 原地 append（可回退） |
| 噪声模型 | 均匀随机（白噪声） | OU 过程（时间相关） |
| 精度模型 | 固定区间随机 | 环境基准 + 慢变 |
| 速度模型 | 匀速、无 speed 字段 | 加速度受限 + speed/course |
| Wi-Fi | 未实现 | 完整实现 |
| 坐标系 | GCJ-02 | WGS/GCJ/BD-09 |
| 自检 | 无 | 有 |
| 权限 | 含 `/` 全盘写 | 逐项收敛 |
