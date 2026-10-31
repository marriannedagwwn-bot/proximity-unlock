"""Windows GATT adapter boundaries with real v3 gates and fake WinRT requests.

No test starts Bluetooth, locks the workstation, accesses stored credentials, or
submits a password. The separate portable protocol tests run on every platform.
"""

import asyncio
import base64
import csv
import importlib
import json
import math
from pathlib import Path
import struct
import sys
import tempfile
import time
from datetime import datetime
from types import SimpleNamespace
import unittest
from unittest.mock import AsyncMock, Mock, patch


class FakeRequest:
    def __init__(self, value=b"", *, option=None, offset=0, on_success=None):
        self.value = value
        self.option = option
        self.offset = offset
        self.length = 512
        self.responses = []
        self.on_success = on_success

    def respond(self):
        if self.on_success:
            self.on_success()
        self.responses.append(("success", None))

    def respond_with_protocol_error(self, error):
        self.responses.append(("error", error))

    def respond_with_value(self, value):
        self.responses.append(("value", bytes(value)))


class FakeArgs:
    def __init__(self, device, request, *, wait=None):
        self.session = SimpleNamespace(device_id=SimpleNamespace(id=device))
        self.request = request
        self.wait = wait
        self.entered = asyncio.Event()

    async def get_request_async(self):
        self.entered.set()
        if self.wait is not None:
            await self.wait.wait()
        return self.request


@unittest.skipUnless(sys.platform == "win32", "Windows WinRT adapter integration")
class PeerAuthenticationTests(unittest.IsolatedAsyncioTestCase):
    @classmethod
    def setUpClass(cls):
        # win_peer is also an executable script and imports its sibling modules.
        prototype = str(Path(__file__).resolve().parents[1] / "prototype")
        with patch.object(sys, "path", [prototype, *sys.path]):
            cls.module = importlib.import_module("win_peer")
            cls.protocol = importlib.import_module("win_unlock_protocol")

    def setUp(self):
        m = self.module
        self.locked = self.enterContext(patch.object(m, "workstation_locked", return_value=True))
        self.enterContext(patch.object(m, "lock_workstation", side_effect=AssertionError("must not lock")))
        self.enterContext(patch.object(m, "to_buffer", side_effect=bytes))
        self.key = self.protocol.UnlockKey(0x78563412, bytes(range(32)))
        self.packet_counter = 0
        p = self.peer = m.Peer.__new__(m.Peer)
        p.args = SimpleNamespace(lock=True, interval=1, slow_interval=3, dormant_interval=30, screen="off")
        p.t0 = time.time() - 100
        p.seq = 0
        p.sent = {}
        p.authenticated_sent = {}
        p.pending_notifications = {}
        p.link_generations = {"trusted": 0, "other": 0}
        p.disconnected_links = set()
        p.clients = {"trusted": "Phone", "other": "Other phone"}
        p.reports = []
        p.report_nonce = bytes(range(16))
        p.maximum_interval = 30
        p.authenticated_reports = m.AuthenticatedReportGate(self.key, p.report_nonce, 30)
        p.unlock_gate = m.UnlockGate(self.key)
        p.lock_gate = m.LockGate(self.key, p.report_nonce, 30)
        p.unlock_failed = False
        p.unlock_backend = Mock(key_id=self.key.id, secret=self.key.secret)
        p.unlock_backend.available.return_value = True
        p.unlock_backend.unlock.return_value = False
        p.report_reject_count = 0
        p.last_report_reject_log = -math.inf
        p.enroll_prompt = None
        p.enroll_prompt_at = -math.inf
        p.alive_at = time.time()
        p.app_proto = 1
        p.connected_since = None
        p.connected_total = 0
        p.notify_ms = []
        p.judge = SimpleNamespace(current_interval=1, prompting=True, prompt_id=42,
                                  near_since=90, update=Mock(), host_state=lambda: 3,
                                  heartbeat_interval=lambda: 1, saved_brightness=None,
                                  display_off_at=None, restore_brightness=Mock())
        p.mark = Mock()
        p.log = Mock()
        p.say = Mock()

    def request(self, value=b"", **kwargs):
        kwargs.setdefault("option", self.module.GattWriteOption.WRITE_WITH_RESPONSE)
        return FakeRequest(value, **kwargs)

    @staticmethod
    def worker_args(path, **overrides):
        defaults = dict(t0=time.time() - 100, health=None, out=path,
                        lock=True, no_auto_unlock=False, interval=1,
                        slow_interval=3, dormant_interval=30, restart=1,
                        ref_window=900, pause_after=3, startup_grace=30,
                        far_th=-80, far_for=10, lost_for=10, active=30,
                        idle_lock=60, awake_minutes=30, screen="dim",
                        approach_th=-72, approach_gain=10, approach_for=3,
                        cancel_after=60, dormant_after=1800, slow_th=-75,
                        freeze_away=60)
        defaults.update(overrides)
        return SimpleNamespace(**defaults)

    def write_old_worker_log(self, path):
        stamp = datetime.now().isoformat()
        with open(path, "w", newline="", encoding="utf-8") as file:
            writer = csv.DictWriter(file, fieldnames=self.module.CSV_FIELDS)
            writer.writeheader()
            for event, note in (("lock", ""), ("prompt", "id=65535"), ("dim", "brightness=67")):
                writer.writerow(dict(time=stamp, t=95, event=event, note=note))
            writer.writerow(dict(time=stamp, t=99, event="report", seq=1,
                                 rssi=-35, phone_state=1, latency_ms=2))

    def packet(self, seq=1, *, key=None, session=None):
        self.packet_counter += 1
        return self.protocol.AuthenticatedReportProtocol.sign(
            struct.pack("<IbBB", seq, -51, 1, 2), key or self.key,
            self.peer.report_nonce if session is None else session,
            self.packet_counter.to_bytes(8, "little"))

    def sent(self, seq=1, device="trusted", *, age=0):
        self.peer.sent[seq] = self.peer.now() - age
        self.peer.authenticated_sent[(seq, device, self.peer.link_generations.get(device, 0))] = time.monotonic() - age

    async def establish_proof(self, device="trusted", seq=1):
        self.sent(seq, device)
        req = self.request(self.packet(seq))
        await self.peer.on_write_report(FakeArgs(device, req))
        self.assertEqual(req.responses, [("success", None)])
        self.assertTrue(self.peer.request_has_proof(device))

    async def command(self, device="trusted"):
        req = self.request()
        await self.peer.on_read_challenge(FakeArgs(device, req))
        self.assertEqual(req.responses[0][0], "value")
        challenge = self.protocol.UnlockProtocol.parse_challenge(req.responses[0][1])
        return self.protocol.UnlockProtocol.command(self.key, challenge)

    async def test_authenticated_report_establishes_proof_before_success_ack(self):
        self.sent()
        req = self.request(self.packet(), on_success=lambda: self.assertTrue(self.peer.request_has_proof("trusted")))
        await self.peer.on_write_report(FakeArgs("trusted", req))
        self.assertEqual(req.responses, [("success", None)])
        self.assertEqual(self.peer.app_proto, 2)
        self.assertEqual(len(self.peer.reports), 1)
        self.assertEqual(self.peer.reports[0][1:3], (-51, 1))
        self.assertEqual(self.peer.reports[0][4], "trusted")

    async def test_bad_signature_gets_error_and_never_reaches_judge(self):
        self.sent()
        packet = bytearray(self.packet())
        packet[-1] ^= 1
        req = self.request(packet)
        await self.peer.on_write_report(FakeArgs("trusted", req))
        self.assertEqual(req.responses, [("error", 0x08)])
        self.assertFalse(self.peer.request_has_proof("trusted"))
        self.assertEqual(self.peer.reports, [])

    async def test_legacy_reports_only_keep_link_alive_without_unlock_proof(self):
        for size in (6, 7):
            with self.subTest(size=size):
                self.peer.alive_at = 0
                req = self.request(struct.pack("<IbBB", 1, -30, 1, 2)[:size])
                await self.peer.on_write_report(FakeArgs("trusted", req))
                self.assertEqual(req.responses, [("success", None)])
                self.assertGreater(self.peer.alive_at, 0)
                self.assertFalse(self.peer.request_has_proof("trusted"))
                self.assertEqual(self.peer.reports, [])

    async def test_authenticated_report_requires_write_with_response(self):
        self.sent()
        req = self.request(self.packet(), option=self.module.GattWriteOption.WRITE_WITHOUT_RESPONSE)
        await self.peer.on_write_report(FakeArgs("trusted", req))
        self.assertEqual(req.responses, [])
        self.assertFalse(self.peer.request_has_proof("trusted"))
        self.assertEqual(self.peer.reports, [])

    async def test_old_unsent_and_wrong_key_packets_never_acknowledge(self):
        self.sent(1, age=11)
        self.sent(2)
        cases = [self.packet(1), self.packet(3), self.packet(2, key=self.protocol.UnlockKey(7, b"x" * 32)),
                 self.packet(2, session=b"z" * 16), b"bad"]
        for packet in cases:
            with self.subTest(length=len(packet), prefix=packet[:4].hex()):
                req = self.request(packet)
                await self.peer.on_write_report(FakeArgs("trusted", req))
                self.assertEqual(req.responses, [("error", 0x08)])
        self.assertEqual(self.peer.reports, [])
        self.assertFalse(self.peer.request_has_proof("trusted"))

    async def test_replayed_report_cannot_add_another_signal_sample(self):
        self.sent()
        packet = self.packet()
        first, replay = self.request(packet), self.request(packet)
        await self.peer.on_write_report(FakeArgs("trusted", first))
        await self.peer.on_write_report(FakeArgs("trusted", replay))
        self.assertEqual(first.responses, [("success", None)])
        self.assertEqual(replay.responses, [("error", 0x08)])
        self.assertEqual(len(self.peer.reports), 1)

    async def test_heartbeat_success_records_sequence_only_for_successful_connection(self):
        m, p = self.module, self.peer
        def result(device, status):
            return SimpleNamespace(status=status, subscribed_client=SimpleNamespace(
                session=SimpleNamespace(device_id=SimpleNamespace(id=device))))
        p.hb = SimpleNamespace(notify_value_async=AsyncMock(return_value=[
            result("trusted", m.GattCommunicationStatus.SUCCESS),
            result("other", m.GattCommunicationStatus.UNREACHABLE)]))
        p.heartbeat_gate = Mock(return_value=True)
        with patch.object(m.asyncio, "sleep", AsyncMock(side_effect=[None, asyncio.CancelledError])):
            with self.assertRaises(asyncio.CancelledError):
                await p.heartbeat_loop()
        self.assertIn((1, "trusted", 0), p.authenticated_sent)
        self.assertNotIn((1, "other", 0), p.authenticated_sent)
        req = self.request(self.packet(1))
        await p.on_write_report(FakeArgs("other", req))
        self.assertEqual(req.responses, [("error", 0x08)])
        self.assertFalse(p.request_has_proof("other"))

    async def test_report_waits_for_actual_notify_completion_before_ack(self):
        pending = asyncio.get_running_loop().create_future()
        self.peer.pending_notifications[1] = pending
        req = self.request(self.packet())
        task = asyncio.create_task(self.peer.on_write_report(FakeArgs("trusted", req)))
        await asyncio.sleep(0)
        self.assertEqual(req.responses, [])
        self.assertFalse(self.peer.request_has_proof("trusted"))
        self.sent()
        pending.set_result(None)
        await task
        self.assertEqual(req.responses, [("success", None)])

    async def test_disconnect_while_waiting_for_notify_invalidates_late_report(self):
        pending = asyncio.get_running_loop().create_future()
        self.peer.pending_notifications[1] = pending
        req = self.request(self.packet())
        task = asyncio.create_task(self.peer.on_write_report(FakeArgs("trusted", req)))
        await asyncio.sleep(0)
        self.peer.on_link("trusted", "DISCONNECTED")
        self.peer.on_link("trusted", "CONNECTED")
        self.sent()  # New connection may already have sent a heartbeat with the same seq.
        pending.set_result(None)
        await task
        self.assertEqual(req.responses, [("error", 0x08)])
        self.assertFalse(self.peer.request_has_proof("trusted"))
        self.assertEqual(self.peer.reports, [])

    async def test_old_get_request_callback_cannot_establish_new_connection_proof(self):
        gate = asyncio.Event()
        req = self.request(self.packet())
        args = FakeArgs("trusted", req, wait=gate)
        task = asyncio.create_task(self.peer.on_write_report(args))
        await args.entered.wait()
        self.peer.on_link("trusted", "DISCONNECTED")
        self.peer.on_link("trusted", "CONNECTED")
        self.sent()
        gate.set()
        await task
        self.assertEqual(req.responses, [("error", 0x08)])
        self.assertFalse(self.peer.request_has_proof("trusted"))

    async def test_old_challenge_and_command_callbacks_cannot_consume_new_connections_nonce(self):
        for handler_name in ("on_read_challenge", "on_write_unlock"):
            with self.subTest(handler=handler_name):
                await self.establish_proof()
                old_command = await self.command()
                gate = asyncio.Event()
                req = self.request(old_command if handler_name == "on_write_unlock" else b"")
                args = FakeArgs("trusted", req, wait=gate)
                task = asyncio.create_task(getattr(self.peer, handler_name)(args))
                await args.entered.wait()
                self.peer.on_link("trusted", "DISCONNECTED")
                self.peer.on_link("trusted", "CONNECTED")
                await self.establish_proof(seq=2)
                new_command = await self.command()
                gate.set()
                await task
                self.assertEqual(req.responses, [("error", int(self.module.UnlockStatus.UNAVAILABLE))])
                self.assertEqual(await self.command(), new_command)
                self.peer.unlock_backend.unlock.assert_not_called()

    async def test_captured_old_ingress_context_rejects_even_a_valid_new_challenge_command(self):
        await self.establish_proof()
        old_context = ("trusted", self.peer.link_generations["trusted"])
        await self.command()
        self.peer.on_link("trusted", "DISCONNECTED")
        self.peer.on_link("trusted", "CONNECTED")
        await self.establish_proof(seq=2)
        new_command = await self.command()
        req = self.request(new_command)
        await self.peer.on_write_unlock(FakeArgs("trusted", req), old_context)
        self.assertEqual(req.responses, [("error", int(self.module.UnlockStatus.UNAVAILABLE))])
        self.peer.unlock_backend.unlock.assert_not_called()
        self.assertEqual(await self.command(), new_command)
        self.peer.unlock_backend.unlock.return_value = True
        legitimate = self.request(new_command)
        await self.peer.on_write_unlock(FakeArgs("trusted", legitimate))
        self.assertEqual(legitimate.responses, [("success", None)])
        self.peer.unlock_backend.unlock.assert_called_once_with()

    async def test_unproven_connection_cannot_read_or_consume_owners_challenge(self):
        await self.establish_proof()
        command = await self.command()
        failures = self.peer.unlock_gate.failures
        for handler, value in ((self.peer.on_read_challenge, b""), (self.peer.on_write_unlock, command)):
            req = self.request(value)
            await handler(FakeArgs("other", req))
            self.assertEqual(req.responses, [("error", int(self.module.UnlockStatus.UNAVAILABLE))])
        self.assertEqual(self.peer.unlock_gate.failures, failures)
        req = self.request(command)
        await self.peer.on_write_unlock(FakeArgs("trusted", req))
        self.peer.unlock_backend.unlock.assert_called_once_with()
        self.assertEqual(req.responses, [("error", int(self.module.UnlockStatus.EXECUTION_FAILED))])

    async def test_backend_failure_consumes_nonce_and_latches_across_new_prompts(self):
        await self.establish_proof()
        command = await self.command()
        first = self.request(command)
        await self.peer.on_write_unlock(FakeArgs("trusted", first))
        self.assertEqual(first.responses, [("error", int(self.module.UnlockStatus.EXECUTION_FAILED))])
        self.assertTrue(self.peer.unlock_failed)
        self.assertFalse(self.peer.unlock_gate.in_flight)
        replay = self.request(command)
        await self.peer.on_write_unlock(FakeArgs("trusted", replay))
        self.assertEqual(replay.responses, [("error", int(self.module.UnlockStatus.UNAVAILABLE))])
        self.peer.judge.prompt_id += 1
        next_prompt = self.request()
        await self.peer.on_read_challenge(FakeArgs("trusted", next_prompt))
        self.assertEqual(next_prompt.responses, [("error", int(self.module.UnlockStatus.UNAVAILABLE))])
        self.peer.unlock_backend.unlock.assert_called_once_with()
        self.locked.return_value = False
        self.assertFalse(self.peer.sync_unlock_gate())
        self.assertFalse(self.peer.unlock_failed)

    async def test_backend_exception_is_failure_and_credential_details_are_not_logged(self):
        await self.establish_proof()
        command = await self.command()
        sensitive_marker = "test-sensitive-password-details"
        self.peer.unlock_backend.unlock.side_effect = RuntimeError(sensitive_marker)
        req = self.request(command)
        await self.peer.on_write_unlock(FakeArgs("trusted", req))
        self.assertEqual(req.responses, [("error", int(self.module.UnlockStatus.EXECUTION_FAILED))])
        self.assertTrue(self.peer.unlock_failed)
        self.assertNotIn(sensitive_marker, str(self.peer.log.call_args_list))

    async def test_backend_success_is_the_only_unlock_success_ack(self):
        await self.establish_proof()
        command = await self.command()
        self.peer.unlock_backend.unlock.return_value = True
        req = self.request(command)
        await self.peer.on_write_unlock(FakeArgs("trusted", req))
        self.assertEqual(req.responses, [("success", None)])
        self.peer.unlock_backend.unlock.assert_called_once_with()
        self.peer.judge.update.assert_called_once_with()
        self.assertFalse(self.peer.unlock_failed)

    # ------------------------------------------------ 手动解锁、手机锁屏（docs/protocol.md「手动锁屏、解锁」）

    def notes(self, event):
        return [c.kwargs.get("note") for c in self.peer.log.call_args_list if c.args[0] == event]

    async def test_manual_unlock_when_locked_and_not_prompting(self):
        p = self.peer
        p.judge.prompting = False
        await self.establish_proof()
        req = self.request()
        await p.on_read_challenge(FakeArgs("trusted", req))
        challenge = self.protocol.UnlockProtocol.parse_challenge(req.responses[0][1])
        self.assertEqual(challenge.prompt_id, 0)
        p.unlock_backend.unlock.return_value = True
        write = self.request(self.protocol.UnlockProtocol.command(self.key, challenge))
        await p.on_write_unlock(FakeArgs("trusted", write))
        self.assertEqual(write.responses, [("success", None)])
        p.unlock_backend.unlock.assert_called_once_with()
        self.assertIn("手动解锁", self.notes("unlock_request")[0])
        self.assertIn("（手动解锁）", self.notes("unlock")[0])
        p.judge.restore_brightness.assert_not_called()  # 没调暗过就不用恢复

    async def test_manual_unlock_restores_dimmed_screen_and_prompt_signature_cannot_be_used(self):
        p = self.peer
        await self.establish_proof()
        prompt_command = await self.command()        # 请提示（编号 42）时拿到的签名
        p.judge.prompting = False                    # 提示撤了，还锁着
        p.judge.saved_brightness = 67
        manual_req = self.request()
        await p.on_read_challenge(FakeArgs("trusted", manual_req))
        self.assertEqual(manual_req.responses[0][1][:2], b"\0\0")
        p.judge.restore_brightness.assert_called_once()
        self.assertIn("手动解锁", p.judge.restore_brightness.call_args.args[1])
        stale = self.request(prompt_command)
        await p.on_write_unlock(FakeArgs("trusted", stale))
        self.assertEqual(stale.responses[0][0], "error")
        p.unlock_backend.unlock.assert_not_called()
        self.assertEqual(p.unlock_gate.manual_failures, 1)
        self.assertEqual(self.notes("unlock_fail"), ["认证拒绝 0x80（手动解锁）"])

    async def test_failed_system_unlock_stops_manual_unlock_until_computer_is_unlocked(self):
        p = self.peer
        p.judge.prompting = False
        await self.establish_proof()
        failed = self.request(await self.command())
        await p.on_write_unlock(FakeArgs("trusted", failed))
        self.assertEqual(failed.responses, [("error", int(self.module.UnlockStatus.EXECUTION_FAILED))])
        self.assertTrue(p.unlock_failed)
        self.assertEqual(p.unlock_gate.manual_failures, 1)
        again = self.request()
        await p.on_read_challenge(FakeArgs("trusted", again))
        self.assertEqual(again.responses, [("error", int(self.module.UnlockStatus.UNAVAILABLE))])
        self.locked.return_value = False             # 在电脑上解开了
        self.assertIsNone(p.sync_unlock_gate())
        self.assertFalse(p.unlock_failed)
        self.assertEqual(p.unlock_gate.manual_failures, 0)
        self.locked.return_value = True
        self.assertEqual(p.sync_unlock_gate(), 0)

    def test_info_advertises_manual_with_unlock(self):
        info = json.loads(self.peer.info_payload())
        self.assertEqual(info["manual"], 1)
        self.peer.unlock_backend.available.return_value = False
        self.assertNotIn("manual", json.loads(self.peer.info_payload()))

    def lock_command(self, seq=1, *, key=None, nonce=None):
        self.packet_counter += 1
        return self.protocol.LockProtocol.command(key or self.key, self.peer.report_nonce if nonce is None else nonce,
                                                  seq, self.packet_counter.to_bytes(8, "little"))

    async def write_lock(self, data, device="trusted", **kwargs):
        req = self.request(data, **kwargs)
        await self.peer.on_write_lock(FakeArgs(device, req))
        return req

    async def test_phone_lock_locks_without_turning_the_screen_off(self):
        # 不主动关屏：电脑端关屏进的待机会把电脑端冻住，之后手机上点解锁没人应答
        m, p = self.module, self.peer
        await self.establish_proof()
        self.locked.return_value = False
        with patch.object(m, "lock_workstation", return_value=True) as lock, \
                patch.object(m, "turn_off_display", side_effect=AssertionError("不该关屏")), \
                patch.object(m, "set_brightness", side_effect=AssertionError("不该调暗")):
            req = await self.write_lock(self.lock_command())
        self.assertEqual(req.responses, [("success", None)])
        lock.assert_called_once_with()
        self.assertEqual(self.notes("phone_lock"), ["已锁屏"])
        self.assertIsNone(p.judge.display_off_at)
        self.locked.return_value = True              # 锁上以后照样能在手机上手动解锁
        p.judge.prompting = False
        self.assertEqual(p.sync_unlock_gate(), 0)

    async def test_phone_lock_when_already_locked_or_lock_fails(self):
        m = self.module
        await self.establish_proof()
        with patch.object(m, "lock_workstation", side_effect=AssertionError("本来就锁着")):
            req = await self.write_lock(self.lock_command())  # setUp 里默认锁着
        self.assertEqual(req.responses, [("success", None)])
        self.locked.return_value = False
        with patch.object(m, "lock_workstation", return_value=False):
            failed = await self.write_lock(self.lock_command())
        self.assertEqual(failed.responses, [("error", 0x83)])
        self.assertEqual(self.notes("phone_lock"), ["本来就锁着"])
        self.assertEqual(self.notes("phone_lock_fail"), ["LockWorkStation 失败"])

    async def test_phone_lock_rejections_never_lock(self):
        m, p = self.module, self.peer
        self.locked.return_value = False
        unproven = await self.write_lock(self.lock_command(), device="other")
        self.assertEqual(unproven.responses, [("error", 0x80)])
        await self.establish_proof()
        good = self.lock_command()
        tampered = bytearray(good)
        tampered[-1] ^= 1
        cases = [(self.lock_command(seq=9), 0x82),                     # 没发过的心跳
                 (bytes(tampered), 0x81),
                 (self.lock_command(key=self.protocol.UnlockKey(7, bytes(range(32)))), 0x81),
                 (self.lock_command(nonce=bytes(16)), 0x81),           # 旧进程的会话
                 (good[:-1], 0x0D)]
        for data, status in cases:
            with self.subTest(status=hex(status)):
                req = await self.write_lock(data)
                self.assertEqual(req.responses, [("error", status)])
        quiet = await self.write_lock(good, option=m.GattWriteOption.WRITE_WITHOUT_RESPONSE)
        self.assertEqual(quiet.responses, [])
        p.args.lock = False
        off = await self.write_lock(good)
        self.assertEqual(off.responses, [("error", 0x80)])
        p.args.lock = True
        with patch.object(m, "lock_workstation", return_value=True) as lock:
            first = await self.write_lock(good)
            replay = await self.write_lock(good)
        self.assertEqual(first.responses, [("success", None)])
        self.assertEqual(replay.responses, [("error", 0x82)])
        lock.assert_called_once_with()
        self.assertIn("replay", self.notes("phone_lock_reject"))

    async def test_unlock_without_response_cannot_reach_backend_or_consume_nonce(self):
        await self.establish_proof()
        command = await self.command()
        req = self.request(command, option=self.module.GattWriteOption.WRITE_WITHOUT_RESPONSE)
        await self.peer.on_write_unlock(FakeArgs("trusted", req))
        self.assertEqual(req.responses, [])
        self.peer.unlock_backend.unlock.assert_not_called()
        self.assertEqual(await self.command(), command)

    async def test_one_link_disconnect_clears_only_its_signal_and_proof(self):
        await self.establish_proof("trusted", 1)
        await self.establish_proof("other", 2)
        command = await self.command("other")
        self.peer.on_link("trusted", "DISCONNECTED")
        self.assertFalse(self.peer.request_has_proof("trusted"))
        self.assertTrue(self.peer.request_has_proof("other"))
        self.assertEqual([r[4] for r in self.peer.reports], ["other"])
        self.assertIsNone(self.peer.judge.near_since)
        self.assertEqual(await self.command("other"), command)

    def test_heartbeat_pauses_as_soon_as_every_link_disconnects(self):
        p = self.peer
        p.hb_paused = False
        p.judge.report_timeout = lambda: 3
        now = time.time()
        p.alive_at = now - 0.5  # 刚收到过报告，按"3 秒没报告"还不会停
        p.on_link("trusted", "DISCONNECTED")
        self.assertTrue(p.heartbeat_gate(now))  # 另一台还连着
        p.on_link("other", "DISCONNECTED")
        self.assertFalse(p.heartbeat_gate(now))
        p.log.assert_any_call("hb_pause", note="底层链路断开")
        p.on_link("other", "CONNECTED")
        self.assertTrue(p.heartbeat_gate(now))
        p.log.assert_any_call("hb_resume")

    async def test_heartbeat_loop_never_notifies_when_every_link_is_disconnected(self):
        p = self.peer
        p.hb_paused = False
        p.judge.report_timeout = lambda: 3
        p.hb = SimpleNamespace(notify_value_async=AsyncMock(return_value=[]))
        p.on_link("trusted", "DISCONNECTED")
        p.on_link("other", "DISCONNECTED")
        with patch.object(self.module.asyncio, "sleep", AsyncMock(side_effect=[None, asyncio.CancelledError])):
            with self.assertRaises(asyncio.CancelledError):
                await p.heartbeat_loop()
        p.hb.notify_value_async.assert_not_called()

    async def enroll_ack(self, data, **kwargs):
        req = self.request(data, **kwargs)
        await self.peer.on_write_enroll_ack(FakeArgs("trusted", req))
        return req

    async def test_enroll_ack_signals_window_only_with_valid_signature(self):
        m, p = self.module, self.peer
        ack = self.protocol.EnrollAckProtocol.sign(self.key, p.report_nonce)
        with patch.object(m, "signal_enroll_window", return_value=True) as signal:
            req = await self.enroll_ack(ack)
            self.assertEqual(req.responses, [("success", None)])
            signal.assert_called_once()
            p.log.assert_called_with("enroll_ack", device="Phone", note="已通知登记窗口关闭")
            signal.reset_mock()
            bad = bytearray(ack)
            bad[-1] ^= 1
            other_session = self.protocol.EnrollAckProtocol.sign(self.key, bytes(16))
            for data in (bytes(bad), other_session, ack[:-1]):
                req = await self.enroll_ack(data)
                self.assertEqual(req.responses, [("error", 0x81)])
            req = await self.enroll_ack(ack, option=m.GattWriteOption.WRITE_WITHOUT_RESPONSE)
            self.assertEqual(req.responses, [])
            signal.assert_not_called()
        self.assertFalse(self.peer.request_has_proof("trusted"))  # 只关窗口，不算手机在场

    async def test_enroll_ack_with_rotated_key_reads_current_enrollment(self):
        m, p = self.module, self.peer
        rotated = self.protocol.UnlockKey(0x0BADBEEF, bytes(range(32, 64)))
        ack = self.protocol.EnrollAckProtocol.sign(rotated, p.report_nonce)
        backend = Mock(key_id=rotated.id, secret=rotated.secret)
        with patch.object(m, "signal_enroll_window", return_value=False), \
                patch.object(m, "load_backend", return_value=backend) as load:
            req = await self.enroll_ack(ack)
        load.assert_called_once()
        self.assertEqual(req.responses, [("success", None)])
        note = p.log.call_args.kwargs["note"]
        self.assertIn("登记窗口没开着", note)
        self.assertIn("新登记的密钥", note)
        with patch.object(m, "load_backend", return_value=None):
            req = await self.enroll_ack(ack)
        self.assertEqual(req.responses, [("error", 0x81)])

    async def enroll_request(self, data=b"\x01", **kwargs):
        req = self.request(data, **kwargs)
        await self.peer.on_write_enroll_request(FakeArgs("trusted", req))
        return req

    async def test_enroll_request_asks_on_the_computer_and_never_opens_twice(self):
        m, p = self.module, self.peer
        self.locked.return_value = False
        prompt = Mock()
        prompt.poll.return_value = None  # 确认窗口还开着
        with patch.object(m, "launch_enroll_prompt", return_value=prompt) as launch, \
                patch.object(m, "enroll_window_open", return_value=False):
            first = await self.enroll_request()
            second = await self.enroll_request()
            self.assertEqual(first.responses, [("success", None)])
            self.assertEqual(second.responses, [("success", None)])
            launch.assert_called_once()
            notes = [c.kwargs["note"] for c in p.log.call_args_list if c.args[0] == "enroll_request"]
            self.assertEqual(notes, ["弹出了确认窗口", "确认窗口已经开着"])
            prompt.poll.return_value = 0  # 用户点了，进程退出；3 秒内不再起，过了再起
            await self.enroll_request()
            launch.assert_called_once()
            p.enroll_prompt_at -= 3
            await self.enroll_request()
            self.assertEqual(launch.call_count, 2)

    async def test_enroll_request_rejections(self):
        m, p = self.module, self.peer
        with patch.object(m, "launch_enroll_prompt") as launch, \
                patch.object(m, "enroll_window_open", return_value=False):
            locked = await self.enroll_request()                    # setUp 里默认锁着屏
            self.assertEqual(locked.responses, [("error", 0x81)])
            self.locked.return_value = False
            for data in (b"", b"\x02", b"\x01\x00"):
                req = await self.enroll_request(data)
                self.assertEqual(req.responses, [("error", 0x0D)])
            req = await self.enroll_request(option=m.GattWriteOption.WRITE_WITHOUT_RESPONSE)
            self.assertEqual(req.responses, [])
            launch.assert_not_called()
            launch.return_value = None                              # 起不来
            failed = await self.enroll_request()
            self.assertEqual(failed.responses, [("error", 0x82)])
        with patch.object(m, "launch_enroll_prompt") as launch, \
                patch.object(m, "enroll_window_open", return_value=True):
            opened = await self.enroll_request()                    # 手动打开的登记窗口还开着
            self.assertEqual(opened.responses, [("success", None)])
            launch.assert_not_called()
        reasons = [c.kwargs["note"] for c in p.log.call_args_list if c.args[0] == "enroll_request_reject"]
        self.assertEqual(reasons, ["电脑锁着屏", "内容不对", "内容不对", "内容不对", "弹不出确认窗口"])

    def test_enroll_prompt_only_exports_an_available_enrollment(self):
        with patch.object(sys, "path", [str(Path(__file__).resolve().parents[1] / "prototype"), *sys.path]):
            prompt = importlib.import_module("enroll_prompt")
        self.assertEqual(prompt.decide(False, None), "not_installed")
        self.assertEqual(prompt.decide(True, None), "not_enrolled")
        self.assertEqual(prompt.decide(True, {"enrolled": True, "available": False, "pendingValidation": True}),
                         "not_enrolled")
        self.assertEqual(prompt.decide(True, {"enrolled": True, "available": True}), "export")

    def test_info_capability_requires_available_backend(self):
        available = json.loads(self.peer.info_payload())
        self.assertEqual(available["platform"], "win32")
        self.assertEqual(available["unlock"], "win-hmac-v3")
        self.assertEqual(base64.b64decode(available["reportNonce"]), self.peer.report_nonce)
        self.peer.unlock_backend.available.return_value = False
        unavailable = json.loads(self.peer.info_payload())
        self.peer.unlock_backend = None
        absent = json.loads(self.peer.info_payload())
        for info in (unavailable, absent):
            self.assertNotIn("unlock", info)
            self.assertNotIn("reportNonce", info)

    def test_authenticated_restart_changes_nonce_and_restores_only_brightness(self):
        m = self.module
        with tempfile.TemporaryDirectory() as folder:
            path = str(Path(folder) / "old-worker.csv")
            self.write_old_worker_log(path)
            args = self.worker_args(path)
            nonces = []
            with patch.object(m, "load_backend", return_value=self.peer.unlock_backend), \
                    patch.object(m, "KeepAwake"), patch.object(m.Peer, "say"):
                for _ in range(2):
                    worker = m.Peer(args)
                    try:
                        nonces.append(worker.report_nonce)
                        self.assertEqual(len(worker.report_nonce), 16)
                        self.assertEqual(worker.reports, [])
                        self.assertFalse(worker.judge.prompting)
                        self.assertFalse(worker.judge.armed)
                        self.assertIsNone(worker.judge.away_at)
                        self.assertIsNone(worker.judge.prompt_at)
                        self.assertNotEqual(worker.judge.prompt_id, 65535)
                        self.assertEqual(worker.judge.saved_brightness, 67)
                        self.assertEqual(worker.authenticated_sent, {})
                        self.assertFalse(worker.request_has_proof("trusted"))
                    finally:
                        worker.file.close()
            self.assertNotEqual(nonces[0], nonces[1])

    def test_authenticated_restart_restores_brightness_when_user_manually_unlocks(self):
        m = self.module
        self.locked.return_value = False
        with tempfile.TemporaryDirectory() as folder:
            path = str(Path(folder) / "old-worker.csv")
            self.write_old_worker_log(path)
            awake = SimpleNamespace(on=False, set=Mock())
            with patch.object(m, "load_backend", return_value=self.peer.unlock_backend), \
                    patch.object(m, "KeepAwake", return_value=awake), \
                    patch.object(m.Peer, "say"), \
                    patch.object(m, "input_idle_seconds", return_value=0), \
                    patch.object(m, "get_brightness", side_effect=AssertionError("must not dim again")), \
                    patch.object(m, "set_brightness", return_value=True) as brightness:
                worker = m.Peer(self.worker_args(path))
                try:
                    self.assertEqual(worker.judge.saved_brightness, 67)
                    self.assertIsNone(worker.judge.away_at)
                    self.assertIsNone(worker.judge.prompt_at)
                    self.assertFalse(worker.judge.prompting)
                    worker.judge.display_off_at = time.time() + 30
                    worker.judge.update()
                    brightness.assert_called_once_with(67)
                    self.assertIsNone(worker.judge.saved_brightness)
                    self.assertIsNone(worker.judge.display_off_at)
                    self.assertFalse(worker.judge.prompting)
                    self.assertFalse(worker.judge.armed)
                    awake.set.assert_not_called()
                finally:
                    worker.file.close()

    def test_no_lock_and_no_auto_unlock_skip_backend_loading(self):
        m = self.module
        with tempfile.TemporaryDirectory() as folder:
            for lock, disabled in ((False, False), (True, True)):
                with self.subTest(lock=lock, no_auto_unlock=disabled):
                    path = str(Path(folder) / f"disabled-{lock}-{disabled}.csv")
                    with patch.object(m, "load_backend") as load, patch.object(m, "KeepAwake"):
                        worker = m.Peer(self.worker_args(path, lock=lock, no_auto_unlock=disabled, restart=0))
                        try:
                            load.assert_not_called()
                            self.assertIsNone(worker.unlock_backend)
                            self.assertIsNone(worker.authenticated_reports)
                            self.assertIsNone(worker.unlock_gate)
                            self.assertNotIn("unlock", json.loads(worker.info_payload()))
                        finally:
                            worker.file.close()


if __name__ == "__main__":
    unittest.main()
