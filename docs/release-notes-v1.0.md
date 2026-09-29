# VoltWarden v1.0

这是 VoltWarden 的首个公开版本。下载 `VoltWarden-v1.0-arm64.zip`，解压后将 App 拖到“应用程序”文件夹；第一次打开与后台服务授权，请按 [README 的安装步骤](https://github.com/Tsing-Z-QZ/VoltWarden#下载与安装) 操作。

这版包含充电上限、临时充满、校准、电池状态与功率展示，以及菜单栏面板和设置页面。README 中有真实界面截图。

目前提供 **Apple 芯片（arm64）** 安装包；我在自己的 M4 Pro、macOS 27 上使用并验证。Intel Mac 不适用。其他系统版本和机型，尤其 75% 等非系统原生上限，尚不能保证一致表现。安装包使用 Apple Development 签名，**未经过 Apple 公证**，首次打开可能需要在“系统设置 → 隐私与安全性”中手动允许；首次启用充电管理还需要管理员授权后台助手。不要与使用相同内部标识的旧版同时安装。

校验值见 `VoltWarden-v1.0-arm64.sha256`。源码、GPL-3.0 许可证及必要的来源说明均在仓库中。