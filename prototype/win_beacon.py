"""Windows 发 iBeacon 的实验工具（docs/protocol.md「用 iBeacon 拉起 App（实验）」）。

用 BluetoothLEAdvertisementPublisher 发厂商数据：Apple 的厂商编号 0x004C，后面是 02 15 + UUID + major + minor + 1 米处的信号。
UUID 和 App 里的 Proto.beaconUUID 一样，App 只按 UUID 监测，major.minor 用来区分是哪台电脑。

    python prototype\\win_beacon.py                  # 一直发，Ctrl+C 停
    python prototype\\win_beacon.py --on 30 --off 60 # 发 30 秒、停 60 秒，轮流

每次开、停、系统报的发布状态都记进 CSV（beacon_日期_时间_win32.csv，写在当前目录），和手机日志对时间。
只依赖 bleak 装进来的 winrt 包（pip install bleak）。
"""
import argparse
import csv
import struct
import sys
import time
import uuid
from datetime import datetime

if sys.platform != "win32":
    raise SystemExit("这是 Windows 版，Mac 用 prototype/mac_beacon/run.sh")

from winrt.windows.devices.bluetooth.advertisement import (
    BluetoothLEAdvertisementPublisher,
    BluetoothLEAdvertisementPublisherStatus,
    BluetoothLEManufacturerData,
)
from winrt.windows.storage.streams import Buffer

BEACON_UUID = uuid.UUID("9E698AEC-9C56-46E3-9209-F2628704D932")
APPLE_COMPANY_ID = 0x004C


def to_buffer(data):
    buf = Buffer(len(data))
    buf.length = len(data)
    with memoryview(buf) as mv:
        mv[:] = data
    return buf


class Log:
    def __init__(self, path):
        self.path = path
        self.f = open(path, "w", newline="", encoding="utf-8-sig")
        self.w = csv.writer(self.f)
        self.w.writerow(["time", "event", "note"])

    def write(self, event, note=""):
        now = datetime.now().isoformat(timespec="milliseconds")
        self.w.writerow([now, event, note])
        self.f.flush()
        print(now, event, note, flush=True)


def make_publisher(args, log):
    pub = BluetoothLEAdvertisementPublisher()
    md = BluetoothLEManufacturerData()
    md.company_id = APPLE_COMPANY_ID
    # iBeacon：02 15 + UUID（16 字节）+ major、minor（大端）+ 1 米处的信号（有符号）
    md.data = to_buffer(bytes([0x02, 0x15]) + BEACON_UUID.bytes + struct.pack(">HHb", args.major, args.minor, args.power))
    pub.advertisement.manufacturer_data.append(md)

    def on_status(sender, e):
        try:
            name = BluetoothLEAdvertisementPublisherStatus(e.status).name
        except ValueError:
            name = str(e.status)
        log.write("status", f"{name} error={e.error}")

    pub.add_status_changed(on_status)
    return pub


def main():
    p = argparse.ArgumentParser(description="Windows 发 iBeacon（实验）")
    p.add_argument("--major", type=int, default=1, help="默认 1（Windows）；Mac 用 2")
    p.add_argument("--minor", type=int, default=1)
    p.add_argument("--power", type=int, default=-59, help="1 米处的信号，默认 -59")
    p.add_argument("--on", type=float, default=0, help="和 --off 一起用：发多少秒")
    p.add_argument("--off", type=float, default=0, help="停多少秒；不给就一直发")
    p.add_argument("--out", help="日志 CSV 路径，默认 beacon_日期_时间_win32.csv")
    args = p.parse_args()

    log = Log(args.out or datetime.now().strftime("beacon_%Y%m%d_%H%M%S_win32.csv"))
    log.write("start", f"日志 {log.path}；" + (f"轮流发 {args.on} 秒、停 {args.off} 秒" if args.off > 0 else "一直发"))
    pub = make_publisher(args, log)
    on_note = f"uuid={str(BEACON_UUID).upper()} major={args.major} minor={args.minor} power={args.power}"
    try:
        while True:
            pub.start()
            log.write("beacon_on", on_note)
            if args.off <= 0:
                while True:
                    time.sleep(1)
            time.sleep(args.on)
            pub.stop()
            log.write("beacon_off", f"停 {args.off:.0f} 秒")
            time.sleep(args.off)
    except KeyboardInterrupt:
        pub.stop()
        log.write("stop", "Ctrl+C")


if __name__ == "__main__":
    main()
