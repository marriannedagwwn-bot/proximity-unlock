"""win_peer 的 Judge：重启后照样锁（phone_known）、手机走后只锁一次（lock_hold）、请提示时恢复亮度、手动锁屏后调暗。
规则见 docs/protocol.md「电脑怎么判断人在不在」，和 Mac 端 JudgeTests 对应。"""
import csv
import importlib
import sys
import tempfile
import time
import unittest
from datetime import datetime
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock, patch


class FakeAwake:
    def __init__(self):
        self.on = False
        self.calls = []

    def set(self, on):
        self.calls.append(on)
        self.on = on
        return True


class FakeDisplay:
    def __init__(self):
        self.on = True
        self.registered = True


class JudgeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        prototype = str(Path(__file__).resolve().parents[1] / "prototype")
        with patch.object(sys, "path", [prototype, *sys.path]):
            cls.module = importlib.import_module("win_peer")

    def setUp(self):
        m = self.module
        self.folder = self.enterContext(tempfile.TemporaryDirectory())
        self.idle = self.enterContext(patch.object(m, "input_idle_seconds", return_value=120))
        self.locked = self.enterContext(patch.object(m, "workstation_locked", return_value=False))
        self.lock = self.enterContext(patch.object(m, "lock_workstation", return_value=True))
        self.get_brightness = self.enterContext(patch.object(m, "get_brightness", return_value=67))
        self.set_brightness = self.enterContext(patch.object(m, "set_brightness", return_value=True))
        self.enterContext(patch.object(m, "KeepAwake", FakeAwake))
        self.enterContext(patch.object(m, "DisplayState", FakeDisplay))
        self.enterContext(patch.object(m.Peer, "say"))

    def write_log(self, name, *rows):
        """rows: (离现在几秒, event, note)；report 行带信号"""
        with open(Path(self.folder) / name, "w", newline="", encoding="utf-8-sig") as f:
            w = csv.DictWriter(f, fieldnames=self.module.CSV_FIELDS)
            w.writeheader()
            for ago, event, note in rows:
                row = dict(time=datetime.fromtimestamp(time.time() - ago).isoformat(timespec="milliseconds"),
                           t=0, event=event, note=note)
                if event == "report":
                    row.update(seq=1, rssi=-50, phone_state=1)
                w.writerow(row)

    def worker(self, backend=None, restart=0):
        m = self.module
        args = SimpleNamespace(
            t0=time.time() - 100, health=None, out=str(Path(self.folder) / "peer_20261024_220000_win32.csv"),
            lock=True, no_auto_unlock=backend is None, interval=1, slow_interval=3, dormant_interval=30,
            restart=restart, ref_window=900, pause_after=3, startup_grace=30, far_th=-80, far_for=10,
            lost_for=10, active=30, idle_lock=60, awake_minutes=30, screen="dim", approach_th=-72,
            approach_gain=10, approach_for=3, cancel_after=60, dormant_after=1800, slow_th=-75,
            freeze_away=60)
        with patch.object(m, "load_backend", return_value=backend):
            w = m.Peer(args)
        self.addCleanup(w.file.close)
        w.judge.started = time.time() - 100  # 过了启动后不算失联的 30 秒
        return w

    def logged(self, w):
        with open(w.path, newline="", encoding="utf-8-sig") as f:
            return [(r["event"], r["note"]) for r in csv.DictReader(f)]

    def events(self, w):
        return [e for e, _ in self.logged(w)]

    @staticmethod
    def phone_gone(w, seconds=20):
        w.clients = {}
        w.judge.lost_since = time.time() - seconds

    @staticmethod
    def phone_back(w, rssi=-50):
        w.clients = {"phone": "Phone"}
        w.last_report_wall = time.time()
        w.reports = [(w.now() - i, rssi, 1, 10) for i in range(5, -1, -1)]
        w.judge.lost_since = None
        w.judge.near_since = time.time() - 5

    # ---------------------------------------------------------------- phone_known

    def test_report_in_previous_log_lets_lost_phone_count_as_away_after_restart(self):
        self.write_log("peer_20261024_080000_win32.csv", (3600, "report", ""))
        w = self.worker()
        self.assertTrue(w.judge.phone_known)
        note = dict(self.logged(w))["phone_known"]
        self.assertRegex(note, r"last=\d+")
        self.assertIsNone(w.last_report_wall)  # 这次启动以来还没收到报告
        self.phone_gone(w)
        w.judge.update()
        self.lock.assert_called_once()
        self.assertIn("lock", self.events(w))

    def test_without_recent_report_lost_phone_still_does_not_lock(self):
        self.write_log("peer_20261010_080000_win32.csv", (8 * 86400, "report", ""))
        w = self.worker()
        self.assertFalse(w.judge.phone_known)
        self.assertNotIn("phone_known", self.events(w))
        self.phone_gone(w)
        w.judge.update()
        self.lock.assert_not_called()

    def test_phone_known_line_carries_over_restarts_without_reports(self):
        last = int(time.time() - 7200)
        self.write_log("peer_20261024_080000_win32.csv", (3600, "phone_known", f"上次收到手机报告是 … last={last}"))
        w = self.worker()
        self.assertTrue(w.judge.phone_known)
        self.assertIn(f"last={last}", dict(self.logged(w))["phone_known"])

    def test_enrolled_phone_is_known_without_any_log(self):
        backend = Mock(key_id=0x78563412, secret=bytes(range(32)))
        backend.available.return_value = True
        w = self.worker(backend=backend)
        self.assertTrue(w.judge.phone_known)
        self.assertIn("登记过解锁的手机", dict(self.logged(w))["phone_known"])

    def test_corrupted_log_rows_do_not_break_startup(self):
        # 守护进程和工作进程同时写日志撞在一起，留下半个汉字，之后每次启动读到这里就崩
        self.write_log("peer_20261024_080000_win32.csv", (3600, "report", ""))
        self.write_log("peer_20261024_220000_win32.csv", (100, "report", ""), (90, "lock", ""))
        broken = "程冻结了），给工作进程 10s\r\n".encode("utf-8")[2:]
        for name in ("peer_20261024_080000_win32.csv", "peer_20261024_220000_win32.csv"):
            with open(Path(self.folder) / name, "ab") as f:
                f.write(broken + b"not-a-time,0,lock,,,,,,\r\n" + b"not-a-time,0,report,1,-50,1,,,\r\n")
        w = self.worker(restart=1)
        self.assertTrue(w.judge.phone_known)
        self.assertIsNotNone(w.judge.away_at)  # 接上了 90 秒前那次判定离开，坏的那行 lock 跳过

    # ---------------------------------------------------------------- 手机走后只锁一次

    def test_unlocked_before_phone_returns_holds_lock_until_phone_is_near(self):
        w = self.worker()
        w.last_report_wall = time.time() - 30  # 这次启动以来收到过报告
        self.phone_gone(w)
        w.judge.update()                      # 离开 → 锁
        self.locked.return_value = True
        w.judge.update()                      # 看到锁上了
        self.locked.return_value = False
        self.idle.return_value = 0            # 远程解开、远程操作
        w.judge.update()
        self.assertTrue(w.judge.hold_lock)
        self.assertIn("lock_hold", self.events(w))
        self.idle.return_value = 120          # 停下来不动了
        w.judge.update()
        w.judge.update()
        self.lock.assert_called_once()        # 没有再锁
        self.assertEqual(self.events(w).count("lock_skip"), 1)
        self.phone_back(w)
        w.judge.update()
        self.assertFalse(w.judge.hold_lock)
        self.assertIn("lock_resume", self.events(w))

    def test_unlock_with_phone_back_does_not_hold(self):
        w = self.worker()
        w.last_report_wall = time.time() - 30
        self.phone_gone(w)
        w.judge.update()
        self.locked.return_value = True
        w.judge.update()
        self.phone_back(w)                    # 手机回来了，再解锁（自动解锁或手动）
        self.locked.return_value = False
        w.judge.update()
        self.assertIn("back", self.events(w))
        self.assertFalse(w.judge.hold_lock)
        self.assertNotIn("lock_hold", self.events(w))

    def test_hold_carries_over_restart(self):
        self.write_log("peer_20261024_080000_win32.csv", (100, "report", ""),
                       (90, "lock", ""), (60, "lock_hold", "手机还没回来就被解开了"))
        w = self.worker()
        self.assertTrue(w.judge.hold_lock)
        self.assertIn("接上前一个进程", dict(self.logged(w))["lock_hold"])

    def test_resumed_hold_is_not_carried_over(self):
        self.write_log("peer_20261024_080000_win32.csv", (60, "lock_hold", ""), (30, "lock_resume", ""))
        self.assertFalse(self.worker().judge.hold_lock)

    # ---------------------------------------------------------------- 守护进程看门狗

    def test_stall_watch_gives_grace_after_supervisor_was_frozen(self):
        watch = self.module.StallWatch(stuck=5, grace=10, now=1000)
        self.assertIsNone(watch.tick(1001))          # 正常每秒转一圈
        self.assertFalse(watch.in_grace(1001))
        self.assertEqual(watch.tick(4601), 3600)     # 待机里冻了一小时，醒来先转
        self.assertTrue(watch.in_grace(4601))        # 这时工作进程的时间戳也是一小时前的，先不判卡死
        self.assertIsNone(watch.tick(4602))
        self.assertTrue(watch.in_grace(4610.9))
        self.assertFalse(watch.in_grace(4611))       # 缓完还没动静才算真卡住

    def test_stall_watch_short_gaps_do_not_open_grace(self):
        watch = self.module.StallWatch(stuck=5, grace=10, now=0)
        for now in (1, 2.5, 7.4):                    # 慢一点的转圈（最多 stuck 秒）照常判断
            self.assertIsNone(watch.tick(now))
            self.assertFalse(watch.in_grace(now))

    # ---------------------------------------------------------------- 屏幕

    def test_prompt_restores_brightness_and_cancel_dims_again(self):
        w = self.worker()
        self.locked.return_value = True
        w.judge.locked = True
        w.judge.away_at = time.time() - 300
        w.judge.armed = w.judge.seen_locked = True
        w.judge.saved_brightness = 67
        self.phone_back(w)
        w.judge.update()
        self.assertTrue(w.judge.prompting)
        self.set_brightness.assert_called_once_with(67)
        undim = [n for e, n in self.logged(w) if e == "undim"]
        self.assertEqual(len(undim), 1)
        self.assertIn("请手机提示解锁", undim[0])
        self.phone_gone(w, seconds=100)       # 又走远了 → 撤销提示 → 再调暗
        w.judge.update()
        self.assertIn("prompt_cancel", self.events(w))
        w.judge.update()
        self.set_brightness.assert_called_with(0)
        self.assertEqual(w.judge.saved_brightness, 67)
        self.assertEqual(self.events(w)[-1], "dim")

    def test_any_lock_keeps_peer_running_before_judged_away(self):
        w = self.worker()
        w.clients = {"phone": "Phone"}
        w.last_report_wall = time.time()      # 手机还连着
        self.idle.return_value = 3            # 刚按了 Win+L，人还没走
        self.locked.return_value = True
        w.judge.update()
        self.assertIsNone(w.judge.away_at)
        self.assertEqual(w.judge.awake.calls, [True])
        self.assertIn("锁屏了", dict(self.logged(w))["keep_awake"])
        self.get_brightness.assert_not_called()  # 屏幕还是判定离开以后才处理
        self.assertNotIn("display_off", self.events(w))
        w.judge.awake_until = time.time() - 1  # 锁满 --awake-minutes：放开，一直锁着也不再开
        w.judge.update()
        w.judge.update()
        self.assertEqual(w.judge.awake.calls, [True, False])
        self.assertIn("锁屏超过", dict(self.logged(w))["allow_sleep"])
        self.locked.return_value = False      # 解锁以后再锁，重新开
        w.judge.update()
        self.locked.return_value = True
        w.judge.update()
        self.assertEqual(w.judge.awake.calls, [True, False, True])

    def test_manual_lock_then_phone_leaves_keeps_awake_and_dims(self):
        w = self.worker()
        w.last_report_wall = time.time() - 30
        self.locked.return_value = True       # 用户自己按了 Win+L
        self.lock.side_effect = AssertionError("本来就锁着，不该再锁")
        self.phone_gone(w)
        w.judge.update()
        lock_note = dict(self.logged(w))["lock"]
        self.assertIn("本来就锁着", lock_note)
        self.assertEqual(w.judge.awake.calls, [True])
        self.assertIn("keep_awake", self.events(w))
        self.set_brightness.assert_called_once_with(0)
        self.assertEqual(w.judge.saved_brightness, 67)

    # ---------------------------------------------------------------- 判定离开不等于走远过

    @staticmethod
    def signal(w, rssi, seconds):
        """最近 seconds 秒每秒一条报告，信号 rssi；接在已有的报告后面"""
        w.clients = {"phone": "Phone"}
        w.last_report_wall = time.time()
        w.reports = [r for r in w.reports if r[0] < w.now() - seconds] + \
                    [(w.now() - i, rssi, 1, 10) for i in range(seconds - 1, -1, -1)]
        w.judge.lost_since = None

    def test_brief_dip_while_locked_does_not_prompt(self):
        # 屏保早就锁了、手机在别的房间，信号跌到 -86 十几秒又回到 -70：判定离开（本来就锁着），但还不算走远过。
        # 原来判定离开那一刻就算走远过，「强 10 dB」被跳过，回到 -72 就自动解锁了，其实没人用
        w = self.worker()
        self.locked.return_value = True
        self.signal(w, -75, 600)
        self.signal(w, -86, 15)
        w.judge.weak_since = time.time() - 15
        w.judge.update()
        self.assertIn("本来就锁着", dict(self.logged(w))["lock"])
        self.assertFalse(w.judge.armed)
        self.signal(w, -70, 30)
        w.judge.near_since = time.time() - 5
        w.judge.update()
        self.assertNotIn("prompt", self.events(w))
        self.assertEqual(w.judge.host_state(), 2)
        self.signal(w, -88, 90)               # 这次真走远了
        w.judge.weak_since = time.time() - 90
        w.judge.update()
        self.assertTrue(w.judge.armed)
        self.signal(w, -60, 8)
        w.judge.near_since = time.time() - 5
        w.judge.update()
        self.assertIn("比走远时（-88）", dict(self.logged(w))["prompt"])

    def test_brief_disconnect_while_locked_does_not_prompt(self):
        # 手机在屋里（-72），连接超时断了十几秒又连回：判定离开（手机失联），但没走远满 60 秒，连回来不提示
        w = self.worker()
        w.last_report_wall = time.time() - 15
        self.locked.return_value = True
        self.phone_gone(w, seconds=15)
        w.judge.update()
        self.assertIn("手机失联", dict(self.logged(w))["lock"])
        self.assertFalse(w.judge.armed)
        self.phone_back(w, rssi=-66)
        w.judge.update()
        self.assertNotIn("prompt", self.events(w))
        self.phone_gone(w, seconds=70)        # 这次断了 1 分多钟（出门）
        w.judge.update()
        self.assertTrue(w.judge.armed)
        self.phone_back(w, rssi=-66)
        w.judge.update()
        self.assertIn("prompt", self.events(w))

    # ---------------------------------------------------------------- 待机冻住

    @staticmethod
    def thaw(w, frozen=2341):
        """电脑端被待机冻住 frozen 秒、刚醒：上次判断是 frozen 秒前，手机还没连回来"""
        w.judge.last_update = time.time() - frozen
        w.clients = {}

    def test_frozen_while_walking_away_prompts_when_woken_locked(self):
        # 走开时合了盖，冻住前还没判定离开；按电源键醒来，锁着，手机马上连回
        w = self.worker()
        w.last_report_wall = time.time() - 2341
        self.locked.return_value = True
        self.thaw(w)
        w.judge.update()
        self.lock.assert_not_called()          # 本来就锁着，没判定离开
        self.assertTrue(w.judge.armed)
        self.assertIn("freeze_away", self.events(w))
        self.assertAlmostEqual(w.judge.ref_start, time.time() - 2341, delta=2)
        self.phone_back(w, rssi=-60)
        w.judge.update()
        self.assertTrue(w.judge.prompting)
        self.assertIn("之前一段没有报告", dict(self.logged(w))["prompt"])
        self.locked.return_value = False       # 自动解锁
        w.judge.update()
        self.assertIn("提示后", dict(self.logged(w))["back"])
        self.assertFalse(w.judge.armed)

    def test_maintenance_wake_with_display_off_waits_for_display(self):
        # 每小时一次的维护唤醒显示器不亮、盖子可能合着：手机在旁边也先不提示
        w = self.worker()
        self.locked.return_value = True
        w.judge.display.on = False
        self.thaw(w, frozen=3600)
        w.judge.update()
        self.assertFalse(w.judge.armed)
        self.assertIn("显示器没亮", dict(self.logged(w))["freeze_wait"])
        self.phone_back(w, rssi=-55)
        w.judge.update()
        self.thaw(w, frozen=600)               # 又冻住、又是维护唤醒：只记一次
        w.judge.update()
        self.assertFalse(w.judge.prompting)
        self.assertEqual(self.events(w).count("freeze_wait"), 1)
        w.judge.display.on = True              # 按了电源键
        self.phone_back(w, rssi=-55)
        w.judge.update()
        self.assertIn("freeze_away", self.events(w))
        self.assertTrue(w.judge.prompting)
        self.assertIn(datetime.fromtimestamp(time.time() - 3600).strftime("%H:%M"),
                      dict(self.logged(w))["freeze_away"])  # 从第一次冻住算起

    def test_short_gap_or_unlocked_wake_does_not_arm(self):
        w = self.worker()
        self.locked.return_value = True
        self.thaw(w, frozen=30)                # 没到 --freeze-away
        w.judge.update()
        self.locked.return_value = False
        self.thaw(w)                           # 醒来没锁（不用密码唤醒），不用解锁
        w.judge.update()
        self.assertFalse(w.judge.armed)
        self.assertIsNone(w.judge.frozen_since)
        self.assertNotIn("freeze_away", self.events(w))
        self.assertNotIn("freeze_wait", self.events(w))

    def test_manual_unlock_while_waiting_for_display_clears_freeze(self):
        w = self.worker()
        self.locked.return_value = True
        w.judge.display.on = False
        self.thaw(w)
        w.judge.update()
        self.assertIsNotNone(w.judge.frozen_since)
        self.locked.return_value = False       # 手动解开了
        w.judge.update()
        self.assertIsNone(w.judge.frozen_since)
        w.judge.display.on = True
        self.locked.return_value = True        # 之后再锁（Win+L，人还坐着）：不当作冻住过
        w.judge.update()
        self.assertFalse(w.judge.armed)
        self.assertNotIn("freeze_away", self.events(w))


if __name__ == "__main__":
    unittest.main()
