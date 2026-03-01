"""
Firefly-Hub AstrBot 插件入口
作为 AstrBot 的自定义平台适配器，同时启动 WebSocket Server 对接 Flutter Client。

Phase 1: Echo 模式 —— 收到 CHAT_REQUEST 后原样返回，不接 LLM。
"""
import asyncio
import uuid
import time
import logging

from astrbot.core.star import Star, Context

from .ws_server import FireflyWSServer

logger = logging.getLogger("firefly_hub")


class FireflyHub(Star):
    """Firefly-Hub 主插件类，负责 WebSocket 服务端生命周期和消息路由。"""

    def __init__(self, context: Context, config: dict = None) -> None:
        super().__init__(context, config)
        self.ws_server = FireflyWSServer(host="0.0.0.0", port=8765)
        self.ws_server.on_message(self._handle_client_message)
        self._server_task: asyncio.Task = None

    # ---------- AstrBot 生命周期钩子 ----------

    async def initialize(self) -> None:
        """当插件被激活时调用，启动 WebSocket 服务端。"""
        logger.info("[Firefly-Hub] 插件激活中，正在启动 WebSocket Server...")
        try:
            await self.ws_server.start()
            logger.info("[Firefly-Hub] WebSocket Server 已启动: ws://0.0.0.0:8765")
        except Exception as e:
            logger.error(f"[Firefly-Hub] WebSocket Server 启动失败: {e}")

    async def terminate(self) -> None:
        """当插件被禁用或重载时调用，关闭 WebSocket 服务端。"""
        logger.info("[Firefly-Hub] 插件卸载中，正在关闭 WebSocket Server...")
        try:
            await self.ws_server.stop()
        except Exception as e:
            logger.error(f"[Firefly-Hub] WebSocket Server 停止失败: {e}")

    # ---------- 消息处理 ----------

    async def _handle_client_message(self, message: dict, session_id: str):
        """
        处理来自 Flutter Client 的业务消息。
        Phase 1: Echo 模式，原样返回用户消息。
        Phase 2+: 将消息提交给 AstrBot LLM 管道处理。
        """
        msg_type = message.get("type", "")

        if msg_type == "CHAT_REQUEST":
            await self._handle_chat_request(message, session_id)
        elif msg_type == "PERSONA_SWITCH":
            await self._handle_persona_switch(message, session_id)
        elif msg_type == "PERSONA_LIST":
            await self._handle_persona_list(message, session_id)
        elif msg_type == "UNDO_REQUEST":
            # Phase 4 实现
            logger.info(f"[Firefly-Hub] 收到撤销请求: {message.get('payload', {}).get('task_id')}")
        else:
            logger.warning(f"[Firefly-Hub] 未知消息类型: {msg_type}")

    async def _handle_chat_request(self, message: dict, session_id: str):
        """
        处理 CHAT_REQUEST。
        Phase 1: Echo —— 直接把用户发的内容原样返回。
        TODO Phase 2: 将消息提交给 AstrBot 的 LLM 管道。
        """
        payload = message.get("payload", {})
        user_content = payload.get("content", "")
        msg_id = message.get("message_id", str(uuid.uuid4()))

        logger.info(f"[Firefly-Hub] 收到消息 (session={session_id}): {user_content}")

        # Phase 1: Echo 响应
        response = {
            "message_id": msg_id,
            "type": "CHAT_RESPONSE",
            "source": "host",
            "target": "client",
            "timestamp": int(time.time() * 1000),
            "payload": {
                "content": f"[Echo] {user_content}",
                "status": "success",
                "persona": "default"
            }
        }

        await self.ws_server.send_to_client(session_id, response)

    async def _handle_persona_switch(self, message: dict, session_id: str):
        """处理人格切换请求。Phase 1: 仅返回确认。"""
        payload = message.get("payload", {})
        persona_id = payload.get("persona_id", "default")
        persona_name = payload.get("persona_name", "默认")

        logger.info(f"[Firefly-Hub] 切换人格: {persona_name} ({persona_id})")

        await self.ws_server.send_to_client(session_id, {
            "message_id": message.get("message_id", str(uuid.uuid4())),
            "type": "PERSONA_SWITCH",
            "source": "host",
            "target": "client",
            "timestamp": int(time.time() * 1000),
            "payload": {
                "persona_id": persona_id,
                "persona_name": persona_name,
                "status": "switched"
            }
        })

    async def _handle_persona_list(self, message: dict, session_id: str):
        """返回可用人格列表。Phase 1: 返回内置人格。"""
        await self.ws_server.send_to_client(session_id, {
            "message_id": message.get("message_id", str(uuid.uuid4())),
            "type": "PERSONA_LIST",
            "source": "host",
            "target": "client",
            "timestamp": int(time.time() * 1000),
            "payload": {
                "personas": [
                    {
                        "id": "default",
                        "name": "默认助手",
                        "author": "系统",
                        "version": "1.0"
                    },
                    {
                        "id": "firefly",
                        "name": "流萤",
                        "author": "官方",
                        "version": "1.0"
                    }
                ]
            }
        })
