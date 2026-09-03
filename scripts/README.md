# 脚本工具集

`scripts/`

## 概述

AgentRT 脚本工具集是项目全生命周期管理的核心基础设施，涵盖 CI/CD 流水线、开发环境搭建、运维部署、性能基准测试、Python 运维工具包和项目资源等六大领域。所有脚本按职能分类存放于五个子模块中，与 `agentrt/` 核心模块紧密对应，形成从代码提交到生产部署的完整自动化链路。

脚本工具集遵循以下设计原则：

- **BAN-33 规则**：所有构建脚本禁止源内构建，构建产物必须输出到独立构建目录中
- **跨平台兼容**：核心脚本同时支持 Linux、macOS 和 Windows（PowerShell）三大平台
- **模块化编排**：每个子模块职责单一、接口清晰，可独立运行也可组合编排
- **安全优先**：集成安全扫描、编码修复、桩函数检测等多层安全保障

> **版本**: v0.1.5
>
> **规范**：所有构建脚本遵循 BAN-33 规则（禁止源内构建），构建产物必须输出到独立构建目录中。

## 与 agentrt/ 模块对应关系

| scripts/ 模块 | 对应的 agentrt/ 模块 | 用途 |
|---------------|---------------------|------|
| `ci/pipeline/` | `atoms/`, `commons/`, `cupolas/`, `daemons/`, `gateway/`, `heapstore/` | 流水线编排（`pipeline/{build,test,deploy}/` 构建→测试→部署） |
| `ci/quality/` | 全部模块 | 质量门禁与分析（`quality/{src,gates}/`，六语言统一分析） |
| `ci/verify/` | `toolkit/` | 构建验证与安全扫描（SDK 验证/构建模式/`security/` 安全扫描） |
| `ci/release/` | 全部模块 | 发布管理（质量门禁→打 tag→打包→双轨签名→上传） |
| `dev/setup/` | 全部模块 | 交互式开发环境配置（依赖安装、工具链设置） |
| `dev/cli/` | `daemons/`, `manager/`, `openlab/` | 统一 CLI 入口（service/agent/task/protocol/config 等子命令） |
| `dev/cmake/` | `atoms/`, `commons/`, `cupolas/` | CMake 辅助（Sanitizers/打包配置/构建打印/预包含头/ctest 包装） |
| `dev/docs/` | 全部模块 | Doxygen 文档生成配置 |
| `dev/utils/` | 全部模块 | 快速启动/环境验证/BAN 规则批量修复/代码修复工具集 |
| `ops/bin/` | `daemons/`, `gateway/` | 运维入口脚本（daemon 一键启动/示例项目快速创建） |
| `ops/deploy/` | `daemons/`, `gateway/` | Docker 容器化部署（gateway_d, llm_d, sched_d, heapstore, monit_d 等） |
| `ops/benchmark/` | `atoms/coreloopthree/`, `atoms/corekern/` | 性能基准测试覆盖核心内核组件 |
| `ops/lib/` | 全部模块 | Shell 脚本公共库（日志/错误码/平台检测） |
| `ops/tests/` | `daemons/`, `cupolas/`, `manager/` | 运维集成测试（核心/检查点/记忆/Token/安全/遥测） |
| `toolkit/` | `commons/`, `daemons/`, `manager/` | Python 运维工具集（诊断/记忆/Token/契约/CLI/插件/遥测） |
| `resources/demos/` | 全部模块 | 技术演示（服务框架/基准测试/工具链/开源治理） |
| `resources/tutorial/` | `openlab/` | 交互式教程引擎与新贡献者引导 |

> **注**：`dev/` 下无 `build/` 目录（该目录此前存放的构建与安装脚本已移除），
> 构建统一由 `ci/pipeline/build/` 承担，安装器位置见下文「安装器位置」。

## 目录结构

```
scripts/
├── .editorconfig                  # 编辑器配置统一规范
├── README.md                      # 本文档
├── ci/                            # CI/CD 流水线与质量工具（四域：pipeline/quality/verify/release）
│   ├── pipeline/                  #   流水线编排（build/ 构建、test/ 测试、deploy/ 部署）
│   ├── quality/                   #   质量门禁与分析（src/ 分析器、gates/ 门禁）
│   ├── verify/                    #   构建验证与安全扫描（security/ 安全扫描）
│   └── release/                   #   发布管理（一键发布/打包/签名/构建清理）
├── dev/                           # 开发环境工具（无 build/，构建统一走 ci/pipeline/build）
│   ├── setup/                     #   环境配置（交互式安装，Linux/macOS/Windows）
│   ├── cli/                       #   CLI 入口（agentrt 统一命令行工具，Python 实现）
│   ├── cmake/                     #   CMake 辅助（Sanitizers/打包配置/构建打印/预包含头/ctest 包装）
│   ├── docs/                      #   文档生成（Doxygen 配置）
│   └── utils/                     #   开发辅助（快速启动/环境验证/批量修复/代码修复工具集）
├── ops/                           # 运维部署与测试
│   ├── bin/                       #   运维入口脚本（daemon 启动/示例项目快速创建）
│   ├── deploy/                    #   Docker 部署（双 Dockerfile + 四环境 Compose 编排）
│   ├── benchmark/                 #   性能基准测试框架（统计引擎/报告生成/历史对比）
│   ├── lib/                       #   Shell 公共库（日志/错误码/平台检测/通用工具）
│   └── tests/                     #   运维测试套件（Python pytest + Shell bats-core）
├── toolkit/                       # Python 运维工具包
│   ├── __init__.py                #   包入口（统一导出所有工具类）
│   └── src/                       #   CLI/诊断/性能/记忆/Token/安全/插件/遥测等 15 个模块
└── resources/                     # 项目资源
    ├── demos/                     #   技术演示脚本（Phase 3 技术栈展示）
    ├── images/                    #   静态资源图片（桌面预览/社区二维码）
    └── tutorial/                  #   交互式教程引擎与新贡献者引导配置
```

## 核心组件说明

### ci/ — CI/CD 流水线与质量工具

持续集成与交付的核心模块，v0.1.5 重组为四个职责单一的域：

- **pipeline/**：流水线编排，内含 `build/`（依赖安装、多模块并行/增量构建）、`test/`（CTest/pytest 双引擎测试、连接线集成测试）、`deploy/`（产物归档部署、数据库迁移）三个子目录，`ci-run.sh` 为 CI 主入口。
- **quality/**：质量门禁与分析，`src/` 为分析器（`unified_quality_analyzer.py` 六语言统一分析、`fix_encoding.py` 编码修复、YAML 检查等），`gates/` 为质量门禁（编译/BAN/安全/合约/跨仓/复杂度）。
- **verify/**：构建验证与安全扫描，覆盖 SDK 三平台构建验证（Linux/macOS/Windows）、MemoryRovol 构建模式测试，以及 `security/` 下的 10 项综合安全扫描、SEC-017 桩函数检测、禁止函数检测和动态 memcpy 检查。
- **release/**：发布管理，支持质量门禁 → 打 tag → 完全体打包 → 双轨签名（cosign + GPG）→ 上传发布。

### dev/ — 开发环境与构建工具

开发者的日常工具集，覆盖环境搭建、CLI 与构建辅助（`dev/` 下不设独立构建目录，构建统一由 `ci/pipeline/build/` 承担）：

- **setup/**：交互式开发环境配置，`setup.sh`（Linux/macOS，支持 `--deps`/`--build`/`--test`/`--all` 参数）与 `setup.ps1`（Windows，支持 `-BuildType`/`-Generator`/`-SkipDeps`/`-Clean`/`-Test` 参数）。
- **cli/agentrt**：统一 CLI 命令行入口（Python 实现），提供服务（service）、智能体（agent）、任务（task）、协议（protocol）、配置（config）、监控（monitor）、开发（dev）、数据库迁移（db）等子命令。
- **cmake/**：CMake 辅助配置，包含 `Sanitizers.cmake`（ASan/LSan/UBSan/TSan/栈保护/FORTIFY）、`AgentRTConfig.cmake.in`（find_package 打包配置）、`agentrt_print.cmake`（统一构建打印系统）、`windows_preinclude.h`（MSVC 兼容性预包含头）和 `ctest_wrapper.sh.in`（sanitizer 环境下的 ctest 包装模板）。
- **docs/Doxyfile**：Doxygen 文档生成配置文件，用于从源码注释自动生成 API 参考文档。
- **utils/**：开发辅助工具，包含快速启动脚本（`quickstart.sh`）、环境完整性验证（`validate.sh`）、BAN 规则批量修复入口（`run_all_fixes.sh`，编排 `fixes/` 下 10 个自动修复脚本）、`fixes/` 代码修复工具集和 `archive/` 一次性脚本归档。

### ops/ — 运维部署与测试

生产环境运维的核心模块：

- **bin/**：运维入口脚本，包含 `agentrt-bootstrap.sh`（按 DAG 层级一键启动所有 daemon）和 `quickstart.sh`（5 分钟创建示例 Agent 项目）。
- **deploy/**：Docker 容器化部署方案，采用双 Dockerfile 分层架构（内核基础镜像 + 服务层镜像），提供开发、预览、预发布和生产四种环境的 Compose 编排配置。
- **benchmark/**：性能基准测试框架，包含统计计算引擎（分布拟合/显著性检验/回归分析）、多格式报告生成器（HTML/Markdown/PDF/JSON/Console）和历史版本对比器。
- **lib/**：Shell 脚本公共库，提供日志输出、统一错误码体系（1000-2999+）和平台检测功能。
- **tests/**：运维测试套件，Python 端使用 pytest 覆盖插件/事件/安全/遥测/检查点/记忆/Token 等模块，Shell 端使用 bats-core 框架。

### toolkit/ — Python 运维工具包

AgentRT 运维和开发的 Python 工具集合，包含 15 个源模块：

- **诊断类**：`doctor.py`（8 大类别系统健康诊断）、`initializer.py`（配置初始化与完整性验证）
- **性能类**：`benchmark.py`（IPC 延迟/内存分配/上下文切换/调度吞吐/JSON 解析基准测试）
- **记忆类**：`memory_manager.py`（L1-L4 四层记忆管理）、`checkpoint_manager.py`（状态检查点管理）
- **Token 类**：`token_utils.py`（多策略计数 + 预算分配/追踪/告警）
- **配置类**：`config_engine.py`（Jinja2 模板引擎，dev/staging/production/testing 四环境）
- **基础设施**：`cli.py`（彩色输出/进度条/spinner/选择菜单/表格）、`logger.py`（终端颜色/格式化输出）、`events.py`（同步/异步事件总线）
- **扩展类**：`plugin.py`（动态发现/元数据管理/依赖解析/执行隔离）、`security.py`（输入净化/路径检查/注入防护/审计）
- **可观测性**：`telemetry.py`（实时指标/基准追踪/趋势分析，兼容 Prometheus）
- **验证类**：`validate_contracts.py`（syscall 头文件/配置格式/API 响应合规验证）

### resources/ — 项目资源与教程

项目宣传和社区建设资源：

- **demos/**：技术演示脚本，如 Phase 3 技术栈展示（服务框架/基准测试/工具链/开源治理）
- **images/**：静态图片资源，包含桌面端预览动图和飞书社区二维码
- **tutorial/**：交互式教程引擎，支持命令行和 Web 双模式，提供渐进式学习路径引导新贡献者

## 使用方式

### 开发环境配置

```bash
# 交互式环境配置（Linux/macOS）
scripts/dev/setup/setup.sh

# 交互式环境配置（Windows PowerShell）
.\scripts\dev\setup\setup.ps1
```

### 项目构建

> **构建入口**：`dev/` 下不设独立构建目录，构建统一由 CI 流水线脚本承担。

```bash
# 模块编译（Release 模式，BAN-33 源外构建）
scripts/ci/pipeline/build/build-module.sh --module all --type Release

# 依赖安装（Linux/macOS）
scripts/ci/pipeline/build/install-deps.sh

# 测试执行（CTest/pytest 双引擎）
scripts/ci/pipeline/test/run-tests.sh --module all
```

### 安装器位置

> **迁移说明**：安装器 `install.sh` / `install.ps1` 已迁移至
> `agent-workload/agentrt/scripts/`，本仓 `tools/scripts/install/` 目录已移除，
> `dev/` 下亦无 build/install 脚本。

```bash
# Linux/macOS 安装
agent-workload/agentrt/scripts/install.sh

# Windows 安装（PowerShell）
.\agent-workload\agentrt\scripts\install.ps1
```

### CLI 工具

```bash
# 查看帮助
scripts/dev/cli/agentrt --help

# 服务管理
scripts/dev/cli/agentrt service list
scripts/dev/cli/agentrt service health

# 智能体管理
scripts/dev/cli/agentrt agent list
```

### CI/CD 流水线

```bash
# 完整 CI 运行
scripts/ci/pipeline/ci-run.sh

# 单独执行质量检查
scripts/ci/quality/check-quality.sh

# 安全扫描
scripts/ci/verify/sec017_scan.sh all

# 版本发布（质量门禁 → 打 tag → 打包 → 签名 → 上传）
scripts/ci/release/release.sh 0.1.5 stable
```

### Docker 部署

```bash
# 开发环境启动
docker-compose -f deploy/docker/docker-compose.yml \
               -f deploy/docker/docker-compose.dev.yml up -d

# 生产环境部署
docker-compose -f deploy/docker/docker-compose.yml \
               -f deploy/docker/docker-compose.prod.yml up -d
```

### 性能基准测试

```bash
# 基础性能基准测试
python scripts/ops/benchmark/benchmark_core.py --rounds 100

# 生成 HTML 报告
python scripts/ops/benchmark/benchmark_core.py --rounds 100 --report html --output results/

# CoreLoopThree 基准测试示例
python scripts/ops/benchmark/example_coreloopthree_benchmark.py
```

### Python 工具包

```python
from scripts.toolkit import (
    AgentRTDoctor,
    MemoryManager,
    TokenCounter,
    TokenBudget,
    CheckpointManager,
    AgentRTBenchmark,
    ContractValidator,
    ConfigEngine,
    PluginRegistry,
    EventBus,
    SecurityManager,
    MetricsCollector,
    ConfigInitializer,
)

doctor = AgentRTDoctor()
doctor.run_all()

mm = MemoryManager()
mm.stats()
```

## 依赖说明

| 子模块 | 核心依赖 | 说明 |
|--------|---------|------|
| `ci/pipeline/` | Bash, CMake, pytest | 流水线运行需要 CMake 构建系统和 pytest 测试框架 |
| `ci/quality/` | Python 3.8+, PyYAML, Jinja2 | 质量分析工具依赖 Python 生态，详见 `requirements.txt` |
| `ci/verify/` | Bash, PowerShell, Python 3.8+ | SDK 验证同时支持 Unix Shell 和 Windows PowerShell；安全扫描按检查项可选依赖 grype/trivy/flawfinder/cppcheck |
| `ci/release/` | Bash, git, gpg, cosign | 发布依赖双轨签名工具（cosign + GPG）与 curl |
| `dev/setup/` | Bash, PowerShell | 环境配置脚本自动检测并安装所需依赖 |
| `dev/cli/` | Python 3.8+ | CLI 为纯 Python 实现，通过 HTTP 调用 gateway（默认 `http://localhost:18789`） |
| `dev/cmake/` | CMake 3.20+, GCC/Clang | Sanitizers 需要 GCC 或 Clang 编译器支持（MSVC 下自动禁用） |
| `dev/utils/` | Bash, Python 3.8+ | 修复工具为纯 Python 实现，由 `run_all_fixes.sh` 编排 |
| `ops/deploy/` | Docker, Docker Compose | 容器化部署需要 Docker Engine 和 Docker Compose |
| `ops/benchmark/` | Python 3.8+, numpy, scipy | 统计计算依赖 numpy/scipy 科学计算库 |
| `ops/tests/` | Python 3.8+, pytest, bats-core | Python 测试使用 pytest，Shell 测试使用 bats-core |
| `toolkit/` | Python 3.8+, Jinja2, Prometheus Client | 配置引擎依赖 Jinja2，遥测模块兼容 Prometheus |
| `resources/` | Python 3.8+ | 教程引擎为纯 Python 实现 |

---

© 2025-2026 SPHARX Ltd. All Rights Reserved.
