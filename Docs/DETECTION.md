# 检测向量与对策

> 这份文档是 Xloc 的设计依据：先搞清楚"别人怎么发现你"，再决定"我们做什么"。
> 每一条都标注了 **Xloc 是否覆盖**，没覆盖的会明说。

---

## 0. 一句话

定位模拟的对抗，本质是**一致性**的对抗：
GPS 说你在这里，那么 Wi-Fi、基站、传感器、时区、IP、行为历史，都得说你在**同一个地方**。
任何一处矛盾，都是检测点。

---

## 1. 系统层：CoreLocation 自己就告诉你了

### 1.1 `CLLocationSourceInformation`（iOS 15+）

```swift
if let src = location.sourceInformation {
    if src.isSimulatedBySoftware { /* 软件模拟 */ }
    if src.isProducedByAccessory { /* 外接设备 */ }
}
```

| 项目 | 说明 |
|---|---|
| 覆盖面 | 所有走 locationd 模拟通道的方案 |
| Xloc | ❌ **无法消除**（走系统通道必然被打标记） |
| 自检 | ✅ 面板会如实显示 |
| 根治 | 只能在目标进程内 hook（v0.3 插件模式） |

**这是最强、也最便宜的一条检测。** 一个 `if` 就能判定。任何声称"完全不被检测"的工具，只要还走系统通道，这句话就不成立。

### 1.2 字段合理性

| 字段 | 真实值 | 常见伪造痕迹 |
|---|---|---|
| `horizontalAccuracy` | 3–30 m，缓慢变化 | 恒定 5.0 / 每帧乱跳 |
| `verticalAccuracy` | 通常 > horizontal | 与 horizontal 相等 |
| `altitude` | 缓慢变化 ±0.5 m | 恒为 0 |
| `speed` | 静止时 0–0.3 | 恒为 0 或恒定值 |
| `course` | 静止时随机 | 恒为 -1 |
| `timestamp` | 递增且贴近当前 | 固定值 / 与设备时间差大 |

Xloc：✅ 全部覆盖（RealismEngine）。

---

## 2. 网络指纹

### 2.1 Wi-Fi BSSID 数据库比对

App 拿到当前 BSSID，查自己的库（或 Apple/Google 的 WLAN 定位库），
如果 BSSID 注册地和 GPS 坐标相差几百公里 → 判定伪造。

| 项目 | 说明 |
|---|---|
| Xloc | ✅ Wi-Fi 伪造（SSID/BSSID/RSSI/信道） |
| 注意 | BSSID 必须"像真的"：格式、组播位、OUI 厂商 |

### 2.2 OUI 与地理的匹配

`A4:2B:B0` 是 TP-Link，`F8:FF:C2` 是 Apple。
如果你的"纽约公寓"用的是某国产路由器 OUI，风控会起疑。

Xloc：✅ `BSSIDValidator` 提供 OUI 识别与合法性校验。

### 2.3 IP 归属地

App 请求自己的服务端，服务端看到出口 IP 在国内，而 GPS 在纽约 → 矛盾。

| 项目 | 说明 |
|---|---|
| Xloc | ❌ 不处理（这是网络层问题，不是定位层） |
| 建议 | 代理出口必须与坐标一致；自检面板会提示 `utun`/`ppp` 与系统代理 |

### 2.4 基站 / Cell ID

iOS 不向普通 App 暴露 Cell ID，但：
- 越狱环境下可读
- App 可以通过私有 API 或运营商信息间接推断

Xloc：🚧 v0.4 规划（`CLSimulationManager.setSimulatedCell:`）

---

## 3. 传感器一致性（最难伪造）

| 传感器 | 检测逻辑 |
|---|---|
| 加速度计 | 走路有 ~2 Hz 的步频特征；坐车有引擎振动 |
| 陀螺仪 | 转弯时角速度与航向变化必须匹配 |
| 磁力计 | 航向与地磁方向一致 |
| 气压计 | 海拔变化与气压变化一致 |
| 运动协处理器 | `CMMotionActivity` 会给出 stationary/walking/automotive |

**一个"以 60 km/h 在高速上移动"的假定位，如果 `CMMotionActivity` 一直是 `stationary`，几乎必然被抓。**

Xloc：❌ 不处理（没有传感器注入能力，也不打算做——那需要更底层的权限）。
这是所有"纯定位层"方案的共同上限。

---

## 4. 行为与服务端

| 检测 | 说明 |
|---|---|
| 瞬移 | 两次定位间隔 1 分钟，距离 800 km |
| 速度不合理 | 城市道路 200 km/h |
| 停留异常 | 从未在任何地点停留超过 5 分钟 |
| 轨迹规律 | 每天同一时刻出现在同一坐标，误差 < 1 m |
| 与账号历史矛盾 | 账号三年都在北京，今天突然在纽约下单 |
| 与设备时区矛盾 | 坐标在东京，设备时区是 Asia/Shanghai |

Xloc 能做的是"让单次定位看起来正常"（速度连续、有抖动、时区通知）。
**跨会话的行为一致性，工具层面解决不了。**

---

## 5. 环境检测（针对"作弊工具"本身）

| 检测 | 实现 | Xloc 自检 |
|---|---|---|
| 越狱 | `/var/lib/cydia`、`/var/lib/dpkg`、`systemhook.dylib` | ✅ |
| 注入 | 扫描 `_dyld_image_count()` 里的异常镜像 | ✅（提示存在） |
| 调试器 | `task_set_exception_ports`、`PT_DENY_ATTACH` | ⚠️ 仅提示 |
| Frida | `gum-js-loop` 线程名、`kern.svc_stalker_ctl_callnum` | ⚠️ 仅提示 |
| 代理 | `CFNetworkCopySystemProxySettings` | ✅ |
| VPN | `utun` / `ppp` 接口 | ✅ |
| 模拟器 | `TARGET_OS_SIMULATOR`、机型字符串 | — |

Xloc 不做对抗，只做**告知**：让用户在模拟前就知道"我这台设备现在有多少个可疑特征"。

---

## 6. 对抗矩阵

| 检测向量 | 单点模拟 | 路线模拟 | 说明 |
|---|:---:|:---:|---|
| `isSimulatedBySoftware` | ❌ | ❌ | 系统通道的固有代价 |
| 坐标静止 | ✅ | ✅ | OU 漂移 |
| 速度阶跃 | ✅ | ✅ | 加速度受限 |
| 精度恒定 | ✅ | ✅ | 环境模型 |
| 海拔缺失 | ✅ | ✅ | 海拔噪声 |
| Wi-Fi 矛盾 | ✅ | ✅ | 指纹伪造 |
| OUI 不合理 | ✅ | ✅ | 校验 + 真实厂商 OUI |
| IP 矛盾 | ❌ | ❌ | 网络层，需自备代理 |
| 传感器矛盾 | ❌ | ❌ | 无注入能力 |
| 服务端行为分析 | ❌ | ❌ | 工具层无解 |

---

## 7. 给"防守方"的建议

如果你在做风控，按性价比排序：

1. 读 `sourceInformation`（一行代码，覆盖 90% 的软件模拟）
2. GPS ↔ Wi-Fi BSSID ↔ IP 三方交叉
3. 加速度计/陀螺仪与轨迹的物理一致性
4. `horizontalAccuracy` / `speed` / `course` 的时序统计特征
5. 服务端行为模型（历史、频次、停留）

前两条能挡住绝大多数工具；第三条能挡住剩下的绝大多数。
