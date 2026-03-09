# Phase 2 实现方案：Host 从 Star 插件升级为 Platform 适配器

## 背景

通过阅读 AstrBot 源码发现：**Star 插件** 只能被动处理已有平台的消息（添加命令、拦截事件等），**无法作为消息来源**注入消息。要让 Firefly-Hub 的 WebSocket Client 消息进入 AstrBot 的 LLM 管道，必须将 Host 注册为 **Platform 适配器**（和 QQ、Telegram 适配器同级）。

## 核心架构变更

```
Phase 1（当前）：Star 插件模式
  Client → WebSocket → main.py (Star) → 手动 Echo 回复

Phase 2（目标）：Platform 适配器模式
  Client → WebSocket → main.py (Platform) → commit_event()
         → AstrBot EventBus → LLM 处理 → event.send()
         → firefly_event.py (重写 send) → WebSocket → Client
```

> [!IMPORTANT]
> 这是一次**架构升级**，不是简单的代码修改。[main.py](file:///e:/firefly-hub/host/main.py) 将从继承 [Star](file:///D:/astrbot-develop/AstrBot/astrbot/core/star/base.py#15-88) 改为继承 [Platform](file:///D:/astrbot-develop/AstrBot/astrbot/core/platform/platform.py#36-166)，整个消息处理逻辑会从"手动 Echo"变为"注入 AstrBot 事件队列由框架自动处理"。

---

## Proposed Changes

### Host 核心模块

#### [MODIFY] [main.py](file:///e:/firefly-hub/host/main.py)

- 从继承 [Star](file:///D:/astrbot-develop/AstrBot/astrbot/core/star/base.py#15-88) 改为继承 [Platform](file:///D:/astrbot-develop/AstrBot/astrbot/core/platform/platform.py#36-166)
- 用 `@register_platform_adapter("firefly_hub", ...)` 注册为平台适配器
- [run()](file:///D:/astrbot-develop/AstrBot/astrbot/core/platform/sources/webchat/webchat_adapter.py#223-230) 方法中启动 WebSocket Server
- 收到消息后：构造 [AstrBotMessage](file:///D:/astrbot-develop/AstrBot/astrbot/core/platform/astrbot_message.py#50-90) → 包装为 `FireflyMessageEvent` → [commit_event()](file:///D:/astrbot-develop/AstrBot/astrbot/core/platform/platform.py#143-146) 注入队列
- 实现 [meta()](file:///D:/astrbot-develop/AstrBot/astrbot/core/platform/sources/webchat/webchat_adapter.py#231-233) 返回 [PlatformMetadata](file:///D:/astrbot-develop/AstrBot/astrbot/core/platform/platform_metadata.py#4-38)
- 实现 [send_by_session()](file:///D:/astrbot-develop/AstrBot/astrbot/core/platform/platform.py#132-142) 支持主动消息推送

#### [NEW] [firefly_event.py](file:///e:/firefly-hub/host/firefly_event.py)

- 继承 [AstrMessageEvent](file:///D:/astrbot-develop/AstrBot/astrbot/core/platform/astr_message_event.py#34-470)
- 重写 [send(message_chain)](file:///D:/astrbot-develop/AstrBot/astrbot/core/platform/sources/webchat/webchat_event.py#132-136) — AstrBot 处理完消息后调用此方法，我们将 `MessageChain` 转为 JSON 通过 WebSocket 发回 Client
- 重写 [send_streaming(generator)](file:///D:/astrbot-develop/AstrBot/astrbot/core/platform/astr_message_event.py#255-268) — 处理流式 LLM 输出，逐块发送 `CHAT_STREAM_CHUNK`

#### [MODIFY] [ws_server.py](file:///e:/firefly-hub/host/ws_server.py)

- 基本不变，只调整回调签名适配新架构

#### [MODIFY] [metadata.yaml](file:///e:/firefly-hub/host/metadata.yaml)

- 更新描述为 Platform 适配器

---

## 数据流（改造后）

```
Flutter Client                     ws_server.py              main.py (Platform)           AstrBot
     │                                  │                         │                          │
     │── CHAT_REQUEST ────────────────→ │                         │                          │
     │                                  │── callback ───────────→ │                          │
     │                                  │                         │── AstrBotMessage 构造     │
     │                                  │                         │── FireflyMessageEvent    │
     │                                  │                         │── commit_event() ──────→ │
     │                                  │                         │                          │── EventBus 处理
     │                                  │                         │                          │── 插件 filter
     │                                  │                         │                          │── LLM 调用
     │                                  │                         │                          │── 调用 event.send()
     │                                  │                         │←── send(MessageChain) ──│
     │                                  │←── send_to_client ─────│                          │
     │←── CHAT_RESPONSE ──────────────│                         │                          │
```

---

## Verification Plan

### 自动化测试

修改 [test_echo.py](file:///e:/firefly-hub/test_echo.py)：
- 发送 `CHAT_REQUEST`，期望收到 `CHAT_RESPONSE`（内容不再是 `[Echo]` 前缀，而是 LLM 生成的回复）
- 验证 [persona](file:///e:/firefly-hub/host/main.py#118-143) 字段正确
- 测试流式输出：发送请求后期望收到多个 `CHAT_STREAM_CHUNK` + 最终 `CHAT_RESPONSE`

```bash
python E:\firefly-hub\test_echo.py
```

### 手动验证

1. 启动 AstrBot（本地），确认日志中出现 `平台适配器 firefly_hub 已注册` 和 `WebSocket Server 已启动`
2. 运行测试脚本发送消息，确认 AstrBot 终端显示 LLM 调用日志
3. 在 AstrBot WebUI (http://localhost:6185) 中确认 firefly_hub 平台适配器出现在平台列表中
