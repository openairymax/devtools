# 开发环境与辅助工具

`tools/scripts/dev/`

## 概述

`dev/` 目录包含 AgentRT 项目的开发环境搭建与辅助工具，涵盖环境配置（`setup/`）、
统一 CLI 入口（`cli/`）、CMake 辅助（`cmake/`）、文档生成（`docs/`）和开发辅助
工具集（`utils/`），是开发者日常使用的核心工具集。

> **版本**: v0.1.5
>
> **布局说明**：`dev/` 下不设独立构建目录（原 `build/` 目录已移除），构建统一由
> `ci/pipeline/build/` 承担；安装器 `install.sh` / `install.ps1` 已迁移至
> `agent-workload/agentrt/scripts/`，本仓 `tools/scripts/install/` 已移除。

## 目录结构

```
dev/
├── README.md                      # 本文档
├── setup/                         # 环境配置（2 个文件）
│   ├── setup.sh                   #   交互式开发环境配置（Linux/macOS）
│   └── setup.ps1                  #   开发环境配置（Windows PowerShell）
├── cli/                           # CLI 入口（1 个文件）
│   └── agentrt                    #   统一 CLI 命令行入口（Python 实现）
├── cmake/                         # CMake 辅助配置（5 个文件）
│   ├── Sanitizers.cmake           #   ASan/LSan/UBSan/TSan/栈保护/FORTIFY 配置
│   ├── AgentRTConfig.cmake.in     #   find_package(AgentRT) 打包配置模板
│   ├── agentrt_print.cmake        #   统一构建打印系统（时间戳 + ANSI 彩色）
│   ├── windows_preinclude.h       #   Windows MSVC 兼容性预包含头
│   └── ctest_wrapper.sh.in        #   sanitizer 环境变量下的 ctest 包装模板
├── docs/                          # 文档生成（1 个文件）
│   └── Doxyfile                   #   Doxygen 文档生成配置
└── utils/                         # 开发辅助工具
    ├── quickstart.sh              #   一键快速启动脚本
    ├── validate.sh                #   环境完整性验证脚本
    ├── run_all_fixes.sh           #   BAN 规则批量自动修复入口（编排 10 个修复脚本）
    ├── fixes/                     #   代码修复工具集（13 个 Python 脚本）
    │   ├── fix_agentrt_efail.py           #   替换 return AGENTRT_EFAIL 为具体错误码 + error_push_ex
    │   ├── fix_agentrt_efail_macro.py     #   替换 AGENTRT_CHECK/AGENTRT_ERROR 宏内 AGENTRT_EFAIL
    │   ├── fix_return_neg_N.py            #   修复 protocols/gateway 中 return -N 负返回值
    │   ├── fix_strncpy.py                 #   strncpy 安全修复
    │   ├── fix_sec22.py                   #   SEC-22：AGENTRT_FREE 后补 ptr = NULL
    │   ├── fix_error_handle.py            #   AGENTRT_ERROR_HANDLE + return 合并为 AGENTRT_ERROR
    │   ├── fix_error_push_ex_order.py     #   修复 airy_error_push_ex 参数顺序
    │   ├── fix_braces_and_codes.py        #   为 if 补大括号 + 修复错误码
    │   ├── fix_indent_and_codes.py        #   修复缩进 + 剩余错误码
    │   ├── fix_includes_and_braces.py     #   调整 #include 位置 + 补大括号
    │   ├── add_error_push_ex.py           #   为 protocol/gateway 补 error_push_ex 上下文
    │   ├── inject_error_push_ex.py        #   为 atoms/ 层注入 error_push_ex
    │   └── check_memory_compat.py         #   检查缺失 memory_compat.h 包含的文件
    └── archive/                   #   已完成的一次性脚本归档
        └── restructure_sdk.py     #   SDK 重构脚本（已完成）
```

## 使用方式

### 环境配置

```bash
# Linux/macOS 交互式环境配置（无参数进入菜单，或直接指定子任务）
scripts/dev/setup/setup.sh
scripts/dev/setup/setup.sh --deps      # 仅检查/安装依赖
scripts/dev/setup/setup.sh --build     # 仅构建（调用 ci/pipeline/build/build-module.sh Release）
scripts/dev/setup/setup.sh --test      # 仅运行测试
scripts/dev/setup/setup.sh --all       # 完整设置（依赖 + 构建 + 测试）

# Windows PowerShell（参数详见 setup.ps1 -Help）
.\scripts\dev\setup\setup.ps1 -BuildType Release -Clean -Test
```

### CLI 工具

```bash
# 查看帮助
scripts/dev/cli/agentrt --help

# 服务管理（list/health 已实现；start/stop/restart 已注册）
scripts/dev/cli/agentrt service list
scripts/dev/cli/agentrt service health

# 智能体管理（list 已实现；register 已注册）
scripts/dev/cli/agentrt agent list

# 任务管理（list 已实现；submit 已注册）
scripts/dev/cli/agentrt task list

# 协议 / 配置 / 数据库迁移
scripts/dev/cli/agentrt protocol list
scripts/dev/cli/agentrt config get <key>
scripts/dev/cli/agentrt db migrate --target v2
```

> CLI 通过 HTTP 调用 gateway：环境变量 `AGENTRT_ENDPOINT`（默认
> `http://localhost:18789`），需要鉴权时设置 `AGENTRT_API_KEY`。命令完整清单
> 与实现状态见 [cli/README.md](cli/README.md)。

### 快速启动与验证

```bash
# 一键快速启动（环境检查 → 依赖安装 → 构建 → 服务启动）
scripts/dev/utils/quickstart.sh

# 环境完整性验证（操作系统/Git/Python/CMake 等逐项检查）
scripts/dev/utils/validate.sh

# BAN 规则批量自动修复（--dry-run 演练 / --verbose 详细输出）
bash scripts/dev/utils/run_all_fixes.sh --dry-run
bash scripts/dev/utils/run_all_fixes.sh
```

### 单个修复脚本

```bash
# fixes/ 下脚本大多以伞仓根（airymaxhub/）为工作目录
python3 scripts/dev/utils/fixes/fix_sec22.py path/to/file.c
python3 scripts/dev/utils/fixes/fix_sec22.py --debug path/to/file.c   # 打印判断过程
python3 scripts/dev/utils/fixes/inject_error_push_ex.py <file.c>       # 注入到 atoms/ 层文件
```

### CMake 集成

```cmake
# Sanitizers（SEC-05/06/08/09 运行时检测，ASan/LSan/UBSan/TSan/栈保护/FORTIFY）
include(scripts/dev/cmake/Sanitizers.cmake)
enable_agentrt_sanitizers(TARGET my_target SCOPE PRIVATE)
```

## 依赖

| 子模块 | 核心依赖 | 说明 |
|--------|---------|------|
| `setup/setup.sh` | Bash 4.0+ | 复用 `ops/lib/` 下 log.sh/error.sh/platform.sh |
| `setup/setup.ps1` | PowerShell 5.1+ | Windows 10/11，依赖 CMake 与 Visual Studio 工具链 |
| `cli/agentrt` | Python 3.8+ | 纯 Python 实现，通过 HTTP 调用 gateway |
| `cmake/Sanitizers.cmake` | CMake 3.20+, GCC/Clang | MSVC 下自动禁用 sanitizers |
| `cmake/AgentRTConfig.cmake.in` | CMake 3.20+ | 由 configure_package_config_file() 生成 |
| `docs/Doxyfile` | Doxygen 1.9+ | 文档生成工具 |
| `utils/quickstart.sh` | Bash, CMake, Python 3.8+ | 快速启动依赖构建与运行时工具 |
| `utils/validate.sh` | Bash 4.0+ | 仅检查环境，不安装依赖 |
| `utils/run_all_fixes.sh` | Bash, Python 3.8+ | 编排 fixes/ 下的 Python 修复脚本 |
| `utils/fixes/*.py` | Python 3.8+ | 纯 Python 实现 |
| `utils/archive/restructure_sdk.py` | Python 3.8+ | 已完成的一次性脚本 |

---

© 2025-2026 SPHARX Ltd. All Rights Reserved.
