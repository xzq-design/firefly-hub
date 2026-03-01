"""
Firefly-Hub WebSocket Server
负责与 Flutter Client 的 WebSocket 通信。
"""
import asyncio
import json
import uuid
import time
import logging
from typing import Dict, Set, Optional, Callable, Awaitable

import websockets
from websockets.server import WebSocketServerProtocol

logger = logging.getLogger("firefly_hub.ws_server")


class FireflyWSServer:
    """Firefly-Hub WebSocket 服务端，管理与 Client 的连接和消息收发。"""

    def __init__(self, host: str = "0.0.0.0", port: int = 8765):
        self.host = host
        self.port = port
        self.clients: Dict[str, WebSocketServerProtocol] = {}  # session_id -> ws
        self.server: Optional[websockets.WebSocketServer] = None
        self._message_handler: Optional[Callable[[dict, str], Awaitable[None]]] = None

    def on_message(self, handler: Callable[[dict, str], Awaitable[None]]):
        """注册消息处理回调。handler(message_dict, session_id)"""
        self._message_handler = handler

    async def start(self):
        """启动 WebSocket 服务端。"""
        self.server = await websockets.serve(
            self._handle_connection,
            self.host,
            self.port,
            ping_interval=20,
            ping_timeout=10,
        )
        logger.info(f"[Firefly-Hub] WebSocket Server 已启动: ws://{self.host}:{self.port}")

    async def stop(self):
        """停止 WebSocket 服务端。"""
        if self.server:
            self.server.close()
            await self.server.wait_closed()
            logger.info("[Firefly-Hub] WebSocket Server 已停止")

    async def send_to_client(self, session_id: str, message: dict):
        """向指定 Client 发送消息。"""
        ws = self.clients.get(session_id)
        if ws:
            try:
                await ws.send(json.dumps(message, ensure_ascii=False))
            except Exception as e:
                logger.error(f"[Firefly-Hub] 发送消息失败 (session={session_id}): {e}")

    async def broadcast(self, message: dict):
        """向所有已连接的 Client 广播消息。"""
        disconnected = []
        for session_id, ws in self.clients.items():
            try:
                await ws.send(json.dumps(message, ensure_ascii=False))
            except Exception:
                disconnected.append(session_id)
        for sid in disconnected:
            self.clients.pop(sid, None)

    # ---------- 内部方法 ----------

    async def _handle_connection(self, ws: WebSocketServerProtocol):
        """处理单个 WebSocket 连接的完整生命周期。"""
        session_id = str(uuid.uuid4())[:8]
        self.clients[session_id] = ws
        remote = ws.remote_address if ws.remote_address else ('unknown', 0)
        client_info = f"{remote[0]}:{remote[1]}"
        logger.info(f"[Firefly-Hub] Client 已连接: {client_info} (session={session_id})")

        try:
            async for raw_message in ws:
                try:
                    message = json.loads(raw_message)
                    await self._dispatch_message(message, session_id)
                except json.JSONDecodeError:
                    logger.warning(f"[Firefly-Hub] 收到无效 JSON (session={session_id})")
                    await self._send_error(session_id, "INVALID_JSON", "消息格式无效，请发送 JSON")
        except websockets.exceptions.ConnectionClosed as e:
            logger.info(f"[Firefly-Hub] Client 断开: {client_info} (code={e.code})")
        except Exception as e:
            logger.error(f"[Firefly-Hub] 连接异常: {client_info} - {e}")
        finally:
            self.clients.pop(session_id, None)

    async def _dispatch_message(self, message: dict, session_id: str):
        """根据消息类型分发处理。"""
        msg_type = message.get("type", "")

        # 心跳处理
        if msg_type == "PING":
            await self.send_to_client(session_id, {
                "message_id": message.get("message_id", str(uuid.uuid4())),
                "type": "PONG",
                "source": "host",
                "target": "client",
                "timestamp": int(time.time() * 1000),
                "payload": {}
            })
            return

        # 连接握手
        if msg_type == "CONNECT":
            logger.info(f"[Firefly-Hub] Client 握手: {message.get('payload', {})}")
            await self.send_to_client(session_id, {
                "message_id": message.get("message_id", str(uuid.uuid4())),
                "type": "CONNECT",
                "source": "host",
                "target": "client",
                "timestamp": int(time.time() * 1000),
                "payload": {
                    "status": "connected",
                    "session_id": session_id,
                    "server_version": "0.1.0"
                }
            })
            return

        # 其余消息交给外部注册的 handler 处理
        if self._message_handler:
            await self._message_handler(message, session_id)
        else:
            logger.warning(f"[Firefly-Hub] 未注册消息处理器，丢弃消息: {msg_type}")

    async def _send_error(self, session_id: str, code: str, detail: str):
        """发送错误响应。"""
        await self.send_to_client(session_id, {
            "message_id": str(uuid.uuid4()),
            "type": "ERROR_ALERT",
            "source": "host",
            "target": "client",
            "timestamp": int(time.time() * 1000),
            "payload": {
                "error_code": code,
                "detail": detail
            }
        })
