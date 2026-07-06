# Airymax DevTools — Development Tools & Configuration Center

> Unified development tools and configuration center for the Airymax project.

**Language:** English | [简体中文](README_zh.md)

[![Version](https://img.shields.io/badge/version-0.1.1-5a6b7e)](https://atomgit.com/openairymax/devtools)
[![License](https://img.shields.io/badge/license-AGPL--3.0+Apache--2.0-4a90d9)](LICENSE)

---

## Overview

DevTools is one of the 3 top-level repositories in the Airymax 38-repository split (alongside docs and docs-closed). It centralizes shared development tool configurations, coding standards, and build toolchains used across the entire project. All 38 repositories reference the configuration files here, ensuring consistent code style and quality standards across repos.

This repository contains no executable code — only configuration files and toolchain definitions, consumed by other repositories via git submodule.

## Repository Position

```
airymaxhub/                     ← Umbrella repo
├── agentrt/                    ← Management repo (7 leaf repos)
├── sdk/                        ← Management repo (6 leaf repos)
├── ecosystem/                  ← Management repo (5 leaf repos)
├── products/                   ← Management repo (3 leaf repos)
├── agentrt-linux/              ← Management repo (8 leaf repos, AirymaxOS)
├── devtools/                   ← THIS REPO (top-level)
├── docs/                       ← Top-level (open documentation)
├── docs-closed/                ← Top-level (internal documentation)
└── cmake/                      ← Umbrella-direct CMake modules
```

## Directory Structure

```
devtools/
├── .clang-format              # C/C++ formatting rules (LLVM style, 100 col, 4-space indent)
├── .clang-tidy                # C/C++ static analysis rules (bugprone/performance/readability)
├── .clangd                    # clangd language server configuration
├── .git-blame-ignore-revs     # Revisions ignored by git blame (formatting commits, etc.)
├── .pre-commit-config.yaml    # Pre-commit hooks (formatting, lint, large files, branch naming)
├── pyproject.toml             # Python project config (ruff/mypy/black)
├── vcpkg.json                 # vcpkg C++ dependency manifest (libuv/json-c/libyaml, etc.)
├── deploy/                    # Deployment configs (Docker/Kubernetes)
├── scripts/                   # Development & ops scripts
│   ├── ci/                    # CI pipeline scripts
│   ├── dev/                   # Development tool scripts
│   └── ops/                   # Operations scripts
├── tests/                     # Cross-repo test suites
│   ├── unit/                  # Unit tests
│   ├── integration/           # Integration tests
│   ├── contract/              # Contract tests
│   ├── security/              # Security tests
│   └── benchmarks/            # Performance benchmarks
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

Each repository references devtools configs via the `devtools/` submodule path:

```bash
# CMake referencing clang-format
set(CLANG_FORMAT_CONFIG ${CMAKE_SOURCE_DIR}/../devtools/.clang-format)

# pre-commit installation
cp devtools/.pre-commit-config.yaml .pre-commit-config.yaml
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
| **Downstream** | All 38 repos reference devtools configs via submodule |

## Repository Information

- **Repository URL**: `git@atomgit.com:openairymax/devtools.git`
- **Organization**: openairymax
- **Branch Strategy**: `main` only
- **License**: AGPL v3 + Apache 2.0 dual license

---

Copyright (c) 2025-2026 SPHARX Ltd. All Rights Reserved.
"From data intelligence emerges."

SPDX-License-Identifier: AGPL-3.0-or-later OR Apache-2.0
