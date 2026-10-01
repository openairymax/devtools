#!/bin/bash
# ============================================================================
# ALK 内核上游同步脚本
#
# 整体分支策略（基于"只增加、不修改 Linux 主线"原则）：
#
#   linux-stable/linux-6.6.y  ── T1: ff-only ──→  ALK-6.6-upstream
#                                                         │
#                                                   T2: merge
#                                                         │
#                                                         ↓
#                                                    ALK-6.6
#
# 约束：
#   - ALK-6.6-upstream：绝对纯净基线，禁止任何本地提交
#   - ALK-6.6：仅新增文件（airy/、include/uapi/linux/airymax/ 等），
#     不改动 Linux 主线已有文件，因此 merge 冲突概率趋近于零
#
# 使用方法：
#   bash sync-upstream.sh              # 交互模式
#   bash sync-upstream.sh --auto       # 自动模式
#   bash sync-upstream.sh --cron       # cron 静默模式
#   bash sync-upstream.sh --t1-only    # 仅 T1
# ============================================================================

set -euo pipefail

# ── 配置 ──────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# 仓库重组（2026-08）：agentrt-linux → agent-linux
REPO_ROOT="$SCRIPT_DIR/../airymaxhub/agent-linux/kernel"
LOG_DIR="$SCRIPT_DIR/logs"

# ── 确保日志目录存在 ────────────────────────────────────────────────────────
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/sync-upstream.log"

UPSTREAM_REMOTE="linux-stable"
UPSTREAM_BRANCH="linux-6.6.y"

BRANCH_UPSTREAM="ALK-6.6-upstream"   # 纯净上游镜像，禁止本地提交
BRANCH_MAIN="ALK-6.6"                # 核心主干，仅新增文件
BRANCH_DEV="ALK-6.6-dev"             # 日常开发分支
ORIGIN="origin"

# ALK 代码独占目录（与 Linux 主线零交集）
ALK_DIRS=(
    "airy"
    "include/uapi/linux/airymax"
    "Documentation/airy"
    "tools/airy"
)

# 可能会被 ALK 和上游同时修改的文件（需要人工审查）
CONFLICT_PRONE_FILES=(
    "MAINTAINERS"
    "Makefile"
    "Kconfig"
    "Kbuild"
)

# 网络重试配置
FETCH_RETRIES=3
FETCH_TIMEOUT=300
FETCH_DELAY=30

# 心跳配置（秒）
HEARTBEAT_INTERVAL=60

# ── 日志（彩色输出）──────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
    C_RESET="\033[0m"
    C_DATE="\033[90m"     # 灰色 - 时间戳
    C_INFO="\033[36m"     # 青色 - INFO
    C_WARN="\033[33m"     # 黄色 - WARN
    C_ERROR="\033[31m"    # 红色 - ERROR
    C_DEBUG="\033[90m"    # 灰色 - DEBUG
    C_OK="\033[32m"       # 绿色 - OK
    C_STEP="\033[1;34m"   # 蓝色粗体 - STEP
else
    C_RESET="" C_DATE="" C_INFO="" C_WARN="" C_ERROR="" C_DEBUG="" C_OK="" C_STEP=""
fi

log()       { echo -e "${C_DATE}[$(date '+%Y-%m-%d %H:%M:%S')][$$]${C_RESET} $1"; }
log_info()  { log "${C_INFO}INFO:${C_RESET}  $1"; }
log_warn()  { log "${C_WARN}WARN:${C_RESET}  $1"; }
log_error() { log "${C_ERROR}ERROR:${C_RESET} $1"; }
log_debug() { log "${C_DEBUG}DEBUG:${C_RESET} $1"; }
log_ok()    { log "${C_OK}OK:${C_RESET}     $1"; }
log_step() {
    local label="$1"
    echo ""
    log_info ">>> 进入阶段: $label <<<"
    echo -e "${C_STEP}═══════════════════════════════════════════════════════════════${C_RESET}"
    echo -e "${C_STEP}  $label${C_RESET}"
    echo -e "${C_STEP}═══════════════════════════════════════════════════════════════${C_RESET}"
}
log_end_step() {
    local label="$1" rc="${2:-0}"
    log_info "<<< 退出阶段: $label (rc=$rc) <<<"
}

# ── 心跳守护进程 ──────────────────────────────────────────────────────────────
start_heartbeat() {
    local operation="$1"
    local start_time=$(date +%s)
    local pid_file="/tmp/alk-sync-heartbeat.pid"
    
    (
        trap "exit 0" INT TERM
        while true; do
            local elapsed=$(( $(date +%s) - start_time ))
            local mins=$(( elapsed / 60 ))
            local secs=$(( elapsed % 60 ))
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] INFO:  ❤️  $operation 进行中... (已运行 ${mins}m${secs}s)"
            sleep "$HEARTBEAT_INTERVAL"
        done
    ) >&2 &
    
    local hb_pid=$!
    echo "$hb_pid" > "$pid_file"
    echo "$hb_pid"
}

stop_heartbeat() {
    local pid="$1"
    local pid_file="/tmp/alk-sync-heartbeat.pid"
    
    if [[ -n "$pid" ]]; then
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    fi
    
    rm -f "$pid_file"
}

# ── 网络优化与重试 ──────────────────────────────────────────────────────────────
fetch_with_retry() {
    local remote="$1"
    local branch="${2:-}"
    local retries="$FETCH_RETRIES"
    local delay="$FETCH_DELAY"
    local attempt=1

    local remote_url
    remote_url=$(git remote get-url "$remote" 2>/dev/null || echo "unknown")
    log_debug "fetch_with_retry: remote=$remote url=$remote_url branch=${branch:-'(all)'}"

    while [[ $attempt -le $retries ]]; do
        log_info "Fetch attempt $attempt/$retries: $remote ${branch:+$branch}"
        
        local heartbeat_pid
        heartbeat_pid=$(start_heartbeat "Fetch $remote")
        
        if [[ -n "$branch" ]]; then
            git -c http.postBuffer=524288000 \
                   -c http.lowSpeedLimit=1000 \
                   -c http.lowSpeedTime=$FETCH_TIMEOUT \
                   fetch "$remote" "$branch" --quiet 2>&1
        else
            git -c http.postBuffer=524288000 \
                   -c http.lowSpeedLimit=1000 \
                   -c http.lowSpeedTime=$FETCH_TIMEOUT \
                   fetch "$remote" --quiet 2>&1
        fi
        
        local rc=$?
        stop_heartbeat "$heartbeat_pid"
        
        if [[ $rc -eq 0 ]]; then
            log_ok "Fetch 成功"
            return 0
        fi
        
        log_warn "Fetch attempt $attempt failed (exit code $rc)"
        
        if [[ $attempt -lt $retries ]]; then
            log_info "等待 $delay 秒后重试..."
            sleep "$delay"
            attempt=$((attempt + 1))
        else
            log_error "Fetch 失败，已重试 $retries 次"
            return $rc
        fi
    done
    
    return 1
}

# 验证 REPO_ROOT 目录存在
if [[ ! -d "$REPO_ROOT" ]]; then
    echo "错误: 仓库目录不存在: $REPO_ROOT"
    exit 1
fi

cd "$REPO_ROOT" || {
    echo "错误: 无法切换到仓库目录: $REPO_ROOT"
    exit 1
}

# ============================================================================
# 0. 前置检查
# ============================================================================
check_prerequisites() {
    log_info "检查前置条件..."

    if [[ ! -d "$REPO_ROOT" ]]; then
        log_error "仓库目录不存在: $REPO_ROOT"
        exit 1
    fi

    if ! git -C "$REPO_ROOT" rev-parse --git-dir > /dev/null 2>&1; then
        log_error "不在 git 仓库中: $REPO_ROOT"
        exit 1
    fi

    if ! git remote get-url "$UPSTREAM_REMOTE" > /dev/null 2>&1; then
        log_error "远程 '$UPSTREAM_REMOTE' 不存在。请执行："
        log_error "  git remote add $UPSTREAM_REMOTE https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux-stable.git"
        exit 1
    fi

    for branch in "$BRANCH_UPSTREAM" "$BRANCH_MAIN"; do
        if ! git show-ref --verify --quiet "refs/heads/$branch"; then
            log_error "本地分支 '$branch' 不存在"
            exit 1
        fi
    done

    if [[ -n "$(git status --porcelain)" ]]; then
        log_error "工作区不干净："
        git status --short
        exit 1
    fi

    log_ok "前置检查通过"
}

# ============================================================================
# 0-1. 安全验证：ALK-6.6-upstream 必须是纯净基线
# ============================================================================
verify_upstream_purity() {
    log_info "验证 $BRANCH_UPSTREAM 纯净性..."

    local upstream_head local_head
    local_head=$(git rev-parse "$BRANCH_UPSTREAM")

    # 抓取上游，确保有最新引用
    if ! fetch_with_retry "$UPSTREAM_REMOTE" "$UPSTREAM_BRANCH"; then
        log_warn "无法获取上游 $UPSTREAM_BRANCH 的引用，跳过纯净性验证"
        return 0
    fi
    upstream_head=$(git rev-parse "$UPSTREAM_REMOTE/$UPSTREAM_BRANCH" 2>/dev/null || echo "")

    if [[ -z "$upstream_head" ]]; then
        log_warn "无法获取上游 $UPSTREAM_BRANCH 的引用，跳过纯净性验证"
        return 0
    fi

    # 检查 ALK-6.6-upstream 是否包含上游不存在的内容
    # 如果 local_head 不是 merge-base，说明 local 有不在上游的提交
    # 纯净情况：local 是 upstream 的祖先 → base == local_head
    # 污染情况：local 有自有提交 → base != local_head（base 在 local 前面）
    local base
    base=$(git merge-base "$local_head" "$upstream_head" 2>/dev/null || echo "")

    if [[ -n "$base" && "$base" != "$local_head" ]]; then
        # ALK-6.6-upstream 有不在上游的提交！
        log_error "=========================================="
        log_error "  $BRANCH_UPSTREAM 不是纯净基线！"
        log_error "  发现不在上游的本地提交："
        log_error "=========================================="
        git log --oneline "$upstream_head..$local_head"
        log_error "=========================================="
        log_error "  请人工处理后再运行本脚本。"
        log_error "  $BRANCH_UPSTREAM 禁止任何本地提交。"
        exit 1
    fi

    log_ok "$BRANCH_UPSTREAM 纯净性验证通过"
}

# ============================================================================
# 0-2. 显示分区——哪些文件会被上游改动、哪些是 ALK 独有的
# ============================================================================
show_partition_summary() {
    local src="$1" dst="$2"

    local dst_commit src_commit
    dst_commit=$(git rev-parse "$dst")
    src_commit=$(git rev-parse "$src")

    if [[ "$dst_commit" == "$src_commit" ]]; then
        return
    fi

    # 构建 ALK 目录的 grep 模式（用于排除上游改动）
    local alk_exclude_pattern=""
    local alk_check_pattern=""
    for dir in "${ALK_DIRS[@]}"; do
        if [[ -n "$alk_exclude_pattern" ]]; then
            alk_exclude_pattern="${alk_exclude_pattern}|"
            alk_check_pattern="${alk_check_pattern}|"
        fi
        alk_exclude_pattern="${alk_exclude_pattern}${dir}/"
        alk_check_pattern="${alk_check_pattern}${dir}/"
    done

    # 构建冲突倾向文件的 grep 模式
    local conflict_pattern=""
    for f in "${CONFLICT_PRONE_FILES[@]}"; do
        if [[ -n "$conflict_pattern" ]]; then
            conflict_pattern="${conflict_pattern}|"
        fi
        conflict_pattern="${conflict_pattern}${f}"
    done

    # 上游改动的文件（排除 ALK 目录）
    echo "  上游改动文件（Linux 主线区域）："
    local upstream_files
    upstream_files=$(git diff --name-only "$dst_commit" "$src_commit" \
        | grep -vE "^(${alk_exclude_pattern})" \
        || true)

    if [[ -n "$upstream_files" ]]; then
        local count
        count=$(echo "$upstream_files" | wc -l)
        echo "$upstream_files" | head -20
        if [[ $count -gt 20 ]]; then
            echo "  ... (共 $count 个文件)"
        fi
    else
        echo "  (无)"
    fi
    echo ""

    # ALK 目录下是否有变更（不应有，但做个检查）
    local alk_changes
    alk_changes=$(git diff --name-only "$dst_commit" "$src_commit" \
        | grep -E "^(${alk_check_pattern})" \
        || true)
    if [[ -n "$alk_changes" ]]; then
        log_warn "上游包含了 ALK 目录的变更（异常情况）"
        echo "$alk_changes" | head -10
        echo ""
    fi

    # 冲突倾向文件检查
    local conflict_files
    conflict_files=$(git diff --name-only "$dst_commit" "$src_commit" \
        | grep -E "^(${conflict_pattern})$" \
        || true)
    if [[ -n "$conflict_files" ]]; then
        echo "  ⚠ 关注：上游改动了可能与 ALK 冲突的文件："
        echo "$conflict_files"
    fi
}

# ============================================================================
# 通用：比较两个 ref，返回值
#   0 = dst 是 src 的祖先（可以 ff）
#   1 = 相同（无差异）
#   2 = 已分叉
# ============================================================================
compare_refs() {
    local src="$1" dst="$2"

    local sc dc
    sc=$(git rev-parse "$src")
    dc=$(git rev-parse "$dst")

    log_debug "compare_refs: src=$src($sc) dst=$dst($dc)"

    if [[ "$sc" == "$dc" ]]; then
        log_debug "compare_refs: 返回 1 (相同)"
        return 1   # 相同
    fi

    local base
    base=$(git merge-base "$sc" "$dc" 2>/dev/null || echo "")

    if [[ "$base" == "$dc" ]]; then
        log_debug "compare_refs: 返回 0 (dst 是 src 祖先，可 ff)"
        return 0   # dst 是 src 的祖先，可 ff
    fi

    log_debug "compare_refs: 返回 2 (已分叉) base=$base"
    return 2       # 已分叉
}

# ============================================================================
# 通用：显示提交摘要
# ============================================================================
show_commit_summary() {
    local from="$1" to="$2" label_from="$3" label_to="$4"

    local fc tc
    fc=$(git rev-parse "$from")
    tc=$(git rev-parse "$to")
    local count
    count=$(git rev-list --count "$tc..$fc")

    echo "  $label_to: $(git log --oneline -1 "$tc")"
    echo "  $label_from: $(git log --oneline -1 "$fc")"
    echo "  差距: $count 个提交"
    echo ""

    if [[ $count -gt 0 ]]; then
        echo "  新增提交："
        git log --oneline "$tc..$fc" | head -10
        if [[ $count -gt 10 ]]; then
            echo "  ... (共 $count 个，仅显示前 10)"
        fi
    fi
}

# ============================================================================
# T1: ALK-6.6-upstream ← linux-stable/linux-6.6.y
#     强制执行 fast-forward only，绝对纯净
# ============================================================================
do_t1() {
    local src_ref="$UPSTREAM_REMOTE/$UPSTREAM_BRANCH"
    local dst="$BRANCH_UPSTREAM"

    log_step "T1: $dst ← $UPSTREAM_BRANCH"

    compare_refs "$src_ref" "$dst" || local cmp_rc=$?
    cmp_rc=${cmp_rc:-0}
    log_debug "T1: cmp_rc=$cmp_rc (0=可ff, 1=相同, 2=分叉)"

    case $cmp_rc in
        1)
            log_info "$dst 已是最新，无需同步"
            echo "  当前: $(git log --oneline -1 "$dst")"
            log_end_step "T1" 1
            return 1
            ;;
        2)
            log_error "=========================================="
            log_error "  FATAL: $dst 与上游已分叉！"
            log_error "  该分支不能有非上游的本地提交。"
            log_error "=========================================="
            git log --oneline "$src_ref..$dst" 2>/dev/null || true
            exit 1
            ;;
    esac

    show_commit_summary "$src_ref" "$dst" "$UPSTREAM_BRANCH" "$dst"
    show_partition_summary "$src_ref" "$dst"

    if ! $AUTO_MODE; then
        read -r -p "执行 T1 fast-forward 同步？(y/N) " confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            log_info "跳过 T1"
            log_end_step "T1" 2
            return 2
        fi
    fi

    log_info "切换到 $dst ..."
    git checkout "$dst"
    log_debug "T1: checkout $dst 成功"

    log_debug "T1: 执行 git merge --ff-only $src_ref"
    git merge --ff-only "$src_ref"
    log_debug "T1: merge --ff-only 成功"

    # 推送前同步远程更新
    local ahead behind
    ahead_behind=$(git rev-list --left-right --count "$ORIGIN/$dst"..."$dst" 2>/dev/null || echo "0 0")
    behind=$(echo "$ahead_behind" | awk '{print $1}')
    ahead=$(echo "$ahead_behind" | awk '{print $2}')
    log_debug "T1: 远程比较 ahead=$ahead behind=$behind (local $dst ↔ origin/$dst)"

    if [[ "$ahead" -gt 0 ]] || [[ "$behind" -gt 0 ]]; then
        log_info "推送前同步远程更新 (local ahead=$ahead, behind=$behind)..."
        local pull_hb_pid
        pull_hb_pid=$(start_heartbeat "Pull $dst")
        git pull "$ORIGIN" "$dst" 2>/dev/null || {
            stop_heartbeat "$pull_hb_pid"
            log_warn "Pull 失败，尝试强制同步..."
            log_debug "T1: git pull $ORIGIN $dst 失败，回退到 fetch+merge"
            git fetch "$ORIGIN" "$dst"
            git merge "$ORIGIN/$dst" --no-edit 2>/dev/null || {
                log_error "无法同步远程更新，请手动处理"
                log_debug "T1: fetch+merge $ORIGIN/$dst 也失败"
                exit 1
            }
            log_debug "T1: fetch+merge 回退成功"
        }
        stop_heartbeat "$pull_hb_pid"
    else
        log_debug "T1: 本地与远程一致，无需 pull 同步"
    fi

    local origin_url
    origin_url=$(git remote get-url "$ORIGIN" 2>/dev/null || echo "unknown")
    log_debug "T1: 执行 git push $ORIGIN $dst (→ $origin_url)"
    local push_hb_pid
    push_hb_pid=$(start_heartbeat "Push $dst")
    git push "$ORIGIN" "$dst"
    stop_heartbeat "$push_hb_pid"
    log_debug "T1: push 成功"

    echo ""
    log_ok "T1 完成: $dst → $(git log --oneline -1 HEAD)"
    log_end_step "T1" 0
    return 0
}

# ============================================================================
# T2: ALK-6.6 ← ALK-6.6-upstream
#     ALK 仅新增文件，不改主线 → merge 几乎零冲突
#     如果有冲突，一定是 CONFLICT_PRONE_FILES 导致的
# ============================================================================
do_t2() {
    local src="$BRANCH_UPSTREAM"
    local dst="$BRANCH_MAIN"

    log_step "T2: $dst ← $src"

    compare_refs "$src" "$dst" || local cmp_rc=$?
    cmp_rc=${cmp_rc:-0}
    log_debug "T2: cmp_rc=$cmp_rc (0=可ff, 1=相同, 2=分叉)"

    case $cmp_rc in
        1)
            log_info "$dst 已是最新，无需同步"
            log_end_step "T2" 1
            return 1
            ;;
    esac

    show_commit_summary "$src" "$dst" "$src" "$dst"

    # 如果 ALK-6.6 有自有提交，显示之
    if [[ $cmp_rc -eq 2 ]]; then
        local sc dc
        sc=$(git rev-parse "$src")
        dc=$(git rev-parse "$dst")
        local own_count
        own_count=$(git rev-list --count "$sc..$dc")
        echo "  $dst 自有提交 ($own_count 个)："
        git log --oneline "$sc..$dc" | head -5
        if [[ $own_count -gt 5 ]]; then
            echo "  ... (共 $own_count 个)"
        fi
        echo ""
    fi

    # 预检可能冲突的文件
    if [[ $cmp_rc -eq 2 ]]; then
        log_info "预检冲突文件..."
        log_debug "T2: 执行 git merge-tree --write-tree $dst $src"
        local conflict_check
        # 使用新语法：git merge-tree --write-tree <branch1> <branch2>
        conflict_check=$(git merge-tree --write-tree "$dst" "$src" 2>/dev/null || true)
        local has_conflict
        has_conflict=$(echo "$conflict_check" | grep -c "<<<<<<<" 2>/dev/null || echo "0")
        has_conflict=$(echo "$has_conflict" | tr -d '\n')
        log_debug "T2: merge-tree 预检结果 has_conflict=$has_conflict"
        if [[ "$has_conflict" -gt 0 ]]; then
            log_warn "预检发现 $has_conflict 个文件可能冲突："
            echo ""
            # 显示冲突的文件名
            echo "$conflict_check" | grep -B1 "<<<<<<<" | grep -v "^--$" | head -20
            echo ""
            log_warn "这些通常是 MAINTAINERS / Makefile / Kconfig 等顶层文件"
            log_warn "需要人工介入确认"
            if ! $AUTO_MODE; then
                read -r -p "继续尝试 merge？(y/N) " confirm
                if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
                    log_info "跳过 T2"
                    log_end_step "T2" 2
                    return 2
                fi
            else
                log_info "自动模式下继续尝试..."
            fi
        else
            log_ok "预检通过，零冲突"
        fi
    fi

    if ! $AUTO_MODE && [[ $cmp_rc -ne 2 ]]; then
        read -r -p "执行 T2 同步？(y/N) " confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            log_info "跳过 T2"
            log_end_step "T2" 2
            return 2
        fi
    fi

    log_info "切换到 $dst ..."
    git checkout "$dst"
    log_debug "T2: checkout $dst 成功"

    if [[ $cmp_rc -eq 0 ]]; then
        # ALK-6.6 无自有提交，可以 ff
        log_info "无 ALK 自有提交，fast-forward 合并..."
        log_debug "T2: 执行 git merge --ff-only $src"
        git merge --ff-only "$src"
        log_debug "T2: merge --ff-only 成功"
    else
        # ALK-6.6 有自有提交，执行 merge
        log_info "有 ALK 自有提交，执行 merge..."
        log_debug "T2: 执行 git merge --no-edit $src"
        if git merge --no-edit "$src"; then
            log_ok "Merge 成功"
            log_debug "T2: merge --no-edit 成功"
        else
            local conflict_files
            conflict_files=$(git diff --name-only --diff-filter=U)
            local conflict_count
            conflict_count=$(echo "$conflict_files" | grep -c . 2>/dev/null || echo "0")
            log_error "Merge 冲突！共 $conflict_count 个文件需要人工处理："
            echo "$conflict_files"
            log_error ""
            log_error "冲突原因通常是 ALK 和上游同时修改了以下文件之一："
            for f in "${CONFLICT_PRONE_FILES[@]}"; do
                if echo "$conflict_files" | grep -q "$f"; then
                    log_error "  → $f"
                fi
            done
            log_error ""
            log_error "解决步骤："
            log_error "  1. 编辑冲突文件"
            log_error "  2. git add <conflicted_files>"
            log_error "  3. git commit"
            log_error "  4. git push origin $dst"
            exit 1
        fi
    fi

    # 推送前同步远程更新
    local ahead behind
    ahead_behind=$(git rev-list --left-right --count "$ORIGIN/$dst"..."$dst" 2>/dev/null || echo "0 0")
    behind=$(echo "$ahead_behind" | awk '{print $1}')
    ahead=$(echo "$ahead_behind" | awk '{print $2}')
    log_debug "T2: 远程比较 ahead=$ahead behind=$behind (local $dst ↔ origin/$dst)"

    if [[ "$ahead" -gt 0 ]] || [[ "$behind" -gt 0 ]]; then
        log_info "推送前同步远程更新 (local ahead=$ahead, behind=$behind)..."
        local pull_hb_pid
        pull_hb_pid=$(start_heartbeat "Pull $dst")
        git pull "$ORIGIN" "$dst" 2>/dev/null || {
            stop_heartbeat "$pull_hb_pid"
            log_warn "Pull 失败，尝试强制同步..."
            log_debug "T2: git pull $ORIGIN $dst 失败，回退到 fetch+merge"
            git fetch "$ORIGIN" "$dst"
            git merge "$ORIGIN/$dst" --no-edit 2>/dev/null || {
                log_error "无法同步远程更新，请手动处理"
                log_debug "T2: fetch+merge $ORIGIN/$dst 也失败"
                exit 1
            }
            log_debug "T2: fetch+merge 回退成功"
        }
        stop_heartbeat "$pull_hb_pid"
    else
        log_debug "T2: 本地与远程一致，无需 pull 同步"
    fi

    local origin_url
    origin_url=$(git remote get-url "$ORIGIN" 2>/dev/null || echo "unknown")
    log_debug "T2: 执行 git push $ORIGIN $dst (→ $origin_url)"
    local push_hb_pid
    push_hb_pid=$(start_heartbeat "Push $dst")
    git push "$ORIGIN" "$dst"
    stop_heartbeat "$push_hb_pid"
    log_debug "T2: push 成功"

    echo ""
    log_ok "T2 完成: $dst → $(git log --oneline -1 HEAD)"
    log_end_step "T2" 0
    return 0
}

# ============================================================================
# T3: ALK-6.6-dev ← ALK-6.6
#     日常开发分支，merge 自 ALK-6.6，保持最新上游更新
# ============================================================================
do_t3() {
    local src="$BRANCH_MAIN"
    local dst="$BRANCH_DEV"

    log_step "T3: $dst ← $src"

    compare_refs "$src" "$dst" || local cmp_rc=$?
    cmp_rc=${cmp_rc:-0}
    log_debug "T3: cmp_rc=$cmp_rc (0=可ff, 1=相同, 2=分叉)"

    case $cmp_rc in
        1)
            log_info "$dst 已是最新，无需同步"
            log_end_step "T3" 1
            return 1
            ;;
    esac

    show_commit_summary "$src" "$dst" "$src" "$dst"

    if [[ $cmp_rc -eq 2 ]]; then
        local sc dc
        sc=$(git rev-parse "$src")
        dc=$(git rev-parse "$dst")
        local own_count
        own_count=$(git rev-list --count "$sc..$dc")
        echo "  $dst 自有提交 ($own_count 个)："
        git log --oneline "$sc..$dc" | head -5
        if [[ $own_count -gt 5 ]]; then
            echo "  ... (共 $own_count 个)"
        fi
        echo ""
    fi

    if [[ $cmp_rc -eq 2 ]]; then
        log_info "预检冲突文件..."
        log_debug "T3: 执行 git merge-tree --write-tree $dst $src"
        local conflict_check
        # 使用新语法：git merge-tree --write-tree <branch1> <branch2>
        conflict_check=$(git merge-tree --write-tree "$dst" "$src" 2>/dev/null || true)
        local has_conflict
        has_conflict=$(echo "$conflict_check" | grep -c "<<<<<<<" 2>/dev/null || echo "0")
        has_conflict=$(echo "$has_conflict" | tr -d '\n')
        log_debug "T3: merge-tree 预检结果 has_conflict=$has_conflict"
        if [[ "$has_conflict" -gt 0 ]]; then
            log_warn "预检发现 $has_conflict 个文件可能冲突："
            echo ""
            # 显示冲突的文件名
            echo "$conflict_check" | grep -B1 "<<<<<<<" | grep -v "^--$" | head -20
            echo ""
            if ! $AUTO_MODE; then
                read -r -p "继续尝试 merge？(y/N) " confirm
                if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
                    log_info "跳过 T3"
                    log_end_step "T3" 2
                    return 2
                fi
            else
                log_info "自动模式下继续尝试..."
            fi
        else
            log_ok "预检通过，零冲突"
        fi
    fi

    if ! $AUTO_MODE && [[ $cmp_rc -ne 2 ]]; then
        read -r -p "执行 T3 同步？(y/N) " confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            log_info "跳过 T3"
            log_end_step "T3" 2
            return 2
        fi
    fi

    log_info "切换到 $dst ..."
    git checkout "$dst"
    log_debug "T3: checkout $dst 成功"

    if [[ $cmp_rc -eq 0 ]]; then
        log_info "无自有提交，fast-forward 合并..."
        log_debug "T3: 执行 git merge --ff-only $src"
        git merge --ff-only "$src"
        log_debug "T3: merge --ff-only 成功"
    else
        log_info "有自有提交，执行 merge..."
        log_debug "T3: 执行 git merge --no-edit $src"
        if git merge --no-edit "$src"; then
            log_ok "Merge 成功"
            log_debug "T3: merge --no-edit 成功"
        else
            local conflict_files
            conflict_files=$(git diff --name-only --diff-filter=U)
            local conflict_count
            conflict_count=$(echo "$conflict_files" | grep -c . 2>/dev/null || echo "0")
            log_error "Merge 冲突！共 $conflict_count 个文件需要人工处理："
            echo "$conflict_files"
            log_error ""
            log_error "冲突原因通常是开发分支和上游同时修改了以下文件之一："
            for f in "${CONFLICT_PRONE_FILES[@]}"; do
                if echo "$conflict_files" | grep -q "$f"; then
                    log_error "  → $f"
                fi
            done
            log_error ""
            log_error "解决步骤："
            log_error "  1. 编辑冲突文件"
            log_error "  2. git add <conflicted_files>"
            log_error "  3. git commit"
            log_error "  4. git push origin $dst"
            exit 1
        fi
    fi

    # 推送前同步远程更新
    local ahead behind
    ahead_behind=$(git rev-list --left-right --count "$ORIGIN/$dst"..."$dst" 2>/dev/null || echo "0 0")
    behind=$(echo "$ahead_behind" | awk '{print $1}')
    ahead=$(echo "$ahead_behind" | awk '{print $2}')
    log_debug "T3: 远程比较 ahead=$ahead behind=$behind (local $dst ↔ origin/$dst)"

    if [[ "$ahead" -gt 0 ]] || [[ "$behind" -gt 0 ]]; then
        log_info "推送前同步远程更新 (local ahead=$ahead, behind=$behind)..."
        local pull_hb_pid
        pull_hb_pid=$(start_heartbeat "Pull $dst")
        git pull "$ORIGIN" "$dst" 2>/dev/null || {
            stop_heartbeat "$pull_hb_pid"
            log_warn "Pull 失败，尝试强制同步..."
            log_debug "T3: git pull $ORIGIN $dst 失败，回退到 fetch+merge"
            git fetch "$ORIGIN" "$dst"
            git merge "$ORIGIN/$dst" --no-edit 2>/dev/null || {
                log_error "无法同步远程更新，请手动处理"
                log_debug "T3: fetch+merge $ORIGIN/$dst 也失败"
                exit 1
            }
            log_debug "T3: fetch+merge 回退成功"
        }
        stop_heartbeat "$pull_hb_pid"
    else
        log_debug "T3: 本地与远程一致，无需 pull 同步"
    fi

    local origin_url
    origin_url=$(git remote get-url "$ORIGIN" 2>/dev/null || echo "unknown")
    log_debug "T3: 执行 git push $ORIGIN $dst (→ $origin_url)"
    local push_hb_pid
    push_hb_pid=$(start_heartbeat "Push $dst")
    git push "$ORIGIN" "$dst"
    stop_heartbeat "$push_hb_pid"
    log_debug "T3: push 成功"

    echo ""
    log_ok "T3 完成: $dst → $(git log --oneline -1 HEAD)"
    log_end_step "T3" 0
    return 0
}

# ============================================================================
# 主流程
# ============================================================================
AUTO_MODE=false
CRON_MODE=false
T1_ONLY=false
T2_ONLY=false

for arg in "$@"; do
    case $arg in
        --auto)    AUTO_MODE=true ;;
        --cron)    CRON_MODE=true ;;
        --t1-only) T1_ONLY=true ;;
        --t2-only) T2_ONLY=true ;;
        --help|-h)
            echo "用法: $0 [--auto] [--cron] [--t1-only] [--t2-only]"
            echo ""
            echo "  (无参数)   交互模式，逐级检查确认"
            echo "  --auto     自动模式，全自动执行"
            echo "  --cron     cron 模式，静默执行"
            echo "  --t1-only  仅同步 $BRANCH_UPSTREAM，不触发 $BRANCH_MAIN"
            echo "  --t2-only  仅同步 $BRANCH_MAIN，不触发 $BRANCH_DEV"
            echo ""
            echo "分支策略："
            echo "  $BRANCH_UPSTREAM  绝对纯净，ff-only 追踪 $UPSTREAM_BRANCH"
            echo "  $BRANCH_MAIN      核心主干，merge 自 upstream，仅新增 ALK 文件"
            echo "  $BRANCH_DEV       日常开发分支，merge 自 $BRANCH_MAIN"
            exit 0
            ;;
    esac
done

if $CRON_MODE; then
    AUTO_MODE=true
    log_info "Cron 模式"
fi

# ── 非 cron 模式下双写日志：终端 + 文件 ──────────────────────────────────
# cron 模式由 systemd 的 StandardOutput=append 处理，无需 tee
if ! $CRON_MODE; then
    exec > >(tee -a "$LOG_FILE") 2>&1
fi

# 计算运行模式标签
RUN_MODE="手动交互"
$AUTO_MODE && RUN_MODE="auto"
$CRON_MODE && RUN_MODE="cron"
$T1_ONLY && RUN_MODE="$RUN_MODE +t1-only"
$T2_ONLY && RUN_MODE="$RUN_MODE +t2-only"

echo ""
log_info "=========================================="
log_info "ALK 内核上游同步"
log_info "  PID:    $$"
log_info "  模式:   $RUN_MODE"
log_info "  仓库:   $REPO_ROOT"
log_info "  上游:   $UPSTREAM_REMOTE/$UPSTREAM_BRANCH"
log_info "  日志:   $LOG_FILE"
log_info "=========================================="
echo ""

check_prerequisites
verify_upstream_purity

# 抓取所有远程（带重试）
log_info "抓取远程更新..."
if ! fetch_with_retry "$UPSTREAM_REMOTE" "$UPSTREAM_BRANCH"; then
    log_error "无法获取上游更新，退出"
    exit 1
fi
if ! fetch_with_retry "$ORIGIN"; then
    log_error "无法获取 origin 更新，退出"
    exit 1
fi
log_ok "抓取完成"

# ── T1 ────────────────────────────────────────────────────────────────────
do_t1 || t1_rc=$?
t1_rc=${t1_rc:-0}
log_info "主流程: T1 完成 → rc=$t1_rc"

# ── T2 ────────────────────────────────────────────────────────────────────
if $T1_ONLY; then
    log_info "主流程: --t1-only，跳过 T2"
    echo ""

    # 提示：ALK-6.6-upstream 更新了，但 ALK-6.6 还没更新
    if [[ $t1_rc -eq 0 ]]; then
        log_warn "提醒：$BRANCH_UPSTREAM 已更新，但 $BRANCH_MAIN 尚未同步"
        log_warn "  请下次运行时不带 --t1-only 以包含 T2"
    fi
    exit 0
fi

# T1 成功（0）或无更新（1）时执行 T2；用户跳过（2）时也跳过 T2
if [[ $t1_rc -eq 0 ]] || [[ $t1_rc -eq 1 ]]; then
    log_info "主流程: 执行 T2 ($BRANCH_MAIN ← $BRANCH_UPSTREAM)"
    do_t2 || t2_rc=$?
    t2_rc=${t2_rc:-0}
    log_info "主流程: T2 完成 → rc=$t2_rc"
else
    log_info "主流程: T1 被跳过 (rc=$t1_rc)，跳过 T2"
    t2_rc=2
fi

# ── T3 ────────────────────────────────────────────────────────────────────
if $T1_ONLY || $T2_ONLY; then
    log_info "主流程: --t1-only / --t2-only，跳过 T3"
    echo ""
    if [[ $t2_rc -eq 0 ]]; then
        log_warn "提醒：$BRANCH_MAIN 已更新，但 $BRANCH_DEV 尚未同步"
        log_warn "  请下次运行时不带 --t2-only 以包含 T3"
    fi
else
    # T2 成功（0）或无更新（1）时执行 T3；用户跳过（2）时也跳过 T3
    if [[ $t2_rc -eq 0 ]] || [[ $t2_rc -eq 1 ]]; then
        log_info "主流程: 执行 T3 ($BRANCH_DEV ← $BRANCH_MAIN)"
        do_t3 || t3_rc=$?
        t3_rc=${t3_rc:-0}
        log_info "主流程: T3 完成 → rc=$t3_rc"
    else
        log_info "主流程: T2 被跳过 (rc=$t2_rc)，跳过 T3"
        t3_rc=2
    fi
fi

echo ""
log_ok "同步流程结束 (T1 rc=${t1_rc:-?} | T2 rc=${t2_rc:-?} | T3 rc=${t3_rc:-?})"
log_info "进程 $$ 退出"

# 给 tee 子进程留一点时间把缓冲刷入日志文件（非 cron 模式）
if ! $CRON_MODE; then
    sleep 0.1
fi
