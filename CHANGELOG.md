## v1.1.14

![macOS](https://img.shields.io/badge/macOS-Supported-000000?style=flat-square&logo=apple) ![Version](https://img.shields.io/badge/Release-v1.1.14-10B981?style=flat-square) ![Channel](https://img.shields.io/badge/Channel-Stable-2563EB?style=flat-square)

> 这是一次聚焦 **SSD 写入收敛、运行期自愈与日志体验** 的稳定性版本。ClashBar 不再写入本地日志文件，日志展示继续保留内存可见性；同时新增本地“核心内存控制”策略，在内核内存达到指定阈值时自动复用现有重启流程，降低长期运行失控风险。

### 🧭 发布基线 (Release Baseline)

- 发布分支：`lovitus/clashbar-rev:beta`
- 发布方式：从当前 `beta` 分支提交打正式 tag，生成固定 Release 资产
- 发布目标：提供一版可长期使用的稳定快照，重点降低后台写盘与高内存异常对日常使用的影响

### 📝 更新日志 (Changelog)

**✨ 新增功能 (New Features)**

- ![Feature](https://img.shields.io/badge/Feature-10B981?style=flat-square) **核心内存控制**：在 System 页面新增本地设置项 `关闭 / 500MB / 1GB / 2GB / 5GB`，默认关闭；开启后仅对本机 `mihomo` 生效，不同步到远端控制目标，也不写入 `/configs`。
- ![Feature](https://img.shields.io/badge/Feature-10B981?style=flat-square) **高内存自动重启**：当本地 core 的 `/memory` 数据达到所选阈值时，ClashBar 会记录 warning 并复用现有 `restartCore()` 流程自动重启；触发尝试有 10 分钟冷却，避免重复重启风暴。
- ![Feature](https://img.shields.io/badge/Feature-10B981?style=flat-square) **内存守护角标**：Proxy 页面内存角标保留实时内存数值，并通过普通内存图标 / 有色盾牌图标区分是否启用本地内存守护；远端控制模式下不会显示本地守护态。

**🚀 优化改进 (Improvements)**

- ![Optimize](https://img.shields.io/badge/Optimize-3B82F6?style=flat-square) **彻底取消日志落盘**：删除 `AppLogStore` 与所有本地日志文件写入、创建、清空路径；`clashbar.log` / `mihomo.log` 不再由当前版本创建或更新，SSD 写入压力显著降低。
- ![Optimize](https://img.shields.io/badge/Optimize-3B82F6?style=flat-square) **保留内存日志可见性**：ClashBar 与 `mihomo` 的 stdout/stderr 采集仍然进入内存日志列表，启动失败、运行警告和错误仍可在当前会话内查看；点击清空日志只清空内存，不触碰磁盘。
- ![Optimize](https://img.shields.io/badge/Optimize-3B82F6?style=flat-square) **后台内存采集按需开启**：仅当本地 core 正在运行且“核心内存控制”非关闭时，后台强制保持 `/memory` stream；关闭该功能时仍沿用原有按 UI 可见性采集策略。
- ![Optimize](https://img.shields.io/badge/Optimize-3B82F6?style=flat-square) **日志筛选范围修正**：日志展示先基于完整内存日志执行 source / level / keyword 筛选，再截断展示结果，避免较旧但仍在内存中的命中项被提前截掉。

**🐞 修复问题 (Bug Fixes)**

- ![Fix](https://img.shields.io/badge/Fix-EF4444?style=flat-square) **日志文件持续增长**：修复 info 级别或高频 core 输出导致 `mihomo.log` 长期增长、带来大量 SSD 写入的问题。
- ![Fix](https://img.shields.io/badge/Fix-EF4444?style=flat-square) **远端模式状态误导**：修复处于 remote target 时 Proxy 页面可能展示本地内存守护态的问题；远端模式下该图标始终回到普通内存显示。
- ![Fix](https://img.shields.io/badge/Fix-EF4444?style=flat-square) **守护态隐藏内存值**：修复启用内存控制后角标只显示“已守护 / Guarded”而看不到实时内存数值的问题。

## v1.1.13

![macOS](https://img.shields.io/badge/macOS-Supported-000000?style=flat-square&logo=apple) ![Version](https://img.shields.io/badge/Release-v1.1.13-10B981?style=flat-square) ![Channel](https://img.shields.io/badge/Channel-Stable-2563EB?style=flat-square)

> 这是一次从当前 `beta` 分支稳定快照切出的固定正式版本，不走滚动 `beta` 覆盖路径。重点补齐了远程订阅配置的状态可见性、定时更新与安全更新链路，同时继续修正连接详情显示和系统代理 Helper 兼容性问题。

### 🧭 发布基线 (Release Baseline)

- 发布分支：`lovitus/clashbar-rev:beta`
- 发布方式：从当前 `beta` 分支提交打正式 tag，生成固定 Release 资产
- 发布目标：保留一份不会被后续 `beta` 滚动覆盖的正式版本，便于持续自用

### 📝 更新日志 (Changelog)

**✨ 新增功能 (New Features)**

- ![Feature](https://img.shields.io/badge/Feature-10B981?style=flat-square) **远程订阅定时更新策略**：每个远程订阅配置都可以独立设置 `关闭 / 每1小时 / 每6小时 / 每12小时 / 每天` 的后台更新策略。
- ![Feature](https://img.shields.io/badge/Feature-10B981?style=flat-square) **配置菜单状态增强**：配置项菜单新增“文件变更时间 / 最后检查成功时间”两行状态展示，并为远程订阅提供单项刷新入口。

**🚀 优化改进 (Improvements)**

- ![Optimize](https://img.shields.io/badge/Optimize-3B82F6?style=flat-square) **远程订阅更新更安全**：单项刷新、批量刷新、定时刷新统一改为“先下载到临时文件，再执行 `mihomo -t` 校验，通过后才原子替换正式配置”，避免截断文件、坏 YAML 或语法错误直接污染当前可用配置。
- ![Optimize](https://img.shields.io/badge/Optimize-3B82F6?style=flat-square) **配置菜单可读性增强**：启用定时更新的订阅会直接在配置名后显示 `（每6小时更新）` 这类明确文案，不再只依赖小图标表达状态。
- ![Optimize](https://img.shields.io/badge/Optimize-3B82F6?style=flat-square) **连接详情信息补齐**：连接列表现在会显示真实规则类型，并在 `TCP/UDP` 后补上目标端口，减少排查时的信息缺口。

**🐞 修复问题 (Bug Fixes)**

- ![Fix](https://img.shields.io/badge/Fix-EF4444?style=flat-square) **刷新反馈状态竞争**：修复连续点击远程订阅刷新时，旧的清理任务提前清掉新反馈状态的问题。
- ![Fix](https://img.shields.io/badge/Fix-EF4444?style=flat-square) **批量更新重复 reload**：修复批量刷新订阅时，当前激活配置可能被单项路径和汇总路径连续 reload 两次的问题。
- ![Fix](https://img.shields.io/badge/Fix-EF4444?style=flat-square) **系统代理 Helper 兼容性**：兼容老版本 Helper 缺少新 RPC 的场景，并继续收敛 Helper 安装、状态读取和恢复链路中的异常路径。
- ![Fix](https://img.shields.io/badge/Fix-EF4444?style=flat-square) **规则显示误导**：不再把 `MATCH / FINAL` 等真实规则类型错误显示成占位符。

## v0.1.11

![macOS](https://img.shields.io/badge/macOS-Supported-000000?style=flat-square&logo=apple) ![Version](https://img.shields.io/badge/Release-v0.1.11-10B981?style=flat-square) ![Core](https://img.shields.io/badge/Core-Mihomo-6366f1?style=flat-square)

> 此版本是 **beta-pr-clean 维护线** 的增量发布，目标是保留更早期稳定基线，同时按需引入你指定的上游 PR #50 小功能并补齐审查修复。

### 🧭 代码基线 (Code Baseline)

- 基线分支：`lovitus:beta-pr-clean`
- 基线提交：[`05295a2f7b5b105c2da6e9cf3fcfbd360a3d4963`](https://github.com/lovitus/ClashBar/commit/05295a2f7b5b105c2da6e9cf3fcfbd360a3d4963)
- 基线特征：处于较早期实现路线（你当前确认“正常”的分支），不跟随后续较大范围重构。

### 🍒 Cherry-Pick 来源 (From PR #50)

- 上游 PR：[`Sitoi/ClashBar#50`](https://github.com/Sitoi/ClashBar/pull/50)
- 上游原始提交：[`5f3819dfb1194d74e8e7346be69acb58305f9e33`](https://github.com/Sitoi/ClashBar/commit/5f3819dfb1194d74e8e7346be69acb58305f9e33)
- 本分支落地提交：`c172b93`
- 引入功能：
  - 配置切换菜单显示两行状态信息（文件变更时间、最后检查成功时间）
  - 仅远程订阅配置显示单项刷新入口（`arrow.clockwise`）
  - 单项刷新支持进行中/成功/失败短时反馈
  - 远程订阅文件内容未变化时不覆写文件，避免无意义更新时间抖动
  - 自动 reload 仅在“当前配置且内容确实变更”时触发

### 🛠️ 审查后优化 (Post-Review Hardening)

- 修复取消任务误清状态：
  - 反馈清理任务在被取消时立即退出，避免连续点击刷新时新一轮反馈被旧任务提前清空。
- 修复批量更新成功统计语义：
  - 日志“成功数”改为真实成功下载数（包含未变更项），避免出现“0 succeeded, 0 failed”这类误导结果。
- 修复批量更新源地址一致性：
  - 批量更新改为使用循环开始时的快照 URL，避免 `await` 期间配置变更导致串源或误报无效地址。

### 📝 更新日志 (Changelog)

**✨ 新增功能 (New Features)**

- ![Feature](https://img.shields.io/badge/Feature-10B981?style=flat-square) **配置菜单状态可见化**：配置列表项新增“变更时间 / 检查成功时间”状态副标题。
- ![Feature](https://img.shields.io/badge/Feature-10B981?style=flat-square) **远程配置单项刷新**：远程订阅配置可直接在列表右侧单项刷新并显示即时反馈。

**🚀 优化改进 (Improvements)**

- ![Optimize](https://img.shields.io/badge/Optimize-3B82F6?style=flat-square) **远程更新幂等写入**：远程内容未变化时不重写本地文件，降低不必要 I/O 与状态抖动。
- ![Optimize](https://img.shields.io/badge/Optimize-3B82F6?style=flat-square) **热更新触发更精确**：仅在当前激活配置且内容有变化时才执行自动 reload。

**🐞 修复问题 (Bug Fixes)**

- ![Fix](https://img.shields.io/badge/Fix-EF4444?style=flat-square) **反馈状态闪烁**：修复快速连续刷新时图标反馈被提前清除的问题。
- ![Fix](https://img.shields.io/badge/Fix-EF4444?style=flat-square) **批量更新成功计数**：修复成功统计与文案语义不一致导致的误导。
- ![Fix](https://img.shields.io/badge/Fix-EF4444?style=flat-square) **批量更新 URL 竞态**：修复批量更新过程中配置源变更引发的潜在串源与误报。

## v0.2.0

![macOS](https://img.shields.io/badge/macOS-Supported-000000?style=flat-square&logo=apple) ![Version](https://img.shields.io/badge/Release-v0.2.0-10B981?style=flat-square) ![Core](https://img.shields.io/badge/Core-Mihomo-6366f1?style=flat-square)

> 本次更新主要聚焦在 **菜单栏交互稳定性与性能修复**：重点解决代理分组悬停时 CPU 异常飙高、Popover 悬停判定不稳、System 页面提示条布局跳动，以及 TUN 与系统代理状态在恢复场景下不同步的问题；同时继续优化活动数据缓存和界面细节，让整体菜单栏体验更顺滑。

### 📝 更新日志 (Changelog)

**✨ 新增功能 (New Features)**

- ![Feature](https://img.shields.io/badge/Feature-10B981?style=flat-square) **暂无内容**：当前版本未新增独立功能项，更新重点为稳定性、性能与交互体验修复。

**🚀 优化改进 (Improvements)**

- ![Optimize](https://img.shields.io/badge/Optimize-3B82F6?style=flat-square) **活动数据缓存**：为 Activity 页和菜单栏相关派生数据增加缓存与预计算，减少列表刷新和统计展示时的额外开销。
- ![Optimize](https://img.shields.io/badge/Optimize-3B82F6?style=flat-square) **实时连接状态处理**：整理实时连接与 WebSocket 数据流处理逻辑，降低 `AppState` 与页面刷新逻辑的耦合，提升 Activity、Proxy、Rules 等页面的刷新稳定性。
- ![Optimize](https://img.shields.io/badge/Optimize-3B82F6?style=flat-square) **菜单栏视觉打磨**：继续细化菜单栏界面的间距、标题区、Sparkline 和 System 页展示细节，整体观感更统一。

**🐞 修复问题 (Bug Fixes)**

- ![Fix](https://img.shields.io/badge/Fix-EF4444?style=flat-square) **代理分组悬停高占用**：修复鼠标悬停代理分组时可能触发 CPU 占用飙升的问题，显著减轻卡顿与发热。
- ![Fix](https://img.shields.io/badge/Fix-EF4444?style=flat-square) **Popover 悬停稳定性**：修复附着式 Popover 在鼠标移动过程中的悬停判定不稳定问题，减少误闪动和意外收起。
- ![Fix](https://img.shields.io/badge/Fix-EF4444?style=flat-square) **System 页布局跳动**：修复反馈提示条出现或消失时导致的 System 页面布局偏移问题。
- ![Fix](https://img.shields.io/badge/Fix-EF4444?style=flat-square) **TUN 状态同步**：修复持久化的 TUN 开关状态与真实运行状态可能不一致的问题，避免界面显示和实际状态脱节。
- ![Fix](https://img.shields.io/badge/Fix-EF4444?style=flat-square) **系统代理恢复竞态**：增强 Helper 恢复阶段的容错处理，减少系统代理状态恢复过程中的偶发异常。
- ![Fix](https://img.shields.io/badge/Fix-EF4444?style=flat-square) **Fallback 分组排序**：修复 Fallback 代理组在刷新后的排序不稳定问题，让列表顺序更可预期。

## v0.1.9

![macOS](https://img.shields.io/badge/macOS-Supported-000000?style=flat-square&logo=apple) ![Version](https://img.shields.io/badge/Release-v0.1.9-10B981?style=flat-square) ![Core](https://img.shields.io/badge/Core-Mihomo-6366f1?style=flat-square)

> 本次更新集中修正了 **状态栏显示稳定性**：速度文本改为模板图像渲染，减少频繁重绘；同时修复状态栏宽度与弹出面板高度在切换场景下容易抖动、跳变的问题，让菜单栏体验更稳。

### 📝 更新日志 (Changelog)

**✨ 新增功能 (New Features)**

- ![Feature](https://img.shields.io/badge/Feature-10B981?style=flat-square) **模板化速度文本渲染**：状态栏上下行速率文本改为缓存模板图像渲染，保留系统原生的高亮/变暗行为，同时减少文本逐帧绘制开销。

**🚀 优化改进 (Improvements)**

- ![Optimize](https://img.shields.io/badge/Optimize-3B82F6?style=flat-square) **状态栏渲染路径**：整理状态栏显示刷新与渲染辅助逻辑，宽度计算与运行态图标切换更直接，后续维护成本更低。
- ![Optimize](https://img.shields.io/badge/Optimize-3B82F6?style=flat-square) **Popover 尺寸跟随**：菜单弹出面板改为使用标准边界尺寸，并更及时响应高度变化，减少内容变化后的尺寸滞后。

**🐞 修复问题 (Bug Fixes)**

- ![Fix](https://img.shields.io/badge/Fix-EF4444?style=flat-square) **状态栏宽度抖动**：修复状态栏在图标/速率模式切换时宽度容易波动的问题，显示更稳定。
- ![Fix](https://img.shields.io/badge/Fix-EF4444?style=flat-square) **弹出面板跳变**：修复菜单栏弹出面板在不同屏幕参数和内容高度变化下尺寸不稳定的问题，避免打开后出现跳一下的体验。

## v0.1.8

![macOS](https://img.shields.io/badge/macOS-Supported-000000?style=flat-square&logo=apple) ![Version](https://img.shields.io/badge/Release-v0.1.8-10B981?style=flat-square) ![Core](https://img.shields.io/badge/Core-Mihomo-6366f1?style=flat-square)

> 本次更新集中在 **代理页面体验提升**：新增 Proxy Group 排序切换（延迟排序 / 原始顺序），重新设计了代理订阅行的信息展示；同时修复了多显示器下状态栏图标不跟随系统变暗的问题，并加固了 Helper XPC 认证安全性。

### 📝 更新日志 (Changelog)

**✨ 新增功能 (New Features)**

- ![Feature](https://img.shields.io/badge/Feature-10B981?style=flat-square) **代理组排序切换**：在 Proxy 页面工具栏新增排序切换，可在延迟排序与默认节点顺序之间切换，同时仍遵循隐藏不可用节点的过滤规则。
- ![Feature](https://img.shields.io/badge/Feature-10B981?style=flat-square) **状态栏运行状态图标**：更新品牌图标资源，状态栏图标区分运行（Running）与休眠（Sleeping）两种状态。

**🚀 优化改进 (Improvements)**

- ![Optimize](https://img.shields.io/badge/Optimize-3B82F6?style=flat-square) **订阅信息重设计**：重新设计代理订阅（Proxy Provider）行，直接展示更新时间、刷新状态、到期信息和用量进度，信息一目了然。
- ![Optimize](https://img.shields.io/badge/Optimize-3B82F6?style=flat-square) **Provider 状态精简**：移除 Provider 节点级别的延迟、测试、展开等冗余状态追踪，保持订阅行聚焦于摘要信息，减少不必要的内存占用。

**🐞 修复问题 (Bug Fixes)**

- ![Fix](https://img.shields.io/badge/Fix-EF4444?style=flat-square) **状态栏图标变暗**：为状态栏图标启用 `isTemplate` 模式，修复多显示器切换焦点时图标不跟随系统自动变暗的问题，行为与系统电池、Wi-Fi 图标保持一致。
- ![Fix](https://img.shields.io/badge/Fix-EF4444?style=flat-square) **Helper XPC 认证**：XPC 认证改为基于代码签名要求（Code Signing Requirement），替代原有的 PID 签名校验方式，提升安全性与可靠性。

---

## v0.1.7

![macOS](https://img.shields.io/badge/macOS-Supported-000000?style=flat-square&logo=apple) ![Version](https://img.shields.io/badge/Release-v0.1.7-10B981?style=flat-square) ![Core](https://img.shields.io/badge/Core-Mihomo-6366f1?style=flat-square)

> 本次更新重点补上了 **系统代理状态恢复** 这块一直该做但没做干净的事情：重启应用后不再莫名掉代理；同时顺手把 `System` 页快捷键和启动后的分组延迟探测补齐，让常用操作更顺手。

### 📝 更新日志 (Changelog)

**✨ 新增功能 (New Features)**

- ![Feature](https://img.shields.io/badge/Feature-10B981?style=flat-square) **系统页快捷键**：新增 `Command + ,` 快捷键，支持从菜单命令快速切换到 `System` 页面，更符合 macOS 用户习惯。

**🚀 优化改进 (Improvements)**

- ![Optimize](https://img.shields.io/badge/Optimize-3B82F6?style=flat-square) **启动延迟探测**：内核启动完成后会自动触发 Proxy Group 延迟测试，用户打开面板时能更快看到各组节点状态。
- ![Optimize](https://img.shields.io/badge/Optimize-3B82F6?style=flat-square) **退出清理流程**：应用退出时会主动清理系统代理，减少异常退出后系统仍残留无效代理状态的情况。

**🐞 修复问题 (Bug Fixes)**

- ![Fix](https://img.shields.io/badge/Fix-EF4444?style=flat-square) **系统代理恢复**：修复 ClashBar 重新启动后系统代理状态丢失的问题；如果退出前已开启代理，应用恢复运行后会自动按上次状态恢复。

## v0.1.6

![macOS](https://img.shields.io/badge/macOS-Supported-000000?style=flat-square&logo=apple) ![Version](https://img.shields.io/badge/Release-v0.1.6-10B981?style=flat-square) ![Core](https://img.shields.io/badge/Core-Mihomo-6366f1?style=flat-square)

> 本次更新重点把 **Mihomo 内核升级** 直接做进了菜单栏底部，运行中的用户无需再手动折腾；同时补齐了升级结果反馈、版本刷新与新版检测时机，减少“点了没反应”和版本信息滞后的问题。

### 📝 更新日志 (Changelog)

**✨ 新增功能 (New Features)**

- ![Feature](https://img.shields.io/badge/Feature-10B981?style=flat-square) **内核一键升级**：在菜单栏底部新增 Mihomo 内核升级入口，支持在运行中直接检查并执行升级操作。

**🚀 优化改进 (Improvements)**

- ![Optimize](https://img.shields.io/badge/Optimize-3B82F6?style=flat-square) **升级反馈**：为内核升级补充进行中、成功、已是最新版、失败等明确状态提示，并同步写入日志，减少黑盒体验。
- ![Optimize](https://img.shields.io/badge/Optimize-3B82F6?style=flat-square) **版本同步**：升级完成后自动刷新内核版本号，底部显示的 Mihomo 版本会尽快与实际运行版本保持一致。
- ![Optimize](https://img.shields.io/badge/Optimize-3B82F6?style=flat-square) **版本检查时机**：应用新版检测改为在面板展开时刷新，避免后台无效轮询，同时保证用户打开菜单时能看到最新版本提示。

**🐞 修复问题 (Bug Fixes)**

- ![Fix](https://img.shields.io/badge/Fix-EF4444?style=flat-square) **升级响应兼容性**：兼容 Mihomo `/upgrade` 接口的多种响应与错误文案，正确识别“已是最新版”场景，避免把正常结果误判为失败。
