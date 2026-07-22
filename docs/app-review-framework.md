# 全应用 Review 框架 · LiveWallpaper

> 目标:为整个 app(534 个 Swift 文件 / ~166.7k LoC / 5 个 SPM 包 / 一套运行时 GLSL→MSL transpile 的 Metal renderer)设计一套**可重复、可分工、可度量**的全面 review 流程,并给出 **Fable 5 作为编排者、小模型 + codex 作为实际执行者**的调度策略与 prompt 设计。
>
> 本文档结构:
> 1. 现状画像(基于代码库扫描)—— review 的杠杆在哪
> 2. 全面 Review 流程设计(8 维度 × 5 阶段 × 严重度分级)
> 3. **Fable 5 编排调度策略**(orchestrator = Fable 5,worker = Sonnet/codex,judge = Opus)
> 4. Review Prompt 模板库(可直接用)
> 5. Reference Library(参考资料库,~130 条一手源)
> 6. 针对本 app 的落地路线图(具体到文件)

---

## 1. 现状画像:review 的杠杆在哪

基于对仓库的扫描(`git` 快照 + 结构测绘),先建立"打哪里最省力"的地图。**Review 不是平均用力,而是把强模型的注意力压到热点上。**

**体量与形态**
- **534 个 Swift 文件 / ~166.7k LoC**;主 app target ~272 文件;**2 个 SPM 包**(`Core` / `ProWPE`,共 106 文件);测试 122 文件(~41.6k LoC,重资产)。
- **2 个构建变体**:`Lite`(`LITE_BUILD`,无 Metal/WPE,video-only)、`Pro`(默认,全 Metal renderer + Steam Workshop 在线)。
- 仅 2 个 `.metal` 文件 —— **shader 绝大多数是运行时 GLSL→MSL transpile**,这是本 app 独有的结构性风险点(见下)。
- **无 CI 入库**(归档在 `build/DerivedData/…`);发版靠 `scripts/release-app.sh`。

**热点文件(review 第一批目标,按 LoC × 复杂度)**

| 文件 | 行数 | 角色 | 健康度 |
|---|---|---|---|
| `Runtime/WPEMetalRenderExecutor.swift` | 5,722 | 每帧派发 + GPU 状态 + 纹理解析 + 蒙皮 + 错误处理 | ✗ 巨石,28/83 个 TODO 集中于此 |
| `Runtime/WPEMetalSceneRenderer.swift` | 4,248 | 场景引导 + 纹理加载/缓存 + FBO 池 | ✗ 与 Executor 强耦合 |
| `Runtime/WPEShaderTranspiler.swift` | 3,369 | GLSL→MSL 手写编译器,无中间 IR | ✗ 难调试/优化 |
| `Infrastructure/WPERenderGraphBuilder.swift` | 2,027 | 场景 → 渲染 pass 图 | ⚠ |
| `ScreenManager.swift` | 1,983 | Views↔Runtime↔Infra 的中央状态机 | ⚠ 巨石,层边界缺失 |
| `Infrastructure/WPEMdlParser.swift` | 1,756 | 模型/骨骼解析 | ⚠ |
| `Runtime/WPESceneScriptRuntime.swift` | 1,700 | 场景脚本运行时 | ⚠ |
| `Infrastructure/WPESceneDocumentParser.swift` | 1,694 | project.json → RenderGraph | ⚠ |
| `Views/GeneralSettingsView.swift` | 1,521 | 混显示默认/快捷键/开发者工具 | ⚠ 按域拆 |
| `Views/Workshop/WorkshopInstalledView.swift` | 1,471 | 列表+删除+重下 | ⚠ |
| `Infrastructure/Workshop/Doctor/SteamCMDDoctorService.swift` | 1,442 | Steam 诊断 | ⚠ |
| `VideoPlayback/HTMLWallpaperView.swift` | 1,438 | WebKit + Metal overlay + 音频反应 + URL scheme | ✗ 关注点混杂 |
| `Runtime/WPEMetalShaderDispatcher.swift` | 1,399 | **硬编码 `switch(shaderName)`,25 个 case** | ✗ **核心结构性弱点** |

**已知结构性弱点(review 应重点确认/量化,而非重新发现)**
1. **硬编码 shader dispatcher**(`WPEMetalShaderDispatcher.swift`,25 个 `case` 手写分支)—— memory 早已锁定这是**唯一真正需要重构的 renderer 核心**:应改为数据驱动的 pass-graph 注册表,解锁任意特效链 / ping-pong / MRT / 跨帧反馈。
2. **巨石文件**:Executor(5.7k)/ SceneRenderer(4.2k)/ ScreenManager(2k)/ HTMLWallpaperView(1.4k)—— 拖慢编译、放大认知负荷、阻碍并行开发。
3. **Transpiler 无中间 IR**:AST 直出 MSL 文本,难以优化/验证。
4. **设计系统只做了一半**:`Core/UI/Tokens/DesignTokens.swift` 存在且在 `Core/UI/` 内部一致使用,但主 app 的 Views(如 GeneralSettingsView)大量内联颜色/透明度(memory:~68% 样式绕过 token)。
5. **死代码/半成品**:`PlaylistSection/`、`ScheduleSection/` 多为 stub/注释 —— 功能取舍(finish vs cut)候选。
6. **特性开关散落**:大量 `WPEMetal…Enabled` UserDefaults flag,每帧在 Executor 里查 12+ 次、加载时查 13+ 次;宜收敛为类型化 `FeatureFlags` 注册表。

**已经做对、review 只需回归验证的**(避免重复劳动):FBO placement-heap aliasing、memoryless depth、纹理 LRU 预算、off-thread transpile 预热、`WPECanonicalTraceRecorder`(os_signpost 式 trace)——每一项都能对应到 §5.8 里一条 Apple 官方最佳实践,review 时引用背书即可。

---

## 2. 全面 Review 流程设计

设计原则:**维度正交、阶段流水、按热点分配算力、每条发现都要对抗验证并落到严重度**。理论支撑见 §5.1(Google eng-practices 的"看什么"与"导航顺序")、§5.7(结构化/限定范围的 prompt 显著优于全上下文)。

### 2.1 八个 Review 维度(每维度 = 目标 + 权威依据 + 本 app 重点 + 输出 rubric)

| # | 维度 | 权威依据(§) | 本 app 重点 |
|---|---|---|---|
| D1 | **架构与模块边界** | ATAM / C4 / ADR / Ousterhout 深浅模块(5.2, 5.4) | dispatcher 数据驱动化;Executor/ScreenManager/HTMLWallpaperView 拆分;Infra↔Runtime 纠缠 |
| D2 | **代码质量与坏味道** | Fowler smells / Sandi Metz / SQALE / CodeScene hotspot(5.3, 5.4) | 巨石(Large Class/Long Method)、重复的 flag 检查、transpiler 复杂度 |
| D3 | **性能 / 资源消耗** | USE Method / 性能预算 / Metal TBDR(5.5, 5.8) | 每帧 flag 查询、transpile 首帧地板、冗余 pass、纹理常驻、`waitUntilCompleted` |
| D4 | **正确性 / 并发安全** | Swift 6 严格并发 / Sendable / ARC(5.6) | `@MainActor` 串行渲染瓶颈、DisplayLink/闭包 `[weak self]`、数据竞争 |
| D5 | **编译时 / 可维护性** | warn-long flags / WMO / SPM 模块化(5.6) | 巨石拖慢编译;拆进现有 5 个 SPM 包并行编译;显式 ACL |
| D6 | **UI/UX 与设计语言** | Nielsen 十启发 / WCAG / 接口清单 / DTCG token(5.10) | token 绕过率、GeneralSettingsView 集中、flat/glass/liquid-glass 设计规范一致性 |
| D7 | **功能取舍(add/keep/cut)** | RICE / Kano / MoSCoW / 减法(5.11) | Playlist/Schedule stub 去留;Lite/Pro SKU 边界;debug flag 转正 vs 删 |
| D8 | **安全 / 隐私(横切)** | OWASP / App Sandbox / CSP(5.6, 已有 `CSPAudit`)| Steam 凭据接触面、沙盒权限最小化、HTML 壁纸 CSP、`EntitlementAudit` |

> 每个维度的**输出统一为结构化 finding**(见 §4 的 JSON schema):`{dimension, file, line, severity, claim, evidence_quote, suggestion, confidence}`。强制"证据引文"是抑制幻觉发现的关键(§5.7,Datadog ground-in-quotes)。

### 2.2 五阶段流水线(orchestrator 驱动)

```
Phase -1 未知发现     → 盲区扫描 + 访谈:先问"这次 review 我漏看了哪些维度/失败模式?对本 app '好'的隐性标准是什么?",再冻结 rubric(防假阴性;见 §3.5 与 fable5-planning-architecture.md §7)
Phase 0  准备/测绘   → 建 repomap + hotspot 排序(git churn × 复杂度)、冻结 rubric、定预算
Phase 1  广度扫描     → Sonnet fan-out:全库按 (维度 × 模块) 出初筛 finding
Phase 2  深度审查     → 编码模型压热点/巨石/renderer/transpiler,带完整上下文
Phase 3  对抗验证     → judge 逐条"反驳",丢掉无证据/假阳性(多数投票,但防相关性误差)
Phase 4  综合与优先级 → 跨 agent 去重、按 严重度×ROI 排序、产出【HTML】报告 + 大决策的 ADR
Phase 5  理解验证     → HTML 交付物 + 双向 triage(拖拽分桶 + copy-as-prompt 派发修复);对关键发现出事后测验,确认团队真懂再落地(见 §4.5)
```
> **两个书挡(Phase -1 与 Phase 5)是本次升级新增**,依据 @trq212 两篇一手文章,详见 [`fable5-planning-architecture.md`](fable5-planning-architecture.md)。中间 Phase 0–4 是"执行最优"(orchestrator-workers/cascade/judge);书挡补的是"**未知发现**"(前)与"**理解闭环**"(后)——前者防 rubric 漏项导致的假阴性,后者防"机器做对但人没看懂就合并"。

- **Phase 0 用 CodeScene 式行为分析**(5.3):`git log` 高频改动 × 高复杂度 = hotspot,优先送深度审查。本 app 的 hotspot 已在 §1 表中。
- **Phase 1 → 2 是级联(cascade)**:Sonnet 先扫,只有它 flag 或置信低的单元才升级到 codex(FrugalGPT,5.9 — 最高省 98% 成本)。
- **收敛判据(loop-until-dry)**:某维度连续 2 轮无新增 fresh finding 即停(Anthropic evaluator-optimizer,5.9)。

### 2.3 严重度分级与门禁(对齐 CCG 质量门)

| 级别 | 定义 | 处置 |
|---|---|---|
| **Critical** | 数据竞争/崩溃/安全漏洞/主功能不可用 | **交付前必修**(CCG 规则:Critical/High 阻断) |
| **High** | 明确正确性 bug、显著性能回归、巨石阻碍演进 | 交付前修或立 ADR + 排期 |
| **Medium** | 坏味道、可维护性、token 绕过、死代码 | 排 backlog,按 ROI(RICE/技术债象限)排序 |
| **Low / Nit** | 风格、命名、微文案 | Conventional Comments 标 `nit:`,可批量自动修 |

---

## 3. Fable 5 编排调度策略(核心)

**目标**:让 **Fable 5 只做它最擅长的事——规划、路由、预算、综合**,把逐行代码审查这种高 token 消耗的重活压给便宜模型和编码模型,只在"验证"和"跨系统综合"两处动用强推理模型。这正是业界两条成熟蓝图的合流(5.9):
- Anthropic 多 agent 研究系统:**lead(强)分解 → subagent(便宜)执行 → CitationAgent 收尾**;
- CodeRabbit 流水线:**便宜模型压上下文 → 规划模型建 task-graph → 强/编码模型审查 → 独立 judge 过滤**(其 80–90% token 花在上下文准备,不在最终审查)。

### 3.1 角色 × 模型分工表

| 角色 | 模型 | 职责 | 为什么是它 |
|---|---|---|---|
| **Orchestrator / Lead**(编排者)| **Fable 5** | 建 repomap、把工作分解成 `(维度 × 模块/热点)` 单元、路由、管预算与并发、跨 agent 去重与综合、写最终报告与 ADR。**不做逐行审查。** | 快、规划/路由足够强;把它自己的 token 省下来留给 fan-out |
| **Scout / Drone**(广度侦察)| **Sonnet 5** | Phase 1 广度活:文件清单、坏味道初筛、flag/死代码 grep、风格、"这文件是否管太多"、UI 接口清单 | 广度主力;比 Haiku 质量高、假阳性少,读长文件更稳,量大仍可控 |
| **Deep Worker**(深度审查)| **Codex(GPT-5.x)** | Phase 2 硬核:renderer executor / transpiler / dispatcher 的正确性与并发、跨文件追踪、复杂重构建议 | 专用编码模型;CCG 已把后端/代码审查路由给 codex |
| **Judge / Verifier**(对抗验证 + 综合)| **Opus 4.8**(争议项)/ Fable 5(廉价初判)| Phase 3 逐条反驳、Phase 4 需要深推理的综合 | 强推理;仅用于验证与综合,量小 |

> **路由规则(Fable 5 每个单元判一次)**:广度/风格/初筛 → Sonnet;代码逻辑/并发/性能热点 → Codex;跨系统架构权衡 → Opus。对应 Anthropic routing 模式(5.9)。

### 3.2 调度模式(映射到成熟 pattern)

- **Orchestrator-workers**(5.9,Anthropic):子任务数量不可预测("有多少文件/多少问题")时的标准解 —— 恰好是全库 review 的形态。
- **Cascade / FrugalGPT**(5.9):Sonnet → 仅在需要时升级 Codex → 仅争议项升级 Opus。省成本主引擎。
- **Effort budget**(5.9):给 orchestrator 显式预算,避免"给简单单元也 spawn 一堆"。用 `budget.remaining()` 动态收敛。
- **Evaluator-optimizer**:验证循环 + loop-until-dry。
- **成本红线**:多 agent ≈ 15× 单聊 token(Anthropic 实测);judge 面板有**相关性误差**("Nine Judges, Two Effective Votes",5.9)——**用 3 个异视角 judge,不要 9 个同质 judge**;judge 有"随和偏差"倾向接受无效输出(5.9),故 judge prompt 必须**默认反驳、要求证据引文**。

### 3.3 上下文管理(避免"注意力稀释")

关键反直觉证据(5.7,SWE-PRBench):**给模型更多上下文会让所有模型变差** —— 结构化的 2k-token "diff+摘要" 胜过 2.5k 全上下文。落地:
- **不要把整个 5.7k 行的 Executor 塞给一个 agent**。用 repomap(Aider tree-sitter + PageRank,5.9)或本文 §1 的热点表切成"目标函数 + 直接邻居 + 该维度 rubric"。
- **增量 review 用 diff-scoped**:只审 `git diff` 触及的函数 + 其调用邻域(CodeRabbit 把 4000 行文件压到改动触及的几个函数)。
- 每个 worker 只喂:**最小高信号集 = 目标片段 + 依赖邻居 + 维度 rubric + 输出 schema**。

### 3.4 Claude Code 里的具体落地

**(a) 会话模型设为 Fable 5** —— 让主循环(编排者)跑在 Fable 5(经 `/model` 或客户端模型选择;本会话内我无法替你切,需你在 UI/CLI 设)。

**(b) 用 `Workflow` 工具把上面的流水线写成确定性脚本**,每个 agent 用 `model` / `agentType` 覆写。骨架(可直接改用):

```js
export const meta = {
  name: 'app-full-review',
  description: 'Fable5-orchestrated whole-app review: Sonnet breadth → Codex depth → Opus verify',
  phases: [{title:'Breadth'},{title:'Depth'},{title:'Verify'},{title:'Synthesize'}],
}
const DIMS = ['architecture','quality','perf','concurrency','build','uiux','features','security']
const HOTSPOTS = [ // §1 热点表,深度审查目标
  'Runtime/WPEMetalRenderExecutor.swift','Runtime/WPEMetalSceneRenderer.swift',
  'Runtime/WPEShaderTranspiler.swift','Runtime/WPEMetalShaderDispatcher.swift',
  'ScreenManager.swift','VideoPlayback/HTMLWallpaperView.swift',
]
// Phase 1: 广度扫描 —— 维度 × 模块,Sonnet fan-out
const breadth = await parallel(DIMS.map(d => () =>
  agent(`按 ${d} 维度用 rubric 扫描全库,返回结构化 finding(带证据引文)`,
        {model:'sonnet', phase:'Breadth', schema: FINDING_SCHEMA})))
// Phase 2: 热点深度审查 —— Codex,带完整上下文(pipeline,谁先好谁先验)
const deep = await pipeline(HOTSPOTS,
  f => agent(`深度审查 ${f}:正确性/并发/性能,给可执行重构建议`,
             {agentType:'codex:codex-rescue', phase:'Depth', schema: FINDING_SCHEMA}),
  // Phase 3: 每条发现立刻对抗验证(Opus 反驳,要求证据)
  review => parallel((review?.findings||[]).map(x => () =>
    agent(`默认此发现为假,尝试反驳:${x.claim}。除非代码证据成立才判 real。`,
          {model:'opus', phase:'Verify', schema: VERDICT_SCHEMA}).then(v=>({...x,v})))))
// Phase 4: Fable5(编排者本体)去重 + 按 严重度×ROI 排序 + 出报告
return { breadth, confirmed: deep.flat().filter(x=>x?.v?.real) }
```

**(c) 复用已装好的 CCG / codex 能力**(无需自建):
- `/ccg:review`(双模型交叉审 git diff)、`/ccg:analyze`(codex 后端 + 前端双视角)、`/verify-quality`、`/verify-security`、`/verify-module`、`/verify-change` —— 对应 D2/D8/D5。
- `codex:codex-rescue` 子 agent = Phase 2 深度 worker;`team-reviewer` = 综合分级。
- 你 SessionStart 里 `models: Default (frontend=gemini, backend=codex)` —— 与本策略一致(后端/代码走 codex);把"编排层"显式指定 Fable 5 即闭环。

**(d) 分层触发**(对齐你全局的 CCG 自动门规则):变更 >30 行 → `/verify-change` + `/verify-quality`;安全相关 → `/verify-security`;新模块 → `/gen-docs` → `/verify-module`。**全量 review 用上面的 Workflow;日常增量用 CCG 门。**

### 3.5 "未知优先"升级(§3 的前置与后置书挡)

> 依据 @trq212 两篇一手文章,提炼见 [`fable5-planning-architecture.md`](fable5-planning-architecture.md)。§3.1–3.4 解决的是"**机器有没有做对**"(路由、cascade、judge 反驳假阳性);但它默认"人已经知道要 review 什么、也会看懂结果"。这两个假设正是 review 的真实上限所在。

**核心洞察(地图 ≠ 疆域)**:review 的 rubric(§2.1 的 8 维度)是**地图**,代码的实际行为是**疆域**,差距 = 未知。Fable 的质量上限 = 澄清未知的能力。对 review 而言,四象限如下:

| 象限 | 在 review 中 | 挖掘技术 |
|---|---|---|
| 已知的已知 | §1 热点表、已知结构性弱点 | 直接送深审 |
| 已知的未知 | rubric 要回答的问题 | 广度/深度扫描(现有 Phase 1–2) |
| 未知的已知 | 本 app "好"的隐性标准(如壁纸的能耗预算、遮挡暂停) | **头脑风暴 + 参考驱动**(对标 Apple 官方最佳实践) |
| **未知的未知** | rubric **没覆盖到**的维度/失败模式 = **假阴性根源** | **盲区扫描 blindspot pass** |

**Phase -1 盲区扫描(前置书挡)**——在冻结 rubric 前,让 Fable 5 先反问:
```
你是本 app 全库 review 的编排者。在我们冻结 review rubric 之前,先做一次盲区扫描:
上下文:这是一个 macOS 动态壁纸 app,含运行时 GLSL→MSL transpile 的 Metal renderer、534 Swift 文件、Lite/Pro 双 SKU。
我打算按 8 个维度审(架构/质量/性能/并发/编译/UIUX/取舍/安全)。
问:①这 8 维之外,针对【壁纸 app + 运行时 transpile + 双 SKU】这个具体形态,我漏了哪些【未知的未知】维度或失败模式?
②对这个 app,"好"有哪些我大概率没写下来、但看到就认得的隐性标准(如能耗/遮挡暂停/多屏)?
先只做盲区扫描并教我,不要开始审查。
```
> 同时跑一轮**访谈模式**:`一个一个采访我,优先问那些【回答会改变 review 范围或优先级】的问题。`

**Phase 5 理解验证(后置书挡)**——见 §4.5,产 HTML 交付物 + 双向 triage + 事后测验,`只在关键决策通过测验后才落地`。

---

## 4. Review Prompt 模板库(可直接用)

设计依据(§5.7):Anthropic 用 XML 标签分隔 `<instructions>/<context>/<input>`、长输入置顶;rubric 特定化胜过通用("Rubric Is All You Need");结构化 JSON 输出 + 证据引文抑制幻觉;先抽引文再判。

**4.1 结构化 finding schema(所有 worker 统一)**
```json
{ "findings": [{
  "dimension": "architecture|quality|perf|concurrency|build|uiux|features|security",
  "file": "相对路径", "line": 123,
  "severity": "critical|high|medium|low",
  "claim": "一句话缺陷陈述",
  "evidence_quote": "从代码里逐字摘的证据(强制,无引文=丢弃)",
  "failure_scenario": "什么输入/状态 → 什么错误结果",
  "suggestion": "可执行的修法",
  "confidence": 0.0 }]}
```

**4.2 Orchestrator(Fable 5)框架 prompt**
```
你是全库 review 的编排者,不做逐行审查。
1) 读 §1 热点表 + repomap,把工作分解成 (维度 × 模块) 单元;
2) 路由:广度/风格→Sonnet,代码逻辑/并发/性能→Codex,跨系统架构→Opus;
3) 用 cascade:先 Sonnet 广度,只升级它 flag 的单元;给每单元喂最小高信号上下文(不要塞整个巨石文件);
4) 每条 finding 送对抗验证后才收录;跨 agent 去重,按 严重度×ROI 排序;
5) 预算:总量按复杂度缩放,简单单元不 spawn 强模型。
```

**4.3 Worker(维度审查)prompt 模板**
```
<role>你是资深 {Swift/Metal/SwiftUI} 工程师,只审 {维度D_x}。</role>
<rubric>{该维度的具体检查项,如 D4:@MainActor 隔离是否套住重的每帧 CPU 工作?
DisplayLink/闭包是否 [weak self]?跨 actor 传的类型是否 Sendable?}</rubric>
<context>{目标片段 + 直接依赖邻居 + 相关 §5 参考背书}</context>
<instructions>先逐条对照 rubric 抽出代码证据引文,再判定。
只报有证据的问题;每条按 schema 输出;严重度用枚举;宁缺毋滥(假阳性代价高于漏报)。</instructions>
```

**4.4 Judge(对抗验证)prompt 模板**
```
默认下面这条 finding 是【假】的,你的任务是反驳它。
只有当引用的代码证据确实成立、且失败场景可复现时,才判 real=true。
不确定 → real=false。给出你的反驳理由与(若 real)最小复现路径。
finding: {claim + evidence_quote + file:line}
```
> 用 3 个异视角 judge(正确性视角 / 安全视角 / 可复现视角)而非 3 个同质 judge,规避相关性误差(5.9)。

### 4.5 HTML 交付物与双向 triage 模板(Phase 5)

> 依据 @trq212《The Unreasonable Effectiveness of HTML》:agent 产出的报告/PR 讲解默认用 **HTML 而非 markdown**——信息密度、可读性、可分享、**双向交互**让"人真正留在回路里"。**载体分层**:思考/审查/触达用 HTML;需 diff/版本化的 finding schema 与 ADR 正文仍留 markdown 底稿。

**(a) 发现报告(HTML)**——渲染 diff + 行内批注 + 按严重度着色,比纯文本清单更可能被真正读完:
```
把本轮 review 的 confirmed findings 打包成一份 HTML 报告。要求:
- 顶部一个概览:按 严重度(Critical/High/Medium/Low)分组计数 + 按维度分布的 SVG 图;
- 每条 finding 渲染实际代码片段 + 行内批注,按严重度着色;可复现失败场景折叠展开;
- 按 严重度×ROI 排序;移动端可读;文件自包含(内联 CSS/JS,可直接丢进 Slack/传 S3)。
```

**(b) 双向 triage 界面(HTML,以导出结尾)**——把"人的判断"低成本回灌进循环:
```
把这批 findings 做成一个 HTML triage 界面:每条 finding 一张可拖拽卡片,跨 4 列 [本周期修 / 排 backlog / 观察 / 拒绝];
按我们的 严重度×ROI 预排好;每张卡显示 file:line、claim、证据引文、建议修法。
底部两个按钮:"copy as prompt"(把'本周期修'列导出成可直接粘回 Claude Code 的修复任务清单)、"copy as markdown"(导出分桶结果 + 每桶一句理由)。
```

**(c) 事后测验(HTML)**——确认团队真懂再落地关键重构(如 dispatcher 数据驱动化):
```
针对本轮最关键的 {N} 条 Critical/High 发现与建议修法,给我一份 HTML 报告:每条含 上下文/根因直觉/建议怎么改/风险;
底部附一个测验(每条 1~2 题,覆盖"为什么这是问题""改动会影响哪些代码路径"),我必须通过才合并对应修复。
```

> 权衡(诚实记录):HTML 生成慢 2-4×、版本控制 diff 噪声大——所以**只把它用作人机交互界面**,底稿仍是 markdown。别急着做成 `/html` skill,直接 prompt "做个 HTML 文件"即可。

---

## 5. Reference Library(参考资料库)

> 说明:每条 = 名称 — 一句话说明 — URL。优先一手权威源(官方文档、原作者站点、WWDC、arXiv、规范仓库)。标注 ✅ 的为研究 agent 已 fetch 验证可解析的载荷性一手源。

### 5.1 通用代码评审:最佳实践与清单

- **Google Engineering Practices — How to do a code review(Reviewer Guide)** ✅ — 业界最权威的一手评审流程规范;下列子页均验证可解析:
  - Reviewer 指南索引 — https://google.github.io/eng-practices/review/reviewer/
  - The Standard of Code Review(核心原则:只要 CL 明确提升整体代码健康即可批准,不追求完美)— https://google.github.io/eng-practices/review/reviewer/standard.html
  - What to Look For(设计/功能/复杂度/测试/命名/注释/风格/一致性/文档)— https://google.github.io/eng-practices/review/reviewer/looking-for.html
  - Navigating a CL(先看全局→主文件→其余的系统化顺序)— https://google.github.io/eng-practices/review/reviewer/navigate.html
  - Speed of Code Reviews(为何延迟重要:一个工作日预期)— https://google.github.io/eng-practices/review/reviewer/speed.html
  - How to Write Comments(友善、讲理由、给方向、标 nit)— https://google.github.io/eng-practices/review/reviewer/comments.html
  - Handling Pushback — https://google.github.io/eng-practices/review/reviewer/pushback.html
- **Google Eng-Practices — CL Author's Guide** ✅ — 作者侧规范:好的 CL 描述、Small CLs — https://google.github.io/eng-practices/review/developer/ · https://google.github.io/eng-practices/review/developer/cl-descriptions.html · https://google.github.io/eng-practices/review/developer/small-cls.html · 源仓库 https://github.com/google/eng-practices
- **SmartBear — Best Practices for Peer Code Review(11 条)** — 基于 Cisco 实证研究(单次 ≤200–400 LOC、~60 分钟、作者标注、清单、度量)— https://smartbear.com/learn/code-review/best-practices-for-peer-code-review/ · PDF https://static1.smartbear.co/support/media/resources/cc/11_best_practices_for_peer_code_review_redirected.pdf
- **SmartBear — Best Kept Secrets of Peer Code Review(Jason Cohen)** — 上述经验法则的原书/电子书 — https://smartbear.com/resources/ebooks/best-kept-secrets-of-code-review/
- **Microsoft — Code-With Engineering Playbook: Code Reviews** — 微软公开工程手册评审章(流程/角色/语气/PR 大小/自动化)— https://microsoft.github.io/code-with-engineering-playbook/code-reviews/ · Reviewer Guidance https://microsoft.github.io/code-with-engineering-playbook/code-reviews/process-guidance/reviewer-guidance/ · 源仓库 https://github.com/microsoft/code-with-engineering-playbook
- **Conventional Comments** — 评审评论标注规范(`label [decorations]: subject`,label 如 praise/nitpick/suggestion/issue/question/todo),显式化意图与严重度 — https://conventionalcomments.org/
- **SPACE Framework(开发者生产力)** — 生产力多维度理论(Satisfaction/Performance/Activity/Communication/Efficiency)— ACM Queue https://queue.acm.org/detail.cfm?id=3454124 · MSR https://www.microsoft.com/en-us/research/publication/the-space-of-developer-productivity-theres-more-to-it-than-you-think/
- **DORA / Four Keys** — 交付四指标(部署频率、变更前置时间、变更失败率、恢复时间)— 官方 https://dora.dev/ · 参考实现 https://github.com/dora-team/fourkeys · Google Cloud 博客 https://cloud.google.com/blog/products/devops-sre/using-the-four-keys-to-measure-your-devops-performance
- **Accelerate(Forsgren/Humble/Kim)** — DORA 指标的科学出处 — https://itrevolution.com/product/accelerate/ · 研究报告存档 https://dora.dev/research/
- **评审清单模板** — Michaela Greiler 清单 https://github.com/mgreiler/code-review-checklist · Awesome Code Review Checklists https://github.com/mgreiler/awesome-code-review-checklists · ahammel/code-review-checklist https://github.com/ahammel/code-review-checklist

### 5.2 架构评审方法论

- **ATAM(SEI/CMU 原始技术报告)** ✅ — Architecture Tradeoff Analysis Method,质量属性驱动、暴露权衡与风险的结构化评估法 — https://www.sei.cmu.edu/library/atam-method-for-architecture-evaluation/ · 1998 早期报告 https://www.sei.cmu.edu/library/the-architecture-tradeoff-analysis-method/ · 合集 https://www.sei.cmu.edu/library/architecture-tradeoff-analysis-method-collection/
- **ADR — Documenting Architecture Decisions(Michael Nygard 原文)** ✅ — 发明 ADR 格式(Title/Context/Decision/Status/Consequences)— https://cognitect.com/blog/2011/11/15/documenting-architecture-decisions
- **adr.github.io** — ADR 社区之家 + 模板库 — https://adr.github.io/ · 模板 https://adr.github.io/adr-templates/
- **joelparkerhenderson/architecture-decision-record** — GitHub 上最全 ADR 示例/模板集 — https://github.com/joelparkerhenderson/architecture-decision-record
- **ThoughtWorks Tech Radar — Lightweight ADRs** — 建议 ADR 随代码入版本库,保持同步(Adopt 环)— https://www.thoughtworks.com/en-us/radar/techniques/lightweight-architecture-decision-records
- **Martin Fowler — Architecture Decision Record(bliki)** — https://martinfowler.com/bliki/ArchitectureDecisionRecord.html
- **C4 Model(Simon Brown 官方站)** ✅ — 四层抽象(Context/Container/Component/Code)、工具无关的架构可视化 — https://c4model.com/
- **Fitness-function-driven development(ThoughtWorks)** ✅ — 把架构特征编码成流水线里的自动化 fitness function — https://www.thoughtworks.com/insights/articles/fitness-function-driven-development
- **Building Evolutionary Architectures(2nd Ed.,Ford/Parsons/Kua/Sadalage)** — 演进式架构与 fitness function 的定义源 — https://www.thoughtworks.com/en-us/insights/books/building-evolutionaryarchitectures-second-edition
- **Design Docs at Google(Malte Ubl / Industrial Empathy)** ✅ — Google 设计文档文化与规范章节(Context&scope / Goals&non-goals / Design / Alternatives considered)— https://www.industrialempathy.com/posts/design-docs-at-google/
- **arc42(官方)** ✅ — 12 节工具无关的架构文档模板 — https://arc42.org/overview · 全文档 https://docs.arc42.org/home/ · 仓库 https://github.com/arc42/arc42-template
- **RFC/Design Doc 实践** — The Pragmatic Engineer 综述 https://blog.pragmaticengineer.com/rfcs-and-design-docs/ · Rust RFC 流程 https://github.com/rust-lang/rfcs · Oxide RFD https://oxide.computer/blog/a-tool-for-discussion

### 5.3 技术债评估框架

- **SQALE 方法(Letouzey 原始论文,MTD 2012)** ✅ — 符合 ISO-25000 的质量+分析模型,语言/工具无关地估算技术债 — https://ieeexplore.ieee.org/document/6225997
- **Managing Technical Debt with SQALE(IEEE Software)** — 技术债指数/金字塔 — https://dl.acm.org/doi/abs/10.1109/MS.2012.129
- **Sonar — SQALE 说明 + SonarQube 度量定义** — Technical Debt Ratio(`sqale_debt_ratio`)、可维护性评级 A–D — https://www.sonarsource.com/blog/sqale-the-ultimate-quality-model-to-assess-technical-debt/ · https://docs.sonarsource.com/sonarqube-server/user-guide/code-metrics/metrics-definition
- **Martin Fowler — Technical Debt Quadrant(原文)** ✅ — 2×2 象限(Deliberate/Inadvertent × Prudent/Reckless)— https://martinfowler.com/bliki/TechnicalDebtQuadrant.html · 债务隐喻本身 https://martinfowler.com/bliki/TechnicalDebt.html
- **CodeScene — Code Health(产品/文档)** — 由 25+ 因子聚合的 1–10 分,关联维护成本与缺陷风险 — https://codescene.com/product/code-health · https://codescene.io/docs/guides/technical/code-health.html
- **Adam Tornhill — Your Code as a Crime Scene / Software Design X-Rays** — 行为式代码分析(用版本历史找 hotspot、变更耦合、按 ROI 排优先级)— https://pragprog.com/titles/atcrime2/your-code-as-a-crime-scene-second-edition/ · https://pragprog.com/titles/atevol/software-design-x-rays/ · 作者站 https://www.adamtornhill.com/
- **CodeScene — Behavioral Code Analysis(用法文档)** — hotspot / temporal coupling / 优先级的实现参考 — https://docs.enterprise.codescene.io/versions/3.0.2/usage/index.html
- **TD 优先级系统文献综述(JSS/ScienceDirect,Lenarduzzi 等)** — 最权威的学术综述 — https://www.sciencedirect.com/science/article/pii/S016412122030220X
- **技术债优先级矩阵(Impact/Effort、RICE、Cost of Delay)** — 实践写作 https://www.tiny.cloud/blog/technical-debt-tracking/
- **Measuring the Impact of Technical Debt on Development Effort(arXiv)** — 技术债如何抬高开发成本的实证 — https://arxiv.org/pdf/2502.16277

### 5.4 重构与坏味道目录

- **Martin Fowler — Refactoring Catalog** ✅ — 《Refactoring 2e》配套的 ~70 项命名重构(Extract Function/Move Field/Replace Conditional with Polymorphism …)— https://refactoring.com/catalog/
- **Martin Fowler — CodeSmell(bliki)** ✅ — "坏味道 = 深层问题的表层信号"(Kent Beck 提出)的一手定义 — https://martinfowler.com/bliki/CodeSmell.html
- **Refactoring, Ch.3 "Bad Smells in Code"** — 原始坏味道目录(Long Method/Large Class/Duplicated Code/Long Parameter List/Feature Envy/Data Clumps …)— https://www.oreilly.com/library/view/refactoring-improving-the/0201485672/ch03.html · 书主页 https://martinfowler.com/books/refactoring.html
- **Refactoring.Guru — Code Smells / Refactoring Catalog** ✅ — 21 坏味道分五类(Bloaters/OO Abusers/Change Preventers/Dispensables/Couplers)+ 66 项重构技法带前后示例 — https://refactoring.guru/refactoring/smells · https://refactoring.guru/refactoring/catalog
- **John Ousterhout — A Philosophy of Software Design(官方书页)** ✅ — 复杂度是万恶之源;症状=变更放大/认知负荷/未知的未知;深模块 vs 浅模块;战术 vs 战略编程 — https://web.stanford.edu/~ouster/cgi-bin/book.php · CS190 讲义 https://web.stanford.edu/~ouster/cgi-bin/cs190-winter19/lecture.php?topic=intro
- **APoSD 社区笔记 / Pragmatic Engineer 书评** — https://github.com/4141done/philosophy_of_software_design_notes · https://blog.pragmaticengineer.com/a-philosophy-of-software-design-review/
- **Sandi Metz' Rules(thoughtbot)** — 类 ≤100 行、方法 ≤5 行、≤4 参数、控制器只实例化一个对象 — https://thoughtbot.com/blog/sandi-metz-rules-for-developers
- **Sandi Metz — The Wrong Abstraction** — "重复远比错误的抽象便宜" — https://sandimetz.com/blog/2016/1/20/the-wrong-abstraction
- **Robert C. Martin — SOLID(一手博客)** — SRP/OCP/LSP/ISP/DIP — https://blog.cleancoder.com/uncle-bob/2020/10/18/Solid-Relevance.html · https://blog.cleancoder.com/

### 5.5 性能 / 资源效率评审

- **Addy Osmani — Start Performance Budgeting** ✅ — 性能预算的定义源:设不可逾越的硬上限(体积/图片重量/TTI),预算是"有意识地花" — https://addyosmani.com/blog/performance-budgets/
- **MDN — Performance budgets** — 权威参考文档式说明 — https://developer.mozilla.org/en-US/docs/Web/Performance/Guides/Performance_budgets
- **web.dev — RAIL model** — Response <100ms / Animation ≤16ms/帧 / Idle ≤50ms 分块 / Load <5s — https://web.dev/articles/rail · MDN https://developer.mozilla.org/en-US/docs/Glossary/RAIL
- **web.dev — Web Vitals + 阈值定义方法** — LCP≤2.5s / INP≤200ms / CLS≤0.1(P75)— https://web.dev/articles/vitals · https://web.dev/articles/defining-core-web-vitals-thresholds
- **Chrome DevTools — Heap snapshots / Fix memory problems** — 堆快照内存泄漏定位工作流 — https://developer.chrome.com/docs/devtools/memory-problems/heap-snapshots · https://developer.chrome.com/docs/devtools/memory-problems
- **Brendan Gregg — The USE Method** ✅ — 对每个资源检查 Utilization/Saturation/Errors 的系统化瓶颈法 — https://www.brendangregg.com/usemethod.html · Linux 清单 https://www.brendangregg.com/USEmethod/use-linux.html
- **Brendan Gregg — Thinking Methodically about Performance(ACM Queue)/ Systems Performance 2e** — https://queue.acm.org/detail.cfm?id=2413037 · https://www.brendangregg.com/systems-performance-2nd-edition-book.html · off-CPU https://www.brendangregg.com/offcpuanalysis.html
- **Donald Knuth — Structured Programming with go to Statements(profile-before-optimize)** — "过早优化是万恶之源…但别放过关键 3%"(注:Knuth 自述转引自 Hoare)— https://dl.acm.org/doi/10.1145/356635.356640

### 5.6 Swift / SwiftUI / macOS 专项

**静态分析与风格工具**
- **realm/SwiftLint** — 规范 Swift linter(100+ 规则,`swiftlint analyze` 支持整模块分析)— https://github.com/realm/SwiftLint · 规则文档 https://realm.github.io/SwiftLint/
- **nicklockwood/SwiftFormat** — 主流格式化器 + Xcode 扩展(自动改而非只报)— https://github.com/nicklockwood/SwiftFormat
- **apple/swift-format** — 苹果官方格式化/lint(对齐 API Design Guidelines)— https://github.com/swiftlang/swift-format
- **peripheryapp/periphery** — 死代码/未用声明检测(比 Xcode 内建更深)— https://github.com/peripheryapp/periphery
- **danger/swift** — PR 自动化(`Dangerfile.swift` 在 CI 跑评审杂务)— https://github.com/danger/swift · https://danger.systems/swift/ · Danger 插件 https://github.com/danger/awesome-danger
- 参考:NSHipster "Swift Code Formatters" — https://nshipster.com/swift-format/
- **推荐 CI 组合**:SwiftFormat(格式)+ SwiftLint 含 analyze(风格/质量)+ Periphery(死代码),经 Danger Swift 内联到 PR。

**SwiftUI 性能与正确性**
- **WWDC21 Demystify SwiftUI** — 视图身份(结构 vs 显式)、生命周期、依赖 — https://developer.apple.com/videos/play/wwdc2021/10022/
- **WWDC23 Demystify SwiftUI performance** — 更新流程、依赖、降低每次更新成本、list/table 身份、避免卡顿 — https://developer.apple.com/videos/play/wwdc2023/10160/
- **WWDC25 Optimize SwiftUI performance with Instruments** — 新 SwiftUI Instruments 模板(Effect/Update 图看 body 重算)— https://developer.apple.com/videos/play/wwdc2025/306/
- **Apple Docs — Understanding and improving SwiftUI performance** — 依赖、`Self._printChanges()`、最小化 body 工作 — https://developer.apple.com/documentation/Xcode/understanding-and-improving-swiftui-performance
- **WWDC23 Discover Observation in SwiftUI** — `@Observable` 宏:按属性追踪,减少无谓失效 — https://developer.apple.com/videos/play/wwdc2023/10149/
- **Apple Docs — 迁移到 Observable 宏** — 去 `ObservableObject`/`@Published`,`@ObservedObject`→`@Bindable`,`@EnvironmentObject`→`@Environment` — https://developer.apple.com/documentation/swiftui/migrating-from-the-observable-object-protocol-to-the-observable-macro
- **WWDC20 Data Essentials in SwiftUI** — 数据源真相模型(`@State`/`@Binding`/`@StateObject` 语义)— https://developer.apple.com/videos/play/wwdc2020/10040/
- **Airbnb Eng — Understanding and improving SwiftUI performance(Cal Stephens)** — 诊断过度重渲染、`EquatableView`/`.equatable()`、昂贵 body、LazyVStack 陷阱 — https://medium.com/airbnb-engineering/understanding-and-improving-swiftui-performance-37b77ac61896

**Swift 并发(Swift 6 严格并发)**
- **Swift.org — Concurrency Migration Guide** — 官方渐进迁移(minimal→targeted→complete→Swift 6)— https://www.swift.org/migration/ · 源 https://github.com/swiftlang/swift-migration-guide
- **Apple — Adopting strict concurrency in Swift 6 apps** — 逐 target 采用、开 complete checking、与未迁移模块互操作 — https://developer.apple.com/documentation/swift/adoptingswift6
- **WWDC22 Eliminate data races using Swift Concurrency** — actor、隔离域、`Sendable`、跨边界传值 — https://developer.apple.com/videos/play/wwdc2022/110351/
- **Swift Concurrency Proposal Index(论坛)** — https://developer.apple.com/forums/thread/768776
- 关键提案:SE-0306 Actors https://github.com/swiftlang/swift-evolution/blob/main/proposals/0306-actors.md · SE-0302 Sendable https://github.com/swiftlang/swift-evolution/blob/main/proposals/0302-concurrent-value-and-concurrent-closures.md · SE-0304 Structured Concurrency https://github.com/swiftlang/swift-evolution/blob/main/proposals/0304-structured-concurrency.md · SE-0337 增量迁移 https://github.com/swiftlang/swift-evolution/blob/main/proposals/0337-support-incremental-migration-to-concurrency-checking.md · SE-0412 全局变量严格并发 https://github.com/swiftlang/swift-evolution/blob/main/proposals/0412-strict-concurrency-for-global-variables.md · 全列表 https://www.swift.org/swift-evolution/
- ⚠️ 对本 renderer:审查是否有重的每帧 CPU 工作被无谓 `@MainActor` 隔离(见 memory:双屏串行渲染根因)。

**内存与 ARC**
- **Apple — Automatic Reference Counting(TSPL)** — strong/`weak`/`unowned`、闭包捕获列表、破环 — https://docs.swift.org/swift-book/documentation/the-swift-programming-language/automaticreferencecounting/
- **WWDC24 Analyze heap memory** — 堆增长/被遗弃内存/泄漏的新 Instruments 流程 — https://developer.apple.com/videos/play/wwdc2024/10173/
- **Apple — `autoreleasepool(invoking:)`** — 内存密集循环里界定峰值占用(每帧纹理/图片分配相关)— https://developer.apple.com/documentation/swift/autoreleasepool(invoking:)
- 参考:An Exhaustive Look At Memory Management in Swift — http://marksands.github.io/2018/05/15/an-exhaustive-look-at-memory-management-in-swift.html
- ⚠️ 对本 app:审查纹理/图片常驻与每帧分配(Allocations + Leaks;在解码/上传循环外包 `autoreleasepool`)。

**Xcode 编译时优化**
- **Apple — Improving the speed of incremental builds** — https://developer.apple.com/documentation/xcode/improving-the-speed-of-incremental-builds
- **`-Xfrontend -warn-long-function-bodies=<ms>` / `-warn-long-expression-type-checking=<ms>`** — 标出类型检查超阈值的函数/表达式(查昂贵类型推断的经典手段)
- **fastred/Optimizing-Swift-Build-Times** — 社区标准参考(两个 warn-long flag、WMO、类型推断成本、ACL、减依赖)— https://github.com/fastred/Optimizing-Swift-Build-Times
- **Jesse Squires — Measuring Swift compile times** — https://www.jessesquires.com/blog/2017/09/18/measuring-compile-times-xcode9/
- **On Swift Wings — Build Time Optimization** — Build With Timing Summary 工作流 — https://www.onswiftwings.com/posts/build-time-optimization-part1/
- ⚠️ 落地:Debug 开两个 warn-long flag;显式类型/中间变量降推断成本;Release 用 WMO;补显式 ACL(`private`/`final`);拆 god-file + 模块化并行编译(见下)。

**大型 Swift app 模块化 / 架构**
- **pointfreeco/isowords** — 真实世界把大 app 拆成 ~86–91 个 SPM 模块的范例 — https://github.com/pointfreeco/isowords
- **Point-Free — Modularization 系列 + A Tour of isowords** — 拆模块的边界与构建/预览收益 — https://www.pointfree.co/episodes/ep171-modularization-part-1 · https://www.pointfree.co/blog/posts/57-a-tour-of-isowords
- **swift-composable-architecture(TCA)** — 可组合/可测/模块化的状态架构库 — https://github.com/pointfreeco/swift-composable-architecture
- **Swift Package Manager(官方)** — 多 target/product 的边界机制 — https://www.swift.org/documentation/package-manager/
- **Nimble — Modularizing iOS Apps with SwiftUI and SPM** — Core 层 + 独立 Feature 模块(feature 依赖 core、不互依)— https://nimblehq.co/blog/modern-approach-modularize-ios-swiftui-spm
- **DECODE — Modularize with SPM** — 依赖图设计、避免环、增量抽取 — https://decode.agency/article/project-modularization-swift-package-manager/
- ⚠️ 契合本项目已有的 Lite/Pro SPM 拆分方向。

**macOS 资源效率**
- **Energy Efficiency Guide for Mac Apps** — 权威能耗指南(App Nap、定时器、后台调度、QoS)— https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/index.html
  - Minimize Timer Usage — https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/Timers.html
  - Schedule Background Activity(`NSBackgroundActivityScheduler`)— https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/SchedulingBackgroundActivity.html
  - Extend App Nap(壁纸常被遮挡时throttle,关键)— https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/AppNap.html
  - Prioritize Work at the Task Level(QoS)— https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/PrioritizeWorkAtTheTaskLevel.html
- **`CVDisplayLink`** — 显示同步回调,优于自由定时器;遮挡/休眠时暂停 — https://developer.apple.com/documentation/corevideo/cvdisplaylink-k0k
- **App Sandbox** — 权限/容器/安全作用域(Workshop/Steam 文件访问相关)— https://developer.apple.com/documentation/security/app-sandbox
- ⚠️ 对壁纸 app 的效率抓手:用 `CVDisplayLink` 驱动渲染(非 NSTimer);**遮挡/全屏游戏/显示器休眠时暂停或降频**(契合 GameModeDetector / App Nap);合并定时器加 tolerance;I/O 走后台调度 + 合适 QoS;用 Activity Monitor Energy 页 + Instruments 能耗计量。

### 5.7 LLM 辅助评审的 Prompt 设计

- **@trq212 —《A Field Guide to Fable: Finding Your Unknowns》(一手,规划方法论核心)** — Claude Code 核心研发的 Fable 5 实战:地图≠疆域、未知的四象限、盲区扫描/头脑风暴/访谈/参考/实施计划/实施笔记/交付物打包/事后测验 8 技法。**本框架 Phase -1/Phase 5 书挡的直接依据**;提炼见 [`fable5-planning-architecture.md`](fable5-planning-architecture.md) — 中译 https://x.com/Lonely__MH/status/2073261408985497994
- **@trq212 —《Using Claude Code: The Unreasonable Effectiveness of HTML》(一手,交付格式核心)** — 为什么 agent 产出的规格/计划/报告默认用 HTML 而非 markdown:信息密度/可读性/可分享/**双向交互**(copy-as-prompt 回灌)/数据摄取;含代码审查 HTML 用例(渲染 diff+行内批注+严重度着色)。**本框架 §4.5 的依据** — https://x.com/trq212/status/2052809885763747935 · 示例集 https://thariqs.github.io/html-effectiveness/
- **Anthropic — Prompting best practices(Claude 官方)** — 用 XML 标签分隔 `<instructions>/<context>/<input>`、角色 prompt、few-shot 结构化输出 — https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/claude-prompting-best-practices
- **Anthropic — Long-context prompting tips** — 把长输入(diff/文件,20k+ token)放最上、query 在下;先抽相关引文再答,提升召回 — https://www.anthropic.com/news/prompting-long-context
- **Anthropic — Effective context engineering for AI agents** — 找"最小高信号 token 集"(别把整库塞进评审 prompt)— https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents
- **Anthropic — Claude Code best practices** — 子 agent 隔离评审、research→plan→execute→review 循环、上下文窗管理 — https://code.claude.com/docs/en/best-practices
- **GitHub — Copilot code review docs + prompt files** — 现成"资深工程师彻底评审"prompt 模板 + `copilot-instructions.md`/路径级 `*.instructions.md` 做 rubric 评审 — https://docs.github.com/en/copilot/concepts/agents/code-review · https://docs.github.com/en/copilot/tutorials/customization-library/prompt-files/review-code · https://github.blog/ai-and-ml/unlocking-the-full-power-of-copilot-code-review-master-your-instructions-files/
- **SWE-PRBench(arXiv 2026)** — 关键实证:前沿模型在纯 diff prompt 上只发现人类标注问题的 ~15–31%;**加更多上下文会因注意力稀释而全线变差**;结构化 2k-token "diff+summary" 胜过 2.5k 全上下文 —— 强证据支持"限定范围、结构化"的评审 prompt — https://arxiv.org/pdf/2603.26130
- **CodeReviewer(arXiv 2203.09095,微软)** — 把代码评审建模为质量估计/评论生成/代码精修三任务,提出 CodeReviewer 数据集 — https://arxiv.org/abs/2203.09095 · 模型卡 https://huggingface.co/microsoft/codereviewer
- **Prompting and Fine-tuning LLMs for Review Comment Generation(arXiv 2411.10129)** — 直接比较 prompting 策略 vs 微调 — https://arxiv.org/abs/2411.10129
- **Automated Code Review Using LLMs at Ericsson(arXiv 2507.19115)** — 工业经验:轻量 LLM + 静态分析的真实评审工具的 prompt/pipeline 教训 — https://arxiv.org/abs/2507.19115
- **LLaMA-Reviewer(arXiv 2308.11148)** — 参数高效微调做评审自动化(微调 vs prompting 的取舍)— https://arxiv.org/abs/2308.11148
- **LLM-as-a-Judge 综述** — rubric 评分与一致性/偏差缓解的方法论根基 — https://arxiv.org/abs/2411.15594 · https://arxiv.org/abs/2412.05579 · 资源集 https://github.com/CSHaitao/Awesome-LLMs-as-Judges
- **Rubric Is All You Need(arXiv 2503.23989,ICER 2025)** — 题目/任务特定 rubric 胜过通用 rubric — https://arxiv.org/abs/2503.23989
- **CRScore / DeepCRCEval(arXiv)** — 如何"评估"生成评审评论的质量(claims + code smells)— https://arxiv.org/pdf/2409.19801 · https://arxiv.org/pdf/2412.18291
- **实践博客** — Cloudflare "Orchestrating AI code review at scale" https://blog.cloudflare.com/ai-code-review/ · Datadog "Detecting malicious PRs at scale with LLMs" https://www.datadoghq.com/blog/engineering/malicious-pull-requests/ · Simon Willison "How I use LLMs to help me write code" https://simonw.substack.com/p/how-i-use-llms-to-help-me-write-code · Promptfoo LLM Rubric https://www.promptfoo.dev/docs/configuration/expected-outputs/model-graded/llm-rubric/

### 5.8 Metal / GPU 渲染性能评审

**Metal 最佳实践**
- **Optimizing GPU performance(官方,评审 Metal 段首选起点)** — 调度、避免 pass 串行、存储模式、shader 调优、Metal System Trace/debugger — https://developer.apple.com/documentation/xcode/optimizing-gpu-performance/
- **Metal Best Practices Guide(archive)** — 资源选项/CPU-GPU 并行/load-store/绑定/PSO — https://developer.apple.com/library/archive/documentation/3DDrawing/Conceptual/MTLBestPracticesGuide/ · Resource Options https://developer.apple.com/library/archive/documentation/3DDrawing/Conceptual/MTLBestPracticesGuide/ResourceOptions.html · Indirect Buffers https://developer.apple.com/library/archive/documentation/3DDrawing/Conceptual/MTLBestPracticesGuide/IndirectBuffers.html
- **Synchronizing CPU and GPU work** — 三缓冲 + 信号量避免 stall — https://developer.apple.com/documentation/Metal/synchronizing-cpu-and-gpu-work
- **Argument buffers(降每-draw 绑定开销)** — https://developer.apple.com/documentation/metal/improving-cpu-performance-by-using-argument-buffers · 与 heap 结合(bindless)https://developer.apple.com/documentation/Metal/using-argument-buffers-with-resource-heaps · Go bindless with Metal 3(WWDC22-10101)https://developer.apple.com/videos/play/wwdc2022/10101/
- **Indirect Command Buffers(CPU/GPU 编码)** — https://developer.apple.com/documentation/Metal/encoding-indirect-command-buffers-on-the-cpu · https://developer.apple.com/documentation/Metal/encoding-indirect-command-buffers-on-the-gpu
- **Delivering Optimized Metal Apps and Games(WWDC19-606)** — 端到端优化流程 — https://developer.apple.com/videos/play/wwdc2019/606/

**Apple TBDR 架构(tile 内存 / load-store / tile shader / memoryless)**
- **Harness Apple GPUs with Metal(WWDC20-10602,TBDR 权威入门)** — 分块/渲染两阶段、隐面剔除、programmable blending、memoryless、tile shader/imageblock、高效 MSAA — https://developer.apple.com/videos/play/wwdc2020/10602/
- **Optimize Metal Performance for Apple silicon Macs(WWDC20-10632)** — https://developer.apple.com/videos/play/wwdc2020/10632/ · **Bring your Metal app to Apple silicon Macs(WWDC20-10631)** — https://developer.apple.com/videos/play/wwdc2020/10631/
- **Tailor your apps for Apple GPUs and TBDR(官方文档)** — 利用 tile 内存、on-chip imageblock、load/store action — https://developer.apple.com/documentation/metal/tailor-your-apps-for-apple-gpus-and-tile-based-deferred-rendering
- **Optimize high-end games for Apple GPUs(WWDC21-10148)** — https://developer.apple.com/videos/play/wwdc2021/10148/ · **Modern Rendering with Metal(WWDC19-601)** — https://developer.apple.com/videos/play/wwdc2019/601/
- 注:`.memoryless`(`MTLStorageModeMemoryless`)适用于单 pass 内产生并消费的瞬态附件(MSAA resolve、depth/stencil、tile-local 中间 buffer)—— 直接对应本 app 的 FBO 内存削减。

**macOS GPU profiling 工具**
- **Capturing a Metal workload in Xcode** — GPU frame capture,选 scope — https://developer.apple.com/documentation/xcode/capturing-a-metal-workload-in-xcode · **Metal debugger** https://developer.apple.com/documentation/xcode/metal-debugger
- **Monitoring your Metal app's graphics performance(perf HUD)** — https://developer.apple.com/documentation/xcode/monitoring-your-metal-apps-graphics-performance/
- **GPU Counters instrument + Optimize with GPU counters(WWDC20-10603,limiter 分析)** — ALU/texture-sample/bandwidth 限制器 — https://developer.apple.com/documentation/metal/optimizing_performance_with_the_gpu_counters_instrument · https://developer.apple.com/videos/play/wwdc2020/10603/
- **Gain insights with Xcode 12(WWDC20-10605,Metal System Trace)** — https://developer.apple.com/videos/play/wwdc2020/10605/ · **Discover Metal debugging/profiling(WWDC21-10157,GPU Timeline)** — https://developer.apple.com/videos/play/wwdc2021/10157/
- **New Metal profiling tools for M3/A17 Pro(Tech Talk 111374)** — shader cost 图/热力图/执行历史 — https://developer.apple.com/videos/play/tech-talks/111374/ · **Metal tools hub** https://developer.apple.com/metal/tools/
- **os_signpost 自定义插桩(对应本 app 的 `WPECanonicalTraceRecorder`)** — Measuring Performance Using Logging(WWDC18-405)https://developer.apple.com/videos/play/wwdc2018/405/ · Creating Custom Instruments(WWDC18-410)https://developer.apple.com/videos/play/wwdc2018/410/ · Eclectic Light 实操 https://eclecticlight.co/2018/07/24/signposts-for-performance-2-instruments/

**Shader 优化(MSL / 精度 / ALU / 分支 / 带宽)**
- **Advanced Metal Shader Optimization(WWDC16-606,关键)** — `half`/`short` vs `float`(A8+ 16 位寄存器)、地址空间、ALU 流水、`-ffast-math` — https://developer.apple.com/videos/play/wwdc2016/606/ · 文字版 https://asciiwwdc.com/2016/sessions/606
- **Learn performance best practices for Metal shaders(Tech Talk 111373)** — 用近似/LUT 降 ALU、mipmap+bilinear 优于 trilinear、降各向异性、纹理压缩、16 位类型提高占用率 — https://developer.apple.com/videos/play/tech-talks/111373/
- **Optimize GPU renderers with Metal(WWDC23-10127)** — 提高并行度/资源利用、光追硬件 — https://developer.apple.com/videos/play/wwdc2023/10127/
- **Metal Shading Language Specification(PDF)** — 数据类型、地址空间、function constants(用特化消除动态分支)— https://developer.apple.com/metal/Metal-Shading-Language-Specification.pdf
- 要点:32 位类型占 2× 寄存器/带宽/功耗;算术优先 `half`/`short`;用 function constants 消动态分支;texture-sample 限制器缓解 = mipmap / bilinear / 降采样数 / 小像素格式 / 压缩。

**帧节奏 / 显示同步**
- **Optimize for variable refresh rate displays(WWDC21-10147)** — ProMotion/自适应同步、`presentAfterMinimumDuration` 稳定节奏、选目标 FPS — https://developer.apple.com/videos/play/wwdc2021/10147/
- **MTKView.preferredFramesPerSecond** — https://developer.apple.com/documentation/metalkit/mtkview/preferredframespersecond
- **CVDisplayLink Doesn't Link To Your Display(Tristan Hume)** — 重要坑:CVDisplayLink 是刷新率派生定时器、非真 vsync,多屏尤需注意 — https://thume.ca/2017/12/09/cvdisplaylink-doesnt-link-to-your-display/
- **多屏 stutter(Apple 论坛 112468)** — https://developer.apple.com/forums/thread/112468 · MTKView 全屏 stutter(733033)https://developer.apple.com/forums/thread/733033
- 要点:MTKView 默认三缓冲 → 用信号量把在飞帧压到 ~3;**静态内容用按需重绘**(`isPaused`/`enableSetNeedsDisplay` 或 gate display link),别渲染相同帧 —— 壁纸 app 的核心"浪费帧"问题。

**全应用资源 profiling**
- **Improving your app's performance(文档 hub)** — model→measure→boost、MetricKit、hitch — https://developer.apple.com/documentation/xcode/improving-your-app-s-performance
- **Analyze heap memory(WWDC24-10173)** — dirty vs clean/footprint、堆分析、什么计入内存上限 — https://developer.apple.com/videos/play/wwdc2024/10173/
- 要点:Time Profiler(CPU 热点)/ Allocations(分配历史/增长)/ Leaks(环)/ Energy Log(壁纸持续运行,能耗关键);设显式预算:稳态 footprint 上限、能耗目标、每帧 GPU 时间(16.6ms@60Hz / 8.3ms@120Hz)。

**通用 GPU 代码评审清单(跨厂商同理)**
- **Vulkan Render Passes 最佳实践** — load/store:瞬态附件用 `DONT_CARE`/`CLEAR`;未用附件仍耗带宽(直接映射 Metal)— https://docs.vulkan.org/samples/latest/samples/performance/render_passes/README.html · Samsung 讲解 https://developer.samsung.com/galaxy-gamedev/resources/articles/renderpasses.html
- **Android GPU Inspector — 识别最贵 render pass** — https://developer.android.com/agi/frame-trace/renderpasses · CPU/GPU 优化(消冗余 pass/draw)https://developer.android.com/games/optimize/optimization-tips
- **AMD RDNA Performance Guide** — 资源生命周期/同步/精度/overdraw 的评审清单 — https://gpuopen.com/learn/rdna-performance-guide/
- **Metal Resource Heaps(`MTLHeap` + `makeAliasable`)** — 非重叠 target 共享 heap 削 FBO/纹理内存(本 app 已用)— https://developer.apple.com/library/archive/documentation/Miscellaneous/Conceptual/MetalProgrammingGuide/ResourceHeaps/ResourceHeaps.html
- **提炼的评审要点**:①冗余 pass(整场景后被全覆盖、可合并的 copy/blit、小 UI 层跑全分辨率)②load/store action(仅需时 `.load`,否则 `.clear`/`.dontCare`;瞬态用 memoryless)③资源生命周期/超额分配(aliasing、避免每帧分配大纹理、空闲资产 purgeable、纹理 LRU 预算)④同步(热路径无 `waitUntilCompleted`,用信号量/`MTLFence`/`MTLEvent`)⑤精度(能用 `half` 不用 `float`)⑥分支(function constants 替动态分支)⑦带宽(mipmap/压缩/小格式/避免大 MRT)⑧提交(按材质/PSO 批,粒子用 instanced draw,ICB 降 CPU 编码)。
- 说明:本 app 的 FBO aliasing / memoryless depth / 纹理 LRU / off-thread transpile 预热 / os_signpost trace 每项都能对应上面一条官方背书,review 时引用即可。

### 5.9 LLM 多 Agent 编排(评审用 —— Fable 5 调度的理论与蓝图)

**Orchestrator + Worker 模式(§3 的核心依据)**
- **Anthropic — Building Effective Agents(一手,必读)** — 5 种工作流分类:prompt chaining / routing / parallelization(sectioning+voting)/ **orchestrator-workers** / evaluator-optimizer;orchestrator-workers 专为"子任务数不可预测(如一个改动触及几个文件)"设计,正是全库 review 的形态 — https://www.anthropic.com/engineering/building-effective-agents
- **Anthropic — How we built our multi-agent research system(一手,必读)** — 生产级 orchestrator-worker:**lead(Opus)分解 → subagent(Sonnet)各带"目标/输出格式/工具指引/边界" → 专职 CitationAgent 收尾**;按复杂度缩放 effort;并行 spawn 3–5;LLM-as-judge rubric;**多 agent ≈ 15× 聊天 token** — https://www.anthropic.com/engineering/multi-agent-research-system
- **Cloudflare Agents — Anthropic patterns 参考实现** — https://github.com/cloudflare/agents/blob/main/guides/anthropic-patterns/README.md
- **LangGraph supervisor / 层级多 agent** — supervisor 持全局状态、分解、派发、随结果更新计划 — https://langchain-ai.github.io/langgraph/tutorials/multi_agent/agent_supervisor/
- **CrewAI(角色化 agent 团队)** https://docs.crewai.com/ · **AutoGen/AG2(GroupChat 选择器)** https://microsoft.github.io/autogen/
- **Map-Reduce over codebase** — map:token-限定分块独立审;reduce:聚合成结构化输出;层级合并(函数→文件→包)— https://cloud.google.com/blog/products/ai-machine-learning/long-document-summarization-with-workflows-and-gemini-models

**生产级 AI 代码评审系统(如何切块/取上下文/组织通道)**
- **CodeRabbit 流水线拆解(与 §3 的 Fable5 策略最接近的蓝图)** — 4 阶段:①便宜模型压 10–15 路上下文 ②规划模型建 task-graph ③生成 shell/`ast-grep` 校验落地假设 ④**独立 judge 模型给每条发现打分、丢无证据的**;80–90% token 花在上下文富化 — https://theaiengineer.substack.com/p/how-coderabbit-actually-works · 官方 https://docs.coderabbit.ai/ · 大库上下文工程 https://www.coderabbit.ai/blog/how-coderabbit-delivers-accurate-ai-code-reviews-on-massive-codebases
- **Greptile — 语义代码图** — 全库函数/类/调用关系/import 链图,PR 到达时多跳调查 — https://www.greptile.com/docs/how-greptile-works/graph-based-codebase-context · TREX 沙盒执行 https://www.greptile.com/blog/trex-code-execution
- **Qodo Merge / PR-Agent(开源,用 RAG 拉 diff 外相关代码)** — https://github.com/qodo-ai/pr-agent
- **GitHub Copilot code review(agentic:工具调用主动探索仓库再评论)** — https://docs.github.com/en/copilot/concepts/agents/code-review · 自定义指令 https://docs.github.com/en/copilot/tutorials/use-custom-instructions
- **Graphite Diamond/Agent** https://graphite.com/blog/series-b-diamond-launch · **Sweep(issue→PR worker 模式)** https://sweep.dev/ · 工具横评(bug 命中率 Greptile~82%/Qodo~60%F1/CodeRabbit~44%)https://www.greptile.com/content-library/best-ai-code-review-tools

**多 agent 代码评审论文**
- **CodeAgent(有监督 QA-Checker agent 保证不跑题)** — 直接对应 orchestrator+验证设计 — https://arxiv.org/abs/2402.02172
- **BitsAI-CR(字节,生产:RuleChecker→ReviewFilter 两阶段 + 数据飞轮,控精度/假阳性)** — https://arxiv.org/pdf/2501.15134
- **RepoReviewer(本地优先多 agent,分:采集→建上下文→文件级审→优先级→报告 —— 与目标设计最像)** — https://arxiv.org/pdf/2603.16107
- **CodeReviewer(微软,评审=质量估计/评论生成/代码精修三任务 + 数据集)** — https://arxiv.org/abs/2203.09095 · **SWR-Bench**(1000 真实 PR 全项目上下文)https://arxiv.org/pdf/2509.01494 · **Sphinx**(PR 评审基准)https://arxiv.org/pdf/2601.04252
> ⚠️ 部分 arXiv 编号是未来日期式(2603.*/2606.*/2601.*),为搜索所得线索,正式引用前请先核实摘要页与作者。

**LLM-as-Judge 与对抗验证(§3.2 judge 设计)**
- **A Survey on LLM-as-a-Judge** — 如何造可靠 judge(一致性、去偏)— https://arxiv.org/abs/2411.15594 · companion https://github.com/llm-as-a-judge/Awesome-LLM-as-a-judge
- **Self-Consistency(采样多路径 + 多数投票,投票确认发现的基础)** — https://arxiv.org/abs/2203.11171
- **Nine Judges, Two Effective Votes(判官集成有相关性误差,更多 judge ≠ 更多信号 —— 用 3 异视角而非 9 同质)** — https://arxiv.org/pdf/2605.29800
- **Beyond Consensus(judge 有"随和偏差",倾向接受无效输出 —— 故 judge 必须默认反驳)** — https://arxiv.org/html/2510.11822v1 · **One Token to Fool LLM-as-a-Judge**(judge 对抗脆弱性)https://arxiv.org/pdf/2507.08794
- 实践:Monte Carlo "LLM-as-Judge 7 best practices" https://montecarlo.ai/blog-llm-as-judge/ · Datadog 幻觉检测 https://www.datadoghq.com/blog/ai/llm-hallucination-detection/

**模型路由 / 成本优化(§3.2 cascade 依据)**
- **FrugalGPT(prompt 适配 / LLM 近似 / **LLM 级联** cheap→escalate,最高省 98% 成本匹配 GPT-4)** — https://arxiv.org/abs/2305.05176
- **RouteLLM(训练/服务路由器按 query 选强/弱模型,~85% 成本降、~95% GPT-4 质量)** — https://github.com/lm-sys/RouteLLM
- **Dynamic Model Routing and Cascading 综述(区分 routing 单次 vs cascading 递升)** — https://arxiv.org/html/2603.04445v1
- 何时用专用编码模型:Copilot(agentic 仓库探索)/ Sweep(issue→PR)= 把难的代码编辑/追踪交给编码模型,便宜模型压上下文(CodeRabbit 的 cheap-compress + strong-review 分工)。

**Prompting 提升评审质量(§4 模板依据)**
- **Anthropic 多 agent 的委派 & rubric prompting** — 给每 worker "目标/输出格式/工具指引/边界";rubric judge 打分 0.0–1.0 — https://www.anthropic.com/engineering/multi-agent-research-system
- **GitHub Copilot 指令文件(`.github/copilot-instructions.md` = checklist 驱动评审)** — https://github.blog/ai-and-ml/github-copilot/unlocking-the-full-power-of-copilot-code-review-master-your-instructions-files/
- **结构化 JSON 输出降幻觉 + 证据引文接地** — https://www.promptfoo.dev/docs/guides/evaluate-json/ · Datadog ground-in-quotes https://www.datadoghq.com/blog/ai/llm-hallucination-detection/
- **SWE-PRBench(关键实证:纯 diff 只测出 15–31% 人类问题;加更多上下文因注意力稀释全线变差;结构化 2k 胜 2.5k 全上下文)** — https://arxiv.org/pdf/2603.26130
- **Rubric Is All You Need(任务特定 rubric 胜通用 rubric)** — https://arxiv.org/abs/2503.23989

**大库上下文管理(§3.3 依据)**
- **Aider — repomap(tree-sitter 抽 defs/refs + personalized PageRank 排序 + token 预算内渲染)** — 规范做法 — https://aider.chat/2023/10/22/repomap.html · docs https://aider.chat/docs/repomap.html · 独立实现 https://github.com/pdavis68/RepoMapper
- **CodeRAG / GraphCodeAgent(repo 级检索)** — https://arxiv.org/abs/2509.16112 · https://arxiv.org/abs/2504.10046
- 增量/diff-scoped:CodeRabbit 把 4000 行文件压到改动触及的几个函数 — https://theaiengineer.substack.com/p/how-coderabbit-actually-works

**长任务:批处理/并行/去重/收敛(§2.2 依据)**
- **Anthropic 多 agent 并行 + effort budget** — 并行 spawn(降 90% 时间)+ 显式预算防超发 + loop 至充分后收口 — https://www.anthropic.com/engineering/multi-agent-research-system
- **evaluator-optimizer 循环("loop until dry"原语)** — https://www.anthropic.com/engineering/building-effective-agents
- **BitsAI-CR ReviewFilter(发帖前去重/抑制低精度评论)** = 跨 agent 去重步 — https://arxiv.org/pdf/2501.15134

### 5.10 UI/UX 与设计语言评审

**可用性启发式评估**
- **10 Usability Heuristics(NN/g,Jakob Nielsen,业界标准)** — 揭示可用性问题的十条经验法则 — https://www.nngroup.com/articles/ten-usability-heuristics/
- **How to Conduct a Heuristic Evaluation(NN/g)** — 方法:3–5 名独立评估者、限时、界定范围、对照十启发 — https://www.nngroup.com/articles/how-to-conduct-a-heuristic-evaluation/
- **10 Heuristics Applied to Complex Applications(NN/g)** — 扩展到企业/功能密集软件 — https://www.nngroup.com/articles/usability-heuristics-complex-applications/
- **UX Expert Reviews(NN/g)** — 专家评审法,补充启发式评估 — https://www.nngroup.com/articles/ux-expert-reviews/

**设计系统 / 一致性审计**
- **Interface Inventory(Brad Frost,原文)** — 截图并归类每个 UI 组件,是设计系统/UI 审计的第一步 — https://bradfrost.com/blog/post/interface-inventory/ · 实操 https://bradfrost.com/blog/post/conducting-an-interface-inventory/ · Atomic Design Ch.4 https://atomicdesign.bradfrost.com/chapter-4/
- **Design Systems 101(NN/g)** — 设计系统=规模化管理设计的完整标准集 — https://www.nngroup.com/articles/design-systems-101/
- **Consistency and Standards — Heuristic #4(NN/g)** — 内/外一致性深挖,"设计语言一致性"评审的载荷点 — https://www.nngroup.com/articles/consistency-and-standards/
- **Your Design System Needs an Enforcer(NN/g)** — 治理:无否决权的一致性审计会失败(对应本 app token 绕过)— https://www.nngroup.com/articles/design-system-enforcer/
- **Design Tokens Community Group(W3C)** https://www.w3.org/community/design-tokens/ · **DTCG Format Module(2025.10 首个稳定版,token 的权威定义)** https://www.w3.org/community/reports/design-tokens/CG-FINAL-format-20251028/ · **命名最佳实践(Smashing,可当 token 审计 rubric)** https://www.smashingmagazine.com/2024/05/naming-best-practices/

**无障碍(WCAG)**
- **How to Meet WCAG(Quick Reference,W3C WAI,可过滤清单)** — https://www.w3.org/WAI/WCAG22/quickref/ · **WCAG 2.2 规范** https://www.w3.org/TR/WCAG22/
- **WebAIM WCAG 2 Checklist(平实可执行版)** — https://webaim.org/standards/wcag/checklist · **Easy Checks(轻量首过)** https://www.w3.org/WAI/test-evaluate/preliminary/ · **WCAG-EM(正式审计方法)** https://www.w3.org/WAI/test-evaluate/conformance/wcag-em/
> 说明:本 app 有明确的"flat 内容卡 / glass 浮动 chrome / liquid-glass 小配件"设计规范(见 memory: UI/UX 统一)—— 用 Interface Inventory 抓 token 绕过与规范漂移,用 Heuristic #4 + Enforcer 治理落地。

### 5.11 功能取舍决策(add / keep / cut)

- **RICE(Intercom,原文)** — (Reach×Impact×Confidence)÷Effort — https://www.intercom.com/blog/rice-simple-prioritization-for-product-managers/
- **Kano 模型(完整指南,Folding Burritos)** — must-be/performance/attractive/indifferent/reverse 分类 + 问卷设计 — https://foldingburritos.com/blog/kano-model/ · 1984 原始论文 https://www.jstage.jst.go.jp/article/quality/14/2/14_KJ00002952366/_article/-char/en
- **People systematically overlook subtractive changes(Nature 2021)** — 人默认"加"、忽视"减" —— "功能减法/砍功能"的实证背书 — https://www.nature.com/articles/s41586-021-03380-y
- **Defeating Feature Fatigue(HBR 2006)** — "功能膨胀/featuritis":以可用性为代价堆能力导致疲劳 —— cut/keep 的权威依据 — https://hbr.org/2006/02/defeating-feature-fatigue
- **Outcome-Driven Innovation / Opportunity Algorithm(Ulwick)** — Opportunity=Importance+max(Importance−Satisfaction,0),识别欠服务 vs 过度服务 — https://en.wikipedia.org/wiki/Outcome-Driven_Innovation · 作者文 https://www.marketingjournal.org/the-path-to-growth-the-opportunity-algorithm-anthony-ulwick/ · Opportunity Scoring https://www.productplan.com/glossary/opportunity-scoring
- **Opportunity Solution Trees(Teresa Torres)** — outcome→opportunities→solutions→假设测试 — https://www.producttalk.org/opportunity-solution-trees/
- **MoSCoW(Agile Business Consortium/DSDM,Must/Should/Could/Won't,≤60% Must 工作量)** — https://www.agilebusiness.org/dsdm-project-framework/moscow-prioritisation.html
- **WSJF(SAFe:Cost of Delay ÷ Job Duration)** — https://framework.scaledagile.com/wsjf
- **Value vs. Effort Matrix(2×2:Quick Wins/Major/Fill-ins/Time Sinks)** — https://creately.com/guides/value-vs-effort-matrix/ · **多框架横评(Atlassian)** https://www.atlassian.com/agile/product-management/prioritization-framework
> 说明:对本 app 的 Playlist/Schedule stub、debug flag 转正 vs 删、Lite/Pro 功能边界,建议用 RICE 排序 + Kano 判"该功能是 must-be 还是 indifferent" + 减法优先(Nature 2021 / HBR 2006)。

---

## 6. 针对本 app 的落地路线图(具体到文件)

把 §2 维度 + §1 热点 + §3 调度落成可执行清单。**分级 = Critical/High 先修,Medium/Low 排 backlog(RICE/技术债象限)。** 建议每个大重构立一份 ADR(5.2)。

### 6.1 架构与重构(D1/D2/D5)—— 最高杠杆
- **[Critical] dispatcher 数据驱动化**:`WPEMetalShaderDispatcher.swift` 的 25 个 `switch(shaderName)` case → pass-graph 注册表(shader 名/uniform 布局/blend/format 抽成配置)。这是 memory 锁定的**唯一真正需重构的 renderer 核心**,解锁任意特效链/ping-pong/MRT/跨帧反馈。先立 ADR。
- **[High] 拆 `WPEMetalRenderExecutor`(5.7k)**:切成 `RenderState`(pipeline cache + FBO 池)/`FrameDispatcher`(编码)/`TextureResolver`(资产→MTLTexture)/`PuppetSkinning`(~2.4k 行蒙皮独立)。
- **[High] 拆 `ScreenManager`(2k)**:分 `AppStateManager`(存储/壁纸分配)+ `RuntimeOrchestrator`(帧驱动更新),定义清晰层协议。
- **[High] 拆 `HTMLWallpaperView`(1.4k)**:`HTMLContentController`(WebKit/scheme)与 `MetalParticleOverlay`(Metal 叠加)分离。
- **[Medium] transpiler 引入中间 IR**:`WPEShaderTranspiler` AST 直出 MSL → 加三地址码/字节码 IR,便于优化与测试(补 GLSL→MSL 用例)。
- **[Medium] Infra 归拢**:`WPESceneDocumentParser`/`WPEMdlParser`/`WallpaperEngineImportService` 是启动期用 → 移入 `Infrastructure/SceneImport/`。
- **[Medium] 巨石入包并行编译**:把上述拆分产物尽量沉进已有 5 个 SPM 包(尤其 `ProWPE`),缩短增量编译、稳定 SwiftUI 预览(5.6)。

### 6.2 质量与死代码(D2)
- **[High] Periphery 死代码扫描**:确认 `PlaylistSection/`、`ScheduleSection/` stub 的去留(接 6.6 功能取舍)。
- **[Medium] 特性开关收敛**:散落的 `WPEMetal…Enabled` UserDefaults → 类型化 `FeatureFlags` 注册表(每帧查 12+ 次 → 冻结读一次,memory 已有此模式)。
- **[Medium] 接 SwiftLint + SwiftFormat + Periphery,经 Danger 上 CI**(当前无 CI 入库)。

### 6.3 性能 / 资源(D3)—— 多为回归验证
- **[验证] 已落地优化回归**:FBO aliasing / memoryless depth / 纹理 LRU / off-thread transpile 预热 —— 用 §5.8 官方背书 + `WPECanonicalTraceRecorder` 出预算报告(每帧 GPU ≤16.6ms@60Hz)。
- **[High] 首帧 transpile 地板**:memory 已证首帧重成本 90–95% 是懒 GLSL→MSL transpile;确认预热默认开、覆盖热点场景。
- **[High] 遮挡/全屏游戏/休眠暂停**:壁纸常被遮挡 → App Nap 协作 + `CVDisplayLink` 遮挡时暂停/降频(5.6/5.8),接现有 GameModeDetector。
- **[Medium] 每帧 flag 查询下沉**、冗余 pass 审计(小 UI 层跑全分辨率 = memory 里 3660962877 的卡顿源)。

### 6.4 并发安全(D4)
- **[High] `@MainActor` 串行渲染**:确认重的每帧 CPU 工作未被无谓 MainActor 隔离(memory:双屏抢帧根因);逐步开 Swift 6 严格并发,补 `Sendable`。
- **[Medium] `[weak self]` 审计**:DisplayLink/定时器/闭包/Combine 订阅的保留环(memory 已记若干 SIGTRAP 教训)。

### 6.5 UI/UX 与设计语言(D6)
- **[High] Interface Inventory**:抓主 app Views 的 token 绕过(~68%),优先 `GeneralSettingsView`(1.5k)按域拆(DisplayDefaults/Shortcuts/DeveloperTools/Advanced)。
- **[Medium] 落地设计规范**:flat 内容卡 / glass 浮动 chrome / liquid-glass 配件的一致性(Heuristic #4 + Enforcer 治理)。
- **[Medium] WCAG 首过**:对比度、键盘导航、触控/点击目标(WebAIM checklist)。

### 6.6 功能取舍(D7)与安全(D8)
- **[决策] Playlist/Schedule**:用 RICE + Kano 判"finish vs cut"(Nature 2021 减法优先;若是 indifferent 质量则删)。
- **[决策] debug flag**:哪些转正为正式设置、哪些删(减少每帧分支与认知负荷)。
- **[High/安全] 复用 `/verify-security` + 现有 `CSPAudit`/`EntitlementAudit`**:Steam 凭据接触面、沙盒权限最小化、HTML 壁纸 CSP(memory: Workshop 账号安全已有姿态盘点)。

### 6.7 执行顺序(与 §3 Fable 5 流水线对齐)
1. **Phase 0**:跑一次结构测绘 + git-churn hotspot 排序(本文 §1 已是初版);冻结 §2 rubric;设预算。
2. **Phase 1(Sonnet 广度)**:D2/D6/D7 全库初筛 + flag/死代码 grep + Interface Inventory。
3. **Phase 2(Codex 深度)**:§1 热点表逐个深审(D1/D3/D4),优先 dispatcher 与 Executor。
4. **Phase 3(Opus 对抗验证)**:逐条反驳,3 异视角,丢假阳性。
5. **Phase 4(Fable 5 综合)**:去重、按 严重度×ROI 排序、出报告 + 为 6.1 的 Critical/High 立 ADR。
6. **落地**:Critical/High 进本周期;Medium/Low 进 backlog;增量改动接 CCG 自动门(`/verify-change`→`/verify-quality`,安全→`/verify-security`)。

---

> 文档版本:v1.1(2026-07-05)。v1 由 8 路研究 agent(Anthropic/Apple/Swift.org/W3C/arXiv 一手源优先)+ 代码库结构测绘汇总,§5 参考库 ~130 条。**v1.1 依据 @trq212 两篇一手文章新增"未知优先"升级:Phase -1 盲区扫描(§2.2/§3.5)、Phase 5 理解验证 + HTML 双向 triage(§4.5),并补 §5.7 两条参考。通用规划方法论已抽成独立文档 [`fable5-planning-architecture.md`](fable5-planning-architecture.md)。** 后续可把 §1 热点表升级为 `git log` 驱动的 CodeScene 式 hotspot 自动排序。
