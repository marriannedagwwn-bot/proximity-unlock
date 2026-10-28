"""Fail-closed adapter between the ordinary BLE peer and the installed native helper.

The peer receives only the random phone key. Passwords are never returned by this
module/helper. The SYSTEM provider separately authenticates every local IPC
request; accepting a pipe write or serializing a password is never success here.
"""
from __future__ import annotations

import ctypes
from ctypes import wintypes
from dataclasses import dataclass, field
import json
import os
from pathlib import Path
import struct
import subprocess
import sys

_CLSID = "{908BDBA7-6A55-4C85-B4AB-33B7D99A76C0}"
_USER_SIZE = 464


def _decode_enrollment(plain: bytes) -> tuple[int, bytes, str]:
    if len(plain) != _USER_SIZE:
        raise ValueError("invalid enrollment size")
    magic, version, key_id = struct.unpack_from("<8sII", plain)
    if magic != b"PRXUSER1" or version != 1 or not key_id:
        raise ValueError("invalid enrollment header")
    sid_bytes = plain[80:]
    if sid_bytes[-2:] != b"\0\0":
        raise ValueError("unterminated enrollment SID")
    sid = sid_bytes.decode("utf-16-le").split("\0", 1)[0]
    if not sid.startswith("S-1-5-21-") or len(sid) > 184:
        raise ValueError("invalid local account SID")
    return key_id, plain[16:48], sid


def _unprotect(path: Path) -> bytes:
    class Blob(ctypes.Structure):
        _fields_ = [("size", wintypes.DWORD), ("data", ctypes.POINTER(ctypes.c_ubyte))]

    encrypted = path.read_bytes()
    if not 0 < len(encrypted) <= 16384:
        raise ValueError("invalid protected enrollment size")
    buffer = (ctypes.c_ubyte * len(encrypted)).from_buffer_copy(encrypted)
    source = Blob(len(encrypted), buffer)
    target = Blob()
    crypt = ctypes.WinDLL("crypt32", use_last_error=True)
    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    crypt.CryptUnprotectData.argtypes = [ctypes.POINTER(Blob), ctypes.c_void_p, ctypes.c_void_p,
                                        ctypes.c_void_p, ctypes.c_void_p, wintypes.DWORD,
                                        ctypes.POINTER(Blob)]
    crypt.CryptUnprotectData.restype = wintypes.BOOL
    kernel.LocalFree.argtypes = [ctypes.c_void_p]
    kernel.LocalFree.restype = ctypes.c_void_p
    if not crypt.CryptUnprotectData(ctypes.byref(source), None, None, None, None, 1, ctypes.byref(target)):
        raise OSError(ctypes.get_last_error(), "local enrollment cannot be decrypted")
    try:
        return ctypes.string_at(target.data, target.size)
    finally:
        ctypes.memset(target.data, 0, target.size)
        kernel.LocalFree(target.data)


def _installed_helper(key_id: int, sid: str) -> Path | None:
    import winreg

    access = winreg.KEY_READ | winreg.KEY_WOW64_64KEY
    with winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE, r"SOFTWARE\ProximityUnlock", 0, access) as key:
        registered_sid, sid_type = winreg.QueryValueEx(key, "TargetSid")
        registered_id, id_type = winreg.QueryValueEx(key, "KeyId")
        verified_id, verified_type = winreg.QueryValueEx(key, "VerifiedKeyId")
    if (sid_type != winreg.REG_SZ or id_type != winreg.REG_DWORD or
            registered_sid != sid or registered_id != key_id or
            verified_type != winreg.REG_DWORD or verified_id != key_id):
        return None
    directory = Path(os.environ["ProgramFiles"]) / "ProximityUnlock"
    with winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE,
                        rf"SOFTWARE\Classes\CLSID\{_CLSID}\InprocServer32", 0, access) as key:
        registered_dll, value_type = winreg.QueryValueEx(key, "")
    dll = directory / "ProximityCredentialProvider.dll"
    if value_type != winreg.REG_SZ or os.path.normcase(registered_dll) != os.path.normcase(str(dll)):
        return None
    with winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE,
                        rf"SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\Credential Providers\{_CLSID}",
                        0, access) as key:
        try:
            disabled, disabled_type = winreg.QueryValueEx(key, "Disabled")
            if disabled_type != winreg.REG_DWORD or disabled:
                return None
        except FileNotFoundError:
            pass
    helper = directory / "ProximityUnlock.exe"
    return helper if helper.is_file() and dll.is_file() else None


def _run(helper: Path, command: str, timeout: float) -> dict:
    result = subprocess.run([str(helper), command], stdin=subprocess.DEVNULL,
                            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                            timeout=timeout, check=False,
                            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
    if len(result.stdout) > 2048:
        return {}
    value = json.loads(result.stdout)
    return value if isinstance(value, dict) else {}


@dataclass(repr=False)
class WindowsUnlockBackend:
    key_id: int
    secret: bytes = field(repr=False)
    _sid: str = field(repr=False)
    _helper: Path = field(repr=False)

    def available(self) -> bool:
        try:
            if _installed_helper(self.key_id, self._sid) != self._helper:
                return False
            # Re-read DPAPI state so deleting/rotating enrollment revokes an already
            # running worker, even if it still holds an old phone key in memory.
            fresh = _decode_enrollment(_unprotect(Path(os.environ["LOCALAPPDATA"]) /
                                                  "ProximityUnlock" / "enrollment.bin"))
            if fresh != (self.key_id, self.secret, self._sid):
                return False
            status = _run(self._helper, "status", 1.0)
            return status.get("available") is True and status.get("localConsole") is True
        except (OSError, ValueError, KeyError, subprocess.SubprocessError):
            return False

    def unlock(self) -> bool:
        # Exactly one native request. A timeout means unconfirmed, never a retry.
        try:
            if not self.available():
                return False
            return _run(self._helper, "request", 5.8).get("success") is True
        except (OSError, ValueError, subprocess.SubprocessError):
            return False


def load_backend() -> WindowsUnlockBackend | None:
    if sys.platform != "win32":
        return None
    try:
        key_id, phone_key, sid = _decode_enrollment(_unprotect(
            Path(os.environ["LOCALAPPDATA"]) / "ProximityUnlock" / "enrollment.bin"))
        helper = _installed_helper(key_id, sid)
        if helper is None:
            return None
        backend = WindowsUnlockBackend(key_id, phone_key, sid, helper)
        return backend if backend.available() else None
    except (OSError, ValueError, KeyError, subprocess.SubprocessError):
        return None
