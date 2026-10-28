#!/usr/bin/env python3
"""
手机在 App 里点「扫码登记」时，win_peer.py 收到 ENROLL_REQUEST 就另起这个进程（docs/protocol.md「手机请求显示登记码」）。
先问用户要不要显示二维码：附近任何设备都能写这个请求，不先问的话别人可能趁电脑开着把登记码弹出来拍走。
点了「是」：已登记就打开本机登记窗口（ProximityUnlock.exe export，窗口里有二维码，手机扫完会自己关）；
没登记只提示用管理员身份登记，不在这里提权。弹窗在单独的进程里，卡不住电脑端的蓝牙。

只用标准库：电脑端用哪个 Python 起它都行。
"""

import ctypes
import json
import os
import subprocess
import sys

TITLE = "iPhone 靠近解锁"
ASK = ("有 iPhone 通过蓝牙请求登记靠近解锁，要在这台电脑上显示登记二维码吗？\n\n"
       "二维码就是解锁这台电脑用的密钥。不是你自己刚在手机上点的「扫码登记」，就选「否」。")
NOT_INSTALLED = ("这台电脑还没装靠近解锁的本机组件，没法显示登记码。\n\n"
                 "请先按 prototype\\windows_unlock\\README.md 构建、安装并登记。")
NOT_ENROLLED = ("这台电脑还没登记靠近解锁（或者登记还没验证），没有可以显示的登记码。\n\n"
                "请在电脑上用管理员身份运行下面的命令登记，登记完会弹出二维码：\n"
                "powershell -ExecutionPolicy Bypass -File prototype\\windows_unlock\\manage.ps1 -Action Enroll")
FAILED = "打不开登记窗口。可以在电脑上运行 manage.ps1 -Action Export 试试。"

MB_YESNO, MB_OK = 0x4, 0x0
MB_ICONQUESTION, MB_ICONINFORMATION, MB_ICONWARNING = 0x20, 0x40, 0x30
MB_DEFBUTTON2, MB_SETFOREGROUND, MB_TOPMOST = 0x100, 0x10000, 0x40000
IDYES = 6
NO_WINDOW = getattr(subprocess, "CREATE_NO_WINDOW", 0)


def helper_path():
    return os.path.join(os.environ.get("ProgramFiles", r"C:\Program Files"), "ProximityUnlock", "ProximityUnlock.exe")


def decide(installed, status):
    """
    根据本机组件装没装、helper status 的结果决定怎么办：
    export（显示现有登记码）、not_installed、not_enrolled（没登记或还没验证）
    """
    if not installed:
        return "not_installed"
    if isinstance(status, dict) and status.get("available") is True:
        return "export"
    return "not_enrolled"


def read_status(helper):
    try:
        out = subprocess.run([helper, "status"], capture_output=True, text=True, timeout=15,
                             creationflags=NO_WINDOW).stdout
        return json.loads(out.strip().splitlines()[-1])
    except (OSError, ValueError, IndexError, subprocess.SubprocessError):
        return None


def message(text, flags):
    # 后台进程起的窗口抢不到前台：置顶并请求前台，至少看得见
    return ctypes.windll.user32.MessageBoxW(None, text, TITLE, flags | MB_TOPMOST | MB_SETFOREGROUND)


def main():
    if message(ASK, MB_YESNO | MB_ICONQUESTION | MB_DEFBUTTON2) != IDYES:
        return 1
    helper = helper_path()
    action = decide(os.path.isfile(helper), read_status(helper) if os.path.isfile(helper) else None)
    if action == "not_installed":
        message(NOT_INSTALLED, MB_OK | MB_ICONINFORMATION)
        return 2
    if action == "not_enrolled":
        message(NOT_ENROLLED, MB_OK | MB_ICONINFORMATION)
        return 2
    # 用户刚点了「是」，这个进程现在在前台：允许接下来起的登记窗口拿到前台，不然会压在别的窗口下面
    ctypes.windll.user32.AllowSetForegroundWindow(-1)  # ASFW_ANY
    try:
        rc = subprocess.run([helper, "export"], creationflags=NO_WINDOW).returncode
    except OSError:
        rc = -1
    if rc != 0:
        message(FAILED, MB_OK | MB_ICONWARNING)
    return 0 if rc == 0 else 3


if __name__ == "__main__":
    sys.exit(main())
