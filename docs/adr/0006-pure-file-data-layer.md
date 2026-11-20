# ADR 0006 — 纯文件数据层：数据层越少越好

- 状态：已接受（2026-11-20）。Stage A 已落地（本文所指 PR）；Stage B/C 为后续排期。
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
| global_route_rules | `documents/global_route_rules.json` | Go | ⚠️ **从未入备份**（遗留，独立小 PR） |
| settings/markers | Room `sager_net.db` | Kotlin（DataStore） | ⏳ Stage C |
| UI 设置文档 | `documents/ui_*.json` | Dart | ✅（seed 自 SharedPreferences） |
| 备份机械 | `data.roomSql`/`applyRoomSnapshot`/THRN staged-table | — | ⏳ Stage C 后删（THRN codec 已 Dart 化） |

## Stage A（已落地）：routes 备份/恢复走内核文档

- 新 `services/route_documents.dart`：文档信封（`{version,name,rows}`，对齐 Go `writeDocument`）的读/原子写/恢复语义（单边 `source_gid` 清理、Default 种子对齐 Go `defaultProfileRow/defaultProfileRules`、`__current` 从 restored `current_route_id` 对账）。
- 备份导出：文档在场读文档（**不再导出 Room 冻结**）；预迁移安装（文档缺失）回退 Room。
- 恢复：文档整体替换 + 单边清理（profiles-only 恢复时对存活文档 `clearSourceGids`）；Room 写路径保留作预迁移种子/兼容（双世界安全：文档在场即权威）。
- 测试：`route_documents_test`（信封/单边/种子/标记 8 例）+ `backup_write_test` 两条集成（文档导出胜过 Room、恢复落回文档、单边清理）。

## Stage B（待做）：profiles/groups 恢复脱离 Room 中转

`applyRestoredProfiles` 已直接写文档，但恢复仍先 commit 进 Room 再重建文档。改为 staged rows 直达 `ProfileStore.replaceAll`/`applyCombined`，`applyRoomSnapshot` 的 doProfiles 分支退役。

## Stage C（待做）：settings 出 Room → Room 整体退役

按 ADR 0005 阶段 2 把 settings 迁入文档后：删除 `data.roomSql`/`applyRoomSnapshot`/`BboxRoomSnapshot`/Room 实体与 DAO、`RoomToJsonMigration`（迁移完成后）、`data.roomSnapshot` 读侧。**验收**：`channel_audit` 只剩 ADR 0002 决策 5 保留集；`room_snapshot_audit` 退役；真实设备备份/恢复/连接回归无数据丢失。

## 不变量（所有阶段）

1. 每份数据一个文件、一个写者；恢复是唯一的特权全量替换（与 `ProfileStore.replaceAll`、`RoomToJsonMigration.seed` 同类）。
2. 双引擎 + IPC + Action wire 骨架不动；数据面的收敛不改通道契约（`channel_audit` 全绿）。
3. 每阶段一个 PR；发现「权威分裂」（两个写者）立即停下重新设计——不为减方法数而迁。
