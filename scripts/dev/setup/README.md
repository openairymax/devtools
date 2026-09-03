# 环境配置

`tools/scripts/dev/setup/`

## 概述

`setup/` 目录提供 AgentRT 开发环境的交互式配置脚本：`setup.sh`（Linux/macOS）
与 `setup.ps1`（Windows PowerShell）。脚本自动检测系统环境、检查依赖工具链，
并可调用 CI 流水线完成构建与测试。`setup.sh` 复用 `ops/lib/` 下的日志、错误码
与平台检测公共库。

> **版本**: v0.1.5

## 目录结构

```
setup/
├── setup.sh     # 交互式开发环境配置（Linux/macOS）：菜单或 --deps/--build/--test/--all 参数
└── setup.ps1    # 开发环境配置（Windows PowerShell）：-BuildType/-Generator/-SkipDeps/-Clean/-Test
```

## 使用方式

### Linux/macOS（setup.sh）

```bash
# 无参数进入交互式菜单（1 依赖 / 2 构建 / 3 测试 / 4 完整 / 5 退出）
scripts/dev/setup/setup.sh

# 直接指定子任务（等价于菜单选项 1-4）
scripts/dev/setup/setup.sh --deps      # 检查/安装依赖（vcpkg、Python 等）
scripts/dev/setup/setup.sh --build     # 构建 AgentRT（调用 ci/pipeline/build/build-module.sh Release）
scripts/dev/setup/setup.sh --test      # 运行测试（优先 ops/tests/shell/test_framework.sh）
scripts/dev/setup/setup.sh --all       # 完整设置：依赖 + 构建 + 测试
scripts/dev/setup/setup.sh --help      # 显示菜单与用法
```

> Windows 平台请使用 `setup.ps1`，`setup.sh` 在 Windows 下会提示改用 PowerShell 脚本。

### Windows（setup.ps1）

```powershell
.\scripts\dev\setup\setup.ps1                            # 默认 Debug 构建
.\scripts\dev\setup\setup.ps1 -BuildType Release         # Release 构建
.\scripts\dev\setup\setup.ps1 -Generator "Ninja"         # 指定 CMake 生成器
.\scripts\dev\setup\setup.ps1 -SkipDeps -Clean -Test     # 跳过依赖、清理后构建并测试
.\scripts\dev\setup\setup.ps1 -Help                      # 查看全部参数
```

| 参数 | 说明 | 默认值 |
|------|------|--------|
| `-Help` | 显示帮助 | - |
| `-BuildType` | 构建类型（Debug/Release/RelWithDebInfo） | `Debug` |
| `-Generator` | CMake 生成器 | `Visual Studio 17 2022` |
| `-SkipDeps` | 跳过依赖安装 | 关 |
| `-Clean` | 构建前清理构建目录 | 关 |
| `-Test` | 构建后运行测试 | 关 |

## 依赖

| 文件 | 核心依赖 | 说明 |
|------|---------|------|
| `setup.sh` | Bash 4.0+ | 加载 `ops/lib/` 下 log.sh/error.sh/platform.sh |
| `setup.ps1` | PowerShell 5.1+ | Windows 10/11，依赖 CMake 与 Visual Studio 工具链 |

---

© 2025-2026 SPHARX Ltd. All Rights Reserved.
