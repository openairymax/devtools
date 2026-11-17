#!/bin/bash
# AgentRT 提交钩子安装器（0.1.21 L-11 / §16.20.5）
#
# 行为：把 commit-msg 与 commit-rules.sh 复制进目标仓的 hooks 目录，并把
#   gitmessage 设为该仓的 local commit.template。可重复执行：内容一致则不写，
#   已有第三方钩子先备份为 <hook>.bak。<commit-msg>.bak 存在时不再覆盖备份，
#   避免二次安装冲掉最初的原件。
#
# 为何复制而非符号链接：工作树/多仓开发时链接会跨仓指回 tools 检出路径，
#   该路径属工具内部路径（R9），不可写入配置；复制让每个仓自洽。
#
# 用法: install.sh [仓库路径...]     （缺省为当前目录）
# 退出码: 0 = 全部安装成功；1 = 有仓失败；2 = 参数/环境错误
set -uo pipefail
export LC_ALL=C

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_HOOK="${SRC_DIR}/commit-msg"
SRC_RULES="${SRC_DIR}/commit-rules.sh"
SRC_TMPL="${SRC_DIR}/gitmessage"

[ -r "$SRC_HOOK" ] && [ -r "$SRC_RULES" ] && [ -r "$SRC_TMPL" ] || {
    echo "install: 源文件不完整：${SRC_DIR}" >&2
    exit 2
}

# 内容不同才落盘，保证重复执行的幂等与 mtime 稳定。
put() {
    local src="$1" dst="$2"
    if [ -f "$dst" ] && cmp -s "$src" "$dst"; then
        return 0
    fi
    cp -f "$src" "$dst" && chmod 755 "$dst"
}

install_one() {
    local repo="$1" hooks tmpl rc=0
    [ -d "$repo/.git" ] || git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || {
        echo "install: 不是 git 仓库：${repo}" >&2
        return 1
    }
    hooks=$(git -C "$repo" rev-parse --git-path hooks)
    case "$hooks" in /*) ;; *) hooks="${repo}/${hooks}" ;; esac
    mkdir -p "$hooks" || return 1

    if [ -f "${hooks}/commit-msg" ] && ! cmp -s "$SRC_HOOK" "${hooks}/commit-msg" \
        && [ ! -f "${hooks}/commit-msg.bak" ]; then
        cp -f "${hooks}/commit-msg" "${hooks}/commit-msg.bak" || rc=1
    fi

    put "$SRC_RULES" "${hooks}/commit-rules.sh" || rc=1
    put "$SRC_HOOK" "${hooks}/commit-msg" || rc=1
    tmpl="${hooks}/gitmessage"
    put "$SRC_TMPL" "$tmpl" || rc=1
    git -C "$repo" config --local commit.template "$tmpl" || rc=1

    if [ "$rc" -eq 0 ]; then
        echo "install: ${repo} 已就绪（hooks=${hooks}）"
    else
        echo "install: ${repo} 安装失败" >&2
    fi
    return "$rc"
}

[ "$#" -gt 0 ] || set -- .
rc=0
for repo in "$@"; do
    install_one "$repo" || rc=1
done
exit "$rc"
