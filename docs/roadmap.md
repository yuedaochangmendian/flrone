# Flrone 下一阶段路线图

> 基线：`main` @ `f4ed2164`（2026-11-17），`VERSION_NAME=4.12.2`。稳定版 `v4.12.2`，最新预览 `v4.12.2-pre.1`。
> 本文只记录当前有效的工程规划；v4.0.0 之前的迁移与 bbox parity 计划为历史文档，不再作为任务来源。

## 1. 当前判断

- `main` 受保护，PR 必须通过 `Unit tests and debug build` 与 `Flutter module tests`。
- main CI 成功后自动发布 `vX.Y.Z-pre.N` prerelease；正式版由 `Stable release` workflow 显式转正。
- Flutter 自有代码覆盖率门槛 60%；全量测试 673，`flutter analyze --fatal-infos` 干净。
- `THRONE_CORE_REF=48273be2`，上游 `throneproj/Throne` `dev` 至今无新提交。
- **16 KB page size 已实测通过**（2026-11-18，v4.12.1 arm64 APK）：`libthrone.so`/`libcore.so` 及两个 JNI 库 LOAD align `0x4000`，`libapp.so`/`libflutter.so` 为 `0x10000`。targetSdk 36 不需要改 gomobile 链接参数。
- 原生库体积仍是主要成本：`libthrone.so` 未压缩约 80 MB，arm64 APK 约 46 MB。
- 工具链相对稳定版有滞后：Flutter 3.47.9（稳定 3.50.0）、AGP 8.12.3（8.13.2）、Kotlin 2.4.10（2.4.21）、KSP 2.3.13（2.3.14）、targetSdk 35（compileSdk 37）。
- 当前 pin 已包含但 UI 未接入的核心能力：route tester、service availability check、multi-DNS、`IPProvider`、auto-selector status。

## 2. 方向

先做**平台与发布硬化**，再做**内核新能力接入**，质量 ratchet 贯穿每个版本。

| 方向 | 价值 | 风险 | 顺序 |
|---|---|---|---|
| A. 平台/工具链/targetSdk 36 | 避免新设备行为异常，保持构建可维护 | 中低 | 1 |
| B. 核心新 API 接入 | 用户可见的新诊断/路由能力 | 中 | 2 |
| C. 覆盖率/TV/无障碍/体积 | 长期稳定与可维护 | 低 | 并行 |

## 3. 里程碑

### M0 — 收口与重基线（本次）

- [x] `v4.12.2` 转正式版（`Stable release`，stable 资产 + `throne-update.json`）。
- [x] 重写本路线图到 4.12.x 基线。
- [x] README 纠偏：日志等级不再有 chip；等级由页头筛选动作设置，不再有标签加词过滤。
- [x] 16 KB page size 审计并记录（见 §1）。
- [ ] 设备清单：arm64 真机 + Android TV 的可选回归（不阻塞 M0）。

### M1 — v4.13.0 平台升级

1. 工具链：
   - Flutter 3.50.0（CI 钉版；本机使用独立 SDK 或升级共享 SDK 前先确认其他项目兼容）；
   - AGP 8.13.2 + Gradle 8.14.7；
   - Kotlin 2.4.21 + KSP 2.3.14；
   - `ffi` 2.2.0、`material_color_utilities` 0.13.1 等小版本随行。
2. `targetSdk 35 → 36`：
   - edge-to-edge / insets、predictive back、通知/磁贴/前台服务行为；
   - Android 16 模拟器 + arm64 真机各跑一轮设备清单；
   - 16 KB 检查保持绿。
3. 核心 pin：上游无提交则不动；有提交时按 overlay/bindgen/schema/audit 流程处理。
4. 验收：673+ 测试、analyze、CI、`v4.13.0` stable；`releases/latest` 指向正式版。

### M2 — v4.14.0 核心新能力

- **路由测试**（`core/mobile/routetest.go`）：输入域名/应用/进程，显示命中规则与最终出站。
- **服务可用性检查**（`core/mobile/servicetest.go`，`ServiceChecks`/`SkipIPInfo`）：按服务分组展示结果。
- **多 DNS**：DNS 设置页支持多服务器/策略。
- **出口查询 provider**：`TestRequest.IPProvider` 接入状态卡/测速设置。
- **自动选择器状态**：展示最近切换、延迟排名与上限触发原因。
- 每个入口补 widget/契约测试，README/device-checklist 同步。

### M3 — 持续质量 ratchet

- 覆盖率 60% → 65%（`box_api`、页面目录、kernel worker 分别 ratchet）。
- TV/遥控焦点、文本缩放 0.8–1.4、浅/深/纯黑对比度、语义标签纳入设备清单。
- 启动时间/APK 体积建立基线，先测量再决定优化。
- i18n 保持 zh/en；新增字符串必须同步两份表，不扩大已知 gap。

## 4. 暂缓

- AGP 9 / Gradle 9 major 迁移（当前无收益）。
- `material_ui` 1.11 大跳（单独实验分支）。
- 新增协议/多语言（现有协议面与 zh/en 已满足）。
- 重写路由 UI / 恢复 bbox 全功能迁移（历史文档仅作参考）。

## 5. 发布规则

- 默认 prerelease：`vX.Y.Z-pre.N`，不占 `releases/latest`。
- 正式版：`Stable release` workflow（`version` = `VERSION_NAME`，`target_sha` = 应用提交），stable 资产必须含 3 ABI + `SHA256SUMS` + `throne-update.json`。
- 文档-only 合并不产生新版本。
