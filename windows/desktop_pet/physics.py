"""Desktop physics in logical screen points, with Y increasing upward.

The rules intentionally match Sources/PetPhysics.swift and ClimbPlanner.swift.
No GUI or operating-system dependencies live here.
"""
from __future__ import annotations

from copy import copy
from dataclasses import dataclass
from math import sqrt


@dataclass(frozen=True)
class Point:
    x: float
    y: float


@dataclass(frozen=True)
class Rect:
    x: float
    y: float
    width: float
    height: float

    @property
    def right(self) -> float:
        return self.x + self.width

    @property
    def top(self) -> float:
        return self.y + self.height

    def contains(self, p: Point) -> bool:
        return self.x <= p.x <= self.right and self.y <= p.y <= self.top

    def intersects(self, other: Rect) -> bool:
        return self.x < other.right and self.right > other.x and self.y < other.top and self.top > other.y


@dataclass(frozen=True)
class Ledge:
    id: int
    edge: str
    left: float
    right: float
    y: float
    carrier: Point

    def supports(self, x: float, half_width: float) -> bool:
        return self.edge == "ground" or (x + half_width > self.left + 3 and x - half_width < self.right - 3)


@dataclass(frozen=True)
class DesktopWindow:
    id: int
    frame: Rect


def window_ledges(windows: list[DesktopWindow], area: Rect) -> list[Ledge]:
    """Input is front-to-back. Subtract occluded portions of each window rim."""
    front: list[Rect] = []
    result: list[Ledge] = []
    for window in windows:
        frame = window.frame
        if not frame.intersects(area):
            continue
        for edge, y, suffix in [("upper", frame.top, 0), ("lower", frame.y, 1)]:
            if not area.y + 1 < y < area.top:
                continue
            segments = [(max(area.x, frame.x), min(area.right, frame.right))]
            for blocker in front:
                if not blocker.y - 1 < y < blocker.top + 1:
                    continue
                pieces: list[tuple[float, float]] = []
                for left, right in segments:
                    if blocker.right <= left or blocker.x >= right:
                        pieces.append((left, right))
                    else:
                        if blocker.x > left:
                            pieces.append((left, min(right, blocker.x)))
                        if blocker.right < right:
                            pieces.append((max(left, blocker.right), right))
                segments = pieces
            for left, right in segments:
                if right - left > 12:
                    result.append(Ledge(window.id * 2 + suffix, edge, left, right, y, Point(frame.x, frame.y)))
        front.append(frame)
    return result


class Physics:
    GRAVITY = 1300.0

    def __init__(self, feet: Point, area: Rect, height: float):
        self.feet = feet
        self.area = area
        self.height = height
        self.wrap_half_width = height * 0.625
        self.vx = 0.0
        self.vy = 0.0
        self.facing_left = False
        self.support_id: int | None = None
        self.ledges: list[Ledge] = []
        self.drop_below: float | None = None
        self.intended_id: int | None = None
        self.update_ledges([])

    @property
    def ceiling(self) -> float:
        return max(self.area.y, self.area.top - self.height - 6)

    @property
    def half_foot(self) -> float:
        return self.height * 0.22

    @property
    def grounded(self) -> bool:
        return self.support_id is not None

    @property
    def moving(self) -> bool:
        return not self.grounded or abs(self.vx) > 0.1

    @property
    def support(self) -> Ledge | None:
        return next((ledge for ledge in self.ledges if ledge.id == self.support_id and ledge.supports(self.feet.x, self.half_foot)), None)

    def set_speed(self, value: float) -> None:
        self.vx = value
        if abs(value) > 0.1:
            self.facing_left = value < 0

    def teleport(self, point: Point) -> None:
        self.feet = Point(point.x, min(self.ceiling, max(self.area.y, point.y)))
        self.vx = self.vy = 0.0
        self.support_id = self.drop_below = self.intended_id = None

    def update_ledges(self, ledges: list[Ledge]) -> None:
        old = self.support
        self.ledges = [Ledge(0, "ground", self.area.x, self.area.right, self.area.y, Point(self.area.x, self.area.y))]
        self.ledges.extend(ledge for ledge in ledges if self.area.y + 1 < ledge.y <= self.ceiling)
        if self.intended_id is not None and not any(x.id == self.intended_id for x in self.ledges):
            self.intended_id = None
        if old:
            replacement = next((x for x in self.ledges if x.id == old.id and x.supports(self.feet.x + x.carrier.x - old.carrier.x, self.half_foot)), None)
            if replacement:
                self.feet = Point(self.feet.x + replacement.carrier.x - old.carrier.x, replacement.y)
                self.vy = 0.0
                return
        if self.support_id is not None:
            self.support_id = None
            self.vy = 0.0

    def advance(self, elapsed: float) -> None:
        remaining = min(max(elapsed, 0.0), 0.1)
        while remaining > 0.000001:
            dt = min(remaining, 1 / 120)
            self._step(dt)
            remaining -= dt

    def _step(self, dt: float) -> None:
        x = self.feet.x + self.vx * dt
        margin = max(self.height * 0.6, self.wrap_half_width)
        span = self.area.width + 2 * margin
        wrapped = False
        if span > 0:
            while x > self.area.right + margin:
                x -= span
                wrapped = True
            while x < self.area.x - margin:
                x += span
                wrapped = True
        self.feet = Point(x, self.feet.y)
        if wrapped and self.support_id != 0:
            self.support_id = None
        support = self.support
        if support and self.drop_below is None:
            self.feet = Point(x, support.y)
            self.vy = 0.0
            return
        self.support_id = None
        old_y = self.feet.y
        y = old_y + self.vy * dt - self.GRAVITY * dt * dt / 2
        self.vy -= self.GRAVITY * dt
        if y > self.ceiling:
            y = self.ceiling
            self.vy = min(0, self.vy)
        if self.vy <= 0:
            target = next((ledge.y for ledge in self.ledges if ledge.id == self.intended_id), None)
            crossed = [ledge for ledge in self.ledges if ledge.supports(x, self.half_foot)
                       and y - 0.001 <= ledge.y <= old_y + 0.001
                       and (self.drop_below is None or ledge.y < self.drop_below - 2)
                       and (target is None or ledge.y <= target + 0.001)]
            if crossed:
                landing = max(crossed, key=lambda ledge: ledge.y)
                y, self.support_id, self.vy = landing.y, landing.id, 0.0
                self.drop_below = self.intended_id = None
        if y <= self.area.y:
            y, self.vy, self.support_id = self.area.y, 0.0, 0
            self.drop_below = self.intended_id = None
        self.feet = Point(x, y)

    def will_land_soon(self, within: float = 0.15) -> bool:
        if self.grounded or self.vy > 0:
            return False
        probe = copy(self)
        remaining = within
        while remaining > 0:
            dt = min(remaining, 1 / 60)
            probe.advance(dt)
            if probe.grounded:
                return True
            remaining -= dt
        return False

    def jump(self, height: float, speed: float = 0.0) -> bool:
        room = self.ceiling - self.feet.y
        if not self.grounded or room <= 4:
            return False
        self.vy = sqrt(2 * self.GRAVITY * min(max(height, 8), room))
        self.set_speed(speed)
        self.support_id = self.drop_below = self.intended_id = None
        return True

    def jump_to(self, ledge: Ledge) -> bool:
        if not self.grounded or not self.feet.y + 8 < ledge.y < self.ceiling - 4:
            return False
        inset = min(self.half_foot + 8, (ledge.right - ledge.left) / 2)
        target_x = min(ledge.right - inset, max(ledge.left + inset, self.feet.x))
        rise = ledge.y - self.feet.y
        apex = min(rise + 45, self.ceiling - self.feet.y)
        launch = sqrt(2 * self.GRAVITY * apex)
        time = (launch + sqrt(max(0, launch * launch - 2 * self.GRAVITY * rise))) / self.GRAVITY
        speed = (target_x - self.feet.x) / max(0.1, time)
        if abs(speed) > 240:
            return False
        self.jump(apex, speed)
        self.intended_id = ledge.id
        return True

    def drop_down(self) -> bool:
        if not self.grounded or self.support_id == 0:
            return False
        self.drop_below = self.feet.y
        self.support_id = self.intended_id = None
        self.vy = -80
        return True


def next_climb(physics: Physics, completed: set[int]) -> tuple[str, Ledge | float | None]:
    width = physics.half_foot * 2 + 8

    def distance(ledge: Ledge) -> float:
        return max(ledge.left - physics.feet.x, physics.feet.x - ledge.right, 0)

    tops = [x for x in physics.ledges if x.edge == "upper" and x.id // 2 not in completed
            and physics.feet.y + 16 < x.y < physics.ceiling - 4 and x.right - x.left > width]
    if not tops:
        return "finished", None
    window = min(tops, key=lambda x: (x.y, distance(x))).id // 2
    steps = sorted((x for x in physics.ledges if x.id // 2 == window and x.edge != "ground"
                    and physics.feet.y + 16 < x.y < physics.ceiling - 4 and x.right - x.left > width), key=lambda x: (x.y, distance(x)))
    if not steps:
        return "finished", None
    lowest = steps[0]
    for step in steps:
        if abs(step.y - lowest.y) < 0.01 and copy(physics).jump_to(step):
            return "jump", step
    inset = min(physics.half_foot + 8, (lowest.right - lowest.left) / 2)
    return "approach", min(lowest.right - inset, max(lowest.left + inset, physics.feet.x))
