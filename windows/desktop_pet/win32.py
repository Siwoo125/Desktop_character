"""Small, public Win32 API boundary. No keyboard hooks, screenshots or admin rights."""
from __future__ import annotations

import ctypes
from ctypes import wintypes
from dataclasses import dataclass
import os

from .physics import DesktopWindow, Point, Rect


@dataclass(frozen=True)
class NativeRect:
    left: int
    top: int
    right: int
    bottom: int


@dataclass(frozen=True)
class Monitor:
    name: str
    bounds: NativeRect
    work: NativeRect


@dataclass(frozen=True)
class ScreenSpace:
    """Map native physical pixels to the current Qt monitor's logical points.

    Qt screen origins are not divided by DPI on Windows. Map relative to BOTH
    origins, rather than dividing global coordinates (which breaks mixed DPI).
    """
    bounds: NativeRect
    logical_origin: Point
    ratio: float

    def to_world(self, native: Point) -> Point:
        return Point(self.logical_origin.x + (native.x - self.bounds.left) / self.ratio,
                     -(self.logical_origin.y + (native.y - self.bounds.top) / self.ratio))

    def to_native(self, world: Point) -> Point:
        return Point(round(self.bounds.left + (world.x - self.logical_origin.x) * self.ratio),
                     round(self.bounds.top + (-world.y - self.logical_origin.y) * self.ratio))

    def rect(self, native: NativeRect) -> Rect:
        a, b = self.to_world(Point(native.left, native.top)), self.to_world(Point(native.right, native.bottom))
        return Rect(a.x, b.y, b.x - a.x, a.y - b.y)


class Win32:
    def __init__(self):
        if os.name != "nt":
            raise RuntimeError("이 실행부는 Windows에서 사용하세요. macOS에서는 실행.command를 사용하세요.")
        self.user = ctypes.WinDLL("user32", use_last_error=True)
        self.dwm = ctypes.WinDLL("dwmapi", use_last_error=True)
        self.enum_callback = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)
        self.monitor_callback = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HANDLE, wintypes.HDC,
                                                  ctypes.POINTER(wintypes.RECT), wintypes.LPARAM)

        def api(library, name, args, result):
            method = getattr(library, name)
            method.argtypes, method.restype = args, result
            return method

        self._enum = api(self.user, "EnumWindows", [self.enum_callback, wintypes.LPARAM], wintypes.BOOL)
        self._visible = api(self.user, "IsWindowVisible", [wintypes.HWND], wintypes.BOOL)
        self._iconic = api(self.user, "IsIconic", [wintypes.HWND], wintypes.BOOL)
        self._pid = api(self.user, "GetWindowThreadProcessId", [wintypes.HWND, ctypes.POINTER(wintypes.DWORD)], wintypes.DWORD)
        self._class = api(self.user, "GetClassNameW", [wintypes.HWND, wintypes.LPWSTR, ctypes.c_int], ctypes.c_int)
        self._rect = api(self.user, "GetWindowRect", [wintypes.HWND, ctypes.POINTER(wintypes.RECT)], wintypes.BOOL)
        self._dwm = api(self.dwm, "DwmGetWindowAttribute", [wintypes.HWND, wintypes.DWORD, ctypes.c_void_p, wintypes.DWORD], ctypes.c_long)
        self._cursor = api(self.user, "GetCursorPos", [ctypes.POINTER(wintypes.POINT)], wintypes.BOOL)
        self._move = api(self.user, "SetCursorPos", [ctypes.c_int, ctypes.c_int], wintypes.BOOL)
        self._key = api(self.user, "GetAsyncKeyState", [ctypes.c_int], ctypes.c_short)
        self._monitors = api(self.user, "EnumDisplayMonitors", [wintypes.HDC, ctypes.POINTER(wintypes.RECT), self.monitor_callback, wintypes.LPARAM], wintypes.BOOL)
        self._monitor_info = api(self.user, "GetMonitorInfoW", [wintypes.HANDLE, ctypes.c_void_p], wintypes.BOOL)
        long_name = "GetWindowLongPtrW" if ctypes.sizeof(ctypes.c_void_p) == 8 else "GetWindowLongW"
        set_name = "SetWindowLongPtrW" if ctypes.sizeof(ctypes.c_void_p) == 8 else "SetWindowLongW"
        self._get_style = api(self.user, long_name, [wintypes.HWND, ctypes.c_int], ctypes.c_ssize_t)
        self._set_style = api(self.user, set_name, [wintypes.HWND, ctypes.c_int, ctypes.c_ssize_t], ctypes.c_ssize_t)
        self._foreground = api(self.user, "GetForegroundWindow", [], wintypes.HWND)
        self._activate = api(self.user, "SetForegroundWindow", [wintypes.HWND], wintypes.BOOL)
        self._position = api(self.user, "SetWindowPos", [wintypes.HWND, wintypes.HWND, ctypes.c_int, ctypes.c_int,
                                                        ctypes.c_int, ctypes.c_int, wintypes.UINT], wintypes.BOOL)

    def cursor(self) -> Point:
        p = wintypes.POINT()
        if not self._cursor(ctypes.byref(p)):
            raise ctypes.WinError(ctypes.get_last_error())
        return Point(p.x, p.y)

    def move_cursor(self, point: Point) -> bool:
        return bool(self._move(round(point.x), round(point.y)))

    def buttons(self) -> bool:
        return any(self._key(code) & 0x8000 for code in (0x01, 0x02, 0x04, 0x05, 0x06))

    def foreground(self) -> int:
        return int(self._foreground() or 0)

    def external_foreground(self) -> int:
        handle = self.foreground()
        pid = wintypes.DWORD()
        if handle:
            self._pid(handle, ctypes.byref(pid))
        return handle if pid.value and pid.value != os.getpid() else 0

    def activate(self, handle: int) -> None:
        if handle:
            self._activate(handle)

    def no_activate(self, handle: int, enabled: bool) -> None:
        style = self._get_style(handle, -20)  # GWL_EXSTYLE
        value = style | 0x08000000 if enabled else style & ~0x08000000  # WS_EX_NOACTIVATE
        ctypes.set_last_error(0)
        result = self._set_style(handle, -20, value)
        if result == 0 and ctypes.get_last_error():
            raise ctypes.WinError(ctypes.get_last_error())
        self._position(handle, None, 0, 0, 0, 0, 0x0037)  # FRAMECHANGED | NOACTIVATE | NOZORDER | NOMOVE | NOSIZE

    def monitors(self) -> list[Monitor]:
        class MonitorInfo(ctypes.Structure):
            _fields_ = [("size", wintypes.DWORD), ("monitor", wintypes.RECT), ("work", wintypes.RECT),
                        ("flags", wintypes.DWORD), ("device", wintypes.WCHAR * 32)]

        result: list[Monitor] = []

        def rect(value) -> NativeRect:
            return NativeRect(value.left, value.top, value.right, value.bottom)

        @self.monitor_callback
        def visit(handle, _dc, _rect, _data):
            info = MonitorInfo()
            info.size = ctypes.sizeof(info)
            if self._monitor_info(handle, ctypes.byref(info)):
                result.append(Monitor(info.device, rect(info.monitor), rect(info.work)))
            return True

        if not self._monitors(None, None, visit, 0):
            raise ctypes.WinError(ctypes.get_last_error())
        return result

    def windows(self, space: ScreenSpace) -> list[DesktopWindow]:
        result: list[DesktopWindow] = []
        excluded = {"Progman", "WorkerW", "Shell_TrayWnd", "Shell_SecondaryTrayWnd", "tooltips_class32", "#32768"}

        @self.enum_callback
        def visit(handle, _data):
            if not self._visible(handle) or self._iconic(handle):
                return True
            pid = wintypes.DWORD()
            self._pid(handle, ctypes.byref(pid))
            if pid.value == os.getpid():
                return True
            name = ctypes.create_unicode_buffer(256)
            self._class(handle, name, len(name))
            if name.value in excluded:
                return True
            style = self._get_style(handle, -20)
            if style & 0x80 or style & 0x20:  # Tool windows / transparent overlays, not application platforms.
                return True
            cloaked = wintypes.DWORD()
            if self._dwm(handle, 14, ctypes.byref(cloaked), ctypes.sizeof(cloaked)) == 0 and cloaked.value:
                return True
            frame = wintypes.RECT()
            # DWMWA_EXTENDED_FRAME_BOUNDS excludes invisible resize borders.
            if self._dwm(handle, 9, ctypes.byref(frame), ctypes.sizeof(frame)) != 0:
                if not self._rect(handle, ctypes.byref(frame)):
                    return True
            logical = space.rect(NativeRect(frame.left, frame.top, frame.right, frame.bottom))
            if logical.width >= 80 and logical.height >= 60:
                result.append(DesktopWindow(int(handle), logical))
            return True

        if not self._enum(visit, 0):
            raise ctypes.WinError(ctypes.get_last_error())
        return result
