# ADR 0006 — 纯文件数据层：数据层越少越好

- 状态：已接受（2026-11-20）。Stage A/B、Stage C2b、C2c1、C2c2a 与 C2c2b 已落地（各自 PR）；C2c2b2 删除了 Room 的全部代码（实体/DAO、`SagerDatabase`、`RoomToJsonMigration`、Dart 侧只读 Room 数据面、Gradle Room/KSP 依赖与 `app/schemas`），活数据层只剩文档。
- 决策来源：架构复盘（与 Bettbox 对比）后的目标架构钦定——**纯文件数据层（数据层越少越好）+ 双引擎 + IPC + Action wire**。双引擎/IPC/Action wire 是继承自 Bettbox 的骨架，保留不动；消灭的是「Room 这层异构」。

## 为什么（实证，不是偏好）

2026-11-20 的数据层排查实锤了一类反复出现的 bug 全部住在 Room 异构层：

1. **备份/恢复 routes 与活存储脱节**（stage A 修）：自 ADR 0002 phase 3c 起 routes 的活存储是 Go 的 `documents/route_*.json`（kernel 唯一写者），Room 的 route 表在 `RoomToJsonMigration`（"a hand-over, not a sync"）之后**冻结**。而备份导出注释写着 "routes…still come from Room"、恢复把 rows 写进 Room——**备份导出的是冻结快照（用户的路由编辑从不进备份），恢复写的是死表（恢复后路由不变）**。
2. 本轮修复的「恢复 FK 终检 / 单边恢复引用清理（resetSourceGids）/ 默认路由播种」全部作用在这条死路径上——对活数据无效的手术。
3. 更早的同类：恢复经 Room 中转再重建 profiles 文档、`apply` 七次独立编辑的原子性、备份预览依赖 ffi SQLite 等——都是异构面的摩擦。

Bettbox 的答案就是本 ADR 的原则：**每份数据一个文件、一个写者**（config.json/profiles/*.yaml，Dart 写者）。我们的对应物：`documents/profiles.json`（Dart 写者，ADR 0005）+ `documents/route_*.json`（Go 写者，经 Action wire）。

## 现状盘点（2026-11-20）

| 数据 | 存储 | 写者 | 状态 |
| --- | --- | --- | --- |
| profiles/groups | `documents/profiles.json` | Dart（ProfileStore） | ✅ 已收敛（ADR 0005） |
| route_profiles/route_rules | `documents/route_*.json` | Go（action wire） | ✅ 已收敛（ADR 0002 3c），**备份/恢复 stage A 接通** |
| global_route_rules | `documents/global_route_rules.json` | Go | ✅ 已入备份（与另外两份 route 文档同路径；旧容器不带该表时保留现存池） |
| settings/markers | `documents/settings.json`/`markers.json` | Kotlin（`SettingsStore` → `SettingsJsonStore`） | ✅ Stage C2b（Room 实体/DAO 已删，schema 21） |
| UI 设置文档 | `documents/ui_*.json` | Dart | ✅（seed 自 SharedPreferences） |
| 备份机械 | `backup.container`（容器文件 SQL 传输）/`settings.snapshot`·`markers.snapshot`/`settings.restore`·`markers.restore`/THRN staged-table；旧库只读读 `LegacyRoomReader` | — | settings/markers 不再经 Room（C2b）；`data.roomSql` 已由 `backup.container` 取代且无 `openRoom`（C2c1）；**C2c2a 起备份/旧库数据面完全不读写 Room**：导出从 `profiles.json`、内核 route 文档与两个设置文档取行，恢复写回文档，`data.roomSnapshot`/`applyRoomSnapshot`/`data.roomProfiles` 退役 |

## Stage A（已落地）：routes 备份/恢复走内核文档

- 新 `services/route_documents.dart`：文档信封（`{version,name,rows}`，对齐 Go `writeDocument`）的读/原子写/恢复语义（单边 `source_gid` 清理、Default 种子对齐 Go `defaultProfileRow/defaultProfileRules`、`__current` 从 restored `current_route_id` 对账）。
- 备份导出：文档在场读文档（**不再导出 Room 冻结**）；预迁移安装（文档缺失）回退 Room。
- 恢复：文档整体替换 + 单边清理（profiles-only 恢复时对存活文档 `clearSourceGids`）；Room 写路径保留作预迁移种子/兼容（双世界安全：文档在场即权威）。
- 回滚：恢复在第一次 route 写之前用 `RouteDocuments.snapshot` 捕获三份文档原文；route 替换本身或其后任一步失败时写回（替换新建的文件删除回“不存在”，全部缺失时如实报告），错误文本带结果说明——与 profiles 文档的回滚对称。
- 测试：`route_documents_test`（信封/单边/种子/标记 8 例）+ `backup_write_test` 两条集成（文档导出胜过 Room、恢复落回文档、单边清理）。

## Stage B（已落地）：profiles/groups 恢复脱离 Room 中转

- staged rows 直达 `ProfileStore.replaceAll`（原子 temp+rename），Room 的 profile/group 表在恢复里**不再被写**（自 ADR 0005 起它们本来就只是预迁移种子）。
- 顺序：文档先行，routes/settings 的 Room 提交在后——文档写失败时 Room 一个字节都没动，整次恢复可用同一个容器重试。文档目录不可写（无 sink）时**恢复直接拒绝**，不留「Room 写了一半、列表还是旧的」的假成功。
- `applyRoomSnapshot` 的 doProfiles 写表分支与 `toProfile`/`toGroup` 退场；它只写 routes/settings/markers，选择项修复改用 Dart 传来的 `restoredGroupIds`/`restoredProfileIds`（文档才是目录）。`room_snapshot_audit` 的列覆盖/单边清理/无裸 SQL 诸项不变。
- 测试：`backup_write_test` 的 ffI 组改断言文档（Room profile 表为 0），新增宿主路径的「文档先行」「文档写失败零副作用」「预迁移安装落文档」「无 sink 拒绝」四例。

## Stage C（进行中）：settings 出 Room → Room 整体退役

**C2b 已落地**：`settings`/`markers` 的 Room 实体、DAO 与 `SettingsStore` 的 Room 回退删除；schema 20→21（`MIGRATION_20_21` 删表）；旧行由 `AndroidLegacySettingsReader` 在 Room 打开前用只读 `SQLiteDatabase` 读出并播种文档（`SagerNet.onCreate` 挂载后立即 `ensure()`）。备份导出让容器仍带合成的 `settings`/`markers` 表（旧构建可恢复），恢复时空白表表示"不覆盖"，THRN 格式未变。

**C2c1 已落地**：`data.roomSql` 退役，备份的 SQL 传输改为 `backup.container`——只打开 App 自有存储内的容器文件（`sager_net.db`、`documents/`、`routeprofiles/` 按名与 canonical 路径拒绝），且**没有** `openRoom`（活的 Room 句柄不再经通道暴露）。host 路径的恢复不再读活库 schema，改为以本 App 自有的 desktop DDL 作为列契约（桌面/CI 仍读活库 PRAGMA）；`data.roomSnapshot`（DAO 读）与 `data.applyRoomSnapshot`（DAO 写）保留。

**C2c2a 已落地**（备份/旧库数据面脱离活 Room）：导出不再读 DAO——profiles/groups 取 Dart 的 `profiles.json`，routes 取内核的 `route_*.json`，settings/markers 经 `settings.snapshot`/`markers.snapshot` 取文档；恢复同样只写文档（`profiles.json`、内核 route 文档、`settings.restore`/`markers.restore` 的合并与整组替换，选择项修复照旧按 Dart 传来的 id 集合）；旧库导入改为 `LegacyRoomReader`（framework `SQLiteDatabase` 只读、不经 Room、不创建/迁移文件、文档在场即不返回该表）。`data.roomSnapshot`/`data.applyRoomSnapshot`/`data.roomProfiles` 退役，`room_snapshot_audit` 改为「只在带 `backup.container` 与四个文档 op」并要求任何 live-Room op 回归即失败。

**C2c2b 已落地**：C2c2b1 让 `GroupRepo`/`ProfileManager` 只走 Dart 文档；C2c2b2 删除 profiles/groups/routes 的 Room 实体与 DAO、`SagerDatabase`、`RouteDao`、`TempDatabase`/`RoomPreferenceDataStore`（编辑器缓存改纯内存 `MemoryPreferenceDataStore`）、`RoomToJsonMigration`（更名 `LegacyDocumentSeed`）、`AndroidLegacySettingsReader`（并入 `LegacyRoomReader`）、Dart 侧只读数据面（`data/db.dart`、`data_layer.dart`、两个 DAO、`RouteProfilesSource`、`SqliteRoomProfileReader`）与 Gradle Room/KSP 依赖、`app/schemas`。`RouteManager` 保留为 `RouteJsonStore` 的只读门面，路由写只经 kernel action bus；`FlroneRoomSnapshot` 只剩容器 + 文档 op，旧容器仍可读。**验收**：`schema_audit`/`room_snapshot_audit` 随 Room 一起退役，新增 `legacy_reader_audit.py` 钉住「无 Room 残留 + `LegacyRoomReader` 唯一且只读」；`channel_audit` 保留集不变。

## 不变量（所有阶段）

1. 每份数据一个文件、一个写者；恢复是唯一的特权全量替换（与 `ProfileStore.replaceAll`、`RoomToJsonMigration.seed` 同类）。
2. 双引擎 + IPC + Action wire 骨架不动；数据面的收敛不改通道契约（`channel_audit` 全绿）。
3. 每阶段一个 PR；发现「权威分裂」（两个写者）立即停下重新设计——不为减方法数而迁。
