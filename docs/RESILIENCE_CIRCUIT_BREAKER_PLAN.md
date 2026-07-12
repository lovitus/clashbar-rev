# ClashBar 异常流量与资源熔断待实现计划

## 背景

ClashBar 需要在 mihomo、TUN、WebSocket 或网络环境进入异常状态时限制故障放大。典型风险包括：

- TUN 或系统代理回流、回环导致连接风暴。
- mihomo 高频重复输出同一错误，ClashBar 日志处理和 SwiftUI 渲染被拖满。
- WebSocket 断开后反复重连，生成大量并发连接或 Task。
- `/connections` 突然出现每秒数千条连接，导致解码、状态发布和 UI 渲染持续占满 CPU。
- 自愈动作反复执行，形成 stop/start 或 TUN 开关风暴。

目标不是隐藏错误，而是限制 CPU、内存、连接数和重试次数，在保留诊断信息的同时安全降级。

## 设计原则

1. 每个高频输入必须有固定事件预算，不能让上游速率直接决定主线程工作量。
2. 熔断按 `closed -> open -> half-open` 状态机实现，禁止无上限即时重试。
3. 先降级采集和 UI，再处理代理/TUN，最后才重启 core。
4. 所有自动恢复动作必须有冷却时间、次数上限和用户可见原因。
5. 阈值采用安全默认值，并允许后续通过高级设置调整；测试不得依赖真实高负载。

## P0：日志洪泛保护

### 重复日志聚合

- 使用标准化后的 `source + level + message` 作为签名。
- 相同签名在聚合窗口内仅保留一条，显示累计次数和首次/末次时间。
- 默认聚合窗口：1 秒；单条消息最大长度：4,096 字符。
- UI 每秒最多发布 5 次日志状态更新。
- 面板关闭或 Logs 页不可见时，每秒最多发布 1 次。

### 日志流熔断

- 滚动统计 1 秒、3 秒和 30 秒日志速率。
- 默认触发条件：连续 3 秒超过 500 条/秒，或单秒超过 2,000 条。
- 触发后：
  1. 记录一条聚合告警。
  2. 取消 logs WebSocket。
  3. 暂停日志流 30 秒。
  4. 半开后只观察 3 秒；再次超限则按 60 秒、120 秒退避。
- 非日志 stream 和 core 生命周期日志不得被静默丢弃。

### 验收标准

- 输入 10,000 条/秒、持续 60 秒时，主线程保持可交互。
- 内存日志集合始终有硬上限。
- 重复消息能看到累计次数，不生成 10,000 个 SwiftUI row identity。
- 熔断、半开和恢复均有单条可诊断事件。

## P0：Stream 和 Task 单实例约束

- 每个 `StreamKind` 同时最多存在：
  - 1 个 `URLSessionWebSocketTask`；
  - 1 个 receive Task；
  - 1 个计划中的 reconnect Task。
- 为每次启动分配 generation token；旧 generation 的回调不得修改新 stream 状态。
- 取消时清理 socket、receive、reconnect 和 pending payload。
- 增加调试快照：当前 stream 状态、generation、重连次数、最近错误和下次重试时间。

### WebSocket 重连熔断

- 保留指数退避并加入随机抖动。
- 默认触发条件：10 秒内重连超过 8 次，或 60 秒内超过 20 次。
- 熔断 30 秒后半开；连续三次半开失败后停止自动恢复，等待网络变化、core 重启或用户操作。

### 验收标准

- 反复切换网络、controller 和配置时，不出现重复 stream。
- 使用测试 transport 模拟立即断开，Task/socket 数量始终有界。
- 旧 session 或旧 generation 的完成回调不能重启已取消 stream。

## P1：连接风暴与回环检测

### 指标

- 当前活跃连接数。
- 每秒新建和关闭连接数。
- 按目标 IP、目标端口、来源进程、规则和代理链统计的集中度。
- ClashBar 到 controller 的本地管理连接单独标记，不计入普通代理流量。

### 默认触发条件

- 活跃连接超过 5,000；或
- 连续 3 秒新建连接超过 1,000 次/秒；或
- 5 秒内超过 80% 新连接集中到同一目标，并且总量超过 2,000。

阈值需要通过真实使用数据校准，避免 BT、下载器和压测场景误触发。

### 分级处理

1. **UI 降级**：停止发布完整连接数组，只保留计数、速率和 Top-N 汇总。
2. **采集降级**：降低 `/connections` 频率或暂停连接 stream 15 秒。
3. **高可信回环**：关闭系统代理，保留告警和恢复入口。
4. **持续异常**：关闭 TUN 后重启 core；恢复前要求 half-open 健康检查通过。

任何可能中断网络的第 3、4 级动作都必须提供设置开关，默认仅对高可信回环或已知致命错误自动执行。

### 验收标准

- 模拟 20,000 活跃连接时 UI 不构造完整可见列表。
- 检测到本地 controller 管理连接时不误判为回环。
- 正常大流量场景只告警或 UI 降级，不擅自关闭代理。

## P1：已知致命错误自愈

建立可测试的错误签名策略，首个候选：

```text
batch read packet: socket operation on non-socket
```

默认判定：同一签名 3 秒内出现至少 100 次，并同时满足 core CPU/日志速率/API 健康检查中的至少一个异常条件。

恢复顺序：

1. 熔断日志 stream，避免 UI 放大。
2. 保存系统代理和 TUN 的期望恢复状态。
3. 关闭系统代理。
4. 尝试关闭 TUN。
5. 重启 core。
6. API 健康检查通过后恢复原状态。

限制：

- 自动重启冷却时间默认 10 分钟。
- 30 分钟内最多自动恢复 2 次。
- 再次触发时保持 TUN/系统代理关闭，并展示明确错误，不继续循环重启。

## P1：全局资源保护

- 为日志解码、连接解码、状态发布和 UI 派生计算分别记录速率与耗时。
- 当主线程更新积压时只保留最新 snapshot，禁止排队保存全部中间状态。
- 所有缓存、历史数组、反馈 Task 字典和诊断集合必须有数量或时间上限。
- 增加 ClashBar 自身 memory footprint 和 CPU 异常告警；采样失败不得触发破坏性动作。

## P2：可观测性与用户体验

- System 页新增“保护状态”区域：正常、降级、熔断、半开、自愈失败。
- 显示触发指标、阈值、开始时间、剩余冷却时间和建议操作。
- 提供“立即重试”“保持 TUN 关闭”“导出诊断摘要”。
- 诊断摘要仅包含计数、错误签名、状态转换和版本信息，不包含 secret、完整 URL 或用户流量内容。
- 为熔断状态变化增加统一内存日志，但禁止状态本身造成日志风暴。

## 建议代码结构

- `Domain/Entities/CircuitBreakerState.swift`
- `Domain/UseCases/Resilience/EvaluateLogFloodUseCase.swift`
- `Domain/UseCases/Resilience/EvaluateConnectionStormUseCase.swift`
- `Domain/UseCases/Resilience/ComputeCircuitBreakerTransitionUseCase.swift`
- `App/Session/Coordinators/AppSession+Resilience.swift`
- `Infrastructure/Diagnostics/RuntimeHealthSampler.swift`

纯阈值和状态转换放入 UseCase，副作用编排放入 coordinator，系统采样放入 Infrastructure；View 只消费展示状态。

## 实施顺序

1. 日志签名聚合、UI 发布预算和日志 stream 熔断。
2. Stream generation token、单实例 reconnect 和状态快照。
3. 连接风暴指标与仅 UI 降级模式。
4. 已知致命错误检测与受限 core 自愈。
5. 高可信回环识别及系统代理/TUN 分级保护。
6. System 页保护状态、诊断导出和阈值配置。

每一步独立提交和发布，至少观察一个 Beta 周期后再启用下一层自动破坏性动作。

## 测试计划

- 单元测试覆盖状态机全部转换、冷却、重试上限和时间窗口边界。
- 使用 fake clock，禁止依赖真实 sleep。
- 使用 fake WebSocket/transport 注入断开、重复 payload 和乱序完成。
- 压力测试覆盖日志 10,000 条/秒、连接 20,000 条和 1,000 次/秒重连事件。
- 回归测试覆盖睡眠唤醒、网络切换、配置切换、远程 controller 和 core 重启。
- Beta 验证记录 CPU、footprint、socket/Task 数量和熔断状态转换。

## 完成定义

- 任一上游异常速率都不能无界增加 ClashBar 的 Task、socket、内存或 UI 更新次数。
- 自动恢复不能形成重启、TUN 或系统代理开关风暴。
- 用户能够知道发生了什么、系统采取了什么动作以及何时会重试。
- 所有保护均有确定性测试，并在 Beta 压力场景下验证。
