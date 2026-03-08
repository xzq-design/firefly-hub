import os
from datetime import datetime
from sqlalchemy import Column, Integer, String, DateTime, Text, ForeignKey, create_engine
from sqlalchemy.orm import declarative_base, relationship, sessionmaker

Base = declarative_base()

class User(Base):
    __tablename__ = 'users'

    id = Column(Integer, primary_key=True, autoincrement=True)
    username = Column(String(50), unique=True, nullable=False, index=True)
    password_hash = Column(String(128), nullable=False)
    created_at = Column(DateTime, default=datetime.utcnow)

    # 关联用户的聊天记录
    messages = relationship("Message", back_populates="user", cascade="all, delete-orphan")

    def __repr__(self):
        return f"<User(username='{self.username}')>"

class Message(Base):
    __tablename__ = 'messages'

    id = Column(Integer, primary_key=True, autoincrement=True)
    user_id = Column(Integer, ForeignKey('users.id'), nullable=False, index=True)
    # role 通常是 'user', 'assistant', 或 'system'
    role = Column(String(20), nullable=False)
    # 消息内容，针对不同 type 这里可以是纯文本，也可以是 JSON string
    content = Column(Text, nullable=False)
    # 消息类型，如 'chat', 'tool_result'
    type = Column(String(50), default='chat')
    timestamp = Column(DateTime, default=datetime.utcnow, index=True)
    
    # 防止多端同步时出现重复 id（如果有前端生成的 UUID 的话可以存这里，目前先作为可选）
    client_msg_id = Column(String(64), nullable=True, unique=True)

    user = relationship("User", back_populates="messages")

    def __repr__(self):
        return f"<Message(role='{self.role}', type='{self.type}', len={len(self.content)})>"

# 数据库引擎初始化辅助函数
def init_db(db_path: str):
    engine = create_engine(f"sqlite:///{db_path}", echo=False)
    Base.metadata.create_all(engine)
    return sessionmaker(bind=engine)
