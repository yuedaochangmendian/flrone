# Bridge payload 审计（Phase 1 摸底 + 后续实施状态）

本文盘点 Dart ↔ Go 桥上每一条 action 方法和 Go→Dart 事件，并标注后续优化项的**实施状态**。Phase 1 只新增了默认关闭的 Dart 侧计数器（见文末「如何读计数器」）；此后 Top 5 中的多项已落地——全局规则增量（`version`/`etag` + `saveGlobalRulesPatch`）、FLS1 状态帧、`speedTestResult` 增量、`groupNodes` 缓存与 channel fallback 移除，详见「三」的实施状态列。所有「估算」字样的数据都是从 handler 字段/调用点推导的**数量级估计**，不是实测采样；实测请用 `BridgeMetrics`。

## 范围与三条通道

| 通道 | 方向 | 入口 | 载体 |
| --- | --- | --- | --- |
| Action bus | Dart → Go → Dart(reply port) | `throne_invoke_action`（`buildScript/core-patch/core/mobile/bridge_runtime.go:141-155`）→ `dispatchAction`（同文件 `:179-203`）→ `postActionResult`/`postRaw`（`:157-174`） | JSON 字符串：`{"id","method","data"}` / `{"id","method","data","code"}`（`action.go:46-68`），经 Dart `Dart_PostCObject_DL`（`dartbridge.go:46-55`） |
| 事件推送 | Go → Dart(message port) | `sendEvent`（`bridge_runtime.go:206-215`）、`postTo`（`:268-274`） | JSON 字符串：`{"method","data"}`；同一 `sendToPort` |
| 日志帧 | Go → Dart(message port) | `sendLogFrame`（`bridge_runtime.go:310-321`），由 `logPump` 的 `WriteBatch`（`log.go:100-120`）喂入 | **FLB1 二进制帧**：`"FLB1" | count u32le | (level i32le | len u32le | utf8)*`（`bridge_runtime.go:289-308`），经 `GoDart_PostBytes` 零拷贝 typed-data（`dartbridge.go:19-28,57-68`）；Dart 解码在 `bridge_log_frame.dart:32-56` |

Dart 侧入口：`ThroneKernel` 构造里的两个 listener（`flutter/lib/core/throne_kernel.dart` 事件 / 结果）；JSON 事件解码是 `decodeBridgeEvent`（`throne_ffi.dart`），结果解码是 `ActionResult.decode`（`action.dart`）。`ThroneKernel` 只看到**本进程内 FFI 桥**的消息；service engine 再把事件转发给 UI engine（`service_entry.dart`），那一段是 IsolateNameServer 的 IPC map，不属于本表的编码范畴。1 Hz 状态事件现在走 FLS1 二进制帧，在 JSON 解码前按 magic 分派（`core/bridge_status_frame.dart`）。

## 一、Dart → Go action 方法（当前 22 个）

枚举与 wire 名的唯一来源是 `flutter/lib/core/action.dart` 的 `ActionMethod`（成员名即 wire 串）；Go 侧注册分布在 `action.go`、`route_actions.go`、`speed_test_actions.go`、`test_session_actions.go`、`profile_actions.go`；`tools/diagnostics/action_contract.py` 对账两端（Go 常量 / 注册 / Dart 枚举三方 22 个一致）。请求/响应主体仍是整条 JSON 字符串，但全局规则已支持增量保存（`saveGlobalRulesPatch` 只传脏行 + `version`/`etag` 冲突检测），编码成本 = 一次 `jsonEncode` + 一次 C 字符串复制 + `json.Unmarshal` + 结果 `json.Marshal` + Dart `jsonDecode`。

| method | data 形状 → 结果形状 | 调用方 | 频率 | 编码 / 批处理 | 大小估算（**估算**） |
| --- | --- | --- | --- | --- | --- |
| `actionVersion` | `null` → `{protocol:1, core:string}`（`action.go:97-102`） | 协议冒烟、诊断 | 一次性/手动 | JSON 字符串；无 | 请求 ~60 B，响应 ~90 B（`core` 版本串 ~20 字符） |
| `getGlobalRules` | → `{rules:[...], version:int64, etag:string}`，增量信封带文档修订号与整表 etag（`route_actions.go`） | `BoxApi.routeGlobalRules`（`box_api.dart`） | 路由页打开/刷新，低频 | JSON 字符串；整表一次返回（**已加 version+etag**） | **估算**：单条规则 10–25 字段、~300–800 B；全表重传仍在，但 version/etag 让后续行级 patch 有可能 |
| `saveGlobalRules` | `{rules:[...]}` → 保存结果；**已实施增量版 `saveGlobalRulesPatch`**（`{baseVersion, added, updated, deleted, order}` → 新 version/etag，陈旧时返回 `RouteRulesStale` 携带当前值） | `routeSaveGlobalRules`（`box_api.dart:218-223`） | 用户保存路由时，低频 | JSON 字符串；全量路径保留兼容，新路径只回传脏行 | 增量保存不再回传整表 ~15–80 KB（**估算**） |
| `deleteGlobalRule` | `{id:int64}` → 保存结果（`route_actions.go`） | `routeDeleteGlobalRule`（`box_api.dart`） | 用户删一行，极低频 | JSON 字符串 | <100 B（**估算**） |
| `speedTestOutbounds` | `null` → `{outbounds:[tag:string,...]}`（`speed_test_actions.go:45-63`） | `SpeedTestApi.speedTestOutbounds`（`box_api.dart:626`） | 打开测速页，一次 | JSON 字符串 | 每 tag ~10–30 B；几十个出站 ~0.3–1 KB（**估算**） |
| `groupNodes` | `null` → `{nodes:[{id,tag,type,isSelector},...]}`（`speed_test_actions.go:80-102`） | `GroupCatalogApi.groupNodes`（`box_api.dart`）——**已缓存**：`groupNodesCache`/`groupNodesCacheRevision` 按 revision 命中，profile/group 写入时失效；**channel fallback 已移除**，空结果不再回落 channel | 选择器打开，低频，重复打开命中缓存 0 次跨桥 | JSON 字符串；缓存命中时无编码 | 每节点 ~60–120 B；100 节点 ~6–12 KB，500 节点 ~30–60 KB（**估算**），缓存命中省全部 |
| `speedTestSessionStart` | `{kind,profileIds:int[],testCurrent,speedMode}` → host 的 JSON 原样（`test_session_actions.go:12,76-79`） | `groupTestSessionStart`（`box_api.dart:424`） | 每次测速开始 | JSON 字符串，经 `platform_request` 二次编码（`:57-72`） | 请求 <200 B；响应依 host，通常 bool/小 map（**估算**） |
| `speedTestSessionStop` | `{}` → host 响应（`test_session_actions.go:13`） | `groupTestSessionStop`（`box_api.dart:428`） | 每次停止 | JSON 字符串（两次编码） | <100 B（**估算**） |
| `speedTestSessionDismiss` | `{}` → host 响应（`:14`） | `groupTestSessionDismiss`（`box_api.dart:437`） | 用户关闭测速卡 | JSON 字符串（两次编码） | <100 B（**估算**） |
| `speedTestSessionSort` | `{groupId}` → bool（`test_session_actions.go:15`） | `groupTestSessionSort`（`box_api.dart:430`） | 用户拖排序 | JSON 字符串（两次编码） | <100 B（**估算**） |
| `speedTestSessionRemove` | `{ids:int[]}` → `{removed:N}`（`test_session_actions.go:16`） | `groupTestSessionRemove`（`box_api.dart:433-436`） | 用户删记录 | JSON 字符串（两次编码） | 请求依选择数，10 个 id ~80 B（**估算**） |
| ~~`speedTestSessionVisible`~~ | 非 bus 方法：可见性需求信号保留在 `groups.testSession.visible` channel（`box.dart:755`），无 core 也能工作 | 测速页可见性变化 | 页面切换 | MethodChannel | <100 B（**估算**） |
| `diagnosticsProfile` | `{kind: cpu|heap|goroutine|allocs|block, seconds:N, dir:string}` → `{files:[string],kind,seconds,bytes}`（`profile_actions.go`；需 `dir` 内的 `profile.enable` 标记，否则拒绝） | 调试工具（`invokeWire` 或 `ThroneKernel.invoke`；本轮无 UI 入口） | 手动触发 | JSON 字符串；CPU 5–60 s、单飞 | 请求 <200 B；响应为文件路径列表（**估算**） |

`message`（`action.go:36-38`）是预留的**无 id 推送 tag**，Dart 侧常量 `actionPushMethod`（`action.dart:59-61`）；当前树里既无 `sendEvent("message", …)` 也无 `postTo(..., "message", ...)` 的生产者，属于空协议位（见「意外发现」）。

## 二、Go → Dart 事件（message port + reply port）

事件主体由 `sendEvent` / `postTo` 走 `json.Marshal(map{"method","data"})`（`bridge_runtime.go`），逐条解码；**例外**：`status` 已改为 FLS1 二进制帧（见上表），`speedTestResult` 后续帧已改为 delta。`postActionResult` 是同一 port 上的另一种 shape（带 `id`/`code`），由 reply port listener 处理（`throne_kernel.dart`）。`ReplyPort` 是一次性 handler port，给 URL/IP/Speed 测试的回调用——它也调 `decodeBridgeEvent`，因此这些事件同样落在 JSON 路径上。

| method | data 形状 | 生产者 / 调用方 | 频率 | 编码 / 批处理 | 大小估算（**估算**） |
| --- | --- | --- | --- | --- | --- |
| `status` | `{memory,goroutines,connectionsIn,connectionsOut,uplink,downlink,uplinkTotal,downlinkTotal,trafficAvailable}` 9 个 int；**推送已改为 FLS1 定长二进制帧**（`"FLS1" | version u8 | 9×int64 | flags u32`，`core/bridge_status_frame.dart`；Go 侧 `status_frame.go` 的 `statusFieldOrder` 钉住字段序），心跳返回值仍是同一 JSON map | `throne_status_snapshot`，Dart 心跳 `Timer.periodic(1s)`（`kernel_worker.dart`）→ `KernelService._onKernelStatus`（`kernel_service.dart`）；`ThroneKernel` 按 magic 分派 | **1 Hz 常驻**（只要核心在跑） | FLS1 二进制帧；逐条，JSON 解码前分流 | ~84 B/帧（**估算**，固定 4+1+9×8+4），1 Hz ≈ 5 KB/分钟；较 JSON 省 ~60% |
| `urlTestResult` | `{tag,latencyMs,err}`（`bridge_runtime.go:343-345`） | `portURLTest.OnResult`，每个 tag 一次 | 一次测速 N 个节点 → N 条，突发 | JSON 字符串；逐条，走 `ReplyPort` | ~60–100 B/条；50 节点 ~3–5 KB（**估算**） |
| `urlTestVpnStatus` | `{tag,connected,state,err}`（`:346-348`） | 每个失败的 VPN endpoint tag 一次（`:746-751`） | 低频 | JSON 字符串；逐条 | ~80–140 B（**估算**） |
| `urlTestDone` | `null`（`:349`） | 一次测速结束 | 一次/测速 | JSON 字符串 | ~45 B（**估算**） |
| `ipTestResult` | `{tag,ip,countryCode,err}`（`:353-355`） | `portIPTest.OnResult` | N 个节点 → N 条 | JSON 字符串；逐条 | ~70–130 B/条（**估算**） |
| `ipTestDone` | `null`（`:356`） | 结束 | 一次 | JSON 字符串 | ~45 B（**估算**） |
| `speedTestResult` | 首帧为 `SpeedTestResult` 全字段 11 个（Go 默认字段名即 wire 名）；**后续帧为增量** `{"tag":<Tag>,"delta":{<field>:<new value>,...}}`（`speed_test_delta.go`），Dart `core/speed_test_delta.dart` 合并回全帧再交 UI | `portSpeedTest.OnResult`（`bridge_runtime.go`）；`newTestReporter` 200 ms 发进度 | 5 Hz × 测速时长（10–30 s → 50–150 条） | JSON 字符串；逐条走 `ReplyPort`；增量只发变化字段 | 首帧 ~250–350 B，delta 通常几十 B（**估算**）；一轮从 ~12–50 KB 降到数 KB |
| `speedTestDone` | `null`（`:363`） | 结束 | 一次 | JSON 字符串 | ~45 B（**估算**） |
| `log`（JSON 形态） | `{level:int,message:string}` | 仅 Kotlin host sink 与旧版 Dart 用；Dart 侧已从 FLB1 帧合成同 shape（`throne_kernel.dart:36-41`）。Go 中 `sendEvent("log", …)` 已无生产者（Go 的 log 全走帧） | Dart 路径 0；host 路径逐行 | JSON 字符串；逐行（已退役于 Dart） | 每行 ~100–300 B（**估算**） |
| `FLB1` 帧（binary，无 `method`） | `"FLB1" | count u32le | (level i32le | len u32le | utf8 bytes)*`，最多 256 条/帧（`bridge_runtime.go:289-308`） | `portLogSink.Write/WriteBatch`（`:323-339`），由 `logPump`（`log.go:100-120`）驱动 | **最高频**：连接事件每行一条，启动时突发数百行；帧按 pump drain 聚合 | **二进制 typed-data**；每批一帧，帧上限 256 条；无二次批处理 | 8 B/条头开销 + 消息长度；256 行 × ~120 B ≈ 31 KB/帧（**估算**） |
| action result | `{id,method,data,code}`（`action.go:56-62`） | `postActionResult`（`bridge_runtime.go:157-164`），每个 action 一次 | 与 action 调用 1:1 | JSON 字符串；无 | 依 data，见 action 表（**估算**） |

**跨 engine 的补充通道**（非 Go 桥，但常被混为「日志还是逐行 JSON」）：service engine 把内核日志按 `receivedAt\tlevel\tmessage` 拼成**一个字符串**批量推给 UI（`service_entry.dart:474-527`，16 ms 窗口 `log_batch.dart:8`，ring 上限 `logRingLimit=5000`、每批最多 `maxKernelLogBatchLines=512` 行），UI 侧 `_applyLogs`（`box.dart:1836+`）合并。Kotlin host 的高频 feed（logs/logcat/connections/groups）走 `StandardMessageCodec` 二进制 bulk（`box.dart:81-97,1449-1455,1762-1793`），>50 KB 自动切到后台 isolate——这两条路径与 Go 桥无关，不要重复优化。

## 三、Top 5：二进制编码 / 分页 / 增量编码候选

排序按「估算字节量 × 频率 × 当前 Dart 主线程成本」，并考虑契约改动面。**实施状态**列标注 Phase 1 之后的落地情况；未标「已实施」的仍是建议。

| # | 目标 | 建议 / 实施 | 实施状态 | 预期收益（**估算**） | 契约 / 测试影响 |
| --- | --- | --- | --- | --- | --- |
| 1 | `getGlobalRules` / `saveGlobalRules` | `get` 携带 `version`/`etag`；新增 `saveGlobalRulesPatch`（`{baseVersion, added, updated, deleted, order}` 行级补丁，陈旧时 `RouteRulesStale` 回带当前 version/etag）；全量 `saveGlobalRules` 保留兼容 | **已实施**（全局规则增量） | 编辑一次不再回传整表 ~15–80 KB（**估算**） | `route_actions.go`、`box_api.dart`（`RouteRulesSnapshot`/`RouteRulesStale`）、`action.dart`；`action_contract.py` 对账 22 个方法 |
| 2 | `FLB1` 帧 | 已经是最优路径，不重编码；只联动 256 条上限与 16 ms/512 行 service 窗口 | **已实施**（保持最优路径） | 边际收益小；主要价值是观测 | 契约已在 `log_frame_test.go` 与 bridge_metrics 测试中固定 |
| 3 | `speedTestResult` 进度 | 首帧全量、后续帧只发变化字段（`{"tag","delta":{...}}`），Dart 合并回全帧（`core/speed_test_delta.dart`） | **已实施**（delta 帧） | ~70–85% 字节节省（**估算**） | `speed_test_delta.go` + `core/speed_test_delta.dart` + Go/Dart 两侧测试；last-frame 合并语义保留 |
| 4 | `status` | 9×int64 定长 **FLS1 帧**（`"FLS1" | version u8 | 9×int64 | flags u32`），`ThroneKernel` 按 magic 分派；心跳返回值仍是 JSON | **已实施**（FLS1 状态帧） | ~200 B → ~84 B/条，省 ~60%（**估算**） | `status_frame.go` 的 `statusFieldOrder` 与 `core/bridge_status_frame.dart` 必须同序；JSON 兼容回退保留 |
| 5 | `groupNodes` / `speedTestOutbounds` | Dart 侧缓存 `groupNodesCache`（按 revision 失效）+ 移除空结果的 channel fallback；`speedTestOutbounds` 仍原样 | **部分实施**：`groupNodes` 缓存 + fallback 移除完成；分页/二进制行数组未做 | 重复打开降到 0 次跨桥调用；100–500 节点列表的字节节省（**估算**）未兑现 | `box_api.dart` 的缓存与失效路径；若再做分页需改 `speed_test_actions.go` 返回 shape |

**不建议动**的低价值项：`actionVersion`、四个 `*Done` 空事件、六个 `speedTestSession*` 控制方法（请求 <200 B、人工触发，`platform_request` 的二次 JSON 编码是 Kotlin 边界的既有约定，单独优化得不偿失）、`urlTestVpnStatus`。

## 四、已经做对的地方（不要重做）

- **日志 FLB1 帧 + typed-data 零拷贝**：`bridge_runtime.go:289-321`、`dartbridge.go:19-28,57-68`、`bridge_log_frame.dart:32-56`。每条只付 8 B 头，按 pump drain 成帧、256 条封顶（`:291,331-338`），Dart 不跑 JSON parser。
- **bulk 事件 + isolate 解码**：`box.dart:81-97,1449-1455,1762-1793`——`logs`/`logcat`/`connections`/`groups` 用 `StandardMessageCodec` 字节，>50 KB 自动 `Isolate.run` 解码，且按到达序串行（`_bulkQueue`）避免日志/连接乱序。
- **300 ms aspect 批处理**：`box.dart:605-606,668-679` 把 `logs`/`logcat`/`connections` 的重建合并成一帧（`batchWindow = 300ms`），后台时用 `_deferredAspects` 挂起。
- **16 ms 日志窗口 + 5000 行环形缓冲 / 512 行每批上限**：`log_batch.dart:8-17`、`service_entry.dart:474-527`、`box.dart:303-306`——service engine 只在有人看日志页时才跨 IPC 发；首开用 `reset:true` 一次性回放 ring（每批 ≤512 行）。
- **action 的 id 关联与单一长寿命 reply port**：`throne_kernel.dart:56-72,119-146`——不为每次调用新建 port；同步 FFI 抛错会清 `_pending`，避免死 Completer。
- **1 Hz 状态推送而非轮询**：`kernel_worker.dart` + `bridge_runtime.go`，且 `_publishStats` 用 `_statsInFlight` 丢弃重叠（`kernel_service.dart`）；推送载体已升级为 FLS1 定长帧（`core/bridge_status_frame.dart`），返回值仍与旧 JSON map 同形。
- **全局规则增量**：`getGlobalRules` 带 `version`/`etag`，`saveGlobalRulesPatch` 只传脏行并做陈旧检测（`route_actions.go`、`box_api.dart`）；全量 `saveGlobalRules` 路径保留兼容。
- **`speedTestResult` delta**：首帧全量、后续帧只发变化字段（`speed_test_delta.go`、`core/speed_test_delta.dart`），Dart 合并回全帧再交 UI；旧构建仍可读首帧。
- **`groupNodes` 缓存 + 无 fallback**：`box_api.dart` 的 `groupNodesCache`/`groupNodesCacheRevision` 按 revision 命中；profile/group 写入时失效；空结果不再回落 channel。

## 五、意外发现 / 待确认

1. **`speedTest` 事件在 Dart 侧有消费者却没有 Go 生产者**：`throne_kernel.dart:50-54` 会缓存 `method == 'speedTest'` 的帧并暴露 `speedTestStates`，但全仓 grep 只找到 `speedTestResult`（`bridge_runtime.go:361`）这一 wire 名；`speed_test_actions.go:5-7` 的注释也写明「progress feed 仍是 channel push」。这条流在 FFI 模式下可能长期为空——排优化优先级前应先确认它是否死代码。
2. **`message` 推送 tag 是空协议位**：`action.go:38` / `action.dart:61` 都定义了，Go 侧没有任何生产者。
3. **测试回调全部走 JSON 逐条**：`urlTestResult` / `ipTestResult` / `speedTestResult` 经 `postTo`（`bridge_runtime.go:268-274`）发到 `ReplyPort`，而 `ReplyPort` 也只挂了 `decodeBridgeEvent`（`throne_kernel.dart:204-211`）——它们没有 FLB1 那种批量路径。测速时这是唯一的「高频 JSON 行」来源，但它走 handler port、不经过本次 `ThroneKernel` 主 listener 的 hook，计数器默认看不到（除非显式从 `ReplyPort` 记录；本轮未改）。
4. **action 的 `data` 是 `json.RawMessage` 二次 unmarshal**：Dart `Action.encode()` 已编码一次，`throne_invoke_action` 再 `json.Unmarshal` 成 `Action`，handler 再 `json.Unmarshal(data)`（`bridge_runtime.go:147`、`route_actions.go:112`）——双层解码成本在小 payload 上可忽略，但在 `saveGlobalRules` 的整表上是实际开销。

## 六、如何读计数器（debug 构建）

`flutter/lib/core/bridge_metrics.dart` 的 `BridgeMetrics` 是进程级、默认关闭的计数器。在 debug 构建里尽早设 `BridgeMetrics.enabled = true`（例如 `main()` 中 `assert(() { BridgeMetrics.enabled = true; return true; }())`，只在 debug 生效），正常跑一遍「启动 → 打开路由页 → 跑一轮测速 → 开关日志页」，然后 `debugPrint(BridgeMetrics.snapshot().toString())` 打印快照：每个 key 是 wire 名（`status` / `speedTestResult` / `logFrame` / 具体 action 方法名），value 含 `count`、`bytes`、`decodeMicros`。`bytes` 对 JSON 取 `String.length`（UTF-16 code unit，ASCII 的 wire 上约等于字节数）、对二进制取 `Uint8List.length`；`decodeMicros` 只在 `ThroneKernel` 主 listener 里 `jsonDecode` 被调用时累计，因此**测速回调（`ReplyPort`）的事件不会计入 decode 时间**。`snapshot()` 返回不可变副本，可安全打印；对比一次 `reset()` 前后的两个快照即可只测某一段交互的增量。关闭状态下除一次布尔判断外不分配、不计时，生产路径零行为变化。
