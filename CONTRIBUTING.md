# 贡献指南（Contributing）

感谢你考虑为 Flrone 贡献。本文件说明开发环境、本地验证、提交流程与需要同步的契约。命令与路径均对应仓库内真实配置：`.github/workflows/ci.yml`、`.github/actions/android-build/action.yml`、`tools/diagnostics/`、`openspec/`。

## 1. 开发环境

| 组件 | 版本 / 说明 | 依据 |
|---|---|---|
| Flutter | **3.50.0**（CI 两处钉版） | `.github/actions/android-build/action.yml` 与 `.github/workflows/ci.yml` 的 `flutter-version: '3.50.0'` |
| JDK | **17**（Temurin） | 同上 `java-version: '17'`；`buildSrc/src/main/kotlin/Helpers.kt` 中的 `JavaVersion.VERSION_17` |
| Android SDK | 本机安装，需含 build-tools（`apksigner`、`aapt2`） | `buildScript/release_assets.py` |
| NDK | `28.2.13676358` | `ci.yml` 的 clang 路径与 `android-build/action.yml` 的 `ndk;28.2.13676358` |
| 构建入口 | `./gradlew` | `android-build/action.yml` 的 Gradle build 步骤 |

Flutter module 位于 `flutter/`，Gradle 主工程在仓库根目录；发布构建会先生成 Flutter AAR 再执行 Gradle 任务。应用支持 Android 7.0（API 24）及以上，含 Android TV。

## 2. 本地验证命令

CI（`ci.yml`）在功能分支的 PR 与 `main` 的 push 上运行以下检查，提交前建议在本地跑一遍（Flutter 命令在 `flutter/` 目录，其余在仓库根目录）：

> 首次在干净机器上跑 Gradle 之前，先准备 CI 会准备的构建输入（Flutter AAR、内核 c-shared、schema、规则集、dashboard），否则 `app:assembleOssDebug` 会因 `io.flrone.ui:flutter_release:1.0` 找不到而失败：
>
> ```bash
> source tools/local-build/local-env.sh   # 固定 JDK/SDK/NDK/Gradle/Flutter/Go 版本
> bash tools/local-build/local-inputs.sh  # 与 CI 相同的输入；--check 只做校验
> ```
>
> 版本要求、各步骤产出与常见报错见 [docs/local-build.md](docs/local-build.md)。


```bash
# Flutter 静态分析与测试
cd flutter && flutter pub get
flutter analyze --fatal-infos
flutter test --coverage
# CI 在 flutter/ 目录另以覆盖率下限脚本收口 —— 与 ci.yml 逐字一致。
# （这行曾经写着 --min 40 且不带 exclude，本地跑出来的门禁比 CI 松，容易误判通过。）
python3 ../tools/diagnostics/coverage_gate.py coverage/lcov.info \
  --min 60 \
  --exclude 'lib/core/throne_ffi.dart' \
  --exclude 'lib/ui/**' \
  --min-dir lib/box_api.dart:32 \
  --min-dir lib/pages:50 \
  --report-dirs
cd ..

# 契约 / 一致性诊断脚本（回到仓库根目录）
python3 tools/diagnostics/channel_audit.py
python3 tools/diagnostics/symbol_audit.py
python3 tools/diagnostics/settings_audit.py --summary
python3 tools/diagnostics/ffi_regression_test.py
python3 tools/diagnostics/generated_models_check.py
python3 tools/diagnostics/py_syntax_check.py tools/diagnostics/*.py tools/bindgen/*.py buildScript/*.py

# Flutter AAR 的 API 扫描（先构建 AAR，路径写法与 ci.yml 一致）
AAR=$(find flutter/build/host/outputs/repo -name "*.aar" | head -1)
python3 tools/diagnostics/scan_aar_apis.py "$AAR"
python3 tools/diagnostics/check_preamble.py

# Kotlin 单元测试与 debug 构建
./gradlew --stacktrace app:testOssDebugUnitTest app:assembleOssDebug
```

CI 还会用 NDK 的 clang 检查 cgo preamble，并要求 `flutter analyze --fatal-infos` 零告警。`generated_models_check.py` 静态核对 `@freezed` 模型与随仓库分发的生成文件是否一致（见脚本头部与 `flutter/lib/ui/generated/README.md`）；完整步骤以 `.github/workflows/ci.yml` 为准。

> Windows 本地跑全量 `flutter test` 时需设置 `BACKUP_TEST_SQLITE='C:\Windows\System32\winsqlite3.dll'`：备份/导入测试在 Android/CI 上直接打开 `libsqlite3.so`，Windows 主机没有该库，不指定系统 sqlite3.dll 时约 35 个用例会因缺库失败，属环境差异而非回归（见 `flutter/test/backup_write_test.dart` 与 `flutter/test/legacy_import_test.dart`）。

## 3. 分支与提交约定

> GitHub 分支、发版、tag、release 与更新器的完整规则见 [docs/github-workflow.md](docs/github-workflow.md)；本节是日常提交细则。

- 从最新 `main` 创建**功能分支**，在分支上提交并推送；CI 通过 Pull Request 验证功能分支，`main` 另有 push CI。
- 通过 **Pull Request** 合并，合并前需 CI 全绿；**不要直接向 `main` 推送提交**。合并 `main` 不再自动发布预览：预览由维护者在本地用 `tools/local-build/local-release.sh --publish` 构建并上传（见 `docs/local-build.md`），正式版才运行 `Stable release` 的 CI（见 `docs/github-workflow.md`）；开新版本线才递增 `VERSION_NAME` 并补 CHANGELOG 段落。正式版不是把预览"改旗标转正"——那会被 `github_governance.py` 判违规——而是用 `Stable release` 从预览的提交另发一条 `vX.Y.Z` 正式 release；降级补发见 `docs/release-runbook.md`。
- 提交信息写清改动目的；涉及行为规范变更时按第 4 节同步 `openspec/`。
- PR 请填写 `.github/PULL_REQUEST_TEMPLATE.md` 的验证清单；涉及运行时行为时对照 `docs/device-checklist.md`。

## 4. openspec 变更流程

仓库用 openspec 管理规范：

- `openspec/specs/` 存放现行规范（如 `proxy-connection`、`backup-restore`、`repository-governance` 等）；
- 变更走 `openspec/changes/<change-id>/`（`proposal.md`、`tasks.md` 与 spec delta），完成后归档到 `openspec/changes/archive/`；配置见 `openspec/config.yaml`；
- 改变行为时先提变更提案并实现，随后同步 `openspec/specs/` 中对应规范，避免规范与代码漂移；`README.md` 的 Development 段同样指明这一流程；
- `.roo/commands/opsx-*.md` 提供 propose / apply / sync / archive 等阶段的命令描述，可供参考。

## 5. 通道契约必须两端同步

Flutter（Dart）与宿主（Kotlin）之间的 channel 方法／事件由 `tools/diagnostics/channel_audit.py` 约束：它扫描 Dart 侧的 `box.call('…')` / `events.add({'type': …})` 与 Kotlin 侧的 `when(call.method)` / `emit("…")`，双端差集必须为空，且该脚本已在 CI 中运行。

因此**新增、改名或删除任何桥接方法或事件时，必须同时修改两端**；只改一端会导致 `channel_audit.py` 失败。`Capabilities.kt` 是 B-box 独有能力开关的唯一来源，`docs/bbox-bridge.md` 记录桥接层的每个方法与事件，改动时应一并核对。

## 6. 代码与文档一致性

- 文档中的版本号、`THRONE_CORE_REF`、命令与字段以仓库内实际配置为准；不确定时采用保守表述，不要凭记忆填写。
- 本仓库为下游发行版，核心（sing-box）按 `nb4a.properties` 的 `THRONE_CORE_REF` 固定并由 CI 构建；请勿在本仓库内改动上游核心代码。

行为准则见 [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md)，安全问题请按 [SECURITY.md](SECURITY.md) 私下报告。
