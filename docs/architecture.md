# 应用结构

Flrone 是一个多模块工程：Android 宿主/桥接、纯 Kotlin 模型、JNI 内核 shim、Flutter UI 与 Go 内核覆盖层。本文记录模块边界和依赖方向；命名词汇见 `docs/naming.md`，数据权威见 ADR 0005/0006。

## 顶层模块

| 路径 | Gradle 模块 | 命名空间 | 职责 |
| --- | --- | --- | --- |
| `app/` | `:app` | 混合 `io.flrone.bridge` / `io.flrone.flutter` / 历史 `io.nekohasekai.sagernet` | Android 宿主：Activity/service、平台能力、Dart↔Go 桥接、旧 Throne 模型的编辑/导入/校验 |
| `core/` | `:core` | `io.flrone.core` | JNI shim（`libcore.so`）、`TunInterface`、`CorePlatform`、`throne_*` C ABI 的 Kotlin 侧 |
| `model/` | `:model` | `io.flrone.model` | 纯 Kotlin 数据模型，无 Android 依赖 |
| `flutter/` | —（预编译 AAR） | `io.flrone.ui` | Flutter UI、Dart 数据层、service engine；通过 `flutter_release-1.0.aar` 链接进 app |
| `buildScript/core-patch/` | — | Go `mobile` 包 | Throne 内核覆盖层：action bus、C ABI、配置构建、测试配置 |
| `tools/` | — | Python/Dart | 构建、诊断、审计、生成器 |

Gradle 只包含 `:app`、`:core`、`:model`；Flutter 模块由 `flutter build aar` 产出，不进入 `settings.gradle.kts`。

## 依赖方向

```
app ──► model
 │
 ├──► core（JNI）
 └──► io.flrone.ui:flutter_release（AAR）
             │
             └── dart:ffi ──► libthrone.so（Go mobile 包）
```

- `model` 不依赖 `app`/`core`/Flutter；
- `core` 只依赖 Android/NDK 与自身 JNI，不反向依赖 `app`；
- `app` 可以依赖 `model`、`core` 和 Flutter AAR；
- Flutter 只通过 method channel 与预编译 AAR 和 app 通信，通过 `dart:ffi` 找 `libthrone.so`；
- Go 覆盖层不依赖 Kotlin/Dart 源码，只共享 C ABI/JSON 契约。

## 包边界

- `io.flrone.bridge`：平台/桥接职责（设置、备份、通知、Wi-Fi、日志、配置准备 `ConfigPrepare`）。
- `io.flrone.flutter`：Flutter engine、service engine、MethodChannel 宿主与 `KernelServiceActions`。
- `io.flrone.core`：JNI/C ABI、TUN、平台回调。
- `io.flrone.model`：纯模型。
- `io.nekohasekai.sagernet` / `moe.matsuri.nb4a`：Throne 血统的历史实现。仍承担 profile 编辑/导入/校验、核心历史组件与 Android 入口；**不是新代码的落点**，新平台/桥接代码写进 `io.flrone.*`。包名保持是为了 Manifest/服务/原生回调与升级兼容，不做全量重命名。

## 数据与配置路径

- `documents/profiles.json`：Dart 唯一写者，Kotlin/Go 只读；
- `documents/profile_selection.json`：选择状态（ADR 0008 P1-5）——Dart 唯一写者（`ProfileSelectionDocument`，每次选择变更原子落盘），Kotlin/Go 只读；迁移期 Kotlin 仍是 `settings.json` 的选择写者（widget/快捷开关/BaseService/订阅刷新/删除回退等路径不经 Dart 的 dashboard/groups 帧），Go `config.build` 与 Kotlin `config.prepare` 用「一致门禁」读该文件：仅当文档与 settings 的 `profileId`/`current_group` 一致、或 settings 无选择（升级场景）时才采用文档，不一致则 settings 优先（判定文档过期）。profiles S4 完成后移除该门禁，配置构建只读此文档；
- `documents/settings.json`、`markers.json`：Kotlin 唯一写者，Go 只读；
- `documents/route_*.json`：Go 唯一写者，Kotlin/Dart 只读；
- 配置构建：Dart `KernelService` → Kotlin `config.prepare` → Go `configBuild` → `createInstance`；Kotlin 不再生成配置。
- 测试配置：Kotlin 测速会话 → `build_test_config` host call → Go `buildTestCoreConfig`。

## 构建入口

```bash
source tools/local-build/local-env.sh
bash tools/local-build/local-inputs.sh          # Flutter AAR + Go 内核 + schema + 资源
bash tools/local-build/local-release.sh         # 预览构建/上传
```

CI 使用 `:app:testOssDebugUnitTest`、`:app:assembleOssDebug`、Flutter analyze/test 与 Go mobile/审计；模块路径过滤由 `tools/diagnostics/workflow_path_audit.py` 校验。