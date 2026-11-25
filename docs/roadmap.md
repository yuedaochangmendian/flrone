# Flrone 下一阶段路线图

> 基线：`main` @ `ffd4203b`（2026-11-25），`VERSION_NAME=4.16.3`。`releases/latest` = 稳定版 `v4.15.1`；预览线 `v4.16.3-pre.N`。
> 本文只记录当前有效的工程规划；v4.0.0 之前的迁移与 bbox parity 计划为历史文档，不再作为任务来源。

## 1. 当前判断

- `main` 受保护，PR 必须通过 `Unit tests and debug build` 与 `Flutter module tests`。
- 正式版晋级在 2026-11-22 恢复：`v4.14.0` 起已发布多个 stable（`v4.15.1` 为当前 `releases/latest`）；此后每条 `vX.Y.Z` 线先发 `vX.Y.Z-pre.N` 预览，转正仍按 §5 执行。
- Flutter 自有代码覆盖率门槛 60%；全量测试数量以 CI 为准，`flutter analyze --fatal-infos` 干净。
- `THRONE_CORE_REF=48273be2`（2026-11-18）；上游 `throneproj/Throne` `dev` 已前进 14 个提交（最新 `e3a8bd34`，含 sing-box 升级与 group/route 修复），升 pin 为下一项候选。
- **16 KB page size 已实测通过**（2026-11-18，v4.12.1 arm64 APK）：`libthrone.so`/`libcore.so` 及两个 JNI 库 LOAD align `0x4000`，`libapp.so`/`libflutter.so` 为 `0x10000`。targetSdk 36 不需要改 gomobile 链接参数。
- 原生库体积仍是主要成本：`libthrone.so` 未压缩约 80 MB，arm64 APK 约 46 MB。
- 工具链已随 M1 抬到 Flutter 3.50.0 / AGP 8.13.2 + Gradle 8.14.7 / Kotlin 2.4.21 + KSP 2.3.14 / targetSdk 36（compileSdk 37），`ffi` 2.2.0，`material_color_utilities` 保持 Flutter 钉版 0.13.0；详见 `docs/toolchain-upgrade.md`。
- 核心 pin 已包含但 UI 尚未接入的能力：service availability check、multi-DNS、`IPProvider`、auto-selector status；route tester 已随 M2 接入。

## 2. 方向

先做**平台与发布硬化**，再做**内核新能力接入**，质量 ratchet 贯穿每个版本。

| 方向 | 价值 | 风险 | 顺序 |
|---|---|---|---|
| A. 平台/工具链/targetSdk 36 | 避免新设备行为异常，保持构建可维护 | 中低 | 1 |
| B. 核心新 API 接入 | 用户可见的新诊断/路由能力 | 中 | 2 |
| C. 覆盖率/TV/无障碍/体积 | 长期稳定与可维护 | 低 | 并行 |

## 3. 里程碑

### M0 — 收口与重基线（已完成）

- [x] `v4.12.2` 转正式版（`Stable release`，stable 资产 + `throne-update.json`）；此后 `releases/latest` 已前进到 `v4.15.1`。
- [x] 重写本路线图并随 M1/M2 进展重设基线到 4.14.0。
- [x] README 纠偏：日志等级不再有 chip；等级由页头筛选动作设置，不再有标签加词过滤。
- [x] 16 KB page size 审计并记录（见 §1）。
- [ ] 设备清单：arm64 真机 + Android TV 的可选回归（不阻塞 M0，作为发布后可选验证）。

### M1 — v4.13.0 平台升级（已完成，工具链部分随预览线验证）

1. 工具链（已落地）：
   - Flutter 3.50.0（CI 两处钉版；本机使用独立 SDK 或升级共享 SDK 前先确认其他项目兼容）；
   - AGP 8.13.2 + Gradle 8.14.7；
   - Kotlin 2.4.21 + KSP 2.3.14；
   - `ffi` 2.2.0（`material_color_utilities` 保持 Flutter SDK 钉版 0.13.0）。
2. `targetSdk 35 → 36`（已落地）：
   - edge-to-edge / insets、predictive back、通知/磁贴/前台服务行为；
   - Android 16 模拟器 + arm64 真机各跑一轮设备清单（设备回归为发布后可选验证）；
   - 16 KB 检查保持绿。
3. 核心 pin：上游无提交则不动；有提交时按 overlay/bindgen/schema/audit 流程处理（现有 pin 之后已有 14 个上游提交，含 sing-box 升级，列为下一项候选）。
4. 验收：`v4.13.0-pre.1` 预览已发布（analyze/CI 全绿）；`v4.14.0` 已于 2026-11-22 转正并成为 `releases/latest`，stable 晋级恢复（见 §5）。

### M2 — 核心新能力与 FlClash 同步（v4.14/v4.15 进行中）

- [x] ~~**路由测试**~~：按用户要求**整体删除**（2026-11-22）——Dart 页面/工具入口/`ActionMethod.routeTest`/`box_api` 包装、Go `core/mobile/route_test_actions.go`、README/CHANGELOG 条目一并移除；上游 `Instance.TestRoute` 留在核心内但不再有调用方。
- [x] ~~**服务可用性检查**~~：已被 Bettbox 风格的 **Connectivity test** 取代（首页卡片 + 完整页面 + 设置，服务列表和图标来自 Bettbox）；`serviceTest` action 与旧的 Service check 页面已删除。
- [x] **自动选择器状态**：`auto_selector.dart` 已展示阶段、当前选择、排名（rank/state/平均延迟/样本数）、最近切换与停止排名原因。
- [ ] **出口查询 provider**：`TestRequest.IPProvider` 接入状态卡/测速设置 — 待定。
- [~] **多 DNS**：DNS object（`useDnsObject` + `dnsObject` JSON）已能表达多服务器/策略；是否需要专用 UI 待定（核心 settings schema 无 `respect_rules`/`cache_algorithm`，本轮已核实不做无效开关）。
- [x] **v4.15.0 FlClash 0.9.4/0.9.5 同步轮**：连接行应用图标/名称/协议筛选、连接计数、详情分组、仪表盘连接卡片、更新提示、规则集状态、搜索自动聚焦、分段控件 reduce-motion、出口卡片标题。mihomo 专属（MITM、DNS 查询流、Provider/图标集/脚本、失败连接原因）不引入。

### M3 — 持续质量 ratchet

- 覆盖率 60% → 65%（`box_api`、页面目录、kernel worker 分别 ratchet）。
- TV/遥控焦点、文本缩放 0.8–1.4、浅/深/纯黑对比度、语义标签纳入设备清单。
- 启动时间/APK 体积建立基线，先测量再决定优化。
- i18n 保持 zh/en；新增字符串必须同步两份表，不扩大已知 gap。

### M4 — 严格 Bettbox 桥接（ADR 0004，进行中）

- [x] P1 c-shared 基座（PR #128）：`buildScript/cgoentry` + `build-cshared.sh`，3 ABI 425 导出。
- [x] P5 前半 / P2a（PR #129）：`CancelToken` 去掉最后一个 gobind 类型；`platform_request` 首批三职责。
- [x] P3.1（PR #130）：同步 `throne_run_action`，Kotlin 路由写入离开 gobind。
- [x] P3.2（PR #131）：`throne_host_call` JSON 宿主桥，版本/校验/QUIC/WARP/DNS/诊断迁出。
- [x] P3.3/P3.4（PR #132）：`CoreInstance` 生命周期、平台实现统一到 `FlroneCorePlatform`，删除 `NativeInterface`。
- [x] P3.5/P3.6（PR #133）：测试轮询 hub、日志 sink，删除 `ThroneCore.aar` 与 gomobile 构建链，CI/F-Droid 只产 c-shared。
- [x] P2b（PR #134）：平台回调 22→5（protect / resolver / release / cancel token / platform_request），`CorePlatform` 只剩 `platformRequest`。
- [ ] P4：单控制面（speedTest 收进 action bus、删 channel fallback/handover/AIDL）。
- [ ] P5 剩余：typed 导出收窄、`bindgen.py` 方法体模板同步、设备清单、release/F-Droid 收尾。

## 4. 暂缓

- AGP 9 / Gradle 9 major 迁移（当前无收益）。
- `material_ui` 1.11 大跳（单独实验分支）。
- 新增协议/多语言（现有协议面与 zh/en 已满足）。
- 重写路由 UI / 恢复 bbox 全功能迁移（历史文档仅作参考）。

## 5. 发布规则

- **正式版晋级已恢复**：`v4.14.0` 于 2026-11-22 作为 stable 发布，当前 `releases/latest` 为 `v4.15.1`。此后每条 `vX.Y.Z` 线先发 `vX.Y.Z-pre.N` 预览；转正需用户明示，按 `docs/github-workflow.md` §3 / `docs/release-runbook.md` 从预览提交**另发**一条 `vX.Y.Z` 正式 release（`Stable release` workflow 或手工路径，stable 资产 + `--latest`）。**不要**把 `-pre.N` 直接改旗标转正。
- 默认 prerelease：`vX.Y.Z-pre.N`，不占 `releases/latest`。
- 正式版：`Stable release` workflow（`version` = `VERSION_NAME`，`target_sha` = 应用提交），stable 资产必须含 3 ABI + `SHA256SUMS` + `throne-update.json`。
- 文档-only 合并不产生新版本。
