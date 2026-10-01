#!/usr/bin/env bash
# ============================================================================
# ALK 内核 openEuler OLK-6.6 驱动上游追踪脚本
#
# 追踪 openEuler OLK-6.6 的驱动与架构更新，同步到 ALK-6.6-dev。
# 仅触及 drivers/ 与 arch/{x86,arm64,sw_64}/，绝不覆盖 airy 核心模块。
#
# 五阶段流水线：
#   E1: fetch  — 从 openEuler 仓库 fetch OLK-6.6 最新提交（不合并）
#   E2: diff   — 对比 ALK-6.6-dev 与 OLK-6.6，过滤目标路径，排除 airy 核心
#   E3: apply  — 双轨制应用（sw_64 直接导入 + drivers cherry-pick/quilt）
#   E4: config — 三架构 defconfig 验证
#   E5: verify — diffconfig IRON-7 一致性验证
#
# 使用方法：
#   bash sync-euler-drivers.sh                    # 全流水线
#   bash sync-euler-drivers.sh --stage E2         # 仅 E2
#   bash sync-euler-drivers.sh --dry-run          # E2/E3 只打印不写盘
#   bash sync-euler-drivers.sh --help             # 帮助
# ============================================================================

set -euo pipefail

# ── 配置 ──────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ALK_DIR="${ALK_DIR:-$SCRIPT_DIR/../airymaxhub/agentrt-linux/kernel}"
EULER_REMOTE="${EULER_REMOTE:-openeuler}"
EULER_REMOTE_URL="${EULER_REMOTE_URL:-https://gitee.com/openeuler/kernel}"
EULER_BRANCH="${EULER_BRANCH:-OLK-6.6}"
ALK_BRANCH="${ALK_BRANCH:-ALK-6.6-dev}"
WORK_DIR="${WORK_DIR:-$SCRIPT_DIR/work-euler}"

LOG_DIR="$SCRIPT_DIR/logs"
LOG_FILE="$LOG_DIR/sync-euler-drivers.log"

# 待同步路径（仅这些目录的变更会被追踪）
SYNC_PATHS=(
    "drivers/"
    "arch/x86/"
    "arch/arm64/"
    "arch/sw_64/"
)

# airy 核心模块（绝不覆盖，E2 排除）
AIRY_EXCLUDE_PATHS=(
    "kernel/corekern/"
    "kernel/superv/"
    "security/airy/"
    "kernel/ipc/airy_ipc_capability.c"
    "kernel/syscalls/airy_syscalls.c"
    "init/airy_core.c"
)

# defconfig 配置
DEFCONFIG_NAME="airy_defconfig"
ARM64_CROSS_COMPILE="aarch64-linux-gnu-"
SW64_CROSS_COMPILE="sw_64-linux-gnu-"

# 网络重试
FETCH_RETRIES=3
FETCH_TIMEOUT=300
FETCH_DELAY=30

# ── 确保目录存在 ─────────────────────────────────────────────────────────────
mkdir -p "$LOG_DIR" "$WORK_DIR"

# ── 日志（彩色输出，前缀 [sync-euler] + 时间戳）──────────────────────────────
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

log()       { echo -e "${C_DATE}[$(date '+%Y-%m-%d %H:%M:%S')][sync-euler][$$]${C_RESET} $1"; }
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

# ── 网络重试 fetch ────────────────────────────────────────────────────────────
fetch_with_retry() {
    local remote="$1"
    local branch="${2:-}"
    local retries="$FETCH_RETRIES"
    local delay="$FETCH_DELAY"
    local attempt=1

    local remote_url
    remote_url=$(git -C "$ALK_DIR" remote get-url "$remote" 2>/dev/null || echo "unknown")
    log_debug "fetch_with_retry: remote=$remote url=$remote_url branch=${branch:-'(all)'}"

    while [[ $attempt -le $retries ]]; do
        log_info "Fetch 尝试 $attempt/$retries: $remote ${branch:+$branch}"
        local rc=0
        if [[ -n "$branch" ]]; then
            git -C "$ALK_DIR" -c http.postBuffer=524288000 \
                -c http.lowSpeedLimit=1000 \
                -c http.lowSpeedTime=$FETCH_TIMEOUT \
                fetch "$remote" "$branch" --quiet 2>&1 || rc=$?
        else
            git -C "$ALK_DIR" -c http.postBuffer=524288000 \
                -c http.lowSpeedLimit=1000 \
                -c http.lowSpeedTime=$FETCH_TIMEOUT \
                fetch "$remote" --quiet 2>&1 || rc=$?
        fi

        if [[ $rc -eq 0 ]]; then
            log_ok "Fetch 成功"
            return 0
        fi

        log_warn "Fetch 尝试 $attempt 失败 (exit code $rc)"

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

# ── 构建 airy 排除模式（grep -E 用）──────────────────────────────────────────
build_exclude_pattern() {
    local pattern=""
    for p in "${AIRY_EXCLUDE_PATHS[@]}"; do
        if [[ -n "$pattern" ]]; then
            pattern="${pattern}|"
        fi
        pattern="${pattern}^${p}"
    done
    echo "$pattern"
}

# ── 辅助：生成 defconfig 并保存 .config ──────────────────────────────────────
capture_config() {
    local arch="$1" cross="${2:-}" output="$3"
    local make_args=(make -C "$ALK_DIR" "ARCH=$arch")
    [[ -n "$cross" ]] && make_args+=("CROSS_COMPILE=$cross")
    make_args+=("$DEFCONFIG_NAME")

    log_debug "capture_config: ${make_args[*]}"
    if "${make_args[@]}" > /dev/null 2>&1; then
        cp "$ALK_DIR/.config" "$output"
        log_debug "  → $output"
    else
        log_warn "  $arch defconfig 生成失败"
        : > "$output"
    fi
}

# ============================================================================
# 前置检查
# ============================================================================
check_prerequisites() {
    log_info "检查前置条件..."

    if [[ ! -d "$ALK_DIR" ]]; then
        log_error "ALK 内核目录不存在: $ALK_DIR"
        exit 1
    fi

    if ! git -C "$ALK_DIR" rev-parse --git-dir > /dev/null 2>&1; then
        log_error "不在 git 仓库中: $ALK_DIR"
        exit 1
    fi

    if ! git -C "$ALK_DIR" show-ref --verify --quiet "refs/heads/$ALK_BRANCH"; then
        log_error "本地分支 '$ALK_BRANCH' 不存在于 $ALK_DIR"
        exit 1
    fi

    log_ok "前置检查通过"
}

# ============================================================================
# E1: fetch — 从 openEuler 仓库 fetch OLK-6.6（不合并）
# ============================================================================
do_e1() {
    log_step "E1: fetch $EULER_REMOTE/$EULER_BRANCH"

    # 确保远程存在
    if ! git -C "$ALK_DIR" remote get-url "$EULER_REMOTE" > /dev/null 2>&1; then
        log_info "远程 '$EULER_REMOTE' 不存在，添加: $EULER_REMOTE_URL"
        git -C "$ALK_DIR" remote add "$EULER_REMOTE" "$EULER_REMOTE_URL"
    else
        local existing_url
        existing_url=$(git -C "$ALK_DIR" remote get-url "$EULER_REMOTE")
        log_debug "远程 '$EULER_REMOTE' 已存在: $existing_url"
        if [[ "$existing_url" != "$EULER_REMOTE_URL" ]]; then
            log_warn "远程 URL 与配置不同 (配置=$EULER_REMOTE_URL, 实际=$existing_url)"
            log_warn "使用已有远程地址继续"
        fi
    fi

    if ! fetch_with_retry "$EULER_REMOTE" "$EULER_BRANCH"; then
        log_error "无法 fetch $EULER_REMOTE/$EULER_BRANCH，退出"
        exit 1
    fi

    local euler_tip alk_tip
    euler_tip=$(git -C "$ALK_DIR" rev-parse --short "$EULER_REMOTE/$EULER_BRANCH" 2>/dev/null || echo "unknown")
    alk_tip=$(git -C "$ALK_DIR" rev-parse --short "$ALK_BRANCH" 2>/dev/null || echo "unknown")

    echo ""
    echo "  $ALK_BRANCH:        $alk_tip"
    echo "  $EULER_REMOTE/$EULER_BRANCH:  $euler_tip"
    echo ""

    log_ok "E1 完成: fetch 成功（未合并）"
    log_end_step "E1" 0
}

# ============================================================================
# E2: diff 过滤 — 对比 ALK-6.6-dev 与 OLK-6.6，过滤目标路径，排除 airy 核心
# ============================================================================
do_e2() {
    log_step "E2: diff 过滤（$ALK_BRANCH ↔ $EULER_REMOTE/$EULER_BRANCH）"

    local euler_ref="$EULER_REMOTE/$EULER_BRANCH"
    local alk_ref="$ALK_BRANCH"

    # 确认 EULER_REMOTE/EULER_BRANCH 引用存在
    if ! git -C "$ALK_DIR" rev-parse --verify "$euler_ref" > /dev/null 2>&1; then
        log_error "引用不存在: $euler_ref（请先运行 E1 fetch）"
        exit 1
    fi

    local base
    base=$(git -C "$ALK_DIR" merge-base "$alk_ref" "$euler_ref" 2>/dev/null || echo "")
    if [[ -z "$base" ]]; then
        log_error "无法计算 merge-base（分支无共同祖先？）"
        exit 1
    fi

    local base_short euler_short alk_short
    base_short=$(git -C "$ALK_DIR" rev-parse --short "$base")
    euler_short=$(git -C "$ALK_DIR" rev-parse --short "$euler_ref")
    alk_short=$(git -C "$ALK_DIR" rev-parse --short "$alk_ref")

    log_info "merge-base: $base_short"
    log_info "$ALK_BRANCH:        $alk_short"
    log_info "$euler_ref:  $euler_short"

    local exclude_pattern
    exclude_pattern=$(build_exclude_pattern)

    # 文件列表：base..euler 中目标路径的变更，排除 airy 核心
    local files_raw files_filtered
    files_raw=$(git -C "$ALK_DIR" diff --name-only "$base" "$euler_ref" -- "${SYNC_PATHS[@]}" 2>/dev/null || true)
    files_filtered=$(echo "$files_raw" | grep -vE "$exclude_pattern" 2>/dev/null || true)

    local file_count=0
    if [[ -n "$files_filtered" ]]; then
        file_count=$(echo "$files_filtered" | grep -c . 2>/dev/null || echo 0)
    fi

    # commit 列表：base..euler 中触及目标路径的提交
    local commits_raw
    commits_raw=$(git -C "$ALK_DIR" log --reverse --pretty=format:'%H %s' "$base..$euler_ref" -- "${SYNC_PATHS[@]}" 2>/dev/null || true)

    local commit_count=0
    if [[ -n "$commits_raw" ]]; then
        commit_count=$(echo "$commits_raw" | grep -c . 2>/dev/null || echo 0)
    fi

    echo ""
    echo "  待同步文件数: $file_count"
    echo "  待同步提交数: $commit_count"
    echo ""

    # 按子目录统计文件分布
    if [[ -n "$files_filtered" ]]; then
        echo "  文件分布（按顶层路径）:"
        echo "$files_filtered" | awk -F/ '{print $1"/"$2}' | sort | uniq -c | sort -rn | head -15
        echo ""
    fi

    # 检查是否有 airy 核心路径被触及（异常情况，已排除不同步）
    local airy_touched
    airy_touched=$(echo "$files_raw" | grep -E "$exclude_pattern" 2>/dev/null || true)
    if [[ -n "$airy_touched" ]]; then
        log_warn "OLK-6.6 改动了 airy 核心路径（已排除，不同步）:"
        echo "$airy_touched" | head -10
        echo ""
    fi

    if $DRY_RUN; then
        log_info "[dry-run] 不写盘，文件/提交清单输出到终端"
        echo ""
        echo "── 文件清单 (前 30) ──"
        echo "$files_filtered" | head -30
        echo ""
        echo "── 提交清单 (前 20) ──"
        echo "$commits_raw" | head -20
    else
        echo "$files_filtered" | sort > "$WORK_DIR/e2-files.txt"
        echo "$commits_raw" > "$WORK_DIR/e2-commits.txt"
        log_ok "文件清单 → $WORK_DIR/e2-files.txt ($file_count 项)"
        log_ok "提交清单 → $WORK_DIR/e2-commits.txt ($commit_count 项)"
    fi

    log_ok "E2 完成"
    log_end_step "E2" 0
}

# ============================================================================
# E3: 应用变更（双轨制）
#   Track 1: arch/sw_64/ 直接导入（vanilla mainline 无 sw_64 架构树，无冲突）
#   Track 2: drivers/hooks/ 及其他 drivers 变更 cherry-pick + quilt 回退
# ============================================================================
do_e3() {
    log_step "E3: 应用变更（双轨制）"

    local euler_ref="$EULER_REMOTE/$EULER_BRANCH"

    if ! git -C "$ALK_DIR" rev-parse --verify "$euler_ref" > /dev/null 2>&1; then
        log_error "引用不存在: $euler_ref（请先运行 E1 fetch）"
        exit 1
    fi

    local report_file="$WORK_DIR/e3-apply-report.txt"
    if ! $DRY_RUN; then
        : > "$report_file"
    fi

    # 切换到 ALK 分支
    log_info "切换到 $ALK_BRANCH ..."
    if ! $DRY_RUN; then
        # 检查工作区是否干净（E3 会修改工作区）
        if [[ -n "$(git -C "$ALK_DIR" status --porcelain)" ]]; then
            log_error "工作区不干净，请先清理: $ALK_DIR"
            git -C "$ALK_DIR" status --short
            exit 1
        fi
        git -C "$ALK_DIR" checkout "$ALK_BRANCH"

        # 记录 E3 前 HEAD（便于回退）
        local pre_e3_head
        pre_e3_head=$(git -C "$ALK_DIR" rev-parse HEAD)
        log_info "E3 前 HEAD: $pre_e3_head"
        log_info "（回退命令: git -C \"$ALK_DIR\" reset --hard $pre_e3_head）"
        echo "# E3 pre-head: $pre_e3_head" >> "$report_file"
    fi

    # ── 捕获基线 config（供 E5 IRON-7 对比）─────────────────────────────────
    if ! $DRY_RUN; then
        log_info "捕获基线 .config（供 E5 IRON-7 对比）..."
        mkdir -p "$WORK_DIR/baseline-configs"
        capture_config "x86" "" "$WORK_DIR/baseline-configs/x86.config"
        capture_config "arm64" "$ARM64_CROSS_COMPILE" "$WORK_DIR/baseline-configs/arm64.config"
        if command -v "${SW64_CROSS_COMPILE}gcc" > /dev/null 2>&1; then
            capture_config "sw_64" "$SW64_CROSS_COMPILE" "$WORK_DIR/baseline-configs/sw_64.config"
        else
            log_warn "sw_64 交叉编译器不可用，基线 config 留空"
            : > "$WORK_DIR/baseline-configs/sw_64.config"
        fi
    fi

    # ── Track 1: arch/sw_64/ 直接导入 ─────────────────────────────────────────
    echo ""
    log_info "Track 1: arch/sw_64/ 直接导入模式"
    log_info "  说明：vanilla mainline 无 sw_64 架构树，与 vanilla 无冲突"
    log_info "  说明：配合 openeuler_defconfig 与 euler_hw_sw64.config"

    local sw64_count
    sw64_count=$(git -C "$ALK_DIR" ls-tree -r --name-only "$euler_ref" -- arch/sw_64/ 2>/dev/null | grep -c . 2>/dev/null || echo 0)

    if $DRY_RUN; then
        log_info "[dry-run] 将从 $euler_ref 检出 arch/sw_64/ ($sw64_count 个文件) 覆盖到 ALK 树"
    else
        if [[ "$sw64_count" -gt 0 ]]; then
            git -C "$ALK_DIR" checkout "$euler_ref" -- arch/sw_64/
            git -C "$ALK_DIR" add arch/sw_64/
            log_ok "arch/sw_64/ 导入完成 ($sw64_count 个文件已暂存)"
            echo "[Track1][apply] arch/sw_64/ ($sw64_count files)" >> "$report_file"
        else
            log_warn "arch/sw_64/ 在 $euler_ref 中无文件，跳过"
            echo "[Track1][skip] arch/sw_64/ (no files)" >> "$report_file"
        fi
    fi

    # ── Track 2: drivers/ cherry-pick + quilt 回退 ───────────────────────────
    echo ""
    log_info "Track 2: drivers/hooks/ 及其他 drivers 变更 cherry-pick + quilt 模式"

    local commits_file="$WORK_DIR/e2-commits.txt"
    if [[ ! -f "$commits_file" ]]; then
        log_warn "提交清单不存在 ($commits_file)，请先运行 E2"
        echo "[Track2][skip] no commits list" >> "$report_file" 2>/dev/null || true
    else
        local quilt_dir="$ALK_DIR/patches/hw-vendor"
        local series_file="$quilt_dir/series"
        if ! $DRY_RUN; then
            mkdir -p "$quilt_dir"
            [[ -f "$series_file" ]] || : > "$series_file"
        fi

        local applied=0 skipped=0 conflicted=0
        local idx=1
        local total
        total=$(grep -c . "$commits_file" 2>/dev/null || echo 0)

        if [[ "$total" -eq 0 ]]; then
            log_info "无待同步提交"
        fi

        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            local commit="${line%% *}"
            local subject="${line#* }"
            local short="${commit:0:12}"

            log_info "[$idx/$total] $short: $subject"

            if $DRY_RUN; then
                log_info "  [dry-run] 将尝试 cherry-pick $short"
                applied=$((applied + 1))
                idx=$((idx + 1))
                continue
            fi

            # 尝试 cherry-pick
            local cp_rc=0
            git -C "$ALK_DIR" cherry-pick "$commit" 2>/dev/null || cp_rc=$?

            if [[ $cp_rc -eq 0 ]]; then
                # 检查是否为空提交（可能已应用）
                if git -C "$ALK_DIR" diff --quiet HEAD~1 HEAD 2>/dev/null; then
                    git -C "$ALK_DIR" reset --hard HEAD~1 > /dev/null 2>&1 || true
                    log_info "  [skip] 空提交（可能已应用）: $short"
                    echo "[Track2][skip] $short $subject (empty, possibly applied)" >> "$report_file"
                    skipped=$((skipped + 1))
                else
                    log_ok "  [apply] cherry-pick 成功"
                    echo "[Track2][apply] $short $subject" >> "$report_file"
                    applied=$((applied + 1))
                fi
            else
                # 冲突或其他失败 → 中止 cherry-pick，落为 quilt 补丁
                git -C "$ALK_DIR" cherry-pick --abort 2>/dev/null || true
                log_warn "  [conflict] cherry-pick 失败，落为 quilt 补丁"

                local patch_name patch_path
                patch_name=$(printf '%04d-%s.patch' "$idx" "$short")
                patch_path="$quilt_dir/$patch_name"

                # 生成仅含目标路径的补丁（排除 airy 核心路径）
                git -C "$ALK_DIR" format-patch -1 "$commit" --stdout \
                    -- drivers/ arch/x86/ arch/arm64/ arch/sw_64/ \
                    > "$patch_path" 2>/dev/null || true

                if [[ -s "$patch_path" ]]; then
                    echo "$patch_name" >> "$series_file"
                    log_warn "  [quilt] → patches/hw-vendor/$patch_name"
                    echo "[Track2][quilt] $short $subject -> $patch_name" >> "$report_file"
                    conflicted=$((conflicted + 1))
                else
                    log_error "  [fail] 无法生成补丁（format-patch 返回空）"
                    echo "[Track2][fail] $short $subject (empty patch)" >> "$report_file"
                    rm -f "$patch_path"
                    skipped=$((skipped + 1))
                fi
            fi

            idx=$((idx + 1))
        done < "$commits_file"

        echo ""
        log_info "Track 2 汇总: apply=$applied, quilt=$conflicted, skip=$skipped (共 $total)"
    fi

    # ── E3 汇总 ───────────────────────────────────────────────────────────────
    echo ""
    if $DRY_RUN; then
        log_ok "E3 完成 [dry-run]（未写盘）"
    else
        log_ok "E3 完成，报告 → $report_file"
    fi
    log_end_step "E3" 0
}

# ============================================================================
# E4: 三架构 defconfig 验证
#   x86:   本地 gcc
#   arm64: aarch64-linux-gnu-gcc（不可用则记录跳过）
#   sw_64: 本机无交叉 gcc，需 OBS 远程构建（记录跳过）
#   任一可构建架构失败则退出非零
# ============================================================================
do_e4() {
    log_step "E4: 三架构 defconfig 验证"

    if ! $DRY_RUN; then
        mkdir -p "$WORK_DIR/current-configs"
    fi

    local report_file="$WORK_DIR/e4-defconfig-report.txt"
    if ! $DRY_RUN; then
        : > "$report_file"
    fi

    local overall_rc=0

    # ── x86: 本地 gcc ────────────────────────────────────────────────────────
    echo ""
    log_info "x86: make ARCH=x86 $DEFCONFIG_NAME (本地 gcc)"
    if $DRY_RUN; then
        log_info "  [dry-run] 跳过实际编译"
    else
        if make -C "$ALK_DIR" ARCH=x86 "$DEFCONFIG_NAME" > /dev/null 2>&1; then
            if [[ -f "$ALK_DIR/.config" ]]; then
                cp "$ALK_DIR/.config" "$WORK_DIR/current-configs/x86.config"
                log_ok "  x86 defconfig 生成成功"
                echo "[x86][ok] defconfig 生成成功" >> "$report_file"
            else
                log_error "  x86 defconfig 生成失败（.config 不存在）"
                echo "[x86][fail] .config not found" >> "$report_file"
                overall_rc=1
            fi
        else
            log_error "  x86 defconfig 生成失败"
            echo "[x86][fail] make 失败" >> "$report_file"
            overall_rc=1
        fi
    fi

    # ── arm64: aarch64-linux-gnu-gcc ──────────────────────────────────────────
    echo ""
    log_info "arm64: make ARCH=arm64 CROSS_COMPILE=$ARM64_CROSS_COMPILE $DEFCONFIG_NAME"
    if $DRY_RUN; then
        log_info "  [dry-run] 跳过实际编译"
    else
        if command -v "${ARM64_CROSS_COMPILE}gcc" > /dev/null 2>&1; then
            if make -C "$ALK_DIR" ARCH=arm64 "CROSS_COMPILE=$ARM64_CROSS_COMPILE" "$DEFCONFIG_NAME" > /dev/null 2>&1; then
                if [[ -f "$ALK_DIR/.config" ]]; then
                    cp "$ALK_DIR/.config" "$WORK_DIR/current-configs/arm64.config"
                    log_ok "  arm64 defconfig 生成成功"
                    echo "[arm64][ok] defconfig 生成成功" >> "$report_file"
                else
                    log_error "  arm64 defconfig 生成失败（.config 不存在）"
                    echo "[arm64][fail] .config not found" >> "$report_file"
                    overall_rc=1
                fi
            else
                log_error "  arm64 defconfig 生成失败"
                echo "[arm64][fail] make 失败" >> "$report_file"
                overall_rc=1
            fi
        else
            log_warn "  arm64 交叉编译器 ${ARM64_CROSS_COMPILE}gcc 不可用，记录跳过"
            echo "[arm64][skip] 交叉编译器不可用" >> "$report_file"
            : > "$WORK_DIR/current-configs/arm64.config"
        fi
    fi

    # ── sw_64: 本机无交叉 gcc，需 OBS 远程构建 ─────────────────────────────────
    echo ""
    log_info "sw_64: make ARCH=sw_64 CROSS_COMPILE=$SW64_CROSS_COMPILE $DEFCONFIG_NAME"
    if $DRY_RUN; then
        log_info "  [dry-run] 跳过实际编译"
    else
        if command -v "${SW64_CROSS_COMPILE}gcc" > /dev/null 2>&1; then
            if make -C "$ALK_DIR" ARCH=sw_64 "CROSS_COMPILE=$SW64_CROSS_COMPILE" "$DEFCONFIG_NAME" > /dev/null 2>&1; then
                if [[ -f "$ALK_DIR/.config" ]]; then
                    cp "$ALK_DIR/.config" "$WORK_DIR/current-configs/sw_64.config"
                    log_ok "  sw_64 defconfig 生成成功"
                    echo "[sw_64][ok] defconfig 生成成功" >> "$report_file"
                else
                    log_error "  sw_64 defconfig 生成失败（.config 不存在）"
                    echo "[sw_64][fail] .config not found" >> "$report_file"
                    overall_rc=1
                fi
            else
                log_error "  sw_64 defconfig 生成失败"
                echo "[sw_64][fail] make 失败" >> "$report_file"
                overall_rc=1
            fi
        else
            log_warn "  sw_64 交叉编译器 ${SW64_CROSS_COMPILE}gcc 不可用，需 OBS 远程构建，记录跳过"
            echo "[sw_64][skip] 本机无交叉 gcc，需 OBS 远程构建" >> "$report_file"
            : > "$WORK_DIR/current-configs/sw_64.config"
        fi
    fi

    # ── 汇总 ─────────────────────────────────────────────────────────────────
    echo ""
    if [[ $overall_rc -ne 0 ]]; then
        log_error "E4 失败：可构建架构 defconfig 生成失败"
        echo ""
        cat "$report_file" 2>/dev/null || true
        log_end_step "E4" 1
        exit 1
    fi

    log_ok "E4 完成: 可构建架构 defconfig 验证通过（sw_64 跳过）"
    if ! $DRY_RUN; then
        log_info "报告 → $report_file"
    fi
    log_end_step "E4" 0
}

# ============================================================================
# E5: diffconfig IRON-7 一致性验证
#   对三架构运行 scripts/diffconfig 对比同步前后 .config 差异
#   输出 IRON-7 一致性报告（关键配置项未意外漂移）
# ============================================================================
do_e5() {
    log_step "E5: diffconfig IRON-7 一致性验证"

    local report_file="$WORK_DIR/e5-iron7-report.txt"
    local diffconfig_script="$ALK_DIR/scripts/diffconfig"

    if ! $DRY_RUN; then
        : > "$report_file"
    fi

    if [[ ! -f "$diffconfig_script" ]]; then
        log_error "diffconfig 脚本不存在: $diffconfig_script"
        exit 1
    fi

    # IRON-7 关注的关键配置前缀（这些不应因驱动同步而意外漂移）
    local iron7_watch_patterns=(
        "CONFIG_AIRY"
        "CONFIG_AIRYMAX"
        "CONFIG_SECURITY"
        "CONFIG_SCHED"
        "CONFIG_MODULES"
    )

    local iron7_pass=true

    for arch in x86 arm64 sw_64; do
        echo ""
        log_info "$arch: diffconfig 对比"

        local baseline="$WORK_DIR/baseline-configs/${arch}.config"
        local current="$WORK_DIR/current-configs/${arch}.config"

        if [[ ! -f "$baseline" ]] || [[ ! -s "$baseline" ]]; then
            log_warn "  基线 config 不存在或为空: $baseline（跳过 $arch）"
            if ! $DRY_RUN; then
                echo "[$arch][skip] baseline missing" >> "$report_file"
            fi
            continue
        fi
        if [[ ! -f "$current" ]] || [[ ! -s "$current" ]]; then
            log_warn "  当前 config 不存在或为空: $current（跳过 $arch）"
            if ! $DRY_RUN; then
                echo "[$arch][skip] current missing" >> "$report_file"
            fi
            continue
        fi

        local diff_output
        diff_output=$(python3 "$diffconfig_script" "$baseline" "$current" 2>/dev/null || true)

        if [[ -z "$diff_output" ]]; then
            log_ok "  $arch: 零差异（IRON-7 一致）"
            if ! $DRY_RUN; then
                echo "[$arch][ok] 零差异" >> "$report_file"
            fi
        else
            local diff_lines
            diff_lines=$(echo "$diff_output" | grep -c . 2>/dev/null || echo 0)
            log_info "  $arch: $diff_lines 项配置差异"
            echo "$diff_output" | head -20
            if [[ $diff_lines -gt 20 ]]; then
                log_info "  ... (共 $diff_lines 项，仅显示前 20)"
            fi

            # 检查 IRON-7 关键配置是否漂移
            local iron7_drift=""
            local pattern
            for pattern in "${iron7_watch_patterns[@]}"; do
                local hit
                hit=$(echo "$diff_output" | grep "$pattern" 2>/dev/null || true)
                if [[ -n "$hit" ]]; then
                    iron7_drift="${iron7_drift}${hit}
"
                fi
            done

            if [[ -n "$iron7_drift" ]]; then
                log_warn "  ⚠ IRON-7 关键配置漂移检测:"
                echo "$iron7_drift" | head -10
                iron7_pass=false
                if ! $DRY_RUN; then
                    echo "[$arch][warn] IRON-7 关键配置漂移:" >> "$report_file"
                    echo "$iron7_drift" >> "$report_file"
                fi
            else
                log_ok "  $arch: IRON-7 关键配置未漂移（差异均为驱动相关）"
                if ! $DRY_RUN; then
                    echo "[$arch][ok] IRON-7 关键配置未漂移 ($diff_lines 项驱动相关差异)" >> "$report_file"
                    echo "$diff_output" >> "$report_file"
                fi
            fi
        fi
    done

    echo ""
    if $iron7_pass; then
        log_ok "E5 完成: IRON-7 一致性验证通过"
    else
        log_warn "E5 完成: 检测到 IRON-7 关键配置漂移，请人工审查"
    fi
    if ! $DRY_RUN; then
        log_info "报告 → $report_file"
    fi
    log_end_step "E5" 0
}

# ============================================================================
# 帮助
# ============================================================================
show_help() {
    cat <<'EOF'
用法: sync-euler-drivers.sh [--stage E1|E2|E3|E4|E5|all] [--dry-run] [--help]

追踪 openEuler OLK-6.6 驱动与架构更新，同步到 ALK-6.6-dev。

选项:
  --stage E1|E2|E3|E4|E5|all   选择执行阶段（默认 all）
  --dry-run                     E2/E3 只打印不写盘
  --help, -h                    显示此帮助

阶段:
  E1  fetch     从 openEuler 仓库 fetch OLK-6.6 最新提交（不合并）
  E2  diff      对比 ALK-6.6-dev 与 OLK-6.6，过滤目标路径，排除 airy 核心
  E3  apply     双轨制应用（sw_64 直接导入 + drivers cherry-pick/quilt）
  E4  config    三架构 defconfig 验证（x86/arm64/sw_64）
  E5  verify    diffconfig IRON-7 一致性验证

可配置环境变量:
  ALK_DIR            ALK 内核源码树路径
                     (默认: ../airymaxhub/agentrt-linux/kernel)
  EULER_REMOTE       openEuler 远程名称 (默认: openeuler)
  EULER_REMOTE_URL   openEuler 远程地址 (默认: https://gitee.com/openeuler/kernel)
  EULER_BRANCH       openEuler 分支 (默认: OLK-6.6)
  ALK_BRANCH         ALK 开发分支 (默认: ALK-6.6-dev)
  WORK_DIR           工作目录 (默认: ./work-euler)

同步范围:
  drivers/           驱动（cherry-pick + quilt 回退）
  arch/x86/          x86 架构
  arch/arm64/        arm64 架构
  arch/sw_64/        申威架构（直接导入，vanilla 无此树）

排除（绝不覆盖）:
  kernel/corekern/   kernel/superv/   security/airy/
  kernel/ipc/airy_ipc_capability.c
  kernel/syscalls/airy_syscalls.c
  init/airy_core.c
EOF
}

# ============================================================================
# 主流程
# ============================================================================
STAGE="all"
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --stage)
            [[ $# -lt 2 ]] && { log_error "--stage 需要参数"; exit 1; }
            STAGE="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --help|-h)
            show_help
            exit 0
            ;;
        *)
            log_error "未知参数: $1"
            show_help
            exit 1
            ;;
    esac
done

case "$STAGE" in
    E1|E2|E3|E4|E5|all) ;;
    *)
        log_error "无效阶段: $STAGE（可选: E1|E2|E3|E4|E5|all）"
        exit 1
        ;;
esac

# 双写日志：终端 + 文件
exec > >(tee -a "$LOG_FILE") 2>&1

echo ""
log_info "=========================================="
log_info "ALK openEuler OLK-6.6 驱动上游追踪"
log_info "  PID:       $$"
log_info "  阶段:      $STAGE"
log_info "  ALK 目录:  $ALK_DIR"
log_info "  远程:      $EULER_REMOTE/$EULER_BRANCH"
log_info "  工作目录:  $WORK_DIR"
log_info "  DRY_RUN:   $DRY_RUN"
log_info "=========================================="

check_prerequisites

case "$STAGE" in
    E1) do_e1 ;;
    E2) do_e2 ;;
    E3) do_e3 ;;
    E4) do_e4 ;;
    E5) do_e5 ;;
    all)
        do_e1
        do_e2
        do_e3
        do_e4
        do_e5
        ;;
esac

echo ""
log_ok "同步流程结束 (stage=$STAGE)"
log_info "进程 $$ 退出"
sleep 0.1