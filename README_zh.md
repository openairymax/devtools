# Airymax DevTools — 开发工具与配置中心

> Airymax 项目统一开发工具与配置中心

**语言:** [English](README.md) | 简体中文

[![Version](https://img.shields.io/badge/version-0.1.1-5a6b7e)](https://atomgit.com/openairymax/devtools)
[![License](https://img.shields.io/badge/license-AGPL--3.0+Apache--2.0-4a90d9)](LICENSE)

---

## 概述

DevTools 是 Airymax 38 仓拆分方案中的 3 个顶层仓之一（另两个为 docs 和 docs-closed），集中管理全项目共用的开发工具配置、代码规范和构建工具链。所有 38 仓共享此处的配置文件，确保跨仓库一致的代码风格和质量标准。

本仓库不包含可执行代码，仅提供配置文件和工具链定义，通过 git submodule 方式被其他仓库引用。

## 仓库定位

```
airymaxhub/                     ← 伞仓
├── agentrt/                    ← 管理仓（7 叶子仓）
├── sdk/                        ← 管理仓（6 叶子仓）
├── ecosystem/                  ← 管理仓（5 叶子仓）
├── products/                   ← 管理仓（3 叶子仓）
├── agentrt-linux/              ← 管理仓（8 叶子仓，AirymaxOS）
├── devtools/                   ← 本仓库（顶层仓）
├── docs/                       ← 顶层仓（开放文档）
├── docs-closed/                ← 顶层仓（内部文档）
└── cmake/                      ← 伞仓直属 CMake 模块
```

## 目录结构

```
devtools/
├── .clang-format              # C/C++ 代码格式化规则（LLVM 风格，列宽 100，4 空格缩进）
├── .clang-tidy                # C/C++ 静态分析规则（bugprone/performance/readability）
├── .clangd                    # clangd 语言服务器配置
├── .git-blame-ignore-revs     # git blame 忽略的修订（格式化提交等）
├── .pre-commit-config.yaml    # pre-commit 钩子配置（格式化、lint、大文件、分支命名）
├── pyproject.toml             # Python 项目配置（ruff/mypy/black）
├── vcpkg.json                 # vcpkg C++ 依赖清单（libuv/json-c/libyaml 等）
├── deploy/                    # 部署配置（Docker/Kubernetes）
├── scripts/                   # 开发与运维脚本
│   ├── ci/                    # CI 流水线脚本
│   ├── dev/                   # 开发工具脚本
│   └── ops/                   # 运维操作脚本
├── tests/                     # 跨仓测试套件
│   ├── unit/                  # 单元测试
│   ├── integration/           # 集成测试
│   ├── contract/              # 契约测试
│   ├── security/              # 安全测试
│   └── benchmarks/            # 性能基准测试
├── LICENSE                    # AGPL v3 + Apache 2.0 双许可证
└── NOTICE                     # 版权与商标声明
```

## 配置文件说明

### C/C++ 工具链

| 文件 | 用途 |
|------|------|
| `.clang-format` | 基于 LLVM 风格的代码格式化，列宽 100，4 空格缩进 |
| `.clang-tidy` | 静态分析检查：bugprone-*、performance-*、readability-* |
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

各仓库通过 `devtools/` submodule 路径引用配置文件：

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

## 上下游关系

| 方向 | 关系 |
|------|------|
| **上游** | 无（顶层仓，不依赖其他 Airymax 仓库） |
| **下游** | 所有 38 仓均通过 submodule 引用 devtools 配置 |

## 仓库信息

- **仓库 URL**: `git@atomgit.com:openairymax/devtools.git`
- **归属组织**: openairymax
- **分支策略**: 仅 `main` 分支
- **许可证**: AGPL v3 + Apache 2.0 双许可证

---

Copyright (c) 2025-2026 SPHARX Ltd. All Rights Reserved.
"From data intelligence emerges."

SPDX-License-Identifier: AGPL-3.0-or-later OR Apache-2.0
