<div align="center">

<img src="docs/images/loomscreen-logo.png" width="128" alt="Loomscreen" />

# Loomscreen

### macOS 动态壁纸 —— 视频、网页、着色器、Wallpaper Engine 场景,铺满每一块屏幕。

[![License: MIT](https://img.shields.io/badge/Lite-MIT-yellow.svg)](LICENSE)
[![macOS 14+](https://img.shields.io/badge/macOS-14.0%2B-blue.svg)](#系统要求)
[![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-required-purple.svg)](#系统要求)
[![Release](https://img.shields.io/github/v/release/Paradox07127/Loomscreen?include_prereleases&sort=semver)](https://github.com/Paradox07127/Loomscreen/releases/latest)

**[⬇ 下载](https://github.com/Paradox07127/Loomscreen/releases/latest)** ·
**[✨ 功能](docs/features.md)** ·
**[⚖ Lite vs Pro](docs/lite-vs-pro.md)** ·
**[🛠 构建](docs/building.md)** ·
[English](README.md)

</div>

---

Loomscreen 是一个菜单栏 App,把你的桌面变成会动的场景,又不打扰你。指给它一个视频、
一个网页、一段 Apple Aerial、一个 Metal 着色器,或一个 Wallpaper Engine 工程——它会
在每一块连接的显示器上渲染,在全屏游戏时自动暂停,其余时间则尽量省电。

它由同一套代码构建出两个版本:

<table>
<tr>
<td width="50%" valign="top">

### 🆓 Loomscreen Lite
**免费 · 开源(MIT)**

轻量运行时。视频、HTML、Apple Aerials 壁纸均为全保真——与 Pro 同一套播放引擎,
只是不含重型渲染器。通过本仓库 GitHub Releases 分发。

</td>
<td width="50%" valign="top">

### ⭐ Loomscreen Pro
**完整版**

包含 Lite 全部功能,外加 Metal 场景/着色器渲染器、Wallpaper Engine 场景播放、
本地工程导入、Workshop 预览,以及开发者工具。

</td>
</tr>
</table>

> Lite 是**轻量运行时,不是阉割界面**——视频 / HTML / Aerials 的观感与行为和 Pro
> 完全一致。区别在于打包了哪些渲染器,而不是少了哪些按钮。完整对照见
> [Lite vs Pro](docs/lite-vs-pro.md)。

> 🚧 **0.x 阶段。** Loomscreen 仍在快速迭代,在稳定到 `1.0.0` 之前,配置结构与界面
> 可能在 `0.y` 版本之间变化。欢迎反馈与报告问题 —— 提交
> [issue](https://github.com/Paradox07127/Loomscreen/issues)。

## ✨ 亮点

- 🎬 **任意来源** —— 本地视频、网页 / HTML、Apple Aerials、Metal 着色器,以及 Wallpaper Engine 场景(Pro)。
- 🖥 **每块屏幕** —— 每台显示器独立壁纸,支持播放列表与按时间调度。
- 🎛 **特效** —— 实时后期特效、粒子叠加、天气联动场景。
- 🔖 **收藏与播放列表** —— 收藏壁纸、轮播一组、定时随机切换。
- 🎮 **不碍事** —— 全屏游戏/应用时自动暂停;适配 ProMotion;省电。
- 🔄 **安静更新** —— 每次启动检查一次 GitHub Releases(12 小时节流),无遥测、无后台轮询。

→ 带"怎么做、为什么"的完整介绍见 **[docs/features.md](docs/features.md)**。

## 🚀 快速开始

1. 从 **[Releases](https://github.com/Paradox07127/Loomscreen/releases/latest)** 下载最新的 `Loomscreen-x.y.z.dmg`(Lite)。
2. 打开 DMG,把 **Loomscreen.app** 拖入 `/Applications`。
3. 由于尚无付费 Apple Developer ID,构建为 ad-hoc 签名,首次启动需在终端**执行一次**清除隔离标记:
   ```bash
   xattr -dr com.apple.quarantine /Applications/Loomscreen.app
   ```
4. 启动后图标出现在菜单栏。

完整安装、更新与排错见 **[docs/install.md](docs/install.md)**。

## 系统要求

- macOS 14.0(Sonoma)或更新
- **Apple Silicon Mac** —— 不支持 Intel
- 从源码构建需 Xcode 16.2+

## 🛠 从源码构建

```bash
git clone https://github.com/Paradox07127/Loomscreen.git
cd LiveWallpaper
open LiveWallpaper.xcodeproj
```

Lite 选 **LiveWallpaperLite** scheme(置 `LITE_BUILD`,`#if !LITE_BUILD` 的 Pro 专属
源码被排除),完整版选 **LiveWallpaper**,然后 `⌘R`。详见
**[docs/building.md](docs/building.md)** · **[RELEASING.md](RELEASING.md)**。

## 贡献 · 安全 · 许可

- **欢迎 PR 与 issue。** 提交前在 `LiveWallpaper` scheme 跑 `xcodebuild test`、在
  `LiveWallpaperLite` 跑 `xcodebuild build`,两者都须通过。测试套件强制运行时不变量。
- **安全问题:** 请用 GitHub 的[私密漏洞上报](https://github.com/Paradox07127/Loomscreen/security/advisories/new),不要公开 issue。
- **许可:** MIT —— 见 [LICENSE](LICENSE),覆盖整个代码库(含 `#if !LITE_BUILD` 的 Pro 专属模块)。

<div align="center"><sub>Loomscreen 不捆绑 Wallpaper Engine 内容,也不绕过创作者授权——你需自行对导入的任何壁纸的版权负责。</sub></div>
