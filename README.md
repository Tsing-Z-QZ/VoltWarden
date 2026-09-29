# VoltWarden

让 MacBook 按我设定的电量停充，而不是一直充到满。

我平时经常把 MacBook 插着电用，也想一眼看清现在到底是在充电、保持，还是由电池供电。系统自带的充电上限只给 80%–100%，我想用的却是 75% 这类更灵活的目标，于是做了 VoltWarden：一个放在菜单栏里的电池工具，设置好后就让它安静待着。


除了充电上限，我还做了电量、健康度、温度、适配器功率、充满时间和断电续航的展示。续航数字是估计值，不会跟着每一次瞬时功率波动来回跳。

## 实际界面

下面是我自己 Mac 上运行时的截图。

<table>
  <tr>
    <td align="center" width="36%">
      <img src="docs/images/menu-panel.png" width="300" alt="VoltWarden 菜单栏面板，显示 75% 电量、140 W 适配器及实时功率"><br>
      <sub>菜单栏面板 · 电量、适配器和功率流向</sub>
    </td>
    <td align="center" width="64%">
      <img src="docs/images/charging-settings.png" width="580" alt="VoltWarden 设置窗口，显示充电管理和 75% 日常充电上限"><br>
      <sub>充电设置 · 日常上限与临时充满</sub>
    </td>
  </tr>
</table>

## 先说适用范围

我目前在自己的 Apple 芯片 MacBook、macOS 27 上使用和验证。 当前提供的是 Apple 芯片版，不是 Intel 版。

- macOS 26.4 及以上：苹果系统自带 80%–100% 充电上限；VoltWarden 的 50%–79% 用到了额外的控制路径。我还没有在 26.4–26.x 上验证 75% 是否能稳定停住。
- macOS 26.3 及更早：是否能真正停充更依赖具体机型的硬件能力。我不把“能打开软件”等同于“限充一定生效”。
- Intel Mac：目前的 App 和后台助手都是 Apple 芯片版本，不能直接运行。
- macOS 14.7 及更早：低于当前 App 声明的最低系统版本，不支持安装。

如果你只需要 80%–100%，并且 Mac 已经运行 macOS 26.4 或更新版本，也可以先试试 [macOS 自带的充电上限](https://support.apple.com/en-au/102338)。

## 快速上手：第一次安装

> v1.6 安装包已经发布：[点这里下载 VoltWarden-v1.6-arm64.zip](https://github.com/Tsing-Z-QZ/VoltWarden/releases/download/v1.6/VoltWarden-v1.6-arm64.zip)。页面自动给的「Source code (zip)」是源码，双击不能当 App 用。

### 步骤零：确认你的 Mac

点屏幕左上角  → 关于本机。看到「芯片」是 M 系列，再看 macOS 版本；如果写的是 Intel，先不要下载这个安装包。

### 步骤一：下载并放进「应用程序」

1. 打开 [Releases](https://github.com/Tsing-Z-QZ/VoltWarden/releases)，点进最新版本，展开 Assets。
2. 下载名字形如 `VoltWarden-v1.6-arm64.zip` 的文件。不要下载页面自动生成的 Source code。
3. 在访达打开「下载」文件夹，双击 ZIP 解压，得到 VoltWarden.app。
4. 把 VoltWarden.app 拖到访达侧边栏的「应用程序」。如果以前装过，先从菜单栏退出旧版，再替换；不要直接在 ZIP 或下载文件夹里运行。

### 步骤二：第一次打开

1. 到「应用程序」里双击 VoltWarden。它是菜单栏软件，打开后去屏幕右上角找电池小图标；Dock 里没有常驻图标是正常的。
2. 如果 macOS 弹出“无法验证开发者”之类的提示，先确认文件确实来自本仓库的 Release。然后打开 系统设置 → 隐私与安全性，向下找到 “仍要打开”，再按系统提示确认。[苹果也有图文说明](https://support.apple.com/en-gb/102445)。

### 步骤三：设定你想要的上限

1. 点击菜单栏的电池图标 → 设置，打开 管理充电。
2. 如果 macOS 让你允许后台运行，去 系统设置 → 通用 → 登录项与扩展 → 允许在后台运行，找到 VoltWarden 或充电助手，把它打开；需要管理员密码时，只在 macOS 自己的窗口里输入。
3. 回到软件，必要时退出并重新打开。拖动滑块到想要的上限，松开滑块后才会提交。
4. 第一次使用时，留意实际电量和系统充电状态。界面显示的目标值是你设定的目标，不代表硬件已经成功执行；如果电量仍持续冲过目标，先拔下充电线，再检查后台助手是否获准运行。

## 我平时会用到的功能

- 日常限充：设一个平时想保持的电量，不用每次手动改系统设置。
- 临时充满：出门前需要满电时点「充满」，结束后回到日常目标。
- 状态看得懂：电量、健康度、温度、适配器规格和功率流向都放在菜单栏面板里。
- 时间只做参考：断电还能用多久、充到目标还需多久都是估计，不参与充电控制。把目标从 75% 改成 50%，电池的真实电量也不会瞬间少 25%。

有问题就在 [Issues](https://github.com/Tsing-Z-QZ/VoltWarden/issues) 留下 Mac 型号、macOS 版本、目标电量和实际电量。发日志前记得遮住序列号等隐私信息。

## 想看看代码

我把源码、测试和打包方法都放在仓库里，详细步骤见 [发布指南](docs/RELEASING.zh-CN.md)。项目采用 [GPL-3.0](LICENSE)，已有代码与依赖的来源见 [开源与版权说明](ATTRIBUTION.md)。图标的平面源文件也在 `Packaging/IconSource/`。

---

## English

VoltWarden lets me set a charging limit for my MacBook, so it does not have to charge to 100% every time. I built it because I often use my MacBook plugged in and wanted a simple way to see whether it is charging, holding its level, or running on battery. It lives in the menu bar and stays out of the way once it is set up.

The panel also shows battery level, health, temperature, power adapter rating, estimated time to charge, and estimated runtime on battery. Runtime is an estimate, not a number that jumps every time power draw changes for a second.

### What it looks like

These are screenshots from my own Mac, not mockups.

<table>
  <tr>
    <td align="center" width="36%">
      <img src="docs/images/menu-panel.png" width="300" alt="VoltWarden menu bar panel showing battery level, a 140 W adapter, and power flow"><br>
      <sub>Menu bar panel · battery, adapter, and power flow</sub>
    </td>
    <td align="center" width="64%">
      <img src="docs/images/charging-settings.png" width="580" alt="VoltWarden charging settings with a 75% daily limit"><br>
      <sub>Charging settings · daily limit and temporary full charge</sub>
    </td>
  </tr>
</table>

### Compatibility first

I currently use and test VoltWarden on my own Apple silicon MacBook running macOS 27. The v1.6 download is built for Apple silicon only.

- macOS 26.4 and later: macOS itself offers an 80%–100% charge limit. VoltWarden uses an additional control path for 50%–79%. I have not verified that a 75% limit works reliably on every Mac running macOS 26.4–26.x.
- macOS 26.3 and earlier: whether charging actually stops depends more heavily on the specific Mac's hardware. Being able to open the app does not mean its charging limit will work.
- Intel Macs: the current app and background helper are built for Apple silicon and will not run on Intel.
- macOS 14.7 and earlier: these are below the app's declared minimum version.

If you only need an 80%–100% limit on macOS 26.4 or later, you may want to try [the built-in macOS charge limit](https://support.apple.com/en-au/102338) first.

### Download and install

Download the app from the [v1.6 release page](https://github.com/Tsing-Z-QZ/VoltWarden/releases/tag/v1.6). Choose `VoltWarden-v1.6-arm64.zip` under Assets. The automatically generated “Source code” ZIP is source code, not an installable app.

1. Check your Mac: open the Apple menu, choose About This Mac, and confirm it has an M-series chip.
2. Open the ZIP from your Downloads folder. It will unpack to `VoltWarden.app`.
3. Drag `VoltWarden.app` into Applications in Finder. If an older copy is running, quit it from the menu bar before replacing it. Do not run the app directly from the ZIP or Downloads folder.
4. Open VoltWarden from Applications. It is a menu bar app, so look for its battery icon at the top of the screen; it does not stay in the Dock.
5. If macOS says it cannot verify the developer, first make sure you downloaded the file from this repository's Release. Then open System Settings → Privacy & Security, find Open Anyway, and confirm. [Apple explains this process here](https://support.apple.com/en-gb/102445). If macOS says the app is damaged or will harm your computer, do not bypass the warning; [report the exact message](https://github.com/Tsing-Z-QZ/VoltWarden/issues) instead.
6. Click the menu bar icon → Settings → charging management. If macOS asks you to allow the background helper, enable it under System Settings → General → Login Items & Extensions. Enter an administrator password only in a macOS system prompt. You may need to quit and reopen VoltWarden afterward.
7. Drag the slider to your preferred limit. The app submits the new target when you release the slider. On first use, keep an eye on the actual battery level and charging status: the target shown in the app is not proof that the hardware has applied it. If the battery keeps charging past your limit, unplug the charger and check whether the background helper is allowed to run.

### Everyday use

- Daily limit: pick the battery level you want to maintain while plugged in.
- Temporary full charge: top up to 100% before heading out, then return to your everyday limit.
- Clear status: see battery health, temperature, adapter rating, and power flow in one menu bar panel.
- Time estimates: estimated runtime and time to charge are informational; they do not control charging. Changing the target from 75% to 50% does not instantly reduce the battery's actual charge by 25%.

If something does not work, [open an issue](https://github.com/Tsing-Z-QZ/VoltWarden/issues) with your Mac model, macOS version, target level, and actual battery level. Please remove serial numbers and other personal details before sharing logs.

### Source and license

The repository includes the source code, tests, and [release instructions in Chinese](docs/RELEASING.zh-CN.md). VoltWarden is licensed under [GPL-3.0](LICENSE); required credits for existing code and dependencies are in [ATTRIBUTION.md](ATTRIBUTION.md). The flat source artwork for the app icon is in `Packaging/IconSource/`.
