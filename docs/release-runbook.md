# 发布手册与 GitHub API 5xx 降级路径

> 完整流程规范见 [github-workflow.md](github-workflow.md)：分支模型、单通道发版、tag 与 release 命名、更新器契约、治理校验。本文只记发版操作与降级路径。

## 正常流程

**预览在本地，正式版在 CI（2026-11-25 起）**。自动发版工作流 `release.yml` 已删除：合并 `main` 不触发 CI 或构建，预览由 `tools/local-build/local-release.sh` 构建、签名并上传；只有正式版才运行 GitHub Actions（`Stable release` → `ci.yml` 门禁 → stable 构建）。

### 预览（默认通道）

1. （开新版本线时）在 `nb4a.properties` 递增 `VERSION_NAME` / `VERSION_CODE`，在 `CHANGELOG.md` 顶部补对应版本段落（`buildScript/release_notes.sh` 会从这里取正文，缺失会在发布前失败）。同一版本线内连续发预览由脚本自动递增 `N`，无需 bump。
2. 合并到 `main`（PR CI 全绿后）。合并本身不产生 release。
3. 本地构建并上传：

   ```bash
   source tools/local-build/local-env.sh
   bash tools/local-build/local-inputs.sh      # 首次或输入缺失时
   bash tools/local-build/local-release.sh --publish
   ```

   脚本以 `channel=preview` / `build-number=N` 构建（签名密钥见 `docs/local-build.md`），`N` 从 GitHub 已有预览 tag 自动递增（读取失败即中止），且要求提交已在 `main` 上。
4. `buildScript/publish_release.sh` 创建/复用 prerelease（每次写操作重试 3 次、间隔 15s，带 `--prerelease`），**不**标记 `--latest`。
5. 核对：`gh release view <tag> --json tagName,name,isPrerelease,isDraft,targetCommitish,assets`。必须是 prerelease、名称等于 tag、4 个 preview 资产（3 个 ABI APK + `SHA256SUMS`，**无** `throne-update.json`），且 `releases/latest` 仍指向上一个正式版。

### 正式版（显式转正）

不能把 `-pre.N` 的 release 改旗标转正——`github_governance.py` 会判 `release:preview-flag` / `release:preview-manifest` 违规，且 `-pre.N` 的 `versionCode` 低于同版本正式版，更新器会认它更旧。**在 `main` 上运行 Actions 的 `Stable release`**（`workflow_dispatch`，`version` = `VERSION_NAME`；没有提交输入，构建的就是派发提交）：它先通过 `workflow_call` 调 `ci.yml` 在**同一提交**上跑完整门禁，再以 `channel=stable` / `build-number=999` 重新构建并签名，跑 `release_assets.py ... stable`，发布 `vX.Y.Z` 并标记 `--latest`。本地手工步骤仅在工作流失败时使用：以该预览的提交为 `target_commitish` 新建 `vX.Y.Z` 正式 release，资产用 `python3 buildScript/release_assets.py <apk-dir> dist stable`（3 个 ABI APK + `SHA256SUMS` + `throne-update.json`），标题 `vX.Y.Z`，显式 `--latest`。`nb4a.properties` 的 `VERSION_NAME` 与 `CHANGELOG.md` 顶部段落必须同为 `X.Y.Z`。

CI 发布失败时会保留 `Flrone-<tag>-publish-failed` 兜底 artifact（签名 APK 不丢），按下方本地补发路径收口。

## 当 runner 侧 GitHub API 返回 502 / 500

2026-11-04 的 v3.2.17 连续两次在 `gh release create` 因 runner 侧 502、500 失败，而构建、签名、`release_assets.py` 全部成功；同一时刻从本地调用 `api.github.com` 却正常。因此：

- 工作流现在会给失败的发布加上 `Flrone-<tag>-publish-failed` artifact，**签名 APK 不会丢**；
- 发布脚本会保留失败状态（CI 标红），不要误以为"重跑就好"——按下面的本地补发路径收口。

### 本地补发步骤

```bash
REPO=yuedaochangmendian/throne-flclash-ui
TAG=v3.2.18
SHA=<目标提交 sha>

# 1. 取回发布失败时保留的已签名产物
gh run download <发布失败的 run id> \
    -n "Flrone-$TAG-publish-failed" -D dist/
ls -l dist/                                      # 应含 3 个 APK、SHA256SUMS、throne-update.json

# 2. 若发行版不存在，先创建草稿（本地 API 通道通常可用）
notes=$(bash buildScript/release_notes.sh "${TAG#v}")
jq -n --arg tag "$TAG" --arg sha "$SHA" --arg body "$notes" \
  '{tag_name:$tag, target_commitish:$sha, name:$tag, body:$body, draft:true, prerelease:false}' \
  | gh api -X POST "repos/$REPO/releases" --input - | tee release.json
REL_ID=$(jq -r .id release.json)

# 3. 上传资产（uploads.github.com，与 api.github.com 是不同端点）
for f in dist/*; do
  curl -fsS -X POST \
    -H "Authorization: Bearer $(gh auth token)" \
    -H "Accept: application/vnd.github+json" \
    -H "Content-Type: application/octet-stream" \
    --data-binary @"$f" \
    "https://uploads.github.com/repos/$REPO/releases/$REL_ID/assets?name=$(basename "$f")" \
    > /dev/null && echo "uploaded $(basename "$f")"
done

# 4. 发布并核对
echo '{"draft":false}' | gh api -X PATCH "repos/$REPO/releases/$REL_ID" --input - > /dev/null
gh release view "$TAG" --json tagName,isDraft,targetCommitish,assets
```

### 两个坑

- **草稿是 untagged 形态**：`GET /releases/tags/<tag>` 对草稿返回 404，但草稿确实存在。始终按 release **id** 查询（`GET /releases/<id>`），不要因为 404 就重复创建。
- **发布前确认 `target_commitish`**：草稿创建时必须写目标提交 sha；否则 tag 可能落到默认分支的旧提交。发布后用 `gh api repos/$REPO/git/ref/tags/$TAG` 复核。

### 可选的清理

若补发时已有同名草稿（如本地创建过但没上传资产），优先复用它（`gh release upload <tag> dist/* --clobber` + `gh release edit <tag> --draft=false`），或先 `gh release delete <tag> --yes` 再走上面的流程。
