# 运维入口脚本（bin）

`tools/scripts/ops/bin/`

## 概述

`bin/` 目录存放 AgentRT 的运维入口脚本，是部署后日常操作的核心入口，涵盖一键启动、快速建项和运行时验证三类场景：

- **一键启动**：`agentrt-bootstrap.sh` 按 5 层 DAG 顺序拉起全部 15 个 daemon（0.1.9 M4 整编稳态：observe/info→monit_d、plugin→tool_d），支持 watchdog 自愈巡检，是唯一启动编排入口（层清单即编排唯一事实源；install 侧手工 `EXPECTED_DAEMONS` 已于 M4 退役，由 `bin/*_d` 推导）
- **快速建项**：`quickstart.sh` 5 分钟从示例模板创建可运行的 Agent 项目
- **运行时验证**：`agentrt-multiagent.py`、`agentrt-e2e.py` 通过 Unix socket 调用真实 daemon，验证多 Agent 协作与端到端 LLM 链路

> **版本**: v0.1.5

## 目录结构

```
bin/
├── README.md               # 本文档
├── agentrt-bootstrap.sh    # AgentRT 一键启动脚本：5 层 DAG 按序启动 15 个 daemon，支持 watchdog 自愈
├── quickstart.sh           # 5 分钟快速创建示例 Agent 项目（复制示例 + 生成 config.yaml / main.agent.yaml）
├── agentrt-multiagent.py   # 多 Agent 协作闭环验证：sched.schedule_task 选后派发 → 双角色接力（PM → 后端）
└── agentrt-e2e.py          # 端到端调用验证：agent.spawn → agent.invoke → 真实 LLM
```

## 核心组件说明

### agentrt-bootstrap.sh — 一键启动（唯一启动编排入口）

按 DAG 层级顺序启动所有 daemon，每层健康检查通过后才进入下一层。0.1.9 M4 整编后共 5 层 15 个 daemon（稳态）：

| 层级 | daemon |
|------|--------|
| Layer 0 基础设施 | monit_d（M4 吸收 observe/info）, notify_d, cupolas_d |
| Layer 1 核心服务 | sched_d, channel_d, mem_d |
| Layer 2 Agent 服务 | llm_d, think_d, tool_d（M4 吸收 plugin）, hook_d, agent_d, a2a_d, maths_d |
| Layer 3 业务服务 | market_d |
| Layer 4 网关 | gateway_d |

主要能力：

- 健康检查以 Unix socket 监听为权威判据（TCP daemon 如 gateway_d 检查 8080 端口），daemon 真实 PID 以 `$AIRY_HOME/run/<name>.pid` 为准
- `--watchdog` 自愈模式：全部拉起后进入巡检循环，死亡 daemon 按启动顺序自动重启（60s 窗口内单 daemon 最多 3 次，防崩溃循环），重启记录写入 `$AIRY_LOG_DIR/watchdog.log`（默认 `$AIRY_HOME/data/agentrt/logs/watchdog.log`）
- 自动加载 `$AIRY_HOME/config/secrets.env`（LLM 凭据）与 `permission_rules.yaml`（工具 ACL，fail-closed）；llm_d 的模型清单 SSoT 为 `model.yaml`
- 启动前检查 Agent Python SDK（airymax_agents / openlab / agentrt）可导入性，缺失时从源码树自动 editable 安装（仅告警不阻断）
- `--sandbox` 控制 shell_run 工具 OS 沙箱模式（Landlock + seccomp + rlimit）：workspace（默认）/ strict / off

### quickstart.sh — 5 分钟快速建项

从 `examples/` 目录复制指定示例项目到目标目录，生成默认 `config.yaml` 与 `agents/main.agent.yaml`，引导新用户快速上手。不要求环境完备（python3 / cargo / git 缺失仅告警，项目仍可创建）。

### agentrt-multiagent.py — 多 Agent 协作闭环验证

通过 sched_d 的 Unix socket 发起 JSON-RPC（短连接模型），注册 `product_manager` 与 `backend` 两个角色 Agent，调度器按 round-robin 选后派发两轮任务：产品经理产出 PRD 摘要 → 后端开发接力产出实现要点。结束时校验两次派发的 agent_id 不同，证明是真实的多 Agent 协作而非单 Agent 复用。

### agentrt-e2e.py — 端到端调用验证

通过 agent_d 的 Unix socket 依次调用 `agent.spawn`（创建 Agent）与 `agent.invoke`（真实 LLM 推理），验证 `client → agent_d → Python runner → openlab → LLM API` 完整链路。

## 使用方式

### 一键启动全部 daemon

```bash
# 基本启动（按 DAG 顺序拉起 15 个 daemon）
bash tools/scripts/ops/bin/agentrt-bootstrap.sh

# 指定安装目录 + 进入 watchdog 自愈巡检
bash tools/scripts/ops/bin/agentrt-bootstrap.sh --home /srv/airymaxrt --watchdog

# dry-run：只打印启动计划，不实际启动
bash tools/scripts/ops/bin/agentrt-bootstrap.sh -n

# 指定二进制目录 / 运行时目录 / 全局超时
bash tools/scripts/ops/bin/agentrt-bootstrap.sh -b ./build/bin -r /var/run/agentrt -t 180

# 收紧工具 OS 沙箱为 strict
bash tools/scripts/ops/bin/agentrt-bootstrap.sh --sandbox strict
```

### 快速创建示例项目

```bash
# 使用默认示例 hello-agent，输出到 ./my-agent-project
bash tools/scripts/ops/bin/quickstart.sh hello-agent ./my-agent-project
```

### 运行时链路验证（需先启动 agentrt）

```bash
# 端到端：agent.spawn + agent.invoke（走 agent_d socket）
python3 tools/scripts/ops/bin/agentrt-e2e.py --role product_manager --input "请介绍一下你自己"

# 多 Agent 协作：sched 选后派发 → 产品经理 → 后端开发接力
python3 tools/scripts/ops/bin/agentrt-multiagent.py --timeout 600
```

## 依赖

| 脚本 | 依赖 | 说明 |
|------|------|------|
| `agentrt-bootstrap.sh` | Bash 4.0+、已安装 daemon 二进制（`$AIRY_HOME/bin`）、python3、`nc`/`curl`/`ss`（健康检查）、`setsid` | 由 `install.sh` 部署到 `$AIRY_HOME/bin/`；无 `ss` 时回退 socket 文件判断 |
| `quickstart.sh` | Bash 4.0+、`examples/` 示例目录 | python3/cargo/git 缺失仅告警 |
| `agentrt-multiagent.py` | Python 3.8+、运行中的 agentrt（sched_d/agent_d 等） | socket 默认 `$AIRY_HOME/run/sched.sock` |
| `agentrt-e2e.py` | Python 3.8+、运行中的 agentrt（agent_d） | socket 默认 `$AIRY_HOME/run/agent.sock` |

---

© 2025-2026 SPHARX Ltd. All Rights Reserved.
