# VoltWarden

一款给 Apple Silicon MacBook 用的菜单栏电池工具：查看电池状态，并设置日常充电上限。它是开源项目 [Stasis](https://github.com/srimanachanta/Stasis) 的非官方中文改版，不是 Apple 或原作者发布的版本。

> v1.0 是免费实验版。它没有 Apple Developer ID 签名与公证，也还没在一台全新安装的 Mac 上完成充电助手验收。请不要把界面显示的目标值当成硬件已执行的证明。

## 下载与安装

目前仓库只提供源码，**安装包尚未发布**。下列步骤适用于将来明确标注为实验版的 Release；GitHub 自动提供的源码 ZIP 不能直接运行。

1. 从本仓库的 **Releases** 下载 `VoltWarden-v1.0-arm64.zip`。GitHub 自动提供的 “Source code” 是源码，不是安装包。
2. 解压后将 `VoltWarden.app` 拖进「应用程序」，从那里打开。它是菜单栏程序，不会常驻 Dock。
3. 因为此免费版未经 Apple 公证，macOS 可能阻止首次打开。若你确认下载来源可信，可在首次尝试打开后，前往「系统设置 → 隐私与安全性」选择「仍要打开」。不要全局关闭 Gatekeeper，也不要执行网上流传的清除隔离属性命令。
4. 打开设置，启用「管理充电」。macOS 要求管理员批准后台充电助手时，前往「系统设置 → 通用 → 登录项与扩展」允许 VoltWarden，回到软件重新检查。
5. 设置充电上限，松开滑块后提交。界面中的 75% 是目标；若助手未获批准或失效，实际限充可能不会执行。遇到异常请先拔电，再检查后台项目状态。

目前仅在开发者的一台 Apple Silicon MacBook、macOS 27.0 上验证。程序声明最低 macOS 14.8，但旧系统、其他机型与全新安装流程尚未验证。软件使用系统私有充电接口，macOS 更新可能影响功能。本版暂沿用上游的内部 bundle ID；**不要与原版 Stasis 同时安装或运行**，否则设置和后台助手可能冲突。

## 能做什么

- 查看电量、健康度、温度、适配器与功率流向。
- 设置 50%–100% 充电上限，临时充满后恢复日常目标。
- 显示稳定的断电续航估计与充至目标的预计时间。
- 合盖、拔电和重新接电时按当前电源状态调整充电控制。

估计时间仅供参考，不参与充电控制。把目标从 75% 改为 50%，不会瞬间减少电池的真实电量。

## 开发与许可证

源码、测试、打包和发布方法见 [发布指南](docs/RELEASING.zh-CN.md)。构建需 Apple Silicon Mac 与当前 Xcode：

```bash
swift test --scratch-path /tmp/StasisBuildTests
SIGN_IDENTITY='Apple Development: 你的证书名称' \
  bash scripts/package-app.sh /tmp/VoltWardenBuild /tmp/VoltWardenDist/VoltWarden.app
```

本项目继承上游 Stasis 的 [GPL-3.0](LICENSE)；发布二进制时须同时提供对应版本的完整源码。保留 [Stasis](https://github.com/srimanachanta/Stasis)、[SMCKit](https://github.com/srimanachanta/SMCKit) 和 [Defaults](https://github.com/sindresorhus/Defaults) 的版权与许可说明。App 图标的平面图形在 `Packaging/IconSource/`，由 Apple Icon Composer 生成图标资源。
