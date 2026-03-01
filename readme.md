# 🌟 Firefly-Hub

**一个替代 QQ 的自建消息前端，直接对接 AstrBot，彻底告别封号风险。**

在此基础上深度集成 OpenClaw + MCP 生态，让 AstrBot 不仅能聊天，还能安全地操作你的本地文件、Git 仓库、Notion 等资源。支持可插拔人格系统，内置「流萤」人格包，用户也可自定义专属交互人格。

---

## 为什么做这个？

QQ 等第三方 IM 平台存在封号风险，消息通道不可控。Firefly-Hub 自建消息前端，Host 作为 AstrBot 的**自定义平台适配器**（与 QQ 适配器同级），从根本上消除平台依赖——你的对话，你做主。

---

## 架构总览

```
┌─────────────────── 手机 / 平板 ────────────────────┐
│                                                     │
│   Flutter Client（Android / iOS / Windows）          │
│   ├── 极简对话界面                                    │
│   └── 高危操作审批弹窗 (Human-in-the-loop)            │
│                                                     │
└───────────────── WebSocket ──────────────────────────┘
                       │
                       ▼
┌─────────────────── 电脑端 ──────────────────────────┐
│                                                     │
│   Host（AstrBot 平台适配器）                          │
│   ├── 接收消息 → 提交给 AstrBot（等同 QQ 消息流程）    │
│   ├── AstrBot 回复 → 转发回 Client                   │
│   ├── 需要执行操作 → 下发指令给 OpenClaw               │
│   └── 高危操作 → 挂起任务，向 Client 发起审批          │
│                                                     │
│   OpenClaw（Agent / 执行引擎）                        │
│   ├── 接收 Host 指令 → 调用 MCP 工具                  │
│   ├── 只读工具：list_dir / view_file / Notion 查询    │
│   ├── 写入工具：write_file / git_commit（需审批）      │
│   └── 执行前自动备份至 .firefly_cache                 │
│                                                     │
└─────────────────────────────────────────────────────┘
```

**核心思路**：手机端只负责聊天和审批，电脑端承担所有算力和执行工作。

---

## 三端职责

### Host — AstrBot 自定义平台适配器（Python）
- 启动 WebSocket Server，承接 Client 连接
- 将消息以平台消息形式提交给 AstrBot（与 QQ 消息进入的流程完全一致）
- 接收 AstrBot 的 LLM 回复，转发回 Client
- 指令分流：判定是否需要调用 OpenClaw，高危操作触发审批拦截
- Lua 虚拟机：可插拔人格包热更新（内置「流萤」人格，支持自定义）

### Agent — 执行引擎（OpenClaw + MCP）
- 接收 Host 的执行指令，调用 MCP 工具完成实际操作
- 写操作前强制触发 `.firefly_cache` 静默备份
- 支持一键撤销（Undo）

### Client — 自建聊天前端（Flutter）
- 跨平台：Android / iOS / Windows
- 极简对话界面，承载人格包的文本沟通与情感表达
- Human-in-the-loop 审批弹窗：展示操作类型、目标路径、diff 预览、风险等级
- 30 秒审批超时自动拒绝

---

## 通讯协议

WebSocket + 强类型 JSON 自定义协议（详见 [`protocol.json`](./protocol.json)）

| 类别 | 消息类型 |
|------|---------|
| 握手心跳 | `PING` / `PONG` / `AUTH_CONNECT` |
| 基础对话 | `CHAT_REQUEST` / `CHAT_RESPONSE` / `CHAT_STREAM_CHUNK` |
| 安全审批 | `AUTH_REQUIRED` / `AUTH_RESPONSE` |
| 任务状态 | `TASK_EXECUTE` / `TASK_STATUS_UPDATE` / `UNDO_REQUEST` |
| 系统通知 | `SYSTEM_NOTIFICATION` / `ERROR_ALERT` |

---

## 人格系统

人格包基于 Lua 脚本实现，支持热更新，无需重启即可切换人格。

- **内置人格**：项目附赠「流萤」人格包，开箱即用
- **自定义人格**：用户可编写自己的 `.lua` 人格脚本，定义说话风格、情绪表达、称呼方式等
- **社区共享**：人格包本质是独立的 Lua 文件，方便分享和安装
- **覆盖安装**：新人格包可直接覆盖现有人格，一键切换

---

## 安全机制

- **执行前备份**：每次修改前自动生成带时间戳的 `.bak` 文件至 `.firefly_cache/backups/`
- **一键撤销**：用备份覆盖回原路径
- **定期清理**：以当前人格口吻提醒用户清理缓存，拒绝堆积数字垃圾
- **自然语言触发**：如 "帮我清理一下缓存"

---

## 安装

代码全部在本仓库中，通过符号链接接入 AstrBot：

```bash
# Windows
mklink /D "你的AstrBot路径\data\plugins\firefly_hub" "本仓库路径\host"

# Linux / macOS
ln -s ./host 你的AstrBot路径/data/plugins/firefly_hub
```

> 后续会提供一键安装脚本 `install.bat` / `install.sh`，填入必要信息即可自动完成配置。

---

## 开发路线

| Phase | 目标 | 内容 |
|-------|------|------|
| **1** | 通信基建 | WebSocket 协议 + Host 适配器空壳 + Flutter Client Echo 闭环 |
| **2** | 接入大脑 | Host 对接 AstrBot（像 QQ 适配器一样） + OpenClaw 集成 + 只读 MCP 工具 |
| **3** | 灵魂注入 | Human-in-the-loop 审批 + `.firefly_cache` 备份回溯 + 写入类 MCP 工具 |
| **4** | 体验打磨 | Flutter 动画优化 + 可插拔人格包系统 + 高级 MCP 扩展 |

---

## 未来展望

- **一键安装脚本**：用户只需填入 AstrBot 路径等必填项，自动完成所有配置
- **人格包市场**：社区共享人格包，一键下载安装
- **端到端加密**：可选开启 Client ↔ Host 通信加密（遵守相关法律法规）
- **多并行 Agent**：多开 OpenClaw 实例，并行处理不同任务
- **移动端 Agent**：当手机性能允许时，OpenClaw 也可跑在移动端，实现全移动化

---

## 工程目录

```
firefly-hub/
├── host/                # AstrBot 平台适配器 (Python)
│   └── personas/        # 人格包目录
│       └── firefly.lua  # 内置流萤人格（示例）
├── agent/               # OpenClaw + MCP 工具
├── client/              # Flutter 跨平台客户端
├── .firefly_cache/      # 安全备份缓存（自动生成）
├── protocol.json        # 通讯协议定义
└── readme.md
```

---

## ⚠️ 法律声明与免责条款

**本项目仅供个人学习与合法用途，严禁用于任何违法违规活动。**

使用者必须遵守所在国家和地区的法律法规，以下行为被明确禁止：

- **未授权访问**：利用 Agent 的文件操作和命令执行能力，未经授权访问、修改或删除他人计算机系统中的数据
- **数据窃取与隐私侵犯**：通过 MCP 工具批量采集或窃取他人隐私信息、商业机密等
- **恶意代码分发**：通过人格包（Lua 脚本）或其他扩展机制传播木马、病毒等恶意代码
- **违规自动化操作**：利用本系统对第三方平台进行违反其服务条款的自动化操作（如刷量、薅羊毛等）
- **诈骗与冒充**：利用 AI 人格系统冒充他人或机构实施诈骗
- **生成违法内容**：引导 LLM 生成违法、色情、暴力或其他有害内容
- **规避监管**：利用端到端加密等功能从事需要依法接受监管的通信活动

**开发者不对使用者的任何违法行为承担责任。如因违规使用造成任何法律后果，由使用者自行承担全部责任。**