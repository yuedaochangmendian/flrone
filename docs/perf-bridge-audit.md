# Bridge payload 审计（Phase 1，只读摸底）

本文盘点 Dart ↔ Go 桥上**每一条** action 方法和 Go→Dart 事件，目的是为后续二进制编码 / 分页 / 增量编码排优先级。本轮不改协议、不改处理逻辑，只新增一个默认关闭的 Dart 侧计数器（见文末「如何读计数器」）。所有「估算」字样的数据都是从 handler 的字段/调用点推导的**数量级估计**，不是实测采样；实测请用 `BridgeMetrics`。

## 范围与三条通道

| 通道 | 方向 | 入口 | 载体 |
| --- | --- | --- | --- |
| Action bus | Dart → Go → Dart(reply port) | `throne_invoke_action`（`buildScript/core-patch/core/mobile/bridge_runtime.go:141-155`）→ `dispatchAction`（同文件 `:179-203`）→ `postActionResult`/`postRaw`（`:157-174`） | JSON 字符串：`{"id","method","data"}` / `{"id","method","data","code"}`（`action.go:46-68`），经 Dart `Dart_PostCObject_DL`（`dartbridge.go:46-55`） |
| 事件推送 | Go → Dart(message port) | `sendEvent`（`bridge_runtime.go:206-215`）、`postTo`（`:268-274`） | JSON 字符串：`{"method","data"}`；同一 `sendToPort` |
| 日志帧 | Go → Dart(message port) | `sendLogFrame`（`bridge_runtime.go:310-321`），由 `logPump` 的 `WriteBatch`（`log.go:100-120`）喂入 | **FLB1 二进制帧**：`"FLB1" | count u32le | (level i32le | len u32le | utf8)*`（`bridge_runtime.go:289-308`），经 `GoDart_PostBytes` 零拷贝 typed-data（`dartbridge.go:19-28,57-68`）；Dart 解码在 `bridge_log_frame.dart:32-56` |

Dart 侧入口：`ThroneKernel` 构造里的两个 listener（`flutter/lib/core/throne_kernel.dart:31-55` 事件 / `:59-72` 结果）；JSON 事件解码是 `decodeBridgeEvent`（`throne_ffi.dart:442-449`），结果解码是 `ActionResult.decode`（`action.dart:93-113`）。注意 `ThroneKernel` 只看到**本进程内 FFI 桥**的消息；service engine 再把事件转发给 UI engine（`service_entry.dart:271-280`），那一段是 IsolateNameServer 的 IPC map，不属于本表的编码范畴。

## 一、Dart → Go action 方法（全部 13 个，含本轮新增的 `diagnosticsProfile`）

枚举与 wire 名的唯一来源是 `action.dart:17-57`（`ActionMethod`，成员名即 wire 串），Go 侧注册表见 `action.go:87-92`、`route_actions.go:54-58`、`speed_test_actions.go:35-38`、`test_session_actions.go:46-51`；`tools/diagnostics/action_contract.py` 对账两端。全部请求/响应都是**整条 JSON 字符串、无批处理、无分页、无增量编码**，编码成本 = 一次 `jsonEncode`（`action.dart:70-74`）+ 一次 C 字符串复制（`bridge_runtime.go:144`）+ `json.Unmarshal`（`:147`）+ 结果 `json.Marshal`（`:159`）+ Dart `jsonDecode`（`action.dart:96`）。

| method | data 形状 → 结果形状 | 调用方 | 频率 | 编码 / 批处理 | 大小估算（**估算**） |
| --- | --- | --- | --- | --- | --- |
| `actionVersion` | `null` → `{protocol:1, core:string}`（`action.go:97-102`） | 协议冒烟、诊断 | 一次性/手动 | JSON 字符串；无 | 请求 ~60 B，响应 ~90 B（`core` 版本串 ~20 字符） |
| `getGlobalRules` | 忽略 `profileId` → `{rules:[{id,name,type,disabled,action,outbound_id,<各 string/list/bool 列>,domain/domain_suffix/ip_cidr/process_name/network_type 简写}...]}`（`route_actions.go:82-102,244-282`） | `BoxApi.routeGlobalRules`（`box_api.dart:214`） | 路由页打开/刷新，人工触发，低频 | JSON 字符串；整表一次返回 | **估算**：单条规则 10–25 字段、~300–800 B；50 条规则 ~15–40 KB，100 条 ~30–80 KB。全表重传是这里的主要浪费 |
| `saveGlobalRules` | `{rules:[...同 get 的形状...]}` → 保存结果（`route_actions.go:108-179`） | `routeSaveGlobalRules`（`box_api.dart:218-223`） | 用户保存路由时，低频 | JSON 字符串；整表写回 | 同上量级，~15–80 KB（**估算**）；包含未变行 |
| `deleteGlobalRule` | `{id:int64}` → 保存结果（`route_actions.go:188`） | `routeDeleteGlobalRule`（`box_api.dart:226`） | 用户删一行，极低频 | JSON 字符串 | <100 B（**估算**） |
| `speedTestOutbounds` | `null` → `{outbounds:[tag:string,...]}`（`speed_test_actions.go:45-63`） | `SpeedTestApi.speedTestOutbounds`（`box_api.dart:626`） | 打开测速页，一次 | JSON 字符串 | 每 tag ~10–30 B；几十个出站 ~0.3–1 KB（**估算**） |
| `groupNodes` | `null` → `{nodes:[{id,tag,type,isSelector},...]}`（`speed_test_actions.go:80-102`） | `GroupCatalogApi.groupNodes`（`box_api.dart:594`），空结果会回落 channel | 选择器打开，低频，但无缓存每次重取 | JSON 字符串 | 每节点 ~60–120 B；100 节点 ~6–12 KB，500 节点 ~30–60 KB（**估算**） |
| `speedTestSessionStart` | `{kind,profileIds:int[],testCurrent,speedMode}` → host 的 JSON 原样（`test_session_actions.go:12,76-79`） | `groupTestSessionStart`（`box_api.dart:424`） | 每次测速开始 | JSON 字符串，经 `platform_request` 二次编码（`:57-72`） | 请求 <200 B；响应依 host，通常 bool/小 map（**估算**） |
| `speedTestSessionStop` | `{}` → host 响应（`test_session_actions.go:13`） | `groupTestSessionStop`（`box_api.dart:428`） | 每次停止 | JSON 字符串（两次编码） | <100 B（**估算**） |
| `speedTestSessionDismiss` | `{}` → host 响应（`:14`） | `groupTestSessionDismiss`（`box_api.dart:437`） | 用户关闭测速卡 | JSON 字符串（两次编码） | <100 B（**估算**） |
| `speedTestSessionSort` | `{groupId}` → bool（`test_session_actions.go:15`） | `groupTestSessionSort`（`box_api.dart:430`） | 用户拖排序 | JSON 字符串（两次编码） | <100 B（**估算**） |
| `speedTestSessionRemove` | `{ids:int[]}` → `{removed:N}`（`test_session_actions.go:16`） | `groupTestSessionRemove`（`box_api.dart:433-436`） | 用户删记录 | JSON 字符串（两次编码） | 请求依选择数，10 个 id ~80 B（**估算**） |
| `speedTestSessionVisible` | `{visible:bool}` → true（`test_session_actions.go:17`） | 测速页可见性变化 | 页面切换 | JSON 字符串（两次编码） | <100 B（**估算**） |
| `diagnosticsProfile` | `{kind: cpu|heap|goroutine|allocs|block, seconds:N, dir:string}` → `{files:[string],kind,seconds,bytes}`（`profile_actions.go`；需 `dir` 内的 `profile.enable` 标记，否则拒绝） | 调试工具（`invokeWire` 或 `ThroneKernel.invoke`；本轮无 UI 入口） | 手动触发 | JSON 字符串；CPU 5–60 s、单飞 | 请求 <200 B；响应为文件路径列表（**估算**） |

`message`（`action.go:36-38`）是预留的**无 id 推送 tag**，Dart 侧常量 `actionPushMethod`（`action.dart:59-61`）；当前树里既无 `sendEvent("message", …)` 也无 `postTo(..., "message", ...)` 的生产者，属于空协议位（见「意外发现」）。

## 二、Go → Dart 事件（message port + reply port）

全部事件由 `sendEvent` / `postTo` 走 `json.Marshal(map{"method","data"})`（`bridge_runtime.go:213,272`），**逐条、无批处理、无增量**；Dart 在 `decodeBridgeEvent`（`throne_ffi.dart:442-449`）逐条 `json.decode`。`postActionResult` 是同一 port 上的**另一种 shape**（带 `id`/`code`），由 reply port listener 处理（`throne_kernel.dart:59-72`）。`ReplyPort`（`throne_kernel.dart:204-227`）是一次性 handler port，给 URL/IP/Speed 测试的回调用——它**也调 `decodeBridgeEvent`**，因此这些事件同样落在 JSON 路径上。

| method | data 形状 | 生产者 / 调用方 | 频率 | 编码 / 批处理 | 大小估算（**估算**） |
| --- | --- | --- | --- | --- | --- |
| `status` | `{memory,goroutines,connectionsIn,connectionsOut,uplink,downlink,uplinkTotal,downlinkTotal,trafficAvailable}` 9 个 int（`bridge_runtime.go:240-256`） | `throne_status_snapshot`（`:217-259`），Dart 心跳 `Timer.periodic(1s)`（`kernel_worker.dart:86`）→ `KernelService._onKernelStatus`（`kernel_service.dart:996-1024`） | **1 Hz 常驻**（只要核心在跑） | JSON 字符串；逐条。返回值（同 map）另走 FFI 返回值 | ~170–220 B/条（**估算**）；1 Hz ≈ 10–15 KB/分钟 |
| `urlTestResult` | `{tag,latencyMs,err}`（`bridge_runtime.go:343-345`） | `portURLTest.OnResult`，每个 tag 一次 | 一次测速 N 个节点 → N 条，突发 | JSON 字符串；逐条，走 `ReplyPort` | ~60–100 B/条；50 节点 ~3–5 KB（**估算**） |
| `urlTestVpnStatus` | `{tag,connected,state,err}`（`:346-348`） | 每个失败的 VPN endpoint tag 一次（`:746-751`） | 低频 | JSON 字符串；逐条 | ~80–140 B（**估算**） |
| `urlTestDone` | `null`（`:349`） | 一次测速结束 | 一次/测速 | JSON 字符串 | ~45 B（**估算**） |
| `ipTestResult` | `{tag,ip,countryCode,err}`（`:353-355`） | `portIPTest.OnResult` | N 个节点 → N 条 | JSON 字符串；逐条 | ~70–130 B/条（**估算**） |
| `ipTestDone` | `null`（`:356`） | 结束 | 一次 | JSON 字符串 | ~45 B（**估算**） |
| `speedTestResult` | `SpeedTestResult` 全字段 11 个：`{Tag,DlSpeed,UlSpeed,Latency,ServerName,ServerCountry,Error,Cancelled,DlBytes,UlBytes,Running}`（`test.go:71-83`，`flattenSpeedTestResult` 在 `:341-356`；Go 默认字段名即 wire 名） | `portSpeedTest.OnResult`（`bridge_runtime.go:360-362`）；`newTestReporter` 以 `testReportInterval = 200ms` 发进度（`test.go:16,194`） | **5 Hz × 测速时长（估算 10–30 s → 50–150 条）** | JSON 字符串；逐条，走 `ReplyPort` | ~250–350 B/条（**估算**，两个速度串+服务器名+错误串）；一轮 ~12–50 KB |
| `speedTestDone` | `null`（`:363`） | 结束 | 一次 | JSON 字符串 | ~45 B（**估算**） |
| `log`（JSON 形态） | `{level:int,message:string}` | 仅 Kotlin host sink 与旧版 Dart 用；Dart 侧已从 FLB1 帧合成同 shape（`throne_kernel.dart:36-41`）。Go 中 `sendEvent("log", …)` 已无生产者（Go 的 log 全走帧） | Dart 路径 0；host 路径逐行 | JSON 字符串；逐行（已退役于 Dart） | 每行 ~100–300 B（**估算**） |
| `FLB1` 帧（binary，无 `method`） | `"FLB1" | count u32le | (level i32le | len u32le | utf8 bytes)*`，最多 256 条/帧（`bridge_runtime.go:289-308`） | `portLogSink.Write/WriteBatch`（`:323-339`），由 `logPump`（`log.go:100-120`）驱动 | **最高频**：连接事件每行一条，启动时突发数百行；帧按 pump drain 聚合 | **二进制 typed-data**；每批一帧，帧上限 256 条；无二次批处理 | 8 B/条头开销 + 消息长度；256 行 × ~120 B ≈ 31 KB/帧（**估算**） |
| action result | `{id,method,data,code}`（`action.go:56-62`） | `postActionResult`（`bridge_runtime.go:157-164`），每个 action 一次 | 与 action 调用 1:1 | JSON 字符串；无 | 依 data，见 action 表（**估算**） |

**跨 engine 的补充通道**（非 Go 桥，但常被混为「日志还是逐行 JSON」）：service engine 把内核日志按 `receivedAt\tlevel\tmessage` 拼成**一个字符串**批量推给 UI（`service_entry.dart:474-527`，16 ms 窗口 `log_batch.dart:8`，ring 上限 `logRingLimit=5000`、每批最多 `maxKernelLogBatchLines=512` 行），UI 侧 `_applyLogs`（`box.dart:1836+`）合并。Kotlin host 的高频 feed（logs/logcat/connections/groups）走 `StandardMessageCodec` 二进制 bulk（`box.dart:81-97,1449-1455,1762-1793`），>50 KB 自动切到后台 isolate——这两条路径与 Go 桥无关，不要重复优化。

## 三、Top 5：二进制编码 / 分页 / 增量编码候选

排序按「估算字节量 × 频率 × 当前 Dart 主线程成本」，并考虑契约改动面。全部是**建议**，本轮未实施。

| # | 目标 | 建议 | 预期收益（**估算**） | 契约 / 测试影响 |
| --- | --- | --- | --- | --- |
| 1 | `getGlobalRules` / `saveGlobalRules` | 改**增量编码**：`get` 带 `version/etag`，规则行按 id 做 patch（新增/修改/删除三类），`save` 只回传脏行；或先退一步做 `StandardMessageCodec` 二进制行数组 | 路由页每次重取省 ~90% 字节（若规则稳定）；编辑一次不再回传整表 ~15–80 KB（**估算**） | 改 Go handler 返回 shape + Dart `box_api.dart:214-223`；`route_crud_test.go`、`action_contract.py` 需同步；需定义版本号与冲突语义（Go 是唯一写者，版本好定） |
| 2 | `FLB1` 帧 | **已经是最优路径**，不建议重编码；只建议把 256 条上限与 16 ms/512 行的 service 窗口联动调参（如需），并给 `decodeBridgeLogFrame` 加计数 | 边际收益小；主要价值是观测 | 契约已在 `log_frame_test.go` 与 bridge_metrics 测试中固定；改帧格式必须同时改 Go 编码器、Dart 解码器、测试 |
| 2 | `speedTestResult` 进度 | **增量 + 二进制**：只发变化的字段（速度串/字节数/Running），tag 只发一次；或复用一个定长二进制帧 | 5 Hz × 30 s ≈ 150 条 × ~300 B ≈ 45 KB → 省 ~70–85%（**估算**），并去掉每帧 `jsonDecode` | 改 `SpeedTestResult` 的 wire（`test.go:71-83`）、`portSpeedTest.OnResult`、`ReplyPort`；`throne_kernel.dart:50-54` 的 last-frame 合并语义要保留；需新测试覆盖「只发 delta 时 UI 仍有全量帧」 |
| 4 | `status` | **二进制定长帧 / delta**：9 个 int64 可压到 ~72–80 B 定长，`trafficAvailable` 位标记；只对变化字段增量 | 1 Hz 常驻：~200 B → ~80 B/条，省 ~60%（**估算**，约 7 KB/分钟） | 新增一种非 FLB1 的二进制帧类型 → `ThroneKernel` 的 listener 需要按 magic 分派（影响事件顺序风险，须测试）；`kernel_service.dart:996-1024` 解析要兼容旧 JSON（过渡期双读） |
| 5 | `groupNodes` / `speedTestOutbounds` | 结果加**分页/游标**（`nodes` 按 group 分批）或二进制行数组；先在 Dart 侧缓存（当前 `box_api.dart:594` 每次重取且空结果回落 channel） | 100–500 节点列表省 ~50–70% 字节与一次全量 decode（**估算**）；缓存可把重复打开降到 0 次跨桥调用 | 改 `speed_test_actions.go:80-102` 返回 shape + `box_api.dart:594,626`；`speed_test_bus_facade_test.dart` 与 Go 侧 handler 测试要更新；分页会引入「打开选择器时是否已有全部页」的语义问题 |

**不建议动**的低价值项：`actionVersion`、四个 `*Done` 空事件、六个 `speedTestSession*` 控制方法（请求 <200 B、人工触发，`platform_request` 的二次 JSON 编码是 Kotlin 边界的既有约定，单独优化得不偿失）、`urlTestVpnStatus`。

## 四、已经做对的地方（不要重做）

- **日志 FLB1 帧 + typed-data 零拷贝**：`bridge_runtime.go:289-321`、`dartbridge.go:19-28,57-68`、`bridge_log_frame.dart:32-56`。每条只付 8 B 头，按 pump drain 成帧、256 条封顶（`:291,331-338`），Dart 不跑 JSON parser。
- **bulk 事件 + isolate 解码**：`box.dart:81-97,1449-1455,1762-1793`——`logs`/`logcat`/`connections`/`groups` 用 `StandardMessageCodec` 字节，>50 KB 自动 `Isolate.run` 解码，且按到达序串行（`_bulkQueue`）避免日志/连接乱序。
- **300 ms aspect 批处理**：`box.dart:605-606,668-679` 把 `logs`/`logcat`/`connections` 的重建合并成一帧（`batchWindow = 300ms`），后台时用 `_deferredAspects` 挂起。
- **16 ms 日志窗口 + 5000 行环形缓冲 / 512 行每批上限**：`log_batch.dart:8-17`、`service_entry.dart:474-527`、`box.dart:303-306`——service engine 只在有人看日志页时才跨 IPC 发；首开用 `reset:true` 一次性回放 ring（每批 ≤512 行）。
- **action 的 id 关联与单一长寿命 reply port**：`throne_kernel.dart:56-72,119-146`——不为每次调用新建 port；同步 FFI 抛错会清 `_pending`，避免死 Completer。
- **1 Hz 状态推送而非轮询**：`kernel_worker.dart:86` + `bridge_runtime.go:217-259`，且 `_publishStats` 用 `_statsInFlight` 丢弃重叠（`kernel_service.dart:1044-1050`）。

## 五、意外发现 / 待确认

1. **`speedTest` 事件在 Dart 侧有消费者却没有 Go 生产者**：`throne_kernel.dart:50-54` 会缓存 `method == 'speedTest'` 的帧并暴露 `speedTestStates`，但全仓 grep 只找到 `speedTestResult`（`bridge_runtime.go:361`）这一 wire 名；`speed_test_actions.go:5-7` 的注释也写明「progress feed 仍是 channel push」。这条流在 FFI 模式下可能长期为空——排优化优先级前应先确认它是否死代码。
2. **`message` 推送 tag 是空协议位**：`action.go:38` / `action.dart:61` 都定义了，Go 侧没有任何生产者。
3. **测试回调全部走 JSON 逐条**：`urlTestResult` / `ipTestResult` / `speedTestResult` 经 `postTo`（`bridge_runtime.go:268-274`）发到 `ReplyPort`，而 `ReplyPort` 也只挂了 `decodeBridgeEvent`（`throne_kernel.dart:204-211`）——它们没有 FLB1 那种批量路径。测速时这是唯一的「高频 JSON 行」来源，但它走 handler port、不经过本次 `ThroneKernel` 主 listener 的 hook，计数器默认看不到（除非显式从 `ReplyPort` 记录；本轮未改）。
4. **action 的 `data` 是 `json.RawMessage` 二次 unmarshal**：Dart `Action.encode()` 已编码一次，`throne_invoke_action` 再 `json.Unmarshal` 成 `Action`，handler 再 `json.Unmarshal(data)`（`bridge_runtime.go:147`、`route_actions.go:112`）——双层解码成本在小 payload 上可忽略，但在 `saveGlobalRules` 的整表上是实际开销。

## 六、如何读计数器（debug 构建）

`flutter/lib/core/bridge_metrics.dart` 的 `BridgeMetrics` 是进程级、默认关闭的计数器。在 debug 构建里尽早设 `BridgeMetrics.enabled = true`（例如 `main()` 中 `assert(() { BridgeMetrics.enabled = true; return true; }())`，只在 debug 生效），正常跑一遍「启动 → 打开路由页 → 跑一轮测速 → 开关日志页」，然后 `debugPrint(BridgeMetrics.snapshot().toString())` 打印快照：每个 key 是 wire 名（`status` / `speedTestResult` / `logFrame` / 具体 action 方法名），value 含 `count`、`bytes`、`decodeMicros`。`bytes` 对 JSON 取 `String.length`（UTF-16 code unit，ASCII 的 wire 上约等于字节数）、对二进制取 `Uint8List.length`；`decodeMicros` 只在 `ThroneKernel` 主 listener 里 `jsonDecode` 被调用时累计，因此**测速回调（`ReplyPort`）的事件不会计入 decode 时间**。`snapshot()` 返回不可变副本，可安全打印；对比一次 `reset()` 前后的两个快照即可只测某一段交互的增量。关闭状态下除一次布尔判断外不分配、不计时，生产路径零行为变化。
