# 单元测试

`tests/unit/`

## 概述

`unit/` 目录是 AgentRT 的单元测试中心，共 **129 个文件**（含 3 个结构文件与 1 个遗留日志），按被测模块划分为 `atoms/`、`commons/`、`cupolas/`、`daemon/`、`heapstore/`、`manager/`、`scripts/`、`toolkit/`、`utils/` 等子目录。C 语言测试经 CMake 构建后用 ctest 运行；Python 测试（manager 的配置校验套件、scripts 的插件注册表测试、toolkit 的 SDK/管理器测试等）使用 pytest 驱动。每个测试文件专注于验证单个模块或函数的正确性，确保各组件在隔离环境下行为符合预期。

单元测试遵循以下原则：

- **隔离性**：每个测试用例独立运行，不依赖其他测试的状态
- **可重复性**：相同输入始终产生相同结果
- **快速执行**：单元测试应毫秒级完成，不涉及外部 I/O
- **单一职责**：每个测试函数只验证一个行为

> **版本**：v0.1.5

## 目录结构

```
unit/                              # 共 129 个文件
├── README.md                      # 本文档
├── CMakeLists.txt                 # 单元测试构建入口（挂载 atoms/coreloopthree、commons/unit）
├── __init__.py                    # Python 包初始化
├── atoms/                         # Atoms 层 C 单元测试（25 个文件）
│   ├── test_common_utils.c        #   Atoms 公共工具函数测试
│   ├── corekern/                  #   微核心测试（7 个文件：IPC/内存/任务/定时器/错误/扩展）
│   ├── coreloopthree/             #   三环运行时测试（10 个文件：认知/记忆/循环/协调器/多数投票 + benchmark.c）
│   ├── memory/                    #   内置记忆子系统测试（1 个文件：Memory Provider）
│   └── syscall/                   #   系统调用层测试（6 个文件：表/入口/功能/扩展/集成/完整工作流）
├── commons/                       # Commons 统一基础库测试（17 个文件）
│   └── unit/                      #   C 测试（配置/成本/IPC/日志/网络/平台/Token 等）+ CMakeLists.txt
├── cupolas/                       # Cupolas 安全穹顶 C 测试（10 个文件）
│   └── unit/                      #   核心/配置/安全/签名/金库/工作台/指标/审计溢出/熔断器/清洗缓存
├── daemon/                        # Daemon 守护进程测试（39 个文件）
│   ├── common/                    #   公共服务测试（9 个文件：IPC 客户端/服务认证/JSON-RPC/安全字符串等）
│   ├── gateway_d/                 #   网关守护进程测试（5 个文件）
│   ├── llm_d/                     #   LLM 守护进程测试（7 个文件，含 Python 测试 test_llm_service.py）
│   ├── market_d/                  #   应用市场守护进程测试（5 个文件）
│   ├── monit_d/                   #   监控告警守护进程测试（4 个文件）
│   ├── sched_d/                   #   任务调度守护进程测试（2 个文件）
│   └── tool_d/                    #   工具执行守护进程测试（7 个文件，含 Python 测试 test_tool_service.py）
├── heapstore/                     # 堆存储测试（12 个文件：核心/注册表/批量/IPC/日志/内存/追踪/边界/模糊并发等）
├── manager/                       # 统一配置管理中心 Python 测试（8 个文件，run_all_tests.py 为运行入口）
├── scripts/                       # scripts/toolkit 插件注册表 pytest 测试（1 个文件：test_plugin.py）
├── toolkit/                       # 运维工具包与多语言 SDK Python 测试（12 个文件）
├── utils/                         # 测试工具函数 Python 测试（1 个文件：test_mock_factory.py）
└── openlab/                       # 遗留日志目录（logs/test_run.log，不含测试用例）
```

## 使用方式

### manager 配置校验套件（Python）

`manager/` 下为统一配置管理中心（ecosystem/manager）的单元测试，通过 `run_all_tests.py` 一键执行配置语法验证、Schema 验证与配置集成测试三组用例：

```bash
# 运行全部测试（默认 --config-dir 为 manager/ 上一级）
python tests/unit/manager/run_all_tests.py

# 详细输出 / 按关键词选择测试（syntax、schema、integration）
python tests/unit/manager/run_all_tests.py --verbose
python tests/unit/manager/run_all_tests.py syntax schema

# 指定配置根目录
python tests/unit/manager/run_all_tests.py --config-dir /etc/agentrt/configs
```

### Python 单元测试（pytest）

```bash
# 全部 Python 单元测试
pytest tests/unit/ -v -m unit

# 按模块运行
pytest tests/unit/manager/ -v
pytest tests/unit/scripts/ -v
pytest tests/unit/toolkit/ -v
pytest tests/unit/daemon/ -v

# 并行运行
pytest tests/unit/ -v -n auto
```

### C 单元测试（CMake + ctest）

```bash
# 构建
cd build && cmake .. && make

# 列出全部 C 测试并运行指定组
cd build && ctest -N | grep test_
cd build && ctest -R cognition_test -V
cd build && ctest -R corekern -V
```

### 统一入口

```bash
python tests/utils/python/run_tests.py --type unit
python tests/utils/python/run_tests.py --type unit --module atoms
```

## 依赖

| 组件 | 说明 |
|------|------|
| Python ≥ 3.8 | Python 测试运行时 |
| pytest ≥ 7.0 | Python 测试框架（见 `tests/pytest.ini` 的 minversion） |
| pytest-xdist | 可选，`-n auto` 并行执行 |
| CMake ≥ 3.16 + C 编译器 | C 单元测试构建（经 `tests/CMakeLists.txt` 挂载） |
| manager 配置目录 | `run_all_tests.py` 默认以 `manager/` 上一级为配置根目录，可用 `--config-dir` 覆盖 |

---

© 2025-2026 SPHARX Ltd. All Rights Reserved.
