# 开发辅助工具

`tools/scripts/dev/utils/`

## 概述

`utils/` 目录提供 AgentRT 开发辅助工具：一键快速启动（`quickstart.sh`）、环境
完整性验证（`validate.sh`）、BAN 规则批量自动修复入口（`run_all_fixes.sh`）、
`fixes/` 代码修复工具集（13 个 Python 脚本）以及 `archive/` 已完成的一次性脚本
归档。修复类脚本以伞仓根（`airymaxhub/`）为工作目录。

> **版本**: v0.1.5

## 目录结构

```
utils/
├── quickstart.sh              # 一键快速启动：环境检查 → 依赖安装 → 构建 → 服务启动
├── validate.sh                # 环境完整性验证：操作系统/Git/Python/CMake 等逐项检查
├── run_all_fixes.sh           # BAN 规则批量自动修复入口（--dry-run/--verbose），编排 10 个修复脚本
├── fixes/                     # 代码修复工具集（13 个 Python 脚本）
│   ├── fix_agentrt_efail.py           # 替换 return AGENTRT_EFAIL 为具体 AGENTRT_ERR_* + agentrt_error_push_ex
│   ├── fix_agentrt_efail_macro.py     # 替换 AGENTRT_CHECK/AGENTRT_ERROR 宏内 AGENTRT_EFAIL 为具体错误码
│   ├── fix_return_neg_N.py            # 修复 protocols/ 和 gateway/ 中 return -N 负返回值模式
│   ├── fix_strncpy.py                 # 将不安全 strncpy 调用替换为安全写法
│   ├── fix_sec22.py                   # SEC-22：AGENTRT_FREE(ptr) 后补 ptr = NULL（支持 --debug）
│   ├── fix_error_handle.py            # 将 AGENTRT_ERROR_HANDLE(code,msg); return code; 合并为 AGENTRT_ERROR
│   ├── fix_error_push_ex_order.py     # 修复 airy_error_push_ex 参数顺序
│   ├── fix_braces_and_codes.py        # 为含 error_push + return 的 if 补大括号 + 修复错误码
│   ├── fix_indent_and_codes.py        # 修复新增大括号内缩进 + 剩余错误码
│   ├── fix_includes_and_braces.py     # 将 #include error.h 移至顶部 + 为 misleading-indentation 补大括号
│   ├── add_error_push_ex.py           # 为 protocol/gateway 文件补 error_push_ex 上下文传播
│   ├── inject_error_push_ex.py        # 为 atoms/ 层文件注入 error_push_ex 上下文追踪
│   └── check_memory_compat.py         # 扫描使用 AGENTRT 内存宏但缺失 memory_compat.h 包含的文件
└── archive/                   # 已完成的一次性脚本归档
    └── restructure_sdk.py     # AgentRT Python SDK 重构脚本（已完成，仅供历史查阅）
```

## 使用方式

### 快速启动与验证

```bash
# 一键快速启动（环境检查 → 依赖安装 → 构建 → 服务启动）
scripts/dev/utils/quickstart.sh

# 环境完整性验证（逐项检查并汇总 PASS/FAIL/WARN）
scripts/dev/utils/validate.sh
```

### BAN 规则批量修复

```bash
# 演练模式：仅展示将执行的修复，不做改动
bash scripts/dev/utils/run_all_fixes.sh --dry-run

# 详细输出
bash scripts/dev/utils/run_all_fixes.sh --verbose

# 实际执行（按依赖顺序运行 fixes/ 下 10 个自动修复脚本）
bash scripts/dev/utils/run_all_fixes.sh
```

> 编排顺序：fix_agentrt_efail → fix_agentrt_efail_macro → fix_return_neg_N →
> fix_strncpy → fix_sec22 → fix_error_handle → fix_error_push_ex_order →
> fix_braces_and_codes → fix_indent_and_codes → fix_includes_and_braces。
> 修复完成后建议运行 `scripts/ci/quality/gates/quality-gate.sh` 验证。
> `add_error_push_ex.py`、`inject_error_push_ex.py`、`check_memory_compat.py`
> 不在批量编排内，需按需单独调用。

### 单个修复脚本

```bash
# SEC-22 修复：AGENTRT_FREE 后补 ptr = NULL（--debug 打印判断过程）
python3 scripts/dev/utils/fixes/fix_sec22.py path/to/file.c
python3 scripts/dev/utils/fixes/fix_sec22.py --debug path/to/file.c

# 为 atoms/ 层文件注入 error_push_ex
python3 scripts/dev/utils/fixes/inject_error_push_ex.py <file.c>

# 扫描缺失 memory_compat.h 包含的文件
python3 scripts/dev/utils/fixes/check_memory_compat.py
```

## 依赖

| 文件 | 核心依赖 | 说明 |
|------|---------|------|
| `quickstart.sh` | Bash, CMake, Python 3.8+, Git | 快速启动依赖构建与运行时全部工具 |
| `validate.sh` | Bash 4.0+ | 仅检查环境，不安装任何依赖 |
| `run_all_fixes.sh` | Bash, Python 3.8+ | 编排 fixes/ 下 Python 修复脚本 |
| `fixes/*.py` | Python 3.8+ | 纯 Python 实现 |
| `archive/restructure_sdk.py` | Python 3.8+ | 已完成的一次性脚本，仅作历史查阅 |

---

© 2025-2026 SPHARX Ltd. All Rights Reserved.
