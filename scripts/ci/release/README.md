# release/ — 发布管理

`tools/scripts/ci/release/`

## 概述

AgentRT 版本发布子模块：覆盖「质量门禁 → 打 tag → 完全体打包 → 双轨签名 →
manifest 生成 → atomgit Release 上传 → latest/ 固定入口更新」的完整发布链路。
官方制品仓库：`atomgit.com/openairymax/agentrt`（GitHub Release 为镜像）。

## 目录结构

```
release/
├── release.sh                 # 一键发布：质量门禁（构建/测试/安全/文档/CHANGELOG/SBOM/Cosign）
│                              #   → 打 tag v<版本> → 推送触发 CI
├── package-full-release.sh    # 完全体二进制包：质量门禁 → 闭源模块预编译（atoms/memoryrovol）
│                              #   → 完全体打包（daemons+CLI+TUI+Python+config）→ 上传
├── publish-release.sh         # 发布执行：cosign 签名每个制品 → manifest.<channel>.json
│                              #   → GPG 签名 manifest → atomgit 上传 → latest/ 更新
├── init-signing-keys.sh       # 双轨签名密钥初始化（GPG 主私钥 + cosign 密钥对）
├── cleanup_builds.sh          # 源码树构建产物清理（CMake/__pycache__/编译产物）
└── keys/                      # 内置公钥（发布端基线）
    ├── agentrt.asc            #   GPG 公钥（ARMORED）
    ├── agentrt.fingerprint    #   GPG 指纹基线（签名前硬比对，防私钥张冠李戴）
    └── cosign.pub             #   cosign 公钥
```

## 发布链路（双轨签名，防供应链攻击）

```
质量门禁（release.sh）
   │
   ▼
完全体打包（package-full-release.sh）→ dist/agentrt-<v版本>-<os>-<arch>.tar.gz + *.sha256
   │
   ▼
发布执行（publish-release.sh）：
   ├── 1. cosign sign-blob 每个制品      → <file>.sig（随制品发布）
   ├── 2. 生成 manifest.<channel>.json   → 制品 url/sha256/size + latest + notes
   ├── 3. GPG 签名 manifest              → manifest.<channel>.json.asc（权威校验链）
   ├── 4. atomgit Release 上传           → 制品 + *.sig + manifest + manifest.asc
   └── 5. latest/ 更新                   → manifest + keys 推送到仓库 latest/ 分支入口
                                          （更新器轮询固定 URL）
```

**通道语义**：`*-rc.*` → `rc`（manifest.rc.json）；`*-beta.*` → `beta`；
其余 → `stable`。rc 独立通道，不与 beta 混淆。

## 使用

```bash
# 1. 初始化签名密钥（一次性；产物含 GPG 私钥 + cosign 私钥，须安全保管）
tools/scripts/ci/release/init-signing-keys.sh "$HOME/.airymaxrt/signing"

# 2. 一键发布（门禁 + 打 tag v0.1.5，推送后 CI 自动构建发布）
tools/scripts/ci/release/release.sh 0.1.5 stable

# 3. 完全体打包（版本默认读 agent-workload/agentrt/VERSION，SSoT）
tools/scripts/ci/release/package-full-release.sh v0.1.5 linux-x86_64

# 4. 发布执行（CI release 阶段自动调用；本地可 DRY_RUN / SKIP_UPLOAD 演练）
DRY_RUN=1 SKIP_UPLOAD=1 \
  tools/scripts/ci/release/publish-release.sh v0.1.5 "$HOME/.airymaxrt/dist"
```

### publish-release.sh 环境变量

| 变量 | 说明 |
|------|------|
| `COSIGN_PRIVATE_KEY` / `COSIGN_PASSWORD` | cosign 私钥（base64 或文件路径）+ 口令 |
| `GPG_PRIVATE_KEY` / `GPG_PASSPHRASE` | GPG 私钥（base64）+ 口令 |
| `ATOMGIT_TOKEN` / `ATOMGIT_REPO` | atomgit 令牌 + 目标仓（默认 openairymax/agentrt） |
| `RELEASE_NOTES` / `RELEASE_NOTES_FILE` | 变更日志摘要 |
| `SKIP_SIGN=1` / `SKIP_UPLOAD=1` / `DRY_RUN=1` | 跳过签名/上传/模拟 |
| `SKIP_LATEST=1` | 跳过 latest/ 固定入口更新 |

## 安全设计

- **fail-closed**：签名缺失/验签失败 → 拒绝发布；指纹硬比对防私钥张冠李戴。
- **客户端同步**：`latest/keys/` 随每次发布刷新，安装器/自更新器在线拉取公钥，
  支持密钥轮换；内嵌公钥仅作离线兜底。
- **BAN-33**：打包产物默认输出 `~/.airymaxrt/dist/`（源码区外）。

---

© 2025-2026 SPHARX Ltd. All Rights Reserved.
