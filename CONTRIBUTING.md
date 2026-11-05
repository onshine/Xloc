# 贡献指南

## 分支

- `main` — 稳定，可发布
- `dev` — 日常开发
- 功能分支：`feat/wifi-oui-table`、`fix/route-finish`

## 代码规范

- Swift 5.9，缩进 4 空格
- 新增私有 API 调用 **只能** 放在 `Xloc/Bridge/`，且必须在 `PrivateHeaders.h` 里有注释说明来源与用途
- 新增权限必须在本 PR 里解释「为什么非它不可」，否则不合并
- 不引入第三方依赖（保持可审计）

## 提交信息

```
type(scope): subject

feat(realism): 用 OU 过程替换白噪声
fix(wifi): 修复 BSSID 组播位判断
docs(detection): 补充传感器一致性说明
```

## 测试

```bash
make project
xcodebuild test -project Xloc.xcodeproj -scheme Xloc -destination 'platform=iOS Simulator,name=iPhone 15'
```

核心逻辑（Geo / Route / Realism / BSSID）必须有测试；UI 不强制。

## 不接受的 PR

- 破解、绕过付费授权
- 注入第三方 App（插件请提到 `XlocPlugin` 仓库）
- 申请与定位无关的权限
- 任何遥测/上报代码
- 混淆代码（本项目坚持可读、可审计）
