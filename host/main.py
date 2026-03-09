"""
Lumi-Hub AstrBot 平台适配器
作为 AstrBot 的自定义消息平台，替代 QQ 对接 AstrBot。
WebSocket Client 的消息通过此适配器进入 AstrBot 的 LLM 管道。
"""
import asyncio
import time
import uuid
import logging
from collections.abc import Coroutine
from typing import Any

from astrbot.core import db_helper

from astrbot.core.platform import (
    AstrBotMessage,
    MessageMember,
    MessageType,
    Platform,
    PlatformMetadata,
)
from astrbot.core.platform.astr_message_event import MessageSesion
from astrbot.core.platform.register import register_platform_adapter
from astrbot.core.message.message_event_result import MessageChain
from astrbot.core.message.components import Plain
from astrbot.core.star import Star

from .ws_server import LumiWSServer
from .lumi_event import LumiMessageEvent
from .database.manager import DatabaseManager

logger = logging.getLogger("lumi_hub")


from astrbot.api.event import filter, AstrMessageEvent
from astrbot.api.star import register

@register("lumi_hub", "Lumi-Hub", "Lumi-Hub Native Tools Plugin", "1.0.0")
class LumiHub(Star):
    """AstrBot 插件壳与原生工具中心。
    包含轻量级的原生 Python 本地执行工具 (双轨制 - Python Native Track)
    """

    async def initialize(self) -> None:
        """插件启动时，深度优化 AI 的 Agent 意识"""
        try:
            pm = self.context.persona_manager
            persona_id = pm.default_persona
            persona = await pm.get_persona(persona_id)
            
            agent_trigger = "### LUMI_IDE_AGENT_v2 ###"
            # 采用 IDE 风格的强力指令集
            agent_prompt = (
                f"\n\n{agent_trigger}\n"
                "【核心指令集：IDE 模式】\n"
                "你现在是一个具备完整权限的高级软件工程师 Agent。你的工作效率取决于你的“少说多做”。\n"
                "1. **ReAct 循环**：当你收到代码修改请求，请务必遵循：[思考 -> 读 -> 思考 -> 改/增/删 -> 验证]。\n"
                "2. **严禁中断**：一旦 `read_file` 成功返回，你必须立即分析并调用 `search_replace` 或 `insert_content`。严禁在读取成功后向用户汇报“我已经读到了，这是内容”，除非你的最终修改已完成。\n"
                "3. **精准编辑**：优先使用 `search_replace`。提供待修改的一段唯一的原始代码块（SEARCH）和替换后的代码块（REPLACE）。注意缩进必须严格匹配。\n"
                "4. **主动性**：如果你不确定文件路径，先用 `list_dir`。发现错误时，先 `read_file` 报错行号。一切以解决问题为导向，而非复读代码内容。\n"
                "########################"
            )
            
            cleaned_prompt = persona.system_prompt
            # 清理历史旧版指令标签（如果有）
            for old_tag in ["### LUMI_AGENT_RULES ###", "### LUMI_IDE_AGENT_v1 ###"]:
                if old_tag in cleaned_prompt:
                    idx = cleaned_prompt.find(old_tag)
                    cleaned_prompt = cleaned_prompt[:idx].strip()
            
            if agent_trigger not in cleaned_prompt:
                new_prompt = cleaned_prompt + agent_prompt
                await pm.update_persona(persona_id, system_prompt=new_prompt)
                logger.info(f"[Lumi-Hub] 已成功升级为人格 '{persona_id}' 注入 IDE-Style Agent 指令。")
        except Exception as e:
            logger.error(f"[Lumi-Hub] 增强人格失败: {e}")

    @filter.command("test_lumi")
    async def test_lumi(self, event: AstrMessageEvent):
        '''测试 Lumi-Hub 插件是否加载成功'''
        yield event.plain_result("Lumi-Hub 原生工具插件已就绪！")

    @filter.llm_tool(name="read_file")
    async def read_file(self, event: AstrMessageEvent, path: str, start_line: int = 1, end_line: int = None):
        '''读取本地指定路径文件的内容。支持分页读取。
        注意：输出中的 Lx: 前缀是行号参考，不是文件内容，修改时请忽略。
        Args:
            path(string): 文件的结构完整路径
            start_line(number): 起始行号，默认为 1
            end_line(number): 结束行号（包左不包右），不填则读取到末尾
        '''
        logger.info(f"LLM 正在调用 read_file: {path} ({start_line}-{end_line})")
        from .native_tools import read_file
        return read_file(path, start_line, end_line)

    @filter.llm_tool(name="search_replace")
    async def search_replace(self, event: AstrMessageEvent, path: str, search_block: str, replace_block: str):
        '''【最推荐】IDE 风格的搜索替换。
        Args:
            path(string): 文件完整路径
            search_block(string): 必须提供待替换的原始代码片段（必须是在文件中唯一存在的，包含正确的缩进）。
            replace_block(string): 替换后的新代码片段。
        '''
        if hasattr(event, "wait_for_auth"):
            approved = await event.wait_for_auth(
                action_type="FILE_MODIFY",
                target_path=path,
                description=f"修改文件并应用 SEARCH/REPLACE 块。",
                tool_name="search_replace",
                diff_preview=f"SEARCH:\n{search_block}\n\nREPLACE:\n{replace_block}"
            )
            if not approved:
                return "Error: User rejected the file modification."

        from .native_tools import search_replace
        return search_replace(path, search_block, replace_block)

    @filter.llm_tool(name="insert_content")
    async def insert_content(self, event: AstrMessageEvent, path: str, line_number: int, content: str):
        '''【推荐】在文件的指定行号位置插入新内容。
        Args:
            path(string): 文件的结构完整路径
            line_number(number): 要插入的目标行号（1-indexed）
            content(string): 要插入的文本内容（会自动换行）
        '''
        if hasattr(event, "wait_for_auth"):
            approved = await event.wait_for_auth(
                action_type="FILE_MODIFY",
                target_path=path,
                description=f"在第 {line_number} 行插入内容。",
                tool_name="insert_content",
                diff_preview=content
            )
            if not approved:
                return "Error: User rejected the file modification."

        from .native_tools import insert_content
        return insert_content(path, line_number, content)


    @filter.llm_tool(name="list_dir")
    async def list_dir(self, event: AstrMessageEvent, path: str):
        '''列出本地指定目录下的文件和文件夹。
        Args:
            path(string): 文件夹的结构完整路径
        '''
        from .native_tools import list_dir
        return list_dir(path)
        
    @filter.llm_tool(name="write_file")
    async def write_file(self, event: AstrMessageEvent, path: str, content: str):
        '''【高危操作】将内容写入到本地文件中。操作前会自动备份原文件。如果文件不存在则新建。
        Args:
            path(string): 文件的结构完整路径
            content(string): 要写入的完整内容
        '''
        if hasattr(event, "wait_for_auth"):
            import os
            approved = await event.wait_for_auth(
                action_type="FILE_CREATE" if not os.path.exists(path) else "FILE_MODIFY",
                target_path=path,
                description=f"全量写入文件内容。",
                tool_name="write_file",
                diff_preview=content[:500] + ("..." if len(content) > 500 else "")
            )
            if not approved:
                return "Error: User rejected the file operation."

        from .native_tools import write_file
        return write_file(path, content)

    @filter.llm_tool(name="delete_file")
    async def delete_file(self, event: AstrMessageEvent, path: str):
        '''【高危操作】删除本地指定路径的文件。操作前会自动备份原文件到 .Lumi_cache。
        Args:
            path(string): 文件的结构完整路径
        '''
        if hasattr(event, "wait_for_auth"):
            approved = await event.wait_for_auth(
                action_type="FILE_DELETE",
                target_path=path,
                description=f"物理删除文件（已自动备份）。",
                tool_name="delete_file"
            )
            if not approved:
                return "Error: User rejected the file deletion."

        from .native_tools import delete_file
        return delete_file(path)

    @filter.llm_tool(name="replace_content")
    async def replace_content(self, event: AstrMessageEvent, path: str, old_content: str, new_content: str):
        '''【推荐】精确修改文件内容。仅当您只需修改文件的一小部分时使用。必须提供唯一的 old_content。
        Args:
            path(string): 文件的结构完整路径
            old_content(string): 要被替换的原始代码片段（必须唯一）
            new_content(string): 替换后的新代码片段
        '''
        if hasattr(event, "wait_for_auth"):
            approved = await event.wait_for_auth(
                action_type="FILE_MODIFY",
                target_path=path,
                description=f"精确替换文件内容。",
                tool_name="replace_content",
                diff_preview=f"OLD:\n{old_content}\n\nNEW:\n{new_content}"
            )
            if not approved:
                return "Error: User rejected the file modification."

        from .native_tools import replace_content
        return replace_content(path, old_content, new_content)



    @filter.llm_tool(name="get_file_size")
    async def get_file_size(self, event: AstrMessageEvent, path: str):
        '''获取文件的字节数大小
        Args:
            path(string): 文件的结构完整路径
        '''
        from .native_tools import get_file_size
        return get_file_size(path)
@register_platform_adapter(
    adapter_name="lumi_hub",
    desc="Lumi-Hub 自建消息前端平台适配器",
    adapter_display_name="Lumi-Hub",
    default_config_tmpl={
        "type": "lumi_hub",
        "enable": True,
        "id": "lumi_hub",
        "ws_host": "0.0.0.0",
        "ws_port": 8765,
    },
    support_streaming_message=True,
)
class LumiHubAdapter(Platform):
    """Lumi-Hub 平台适配器。

    功能：
    1. 启动 WebSocket Server，接收 Flutter Client 连接
    2. 将 Client 消息转为 AstrBotMessage，注入 AstrBot 事件队列
    3. AstrBot 处理后通过 LumiMessageEvent.send() 回复给 Client
    """

    def __init__(
        self,
        platform_config: dict,
        platform_settings: dict,
        event_queue: asyncio.Queue,
    ) -> None:
        super().__init__(platform_config, event_queue)

        self.settings = platform_settings
        ws_host = platform_config.get("ws_host", "0.0.0.0")
        ws_port = platform_config.get("ws_port", 8765)

        self.ws_server = LumiWSServer(host=ws_host, port=ws_port)
        self.ws_server.on_message(self._handle_client_message)

        # 初始化数据库管理器，数据存放在项目根目录下的 data 文件夹
        import os
        host_dir = os.path.dirname(os.path.abspath(__file__))
        project_root = os.path.dirname(host_dir)
        data_dir = os.path.join(project_root, "data")
        self.db = DatabaseManager(data_dir=data_dir)
        
        # 记录已验证的 websocket session -> user_id
        self.active_sessions: dict[str, int] = {}

        self.metadata = PlatformMetadata(
            name="lumi_hub",
            description="Lumi-Hub 自建消息前端",
            id=platform_config.get("id", "lumi_hub"),
            adapter_display_name="Lumi-Hub",
            support_streaming_message=True,
            support_proactive_message=True,
        )

        self._shutdown_event = asyncio.Event()

    def run(self) -> Coroutine[Any, Any, None]:
        """返回平台运行协程，AstrBot 会将其作为 asyncio.Task 启动。"""
        return self._run()

    async def _run(self) -> None:
        """启动 WebSocket Server 并等待关闭信号。"""
        try:
            await self.ws_server.start()
            self.status = __import__(
                "astrbot.core.platform.platform", fromlist=["PlatformStatus"]
            ).PlatformStatus.RUNNING
            logger.info("[Lumi-Hub] 平台适配器已启动")
            await self._shutdown_event.wait()
        except Exception as e:
            logger.error(f"[Lumi-Hub] 平台适配器启动失败: {e}")
            raise

    async def terminate(self) -> None:
        """关闭平台适配器。"""
        logger.info("[Lumi-Hub] 平台适配器关闭中...")
        await self.ws_server.stop()

    def meta(self) -> PlatformMetadata:
        """返回平台元数据。"""
        return self.metadata

    async def send_by_session(
        self,
        session: MessageSesion,
        message_chain: MessageChain,
    ) -> None:
        """通过会话发送主动消息（插件主动推送）。"""
        # 从 session_id 中提取 user_id 和 context_id
        # 格式: lumi_hub!{user_id}!{context_id}
        parts = session.session_id.split("!")
        user_id = None
        if len(parts) >= 3:
            try:
                user_id = int(parts[1])
            except ValueError:
                pass

        text_parts = []
        for comp in message_chain.chain:
            if isinstance(comp, Plain):
                text_parts.append(comp.text)
                
        content_str = "".join(text_parts)

        if content_str and user_id is not None:
            # 存入数据库 (无论用户是否在线、连接是否存在都可以保存)
            self.db.save_message(user_id=user_id, role="assistant", content=content_str)
            
            # 查找所有关联到该 user_id 的 ws_session_id 并分发
            target_ws_ids = [ws_id for ws_id, uid in self.active_sessions.items() if uid == user_id]
            for ws_id in target_ws_ids:
                msg = {
                    "message_id": str(uuid.uuid4())[:8],
                    "type": "CHAT_RESPONSE",
                    "source": "host",
                    "target": "client",
                    "timestamp": int(time.time() * 1000),
                    "payload": {
                        "content": content_str,
                        "status": "success",
                        "persona": "default",
                    },
                }
                await self.ws_server.send_to_client(ws_id, msg)

        await super().send_by_session(session, message_chain)

    # ---------- WebSocket 消息处理 ----------

    async def _handle_client_message(self, message: dict, ws_session_id: str) -> None:
        """处理从 WebSocket Client 收到的业务消息。"""
        msg_type = message.get("type", "")

        if msg_type == "CHAT_REQUEST":
            await self._handle_chat_request(message, ws_session_id)
        elif msg_type == "PERSONA_SWITCH":
            await self._handle_persona_switch(message, ws_session_id)
        elif msg_type == "PERSONA_LIST":
            await self._handle_persona_list(message, ws_session_id)
        elif msg_type == "AUTH_REGISTER":
            await self._handle_auth_register(message, ws_session_id)
        elif msg_type == "AUTH_LOGIN":
            await self._handle_auth_login(message, ws_session_id)
        elif msg_type == "AUTH_RESTORE":
            await self._handle_auth_restore(message, ws_session_id)
        elif msg_type == "HISTORY_REQUEST":
            await self._handle_history_request(message, ws_session_id)
        else:
            logger.warning(f"[Lumi-Hub] 未知消息类型: {msg_type}")

    async def _handle_auth_register(self, message: dict, ws_session_id: str) -> None:
        payload = message.get("payload", {})
        username = payload.get("username", "")
        password = payload.get("password", "")
        
        result = self.db.create_user(username, password)
        msg_id = message.get("message_id", str(uuid.uuid4())[:8])
        
        if "error" in result:
            await self.ws_server.send_to_client(ws_session_id, {
                "message_id": msg_id, "type": "AUTH_RESPONSE", "source": "host", "target": "client",
                "payload": {"status": "error", "message": result["error"]}
            })
        else:
            # 注册成功直接登录
            self.active_sessions[ws_session_id] = result["id"]
            await self.ws_server.send_to_client(ws_session_id, {
                "message_id": msg_id, "type": "AUTH_RESPONSE", "source": "host", "target": "client",
                "payload": {"status": "success", "user": {"id": result["id"], "username": result["username"]}, "token": str(result["id"])}
            })
            logger.info(f"[Lumi-Hub] 用户注册并登录成功: {username}")

    async def _handle_auth_login(self, message: dict, ws_session_id: str) -> None:
        payload = message.get("payload", {})
        username = payload.get("username", "")
        password = payload.get("password", "")
        
        result = self.db.verify_user(username, password)
        msg_id = message.get("message_id", str(uuid.uuid4())[:8])
        
        if "error" in result:
            await self.ws_server.send_to_client(ws_session_id, {
                "message_id": msg_id, "type": "AUTH_RESPONSE", "source": "host", "target": "client",
                "payload": {"status": "error", "message": result["error"]}
            })
        else:
            self.active_sessions[ws_session_id] = result["id"]
            await self.ws_server.send_to_client(ws_session_id, {
                "message_id": msg_id, "type": "AUTH_RESPONSE", "source": "host", "target": "client",
                "payload": {"status": "success", "user": {"id": result["id"], "username": result["username"]}, "token": str(result["id"])}
            })
            logger.info(f"[Lumi-Hub] 用户登录成功: {username}")

    async def _handle_auth_restore(self, message: dict, ws_session_id: str) -> None:
        payload = message.get("payload", {})
        token = payload.get("token", "")
        msg_id = message.get("message_id", str(uuid.uuid4())[:8])

        if not token:
            return

        try:
            user_id = int(token)
            user = self.db.get_user_by_id(user_id)
            if user:
                self.active_sessions[ws_session_id] = user_id
                await self.ws_server.send_to_client(ws_session_id, {
                    "message_id": msg_id, "type": "AUTH_RESPONSE", "source": "host", "target": "client",
                    "payload": {"status": "success", "user": user, "token": token}
                })
                logger.info(f"[Lumi-Hub] 用户通过 Token 恢复会话成功: {user['username']}")
            else:
                await self.ws_server.send_to_client(ws_session_id, {
                    "message_id": msg_id, "type": "AUTH_RESPONSE", "source": "host", "target": "client",
                    "payload": {"status": "error", "message": "Invalid token"}
                })
        except ValueError:
            await self.ws_server.send_to_client(ws_session_id, {
                "message_id": msg_id, "type": "AUTH_RESPONSE", "source": "host", "target": "client",
                "payload": {"status": "error", "message": "Malformed token"}
            })

    async def _handle_history_request(self, message: dict, ws_session_id: str) -> None:
        user_id = self.active_sessions.get(ws_session_id)
        msg_id = message.get("message_id", str(uuid.uuid4())[:8])
        if not user_id:
            logger.warning(f"[Lumi-Hub] 拒绝未登录用户的历史记录请求")
            await self.ws_server.send_to_client(ws_session_id, {
                "message_id": msg_id, "type": "ERROR_ALERT", "source": "host", "target": "client",
                "payload": {"error_code": "UNAUTHORIZED", "detail": "请先登录"}
            })
            return
            
        payload = message.get("payload", {})
        limit = payload.get("limit", 50)
        offset = payload.get("offset", 0)
        
        messages = self.db.get_messages(user_id=user_id, limit=limit, offset=offset)
        
        await self.ws_server.send_to_client(ws_session_id, {
            "message_id": msg_id,
            "type": "HISTORY_RESPONSE",
            "source": "host",
            "target": "client",
            "timestamp": int(time.time() * 1000),
            "payload": {
                "messages": messages,
                "has_more": len(messages) == limit
            }
        })

    async def _handle_chat_request(self, message: dict, ws_session_id: str) -> None:
        """
        处理 CHAT_REQUEST：
        1. 构造 AstrBotMessage
        2. 包装为 LumiMessageEvent
        3. commit_event() 注入 AstrBot 事件队列
        4. AstrBot 自动调 LLM → 调用 event.send() → WebSocket 回传
        """
        payload = message.get("payload", {})
        user_content = payload.get("content", "")
        msg_id = message.get("message_id", str(uuid.uuid4())[:8])
        context_id = payload.get("context_id", ws_session_id)

        logger.info(f"[Lumi-Hub] 收到消息 (session={ws_session_id}): {user_content}")

        # 鉴权校验
        user_id = self.active_sessions.get(ws_session_id)
        if not user_id:
            logger.warning(f"[Lumi-Hub] 未登录用户尝试发送消息，已拒绝")
            await self.ws_server.send_to_client(ws_session_id, {
                "message_id": msg_id, "type": "ERROR_ALERT", "source": "host", "target": "client",
                "timestamp": int(time.time() * 1000), "payload": {"error_code": "UNAUTHORIZED", "detail": "请先登录"}
            })
            return

        # 异步存入数据库
        self.db.save_message(user_id=user_id, role="user", content=user_content, client_msg_id=msg_id)

        # 1. 构造 AstrBotMessage（和 WebChatAdapter 做法一致）
        abm = AstrBotMessage()
        abm.self_id = "lumi_hub"
        # 使用绑定的真实账号 user_id 而不是动态 session_id 作为识别，让大模型持久记忆用户
        abm.sender = MessageMember(user_id=str(user_id), nickname=f"User_{user_id}")
        abm.type = MessageType.FRIEND_MESSAGE
        # SessionID 格式: lumi_hub!user_id!context_id，这样 AstrBot 的会话上下文将完全跟着账号走
        abm.session_id = f"lumi_hub!{user_id}!{context_id}"
        abm.message_id = msg_id
        abm.message = [Plain(user_content)]
        abm.message_str = user_content
        abm.raw_message = message
        abm.timestamp = int(time.time())

        # 2. 包装为 LumiMessageEvent
        event = LumiMessageEvent(
            message_str=user_content,
            message_obj=abm,
            platform_meta=self.metadata,
            session_id=abm.session_id,
            ws_server=self.ws_server,
            ws_session_id=ws_session_id,
            db=self.db,
            user_id=user_id,
        )

        # 3. 注入 AstrBot 事件队列（EventBus 会自动 handle、调 LLM、调 event.send()）
        self.commit_event(event)
        logger.info(f"[Lumi-Hub] 事件已提交到 AstrBot 队列 (msg_id={msg_id})")

    async def _handle_persona_switch(self, message: dict, ws_session_id: str) -> None:
        """处理人格切换请求。"""
        payload = message.get("payload", {})
        persona_id = payload.get("persona_id", "default")
        persona_name = payload.get("persona_name", "默认")

        logger.info(f"[Lumi-Hub] 切换人格: {persona_name} ({persona_id})")

        await self.ws_server.send_to_client(ws_session_id, {
            "message_id": message.get("message_id", str(uuid.uuid4())[:8]),
            "type": "PERSONA_SWITCH",
            "source": "host",
            "target": "client",
            "timestamp": int(time.time() * 1000),
            "payload": {
                "persona_id": persona_id,
                "persona_name": persona_name,
                "status": "switched",
            },
        })

    async def _handle_persona_list(self, message: dict, ws_session_id: str) -> None:
        """返回 AstrBot 中已有的人格列表。"""
        try:
            personas = await db_helper.get_personas()
            persona_list = []
            for p in personas:
                persona_list.append({
                    "id": p.persona_id,
                    "name": p.persona_id,  # AstrBot 的 persona_id 就是名称
                    "system_prompt_preview": (p.system_prompt[:200] + "...") if len(p.system_prompt) > 200 else p.system_prompt,
                    "has_begin_dialogs": bool(p.begin_dialogs),
                    "tools": p.tools,
                    "skills": p.skills,
                })
            logger.info(f"[Lumi-Hub] 返回 {len(persona_list)} 个人格")
        except Exception as e:
            logger.error(f"[Lumi-Hub] 读取人格列表失败: {e}")
            persona_list = []

        await self.ws_server.send_to_client(ws_session_id, {
            "message_id": message.get("message_id", str(uuid.uuid4())[:8]),
            "type": "PERSONA_LIST",
            "source": "host",
            "target": "client",
            "timestamp": int(time.time() * 1000),
            "payload": {
                "personas": persona_list,
            },
        })
