import asyncio
import json
import logging
import uuid
import base64
import hashlib
import time
import websockets
from cryptography.hazmat.primitives.asymmetric import ed25519
from cryptography.hazmat.primitives import serialization

# 配置日志输出
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(name)s - %(levelname)s - %(message)s')
logger = logging.getLogger("test_openclaw")

def base64url_encode(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b'=').decode('utf-8')

async def test_lumi_agent_v2():
    ws_url = "ws://127.0.0.1:18789"
    logger.info(f"正在连接到 OpenClaw Gateway: {ws_url}")
    
    try:
        async with websockets.connect(ws_url) as ws:
            logger.info("✅ 连接成功，等待 connect.challenge...")
            
            # 第一步：等待服务端发来的 connect.challenge
            challenge_msg = await ws.recv()
            challenge = json.loads(challenge_msg)
            logger.info(f"收到握手挑战: {challenge}")
            
            if challenge.get("event") != "connect.challenge":
                logger.error("未收到正确的 connect.challenge 帧")
                return
                
            nonce = challenge["payload"]["nonce"]
            
            # 准备终端身份与设备签名 (Ed25519)
            private_key = ed25519.Ed25519PrivateKey.generate()
            public_key = private_key.public_key()
            
            # 取 DER 格式的 SPKI 作为公开密钥 (OpenClaw 原生处理方式)
            public_bytes = public_key.public_bytes(
                encoding=serialization.Encoding.DER,
                format=serialization.PublicFormat.SubjectPublicKeyInfo
            )
            
            # 假设 OpenClaw 要求的 raw PublicKey 其实去掉了 ED25519_SPKI_PREFIX 前缀
            prefix = bytes.fromhex("302a300506032b6570032100")
            if public_bytes.startswith(prefix):
                raw_pub = public_bytes[len(prefix):]
            else:
                raw_pub = public_bytes
                
            # DeviceId 是原始公钥的 SHA256 Hex
            device_id = hashlib.sha256(raw_pub).hexdigest()
            pub_b64url = base64url_encode(raw_pub)
            
            # 构建 V3 签名载荷
            # 注意: client_id 和 client_mode 必须严格符合 OpenClaw Gateway 的 Schema 枚举值
            # client_id 必须是 GatewayClientId 之一，例如 'gateway-client', 'cli', 'node-host'
            # client_mode 必须是 GatewayClientMode 之一，例如 'backend', 'cli', 'node'
            client_id = "gateway-client"
            client_mode = "backend"
            role = "operator"
            scopes = ["operator.admin", "operator.read", "operator.write"]
            signed_at_ms = int(time.time() * 1000)
            platform = "windows"
            
            # v3|<deviceId>|<clientId>|<clientMode>|<role>|<scopes_comma>|<signedAtMs>|<token>|<nonce>|<platform>|<deviceFamily>
            payload_str = f"v3|{device_id}|{client_id}|{client_mode}|{role}|{','.join(scopes)}|{signed_at_ms}||{nonce}|{platform}|"
            
            # 签名
            signature = private_key.sign(payload_str.encode("utf-8"))
            sig_b64url = base64url_encode(signature)
            
            # 第二步：发送正确的带有有效 device identity 的握手包 (ConnectParams)
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
                        "password": "xzq060312@a"
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
            logger.info(f"发送签名后的 Connect 请求: {handshake_msg}")
            await ws.send(json.dumps(handshake_msg))
            
            # 接收握手结果 (hello-ok)
            response = await ws.recv()
            logger.info(f"收到 Connect 响应: {response}")
            
            # 如果不是 hello-ok 就说明被拒绝了
            resp_data = json.loads(response)
            if not resp_data.get("ok"):
                logger.error("握手被服务器拒绝！")
                return

            # 第三步：查询可用的执行节点及其能力 (node.list)
            req_id = str(uuid.uuid4())[:8]
            req_msg = {
                "type": "req",
                "id": req_id,
                "method": "node.list",
                "params": {}
            }
            logger.info(f"\n发送 node.list 请求: {req_msg}")
            await ws.send(json.dumps(req_msg))
            
            # 监听对应的响应
            logger.info("开始监听 node.list 响应，寻找可用节点...")
            target_node_id = None
            for i in range(5):
                try:
                    msg = await asyncio.wait_for(ws.recv(), timeout=10.0)
                    data = json.loads(msg)
                    logger.info(f"流式消息 [{i+1}]: {json.dumps(data, ensure_ascii=False)}")
                    if data.get("type") == "res" and data.get("id") == req_id:
                        nodes = data.get("payload", {}).get("nodes", [])
                        if nodes:
                            target_node_id = nodes[0].get("nodeId")
                            logger.info(f"拿到可用节点 ID: {target_node_id}")
                        else:
                            logger.error("没有找到任何存活的 Nodes！请确保启动了 node host。")
                        break
                except asyncio.TimeoutError:
                    logger.warning("等待响应超时...")
                    break
                    
            if not target_node_id:
                return
                
            # 第四步：直接调用节点的 system.run 执行命令
            invoke_id = str(uuid.uuid4())[:8]
            invoke_msg = {
                "type": "req",
                "id": invoke_id,
                "method": "node.invoke",
                "params": {
                    "nodeId": target_node_id,
                    "command": "system.run",
                    "params": {
                        "command": ["type", "readme.md"],
                        "approvalDecision": "allow-once",
                        "runId": str(uuid.uuid4())
                    },
                    "idempotencyKey": str(uuid.uuid4())
                }
            }
            logger.info(f"\n发送 node.invoke 请求: {invoke_msg}")
            await ws.send(json.dumps(invoke_msg))
            
            # 监听执行结果
            logger.info("开始监听 node.invoke 执行结果...")
            for i in range(10):
                try:
                    msg = await asyncio.wait_for(ws.recv(), timeout=10.0)
                    data = json.loads(msg)
                    logger.info(f"流式消息 [{i+1}]: {json.dumps(data, ensure_ascii=False)}")
                    if data.get("type") == "res" and data.get("id") == invoke_id:
                        logger.info("拿到 node.invoke 最终结果！测试圆满成功！")
                        break
                except asyncio.TimeoutError:
                    break
                    
    except Exception as e:
        logger.error(f"❌ 连接或执行失败: {e}", exc_info=True)

if __name__ == "__main__":
    asyncio.run(test_lumi_agent_v2())
