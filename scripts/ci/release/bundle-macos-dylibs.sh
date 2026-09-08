#!/usr/bin/env bash
# bundle-macos-dylibs.sh — macOS 包 dylib 自包含（0.1.13 G4 / U6）
#
# 背景（一手证据）：0.1.12 前 macOS 包内二进制链接 brew dylib（/opt/homebrew
# 或 /usr/local），干净机器（无 brew 依赖）daemon 启动即 dyld 失败——社区用户
# U6。Linux 侧已由容器内 ldd 收集 + ELF 守卫 fail-closed（P15/U3）；macOS 无
# 容器、ldd 不存在，需 otool -L 递归收集 + install_name_tool 重写到包内。
#
# 方案：
#   1) 遍历 bin/ 全部 Mach-O，otool -L 收集非系统 dylib（系统豁免：/usr/lib、
#      /System、/Library/Apple）；BFS 展开传递依赖（dylib 自身也可能依赖其他
#      brew dylib），拷贝至 <stage>/lib/。
#   2) 对 bin/ 与 lib/ 所有被改写文件 install_name_tool -change 绝对路径 →
#      @executable_path/../lib/<basename>（@executable_path 恒相对主可执行，
#      嵌套依赖同样可解；所有 daemon/CLI 均位于 bin/）。
#   3) 改写后清除指向构建机的 LC_RPATH（残留在干净机上必失败，抹掉回退路径
#      让其在打包期即显式报错），再 codesign --force -s - 重签（Apple Silicon
#      强制，Intel 无害）。
#   4) fail-closed 校验（bin/ + lib/ 全量 Mach-O）：残留 @rpath/* 或任何非
#      系统绝对依赖 → 中止（杜绝"干净机启动失败"缺陷包出库）。
#
# rc4-8 教训（0.1.13 G4b 实证）：Homebrew 的 libbrotlidec.1.dylib 以
# @rpath/libbrotlicommon.1.dylib 表达传递依赖，旧版把一切 @ 前缀按"系统/
# 已改写"豁免——漏收集漏改写；构建机 brew 在盘故 LC_RPATH 可解析、冒烟假绿，
# 干净机 dyld "no such file"，daemon 群全崩。@rpath 依赖必须经引用方
# LC_RPATH 解析为盘上文件入库并改写；校验必须覆盖 lib/ 嵌套依赖。
#
# rc4-9 教训（rc5 run 34196069821 实证）：otool -L 真实输出第 1 行是文件
# 路径行、第 2 行是文件自身 LC_ID_DYLIB（brew 构建期绝对路径），依赖从第 3
# 行起——tail -n +2 把 id 行误当依赖，26 个入库 dylib 全部假性 FAIL；且
# two-level namespace 下 dyld 要求引用者 LC_LOAD_DYLIB 与目标 LC_ID_DYLIB
# 一致，入库 dylib 的 id 必须与引用面同步改写为 @executable_path/../lib/。
# mock 的 sidecar 缺 id 行故未拦截此雷（教训：mock 必须复刻真实工具输出
# 结构，含头部与 id 行）。
#
# 用法：bundle-macos-dylibs.sh <stage_dir>
#   stage_dir 内含 bin/（daemon + CLI + TUI 等）与 lib/（python 等）。
set -euo pipefail

STAGE="${1:?usage: bundle-macos-dylibs.sh <stage_dir>}"
BIN_DIR="$STAGE/bin"
LIB_DIR="$STAGE/lib"
mkdir -p "$LIB_DIR"
[ -d "$BIN_DIR" ] || { echo "::error::bin/ 不存在: $BIN_DIR"; exit 1; }

# Mach-O 判定：前 4 字节魔数（0xFEEDFACE / 0xFEEDFACF / 0xCAFEBABE 等）
is_macho() {
    local m
    m="$(head -c4 "$1" 2>/dev/null | od -An -tx1 | tr -d ' \n')"
    [ "$m" = "cffaedfe" ] || [ "$m" = "cefaedfe" ] || [ "$m" = "cafebabe" ] \
        || [ "$m" = "bebafeca" ] || [ "$m" = "feedface" ] || [ "$m" = "feedfacf" ]
}

# 系统库豁免：Apple 自带，目标机必有，不入包。
# 注意：@ 前缀不可一刀切豁免——@rpath/<name> 是 Homebrew 表达传递依赖的
# 常规形态（rc4-8 实证漏收 libbrotlicommon），必须由引用方 LC_RPATH 解析。
is_system_dylib() {
    case "$1" in
        /usr/lib/*|/System/*|/Library/Apple/*) return 0 ;;
    esac
    return 1
}

# 已指向包内的引用（改写完成态），跳过收集
is_inpack_ref() {
    case "$1" in
        @executable_path/../lib/*) return 0 ;;
    esac
    return 1
}

# otool -l 提取 LC_RPATH 路径列表
rpaths_of() {
    otool -l "$1" 2>/dev/null \
        | awk '$1=="cmd"&&$2=="LC_RPATH"{f=1;next} f&&$1=="path"{print $2;f=0}'
}

# 解析 @rpath/<name>：按引用 Mach-O 的 LC_RPATH（展开 @loader_path/
# @executable_path 相对引用文件所在目录）逐条探测盘上文件，命中输出绝对路径
resolve_rpath_dep() {
    local ref="$1" dep="$2" n rp cand
    n="${dep#@rpath/}"
    while IFS= read -r rp; do
        [ -n "$rp" ] || continue
        case "$rp" in
            @loader_path/*)     cand="$(dirname "$ref")/${rp#@loader_path/}" ;;
            @loader_path)       cand="$(dirname "$ref")" ;;
            @executable_path/*) cand="$(dirname "$ref")/${rp#@executable_path/}" ;;
            @executable_path)   cand="$(dirname "$ref")" ;;
            *)                  cand="$rp" ;;
        esac
        cand="${cand%/}/$n"
        if [ -f "$cand" ]; then
            printf '%s\n' "$cand"
            return 0
        fi
    done < <(rpaths_of "$ref")
    return 1
}

# 收集一个 Mach-O 的全部依赖路径。otool -L 真实输出三段时间：第 1 行文件
# 路径行、第 2 行自身 LC_ID_DYLIB（非依赖），第 3 行起才是 LC_LOAD_* 依赖
# （rc4-9 教训：只跳 1 行会把 id 行误当依赖，lib/ 全体假性 FAIL）。
deps_of() {
    otool -L "$1" 2>/dev/null | tail -n +3 | awk '{print $1}'
}

declare -a QUEUE=()      # 待拷贝的绝对 dylib 路径
declare -a SEEN_LIBS=()  # 已入队 basename（bash 3.2 无关联数组，用线性表）

seen() {
    local s="$1" x
    for x in "${SEEN_LIBS[@]:-}"; do [ "$x" = "$s" ] && return 0; done
    return 1
}

# enqueue <依赖引用> <引用者路径>
# 引用形态三类：绝对路径（brew/其它）、@rpath/<name>（经引用者 LC_RPATH 解析
# 为绝对路径后入库）、@executable_path/../lib/*（已改写完成态，跳过）。
enqueue() {
    local ref="$1" by="$2" p n
    [ -n "$ref" ] || return 0
    is_system_dylib "$ref" && return 0
    is_inpack_ref "$ref" && return 0
    p="$ref"
    case "$ref" in
        @rpath/*)
            if ! p="$(resolve_rpath_dep "$by" "$ref")"; then
                echo "  warn: @rpath 依赖解析失败（LC_RPATH 未命中）: $ref (in $by)"
                return 0
            fi ;;
        @*)
            # @loader_path/@executable_path 等非 @rpath 相对引用：构建机上不
            # 可稳定解析为绝对路径。若 basename 已在库内则改写阶段可闭环；
            # 否则告警，交由 fail-closed 校验最终裁决。
            : ;;
    esac
    n="$(basename "$ref")"
    seen "$n" && return 0   # 同名已入队（防环/重复）
    if [ ! -f "$p" ]; then
        echo "  warn: 依赖不存在: $p (in $by)"
        return 0
    fi
    SEEN_LIBS+=("$n")
    QUEUE+=("$p")
}

collect_from() { # 展开某 Mach-O 的一层依赖并排队
    local f="$1" p
    while read -r p; do enqueue "$p" "$f"; done < <(deps_of "$f")
}

# ---- 1) BFS：从 bin/ 全部 Mach-O 收集并拷贝到 lib/ ----
for f in "$BIN_DIR"/*; do
    [ -f "$f" ] || continue
    is_macho "$f" || continue
    collect_from "$f"
done
i=0
while [ "$i" -lt "${#QUEUE[@]}" ]; do
    p="${QUEUE[$i]}"; i=$((i+1))
    n="$(basename "$p")"
    # 同名不同内容告警（同 prefix 树内通常一致；防静默错配）
    if [ -f "$LIB_DIR/$n" ] && ! cmp -s "$p" "$LIB_DIR/$n"; then
        echo "  warn: 同名 dylib 内容不一致（已保留首个）: $n"
        continue
    fi
    cp -f "$p" "$LIB_DIR/$n"
    # 该 dylib 自身的依赖也要展开（传递依赖）。必须以构建机原始路径解析：
    # @loader_path 类 LC_RPATH token 相对的是原始安装位置，包内拷贝的
    # dirname 已是 staging 目录，据其解析只会指错。
    collect_from "$p"
done
echo "dylib 收集完成: lib/ 共 $(ls "$LIB_DIR" | wc -l | tr -d ' ') 项（含 python/config 目录则合并计数）"

# ---- 2) 重写依赖路径到 @executable_path/../lib ----
# @executable_path 恒相对主可执行文件（bin/ 下），对 bin/ 与 lib/ 内嵌套依赖
# 均成立（dyld 以主可执行解析该变量）。
rewrite_macho() {
    local f="$1" p n rewrote=0
    while read -r p; do
        is_system_dylib "$p" && continue
        # 已指向包内（@executable_path/../lib/）则跳过
        case "$p" in @executable_path/../lib/*) continue ;; esac
        n="$(basename "$p")"
        if [ -f "$LIB_DIR/$n" ]; then
            install_name_tool -change "$p" "@executable_path/../lib/$n" "$f" 2>/dev/null \
                || { echo "  warn: install_name_tool 失败($f -> $n)"; }
            rewrote=1
        else
            echo "  warn: 依赖未入库（漏收集）: $p (in $f)"
        fi
    done < <(deps_of "$f")
    # 抹掉指向构建机的绝对 LC_RPATH：残留会让 @rpath 漏改写文件在打包机上
    # "侥幸可启"、干净机必崩（rc4-8 假绿通道）。删除后解析立即显式失败。
    while IFS= read -r rp; do
        case "$rp" in
            @executable_path/../lib/*|"") continue ;;
        esac
        install_name_tool -delete_rpath "$rp" "$f" 2>/dev/null || true
        rewrote=1
    done < <(rpaths_of "$f")
    [ "$rewrote" = "1" ] && codesign --force -s - "$f" >/dev/null 2>&1 || true
}

# 入库 dylib 的 LC_ID_DYLIB 必须与引用面同步改写：two-level namespace 下
# dyld 校验引用者 LC_LOAD_DYLIB 字符串与目标 dylib 的 id 一致，残留构建机
# 绝对路径会在干净机报 "library not loaded"（rc4-9）。
for f in "$BIN_DIR"/* "$LIB_DIR"/*.dylib; do
    [ -f "$f" ] || continue
    is_macho "$f" || continue
    case "$f" in
        "$LIB_DIR"/*.dylib)
            if install_name_tool -id "@executable_path/../lib/$(basename "$f")" "$f" 2>/dev/null; then
                codesign --force -s - "$f" >/dev/null 2>&1 || true
            else
                echo "  warn: install_name_tool -id 失败: $f"
            fi ;;
    esac
    rewrite_macho "$f"
done

# ---- 3) fail-closed 校验：无残留未解析非系统依赖（bin/ + lib/ 全量） ----
BAD=0
for f in "$BIN_DIR"/* "$LIB_DIR"/*.dylib; do
    [ -f "$f" ] || continue
    is_macho "$f" || continue
    while read -r p; do
        case "$p" in
            @executable_path/../lib/*) [ -f "$LIB_DIR/${p#@executable_path/../lib/}" ] || { echo "  FAIL: 包内缺 $p ($f)"; BAD=1; } ;;
            @rpath/*) echo "  FAIL: @rpath 依赖未改写入库: $p ($f)"; BAD=1 ;;
            @*) : ;;  # 其它 @loader_path/@executable_path 相对引用：dyld 语义自洽，放行
            *) is_system_dylib "$p" || { echo "  FAIL: 残留非系统依赖 $p ($f)"; BAD=1; } ;;
        esac
    done < <(deps_of "$f")
done
if [ "$BAD" = "1" ]; then
    echo "::error::macOS dylib 自包含校验失败，中止打包"
    exit 1
fi
echo "[OK] macOS dylib 自包含：全部非系统依赖已入库并重写 ($(ls "$LIB_DIR"/*.dylib 2>/dev/null | wc -l | tr -d ' ') 个)"
