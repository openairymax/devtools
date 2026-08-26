# CI/CD 流水线与质量工具

`tools/scripts/ci/`

## 概述

CI/CD 流水线脚本覆盖 agentrt（`agent-workload/agentrt/`）全部模块的构建、测试、
质量门禁、安全扫描与版本发布，是持续集成和质量保证的核心基础设施。

本模块按**职责单一**原则划分为四个子模块（v0.1.5 重组，消除职责重叠）：

| 子模块 | 职责 | 对应目录 |
|--------|------|---------|
| `pipeline/` | 流水线编排：构建 → 测试 → 部署 | `pipeline/{build,test,deploy}/` |
| `quality/` | 质量门禁与分析（提交前检查 / 六语言分析 / 门禁） | `quality/{src,gates}/` |
| `verify/` | 构建验证与安全扫描（SDK 验证 / 构建模式 / 安全扫描） | `verify/{security,sdk}/` |
| `release/` | 发布管理（质量门禁 → 打 tag → 完全体打包 → 双轨签名 → 上传） | `release/` |

> **版本**: v0.1.5（对应 agentrt 0.1.5）
>
> **布局约定**：本模块运行于伞仓 `airymaxhub`（agentrt 源码位于
> `agent-workload/agentrt/`）。所有脚本以自身位置上跳 5 级解析伞仓根，
> 构建产物一律输出到源码区外（铁律 4.7）。

## 目录结构

```
ci/
├── README.md                              # 本文档
├── pipeline/                              # 流水线编排（构建→测试→部署）
│   ├── ci-run.sh                          #   CI 主运行脚本（依赖→构建→测试→质量→部署）
│   ├── build/                             #   构建工具
│   │   ├── build-module.sh                #     多模块并行/增量构建
│   │   ├── install-deps.sh                #     跨平台依赖安装
│   │   ├── requirements-linux.txt         #     Linux 依赖清单
│   │   └── requirements-macos.txt         #     macOS 依赖清单
│   ├── test/                              #   测试执行
│   │   ├── run-tests.sh                   #     CTest/pytest 双引擎测试
│   │   ├── run-connection-tests.sh        #     连接线集成测试（L01-L12）
│   │   ├── test-integration.sh            #     集成测试环境启动与验证
│   │   └── wait-for-it.sh                 #     服务就绪等待工具
│   └── deploy/                            #   部署工具
│       ├── deploy-artifacts.sh            #     构建产物归档与部署
│       └── db-migrate.sh                  #     heapstore 数据库迁移
├── quality/                               # 质量门禁与分析
│   ├── check-quality.sh                   #   提交前质量检查（git pre-commit 可调用）
│   ├── requirements.txt                   #   Python 依赖清单
│   ├── src/                               #   质量分析器
│   │   ├── unified_quality_analyzer.py    #     六语言（C/C++/Python/Go/Rust/TS）统一分析
│   │   ├── fix_encoding.py                #     编码修复（check/fix-bom/fix-double）
│   │   ├── check_yaml_syntax.py           #     YAML 语法检查
│   │   ├── enhance_coverage.py            #     覆盖率提升工具
│   │   ├── verify_consistency.py          #     文档一致性验证
│   │   └── update_openlab_paths.py        #     OpenLab 路径更新
│   └── gates/                             #   质量门禁（v0.1.5 自 pipeline/validate 收敛）
│       ├── quality-gate.sh                #     门禁主编排（编译/BAN/安全/合约/跨仓）
│       ├── contract-version-check.sh      #     合约版本变更检测
│       ├── cross-repo-verify.sh           #     跨子仓库交叉验证
│       ├── config_validator.py            #     agentrt.yaml Schema 校验
│       └── complexity-check.sh            #     圈复杂度检查
├── verify/                                # 构建验证与安全扫描
│   ├── verify_sdks.sh / verify_sdks.ps1   #   SDK 构建验证（Linux/macOS/Windows）
│   ├── test_build_modes.sh                #   MemoryRovol OSS/PRO 构建模式测试
│   └── security/                          #   安全扫描（v0.1.5 自 pipeline/security + verify 收敛）
│       ├── security-scan.sh               #     10 项综合安全扫描（CVE/静态/容器/密钥/SBOM/...）
│       ├── security-scan.py               #     综合安全扫描（Python 实现）
│       ├── security_check.py              #     C 语言安全编码静态检查（SEC-001~011）
│       ├── security_regression.sh         #     安全回归测试（构建+flawfinder+cppcheck）
│       ├── leak-detection.sh              #     内存泄漏检测（ASan soak）
│       ├── forbidden_functions.sh         #     禁止函数（BAN 规则）检测
│       ├── sec017_scan.sh                 #     SEC-017 桩函数穷尽检测
│       └── check_memcpy_dynamic.sh        #     动态长度 memcpy 前置校验（SEC-11）
└── release/                               # 发布管理
    ├── release.sh                         #   一键发布（质量门禁 + 打 tag）
    ├── package-full-release.sh            #   完全体二进制包（含闭源模块预编译/TUI/Python）
    ├── publish-release.sh                 #   签名 + manifest + atomgit 上传 + latest/ 入口
    ├── init-signing-keys.sh               #   双轨签名密钥初始化（GPG + cosign）
    ├── cleanup_builds.sh                  #   源码树构建产物清理
    └── keys/                              #   内置公钥（agentrt.asc / agentrt.fingerprint / cosign.pub）
```

## 各子模块说明

- **[pipeline/](pipeline/README.md)** — 流水线编排：`ci-run.sh` 是 CI 主入口，
  按序调用依赖安装、构建、测试、质量门禁、部署五个阶段（各阶段可独立运行）。
- **[quality/](quality/README.md)** — 质量门禁与分析：提交前检查、六语言统一质量分析、
  编码修复、覆盖率、合约版本、跨仓一致性、配置 Schema、圈复杂度门禁。
- **[verify/](verify/README.md)** — 构建验证与安全扫描：SDK 三平台构建验证、
  MemoryRovol 构建模式、10 项综合安全扫描、SEC-017 桩函数检测等。
- **[release/](release/README.md)** — 发布管理：一键发布、完全体打包、双轨签名
  （cosign 每个制品 + GPG 权威 manifest）、atomgit Release 上传与 latest/ 入口更新。

## 使用方式

### 完整 CI 流水线

```bash
tools/scripts/ci/pipeline/ci-run.sh
```

### 单独运行各阶段

```bash
# 依赖安装 / 模块编译 / 测试执行
tools/scripts/ci/pipeline/build/install-deps.sh
tools/scripts/ci/pipeline/build/build-module.sh --module all --type Release
tools/scripts/ci/pipeline/test/run-tests.sh --module all

# 质量门禁（编译 / BAN / 安全 / 合约 / 跨仓 / 复杂度）
tools/scripts/ci/quality/gates/quality-gate.sh
tools/scripts/ci/quality/check-quality.sh

# 安全扫描（10 项）/ 桩函数检测 / 禁止函数
tools/scripts/ci/verify/security/security-scan.sh
tools/scripts/ci/verify/security/sec017_scan.sh all
tools/scripts/ci/verify/security/forbidden_functions.sh

# SDK 构建验证（Linux/macOS；Windows 用 .ps1）
tools/scripts/ci/verify/verify_sdks.sh
```

### 版本发布

```bash
# 一键发布（门禁 → 打 tag v0.1.5 → 推送触发 CI）
tools/scripts/ci/release/release.sh 0.1.5 stable

# 完全体二进制包（版本默认读 agentrt/VERSION，SSoT）
tools/scripts/ci/release/package-full-release.sh v0.1.5 linux-x86_64

# 发布（签名 + manifest + atomgit 上传；CI release 阶段自动调用）
tools/scripts/ci/release/publish-release.sh v0.1.5 "$PWD/dist"
```

## 依赖说明

| 子模块 | 核心依赖 |
|--------|---------|
| `pipeline/` | Bash 4.0+、CMake 3.20+、GCC/Clang、pytest |
| `quality/` | Python 3.8+（见 `requirements.txt`）、clang-format（可选） |
| `verify/security/` | Python 3.8+；grype/trivy/flawfinder/cppcheck 等扫描工具按检查项可选 |
| `release/` | Bash、git、gpg、cosign、curl、python3 |

## 安全与质量设计

- **安全左移**：安全扫描（10 项）与 SEC-017 桩函数/禁止函数检测在提交与 CI 阶段
  即拦截，不等到发布。
- **发布供应链**：cosign 对每个 tarball 签名（`*.sig` 随制品发布），GPG 对
  manifest 做权威签名；客户端安装器/自更新器验签失败即拒绝（fail-closed）。
- **BAN-33**：所有构建脚本禁止源内构建，产物输出到独立构建目录（`~/.airymaxrt-build/`）。

---

© 2025-2026 SPHARX Ltd. All Rights Reserved.
