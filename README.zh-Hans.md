# LiveWallpaper · Loomscreen

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![macOS 14+](https://img.shields.io/badge/macOS-14.0%2B-blue.svg)](#运行环境)
[![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-required-purple.svg)](#运行环境)
[![Release](https://img.shields.io/github/v/release/Paradox07127/Loomscreen?include_prereleases&sort=semver&filter=loomscreen-*)](https://github.com/Paradox07127/Loomscreen/releases)

> [English](README.md) | 简体中文

> 🚧 **持续开发中。** Loomscreen 正在不断迭代完善,欢迎提建议、反馈 bug、贡献 PR —— 来开 [issue](https://github.com/Paradox07127/Loomscreen/issues) 或者 [discussion](https://github.com/Paradox07127/Loomscreen/discussions)。

一款 macOS 菜单栏应用,把视频和网页变成跨多显示器的动态壁纸。

本仓库的代码同时构建两个产品:

| 构建 | 许可 | 备注 |
|---|---|---|
| **LiveWallpaper Pro** | 商业版,单独分发 | 全功能 |
| **Loomscreen Lite** | **MIT 开源,通过 GitHub Releases 分发** | 轻量运行时;Pro 独有的渲染器、本地项目导入、开发者工具在编译期排除 |

> ⚠️ Loomscreen 处于 **0.x** 版本线 —— 功能与配置形态在 `0.y` 之间可能有破坏性变更,到 `1.0.0` 时才会锁定。

## 快速开始

1. 从 [Releases](https://github.com/Paradox07127/Loomscreen/releases) 下载 `Loomscreen-x.y.z.dmg`。
2. 打开 DMG,把 **Loomscreen.app** 拖到 `/Applications`。
3. 在终端**执行一次** —— Loomscreen 采用 ad-hoc 签名(暂无 Apple Developer ID),所以 macOS Gatekeeper 会在第一次启动时拦截:
   ```bash
   xattr -dr com.apple.quarantine /Applications/Loomscreen.app
   ```
4. 双击 `Loomscreen.app`,图标出现在菜单栏。

Loomscreen 在每次启动时查 GitHub Releases(每 12 小时节流;不做后台轮询,无遥测)。也可在 **设置 → 关于** 手动触发检查。

## 功能对照

| 能力 | Pro | Lite |
|---|:---:|:---:|
| 视频 / HTML / Apple 航拍壁纸 | ✅ | ✅ |
| 多显示器、播放列表、定时计划、收藏库 | ✅ | ✅ |
| 实时滤镜、粒子叠层、天气联动 | ✅ | ✅ |
| **Metal 着色器程序化壁纸** | ✅ | — |
| **本地拷贝项目目录导入** | ✅ | — |
| **兼容 Scene 工程渲染** | ✅ | — |
| **开发者工具** | ✅ | — |

Lite 是**轻量运行时,而不是 UI 阉割版** —— 视频 / HTML / 航拍的体验与 Pro 完全一致。能力矩阵的权威定义在 [ProductCapabilities.swift](Packages/LiveWallpaperCore/Sources/LiveWallpaperCore/Capabilities/ProductCapabilities.swift)。

## LiveWallpaper Pro 本地项目导入

LiveWallpaper Pro 可扫描并导入从 Windows 上 Wallpaper Engine 库**拷贝过来**的本地项目目录。工作流:

1. 在 Windows 上,通过 Steam / Wallpaper Engine 下载**你有权使用**的壁纸。
2. 把包含编号项目子目录的本地文件夹拷贝到 Mac。
3. 在 Pro 中选择该目录。应用扫描本地 `project.json`,为受支持的项目准备播放。

LiveWallpaper **不会**登录 Steam、不连接 Steam Workshop、不下载 Workshop 项目、不内置任何 Wallpaper Engine 内容、不绕过作者权限。用户需自行确保对所导入的项目文件拥有合法使用权。需要 Windows 可执行文件或 `.dll` 插件的项目在 macOS 上跳过。

## 运行环境

- macOS 14.0(Sonoma)或更高版本
- **必须 Apple Silicon Mac** —— 不支持 Intel Mac
- Xcode 16.2+(从源码构建)

## 从源码构建

```bash
git clone https://github.com/Paradox07127/Loomscreen.git
cd LiveWallpaper
open LiveWallpaper.xcodeproj
```

选择 **LiveWallpaperLite** scheme 构建 Loomscreen Lite(`LITE_BUILD` 编译标志启用,`#if !LITE_BUILD` 守卫的 Pro 源码会被排除),或者 **LiveWallpaper** scheme 构建完整 Pro 版。`⌘R` 运行。

两个 scheme 不能并行构建 —— 它们共享同一个 `XCBuildData/build.db`。

## 参与贡献 · 安全 · 许可

- **欢迎 PR 和 issue。** 在开 PR 之前请本地跑通 `LiveWallpaper` scheme 的 `xcodebuild test` 和 `LiveWallpaperLite` scheme 的 `xcodebuild build`,两者都必须成功。测试套件强制了若干运行时约定 —— 如果 PR 需要偏离,请在描述里明确说明。
- **安全漏洞:** 请使用 GitHub 的 [私有漏洞报告通道](https://github.com/Paradox07127/Loomscreen/security/advisories/new),不要开公开 issue。
- **许可:** MIT —— 见 [LICENSE](LICENSE)。整个 LiveWallpaper 代码库(包括 `#if !LITE_BUILD` 守卫的 Pro 独有模块)同样适用该许可。
