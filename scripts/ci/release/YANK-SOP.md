# YANK-SOP — 已发布版本紧急下线标准作业程序

适用：已发布到 atomgit（stable/beta/rc 渠道）的 agentrt 版本出现严重缺陷
（数据损坏、安全漏洞、升级链断裂等），需要立即阻断新装/新升级。

发布脚本 SSoT：`publish-release.sh`（本目录）。本 SOP 所有命令均以其真实
行为为依据（manifest 全量重生成、GPG 整文件签名、latest/ push 双端同步）。

## 0. 边界：yank ≠ 修复重发

| 场景 | 动作 | 入口 |
|------|------|------|
| 同 tag 修复重发（内容更新） | `AIRY_FORCE_UPLOAD=1` 重跑发布 | release.yml / 本地 publish-release.sh |
| 版本紧急下线（不再分发） | **本 SOP（yank）** | — |

同 tag 可修复的问题一律走修复重发，不走 yank。yank 是"撤回分发"，不是
"覆盖内容"；已安装用户不受影响（无远程禁用/卸载机制），公告渠道另行通知。

## 1. 三步语义总览

atomgit Release API 的 release 对象不可删除（DELETE 405），故 yank 是
逻辑下线而非物理删除，共三步：

1. **manifest 回退（核心断供面）**：`latest/manifest.<CH>.json` 的
   `latest` 指针回退到上一版本、`releases` 中被 yank 版本条目消失。
   安装器/更新器只按 manifest 的 latest 指针分发——指针回退即断供。
2. **tag 双端删除**：atomgit + GitHub 删除发布 tag，阻断
   `releases/download/<tag>/` 直链与源码包入口。
3. **发布页人工弃用标注**：release 对象不可删，在发布页正文顶部人工加
   **[YANKED]** 标注（直链附件在 tag 删除后仍可能匿名可达，但不再被
   manifest 引用，安装器/更新器不再分发）。

关键机制（决定操作细节）：

- manifest 每次发布**全量重生成**，`releases` 仅含当次版本 → yank 后的
  manifest 必须包含**上一版本的完整条目**（artifacts url/sha256/size），
  否则更新器回退后找不到升级目标。
- GPG 对 manifest **整文件签名** → 任何内容改动必须重签 `.asc`，否则
  客户端验签 fail-closed 全链失败。
- `latest/` 在 agentrt 仓 `.gitignore` 白名单制下天然被忽略，git add 必须
  `-f`。

## 2. 前置条件（本机发布台）

- 上一版本（回退目标，下记 `<PREV>`）的 dist 目录：含全部
  `agentrt-<PREV>-*.tar.gz` + `.sha256` + `.sig`（+ 已签名的
  `manifest.<CH>.json` / `.asc` 若保留）。没有则按 §4 从 release 附件重建。
- `ATOMGIT_TOKEN`（openairymax/agentrt 发布权限）、`GITHUB_REPO` +
  `GITHUB_PAT`（manifest 双端同步）。
- GPG 私钥：`GPG_PRIVATE_KEY`（base64）+ `GPG_PASSPHRASE`；公钥指纹须与
  仓内 `keys/agentrt.fingerprint` 一致（脚本自动硬比对）。
- channel 定位：`<CH>` ∈ stable/beta/rc，对应
  `latest/manifest.<CH>.json`。

## 3. 路径 A（推荐）：重放上一版本发布

复用 `publish-release.sh` 全部幂等保护（附件已存在跳过、.sig 已存在跳过、
dist 内 manifest 已存在跳过重生成——保留既有 GPG 签名一致性），人工动作
最小、最不易错：

```bash
export ATOMGIT_TOKEN=... GPG_PRIVATE_KEY=... GPG_PASSPHRASE=...
export GITHUB_REPO=openairymax/agentrt GITHUB_PAT=...
# 切勿设置 AIRY_FORCE_UPLOAD（yank 不覆盖任何远端附件）
bash tools/scripts/ci/release/publish-release.sh <PREV> <prev-dist-dir>
```

脚本依次：预检 <PREV> 制品 → （.sig 已存在则跳过）cosign → manifest
（dist 内已有 = 上次发布原件，latest 本就是 <PREV>，跳过重生成）→ GPG 签名
（.asc 已存在则跳过）→ 附件上传（全部已存在自动跳过）→ latest/ push
commit `release: update manifest.<CH>.json for <PREV>`（atomgit main 先推，
GitHub main 补推）。该 commit 即回退标记。

注意：dist 内若缺 manifest.<CH>.json（上次发布未保留），脚本会以 <PREV>
制品重生成（`updated_at` 为当前时间，需 `RELEASE_NOTES`/`-notes` 提供
notes），并重签 .asc——内容与上次发布不同但语义等价，验签仍自洽。

## 4. 路径 B：上一版本 dist 不在本地时，从 release 附件重建

```bash
# 1. 取上一版本发布页全部附件（tar.gz/.sha256/.sig/manifest）
curl -fLO https://atomgit.com/openairymax/agentrt/releases/download/<PREV>/agentrt-<PREV>-<plat>.tar.gz
#    …每个平台包 + 对应 .sha256/.sig + manifest.<CH>.json + manifest.<CH>.json.asc
# 2. 完整性自证（附件被篡改则此处暴露）
sha256sum -c agentrt-<PREV>-*.sha256
# 3. 令牌校验既有签名（证明附件即当年发布原件）
gpg --verify manifest.<CH>.json.asc manifest.<CH>.json
# 4. 聚合为 dist 目录后走 §3 路径 A
```

## 5. tag 双端删除

agentrt 仓 remote：`origin` = atomgit（SSoT）、`github` = GitHub 镜像。

```bash
git push origin  --delete "refs/tags/<TAG>"
git push github  --delete "refs/tags/<TAG>"
```

删除前确认无进行中的发布 run（release.yml 同 tag concurrency 单飞，避免
删除后旧 run 复推 tag）。tag 删除**不可逆**。

## 6. 发布页人工弃用标注

atomgit 发布页（`https://atomgit.com/openairymax/agentrt/releases` 对应
tag 页）正文顶部人工追加：

```
**[YANKED YYYY-MM-DD]** 本版本因 <原因> 已下线，请勿使用；
已安装用户请升级至 <PREV>（或更高）。
```

## 7. 验证口径

```bash
# 1. manifest 已回退且被 yank 版本条目消失
curl -fsSL https://atomgit.com/openairymax/agentrt/raw/main/latest/manifest.<CH>.json \
  | python3 -c "import sys,json;m=json.load(sys.stdin);assert m['latest']=='<PREV>',m['latest'];assert '<VER>' not in m['releases'];print('manifest 回退 OK')"
# 2. 签名与新内容匹配（fail-closed 验证）
curl -fsSL https://atomgit.com/openairymax/agentrt/raw/main/latest/manifest.<CH>.json.asc \
  | gpg --verify - <(curl -fsSL https://atomgit.com/openairymax/agentrt/raw/main/latest/manifest.<CH>.json)
# 3. 一键安装拉到的就是 <PREV>
bash <(curl -fsSL https://atomgit.com/openairymax/agentrt/releases/download/<PREV>/install.sh) --help
```

GitHub main 同步验证：manifest commit 双端可见（publish-release.sh 阶段 5
补推 fail-soft，失败时手动 merge 后重推）。

## 8. 红线

1. **`.asc` 必须与 manifest 内容比特级匹配**：GPG 整文件签名，改内容必
   重签；客户端验签 fail-closed，签名失配 = 全渠道安装/升级瘫痪。
2. **yank 期间禁用 `AIRY_FORCE_UPLOAD`**：yank 是撤回分发，不是覆盖内容。
3. **atomgit main 先推（SSoT），GitHub main 随后**：两仓为同一提交图镜像，
   双端分叉时手动 merge 后重推。
4. **tag 删除不可逆**；删除后该 tag 不可复用——后续修复必须换新版本号。
5. yank 不触达已安装用户（无远程禁用机制），用户公告另行发布。
