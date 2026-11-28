# ADR 0008 — Kotlin-free core path

- 日期：2026-11-27
- 状态：进行中（分阶段执行）
- 关联：ADR 0002（Bettbox 协议层）、ADR 0004（严格 Bettbox 桥接）、ADR 0005（数据权威）、ADR 0006（纯文件数据层）

## 目标

让 Kotlin 只承担 Android 平台职责，核心控制面与配置/模型归属回到 Dart/Go：

- `config.build` 及 sing-box 配置生成由 **Go** 负责；
- profile/group 文档 CRUD、订阅、auto-selector 编辑器状态由 **Dart** 负责；
- Kotlin 保留 VpnService/TUN、通知/前台服务、SAF/`content://`、WorkManager 触发、Keystore、应用图标/包名/UID、Wi-Fi/网络状态、settings.json/markers.json 的写者身份；
- 核心 action 不经过 Kotlin；平台事实通过窄通道或 callbacks 提供。

这不是“删一层桥”，而是把 Kotlin 当前承担的 Throne 模型/配置生成业务迁走；迁移期间必须保持配置字节、错误文案和用户数据不变。

## 数据所有权（迁移后）

| 数据 | 唯一写者 | 唯一读入口 |
| --- | --- | --- |
| `documents/profiles.json` | Dart `ConfigurationStore` | Dart/Go 只读 |
| `documents/profile_selection.json` | Dart（新增） | Go 只读，Kotlin 只读 |
| `documents/global_route_rules.json` | Go | Go/Dart/Kotlin 只读 |
| `documents/settings.json` / `markers.json` | Kotlin `SettingsJsonStore` | Go 只读（配置构建），Dart 经 host 读 |
| `routeprofiles/srslist.h` | Kotlin 种子/只读 | Go/Dart 只读 |

配置构建是纯读：不得写入任何文档；随机端口、secret、`startWithoutRuleSets` 等副作用集中在 Kotlin `config.prepare`，在 Go 构建前完成。

## 阶段

### Profiles

| 阶段 | 内容 | 门禁 |
| --- | --- | --- |
| S0 | Dart `ProfileDocumentService` 与 `data.refresh` 纪律 | 文档单写者测试 |
| S1 | `stats`/`reorder`/`clearTestResults`/`nodeList`/`nodeReorder` → Dart | `platform_duty_audit` 部分所有权 |
| S2 | `config`/`read`/`write`（分组清单）→ Dart | **已完成**：revision/whitelist/canonical 测试 |
| S3 | `delete`、本地 `save`（分组 CRUD）→ Dart | prune/stop 语义 |
| S4 | `select`/`switchRelative` + `profile_selection.json` | **已完成（2026-11-28，真机未验证）**：四个选择 action 迁 Dart（Dart 从 profiles 文档解析成员/分组）；Dart 写 `profile_selection.json`（原子/去重/串行/重试），服务引擎每次 build 前投影 `config.prepare` 的结果；`config.build` 只读该文档，缺失/非法为硬错误；settings 仍是平台路径的写者，UI 选择用 `selection.mirror` 镜像，`config.prepare` 仅作 settings→文档→首条的解析 |
| S5 | 分享链接/JSON/YAML 解析、校验、导出 → Go actions | **进行中（S5a–S5i）**：Go base64/QUrl 基座；`profileExport` 简单四类 + vmess/vless/trojan/hysteria(2) + tuic/anytls/mieru/snell/shadowtls + juicity/naive/ssh/trusttunnel + wireguard/masque + openvpn/openconnect；`profileValidate format=stored` 覆盖上述全部类型；`profileImport` 覆盖上述协议的 link/Clash/JSON/SIP008，高级 TLS cipher/curve/fragment/spoof/tls_tricks、quic transport、xhttp extra、Hysteria2 realm/port-hopping 已支持；`profileNewOutbound` 25 类型模板 + `profileNormalize format=stored` 21 类型（openvpn/openconnect normalize 仍 refused）；`profileMigrate`；corpus 50 included/2 excluded；剩余 trusttunnel deep-link TLV、wg-quick INI、masque share link（Kotlin 也无）、Clash wireguard、invalid 值拒绝、旧 Xray full-config corpus、非空 stored multiplex JSON body |
| S6 | 订阅队列/HTTP/重试 → Dart | **进行中（S6-6）**：Dart HTTP/metadata、reconcile、queue/client 纯层；服务引擎独占 profiles 文档；`subscription_refresh.dart` fetch→parse（含 name include/exclude 过滤）→reconcile→单次 `applyCombined`；`subscription_engine.dart` 接入事件/前台桥；手动刷新、自动轮询、普通 http(s) 新建订阅均走 Dart；content:///front-landing 仍回退 Kotlin |
| S7 | auto-selector 编辑器 → Dart | 文档锁/默认值 |
| S8 | 删除 Kotlin outbound 模型/import/config 包 | **进行中（批 1 + Xray 迁移 + 节点编辑器 Go-first）**：已删 AutoSelectorPlan（460 行）及 rank/rerank 死方法、SettingsMapper selectorStore、Outbound/BuildContext/ProfileJson 死成员（17 文件 +6/−801）；`ProxyEntity.parseOutbound` 已去掉 LegacyXray，旧行由服务引擎 `profileMigrate` 一次性迁移（`migrations.legacyXray` marker）。节点编辑器 create/parse/commit/update/nodeConfig/nodeInfo/decode 已先走 Go `profileNewOutbound`/`profileImport`/`profileNormalize`/`profileValidate`/`profileExport`（`FlroneProfileActions`），只有 `supported:false` 或不可回答才回退 `FlroneNodeEditorLegacy`（`ProfileImport`/`OutboundFactory`/`Outbound` 的唯一残留点；tuning 反射隔离在 `FlroneNodeTuning`）。`SubscriptionRefresh`/outbound types/notifier 等大批量仍待 S5 剩余能力与 Kotlin fallback 清零。**批 2（feat/s8-delete）**：共享非模型工具已迁出 outbound——`document.json`（Json/JsonInput/JsonWriter/QtStrings）、`document.link`（Hosts/Base64Strict/LinkParser+LinkQuery+ParsedLink/LinkCodec/ProfileImportScan）、`data.config`（GeneratedConfig/PredefinedDns）；删除 `ProxyEntity.requireChain`、`ProfileManager.createProfile/updateOutbound`，`addProfile(Outbound)`/`addProfileBatch(Outbound)` 改为 `addStoredProfile`/`addStoredProfileBatch(StoredRow)`，`ProfileJson` 去掉 Outbound 重载。残留（Go 无等价 action）：`FlroneNodeEditorLegacy`（unsupported 类型回退）、`FlroneNodeTuning`（mux/TLS 反射）、`ProfileValidator`（fragment 全局豁免 + buildChecked）、`SubscriptionRefresh`/`SubscriptionNameFilter`（content:// 回退）、`AutoSelectorProfiles`（pool/last_built 剪枝）、`ProxyEntity`/`SettingsMapper`，模型 `types/common/import/Outbound/OutboundFactory/BuildContext/NodeDedupe/LinkBuilder` 暂留 |

### Config

| 阶段 | 内容 | 门禁 |
| --- | --- | --- |
| C0 | Kotlin oracle golden harness + fixtures + `config_golden.py` | **已完成**：2 个 fixture 字节级一致 |
| C1 | Go simple-shadowsocks builder（inputs + qjson） | **已完成**：simple-shadowsocks + chain-two-hop 字节一致；其余 fixture 以 `goStage=2` 标记 |
| C2 | 协议矩阵（socks/http/ss/vmess/vless/trojan/hysteria2/wireguard/…） | **已完成**：7 类型字节一致，15 个 golden 全绿 |
| C3 | chain / landing-front / route outbounds / WARP endpoints | **已完成**：WARP 三模式 + custom fullconfig 字节一致 |
| C4 | DNS / route rules / rule-set / adblock / deferred | **已完成**：4 个新 DNS/route fixture 字节一致 |
| C5 | auto-selector（固定 clock） | **已完成**：7 个 selector fixture，56/56 main golden |
| C6 | test config（`forTest`）与 Kotlin 调用方 | **已完成**：5 fixture envelope 一致；Kotlin 调用方改走 `build_test_config` host call |
| C7 | 切到 Go `config.build`，删除 Kotlin ConfigGenerator/CoreConfigs/SettingsMapper | **已完成（pre-release，无设备矩阵）**：Dart 调 `config.prepare` + Go `configBuild`；Kotlin generator/model/BoxInstance/CoreConfigs 删除；golden 冻结为 Go 侧 56/56 + 5/5；C7c 用户真机冒烟正常（2026-11-28），完整矩阵未逐项记录 |

### 依赖

1. profiles S4（选择 action 与 selection 文档）已完成：Dart 解析并写文档，Go start build 只读文档；
2. config C1-C5 是 test session 迁移的前置（`buildTest`/结果落盘）；
3. test session 最后迁，Kotlin 只留通知/前台服务。

## 契约

### `config.prepare`（Kotlin，副作用）

在 Go build 前调用一次：

```
request:  {}
response: {selectedProfileId, currentGroupId, documentsDir, deferRuleSets}
```

端口/secret/selection 修复、`startWithoutRuleSets` 消费、dashboard 安装等 Kotlin/Android
副作用都写进 `settings.json`（端口/secret）或由 `selectedProfileId` 返回。选择解析顺序：
settings `selectedProxy`（有有效 profile）→ 文档（settings 无有效选择时）→ 首条 profile；
`currentGroupId` 是成员所属分组，`documentsDir` 供服务引擎写 `profile_selection.json`。
Dart 在调用 `config.build` 前把这三个选择事实投影进文档；Go 随后只读文档，不生成配置。

### `config.build`（Go，纯读）

```
request:  {mode?, deferRuleSets?}
response: {coreConfig, involvedProfileIds, deferRuleSets}
```

- 读取 `profiles.json`、`profile_selection.json`、`settings.json`、`global_route_rules.json`、`srslist.h`；
- 输出 `coreConfig` 必须与 Kotlin oracle 字节一致；
- 不写任何文档、不生成 secret、不消费 consent；
- 保留 30s 上限与既有错误文案。

### `profile_selection.json`

```
{"version":1,"selectedProfileId":N,"currentGroupId":N,"updatedAt":epochMs}
```

- Dart 唯一写者（`ProfileSelectionDocument` + `SelectionDocumentPublisher`：按磁盘内容去重、串行原子写、失败后重试；服务引擎在每次 start build 前投影 `config.prepare` 的解析结果）；Kotlin `ProfileSelectionStore` 与 Go `readProfileSelection` 只读；
- UI 选择（四个 action）由 Dart 从 profiles 文档解析成员/分组，先经 `selection.mirror` 镜像进 settings，再写文档并让 core 原地切换或重建；平台路径（widget/快捷开关/BaseService/订阅后继/删除回退）只写 settings，下一次 build 由服务引擎投影；
- `config.build` 只读该文档：缺失/非法是硬错误，不回退 settings；fixture 与 buildTest 仍走 settings（测试源，不是迁移门禁）。`currentGroupId` 是成员所属分组（可与 settings `current_group` 不同），当前构建无消费方。

### Golden / 字节一致性

- `expected.json` 在 C7 前只由 Kotlin oracle 生成；oracle 已删除，现值冻结，禁止手写；
- Go builder 通过 `config_build_golden_test.go` 比较**原始字符串**；
- `config_golden.py --check` 在 CI 跑；`--update` 仅显式使用；
- 每个协议/section 的 PR 必须同时提交 fixture 与通过结果。

## 不变量

1. **单写者**：profiles= Dart，route=Go，settings=Kotlin；构建只读。
2. **字节一致**：不接受“语义相同”；`JsonWriter`/`qjson` 的键序、转义、数字格式固定。
3. **错误文案**：生成失败的用户可见文本沿用 Kotlin；action 错误需保留可读原因。
4. **密钥**：config 不日志化 secret/coreConfig；secret 生成只在 `config.prepare`。
5. **snapshot**：每份文档一次读取，记录 revision；不允许跨文件半快照。
6. **平台边界**：Kotlin 只保留 Android 职责；新增 Kotlin core 调用必须被审计拒绝。

## 切流与回滚

- C1-C6 期间保持 Kotlin `config.build` 生产路径不变，只在测试/双跑中使用 Go；
- C7a 先暴露 Go `configBuild` action，C7b 由 Dart 调 `config.prepare` + `configBuild`；
- 2026-11-28 按用户指示直接切流并删除 Kotlin 生成器（不做 dual-run 开关）：
  启动路径只有 prepare + Go，失败按普通启动错误上报；
- golden 期望值冻结在 `app/src/test/resources/config-*-golden/expected.json`，
  `config_golden.py` 只校验 fixture/信封/SHA，字节比较由 Go harness 完成；
- 回滚只能 revert 提交（保留一个版本可回退），C7c 真机矩阵未做。

## 风险

1. 协议字段映射（WireGuard worker/keepalive、Hysteria v1/v2、OpenVPN 等）是主要风险；每协议 golden + `option.*` 解码。
2. 默认值漂移（GeneratorSettings vs SettingsRegistry）；settings defaults 表 + invalid/missing 测试。
3. `GroupSort`、`nodeList` prune、auto-selector planner 是有副作用的纯逻辑，迁移时必须显式保留或重写。
4. rule-set tag 哈希、mirror、deferred `http_client` 路径必须逐字节对齐。
5. 订阅 HWID/TLS/HTTP2、前台提升、WorkManager 触发属于平台/网络混合，放最后并做设备对比。
6. 迁移期双写窗口必须有 revision/冲突测试，避免 Dart/Kotlin 两写者。

## 验收

- 所有阶段：`flutter analyze --fatal-infos`、`flutter test`、Go mobile、JVM、action/channel/platform/symbol/core-patch 审计全绿。
- C1 起：每个 fixture 字节一致；C7 前完成设备清单（proxy/VPN/tun IPv6/per-app/chain/WARP/auto-selector/rule-set/test probe）。
- 最终：Kotlin 中不再有 ConfigGenerator/CoreConfigs/SettingsMapper/OutboundFactory/ProfileImport/SubscriptionQueue/FlroneProfiles 的生产调用；Kotlin 只保留平台层。
