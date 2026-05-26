# LiveWallpaper · Loomscreen

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![macOS 14+](https://img.shields.io/badge/macOS-14.0%2B-blue.svg)](#运行环境)
[![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-required-purple.svg)](#运行环境)
[![Release](https://img.shields.io/github/v/release/Paradox07127/LiveWallpaper?include_prereleases&sort=semver&filter=loomscreen-*)](https://github.com/Paradox07127/LiveWallpaper/releases)

> [English](README.md) | 简体中文

一款 macOS 菜单栏应用,把视频和网页变成跨多显示器的动态壁纸。

本仓库的代码同时构建两个 macOS 产品:

| 构建 | 分发渠道 | 状态 |
|---|---|---|
| **LiveWallpaper** | 商业 Pro 版,单独分发。 | 全功能,包括 Metal 着色器壁纸、本地拷贝项目导入、兼容 Scene 渲染,以及开发者工具。 |
| **Loomscreen** | **开源 Lite 版,MIT 许可,**通过 GitHub Releases 分发。 | 视频、HTML/网页、Apple 航拍、粒子、定时、播放列表 —— Pro 独有的渲染器、本地项目导入和开发者工具在编译期排除。 |

"LiveWallpaper" 是本仓库的**内部代号**;"Loomscreen" 是开源版的**对外产品名** —— 同一份代码,轻量出货。

> ⚠️ Loomscreen 目前处于 **0.x** 版本线。功能与配置形态在 `0.y` → `0.(y+1)` 之间可能有破坏性变更。版本号到达 `1.0.0` 时表层契约才会锁定。

## Loomscreen(Lite 版)

### 下载

> **发布页:** https://github.com/Paradox07127/LiveWallpaper/releases

1. 从 GitHub Releases 下载最新的 `Loomscreen-x.y.z.dmg`。
2. 打开 DMG,把 **Loomscreen.app** 拖到 `/Applications`。
3. Loomscreen 采用 **ad-hoc 签名**(暂无 Apple Developer ID),所以 macOS Gatekeeper 会在第一次启动时拦截。在终端**执行一次**:
   ```bash
   xattr -dr com.apple.quarantine /Applications/Loomscreen.app
   ```
   这告诉 macOS 你信任该二进制。跳过这一步,双击会无声失败并提示 "*Loomscreen can't be opened…*"。
4. 双击 `Loomscreen.app`。Loomscreen 图标出现在菜单栏;点击它即可添加壁纸。

### 首次启动故障排查

- **"Loomscreen is damaged and can't be opened"** —— 这是 Gatekeeper 对隔离标记的话术。重新执行上面的 `xattr` 命令(必要时加 `sudo`)。
- **首次使用时弹出权限对话框** —— Loomscreen 只在用到对应功能时才请求桌面 / 文稿 / 下载 / 定位 / 系统设置权限。逐个授权;后续可在 `系统设置 → 隐私与安全性` 中撤销。
- **Loomscreen 与 LiveWallpaper Pro 同时安装?** —— 两者干净共存:Bundle ID 不同(`com.loomscreen` vs `Taijia.LiveWallpaper`)、文件类型不同(`.loomscreen` vs `.lwconfig`)、Dock 和访达里的图标也独立。

### 自动更新

Loomscreen 在应用启动时查询 GitHub Releases(每台机器**每 12 小时一次**节流;不做后台轮询,无遥测)。发现新版本会弹出 "*New version available*" 提示,点击后用浏览器打开 GitHub Releases 页面。也可在 **设置 → 关于** 手动触发检查。

### 功能对照表

| 能力                                                | LiveWallpaper Pro | Loomscreen Lite |
|---|:---:|:---:|
| 视频壁纸(MP4 / MOV / AVI)                          | ✅ | ✅ |
| HTML / 网页(WKWebView)壁纸                         | ✅ | ✅ |
| Apple 航拍浏览                                       | ✅ | ✅ |
| 多显示器、按屏独立配置                                | ✅ | ✅ |
| 收藏库(一键再应用)                                  | ✅ | ✅ |
| 播放列表 + 随机 / 拖拽排序 / 定时计划                  | ✅ | ✅ |
| 实时 CIFilter 滤镜(模糊 / 暗角 / …)                | ✅ | ✅ |
| 粒子叠层(雪 / 雨 / 樱花 / …)                       | ✅ | ✅ |
| 天气联动                                              | ✅ | ✅ |
| 系统监控(CPU / GPU / 内存)                         | ✅ | ✅ |
| 锁屏快照帧                                           | ✅ | ✅ |
| 检视器内联预览                                       | ✅ | ✅ |
| 全局快捷键                                           | ✅ | ✅ |
| **Metal 着色器程序化壁纸**                            | ✅ | — |
| **本地拷贝项目目录导入**                              | ✅ | — |
| **兼容 Scene 工程渲染**                              | ✅ | — |
| **开发者工具**                                       | ✅ | — |

Lite 是**轻量运行时,而不是 UI 阉割版**:视频 / HTML / 航拍的体验与 Pro 完全一致。仅不包含 Pro 独有的本地项目导入器和兼容 Scene 渲染器。能力矩阵的权威定义在 [ProductCapabilities.swift](Packages/LiveWallpaperCore/Sources/LiveWallpaperCore/Capabilities/ProductCapabilities.swift)。

## LiveWallpaper Pro 本地项目导入

LiveWallpaper Pro 可扫描并导入从 Windows 上 Wallpaper Engine 库**拷贝过来**的本地项目目录。受支持的工作流如下:

1. 在 Windows 上,通过 Steam / Wallpaper Engine 下载你**有权使用**的壁纸。
2. 把包含编号项目子目录的本地文件夹拷贝到你的 Mac。这通常是一个父目录(例如 `431960/`),或几个具体的项目 ID 子目录。
3. 在 LiveWallpaper Pro 中选择该拷贝目录。应用会扫描本地 `project.json`、读取预览与元数据,并为受支持的项目准备播放。

这是一个**纯本地文件**的工作流。LiveWallpaper 不登录 Steam、不连接 Steam Workshop、不下载 Workshop 项目、不内置任何 Wallpaper Engine 内容、不绕过作者权限。用户需自行确保对所拷贝和使用的项目文件拥有合法使用权。

导入支持有意保守:

- 视频和网页项目映射到 LiveWallpaper 原生的视频 / WKWebView 运行时。
- 兼容的 Scene 工程由 Pro Scene 渲染器渲染;覆盖范围仍在扩张,部分场景可能只能部分渲染或被标记为不支持。
- 需要 Windows 可执行文件或 `.dll` 插件的项目在 macOS 上跳过。
- 缺失依赖的项目必须本身已存在于拷贝目录或 Pro 缓存中。

## 全代码库特性

- **多类型壁纸** —— 视频(MP4/MOV/AVI)、HTML/网页(WKWebView)、Metal 着色器(程序化 GPU 艺术),以及 Pro 独有的从 Windows 拷贝来的本地项目目录(必要时 `.pkg` 解包或目录镜像)
- **多显示器** —— 每屏独立配置
- **收藏库** —— 任意视频 / 网页 / 着色器保存一次,后续可一键再应用到任意显示器(侧栏 Library、检视器顶部)
- **HTML 信任模型** —— 未信任的远程 URL 默认禁用 JavaScript;一键 `信任此站点` 放行
- **Apple 航拍** —— 浏览并应用 Apple 已下载的航拍壁纸(一次性目录授权后即可)
- **播放列表 + 定时** —— 多视频播放列表,支持随机、拖拽排序、按时段切换
- **实时滤镜** —— CIFilter 管线:模糊、饱和度、亮度、色温、暗角、雨打玻璃
- **粒子叠层** —— 雪、雨、散景、萤火虫、落叶、樱花
- **天气联动** —— 可选用实时天气驱动粒子和颜色(Open-Meteo,无需 API key)
- **电源感知** —— 电池模式下暂停、检测全屏应用、锁屏帧捕捉
- **播放控制** —— 速度(0.5x-2.0x)、帧率限制、适配模式(填充 / 适应 / 拉伸)、按屏静音
- **系统监控** —— 系统级 CPU/GPU/内存/温度 + 单进程指标,估算渲染 FPS
- **自适应 macOS UI** —— macOS 26 原生 Liquid Glass,macOS 14 / 15 走材质回退。每个版本上的最高保真路径都是默认;不需要用户配置。
- **Swift 6 严格并发** —— 编译期数据竞争安全
- **800+ 单元测试** —— 策略、解码器、收藏、HTML 信任、定时、播放列表、场景导入 / 渲染、macOS 兼容性策略、应用内更新检查器、发布回归
- **零依赖** —— 纯 Apple 原生框架

## 运行环境

- macOS 14.0(Sonoma)或更高版本
- **必须 Apple Silicon Mac。** 不支持 Intel Mac。
- Xcode 16.2+(从源码构建时)

## 从源码构建

1. 在 Xcode 中打开 `LiveWallpaper.xcodeproj`。
2. 选择 scheme:
   - **LiveWallpaper** —— 完整 Pro 构建。
   - **LiveWallpaperLite** —— Loomscreen Lite 构建。已设置 `LITE_BUILD` 编译标志;由 `#if !LITE_BUILD` 守卫的 Pro 独有源码会被排除。
3. 构建并运行(`⌘R`)。
4. 点击菜单栏图标 → 选择一个显示器 → 选择一个视频。

> 两个 scheme 共享 `DerivedData/.../XCBuildData/build.db`,**不能并行构建**。请按顺序运行,或为各自指定不同的 `-derivedDataPath`。

## 文档

- [CHANGELOG.md](CHANGELOG.md) —— Loomscreen(Lite)版本变更说明。Pro 版本说明单独维护。

## 发布工具

- [scripts/release-loomscreen.sh](scripts/release-loomscreen.sh) —— 构建、ad-hoc 签名并打包 Loomscreen DMG。`--version X.Y.Z` 必填,`--dry-run` 跳过 DMG 生成。
- [scripts/release_candidate_check.sh](scripts/release_candidate_check.sh) —— 自动化本地发布候选检查(Hardened Runtime、隐私清单、i18n、静态审计)。在签名机器上设 `REQUIRE_DEVELOPER_ID=1` 会在缺 Developer ID Application 证书时快速失败。
- [.github/workflows/release-loomscreen.yml](.github/workflows/release-loomscreen.yml) —— 推送 `loomscreen-v*.*.*` 形式的 tag 即可触发自动化 archive → 签名 → DMG → publish 流水线。

## 参与贡献

欢迎提 PR 和 issue。在开 PR 之前请本地跑通 `LiveWallpaper` scheme 的 `xcodebuild test` 和 `LiveWallpaperLite` scheme 的 `xcodebuild build`,两者都必须成功。测试套件强制了若干运行时约定(持久化、observation 守卫、通知时序、Liquid Glass 自适应包装、播放列表 schema、收藏语义)—— 如果你的 PR 需要偏离这些约定,请在描述里明确说明。

## 安全

如发现安全漏洞,请使用 GitHub 的 [私有漏洞报告通道](https://github.com/Paradox07127/LiveWallpaper/security/advisories/new),不要开公开 issue。

## 商标声明

"Wallpaper Engine"、"Steam" 与 "Steam Workshop" 是其各自所有者的商标。本项目为独立软件,不附属于、不被 Wallpaper Engine、Steam、Valve 或其关联公司认可、不被其赞助。文档中提及上述名称仅用于互操作性说明和准确的用户操作指引。

## 许可

本项目以 **MIT License** 发布 —— 完整条款见 [LICENSE](LICENSE)。整个 LiveWallpaper 代码库(包括由 `#if !LITE_BUILD` 守卫的 Pro 独有模块)同样适用该许可。
