# P7 — 数据权威向 Bettbox 对齐：分阶段迁移方案（不实现）

- 日期：2026-11-19
- 基线：分支 `p7/data-slice` @ `28095f1f`（`p6/integration`）
- 状态：提案。本轮只落地「阶段 0：WebDAV 连通性检查」的可独立切片；其余为可执行方案。
- 相关：[ADR 0002](adr/0002-bettbox-alignment.md)（数据权威边界）、[ADR 0004](adr/0004-strict-bettbox-parity.md)（P1–P5 范围与护栏）

## 为什么必须分阶段（先纠正一个前提）

任务描述假设 `WebDavApi`/`BackupApi` 的 7–9 个方法「只做 HTTP/文件 IO」。逐个读代码后结论是**只有 `webdav.check` 成立**：

| 方法 | Kotlin 实现 | 真正依赖 | 能否纯 Dart |
| --- | --- | --- | --- |
| `webdav.get` / `webdav.set` | `BboxBackup.webdav()/setWebdav()` | `DataStore.webdav*`（Room `settings` 表的 4 行） | 否（除非把 Room 设置权威搬走，见阶段 2） |
| `webdav.check` | `BboxBackup.checkWebdav()` → `WebDavBackup.check()` | 只做 PROPFIND/MKCOL HTTP | **是** |
| `webdav.upload` | `uploadWebdav()` → `BackupExport.write()` + `WebDavBackup.upload()` | Room 全库导出成 THRN 容器 | 否（THRN 编码器 + Room） |
| `webdav.read` | `readWebdav()` → `BackupRestore.load()` | THRN 解码 + 临时 SQLite | 否 |
| `backup.create/open/restore` | `BboxBackup` | THRN 容器、`BackupRestore`、`GroupRepo`/`ProfileManager` | 否 |

`BboxBackup` 还被 `BboxProfiles.decodeFile()`、`ThroneBoxBridge.openBackupDocument()` 复用（`git grep BboxBackup` 可复核），所以「删掉整个 BackupApi」在本轮不成立。本轮按 ADR 0002 的判据「**权威在哪，写者就在哪；能读到数据 ≠ 该由它处理**」，只迁能力完整、依赖为零的 `webdav.check`。

### 本轮已落地（阶段 0）

- 新增 `flutter/lib/services/webdav_client.dart`：纯 Dart WebDAV 传输（`dart:io` + `dart:convert`，零新依赖），实现 `check()`（PROPFIND Depth 0，404 时逐级 MKCOL，Basic auth，重定向不跟随，connect/read 超时）、`downloadBytes/downloadToFile`、`uploadBytes/uploadFromFile`（后两组供阶段 4 复用）。
- `BoxController` 增加可注入 `webDavChecker`（沿用 `RouteProfilesAttach` 的注入模式）；`webdavCheck()` 保持现有 `Future<dynamic>` 签名与布尔返回：先 `webdav.get` 取账户（仍是 Room 读），再在 Dart 侧探测。
- 删除 Kotlin `"webdav.check"` handler 与 `BboxBackup.checkWebdav()`（grep 证明无其他 Kotlin caller）。`channel_audit` 由脚本动态统计，handler 118→117、Dart caller 144→143，contract OK；无硬编码计数需同步。
- 测试：`flutter/test/webdav_client_test.dart` 用 `HttpServer.bind(loopback)` 假服务器覆盖成功/404 后 MKCOL/401/超时/文件不存在（远端与本地两条）/上传字节/默认 checker；`backup_test.dart` 注入确定性 checker 并断言不再走 `webdav.check` 通道。
- 验收：`flutter analyze` 干净，`flutter test` 691/691 绿，`channel_audit.py` 通过。

---

## 全局约束（所有阶段通用）

1. 不改 `kernel_service` / `service_entry` / service engine；不碰 AIDL。
2. 不新增 pub 依赖。Dart 侧已有 `sqlite.dart`（cgo 无关的纯 `dart:ffi` 直连系统 libsqlite3）、`UiDocuments`（Go 拥有的 JSON 文档）；**优先复用**，不要引入 `sqlite3`/`drift`/`path_provider`。若未来确需 `drift`，必须单独立项评估「AAR GeneratedPluginRegistrant 被宿主反射加载失败静默吞掉」的插件风险（见 `data/sqlite.dart` 顶部注释）。
3. 一个域只有存储权威也在 Dart/Go 时才算迁完；仅注册 handler 不算（ADR 0002 修订）。
4. 每阶段一个 PR；CI 三重门禁（`symbol_audit` / `channel_audit` / `action_contract`）全绿才合入；删 handler 前 `git grep` 证明零引用。

---

## 阶段 1：WebDAV get/set 与账户配置（删 2 个 handler）

**目标**：让 `webdav.get/set`（账户 URI/用户/密码/目录）成为 Dart 拥有的 JSON 文档，Room 只保留只读兼容。

**依赖图**：`DataStore.webdavServer/Username/Password/Path` → `SettingsRegistry.ANDROID_KEYS` + `DEVICE_LOCAL_KEYS`（备份永不导出）、`WebDavBackup.configured()`、`BboxBackup.webdav()/setWebdav()`。字段是设备本地的，Kotlin 没有别的读方（native WebDAV 设置 UI 已下线，`git grep` 仅命中 Registry 与 DataStore）。

**做法**：把 4 个键写进 `UiDocuments`（`host_facts.json` 或新增 `webdav.json`）经 `preferences.set` 的既有文档通道落盘；Dart 侧 `WebDavAccountStore` 读写同一文档，Kotlin `webdav.get/set` 删除，`BboxBackup.webdav()/setWebdav()` 与 `WebDavBackup.configured()` 改为从该文档读（为阶段 4 的容器 codec 留只读桥）。`DEVICE_ID`/`DEVICE_NAME` 同理但保留 Kotlin 生成。

**验收**：配置保存后冷启仍在；一次备份/恢复往返账户不丢失；`channel_audit` handlers 117→115；`SettingsRegistry` 设备本地集合不变（备份仍不导出凭据）。

**风险**：`WebDavBackup` 仍编译依赖 DataStore 字段，改动要同时保留旧字段读取的兼容路径，否则存量用户升级后账户「消失」。缓解：一次版本内双写（Dart 文档 + Room），下一版本再删 Kotlin 侧字段。

## 阶段 2：settings（4 + preferences.set，共 5 个方法）

**目标**：区分 UI-only 与 Kotlin service 消费的键，只迁前者。

**键分类（`SettingsSchema.kt` 与 `bg/` 实测）**：
- **UI-only overlay**（可进 Dart）：主题、字号、排序、卡片布局、`logcatLevel`、`restoreStrategy` 等——当前已由 `UiDocuments.readUiSettings()`/`preferences.json` 承载，`settingsWire()` 里 `ThroneSettings.read()` 覆盖其上。
- **Kotlin service/VpnService 必读**（必须留 Kotlin 或双向同步）：`remoteDns`/`directDns`（`Apply.Reload`，`CoreConfigs`）、`vpnAllowBypass`、`allowBypass`、`mode`、`enableMux`、`appTLSVersion` 等，以及 `DataStore.selectedProxy`/`runningProfiles`/`runningRouteId`（`BboxKernel.buildStartOptions()`、`ProfileManager.runningUses()`）。这批键经 `SettingsRegistry` → `DataStore` → `bg/proto/CoreConfigs.kt` 参与配置生成，Dart 无法独立拥有。

**做法**：先把 overlay 键的读写彻底搬到 Dart（`settings.get/patch/reset` 的 UI-only 分支由 Dart 直接读写文档，只有命中 `ThroneSettings.has(key)` 的键才落到 `settings.set` 通道）；preferences 同理。保留的 `settings.set`/`settings.patch` 收窄为「只接受 Kotlin 权威键」，`channel_audit` 的 DYNAMIC_SITES 与 `settings_contract.py` 同步。

**验收**：UI-only 键写入后重启保留且不触发 `applyRequired` badge；service 键写入仍触发 Reload/AppRestart（现有 `settings_channel_test.dart` 行为不变）；`channel_audit` handlers 净减 2–3。

**风险**：`settingsWire()` 三层合并（overlay + ThroneSettings + derived）是静默覆盖关系，迁 overlay 后要防止 Dart 缓存陈旧值盖住 Kotlin 新值——建议 Dart 侧每次 `settings.get` 重新合并而非缓存整图；这也是 ADR 0002 曾把 settings 整体退回 channel 的原因，必须避免重蹈。

## 阶段 3：routes（2 + routes.list/presets/ruleSets，共约 14 个方法）

**边界**：`RouteJsonStore`（Kotlin，读写 `<filesDir>/documents/routes.json` 等文件）与 `RouteManager`（Room 三表）已并行存在；Go 侧 `route_actions.go` 注册 `getRouteProfiles`/`saveRouteProfile`/`getRouteRules`/`saveRouteRules`/`setCurrentRoute` 等 action（已由 `action_contract.py` 三向校验）。Dart 已通过 action bus 调用它们（`box_api.dart` 的 `RoutesApi`）；`routes.list` 仅作无 FFI 时的 channel fallback，`RouteProfilesSource` 已用 `data.path` + `dart:ffi` 直接复现 Room 读。

**能否把 CRUD 移到 Dart JSON 文件而 Go 继续读**：可以，但要改 Go 的文档路径与 Dart 写同一份文件——当前 Go 是唯一写者，README/ADR 明确「kernel owns the route documents」。若 Dart 也写，就必须把 `__current` 标记、`state.setCurrentRoute` 的 `DataStore.currentRouteId`（Room）同步写入，否则配置生成仍读旧选择（见 `routeSetCurrentHost` 注释）。因此**不建议再开第二个写者**；正解是完成既有 action bus 迁移后，把 `routes.list` fallback 降级为「仅诊断」并最终删除，让 Go 文档成为单一权威，Dart 只读其 JSON（`RouteJsonStore.directory` 指向的同一路径）。

**步骤**：① 确认 `routeGetProfile/routeRules/routeSaveRules/...` 全部走 action bus 且无 channel 实现（现状已成立）；② `routeRuleSets`（读已安装规则集文件）目前是 channel，可改成 Dart 扫描 `filesDir` 下规则集目录（复用 `document.save`/`data.path` 的目录事实）——这一步能删 1 个 handler；③ 待 service engine 常驻后删 `routes.list` fallback 与 `data.documents` seed（kernel 自持文档），每步 `channel_audit` 同步。

**验收**：断网/无 FFI 时路由页给出明确错误而非陈旧数据；切当前路由后 `config.build` 立即使用新集合（`BboxKernel.buildStartOptions` 实测）；`action_contract.py` 三方相等。

**风险**：Go 与 Dart 双写路由文档会立刻产生「两写者不一致」（ADR 0002 在 profiles 上已踩过一次），必须一次只留一个写者；`RouteJsonStore` 的 JSON schema 用 Kotlin `JsonObject` encoder，Dart 直接写要保证字段名/类型逐字一致。

## 阶段 4：backup/WebDAV 容器与文件（删剩余 8 个方法）

**目标**：THRN 容器 codec 与 Room 导出改为 Dart/Go 拥有，从而删掉 `backup.create/open/read/restore`、`webdav.upload/read`。`document.save` 不在此列——它还有 `logs.dart`（日志导出）和 `profiles.dart`（配置导出）两个调用方，是通用的「保存到文件」平台能力，属保留集。

**前提**：阶段 1–3 已完成，Room 不再是 profiles/routes/settings 的唯一写者，或至少 Dart 已能只读导出等价数据（`DataLayer` 已只读打开 `sager_net.db`，可扩展到全部 7 表）。THRN 格式（`ThrBackup.kt`：MAGIC `THRN`、u32 版本、`files` 映射、meta JSON）是纯字节协议，可用 Dart `ByteData` 重写；`BackupExport` 的 SQL 导出改为从 Dart SQLite 只读表生成。

**做法**：新增 `services/backup_store.dart`：`create(scope)` 导出 JSON 文档→THRN，`open/restore` 反向；`webdav.upload/read` 复用阶段 0 的 `WebDavClient.uploadBytes/downloadBytes` + `throne_backups.json` 索引（Kotlin `WebDavBackup` 的完整协议已在同文件注释里，可直接逐条移植）。Dart 侧保持现有 envelope 形状（`format/createdAt/profiles[]/thr/ui`），页面零改动；删除 Kotlin `BboxBackup`、`WebDavBackup` 与全部 backup/webdav handler。

**验收**：Dart 生成的 `.thrbackup` 能被现有 Kotlin/桌面版恢复（互操作测试，至少 1 个真实 room 样本往返）；本地/WebDAV 备份恢复后收藏与设置不丢；`channel_audit` backup/webdav 归零。

**风险**：这是全案最高风险——THRN 的 id counter/表修复/设置合并规则在 `BackupRestore` 里非常细，重写任何偏差都会不可逆丢用户数据；必须双跑对照（旧 Kotlin 恢复与新 Dart 恢复对同一容器产出相同 DB）一段时间后才删 Kotlin。

## 阶段 5：profiles（任务描述称 24 个方法；实测 bridge 中 32 个 `profiles.*` handler）

先说明口径差异：`ThroneBoxBridge.kt` 里 `profiles.*` 的 `when` 分支实测 32 个（`git grep '"profiles\.'` 可复核）；任务描述的 24 可能只计 Dart 侧 `box_api.dart` 的调用（22 个）或某个子集。无论按哪个口径，结论不变：**大部分不应迁**。

ADR 0002「迁移边界」已逐项判定：`profiles.*` 31 个 channel 动作中 9 个已有 Go handler、22 个依赖 `parseOutbounds/OutboundFactory/ProfileJson`、反射 `Mux`/`Tls`、`exportLink`、`AutoSelectorRuntime`、控制面（select/update）等**完整出站协议模型**。把任何一个搬走都要把第二个实现带进 Go/Dart，必然漂移——**判定为「不该迁」，不是「还没做」**。

本阶段实际可做的只有：
- **`profiles.read/config/write`**：若阶段 4 后 Room 已有 Dart 只读镜像，可把纯 reads（`config/read`）改为 Dart SQLite 读，删 2 个 handler；`write` 涉及 revision 校验与 guarded write，保留 Kotlin。
- **`profiles.clearTestResults/clearTraffic/reorder`**：已有 Go action（`ActionMethod.*`），待 service engine 常驻后删 channel fallback 3 个 handler。
- **`profiles.stats`**：读 `BboxBridge.state` 内存快照，属控制面保留集，不迁。

**验收**：仅当某 handler 同时满足「Dart 有等价只读实现 + 无 Kotlin 写者 + 无第二个模型」才删；每次删前 `git grep`。`channel_audit` 逐步下降但不设清零目标。

**风险**：把 profile 出站模型搬成第二实现是最容易犯的错；守住 ADR 0002 第 3 判据（能力归属层，而非数据位置）。

**结果（P13，2026-11-19）**：没有搬出站模型，也没有保留 32 个命名 handler。实现为一个 `profiles.platform` 平台职责边界：`{op, payload}` 交给 `BboxProfileDuty`（27 个 op：解析/校验、订阅队列、选择设置、自动选择器运行时），Dart 侧只剩 `profilePlatform`/`_profileDutyAct` 两个入口；数据写入仍走 `profiles.applyDocument`，Dart 仍是文档唯一写者。`profiles.list/scan/scan.close` 无调用方直接删除，`profiles.importFile` 是 SAF 平台 UI，改名 `files.pickProfile`。Go 侧读写 Room 的 `profile_actions.go`/`autoselector_actions.go` 随 Room 权威结束一并删除（32→23 个 action）。op 表与 Dart 调用点由 `platform_duty_audit.py` 双向校验（channel_audit 74 handlers，原 104）。

---

## 状态管理（Riverpod）：成本评估与渐进方案

**现状**：`flutter/lib` 277 个 Dart 文件；`BoxController extends ChangeNotifier` + `BoxScope`（InheritedWidget）+ `BoxAspect`/`BoxEventBus` 单一事实源，11 个文件直接用 ChangeNotifier。ADR 0002 决策 8 与 ADR 0004 明确 P1–P6 都不改状态框架。

**引入 `flutter_riverpod` 的成本**：pubspec 是新依赖（违反本轮「切片不新增依赖」，故列为后续独立立项）；但 Riverpod 本身是纯 Dart（无 Android plugin），AAR 插件注册风险低。真正的成本不在依赖，而在 **35+ widget 测试与 vendored `lib/ui`** 对 `BoxScope.of(context)` 的硬依赖：一次性全量改写会让这批测试和页面同时失效，且双写期（Riverpod + ChangeNotifier 同时作为事实源）必然产生状态漂移——ADR 0001 正是因此否决了「Riverpod + globalState 双写」。

**渐进方案（新代码用 Riverpod，旧代码逐步适配）**：
1. 引入 `flutter_riverpod` + 一个**单向桥**：`boxProvider = Provider<BoxController>((ref) => BoxScope.of(context))` 不可行（Provider 拿不到 context），改为在 `BoxApp` 顶部挂 `ProviderScope` 并用 `Provider<BoxController>((ref) => rootController)` 注入同一个实例；同时为 `settings`/`preferences`/`dashboard` 各建 `ValueNotifier`-backed `ChangeNotifierProvider`，其 `notifyListeners` 由现有事件总线 `BoxEventBus` 的对应事件驱动（单向：BoxController → Riverpod provider，**绝不反向写**）。
2. **第一批试点页面**：`SettingsPage` / `ConnectivitySettingsPage`（`lib/components/connectivity/connectivity_store.dart`）——它们是纯 UI-only 键 + 现有 checker，改动面小、可对照 `settings_channel_test.dart` 回归。试点页用 `ConsumerWidget` 读 provider，但**仍通过 `context.box.setSetting()` 写**（写路径不变），验证单向桥无漂移。
3. 第二批：`BackupPage`（本轮已注入 checker，天然适合 provider 化）、`dashboard`。每批必须保留旧 ChangeNotifier 页面作为回退至少两个版本。
4. 适配完成度以「某 provider 的唯一写入者是 BoxController」为验收；只有当所有读方迁完后，才把 BoxController 的对应字段改为 provider 独占并删 ChangeNotifier 字段——这一步才算真正迁移，不是加一层壳。

**验收**：每次试点 analyze/test 全绿；`BoxScope`/`BoxAspect` 行为在混合树里不变；无「Riverpod 改了值但 UI 仍显示旧值」的双写窗口。

**风险**：`ProviderScope` 必须包住整个 `BoxApp`，vendored `lib/ui` 页面若自行创建 `BoxScope` 会拿到两个 controller 实例——需要用同一个 root 实例并加断言（debug 下比较 `identical`）；异步 provider 的 loading/error 语义要与现有 `ErrorState` 对齐，避免 UI 回归。

---

## 阶段总表与全局验收

| 阶段 | 删 handler 数（估） | 主要风险 | 验收门禁 |
| --- | --- | --- | --- |
| 0（本轮） | 1 | 低 | analyze + 691 tests + channel_audit |
| 1 webdav账户 | 2 | 中（Room 兼容） | 冷启/备份往返 + audit |
| 2 settings overlay | 2–3 | 中（三层合并漂移） | settings_channel_test + audit |
| 3 routes 收尾 | 1–3 | 中高（双写者） | action_contract + 切路由→config.build |
| 4 backup 容器 | 8+ | 高（不可逆丢数据） | 互操作 + 双跑对照 + audit |
| 5 profiles 可选 | 2–5 | 高（第二模型） | 逐项判据 + grep |
| Riverpod（并行） | 0 | 中（双事实源） | 单向桥 + 试点页回归 |

**全局完成标准**：`channel_audit` 只剩 ADR 0002 决策 5 的保留集（VpnService/TUN、通知、`state.stats`、`wifi.watch`、`apps.*`、SAF、`data.path`、FFI 交接）；三重 CI 门禁全绿；真实设备备份/恢复/连接/测速回归无数据丢失。任何阶段若导致「权威分裂」（两个写者）或「第二实现」（同模型两份代码），立即停下重新设计，不为降低方法数而迁。
