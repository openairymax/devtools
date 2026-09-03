# pipeline/ — 流水线编排

`tools/scripts/ci/pipeline/`

## 概述

流水线编排子模块：`ci-run.sh` 是 CI 主入口，按序执行六个阶段——
环境准备 → 依赖安装 → 构建 → 测试 → 质量门禁 → 制品部署。
各阶段脚本位于 `build/`、`test/`、`deploy/` 子目录，既可组合编排也可独立运行。

## 目录结构

```
pipeline/
├── ci-run.sh                      # CI 主编排（6 阶段；--skip-* / --module / --type 可调）
├── build/                         # 构建
│   ├── build-module.sh            #   多模块并行/增量构建（--module/--type/--parallel/--clean）
│   ├── install-deps.sh            #   跨平台依赖安装（读取 requirements-*.txt）
│   ├── requirements-linux.txt     #   Linux apt 依赖清单
│   └── requirements-macos.txt     #   macOS Homebrew 依赖清单
├── test/                          # 测试
│   ├── run-tests.sh               #   CTest/pytest 双引擎测试执行
│   ├── run-connection-tests.sh    #   12 条连接线集成测试（L01-L12，--line/--all/--ci）
│   ├── test-integration.sh        #   集成测试环境启动与验证（--up/--down/--verify/--logs）
│   └── wait-for-it.sh             #   服务就绪等待工具（轮询 TCP/文件直到就绪）
└── deploy/                        # 部署
    ├── deploy-artifacts.sh        #   构建产物归档与部署（--output/--keep）
    └── db-migrate.sh              #   heapstore 数据库迁移
```

## 使用

```bash
# 完整流水线（依赖→构建→测试→质量→部署）
tools/scripts/ci/pipeline/ci-run.sh

# 跳过部分阶段 / 指定模块与构建类型
tools/scripts/ci/pipeline/ci-run.sh --skip-deploy --module all --type Debug

# 各阶段独立运行
tools/scripts/ci/pipeline/build/install-deps.sh
tools/scripts/ci/pipeline/build/build-module.sh -m daemons -t Release -j8
tools/scripts/ci/pipeline/test/run-tests.sh --module all
tools/scripts/ci/pipeline/deploy/deploy-artifacts.sh --output "$HOME/.airymaxrt/dist"
```

## 规范

- **BAN-33**：构建产物一律输出到源码区外（默认 `~/.airymaxrt-build/`），
  `CI_BUILD_DIR` 环境变量可覆盖；严禁在 `agent-workload/agentrt` 源码树内落盘。
- **依赖**：Bash 4.0+、CMake 3.20+、GCC/Clang、pytest。

---

© 2025-2026 SPHARX Ltd. All Rights Reserved.
