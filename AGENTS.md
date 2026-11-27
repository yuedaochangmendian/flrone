# Flrone（原 throne-flclash-ui）

Flrone 是 sing-box 内核的 Android GUI：Throne 引擎 + 基于 FlClash dev 分支所用 prism UI 层重建的 Flutter 界面，Kotlin 宿主负责桥接与平台能力，包名 `com.throneflclash`。仓库 `https://github.com/yuedaochangmendian/flrone`（旧仓库名 `throne-flclash-ui` 的 GitHub 地址会重定向）；本地主工作目录 `E:\hu\work\flrone`。旧路径 `E:\hu\work\throne-flclash-ui` 的 junction 已在 2026-11-27 修复 142 个 linked worktree 的 gitdir 后删除，不要再引用旧路径。仓库全 UTF-8 / LF（`.gitattributes` 强制 `eol=lf`，vendored 文件哈希按 LF 计算），不要写入 CRLF。

## 架构

- Kotlin 宿主：`io.throne.bbox` corehost（`io.nekohasekai.sagernet` 为 SagerNet/nb4a 血统，`io.flrone.bridge` / `io.flrone.flutter` 为自有桥接层），主源码 `app/src/main/java/`；Flutter 模块 `flutter/` 以预编译 AAR `io.flrone.ui:flutter_release:1.0` 链接（`app/build.gradle.kts`），AAR 是构建产物、被 gitignore，Dart 改动后必须重建（`local-inputs.sh --only=flutter`）。
- 内核不是自有 fork：`THRONE_CORE_REF`（`nb4a.properties`）钉住 throneproj/Throne 上游提交，CI/本地脚本经 gomobile（AAR 路径）或 c-shared（`libthrone.so`）构建 ThroneCore，patch 覆盖在 `buildScript/core-patch/`。内核侧日志噪音（如握手成功上报 ECONNRESET）不可在本仓库修；热路径坚持 Go，不引入 Rust（ADR 0007）。
- 数据权威（ADR 0005 / ADR 0006）：**每份数据一个文件、一个写者，无 Room**——Dart 独占 profiles/groups（`documents/profiles.json`，`ProfileStore`，Kotlin 经 `DartProfileStore` 只读、写走 `DartProfileWriter.applyDocument`）；Go 独占 `documents/route_*.json`（含 `global_route_rules.json`，经 Action wire）；Kotlin `SettingsStore` → `SettingsJsonStore` 独占 `documents/settings.json` / `markers.json`。Room 代码已从 v4.17.x 彻底删除，旧库迁移链也移除；`.thrbackup` 恢复仍是支持路径。
- 关键路径：`app/src/main/java/io/flrone/`（桥接与 Flutter 宿主）、`flutter/lib/`（UI、服务、数据层；`flutter/lib/ui/` 为 vendored Prism）、`buildScript/core-patch/`（内核覆盖）、`tools/diagnostics/`（契约审计）、`tools/local-build/`（本地构建/发版）、`docs/adr/`（架构决策）。

## 当前状态（2026-11-27）

- `nb4a.properties`：`VERSION_NAME=4.17.4`、`VERSION_CODE=198`、`PACKAGE_NAME=com.throneflclash`。分支 `main`。
- `releases/latest` = 稳定版 **v4.15.1**（2026-11-24）；本轮预览 **v4.17.4-pre.2**（4 个资产：3 ABI APK + `SHA256SUMS`，无 `throne-update.json`；pre.1 已按预览保留策略清理）。
- **Kotlin-free core path（进行中，本地 main）**：
  - `groupsSelect`：节点切换改为 Go action（`groups_actions.go`，运行时 `group.Selector`，无 HTTP），`FlroneApi.kt` 删除，启动不再自动开启 Clash API；持久化拆为 `persistSelection`（不重载）/`selectMember`（重载）。已知边界：普通分组没有 selector 出站，仍回落重载；可原地切换的是自定义完整配置里的 selector。
  - profiles S1+S2：S1 的 `stats`/`reorder`/`clearTestResults`/`nodeList`/`nodeReorder`，S2 的 `config`/`read`/`write` 已迁 Dart（`ProfileDocumentService`）；`profiles.platform` 26 ops、8 个 Dart-owned；Kotlin 仅保留窄 `sort.reposition`、`revision.edit`、`subscription.schedule` 与 `data.refresh`。
  - config 阶段 0/1/2：Kotlin `ConfigGenerator` golden harness + 15 个 fixture（含 Stage-2 协议矩阵与 WARP/chain 预备语料，字节级 expected）已入库；Go 侧新增 `qjson.go`（对齐 Kotlin JsonWriter）、`config_inputs.go`/`settings_defaults.go`（只读文档 + NTP 等 settings key）、`config_build*.go`（Stage-2 builder：shadowsocks/direct/chain/http/socks/vmess/vless/trojan/hysteria2/wireguard endpoint 全部字节一致；新增 socks-basic / vless-reality-grpc / trojan-http-tls；custom-full-config 与 4 个 WARP fixture 以 `goStage=3` 标记）、`profileValidate`/`profileNormalize`/`profileNewOutbound` actions。
  - 设计结论：config.build 用 **Go**；完整迁移约 19–28 人周（2–3 人 2.5–4 个月）。test session 迁移被 test config 生成/结果落盘依赖阻塞，须排在 config 之后。
- Prism UI vendored 基线：`cae9a435`（v0.1.3 之后 44 个提交，2026-11-25），149 个 dart，来源与本地补丁见 `docs/prism-upstream.md`；清单 `flutter/flclash-manifest.json` / `tools/prism_baseline.json`。
- 上次完整门禁（2026-11-27）：`flutter analyze --fatal-infos` 干净、**1112 个 Flutter 测试**全绿；Go mobile（跳过既有 Windows `TestParseProfileRequest*`，含 Stage-1 golden）、JVM、`config_golden.py --check`（15/15）、action/channel/platform/symbol/core-patch 审计全过。

## 构建与测试

本机 SDK CI 钉版（CI 用 `.github/actions/android-build/action.yml` 的 `flutter-version: '3.50.0'`，`.github/actions/throne-core/action.yml` 的 Go 1.27.0）：

- Flutter：`E:\hu\toolchain\flutter-3.50.0`（Git Bash 用 `export PATH=/e/hu/toolchain/flutter-3.50.0/bin:$PATH`；`E:\hu\toolchain\flutter` 是共享目录，当前 3.47.8）
- `JAVA_HOME=E:\hu\toolchain\jdk21`（JDK 21；Gradle wrapper 钉 8.14.7，已缓存在 `gradle-home/wrapper/dists`；AGP 8.13.2 不兼容 Gradle 9）
- `ANDROID_HOME=E:\hu\toolchain\android-sdk`（platform 37，compileSdk 37 / targetSdk 36 / minSdk 24；NDK 28.2.13676358、CMake 3.22.1）
- `GRADLE_USER_HOME=E:\hu\toolchain\gradle-home`、`PUB_CACHE=E:\hu\toolchain\pub-cache`、`BACKUP_TEST_SQLITE=E:\hu\toolchain\sqlite3\sqlite3.dll`（Windows 上 `flutter test` 的备份用例必需；缺了会静默裸崩）
- 完整本地环境先 `source tools/local-build/local-env.sh`（会自动把 Windows 风格变量转成 MSYS/Gradle 需要的路径，并优先选 CI 钉版 Flutter/Go）；构建输入用 `bash tools/local-build/local-inputs.sh`（`--check` 只校验，`--only=flutter,routeprofiles,...` 跑子集）。

验证命令（CI 门禁等价）：

```bash
flutter analyze --fatal-infos
flutter test
./gradlew app:testOssDebugUnitTest
python tools/diagnostics/action_contract.py
python tools/diagnostics/symbol_audit.py
python tools/diagnostics/channel_audit.py
python tools/diagnostics/platform_duty_audit.py
python tools/diagnostics/settings_contract.py
python tools/diagnostics/legacy_reader_audit.py
python tools/diagnostics/ffi_regression_test.py
python tools/diagnostics/github_governance.py
```

诊断目录另有 `settings_audit.py`、`i18n_coverage.py`、`core_patch_audit.py`、`coverage_gate.py`、`aar_channel_audit.py`、`workflow_path_audit.py` 等，由 `ci.yml` 运行；`prism_diff.py`（上游树对比）与 `core_pin_report.py`（core pin 对照）是**手工工具，CI 不跑**——需要时按 `docs/prism-upstream.md` / `docs/core-upgrade.md` 手动执行。**命令一律裸跑取退出码**，不要用 `cmd | tail`——管道吞失败退出码已多次发生（误判绿灯）。

## 发布 SOP

- **prerelease（默认，本地构建上传）**：`source tools/local-build/local-env.sh` →（首次/输入缺失时）`bash tools/local-build/local-inputs.sh` → `bash tools/local-build/local-release.sh`（默认构建即上传；`--build-only` 只构建打包到 `dist/`，不上传）。前提：工作树干净、提交已在 `main` 上；`N` = GitHub 上该版本最大 `vX.Y.Z-pre.N` + 1（读取失败即中止，不会猜号）；用与已发布 APK 相同的 release 密钥（`throne-release` keystore，路径/口令见 `docs/local-build.md`，换钥会使老设备无法覆盖安装）；产物为 3 ABI APK + `SHA256SUMS`，**不带** `throne-update.json`，标 `prerelease=true` 且不占 `releases/latest`。新版本线才需要 bump `VERSION_NAME`/`VERSION_CODE`；同一版本线连续发预览由脚本自增 `N`。
- **stable（显式转正，GitHub Actions）**：在 `main` 上 dispatch `Stable release`（`workflow_dispatch`，`version` = `VERSION_NAME`，无提交输入）；它先 `workflow_call` 调 `ci.yml` 在同一提交跑完整门禁，再以 `channel=stable` / `build-number=999` 重建签名，发布 `vX.Y.Z` + `--latest`，资产为 3 APK + `SHA256SUMS` + `throne-update.json`。**不要**把 `-pre.N` release 直接改旗标转正：`github_governance.py` 会判 `release:preview-flag` / `release:preview-manifest` 违规，且 pre 的 versionCode 更低。工作流失败时用 `docs/release-runbook.md` 的本地补发路径（草稿按 release id 查、资产走 `uploads.github.com`）。
- 每次发版前 `CHANGELOG.md` 顶部必须有对应 `#### <version>` 段（`buildScript/release_notes.sh` 强校验），且 `CHANGELOG.zh-CN.md` 要有同版本、同分组的中文段（脚本自动追加 `## 中文说明`）。**没有功能性变化时不要发 prerelease**（纯 CI/文档/审计改动不单独发预览）。
- tag 规则 `^v\d+\.\d+\.\d+(-pre\.\d+)?$`；一个 tag 对应一个 release，不复用/改名/删除重建。发布前查重，dispatch 超时重发先看 run 列表；`gh` 不读 git proxy，命令前加 `HTTPS_PROXY=http://127.0.0.1:7890`（代理断连时 gh api 仍可用）。

## 命名与边界

- 应用显示名、`rootProject.name`（`settings.gradle.kts`）、README 均为 **Flrone**；`PACKAGE_NAME` / Android `applicationId` 保持 **`com.throneflclash`**（历史包名，改动会破坏升级与数据目录）。
- `UpdateChecker.REPOSITORY`（`app/src/main/java/io/nekohasekai/sagernet/update/UpdateChecker.kt`）必须指向 `yuedaochangmendian/flrone`——更新器读 GitHub releases 与两份 CHANGELOG；曾错误指向上游导致更新失效。`flutter/lib/pages/about.dart` 的 `repositoryUrl` 同指本仓库。
- GitHub 上旧的 `throne-flclash-ui` URL 重定向到新仓库；文档/链接写新名，但代码标识符里保留 `throne`/`flclash` 的（如 `throne-release.keystore`、`throne-update.json`、`FlClash` 动画参考）是历史契约，不要顺手改名。

## 环境（2026-11-26 迁至 `E:\hu\toolchain`，C 盘旧路径只留 junction）

实体目录：`android-sdk`（含 platforms 24/34/35/36/37、NDK 27/28、cmake）、`android-home`（AVD、adbkey、`debug.keystore`）、`jdk21`、`flutter`（3.47.8）与 `flutter-3.50.0`（CI 钉版）、`go` / `go-1.27` / `gopath`（`gomobile` 在 `gopath\bin`）、`gradle-home`（wrapper dists 8.10.2/8.14.7/9.x）、`rustup` / `cargo`（stable + 1.99.0 × gnu/msvc）、`pub-cache`、`python\311`、`sqlite3\sqlite3.dll`、`caches\{go,npm,pip}`。旧 `C:\Users\ljlgg\.android` / `.gradle` / `.cargo` / `go` / `Pub\Cache` 等均为 junction；用户级环境变量已指向 `E:\hu\toolchain`。Git Bash 单文件入口 `source /e/hu/toolchain/env.sh`（设 JAVA_HOME/ANDROID_HOME/PATH/BACKUP_TEST_SQLITE 等）；PowerShell 入口 `. E:\hu\toolchain\env.ps1`（须保留 UTF-8 BOM，本机 `ExecutionPolicy=Restricted`，用 `powershell -ExecutionPolicy Bypass`）。`local-env.sh` 会把 Windows 风格 `JAVA_HOME` 等转成 MSYS 路径、`GRADLE_USER_HOME` 转正斜杠——新增路径变量时沿用 `_msys_path` / `_win_slash_path` 两个助手。
- 用户级变量用 PowerShell `[Environment]::SetEnvironmentVariable(名称, 值, "User")` 写入：`setx "VAR" "path"` 会把引号一起存进值里（2026-11-26 曾致 Gradle `InvalidPathException`），本机变量已改为无引号。

## 已知坑与教训（历史事故提炼）

- **Android ICU regex ≠ desktop JVM**：嵌套占有量词（`[^\[\]"]++` 等）在 JVM 单测通过、Android `<clinit>` 抛 `PatternSyntaxException` → `ExceptionInInitializerError`（`catch (Exception)` 抓不住），且崩溃页复用坏类会导致重启循环白屏。脱敏/解析正则必须扁平无占有量词、`safeRegex` 逐条编译、`runCatching` 逐次兜底，上报路径 `catch Throwable` 并对重启限流；这类正则要在设备上实跑（`d8` 成 dex → `app_process`）才算验证。
- **跨平台契约改动必须双端 grep**：`flutter analyze` 不校验 MethodChannel 方法名；改通道名/op/payload 键后全文核对 Dart/Kotlin/Go 两端，并跑 `channel_audit` / `platform_duty_audit` / `settings_contract` / `action_contract`。这些审计脚本本身是高价值评审对象——放行型假阴性关卡比没有更糟（字符串匹配要兼容双引号、不可定界时响亮失败）。
- **数据单写者**：Room/settings 曾因多写者出现「备份读冻结表、恢复写死表」「两路设置互相覆盖」。迁移叫 "hand-over" 的表要立刻切断旧读者；「只写不读的持久化 = 没有持久化」；Action「入队即返」的 API 不要包 retry/timeout。
- **profiles/catalog 空列表诊断**：先看 `data.profilesView`（宿主目录/exists/行数/解析错误）与备份页「宿主读取」「目录」两行——`不可用:…` = 解析失败，目录为空/路径不符 = 目录问题，宿主也 1/1 而 UI 空 = catalog 映射/事件推送。`DartProfileStore.directory` 必须在 `BboxBridge.install()` 时就设置，否则首次 catalog 刷新缓存空列表跨重启复现。
- **二引擎/UI 线程**：Android 上 `merged_platform_ui_thread` 默认开启，main 线程构造的任何 `FlutterEngine`（含 headless）其 Dart 同步工作都直接吃 UI 帧预算；`FlutterEngineGroup` 还共享 isolate group 堆/GC。真要隔离用 spawned isolate（`kernelWorker`，同 group 独立线程）或与非 main 线程创建引擎（受 `@UiThread` 断言限制）。broadcast 流没有监听者就是静默黑洞——`connect()` 与 `listen()` 要原子绑定。
- **Windows 本地**：`flutter test` 需要 `BACKUP_TEST_SQLITE` 指向官方 sqlite3.dll；`flutter pub get` 会把 `pubspec.lock` 写成 `pub.flutter-io.cn`，提交前必须恢复为 `pub.dev`（CI 一致，已多次发生）。`Process.myPid()` 在 JVM 单测是 Stub 抛异常，用可注入 provider；`Isolate.run` 闭包必须写在顶层函数（捕获作用域 Context 会报非法 isolate 消息）。
- **git 操作**：`git worktree` 用于内核升级等实验（见 `docs/core-upgrade.md`），本仓库登记了大量 linked worktree（`.git/worktrees/*/gitdir` 记录绝对路径）；旧路径 `work/throne-flclash-ui` 的 junction 已于 2026-11-27 删除，142 个 worktree 的 gitdir 已改指 `E:/hu/work/flrone`。fetch 未成功前严禁 `git reset --hard origin/main`；squash 合并后开新分支用 `git checkout -B <branch> origin/main` + cherry-pick，不用 rebase；rebase 解冲突 `git checkout --ours` 会抹掉自动合并的 hunk，须 `git checkout --merge` 手工解。`gh pr merge` 后要 `gh pr view --json state` 验证 MERGED（BEHIND 会报错且退出码不可靠）。
- **CI 边界**：`ci.yml` 只在 PR 触发（及被 stable `workflow_call` 调用），合并 `main` 不跑 CI、不发预览；`Stable release` 必须在 `main` 上 dispatch。治理脚本 `github_governance.py` 每周跑（`governance.yml`），新增违规阻断、历史遗留列基线。2026-11-26 实测 `main` 分支保护当前未启用（`docs/github-workflow.md` §8.1），如需恢复由仓库所有者用 PAT 设置。
- **部分设置需重启应用**：`app.restart`（`triggerFullRestart`：停服务 + ProcessPhoenix）用于「restart required」类设置；改设置后 UI 未生效先确认是否需要重启，而不是直接判定功能失效。

## 文档索引

`docs/release-runbook.md`（发版与 GitHub API 5xx 补发）、`docs/github-workflow.md`（分支/PR/tag/release/更新器契约，流程基准）、`docs/local-build.md`（本地全量构建与签名）、`docs/device-checklist.md`（发布后设备回归）、`docs/transport-invariants.md`（传输层对齐约束）、`docs/prism-upstream.md`（vendored UI 来源/同步）、`docs/adr/0004-strict-bettbox-parity.md`、`docs/adr/0005-data-authority-phased-plan.md`、`docs/adr/0006-pure-file-data-layer.md`（另 0001/0002/0007），`README.md` / `readme/README_zh.md`、`CHANGELOG.md` / `CHANGELOG.zh-CN.md`。
