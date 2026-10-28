import json
from contextlib import nullcontext
from pathlib import Path
import struct
import subprocess
import unittest
from types import SimpleNamespace
from unittest.mock import patch

from windows_unlock import backend


def fixture(key_id=41, secret=b"p" * 32, sid="S-1-5-21-1-2-3-1001"):
    return struct.pack("<8sII32s32s384s", b"PRXUSER1", 1, key_id, secret,
                       b"i" * 32, (sid + "\0").encode("utf-16-le"))


class EnrollmentTests(unittest.TestCase):
    def test_only_phone_key_is_exposed(self):
        self.assertEqual(backend._decode_enrollment(fixture()),
                         (41, b"p" * 32, "S-1-5-21-1-2-3-1001"))

    def test_corrupt_or_unsupported_enrollment_rejected(self):
        for value in (b"", fixture()[:-1], b"badmagic" + fixture()[8:], fixture(key_id=0),
                      fixture(sid="S-1-5-18"), fixture()[:-2] + b"XX"):
            with self.subTest(size=len(value)):
                with self.assertRaises(ValueError):
                    backend._decode_enrollment(value)


class BackendTests(unittest.TestCase):
    def setUp(self):
        self.helper = Path("native-helper-fixture.exe")
        self.value = backend.WindowsUnlockBackend(41, b"p" * 32,
                                                   "S-1-5-21-1-2-3-1001", self.helper)

    def test_missing_or_rotated_registration_revokes_backend(self):
        with patch.object(backend, "_installed_helper", return_value=None), patch.object(backend, "_run") as run:
            self.assertFalse(self.value.available())
            run.assert_not_called()

    def test_provisional_and_stale_verified_generation_never_load(self):
        for verified in (0, 40, 42):
            with self.subTest(verified=verified):
                fake = SimpleNamespace(KEY_READ=1, KEY_WOW64_64KEY=2,
                                       HKEY_LOCAL_MACHINE=3, REG_SZ=1, REG_DWORD=4)
                values = {"TargetSid": (self.value._sid, 1), "KeyId": (41, 4),
                          "VerifiedKeyId": (verified, 4)}
                fake.OpenKey = lambda *args: nullcontext(values)
                fake.QueryValueEx = lambda key, name: key[name]
                with patch.dict(backend.sys.modules, {"winreg": fake}):
                    self.assertIsNone(backend._installed_helper(41, self.value._sid))

    def test_dpapi_deletion_and_rotated_key_revoke_backend(self):
        for protected in (OSError("removed"), fixture(key_id=42), fixture(secret=b"q" * 32)):
            with self.subTest(protected=type(protected).__name__):
                with patch.object(backend, "_installed_helper", return_value=self.helper), patch.dict(backend.os.environ, {"LOCALAPPDATA": "fixture"}), \
                        patch.object(backend, "_unprotect", side_effect=protected if isinstance(protected, Exception) else None,
                                     return_value=protected), patch.object(backend, "_run") as run:
                    self.assertFalse(self.value.available())
                    run.assert_not_called()

    def test_requires_actual_native_boolean_unlock_confirmation(self):
        for result in ({}, {"success": False}, {"success": "true"}, {"success": 1}, {"success": True}):
            with self.subTest(result=result):
                with patch.object(self.value, "available", return_value=True), patch.object(backend, "_run", return_value=result) as run:
                    self.assertEqual(self.value.unlock(), result.get("success") is True)
                    run.assert_called_once_with(self.helper, "request", 5.8)

    def test_failure_or_timeout_never_retries(self):
        for error in (OSError("unavailable"), subprocess.TimeoutExpired("fixture", 5.8), json.JSONDecodeError("bad", "", 0)):
            with self.subTest(error=type(error).__name__):
                with patch.object(self.value, "available", return_value=True), patch.object(backend, "_run", side_effect=error) as run:
                    self.assertFalse(self.value.unlock())
                    self.assertEqual(run.call_count, 1)

    def test_unavailable_never_requests(self):
        with patch.object(self.value, "available", return_value=False), patch.object(backend, "_run") as run:
            self.assertFalse(self.value.unlock())
            run.assert_not_called()


if __name__ == "__main__":
    unittest.main()
