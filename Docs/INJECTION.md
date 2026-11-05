# 单 App 注入（B 方案）

## 为什么需要它

系统模拟通道（`CLSimulationManager` → locationd）有一个绕不过去的副作用：

> locationd 知道自己下发的是模拟位置，会给它打上
> `CLLocationSourceInformation.isSimulatedBySoftware = true`。

目标 App 只要读这一位，就知道是假的。**在 App 侧改不了**，因为这个标记是产生方打的。

唯一解法是让定位**不在系统通道里产生**，而是在目标 App 进程内自己构造一个
`CLLocation`——这种对象没有 `sourceInformation`，App 读到的是 `nil`，与真实定位无法区分。

## 实现

```
Xloc（主程序）
  ├─ 枚举已安装 App（LSApplicationWorkspace）
  ├─ 复制目标 App 的 bundle 到临时目录
  ├─ 放入 XlocPlugin.dylib + XlocConfig.plist
  ├─ 往主程序 Mach-O 头里插一条 LC_LOAD_DYLIB
  └─ 打包成 Payload/<App>.app 的 .tipa
        ↓
     TrollStore 覆盖安装（由它重新签名）
        ↓
目标 App 启动 → 加载 XlocPlugin → hook CLLocationManager
```

### 插件做了什么

| 被替换的方法 | 行为 |
|---|---|
| `-startUpdatingLocation` | 不真的开定位，改为 1 Hz 回调 delegate |
| `-requestLocation` | 同上（一次性定位） |
| `-stopUpdatingLocation` | 停掉定时器 |
| `+/-authorizationStatus` | 返回 `authorizedAlways`，避免 App 卡在未授权 |
| `-requestWhenInUseAuthorization` / `-requestAlwaysAuthorization` | 调完立刻回调已授权 |

回调里投递的 `CLLocation` 是插件用配置坐标现造的，带轻微随机漂移，`sourceInformation` 为 `nil`。

## 限制（必须知道）

1. **每次换坐标都要重新生成、重新安装**。配置是随包带过去的，不是运行时下发。
2. **安装包会覆盖原 App**。TrollStore 覆盖安装通常保留数据，但不保证；重要 App 先备份。
3. **注入后原 App 的签名失效**，只能由 TrollStore 重新签。不要用 App Store 更新它。
4. **App 自带的完整性校验/越狱检测可能发现**。本方案不做对抗。
5. 只对**这个 App** 生效，其他 App 不受影响 —— 这正是它相对系统通道的优势。

## 卸载

删除该 App，从 App Store 重装，或安装一份未修改的包即可恢复。
