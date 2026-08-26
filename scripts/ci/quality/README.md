# quality/ — 质量门禁与分析

`tools/scripts/ci/quality/`

## 概述

质量门禁与分析子模块：提供提交前质量检查（`check-quality.sh`）、六语言统一质量分析
（`src/unified_quality_analyzer.py`）以及发布门禁（`gates/`）三类能力。
v0.1.5 起原 `pipeline/validate/` 的五个门禁脚本收敛至此（消除职责重叠）。

## 目录结构

```
quality/
├── check-quality.sh               # 提交前质量检查（jscpd 重复代码 / lizard 复杂度）
├── requirements.txt               # Python 依赖清单
├── src/                           # 质量分析器
│   ├── unified_quality_analyzer.py #   六语言（C/C++/Python/Go/Rust/TS）统一质量分析
│   ├── fix_encoding.py             #   编码修复（check/fix-bom/fix-double 子命令）
│   ├── check_yaml_syntax.py        #   YAML 配置语法检查
│   ├── enhance_coverage.py         #   覆盖率提升建议生成
│   ├── verify_consistency.py       #   文档一致性验证
│   └── update_openlab_paths.py     #   OpenLab 路径批量更新
└── gates/                         # 质量门禁（原 pipeline/validate，v0.1.5 收敛）
    ├── quality-gate.sh            #   门禁主编排（编译/BAN-191·193/安全/合约/跨仓/复杂度）
    ├── contract-version-check.sh  #   合约版本变更检测（--baseline-branch / --baseline-snapshot）
    ├── cross-repo-verify.sh       #   跨子仓库交叉验证（--ci / --json）
    ├── config_validator.py        #   agentrt.yaml Schema 校验（入参为配置文件路径）
    └── complexity-check.sh        #   圈复杂度检查（lizard，--files/--strict）
```

## 使用

```bash
# 提交前质量检查
tools/scripts/ci/quality/check-quality.sh

# 六语言统一质量分析
python3 tools/scripts/ci/quality/src/unified_quality_analyzer.py \
    --project-path agent-workload/agentrt --scan-all

# 编码修复 / YAML 检查 / 覆盖率
python3 tools/scripts/ci/quality/src/fix_encoding.py check
python3 tools/scripts/ci/quality/src/check_yaml_syntax.py
python3 tools/scripts/ci/quality/src/enhance_coverage.py

# 发布质量门禁（编译/BAN/安全/合约/跨仓/复杂度；--security-scan 仅跑安全）
tools/scripts/ci/quality/gates/quality-gate.sh
```

## 依赖

Python 3.8+（见 `requirements.txt`）；jscpd / lizard / clang-format 可选。

---

© 2025-2026 SPHARX Ltd. All Rights Reserved.
