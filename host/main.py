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

logger = logging.getLogger("lumi_hub")


class LumiHub(Star):
    """AstrBot 插件壳。

    star_manager 要求 plugins 目录下必须有 Star 子类。
    真正的逻辑在 LumiHubAdapter (Platform) 中。
    """
    pass


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
        self._shutdown_event.set()
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
        # 从 session_id 中提取 ws_session_id
        # 格式: lumi_hub!user!{ws_session_id}
        parts = session.session_id.split("!")
        if len(parts) >= 3:
            ws_session_id = parts[2]
        else:
            ws_session_id = session.session_id

        text_parts = []
        for comp in message_chain.chain:
            if isinstance(comp, Plain):
                text_parts.append(comp.text)

        if text_parts:
            msg = {
                "message_id": str(uuid.uuid4())[:8],
                "type": "CHAT_RESPONSE",
                "source": "host",
                "target": "client",
                "timestamp": int(time.time() * 1000),
                "payload": {
                    "content": "".join(text_parts),
                    "status": "success",
                    "persona": "default",
                },
            }
            await self.ws_server.send_to_client(ws_session_id, msg)

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
        else:
            logger.warning(f"[Lumi-Hub] 未知消息类型: {msg_type}")

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

        # 1. 构造 AstrBotMessage（和 WebChatAdapter 做法一致）
        abm = AstrBotMessage()
        abm.self_id = "lumi_hub"
        abm.sender = MessageMember(user_id=ws_session_id, nickname="开拓者")
        abm.type = MessageType.FRIEND_MESSAGE
        abm.session_id = f"lumi_hub!{ws_session_id}!{context_id}"
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
        )

        # 3. 注入 AstrBot 事件队列（EventBus 会自动处理、调 LLM、调 event.send()）
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
