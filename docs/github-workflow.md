# GitHub 流程规范

本文是仓库在 GitHub 上的**唯一流程基准**：分支、PR、发版、tag、release、更新器契约与 CI 职责。`CONTRIBUTING.md` 第 3 节与 `docs/release-runbook.md` 是它的执行细则，冲突时以本文为准。配置真源是仓库内文件（`nb4a.properties`、`.github/workflows/`、`buildScript/`），本文不复制具体数值，只固定规则。

配套自动校验：`tools/diagnostics/github_governance.py`（`Repository governance` workflow 每周运行，也可手动触发）。**新增违规会阻断，历史遗留列在 `github_governance_baseline.json`，修复一项就从基线删一项。**

## 1. 分支模型

| 规则 | 要求 |
|---|---|
| 发布基线 | `main` 是唯一基线；只接受 PR 合并，禁止直接推送提交（`CONTRIBUTING.md` 已规定） |
| 分支命名 | `feat/*`、`refactor/*`、`fix/*`、`docs/*`、`build/*`、`chore/*`、`dependabot/*`；禁止 `wip-*`、`tmp-*`、日期分支、个人名分支 |
| 起点 | 从最新 `main` 创建；长期开发线需定期 rebase `main`，不得与基线长期分叉 |
| 收口 | 一个 PR 对应一个自洽改动；超过约 20 提交的线应拆成可独立审查的 PR |
| 合并后 | 删除源分支（仓库设置 `delete_branch_on_merge=true`）；已合并分支不留残枝 |
| 保护 | `main` 应配置保护：禁止强制推送与删除、要求经 PR、要求 CI 全绿。**启用前必须确认 CI 依赖可用**，否则会把 `main` 锁死（见第 7 节） |

> **已启用（2026-11-08，管理员约束于 2026-11-09 收紧）**：`main` 要求经 PR、分支保持最新，并通过 `Unit tests and debug build` 与 `Flutter module tests` 两个检查；强推和删除被禁止，管理员同样不能绕过。单维护者场景不强制审批，避免无人可批导致分支锁死。3.3.1 开发线已于同日以 PR #11 合回 `main`；`v3.3.1-pre.*` 的 tag 仍指向合并前的提交，属已发布历史的正常结果，不回填。

## 2. Pull Request

- 填写 `.github/PULL_REQUEST_TEMPLATE.md` 的全部验证清单；涉及桥接方法／事件时同步 Dart 与 Kotlin 两端并核对 `docs/bbox-bridge.md`、`Capabilities.kt`。
- 合并前 CI 全绿（`ci.yml`：Kotlin 单测与 debug 构建、Flutter analyze / test / 覆盖率下限、`channel_audit`、`symbol_audit`、`settings_audit`、`settings_contract`、`ffi_regression_test`、`generated_models_check`、`py_syntax_check`、cgo preamble、AAR API 与通道审计）。
- 依赖升级由 `dependabot.yml` 每周发起；合并前确认不引入 SDK / AGP / Kotlin 版本跨越，关闭时不留分支。
- CI 因外部依赖故障变红**不等于代码不合格**；按第 7 节处理，不得为凑绿而跳过签名、校验或直接推送 `main`。

## 3. 版本与发版通道

**唯一真源**：`nb4a.properties` 的 `PACKAGE_NAME` / `VERSION_NAME` / `VERSION_CODE` / `THRONE_CORE_REF`。构建号只由 workflow 注入（`THRONE_CHANNEL`、`THRONE_BUILD`），不得手改 APK 元数据。

**只有一条发版通道**：`main` CI 成功后，`release.yml` 的 `workflow_run` 自动发布 `nb4a.properties` 中 `VERSION_NAME` 对应的下一个 **prerelease**。没有 `workflow_dispatch`、没有 tag 推送触发；正式版只由维护者从预览提交另发，绝不由合并 `main` 自动产生（2026-11-16 起，默认发 prerelease）。

| 项 | 值 |
|---|---|
| tag | `vX.Y.Z-pre.N`，`N` 取该版本已有预览号最大值 +1（1..998） |
| 包名 | `PACKAGE_NAME` |
| 触发 | `main` 的 CI run 成功且仍为当前 `main`、且自最近 release tag 有应用/构建输入变更 |
| `versionName` / `versionCode` | `X.Y.Z-pre.N` / `VERSION_CODE*1000 + N` |
| GitHub 标记 | `prerelease=true`，**不占 `releases/latest`** |
| 资产 | 3 个 ABI APK + `SHA256SUMS`（preview 通道**不得**带 `throne-update.json`） |
| 应用内更新 | 不推送（更新器只读 `releases/latest`） |

- **发下一版**：递增 `VERSION_NAME`（及 `VERSION_CODE`）、在 `CHANGELOG.md` 顶部补 `#### <version>` 段落、合并到 `main`。同一版本线内连续合并由 `N` 自动递增，无需 bump；`N` 用尽到 998 才要求 bump。
- **转正正式版**（维护者显式操作，且必须是一条**新**发布）：优先运行 `Stable release` 的 `workflow_dispatch`（`version` = `VERSION_NAME`，`target_sha` = 预览对应的提交），它按 stable 通道重新构建并发布 `vX.Y.Z` + `--latest`。手工路径（工作流失败时）：以预览对应的提交为 `target_commitish` 创建 `vX.Y.Z`（不带 `-pre.N`）的正式 release，资产按 stable 规则重打（`release_assets.py <apk-dir> <dist> stable`，即 3 个 ABI APK + `SHA256SUMS` + `throne-update.json`），标题为 `vX.Y.Z`，标记 `--latest`。**不要**把 `-pre.N` 的 release 直接 `--prerelease=false`：`github_governance.py` 的 `release:preview-flag` 与 `release:preview-manifest` 两条规则会判它违规（预览 tag 不允许是正式版，也不允许带更新清单），而且 `-pre.N` 的 `versionCode` 低于同版本正式版，转正后更新器会把它当成更旧的版本。
- 正式版的 `VERSION_NAME` 必须与 `CHANGELOG.md` 顶部 `#### <version>` 段落一致（`github_governance.py` 的 `version:changelog` 校验；预览段落允许带 `-pre.N` 后缀）。
- `release_assets.py` 会拒绝 `channel` 与 `versionName` 不匹配、签名者不唯一、ABI 缺失；`Changelog` 步骤会拒绝缺少 `#### <version>` 段落。**发版前必须先写 CHANGELOG 段落**。
- 一个 tag 对应一个 release；tag 不复用、不改名、不删除重建。
- `Version` 步骤校验触发提交仍是当前 `main`、预览 tag 列表可读取（读取失败即中止，绝不复用旧号）；`publish_release.sh` 对每次写操作重试 3 次并保留 `dist/` 供降级补发。

## 4. tag 与 release 命名

- 允许：`^v\d+\.\d+\.\d+(-pre\.\d+)?$`。禁止 `wip-*`、`*-debug`、`*-bbox-ui-*`、日期 tag 等非正式命名。
- `main` CI 成功后自动创建 `vX.Y.Z-pre.N` GitHub prerelease；没有手动补发、没有仅产 artifact 的 `publish=false` 路径，也没有推送 tag 触发。
- `releases/latest` 只由**显式转正**且资产齐全的 stable release 占用；自动 prerelease 绝不碰它。
- release 的 `name` 与 `tag_name` 保持一致。

> **已修复（2026-11-08）**：`v3.3.1-pre.23` 已恢复为 prerelease，名称改为与 tag 一致，并移除误带的 `throne-update.json`。正式 `v3.3.1` 已于 2026-11-08 发布并成为 `releases/latest`，5 个资产与更新清单齐全。治理脚本现在会拒绝“preview tag 被标成正式版”，防止同类问题再次进入 Latest 或应用内更新。另有 6 个 2026-11-01 的 debug 构建曾被标为 stable、5 个历史 preview release 误带 `throne-update.json`、3 个 `wip-bbox-*` tag 无 release，均已列入治理基线。

## 5. 更新器与签名契约

- `UpdateChecker.REPOSITORY` **必须指向本仓库** `yuedaochangmendian/throne-flclash-ui`；常量曾指向上游 `throneproj/ThroneForAndroid`，导致本仓库发布的 `throne-update.json` 根本不被应用内更新器读取。本次已在 `main` 修复（此前另在 `feat/ffi` 修过一次，该分支已合并删除），**已发布 APK 需重新构建才生效**。
- `throne-update.json`（`schema=1`）字段：`packageName`、`channel`、`versionName`、`versionCode`、`coreRef`、`minSdk`、`signerSha256`、`assets`（每个 ABI 的 `name` / `size` / `sha256`）。三个 ABI 必须同一签名者、同一 `versionCode`，且与实际 APK / `SHA256SUMS` 一致。
- 签名固定值来自仓库 secrets，发布前按 `SIGNING-POLICY.md` 核对 `signerSha256`；`UpdateVerifier` 会校验文件大小、SHA-256、包名、`versionCode` 递增、签名一致与 pin。
- `release_assets.py` 只在 stable 通道生成清单；自动发版默认是 preview，产物**不带** `throne-update.json`，转正时需补上。

## 6. workflow 职责边界

| workflow | 触发 | 职责 | 对外产物 |
|---|---|---|---|
| `ci.yml` | push `main` / PR to `main` | 轻量变更检测后运行静态分析、单测、契约审计；文档-only 变更走全跳过成功路径；**验证只跑一次**：`main` 的 push 若合并树与 PR head 树一致（squash / rebase 的 `(#N)` 与 merge commit 的 `Merge pull request #N from` 两种消息都能识别）则跳过两个重活 job | `build-inputs`（仅 `main` 的 push 且未判重：Flutter AAR、ThroneCore、schema、routeprofiles、dashboard，供 Release 复用；判重跳过时 Release 回退完整构建）/ `flutter-coverage`（仅 main 或失败） |
| `release.yml` | CI `workflow_run`（仅 `main` 成功） | 仅在存在应用或构建输入变化时自动发布 `vX.Y.Z-pre.N` prerelease；复用 CI 的 `build-inputs` 只重跑 release Gradle 任务，缺失时回退完整构建；签名、4 个 preview 资产、publish（`--prerelease`，不碰 latest） | GitHub prerelease |
| `governance.yml` | 每周 / 手动 | 校验仓库状态是否符合本文 | Step Summary |

仅涉及文档的 PR 会由 `Detect changed areas` 识别，两个必需 Job 的所有步骤被跳过、以成功结束，不启动 Android/Flutter 构建；同样的文档-only 提交合并到 `main` 后也不会生成新 release。

`release.yml` 只有 `workflow_run` 一条路径：触发提交仍是当前 `main`、且自最近 release tag 有应用/构建输入变更时才构建；`N` 从该版本已有预览号自动递增，读取失败即中止。产物一律走 preview 通道（无 `throne-update.json`），不占 `releases/latest`；正式版由维护者从预览提交另发。

## 7. 降级路径（外部依赖故障）

- GitHub releases 下载端点可能返回 504（2026-11-08 的 `kotlin-compiler-embeddable-2.2.21.jar` 持续故障），导致 `ci.yml` / `release.yml` 的 Gradle 构建失败。**这是外部故障，不是代码问题**；`Repository governance` 不依赖 Gradle/NDK/Flutter，仍可运行。
- 自动 release 复用 CI 的 `build-inputs` artifact（仅 `main` push 的 CI 上传；按触发 CI run id 下载，并校验该 run 的 `head_sha` 与本次构建的 `HEAD` 完全一致，不一致即丢弃、回退完整构建）。artifact 只被当作构建输入读取、从不执行其中任何脚本；`android-build` 的 `reuse-inputs` 断言保证不会用残缺输入打出 APK。
- 已构建并签名的产物由 `publish_release.sh` 保留为 `Flrone-<tag>-publish-failed` artifact；按 `docs/release-runbook.md` 的本地补发路径收口（草稿按 release id 查询、`target_commitish` 写目标 sha、资产走 `uploads.github.com`）。
- 需要读取 release 资产时，`api.github.com/repos/.../releases/assets/<id>` 的 302 `Location`（`release-assets.githubusercontent.com` 签名直连）通常仍可用，可配合 HTTP Range；不要因为 `github.com/.../releases/download/` 返回 504 就判定资产丢失。
- 发布失败时可重跑对应的 `main` CI run 再次触发 `workflow_run`；`Version` 步骤对已存在的 tag 安全跳过，因此只有发布未成功落 tag 时才会重试构建。本地补发仅限 `docs/release-runbook.md` 的手动路径。

## 8. 治理校验

`github_governance.py` 用 GitHub API 只读检查：分支命名、tag 命名、tag↔release 一一对应、stable 资产齐全、preview 不带清单、`releases/latest` 合法、`UpdateChecker.REPOSITORY` 指向本仓库、`nb4a.properties` 与 CHANGELOG 顶部段落一致、仓库 `delete_branch_on_merge` 已开启。`delete_branch_on_merge` 属 admin 级字段，CI 的 `github.token`（`contents: read`）读不到时该项跳过、不误报；用维护者 PAT 本地运行时会实际校验。

- `--strict`：存在**不在基线内**的违规时退出 1；`Repository governance` 以 strict 运行并写入 Step Summary。
- 基线 `github_governance_baseline.json` 只收录已确认的历史遗留；每修复一项就删除对应 id，使校验重新对该项生效。
- 本地运行：`GH_TOKEN=<token> python3 tools/diagnostics/github_governance.py --repo <owner/repo> --format markdown`。

## 9. 待收口项（需维护者决策）

| 项 | 现状 | 建议动作 | 影响 |
|---|---|---|---|
| `v4.0.0` 平台升级 | `compileSdk 37`、依赖大版本、核心/schema 与签名资产均已发布 | 无 | 完成 |
| Issue #13 Base64 样本 | 等待可复现的远程订阅样本 | 收到样本后补语料并关闭 | 低 |
| Issue #17 真机矩阵 | arm64 / TV 验收已改为可选的发布后回归 | 有空闲设备时执行 | 低 |
| 6 个 debug release | 曾标 stable、资产不齐 | 已改标 `prerelease`（可逆）；或删除 | 中 |
| 5 个 preview 带清单 | v3.2.18–v3.2.22 | 移除 `throne-update.json` 资产，或列入基线保留 | 中 |
| 3 个 `wip-bbox-*` tag | 无对应 release | 删除调试 tag | 低 |

**已收口（2026-11-10）**：正式 `v3.3.2` 与 `v4.0.0` 均已发布；PR #38 完成平台升级，PR #39 修复 build-tools 37 的签名输出解析，PR #6/#9 因被 #38 覆盖而关闭，PR #16 的轻量扫码实现已进入 `main`。

**已简化（2026-11-15）**：`release.yml` 收口为单一 `workflow_run` 路径，删除 `workflow_dispatch` 与 `push tags`。**已调整（2026-11-16）**：自动产物改回默认 prerelease（`vX.Y.Z-pre.N`，不占 `releases/latest`），正式版需维护者显式转正。GitHub 流程现为 PR 验证 → main CI → 自动 prerelease →（按需）从该提交另发正式版。
