<div align="center">

# Xloc

**一个开源的 iOS 定位模拟工具 — 追求"真实"，而不只是"能改"**

[![CI](https://github.com/onshine/Xloc/actions/workflows/ci.yml/badge.svg)](https://github.com/onshine/Xloc/actions/workflows/ci.yml)
[![Platform](https://img.shields.io/badge/iOS-15.0%2B-black?style=flat-square&logo=apple)](https://github.com/onshine/Xloc)
[![TrollStore](https://img.shields.io/badge/Requires-TrollStore-purple?style=flat-square)](https://github.com/opa334/TrollStore)
[![License](https://img.shields.io/badge/License-GPL--3.0-blue?style=flat-square)](LICENSE)
[![Version](https://img.shields.io/badge/Version-0.1.0--alpha-orange?style=flat-square)](#路线图)

</div>

---

## 这是什么

Xloc 是一个**完全开源、可审计**的 iOS 定位模拟工具，跑在 TrollStore 上，不需要越狱。

它和市面上已有的工具最大的区别不是"能改定位"——那是 `CLSimulationManager` 给的，谁都能做到。
区别在于**改完之后像不像真的**：

| 能力 | Andromeda / Geranium | **Xloc** |
|---|:---:|:---:|
| locationd 模拟通道 | ✅ | ✅ |
| 单点 / 摇杆 / 路线 | ✅ | ✅ |
| GPX 导入 | ✅ | ✅ |
| GCJ-02 / BD-09 转换 | ⚠️ 仅 GCJ | ✅ 三套坐标系 |
| **Wi-Fi SSID/BSSID 伪造** | ❌ | ✅ |
| **BSSID 合理性校验 / OUI 匹配** | ❌ | ✅ |
| **相关噪声漂移（OU 过程）** | ⚠️ 均匀随机 | ✅ 时间相关 |
| **精度随环境变化** | ⚠️ 固定区间随机 | ✅ 环境模型 |
| **速度/加速度连续剖面** | ❌ 匀速 | ✅ 加速度受限 |
| **交付节奏抖动** | ❌ | ✅ |
| **自检面板（会不会被识破）** | ❌ | ✅ |
| 更新时重建模拟 | ⚠️ 每秒重建一次 | ❌ 原地 append |
| 开源可审计 | ✅ | ✅ |
| 权限最小化 | ⚠️ 含 `/` 全盘写 | ✅ 逐项收敛 |

> Andromeda 的分析见 [Docs/ANALYSIS-ANDROMEDA.md](Docs/ANALYSIS-ANDROMEDA.md)。

---

## 它怎么工作

```
┌──────────────────────────────────────────────────────────────┐
│                        Xloc.app (SwiftUI)                    │
│                                                              │
│   MapScreen      RouteScreen     WiFiScreen     Settings     │
│       │              │               │              │        │
│       └──────────────┴───────┬───────┴──────────────┘        │
│                              ▼                               │
│                    SimulationEngine (状态机)                  │
│                     │            │            │              │
│            ┌────────▼──┐  ┌──────▼─────┐  ┌───▼────────┐     │
│            │ Realism   │  │ Route      │  │ WiFi       │     │
│            │ Engine    │  │ Engine     │  │ Bridge     │     │
│            │ (OU 噪声) │  │ (加速度)   │  │ (指纹)     │     │
│            └────────┬──┘  └──────┬─────┘  └───┬────────┘     │
│                     └────────────┼────────────┘              │
│                                  ▼                           │
│                          LocSimBridge                        │
│                     (CLSimulationManager)                    │
└──────────────────────────────────┬───────────────────────────┘
                                   │ 私有 XPC（需 entitlement）
                                   ▼
                            locationd  ──►  所有 App 的 CoreLocation
```

关键点：**模拟发生在 locationd 里，不在 Xloc 进程里**。所以目标 App 拿到的是"系统给的定位"，而不是"某个 App 塞给它的对象"——这也是它比"越狱 tweak 在自己进程里 hook"更干净的原因。

---

## 快速开始

### 环境

- macOS + Xcode 15+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) `brew install xcodegen`
- [ldid](https://github.com/ProcursusTeam/ldid) `brew install ldid-procursus`
- 一台装了 [TrollStore](https://github.com/opa334/TrollStore) 的 iPhone（iOS 15.0–17.0）

### 构建

```bash
git clone https://github.com/onshine/Xloc.git
cd Xloc

make tipa        # 生成 Xloc.tipa
```

`make tipa` 会依次：生成 Xcode 工程 → `xcodebuild` → 用 `ldid` 把 [Xloc.entitlements](Xloc/Xloc.entitlements) 签进主程序 → 打包成 `Payload/Xloc.app`。

然后 AirDrop / 文件 App 把 `Xloc.tipa` 丢给 TrollStore 安装即可。

### 自动发布

```bash
git tag v0.1.0 && git push origin v0.1.0
```

GitHub Actions 会自动构建、写入 entitlements、**校验 `locationd.simulation` 确实签进去了**、
生成 changelog 并把 `.tipa` + `.sha256` 挂到 Release。
细节见 [Docs/RELEASING.md](Docs/RELEASING.md)。

### 直接改工程

```bash
make project     # 只生成 Xloc.xcodeproj
open Xloc.xcodeproj
```

---

## 权限（这是这个项目最较真的地方）

`Xloc.entitlements` 只申请"改自己的定位"真正需要的东西：

```xml
platform-application                                   ← TrollStore 必需
com.apple.locationd.simulation                         ← 定位模拟核心
com.apple.private.security.no-sandbox                  ← 访问 SystemConfiguration
com.apple.SystemConfiguration.SCDynamicStore-write-access
com.apple.developer.networking.wifi-info               ← 读当前 SSID/BSSID
com.apple.security.exception.files.absolute-path.read-write
    /private/var/preferences/SystemConfiguration/      ← 只给这一个目录
```

**刻意没有申请**：

```
task_for_pid-allow / run-unsigned-code / get-task-allow   ← 能读写任意进程内存
com.apple.private.security.storage.AppBundles             ← 能改别的 App 的包（注入）
com.apple.developer.driverkit / AGXDeviceUserClient       ← 驱动 / GPU
networkextension / vpn.api / HotspotHelper                ← 网络扩展
```

原因很简单：**一个定位工具不需要这些**。权限越多，一旦被投毒，损失越大。

---

## 真实感引擎

这是 Xloc 的核心，也是它和"定时器 + 随机数"式实现的本质差别。

### 1. 漂移不是白噪声

真实的 GPS 静止漂移是**相关的**：这一秒偏东，下一秒大概率还在东边。用独立随机数（Andromeda 的做法）会得到一条"锯齿"轨迹，一阶自相关检验就能识破。

Xloc 用 Ornstein–Uhlenbeck 过程：

```
dx = -θ·x·dt + σ·√(2θ)·dW
```

- `θ = 1/τ`，τ 默认 18 s（真实漂移的相关时间）
- `σ` 由环境决定：空旷 0.8 m，郊区 1.2 m，城市 2.0 m，室内 4.5 m
- 结果：偏移量有回归力、有相关时间，和真实 GPS 同分布

### 2. 精度随环境变化

```
空旷户外  4 m ± 2
郊区      6 m ± 3
城市      9 m ± 5
室内     22 m ± 12
```

并且是**慢变**的（30 s 时间常数），不是每帧乱跳——真实的 `horizontalAccuracy` 就是这样。

### 3. 速度与加速度

路线模式不是"每 tick 移动固定距离"，而是：

- 目标速度由出行方式决定（步行 1.1–1.6 m/s，驾车 8–22 m/s）
- 受最大加速度约束（步行 1.0，驾车 2.2 m/s²）
- 起步有 2 s 加速段，到终点前 30 m 减速
- 前方 25 m 内有转弯时按角度减速

这样输出的 `speed` 曲线是连续的，不是阶跃的。

### 4. 交付节奏

真实 iOS 的定位交付不是严格 1 Hz。Xloc 以 4% 的概率跳过一拍，并对速度做一阶低通。

---

## Wi-Fi 指纹

风控的第一道防线往往不是 GPS，而是**交叉校验**：GPS 说在纽约，Wi-Fi BSSID 却注册在北京 → 判定伪造。

Xloc 提供：

1. **读取真实网络**作为模板（SSID/BSSID/RSSI/信道）
2. **手动或随机生成**伪造值
3. **BSSID 合理性校验**：
   - 格式、组播位、本地管理位（LAA）
   - 全 0 / 广播地址
   - OUI 厂商识别（Apple / TP-Link / 小米 / 华为 / H3C / Cisco…）
4. **写入系统**：优先 `SCDynamicStore`，失败回退 plist 补丁
5. **自动备份 + 停止时还原**

> ⚠️ 默认 **dry-run**，不会改系统。必须在设置里显式打开「真正写入系统」才会生效。
> 这是系统级操作，改坏了可能影响网络，请务必用「还原」按钮或重装网络配置恢复。

---

## 自检面板

大多数用户不知道自己的模拟为什么被发现。Xloc 把可观测的检测向量摊开：

| 检查项 | 说明 |
|---|---|
| 权限 | `locationd.simulation` 等是否真的签进去了 |
| **模拟标记** | `CLLocation.sourceInformation.isSimulatedBySoftware` 是否为 true |
| Wi-Fi 一致性 | 是否设置了伪造 Wi-Fi、BSSID 是否合法、OUI 是否合理 |
| 越狱痕迹 | `/var/lib/cydia`、`systemhook.dylib`、`MobileSubstrate`… |
| 系统代理 | `HTTPEnable` / `HTTPSEnable` |
| VPN 接口 | `utun` / `ppp` |

这一项项都是目标 App 会做的检查，先自己查一遍，比事后猜有用。

---

## 已知限制

- **`isSimulatedBySoftware` 仍然为 true**。只要走 locationd 的模拟通道，系统就会打这个标记，Xloc 无法消除它（这需要目标进程内的 hook，属于插件模式，见路线图）。自检面板会如实告诉你。
- **不做注入、不做 hook**。这是设计选择：注入需要 `task_for_pid` / `AppBundles` 权限，风险和审计成本都不划算。
- **按 App 生效**目前只能靠"用完即停"，真正的 per-app 作用域需要插件（v0.3 规划）。
- **Wi-Fi 写入**在不同 iOS 版本上结构不同，`applyViaPlist` 是保守实现，可能无效——失败会如实返回，不会静默破坏。
- 没有在 iOS 17 以上完整验证（TrollStore 支持范围本身有限）。

---

## 路线图

- [x] v0.1 — 单点 / 摇杆 / 路线 / GPX / 真实感引擎 / Wi-Fi 指纹 / 自检
- [ ] v0.2 — 收藏与导入导出、App 预设、路线录制、后台保活优化
- [ ] v0.3 — 可选插件（越狱）：per-app 作用域 + 抹掉 `isSimulatedBySoftware`
- [ ] v0.4 — 蜂窝基站模拟（`CLSimulationManager.setSimulatedCell:`）
- [ ] v1.0 — 完整的检测向量实验室（把每种检测做成可复现的测试用例）

详见 [Docs/ROADMAP.md](Docs/ROADMAP.md)。

---

## 文档

- [架构设计](Docs/ARCHITECTURE.md)
- [检测向量与对策](Docs/DETECTION.md)
- [Andromeda 分析](Docs/ANALYSIS-ANDROMEDA.md)
- [路线图](Docs/ROADMAP.md)
- [发布流程](Docs/RELEASING.md)

---

## 免责声明

Xloc 仅供**学习、研究与个人测试**使用，例如：测试自己开发的 App 在异地场景下的行为、验证风控逻辑、做位置相关的自动化测试。

**不要**用于：伪造考勤、刷单、游戏作弊、规避平台风控、任何违反当地法律或服务条款的行为。使用者自行承担全部后果。

本项目不包含、也不会包含任何破解、绕过付费授权、注入第三方 App 的功能。

---

## 致谢

- [Geranium](https://github.com/c22dev/Geranium) / [Andromeda](https://github.com/Sonerbt/Andromeda) — 证明了 TrollStore 上定位模拟的可行性
- [udevs/LocSim](https://github.com/udevs/LocSim) — `CLSimulationManager` 接口的最早公开整理
- [TrollStore](https://github.com/opa334/TrollStore) — 让这一切不需要越狱

<div align="center">

**GPL-3.0** · Made for learning, not for cheating.

</div>
