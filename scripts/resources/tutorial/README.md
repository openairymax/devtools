# 交互式教程（tutorial）

`tools/scripts/resources/tutorial/`

## 概述

`tutorial/` 目录存放 AgentRT 的交互式教程系统，包含教程引擎与教程配置两部分：`tutorial_engine.py` 提供命令行与 Web 两种交互方式，支持渐进式学习路径、进度保存恢复与步骤实时验证；`new-contributor.json` 定义面向首次接触 AgentRT 的贡献者的入门教程（约 4 小时），覆盖欢迎、环境配置、项目结构、开发流程到首个 PR 的完整路径。

> **版本**: v0.1.5

## 目录结构

```
tutorial/
├── README.md               # 本文档
├── tutorial_engine.py      # 交互式教程引擎：list/start/next/prev/status/validate/serve 子命令，命令行 + Web 双模式
└── new-contributor.json    # 新贡献者入门教程配置（id=new-contributor，约 4 小时，含 welcome/env-setup/project-structure/…）
```

## 核心组件说明

### tutorial_engine.py — 交互式教程引擎

- 三种教程角色：`new-contributor`（新贡献者）、`module-developer`（模块开发者）、`system-integrator`（系统集成者）
- 五种步骤类型：theory（理论学习）、practice（实践操作）、exercise（练习验证）、quiz（知识测验）、review（回顾总结）
- 每个步骤支持验证机制（`validation_type`：command/file/manual）、提示（hints）与前置依赖（prerequisites）
- 进度以用户为单位保存与恢复（UserProgress），支持暂停后续学
- Web 模式：`serve` 子命令启动内置 HTTP 服务器，浏览器中交互

### new-contributor.json — 新贡献者入门教程配置

定义 `new-contributor` 教程路径（estimated_hours=4），包含欢迎（welcome）、环境配置（env-setup，验证 git/python3/cmake/gcc 安装）、项目结构分析（project-structure）、开发流程与首个 PR 等步骤，每步含理论内容、命令清单、验证命令与正则校验模式。

## 使用方式

```bash
# 列出所有教程
python3 tools/scripts/resources/tutorial/tutorial_engine.py list

# 开始新贡献者教程（指定用户 ID 可选）
python3 tools/scripts/resources/tutorial/tutorial_engine.py start --tutorial new-contributor
python3 tools/scripts/resources/tutorial/tutorial_engine.py start --tutorial new-contributor --user alice

# 前进 / 后退 / 查看当前状态
python3 tools/scripts/resources/tutorial/tutorial_engine.py next
python3 tools/scripts/resources/tutorial/tutorial_engine.py prev
python3 tools/scripts/resources/tutorial/tutorial_engine.py status

# 验证当前步骤（练习类步骤提交输入）
python3 tools/scripts/resources/tutorial/tutorial_engine.py validate --input "done"

# 启动 Web 交互模式（默认端口 8080）
python3 tools/scripts/resources/tutorial/tutorial_engine.py serve --port 8080
```

## 依赖

| 组件 | 依赖 | 说明 |
|------|------|------|
| `tutorial_engine.py` | Python 3.8+ | 标准库实现（argparse/http.server），无第三方依赖；教程配置从同目录 `*.json` 自动加载 |
| `new-contributor.json` | 无 | JSON 配置文件，无运行时依赖 |

---

© 2025-2026 SPHARX Ltd. All Rights Reserved.
