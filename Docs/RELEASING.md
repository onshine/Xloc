# 发布流程

## 自动发布（推荐）

打一个 tag，剩下交给 GitHub Actions：

```bash
# 1. 确认 main 是绿的
git checkout main && git pull

# 2. 打 tag（语义化版本，必须 v 开头）
git tag v0.1.0 -m "Xloc 0.1.0"
git push origin v0.1.0
```

`.github/workflows/release.yml` 会：

1. `macos-14` + 最新 Xcode
2. `xcodegen generate`
3. `xcodebuild -sdk iphoneos -configuration Release`（不签名构建）
4. 用 **ldid** 写入 `Xloc.entitlements`（没有 ldid 则回退 `codesign` ad-hoc）
5. **校验 entitlements 里确实有 `com.apple.locationd.simulation`**，没有就 fail
6. 打包 `Payload/Xloc.app` → `Xloc-<version>.tipa` + `.sha256`
7. 用 `git log <上一个tag>..HEAD` 生成 changelog
8. 创建 GitHub Release 并上传 tipa

产物在 Release 页面，TrollStore 直接打开安装。

### 手动触发

Actions → Release → Run workflow，填版本号即可（不会创建 tag，但会创建同名 Release）。
勾选 `prerelease` 会标记为预发布。

---

## 本地发布（离线）

```bash
make tipa
# 等价于：
#   xcodegen generate
#   xcodebuild ... build
#   ./Scripts/package.sh build/Build/Products/Release-iphoneos/Xloc.app Xloc.tipa
```

`Scripts/package.sh` 的行为：

| 情况 | 结果 |
|---|---|
| 有 `ldid` | `ldid -S<entitlements>`（推荐） |
| 没有 `ldid` | `codesign --force --sign - --entitlements` 回退 |
| 传 `--no-sign` | 只打包，不签名（CI 里验证编译用） |
| entitlements 没写进去 | 打印警告并以退出码 2 结束 |

---

## 版本号

- `MARKETING_VERSION` ← tag（去掉 `v`），release workflow 会自动传
- `CURRENT_PROJECT_VERSION` ← `github.run_number`
- `Info.plist` 里写的是 `$(MARKETING_VERSION)`，不需要手改

---

## 常见问题

### Release 卡在 "Verify entitlements"

说明签名没生效。检查：

```bash
codesign -d --entitlements :- Xloc.app/Xloc
```

如果没有输出，通常是：
- `Xloc.entitlements` 路径不对（CI 里是仓库根目录相对路径）
- `codesign` 对已签名的二进制拒绝重复签名 → 加 `--force`

### 安装后定位没反应

TrollStore 安装时会重新 fakesign，**用的是二进制里已有的 entitlements**。
如果打包时没签进去，装完就没有 `locationd.simulation`，`CLSimulationManager` 会静默失效。
Xloc 的自检面板第一项就会把这条标红。

### 想要 Apple 公证？

不需要，也不可行——这些 entitlements 不可能通过 App Store 审核。
本项目只面向 TrollStore。

---

## CI 矩阵

| 工作流 | 触发 | 产物 |
|---|---|---|
| `ci.yml` / build | push、PR | `Xloc-unsigned.tipa`（7 天） |
| `ci.yml` / test | push、PR | 测试日志（失败时也上传） |
| `release.yml` | tag `v*`、手动 | `Xloc-<ver>.tipa` + sha256 |
