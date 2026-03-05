"""
Lumi-Hub 自定义消息事件
继承 AstrMessageEvent，重写 send() 和 send_streaming()，
将 AstrBot 的 LLM 回复通过 WebSocket 转发回 Flutter Client。
"""
import json
import uuid
import time
import logging
from collections.abc import AsyncGenerator

from astrbot.core.platform.astr_message_event import AstrMessageEvent
from astrbot.core.message.message_event_result import MessageChain
from astrbot.core.message.components import Plain, Image

logger = logging.getLogger("lumi_hub")


class LumiMessageEvent(AstrMessageEvent):
    """Lumi-Hub 的消息事件。

    AstrBot EventBus 处理完消息后，会调用 event.send() 或 event.send_streaming()
    发送回复。我们在这里将回复转为 JSON，通过 WebSocket 发回给 Client。
    """

    def __init__(
        self,
        message_str: str,
        message_obj,
        platform_meta,
        session_id: str,
        ws_server=None,
        ws_session_id: str = "",
    ) -> None:
        super().__init__(message_str, message_obj, platform_meta, session_id)
        self._ws_server = ws_server
        self._ws_session_id = ws_session_id

    def _chain_to_text(self, chain: MessageChain) -> str:
        """将 MessageChain 转为纯文本。"""
        parts = []
        for comp in chain.chain:
            if isinstance(comp, Plain):
                parts.append(comp.text)
            elif isinstance(comp, Image):
                parts.append("[图片]")
            else:
                parts.append(f"[{comp.type}]")
        return "".join(parts)

    async def send(self, message: MessageChain) -> None:
        """AstrBot 调用此方法发送回复。我们将其转发到 WebSocket Client。"""
        if not self._ws_server or not self._ws_session_id:
            logger.warning("[Lumi-Hub] 无法发送回复：ws_server 或 ws_session_id 未设置")
            return

        text = self._chain_to_text(message)
        if not text.strip():
            await super().send(MessageChain([]))
            return

        response = {
            "message_id": getattr(self.message_obj, "message_id", str(uuid.uuid4())),
            "type": "CHAT_RESPONSE",
            "source": "host",
            "target": "client",
            "timestamp": int(time.time() * 1000),
            "payload": {
                "content": text,
                "status": "success",
                "persona": "default",
            },
        }

        logger.info(f"[Lumi-Hub] 发送 LLM 回复 (session={self._ws_session_id}): {text[:80]}...")
        await self._ws_server.send_to_client(self._ws_session_id, response)
        await super().send(MessageChain([]))

    async def send_streaming(
        self, generator: AsyncGenerator[MessageChain, None], use_fallback: bool = False
    ) -> None:
        """处理流式 LLM 输出，逐块发送 CHAT_STREAM_CHUNK。"""
        if not self._ws_server or not self._ws_session_id:
            logger.warning("[Lumi-Hub] 无法发送流式回复")
            return

        msg_id = getattr(self.message_obj, "message_id", str(uuid.uuid4()))
        chunk_index = 0
        full_text = ""

        async for chain in generator:
            chunk_text = self._chain_to_text(chain)
            if not chunk_text:
                continue

            full_text += chunk_text

            chunk_msg = {
                "message_id": msg_id,
                "type": "CHAT_STREAM_CHUNK",
                "source": "host",
                "target": "client",
                "timestamp": int(time.time() * 1000),
                "payload": {
                    "chunk": chunk_text,
                    "index": chunk_index,
                    "finished": False,
                },
            }

            await self._ws_server.send_to_client(self._ws_session_id, chunk_msg)
            chunk_index += 1

        # 发送完成标记
        finish_msg = {
            "message_id": msg_id,
            "type": "CHAT_STREAM_CHUNK",
            "source": "host",
            "target": "client",
            "timestamp": int(time.time() * 1000),
            "payload": {
                "chunk": "",
                "index": chunk_index,
                "finished": True,
            },
        }
        await self._ws_server.send_to_client(self._ws_session_id, finish_msg)

        # 发送完整的最终回复
        final_msg = {
            "message_id": msg_id,
            "type": "CHAT_RESPONSE",
            "source": "host",
            "target": "client",
            "timestamp": int(time.time() * 1000),
            "payload": {
                "content": full_text,
                "status": "success",
                "persona": "default",
            },
        }
        await self._ws_server.send_to_client(self._ws_session_id, final_msg)

        logger.info(f"[Lumi-Hub] 流式回复完成 (session={self._ws_session_id}): {full_text[:80]}...")
        await super().send_streaming(generator, use_fallback)
