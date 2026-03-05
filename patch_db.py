import sqlite3
import os
import json

db_path = r"D:\astrbot-develop\AstrBot\data\data_v4.db"

if not os.path.exists(db_path):
    print(f"Database {db_path} not found.")
    exit(1)

try:
    conn = sqlite3.connect(db_path)
    cursor = conn.cursor()

    # AstrBot Stores provider/platform config in kv table or specific tables
    # Let's search all tables for "firefly_hub" and replace it with "lumi_hub"
    
    # 1. Check if there's a table named "plugin_config" or similar
    cursor.execute("SELECT name FROM sqlite_master WHERE type='table';")
    tables = cursor.fetchall()
    
    for table_tuple in tables:
        table = table_tuple[0]
        # Just simple text search and replace if it's a known table holding config
        if table == "kv":
            # AstrBot kv table usually stores json configs
            cursor.execute(f"SELECT id, value FROM {table} WHERE value LIKE '%firefly_hub%'")
            rows = cursor.fetchall()
            for r_id, r_val in rows:
                new_val = r_val.replace("firefly_hub", "lumi_hub").replace("Firefly-Hub", "Lumi-Hub")
                cursor.execute(f"UPDATE {table} SET value = ? WHERE id = ?", (new_val, r_id))
                print(f"Updated {table} id={r_id}")
                
        elif table == "platform_config":
            cursor.execute(f"SELECT * FROM pragma_table_info('{table}')")
            cols = [col[1] for col in cursor.fetchall()]
            if 'id' in cols and 'adapter_name' in cols:
                cursor.execute(f"UPDATE {table} SET adapter_name = 'lumi_hub' WHERE adapter_name = 'firefly_hub'")
                cursor.execute(f"UPDATE {table} SET id = REPLACE(id, 'firefly_hub', 'lumi_hub')")
                print(f"Updated {table}")
                
    conn.commit()
    print("Successfully patched AstrBot database. Please restart AstrBot.")
    
except Exception as e:
    print(f"Error: {e}")
finally:
    if 'conn' in locals():
        conn.close()
