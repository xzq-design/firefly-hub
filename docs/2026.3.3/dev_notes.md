# Firefly-Hub 开发笔记：Phase 2 从 Echo 到 LLM 真回复

> 记录时间：2026-03-03  
> 内容：将 Host 从 Star 插件重构为 Platform 适配器，接入 AstrBot LLM 管道，实现真正的 AI 对话

---

## 一、Phase 2 目标

Phase 1 验证了通信链路（Echo），Phase 2 的核心任务是**让管道里流的不再是 Echo，而是 LLM 生成的真实回复**。

具体来说：
- Client 发的消息要进入 AstrBot 的 LLM 处理管道
- AstrBot 调用 LLM（DeepSeek）生成回复
- 回复通过 WebSocket 发回 Client
- 同时能读取 AstrBot 中已配置的人格列表

---

## 二、关键发现：Star vs Platform

### 研究过程

Phase 1 用的是 Star 插件，但研究 AstrBot 源码后发现一个关键问题：

**Star 插件** 只能：
- 注册命令（`/xxx`）
- 监听和拦截事件
- 被动处理别的平台产生的消息

**Platform 适配器** 能：
- 作为消息来源（和 QQ、Telegram 同级）
- 把消息注入 AstrBot 的事件队列
- 让 AstrBot EventBus 自动调 LLM 处理

简单说，Star 是"别人说话我插嘴"，Platform 是"我就是说话的那个人"。

### AstrBot 消息管道架构

```
QQ 适配器 ──┐
Telegram ───┤
Discord ────┤──→ EventBus ──→ 插件 Filter ──→ LLM 调用 ──→ event.send() 回复
WebChat ────┤
Firefly ────┘  ← 我们要加在这里
```

通过阅读 `webchat_adapter.py` 源码，总结出消息注入的模式：

```python
# 1. 构造 AstrBotMessage
abm = AstrBotMessage()
abm.sender = MessageMember(user_id="xxx", nickname="开拓者")
abm.message_str = "用户说的话"
abm.message = [Plain("用户说的话")]

# 2. 包装为自定义 MessageEvent
event = FireflyMessageEvent(message_str=..., message_obj=abm, ...)

# 3. 注入事件队列
self.commit_event(event)
# 之后 AstrBot 自动处理，调 LLM，调 event.send()
```

---

## 三、重构实现

### 3.1 架构变更

```
Phase 1:
  main.py (Star) → 收到 CHAT_REQUEST → 手动 Echo → 发回

Phase 2:
  main.py (Platform) → 收到 CHAT_REQUEST → 构造 AstrBotMessage
  → commit_event() → AstrBot EventBus → LLM → event.send()
  → firefly_event.py 重写的 send() → WebSocket → Client
```

### 3.2 新增文件：firefly_event.py

这是整个 Phase 2 最巧妙的设计——**重写 `send()` 方法**。

AstrBot 处理完消息后，会调用 `event.send(MessageChain)` 发送回复。每个平台通过重写 `send()` 定义"怎么把回复发出去"：
- QQ 适配器的 send() → 调用 QQ 的 API 发消息
- Telegram 的 send() → 调用 Telegram Bot API
- **我们的 send() → 转为 JSON，通过 WebSocket 发回 Client**

```python
class FireflyMessageEvent(AstrMessageEvent):
    async def send(self, message: MessageChain) -> None:
        # 把 MessageChain 转为纯文本
        text = self._chain_to_text(message)
        # 构造 CHAT_RESPONSE JSON
        response = {
            "type": "CHAT_RESPONSE",
            "payload": {"content": text, "status": "success"}
        }
        # 通过 WebSocket 发回 Client
        await self._ws_server.send_to_client(self._ws_session_id, response)
```

#### 什么是 MessageChain？

AstrBot 用 `MessageChain` 表示一条消息，它是多个组件的链：

```python
MessageChain([
    Plain("你好！"),           # 纯文本
    Image(url="..."),          # 图片
    Plain("这是一张猫的照片"),   # 又一段文本
])
```

我们通过 `_chain_to_text()` 把链拍平成纯文本（图片变成 `[图片]` 占位符）。

### 3.3 重写 main.py：Star → Platform

#### @register_platform_adapter 装饰器

```python
@register_platform_adapter(
    adapter_name="firefly_hub",
    desc="Firefly-Hub 自建消息前端平台适配器",
    default_config_tmpl={
        "type": "firefly_hub",
        "enable": True,
        "ws_host": "0.0.0.0",
        "ws_port": 8765,
    },
)
class FireflyHubAdapter(Platform):
    ...
```

这个装饰器做的事情：
1. 创建 `PlatformMetadata` 对象
2. 把类注册到 `platform_cls_map["firefly_hub"]`
3. AstrBot 的 `PlatformManager` 初始化时从 `cmd_config.json` 读取配置，找到 `type: firefly_hub`，去 `platform_cls_map` 查找对应类，实例化

#### Platform 生命周期

```python
class FireflyHubAdapter(Platform):
    def run(self):
        # AstrBot 把这个协程作为 asyncio.Task 启动
        return self._run()

    async def _run(self):
        await self.ws_server.start()
        self.status = PlatformStatus.RUNNING
        await self._shutdown_event.wait()  # 等待关闭信号

    async def terminate(self):
        self._shutdown_event.set()
        await self.ws_server.stop()
```

#### commit_event() 注入消息

```python
async def _handle_chat_request(self, message, ws_session_id):
    abm = AstrBotMessage()
    abm.sender = MessageMember(user_id=ws_session_id, nickname="开拓者")
    abm.message = [Plain(user_content)]
    # ...

    event = FireflyMessageEvent(
        message_str=user_content,
        message_obj=abm,
        ws_server=self.ws_server,       # 传入 WS Server 引用
        ws_session_id=ws_session_id,     # 传入会话 ID
    )

    self.commit_event(event)  # 注入！剩下全交给 AstrBot
```

### 3.4 读取 AstrBot 人格列表

AstrBot 的人格存储在 SQLite 数据库中，通过全局单例 `db_helper` 访问：

```python
from astrbot.core import db_helper

personas = await db_helper.get_personas()
# 每个 persona 有: persona_id, system_prompt, begin_dialogs, tools, skills
```

我们通过 `PERSONA_LIST` 消息返回给 Client，包含 prompt 前 200 字预览。

---

## 四、人格系统分层设计

通过这次研究，确定了人格系统的分层架构：

| 层级 | 管理方 | 内容 |
|------|--------|------|
| **后端人格** | AstrBot（数据库） | system_prompt、begin_dialogs、工具权限 |
| **前端主题** | Flutter Client（本地） | 头像、气泡颜色、主题色、UI 文案 |

两者**绑定但独立**——切换人格时同时切换后端 prompt 和前端主题，但也可以只改其中一个。

---

## 五、踩坑记录

### 坑 1：Star 和 Platform 不能直接替换

**现象**：去掉 Star 改成 Platform 后，`star_manager` 报 `IndexError: list index out of range`。  
**原因**：AstrBot 的 `star_manager` 扫描 plugins 目录时要求每个插件必须有 `Star` 子类。  
**解决**：保留一个空的 `FireflyHub(Star)` 壳类满足 star_manager，同时通过 `@register_platform_adapter` 独立注册 Platform 适配器。两个类共存，各走各的加载通道。

### 坑 2：Platform 加载时序

**问题**：`@register_platform_adapter` 装饰器需要在 `PlatformManager.initialize()` 之前执行，否则 `platform_cls_map` 里找不到。  
**AstrBot 的加载顺序**：
1. `plugin_manager.reload()` → 加载插件 → 触发 `__init__.py` 的 import → 执行装饰器 → 注册到 `platform_cls_map`
2. `platform_manager.initialize()` → 读取 `cmd_config.json` 的 platform 配置 → 从 `platform_cls_map` 找到类 → 实例化

时序恰好正确，插件先加载，平台后启动。

### 坑 3：PlatformManager 的 match/case 硬编码

**问题**：`load_platform()` 里有个 match/case 列举了所有内置适配器（aiocqhttp、telegram 等），我们的 `firefly_hub` 不在里面。  
**实际影响**：无。match/case 只是为了 lazy import 内置模块，走完 match/case 后会统一从 `platform_cls_map` 查找。我们的适配器已经通过装饰器提前注册了，所以能被正常找到。

### 坑 4：cmd_config.json 需要手动添加配置

**问题**：光注册适配器不够，还需要在 AstrBot 的配置文件 `cmd_config.json` 的 `platform` 数组中添加条目。  
**原因**：`PlatformManager.initialize()` 只遍历配置中的平台列表，不会自动发现已注册的适配器。

---

## 六、Phase 2 验证结果

| 测试项 | 结果 |
|--------|------|
| AstrBot 加载插件 + 平台适配器 | ✅ 同时加载 Star 壳 + Platform 适配器 |
| WebSocket Server 启动 | ✅ ws://0.0.0.0:8765 |
| CONNECT 握手 | ✅ |
| PING/PONG 心跳 | ✅ |
| CHAT_REQUEST → LLM 真回复 | ✅ 流萤人格回复（"好呀，宝宝..."） |
| PERSONA_LIST（真实数据） | ✅ 从 AstrBot 数据库读取 |
| PERSONA_SWITCH | ✅ |

**里程碑**：Phase 2 完成了从 Echo 到 AI 真回复的跨越——现在你的自建 App 和 QQ 一样能和 AI 聊天了，只不过走的是自己的 WebSocket 而不是腾讯的服务器。

---

## 七、当前文件结构

```
firefly-hub/
├── host/
│   ├── __init__.py          # 导出 FireflyHub + FireflyHubAdapter
│   ├── main.py              # Star 壳 + Platform 适配器（核心入口）
│   ├── ws_server.py         # WebSocket Server（Phase 1 基本不变）
│   ├── firefly_event.py     # [新] 重写 send() 实现 LLM 回复转发
│   ├── metadata.yaml        # 插件元数据 v0.2.0
│   └── personas/            # 前端主题包目录（后续）
├── test_echo.py             # 测试脚本（已更新为 LLM 断言）
└── docs/
    ├── dev_notes_phase1.md  # Phase 1 笔记
    └── 2026.3.3/
        └── dev_notes.md     # ← 本文件
```

---

## 八、下一步

- **流式输出**：已在 `firefly_event.py` 中实现了 `send_streaming()`，需要前端配合
- **OpenClaw + MCP**：让 AI 能通过只读工具查看文件和目录
- **Flutter Client**：搭建真正的聊天 App
- **PERSONA_UPDATE**：前端直接修改后端 prompt
