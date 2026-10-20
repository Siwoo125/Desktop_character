"""Portable behavior checks. No real cursor or application windows are controlled."""
from __future__ import annotations

import math
from pathlib import Path
import random
import tempfile
import unittest

from .animation import CursorCarry, gaze_direction
from .engine import PetEngine
from .physics import DesktopWindow, Ledge, Physics, Point, Rect, next_climb, window_ledges
from .settings import Settings
from .win32 import NativeRect, ScreenSpace


class FakeCursor:
    def __init__(self, point: Point = Point(500, 300)):
        self.point = point
        self.down = False
        self.moves: list[Point] = []
        self.fail_move = False

    def move(self, point: Point) -> bool:
        if self.fail_move:
            return False
        self.point = point
        self.moves.append(point)
        return True

    def lease(self) -> CursorCarry:
        return CursorCarry(lambda: self.point, self.move, lambda: self.down)


def physics() -> Physics:
    result = Physics(Point(500, 0), Rect(0, 0, 1200, 900), 60)
    result.advance(1 / 120)
    return result


def ledge(id: int, y: float, left: float = 350, right: float = 700, edge: str = "upper") -> Ledge:
    return Ledge(id, edge, left, right, y, Point(left, y - 200))


class PhysicsChecks(unittest.TestCase):
    def test_gravity_landing_and_drop(self):
        p = physics()
        p.update_ledges([ledge(2, 200)])
        self.assertTrue(p.jump(300))
        for _ in range(180):
            p.advance(1 / 60)
        self.assertEqual(p.support_id, 2)
        self.assertEqual(p.feet.y, 200)
        self.assertTrue(p.drop_down())
        for _ in range(100):
            p.advance(1 / 60)
        self.assertEqual(p.support_id, 0)

    def test_intended_lower_landing(self):
        p = physics()
        low, high = ledge(2, 150), ledge(4, 180)
        p.update_ledges([low, high])
        self.assertTrue(p.jump_to(low))
        for _ in range(100):
            p.advance(1 / 60)
        self.assertEqual(p.support_id, low.id)

    def test_window_move_and_close(self):
        p = physics()
        p.teleport(Point(500, 201))
        p.update_ledges([ledge(2, 200)])
        p.advance(0.1)
        old = p.feet
        p.update_ledges([Ledge(2, "upper", 400, 750, 240, Point(400, 40))])
        self.assertEqual(p.feet, Point(old.x + 50, 240))
        p.update_ledges([])
        p.advance(0.1)
        self.assertLess(p.feet.y, 240)

    def test_wrap_both_edges_and_negative_monitor(self):
        p = Physics(Point(-10, 0), Rect(-1200, 0, 1200, 900), 60)
        p.set_speed(180)
        for _ in range(60):
            p.advance(1 / 60)
        self.assertLess(p.feet.x, -1000)
        p.teleport(Point(-1190, 0))
        p.set_speed(-180)
        for _ in range(60):
            p.advance(1 / 60)
        self.assertGreater(p.feet.x, -200)

    def test_lowest_window_first_and_lower_rim(self):
        p = physics()
        p.update_ledges([ledge(2, 500, 350, 700), ledge(4, 250, 850, 1100), ledge(5, 100, 850, 1100, "lower")])
        kind, target = next_climb(p, set())
        self.assertEqual(kind, "approach")
        self.assertGreater(target, 850)
        p.teleport(Point(900, 0))
        p.advance(1 / 120)
        kind, target = next_climb(p, set())
        self.assertEqual(kind, "jump")
        self.assertEqual(target.id, 5)

    def test_occluded_window_segments(self):
        area = Rect(0, 0, 1200, 900)
        front = DesktopWindow(1, Rect(300, 100, 300, 500))
        back = DesktopWindow(2, Rect(100, 50, 800, 300))
        result = window_ledges([front, back], area)
        segments = [(x.left, x.right) for x in result if x.id == 4]
        self.assertEqual(segments, [(100, 300), (600, 900)])

    def test_time_step_equivalence(self):
        a, b = physics(), physics()
        a.jump(300, 100)
        b.jump(300, 100)
        for _ in range(30):
            a.advance(1 / 30)
        for _ in range(60):
            b.advance(1 / 60)
        self.assertAlmostEqual(a.feet.x, b.feet.x, places=6)
        self.assertAlmostEqual(a.feet.y, b.feet.y, places=6)


class CoordinateChecks(unittest.TestCase):
    def test_mixed_dpi_and_negative_origins(self):
        for bounds, origin, ratio in [(NativeRect(1920, 0, 4480, 1440), Point(1920, 0), 1.5),
                                      (NativeRect(-2560, -720, 0, 720), Point(-2560, -720), 2.0)]:
            space = ScreenSpace(bounds, origin, ratio)
            for point in [Point(bounds.left, bounds.top), Point(bounds.right - 1, bounds.bottom - 1), Point(bounds.left + 314, bounds.top + 276)]:
                self.assertEqual(space.to_native(space.to_world(point)), point)
            work = space.rect(bounds)
            self.assertAlmostEqual(work.width, (bounds.right - bounds.left) / ratio)
            self.assertAlmostEqual(work.height, (bounds.bottom - bounds.top) / ratio)


class CursorChecks(unittest.TestCase):
    def test_follow_and_original_restore(self):
        fake = FakeCursor()
        lease = fake.lease()
        original = fake.point
        self.assertTrue(lease.begin(original))
        self.assertTrue(lease.follow(Point(400, 100)))
        self.assertTrue(lease.follow(Point(430, 90)))
        lease.release()
        self.assertEqual(fake.point, original)
        self.assertFalse(lease.active)
        moves = len(fake.moves)
        lease.release()
        self.assertEqual(len(fake.moves), moves)

    def test_user_movement_and_click_always_win(self):
        for clicked in [False, True]:
            fake = FakeCursor()
            lease = fake.lease()
            lease.begin(fake.point)
            lease.follow(Point(300, 200))
            if clicked:
                fake.down = True
            else:
                fake.point = Point(900, 700)
            user_point = fake.point
            moves = len(fake.moves)
            self.assertFalse(lease.follow(Point(200, 100)))
            lease.release()
            self.assertEqual(fake.point, user_point)
            self.assertEqual(len(fake.moves), moves)

    def test_failed_cursor_move(self):
        fake = FakeCursor()
        lease = fake.lease()
        lease.begin(fake.point)
        fake.fail_move = True
        self.assertFalse(lease.follow(Point(300, 200)))
        lease.release(False)
        self.assertFalse(lease.active)


class EngineChecks(unittest.TestCase):
    def test_independent_move_and_rest_on_shared_clock(self):
        engines = []
        for seed in (13, 79):
            fake = FakeCursor(Point(-1000, -1000))
            engine = PetEngine(physics(), fake.lease(), lambda *_: Point(20, 30), rng=random.Random(seed))
            engine.next_cursor = math.inf
            engines.append(engine)
        self.assertNotEqual(engines[0].next_action, engines[1].next_action)
        mixed = 0
        observed = [set(), set()]
        transitions = [[], []]
        for step in range(2400):
            now = (step + 1) / 20
            for index, engine in enumerate(engines):
                before = engine.physics.moving
                engine.tick(.05, now, Point(-1000, -1000))
                moving = engine.physics.moving
                observed[index].add(moving)
                if before != moving:
                    transitions[index].append(step)
            mixed += engines[0].physics.moving != engines[1].physics.moving
        self.assertGreater(mixed, 300, "같은 시간에도 한 마리는 걷고 다른 마리는 쉬어야 합니다")
        self.assertEqual(observed, [{False, True}, {False, True}])
        self.assertNotEqual(transitions[0], transitions[1])
        for engine in engines:
            engine.reschedule_auto(200)
            self.assertTrue(200.8 <= engine.next_action <= 204.5)
        self.assertNotEqual(engines[0].next_action, engines[1].next_action)

    def make(self):
        fake = FakeCursor(Point(600, 300))
        engine = PetEngine(physics(), fake.lease(), lambda _roll, _frame, mirror: Point(-20 if mirror else 20, 30), rng=random.Random(2))
        engine.next_action = math.inf
        return engine, fake

    def test_keyboard_movement_running_release_jump(self):
        engine, fake = self.make()
        engine.set_manual(True, 0)
        start = engine.physics.feet.x
        engine.key_down("d")
        engine.tick(0.1, 0.1, fake.point, focused=True)
        self.assertAlmostEqual(engine.physics.feet.x - start, 9)
        engine.key_up("d")
        stopped = engine.physics.feet.x
        engine.tick(0.1, 0.2, fake.point, focused=True)
        self.assertEqual(engine.physics.feet.x, stopped)
        engine.running = True
        engine.key_down("a")
        engine.tick(0.1, 0.3, fake.point, focused=True)
        self.assertAlmostEqual(stopped - engine.physics.feet.x, 18)
        engine.key_up("a")
        engine.key_down("space")
        self.assertEqual(engine.hop.phase, "preparing")
        engine.tick(0.1, 0.4, fake.point, focused=True)
        engine.tick(0.1, 0.5, fake.point, focused=True)
        self.assertFalse(engine.physics.grounded)
        self.assertGreater(engine.physics.feet.y, 20)
        engine.reset_keys()
        self.assertEqual(engine.axis, 0)

    def test_focus_loss_stops_movement(self):
        engine, fake = self.make()
        engine.set_manual(True, 0)
        engine.key_down("d")
        engine.tick(0.1, 0.1, fake.point, focused=False)
        self.assertEqual(engine.physics.vx, 0)

    def test_full_cursor_trick_and_restore(self):
        engine, fake = self.make()
        original = fake.point
        self.assertTrue(engine.begin_trick(original, 0, False))
        seen = set()
        frames = set()
        for index in range(400):
            if not engine.trick:
                break
            seen.add(engine.trick.phase)
            if engine.trick.phase == "rolling":
                frames.add(engine.trick.frame)
            engine.tick(1 / 30, (index + 1) / 30, fake.point)
        self.assertTrue({"preparing", "flying", "holding", "falling", "landing", "rolling"} <= seen)
        self.assertEqual(frames, set(range(8)))
        self.assertIsNone(engine.trick)
        self.assertTrue(engine.physics.grounded)
        self.assertEqual(fake.point, original)
        self.assertFalse(engine.carry.active)

    def test_interrupt_and_pause_restore(self):
        for mode in ("move", "click", "pause"):
            engine, fake = self.make()
            original = fake.point
            engine.begin_trick(original, 0, False)
            for index in range(100):
                engine.tick(1 / 30, (index + 1) / 30, fake.point)
                if engine.carry.active:
                    break
            self.assertTrue(engine.carry.active)
            if mode == "pause":
                engine.stop(4)
                self.assertEqual(fake.point, original)
            else:
                if mode == "move":
                    fake.point = Point(1100, 800)
                else:
                    fake.down = True
                user_point = fake.point
                engine.tick(1 / 30, 4, fake.point, fake.down)
                self.assertEqual(fake.point, user_point)
            self.assertIsNone(engine.trick)
            self.assertFalse(engine.carry.active)

    def test_cursor_attempt_interval(self):
        engine, fake = self.make()
        engine.last_cursor = fake.point
        engine.cursor_still_since = 0
        engine.next_action = 59
        engine.tick(0, 59, fake.point)
        self.assertIsNone(engine.trick)
        engine.physics.set_speed(0)
        engine.next_action = 60
        engine.tick(0, 60, fake.point)
        self.assertIsNotNone(engine.trick)
        self.assertEqual(engine.next_cursor, 120)

    def test_gaze_dead_band(self):
        head = Point(-400, 300)
        self.assertEqual(gaze_direction(1, Point(-600, 500), head, 60), 0)
        self.assertEqual(gaze_direction(0, Point(-400, 900), head, 60), 1)
        self.assertEqual(gaze_direction(1, Point(-200, 500), head, 60), 2)
        self.assertEqual(gaze_direction(2, Point(-325, 500), head, 60), 2)


class SettingsChecks(unittest.TestCase):
    def test_multiple_instances_and_empty_roster(self):
        import uuid
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "settings.json"
            settings = Settings(path)
            self.assertIsNone(settings.instances)
            entries = [{"id": str(uuid.uuid4()), "character": name, "base_height": 60, "scale": scale, "x": -400, "y": -500}
                       for name, scale in (("puppy", .5), ("bonobono", 1.5), ("puppy", 2))]
            settings.instances = entries
            settings.save()
            self.assertEqual(Settings(path).instances, entries)
            settings.instances = []
            settings.save()
            self.assertEqual(Settings(path).instances, [])
            path.write_text('{"instances":[null,{}, {"id":"bad","character":"puppy","scale":1}]}', encoding="utf-8")
            self.assertEqual(Settings(path).instances, [])

    def test_roundtrip_and_corruption(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "settings.json"
            settings = Settings(path)
            settings.character, settings.scale, settings.x, settings.y = "bonobono", 1.5, -400, -500
            settings.save()
            loaded = Settings(path)
            self.assertEqual((loaded.character, loaded.scale, loaded.x, loaded.y), ("bonobono", 1.5, -400, -500))
            for content in ("{", "[]", '{"character":"missing","scale":99,"x":"bad","y":NaN}'):
                path.write_text(content, encoding="utf-8")
                loaded = Settings(path)
                self.assertEqual((loaded.character, loaded.scale), ("puppy", 1.0))
                self.assertIsNone(loaded.x)
                self.assertIsNone(loaded.y)


def run() -> bool:
    suite = unittest.defaultTestLoader.loadTestsFromModule(__import__(__name__, fromlist=["*"]))
    return unittest.TextTestRunner(verbosity=2).run(suite).wasSuccessful()
