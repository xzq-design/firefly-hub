import os
import subprocess
import shutil

old_dir = r"D:\astrbot-develop\AstrBot\data\plugins\firefly_hub"
new_dir = r"D:\astrbot-develop\AstrBot\data\plugins\lumi_hub"
target = r"E:\Lumi-Hub\host"

try:
    if os.path.exists(old_dir) or os.path.islink(old_dir):
        print(f"Removing {old_dir} ...")
        if os.path.islink(old_dir):
            os.unlink(old_dir)
        elif os.path.isdir(old_dir):
            try:
                os.rmdir(old_dir)
            except OSError:
                shutil.rmtree(old_dir)
    
    if not os.path.exists(new_dir):
        print(f"Creating symlink {new_dir} -> {target} ...")
        # Use mklink /J for Windows directory junction which doesn't require admin
        subprocess.run(f'cmd /c mklink /J "{new_dir}" "{target}"', shell=True, check=True)
        print("Success!")
    else:
        print(f"{new_dir} already exists.")
except Exception as e:
    print(f"Error: {e}")
