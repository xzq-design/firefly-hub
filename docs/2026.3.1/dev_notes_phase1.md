# Firefly-Hub 开发笔记：Phase 1 从零到 Echo 闭环

> 记录时间：2026-03-01  
> 内容：从项目规划到 Host 端 WebSocket Echo 闭环打通的完整过程

---

## 一、项目规划阶段

### 1.1 需求分析

**核心问题**：QQ 等第三方 IM 平台存在封号风险，需要一个自建的消息前端。

**解决方案**：Firefly-Hub —— 三端解耦架构
- **Client**（Flutter）：自建聊天 UI，替代 QQ
- **Host**（Python）：AstrBot 平台适配器，像 QQ 适配器一样对接 AstrBot
- **Agent**（OpenClaw + MCP）：AI 执行引擎，负责实际操作

**关键设计决策**：
1. Host 不是独立服务器，而是 **AstrBot 的一个平台适配器**。好处是可以复用 AstrBot 的 LLM 管理、会话记忆、插件生态。
2. 人格系统采用**可插拔设计**，流萤只是一个示例人格包，用户可以自定义。
3. 所有高危操作必须经过 **Human-in-the-loop 审批**。

### 1.2 通信协议设计

#### 什么是通信协议？

三端之间要通过网络传递消息，双方必须约定好"消息长什么样"，这就是协议。我们选择了：
- **传输层**：WebSocket（全双工、低延迟、适合实时聊天）
- **数据格式**：JSON（人类可读、易调试、前后端通用）

#### WebSocket vs HTTP

```
HTTP（半双工）：
Client ──请求──→ Server
Client ←──响应── Server
每次都是 Client 主动发起，Server 不能主动推消息。

WebSocket（全双工）：
Client ←──────→ Server
建立连接后双方可以随时互发消息，适合聊天场景。
```

#### Envelope（信封）设计

所有消息都包裹在统一的"信封"结构中：

```json
{
  "message_id": "msg-001",     // 唯一 ID，用于请求/响应配对
  "type": "CHAT_REQUEST",      // 消息类型，决定 payload 怎么解析
  "source": "client",          // 谁发的
  "target": "host",            // 发给谁
  "timestamp": 1700000000000,  // 时间戳
  "payload": { ... }           // 实际业务数据
}
```

**为什么需要 message_id？**
因为 WebSocket 是异步的——Client 可能同时发了 3 条消息，Server 回复的顺序不一定和发送顺序一致。有了 message_id，Client 就能把回复和请求对应上。

---

## 二、工程结构设计

### 2.1 Monorepo 结构

所有代码放在一个仓库里，通过目录区分三端：

```
firefly-hub/
├── host/                # AstrBot 平台适配器
│   ├── metadata.yaml    # AstrBot 插件元数据
│   ├── main.py          # 插件入口
│   ├── ws_server.py     # WebSocket Server
│   └── personas/        # 人格包目录
├── agent/               # OpenClaw + MCP（Phase 2+）
├── client/              # Flutter（Phase 2+）
├── protocol.json        # 协议定义
├── protocol_spec.md     # 协议说明文档
└── test_echo.py         # 测试脚本
```

### 2.2 符号链接（Symlink）

**问题**：AstrBot 只认 `data/plugins/` 目录下的插件，但我们的代码在 `E:\firefly-hub\host\`。

**解决方案**：用操作系统的符号链接，让 AstrBot 以为插件在它的目录下：

```bash
mklink /D "AstrBot路径\data\plugins\firefly_hub" "E:\firefly-hub\host"
```

#### 什么是符号链接？

符号链接（Symbolic Link）类似于快捷方式，但对操作系统来说它就是一个"真实目录"。程序访问链接路径时，操作系统会自动重定向到实际路径。

```
D:\astrbot\data\plugins\firefly_hub\  (符号链接)
         │
         └──→ E:\firefly-hub\host\  (实际文件)
```

**好处**：代码只维护一份，AstrBot 能加载到，Git 只管 firefly-hub 仓库。

---

## 三、编码实现

### 3.1 ws_server.py —— 只管通信的 WebSocket 层

#### 设计原则：职责分离

`ws_server.py` **只做三件事**：
1. 管理连接（谁连上了、谁断开了）
2. 收发消息（接收 JSON、发送 JSON）
3. 处理协议层事务（心跳、握手）

它**不知道也不关心** CHAT_REQUEST 该怎么回复——这是业务逻辑，交给 `main.py`。

#### 回调机制（依赖反转）

```python
class FireflyWSServer:
    def on_message(self, handler):
        """注册消息处理回调"""
        self._message_handler = handler
    
    async def _dispatch_message(self, message, session_id):
        if msg_type == "PING":
            # 自己处理（协议层）
        else:
            # 交给外部 handler（业务层）
            await self._message_handler(message, session_id)
```

**什么是回调（Callback）？**
回调就是"你先告诉我要做什么，等事情发生了我替你调用"。这里 `main.py` 把自己的处理函数注册进来，`ws_server.py` 在收到消息时调用它。

**什么是依赖反转（DIP）？**
正常逻辑是"底层调用上层"——ws_server 直接 import main.py 的函数。但这会导致紧耦合。依赖反转就是反过来：底层定义接口（回调），上层注入实现。这样 ws_server 可以完全独立测试和复用。

#### 异步迭代器

```python
async for raw_message in ws:
    message = json.loads(raw_message)
    await self._dispatch_message(message, session_id)
```

这是 Python asyncio 的写法。`async for` 会持续等待 WebSocket 上的新消息，每来一条就处理一条，直到连接断开。整个过程是**非阻塞**的——等待消息时不会卡住其他客户端的处理。

#### 什么是异步（async/await）？

```python
# 同步（阻塞）：一次只能做一件事
result = requests.get("http://example.com")  # 卡在这里等响应
# 其他客户端只能排队

# 异步（非阻塞）：等待时切换去做别的事
result = await aiohttp.get("http://example.com")  # 等待时去处理其他客户端
# 多个客户端可以"并发"处理
```

对于 WebSocket 服务器来说，同时可能有多个 Client 连接，异步是必须的。

### 3.2 main.py —— AstrBot 插件入口

#### AstrBot 插件机制

AstrBot 的插件系统基于 **Star 基类**：

```python
class Star:
    async def initialize(self):   # 插件激活时调用
    async def terminate(self):    # 插件禁用/重载时调用
```

所有继承 Star 的类会被 AstrBot **自动识别并注册**（通过 `__init_subclass__` 元编程实现）。你不需要手动注册，AstrBot 扫描 plugins 目录时看到继承了 Star 的类就会加载。

#### \_\_init_subclass\_\_ 是什么？

这是 Python 的元编程特性。当一个类被继承时，父类的 `__init_subclass__` 会自动被调用：

```python
class Star:
    def __init_subclass__(cls, **kwargs):
        # 每当有类继承 Star 时，这里自动执行
        # AstrBot 在这里把子类注册到插件列表中
        star_registry.append(cls)

class FireflyHub(Star):  # 定义这个类的瞬间，Star.__init_subclass__ 就被触发了
    pass
```

#### 生命周期管理

```python
class FireflyHub(Star):
    async def initialize(self):
        await self.ws_server.start()   # 插件激活 → 启动 WS Server
    
    async def terminate(self):
        await self.ws_server.stop()    # 插件禁用 → 关闭 WS Server
```

AstrBot 保证：`initialize()` 在插件可用时调用，`terminate()` 在插件被关闭时调用。我们利用这个机制管理 WebSocket Server 的启停。

---

## 四、踩坑记录

### 坑 1：生命周期钩子名称不对

**现象**：插件加载成功但 WebSocket Server 没启动。  
**原因**：我最初用的是 `on_star_loaded()`，但 AstrBot v4.18.3 实际的钩子名是 `initialize()`。  
**排查方法**：直接去读 AstrBot 源码 `astrbot/core/star/base.py`，找到正确的方法定义。  
**教训**：框架文档可能过时，源码才是真理。

### 坑 2：相对导入 vs 绝对导入

**现象**：`from .ws_server import ...` 报错 `attempted relative import with no known parent package`  
**原因**：直接运行 `python main.py` 时，Python 不知道它属于哪个包，所以相对导入失败。  
**但是**：通过 AstrBot 加载时，AstrBot 是用 `__import__` 以包的形式导入的，相对导入反而是对的。  
**结论**：相对导入 `from .ws_server` 是正确的，那个报错是因为直接运行 main.py 导致的。

### 坑 3：websockets v12+ API 变更

**现象**：`AttributeError: 'ServerConnection' object has no attribute 'closed'`  
**原因**：`websockets` 从 v12 开始，`ServerConnection` 去掉了 `.closed` 属性。  
**修复**：删掉 `ws.closed` 检查，改为直接 try-except 捕获发送异常。  
**教训**：第三方库的 API 在大版本更新时可能有 breaking change，要注意版本兼容。

### 坑 4：Docker vs 本地开发

**现象**：AstrBot 在 Docker 里运行，符号链接在容器内无法使用。  
**解决**：开发阶段改为本地运行 AstrBot，把 Docker 的 data 目录复制出来共享。  
**建议**：开发用本地（快速迭代），部署用 Docker（稳定运行）。

---

## 五、Phase 1 验证结果

test_echo.py 依次测试了 5 个场景，全部通过：

| 测试项 | 发送 | 期望回复 | 结果 |
|--------|------|---------|------|
| CONNECT 握手 | `CONNECT` | `status: connected` | ✅ |
| 心跳 | `PING` | `PONG` | ✅ |
| Echo 对话 | `CHAT_REQUEST` | `[Echo] 原文` | ✅ |
| 人格列表 | `PERSONA_LIST` | 包含 firefly 和 default | ✅ |
| 人格切换 | `PERSONA_SWITCH` | `status: switched` | ✅ |

---

## 六、下一步（Phase 2 预览）

Phase 1 的 Echo 只是验证通信链路。Phase 2 要做的是把 `_handle_chat_request` 里的 Echo 替换成**真正的 AstrBot LLM 调用**：

```python
# Phase 1（当前）
response_content = f"[Echo] {user_content}"

# Phase 2（下一步）
# 1. 把 user_content 提交给 AstrBot 消息管道
# 2. AstrBot 调用 LLM 生成回复
# 3. 把 LLM 回复发回给 Client
response_content = await self.context.send_to_llm(user_content)
```

同时还会接入 OpenClaw Agent 和只读 MCP 工具。
