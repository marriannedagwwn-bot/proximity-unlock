"""Cross-platform v3 fixed vectors and security boundary regression tests."""

import math
import struct
import unittest

from prototype.win_unlock_protocol import (
    AuthenticatedReportGate,
    AuthenticatedReportProtocol,
    Challenge,
    EnrollAckProtocol,
    ReportAuthenticationError,
    UnlockError,
    UnlockGate,
    UnlockKey,
    UnlockProtocol,
    UnlockStatus,
)


class UnlockProtocolTests(unittest.TestCase):
    def setUp(self):
        self.key = UnlockKey(0x01020304, bytes(range(32)))
        self.nonce = bytes(range(16))
        self.gate = UnlockGate(self.key)
        self.gate.sync(0x1234, now=100)

    def command(self, now=101, central="trusted"):
        data = self.gate.challenge(central, now=now, nonce=self.nonce)
        return UnlockProtocol.command(self.key, UnlockProtocol.parse_challenge(data))

    def rejected(self, status, function, *args, **kwargs):
        with self.assertRaises(UnlockError) as rejected:
            function(*args, **kwargs)
        self.assertEqual(rejected.exception.status, status)

    def authorize(self, data, now=101, central="trusted", eligible=True):
        return self.gate.authorize(data, central, now, eligible)

    def test_swift_and_iphone_fixed_unlock_vector(self):
        challenge = Challenge(0x1234, self.nonce)
        self.assertEqual(challenge.data.hex(), "3412000102030405060708090a0b0c0d0e0f")
        self.assertEqual(UnlockProtocol.tag(self.key, challenge).hex(), "4b78d367ade22f9aee438984eccfd654")
        self.assertEqual(self.command().hex(), "0403020134124b78d367ade22f9aee438984eccfd654")
        self.assertEqual(UnlockProtocol.parse_challenge(challenge.data), challenge)
        self.assertIsNone(UnlockProtocol.parse_challenge(challenge.data[:-1]))
        self.assertIsNone(UnlockProtocol.parse_challenge(challenge.data + b"\0"))

    def test_enroll_ack_fixed_vector_and_rejections(self):
        # Same vector in docs/protocol.md for the iPhone side; cross-checked with openssl.
        key, report_nonce = UnlockKey(0x78563412, bytes(range(32))), bytes(range(16))
        ack = EnrollAckProtocol.sign(key, report_nonce)
        self.assertEqual(ack.hex(), "12345678e8a232851651af8c3a8c9efbbeb9ab78")
        self.assertEqual(EnrollAckProtocol.key_id(ack), 0x78563412)
        self.assertTrue(EnrollAckProtocol.verify(ack, key, report_nonce))
        tampered = bytearray(ack)
        tampered[-1] ^= 1
        for data, nonce, other in ((bytes(tampered), report_nonce, key), (ack, bytes(16), key),
                                   (ack[:-1], report_nonce, key), (ack + b"\0", report_nonce, key),
                                   (ack, report_nonce, UnlockKey(0x78563412, bytes(32)))):
            with self.subTest(data=data.hex(), nonce=nonce.hex(), secret=other.secret[:2].hex()):
                self.assertFalse(EnrollAckProtocol.verify(data, other, nonce))
        self.assertIsNone(EnrollAckProtocol.key_id(ack[:-1]))

    def test_no_prompt_zero_prompt_or_invalid_key_never_enables(self):
        for key, prompt in ((self.key, None), (self.key, 0), (UnlockKey(1, b"x"), 1)):
            with self.subTest(prompt=prompt, key_length=len(key.secret)):
                gate = UnlockGate(key)
                gate.sync(prompt, now=100)
                self.rejected(UnlockStatus.UNAVAILABLE, gate.challenge, "trusted", 101)

    def test_valid_request_is_single_use_and_cannot_run_concurrently(self):
        command = self.command()
        self.authorize(command)
        self.assertTrue(self.gate.in_flight)
        self.rejected(UnlockStatus.UNAVAILABLE, self.authorize, command)
        self.rejected(UnlockStatus.UNAVAILABLE, self.gate.challenge, "trusted", 102)
        self.gate.finish()
        self.assertFalse(self.gate.in_flight)
        self.rejected(UnlockStatus.INVALID_CHALLENGE, self.authorize, command)

    def test_ineligible_owner_cancels_nonce(self):
        command = self.command()
        self.rejected(UnlockStatus.UNAVAILABLE, self.authorize, command, eligible=False)
        self.rejected(UnlockStatus.INVALID_CHALLENGE, self.authorize, command)

    def test_stranger_cannot_reserve_consume_or_cancel_owned_challenge(self):
        command = self.command()
        self.rejected(UnlockStatus.UNAVAILABLE, self.gate.challenge, "stranger", 101)
        self.rejected(UnlockStatus.UNAVAILABLE, self.authorize, command, central="stranger")
        self.rejected(UnlockStatus.UNAVAILABLE, self.authorize, b"", central="stranger", eligible=False)
        self.assertEqual(self.gate.failures, 0)
        self.authorize(command)

    def test_same_owner_reread_keeps_challenge(self):
        first = self.gate.challenge("trusted", 101, self.nonce)
        second = self.gate.challenge("trusted", 102, bytes(reversed(self.nonce)))
        self.assertEqual(first, second)

    def test_prompt_deadline_cannot_renew_by_cancel_reactivate(self):
        command = self.command()
        self.gate.sync(None, now=200)
        self.gate.sync(0x1234, now=219)
        self.rejected(UnlockStatus.INVALID_CHALLENGE, self.gate.challenge, "trusted", 220.01)
        self.gate.sync(0x1235, now=221)
        self.rejected(UnlockStatus.INVALID_CHALLENGE, self.authorize, command, now=221)
        self.assertEqual(self.gate.failures, 1)
        self.assertEqual(len(self.gate.challenge("trusted", 221)), 18)

    def test_challenge_expiry_and_deadline_boundary(self):
        command = self.command()
        self.authorize(command, now=220)
        self.gate.finish()
        self.rejected(UnlockStatus.INVALID_CHALLENGE, self.gate.challenge, "trusted", 220.01)

    def test_expired_command_consumes_its_nonce(self):
        command = self.command()
        self.rejected(UnlockStatus.INVALID_CHALLENGE, self.authorize, command, now=220.01)
        self.assertEqual(self.gate.failures, 1)

    def test_invalid_clock_values_or_nonce_fail_closed(self):
        for now in (99, math.nan, math.inf, -math.inf, None):
            with self.subTest(now=now):
                self.rejected(UnlockStatus.INVALID_CHALLENGE, self.gate.challenge, "trusted", now)
        self.rejected(UnlockStatus.INVALID_CHALLENGE, self.gate.challenge, "trusted", 101, b"x")

    def test_new_prompt_or_cancellation_invalidates_old_command(self):
        command = self.command()
        self.gate.sync(0x1235, now=102)
        self.rejected(UnlockStatus.INVALID_CHALLENGE, self.authorize, command, now=102)
        self.command(now=103)
        self.gate.sync(None, now=104)
        self.rejected(UnlockStatus.UNAVAILABLE, self.authorize, command, now=104)

    def test_wrong_key_prompt_format_and_signature_consume_nonce(self):
        for index, status in ((0, UnlockStatus.UNAVAILABLE), (4, UnlockStatus.UNAVAILABLE),
                              (21, UnlockStatus.INVALID_SIGNATURE), (None, UnlockStatus.INVALID_SIGNATURE)):
            with self.subTest(index=index):
                self.setUp()
                command = bytearray(self.command())
                if index is None:
                    command = command[:-1]
                else:
                    command[index] ^= 1
                self.rejected(status, self.authorize, command)
                self.rejected(UnlockStatus.INVALID_CHALLENGE, self.authorize, command)

    def test_three_failed_signatures_exhaust_prompt_and_same_id_preserves_budget(self):
        for n in range(3):
            command = bytearray(self.command(now=101 + n))
            command[-1] ^= 1
            self.rejected(UnlockStatus.INVALID_SIGNATURE, self.authorize, command, now=101 + n)
        self.assertEqual(self.gate.failures, 3)
        self.gate.sync(0x1234, now=105)
        self.gate.sync(None, now=105)
        self.gate.sync(0x1234, now=105)
        self.rejected(UnlockStatus.UNAVAILABLE, self.gate.challenge, "trusted", 105)
        self.assertEqual(self.gate.failures, 3)
        self.gate.sync(0x1235, now=106)
        self.assertEqual(self.gate.failures, 0)
        self.assertEqual(len(self.gate.challenge("trusted", 106)), 18)

    def test_execution_failure_counts_only_current_prompt_and_prompt_cannot_bypass_in_flight(self):
        self.authorize(self.command())
        self.gate.finish(succeeded=False)
        self.assertEqual(self.gate.failures, 1)
        self.authorize(self.command(now=102), now=102)
        self.gate.sync(0x1235, now=103)
        self.rejected(UnlockStatus.UNAVAILABLE, self.gate.challenge, "trusted", 103)
        self.gate.finish(succeeded=False)
        self.assertEqual(self.gate.failures, 0)
        self.assertEqual(len(self.gate.challenge("trusted", 104)), 18)

    def test_disconnect_invalidates_only_the_owner_challenge(self):
        command = self.command()
        self.gate.clear_central("stranger")
        self.authorize(command)
        self.gate.finish()
        command = self.command(now=102)
        self.gate.clear_central("trusted")
        self.rejected(UnlockStatus.INVALID_CHALLENGE, self.authorize, command, now=102)


class AuthenticatedReportTests(unittest.TestCase):
    def setUp(self):
        self.key = UnlockKey(0x78563412, bytes(range(32)))
        self.session = bytes(range(16))
        self.nonce = bytes(range(8))
        self.gate = AuthenticatedReportGate(self.key, self.session, maximum_interval=30)

    def base(self, seq=0x01020304, rssi=-60):
        return struct.pack("<IbBB", seq, rssi, 2, 2)

    def packet(self, seq=0x01020304, rssi=-60, nonce=None):
        return AuthenticatedReportProtocol.sign(
            self.base(seq, rssi), self.key, self.session, self.nonce if nonce is None else nonce
        )

    def accept(self, data, central="trusted", sent_at=100, now=101, current_interval=1):
        return self.gate.accept(data, central, sent_at, now, current_interval)

    def rejected(self, reason, data, **kwargs):
        with self.assertRaises(ReportAuthenticationError) as rejected:
            self.accept(data, **kwargs)
        self.assertEqual(rejected.exception.reason, reason)

    def test_swift_and_iphone_fixed_authenticated_report_vector(self):
        data = self.packet()
        self.assertEqual(data.hex(), "04030201c40202123456780001020304050607fe75e30883ae3552ab7196d247dfdab9")
        self.assertEqual(AuthenticatedReportProtocol.sequence(data), 0x01020304)
        self.assertIsNone(AuthenticatedReportProtocol.sequence(b"abc"))
        self.assertEqual(self.accept(data), self.base())

    def test_every_changed_byte_is_rejected_without_establishing_presence(self):
        for index in range(35):
            with self.subTest(index=index):
                packet = bytearray(self.packet())
                packet[index] ^= 1
                with self.assertRaises(ReportAuthenticationError):
                    self.accept(packet)
                self.assertFalse(self.gate.is_fresh("trusted", 101, 1))
        self.assertEqual(self.accept(self.packet()), self.base())

    def test_another_key_or_worker_nonce_cannot_authenticate(self):
        packet = self.packet()
        for key, session in ((UnlockKey(self.key.id, b"\xa5" * 32), self.session),
                             (self.key, b"\xa5" * 16)):
            self.gate = AuthenticatedReportGate(key, session)
            self.rejected("invalid_signature", packet)
        self.gate = AuthenticatedReportGate(UnlockKey(999, self.key.secret), self.session)
        self.rejected("wrong_key", packet)

    def test_missing_future_expired_or_nonfinite_sent_time_is_rejected(self):
        for sent_at in (None, 102, 90.99, math.nan, math.inf, -math.inf):
            with self.subTest(sent_at=sent_at):
                self.rejected("stale_heartbeat", self.packet(), sent_at=sent_at)
        self.assertEqual(self.accept(self.packet(), sent_at=100, now=135, current_interval=30), self.base())
        self.rejected("stale_heartbeat", self.packet(nonce=b"\xaa" * 8),
                      sent_at=100, now=135.01, current_interval=30)

    def test_invalid_configuration_and_clock_fail_closed(self):
        for maximum, interval, now in ((30, -1, 101), (30, 31, 101), (30, math.nan, 101),
                                       (30, 1, math.nan), (30, 1, math.inf),
                                       (math.inf, 1, 101), (-1, 1, 101)):
            with self.subTest(maximum=maximum, interval=interval, now=now):
                self.gate = AuthenticatedReportGate(self.key, self.session, maximum)
                self.rejected("invalid_configuration", self.packet(), now=now, current_interval=interval)
        self.gate = AuthenticatedReportGate(self.key, b"x")
        self.rejected("invalid_configuration", self.packet())

    def test_replay_rejected_but_new_nonce_for_same_heartbeat_accepted(self):
        packet = self.packet()
        self.accept(packet)
        self.rejected("replay", packet, now=102)
        self.assertEqual(self.accept(self.packet(nonce=b"\xaa" * 8), now=103), self.base())

    def test_fast_then_slow_tier_cannot_reenable_replay(self):
        packet = self.packet()
        self.accept(packet)
        self.accept(self.packet(seq=2), sent_at=111, now=111)
        self.rejected("replay", packet, now=112, current_interval=30)

    def test_unsigned_and_malformed_reports_never_produce_signal_bytes(self):
        for data in (self.base(), self.base()[:-1], self.packet()[:-1], self.packet() + b"\0"):
            self.rejected("invalid_format", data)
        self.assertFalse(self.gate.has_fresh_report(101, 1))

    def test_invalid_signing_lengths(self):
        for base, key, report_nonce, packet_nonce in (
            (self.base()[:-1], self.key, self.session, self.nonce),
            (self.base(), UnlockKey(1, b"x"), self.session, self.nonce),
            (self.base(), self.key, b"x", self.nonce),
            (self.base(), self.key, self.session, b"x"),
        ):
            with self.assertRaises(ValueError):
                AuthenticatedReportProtocol.sign(base, key, report_nonce, packet_nonce)

    def test_disconnect_clears_only_target_and_replay_cannot_restore_proof(self):
        first = self.packet()
        self.accept(first, central="first")
        self.accept(self.packet(nonce=b"\x55" * 8), central="second")
        self.gate.clear_presence("first")
        self.assertFalse(self.gate.is_fresh("first", 102, 1))
        self.assertTrue(self.gate.is_fresh("second", 102, 1))
        self.rejected("replay", first, central="first", now=102)
        self.assertFalse(self.gate.is_fresh("first", 102, 1))
        self.accept(self.packet(nonce=b"\xaa" * 8), central="first", now=102)
        self.assertTrue(self.gate.is_fresh("first", 102, 1))
        self.gate.clear_all_presence()
        self.assertFalse(self.gate.has_fresh_report(102, 1))

    def test_presence_uses_current_tier_and_rejects_clock_rollback(self):
        self.accept(self.packet())
        self.assertTrue(self.gate.is_fresh("trusted", 111, 1))
        self.assertFalse(self.gate.is_fresh("trusted", 111.01, 1))
        self.assertTrue(self.gate.is_fresh("trusted", 136, 30))
        self.assertFalse(self.gate.is_fresh("trusted", 136.01, 30))
        self.assertFalse(self.gate.is_fresh("trusted", 100, 1))
        self.assertFalse(self.gate.is_fresh("trusted", 102, -1))
        self.assertFalse(self.gate.is_fresh("trusted", 102, 31))

    def test_presence_guard_prevents_unauthenticated_reservation_or_consumption(self):
        unlock = UnlockGate(self.key)
        unlock.sync(123, 100)
        self.accept(self.packet())
        self.rejected("invalid_format", self.base(), central="stranger")

        def challenge(central):
            if not self.gate.is_fresh(central, 101, 1):
                raise UnlockError(UnlockStatus.UNAVAILABLE)
            return unlock.challenge(central, 101)

        def authorize(data, central):
            if not self.gate.is_fresh(central, 101, 1):
                raise UnlockError(UnlockStatus.UNAVAILABLE)
            unlock.authorize(data, central, 101, eligible=True)

        with self.assertRaises(UnlockError):
            challenge("stranger")
        wire = challenge("trusted")
        with self.assertRaises(UnlockError):
            challenge("stranger")
        with self.assertRaises(UnlockError):
            authorize(b"", "stranger")
        self.assertEqual(unlock.failures, 0)
        authorize(UnlockProtocol.command(self.key, UnlockProtocol.parse_challenge(wire)), "trusted")
        self.assertTrue(unlock.in_flight)


if __name__ == "__main__":
    unittest.main()
