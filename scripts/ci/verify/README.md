# verify/ — 构建验证与安全扫描

`tools/scripts/ci/verify/`

## 概述

构建验证与安全扫描子模块：验证 SDK 三平台构建正确性、MemoryRovol 构建模式，
并集中所有安全扫描能力（v0.1.5 起原 `pipeline/security/` 与 `verify/` 下的
安全脚本收敛至 `security/`，安全扫描单一归属）。

## 目录结构

```
verify/
├── verify_sdks.sh                 # SDK 构建验证（Linux/macOS；tsc + cargo + go build + pytest）
├── verify_sdks.ps1                # SDK 构建验证（Windows PowerShell）
├── test_build_modes.sh            # MemoryRovol OSS/PRO 构建模式测试（--standalone/--keep）
└── security/                      # 安全扫描（v0.1.5 收敛：原 pipeline/security + verify 安全项）
    ├── security-scan.sh           #   10 项综合安全扫描
    │                              #   （CVE/静态分析/容器/密钥/SBOM/敏感数据/许可证/IaC/API/供应链）
    ├── security-scan.py           #   综合安全扫描（Python 实现）
    ├── security_check.py          #   C 语言安全编码静态检查（SEC-001~011，参数为源码目录）
    ├── security_regression.sh     #   安全回归测试（干净构建 0e0w + flawfinder L4 + cppcheck 0e）
    ├── leak-detection.sh          #   内存泄漏检测（ASan soak；--mode=pr|weekly|release）
    ├── forbidden_functions.sh     #   禁止函数（BAN 规则）检测
    ├── sec017_scan.sh             #   SEC-017 桩函数穷尽检测（参数：daemon|gateway|cupolas|all）
    └── check_memcpy_dynamic.sh    #   动态长度 memcpy 前置校验（SEC-11；--fix/--report）
```

## 使用

```bash
# SDK 构建验证（Linux/macOS；CI 模式输出 JUnit + strict）
tools/scripts/ci/verify/verify_sdks.sh --ci

# 10 项综合安全扫描（--only 3 / --skip 4,7 / --json）
tools/scripts/ci/verify/security/security-scan.sh

# 安全编码静态检查（指定源码目录）
python3 tools/scripts/ci/verify/security/security_check.py \
    agent-workload/agentrt/atoms/ agent-workload/agentrt/commons/

# 桩函数 / 禁止函数 / 动态 memcpy 检查
tools/scripts/ci/verify/security/sec017_scan.sh all
tools/scripts/ci/verify/security/forbidden_functions.sh
tools/scripts/ci/verify/security/check_memcpy_dynamic.sh

# 内存泄漏 soak（PR / 每周 / 发布前）
tools/scripts/ci/verify/security/leak-detection.sh --mode=pr
```

## 安全扫描 10 项清单

| # | 检查项 | 工具 |
|---|--------|------|
| 1 | 依赖 CVE 漏洞 | grype / trivy |
| 2 | C 静态分析 | flawfinder + cppcheck |
| 3 | Docker 镜像 | docker scout / trivy config |
| 4 | 密钥泄露 | gitleaks / trufflehog |
| 5 | SBOM（SPDX） | syft / trivy |
| 6 | 敏感数据 | detect-secrets |
| 7 | 许可证合规 | license_finder |
| 8 | IaC 安全 | checkov |
| 9 | API 安全 | ZAP baseline/full |
| 10 | 供应链 | cosign verify-blob + 依赖校验和 |

扫描工具按项可选：未安装的工具对应检查自动 SKIP，不阻塞其余检查。

---

© 2025-2026 SPHARX Ltd. All Rights Reserved.
