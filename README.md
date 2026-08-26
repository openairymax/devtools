# Airymax Tools — Development Tools & Configuration Center

> Unified development tools and configuration center for the Airymax project.

**Language:** English | [简体中文](README_zh.md)

[![Version](https://img.shields.io/badge/version-0.1.1-5a6b7e)](https://atomgit.com/openairymax/tools)
[![License](https://img.shields.io/badge/license-AGPL--3.0+Apache--2.0-4a90d9)](LICENSE)

---

## Overview

Tools is one of the 4 top-level repositories in the Airymax 38-repository split (alongside docs, closed-docs and closed-dev-build; renamed from devtools in v0.1.4). It centralizes shared development tool configurations, coding standards, and build toolchains used across the entire project. All 38 repositories reference the configuration files here, ensuring consistent code style and quality standards across repos.

This repository contains shared tooling — CI/CD pipelines, development/ops scripts,
Python toolkit, deployment configs and cross-repo test suites — consumed by other
repositories via git submodule.

## Repository Position

```
airymaxhub/                     ← Umbrella repo
├── agent-workload/             ← user-space engineering super-repo (v0.1.3, renamed from agent-runtim in v0.1.4)
│   ├── agentrt/                ← Management repo (7 leaf repos; owns cmake/ build modules and scripts/ installer)
│   ├── sdk/                    ← Management repo (6 leaf repos)
│   ├── ecosystem/              ← Management repo (6 leaf repos)
│   └── products/               ← Management repo (3 leaf repos)
├── agent-linux/                ← kernel-space engineering super-repo (8 leaf repos, AirymaxOS; formerly agentrt-linux, renamed v0.1.3)
├── tools/                      ← THIS REPO (top-level, renamed from devtools in v0.1.4)
├── docs/                       ← Top-level (open documentation)
├── closed-docs/                ← Top-level (internal documentation)
└── closed-dev-build/           ← Top-level (internal build/deploy)
```
> Umbrella-direct `cmake/` and `scripts/` moved into the agentrt management repo since v0.1.2 (IRON-9 [IND] fully independent layer); the umbrella root holds no direct source directories.

## Directory Structure

```
tools/
├── .clang-format              # C/C++ formatting rules (LLVM style, 100 col, 4-space indent)
├── .clang-tidy                # C/C++ static analysis rules (bugprone/performance/readability)
├── .clangd                    # clangd language server configuration
├── .git-blame-ignore-revs     # Revisions ignored by git blame (formatting commits, etc.)
├── .pre-commit-config.yaml    # Pre-commit hooks (formatting, lint, large files, branch naming)
├── pyproject.toml             # Python project config (ruff/mypy/black)
├── vcpkg.json                 # vcpkg C++ dependency manifest (libuv/json-c/libyaml, etc.)
├── deploy/                    # Deployment configs（docker / kubernetes / systemd）
├── scripts/                   # Development & ops scripts
│   ├── ci/                    # CI/CD（pipeline 编排 / quality 质量 / verify 安全 / release 发布）
│   ├── dev/                   # Development tool scripts（setup/cmake/cli/utils/docs）
│   ├── ops/                   # Operations scripts（bin 编排 / lib 公共库 / tests / deploy / benchmark）
│   ├── resources/             # 演示脚本与教程资源（demos / tutorial / images）
│   └── toolkit/               # Python 运维工具包（src/ 15 模块）
├── tests/                     # Cross-repo test suites
│   ├── unit/                  # Unit tests（manager / cupolas / scripts）
│   ├── integration/           # Integration tests（python / c / coreloopthree / syscall / memoryrovol / platform / commons / cupolas）
│   ├── contract/              # Contract tests
│   ├── security/              # Security tests（python / c / cupolas）
│   ├── benchmarks/            # Performance benchmarks（python / c / atoms / cupolas）
│   └── utils/                 # Test utilities（fixtures / templates）
├── LICENSE                    # AGPL v3 + Apache 2.0 dual license
└── NOTICE                     # Copyright and trademark notice
```

## Configuration Files

### C/C++ Toolchain

| File | Purpose |
|------|---------|
| `.clang-format` | LLVM-based code formatting, 100-column width, 4-space indent |
| `.clang-tidy` | Static analysis checks: bugprone-*, performance-*, readability-* |
| `.clangd` | clangd config specifying compile options and include paths |

### Python Toolchain

| File | Purpose |
|------|---------|
| `pyproject.toml` | ruff (lint + format), mypy (type checking) configuration |

### Git Toolchain

| File | Purpose |
|------|---------|
| `.git-blame-ignore-revs` | Ignores pure formatting commits so `git blame` focuses on logic |
| `.pre-commit-config.yaml` | Pre-commit auto-checks: formatting, lint, large files, branch naming |

### C++ Dependency Management

| File | Purpose |
|------|---------|
| `vcpkg.json` | vcpkg dependency manifest (libuv/json-c/libyaml, etc.) |

## Usage

### Referencing from Other Repositories

Each repository references tools configs via the `tools/` submodule path:

```bash
# CMake referencing clang-format
set(CLANG_FORMAT_CONFIG ${CMAKE_SOURCE_DIR}/../tools/.clang-format)

# pre-commit installation
cp tools/.pre-commit-config.yaml .pre-commit-config.yaml
pre-commit install
```

### Local Development Environment Setup

```bash
# 1. Install clangd (recommended for VS Code / Neovim)
sudo apt install clangd-15

# 2. Install pre-commit
pip install pre-commit
pre-commit install

# 3. Install vcpkg (C++ dependencies)
git clone https://github.com/microsoft/vcpkg.git
./vcpkg/bootstrap-vcpkg.sh
```

## Upstream / Downstream

| Direction | Relationship |
|-----------|-------------|
| **Upstream** | None (top-level repo, no Airymax dependencies) |
| **Downstream** | All 38 repos reference tools configs via submodule |

## Repository Information

- **Repository URL**: `git@atomgit.com:openairymax/tools.git`
- **Organization**: openairymax
- **Branch Strategy**: `main` only
- **License**: AGPL v3 + Apache 2.0 dual license

---

Copyright (c) 2025-2026 SPHARX Ltd. All Rights Reserved.
"From data intelligence emerges."

SPDX-License-Identifier: AGPL-3.0-or-later OR Apache-2.0
