#!/usr/bin/env python3
"""
测电源请求能不能挡住"关屏就进现代待机"：打开电源请求 → 关屏 → 等 15 秒 → 查系统日志里有没有
Kernel-Power 506（进入待机）。测试期间别碰键盘鼠标；结束后动一下鼠标屏幕就亮。

    .venv\\Scripts\\python.exe prototype\\keep_awake_test.py            # 带电源请求
    .venv\\Scripts\\python.exe prototype\\keep_awake_test.py --without  # 不带，对照
"""

import subprocess
import sys
import time
from datetime import datetime

sys.argv, without = sys.argv[:1], "--without" in sys.argv
import win_peer as w

start = datetime.now()
awake = w.KeepAwake()
if not without:
    print("打开电源请求：", "成功" if awake.set(True) else "失败")
time.sleep(1)
print(f"{datetime.now():%H:%M:%S} 关屏，15 秒内别碰键盘鼠标…", flush=True)
w.turn_off_display()
t0 = time.time()
time.sleep(15)
waited = time.time() - t0
awake.set(False)
print(f"{datetime.now():%H:%M:%S} 结束，实际过了 {waited:.0f} 秒" +
      ("（比 15 秒长很多，说明中间被暂停过）" if waited > 20 else ""))

ps = ("Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='Microsoft-Windows-Kernel-Power'; "
      f"StartTime=[datetime]'{start:%Y-%m-%d %H:%M:%S}'}} -ErrorAction SilentlyContinue | "
      "Where-Object { $_.Id -in 506,507 } | ForEach-Object { $_.TimeCreated.ToString('HH:mm:ss') + ' ' + $_.Id }")
events = subprocess.run(["powershell", "-NoProfile", "-Command", ps], capture_output=True, text=True).stdout.split()
entered = [e for e in zip(events[::2], events[1::2]) if e[1] == "506"]
print("系统日志：", " ".join(f"{t} {'进入待机' if i == '506' else '退出待机'}" for t, i in zip(events[::2], events[1::2]))
      or "这段时间没有进入、退出待机")
print("结论：", "进了待机" if entered else "没进待机", "（带电源请求）" if not without else "（不带电源请求，对照）")
