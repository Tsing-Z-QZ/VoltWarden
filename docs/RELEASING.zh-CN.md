# VoltWarden 发布指南

当前版本：1.0（2026092904）。当前准备的是本机开发签名构建，尚未公证。包含五类设置、原生 Liquid Glass 控件、按电量填充的菜单栏图标、稳定续航估计、充满时间展示，以及睡眠／离电原生限充重试暂停保护。菜单栏电池图标为三位数字和状态符号预留独立宽度；接电时小于 2 W 的负向电池功率只在界面状态中视为保持，适配器与电池显著共同供电时单独标明。睡眠唤醒后暂不采用过渡期的极低功耗读数，沿用上次估算至正常采样恢复。此次增加旧版特权助手登记失效时的离电安全重注册，避免 App 升级后后台服务仍指向已经移走的旧版 bundle。若 macOS 将后台项目设为未允许，必须由管理员在系统设置中批准，应用无法绕过。不要把本机测试包称为正式公共发行版。

## 本次功能语义

“断电预计”表示现在拔掉电源后，按当前工作负载预计能用多久。电量仍为 75% 时，把充电上限从 75% 改成 50% 不会立刻扣掉 25% 电量；只有实际容量或工作功耗变化，续航才应变化。上限高于当前电量时，时间卡切到“充至目标”；100% 或 Top Up 时切到“预计充满”。充电估算优先用剩余待充容量和真实充电电流，必要时用系统的充满时间；没有有效充电数据时显示“等待充电开始”，不把放电续航误当充满时间。估算不参与充放电控制。

断电续航使用约一分钟的时间平滑功耗，最多每 5 分钟检查一次，差异至少 10 分钟且达到约 15% 才更新，取约 5 分钟精度；短暂功率峰值不会使数字跳动。短暂缺失的数据沿用最近值，数据过期时在提示文字中说明。充电 ETA 首次有效采样立即显示，目标变化立即重算；充电刚启动的前 10 秒每 5 秒快速校正小电流偏差，之后同目标最多约 30 秒刷新一次。接近满电时充电会减速，实际时长可能更长。实时功率图仍保持快速采样与显示。

## 仓库结构

- `Stasis/`：界面、显示模型及服务。
- `SMCPower/`、`Helper/`、`ChargingHelper/`：硬件访问与两个 helper。
- `Tests/`：策略、异步时序和显示回归测试。
- `Vendor/`：本地依赖及各自许可证；源码构建不依赖旧 App。
- `Packaging/`：App 和 XPC 的 Info.plist、Icon Composer 源文件与平面 SVG 图层。
- `scripts/package-app.sh`：Release 构建、组装和从内向外签名。
- `scripts/notarize-app.sh`：提交公证、装订票据、校验并生成 ZIP。
- `README.md`、`docs/RELEASING.zh-CN.md`、`LICENSE`：说明与 GPL-3.0 许可证。

不要提交 `.build`、旧 App、日志、备份文件、证书私钥、Apple ID 密码或公证凭据。`.gitignore` 已覆盖常见残留。保留上游及依赖的版权信息，随二进制提供与其匹配的完整源码及构建材料。

## 先收口 helper 安装方式

本机目前运行的是 macOS ServiceManagement 注册的助手，App 路径为
`/Applications/VoltWarden.app`。`/Library/LaunchDaemons/com.srimanachanta.stasis.charging-helper.native.plist`
仍是历史部署残留；当前运行的服务不是靠该系统目录中的 plist 启动的。
它不应复制到公共下载包，也不要在没有独立核实的情况下删除。打包脚本只把使用相对
`BundleProgram` 的 plist 放进 App。

App 已有 `SMAppService.daemon(...).register()` 和授权状态检查。公共版本应由这个正式入口完成安装：用户把 App 拖入“应用程序”，首次启用“管理充电”，按系统提示允许后台项目，回到 App 检查状态。Apple 说明 helper 注册受用户批准控制，因此特权充电控制不可能做到完全免授权。[Apple SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice)

优先在没有 Stasis、没有旧系统 plist 的真实 Apple Silicon 测试机上完成首次安装、拒绝权限、重新批准、重启、升级和卸载验证。仅靠本机已有 helper 的成功运行不能证明首次安装可靠。本机迁移时，先准备好经过签名验证的 App 与可恢复的旧配置，再在管理员授权下停止并移除旧手工服务，完成 App 内注册和授权；验证通过以后才永久清理旧 plist。不要同时启用两个同名 Mach service。

helper 会检查客户端的 bundle ID 与签名 Team ID。主程序、XPC 和充电 helper 必须使用同一团队签名。当前 bundle ID 沿用上游 `com.srimanachanta.stasis`；面向大众发布独立 fork 前应统一规划自己的 ID，并一并迁移 Mach service、权限验证、plist、偏好设置及登录项，不能只改 Info.plist。本轮保持已验证的核心时序；这个迁移需单独回归。

## 构建、签名、公证

本次使用 Apple Silicon、macOS 27.0、Xcode 27 / Swift 6.4 验证；Package 要求 Swift 6.2+。安装声明最低 macOS 14.8，但本次未实机验证旧系统。液态玻璃只在 macOS 26+ 使用，旧系统有普通材质回退。原生限充使用 PowerUI 私有接口和 SMC，硬件/系统兼容性需单独验证，不承诺所有 Mac 或所有系统版本。发布初期只列出实际验证的配置。

先在项目目录运行：

```bash
swift test --scratch-path /tmp/StasisBuildTests
swift build --scratch-path /tmp/StasisBuild
```

本机测试包：

```bash
SIGN_IDENTITY='Apple Development: 你的证书名称' \
  bash scripts/package-app.sh /tmp/VoltWardenBuild /tmp/VoltWardenDist/VoltWarden.app
```

输出 App 路径必须不存在，避免覆盖。脚本构建所有组件，从源码生成本地化资源和 Icon Composer 图标，不携带备份源码或旧 framework。图标编译会生成 `Assets.car` 与 `AppIcon.icns`，两者都必须出现在 App 的 `Contents/Resources` 中。

公共发行需要 Apple Developer Program 的 Developer ID Application 证书。2026-09-28 本机钥匙串只检测到 Apple Development 证书，不能完成正式公证。拥有账号的 Account Holder 可按 [Apple 创建 Developer ID 证书说明](https://developer.apple.com/help/account/certificates/create-developer-id-certificates)在本机钥匙串创建证书签名请求、在开发者网站申请 Developer ID Application、下载并双击安装 `.cer`；私钥必须留在本机钥匙串，不要上传仓库或发给他人。安装后运行 `security find-identity -v -p codesigning`，确认出现 `Developer ID Application:`，再使用：

```bash
SIGN_IDENTITY='Developer ID Application: 你的发行者名称 (TEAMID)' \
  bash scripts/package-app.sh /tmp/VoltWardenBuild /tmp/VoltWardenDist/VoltWarden.app
```

在钥匙串中创建公证凭据配置（交互输入，不将密码写进仓库或脚本）。可使用 App Store Connect API Key，或按 [Apple 公证说明](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)使用 Apple 账号、团队 ID 和 App 专用密码：

```bash
xcrun notarytool store-credentials VoltWarden-notary
NOTARY_PROFILE=VoltWarden-notary \
  bash scripts/notarize-app.sh /tmp/VoltWardenDist/VoltWarden.app "$PWD/dist/VoltWarden-v1.0-arm64.zip"
```

脚本启用 hardened runtime、逐层签名并校验；公证脚本检查 Developer ID、提交、装订票据及 Gatekeeper 评估。若公证未被接受或校验失败，停止发布，查看服务给出的具体日志。开发签名包不能靠清除隔离属性变成正式可信发行版。不要把让所有用户执行 `xattr -cr` 当作安装流程。[Apple Developer ID](https://developer.apple.com/developer-id/) · [Apple 公证流程](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)

## 不付费的 GitHub 实验版

上传源码到 GitHub 不需要 Apple Developer Program。macOS 应用也没有 iOS 免费开发设备安装那种数天后必须重签的周期；但这并不等于未公证的下载包会被陌生用户的 Mac 默认信任。当前脚本使用本机 Apple Development 证书可构建本地测试包，它不是 Developer ID 发行签名，不能提交 Apple 公证。对网上下载的未公证 App，macOS Gatekeeper 可能阻止首次打开；用户须自行在「系统设置 → 隐私与安全性」决定是否点「仍要打开」。不要让用户全局关闭 Gatekeeper，也不要把清除隔离属性写成常规安装步骤。

更重要的是，充电控制依赖获系统批准的特权后台助手。本机已有历史注册，不能证明开发签名包在全新 Mac 上能完成首次注册。免费路线建议先发布源码，二进制如需分享只标为「实验性预览」，明确说明可能无法启动或限充、只支持已验证机型，并先让另一台干净 Mac 验证首次安装、拒绝/允许后台项目和实际系统上限。不确认系统写入就不能声称限充生效。[Apple 关于打开未公证 App 的说明](https://support.apple.com/en-gb/102445)

## 上传 GitHub

先在 GitHub 创建空的公共仓库 `Tsing-Z-QZ/VoltWarden`，不要勾选自动添加 README。随后在本地项目目录执行：

```bash
git init -b main
git add .
git status --short
git commit -m "Prepare VoltWarden 1.0"
git remote add origin https://github.com/Tsing-Z-QZ/VoltWarden.git
git push -u origin main
```

检查待提交内容中没有私钥、个人日志、旧编译产物。私有接口兼容性和 helper 首装未验收前，只发布源码或明确标注实验性预览，不要写“下载即用”。

正式包通过前面的验收后，在 GitHub 仓库点击 Releases → Draft a new release，创建标签 `v1.0`。上传装订后重新打包的 `VoltWarden-v1.0-arm64.zip`、SHA-256 校验文本，并提供对应标签源码。发布说明列清楚已测试的机型/系统、首次授权步骤和已知限制。先保存草稿，核对附件，再发布。GitHub 的“Source code (zip)”是源码，不是普通用户可直接运行的 App。[GitHub Release 官方步骤](https://docs.github.com/en/repositories/releasing-projects-on-github/managing-releases-in-a-repository)

## 普通用户的安装说明（正式公证后使用）

1. 从 Release 下载 `VoltWarden-版本-arm64.zip`，解压。
2. 将 `VoltWarden.app` 拖到“应用程序”，再从那里打开；不要直接在下载目录或 ZIP 内运行。
3. 在设置中启用“管理充电”。如果 macOS 要求允许后台项目，按提示前往“系统设置 → 通用 → 登录项与扩展”，批准 VoltWarden 后返回 App 点击重新检查。
4. 选择充电上限，松手后生效。Top Up 是暂时充到 100%，不会覆盖原来的限充目标，可主动取消。
5. 卸载前先在 App 内关闭充电管理，等待恢复外接供电及解除控制、注销 helper 成功，再退出并移除 App。若无法注销，不要仅删除 App 导致留下无效的系统服务。

发布验收还应包括睡眠/唤醒、物理拔线、Top Up 取消、后台项目被禁用、helper 连接失败和系统升级。此次用户已手动验证本机行为；按照要求，不再进行额外实机验证。

## 本次交付仍未收口的控制风险

2026-09-27 的 100% → 75% 日志曾复现 75% 目标下继续充到 80%。1.0 已加入重复重置保护、延迟确认处理及过充安全保护；本机手动验证后用户认为日常使用正常，但这不代表跨机型、系统版本和清洁安装已验证。

正式公共版本仍需：清洁机器验证 SMAppService 首次安装和卸载 → 多机型验证 100%/80% 回到 75%（包含睡眠、拔电与取消）→ Developer ID 签名与公证 → GitHub 正式 Release。

本机通过 79 项自动测试，视觉修改完成编译和打包检查；没有进行新的充放电实机压力测试。自动测试使用模拟硬件，不替代上述实机验收；合盖耗电修复尚无修复后整夜对照结果。
