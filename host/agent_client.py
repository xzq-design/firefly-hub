import asyncio
import json
import logging
import time
import uuid
import websockets

logger = logging.getLogger("lumi_hub.agent_client")

class OpenClawClient:
    """
    OpenClaw Gateway WebSocket 客户端。
    负责连接到本地运行的 OpenClaw 网关，并执行工具指令。
    """
    def __init__(self, ws_url: str = "ws://127.0.0.1:18789"):
        self.ws_url = ws_url
        self.ws = None
        self._connected = False
        self._lock = asyncio.Lock()
        self._callbacks = {}

    async def _send_ping(self):
        """发送测试握手包 (此方法在新协议中将不再单独调用，合并入 connect)"""
        pass

    async def _listen_loop(self):
        """持续监听 WebSocket 消息"""
        try:
            async for message in self.ws:
                data = json.loads(message)
                logger.debug(f"[OpenClaw流] 收到消息: {data}")
                
                # TODO: 解析执行结果、工具流，并将状态抛给宿主
                # 如果有回调注册，则调用回调
                req_id = data.get("reqId") or data.get("id") or data.get("resId")
                if req_id and req_id in self._callbacks:
                    await self._callbacks[req_id](data)
                
        except websockets.ConnectionClosed:
            logger.warning("[OpenClaw] 网关连接已关闭")
        except Exception as e:
            logger.error(f"[OpenClaw] 监听异常跑出: {e}")
        finally:
            self._connected = False

    async def connect(self):
        """建立 WebSocket 连接并执行标准的包含 Ed25519 签名的接入手续"""
        if self._connected:
            return
        
        try:
            self.ws = await websockets.connect(self.ws_url)
            
            # 等待握手挑战
            challenge_msg = await self.ws.recv()
            challenge = json.loads(challenge_msg)
            if challenge.get("event") != "connect.challenge":
                raise Exception(f"Expected connect.challenge, got {challenge}")
                
            nonce = challenge["payload"]["nonce"]
            
            # 引入 cryptography 的延迟加载，避免影响主包启动速度
            import base64
            import hashlib
            from cryptography.hazmat.primitives.asymmetric import ed25519
            from cryptography.hazmat.primitives import serialization
            
            def base64url_encode(data: bytes) -> str:
                return base64.urlsafe_b64encode(data).rstrip(b'=').decode('utf-8')
                
            # 准备身份
            # 在实际工程中，可以把这个 private key 持久化，避免每次重启都会产生新的 deviceId
            private_key = ed25519.Ed25519PrivateKey.generate()
            public_key = private_key.public_key()
            public_bytes = public_key.public_bytes(
                encoding=serialization.Encoding.DER,
                format=serialization.PublicFormat.SubjectPublicKeyInfo
            )
            
            prefix = bytes.fromhex("302a300506032b6570032100")
            raw_pub = public_bytes[len(prefix):] if public_bytes.startswith(prefix) else public_bytes
                
            device_id = hashlib.sha256(raw_pub).hexdigest()
            pub_b64url = base64url_encode(raw_pub)
            
            client_id = "gateway-client"
            client_mode = "backend"
            role = "operator"
            scopes = ["operator.admin", "operator.read", "operator.write"]
            signed_at_ms = int(time.time() * 1000)
            platform = "windows"
            
            # v3 签名
            payload_str = f"v3|{device_id}|{client_id}|{client_mode}|{role}|{','.join(scopes)}|{signed_at_ms}||{nonce}|{platform}|"
            signature = private_key.sign(payload_str.encode("utf-8"))
            sig_b64url = base64url_encode(signature)
            
            # Gateway 配置的密码 (可以放到配置中读取)
            gateway_pwd = "xzq060312@a"
            
            # 发送 Connect
            handshake_id = str(uuid.uuid4())[:8]
            handshake_msg = {
                "type": "req",
                "id": handshake_id,
                "method": "connect",
                "params": {
                    "minProtocol": 1,
                    "maxProtocol": 3,
                    "client": {
                        "id": client_id,
                        "displayName": "Lumi-Hub Python Host",
                        "version": "1.0.0",
                        "platform": platform,
                        "mode": client_mode
                    },
                    "role": role,
                    "scopes": scopes,
                    "caps": ["chat"],
                    "auth": {
                        "password": gateway_pwd
                    },
                    "device": {
                        "id": device_id,
                        "publicKey": pub_b64url,
                        "signature": sig_b64url,
                        "signedAt": signed_at_ms,
                        "nonce": nonce
                    }
                }
            }
            await self.ws.send(json.dumps(handshake_msg))
            resp_msg = await self.ws.recv()
            resp = json.loads(resp_msg)
            
            if not resp.get("ok"):
                raise Exception(f"OpenClaw Gateway rejected connection: {resp}")
                
            self._connected = True
            logger.info(f"[OpenClaw] 成功连接至 OpenClaw Gateway 并完成 Auth: {self.ws_url}")
            
            # 启动监听循环
            asyncio.create_task(self._listen_loop())
            
        except Exception as e:
            logger.error(f"[OpenClaw] 连接网关失败: {e}", exc_info=True)
            self._connected = False
        try:
            async for message in self.ws:
                data = json.loads(message)
                logger.debug(f"[OpenClaw流] 收到消息: {data}")
                
                # TODO: 解析执行结果、工具流，并将状态抛给宿主
                # 如果有回调注册，则调用回调
                req_id = data.get("reqId") or data.get("resId")
                if req_id and req_id in self._callbacks:
                    await self._callbacks[req_id](data)
                
        except websockets.ConnectionClosed:
            logger.warning("[OpenClaw] 网关连接已关闭")
        except Exception as e:
            logger.error(f"[OpenClaw] 监听异常跑出: {e}")
        finally:
            self._connected = False

    async def execute_action(self, action_type: str, args: dict, callback=None):
        """
        抛出一个执行任务给 Agent
        Args:
            action_type: 对应工具名
            args: 工具参数
            callback: 处理流式返回状态的回调函数
        """
        if not self._connected:
            await self.connect()
        
        if not self._connected:
            logger.error("[OpenClaw] 无法连接到执行引擎，动作中止")
            return
        
        req_id = str(uuid.uuid4())[:8]
        if callback:
            self._callbacks[req_id] = callback
            
        # 封装发给 OpenClaw Gateway 的协议栈
        command_msg = {
            "type": "req",
            "id": req_id,
            "method": "chat.send",
            "params": {
                "sessionKey": f"agent:lumi:{req_id}", # 临时隔离的 session
                "idempotencyKey": str(uuid.uuid4()),
                "message": f"Execute MCP Tool {action_type} with parameters {json.dumps(args, ensure_ascii=False)}"
            }
        }
        
        try:
            await self.ws.send(json.dumps(command_msg))
            logger.info(f"[OpenClaw] 任务已下发: reqId={req_id}, action={action_type}")
        except Exception as e:
            logger.error(f"[OpenClaw] 任务下发失败: {e}")

    async def stop(self):
        """关闭连接"""
        if self.ws:
            await self.ws.close()
        self._connected = False
        logger.info("[OpenClaw] 已断开连接")

# 全局单例
openclaw_client = OpenClawClient()
