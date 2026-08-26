# systemd — AgentRT 服务编排

`deploy/systemd/`

## 概述

`systemd/` 目录提供 AgentRT 全部 daemon 的 systemd 单元文件（P1.23.2 daemon 启动顺序编排），共 12 个 `agentrt-*.service` 与 1 个聚合 `agentrt.target`。各 service 按 **Layer 0 → Layer 4** 分层定义启动依赖：Layer 0 为无依赖的基础设施（监控/可观测/信息/通知），Layer 4 为对外网关；`agentrt.target` 通过 `Wants=` 聚合全部服务，一条命令即可启用整套服务栈。

所有 service 采用统一的加固与恢复策略：`Type=simple`、`Restart=on-failure`（`RestartSec=5`）、`NoNewPrivileges=true`、`ProtectSystem=strict`、`ProtectHome=true`、`PrivateTmp=true`、`ReadWritePaths=@AGENTRT_RUNTIME_DIR@`，并设置 `LimitNOFILE=65536` / `LimitNPROC` 资源上限。

> **版本**：v0.1.5

## 目录结构

```
systemd/
├── README.md                      # 本文档
├── agentrt.target                 # 聚合目标：Wants= 全部 12 个 service，一键启停整套服务栈
├── agentrt-monit.service          # Layer 0 基础设施 — monit_d 监控守护进程（无依赖）
├── agentrt-observe.service        # Layer 0 基础设施 — observe_d 可观测性守护进程（无依赖）
├── agentrt-info.service           # Layer 0 基础设施 — info_d 信息守护进程（无依赖）
├── agentrt-notify.service         # Layer 0 基础设施 — notify_d 通知守护进程（无依赖）
├── agentrt-sched.service          # Layer 1 核心服务 — sched_d 任务调度守护进程（依赖 observe）
├── agentrt-channel.service        # Layer 1 核心服务 — channel_d 通道守护进程（依赖 notify）
├── agentrt-llm.service            # Layer 2 Agent 服务 — llm_d LLM 守护进程（依赖 sched，需 --manager /etc/agentrt/model.yaml）
├── agentrt-tool.service           # Layer 2 Agent 服务 — tool_d 工具执行守护进程（依赖 llm、sched）
├── agentrt-hook.service           # Layer 2 Agent 服务 — hook_d 钩子守护进程（依赖 tool）
├── agentrt-plugin.service         # Layer 2 Agent 服务 — plugin_d 插件守护进程（依赖 tool、hook）
├── agentrt-market.service         # Layer 3 业务服务 — market_d 应用市场守护进程（依赖 plugin）
└── agentrt-gateway.service        # Layer 4 网关 — gateway_d 网关守护进程（依赖 llm、tool、market，CAP_NET_BIND_SERVICE）
```

## Service 与 Daemon 对应关系

| service 文件 | ExecStart 二进制 | 分层 | 启动依赖（Requires） |
|--------------|------------------|------|----------------------|
| `agentrt-monit.service` | `@CMAKE_INSTALL_PREFIX@/bin/monit_d` | Layer 0 | — |
| `agentrt-observe.service` | `@CMAKE_INSTALL_PREFIX@/bin/observe_d` | Layer 0 | — |
| `agentrt-info.service` | `@CMAKE_INSTALL_PREFIX@/bin/info_d` | Layer 0 | — |
| `agentrt-notify.service` | `@CMAKE_INSTALL_PREFIX@/bin/notify_d` | Layer 0 | — |
| `agentrt-sched.service` | `@CMAKE_INSTALL_PREFIX@/bin/sched_d` | Layer 1 | `agentrt-observe.service` |
| `agentrt-channel.service` | `@CMAKE_INSTALL_PREFIX@/bin/channel_d` | Layer 1 | `agentrt-notify.service` |
| `agentrt-llm.service` | `@CMAKE_INSTALL_PREFIX@/bin/llm_d --manager /etc/agentrt/model.yaml` | Layer 2 | `agentrt-sched.service` |
| `agentrt-tool.service` | `@CMAKE_INSTALL_PREFIX@/bin/tool_d` | Layer 2 | `agentrt-llm.service`、`agentrt-sched.service` |
| `agentrt-hook.service` | `@CMAKE_INSTALL_PREFIX@/bin/hook_d` | Layer 2 | `agentrt-tool.service` |
| `agentrt-plugin.service` | `@CMAKE_INSTALL_PREFIX@/bin/plugin_d` | Layer 2 | `agentrt-tool.service`、`agentrt-hook.service` |
| `agentrt-market.service` | `@CMAKE_INSTALL_PREFIX@/bin/market_d` | Layer 3 | `agentrt-plugin.service` |
| `agentrt-gateway.service` | `@CMAKE_INSTALL_PREFIX@/bin/gateway_d` | Layer 4 | `agentrt-llm.service`、`agentrt-tool.service`、`agentrt-market.service` |

> 说明：`@CMAKE_INSTALL_PREFIX@` 与 `@AGENTRT_RUNTIME_DIR@` 为 CMake 配置期占位符，由 `cmake` 生成/安装时替换为实际路径。

## 使用方式

### 单服务启停

```bash
# 启动 / 停止 / 查看状态
systemctl start agentrt-gateway.service
systemctl stop agentrt-gateway.service
systemctl status agentrt-gateway.service

# 开机自启
systemctl enable agentrt-gateway.service
systemctl disable agentrt-gateway.service

# 查看运行日志
journalctl -u agentrt-gateway.service -f
```

### 聚合启停（agentrt.target）

`agentrt.target` 通过 `Wants=` 拉起全部 12 个 service（`After=` 保证按层序启动），适合整套服务栈的统一启停：

```bash
# 启用整套服务栈（开机自启）
systemctl enable agentrt.target

# 一次性启动 / 停止全部 daemon
systemctl start agentrt.target
systemctl stop agentrt.target

# 查看整套服务栈状态（含各 service 状态树）
systemctl status agentrt.target
systemctl list-dependencies agentrt.target

# 禁用整套服务栈
systemctl disable agentrt.target
```

### 覆盖默认参数

个别 service 的 `ExecStart` 需要按部署环境调整（例如 `llm_d` 的模型清单路径），使用 systemd 原生覆盖机制，勿直接编辑单元文件：

```bash
systemctl edit agentrt-llm.service
# 在 [Service] 段追加/覆盖 ExecStart（如更换 model.yaml 路径）
```

## 依赖

| 组件 | 说明 |
|------|------|
| systemd | ≥ 240（支持 `ProtectSystem`/`NoNewPrivileges` 等安全特性） |
| daemon 二进制 | `monit_d`/`observe_d`/`info_d`/`notify_d`/`sched_d`/`channel_d`/`llm_d`/`tool_d`/`hook_d`/`plugin_d`/`market_d`/`gateway_d`，由 CMake 安装至 `@CMAKE_INSTALL_PREFIX@/bin/` |
| 配置文件 | `/etc/agentrt/model.yaml`（llm_d 模型清单 SSoT，必需显式传入） |
| 运行时目录 | `@AGENTRT_RUNTIME_DIR@`（唯一可写路径） |
| 网络 | `network.target` / `network-online.target`（全部 service 声明） |

---

© 2025-2026 SPHARX Ltd. All Rights Reserved.
