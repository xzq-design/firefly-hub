# Firefly-Hub: 通信协议与工程目录结构设计

## 1. 工程目录结构规划 (三端解耦)

为了保持 Host、Agent、Client 三端的独立性和未来的可扩展性，建议采用标准的 Monorepo 结构，或者将其拆分为三个独立的代码库。这里以 Monorepo 结构为例：

```text
firefly-hub/
├── docs/                # 项目文档 (架构图、API 说明、演进路线等)
├── host/                # 服务端/中控 (Python + AstrBot)
│   ├── core/            # 核心业务逻辑 (连接管理、指令分发、状态机)
│   ├── auth/            # 安全网关 (高危指令拦截、权限校验)
│   ├── engine/          # 逻辑引擎 (Lua 虚拟机集成、流萤人格控制)
│   ├── config/          # 配置文件 (环境、数据库、基础设置)
│   ├── main.py          # Host 服务入口
│   └── requirements.txt
├── agent/               # 执行端 (Python + OpenClaw + MCP)
│   ├── executor/        # 指令执行引擎
│   ├── mcp_tools/       # MCP 协议工具箱 (FileIO, Git, Notion 等)
│   ├── cache_mgr/       # 缓存与安全备份服务 (.firefly_cache 管理)
│   ├── main.py          # Agent 服务入口
│   └── requirements.txt
├── client/              # 用户端 (Flutter)
│   ├── lib/
│   │   ├── main.dart    # App 入口
│   │   ├── core/        # 核心服务 (WebSocket 客户端、本地数据库)
│   │   ├── ui/          # 用户界面 (对话框、审批弹窗、动画体验)
│   │   └── models/      # 数据模型 (与以下 JSON 协议映射)
│   ├── pubspec.yaml     # Flutter 依赖
│   └── ...
└── .firefly_cache/      # 本地安全回溯缓存 (由 Agent 管理，Host 监控)
    ├── backups/         # 每次高危操作前的强制备份点
    └── logs/
```

---

## 2. WebSocket 通信协议 (JSON Schema)

建议采用统一的 `Envelope`（信封）结构来封装所有消息。所有通信内容**必须**包含 `type` 字段以区分消息意图，以及 `message_id` 以便支持异步状态追踪、挂起（Wait）和恢复（Resume）。

### 2.1 基础信封格式 (Envelope)

所有通过 WebSocket 传输的 JSON 必须遵循此结构：

```json
{
  "message_id": "uuid-string",  // 消息的唯一标识，用于请求/响应匹配
  "type": "string",             // 消息类型，决定 payload 如何解析
  "source": "client|host|agent",// 消息发送方
  "target": "client|host|agent",// 消息接收方
  "timestamp": 1700000000,      // Unix 时间戳
  "payload": {}                 // 实际承载的业务数据，根据 type 变化
}
```

---

### 2.2 核心通信流程设计

#### 场景 1：基础文本对话 (Client -> Host -> Agent)

用户在 Flutter App 输入日常聊天（例如：“今天天气如何？”或“帮我列出项目的目录架构”）。

**Client -> Host 发送请求：**
```json
{
  "message_id": "msg-001",
  "type": "CHAT_REQUEST",
  "source": "client",
  "target": "host",
  "timestamp": 1700000100,
  "payload": {
    "content": "帮我看看 e:\\firefly-hub 目录下面都有什么文件？",
    "context_id": "session-123" // 用于多轮对话上下文追踪
  }
}
```

**Host 接收后透传给 Agent，Agent 处理（可能调用 MCP 的 `list_dir`）并返回响应给 Host，Host 再发送回 Client：**
```json
{
  "message_id": "msg-001",      // 保持与请求相同的 message_id
  "type": "CHAT_RESPONSE",
  "source": "host",             // 从 Host 直接回复给 Client
  "target": "client",
  "timestamp": 1700000105,
  "payload": {
    "content": "开拓者，我已经帮您看过了。e:\\firefly-hub 目录下目前只有 readme.md 文件噢。",
    "status": "success"         // success, error, processing
  }
}
```

---

#### 场景 2：安全拦截与打断审批 (Human-in-the-loop)

这是项目的核心亮点。当由于意图判断或 Agent 即将执行高危工具（如写入文件）时，Host 挂起任务并向 Client 发起请求。

**Host -> Client 发起拦截审批请求：**
```json
{
  "message_id": "msg-002",
  "type": "AUTH_REQUIRED",
  "source": "host",
  "target": "client",
  "timestamp": 1700000200,
  "payload": {
    "task_id": "task-write-001", // 被挂起的任务 ID
    "action_type": "FILE_MODIFY",// 操作类型：FILE_MODIFY, FILE_DELETE, GIT_PUSH 等
    "risk_level": "HIGH",        // 风险等级：LOW, MEDIUM, HIGH
    "target_path": "e:\\firefly-hub\\readme.md",
    "description": "流萤准备修改 readme.md 文件，添加了关于 JSON 协议的设计。",
    "diff_preview": "@@ -55,3 +55,6 @@\n * **Phase 5: 体验打磨**\n...\n+* **JSON 协议设计**: 增加 WebSocket...",
    "timeout_seconds": 30        // 审批倒计时，超时自动视为拒绝
  }
}
```

**Client -> Host 用户做出最终裁决（同意或拒绝）：**
```json
{
  "message_id": "msg-002-reply", // 或者是关联 msg-002
  "type": "AUTH_RESPONSE",
  "source": "client",
  "target": "host",
  "timestamp": 1700000215,
  "payload": {
    "task_id": "task-write-001",
    "decision": "APPROVED",      // APPROVED (同意) 或 REJECTED (拒绝)
    "reason": ""                 // 拒绝时可以带上用户的理由
  }
}
```
*Host 收到 `APPROVED` 后，通知 Agent 进行 `.firefly_cache` 静默备份，并恢复（Resume）任务执行。*

---

#### 场景 3：Agent 任务状态/日志流推送 (Agent -> Host -> Client)

在执行耗时任务（或流式输出文本）时，需要持续推送状态以避免用户界面假死。

**Host -> Client 实时状态推送：**
```json
{
  "message_id": "msg-003",
  "type": "TASK_STATUS_UPDATE",
  "source": "host",
  "target": "client",
  "timestamp": 1700000300,
  "payload": {
    "task_id": "task-write-001",
    "status": "BACKUP_CREATING", // 状态枚举：BACKUP_CREATING, EXECUTING, SUCCESS, FAILED
    "message": "正在为您创建安全缓存备份..."
  }
}
```

---

#### 场景 4：撤销操作 (Undo) 与缓存清理

**Client -> Host 发起一键撒回请求：**
```json
{
  "message_id": "msg-004",
  "type": "UNDO_REQUEST",
  "source": "client",
  "target": "host",
  "timestamp": 1700000400,
  "payload": {
    "task_id": "task-write-001" // 指定要撤销的历史任务
  }
}
```

**Host -> Client 缓存容量报警 (流萤主动发起)：**
```json
{
  "message_id": "msg-005",
  "type": "SYSTEM_NOTIFICATION",
  "source": "host",
  "target": "client",
  "timestamp": 1700000500,
  "payload": {
    "notification_type": "CACHE_CLEANUP",
    "content": "开拓者，本地安全缓存已超过 5GB，存在很多数字垃圾。建议立即清理！",
    "actions": ["一键清理", "暂不处理"] // 供 UI 渲染按钮
  }
}
```

---

### 2.3 消息类型 (Type) 汇总字典

*   **握手与心跳**: `PING`, `PONG`, `AUTH_CONNECT`
*   **基础对话流**: `CHAT_REQUEST`, `CHAT_RESPONSE`, `CHAT_STREAM_CHUNK`
*   **安全与授权**: `AUTH_REQUIRED`, `AUTH_RESPONSE`
*   **任务与状态**: `TASK_EXECUTE`, `TASK_STATUS_UPDATE`, `UNDO_REQUEST`
*   **系统通知**: `SYSTEM_NOTIFICATION`, `ERROR_ALERT`
