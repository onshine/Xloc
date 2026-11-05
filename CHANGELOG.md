# 更新日志

## 未发布：撤回改包入口与纠正诊断

- 撤下未经目标应用运行验证的改包安装入口及插件构建步骤。
- `sourceInformation == nil` 不再标为“真实定位”，而是“来源信息未知”。
- 系统模拟标记保持原样读取，未实现将目标应用观测值变成 false。
- 不把这次纠错发布为“隐蔽模拟已修复”。

## v0.2.0（方案未验证，相关入口已撤下）

### 新增：单 App 注入（B 方案）

- 新增 **App** 标签页：枚举已安装应用、搜索、一键生成注入版安装包
- 新增 `XlocPlugin`：注入到目标 App 内的钩子，替换 `CLLocationManager`
  的定位入口，在进程内构造 `CLLocation` —— 这种对象没有 `sourceInformation`，
  目标 App 读 `isSimulatedBySoftware` 得到的是 `nil`
- 新增 `MachOInjector`：在 Mach-O 头部空白处插入 `LC_LOAD_DYLIB`，不移动任何 section
- 新增 `ZipWriter`：纯 Swift 的最小 ZIP 写入器，用于生成 `.tipa`
- entitlements 增加 `AppBundles` / `AppDataContainers`

### 说明

- 系统通道（`CLSimulationManager`）依然保留，适合"全设备生效、不需要隐蔽"的场景
- 注入模式每次换坐标需重新生成安装包，详见 `Docs/INJECTION.md`


## v0.1.3

### 修复

- **地图空白 + 键盘弹出闪退（同一根因）**：`platform-application` 下没有 GPU 的
  IOKit user client，`MKMapView` 拿不到渲染表面（空白），键盘毛玻璃背景在 CoreImage
  里 SIGSEGV。补回 `AGXDeviceUserClient` 与 `IOSurfaceRootUserClient`。
- **UID 每次启动都变**：Keychain 在 fakesign 应用里会返回 -34018（缺少
  application-identifier），写入失败后每次生成新 ID。改为存到 App 容器之外
  `/var/mobile/Library/Preferences/com.onshine.xloc.uid.plist`，卸载重装不变。


## v0.1.2

### 新增

- **崩溃日志**：信号崩溃（SIGSEGV/SIGABRT/…，C 层捕获，async-signal-safe）、
  未捕获 ObjC 异常（含完整调用栈）、异常退出（上次会话未正常结束）三类记录。
  入口在 设置 → 设备 → 崩溃日志，支持查看 / 复制 / 分享 / 删除。
- **设备 UID**：Keychain 持久化，卸载重装不变，设置顶部一键复制。
- **手动坐标输入**：地图不可用时仍可工作。
- **地图瓦片加载失败提示**：不再"一片空白什么都不说"，会把错误显示出来。

### 修复

- **搜索框点击闪退**：搜索改为独立 sheet，TextField 不再嵌在满屏地图的 ZStack 里。
- 搜索建议改为主线程更新，避免后台线程修改 @Published。


## v0.1.1

### 修复

- **地图不显示**：`UIViewRepresentable` 没有固有尺寸，在 ZStack 里被压成 0 高度。改为显式
  `frame(maxWidth:maxHeight:)` + `ignoresSafeArea()`，并给默认视角（首次进入不再是一片空白）。
- **国内坐标偏移**：地图长按 / 搜索结果拿到的是 GCJ-02，之前直接当 WGS-84 用，实际会偏
  300~600 m。现在统一在入口转 WGS-84，显示时再转回 GCJ-02。
- **自检显示"还没收到定位样本"**：之前传的是 `nil`。现在接入 `CLLocationManager`，
  显示系统实际交付的坐标、精度、海拔和来源。

### 新增

- **地点搜索**：`MKLocalSearchCompleter` 联想 + `MKLocalSearch` 解析，点结果直接落点。
- **我的位置**：一键回到当前真实位置。
- **"模拟是否生效"自检项**：把系统交付的定位和目标坐标做距离比对，直接告诉你生效没有。
- 设置页新增"系统当前交付的定位"面板（坐标 / 精度 / 海拔 / 来源）。

### 调整

- 状态条只在模拟运行时出现，不再占用地图顶部。
- VPN / 代理检测降级为提示（`.info`），不再显示成告警。

## v0.1.0

首个版本：单点 / 摇杆 / 路线 / GPX / 真实感引擎 / Wi-Fi 指纹 / 自检 / 最小权限集。
