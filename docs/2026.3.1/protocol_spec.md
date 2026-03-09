# Firefly-Hub 通讯协议规范

本文档是 [`protocol.json`](./protocol.json) 的详细说明，定义了 Client、Host、Agent 三端之间通过 WebSocket 传输的所有消息格式。

---

## 1. 信封格式 (Envelope)

所有 WebSocket 消息**必须**遵循以下结构：

```json
{
  "message_id": "uuid-string",
  "type": "CHAT_REQUEST",
  "source": "client",
  "target": "host",
  "timestamp": 1700000000000,
  "payload": { }
}
```

| 字段 | 类型 | 说明 |
|------|------|------|
| `message_id` | string (UUID) | 消息唯一标识。请求与对应的响应使用**同一个 ID**，用于异步配对 |
| `type` | string | 消息类型枚举，决定 `payload` 如何解析，见下方分类 |
| `source` | enum | 发送方：`client` / `host` / `agent` |
| `target` | enum | 接收方：`client` / `host` / `agent` |
| `timestamp` | integer | UNIX 毫秒时间戳，用于消息排序和超时判定 |
| `payload` | object | 业务数据，格式随 `type` 变化 |

---

## 2. 消息类型分类

### 2.1 连接管理 (connection)

用于心跳保活和连接状态管理。

| 类型 | 方向 | 说明 |
|------|------|------|
| `PING` | Client → Host | 心跳探测，Client 定期发送 |
| `PONG` | Host → Client | 心跳回复，Host 收到 PING 后立即回复 |
| `CONNECT` | Client → Host | 首次建立连接时发送，携带客户端信息 |
| `DISCONNECT` | 任意方向 | 主动断开连接通知 |

**CONNECT payload：**
```json
{
  "client_version": "1.0.0",
  "platform": "android",
  "device_name": "Pixel 9"
}
```

---

### 2.2 基础对话 (chat)

核心对话流，消息从 Client 经 Host 提交给 AstrBot（等同 QQ 消息流程），AstrBot 的 LLM 回复再原路返回。

| 类型 | 方向 | 说明 |
|------|------|------|
| `CHAT_REQUEST` | Client → Host | 用户发送的自然语言消息 |
| `CHAT_RESPONSE` | Host → Client | AstrBot 处理后的完整回复 |
| `CHAT_STREAM_CHUNK` | Host → Client | 流式输出的单个片段（逐字/逐段推送） |

**CHAT_REQUEST payload：**
```json
{
  "content": "帮我看看项目目录下有什么文件",
  "context_id": "session-abc"
}
```
- `content`：用户输入的文本
- `context_id`：会话 ID，用于多轮对话上下文追踪

**CHAT_RESPONSE payload：**
```json
{
  "content": "目录下有 readme.md 和 protocol.json 两个文件。",
  "status": "success",
  "persona": "firefly"
}
```
- `status`：`success` / `error` / `processing`
- `persona`：当前回复使用的人格包 ID

**CHAT_STREAM_CHUNK payload：**
```json
{
  "chunk": "目录下有",
  "index": 0,
  "finished": false
}
```
- `chunk`：本次推送的文本片段
- `index`：片段序号
- `finished`：是否为最后一个片段

---

### 2.3 安全审批 (security) — Human-in-the-loop 核心

当 Host 判定操作涉及高危行为（写入、删除、推送等），挂起任务并向 Client 发起审批请求。

| 类型 | 方向 | 说明 |
|------|------|------|
| `AUTH_REQUIRED` | Host → Client | 请求用户审批，Client 弹出拦截窗口 |
| `AUTH_RESPONSE` | Client → Host | 用户做出的审批决定 |
| `AUTH_TIMEOUT` | Host → Client | 审批超时通知，任务自动取消 |

**AUTH_REQUIRED payload：**
```json
{
  "task_id": "task-789",
  "action_type": "FILE_MODIFY",
  "risk_level": "HIGH",
  "target_path": "e:\\firefly-hub\\readme.md",
  "description": "准备修改 readme.md，添加法律声明章节",
  "diff_preview": "@@ -150,3 +150,20 @@\n+ ## 法律声明\n+ ...",
  "tool_name": "write_file",
  "timeout_seconds": 30
}
```
- `task_id`：被挂起的任务 ID，贯穿整个任务生命周期
- `action_type`：操作类型枚举（见第 4 节）
- `risk_level`：风险等级 `LOW` / `MEDIUM` / `HIGH`
- `target_path`：操作目标路径
- `diff_preview`：变更预览（diff 格式），让用户看到具体改了什么
- `tool_name`：将要调用的 MCP 工具名称
- `timeout_seconds`：审批倒计时，超时自动拒绝

**AUTH_RESPONSE payload：**
```json
{
  "task_id": "task-789",
  "decision": "APPROVED",
  "reason": ""
}
```
- `decision`：`APPROVED`（同意）/ `REJECTED`（拒绝）/ `QUEUED`（加入队列稍后处理）
- `reason`：拒绝时可附带理由

---

### 2.4 任务管理 (task)

追踪 Agent 执行任务的完整生命周期。

| 类型 | 方向 | 说明 |
|------|------|------|
| `TASK_EXECUTE` | Host → Agent | 下发执行指令给 OpenClaw |
| `TASK_STATUS_UPDATE` | Host → Client | 实时推送任务进度，防止界面假死 |
| `TASK_COMPLETE` | Host → Client | 任务执行完毕（成功或失败） |
| `UNDO_REQUEST` | Client → Host | 用户请求撤销某个已完成的任务 |
| `UNDO_RESPONSE` | Host → Client | 撤销操作的执行结果 |

**TASK_STATUS_UPDATE payload：**
```json
{
  "task_id": "task-789",
  "status": "BACKUP_CREATING",
  "message": "正在创建安全备份..."
}
```
- `status`：任务状态枚举（见第 4 节）

**UNDO_REQUEST payload：**
```json
{
  "task_id": "task-789"
}
```

---

### 2.5 人格包管理 (persona)

管理可插拔人格系统，支持切换、查询。

| 类型 | 方向 | 说明 |
|------|------|------|
| `PERSONA_SWITCH` | Client → Host | 切换当前使用的人格包 |
| `PERSONA_LIST` | 双向 | 请求/返回已安装的人格包列表 |
| `PERSONA_INFO` | 双向 | 请求/返回某个人格包的详细信息 |

**PERSONA_SWITCH payload：**
```json
{
  "persona_id": "firefly",
  "persona_name": "流萤"
}
```

**PERSONA_LIST 响应 payload：**
```json
{
  "personas": [
    { "id": "firefly", "name": "流萤", "author": "官方", "version": "1.0" },
    { "id": "custom_001", "name": "自定义助手", "author": "用户", "version": "0.1" }
  ]
}
```

---

### 2.6 系统通知 (system)

系统级事件推送。

| 类型 | 方向 | 说明 |
|------|------|------|
| `SYSTEM_NOTIFICATION` | Host → Client | 通用系统通知（缓存清理提醒等） |
| `ERROR_ALERT` | 任意方向 | 错误告警 |
| `CACHE_CLEANUP` | Host → Client | 缓存容量预警，附带操作按钮 |

**SYSTEM_NOTIFICATION payload：**
```json
{
  "notification_type": "CACHE_CLEANUP",
  "content": "本地缓存已超过 5GB，建议清理。",
  "actions": ["一键清理", "暂不处理"]
}
```
- `actions`：供 Client 渲染为按钮的选项列表

---

## 3. 数据流示例

### 普通对话
```
Client                    Host                     AstrBot
  │── CHAT_REQUEST ──────→│                            │
  │                        │── 提交为平台消息 ──────────→│
  │                        │                            │── LLM 处理
  │                        │←── 回复 ───────────────────│
  │←── CHAT_RESPONSE ─────│                            │
```

### 高危操作审批
```
Client                    Host                     Agent(OpenClaw)
  │── CHAT_REQUEST ──────→│                            │
  │                        │── 意图分析：检测到写操作      │
  │←── AUTH_REQUIRED ─────│  (任务挂起，等待审批)         │
  │                        │                            │
  │── AUTH_RESPONSE ──────→│  (用户点击「同意」)          │
  │  (APPROVED)            │                            │
  │                        │── TASK_EXECUTE ───────────→│
  │←── STATUS_UPDATE ─────│                            │── 创建备份
  │  (BACKUP_CREATING)     │                            │── 执行操作
  │←── TASK_COMPLETE ─────│←── 执行结果 ───────────────│
```

---

## 4. 枚举值字典

### action_type（操作类型）
| 值 | 含义 |
|----|------|
| `FILE_READ` | 读取文件 |
| `FILE_MODIFY` | 修改文件 |
| `FILE_DELETE` | 删除文件 |
| `FILE_CREATE` | 创建文件 |
| `GIT_COMMIT` | Git 提交 |
| `GIT_PUSH` | Git 推送 |
| `COMMAND_EXEC` | 执行系统命令 |
| `NOTION_WRITE` | Notion 写入 |

### risk_level（风险等级）
| 值 | 含义 | 是否需要审批 |
|----|------|-------------|
| `LOW` | 只读操作 | 否 |
| `MEDIUM` | 可逆的修改操作 | 可配置 |
| `HIGH` | 不可逆操作（删除/推送等） | **强制审批** |

### task_status（任务状态）
| 值 | 含义 |
|----|------|
| `PENDING` | 任务已创建，等待处理 |
| `WAITING_APPROVAL` | 等待用户审批 |
| `BACKUP_CREATING` | 正在创建安全备份 |
| `EXECUTING` | 正在执行 |
| `SUCCESS` | 执行成功 |
| `FAILED` | 执行失败 |
| `CANCELLED` | 已取消（用户拒绝或超时） |
| `UNDONE` | 已撤销 |

### auth_decision（审批决定）
| 值 | 含义 |
|----|------|
| `APPROVED` | 同意执行 |
| `REJECTED` | 拒绝执行 |
| `TIMEOUT` | 超时自动拒绝 |
| `QUEUED` | 加入任务队列，稍后处理 |
