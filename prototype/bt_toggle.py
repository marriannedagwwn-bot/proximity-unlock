#!/usr/bin/env python3
"""
关开一次电脑的蓝牙（Windows）。用来修"协议广播一直 ABORTED"。关开的那几秒所有蓝牙设备会断开一下。
实测：手机订阅着电脑端的服务时把服务撤掉（重启、卡死重启），之后整台电脑的可连接广播都开不起来，
只有关开蓝牙能恢复。另外有的程序（比如某些手机互联软件）会在蓝牙打开约 4 秒后占住可连接广播，所以关开以后要马上启动电脑端（--settle 0）。

    .venv\\Scripts\\python.exe prototype\\bt_toggle.py            # 关 5 秒再开
    .venv\\Scripts\\python.exe prototype\\bt_toggle.py --off 10   # 关 10 秒
"""

import argparse
import asyncio
import sys

from winrt.windows.devices.radios import Radio, RadioKind, RadioState


async def find_bluetooth():
    for r in await Radio.get_radios_async():
        if r.kind == RadioKind.BLUETOOTH:
            return r
    return None


async def toggle(off_seconds, settle=2):
    access = await Radio.request_access_async()
    if access.name != "ALLOWED":
        print(f"没有控制蓝牙开关的权限：{access.name}")
        return 1
    radio = await find_bluetooth()
    if radio is None:
        print("没找到蓝牙")
        return 1
    print(f"蓝牙现在：{radio.state.name}")
    r = await radio.set_state_async(RadioState.OFF)
    print(f"关：{r.name}")
    await asyncio.sleep(off_seconds)
    r = await radio.set_state_async(RadioState.ON)
    print(f"开：{r.name}", flush=True)
    if settle:
        await asyncio.sleep(settle)
        print(f"蓝牙现在：{(await find_bluetooth()).state.name}")
    return 0


if __name__ == "__main__":
    p = argparse.ArgumentParser(description="关开一次电脑的蓝牙")
    p.add_argument("--off", type=float, default=5, help="关多少秒，默认 5")
    p.add_argument("--settle", type=float, default=2, help="打开后等几秒再看一次状态，默认 2；0 表示开了马上返回")
    a = p.parse_args()
    sys.exit(asyncio.run(toggle(a.off, a.settle)))
