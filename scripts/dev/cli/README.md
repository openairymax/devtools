# CLI 入口

`tools/scripts/dev/cli/`

## 概述

`cli/` 目录提供 AgentRT 统一命令行入口 `agentrt`（Python 3 实现，基于 argparse）。
它通过 HTTP 调用 gateway 服务，提供服务、智能体、任务、协议、配置、开发与数据库
迁移等子命令，是日常开发与运维的统一操作界面。

> **版本**: v0.1.5

## 目录结构

```
cli/
└── agentrt    # 统一 CLI 命令行入口（Python 实现）
```

## 使用方式

### 运行前置

CLI 通过 HTTP 调用 gateway，相关环境变量：

| 环境变量 | 说明 | 默认值 |
|---------|------|--------|
| `AGENTRT_ENDPOINT` | gateway 服务地址 | `http://localhost:18789` |
| `AGENTRT_API_KEY` | 需要鉴权时的 API 密钥 | 空 |

### 子命令一览

`agentrt` 基于 argparse 注册了以下命令树（`--help` 可见；带 ✅ 的子命令已绑定
执行逻辑，其余已注册、暂未绑定执行器，调用时会列出可用子命令）：

```bash
scripts/dev/cli/agentrt --help              # 帮助

# 服务管理：list ✅ / health ✅ / start / stop / restart
scripts/dev/cli/agentrt service list
scripts/dev/cli/agentrt service health

# 智能体管理：list ✅ / register
scripts/dev/cli/agentrt agent list

# 任务管理：list ✅ / submit
scripts/dev/cli/agentrt task list

# 协议操作：list / info / test / detect / send / stats / transform / capabilities（均已实现 ✅）
scripts/dev/cli/agentrt protocol list
scripts/dev/cli/agentrt protocol test jsonrpc
scripts/dev/cli/agentrt protocol send jsonrpc "method" '{"param":1}'

# 配置：get ✅ / set ✅
scripts/dev/cli/agentrt config get <key>
scripts/dev/cli/agentrt config set <key> <value>

# 开发：doctor ✅ / build / test
scripts/dev/cli/agentrt dev doctor

# 数据库（heapstore schema 迁移）：migrate ✅ / migrate-status ✅ / migrate-rollback ✅ / backup ✅
scripts/dev/cli/agentrt db migrate --target v2
scripts/dev/cli/agentrt db migrate-status
scripts/dev/cli/agentrt db migrate-rollback --force
scripts/dev/cli/agentrt db backup

# 系统：version ✅ / status ✅
scripts/dev/cli/agentrt version
scripts/dev/cli/agentrt status
```

## 依赖

| 文件 | 核心依赖 | 说明 |
|------|---------|------|
| `agentrt` | Python 3.8+ | 纯 Python 实现（argparse + urllib），依赖 gateway 服务可达 |

---

© 2025-2026 SPHARX Ltd. All Rights Reserved.
