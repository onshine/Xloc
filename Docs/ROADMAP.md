# 路线图

## v0.1 — 可用（当前）

- [x] `CLSimulationManager` 封装（append / restart 双策略）
- [x] 单点模拟
- [x] 摇杆（八向 + 力度）
- [x] 路线模拟（MapKit 算路 + 加速度剖面）
- [x] GPX 导入（Douglas–Peucker 抽稀）
- [x] 真实感引擎（OU 漂移 / 环境精度 / 海拔 / 节奏抖动）
- [x] Wi-Fi 指纹（读取 / 校验 / 伪造 / 备份还原）
- [x] 坐标系（WGS-84 / GCJ-02 / BD-09）
- [x] 自检面板
- [x] 最小权限集

## v0.2 — 好用

- [ ] 收藏夹（本地 + 导入导出 JSON）
- [ ] App 预设：为不同目标 App 保存不同的坐标/路线/Wi-Fi
- [ ] 路线录制：把摇杆轨迹录下来回放
- [ ] 后台保活：`BGTaskScheduler` + 定位后台模式
- [ ] 地图长按选点时的地址反查（`CLGeocoder`，注意国内需 GCJ）
- [ ] 深色模式与图标

## v0.3 — 可选插件（越狱）

> 独立仓库 `XlocPlugin`，主程序保持零注入。

- [ ] MobileSubstrate 插件：在目标 App 进程内 hook `CLLocationManager`
- [ ] 消除 `isSimulatedBySoftware`（目标 App 视角）
- [ ] 真正的 per-app 作用域
- [ ] 自动检测目标 App 的越狱/注入检测并提示（不绕过，只提示）

## v0.4 — 更完整的环境伪造

- [ ] 蜂窝模拟（`setSimulatedCell:`）
- [ ] `.scenario` 文件支持（`loadScenarioFromURL:`）
- [ ] Wi-Fi 扫描列表伪造（不止当前连接）
- [ ] 时区 / 语言 / 运营商跟随坐标

## v1.0 — 稳定

- [ ] 检测向量实验室：每条检测做成可复现用例
- [ ] 完整的单元测试（Geo / Route / Realism）
- [ ] 多语言（en / zh-Hans / zh-Hant / ja）
- [ ] 崩溃上报（本地日志，不上传）

---

## 不做的事

明确排除，避免方向跑偏：

- ❌ 破解、绕过任何付费授权
- ❌ 注入第三方 App（v0.3 的插件是独立可选项，默认不安装）
- ❌ 伪造设备指纹（IDFA/IDFV/UDID）
- ❌ 任何形式的遥测/上报
- ❌ 申请与定位无关的权限（驱动、GPU、VPN 扩展……）
