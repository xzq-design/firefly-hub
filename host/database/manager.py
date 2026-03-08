import os
import logging
import hashlib
import datetime
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
            new_user = User(username=username, password_hash=hashed_pwd)
            session.add(new_user)
            session.commit()
            session.refresh(new_user)
            
            return {
                "id": new_user.id,
                "username": new_user.username,
                "created_at": new_user.created_at.isoformat()
            }

    def verify_user(self, username: str, password: str) -> dict:
        """验证用户登录。成功返回用户信息，失败返回 error。"""
        with self.SessionLocal() as session:
            user = session.query(User).filter(User.username == username).first()
            if not user or not self.verify_password(password, user.password_hash):
                return {"error": "Invalid username or password"}
                
            return {
                "id": user.id,
                "username": user.username,
                "created_at": user.created_at.isoformat()
            }
            
    def get_user_by_id(self, user_id: int):
        with self.SessionLocal() as session:
            user = session.query(User).filter(User.id == user_id).first()
            if user:
                return {"id": user.id, "username": user.username}
            return None

    # ===== 消息相关 =====

    def save_message(self, user_id: int, role: str, content: str, msg_type: str = 'chat', client_msg_id: str = None) -> dict:
        """保存单条消息记录"""
        with self.SessionLocal() as session:
            msg = Message(
                user_id=user_id,
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
                "timestamp": int(msg.timestamp.replace(tzinfo=datetime.timezone.utc).timestamp() * 1000)
            }

    def get_messages(self, user_id: int, limit: int = 50, offset: int = 0) -> list:
        """倒序获取指定用户的历史消息，返回格式化后的列表"""
        with self.SessionLocal() as session:
            # 按照时间降序获取（最新的在前面）
            messages = session.query(Message).filter(Message.user_id == user_id)\
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
                    "timestamp": int(msg.timestamp.replace(tzinfo=datetime.timezone.utc).timestamp() * 1000)
                })
            return result
