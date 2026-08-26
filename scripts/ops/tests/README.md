# 运维测试套件（tests）

`tools/scripts/ops/tests/`

## 概述

`tests/` 目录存放运维模块的自动化测试套件，分为 Python 与 Shell 两部分：Python 测试基于 pytest/unittest，覆盖 AgentRT 的插件、事件、安全、遥测及 token/记忆/检查点等 toolkit 模块；Shell 测试基于自研的 bats-core 风格测试框架，验证 `lib/` 公共库工具函数。测试与 `lib/`、`bin/` 目录配套，是运维代码回归与质量保障的核心入口。

> **版本**: v0.1.5

## 目录结构

```
tests/
├── README.md                        # 本文档
├── python/                          # Python 测试（6 个文件）
│   ├── conftest.py                  #   pytest 配置：注册 slow/integration/security 标记，core 相关测试自动标记 slow
│   ├── test_core.py                 #   Core 模块单元测试：plugin 插件系统 / events 事件总线 / security 安全模块 / telemetry 遥测模块
│   ├── test_checkpoint_manager.py   #   检查点管理器测试：创建/恢复/列表/删除/过期清理/完整性验证
│   ├── test_memory_manager.py       #   记忆管理器测试：统计/查询/清理/遗忘策略/报告导出
│   ├── test_token_budget.py         #   Token 预算管理测试：设置/检查/记录/限制/告警/持久化
│   └── test_token_counter.py        #   Token 计数器测试：计数/记录/统计/成本估算/多模型/持久化
└── shell/                           # Shell 测试（2 个文件）
    ├── test_framework.sh            #   Shell 测试框架：test_start/pass/fail/skip、assert_* 断言、run_test、print_test_report
    └── test_common_utils.sh         #   通用工具函数测试：验证 lib/common.sh 的字符串/文件/进程等 airy_* 函数
```

## 核心组件说明

### python/ — Python 测试

- **conftest.py**：pytest 配置，通过 `pytest_configure` 注册 `slow`、`integration`、`security` 三个标记；`pytest_collection_modifyitems` 将路径含 `core` 的测试自动标记为 `slow`
- **test_core.py**：验证 `scripts.core` 下 plugin（插件元数据/注册表/生命周期）、events（事件总线/优先级）、security（输入校验/安全级别）、telemetry（指标采集）四个子模块
- **test_checkpoint_manager.py**：验证检查点创建、恢复、列表、删除、过期清理与完整性校验
- **test_memory_manager.py**：验证记忆统计、查询、清理、遗忘策略配置与报告导出
- **test_token_budget.py**：验证 Token 预算设置、检查、使用记录、限制、告警与持久化
- **test_token_counter.py**：验证快速估算与精确计数、使用记录、统计查询、成本估算、多模型支持与持久化

### shell/ — Shell 测试

- **test_framework.sh**：基于 bats-core 单元测试库的轻量测试框架，提供 `test_start`/`test_pass`/`test_fail`/`test_skip`、`assert_true`/`assert_false`/`assert_equal`/`assert_contains`/`assert_match`/`assert_file_exists`/`assert_dir_exists`/`assert_command_exists`/`assert_not_empty`、`run_test`（执行测试函数并统计）、`print_test_report`（汇总报告）等基础设施
- **test_common_utils.sh**：加载测试框架后对 `lib/common.sh` 的 `airy_*` 工具函数做单元测试（字符串大小写转换、trim、contains、random_string、mkdir、safe_rm、版本比较等）

## 使用方式

### Python 测试（pytest）

```bash
# 运行全部 Python 测试
pytest tools/scripts/ops/tests/python/

# 运行指定测试文件
pytest tools/scripts/ops/tests/python/test_core.py

# 仅运行慢速标记测试
pytest tools/scripts/ops/tests/python/ -m slow

# 按标记筛选（integration / security）
pytest tools/scripts/ops/tests/python/ -m integration
pytest tools/scripts/ops/tests/python/ -m security
```

### Shell 测试

```bash
# 运行 Shell 公共库工具函数测试
bash tools/scripts/ops/tests/shell/test_common_utils.sh
```

## 依赖

| 子目录 | 依赖 | 说明 |
|--------|------|------|
| `python/` | Python 3.8+、pytest（conftest 标记机制） | 测试用例本身基于 unittest/pytest 双风格 |
| `shell/` | Bash 4.0+ | 自研测试框架，无外部依赖（借鉴 bats-core 风格） |

---

© 2025-2026 SPHARX Ltd. All Rights Reserved.
