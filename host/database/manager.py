import os
import secrets
import logging
import hashlib
import datetime
from datetime import timezone
from sqlalchemy.orm import sessionmaker

from .models import init_db, User, Message

logger = logging.getLogger("lumi_hub.db")

class DatabaseManager:
    """管理 Lumi-Hub 的本地 SQLite 数据库操作"""
    
    def __init__(self, data_dir: str):
        self.db_path = os.path.join(data_dir, "lumi_hub.db")
        os.makedirs(data_dir, exist_ok=True)
        self.SessionLocal = init_db(self.db_path)
        logger.info(f"[Lumi-Hub DB] 数据库初始化完成: {self.db_path}")

    # ===== 用户相关 =====

    def verify_password(self, plain_password, hashed_password):
        return self.get_password_hash(plain_password) == hashed_password

    def get_password_hash(self, password):
        # 简单好用的内置 sha256 即可，无需引入容易出依赖问题的 passlib/bcrypt
        return hashlib.sha256(password.encode('utf-8')).hexdigest()

    def create_user(self, username: str, password: str) -> dict:
        """注册新用户。成功返回用户信息，失败返回 error。"""
        with self.SessionLocal() as session:
            # 检查是否已存在
            existing = session.query(User).filter(User.username == username).first()
            if existing:
                return {"error": "Username already exists"}
            
            hashed_pwd = self.get_password_hash(password)
            new_token = secrets.token_hex(32)
            new_user = User(username=username, password_hash=hashed_pwd, token=new_token)
            session.add(new_user)
            session.commit()
            session.refresh(new_user)
            
            return {
                "id": new_user.id,
                "username": new_user.username,
                "token": new_user.token,
                "created_at": new_user.created_at.isoformat()
            }

    def verify_user(self, username: str, password: str) -> dict:
        """验证用户登录。成功返回用户信息（含新 token），失败返回 error。"""
        with self.SessionLocal() as session:
            user = session.query(User).filter(User.username == username).first()
            if not user or not self.verify_password(password, user.password_hash):
                return {"error": "Invalid username or password"}
            
            # 每次登录刷新 token，使旧 token 立即失效
            user.token = secrets.token_hex(32)
            session.commit()
            session.refresh(user)
                
            return {
                "id": user.id,
                "username": user.username,
                "token": user.token,
                "created_at": user.created_at.isoformat()
            }
            
    def get_user_by_token(self, token: str):
        """通过 token 查找用户（用于 AUTH_RESTORE）。"""
        with self.SessionLocal() as session:
            user = session.query(User).filter(User.token == token).first()
            if user:
                return {"id": user.id, "username": user.username}
            return None

    # ===== 消息相关 =====

    def save_message(self, user_id: int, role: str, content: str, msg_type: str = 'chat', client_msg_id: str = None, persona_id: str = 'default') -> dict:
        """保存单条消息记录"""
        with self.SessionLocal() as session:
            msg = Message(
                user_id=user_id,
                persona_id=persona_id,
                role=role,
                content=content,
                type=msg_type,
                client_msg_id=client_msg_id
            )
            session.add(msg)
            session.commit()
            session.refresh(msg)
            
            return {
                "id": msg.id,
                "role": msg.role,
                "content": msg.content,
                "type": msg.type,
                "timestamp": int(msg.timestamp.replace(tzinfo=timezone.utc).timestamp() * 1000)
            }

    def clear_messages(self, user_id: int, persona_id: str = "default") -> int:
        """删除指定用户的指定人格的全部聊天记录，返回被删除的条数。"""
        with self.SessionLocal() as session:
            query = session.query(Message).filter(Message.user_id == user_id, Message.persona_id == persona_id)
            count = query.count()
            query.delete()
            session.commit()
            logger.info(f"[Lumi-Hub DB] 已清空用户 {user_id} 对人格 {persona_id} 的 {count} 条聊天记录")
            return count

    def get_messages(self, user_id: int, persona_id: str = "default", limit: int = 50, offset: int = 0) -> list:
        """倒序获取指定用户的特定人格的历史消息，返回格式化后的列表"""
        with self.SessionLocal() as session:
            # 按照时间降序获取（最新的在前面）
            messages = session.query(Message).filter(Message.user_id == user_id, Message.persona_id == persona_id)\
                              .order_by(Message.timestamp.desc())\
                              .offset(offset).limit(limit).all()
            
            # 为了给前端展示，通常需要按时间正序（旧的在上面，新的在下面）
            # 所以我们倒序获取后，再反转列表
            messages.reverse()
            
            result = []
            for msg in messages:
                result.append({
                    "message_id": msg.client_msg_id or str(msg.id),
                    "role": msg.role,
                    "content": msg.content,
                    "type": msg.type,
                    "timestamp": int(msg.timestamp.replace(tzinfo=timezone.utc).timestamp() * 1000)
                })
            return result
