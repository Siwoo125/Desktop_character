from __future__ import annotations

from dataclasses import dataclass
from math import hypot, sqrt
from typing import Callable

from .physics import Physics, Point

IDLE_TIMES = (0.16, 0.14, 0.09, 0.14, 0.09, 0.14, 0.14, 0.18)
SCALES = (0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0)


@dataclass
class Hop:
    kind: str
    phase: str = "preparing"
    elapsed: float = 0.0

    @property
    def holds_motion(self) -> bool:
        return self.phase in ("preparing", "landing")

    def transition(self, phase: str) -> None:
        self.phase, self.elapsed = phase, 0.0

    def observe(self, grounded: bool, soon: bool) -> bool:
        """Return true on the first actual landing."""
        if self.phase in ("preparing", "landing"):
            return False
        if self.phase == "airborne" and (grounded or soon):
            self.transition("before_landing")
        elif self.phase == "before_landing" and grounded and self.elapsed >= 0.04:
            self.transition("landing")
            return True
        elif self.phase == "before_landing" and not grounded and not soon:
            self.transition("airborne")
        return False


class CursorCarry:
    """Move only the real pointer while held; never lock or replace the system cursor.

    Each move first checks for user movement/clicks. On interruption the user's new
    location wins; a completed stationary trick restores the original location.
    Injected callbacks make this fully testable without moving a user's pointer.
    """
    def __init__(self, read: Callable[[], Point], move: Callable[[Point], bool], buttons: Callable[[], bool]):
        self.read, self.move_pointer, self.buttons = read, move, buttons
        self.original: Point | None = None
        self.expected: Point | None = None

    @property
    def active(self) -> bool:
        return self.original is not None

    def interrupted(self) -> bool:
        if not self.active:
            return False
        current = self.read()
        return self.buttons() or hypot(current.x - self.expected.x, current.y - self.expected.y) > 1.1

    def begin(self, original: Point) -> bool:
        if self.active:
            return True
        current = self.read()
        if self.buttons() or hypot(current.x - original.x, current.y - original.y) > 1.1:
            return False
        self.original, self.expected = original, current
        return True

    def follow(self, point: Point) -> bool:
        if not self.active or self.interrupted():
            return False
        if not self.move_pointer(point):
            return False
        # Native pixel rounding and clipping must be accounted for on high DPI monitors.
        actual = self.read()
        if hypot(actual.x - point.x, actual.y - point.y) > 1.1:
            return False
        self.expected = actual
        return True

    def release(self, restore: bool = True) -> None:
        try:
            if self.active and restore and not self.interrupted():
                self.move_pointer(self.original)
        finally:
            self.original = self.expected = None


class CursorTrick:
    def __init__(self, start: Point, cursor: Point, grip: Point, ceiling: float):
        self.start, self.original = start, cursor
        self.destination = Point(cursor.x - grip.x, cursor.y - grip.y)
        self.mirrored = cursor.x < start.x
        self.phase, self.elapsed, self.total = "preparing", 0.0, 0.0
        rise = self.destination.y - start.y
        apex = min(ceiling - start.y, max(45, rise))
        self.launch = sqrt(2 * Physics.GRAVITY * max(0, apex))
        self.duration = (self.launch + sqrt(max(0, self.launch ** 2 - 2 * Physics.GRAVITY * rise))) / Physics.GRAVITY

    @property
    def has_cursor(self) -> bool:
        return self.phase in ("holding", "falling", "landing", "rolling")

    @property
    def uses_physics(self) -> bool:
        return self.phase in ("falling", "landing", "rolling", "finished")

    @property
    def frame(self) -> int:
        if self.phase == "preparing":
            return 0 if self.elapsed < 0.1 else 1
        if self.phase == "flying":
            return 2 if self.elapsed < self.duration * 0.5 else 3
        if self.phase == "holding":
            return 4
        if self.phase == "falling":
            return 5
        if self.phase == "landing":
            return 6 if self.elapsed < 0.16 else 7
        if self.phase == "rolling":
            return min(15, int(self.elapsed / 0.14)) % 8
        return 7

    @property
    def feet(self) -> Point:
        if self.phase == "preparing":
            return self.start
        if self.phase != "flying":
            return self.destination
        t = min(self.elapsed, self.duration)
        return Point(self.start.x + (self.destination.x - self.start.x) * t / max(0.001, self.duration),
                     self.start.y + self.launch * t - Physics.GRAVITY * t * t / 2)

    def advance(self, dt: float, grounded: bool) -> None:
        self.elapsed += dt
        self.total += dt
        phase = self.phase
        next_phase = None
        if phase == "preparing" and self.elapsed >= 0.24:
            next_phase = "flying"
        elif phase == "flying" and self.elapsed >= self.duration:
            next_phase = "holding"
        elif phase == "holding" and self.elapsed >= 0.35:
            next_phase = "falling"
        elif phase == "falling" and grounded:
            next_phase = "landing"
        elif phase in ("landing", "rolling") and not grounded:
            next_phase = "falling"
        elif phase == "landing" and self.elapsed >= 0.32:
            next_phase = "rolling"
        elif phase == "rolling" and self.elapsed >= 2.24:
            next_phase = "finished"
        if next_phase:
            self.phase, self.elapsed = next_phase, 0.0


def gaze_direction(previous: int, cursor: Point, head: Point, height: float) -> int:
    dx, dy = cursor.x - head.x, max(0, cursor.y - head.y)
    boundary = max(height * 0.22, dy * 0.4)
    returning = boundary * 0.72
    if previous == 1:
        return 0 if dx < -boundary else 2 if dx > boundary else 1
    if previous == 0:
        return 2 if dx > boundary else 1 if dx > -returning else 0
    return 0 if dx < -boundary else 1 if dx < returning else 2
