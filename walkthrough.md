# Phase 1 代码拆解：Host 端 AstrBot 平台适配器

## 整体架构

```
test_echo.py (测试客户端)
     │
     │ WebSocket (ws://localhost:8765)
     ▼
ws_server.py ─── WebSocket Server 核心
     │              ├── 连接管理（session_id 映射）
     │              ├── 心跳处理（PING/PONG）
     │              └── 消息分发（dispatch）
     ▼
main.py ─── AstrBot 插件入口
                ├── 继承 Star 基类（AstrBot 自动识别）
                ├── initialize() 启动 WS Server
                ├── terminate() 关闭 WS Server
                └── 业务消息处理（Echo / 人格切换）
```

---

## 文件 1：ws_server.py — WebSocket 通信层

### 设计理念

这个文件**只管通信，不管业务**。它负责：维护 WebSocket 连接、收发 JSON、心跳保活。所有业务逻辑通过回调函数交给 [main.py](file:///e:/firefly-hub/host/main.py) 处理。

### 核心类：[FireflyWSServer](file:///e:/firefly-hub/host/ws_server.py#18-147)

#### 1. 连接管理

```python
self.clients: Dict[str, WebSocketServerProtocol] = {}  # session_id -> ws
```

每个 Client 连接进来，分配一个 `session_id`（UUID 前 8 位），存到字典里。发消息时通过 `session_id` 找到对应的 WebSocket 连接。

**为什么用 session_id 而不是直接用 ws 对象？**
因为后续需要在不同模块之间传递"给谁发消息"的信息（比如 Host 收到 Agent 的执行结果，要转发给正确的 Client），传一个字符串比传一个对象方便得多。

#### 2. 回调机制

```python
def on_message(self, handler):
    self._message_handler = handler
```

[ws_server.py](file:///e:/firefly-hub/host/ws_server.py) 不知道收到 `CHAT_REQUEST` 该怎么处理，它只管"我收到了一条消息"，然后调用注册好的 handler。这是**依赖反转**——底层不依赖上层，上层注入处理逻辑。

#### 3. 消息分发 [_dispatch_message()](file:///e:/firefly-hub/host/ws_server.py#95-133)

```python
async def _dispatch_message(self, message, session_id):
    msg_type = message.get("type", "")
    
    if msg_type == "PING":    # 心跳 → 自动回 PONG
    if msg_type == "CONNECT": # 握手 → 返回连接确认
    else:                     # 其他 → 交给外部 handler
```

Server 自己只处理**协议层的事**（心跳、握手），业务消息全部外抛。

#### 4. 连接生命周期 [_handle_connection()](file:///e:/firefly-hub/host/ws_server.py#72-94)

```python
async def _handle_connection(self, ws):
    session_id = str(uuid.uuid4())[:8]    # 分配 ID
    self.clients[session_id] = ws          # 注册
    try:
        async for raw_message in ws:       # 持续监听
            message = json.loads(raw_message)
            await self._dispatch_message(message, session_id)
    except ConnectionClosed:               # 断线
        pass
    finally:
        self.clients.pop(session_id)       # 清理
```

`async for raw_message in ws` 是 websockets 库提供的异步迭代器，会持续接收消息直到连接断开。**整个 try-finally 保证了无论正常断开还是异常断开，都会从客户端列表中清理掉。**

---

## 文件 2：main.py — AstrBot 插件与业务逻辑

### 设计理念

这个文件是 AstrBot 和 WebSocket 世界的**胶水层**。它继承 AstrBot 的 [Star](file:///D:/astrbot-develop/AstrBot/astrbot/core/star/base.py#15-88) 基类，利用 AstrBot 的生命周期管理 WebSocket Server，并处理从 Client 来的业务消息。

### 关键技术点

#### 1. AstrBot 插件注册（零配置）

```python
class FireflyHub(Star):
    ...
```

AstrBot v4.18.3 通过 [__init_subclass__](file:///D:/astrbot-develop/AstrBot/astrbot/core/star/base.py#37-49) 魔术方法**自动识别所有继承 Star 的类**，不需要任何装饰器。插件名称、版本等信息从 [metadata.yaml](file:///e:/firefly-hub/host/metadata.yaml) 读取。

#### 2. 生命周期钩子

```python
async def initialize(self):   # 插件激活 → 启动 WS Server
async def terminate(self):    # 插件禁用 → 关闭 WS Server
```

这两个方法是 AstrBot [Star](file:///D:/astrbot-develop/AstrBot/astrbot/core/star/base.py#15-88) 基类定义的，AstrBot 在插件加载/卸载时自动调用。我们在这里启动和关闭 WebSocket Server。

#### 3. Phase 1 Echo 响应

```python
async def _handle_chat_request(self, message, session_id):
    user_content = message["payload"]["content"]
    
    response = {
        "message_id": message["message_id"],  # 同一个 ID，请求/响应配对
        "type": "CHAT_RESPONSE",
        "payload": {
            "content": f"[Echo] {user_content}",  # 原样返回
            "status": "success",
            "persona": "default"
        }
    }
    
    await self.ws_server.send_to_client(session_id, response)
```

Phase 1 只做 Echo，Phase 2 这里会改成：把 `user_content` 提交给 AstrBot 的 LLM 管道，拿到 AI 回复后再发回去。

---

## 数据流时序（Phase 1 完整链路）

```
test_echo.py                    ws_server.py                    main.py
     │                               │                              │
     │── CONNECT ──────────────────→ │                              │
     │                               │── 自动回复连接确认            │
     │←── CONNECT (connected) ──────│                              │
     │                               │                              │
     │── PING ─────────────────────→ │                              │
     │                               │── 自动回 PONG                │
     │←── PONG ────────────────────│                              │
     │                               │                              │
     │── CHAT_REQUEST ─────────────→ │                              │
     │                               │── handler 回调 ────────────→ │
     │                               │                              │── 构造 Echo 响应
     │                               │←── send_to_client ──────────│
     │←── CHAT_RESPONSE ──────────│                              │
```

---

## 涉及的技术栈（简历可写）

| 技术 | 用在哪 |
|------|--------|
| **Python asyncio** | 全异步架构，WebSocket Server 和消息处理都基于协程 |
| **websockets 库** | 异步 WebSocket Server 实现 |
| **AstrBot 插件系统** | 继承 Star 基类，利用 initialize/terminate 生命周期钩子 |
| **JSON 自定义协议** | 设计了 Envelope 信封格式 + 六大消息类别 |
| **回调/依赖反转** | ws_server 不依赖业务逻辑，通过 on_message 注入 |
| **会话管理** | session_id 映射，支持多客户端并发连接 |
| **符号链接部署** | 开发时 symlink，不侵入 AstrBot 目录结构 |
