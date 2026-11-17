#!/bin/bash
# Gate 48 测试债反查（0.1.21 L-12 / §16.20.6 R6）
#
# 判据：头文件声明的每个 `airy_*` 导出符号必须被测试树引用；新增符号
#   （AIRY_COMMIT_BASE 起的头文件新增行）若无任何测试引用即强红。
#
# 口径实现在 src/test_debt.py（唯一定义），本脚本只负责定位仓库与
#   组装参数——门禁里再抄一遍解析逻辑就必然出现两套判定。
#
# 未设 AIRY_COMMIT_BASE 时只出账（报告模式），供台账更新与本地自查。
# 用法: g48-test-debt.sh [--report]
# 环境变量: AIRY_COMMIT_BASE / G48_ROOT / G48_REPO
# 退出码: 0 = 通过/仅报告；1 = 新增符号无测试引用；2 = 环境错误
set -uo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="${G48_ROOT:-$(cd "${SCRIPT_DIR}/../../../../.." && pwd)}"
REPO="${G48_REPO:-${ROOT}/agent-workload/agentrt}"
PY="${SCRIPT_DIR}/../src/test_debt.py"

[ -r "$PY" ] || { echo "g48: 反查实现缺失：${PY}" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "g48: 需要 python3" >&2; exit 2; }
[ -d "$REPO" ] || { echo "g48: 仓库不存在：${REPO}" >&2; exit 2; }

BASE="${AIRY_COMMIT_BASE:-}"
if [ "${1:-}" = --report ] || [ -z "$BASE" ]; then
    python3 "$PY" --root "$REPO"
    exit $?
fi

python3 "$PY" --root "$REPO" --check --base "$BASE"
