# 技术演示脚本（demos）

`tools/scripts/resources/demos/`

## 概述

`demos/` 目录存放 AgentRT 的技术演示脚本，用于在项目宣传、社区活动等场合展示第三阶段（系统完善）的核心能力，包括服务管理框架、性能基准测试框架、开发工具链增强与开源治理准备四大部分。脚本为纯 Python 实现，可直接运行。

> **版本**: v0.1.5

## 目录结构

```
demos/
├── README.md                   # 本文档
└── phase3_technology_demo.py   # 第三阶段技术演示（服务框架/基准测试/工具链/开源治理），version 0.1.1
```

## 核心组件说明

### phase3_technology_demo.py — 第三阶段技术演示

演示四大主题，每个主题对应一个异步演示步骤：

1. **开发工具链增强**：展示统一代码质量分析器（支持 C/C++、Python、Go、TypeScript 多语言；集成 clang-tidy、cppcheck、bandit、mypy、ruff）与交互式教程
2. **性能基准测试框架**：展示 BenchmarkRegistry / BenchmarkRunner 与 CoreLoopThree 认知、记忆基准测试示例
3. **服务管理框架**：展示统一的服务生命周期管理与架构通信机制
4. **开源治理准备**：展示项目治理模型与贡献者指南

脚本通过 `sys.path` 引入父目录模块（`benchmark/`、`tutorial/`、`code_quality/`），导入失败时给出告警并中止演示。演示结束后生成汇总报告，以退出码 0/1 表示成功/失败。

## 使用方式

```bash
# 直接运行完整演示（需能导入 benchmark/tutorial/code_quality 等模块）
python3 tools/scripts/resources/demos/phase3_technology_demo.py

# 或在项目 tools/scripts 根路径下运行
cd tools/scripts && python3 resources/demos/phase3_technology_demo.py
```

## 依赖

| 组件 | 依赖 | 说明 |
|------|------|------|
| `phase3_technology_demo.py` | Python 3.8+（asyncio） | 演示依赖同仓库 `benchmark/`、`tutorial/`、`code_quality/` 模块，缺任一模块时演示告警中止 |

---

© 2025-2026 SPHARX Ltd. All Rights Reserved.
