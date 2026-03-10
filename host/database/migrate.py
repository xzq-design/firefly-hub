"""
数据库迁移脚本 - 给 users 表增加 token 列
运行方式（在项目根目录）:
    python -m host.database.migrate
"""
import os
import sqlite3
import secrets
import logging

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("lumi_hub.migrate")

def run_migration():
    # 查找数据库文件
    script_dir = os.path.dirname(os.path.abspath(__file__))
    project_root = os.path.dirname(os.path.dirname(script_dir))
    db_path = os.path.join(project_root, "data", "lumi_hub.db")
    
    if not os.path.exists(db_path):
        logger.info("数据库不存在，无需迁移（将由应用首次启动时创建）。")
        return

    logger.info(f"正在迁移数据库: {db_path}")
    conn = sqlite3.connect(db_path)
    cursor = conn.cursor()

    # 检查 token 列是否已存在
    cursor.execute("PRAGMA table_info(users)")
    columns = [row[1] for row in cursor.fetchall()]
    
    if "token" not in columns:
        logger.info("正在添加 token 列...")
        # SQLite 的 ALTER TABLE 不支持直接添加 UNIQUE 列，需分两步：先加列，再建唯一索引
        cursor.execute("ALTER TABLE users ADD COLUMN token TEXT")
        
        # 为已有用户生成 token
        cursor.execute("SELECT id FROM users WHERE token IS NULL")
        users = cursor.fetchall()
        for (user_id,) in users:
            token = secrets.token_hex(32)
            cursor.execute("UPDATE users SET token = ? WHERE id = ?", (token, user_id))
            logger.info(f"  已为 user_id={user_id} 生成新 token")
        
        conn.commit()
        
        # 建唯一索引（等效于 UNIQUE 约束）
        cursor.execute("CREATE UNIQUE INDEX IF NOT EXISTS ix_users_token ON users (token)")
        conn.commit()
        
        logger.info(f"✅ 迁移完成！已为 {len(users)} 个现有用户生成新 token。")
        logger.info("⚠️  已有用户的旧 token（即原来的用户 ID 数字）已失效，下次启动 App 后重新登录即可。")
    else:
        logger.info("token 列已存在，无需迁移。")
    
    conn.close()

if __name__ == "__main__":
    run_migration()
