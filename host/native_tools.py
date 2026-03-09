import os
import shutil
import time
import logging

logger = logging.getLogger("astrbot")

def read_file(path: str, start_line: int = 1, end_line: int = None) -> str:
    """读取本地文件内容，支持指定行范围。"""
    try:
        if not os.path.exists(path):
            return f"Error: File '{path}' does not exist."
        if not os.path.isfile(path):
            return f"Error: '{path}' is not a file."
        
        with open(path, 'r', encoding='utf-8') as f:
            lines = f.readlines()
            
        total_lines = len(lines)
        # 1-indexed conversion
        start = max(0, start_line - 1)
        end = end_line if end_line is not None else total_lines
        end = min(total_lines, end)
        
        if start >= total_lines:
            return f"Error: start_line {start_line} exceeds total lines {total_lines}."
            
        selected_lines = lines[start:end]
        output = []
        for i, line in enumerate(selected_lines):
            # 仅移除行尾换行符，保留所有空格，确保 AI 能看到真实的缩进和尾随空格
            line_content = line.replace("\n", "").replace("\r", "")
            output.append(f"L{start + i + 1}: {line_content}")
            
        summary = f"\n--- Lines {start+1} to {end} of {total_lines} ---"
        hint = "\n[AI HINT] Code read successful. You can now use `insert_content` or `replace_content` to apply changes. Refer to 'Lx' for line numbers."
        return "\n".join(output) + summary + hint
    except Exception as e:
        return f"Error reading file: {e}"

def backup_file(path: str) -> bool:
    """修改文件前备份。失败时记录错误并返回 False。"""
    try:
        if not os.path.exists(path):
            return False
        
        # 获取绝对路径以避免 CWD 变化导致的路径问题
        abs_path = os.path.abspath(path)
        base_dir = os.path.dirname(abs_path)
        cache_dir = os.path.join(base_dir, ".Lumi_cache")
        
        os.makedirs(cache_dir, exist_ok=True)
        filename = os.path.basename(abs_path)
        timestamp = int(time.time())
        backup_path = os.path.join(cache_dir, f"{filename}.{timestamp}.bak")
        
        shutil.copy2(abs_path, backup_path)
        logger.info(f"[Lumi-Hub] 备份成功: {abs_path} -> {backup_path}")
        return True
    except Exception as e:
        logger.error(f"[Lumi-Hub] 备份失败! 路径: {path}, 错误: {str(e)}")
        return False

def list_dir(path: str) -> str:
    """列出目录下文件"""
    try:
        if not os.path.exists(path):
            return f"Error: Directory '{path}' does not exist."
        if not os.path.isdir(path):
            return f"Error: '{path}' is not a directory."
        res = []
        for x in os.listdir(path):
            try:
                full_path = os.path.join(path, x)
                is_dir = "DIR " if os.path.isdir(full_path) else "FILE"
                res.append(f"[{is_dir}] {x}")
            except Exception:
                res.append(f"[UNKNOWN] {x}")
        return "\n".join(res)
    except Exception as e:
        return f"Error listing dir: {e}"

        
def write_file(path: str, content: str) -> str:
    """写入文件内容 (会先进行安全备份)"""
    try:
        if os.path.exists(path):
            if not backup_file(path):
                return f"Error: Failed to backup {path}. Operation aborted for safety."
        
        with open(path, 'w', encoding='utf-8') as f:
            f.write(content)
        return f"Successfully wrote to {path}"
    except Exception as e:
        return f"Error writing file: {e}"

def delete_file(path: str) -> str:
    """删除文件 (会先进入 .Lumi_cache 备份，随后物理删除)"""
    try:
        if not os.path.exists(path):
            return f"Error: File '{path}' does not exist."
        
        if not backup_file(path):
            return f"Error: Failed to backup {path}. Deletion aborted for safety."
            
        os.remove(path)
        return f"Successfully deleted {path} (backup created in .Lumi_cache)"
    except Exception as e:
        return f"Error deleting file: {e}"

def replace_content(path: str, old_content: str, new_content: str) -> str:
    """部分替换文件内容 (针对单行或简单代码块)"""
    try:
        if not os.path.exists(path):
            return f"Error: File '{path}' does not exist."
        
        with open(path, 'r', encoding='utf-8') as f:
            text = f.read()
        
        if old_content not in text:
            return f"Error: Could not find the specified content to replace in {path}."
        
        count = text.count(old_content)
        if count > 1:
            return f"Error: Found {count} occurrences of the target content. Please provide a more unique snippet to replace."
        
        if not backup_file(path):
            return f"Error: Failed to backup {path}. Modification aborted for safety."
            
        updated_text = text.replace(old_content, new_content)
        
        with open(path, 'w', encoding='utf-8') as f:
            f.write(updated_text)
        
        return f"Successfully updated {path}."
    except Exception as e:
        return f"Error replacing content: {e}"

def insert_content(path: str, line_number: int, content: str) -> str:
    """在指定行号位置插入内容 (1-indexed)"""
    try:
        if not os.path.exists(path):
            return f"Error: File '{path}' does not exist."
        
        with open(path, 'r', encoding='utf-8') as f:
            lines = f.readlines()
        
        total_lines = len(lines)
        idx = max(0, line_number - 1)
        if idx >= total_lines:
            lines.append(content + "\n")
        else:
            lines.insert(idx, content + "\n")
            
        if not backup_file(path):
            return f"Error: Failed to backup {path}. Insertion aborted for safety."
            
        with open(path, 'w', encoding='utf-8') as f:
            f.writelines(lines)
            
        return f"Successfully inserted content at line {line_number} in {path}."
    except Exception as e:
        return f"Error inserting content: {e}"

def search_replace(path: str, search_block: str, replace_block: str) -> str:
    """IDE 风格的搜索替换工具。鲁棒性增强：忽略行尾空格差异。"""
    try:
        if not os.path.exists(path):
            return f"Error: File '{path}' does not exist."
        
        with open(path, 'r', encoding='utf-8') as f:
            full_content = f.read()
        
        lines = full_content.splitlines()
        search_lines = search_block.splitlines()
        
        match_start = -1
        match_count = 0
        
        for i in range(len(lines) - len(search_lines) + 1):
            is_match = True
            for j in range(len(search_lines)):
                # 比较时忽略行尾空格
                if lines[i+j].rstrip() != search_lines[j].rstrip():
                    is_match = False
                    break
            if is_match:
                match_start = i
                match_count += 1
        
        if match_count == 0:
            return f"Error: Search block not found in {path}. Please ensure indentation matches exactly."
        if match_count > 1:
            return f"Error: Search block found {match_count} times. Please provide a more unique block."
        
        new_lines = lines[:match_start] + replace_block.splitlines() + lines[match_start + len(search_lines):]
        
        if not backup_file(path):
            return f"Error: Failed to backup {path}. Modification aborted for safety."
            
        with open(path, 'w', encoding='utf-8', newline='\n') as f:
            f.write("\n".join(new_lines) + "\n")
            
        return f"Successfully applied changes to {path}."
    except Exception as e:
        return f"Error in search_replace: {e}"

def get_file_size(path: str) -> str:
    """获取文件的字节数大小"""
    try:
        if not os.path.exists(path):
            return f"Error: File '{path}' does not exist."
        if not os.path.isfile(path):
            return f"Error: '{path}' is not a file."
        
        size = os.path.getsize(path)
        return f"File '{os.path.basename(path)}' size: {size} bytes ({size / 1024:.2f} KB, {size / 1024 / 1024:.2f} MB)"
    except Exception as e:
        return f"Error getting file size: {e}"
