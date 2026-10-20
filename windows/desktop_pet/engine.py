"""Animation and autonomous/manual behavior, independent of Qt and Win32."""
from __future__ import annotations

import random
from math import hypot
from typing import Callable

from .animation import CursorCarry, CursorTrick, Hop, IDLE_TIMES, gaze_direction
from .physics import Ledge, Physics, Point, next_climb


class PetEngine:
    CURSOR_INTERVAL = 60.0

    def __init__(self, physics: Physics, carry: CursorCarry, grip: Callable[[bool, int, bool], Point],
                 now: float = 0.0, rng: random.Random | None = None):
        self.physics, self.carry, self.grip = physics, carry, grip
        self.can_begin_cursor = lambda: True
        self.now = now
        self.random = rng or random.Random()
        self.hop: Hop | None = None
        self.pending: tuple[str, object] | None = None
        self.trick: CursorTrick | None = None
        self.pressed: set[str] = set()
        self.running = self.manual = False
        self.paused = self.hidden = self.dragging = self.menu_open = False
        self.walk_until = now
        self.landing_speed = 0.0
        self.next_action = now + self.random.uniform(.8, 4.5)
        self.next_cursor = now + self.CURSOR_INTERVAL
        self.cursor_request = 0.0
        self.cursor_still_since = now
        self.last_cursor: Point | None = None
        self.climbing = self.approaching = self.prefer_down = False
        self.completed: set[int] = set()
        self.action_count = 0
        self.gait = "walking"
        self.idle_frame: int | None = None
        self.next_idle = now + self.random.uniform(3.5, 6.5)
        self.gaze = 1

    @property
    def active(self) -> bool:
        return not (self.paused or self.hidden or self.dragging or self.menu_open)

    @property
    def feet(self) -> Point:
        return self.trick.feet if self.trick and not self.trick.uses_physics else self.physics.feet

    @property
    def axis(self) -> int:
        return int("d" in self.pressed) - int("a" in self.pressed)

    @property
    def speed(self) -> float:
        return 180.0 if self.gait == "running" else 90.0

    def reset_keys(self) -> None:
        self.pressed.clear()
        self.running = False
        if self.manual:
            self.physics.set_speed(0)
            self.landing_speed = 0

    def cancel_hop(self) -> None:
        self.hop = self.pending = None
        self.climbing = self.approaching = False
        self.completed.clear()
        self.landing_speed = 0.0

    def cancel_trick(self, restore: bool = True) -> None:
        self.carry.release(restore)
        if self.trick and not self.trick.uses_physics:
            self.physics.teleport(self.trick.feet)
        self.trick = None

    def stop(self, now: float) -> None:
        self.cancel_trick()
        self.cursor_request = 0
        self.cursor_still_since = now
        self.reset_keys()
        self.idle_frame = None

    def set_manual(self, enabled: bool, now: float) -> None:
        self.stop(now)
        self.cancel_hop()
        self.manual = enabled
        self.physics.set_speed(0)
        self.walk_until = now
        self.reschedule_auto(now)
        if enabled:
            self.paused = self.hidden = False

    def reschedule_auto(self, now: float) -> None:
        self.next_action = now + self.random.uniform(.8, 4.5)
        if self.physics.moving and self.walk_until > now and not self.climbing:
            self.next_action = max(self.next_action, self.walk_until + self.random.uniform(1.2, 6))

    def key_down(self, key: str, repeat: bool = False) -> None:
        if not self.manual:
            return
        fresh = key not in self.pressed
        self.pressed.add(key)
        if not fresh or repeat or not self.active:
            return
        if key in ("w", "space"):
            self.begin_hop("in_place", max(220, self.physics.height * 2.5))
        elif key == "s":
            self.climbing = self.approaching = False
            self.begin_hop("down", None)

    def key_up(self, key: str) -> None:
        self.pressed.discard(key)

    def begin_hop(self, action: str, value: object) -> bool:
        p = self.physics
        if not p.grounded or self.hop or self.trick:
            return False
        if action == "down" and p.support_id == 0:
            return False
        if action != "down" and p.ceiling - p.feet.y <= 4:
            return False
        p.set_speed(0)
        self.pending = action, value
        self.hop = Hop("downward" if action == "down" else "upward")
        self.landing_speed = 0.0
        self.idle_frame = None
        return True

    def _launch(self) -> None:
        if not self.pending:
            self.cancel_hop()
            return
        action, value = self.pending
        if action == "onto":
            candidates = [x for x in self.physics.ledges if x.id == value.id and x.right - x.left > self.physics.half_foot * 2]
            launched = bool(candidates) and self.physics.jump_to(min(candidates, key=lambda x: abs(x.left - value.left)))
        elif action == "down":
            launched = self.physics.drop_down()
        else:
            launched = self.physics.jump(float(value))
        self.pending = None
        if launched:
            self.hop.transition("airborne")
        else:
            self.cancel_hop()

    def _contact(self) -> None:
        p = self.physics
        if self.hop and self.hop.observe(p.grounded, p.will_land_soon()):
            if self.climbing and p.support and p.support.edge == "upper":
                self.completed.add(p.support.id // 2)
            self.landing_speed = 0 if self.climbing or self.manual else p.vx
            p.set_speed(0)

    def attempt_climb(self) -> bool:
        if not self.climbing:
            self.completed.clear()
        kind, target = next_climb(self.physics, self.completed)
        if kind == "jump":
            self.climbing, self.approaching, self.prefer_down = True, False, False
            return self.begin_hop("onto", target)
        if kind == "approach":
            self.climbing, self.approaching, self.prefer_down = True, True, False
            self.gait = "walking"
            self.physics.set_speed(-90 if target < self.physics.feet.x else 90)
            self.walk_until = self.now + self.random.uniform(1.5, 5.5)
            return True
        self.climbing = self.approaching = False
        return False

    def _roam(self, now: float) -> None:
        duration, rest = self.random.uniform(1.5, 5.5), self.random.uniform(1.2, 6)
        self.walk_until = now + duration
        if self.climbing:
            self.next_action = now + self.random.uniform(.8, 1.8)
            if not self.attempt_climb():
                self.prefer_down = True
                self.physics.set_speed(0)
                self.walk_until = now
                self.next_action = now + rest
            return
        if self.random.randrange(10) < 3:
            self.physics.set_speed(0)
            self.walk_until = now
            self.next_action = now + rest
            return
        self.next_action = self.walk_until + rest
        self.action_count += 1
        if self.action_count % 3 == 1:
            self.move_randomly()
        elif self.prefer_down and self.physics.support and self.physics.support.edge == "upper":
            self.begin_hop("down", None)
            self.prefer_down = False
        elif not self.attempt_climb():
            self.move_randomly()
            if self.physics.support and self.physics.support.edge == "lower" and self.prefer_down:
                self.begin_hop("down", None)
                self.prefer_down = False
        if self.climbing:
            self.next_action = now + self.random.uniform(.8, 1.8)

    def move_randomly(self) -> None:
        self.gait = "running" if self.random.randrange(10) < 4 else "walking"
        self.physics.set_speed(self.speed * self.random.choice((-1, 1)))

    def request_cursor(self, now: float) -> None:
        self.cancel_trick()
        self.cancel_hop()
        self.manual = False
        self.paused = self.hidden = False
        self.physics.set_speed(0)
        self.cursor_still_since = now
        self.cursor_request = now + 15

    def begin_trick(self, cursor: Point, now: float, automatic: bool) -> bool:
        p = self.physics
        if not self.active or self.manual or not p.grounded or self.hop or self.trick or self.carry.buttons() or not self.can_begin_cursor():
            return False
        grip = self.grip(False, 4, cursor.x < p.feet.x)
        destination = Point(cursor.x - grip.x, cursor.y - grip.y)
        if not p.area.contains(cursor) or not p.area.y <= destination.y <= p.ceiling or p.ceiling - p.feet.y <= 8:
            return False
        if automatic and (abs(destination.x - p.feet.x) > 420 or abs(destination.y - p.feet.y) > 360):
            return False
        self.cancel_hop()
        p.set_speed(0)
        self.walk_until = now
        self.next_cursor = now + self.CURSOR_INTERVAL
        self.reschedule_auto(now)
        self.cursor_request = 0
        self.idle_frame = None
        self.trick = CursorTrick(p.feet, cursor, grip, p.ceiling)
        return True

    def _tick_trick(self, dt: float, cursor: Point, buttons: bool) -> bool:
        trick = self.trick
        if not trick:
            return False
        moved = self.carry.interrupted() if trick.has_cursor else hypot(cursor.x - trick.original.x, cursor.y - trick.original.y) > 1.1
        if moved or buttons or trick.total > 10:
            self.cancel_trick(restore=not (moved or buttons))
            return False
        used_physics = trick.uses_physics
        if used_physics:
            self.physics.set_speed(0)
            self.physics.advance(dt)
        was_holding = trick.has_cursor
        trick.advance(dt, self.physics.grounded)
        if trick.has_cursor and not was_holding and not self.carry.begin(trick.original):
            self.cancel_trick(False)
            return False
        if trick.uses_physics and not used_physics:
            self.physics.teleport(trick.destination)
            self.physics.advance(dt)
        if trick.phase == "finished":
            self.cancel_trick()
        elif trick.has_cursor:
            grip = self.grip(trick.phase == "rolling", trick.frame, trick.mirrored)
            feet = self.feet
            if not self.carry.follow(Point(feet.x + grip.x, feet.y + grip.y)):
                self.cancel_trick(False)
        return True

    def tick(self, dt: float, now: float, cursor: Point, buttons: bool = False, focused: bool = False) -> None:
        self.now = now
        dt = min(0.1, max(0, dt))
        if not self.active:
            return
        own_cursor = self.carry.active and not self.carry.interrupted()
        if not own_cursor and (self.last_cursor is None or buttons or hypot(cursor.x - self.last_cursor.x, cursor.y - self.last_cursor.y) > 1):
            self.last_cursor, self.cursor_still_since = cursor, now
        if self.cursor_request and now > self.cursor_request:
            self.cursor_request = 0
        if self.cursor_request and now - self.cursor_still_since >= 1:
            self.begin_trick(cursor, now, False)
        if self._tick_trick(dt, cursor, buttons):
            return
        p = self.physics
        if not self.manual and self.approaching and p.grounded and not self.hop:
            self.attempt_climb()
        if self.hop:
            self.hop.elapsed += dt
            if self.hop.phase == "preparing" and not p.grounded:
                self.pending = None
                self.hop = Hop("downward", "airborne")
            if self.hop.phase == "preparing" and self.hop.elapsed >= 0.16:
                self._launch()
            if self.hop and self.hop.phase == "landing" and self.hop.elapsed >= 0.2:
                self.hop = None
                if p.grounded and now < self.walk_until:
                    p.set_speed(self.landing_speed)
                self.landing_speed = 0
        holding = self.hop is not None and self.hop.holds_motion
        if holding:
            p.set_speed(0)
        if self.manual:
            self.gait = "running" if self.running else "walking"
            p.set_speed(self.axis * self.speed if focused and not holding else 0)
        elif now >= self.walk_until and p.grounded:
            p.set_speed(0)
        if not self.hop and not p.grounded:
            self.hop = Hop("downward", "airborne")
        self._contact()
        p.advance(dt)
        if not self.hop and not p.grounded:
            self.hop = Hop("downward", "airborne")
        self._contact()
        if self.hop and self.hop.phase == "landing" and not p.grounded:
            self.hop = Hop("downward", "airborne")
        if not self.manual and now >= self.next_action and p.grounded and not self.hop and not self.cursor_request:
            self.next_action = now + self.random.uniform(.8, 1.8)
            if not self.climbing and now >= self.next_cursor and now - self.cursor_still_since >= 2.5:
                self.next_cursor = now + self.CURSOR_INTERVAL
                if self.begin_trick(cursor, now, True):
                    return
            self._roam(now)
        if p.moving or self.hop:
            self.idle_frame = None
            self.next_idle = now + self.random.uniform(3.5, 6.5)
        elif now >= self.next_idle:
            self.idle_frame = 0 if self.idle_frame is None else self.idle_frame + 1
            if self.idle_frame >= 8:
                self.idle_frame = None
                self.next_idle = now + self.random.uniform(3.5, 6.5)
            else:
                self.next_idle = now + IDLE_TIMES[self.idle_frame]
        if p.grounded and not p.moving:
            self.gaze = gaze_direction(self.gaze, cursor, Point(p.feet.x, p.feet.y + p.height * 0.68), p.height)
