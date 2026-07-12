# ClashBar 异常流量与资源熔断待实现计划

## 状态与结论

本计划用于限制 mihomo、TUN、WebSocket 或网络异常在 ClashBar 内被放大。当前只批准按下述顺序推进基础设施和非破坏性保护；日志熔断、连接风暴判断和自动自愈不得跳过生命周期、线程边界与测试基础直接实现。

典型风险：

- TUN 或系统代理回流、回环导致连接风暴。
- mihomo 高频输出重复或高基数错误，拖满字符串处理、状态发布和 SwiftUI 渲染。
- WebSocket 旧回调与新 stream 竞争，生成重复 socket、receive Task 或 reconnect Task。
- `/connections` 含数万条记录时，完整 JSON 解码已经耗尽 CPU，UI 截断无法提供保护。
- 自动恢复覆盖用户的新操作，或形成 stop/start、TUN、系统代理开关风暴。

## 不可违反的设计约束

1. 每个高频入口必须在进入 `MainActor` 前受到固定事件、内存和高基数预算约束。
2. 每个 `StreamKind` 同时最多有一个 socket、receive Task 和 reconnect Task。
3. breaker 的 `.open` 状态必须接入 data acquisition policy，不能只在回调层取消 socket。
4. 任何旧 generation、旧 session 或已取消任务的完成回调都不能修改当前状态。
5. 先停止放大和降级采集，再考虑系统代理、TUN 或 core；破坏性动作首个 Beta 阶段默认仅告警。
6. 自愈必须服从最新用户意图。开始恢复时保存的状态不能覆盖恢复期间发生的新操作。
7. 时间、随机抖动和 transport 必须可注入，状态机测试不得依赖真实 `Date()`、`Task.sleep` 或随机数。

## P0-A：Stream 生命周期与测试基础

### 单实例所有权

为每个 `StreamKind` 建立显式 runtime slot：

- `generation`；
- `breakerState`；
- 当前 `URLSessionWebSocketTask`；
- 当前 receive Task；
- 当前 reconnect Task；
- 最近错误、连接开始时间、有效 payload 数和下次重试时间。

启动、接收、断开、重连和取消均携带 generation。只有 generation 与当前 slot 一致时才能：

- 写入 socket/Task；
- 发布 payload；
- 修改计数；
- 启动重连；
- 清空当前状态。

取消必须幂等地清理 socket、receive、reconnect 和 pending payload。`DetermineDataAcquisitionPolicyUseCase` 或等价 policy 输入必须包含 breaker 状态；`.open` 时禁止重新启动对应 stream，避免 policy 因 socket 为空立即绕过熔断。

### 重连健康模型

保留指数退避和可注入抖动，但拆分以下指标：

- `rollingReconnectStarts`：滚动窗口内实际开始的重连次数，不因收到单个 payload 清零；
- `consecutiveUnhealthySessions`：未达到稳定条件就断开的 session 数；
- `stableSessionSuccess`：连接持续至少 30 秒或收到至少 N 条有效 payload 后才成立。

half-open 成功必须达到 `stableSessionSuccess`，单个 payload 不算恢复。初始 breaker 阈值通过现有 1/2/4/8 秒退避模型和测试推导，不预设不可达的“60 秒 20 次”；Beta 采样后再固化默认值。

### 调试快照

提供只读 snapshot：kind、generation、breaker、socket/Task 是否存在、rolling starts、unhealthy sessions、稳定时长、payload 数、最近错误和下次动作。snapshot 不包含 secret 或完整 URL。

### 测试工程落点

第一批提交先在 `Package.swift` 增加 `ClashBarTests` test target 和 `Tests/ClashBarTests`，并提供：

- 注入式 `Clock`；
- 注入式随机数/抖动源；
- WebSocket transport 协议和 fake transport；
- 不依赖 actor 调度时序的纯 breaker transition reducer。

分别断言 `received`、`dropped`、`aggregated`、`published`，不能只检查最终数组大小。

### P0-A 验收标准

- 网络、controller、配置和 target 高频切换时，每种 stream 的三类资源始终最多各一个。
- 旧 generation 的乱序完成不能重启或清空新 stream。
- `.open` 后 acquisition policy 不会重新建连。
- fake clock 可覆盖退避、half-open、稳定成功和冷却边界，无真实 sleep。

## P0-B：非主线程有界日志入口

### `LogIngressActor`

WebSocket 收到原始日志后立即交给非 `MainActor` 的 `LogIngressActor`。下列工作必须在 actor 内完成：

- 字节/字符长度截断；
- 日志级别解析、脱敏和签名；
- 固定时间桶速率统计；
- 重复聚合；
- token bucket 消耗；
- bounded buffer 管理；
- 高基数签名驱逐。

actor 的硬限制至少包括：

- `maxMessageBytes`/`maxMessageCharacters`；
- `maxBufferedEvents`；
- `maxDistinctSignatures`；
- 全局每秒接收预算；
- 每个签名每个窗口的保留预算；
- 单次发布最大聚合条数。

当每条消息都不同时，`maxDistinctSignatures` 与全局 token bucket 仍必须限制 CPU 和内存。驱逐采用确定性、有界算法，不允许按攻击者输入创建无界字典键。

### MainActor 发布边界

- actor 每个发布周期最多向 MainActor 提交一次聚合 snapshot。
- 面板可见时默认最多 5 次/秒，后台最多 1 次/秒。
- snapshot 中包含聚合次数、首次/末次时间和 dropped 数。
- MainActor 只合并已聚合结果，不再逐条脱敏、创建 UUID 或重建数组。
- core 生命周期日志走同一有界入口的高优先级通道，不随 logs WebSocket 熔断静默丢失。

### 日志 breaker

日志 breaker 必须在 P0-A 完成后接入 stream policy。初始候选阈值为连续 3 秒超过 500 条/秒或单秒超过 2,000 条，但最终值以有界入口压力测试和 Beta 数据为准。

触发后：记录单条聚合事件、将 logs breaker 置为 `.open`、取消 logs stream、冷却后 half-open。half-open 是否成功按稳定 session 定义判断；再次失败按有限序列延长冷却，达到上限后等待用户、网络变化或 core generation 变化。

### P0-B 验收标准

- 10,000 条/秒持续 60 秒时，MainActor 接收调用次数保持固定上限。
- 重复和全高基数两类输入都不会无界增加内存、签名字典或 UUID 数量。
- 日志集合有硬上限，重复消息只生成稳定数量的 row identity。
- 熔断本身不会产生日志反馈回路。

## P1-A：连接摘要与非破坏性资源保护

### 当前能力限制

当前 `Connection` 解码会遍历完整 snapshot 后只保留前 120 条。因此“UI 不展示”不能降低 20,000 条连接的解码成本。当前 metadata 也没有可靠来源进程字段，第一版不得把来源进程作为必要信号。

### 流式摘要解码

增加专用连接 snapshot 解码路径，在遍历 JSON 时原地累计：

- 总连接数；
- 最多 120 个展示对象；
- 目标 IP/端口、规则和代理链 Top-N；
- 必要时间桶计数；
- payload 提供时的可选进程信息。

不得先构造完整 `[Connection]` 再截断。Top-N 使用固定容量结构。来源进程仅在 mihomo payload 明确支持且验证可靠时启用。

### 新建/关闭速率

第一版优先使用 snapshot 自带的总量和开始时间桶推导近似速率。若必须按 ID 做差分，只保存有界 hash/采样结构并记录误差，禁止跨 snapshot 保存全部连接 ID。

集中度只能基于摘要遍历期间的全量计数计算，不能从保留的 120 条展示样本推断。

### 第一阶段动作

P1-A 只允许：

1. 降低完整连接状态的发布频率；
2. 仅发布 count、速率和 Top-N；
3. 暂停连接 stream 并进入 half-open；
4. 展示告警。

不得自动关闭系统代理、TUN 或重启 core。活跃 5,000、1,000 次/秒和 80% 集中度仅作为待校准候选阈值。

### P1-A 验收标准

- 20,000 条连接输入时不构造 20,000 个 `Connection` 对象。
- Top-N 和集中度来自完整遍历计数，展示截断不影响判断。
- 本地 controller 管理连接可识别并从普通代理指标中排除。
- BT、下载器和压测场景默认只告警/降级，不中断网络。

## P1-B：带所有权约束的受限自愈

### `RecoveryCoordinator`

所有可能修改系统代理、TUN 或 core 的动作必须由单实例 coordinator 串行编排。每次 recovery 记录：

- recovery generation；
- controller、config 和 target generation；
- 用户意图版本；
- core generation；
- 触发信号及适用版本范围；
- 已完成步骤和超时状态。

每一步必须幂等并有超时。新的用户操作、target/config 变化、App 退出或更高 generation recovery 会取消旧流程。只有用户意图版本未变化时，才能恢复开始时的系统代理/TUN 状态。

### 触发安全边界

首个候选错误签名：

```text
batch read packet: socket operation on non-socket
```

破坏性恢复不得仅依赖“日志签名 + 一次 API 超时”。必须满足以下之一：

- 已知错误签名、明确受影响的 mihomo 版本范围，以及可复现的致命状态；或
- 两个独立信号，例如持续日志洪泛与 core CPU 异常，或持续日志洪泛与多次独立 API 健康检查失败。

CPU/footprint 采样失败本身不能作为异常证据。第一轮 Beta 默认仅告警和建议用户重启 core，收集数据确认后才允许自动执行。

### 受限恢复流程

候选顺序：熔断日志流、记录用户意图版本、关闭系统代理、尝试关闭 TUN、重启 core、独立 API 健康检查、按版本校验恢复用户意图。

限制：默认冷却 10 分钟；30 分钟最多两次；再次失败进入持久保护状态，不继续循环。失败状态可以持久化，自动动作不得在下次启动时无条件续跑。

### P1-B 验收标准

- recovery 中用户手动切换代理/TUN 后，旧流程不会覆盖新选择。
- core 启动失败、健康超时、网络变化和 App 退出均有确定性终止状态。
- 多个异常同时触发时只有一个 recovery owner。
- 默认配置不执行未经 Beta 验证的断网动作。

## P2：高可信回环检测与 UX

- 在连接摘要、系统代理目标、controller 地址和路由信息足够可靠后再建立回环模型。
- System 页展示正常、降级、熔断、half-open、自愈中和自愈失败。
- 显示触发指标、阈值、generation、开始时间、冷却和建议操作。
- 提供“立即重试”“保持 TUN 关闭”“导出诊断摘要”。
- 摘要只包含计数、错误签名、状态转换和版本，不包含 secret、完整 URL 或流量内容。
- 高级阈值可配置，但必须保留不可突破的全局安全上限。

## 建议代码结构

- `Domain/Entities/CircuitBreakerState.swift`
- `Domain/Entities/StreamRuntimeSnapshot.swift`
- `Domain/UseCases/Resilience/ComputeCircuitBreakerTransitionUseCase.swift`
- `Domain/UseCases/Resilience/EvaluateLogFloodUseCase.swift`
- `Domain/UseCases/Resilience/EvaluateConnectionStormUseCase.swift`
- `App/Session/Coordinators/AppSession+StreamLifecycle.swift`
- `App/Session/Coordinators/AppSession+Resilience.swift`
- `App/Session/Coordinators/RecoveryCoordinator.swift`
- `Infrastructure/Logging/LogIngressActor.swift`
- `Infrastructure/API/Decoding/ConnectionsSummaryDecoder.swift`
- `Infrastructure/Diagnostics/RuntimeHealthSampler.swift`
- `Tests/ClashBarTests/Resilience/`

纯状态转换放入 UseCase/reducer，副作用编排放 coordinator，输入限流与解码放 Infrastructure；View 只消费稳定 snapshot。

## 批次与发布门槛

### P0-A：基础安全性

1. test target、fake clock、fake jitter、fake transport。
2. Stream generation 和单 socket/receive/reconnect。
3. breaker 状态接入 acquisition policy。
4. runtime 调试 snapshot。

### P0-B：日志入口保护

1. 非 MainActor bounded ingress。
2. 全局 token bucket、消息长度和签名数量上限。
3. 重复聚合与固定发布频率。
4. logs breaker 与 stable-session half-open。

### P1-A：连接资源保护

1. 流式摘要解码。
2. count、近似速率、Top-N 和可用能力标记。
3. 仅 UI/采集降级与告警。

### P1-B：受限自愈

1. RecoveryCoordinator、generation 和用户意图版本。
2. 幂等步骤、超时、取消和持久失败状态。
3. 已知签名与独立信号组合。
4. 首轮 Beta 默认仅告警，数据确认后单独开启自动恢复。

### P2：回环检测和 UX

1. 高可信回环模型。
2. System 页保护状态。
3. 诊断导出和高级阈值。

每个批次独立提交并至少经过一个 Beta 观察周期。上一批次的资源上界和状态机测试未通过，不得开始下一批次的自动动作。

## 全局测试矩阵

- 重复日志 10,000 条/秒和全高基数日志 10,000 条/秒。
- 连接 snapshot 20,000 条和连续大 snapshot。
- 立即断开、收到一个 payload 后断开、稳定 30 秒后断开。
- 旧 generation 乱序完成、取消与重连同时发生。
- 睡眠唤醒、网络切换、controller/config/target 切换和 core 重启。
- recovery 中插入用户操作、健康超时、启动失败和 App 退出。
- 分别记录 CPU、footprint、MainActor 发布次数、socket/Task 数以及 received/dropped/aggregated/published。

## 完成定义

- 上游异常不能无界增加 ClashBar 的 MainActor 工作、Task、socket、签名字典、连接对象或内存。
- breaker `.open` 能从 policy 层阻止重启，half-open 有明确稳定成功条件。
- 连接保护在解码阶段就限制对象构造，而不是只限制 UI。
- 自动恢复有唯一 owner，并且不能覆盖更新后的用户意图。
- 所有时间、随机和 transport 行为可确定性测试。
- 用户能够知道触发原因、采取动作、剩余冷却和下一步选择。
