# GPU 归因实验协议(2026-07 热源攻坚)

前提结论(powermetrics 实测,见 memory `project_wpe_thermal_and_perf_baseline`):热源=GPU 17W@P13,CPU 已榨干。
本轮目标:把 GPU 瓦数**归因**到 pass / limiter / 带宽,为 pass 合并选材并裁决"带宽热 vs 计算热"。

## 0. 工具就绪状态

### A. 逐 pass GPU 计时(已落地,DEBUG-only)
```bash
defaults write Taijia.LiveWallpaper WPEPassGPUProfileEnabled -bool YES   # 开
defaults write Taijia.LiveWallpaper WPEPassGPUProfileReportEvery -int 900 # 可选,报告周期(command buffer 数)
```
- 实现:`WPEMetalPassGPUProfiler.swift`,stage-boundary counter sampling,挂在所有 12 类 render pass 上。
- 输出:`~/Library/Containers/Taijia.LiveWallpaper/Data/Library/Caches/WPEPassGPUProfile/pass-profile-<scene>-<n>.csv`
  (非沙盒运行时在 `~/Library/Caches/WPEPassGPUProfile/`),列:label,count,avg_ms,max_ms,total_s,share_pct。
- 切场景自动 flush 一份 CSV;os_log 每周期打 top-5(`[WPE pass-gpu-profile]`)。
- ⚠️ TBDR 语义:各 pass 的 vertex/fragment 跨 pass 重叠,**avg_ms 用于排名,不可加总当帧时间**(官方 WWDC20-10603)。
- 覆盖缺口:blit(refract 快照、copyTexture)不采样——CSV 头部 `cbTotal_s` 与 `attributed_s` 的差额即 blit+空隙的未归因部分。

### B. Performance Limiters 自定义模板(一次性 GUI 操作,待做)
attach 模式已实测可产出 `gpu-counter-value` 表,但**默认 counter set 只有 1 个计数器**;
limiter 集是 GUI recording option,xctrace CLI 无开关 → 解法:
1. 打开 Instruments → Game Performance 模板。
2. 选中 "Metal Application" instrument → Recording Options → Counter Set → **Performance Limiters**。
3. File → Save As Template… 命名 `GP-Limiters`。
之后 CLI 永久可用:`xcrun xctrace record --template 'GP-Limiters' --attach <pid> …`。

## 1. 判据框架(来自 Apple 官方语义)

- **limiter vs utilization 成对读**:limiter = 工作+stall,utilization = 纯工作。
  **limiter ≫ utilization = 该单元在 stall,才是真瓶颈**;单看 limiter 高会误判。
- limiter → 杠杆映射(WWDC20-10603):
  | limiter 最高者 | 结论与杠杆 |
  |---|---|
  | Texture Sample / Texture Write / Buffer | **带宽热** → pass 合并 + FBO 削减方向正确;辅助:mipmap、更小像素格式、`.load/.store` 精简 |
  | ALU(且 F32 util 高) | **计算热** → shader 降精度(half)、查表近似;pass 合并收益有限 |
  | GPU Last Level Cache | 先修上面两类;缩 working set |
  | MMU | 访存不连贯 → 布局/局部性 |
- **occupancy 注意**(M3+ 架构):低 occupancy 可能是 GPU 主动防 cache thrashing,不当默认优化目标;
  诊断顺序 ALU/带宽 → Occupancy Manager Target → L1 eviction → LLC → MMU。
- **帧节奏指标**:p50/p95/p99 帧时间 + missed-interval(hitch)计数,不用平均 FPS;
  帧间隔允许非 16.7ms,判据是"稳定一致"(Apple 官方立场)。

## 2. 每 cell 采集项

| 采集 | 命令/来源 | 给什么判据 |
|---|---|---|
| 逐 pass 排行 | 工具 A 的 CSV | pass 合并选材(头号交付物) |
| GPU limiter | `GP-Limiters` 模板 attach 30s | 带宽热 vs 计算热裁决 |
| GPU 时间线/气泡 | Metal System Trace attach 30s | encoder 间隙、vsync、drawable 等待 |
| CPU 七阶段 | Time Profiler + os_signpost attach 30s | 回归对照(基线 p50 2.86ms/encode 1.94ms) |
| 功耗/热 | `sudo powermetrics --samplers gpu_power,thermal -i 1000 -n 30`(用户跑) | GPU W、P-state 直方图、thermal pressure |
| 单帧深剖(仅榜首场景) | Xcode Cmd+I GPU Frame Capture(用户 GUI) | 逐 draw 带宽/shader 每行成本 |

trace 里顺带可导的表(同一份 `GP-Limiters`/MST trace):`gpu-performance-state-intervals`(P-state,免 sudo 交叉验证)、
`device-thermal-state-intervals`、`displayed-surfaces-per-second`、`ca-client-buffer-wait-interval`、
`metal-shader-profiler-intervals`(逐 shader GPU 时间,与工具 A 互证)、`graphics-compiler-spill-events`(寄存器溢出)。

## 3. 环境控制

- **Profile 构建**:Xcode Cmd+I(ProfileAction=Release)或直接跑 Release;别动 LaunchAction(Debug+MTL_HUD)。
  - ⚠️ 工具 A 是 DEBUG-only:逐 pass 排行 cell 用 Debug 跑(排名不受构建配置影响);limiter/功耗 cell 必须 Release。
- 插电、亮度固定、关其它 GPU 应用;**每 cell 预热 3-5 分钟到热稳态**(必须盖过懒 GLSL→MSL 转译的首帧成本),采样 30s。
- 双屏为主(与基线同构),单屏一组对照。
- defaults 域名 `Taijia.LiveWallpaper`。

## 4. 壁纸 × 参数矩阵

场景(各考一个子系统):
| 场景 | 考什么 |
|---|---|
| 轻量单层 scene | 地板对照 |
| 3660962877 | 极端 pass 数(4K×~36 pass)——带宽假设主考题 |
| 3448877775 | 多层 blend / 2-pass tint |
| 3509243656(三体) | JS 重,scriptTick CPU 上限 |
| 烟花/火星粒子场景 | particleTick + additive overdraw |
| 4K 视频壁纸 | AVFoundation 对照,隔离"Metal 是否唯一热源" |
| 音频响应 + 捕获开 | audio tap 增量成本 |

参数(单维扫,不交叉):FPS 30↔60;`WPEMetalPerspectiveNativeResolution` YES↔NO;双屏↔单屏。

## 5. 裁决表

1. 榜首 pass 集中度:top-5 pass share ≥50% → 合并/削减这几个 pass 的预期收益上限即其 share × GPU W。
2. Texture/Buffer limiter ≫ ALU 且 ≫ utilization → 带宽热实锤,pass 合并立项;反之转向 shader 降精度。
3. `PerspectiveNativeResolution NO` 若使 GPU W 大降 → fill-rate 主导的旁证。
4. 视频壁纸 GPU W 对照 → 划出"非 scene-renderer"热的基线。
5. CPU 七阶段 p95 与基线漂移 >20% → 先查回归再谈优化。

## 6. 管线联调结论(2026-07-18 双屏 3660962877 试跑)

全链路已打通:工具 A CSV(双屏分文件)、os-signpost 七阶段、time-profile(含 `core fmt="CPU N (S Core)"` 核放置)、
displayed-surfaces-per-second、gpu-performance-state、thermal、buffer-wait、metal-gpu-intervals(GPU busy)全部导出+解析成功;
Game Performance attach 真 app(Release)录制成功。

解析铁律(踩过的坑):
- xctrace XML 的 id/ref 去重必须**递归注册子孙节点**(`process` 嵌在 `formatted-label` 里,只扫 row 直接子节点会漏)。
- 值元素的 tag 是 **engineering-type**(`gpu-channel-name`/`gpu-performance-state`),不是列 mnemonic;列对不上先 dump schema+首行。
- `metal-gpu-intervals`(176MB/30s)要 streaming iterparse + `metal-nesting-level==0` 防嵌套双算 + 按进程过滤
  (同表混着 WindowServer/Chrome/Claude Helper——正式 cell 前关掉其它 GPU 应用)。
- Debug scheme 的 MTL_HUD 会把 `libMTLHud_draw` 注入 GPU intervals;Release 干净。
- MST 模板已含 Game Performance 的全部 GPU 表;GP 模板非必需。

## 7. 遗留 unknown

- **limiter 计数器与 shader profiler 都是 GUI recording option**:默认 counter set 只有 RT Unit Active、
  `metal-shader-profiler-intervals` 0 行。都要在 GUI 里开(Counter Set=Performance Limiters;Shader Profiler 勾选)后存 `GP-Limiters` 模板;齐全性待首个正式 cell 验证。
- 工具 A 对 blit 不可见;若 share 差额大(cb 总时长 ≫ Σpass),需补 blit 采样(MTLBlitPassDescriptor 同机制)。
- `displayed-surfaces-per-second` 双屏都叫 "Built-In Display",按屏区分待用 `display-vsyncs-interval`/`display-surface-swap` 交叉。
- powermetrics 在 macOS 27 beta 的 `CPU Power: 0 mW` 读数 bug——CPU 侧瓦数以 `gpu-performance-state-intervals` + 频率驻留旁证。
