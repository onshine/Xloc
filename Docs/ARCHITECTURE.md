# 架构设计

## 分层

```
┌─ UI ────────────────────────────────────────────────────────┐
│ MapScreen  RouteScreen  WiFiScreen  SettingsScreen           │
│ 只做展示与输入，不碰 CoreLocation / 私有 API                  │
└───────────────────────┬─────────────────────────────────────┘
                        │ @Published / 方法调用
┌─ Core ────────────────▼─────────────────────────────────────┐
│ SimulationEngine   状态机、定时器、模式调度                    │
│ RealismEngine      噪声模型（OU）、精度、海拔、速度            │
│ RouteEngine        折线参数化、速度剖面、GPX                  │
│ Geo                距离/方位/坐标系                            │
└───────────────────────┬─────────────────────────────────────┘
                        │ SimulatedFix
┌─ Bridge ──────────────▼─────────────────────────────────────┐
│ LocSimBridge  → CLSimulationManager（唯一私有定位入口）        │
│ WiFiBridge    → SCDynamicStore / plist（唯一系统写入入口）     │
│ Diagnostics   → 只读检查                                       │
└─────────────────────────────────────────────────────────────┘
```

**约束**：UI 层不允许 `import CoreLocation` 之外的东西；所有私有 API 只在 Bridge 层出现，方便审计（`grep -r CLSimulationManager Xloc/` 只有两个文件）。

---

## 数据流

一次 tick（默认 1 s）：

```
SimulationEngine.tick()
   │
   ├─ 模式 == .route ? RouteSimulator.advance(dt:) → 基准坐标
   │                    更新 progress / 判断结束
   │
   ├─ RealismEngine.step(base:dt:)
   │     ├─ OU 漂移 → 米级偏移（东/北）
   │     ├─ 精度慢变 → horizontalAccuracy
   │     ├─ 海拔漂移 → altitude
   │     └─ 与上一帧比较 → speed / course
   │
   └─ LocSimBridge.update(with: fix)
         ├─ 节流（≥0.45 s）
         ├─ appendSimulatedLocation + flush
         └─ （可选）restart 策略
```

`SimulatedFix` 是 Core 与 Bridge 之间唯一的数据契约，包含：

| 字段 | 说明 |
|---|---|
| coordinate | WGS-84 |
| altitude / verticalAccuracy | 海拔与垂直精度 |
| horizontalAccuracy | 水平精度 |
| speed / course | m/s、度（-1 表示无效） |
| timestamp | 必须是真实时间 |

---

## 状态机

```
        start()                pause()
 idle ─────────► running ◄────────────► paused
   ▲                │  resume()
   │                │ 路线走完
   │   stop()       ▼
   └──────────── finished
```

- `stop()` 会调用 `bridge.stop()` 并**还原 Wi-Fi**
- `pause()` 只停推送，不清 locationd 状态（恢复更快）
- `finished` 保留最后一个点，不清除（用户往往希望"停在那里"）

---

## 关键决策

### 1. 为什么不做注入？

注入（把 dylib 塞进目标 App）能解决两件事：per-app 作用域、抹掉 `isSimulatedBySoftware`。
代价是：需要 `task_for_pid-allow` / `AppBundles` / `run-unsigned-code`，并且**必须**有一个不可审计的二进制在别人进程里跑。

Xloc 选择不做。这既是安全考量，也是可维护性考量——注入一旦失败，表现为目标 App 闪退，用户完全无从排查。

> 如果将来要做，会以**独立的可选插件**形式提供（v0.3），主程序保持零注入。

### 2. 为什么默认 append 而不是 restart？

Andromeda 每次更新都 `stop → clear → append → flush → start`。在 1 Hz 下，这意味着 locationd 每秒重建一次模拟状态：
- 目标 App 可能看到定位"跳一下再回来"
- 系统日志里会留下高频的模拟会话建立记录

`append + flush` 是原地更新。如果某些系统版本上不生效，`LocSimUpdateStrategy.restart` 可以回退（设置项里可切换）。

### 3. 为什么用 OU 而不是"随机 + 低通"？

低通滤波（`x = x*0.9 + rand*0.1`）也能得到相关噪声，但它的**方差随采样率变化**：更新频率从 1 Hz 变成 2 Hz，抖动幅度会变。OU 过程有解析解，参数（τ、σ）与采样率无关，行为可预测、可测试。

### 4. 坐标系放在哪一层？

放在 Core（`Geo.swift`），**在进入 Bridge 之前**统一转成 WGS-84。
原因：MapKit 在国内返回 GCJ-02，GPX 通常是 WGS-84，用户手输可能是任意一种。如果转换散落在各处，一定会出现"某个入口忘了转"的 bug。

---

## 线程模型

- `SimulationEngine` 标了 `@MainActor`，所有 `@Published` 更新都在主线程
- `Timer` 挂在 `RunLoop.main`，`.common` 模式（滚动列表时也触发）
- 没有后台队列：1 Hz 的计算量微不足道，避免并发复杂度

## 错误处理

- `LocSimError.unavailable`：设备没有 `CLSimulationManager`（非 iOS 或非 TrollStore）
- `LocSimError.notPermitted`：entitlement 没签进去 → 自检面板会直接指出
- Wi-Fi 写入失败不会抛异常，而是返回 `ApplyResult(success: false, messages:)`，UI 原样展示

原则：**不静默失败**。用户必须知道"这次模拟到底生效了没有"。
