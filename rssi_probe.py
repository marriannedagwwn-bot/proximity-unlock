#!/usr/bin/env python3
"""
iPhone 蓝牙信号实测工具（Windows / macOS 通用）

  scan     扫描附近的蓝牙设备，找出你的 iPhone
  record   持续记录 iPhone 的信号强度，按数字键标记"手机现在在哪"
  analyze  分析记录文件：各位置的信号分布、远近能否分开、建议阈值、模拟锁屏/解锁

依赖：pip install bleak（analyze 不需要）
"""

import argparse
import asyncio
import csv
import math
import os
import shutil
import sys
import time
import unicodedata
from collections import deque
from datetime import datetime

APPLE_COMPANY_ID = 0x004C

# Apple Continuity 广播里的消息类型
CONTINUITY_TYPES = {
    0x02: "iBeacon", 0x03: "AirPrint", 0x05: "AirDrop", 0x06: "HomeKit",
    0x07: "耳机配对", 0x08: "Siri", 0x09: "AirPlay目标", 0x0A: "AirPlay源",
    0x0B: "手表切换", 0x0C: "Handoff", 0x0D: "热点目标", 0x0E: "个人热点",
    0x0F: "附近操作", 0x10: "附近信息", 0x12: "查找",
}
NEARBY_INFO = 0x10

CLASS_CN = {"near": "近", "far": "远", "mid": "中间", "mix": "混合", "skip": "暂停"}
DEFAULT_LABELS = "桌上:near,兜里:near,1米:mid,3米:far,门口:far,隔壁:far,日常:mix"

NEAR, FAR, UNKNOWN = "near", "far", "unknown"
STATE_CN = {NEAR: "靠近", FAR: "离开", UNKNOWN: "未定"}

CSV_FIELDS = ["time", "t", "event", "addr", "rssi", "label", "class", "apple", "name", "note"]
GRID_STEP = 0.25


# ---------------------------------------------------------------- 小工具

def disp_width(s):
    return sum(2 if unicodedata.east_asian_width(c) in "WF" else 1 for c in s)


def pad(s, width):
    s = str(s)
    return s + " " * max(0, width - disp_width(s))


def truncate(s, width):
    out, w = "", 0
    for c in s:
        cw = disp_width(c)
        if w + cw > width:
            break
        out += c
        w += cw
    return out


def print_table(headers, rows):
    widths = [max(disp_width(str(x)) for x in col) for col in zip(headers, *rows)]
    print("  ".join(pad(h, w) for h, w in zip(headers, widths)))
    for r in rows:
        print("  ".join(pad(x, w) for x, w in zip(r, widths)))


def percentile(values, p):
    if not values:
        return None
    v = sorted(values)
    k = (len(v) - 1) * p / 100
    lo, hi = math.floor(k), math.ceil(k)
    return v[lo] + (v[hi] - v[lo]) * (k - lo)


def median(values):
    return percentile(values, 50)


def stdev(values):
    if len(values) < 2:
        return 0.0
    m = sum(values) / len(values)
    return math.sqrt(sum((x - m) ** 2 for x in values) / (len(values) - 1))


def fmt_t(t):
    t = max(0, int(t))
    return f"{t // 60:02d}:{t % 60:02d}"


def fmt_db(x):
    return "-" if x is None else f"{x:.0f}"


def is_dup(last, addr, t):
    """Windows 会把同一次广播的广播包和扫描响应分成两条上报，0.1 秒内同一设备只算一次"""
    return last[0] == addr and t - last[1] < 0.1


def parse_apple(data):
    """把 Apple 厂商数据拆成 Continuity 消息类型列表"""
    types, i = [], 0
    while i + 1 < len(data):
        types.append(data[i])
        i += 2 + data[i + 1]
    return tuple(types)


def apple_desc(types):
    if not types:
        return ""
    return "/".join(CONTINUITY_TYPES.get(x, f"0x{x:02X}") for x in dict.fromkeys(types))


def parse_labels(spec):
    labels = []
    for item in spec.split(","):
        item = item.strip()
        if not item:
            continue
        name, _, cls = item.partition(":")
        cls = cls.strip() or "mid"
        if cls not in ("near", "far", "mid", "mix"):
            raise SystemExit(f"标签类别只能是 near/far/mid/mix：{item}")
        labels.append((name.strip(), cls))
    if not 1 <= len(labels) <= 9:
        raise SystemExit("标签数量需要在 1 到 9 个之间")
    return labels


# ---------------------------------------------------------------- 信号处理（record 和 analyze 共用）

class MedianFilter:
    """最近 window 秒内的中位数；窗口内没有新数据时保持上一次的值"""

    def __init__(self, window):
        self.window = window
        self.buf = deque()
        self.last = None

    def add(self, t, rssi):
        self.buf.append((t, rssi))

    def value(self, t):
        while self.buf and self.buf[0][0] <= t - self.window:
            self.buf.popleft()
        fresh = bool(self.buf)
        if fresh:
            self.last = median([r for _, r in self.buf])
        return self.last, fresh


class PresenceFSM:
    """近 / 远 状态机：双阈值滞回 + 持续时间 + 信号消失判定"""

    def __init__(self, near_th, far_th, t_near, t_far, t_lost, start_t=0.0):
        if near_th <= far_th:
            raise SystemExit(f"靠近阈值({near_th})必须大于离开阈值({far_th})")
        self.near_th, self.far_th = near_th, far_th
        self.t_near, self.t_far, self.t_lost = t_near, t_far, t_lost
        self.start_t = start_t
        self.state = UNKNOWN
        self.near_since = None
        self.far_since = None

    def update(self, t, filtered, last_sample_t):
        """返回 (新状态, 原因)；状态没变返回 None"""
        ref = last_sample_t if last_sample_t is not None else self.start_t
        if t - ref >= self.t_lost:
            self.near_since = self.far_since = None
            return self._set(FAR, f"信号消失 {self.t_lost:g}s")
        if filtered is None:
            return None
        if filtered >= self.near_th:
            if self.near_since is None:
                self.near_since = t
        else:
            self.near_since = None
        if filtered <= self.far_th:
            if self.far_since is None:
                self.far_since = t
        else:
            self.far_since = None
        if self.state != NEAR and self.near_since is not None and t - self.near_since >= self.t_near:
            return self._set(NEAR, f"≥{self.near_th} 持续 {self.t_near:g}s")
        if self.state != FAR and self.far_since is not None and t - self.far_since >= self.t_far:
            return self._set(FAR, f"≤{self.far_th} 持续 {self.t_far:g}s")
        return None

    def _set(self, state, reason):
        if state == self.state:
            return None
        self.state = state
        return state, reason


# ---------------------------------------------------------------- 蓝牙扫描

def patch_macos_duplicates():
    """macOS 上 bleak 默认把同一设备的重复广播合并掉，采样会很稀疏，这里打开 AllowDuplicates"""
    if sys.platform != "darwin":
        return
    try:
        from bleak.backends.corebluetooth.CentralManagerDelegate import CentralManagerDelegate
        try:
            from CoreBluetooth import CBCentralManagerScanOptionAllowDuplicatesKey as key
        except ImportError:
            key = "kCBScanOptionAllowDuplicates"

        async def start_scan(self, service_uuids):
            self.central_manager.scanForPeripheralsWithServices_options_(None, {key: True})

        CentralManagerDelegate.start_scan = start_scan
    except Exception as e:
        print(f"提示：无法开启 macOS 重复上报（{e}），采样率可能偏低。")


def import_bleak():
    try:
        from bleak import BleakScanner
    except ImportError:
        raise SystemExit("缺少 bleak，请先运行：pip install bleak")
    patch_macos_duplicates()
    return BleakScanner


def addr_type(adv):
    """Windows 上能拿到地址类型：'公开'说明系统已经认出了设备的真实地址"""
    try:
        raw = adv.platform_data[1]
        ev = raw.adv or raw.scan
        return {0: "公开", 1: "随机"}.get(int(ev.bluetooth_address_type), "")
    except Exception:
        return ""


class Adv:
    __slots__ = ("t", "addr", "rssi", "name", "apple", "addr_type")

    def __init__(self, t, device, adv):
        self.t = t
        self.addr = device.address
        self.rssi = adv.rssi
        self.name = adv.local_name or device.name or ""
        data = adv.manufacturer_data.get(APPLE_COMPANY_ID)
        self.apple = parse_apple(data) if data is not None else None
        self.addr_type = addr_type(adv)

    @property
    def valid(self):
        # Windows 用 -127 表示超出范围，macOS 用 127 表示拿不到
        return self.rssi is not None and -120 < self.rssi < 0


class DevStat:
    def __init__(self, addr):
        self.addr = addr
        self.rssis = []
        self.name = ""
        self.types = {}
        self.addr_type = ""
        self.first = self.last = None
        self.times = []

    def add(self, a):
        self.name = a.name or self.name
        self.addr_type = a.addr_type or self.addr_type
        for x in a.apple or ():
            self.types[x] = None
        if is_dup((self.addr, self.last if self.last is not None else -1.0), a.addr, a.t):
            return
        if self.first is None:
            self.first = a.t
        self.last = a.t
        self.rssis.append(a.rssi)
        self.times.append(a.t)

    def max_gap(self, start, end):
        times = [start] + self.times + [end]
        return max(b - a for a, b in zip(times, times[1:]))

    @property
    def is_apple(self):
        return bool(self.types)


# ---------------------------------------------------------------- scan

async def cmd_scan(args):
    BleakScanner = import_bleak()
    t0 = time.monotonic()
    stats = {}

    def on_adv(device, adv):
        a = Adv(time.monotonic() - t0, device, adv)
        if not a.valid or (a.apple is None and not args.all):
            return
        stats.setdefault(a.addr, DevStat(a.addr)).add(a)

    print(f"扫描 {args.seconds:g} 秒…请把 iPhone 解锁亮屏，放在电脑旁边。")
    async with BleakScanner(detection_callback=on_adv):
        await asyncio.sleep(args.seconds)

    devs = sorted(stats.values(), key=lambda d: max(d.rssis), reverse=True)
    if not devs:
        print("没有扫到设备。检查电脑蓝牙是否打开；macOS 需要在 系统设置 → 隐私与安全性 → 蓝牙 里允许终端。")
        return
    rows = []
    for i, d in enumerate(devs[: args.top], 1):
        rows.append([
            i, d.addr, truncate(d.name, 16) or "-", apple_desc(d.types) or "-", d.addr_type or "-",
            len(d.rssis), f"{len(d.rssis) / args.seconds:.1f}", f"{d.max_gap(0, args.seconds):.1f}s",
            max(d.rssis), fmt_db(median(d.rssis)),
        ])
    print()
    print_table(["#", "地址/ID", "名称", "Apple 消息类型", "地址类型", "包数", "包/秒", "最长间隔",
                 "最强", "中位"], rows)
    print()
    print("信号最强、带「附近信息」的 Apple 设备通常就是你的 iPhone（注意别和旁边的 Mac 搞混）。")
    print("下一步：python rssi_probe.py record            （自动选信号最强的 Apple 设备）")
    print("   或：python rssi_probe.py record --target <地址/ID>")


# ---------------------------------------------------------------- record

class KeyReader:
    """不用回车的单键读取，Windows 用 msvcrt，macOS 用 cbreak 模式"""

    def __init__(self):
        self.ok = False
        self._old = None

    def __enter__(self):
        try:
            if not sys.stdin.isatty():
                return self
            if os.name == "nt":
                import msvcrt
                self._msvcrt = msvcrt
            else:
                import termios
                import tty
                self._old = termios.tcgetattr(sys.stdin.fileno())
                tty.setcbreak(sys.stdin.fileno())
            self.ok = True
        except Exception:
            self.ok = False
        return self

    def __exit__(self, *exc):
        if self._old is not None:
            import termios
            termios.tcsetattr(sys.stdin.fileno(), termios.TCSADRAIN, self._old)

    def get(self):
        if not self.ok:
            return None
        if os.name == "nt":
            if not self._msvcrt.kbhit():
                return None
            ch = self._msvcrt.getwch()
            if ch in ("\x00", "\xe0"):  # 方向键等功能键会多带一个字符
                self._msvcrt.getwch()
                return None
            return ch
        import select
        if select.select([sys.stdin], [], [], 0)[0]:
            return sys.stdin.read(1)
        return None


class Tracker:
    """跟住目标设备。iPhone 大约每 15 分钟换一次随机地址，换地址时自动跟到新地址上"""

    def __init__(self, target, follow, ready_t=0.0, min_gap=15.0, max_gap=120.0, name_fallback=90.0):
        self.target = target
        self.follow = follow
        self.ready_t = ready_t  # 这之前就出现的设备一律不当作"新地址"
        self.min_gap, self.max_gap = min_gap, max_gap
        self.name_fallback = name_fallback
        self.last_seen = None
        self.types = set()
        # 有些 iPhone 广播里带一个固定名字，换地址也不变。只记第一次看到的，免得跟错后被别的设备的名字覆盖
        self.name = ""
        self.first_seen = {}
        self.prev = None
        self.prev_switch_t = None

    def feed(self, a):
        """返回 (这条是不是目标的, 换地址说明)"""
        self.first_seen.setdefault(a.addr, a.t)
        if a.addr == self.target:
            self.last_seen = a.t
            self.types.update(a.apple or ())
            self.name = self.name or a.name
            return True, None
        if not self.follow or a.apple is None or self.last_seen is None:
            return False, None
        if self.name:
            if a.name == self.name:
                self.prev, self.target = self.target, a.addr
                self.prev_switch_t = self.last_seen = a.t
                return True, f"目标换了地址 {self.prev} → {a.addr}（名字相同）"
            # 知道名字时只按名字跟；按"消失后出现的新地址"去猜很容易跟到别的 Apple 设备上，
            # 只有目标消失太久（可能连名字也换了）才退回去猜
            if a.t - self.last_seen < self.name_fallback:
                return False, None
        # 换过去之后旧地址又出现了：说明跟错了设备，切回来
        if a.addr == self.prev and a.t - self.prev_switch_t < 60:
            wrong, self.target, self.prev = self.target, a.addr, None
            self.last_seen = a.t
            return True, f"原地址又出现，切回 {a.addr}（刚才误跟了 {wrong}）"
        gap = a.t - self.last_seen
        first = self.first_seen[a.addr]
        is_new = first >= self.last_seen - 0.5 and first > self.ready_t
        overlap = not self.types or bool(self.types & set(a.apple))
        if is_new and overlap and self.min_gap <= gap <= self.max_gap:
            self.prev, self.target = self.target, a.addr
            self.prev_switch_t = self.last_seen = a.t
            self.types = set(a.apple)
            return True, f"目标换了地址 {self.prev} → {a.addr}（消失 {gap:.1f}s 后出现的新 Apple 地址）"
        return False, None


class Recorder:
    def __init__(self, args, labels):
        self.args = args
        self.labels = labels
        self.t0 = time.monotonic()
        self.cands = {}
        # 手动指定目标时没有"自动选目标"那几秒来认识周围设备，先观察 5 秒再允许跟踪换地址
        self.tracker = Tracker(args.target, follow=not args.no_follow, ready_t=5.0 if args.target else 0.0)
        self.filter = MedianFilter(args.window)
        self.fsm = PresenceFSM(args.near_th, args.far_th, args.t_near, args.t_far, args.t_lost)
        self.recent = deque()
        self.n_samples = 0
        self.last_rssi = None
        self.last_sample = (None, -1.0)
        self.label, self.cls = "暂停", "skip"
        self.tty = sys.stdout.isatty()
        self.status_w = 0

        self.path = args.out or datetime.now().strftime(f"rssi_%Y%m%d_%H%M%S_{sys.platform}.csv")
        self.file = open(self.path, "w", newline="", encoding="utf-8-sig")
        self.csv = csv.DictWriter(self.file, CSV_FIELDS)
        self.csv.writeheader()

    def now(self):
        return time.monotonic() - self.t0

    def write(self, event, **kw):
        t = kw.pop("t", None)
        t = self.now() if t is None else t
        row = {"time": datetime.now().isoformat(timespec="milliseconds"), "t": f"{t:.3f}", "event": event}
        row.update(kw)
        self.csv.writerow(row)

    def say(self, msg):
        """打印一整行消息，不和状态行打架"""
        if self.tty and self.status_w:
            sys.stdout.write("\r" + " " * self.status_w + "\r")
            self.status_w = 0
        print(msg, flush=True)

    def on_adv(self, device, adv):
        a = Adv(self.now(), device, adv)
        if not a.valid:
            return
        if self.tracker.target is None:
            if a.apple is not None:
                self.cands.setdefault(a.addr, DevStat(a.addr)).add(a)
            return
        is_target, switch = self.tracker.feed(a)
        if switch:
            self.say(f"[{fmt_t(a.t)}] {switch}")
            self.write("addr_switch", t=a.t, addr=a.addr, note=switch)
        if not is_target:
            # 周围其他发「附近信息」的设备也记下来，事后能查跟踪有没有跟丢、跟错
            if a.apple and NEARBY_INFO in a.apple:
                self.write("other", t=a.t, addr=a.addr, rssi=a.rssi, name=a.name)
            return
        if is_dup(self.last_sample, a.addr, a.t):
            return
        self.last_sample = (a.addr, a.t)
        self.filter.add(a.t, a.rssi)
        self.recent.append(a.t)
        self.last_rssi = a.rssi
        self.n_samples += 1
        self.write("sample", t=a.t, addr=a.addr, rssi=a.rssi, label=self.label,
                   **{"class": self.cls}, apple=apple_desc(a.apple), name=a.name)

    def phone_candidates(self):
        # iPhone 会一直发「附近信息」，AirPods 之类的设备不发
        return [d for d in self.cands.values() if len(d.rssis) >= 2 and NEARBY_INFO in d.types]

    def pick_strongest(self):
        devs = self.phone_candidates()
        if not devs:
            devs = [d for d in self.cands.values() if len(d.rssis) >= 2]
            if devs:
                self.say("注意：没扫到带「附近信息」的 Apple 设备，下面选中的很可能不是 iPhone（比如 AirPods）。"
                         "建议先用 scan 确认，再用 --target 指定。")
        devs.sort(key=lambda d: max(d.rssis), reverse=True)
        if not devs:
            self.say("没有找到 Apple 设备。先用 scan 看看能不能扫到你的 iPhone。")
            return False
        self.say("扫到的 Apple 设备（信号从强到弱）：")
        for d in devs[:3]:
            self.say(f"   {d.addr}  {d.name or '(无名字)'}  最强 {max(d.rssis)}  中位 {fmt_db(median(d.rssis))}"
                     f"  {apple_desc(d.types)}  {d.addr_type}")
        best = devs[0]
        if max(best.rssis) < -65:
            self.say(f"注意：最强的也只有 {max(best.rssis)} dBm，可能不是你的 iPhone，建议把手机贴近电脑重来。")
        if len(devs) > 1 and max(best.rssis) - max(devs[1].rssis) < 8:
            self.say("注意：前两名信号很接近，如果选错了，请用 --target 指定。")
        self.tracker.target = best.addr
        self.tracker.last_seen = best.last
        self.tracker.types = set(best.types)
        self.tracker.name = best.name
        self.tracker.first_seen.update({d.addr: d.first for d in self.cands.values()})
        self.say(f"→ 跟踪 {best.addr}")
        return True

    def set_label(self, label, cls):
        self.label, self.cls = label, cls
        self.write("label", label=label, **{"class": cls})
        self.say(f"[{fmt_t(self.now())}] 标签 → {label}（{CLASS_CN[cls]}）")

    def tick(self):
        t = self.now()
        filtered, _ = self.filter.value(t)
        change = self.fsm.update(t, filtered, self.tracker.last_seen)
        if change:
            self.say(f"[{fmt_t(t)}] 模拟状态 → {STATE_CN[change[0]]}（{change[1]}）")

    def status(self):
        t = self.now()
        while self.recent and self.recent[0] < t - 5:
            self.recent.popleft()
        filtered, _ = self.filter.value(t)
        since = "-" if self.tracker.last_seen is None else f"{t - self.tracker.last_seen:.1f}s"
        line = (f"[{fmt_t(t)}] {self.label}({CLASS_CN[self.cls]}) | 原始 {fmt_db(self.last_rssi)}"
                f" 滤波 {fmt_db(filtered)} | {len(self.recent) / 5:.1f}包/秒 距上次 {since}"
                f" | 模拟 {STATE_CN[self.fsm.state]}")
        if self.tty:
            cols = shutil.get_terminal_size((100, 20)).columns - 1
            line = truncate(line, cols)
            w = disp_width(line)
            sys.stdout.write("\r" + line + " " * max(0, self.status_w - w))
            sys.stdout.flush()
            self.status_w = w
        elif int(t) % 5 == 0:
            print(line, flush=True)
        self.file.flush()

    def help(self, keys_ok):
        keys = "  ".join(f"{i}={name}({CLASS_CN[cls]})" for i, (name, cls) in enumerate(self.labels, 1))
        self.say(f"按键：{keys}  0=暂停  q=结束")
        if not keys_ok:
            self.say("（当前终端不能读按键，只能用 --label 指定固定标签，Ctrl+C 结束）")
        self.say("用法：在电脑前按下标签键 → 带着手机走到对应位置 → 待 60 秒以上 → 回来按下一个键。")

    async def run(self, keys):
        self.help(keys.ok)
        if self.args.label:
            name, cls = parse_labels(self.args.label)[0]
            self.set_label(name, cls)
        next_tick = next_status = 0.0
        while True:
            t = self.now()
            if self.args.duration and t >= self.args.duration:
                break
            k = keys.get()
            if k in ("q", "Q"):
                break
            if k == "0" or k == " ":
                self.set_label("暂停", "skip")
            elif k and k.isdigit() and 1 <= int(k) <= len(self.labels):
                self.set_label(*self.labels[int(k) - 1])
            if t >= next_tick:
                self.tick()
                next_tick = t + GRID_STEP
            if t >= next_status:
                self.status()
                next_status = t + (0.5 if self.tty else 1.0)
            await asyncio.sleep(0.05)

    def close(self):
        self.write("stop", note=f"samples={self.n_samples}")
        self.file.close()
        self.say("")
        self.say(f"记录结束：{fmt_t(self.now())}，目标样本 {self.n_samples} 条 → {self.path}")
        self.say(f"下一步：python rssi_probe.py analyze \"{self.path}\"")


async def cmd_record(args):
    BleakScanner = import_bleak()
    labels = parse_labels(args.labels)
    rec = Recorder(args, labels)
    rec.write("start", addr=args.target or "", note=(
        f"platform={sys.platform} near_th={args.near_th} far_th={args.far_th} window={args.window}"))
    scanner = BleakScanner(detection_callback=rec.on_adv)
    await scanner.start()
    try:
        if rec.tracker.target is None:
            rec.say(f"自动选择目标：请把 iPhone 解锁亮屏、贴近电脑，{args.acquire:g} 秒…")
            await asyncio.sleep(args.acquire)
            # iPhone 锁屏时发得很慢，没扫到就再等一会儿，最多等到 3 倍时间
            extra = args.acquire * 2
            if not rec.phone_candidates():
                rec.say("还没扫到 iPhone，再等一会儿…（请确认 iPhone 已解锁亮屏）")
                while extra > 0 and not rec.phone_candidates():
                    await asyncio.sleep(1)
                    extra -= 1
            if not rec.pick_strongest():
                return
            rec.write("target", addr=rec.tracker.target)
            rec.say("现在可以让 iPhone 恢复平时的状态（锁屏放兜里或桌上），测的就是平时的信号。")
        with KeyReader() as keys:
            await rec.run(keys)
    finally:
        await scanner.stop()
        rec.close()


# ---------------------------------------------------------------- analyze

def load_log(path):
    samples, labels, switches = [], [], []
    end_t = 0.0
    last = (None, -1.0)
    with open(path, newline="", encoding="utf-8-sig") as f:
        for row in csv.DictReader(f):
            t = float(row["t"])
            end_t = max(end_t, t)
            ev = row["event"]
            if ev == "sample":
                if is_dup(last, row["addr"], t):
                    continue
                last = (row["addr"], t)
                samples.append((t, int(row["rssi"])))
            elif ev == "label":
                labels.append((t, row["label"], row["class"]))
            elif ev == "addr_switch":
                switches.append((t, row["note"]))
    samples.sort()
    return samples, labels, switches, end_t


def build_segments(labels, end_t, trim):
    segs = []
    for i, (t, name, cls) in enumerate(labels):
        end = labels[i + 1][0] if i + 1 < len(labels) else end_t
        segs.append({"name": name, "cls": cls, "start": t, "end": end,
                     "a": t + trim, "b": end - trim})
    return segs


def build_grid(samples, end_t, window):
    """按固定时间步长算滤波值，和 record 实时用的算法一致"""
    flt = MedianFilter(window)
    grid, i, last = [], 0, None
    t = samples[0][0] if samples else 0.0
    while t <= end_t:
        while i < len(samples) and samples[i][0] <= t:
            flt.add(*samples[i])
            last = samples[i][0]
            i += 1
        value, fresh = flt.value(t)
        grid.append((t, value, fresh, last))
        t += GRID_STEP
    return grid


def in_range(t, seg):
    return seg["a"] <= t < seg["b"]


def segment_stats(seg, samples, grid):
    dur = seg["b"] - seg["a"]
    raw = [r for t, r in samples if in_range(t, seg)]
    times = [seg["a"]] + [t for t, _ in samples if in_range(t, seg)] + [seg["b"]]
    pts = [g for g in grid if in_range(g[0], seg)]
    fresh = [v for _, v, f, _ in pts if f]
    return {
        "dur": dur, "raw": raw, "fresh": fresh,
        "rate": len(raw) / dur if dur > 0 else 0,
        "max_gap": max(b - a for a, b in zip(times, times[1:])) if dur > 0 else 0,
        "no_signal": 1 - len(fresh) / len(pts) if pts else 0,
    }


def suggest_thresholds(near_vals, far_vals):
    near_low = percentile(near_vals, 5)
    far_high = percentile(far_vals, 95)
    if near_low > far_high:
        gap = near_low - far_high
        mid = (near_low + far_high) / 2
        near_th = round(mid + gap / 4)
        far_th = round(mid - gap / 4)
        if near_th <= far_th:
            near_th = far_th + 1
        verdict = f"能分开：「近」的低位(P5) {near_low:.0f} 比「远」的高位(P95) {far_high:.0f} 还高 {gap:.0f} dB。"
        if gap < 3:
            verdict = (f"勉强能分开：「近」的低位(P5) {near_low:.1f} 和「远」的高位(P95) {far_high:.1f}"
                       f" 只差 {gap:.1f} dB，环境稍有变化就会误判。")
    else:
        near_th = math.ceil(far_high) + 1
        far_th = math.floor(near_low) - 1
        verdict = (f"有 {far_high - near_low:.0f} dB 重叠：「近」的低位(P5) {near_low:.0f}，"
                   f"「远」的高位(P95) {far_high:.0f}。单靠信号强度会误判，要靠持续时间、信号消失和手机确认来兜底。")
    return near_th, far_th, near_low, far_high, verdict


def simulate(grid, near_th, far_th, t_near, t_far, t_lost):
    fsm = PresenceFSM(near_th, far_th, t_near, t_far, t_lost, start_t=grid[0][0] if grid else 0)
    states, changes = [], []
    for t, value, _, last in grid:
        change = fsm.update(t, value, last)
        if change:
            changes.append((t, *change))
        states.append((t, fsm.state))
    return states, changes


def label_at(t, segs):
    for s in segs:
        if s["start"] <= t < s["end"]:
            return s["name"]
    return "-"


def cmd_analyze(args):
    samples, labels, switches, end_t = load_log(args.file)
    if not samples:
        raise SystemExit("文件里没有样本。")
    segs = [s for s in build_segments(labels, end_t, args.trim) if s["cls"] != "skip"]
    grid = build_grid(samples, end_t, args.window)

    print(f"== 概况 ==")
    print(f"文件 {args.file}：时长 {fmt_t(end_t)}，样本 {len(samples)} 条，"
          f"平均 {len(samples) / max(end_t, 1):.1f} 包/秒，换地址 {len(switches)} 次")
    for t, note in switches:
        print(f"   {fmt_t(t)} {note}")
    print(f"（每段去掉开头和结尾各 {args.trim:g} 秒的走动时间；滤波 = 最近 {args.window:g} 秒的中位数）")
    print()

    stats = {}
    rows = []
    for s in segs:
        st = stats[id(s)] = segment_stats(s, samples, grid)
        if st["dur"] <= 0:
            rows.append([s["name"], CLASS_CN[s["cls"]], fmt_t(s["start"]), "太短"] + [""] * 6)
            continue
        raw, fresh = st["raw"], st["fresh"]
        rows.append([
            s["name"], CLASS_CN[s["cls"]], fmt_t(s["start"]), f"{st['dur']:.0f}s",
            f"{st['rate']:.1f}", f"{st['max_gap']:.1f}s", f"{st['no_signal'] * 100:.0f}%",
            f"{fmt_db(median(raw))} ({fmt_db(percentile(raw, 10))}~{fmt_db(percentile(raw, 90))})",
            f"{stdev(raw):.1f}" if raw else "-",
            f"{fmt_db(percentile(fresh, 5))}~{fmt_db(percentile(fresh, 95))}",
        ])
    print("== 各位置信号 ==")
    print_table(["标签", "类别", "开始", "有效时长", "包/秒", "最长间隔", "无信号",
                 "原始 中位(P10~P90)", "抖动", "滤波后 P5~P95"], rows)
    print("（抖动 = 原始值标准差；无信号 = 滤波窗口内一个包都没收到的时间占比）")
    print()

    near_segs = [s for s in segs if s["cls"] == "near" and stats[id(s)]["dur"] > 0]
    far_segs = [s for s in segs if s["cls"] == "far" and stats[id(s)]["dur"] > 0]
    near_vals = [v for s in near_segs for v in stats[id(s)]["fresh"]]
    far_vals = [v for s in far_segs for v in stats[id(s)]["fresh"]]

    print("== 远近能不能分开 ==")
    near_th, far_th = args.near_th, args.far_th
    if near_vals and far_vals:
        sug_near, sug_far, _, _, verdict = suggest_thresholds(near_vals, far_vals)
        print(verdict)
        print(f"建议阈值：滤波后 ≥ {sug_near} 判为靠近，≤ {sug_far} 判为离开")
        near_th = sug_near if near_th is None else near_th
        far_th = sug_far if far_th is None else far_th
    else:
        missing = "「近」" if not near_vals else "「远」"
        print(f"缺少{missing}类的有效数据，没法给建议阈值。至少各测一个近和远的位置，每个位置待 60 秒以上。")
    if near_th is None or far_th is None:
        near_th = -65 if near_th is None else near_th
        far_th = -78 if far_th is None else far_th
        print(f"下面用默认阈值模拟：≥ {near_th} 靠近，≤ {far_th} 离开")

    t_lost = args.t_lost
    if near_segs:
        near_gap = max(stats[id(s)]["max_gap"] for s in near_segs)
        sug_lost = max(10, math.ceil(near_gap * 2))
        print(f"人在电脑前时最长 {near_gap:.1f}s 没收到包 → 建议「信号消失」判定时间 ≥ {sug_lost}s")
        if t_lost is None:
            t_lost = sug_lost
    t_lost = 15 if t_lost is None else t_lost
    print()

    print(f"== 模拟（≥{near_th} 持续 {args.t_near:g}s → 靠近；≤{far_th} 持续 {args.t_far:g}s"
          f" 或 {t_lost:g}s 无信号 → 离开）==")
    states, changes = simulate(grid, near_th, far_th, args.t_near, args.t_far, t_lost)
    rows, false_lock, false_near = [], 0, 0
    for s in segs:
        if stats[id(s)]["dur"] <= 0:
            continue
        pts = [st for t, st in states if in_range(t, s)]
        n = len(pts) or 1
        ch = [c for c in changes if in_range(c[0], s)]
        bad = 0
        if s["cls"] == "near":
            bad = sum(1 for c in ch if c[1] == FAR)
            false_lock += bad
        elif s["cls"] == "far":
            bad = sum(1 for c in ch if c[1] == NEAR)
            false_near += bad
        rows.append([s["name"], CLASS_CN[s["cls"]],
                     f"{pts.count(NEAR) / n * 100:.0f}%", f"{pts.count(FAR) / n * 100:.0f}%",
                     f"{pts.count(UNKNOWN) / n * 100:.0f}%", len(ch), bad if s["cls"] in ("near", "far") else "-"])
    print_table(["标签", "类别", "判为靠近", "判为离开", "未定", "状态切换", "误判"], rows)
    print(f"误锁（人在电脑前却判为离开）：{false_lock} 次")
    print(f"误判靠近（人已离开却判为靠近）：{false_near} 次")

    # 按下「远」标签时还是靠近状态 → 从按键到判为离开用了多久
    latencies = []
    for s in segs:
        if s["cls"] != "far":
            continue
        before = [st for t, st in states if t < s["start"]]
        if not before or before[-1] != NEAR:
            continue
        hit = next((c for c in changes if c[0] >= s["start"] and c[1] == FAR), None)
        if hit and hit[0] < s["end"]:
            latencies.append(hit[0] - s["start"])
    if latencies:
        print(f"离开后多久锁屏（从按键算起，含走路时间）：平均 {sum(latencies) / len(latencies):.0f}s，"
              f"最长 {max(latencies):.0f}s")
    print()

    print("== 状态变化时间线 ==")
    for t, state, reason in changes[: args.max_events]:
        print(f"   {fmt_t(t)}  → {STATE_CN[state]}（{reason}）  标签：{label_at(t, segs)}")
    if len(changes) > args.max_events:
        print(f"   …共 {len(changes)} 次，只显示前 {args.max_events} 次（--max-events 调整）")
    if not changes:
        print("   （没有状态变化）")


# ---------------------------------------------------------------- 入口

def main():
    p = argparse.ArgumentParser(description="iPhone 蓝牙信号实测工具")
    sub = p.add_subparsers(dest="cmd", required=True)

    sp = sub.add_parser("scan", help="扫描附近的蓝牙设备")
    sp.add_argument("--seconds", type=float, default=10, help="扫描时长，默认 10 秒")
    sp.add_argument("--all", action="store_true", help="显示所有设备（默认只显示 Apple 设备）")
    sp.add_argument("--top", type=int, default=15, help="最多显示多少台，默认 15")

    def fsm_args(sp, defaults):
        sp.add_argument("--near-th", type=int, default=defaults, help="靠近阈值 dBm")
        sp.add_argument("--far-th", type=int, default=defaults, help="离开阈值 dBm")
        sp.add_argument("--window", type=float, default=3, help="中位数滤波窗口秒数，默认 3")
        sp.add_argument("--t-near", type=float, default=2, help="高于靠近阈值持续多久判为靠近，默认 2 秒")
        sp.add_argument("--t-far", type=float, default=10, help="低于离开阈值持续多久判为离开，默认 10 秒")

    rp = sub.add_parser("record", help="记录目标设备的信号")
    rp.add_argument("--target", help="目标地址/ID（scan 里看到的），不填就自动选信号最强的 Apple 设备")
    rp.add_argument("--labels", default=DEFAULT_LABELS,
                    help=f"位置标签，格式 名称:类别，类别是 near/far/mid/mix。默认 {DEFAULT_LABELS}")
    rp.add_argument("--label", help="一开始就使用的标签，例如 桌上:near（终端读不了按键时用）")
    rp.add_argument("--out", help="输出 CSV 路径，默认 rssi_日期_时间_平台.csv")
    rp.add_argument("--duration", type=float, default=0, help="记录多少秒后自动结束，默认不限")
    rp.add_argument("--acquire", type=float, default=6, help="自动选目标时的扫描秒数，默认 6")
    rp.add_argument("--no-follow", action="store_true", help="不自动跟踪换了地址的目标")
    fsm_args(rp, None)
    rp.add_argument("--t-lost", type=float, default=15, help="多久收不到包判为离开，默认 15 秒")

    ap = sub.add_parser("analyze", help="分析记录文件")
    ap.add_argument("file", help="record 生成的 CSV")
    ap.add_argument("--trim", type=float, default=10, help="每段开头结尾各去掉多少秒，默认 10")
    ap.add_argument("--max-events", type=int, default=40, help="时间线最多显示多少条，默认 40")
    fsm_args(ap, None)
    ap.add_argument("--t-lost", type=float, default=None, help="多久收不到包判为离开，默认按数据推算")

    args = p.parse_args()
    if args.cmd == "record":
        args.near_th = -65 if args.near_th is None else args.near_th
        args.far_th = -78 if args.far_th is None else args.far_th
    try:
        if args.cmd == "scan":
            asyncio.run(cmd_scan(args))
        elif args.cmd == "record":
            asyncio.run(cmd_record(args))
        else:
            cmd_analyze(args)
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
