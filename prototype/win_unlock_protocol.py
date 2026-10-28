"""Portable v3 authentication shared by the Windows BLE and unlock boundaries.

All ``now`` and ``sent_at`` values must come from the same monotonic clock.
``sent_at`` must be looked up in this worker's actually sent heartbeat table,
never taken from a phone packet. These objects are used on the BLE event loop;
they are not shared across threads. No Windows APIs or third-party packages are
needed here, so the fixed wire vectors can also be checked on Mac and Linux.

The caller must check subscription and AuthenticatedReportGate.is_fresh() for
the requesting connection *before* sync(), challenge(), or authorize(). A
disconnect must clear that connection's presence and pending challenge. Neither
a successful signature nor authorize() means that Windows actually unlocked:
finish() must receive the separately verified operating-system result.
"""

from dataclasses import dataclass
from enum import IntEnum
import hashlib
import hmac
import math
import secrets
import struct


CHALLENGE_UUID = "0c28c82e-69ec-4cd1-ab3b-ea7e160fcd3c"
UNLOCK_UUID = "54cd9a6f-36e3-4c39-b875-bbeee5f1aef1"
ENROLL_ACK_UUID = "be282b23-6b55-4b86-86ea-b7f8f3c273e3"
# 手机请电脑显示登记码（docs/protocol.md「手机请求显示登记码」）：有没有登记都开放，内容 1 字节 0x01
ENROLL_REQUEST_UUID = "3465d7ce-93d4-4d36-9c16-0619b8ebadbf"
ENROLL_REQUEST_V1 = b"\x01"
CAPABILITY = "win-hmac-v3"


@dataclass(frozen=True)
class UnlockKey:
    """Offline enrollment key; id is UInt32 and secret must contain 32 bytes."""

    id: int
    secret: bytes

    def __post_init__(self):
        if not isinstance(self.id, int) or not 0 <= self.id <= 0xFFFFFFFF:
            raise ValueError("key id must be UInt32")
        object.__setattr__(self, "secret", bytes(self.secret))


@dataclass(frozen=True)
class Challenge:
    prompt_id: int
    nonce: bytes

    @property
    def data(self):
        if not 0 <= self.prompt_id <= 0xFFFF or len(self.nonce) != 16:
            raise ValueError("challenge must have a UInt16 prompt and 16-byte nonce")
        return struct.pack("<H16s", self.prompt_id, self.nonce)


class UnlockProtocol:
    challenge_uuid = CHALLENGE_UUID
    command_uuid = UNLOCK_UUID
    capability = CAPABILITY
    challenge_length = 18
    command_length = 22
    Challenge = Challenge

    @staticmethod
    def parse_challenge(data):
        if len(data) != UnlockProtocol.challenge_length:
            return None
        return Challenge(*struct.unpack("<H16s", data))

    @staticmethod
    def tag(key, challenge):
        if len(key.secret) != 32:
            raise ValueError("unlock key must contain 32 bytes")
        return hmac.new(key.secret, b"unlock-v2" + challenge.data, hashlib.sha256).digest()[:16]

    @staticmethod
    def command(key, challenge):
        return struct.pack("<IH", key.id, challenge.prompt_id) + UnlockProtocol.tag(key, challenge)


class UnlockStatus(IntEnum):
    UNAVAILABLE = 0x80
    INVALID_SIGNATURE = 0x81
    INVALID_CHALLENGE = 0x82
    EXECUTION_FAILED = 0x83


class UnlockError(Exception):
    """ATT application error. Only status, never credentials, belongs in replies."""

    def __init__(self, status):
        self.status = UnlockStatus(status)
        super().__init__(self.status.name.lower())


def _finite(value):
    try:
        return math.isfinite(value)
    except (TypeError, ValueError, OverflowError):
        return False


class UnlockGate:
    """One expiring challenge, bound to a prompt and a connection identifier.

    challenge() returns its wire bytes. authorize() returns None on success and
    holds in_flight until finish(); both operations otherwise raise UnlockError.
    A different central cannot consume an existing challenge or its failure
    budget, even if an integration accidentally omits its presence check.
    """

    def __init__(self, key, lifetime=120, maximum_failures=3):
        self.key = key
        self.lifetime = lifetime
        self.maximum_failures = maximum_failures
        self.prompt_id = None
        self._last_prompt_id = None
        self._prompt_started = None
        self._pending = None
        self._authorizing_prompt_id = None
        self.failures = 0
        self.in_flight = False

    def sync(self, prompt_id, now):
        """None revokes the prompt. Reusing an id cannot renew its lifetime."""
        if prompt_id is not None and (
            not isinstance(prompt_id, int) or not 0 <= prompt_id <= 0xFFFF
        ):
            raise ValueError("prompt id must be UInt16 or None")
        if self.prompt_id == prompt_id:
            return
        self.prompt_id = prompt_id
        self._pending = None
        if prompt_id is not None and prompt_id != self._last_prompt_id:
            self._prompt_started = now
            self.failures = 0
            self._last_prompt_id = prompt_id
        # An already submitted system operation must complete before another.

    def _valid_time(self, now):
        return (
            _finite(now)
            and _finite(self._prompt_started)
            and _finite(self.lifetime)
            and self.lifetime >= 0
            and now >= self._prompt_started
            and now - self._prompt_started <= self.lifetime
        )

    def _available(self):
        return (
            self.prompt_id is not None
            and self.prompt_id != 0
            and len(self.key.secret) == 32
            and not self.in_flight
            and isinstance(self.maximum_failures, int)
            and self.maximum_failures > 0
            and self.failures < self.maximum_failures
        )

    def challenge(self, central, now, nonce=None):
        if not central or not self._available():
            raise UnlockError(UnlockStatus.UNAVAILABLE)
        if not self._valid_time(now):
            self._pending = None
            raise UnlockError(UnlockStatus.INVALID_CHALLENGE)
        if self._pending is not None:
            owner, challenge = self._pending
            if owner != central:
                raise UnlockError(UnlockStatus.UNAVAILABLE)
            return challenge.data
        nonce = secrets.token_bytes(16) if nonce is None else bytes(nonce)
        if len(nonce) != 16:
            raise UnlockError(UnlockStatus.INVALID_CHALLENGE)
        challenge = Challenge(self.prompt_id, nonce)
        self._pending = (central, challenge)
        return challenge.data

    def _failed(self, status):
        self.failures += 1
        raise UnlockError(status)

    def authorize(self, data, central, now, eligible):
        # Do not let a different connection clear the owner's pending nonce,
        # including through an ineligible request. Presence is checked outside.
        if not central or (self._pending is not None and self._pending[0] != central):
            raise UnlockError(UnlockStatus.UNAVAILABLE)
        if not eligible:
            self._pending = None
            raise UnlockError(UnlockStatus.UNAVAILABLE)
        if not self._available():
            raise UnlockError(UnlockStatus.UNAVAILABLE)
        if self._pending is None:
            self._failed(UnlockStatus.INVALID_CHALLENGE)
        _, challenge = self._pending
        self._pending = None  # Every owner attempt consumes the nonce.
        if not self._valid_time(now):
            self._failed(UnlockStatus.INVALID_CHALLENGE)
        if len(data) != UnlockProtocol.command_length:
            self._failed(UnlockStatus.INVALID_SIGNATURE)
        key_id, prompt_id = struct.unpack_from("<IH", data)
        if key_id != self.key.id or prompt_id != self.prompt_id:
            self._failed(UnlockStatus.UNAVAILABLE)
        if not hmac.compare_digest(UnlockProtocol.tag(self.key, challenge), data[6:22]):
            self._failed(UnlockStatus.INVALID_SIGNATURE)
        self.in_flight = True
        self._authorizing_prompt_id = self.prompt_id

    def finish(self, succeeded=True):
        if self.in_flight and not succeeded and self.prompt_id == self._authorizing_prompt_id:
            self.failures += 1
        self.in_flight = False
        self._pending = None
        self._authorizing_prompt_id = None

    def clear_central(self, central):
        """Disconnect drops only that central's nonce, not another's operation."""
        if self._pending is not None and self._pending[0] == central:
            self._pending = None


class AuthenticatedReportProtocol:
    packet_length = 35

    @staticmethod
    def sequence(data):
        return struct.unpack_from("<I", data)[0] if len(data) >= 4 else None

    @staticmethod
    def sign(base_report, key, report_nonce, packet_nonce):
        """Return the 35-byte v3 envelope; invalid codec inputs raise ValueError."""
        if (
            len(base_report) != 7 or len(key.secret) != 32
            or len(report_nonce) != 16 or len(packet_nonce) != 8
        ):
            raise ValueError("invalid authenticated report lengths")
        prefix = bytes(base_report) + struct.pack("<I", key.id) + bytes(packet_nonce)
        message = b"proximity-report-v1" + bytes(report_nonce) + prefix
        return prefix + hmac.new(key.secret, message, hashlib.sha256).digest()[:16]


class EnrollAckProtocol:
    """The iPhone confirms it saved an offline enrollment, so the local enrollment window can close.

    20 bytes: keyID (UInt32 LE) + HMAC-SHA256(secret, b"enroll-ack-v1" + reportNonce + keyID)[:16],
    bound to this BLE session's INFO reportNonce. It never authorizes an unlock or counts as presence;
    a replay within the same session can only close a window again.
    """

    length = 20

    @staticmethod
    def key_id(data):
        return struct.unpack_from("<I", data)[0] if len(data) == EnrollAckProtocol.length else None

    @staticmethod
    def sign(key, report_nonce):
        if len(key.secret) != 32 or len(report_nonce) != 16:
            raise ValueError("invalid enrollment acknowledgement lengths")
        key_id = struct.pack("<I", key.id)
        message = b"enroll-ack-v1" + bytes(report_nonce) + key_id
        return key_id + hmac.new(key.secret, message, hashlib.sha256).digest()[:16]

    @staticmethod
    def verify(data, key, report_nonce):
        return (len(data) == EnrollAckProtocol.length
                and hmac.compare_digest(bytes(data), EnrollAckProtocol.sign(key, report_nonce)))


class ReportAuthenticationError(Exception):
    """A rejected envelope exposes a reason, never unverified base-report data."""

    def __init__(self, reason):
        self.reason = reason
        super().__init__(reason)


class AuthenticatedReportGate:
    def __init__(self, key, report_nonce, maximum_interval=30):
        self.key = key
        self.report_nonce = bytes(report_nonce)
        self.maximum_interval = maximum_interval
        self._seen_tags = {}
        self._verified_centrals = {}

    def _valid_interval(self, current_interval):
        return (
            _finite(self.maximum_interval) and self.maximum_interval >= 0
            and _finite(current_interval)
            and 0 <= current_interval <= self.maximum_interval
        )

    def accept(self, data, central=None, sent_at=None, now=None, current_interval=1):
        """Return exactly seven authenticated bytes or ReportAuthenticationError.

        Changing the heartbeat tier cannot shorten replay retention. Clearing a
        connection's proof deliberately retains replay tags, so reconnecting
        cannot restore proof with a captured old packet.
        """
        if (
            len(self.key.secret) != 32 or len(self.report_nonce) != 16
            or not _finite(now) or not self._valid_interval(current_interval)
        ):
            raise ReportAuthenticationError("invalid_configuration")
        retention = max(10, self.maximum_interval + 5)
        self._seen_tags = {
            tag: sent for tag, sent in self._seen_tags.items() if now - sent <= retention
        }
        if len(data) != AuthenticatedReportProtocol.packet_length:
            raise ReportAuthenticationError("invalid_format")
        if struct.unpack_from("<I", data, 7)[0] != self.key.id:
            raise ReportAuthenticationError("wrong_key")
        if (
            not _finite(sent_at) or now < sent_at
            or now - sent_at > max(10, current_interval + 5)
        ):
            raise ReportAuthenticationError("stale_heartbeat")
        prefix = bytes(data[:19])
        message = b"proximity-report-v1" + self.report_nonce + prefix
        expected = hmac.new(self.key.secret, message, hashlib.sha256).digest()[:16]
        supplied = bytes(data[19:35])
        if not hmac.compare_digest(expected, supplied):
            raise ReportAuthenticationError("invalid_signature")
        if supplied in self._seen_tags:
            raise ReportAuthenticationError("replay")
        self._seen_tags[supplied] = sent_at
        if central is not None:
            self._verified_centrals[central] = now
        return bytes(data[:7])

    def _fresh(self, timestamp, now, current_interval):
        return (
            _finite(now) and _finite(timestamp) and self._valid_interval(current_interval)
            and now >= timestamp and now - timestamp <= max(10, current_interval + 5)
        )

    def is_fresh(self, central, now, current_interval):
        timestamp = self._verified_centrals.get(central)
        return timestamp is not None and self._fresh(timestamp, now, current_interval)

    def has_fresh_report(self, now, current_interval):
        return any(self._fresh(t, now, current_interval) for t in self._verified_centrals.values())

    def clear_presence(self, central):
        self._verified_centrals.pop(central, None)

    def clear_all_presence(self):
        self._verified_centrals.clear()
