# Lumi-Hub 开发笔记：破旧立新 (拥抱 MCP，打通记忆与 UI 蜕变)

> 记录时间：2026-03-08
> 内容：今天完成了一次重大的架构清理与功能跃升。正式决定废弃臃肿的 OpenClaw，全面倒向原生 MCP 协议。同时，引入 SQLite 彻底打通了 AstrBot 的用户记忆持久化闭环。在客户端（Flutter），我们深入原生 C++ 层，打造了多项堪比主流商业 IM 软件的流畅体验。

---

## 一、架构层面的“破局”：从黑盒 OpenClaw 到原生的 MCP 协议

在之前的构想中，系统采用了“原生（Native）+ OpenClaw”的双轨制，试图用 OpenClaw 作为高级操作的执行引擎。但在今天的深度技术沙盘推演中，我们发现了它的根本局限，做出了**彻底移除 OpenClaw (`agent_client.py`)，直接在 Host 内部集成 MCP Client** 的重磅决定。

### 1. 概念引入：什么是 MCP (Model Context Protocol)?

MCP 是由 Anthropic (Claude的母公司) 牵头推出的一种标准化通信协议（底层多基于 JSON-RPC 或 stdio）。它的核心思想是解耦：
- **MCP Client (大模型/Agent端)**：只负责“思考”和“发出请求”。
- **MCP Server (工具端)**：提供具体能力（如读取本地 Git 仓库、操作 MySQL 数据库、搜索 Notion 文档等）。

**知识点**：MCP 的伟大之处在于统一了接口规范。只要大模型支持 MCP 协议，它就能瞬间挂载全世界开发者写好的成百上千个能力 Server，而不需要为每一个新工具去单独编写 API 对接代码。

### 2. 为什么要“挥泪斩 OpenClaw”？

1. **链路冗长导致的可控性丧失（“黑盒效应”）**
   - **过去**：Host 拦截消息 -> 封装为 WebSocket (Agent Protocol) 发给远端 OpenClaw -> OpenClaw 再去解析并调用 MCP Server。
   - **痛点**：OpenClaw 强行在中间加了一层非常厚的沙盒与状态机。这意味着如果 Agent 发出的某个工具调用参数出错，报错会在 OpenClaw 内部被吞掉或转义，造成极度痛苦的 Debug 体验。
   - **重构后**：Agent 直接在极轻巧的 Python Host 内“直连”各大 MCP Server。去中心化，拒绝中间商赚差价。
2. **HitL（Human-in-the-loop 人机流）的架构排斥**
   - Lumi-Hub 的核心卖点是**安全**：高危的写入操作必须等待 Flutter 客户端的用户进行授权。
   - 如果执意使用远端的 OpenClaw，它一旦开始执行任务链，就极难被中途优雅地挂起并提取确切的状态上下文给前端展示。而在原生 Host 内集成 MCP Client，我们可以直接在 Python 函数调用的切面上做拦截（AOP 思想），轻松通过 WebSocket 发送 `AUTH_REQUIRED` 询问 UI 界面，拿到结果后再继续 `await`。

---

## 二、持久化与账号体系：SQLite 与 SQLAlchemy 的工程实践

为了让每一次重启不再“失忆”，今天重构了整个底层的消息流转逻辑。

### 1. 为什么选择 SQLite + SQLAlchemy？
- **SQLite 的优势**：对于这种主要运行在单机或私有云、以本地 I/O 为主的轻量服务端，SQLite 的“零配置、单文件”属性极大降低了部署门槛。对于少量并发的个人 Assistant 场景，甚至不存在锁表瓶颈。
- **SQLAlchemy 的前瞻性**：虽然原生 SQL 也能写，但引入 SQLAlchemy 作为 ORM（对象关系映射）层，是为了后续的 **Multi-Persona (多人格)** 铺路。当我们未来需要进行复杂的跨表查询（例如：查询用户 A 在人格 B 下的历史聊天）时，ORM 能帮我们省去大量易错的硬编码 SQL，并天然防范 SQL 注入。

### 2. Session Bind (上下文记忆打通) 的实现原理
长久以来，LLM 平台的通病是：WebSocket 每次断开重连，就会生成一个新的随机 ID，导致大模型以为你在开启新对话。
- **今天的突破**：我们在 Host 层的通信桥梁中，强制提取已登录用户的静态唯一 `User ID`，将其作为 AstrBot 的 `Session ID` 和 `Sender ID` 强行灌入。
- **效果**：无论 Flutter 客户端如何被杀进程重启，只要账号不变，AstrBot 就会从数据库直接恢复其对应的长期记忆链。

### 3. 深坑记录：UTC 与 Local Timezone 的换算错觉
- **现象**：Flutter 展示的消息时间，总是比真实时间早了 8 个小时。
- **原因与知识点**：在 Python 存入数据库时使用了 `datetime.utcnow()`，这在库里是一个“Naive（无时区概念）”的时间对象。当拉取它并调用 `.timestamp()` 转为 POSIX 秒数时，Python 底层的 C 实现会**默认你提供的是本地时间**（Local Time），于是又强行减去了东八区的 8 小时。
- **解法**：在转换前，显式地给时间对象打上 UTC 烙印 `msg.timestamp.replace(tzinfo=datetime.timezone.utc).timestamp()`，这样底层就会在计算 POSIX 时间戳时正确规避本土的偏移，令前端得以获取到纯净的世界统一毫秒数。

---

## 三、客户端 (Flutter) 的史诗级体验翻新

一个优秀的 Agent 框架除了强大的后端，还需要能令人产生愉悦感的前端交互。今天对许多底层的 Flutter 和 C++ 代码动了刀，解决了几个顽疾：

### 1. 0.618 黄金比例启动（消灭原生框架的启动白屏）
- **现象**：传统的 Flutter Desktop 启动时，无论怎么配置，都会短暂闪烁一个由 Win32 API 创建的默认大小的纯白窗口。
- **原理与解法**：这个窗口实质上是 C++ 层的 `HWND`。通过引入 `screen_retriever` 读取物理显示器尺寸，并计算 0.618 黄金分割比。更核心的是：**我们直接修改了底层的 `windows/runner/flutter_window.cpp`**，删除了 Flutter 引擎初始化的 `this->Show()`，将其扣留。把显示时机的控制权彻底交还给 dart 层的 `window_manager`，让它在尺寸和位置完全就绪（`waitUntilReadyToShow`）后再优雅呼出，实现了真正意义上的无缝冷启动。

### 2. 跨气泡的自由文本选择 (Native-like Selection)
- **痛点**：普通聊天应用中，往往只能复制单条信息的某一行，无法进行像网页那样丝滑的全选跨段落操作。
- **解法**：深入分析 Flutter 的渲染树，发现并关闭了 `MarkdownBody` 内置的排他性 `selectable` 属性，转而在整个 `ListView.builder` 外围套上了一个全局的 `SelectionArea` 门面。这使得底层渲染引擎将整个聊天滚动的列表视为一块完整的可选画布，完美还原了原生桌面应用的选区体验。

### 3. 悬浮时间戳与沉浸式过场
- 摒弃了生硬的加载条，在检测到本地 Token 时渲染出带有毛玻璃淡入的“自动登录中”页面。
- 将原本突兀居中的时间气泡，重构为基于 `MouseRegion` 与 `AnimatedOpacity` 的定制态。现在它会跟随鼠标的长悬停，聪慧地出现在对方/己方泡泡的最边缘处上浮，既保持了极简，又留住了功能性。

---

## 四、下一步规划 (Roadmap)

我们现在的基建已经异常扎实了，下一阶段的任务是向更高的交互维度进发：

1. **高危权限审批弹窗 (HitL / Human-in-the-loop)**
   - 在 Flutter 端开发一个帅气的“安全拦截确认框”。当 Host 拦截到 `write_file` 等行为时，必须拿到前端的许可指令才放行。
2. **多人格横向架构支持 (Multi-Persona)**
   - 当前的 `ws_service` 是单身绑定的。未来我们将拉取 AstrBot 的 Personsa 列表，并在左侧导航栏将其渲染为“联系人”。切换不同联系人时，即可动态切换聊天室与背后的系统 Prompt。
3. **原生 MCP Client 集成**
   - 正式在 Host 侧引入开源的 Python MCP 客户端，试水挂载第一个外部工具 Server。
