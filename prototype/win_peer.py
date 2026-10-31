#!/usr/bin/env python3
"""
原型 v0 电脑端（Windows）：当蓝牙外设，等 iPhone 来连接

- 广播协议里的服务，iPhone 连上后订阅 HEARTBEAT
- 每秒发一次心跳；iPhone 每收到一次就测一次信号强度，写回 REPORT
- 所有事件记到 CSV，用来分析连接稳不稳、信号采样率多少

Windows 的蓝牙接口会卡死：实测连上 22 到 24 分钟后，发心跳的 WinRT 调用卡在跨进程调用
系统蓝牙服务那一步，再也不返回，iPhone 断开也不返回。而且卡住时一直占着 Python 的全局锁（GIL），
同一个进程里的其他线程也跟着停住，所以看门狗必须放在另一个进程里：
- 守护进程：启动工作进程，通过共享内存看它的"心跳时间戳"，超过 --stuck 秒没更新就强制结束、重启它，
  日志接着写同一个文件
- 工作进程：蓝牙线程做所有 WinRT 调用，每 0.5 秒更新一次时间戳；主线程显示状态

协议见 docs/protocol.md。只依赖 bleak 装进来的 winrt 包（pip install bleak）。
"""

import argparse
import asyncio
import bisect
import base64
import csv
import ctypes
import gc
import json
import math
import os
import re
import socket
import statistics
import struct
import subprocess
import sys
import threading
import time
import uuid
from datetime import datetime
from multiprocessing import shared_memory

from win_unlock_protocol import (
    ENROLL_ACK_UUID, ENROLL_REQUEST_UUID, ENROLL_REQUEST_V1, LOCK_UUID, MANUAL_PROMPT_ID, MANUAL_VERSION,
    AuthenticatedReportGate, AuthenticatedReportProtocol, EnrollAckProtocol, LockGate, LockProtocol,
    ReportAuthenticationError, UnlockError, UnlockGate, UnlockKey, UnlockStatus,
)
from windows_unlock.backend import load_backend

if sys.platform != "win32":
    raise SystemExit("这是 Windows 版电脑端，Mac 版见 docs/protocol.md")

from winrt.windows.devices.bluetooth import BluetoothError, BluetoothLEDevice
from winrt.windows.devices.bluetooth.genericattributeprofile import (
    GattCharacteristicProperties as Props,
    GattCommunicationStatus,
    GattLocalCharacteristicParameters,
    GattProtectionLevel,
    GattServiceProvider,
    GattServiceProviderAdvertisementStatus as AdvStatus,
    GattServiceProviderAdvertisingParameters,
    GattWriteOption,
)
from winrt.windows.devices.bluetooth.advertisement import (
    BluetoothLEAdvertisementPublisher,
    BluetoothLEAdvertisementPublisherStatus as BeaconStatus,
    BluetoothLEManufacturerData,
)
from winrt.windows.devices.radios import Radio, RadioKind
from winrt.windows.storage.streams import Buffer

SERVICE_UUID = "74cb8b6c-6eb7-4eed-bbcd-0a37f0ac77d7"
HEARTBEAT_UUID = "2399f9b5-b3ca-43ee-966d-d669401a5ed4"
REPORT_UUID = "ba3e7281-d451-4a7f-a305-150c789f1460"
INFO_UUID = "a82beb9a-cba0-4974-8df3-2c8cf3052899"
PROTO_VERSION = 1
CHALLENGE_UUID = "0c28c82e-69ec-4cd1-ab3b-ea7e160fcd3c"
UNLOCK_UUID = "54cd9a6f-36e3-4c39-b875-bbeee5f1aef1"
UNLOCK_CAPABILITY = "win-hmac-v3"

# iBeacon（docs/protocol.md「用 iBeacon 拉起 App」）：App 被划掉、手机重启后，iOS 的区域监测能把 App 拉起来。
# App 只按 UUID 监测；major 1 = Windows、2 = Mac；1 米处信号 -59
BEACON_UUID = uuid.UUID("9E698AEC-9C56-46E3-9209-F2628704D932")
BEACON_MAJOR = 1
APPLE_COMPANY_ID = 0x004C


def beacon_payload(major, minor, power=-59):
    """Apple 厂商数据里的 iBeacon：02 15 + UUID + major、minor（大端）+ 1 米处的信号"""
    return bytes([0x02, 0x15]) + BEACON_UUID.bytes + struct.pack(">HHb", major, minor, power)

# seq, 电脑状态（1 未锁屏 2 已锁屏 3 请提示解锁）, 提示编号, 下一次心跳最晚几秒后到（v1.2，App 的看门狗按它放宽）
HEARTBEAT_FMT = "<IBHB"
REPORT_FMT = "<IbB"    # seq, rssi, 手机判断的状态
PHONE_STATE = {0: "未定", 1: "靠近", 2: "离开"}
CSV_FIELDS = ["time", "t", "event", "seq", "rssi", "phone_state", "latency_ms", "device", "note"]
# 守护进程和工作进程共享的一小块内存：
#   [0:8]   double  工作进程最后一次确认自己没卡住的时间
#   [8:16]  int64   工作进程（真正的解释器）的 PID，venv 下守护进程直接拿到的是启动器的 PID
#   [16:48] 字符串  正在调用哪个可能卡住的系统接口，卡死时守护进程记到日志里
#   [48:56] double  协议广播从什么时候起不在 STARTED（0 表示正常），守护进程据此决定要不要关开蓝牙修
#   [56]    byte    守护进程请工作进程正常退出（1）：停广播、撤服务再退。强制结束的话实测下次启动广播一直 ABORTED
OP_END = 48
STOP_AT = 56
HEALTH_SIZE = 64
# 外面（install_autostart.ps1 -Stop）请电脑端正常退出用的命名事件，守护进程收到后转告工作进程
STOP_EVENT = "Local\\iphone-proximity-unlock-win-peer-stop"
# 本机登记窗口（windows_unlock/native/helper.cpp）开着时建的命名事件：iPhone 确认已保存登记，窗口显示一下就自己关
ENROLL_WINDOW_EVENT = "Local\\iphone-proximity-unlock-enroll-ack"
EXIT_RADIO = 4  # 蓝牙关着或不可用：守护进程等 10 秒再启动，一直等到蓝牙回来


def to_buffer(data):
    buf = Buffer(len(data))
    buf.length = len(data)
    with memoryview(buf) as mv:
        mv[:] = data
    return buf


def fmt_t(t):
    t = max(0, int(t))
    return f"{t // 60:02d}:{t % 60:02d}"


def fmt_addr(addr):
    return ":".join(f"{(addr >> s) & 0xFF:02X}" for s in range(40, -1, -8))


class LASTINPUTINFO(ctypes.Structure):
    _fields_ = [("cbSize", ctypes.c_uint), ("dwTime", ctypes.c_uint)]


_user32 = ctypes.WinDLL("user32")
_kernel32 = ctypes.WinDLL("kernel32")


def input_idle_seconds():
    """距离上次键盘鼠标操作过了多少秒"""
    lii = LASTINPUTINFO()
    lii.cbSize = ctypes.sizeof(lii)
    if not _user32.GetLastInputInfo(ctypes.byref(lii)):
        return None
    return ((_kernel32.GetTickCount() - lii.dwTime) & 0xFFFFFFFF) / 1000.0


class WTSINFOEX_LEVEL1_W(ctypes.Structure):
    _fields_ = [("SessionId", ctypes.c_ulong), ("SessionState", ctypes.c_int), ("SessionFlags", ctypes.c_long),
                ("WinStationName", ctypes.c_wchar * 33), ("UserName", ctypes.c_wchar * 21),
                ("DomainName", ctypes.c_wchar * 18),
                ("LogonTime", ctypes.c_longlong), ("ConnectTime", ctypes.c_longlong),
                ("DisconnectTime", ctypes.c_longlong), ("LastInputTime", ctypes.c_longlong),
                ("CurrentTime", ctypes.c_longlong),
                ("IncomingBytes", ctypes.c_ulong), ("OutgoingBytes", ctypes.c_ulong),
                ("IncomingFrames", ctypes.c_ulong), ("OutgoingFrames", ctypes.c_ulong),
                ("IncomingCompressedBytes", ctypes.c_ulong), ("OutgoingCompressedBytes", ctypes.c_ulong)]


class WTSINFOEXW(ctypes.Structure):
    _fields_ = [("Level", ctypes.c_ulong), ("Data", WTSINFOEX_LEVEL1_W)]


_wtsapi32 = ctypes.WinDLL("wtsapi32")
_wtsapi32.WTSQuerySessionInformationW.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_int,
                                                  ctypes.POINTER(ctypes.c_void_p), ctypes.POINTER(ctypes.c_ulong)]
_wtsapi32.WTSFreeMemory.argtypes = [ctypes.c_void_p]


def workstation_locked():
    """
    问系统当前会话是不是锁着（WTSSessionInfoEx 的 SessionFlags：0 锁着，1 没锁）。
    原来用"打不开输入桌面就算锁屏"，实测 Windows 10 锁屏时照样打得开，检测不到。
    """
    buf, n = ctypes.c_void_p(), ctypes.c_ulong()
    # WTS_CURRENT_SERVER_HANDLE = NULL，WTS_CURRENT_SESSION = -1，WTSSessionInfoEx = 25
    if not _wtsapi32.WTSQuerySessionInformationW(None, 0xFFFFFFFF, 25, ctypes.byref(buf), ctypes.byref(n)):
        return False
    try:
        info = ctypes.cast(buf, ctypes.POINTER(WTSINFOEXW)).contents
        return info.Level == 1 and info.Data.SessionFlags == 0
    finally:
        _wtsapi32.WTSFreeMemory(buf)


class HeartbeatSchedule:
    """
    什么时候发下一次心跳。每次心跳都宣布"下一次最晚几秒后到"，所以：
    - 变快（比如休眠时手机信号变强）：马上按新的间隔算，到点就发
    - 变慢：已经宣布过的不能失信，按上一次宣布的间隔发下一次，这一次再宣布新的间隔
    """

    def __init__(self, interval):
        self.announced = interval
        self.last_sent = None

    def due(self, now, interval):
        if self.last_sent is None:
            return True
        return now - self.last_sent >= min(interval, self.announced)

    def sent(self, now, interval):
        self.last_sent, self.announced = now, interval


def lock_workstation():
    return bool(_user32.LockWorkStation())


def _powershell(command):
    r = subprocess.run(["powershell", "-NoProfile", "-NonInteractive", "-Command", command],
                       capture_output=True, text=True, timeout=15,
                       creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
    return r.stdout.strip() if r.returncode == 0 else None


def get_brightness():
    """笔记本屏幕的亮度 0 到 100，读不到返回 None"""
    out = _powershell("(Get-CimInstance -Namespace root/WMI -ClassName WmiMonitorBrightness).CurrentBrightness")
    try:
        return int(out.split()[0])
    except (AttributeError, ValueError, IndexError):
        return None


def set_brightness(level):
    out = _powershell("Get-CimInstance -Namespace root/WMI -ClassName WmiMonitorBrightnessMethods | "
                      f"Invoke-CimMethod -MethodName WmiSetBrightness -Arguments @{{Timeout=[uint32]0; Brightness=[byte]{int(level)}}}"
                      " | Out-Null; 'ok'")
    return out == "ok"


class REASON_CONTEXT(ctypes.Structure):
    class _Reason(ctypes.Union):
        _fields_ = [("SimpleReasonString", ctypes.c_wchar_p), ("Detailed", ctypes.c_byte * 24)]
    _fields_ = [("Version", ctypes.c_ulong), ("Flags", ctypes.c_ulong), ("Reason", _Reason)]


_kernel32.PowerCreateRequest.restype = ctypes.c_void_p
_kernel32.PowerCreateRequest.argtypes = [ctypes.POINTER(REASON_CONTEXT)]
_kernel32.PowerSetRequest.argtypes = [ctypes.c_void_p, ctypes.c_int]
_kernel32.PowerClearRequest.argtypes = [ctypes.c_void_p, ctypes.c_int]


class KeepAwake:
    """
    锁屏期间让电脑端在现代待机里接着跑。支持现代待机的笔记本锁屏、关屏后很快就进待机（系统日志
    Kernel-Power 506），没有电源请求时用电池进待机约 15 秒电脑端就被暂停，手机回来没人应答。
    电源请求（SystemRequired + ExecutionRequired）挡不住进待机，但电脑端和蓝牙照常运行，
    自动解锁还会把电脑从待机里唤醒（拔着电源实测过，见 docs/protocol.md）。
    """
    SYSTEM_REQUIRED, EXECUTION_REQUIRED = 1, 3

    def __init__(self):
        # 结构体要一直留着，里面的字符串指针系统会用到
        self.reason = REASON_CONTEXT(0, 0x1)  # POWER_REQUEST_CONTEXT_VERSION, POWER_REQUEST_CONTEXT_SIMPLE_STRING
        self.reason.Reason.SimpleReasonString = "iPhone 靠近解锁：锁屏期间保持蓝牙运行，手机回来时要能提示解锁"
        h = _kernel32.PowerCreateRequest(ctypes.byref(self.reason))
        self.handle = h if h and h != ctypes.c_void_p(-1).value else None
        self.on = False

    def set(self, on):
        """返回是否成功；状态没变直接返回 True"""
        if on == self.on:
            return True
        if self.handle is None:
            return False
        fn = _kernel32.PowerSetRequest if on else _kernel32.PowerClearRequest
        ok = all([fn(self.handle, self.SYSTEM_REQUIRED), fn(self.handle, self.EXECUTION_REQUIRED)])
        self.on = on
        return ok


_DEVICE_NOTIFY_CALLBACK_ROUTINE = ctypes.WINFUNCTYPE(ctypes.c_ulong, ctypes.c_void_p, ctypes.c_ulong, ctypes.c_void_p)


class _DEVICE_NOTIFY_SUBSCRIBE_PARAMETERS(ctypes.Structure):
    _fields_ = [("Callback", _DEVICE_NOTIFY_CALLBACK_ROUTINE), ("Context", ctypes.c_void_p)]


class DisplayState:
    """
    显示器亮没亮（GUID_CONSOLE_DISPLAY_STATE）。系统在注册时报一次当前状态，之后每次变化回调一次（在系统的线程里）。
    on：True 亮（包括变暗），False 关，None 还不知道（订阅失败）。
    用来分开"人按电源键、开盖、动鼠标叫醒的"和每小时一次的维护唤醒（显示器不亮，盖子可能合着）
    """
    GUID_CONSOLE_DISPLAY_STATE = uuid.UUID("6fe69556-704a-47a0-8f24-c28d936fda47").bytes_le
    DEVICE_NOTIFY_CALLBACK, PBT_POWERSETTINGCHANGE = 2, 0x8013

    def __init__(self):
        self.on = None
        # 回调、参数结构体、GUID 都要一直留着，系统会一直用
        self._callback = _DEVICE_NOTIFY_CALLBACK_ROUTINE(self._changed)
        self._params = _DEVICE_NOTIFY_SUBSCRIBE_PARAMETERS(self._callback, None)
        self._guid = ctypes.create_string_buffer(self.GUID_CONSOLE_DISPLAY_STATE, 16)
        self._handle = ctypes.c_void_p()
        try:
            register = ctypes.windll.powrprof.PowerSettingRegisterNotification
            register.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_void_p, ctypes.POINTER(ctypes.c_void_p)]
            register.restype = ctypes.c_ulong
            self.registered = register(self._guid, self.DEVICE_NOTIFY_CALLBACK,
                                       ctypes.byref(self._params), ctypes.byref(self._handle)) == 0
        except (OSError, AttributeError):
            self.registered = False

    def _changed(self, context, kind, setting):
        if kind == self.PBT_POWERSETTINGCHANGE and setting:
            # POWERBROADCAST_SETTING：GUID（16 字节）、DataLength（4 字节）、Data（DWORD：0 关、1 亮、2 变暗）
            self.on = ctypes.c_ulong.from_address(setting + 20).value != 0
        return 0


def turn_off_display():
    """关显示器（SC_MONITORPOWER = 2）。只关屏、不睡眠，蓝牙照常工作；动一下鼠标键盘就亮。
    用 PostMessage 不用 SendMessage：广播给所有窗口，有窗口卡住时 SendMessage 会跟着卡住"""
    HWND_BROADCAST, WM_SYSCOMMAND, SC_MONITORPOWER = 0xFFFF, 0x0112, 0xF170
    return bool(_user32.PostMessageW(HWND_BROADCAST, WM_SYSCOMMAND, SC_MONITORPOWER, 2))


class Judge:
    """
    电脑端判断人在不在，据此锁屏、请手机提示解锁。规则见 docs/protocol.md「电脑怎么判断人在不在」：
    - 在电脑前：--active 秒内有键盘鼠标操作，不管信号多少
    - 离开：--idle-lock 秒没有操作，并且手机失联 --lost-for 秒、或信号中位数低于 --far-th 持续 --far-for 秒
      → 锁屏（lock）；--no-lock 时只记 would_lock。这台电脑从没收到过手机报告时（phone_known 也没设），失联不算离开
    - 手机走后只锁一次：锁过以后手机还没回来就被解开了（多半是远程解的），手机回来以前不再自动锁（hold_lock）
    - 锁屏期间手机走远过（armed），之后信号回到 --approach-th 以上、并且比走远时的信号（reference）
      强 --approach-gain → 请手机提示解锁（prompt，心跳里电脑状态 3）。
      用户自己锁屏、人还坐着时手机一直在附近，不会 armed，所以不提示
    - 电脑端被冻住（合盖、关屏进的待机）超过 --freeze-away 秒、醒来时锁着、显示器亮了：冻住期间看不到手机走没走，
      当作手机走远过（armed），手机在旁边就请提示（freeze_away）
    - 解锁（--no-lock 时是又有了键盘鼠标操作）→ 记 back，写提示后多久解锁
    """

    def __init__(self, peer):
        self.peer = peer
        self.args = peer.args
        self.started = time.time()
        self.state = None
        self.weak_since = None
        self.lost_since = None
        self.away_at = None        # 判定离开（锁屏）的时间
        self.prompt_at = None      # 请手机提示解锁的时间
        self.prompting = False     # 心跳里正在发电脑状态 3
        self.armed = False         # 锁屏期间手机走远过，回来时要提示
        self.near_since = None     # 信号从什么时候起一直在 --approach-th 以上、并且比走远时强 --approach-gain
        self.ref_start = None      # 手机从什么时候起走远的：「走远时的信号」只看这以后的报告，不算人还坐在电脑前时的
        self.last_ref = None       # 最近一次判断时「走远时的信号」，None 是最近一段没有报告（手机刚连回来）
        self.last_idle = None      # 最近一次判断时的空闲秒数，休眠用
        self.last_med = None       # 最近一次判断时的信号中位数，心跳快慢用
        self.current_interval = self.args.interval  # 最近一次心跳宣布的间隔，失联阈值和中位数窗口跟着放宽
        self.last_rssi = None      # 最新一条报告的信号（还没过期的）
        self.seen_locked = False   # 判定离开后确实看到 Windows 锁上了（LockWorkStation 是异步生效的）
        self.prompt_id = int(time.time()) % 60000 + 1  # 重启后不和之前的编号撞上
        self.locked = None         # Windows 真实的锁屏状态
        self.display_off_at = None  # 自己锁屏后，到这个时间调暗或关屏
        self.saved_brightness = None  # 调暗前的亮度，回来时恢复
        self.awake = KeepAwake()    # 锁屏期间让电脑端在待机里接着跑，最多 --awake-minutes 分钟
        self.awake_until = None
        self.awake_spent = False    # 这次锁屏已经开过电源请求（到时放开后不再开，解锁后重置）
        self.dim_after_cancel = False  # 请提示时恢复了亮度：提示撤销（手机又走远）时再调暗
        self.phone_known = False   # 以前收到过手机报告（7 天内）或登记过解锁，见 restore_history
        self.hold_lock = False     # 手机走后锁过一次、手机还没回来就被解开了（多半是远程解的）：手机回来以前不再自动锁
        self.last_update = None    # 上次判断的时间：隔了很久说明电脑端被待机冻住了
        self.frozen_since = None   # 冻住后醒来时锁着、等显示器亮了再当作手机走远过：冻住是从什么时候开始的
        self.display = DisplayState()
        if not self.display.registered:
            peer.log("freeze_watch", note="订阅显示器状态失败：冻住后醒来锁着就当作离开过，不等显示器亮")
        if self.args.restart:
            self.restore(peer.path, signals=peer.authenticated_reports is None)
        self.restore_history(peer.path)

    def restore(self, path, signals=True):
        """
        卡死自动重启后接上前一个工作进程的判断：最后一次锁屏之后还没有 back，就还算离开。
        还要读回最近 --ref-window 的报告：不然「走远时的信号」是空的，提示只看 -72，夜里一重启就可能误提示
        """
        events = ("lock", "would_lock", "prompt", "would_prompt", "prompt_cancel", "back", "dim", "undim")
        since = self.peer.now() - self.args.ref_window - 60
        recent = []
        try:
            with open(path, newline="", encoding="utf-8-sig", errors="replace") as f:
                rows = []
                for r in csv.DictReader(f):
                    if r["event"] in events and log_time(r["time"]) is not None:
                        rows.append(r)
                    elif signals and r["event"] == "report":
                        try:
                            t = float(r["t"])
                            if t >= since:
                                lat = float(r["latency_ms"]) if r["latency_ms"] else None
                                recent.append((t, int(r["rssi"]), int(r["phone_state"] or 0), lat))
                        except ValueError:
                            pass
        except OSError:
            return
        if recent and not self.peer.reports:
            self.peer.reports.extend(recent)
        away = prompt = None
        prompting, pid, brightness = False, None, None
        for r in rows:
            ts = log_time(r["time"])
            ev = r["event"]
            if ev in ("lock", "would_lock"):
                away, prompt, prompting = ts, None, False
            elif ev in ("prompt", "would_prompt"):
                prompt, prompting = ts, True
                m = re.search(r"id=(\d+)", r["note"])
                pid = int(m.group(1)) if m else pid
            elif ev == "prompt_cancel":
                prompting = False
            elif ev == "back":
                away = prompt = None
                prompting = False
            elif ev == "dim":
                m = re.search(r"brightness=(\d+)", r["note"])
                brightness = int(m.group(1)) if m and "失败" not in r["note"] else None
            elif ev == "undim":
                brightness = None
        self.saved_brightness = brightness  # 前一个进程调暗了还没恢复的话，回来时由这个进程恢复
        if not signals:
            # 自动解锁只信本次进程收到的签名报告；亮度恢复不构成设备在场证明。
            return
        if away is None and not prompting:
            return
        self.away_at, self.prompt_at, self.prompting = away, prompt, prompting
        self.armed = not prompting
        self.ref_start = away
        if pid is not None:
            self.prompt_id = pid
        note = (f"{time.time() - away:.0f}s 前判定离开" if away else "用户自己锁的屏") + \
               (f"，正在提示解锁 id={pid}" if prompting else "")
        self.peer.log("judge_restore", note=note)

    def restore_history(self, path):
        """
        每次启动（包括卡死重启）读前一个日志和当前日志，和 Mac 端一样（docs/protocol.md「电脑怎么判断人在不在」）：
        - phone_known：7 天内收到过手机报告，或者登记过解锁的手机，这次启动以来还没收到报告时失联也算离开。
          不然电脑端在手机不在时重启以后，按「这次启动以来没收到过报告就不算」就再也不锁了。
          记一行 phone_known（带上次收到报告的时间），连着重启几次、中间都没收到报告也接得上
        - 不再自动锁（hold_lock）：最后一次 lock_hold 之后没有 lock_resume、lock 就接着不锁。
          自动解锁启用时也接：只会让电脑少锁，不会多解锁
        """
        folder, name = os.path.split(os.path.abspath(path))
        try:
            older = sorted(f for f in os.listdir(folder)
                           if f.startswith("peer_") and f.endswith("_win32.csv") and f < name)
        except OSError:
            older = []
        last_report = hold = None
        for file in [os.path.join(folder, f) for f in older[-1:]] + [path]:
            report_time = None
            try:
                # 守护进程和工作进程都往同一个日志里写，偶尔撞在一起，留下半个汉字，
                # 读不出来的字节换掉、时间读不出来的行跳过，不然工作进程每次一启动就崩
                with open(file, newline="", encoding="utf-8-sig", errors="replace") as f:
                    for r in csv.DictReader(f):
                        ev = r["event"]
                        if ev == "report":
                            report_time = log_time(r["time"]) or report_time
                        elif ev == "phone_known":
                            m = re.search(r"last=(\d+)", r["note"] or "")
                            if m:
                                last_report = max(last_report or 0, int(m.group(1)))
                        elif ev == "lock_hold":
                            hold = log_time(r["time"]) or hold
                        elif ev in ("lock_resume", "lock", "would_lock"):
                            hold = None
            except (OSError, csv.Error, KeyError):
                continue
            if report_time:
                last_report = max(last_report or 0, report_time)
        now = time.time()
        self.phone_known = (self.peer.unlock_backend is not None
                            or (last_report is not None and now - last_report <= 7 * 86400))
        if self.phone_known:
            seen = (f"上次收到手机报告是 {datetime.fromtimestamp(last_report):%m-%d %H:%M}" if last_report
                    else "登记过解锁的手机")
            self.peer.say(f"{seen}：手机还没连上时，失联也算离开")
            self.peer.log("phone_known", note=f"{seen}，这次启动以来还没收到报告时失联也算离开"
                                              + (f" last={int(last_report)}" if last_report else ""))
        if hold is not None:
            self.hold_lock = True
            note = f"{now - hold:.0f}s 前手机还没回来就被解开了，接着不自动锁，等手机回来"
            self.peer.say(f"接上前一个进程：{note}")
            self.peer.log("lock_hold", note="接上前一个进程：" + note)

    @staticmethod
    def reference(reports, now_t, start_t, window, lag=30):
        """
        「走远时的信号」：最近 window 秒（不含最近 lag 秒）、start_t 以后的报告里，信号强的那一头（90% 分位）。
        少于 3 条时 None（手机刚连回来，或者刚走开）。reports 是按时间排好的 (t, rssi, ...)，t 是 Peer.now() 的时间。
        手机放在别的房间时，信号可能在 -70 到 -90 之间来回（被身体、被子挡），中位数会在 -82 停几分钟再回到 -72：
        拿中位数当参考，回到 -72 就正好强了 10 dB，照样半夜提示；拿强的那一头（这时最强也就 -71）才分得开
        """
        lo = now_t - lag - window if start_t is None else max(now_t - lag - window, start_t)
        i = bisect.bisect_left(reports, lo, key=lambda r: r[0])
        j = bisect.bisect_right(reports, now_t - lag, key=lambda r: r[0])
        values = sorted(r[1] for r in reports[i:j] if r[1] != 127)
        if len(values) < 3:
            return None
        return values[min(len(values) - 1, len(values) * 9 // 10)]

    def gone_start(self, now):
        """手机从什么时候起算走远的：失联、信号弱里更早开始的那个"""
        starts = [x for x in (self.lost_since, self.weak_since) if x is not None]
        return min(starts) if starts else now

    def report_timeout(self):
        """多久没报告算失联：平时 --pause-after（3 秒）；心跳慢下来时报告本来就隔得久，跟着放宽"""
        return self.args.pause_after + max(0.0, self.current_interval - 1)

    def rssi_median(self):
        """最近 5 次报告的信号中位数（只算最近 10 秒的，和 App 的判断参数一样取 5 次；心跳慢下来时窗口跟着放宽）"""
        window = max(10.0, self.current_interval * 2 + 2)
        recent = [r[1] for r in self.peer.reports[-5:] if r[1] != 127 and r[0] > self.peer.now() - window]
        return statistics.median(recent) if recent else None

    def screen_locked(self):
        """真锁屏时看 Windows；--no-lock 时判定离开就算本来已经锁了"""
        return bool(self.locked) if self.args.lock else self.away_at is not None

    def host_state(self):
        """写进心跳的电脑状态：1 未锁屏，2 已锁屏，3 已锁屏且请手机提示解锁"""
        if not self.screen_locked():
            return 1
        return 3 if self.prompting else 2

    def update(self):
        a, p, now = self.args, self.peer, time.time()
        gap = now - self.last_update if self.last_update is not None else 0.0
        self.last_update = now
        p.mark("idle_check")
        idle = input_idle_seconds()
        med = self.rssi_median()
        last = p.last_report_wall
        # 电脑端刚启动（包括卡死后自动重启）时手机还没连回来，不算失联
        lost = ((not p.clients or last is None or now - last > self.report_timeout())
                and now - self.started > a.startup_grace)
        self.lost_since = (self.lost_since or now) if lost else None
        weak = not lost and med is not None and med < a.far_th
        self.weak_since = (self.weak_since or now) if weak else None

        self.last_idle = idle
        present = idle is not None and idle < a.active
        # 手机失联算离开的前提是这次启动以来收到过它的报告：分不清"手机走了"和"手机根本没连这台
        # 电脑"（比如 App 还没添加它），宁可不锁，不然会把坐着、只是一会儿没碰电脑的人锁住。
        # 以前收到过报告（phone_known，见 restore_history）的也算
        lost_away = (self.lost_since and now - self.lost_since >= a.lost_for
                     and (last is not None or self.phone_known))
        away = (idle is not None and idle >= a.idle_lock
                and (lost_away or (self.weak_since and now - self.weak_since >= a.far_for)))
        state = "present" if present else "away" if away else "idle"
        entering_away = state == "away" and self.state != "away"
        if state != self.state:
            names = {"present": "在电脑前", "away": "离开", "idle": "没在操作"}
            idle_s = "?" if idle is None else f"{idle:.0f}"
            why = f"空闲 {idle_s}s" + (f"，信号 {med:.0f}" if med is not None else "") + ("，手机失联" if lost else "")
            p.say(f"电脑判断 → {names[state]}（{why}）")
            p.log("judge", rssi=f"{med:.0f}" if med is not None else "",
                  note=f"{state} idle={idle_s}s" + (" lost" if lost else ""))
            self.state = state

        p.mark("lock_check")
        locked = workstation_locked()
        if locked != self.locked:
            if self.locked is not None:
                p.say("Windows 已锁屏" if locked else "Windows 已解锁")
            p.log("locked" if locked else "unlocked")
            self.locked = locked
        if locked and self.away_at is not None:
            self.seen_locked = True

        # 电脑端被冻住过（合盖、我们关屏进的待机，电源请求都挡不住），醒来时锁着：冻住期间看不到手机走没走，
        # 当作手机走远过（armed），手机在旁边就请提示。不然走开时合了盖、冻住前还没判定离开的话，
        # 醒来后手机马上连回，电脑端却没看到手机走过，一直不提示，只能手动解锁。
        # 要等显示器亮了（按电源键、开盖、动鼠标）才算：每小时一次的维护唤醒显示器不亮、盖子可能合着，这时不能解
        if gap >= a.freeze_away and a.lock and locked and not (self.armed or self.prompting):
            if self.frozen_since is None and self.display.on is False:
                p.log("freeze_wait", note=f"电脑端 {gap:.0f}s 没转（待机冻住了），醒来锁着、显示器没亮，等亮了再当作离开过")
            self.frozen_since = self.frozen_since or now - gap
        if self.frozen_since is not None:
            if not locked or self.armed or self.prompting:
                self.frozen_since = None
            elif self.display.on is not False:
                note = (f"电脑端从 {datetime.fromtimestamp(self.frozen_since):%H:%M:%S} 起被待机冻住，"
                        "醒来锁着、显示器亮了，当作手机走远过，手机在旁边就请提示")
                p.say(note)
                p.log("freeze_away", note=note)
                self.armed = True
                self.ref_start = self.frozen_since  # 「走远时的信号」只看冻住以后的报告，冻住前人还坐着
                self.frozen_since = None

        # 判定离开 → 锁屏；手机走后已经锁过一次、被解开了就不再锁（hold_lock）
        if state == "away" and self.away_at is None and self.hold_lock:
            if entering_away:
                why = f"空闲 {idle:.0f}s，" + ("手机失联" if lost else f"信号 {med:.0f}")
                p.say("判定离开，但手机走后已经锁过一次、被解开了，不再锁")
                p.log("lock_skip", note=why + "；手机走后已经锁过一次、被解开了，手机回来以前不再自动锁")
        elif state == "away" and self.away_at is None:
            # 判定离开只要手机失联或信号弱 10 秒，还不算「走远过」（armed）：要像下面那样持续走远 --cancel-after 秒。
            # 这时就算走远过的话，判定离开后头二十来秒「走远时的信号」还没有报告（reference 为 None），「强 10 dB」被跳过，
            # 信号回到 -72 就请提示：手机在屋里、信号只是跌了一下，电脑也会自动解锁，其实没人用
            self.away_at = now
            why = f"空闲 {idle:.0f}s，" + ("手机失联" if lost else f"信号 {med:.0f}")
            if not a.lock:
                p.say("⇒ 本来会锁屏")
                p.log("would_lock", note=why)
            else:
                if locked:
                    # 用户自己锁的屏、之后手机也走了：同样调暗、不让待机，不然系统关屏就进待机，手机回来没法提示
                    ok = True
                    p.say("判定离开（Windows 本来就锁着）")
                    p.log("lock", note=why + "，本来就锁着")
                else:
                    p.mark("LockWorkStation")
                    ok = lock_workstation()
                    p.say("⇒ 已锁屏：你离开了" if ok else "⇒ 锁屏失败")
                    p.log("lock", note=why + ("" if ok else "，LockWorkStation 失败"))
                if ok and a.awake_minutes > 0:
                    # 用户自己锁屏时可能已经开着（见下面），这里从判定离开起重新算 --awake-minutes
                    p.mark("PowerSetRequest")
                    awake_ok = self.awake.set(True)
                    self.awake_until = now + a.awake_minutes * 60
                    self.awake_spent = True
                    p.log("keep_awake", note=f"最多 {a.awake_minutes:g} 分钟" + ("" if awake_ok else "，电源请求失败"))
                if ok and a.screen != "keep":
                    # 自己锁的等锁屏界面出来再调暗或关屏，免得被锁屏动画重新点亮；本来就锁着的马上调
                    self.display_off_at = now + (0 if locked else 2)

        if locked and a.lock and a.awake_minutes > 0 and not self.awake.on and not self.awake_spent:
            # 锁着就打开电源请求，不管是谁锁的（包括用户自己按 Win+L）：用电池时锁屏 0.5 秒就进待机、约 15 秒后
            # 电脑端被暂停，等判定离开（空闲 60 秒、手机失联 10 秒）再开就晚了，手机回来没人应答。
            # 只开电源请求，屏幕还是判定离开以后才处理
            p.mark("PowerSetRequest")
            awake_ok = self.awake.set(True)
            self.awake_until = now + a.awake_minutes * 60
            self.awake_spent = True
            p.log("keep_awake", note=f"锁屏了，最多 {a.awake_minutes:g} 分钟" + ("" if awake_ok else "，电源请求失败"))
        # 不能只看"现在没锁"：LockWorkStation 是异步的，刚调完那一秒系统还报没锁，所以还要判定离开也清掉了
        unlocked_back = not locked and self.away_at is None
        if self.awake.on and (unlocked_back or self.awake_until is None or now >= self.awake_until):
            # 解锁了（back 会清掉 away_at），或者锁得太久：放开电源请求（之后再回来，用电池时要先按键唤醒）
            p.mark("PowerClearRequest")
            self.awake.set(False)
            self.awake_until = None
            p.log("allow_sleep", note="回来了" if unlocked_back else
                  f"{'离开' if self.away_at is not None else '锁屏'}超过 {a.awake_minutes:g} 分钟")
            if self.away_at is not None and self.saved_brightness is not None:
                # 离开太久：恢复亮度再真关屏，让电脑去待机省电
                self.restore_brightness(p)
                self.screen_off(p, f"离开超过 {a.awake_minutes:g} 分钟，关屏待机，回来要先按键唤醒")
        if unlocked_back:
            self.awake_spent = False  # 这次锁屏的电源请求用过了就不再开，解锁以后下次锁屏再开
        if self.display_off_at is not None and now >= self.display_off_at:
            self.display_off_at = None
            if locked and a.screen == "dim":
                # 亮度调到 0：看着接近黑屏，对系统来说显示器还开着。原来以为真关屏进了待机蓝牙就停，
                # 后来实测有电源请求时待机里照常跑，默认改成了真关屏（off），这个留作备选
                p.mark("get_brightness")
                self.saved_brightness = get_brightness()
                p.mark("set_brightness")
                ok = self.saved_brightness is not None and set_brightness(0)
                p.say(f"⇒ 屏幕调暗（原来亮度 {self.saved_brightness}）" if ok else "⇒ 调暗失败")
                p.log("dim", note=f"brightness={self.saved_brightness}" + ("" if ok else " 失败"))
                if not ok:
                    self.saved_brightness = None
            elif locked and a.screen == "off":
                self.screen_off(p, "")

        # 锁屏期间：手机走远过、又回来了 → 请手机提示解锁。
        # 信号要连续 --approach-for 秒都在 --approach-th 以上：两天的日志里 65 次提示大多是在 -79 到 -82
        # 弹的（手机在别的房间、蓝牙范围边上，信号一跳就算回来），夜里也弹
        self.last_med = med
        latest = [r[1] for r in p.reports[-1:] if r[1] != 127 and r[0] > p.now() - self.report_timeout()]
        self.last_rssi = latest[0] if latest else None
        # 还要比走远时明显变强：手机放在别的房间时信号也会到 -72，只看阈值会整夜反复提示
        ref = self.reference(p.reports, p.now(), None if self.ref_start is None else self.ref_start - p.t0,
                             a.ref_window)
        self.last_ref = ref
        if not lost and med is not None and med >= a.approach_th and (ref is None or med >= ref + a.approach_gain):
            self.near_since = self.near_since or now
        else:
            self.near_since = None
        phone_near = self.near_since is not None and now - self.near_since >= a.approach_for
        if self.hold_lock and phone_near:
            self.hold_lock = False
            p.say("手机回来了，恢复自动锁屏")
            p.log("lock_resume", rssi=f"{med:.0f}", note="手机回来了，恢复自动锁屏")
        # 手机持续走远（失联或信号弱）--cancel-after 秒才算"走远过"：信号在阈值附近来回跳、偶尔几秒
        # 没报告都不算，不然会反复撤销、重弹通知（实测锁屏 3 小时里撤了又弹二十多次）
        gone_for = max(now - self.lost_since if self.lost_since else 0,
                       now - self.weak_since if self.weak_since else 0)
        phone_gone = gone_for >= a.cancel_after
        if self.screen_locked():
            if phone_gone:
                self.armed = True  # 也包括用户自己锁屏后带着手机走开
                self.ref_start = self.ref_start or self.gone_start(now)
                if self.prompting:
                    self.prompting = False  # 提示过以后人又走远了，撤销，等下次回来再提示
                    self.prompt_at = None   # 不清掉的话，之后解锁会记成"提示后几万秒解锁"
                    # 「走远时的信号」从这次走开算起：不然上次回来时的强信号还在参考里，再回来就不提示了
                    self.ref_start = self.gone_start(now)
                    p.say("手机又走远了，撤销解锁提示")
                    p.log("prompt_cancel")
                    if self.dim_after_cancel:
                        self.dim_after_cancel = False
                        self.display_off_at = now  # 请提示时恢复的亮度再调暗
            elif self.armed and phone_near and not self.prompting:
                self.prompting, self.armed, self.prompt_at = True, False, now
                self.prompt_id = self.prompt_id % 65535 + 1
                note = (f"id={self.prompt_id}" + (f"，离开 {now - self.away_at:.0f}s 后" if self.away_at else "")
                        + (f"，比走远时（{ref:.0f}）强 {med - ref:.0f} dB" if ref is not None
                           else "，之前一段没有报告（手机刚连回来）"))
                p.say(f"⇒ 手机回来了（信号 {med:.0f}），请手机提示解锁")
                p.log("prompt" if a.lock else "would_prompt", rssi=f"{med:.0f}", note=note)
                if self.saved_brightness is not None or self.display_off_at is not None:
                    # 先恢复亮度，和 Mac 请提示时点亮屏幕一样：自动解锁没成、要手动输密码时，
                    # 不能对着亮度 0 的锁屏（亮度是软件调的，按键也亮不起来）
                    self.restore_brightness(p, "请手机提示解锁，先恢复亮度")
                    self.display_off_at = None
                    self.dim_after_cancel = True

        # 回来了：真锁屏时看 Windows 解锁；--no-lock 或锁屏失败时看键盘鼠标
        if a.lock:
            # 刚调 LockWorkStation 的一两秒里，系统还没报锁上，而且会把"上次操作时间"刷新一次，
            # 所以锁屏 5 秒后还没看到锁上才算锁屏失败，这时看键盘鼠标
            lock_failed = self.away_at is not None and not self.seen_locked and now - self.away_at > 5
            back = (not locked) and (self.seen_locked or (lock_failed and present)
                                     or (self.away_at is None and self.prompt_at is not None))
        else:
            back = self.away_at is not None and present
        if back:
            if self.prompt_at is not None:
                note = f"提示后 {now - self.prompt_at:.0f}s " + ("解锁" if a.lock else "动了键盘鼠标")
            else:
                note = "没提示就" + ("解锁了" if a.lock else "回来了")
            p.say(f"⇒ 回来了：{note}")
            p.log("back", rssi=f"{med:.0f}" if med is not None else "",
                  note=(f"离开 {now - self.away_at:.0f}s，" if self.away_at else "") + note)
            # 判定离开锁的屏、手机还没回来（失联或信号弱）就被解开了：多半是人在外面远程解的（远程操作和本机
            # 键盘鼠标分不出来），手机回来以前不再自动锁，不然停一下就锁、每次都得远程输密码
            if self.away_at is not None and (lost or weak) and not self.hold_lock:
                self.hold_lock = True
                p.say("手机还没回来就被解开了（可能是远程），手机回来以前不再自动锁")
                p.log("lock_hold", note="手机还没回来就被解开了（多半是远程解的），手机回来以前不再自动锁")
            self.restore_brightness(p)
            self.display_off_at = None
            self.dim_after_cancel = False
            self.away_at = self.prompt_at = self.ref_start = None
            self.prompting = self.armed = self.seen_locked = False
        elif a.lock and not locked and self.away_at is None:
            # 用户自己解锁，或认证模式重启后没有恢复旧 away/prompt，也要还原旧进程调暗的亮度。
            self.restore_brightness(p)
            self.display_off_at = None
            self.dim_after_cancel = False
            self.prompting = self.armed = False
            self.ref_start = None

    def restore_brightness(self, p, why=""):
        if self.saved_brightness is None:
            return
        p.mark("set_brightness")
        ok = set_brightness(self.saved_brightness)
        p.say(f"⇒ 恢复亮度 {self.saved_brightness}" if ok else "⇒ 恢复亮度失败")
        p.log("undim", note=f"brightness={self.saved_brightness}" + (f"，{why}" if why else "") + ("" if ok else " 失败"))
        self.saved_brightness = None

    def screen_off(self, p, note):
        p.mark("turn_off_display")
        ok = turn_off_display()
        p.say("⇒ 已关屏" if ok else "⇒ 关屏失败")
        p.log("display_off", note=note + ("" if ok else " PostMessage 失败"))

    def heartbeat_interval(self):
        """
        心跳分三档（docs/protocol.md「心跳快慢和休眠」）：
        - 每秒一次（--interval）：有人在用电脑，或者手机信号不弱
        - 慢（--slow-interval，3 秒）：没人用电脑、信号 < --slow-th（-75）。两天里卡死 69 次，大多在夜里手机在远处、
          信号 -80 到 -95 时，发得越勤越容易碰上卡死
        - 休眠（--dormant-interval，30 秒）：锁着、--dormant-after（30 分钟）没碰键盘鼠标，不看信号。
          每发一次心跳就把 App 叫醒一次，一晚上上万次，耗手机电。原来要信号 < -80 持续 10 分钟，
          可手机放在别的房间时信号一直在 -69 到 -76（和揣兜里坐在电脑前差不多），根本进不去
        每次心跳都写明下一次最晚几秒后到，App 的看门狗跟着放宽。最新一条报告比走远时明显变强（≥ 参考 + --approach-gain，
        包括手机亮屏时 App 主动报的），或者前一段没有报告（手机刚连回来），就退出休眠
        """
        a = self.args
        if self.state == "present":
            return a.interval
        # 休眠要 App 认识心跳里"下一次最晚几秒"（报告里写了协议版本 ≥ 2）：旧 App 的看门狗固定 5 秒，
        # 30 秒一次心跳会让它以为断了、每 5 秒重连一次，反而更耗电
        if (getattr(self.peer, "app_proto", 1) >= 2 and self.screen_locked()
                and self.last_idle is not None and self.last_idle >= a.dormant_after
                and self.last_ref is not None
                and not (self.last_rssi is not None and self.last_rssi >= self.last_ref + a.approach_gain)):
            return a.dormant_interval
        # 进入慢档看中位数；退出只要最新一条够强
        if (self.last_med is None or self.last_med >= a.slow_th
                or (self.last_rssi is not None and self.last_rssi >= a.slow_th)):
            return a.interval
        return a.slow_interval

    def summary(self):
        names = {"present": "在电脑前", "away": "离开", "idle": "没在操作", None: "-"}
        idle = input_idle_seconds()
        text = f"电脑判断 {names[self.state]}（空闲 {idle:.0f}s）" if idle is not None else ""
        if self.current_interval >= self.args.dormant_interval:
            text += "，休眠（心跳 30 秒一次）" if self.args.dormant_interval == 30 else f"，休眠（心跳 {self.current_interval:g} 秒一次）"
        if self.prompting:
            text += "，正在请手机提示解锁"
        elif self.screen_locked():
            text += "，锁屏中"
        return text


def log_time(text):
    """日志 time 列转成时间戳；行被写坏了（读不出来）返回 None"""
    try:
        return datetime.fromisoformat(text).timestamp()
    except (TypeError, ValueError):
        return None


def open_log(path):
    new = not os.path.exists(path) or os.path.getsize(path) == 0
    f = open(path, "a", newline="", encoding="utf-8-sig")
    w = csv.DictWriter(f, CSV_FIELDS)
    if new:
        w.writeheader()
    return f, w


def log_row(writer, t0, event, **kw):
    row = {"time": datetime.now().isoformat(timespec="milliseconds"),
           "t": f"{time.time() - t0:.3f}", "event": event}
    row.update(kw)
    writer.writerow(row)


class Peer:
    def __init__(self, args):
        self.args = args
        self.loop = None                  # 蓝牙线程的事件循环
        self.started = threading.Event()
        self.start_error = None
        self.t0 = args.t0 or time.time()  # 守护进程传进来，重启后 t 接着算
        self.seq = 0
        self.sent = {}       # seq -> 发出时间，用来算往返延迟
        self.authenticated_sent = {}  # (seq, device_id, connection generation) -> 本次实际通知的单调时间
        self.pending_notifications = {}
        self.link_generations = {}
        self.disconnected_links = set()
        self.clients = {}    # device_id -> 显示名
        self.reports = []    # (t, rssi, state, latency_ms)
        self.connected_since = None
        self.connected_total = 0.0
        self.disconnects = 0
        self.last = None
        self.last_report_wall = None  # 最后一次收到报告的时间
        self.app_proto = 1            # App 在报告第 7 个字节里写的协议版本，没写就是 1；≥ 2 才会进休眠
        self.alive_at = time.time()   # 最后一次确认手机有回应（报告、订阅、读 INFO）的时间
        self.hb_paused = False        # 手机没回应时暂停发心跳，见 heartbeat_gate
        self.bt_tick = time.time()   # 蓝牙线程的事件循环最后一次转动的时间
        self.notify_since = None     # 正在发的那次心跳是什么时候开始的
        self.notify_ms = []          # 每次发心跳的耗时（毫秒）
        self.adv_bad_since = None    # 广播从什么时候起不在 STARTED 状态
        self.beacon = None           # iBeacon 发布器
        self.links = {}              # device_id -> BluetoothLEDevice，留着引用才会一直收到链路断开、连上的事件
        self.beacon_next_retry = 0.0
        self.adv_next_retry = 0.0
        self.adv_retry_wait = 10
        self.health = shared_memory.SharedMemory(name=args.health) if args.health else None
        if self.health is not None:
            struct.pack_into("q", self.health.buf, 8, os.getpid())
        self.lock = threading.Lock()
        self.path = args.out or datetime.now().strftime("peer_%Y%m%d_%H%M%S_win32.csv")
        self.file, self.csv = open_log(self.path)
        self.unlock_backend = None
        load_failed = False
        if args.lock and not getattr(args, "no_auto_unlock", False):
            try:
                self.unlock_backend = load_backend()
            except Exception:
                # 存储或组件不可用时绝不向手机宣称支持自动解锁，也不输出凭据细节。
                load_failed = True
        key = (UnlockKey(self.unlock_backend.key_id, self.unlock_backend.secret)
               if self.unlock_backend is not None else None)
        self.report_nonce = os.urandom(16)
        self.maximum_interval = max(args.interval, args.slow_interval, args.dormant_interval)
        self.authenticated_reports = (AuthenticatedReportGate(key, self.report_nonce, self.maximum_interval)
                                      if key is not None else None)
        self.unlock_gate = UnlockGate(key) if key is not None else None
        # 手机让电脑锁屏（App 首页的锁按钮，docs/protocol.md「手动锁屏、解锁」），登记了才有
        self.lock_gate = LockGate(key, self.report_nonce, self.maximum_interval) if key is not None else None
        self.unlock_failed = False  # 系统提交失败后停用到手动解锁，不能由新靠近提示反复提交错误密码
        self.enroll_prompt = None     # 手机请求显示登记码时另起的确认进程（enroll_prompt.py），开着就不再起第二个
        self.enroll_prompt_at = -math.inf
        self.report_reject_count = 0
        self.last_report_reject_log = -math.inf
        self.judge = Judge(self)
        if self.unlock_backend is not None:
            self.log("unlock_enabled", note=UNLOCK_CAPABILITY)
            self.say("已启用登记手机自动解锁：只接受当前连接的认证报告和一次性签名请求"
                     "（当前提示，或锁着时手机上手动解锁）；手机也能让电脑锁屏。")
        elif load_failed:
            self.log("unlock_disabled", note="本机登记或 Credential Provider 不可用")
            self.say("本机自动解锁登记或组件不可用，请检查本机安装和登记。")

    def info_payload(self):
        fields = {"proto": PROTO_VERSION, "platform": sys.platform, "name": socket.gethostname()}
        if self.unlock_backend is not None and self.unlock_backend.available():
            fields.update(unlock=UNLOCK_CAPABILITY,
                          reportNonce=base64.b64encode(self.report_nonce).decode("ascii"),
                          # 支持手动解锁（锁着、没在请提示时也给挑战）和手机锁屏（docs/protocol.md「手动锁屏、解锁」）
                          manual=MANUAL_VERSION)
        return json.dumps(fields, ensure_ascii=False).encode()

    def clear_connection_proof(self, dev_id):
        self.link_generations[dev_id] = self.link_generations.get(dev_id, 0) + 1
        self.authenticated_sent = {k: v for k, v in self.authenticated_sent.items() if k[1] != dev_id}
        if self.authenticated_reports is not None:
            self.authenticated_reports.clear_presence(dev_id)
            self.unlock_gate.clear_central(dev_id)
            self.reports[:] = [r for r in self.reports if len(r) < 5 or r[4] != dev_id]
            if hasattr(self, "judge"):
                self.judge.near_since = None

    def request_has_proof(self, dev_id):
        return (self.authenticated_reports is not None and dev_id in self.clients
                and dev_id not in self.disconnected_links
                and self.authenticated_reports.is_fresh(dev_id, time.monotonic(), self.judge.current_interval))

    def sync_unlock_gate(self):
        """
        每次访问都重新核对系统锁屏。返回现在能解的目标：正在请的提示编号；锁着、没在请提示时是 0
        （手动解锁，手机用户在 App 里点了解锁）；不能解是 None。0 也是能解，调用方要用 is None 判断。
        系统解锁失败一次（unlock_failed）就连手动解锁一起停，直到在电脑上解开：不能反复提交错误密码
        """
        if self.unlock_gate is None:
            return None
        locked = workstation_locked()
        if not locked:
            self.unlock_failed = False
            self.unlock_gate.reset_manual_failures()  # 真解锁了才清零，手机断开再连回不清
        if not (self.args.lock and not self.unlock_failed and locked
                and self.authenticated_reports.has_fresh_report(time.monotonic(), self.judge.current_interval)):
            target = None
        elif self.judge.prompting:
            target = self.judge.prompt_id
        else:
            target = MANUAL_PROMPT_ID
        self.unlock_gate.sync(target, time.monotonic())
        return target

    def now(self):
        return time.time() - self.t0

    def log(self, event, **kw):
        # 每行都立刻写盘：工作进程可能被守护进程强制结束，缓冲里的不能丢
        with self.lock:
            log_row(self.csv, self.t0, event, **kw)
            self.file.flush()

    def say(self, msg):
        print(f"[{fmt_t(self.now())}] {msg}", flush=True)

    def safe_call(self, fn, *args):
        """把系统线程上的回调转回蓝牙线程；进程退出时事件循环已经关了，系统的回调还会来，忽略"""
        try:
            self.loop.call_soon_threadsafe(fn, *args)
        except RuntimeError:
            pass

    def mark(self, op):
        """调用可能卡住的系统接口之前打个点。卡死的线程占着 GIL，别的线程没机会再改，
        所以守护进程读到的就是卡住的那个调用"""
        if self.health is not None:
            self.health.buf[16:OP_END] = op.encode()[:OP_END - 17].ljust(OP_END - 16, b"\0")

    # ------------------------------------------------ 蓝牙线程

    def run_bt(self):
        try:
            asyncio.run(self.bt_main())
        except BaseException as e:
            self.start_error = e
            self.started.set()

    async def bt_main(self):
        self.loop = asyncio.get_running_loop()
        await self.start()
        self.started.set()
        self.tasks = [asyncio.create_task(self.heartbeat_loop()), asyncio.create_task(self.tick_loop())]
        await asyncio.gather(*self.tasks)

    async def tick_loop(self):
        next_judge = next_adv = 0.0
        while True:
            self.bt_tick = time.time()
            if self.bt_tick >= next_judge:
                next_judge = self.bt_tick + 1
                try:
                    self.judge.update()
                    self.sync_unlock_gate()
                except Exception as e:
                    self.say(f"判断出错：{e!r}")
            if self.bt_tick >= next_adv:
                next_adv = self.bt_tick + 5
                try:
                    self.check_advertising()
                    self.check_beacon()
                except Exception as e:
                    self.say(f"检查广播出错：{e!r}")
            if self.health is not None:
                # 有一次心跳正在发、还没返回时，报它开始的时间：异步操作一直不完成也算卡住
                healthy = self.bt_tick if self.notify_since is None else self.notify_since
                struct.pack_into("d", self.health.buf, 0, healthy)
                if self.notify_since is not None and self.bt_tick - self.notify_since > 1:
                    # 心跳发出去了但一直没完成：标签写明，免得被之后别的调用的标签盖掉
                    self.mark("notify:pending")
            if self.args.simulate_stuck and self.args.restart == 0 and self.now() > self.args.simulate_stuck:
                # 测试用：和真实情况一样，卡在原生调用里并且占着 GIL（PyDLL 调用不释放 GIL）
                self.mark("simulate_stuck")
                ctypes.PyDLL("kernel32").Sleep(1_000_000_000)
            await asyncio.sleep(0.5)

    async def start(self):
        res = await GattServiceProvider.create_async(uuid.UUID(SERVICE_UUID))
        if res.error != BluetoothError.SUCCESS:
            raise RuntimeError(f"创建蓝牙服务失败：{res.error.name}")
        self.provider = res.service_provider
        self.hb = await self._char(HEARTBEAT_UUID, Props.NOTIFY | Props.READ, "heartbeat")
        self.report = await self._char(REPORT_UUID, Props.WRITE | Props.WRITE_WITHOUT_RESPONSE, "report")
        self.info_char = await self._char(INFO_UUID, Props.READ, "info")
        # 有没有登记都开放：第一次登记也要靠它请电脑弹窗
        self.enroll_request_char = await self._char(ENROLL_REQUEST_UUID, Props.WRITE, "enroll_request")
        self.enroll_request_char.add_write_requested(lambda s, a: self.defer(a, self.on_write_enroll_request))
        self.challenge_char = self.unlock_char = self.enroll_ack_char = self.lock_char = None
        if self.unlock_gate is not None:
            # 不开放 KEY 特征；手机只能通过本机离线登记得到随机密钥。
            self.challenge_char = await self._char(CHALLENGE_UUID, Props.READ, "challenge")
            self.unlock_char = await self._char(UNLOCK_UUID, Props.WRITE, "unlock")
            self.enroll_ack_char = await self._char(ENROLL_ACK_UUID, Props.WRITE, "enroll_ack")
            self.lock_char = await self._char(LOCK_UUID, Props.WRITE, "lock")
            self.challenge_char.add_read_requested(lambda s, a: self.defer(a, self.on_read_challenge))
            self.unlock_char.add_write_requested(lambda s, a: self.defer(a, self.on_write_unlock))
            self.enroll_ack_char.add_write_requested(lambda s, a: self.defer(a, self.on_write_enroll_ack))
            self.lock_char.add_write_requested(lambda s, a: self.defer(a, self.on_write_lock))

        # WinRT 事件在系统线程上触发，统一转回蓝牙线程的事件循环处理
        self.hb.add_subscribed_clients_changed(lambda s, a: self.loop.call_soon_threadsafe(self.on_subscribers))
        self.hb.add_read_requested(lambda s, a: self.defer(a, self.on_read_heartbeat))
        self.info_char.add_read_requested(lambda s, a: self.defer(a, self.on_read_info))
        self.report.add_write_requested(lambda s, a: self.defer(a, self.on_write_report))
        self.provider.add_advertisement_status_changed(
            lambda s, a: self.loop.call_soon_threadsafe(self.on_adv_status, a.status, a.error))

        self.adv_params = GattServiceProviderAdvertisingParameters()
        self.adv_params.is_connectable = True
        self.adv_params.is_discoverable = True
        self.provider.start_advertising_with_parameters(self.adv_params)
        self.log("start", note=f"service={SERVICE_UUID} interval={self.args.interval} "
                               f"secure={self.args.secure} restart={self.args.restart}")
        await self.watch_radio()
        if self.args.beacon:
            self.start_beacon()

    async def watch_radio(self):
        """记下电脑蓝牙开关的变化：用户关开过蓝牙的话，日志里要看得出来，不然没法判断"""
        try:
            for radio in await Radio.get_radios_async():
                if radio.kind == RadioKind.BLUETOOTH:
                    self.radio = radio  # 留着引用，事件才会一直来
                    radio.add_state_changed(lambda r, _: self.safe_call(self.on_radio, r.state))
                    self.log("radio", note=radio.state.name)
                    return
            self.log("radio", note="没找到蓝牙")
        except Exception as e:
            self.log("radio", note=f"读不到：{e!r}")

    def on_radio(self, state):
        self.say(f"电脑蓝牙：{state.name}")
        self.log("radio", note=state.name)

    def start_beacon(self):
        """和协议服务的广播一起发 iBeacon，实测两个同时发互不影响"""
        self.mark("beacon_start")
        pub = BluetoothLEAdvertisementPublisher()
        md = BluetoothLEManufacturerData()
        md.company_id = APPLE_COMPANY_ID
        md.data = to_buffer(beacon_payload(BEACON_MAJOR, self.args.beacon_minor))
        pub.advertisement.manufacturer_data.append(md)
        pub.add_status_changed(lambda s, e: self.safe_call(self.on_beacon_status, e.status, e.error))
        pub.start()
        self.beacon = pub
        self.log("beacon_on", note=f"uuid={str(BEACON_UUID).upper()} major={BEACON_MAJOR} minor={self.args.beacon_minor}")

    def on_beacon_status(self, status, error):
        name = getattr(status, "name", str(status))
        if name not in ("WAITING", "STARTED"):
            self.say(f"iBeacon 状态：{name}")
        self.log("beacon_status", note=f"{name} {getattr(error, 'name', error)}")

    def check_beacon(self):
        """iBeacon 被系统停掉（ABORTED、STOPPED）就每 30 秒重开一次"""
        if self.beacon is None:
            return
        self.mark("beacon_status")
        status = self.beacon.status
        if status in (BeaconStatus.STARTED, BeaconStatus.WAITING, BeaconStatus.CREATED):
            return
        now = time.time()
        if now < self.beacon_next_retry:
            return
        self.beacon_next_retry = now + 30
        self.mark("beacon_start")
        try:
            self.beacon.start()
            err = ""
        except Exception as e:
            err = f"，出错 {e!r}"
        self.log("beacon_retry", note=f"{status.name}{err}")

    def share_adv_bad(self):
        if self.health is not None:
            struct.pack_into("d", self.health.buf, OP_END, self.adv_bad_since or 0.0)

    def check_advertising(self):
        """
        广播不在 STARTED 状态、手机又没连着，就隔一段时间重开（10 秒后第一次，之后间隔翻倍，最多 5 分钟）。
        实测：手机订阅着时电脑端的服务被撤掉（卡死重启、手动重启），之后整台电脑的可连接广播
        都开不起来，手机断开也没用，重开没用，要关开一次蓝牙（守护进程自动修）。
        配对过的手机广播坏着也连得回来，App 按服务 UUID 搜索时才用得着。
        """
        self.mark("advertisement_status")
        status = self.provider.advertisement_status
        now = time.time()
        if status in (AdvStatus.STARTED, AdvStatus.STARTED_WITHOUT_ALL_ADVERTISEMENT_DATA):
            if self.adv_bad_since is not None and self.adv_retry_wait > 10:
                # 只在重开过以后记：启动时状态会先报一下 ABORTED，几十毫秒后才变 STARTED，那不算不正常
                self.log("adv_ok", note=f"广播恢复，之前 {now - self.adv_bad_since:.0f}s 不正常")
            self.adv_bad_since, self.adv_retry_wait = None, 10
            self.share_adv_bad()
            return
        if self.clients and time.time() - self.alive_at <= self.judge.report_timeout():
            # 手机连着：广播手机用不着，而这时停了再开广播，之后几秒内的心跳常常卡死，
            # 所以等手机断开再重开
            if self.adv_bad_since is not None:
                self.adv_bad_since, self.adv_retry_wait = None, 10
                self.share_adv_bad()
            return
        if self.adv_bad_since is None:
            self.adv_bad_since, self.adv_next_retry = now, now + self.adv_retry_wait
            self.share_adv_bad()
            return
        if now < self.adv_next_retry:
            return
        self.mark("start_advertising")
        try:
            self.provider.stop_advertising()
        except Exception:
            pass
        try:
            self.provider.start_advertising_with_parameters(self.adv_params)
            err = ""
        except Exception as e:
            err = f"，出错 {e!r}"
        self.say(f"广播状态是 {status.name}，已经 {now - self.adv_bad_since:.0f} 秒，重开一次"
                 "（一直不好的话，关开一次电脑蓝牙）")
        self.log("adv_retry", note=f"{status.name}，已 {now - self.adv_bad_since:.0f}s{err}")
        self.adv_retry_wait = min(self.adv_retry_wait * 2, 300)
        self.adv_next_retry = now + self.adv_retry_wait

    async def _char(self, uid, props, desc):
        # 默认要求加密，iPhone 第一次访问时会弹配对请求。配对后 iPhone 存下电脑的身份密钥，
        # 电脑换了广播地址也能认出来；不配对（--plain）的话电脑每次重新广播，iPhone 都当成一台新设备
        level = GattProtectionLevel.ENCRYPTION_REQUIRED if self.args.secure else GattProtectionLevel.PLAIN
        p = GattLocalCharacteristicParameters()
        p.characteristic_properties = props
        p.read_protection_level = level
        p.write_protection_level = level
        p.user_description = desc
        r = await self.provider.service.create_characteristic_async(uuid.UUID(uid), p)
        if r.error != BluetoothError.SUCCESS:
            raise RuntimeError(f"创建特征值 {desc} 失败：{r.error.name}")
        return r.characteristic

    async def stop_advertising(self):
        """停广播、撤服务。中间不 await：任务一取消 bt_main 就结束了，事件循环随之关掉"""
        self.mark("stop_advertising")
        self.provider.stop_advertising()
        if self.beacon is not None:
            self.beacon.stop()
        for t in getattr(self, "tasks", []):
            t.cancel()
        # 放掉对服务的引用，系统马上撤掉这个服务，不用等进程没了以后过几分钟才清理
        self.hb = self.report = self.info_char = self.enroll_request_char = self.provider = self.beacon = None
        self.challenge_char = self.unlock_char = self.enroll_ack_char = self.lock_char = None
        if self.unlock_gate is not None:
            self.unlock_gate.sync(None, time.monotonic())
            self.authenticated_reports.clear_all_presence()
            self.authenticated_sent.clear()
        self.links = {}
        gc.collect()

    def defer(self, args, handler):
        """读写请求要先拿 deferral，在蓝牙线程里处理完再 complete"""
        self.mark(f"get_deferral:{handler.__name__}")
        deferral = args.get_deferral()
        context = None
        if handler.__name__ in ("on_read_challenge", "on_write_unlock", "on_write_report"):
            # 在原生事件入队时快照，不能等协程开始才套用重连后的新代际。
            try:
                dev_id = args.session.device_id.id
                context = (dev_id, self.link_generations.get(dev_id, 0))
            except Exception:
                deferral.complete()
                return

        async def run():
            try:
                if context is None:
                    await handler(args)
                else:
                    await handler(args, context)
            except Exception as e:
                self.say(f"处理请求出错：{e!r}")
            finally:
                deferral.complete()

        asyncio.run_coroutine_threadsafe(run(), self.loop)

    def on_adv_status(self, status, error):
        self.say(f"广播状态：{status.name}" + ("" if error == BluetoothError.SUCCESS else f"（{error.name}）"))
        self.log("adv_status", note=f"{status.name} {error.name}")

    def on_subscribers(self):
        self.mark("subscribed_clients")
        current = {c.session.device_id.id for c in self.hb.subscribed_clients}
        for dev in current - set(self.clients):
            self.clear_connection_proof(dev)
            self.disconnected_links.discard(dev)
            self.clients[dev] = dev
            self.alive_at = time.time()
            if self.connected_since is None:
                self.connected_since = self.now()
            self.say("手机已订阅心跳")
            self.log("subscribe", device=dev)
            asyncio.ensure_future(self.resolve_name(dev))
        for dev in set(self.clients) - current:
            self.clear_connection_proof(dev)
            name = self.clients.pop(dev)
            self.disconnects += 1
            self.say(f"手机断开：{name}")
            self.log("unsubscribe", device=name)
        if not self.clients:
            self.on_disconnected_all()

    def on_disconnected_all(self):
        if self.authenticated_reports is not None:
            self.authenticated_reports.clear_all_presence()
            self.authenticated_sent.clear()
            self.unlock_gate.sync(None, time.monotonic())
        if self.connected_since is not None:
            self.connected_total += self.now() - self.connected_since
            self.connected_since = None

    def watch_link(self, dev_id, dev):
        """
        记手机和电脑之间底层链路的断开、连上。配对过的手机离开时 Windows 不报告取消订阅，
        链路却是系统维持的，看它才知道手机什么时候真的断了（广播只有链路断了才开得起来）
        """
        if dev_id in self.links:
            return
        self.links[dev_id] = dev
        dev.add_connection_status_changed(lambda d, _: self.safe_call(self.on_link, dev_id, d.connection_status.name))
        self.on_link(dev_id, dev.connection_status.name)

    def on_link(self, dev_id, status):
        if status == "DISCONNECTED":
            self.disconnected_links.add(dev_id)
            self.clear_connection_proof(dev_id)
        else:
            self.disconnected_links.discard(dev_id)
        self.say(f"手机底层链路：{status}")
        self.log("link", device=self.clients.get(dev_id, dev_id), note=status)

    async def resolve_name(self, dev_id):
        try:
            self.mark("from_id_async")
            dev = await BluetoothLEDevice.from_id_async(dev_id)
            name = f"{dev.name or '无名'}（{fmt_addr(dev.bluetooth_address)}）"
            self.watch_link(dev_id, dev)
        except Exception as e:
            name = f"{dev_id}（取不到名字：{e!r}）"
        if dev_id in self.clients:
            self.clients[dev_id] = name
            self.say(f"连接的设备：{name}")
            self.log("device", device=name)

    async def on_read_heartbeat(self, args):
        self.mark("read_hb:get_request")
        req = await args.get_request_async()
        if req is None:
            return
        self.mark("read_hb:respond")
        self.respond_read(req, self.heartbeat_payload())

    async def on_read_info(self, args):
        self.mark("read_info:get_request")
        req = await args.get_request_async()
        if req is None:
            return
        self.mark("read_info:respond")
        self.respond_read(req, self.info_payload())
        self.alive_at = time.time()  # App 每次（重新）连上都会读一次 INFO
        self.log("read_info")

    @staticmethod
    def respond_read(req, data):
        if req.offset > len(data):
            req.respond_with_protocol_error(0x07)  # Invalid Offset
        else:
            req.respond_with_value(to_buffer(data[req.offset:req.offset + req.length]))

    def request_context(self, args, context):
        if context is not None:
            return context
        dev_id = args.session.device_id.id
        return dev_id, self.link_generations.get(dev_id, 0)

    async def on_read_challenge(self, args, context=None):
        dev_id, generation = self.request_context(args, context)
        req = await args.get_request_async()
        if req is None:
            return
        if req.offset != 0:
            req.respond_with_protocol_error(0x07)
            return
        # 必须先检查本连接，未认证设备不能清掉其它手机的挑战或刷新提示期限。
        if generation != self.link_generations.get(dev_id, 0) or not self.request_has_proof(dev_id):
            req.respond_with_protocol_error(int(UnlockStatus.UNAVAILABLE))
            return
        target = self.sync_unlock_gate()
        if target is None or not self.unlock_backend.available():
            req.respond_with_protocol_error(int(UnlockStatus.UNAVAILABLE))
            return
        try:
            value = self.unlock_gate.challenge(dev_id, time.monotonic())
        except UnlockError as error:
            req.respond_with_protocol_error(int(error.status))
        else:
            self.respond_read(req, value)
            if target == MANUAL_PROMPT_ID and self.judge.saved_brightness is not None:
                # 手动解锁：和请提示时一样先恢复调暗的亮度，自动解锁没成、要手动输密码时不用对着亮度 0 的锁屏。
                # 真关屏（默认）不用管：解锁会把电脑从待机里叫醒，屏幕跟着亮
                self.judge.restore_brightness(self, "手机要手动解锁，先恢复亮度")
                self.judge.display_off_at = None

    async def on_write_unlock(self, args, context=None):
        dev_id, generation = self.request_context(args, context)
        req = await args.get_request_async()
        if req is None:
            return
        if req.option != GattWriteOption.WRITE_WITH_RESPONSE:
            return
        if req.offset != 0:
            req.respond_with_protocol_error(0x07)
            return
        if generation != self.link_generations.get(dev_id, 0) or not self.request_has_proof(dev_id):
            req.respond_with_protocol_error(int(UnlockStatus.UNAVAILABLE))
            return
        target = self.sync_unlock_gate()
        if target is None or not self.unlock_backend.available():
            req.respond_with_protocol_error(int(UnlockStatus.UNAVAILABLE))
            return
        manual = target == MANUAL_PROMPT_ID
        try:
            self.unlock_gate.authorize(bytes(req.value), dev_id, time.monotonic(), eligible=True)
        except UnlockError as error:
            req.respond_with_protocol_error(int(error.status))
            if manual:
                self.log("unlock_fail", device=self.clients.get(dev_id, ""),
                         note=f"认证拒绝 0x{int(error.status):02x}（手动解锁）")
            return
        self.log("unlock_request", device=self.clients.get(dev_id, ""),
                 note="手动解锁：当前连接的一次性签名已核对（电脑没在请提示，手机用户在 App 里点了解锁）"
                      if manual else "当前连接的一次性签名已核对")
        ok = False
        try:
            # 原生后端有自己的期限、一次性 IPC 和目标会话校验；等待不占住蓝牙事件循环。
            ok = await asyncio.to_thread(self.unlock_backend.unlock)
        except Exception:
            pass
        finally:
            self.unlock_gate.finish(succeeded=bool(ok))
            if not ok:
                self.unlock_failed = True
        self.log("unlock" if ok else "unlock_fail", device=self.clients.get(dev_id, ""),
                 note=("Windows 已确认目标会话解锁" if ok else "未确认解锁，请手动解锁；不自动重试密码")
                      + ("（手动解锁）" if manual else ""))
        if ok:
            req.respond()
            self.judge.update()
            self.sync_unlock_gate()
        else:
            req.respond_with_protocol_error(int(UnlockStatus.EXECUTION_FAILED))

    async def on_write_lock(self, args, context=None):
        """
        手机让电脑锁屏（App 首页的锁按钮，docs/protocol.md「手动锁屏、解锁」）：核对登记密钥的签名、心跳 seq 是这次进程
        对这条连接真发过、没过期的，不重放。本来就锁着也回成功。锁上 2 秒后按 --screen 处理屏幕，和电脑端自己锁屏一样。
        判断那边当作用户自己锁的屏：手机一直在旁边就不会请提示，要在手机上点一下解锁，或者带着手机走开 1 分钟再回来
        """
        dev_id, generation = self.request_context(args, context)
        self.mark("lock:get_request")
        req = await args.get_request_async()
        if req is None:
            return
        if req.option != GattWriteOption.WRITE_WITH_RESPONSE:
            return
        if req.offset != 0:
            req.respond_with_protocol_error(0x07)
            return
        device = self.clients.get(dev_id, dev_id)
        if (not self.args.lock or self.lock_gate is None
                or generation != self.link_generations.get(dev_id, 0) or not self.request_has_proof(dev_id)):
            req.respond_with_protocol_error(int(UnlockStatus.UNAVAILABLE))
            self.log("phone_lock_reject", device=device, note="这条连接还没有通过认证的报告，或者没开真的锁屏")
            return
        data = bytes(req.value)
        seq = LockProtocol.sequence(data)
        pending = self.pending_notifications.get(seq) if seq is not None else None
        if pending is not None:
            # 和报告一样：手机可能抢在 NotifyValueAsync 的完成回调之前写过来，等实际发送结果
            try:
                await asyncio.wait_for(asyncio.shield(pending), timeout=1)
            except asyncio.TimeoutError:
                pass
        if generation != self.link_generations.get(dev_id, 0):
            req.respond_with_protocol_error(int(UnlockStatus.UNAVAILABLE))
            self.log("phone_lock_reject", device=device, note="等心跳发送结果时连接断了")
            return
        try:
            self.lock_gate.accept(data, self.authenticated_sent.get((seq, dev_id, generation)),
                                  time.monotonic(), self.judge.current_interval)
        except ReportAuthenticationError as error:
            status = {"invalid_format": 0x0D, "wrong_key": int(UnlockStatus.INVALID_SIGNATURE),
                      "invalid_signature": int(UnlockStatus.INVALID_SIGNATURE),
                      "stale_heartbeat": int(UnlockStatus.INVALID_CHALLENGE),
                      "replay": int(UnlockStatus.INVALID_CHALLENGE)}.get(error.reason, int(UnlockStatus.UNAVAILABLE))
            req.respond_with_protocol_error(status)
            self.log("phone_lock_reject", device=device, note=error.reason)
            return
        self.mark("lock:lock_check")
        if workstation_locked():
            req.respond()
            self.log("phone_lock", device=device, note="本来就锁着")
            return
        self.mark("LockWorkStation")
        if not lock_workstation():
            req.respond_with_protocol_error(int(UnlockStatus.EXECUTION_FAILED))
            self.log("phone_lock_fail", device=device, note="LockWorkStation 失败")
            return
        req.respond()
        self.say(f"⇒ 手机让电脑锁屏：{device}")
        self.log("phone_lock", device=device, note="已锁屏")
        # 不主动关屏：电脑端关屏进的待机会把电脑端冻住，之后手机上点解锁没人应答；
        # 锁屏界面约 30 秒后系统自己关屏，进的是闲置待机，锁着时有电源请求，电脑端照常跑，手机随时能解锁

    def enroll_ack_key(self, key_id):
        """验登记确认用的密钥：启动时载入的；重新登记换了新密钥（keyID 不同）时现读本机登记"""
        backend = self.unlock_backend
        if backend is None or backend.key_id != key_id:
            try:
                backend = load_backend()
            except Exception:
                return None
        if backend is None or backend.key_id != key_id:
            return None
        return UnlockKey(backend.key_id, backend.secret)

    async def on_write_enroll_ack(self, args, context=None):
        """
        iPhone 扫码或粘贴保存登记以后发来的确认（docs/protocol.md「登记确认」）：验签通过就通知本机登记窗口，
        窗口显示一下就自己关。只用来关窗口，不算手机在场、不能解锁，所以同一次连接里重放也无害
        """
        dev_id, _ = self.request_context(args, context)
        self.mark("enroll_ack:get_request")
        req = await args.get_request_async()
        if req is None:
            return
        if req.option != GattWriteOption.WRITE_WITH_RESPONSE:
            return
        if req.offset != 0:
            req.respond_with_protocol_error(0x07)
            return
        data = bytes(req.value)
        key_id = EnrollAckProtocol.key_id(data)
        # 现读登记要调 helper，放到线程里，不占住蓝牙事件循环
        key = None if key_id is None else await asyncio.to_thread(self.enroll_ack_key, key_id)
        device = self.clients.get(dev_id, dev_id)
        if key is None or not EnrollAckProtocol.verify(data, key, self.report_nonce):
            req.respond_with_protocol_error(int(UnlockStatus.INVALID_SIGNATURE))
            self.log("enroll_ack_reject", device=device, note="签名对不上，或者不是本机现在登记的密钥")
            return
        req.respond()
        shown = signal_enroll_window()
        rotated = self.unlock_backend is None or key.id != self.unlock_backend.key_id
        self.log("enroll_ack", device=device,
                 note=("已通知登记窗口关闭" if shown else "登记窗口没开着")
                      + ("；是新登记的密钥，重启电脑端以后才用它验报告" if rotated else ""))

    async def on_write_enroll_request(self, args, context=None):
        """
        手机点「扫码登记」时请电脑弹出登记窗口（docs/protocol.md「手机请求显示登记码」）。锁着屏回 0x81；
        确认进程或登记窗口已经开着就回成功、不开第二个；否则另起 enroll_prompt.py 先问用户再显示二维码，
        起不来回 0x82。附近任何设备都能写，所以电脑上一定要先确认
        """
        dev_id, _ = self.request_context(args, context)
        self.mark("enroll_request:get_request")
        req = await args.get_request_async()
        if req is None:
            return
        if req.option != GattWriteOption.WRITE_WITH_RESPONSE:
            return
        if req.offset != 0:
            req.respond_with_protocol_error(0x07)
            return
        device = self.clients.get(dev_id, dev_id)
        if bytes(req.value) != ENROLL_REQUEST_V1:
            req.respond_with_protocol_error(0x0D)  # Invalid Attribute Value Length
            self.log("enroll_request_reject", device=device, note="内容不对")
            return
        self.mark("enroll_request:lock_check")
        if workstation_locked():
            req.respond_with_protocol_error(0x81)
            self.log("enroll_request_reject", device=device, note="电脑锁着屏")
            return
        now = time.monotonic()
        if self.enroll_prompt is not None and self.enroll_prompt.poll() is None:
            note = "确认窗口已经开着"
        elif enroll_window_open():
            note = "登记窗口已经开着"
        elif now - self.enroll_prompt_at < 3:
            note = "刚弹过确认窗口"
        else:
            self.enroll_prompt = launch_enroll_prompt()
            if self.enroll_prompt is None:
                req.respond_with_protocol_error(0x82)
                self.log("enroll_request_reject", device=device, note="弹不出确认窗口")
                return
            self.enroll_prompt_at = now
            note = "弹出了确认窗口"
        req.respond()
        self.log("enroll_request", device=device, note=note)

    async def on_write_report(self, args, context=None):
        dev_id, generation = self.request_context(args, context)
        self.mark("report:get_request")
        req = await args.get_request_async()
        if req is None:
            return
        data = bytes(req.value)
        respond = req.option == GattWriteOption.WRITE_WITH_RESPONSE
        if req.offset != 0:
            if respond:
                req.respond_with_protocol_error(0x07)
            return
        if self.authenticated_reports is not None:
            self.alive_at = time.time()  # 未登记手机仍可维持链路以完成离线导入
            if len(data) in (6, 7):
                if respond:
                    req.respond()
                return  # 不能进入 Judge，也不能建立认证证明
            accepted = False
            if (respond and dev_id in self.clients and dev_id not in self.disconnected_links
                    and generation == self.link_generations.get(dev_id, 0)):
                seq = AuthenticatedReportProtocol.sequence(data)
                pending = self.pending_notifications.get(seq)
                if pending is not None:
                    # REPORT 可能抢在 NotifyValueAsync 的完成回调之前抵达；等实际发送结果，不能先 ACK。
                    try:
                        await asyncio.wait_for(asyncio.shield(pending), timeout=1)
                    except asyncio.TimeoutError:
                        pass
                if generation == self.link_generations.get(dev_id, 0):
                    try:
                        data = self.authenticated_reports.accept(
                            data, dev_id, self.authenticated_sent.get((seq, dev_id, generation)),
                            time.monotonic(), self.judge.current_interval)
                        accepted = True
                    except ReportAuthenticationError:
                        pass
            if not accepted:
                self.report_reject_count += 1
                now = time.monotonic()
                if now - self.last_report_reject_log >= 30:
                    self.log("report_auth_reject", note=f"拒绝 {self.report_reject_count} 条认证报告；未用于判断")
                    self.last_report_reject_log, self.report_reject_count = now, 0
                if respond:
                    req.respond_with_protocol_error(0x08)  # Insufficient Authorization
                return
        if len(data) < struct.calcsize(REPORT_FMT):
            if respond:
                req.respond_with_protocol_error(0x0D)
            self.log("bad_report", note="报告长度错误")
            return
        if respond:
            self.mark("report:respond")
            req.respond()  # 签名、序号、连接代际均已核对后才 ACK
        seq, rssi, state = struct.unpack_from(REPORT_FMT, data)
        proto = data[struct.calcsize(REPORT_FMT)] if len(data) > struct.calcsize(REPORT_FMT) else 1
        if proto != self.app_proto:
            self.log("app_proto", note=f"App 协议版本 {self.app_proto} → {proto}" + ("（可以休眠）" if proto >= 2 else ""))
            self.app_proto = proto
        t = self.now()
        sent = self.sent.get(seq)
        latency = (t - sent) * 1000 if sent is not None else None
        row = (t, rssi, state, latency)
        self.reports.append(row + (dev_id,) if self.authenticated_reports is not None else row)
        if len(self.reports) > 20000:
            del self.reports[:-20000]
        self.last = (rssi, state, latency)
        self.last_report_wall = self.alive_at = time.time()
        self.log("report", seq=seq, rssi=rssi, phone_state=state,
                 latency_ms="" if latency is None else f"{latency:.0f}",
                 device=self.clients.get(dev_id, ""), note="auth=v3" if self.authenticated_reports is not None else "")

    def heartbeat_payload(self, next_within=None):
        if next_within is None:
            next_within = self.judge.current_interval
        return struct.pack(HEARTBEAT_FMT, self.seq, self.judge.host_state(), self.judge.prompt_id,
                           min(255, math.ceil(next_within)))

    def heartbeat_gate(self, now):
        """
        手机几秒没回报告就停发心跳，直到它自己有回应（报告、重新订阅、读 INFO）。
        实测往一条正在断开或已经断开的连接上发心跳，这次调用可能永远不完成：手机走出范围后
        每秒照发时卡过两次，停发 20 秒后"试探"发一次又卡了两次。所以不试探。
        手机那边不会因此卡住：App 5 秒收不到心跳会自己重连，重连时读 INFO，这里就恢复了。
        订阅着的手机底层链路都报了断开也马上停：实测卡死常常是链路断开后不到 1 秒
        （离上次报告还不到 3 秒）又发了一次心跳，这次一直不完成。链路连回来（或重新订阅）才恢复。
        有几台手机时只要还有一台连着就照发，notify_value_async 仍会发给断开的那台。
        """
        quiet = now - self.alive_at
        linked = any(dev not in self.disconnected_links for dev in self.clients)
        if linked and quiet <= self.judge.report_timeout():
            if self.hb_paused:
                self.hb_paused = False
                self.say("手机有回应了，恢复每秒心跳")
                self.log("hb_resume")
            return True
        if not self.hb_paused:
            self.hb_paused = True
            if linked:
                self.say(f"手机 {quiet:.0f} 秒没回报告，停发心跳，等它回应")
                self.log("hb_pause", note=f"{quiet:.1f}s 没回报告")
            else:
                self.say("手机底层链路断开了，停发心跳，等它连回来")
                self.log("hb_pause", note="底层链路断开")
        return False

    async def heartbeat_loop(self):
        sched = HeartbeatSchedule(self.args.interval)
        while True:
            await asyncio.sleep(0.25)
            now = time.time()
            interval = self.judge.heartbeat_interval()
            if not sched.due(now, interval):
                continue
            if not self.clients or not self.heartbeat_gate(now):
                continue
            if interval != sched.announced:
                med = self.judge.last_med
                self.log("hb_rate", rssi=f"{med:.0f}" if med is not None else "",
                         note=f"心跳间隔 {sched.announced:g}s → {interval:g}s"
                              + ("（休眠）" if interval >= self.args.dormant_interval else ""))
            sched.sent(now, interval)
            self.judge.current_interval = interval
            self.seq = (self.seq + 1) & 0xFFFFFFFF
            self.sent[self.seq] = self.now()
            self.sent.pop((self.seq - 600) & 0xFFFFFFFF, None)
            self.notify_since = time.time()
            sent_at = time.monotonic()
            generations = {dev: self.link_generations.get(dev, 0) for dev in self.clients}
            pending = None
            if self.authenticated_reports is not None:
                pending = asyncio.get_running_loop().create_future()
                self.pending_notifications[self.seq] = pending
            self.mark("notify")
            try:
                results = await self.hb.notify_value_async(to_buffer(self.heartbeat_payload(interval)))
                if self.authenticated_reports is not None:
                    cutoff = time.monotonic() - max(10, self.maximum_interval + 5)
                    self.authenticated_sent = {k: v for k, v in self.authenticated_sent.items() if v >= cutoff}
                    for result in results:
                        if result.status != GattCommunicationStatus.SUCCESS:
                            continue
                        dev = result.subscribed_client.session.device_id.id
                        generation = generations.get(dev)
                        if generation is not None and generation == self.link_generations.get(dev, 0):
                            self.authenticated_sent[(self.seq, dev, generation)] = sent_at
            finally:
                if pending is not None:
                    pending.set_result(None)
                    self.pending_notifications.pop(self.seq, None)
            # 记下每次发心跳花了多久，用来定看门狗的 --stuck 阈值
            dt = (time.time() - self.notify_since) * 1000
            self.notify_since = None
            self.notify_ms.append(dt)
            ok = sum(1 for r in results if r.status == GattCommunicationStatus.SUCCESS)
            self.log("hb", seq=self.seq, note=f"ok={ok}/{len(results)} dt={dt:.0f}ms")

    # ------------------------------------------------ 主线程：状态（蓝牙线程卡住占着 GIL 时这里也会停）

    def stuck_for(self):
        now = time.time()
        stalled = now - self.bt_tick
        if self.notify_since is not None:
            stalled = max(stalled, now - self.notify_since)
        return stalled

    def status(self):
        t = self.now()
        recent = [r for r in self.reports if r[0] > t - 10]
        if not self.clients:
            line = "等待手机订阅心跳…（Windows 只在订阅后才知道手机连上了）"
        elif self.last is None:
            line = f"已连接 {len(self.clients)} 台，还没收到信号报告"
        else:
            rssi, state, latency = self.last
            lat = "-" if latency is None else f"{latency:.0f}ms"
            line = (f"已连接 | 最近 10 秒收到 {len(recent)} 次报告 | 信号 {rssi} | "
                    f"手机判断 {PHONE_STATE.get(state, state)} | 往返延迟 {lat}")
        line += " | " + self.judge.summary()
        if self.adv_bad_since is not None:
            line += f" | ⚠ 广播没开 {time.time() - self.adv_bad_since:.0f} 秒"
        stalled = self.stuck_for()
        if stalled > 3:
            line += f" | ⚠ 蓝牙调用已 {stalled:.0f} 秒没返回"
        self.say(line)

    def stop(self, reason=""):
        if self.loop is not None:
            try:
                asyncio.run_coroutine_threadsafe(self.stop_advertising(), self.loop).result(timeout=3)
            except Exception:
                self.say("停止广播没有响应，直接退出")
        self.on_disconnected_all()
        self.log("stop", note=reason)
        with self.lock:
            self.file.close()
        self.summary()

    def summary(self):
        print()
        print(f"本次运行到 {fmt_t(self.now())}，连接时长 {fmt_t(self.connected_total)}，断开 {self.disconnects} 次")
        if self.reports:
            times = [r[0] for r in self.reports]
            gaps = [b - a for a, b in zip(times, times[1:])]
            lats = [r[3] for r in self.reports if r[3] is not None]
            rate = len(self.reports) / self.connected_total if self.connected_total else 0
            print(f"收到报告 {len(self.reports)} 次，连接期间平均 {rate:.2f} 次/秒"
                  + (f"，最长间隔 {max(gaps):.1f}s" if gaps else ""))
            if lats:
                print(f"往返延迟：中位 {statistics.median(lats):.0f}ms，最长 {max(lats):.0f}ms")
            valid = [r[1] for r in self.reports if r[1] != 127]
            if valid:
                print(f"信号：中位 {statistics.median(valid):.0f}，最强 {max(valid)}，最弱 {min(valid)}")
        if self.notify_ms:
            ms = sorted(self.notify_ms)
            print(f"发心跳耗时：中位 {statistics.median(ms):.0f}ms，"
                  f"99% 在 {ms[int(len(ms) * 0.99)]:.0f}ms 以内，最长 {ms[-1]:.0f}ms")
        print(f"日志：{self.path}", flush=True)


def run_worker(args):
    peer = Peer(args)
    threading.Thread(target=peer.run_bt, name="bluetooth", daemon=True).start()
    if not peer.started.wait(20):
        peer.say("启动蓝牙服务 20 秒没完成")
        os._exit(1)
    if peer.start_error:
        print(f"启动失败：{peer.start_error}", flush=True)
        os._exit(EXIT_RADIO if "RADIO_NOT_AVAILABLE" in str(peer.start_error) else 1)

    if args.restart == 0:
        print(f"服务 UUID：{SERVICE_UUID}")
        if args.secure:
            print("要求加密：没配对过的 iPhone 第一次连接时会弹「蓝牙配对请求」，点「配对」；电脑右下角如果弹出配对提示，也要允许。")
        else:
            print("不加密（--plain）：电脑每次重新广播都会换地址，App 要手动忘记这台电脑再重新添加。")
        print("等待 iPhone 连接。没有 App 时可以先用 iPhone 上的 LightBlue 或 nRF Connect 测：")
        print("  扫描 → 找到带上面服务 UUID 的设备 → 连接 → 订阅 heartbeat 特征值，应该每秒收到一次通知。", flush=True)
    else:
        peer.say(f"已自动重启（第 {args.restart} 次），等待手机重新订阅")

    next_status = time.monotonic() + 5
    end = time.monotonic() + args.duration if args.duration else None
    reason = ""
    try:
        while True:
            time.sleep(1)
            if time.monotonic() >= next_status:
                peer.status()
                next_status += 5
            if end and time.monotonic() >= end:
                break
            if peer.health is not None and peer.health.buf[STOP_AT]:
                reason = "守护进程请求退出"
                break
    except KeyboardInterrupt:
        pass
    peer.stop(reason)
    sys.stdout.flush()
    os._exit(0)  # 蓝牙线程是 WinRT 的事件循环，直接结束进程最干净


def capture_stack(pid, out, n):
    """强制结束前用 py-spy 抓卡死现场，存到 <日志名>_stuck<n>.txt；py-spy 装在 .venv 里"""
    spy = os.path.join(os.path.dirname(sys.executable), "py-spy.exe")
    if not pid or not os.path.exists(spy):
        return "没有 py-spy，没抓现场"
    path = os.path.splitext(out)[0] + f"_stuck{n}.txt"
    try:
        r = subprocess.run([spy, "dump", "--pid", str(pid), "--native"], capture_output=True,
                           text=True, encoding="utf-8", errors="replace", timeout=20,
                           creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
        with open(path, "w", encoding="utf-8") as f:
            f.write(r.stdout + r.stderr)
    except Exception as e:
        return f"py-spy 失败：{e!r}"
    return f"现场 {os.path.basename(path)}"


def single_instance():
    """同一个用户只跑一份：两份会抢同一个蓝牙服务。返回锁的句柄，进程退出时系统自动释放"""
    k32 = ctypes.WinDLL("kernel32", use_last_error=True)
    k32.CreateMutexW.restype = ctypes.c_void_p
    k32.CreateMutexW.argtypes = [ctypes.c_void_p, ctypes.c_bool, ctypes.c_wchar_p]
    h = k32.CreateMutexW(None, False, "Local\\iphone-proximity-unlock-win-peer")
    if not h or ctypes.get_last_error() == 183:  # ERROR_ALREADY_EXISTS
        return None
    return h


def stop_event():
    """建（或打开）外面请求停止用的命名事件，手动复位、开始时没信号"""
    k32 = ctypes.WinDLL("kernel32", use_last_error=True)
    k32.CreateEventW.restype = ctypes.c_void_p
    k32.CreateEventW.argtypes = [ctypes.c_void_p, ctypes.c_bool, ctypes.c_bool, ctypes.c_wchar_p]
    k32.ResetEvent.argtypes = [ctypes.c_void_p]
    k32.WaitForSingleObject.argtypes = [ctypes.c_void_p, ctypes.c_uint32]
    k32.WaitForSingleObject.restype = ctypes.c_uint32
    h = k32.CreateEventW(None, True, False, STOP_EVENT)
    if h:
        k32.ResetEvent(h)  # 上一次 -Stop 的脚本可能还开着它
    return k32, h


def enroll_window_open():
    """本机登记窗口开着没有（开着时 helper 建了 ENROLL_WINDOW_EVENT，手动 manage.ps1 -Action Export 打开的也算）"""
    k32 = ctypes.WinDLL("kernel32", use_last_error=True)
    k32.OpenEventW.restype = ctypes.c_void_p
    k32.OpenEventW.argtypes = [ctypes.c_uint32, ctypes.c_bool, ctypes.c_wchar_p]
    k32.CloseHandle.argtypes = [ctypes.c_void_p]
    h = k32.OpenEventW(0x00100000, False, ENROLL_WINDOW_EVENT)  # SYNCHRONIZE
    if not h:
        return False
    k32.CloseHandle(h)
    return True


def launch_enroll_prompt():
    """另起 enroll_prompt.py 问用户要不要显示登记码，不卡蓝牙线程；起不来返回 None"""
    script = os.path.join(os.path.dirname(os.path.abspath(__file__)), "enroll_prompt.py")
    try:
        return subprocess.Popen([sys.executable, script],
                                creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
    except OSError:
        return None


def signal_enroll_window():
    """通知本机登记窗口 iPhone 已确认保存登记（窗口开着时才有这个事件）。窗口没开返回 False"""
    k32 = ctypes.WinDLL("kernel32", use_last_error=True)
    k32.OpenEventW.restype = ctypes.c_void_p
    k32.OpenEventW.argtypes = [ctypes.c_uint32, ctypes.c_bool, ctypes.c_wchar_p]
    k32.SetEvent.argtypes = [ctypes.c_void_p]
    k32.CloseHandle.argtypes = [ctypes.c_void_p]
    h = k32.OpenEventW(0x0002, False, ENROLL_WINDOW_EVENT)  # EVENT_MODIFY_STATE
    if not h:
        return False
    try:
        return bool(k32.SetEvent(h))
    finally:
        k32.CloseHandle(h)


def stop_requested(ev):
    k32, h = ev
    return bool(h) and k32.WaitForSingleObject(h, 0) == 0


def stop_worker(p, shm, timeout=8):
    """请工作进程正常退出（停广播、撤服务），等不到就强制结束。返回是不是正常退出的"""
    shm.buf[STOP_AT] = 1
    try:
        p.wait(timeout=timeout)
        return True
    except subprocess.TimeoutExpired:
        p.kill()
        p.wait()
        return False


def user_away():
    """人不在电脑前：锁着屏，或者 10 分钟没碰键盘鼠标"""
    idle = input_idle_seconds()
    return workstation_locked() or (idle is not None and idle >= 600)


def should_repair_adv(now, adv_bad_since, last_repair, away, args):
    """广播坏了超过 --adv-repair-after 秒、人不在、离上次修超过 --adv-repair-gap 秒"""
    return (args.adv_repair_after > 0 and adv_bad_since > 0
            and now - adv_bad_since >= args.adv_repair_after
            and now - last_repair >= args.adv_repair_gap and away)


def repair_radio(off_seconds):
    """
    关开一次蓝牙。实测：手机订阅着时电脑端的服务被撤掉，之后整台电脑的可连接广播都开不起来，
    只有关开蓝牙能恢复；电脑端还在跑的时候关开没用。所以要先停掉工作进程、关开，开了以后马上启动工作进程
    （不等：有的程序（比如某些手机互联软件）会在蓝牙打开约 4 秒后占住可连接广播）
    """
    try:
        import bt_toggle
        return asyncio.run(bt_toggle.toggle(off_seconds, settle=0)) == 0
    except Exception as e:
        print(f"关开蓝牙失败：{e!r}", flush=True)
        return False


class StallWatch:
    """
    守护进程判断工作进程卡死。电脑进了现代待机、进程被冻结时，守护进程和工作进程一起停（我们关屏触发的
    待机可能一冻好几个小时，只在每小时一次的维护唤醒时醒一下）；醒来时守护进程先转，看到时间戳一个小时没更新，
    就会误判卡死把工作进程杀掉，留下旧服务、弄坏广播。所以守护进程自己隔了好久才转一圈时，
    先给工作进程 grace 秒缓一缓，这期间不判卡死、不修广播；缓完还没动静才算真卡住
    """

    def __init__(self, stuck, grace=10.0, now=None):
        self.stuck, self.grace = stuck, grace
        self.last = time.time() if now is None else now
        self.grace_until = 0.0

    def tick(self, now):
        """每转一圈调一次；守护进程刚被冻结过就返回冻了几秒，否则 None"""
        gap, self.last = now - self.last, now
        if gap > self.stuck:
            self.grace_until = now + self.grace
            return gap
        return None

    def in_grace(self, now):
        return now < self.grace_until


def supervise(args, argv):
    if single_instance() is None:
        print("已经有一个电脑端在运行（可能是开机自启的那个），这个不再启动。", flush=True)
        return 0
    os.makedirs(args.log_dir, exist_ok=True)
    out = args.out or os.path.join(args.log_dir, datetime.now().strftime("peer_%Y%m%d_%H%M%S_win32.csv"))
    t0 = time.time()
    shm = shared_memory.SharedMemory(create=True, size=HEALTH_SIZE)
    ev = stop_event()
    restart, delay, radio_off = 0, 1, False
    last_repair = 0.0
    try:
        while True:
            # 给启动留 10 秒余量：建服务、开广播要一点时间
            shm.buf[:HEALTH_SIZE] = bytes(HEALTH_SIZE)
            struct.pack_into("d", shm.buf, 0, time.time() + 10)
            cmd = [sys.executable, os.path.abspath(__file__), *argv, "--worker", "--out", out,
                   "--t0", repr(t0), "--restart", str(restart), "--health", shm.name]
            started = time.time()
            p = subprocess.Popen(cmd)
            stalled = None
            watch = StallWatch(args.stuck)
            try:
                while True:
                    try:
                        rc = p.wait(timeout=1)
                        break
                    except subprocess.TimeoutExpired:
                        pass
                    now = time.time()
                    frozen = watch.tick(now)
                    if frozen is not None:
                        f, w = open_log(out)
                        log_row(w, t0, "supervisor_resume",
                                note=f"守护进程 {frozen:.0f}s 没转（电脑待机把进程冻结了），给工作进程 {watch.grace:g}s 缓一缓再判断卡死")
                        f.close()
                    stalled = now - struct.unpack_from("d", shm.buf, 0)[0]
                    if stalled > args.stuck and not watch.in_grace(now):
                        pid = struct.unpack_from("q", shm.buf, 8)[0]
                        op = bytes(shm.buf[16:OP_END]).split(b"\0")[0].decode(errors="replace") or "?"
                        print(f"—— 电脑端卡在 {op}，正在抓现场… ——", flush=True)
                        evidence = capture_stack(pid, out, restart + 1)
                        p.kill()
                        p.wait()
                        rc = None
                        break
                    if stop_requested(ev):
                        graceful = stop_worker(p, shm)
                        f, w = open_log(out)
                        log_row(w, t0, "supervisor_stop",
                                note="收到停止请求，" + ("工作进程已正常退出" if graceful else "工作进程没响应，强制结束"))
                        f.close()
                        return 0
                    adv_bad = struct.unpack_from("d", shm.buf, OP_END)[0]
                    # 刚从冻结里醒来时不修：多半是待机里的维护唤醒，修到一半又被冻住，关开蓝牙会拖上好几个小时
                    if not watch.in_grace(now) and should_repair_adv(now, adv_bad, last_repair, user_away(), args):
                        graceful = stop_worker(p, shm)
                        rc = "repair"
                        break
            except KeyboardInterrupt:
                try:
                    return p.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    p.kill()  # 卡住的工作进程收不到 Ctrl+C
                    return 1
            # 只有正常结束（Ctrl+C、到了 --duration）才退出；其他情况都重启，开机自启时没人看着
            if rc == 0:
                return 0
            if rc == "repair":
                f, w = open_log(out)
                log_row(w, t0, "adv_repair", note=f"广播 ABORTED 已 {time.time() - adv_bad:.0f}s、人不在电脑前："
                                                  + ("工作进程已正常退出" if graceful else "工作进程没响应，强制结束")
                                                  + "，关开一次蓝牙")
                f.close()
                print(f"—— 广播坏了 {(time.time() - adv_bad) / 60:.0f} 分钟、人不在：关开一次蓝牙 ——", flush=True)
                ok = repair_radio(args.adv_repair_off)
                last_repair = time.time()
                f, w = open_log(out)
                log_row(w, t0, "adv_repair_done", note="关开完成" if ok else "关开失败")
                f.close()
                restart += 1
                continue  # 马上启动，晚几秒广播位置就被别的程序占了
            f, w = open_log(out)
            if rc is None:
                log_row(w, t0, "stuck", note=f"工作进程 {stalled:.1f}s 没有进展，卡在 {op}，守护进程强制结束；{evidence}")
                reason = f"电脑端卡住 {stalled:.0f} 秒，已强制结束"
            elif rc == EXIT_RADIO:
                if not radio_off:
                    log_row(w, t0, "radio_off", note="蓝牙关着或不可用，每 10 秒再试一次")
                reason = "蓝牙关着或不可用"
            else:
                log_row(w, t0, "worker_exit", note=f"工作进程意外退出，退出码 {rc}")
                reason = f"工作进程意外退出（退出码 {rc}）"
            f.close()
            if rc == EXIT_RADIO:
                delay = 10
                if not radio_off:
                    print(f"—— {reason}，每 10 秒再试一次，蓝牙打开后自动恢复 ——", flush=True)
                radio_off = True
            else:
                # 刚启动没多久又出问题，就逐渐拉长等待，免得一直重启
                delay = 2 if time.time() - started > 60 else min(delay * 2, 60)
                print(f"—— {reason}，{delay} 秒后自动重启（第 {restart + 1} 次）——", flush=True)
                radio_off = False
            restart += 1
            time.sleep(delay)
    finally:
        shm.close()
        shm.unlink()


if __name__ == "__main__":
    # Windows 重定向输出默认可能是 GBK；状态里的 Unicode 警告符号不能让后台进程崩溃。
    for stream in (sys.stdout, sys.stderr):
        if stream is not None and hasattr(stream, "reconfigure"):
            stream.reconfigure(encoding="utf-8", errors="backslashreplace")
    p = argparse.ArgumentParser(description="原型 v0 电脑端（Windows）")
    p.add_argument("--interval", type=float, default=1.0, help="心跳间隔秒数，默认 1")
    p.add_argument("--duration", type=float, default=0, help="运行多少秒后自动退出，默认一直运行")
    p.add_argument("--out", help="日志 CSV 路径，默认 <--log-dir>/peer_日期_时间_win32.csv")
    p.add_argument("--log-dir", default=".", help="日志放在哪个文件夹，默认当前文件夹；开机自启用的是 logs")
    p.add_argument("--plain", action="store_true",
                   help="不加密、不配对。电脑每次重新广播都换地址，iPhone 会当成新设备，要手动忘记再添加")
    p.add_argument("--stuck", type=float, default=5,
                   help="蓝牙调用卡住多少秒就自动重启电脑端，默认 5（实测发心跳 99%% 在 16ms 以内）")
    g = p.add_argument_group("电脑端判断人在不在、锁屏、请手机提示解锁")
    g.add_argument("--no-auto-unlock", action="store_true", help="本次不启用已登记的自动解锁，保留原有锁屏和提示行为")
    g.add_argument("--no-lock", dest="lock", action="store_false",
                   help="只记录本来会怎么做（would_lock / would_prompt），不真的锁屏")
    g.add_argument("--screen", choices=["dim", "off", "keep"], default="off",
                   help="自己锁屏 2 秒后屏幕怎么处理：off 真关屏（默认，电脑会进现代待机，有电源请求时电脑端照常跑）；"
                        "dim 亮度调到 0、回来恢复；keep 不动")
    g.add_argument("--keep-display", dest="screen", action="store_const", const="keep", help=argparse.SUPPRESS)
    g.add_argument("--awake-minutes", type=float, default=30,
                   help="锁屏后多少分钟内用电源请求让电脑端在待机里接着跑（没有的话用电池时进待机就被暂停），默认 30，0 表示不管")
    g.add_argument("--active", type=float, default=30, help="多少秒内有键盘鼠标操作就算在电脑前，默认 30")
    g.add_argument("--idle-lock", type=float, default=60, help="多少秒没有操作才可能判定离开，默认 60")
    g.add_argument("--far-th", type=float, default=-80, help="信号中位数低于它算弱，默认 -80")
    g.add_argument("--far-for", type=float, default=10, help="信号弱持续多少秒算离开，默认 10")
    g.add_argument("--lost-for", type=float, default=10, help="手机失联多少秒算离开，默认 10")
    g.add_argument("--cancel-after", type=float, default=60,
                   help="提示解锁以后，手机持续走远（失联或信号弱）多少秒才撤销提示，默认 60；锁屏期间也要走远这么久才会在回来时提示")
    g.add_argument("--approach-th", type=float, default=-72,
                   help="判定离开后，信号中位数回到它以上、并持续 --approach-for 秒，就提示解锁，默认 -72")
    g.add_argument("--approach-for", type=float, default=3, help="见 --approach-th，默认 3 秒")
    g.add_argument("--approach-gain", type=float, default=10,
                   help="还要比走远时的信号强多少 dB 才提示、才退出休眠，默认 10")
    g.add_argument("--ref-window", type=float, default=900,
                   help="「走远时的信号」看最近多少秒的报告（不含最近 30 秒，取信号强的那一头），默认 900")
    g.add_argument("--slow-th", type=float, default=-75,
                   help="没人在用电脑、信号中位数低于它时，心跳放慢到 --slow-interval，默认 -75")
    g.add_argument("--slow-interval", type=float, default=3, help="见 --slow-th，默认 3 秒")
    g.add_argument("--dormant-after", type=float, default=1800,
                   help="锁着并且多少秒没碰键盘鼠标就休眠（不看信号），默认 1800（30 分钟）")
    g.add_argument("--dormant-interval", type=float, default=30, help="休眠时心跳间隔，默认 30 秒")
    g.add_argument("--freeze-away", type=float, default=60,
                   help="电脑端被待机冻住多少秒、醒来时锁着（显示器亮了），就当作手机走远过、回来请提示，默认 60")
    g.add_argument("--startup-grace",type=float, default=30, help="电脑端启动后多少秒内不算手机失联，默认 30")
    p.add_argument("--adv-repair-after", type=float, default=1800,
                   help="协议广播坏了（ABORTED）多少秒、并且人不在电脑前，就停掉工作进程、关开一次蓝牙修，默认 1800；0 表示不修")
    p.add_argument("--adv-repair-gap", type=float, default=10800, help="两次修之间至少隔多少秒，默认 10800（3 小时）")
    p.add_argument("--adv-repair-off", type=float, default=5, help="修的时候蓝牙关多少秒，默认 5")
    p.add_argument("--no-beacon", dest="beacon", action="store_false",
                   help="不发 iBeacon（默认发：App 被划掉后，人离开时 iOS 会靠它把 App 拉起来）")
    p.add_argument("--beacon-minor", type=int, default=1, help="iBeacon 的 minor，默认 1")
    p.add_argument("--pause-after", type=float, default=3,
                   help="多少秒没收到报告就停发心跳，等手机自己回应，默认 3（实测正常间隔 99%% 在 1.3 秒以内）")
    p.add_argument("--secure", action="store_true", help=argparse.SUPPRESS)  # 现在默认就加密，留着只为兼容旧命令
    # 下面是守护进程传给工作进程的参数
    p.add_argument("--worker", action="store_true", help=argparse.SUPPRESS)
    p.add_argument("--t0", type=float, default=0, help=argparse.SUPPRESS)
    p.add_argument("--restart", type=int, default=0, help=argparse.SUPPRESS)
    p.add_argument("--health", help=argparse.SUPPRESS)
    p.add_argument("--simulate-stuck", type=float, default=0, help=argparse.SUPPRESS)  # 测试看门狗用
    args = p.parse_args()
    args.secure = not args.plain
    if sys.stdout is None:
        # 用 pythonw.exe 在后台跑（开机自启）时没有控制台，打印的内容写到文件里，出问题时能查
        os.makedirs(args.log_dir, exist_ok=True)
        console = open(os.path.join(args.log_dir, "win_peer_console.log"), "a", encoding="utf-8", buffering=1)
        sys.stdout = sys.stderr = console
        print(f"===== {datetime.now():%Y-%m-%d %H:%M:%S} {'工作进程' if args.worker else '守护进程'}启动，"
              f"PID {os.getpid()} =====", flush=True)
    if args.worker:
        run_worker(args)
    else:
        try:
            sys.exit(supervise(args, sys.argv[1:]))
        except KeyboardInterrupt:
            pass
