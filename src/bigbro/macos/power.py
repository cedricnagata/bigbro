"""Keeps the Mac awake while bigbro is running, via an IOKit power assertion.

Uses `PreventSystemSleep` — the same assertion `caffeinate -s` takes — so the Mac
stays running even with the lid closed *while on AC power*. On battery, macOS still
enforces clamshell sleep and this assertion is overridden. Display sleep is still
allowed. Idempotent.

The Swift original paired this with `ProcessInfo.beginActivity(.idleSystemSleepDisabled)`.
That is dropped here: it has no cheap ctypes equivalent, and it was always the
redundant half — `beginActivity` is a Foundation convenience over this same power
management mechanism, so the assertion below is what actually held the Mac awake.
"""

from __future__ import annotations

import ctypes
import ctypes.util
import logging

log = logging.getLogger("bigbro.power")

_ASSERTION_TYPE = "PreventSystemSleep"  # kIOPMAssertionTypePreventSystemSleep
_LEVEL_ON = 255                         # kIOPMAssertionLevelOn
_RETURN_SUCCESS = 0                     # kIOReturnSuccess
_UTF8 = 0x08000100                      # kCFStringEncodingUTF8

_CFStringRef = ctypes.c_void_p
_IOPMAssertionID = ctypes.c_uint32

_libs: tuple | None = None


def _frameworks() -> tuple:
    """Binds IOKit and CoreFoundation, once, on first use.

    Deferred rather than done at import so this module stays importable off macOS,
    which keeps `PowerAssertion` mockable in tests that never touch a real assertion.
    """
    global _libs
    if _libs is not None:
        return _libs

    iokit = ctypes.CDLL("/System/Library/Frameworks/IOKit.framework/IOKit")
    cf = ctypes.CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")

    cf.CFStringCreateWithCString.restype = _CFStringRef
    cf.CFStringCreateWithCString.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_uint32]

    cf.CFRelease.restype = None
    cf.CFRelease.argtypes = [ctypes.c_void_p]

    iokit.IOPMAssertionCreateWithName.restype = ctypes.c_int
    iokit.IOPMAssertionCreateWithName.argtypes = [
        _CFStringRef,                        # assertion type
        ctypes.c_uint32,                     # level
        _CFStringRef,                        # human-readable reason
        ctypes.POINTER(_IOPMAssertionID),    # out
    ]

    iokit.IOPMAssertionRelease.restype = ctypes.c_int
    iokit.IOPMAssertionRelease.argtypes = [_IOPMAssertionID]

    _libs = (iokit, cf)
    return _libs


def _cfstr(cf, value: str) -> _CFStringRef:
    ref = cf.CFStringCreateWithCString(None, value.encode(), _UTF8)
    if not ref:
        raise OSError(f"CFStringCreateWithCString failed for {value!r}")
    return ref


class PowerAssertion:
    """Holds a system power assertion for as long as it is acquired."""

    def __init__(self) -> None:
        self._assertion_id = _IOPMAssertionID(0)
        self._held = False

    @property
    def held(self) -> bool:
        return self._held

    def acquire(self, reason: str) -> None:
        if self._held:
            return

        iokit, cf = _frameworks()
        assertion_type = _cfstr(cf, _ASSERTION_TYPE)
        assertion_name = _cfstr(cf, reason)
        try:
            result = iokit.IOPMAssertionCreateWithName(
                assertion_type, _LEVEL_ON, assertion_name,
                ctypes.byref(self._assertion_id),
            )
        finally:
            cf.CFRelease(assertion_type)
            cf.CFRelease(assertion_name)

        if result == _RETURN_SUCCESS:
            self._held = True
            log.info("keeping the Mac awake (%s)", reason)
        else:
            # Not fatal — the daemon still serves requests, the Mac may just nap.
            log.error("failed to acquire power assertion: %s", result)

    def release(self) -> None:
        if not self._held:
            return
        _frameworks()[0].IOPMAssertionRelease(self._assertion_id)
        self._assertion_id = _IOPMAssertionID(0)
        self._held = False
        log.info("released power assertion — the Mac may sleep normally again")

    def __enter__(self) -> "PowerAssertion":
        return self

    def __exit__(self, *_exc) -> None:
        self.release()
