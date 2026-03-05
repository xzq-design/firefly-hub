"""
Firefly-Hub Echo 测试脚本
用于验证 Host WebSocket Server 是否正常工作。

使用方法：
1. 确保 AstrBot 已启动并加载了 lumi_hub 插件
2. 运行此脚本: python test_echo.py
"""
import asyncio
import json
import uuid
import time

import websockets


SERVER_URL = "ws://localhost:8765"


def make_message(msg_type: str, payload: dict) -> str:
    """构造符合协议规范的消息。"""
    return json.dumps({
        "message_id": str(uuid.uuid4())[:8],
        "type": msg_type,
        "source": "client",
        "target": "host",
        "timestamp": int(time.time() * 1000),
        "payload": payload,
    }, ensure_ascii=False)


async def test_echo():
    """测试 Echo 闭环。"""
    print(f"正在连接 {SERVER_URL} ...")

    async with websockets.connect(SERVER_URL) as ws:
        # 1. 测试 CONNECT 握手
        print("\n--- 测试 CONNECT 握手 ---")
        await ws.send(make_message("CONNECT", {
            "client_version": "0.1.0",
            "platform": "test_script",
            "device_name": "dev-machine"
        }))
        resp = json.loads(await ws.recv())
        print(f"收到: {json.dumps(resp, indent=2, ensure_ascii=False)}")
        assert resp["type"] == "CONNECT"
        assert resp["payload"]["status"] == "connected"
        print("✅ CONNECT 握手成功")

        # 2. 测试 PING/PONG 心跳
        print("\n--- 测试 PING/PONG ---")
        await ws.send(make_message("PING", {}))
        resp = json.loads(await ws.recv())
        print(f"收到: {resp['type']}")
        assert resp["type"] == "PONG"
        print("✅ 心跳正常")

        # 3. 测试 CHAT_REQUEST → LLM 回复
        print("\n--- 测试 CHAT_REQUEST (LLM) ---")
        test_content = "你好，流萤！帮我看看项目文件。"
        await ws.send(make_message("CHAT_REQUEST", {
            "content": test_content,
            "context_id": "test-session"
        }))
        resp = json.loads(await asyncio.wait_for(ws.recv(), timeout=30))
        print(f"收到: {json.dumps(resp, indent=2, ensure_ascii=False)}")
        assert resp["type"] == "CHAT_RESPONSE"
        assert resp["payload"]["status"] == "success"
        assert len(resp["payload"]["content"]) > 0
        print(f"✅ LLM 回复正常 ({len(resp['payload']['content'])} 字)")

        # 4. 测试 PERSONA_LIST（从 AstrBot 数据库读取）
        print("\n--- 测试 PERSONA_LIST ---")
        await ws.send(make_message("PERSONA_LIST", {}))
        resp = json.loads(await ws.recv())
        personas = resp["payload"]["personas"]
        print(f"收到 {len(personas)} 个人格:")
        for p in personas:
            print(f"  - {p['id']}: {p.get('system_prompt_preview', '')[:60]}...")
        assert resp["type"] == "PERSONA_LIST"
        assert len(personas) >= 1
        print("✅ 人格列表正常")

        # 5. 测试 PERSONA_SWITCH
        print("\n--- 测试 PERSONA_SWITCH ---")
        await ws.send(make_message("PERSONA_SWITCH", {
            "persona_id": "firefly",
            "persona_name": "流萤"
        }))
        resp = json.loads(await ws.recv())
        print(f"收到: {json.dumps(resp, indent=2, ensure_ascii=False)}")
        assert resp["type"] == "PERSONA_SWITCH"
        assert resp["payload"]["status"] == "switched"
        print("✅ 人格切换正常")

    print("\n🎉 所有测试通过！Host WebSocket Server 工作正常。")


if __name__ == "__main__":
    asyncio.run(test_echo())
