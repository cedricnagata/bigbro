"""Bonjour (mDNS) service advertisement via the native DNS-SD C API.

Binds `DNSServiceRegister` out of libSystem directly with ctypes. That is the same
API Foundation's `NetService` sits on, so the service is registered with the real
mDNSResponder — the one every other Bonjour client on the Mac already talks to —
rather than by standing up a second, parallel mDNS stack alongside it the way a
pure-Python implementation must.

The socket DNS-SD hands back is registered with the asyncio loop rather than
polled from a thread, so responses are processed on the same loop as everything
else and there is nothing to join at shutdown.
"""

from __future__ import annotations

import asyncio
import ctypes
import ctypes.util
import logging
import socket
import subprocess

log = logging.getLogger("bigbro.bonjour")

SERVICE_TYPE = "_bigbro._tcp"
SERVICE_DOMAIN = "local."
TXT_VERSION = "1.0"

_NO_ERROR = 0

_DNSServiceRef = ctypes.c_void_p
_DNSServiceErrorType = ctypes.c_int32

# void (*)(DNSServiceRef, DNSServiceFlags, DNSServiceErrorType,
#          const char *name, const char *regtype, const char *domain, void *context)
_RegisterReply = ctypes.CFUNCTYPE(
    None,
    _DNSServiceRef,
    ctypes.c_uint32,
    _DNSServiceErrorType,
    ctypes.c_char_p,
    ctypes.c_char_p,
    ctypes.c_char_p,
    ctypes.c_void_p,
)

_lib = None


def _dnssd():
    """Binds the DNS-SD entry points out of libSystem, once, on first use.

    Deferred rather than done at import so this module stays importable off macOS —
    `encode_txt_record` is pure and has tests that should not need a Mac to run.
    """
    global _lib
    if _lib is not None:
        return _lib

    lib = ctypes.CDLL(ctypes.util.find_library("System") or "/usr/lib/libSystem.dylib")

    lib.DNSServiceRegister.restype = _DNSServiceErrorType
    lib.DNSServiceRegister.argtypes = [
        ctypes.POINTER(_DNSServiceRef),  # sdRef (out)
        ctypes.c_uint32,                 # flags
        ctypes.c_uint32,                 # interfaceIndex (0 = all)
        ctypes.c_char_p,                 # name
        ctypes.c_char_p,                 # regtype
        ctypes.c_char_p,                 # domain
        ctypes.c_char_p,                 # host
        ctypes.c_uint16,                 # port, network byte order
        ctypes.c_uint16,                 # txtLen
        ctypes.c_void_p,                 # txtRecord
        _RegisterReply,                  # callBack
        ctypes.c_void_p,                 # context
    ]

    lib.DNSServiceRefSockFD.restype = ctypes.c_int
    lib.DNSServiceRefSockFD.argtypes = [_DNSServiceRef]

    lib.DNSServiceProcessResult.restype = _DNSServiceErrorType
    lib.DNSServiceProcessResult.argtypes = [_DNSServiceRef]

    lib.DNSServiceRefDeallocate.restype = None
    lib.DNSServiceRefDeallocate.argtypes = [_DNSServiceRef]

    _lib = lib
    return _lib


def encode_txt_record(pairs: dict[str, str]) -> bytes:
    """Encodes key=value pairs into DNS-SD's length-prefixed TXT wire format.

    Each entry is one length byte followed by that many bytes of `key=value`, which
    caps any single entry at 255 bytes.
    """
    out = bytearray()
    for key, value in pairs.items():
        entry = f"{key}={value}".encode()
        if len(entry) > 255:
            raise ValueError(f"TXT entry '{key}' is {len(entry)} bytes, max 255")
        out.append(len(entry))
        out += entry
    return bytes(out)


def computer_name() -> str:
    """The Mac's friendly name, matching what `Host.current().localizedName` returned.

    `scutil` is the same store System Settings writes, so this is "Cedric's MacBook Pro"
    rather than the `.local` hostname. Falls back to the hostname if scutil is
    unavailable or returns nothing.
    """
    try:
        result = subprocess.run(
            ["scutil", "--get", "ComputerName"],
            capture_output=True, text=True, timeout=2, check=False,
        )
        name = result.stdout.strip()
        if name:
            return name
    except (OSError, subprocess.SubprocessError):
        pass
    return socket.gethostname()


class BonjourAdvertiser:
    """Publishes `_bigbro._tcp.` on the local network for as long as it is started."""

    def __init__(self) -> None:
        self._ref = _DNSServiceRef()
        self._fd: int | None = None
        self._loop: asyncio.AbstractEventLoop | None = None
        # The CFUNCTYPE object must outlive the registration — ctypes does not
        # retain it, and letting it be collected leaves mDNSResponder calling into
        # freed memory.
        self._callback = _RegisterReply(self._on_registered)

    def start(self, port: int, name: str | None = None) -> None:
        if self._fd is not None:
            return

        service_name = name or computer_name()
        txt = encode_txt_record({"version": TXT_VERSION, "port": str(port)})

        lib = _dnssd()
        error = lib.DNSServiceRegister(
            ctypes.byref(self._ref),
            0,                                  # flags
            0,                                  # all interfaces
            service_name.encode(),
            SERVICE_TYPE.encode(),
            SERVICE_DOMAIN.encode(),
            None,                               # host: this machine
            socket.htons(port),
            len(txt),
            ctypes.cast(ctypes.c_char_p(txt), ctypes.c_void_p),
            self._callback,
            None,
        )
        if error != _NO_ERROR:
            raise OSError(f"DNSServiceRegister failed: {error}")

        self._fd = lib.DNSServiceRefSockFD(self._ref)
        self._loop = asyncio.get_running_loop()
        self._loop.add_reader(self._fd, self._process)

    def stop(self) -> None:
        """Deregisters the service. Browsers see it disappear immediately rather than
        holding a stale record until its TTL expires."""
        if self._fd is None:
            return
        if self._loop is not None:
            self._loop.remove_reader(self._fd)
        _dnssd().DNSServiceRefDeallocate(self._ref)
        self._ref = _DNSServiceRef()
        self._fd = None
        self._loop = None
        log.info("unpublished %s", SERVICE_TYPE)

    def _process(self) -> None:
        error = _dnssd().DNSServiceProcessResult(self._ref)
        if error != _NO_ERROR:
            log.error("DNSServiceProcessResult failed: %s", error)
            self.stop()

    def _on_registered(self, _ref, _flags, error, name, regtype, domain, _ctx) -> None:
        if error != _NO_ERROR:
            log.error("failed to publish: %s", error)
            return
        log.info(
            "published %s as %s%s",
            (name or b"").decode(), (regtype or b"").decode(), (domain or b"").decode(),
        )
