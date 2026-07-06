# Airymax DevTools

> Airymax 项目统一开发工具与配置中心

## 概述

DevTools 仓库集中管理 Airymax 全项目共用的开发工具配置、代码规范和构建工具链。所有 29 仓共享此处的配置文件，确保跨仓库一致的代码风格和质量标准。

## 目录结构

```
devtools/
├── .clang-format          # C/C++ 代码格式化规则
├── .clang-tidy            # C/C++ 静态分析规则
├── .clangd                # clangd 语言服务器配置
├── .git-blame-ignore-revs # git blame 忽略的修订（格式化等）
├── .pre-commit-config.yaml # pre-commit 钩子配置
├── pyproject.toml         # Python 项目配置（ruff/mypy/black）
├── vcpkg.json             # vcpkg C++ 依赖清单
├── LICENSE                # AGPL v3 + Apache 2.0 双许可证
└── NOTICE                 # 版权与商标声明
```

## 配置文件说明

### C/C++ 工具链

| 文件 | 用途 |
|------|------|
| `.clang-format` | 基于 LLVM 风格的代码格式化，列宽 100，4 空格缩进 |
| `.clang-tidy` | 静态分析检查：bugprone-*, performance-*, readability-* |
| `.clangd` | clangd 配置，指定编译选项和头文件搜索路径 |

### Python 工具链

| 文件 | 用途 |
|------|------|
| `pyproject.toml` | ruff（lint + format）、mypy（类型检查）配置 |

### Git 工具链

| 文件 | 用途 |
|------|------|
| `.git-blame-ignore-revs` | 忽略纯格式化提交，使 `git blame` 聚焦逻辑变更 |
| `.pre-commit-config.yaml` | 提交前自动检查：格式化、lint、大文件、分支命名 |

### C++ 依赖管理

| 文件 | 用途 |
|------|------|
| `vcpkg.json` | vcpkg 依赖清单（libuv/json-c/libyaml 等） |

## 使用方式

### 在各仓库中引用

各仓库的 `.gitignore` 应忽略这些文件，构建系统通过 `devtools/` submodule 路径引用：

```bash
# CMake 引用 clang-format
set(CLANG_FORMAT_CONFIG ${CMAKE_SOURCE_DIR}/../devtools/.clang-format)

# pre-commit 安装
cp devtools/.pre-commit-config.yaml .pre-commit-config.yaml
pre-commit install
```

### 本地开发环境搭建

```bash
# 1. 安装 clangd（VS Code / Neovim 推荐）
sudo apt install clangd-15

# 2. 安装 pre-commit
pip install pre-commit
pre-commit install

# 3. 安装 vcpkg（C++ 依赖）
git clone https://github.com/microsoft/vcpkg.git
./vcpkg/bootstrap-vcpkg.sh
```

## 仓库信息

- **仓库 URL**: `git@atomgit.com:openairymax/devtools.git`
- **归属组织**: openairymax
- **分支策略**: 仅 `main` 分支
- **许可证**: AGPL v3 + Apache 2.0 双许可证

Copyright (c) 2025-2026 SPHARX Ltd. All Rights Reserved.
SPDX-License-Identifier: AGPL-3.0-or-later OR Apache-2.0
