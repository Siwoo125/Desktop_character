from __future__ import annotations

import ctypes
from ctypes import wintypes
import logging
from math import ceil
import time
import uuid

from PySide6.QtCore import QEvent, QPoint, QPointF, QTimer, Qt
from PySide6.QtGui import QAction, QActionGroup, QColor, QIcon, QPainter, QPen, QPixmap
from PySide6.QtWidgets import QApplication, QMenu, QMessageBox, QSystemTrayIcon, QWidget

from .animation import CursorCarry, SCALES
from .assets import Atlas, CHARACTERS
from .engine import PetEngine
from .custom import CharacterLibrary
from .physics import Physics, Point, Rect, window_ledges
from .settings import Settings
from .win32 import ScreenSpace, Win32

LOG = logging.getLogger(__name__)


class PetWindow(QWidget):
    def __init__(self, native: Win32, settings: Settings, *, timers: bool = True, persist: bool = True, collection=None, instance_id=None):
        super().__init__(None, Qt.WindowType.FramelessWindowHint | Qt.WindowType.Tool | Qt.WindowType.WindowStaysOnTopHint)
        self.native, self.settings = native, settings
        self.collection = collection
        self.instance_id = instance_id or str(uuid.uuid4())
        self.persist = persist
        self.setAttribute(Qt.WidgetAttribute.WA_TranslucentBackground)
        self.setAttribute(Qt.WidgetAttribute.WA_ShowWithoutActivating)
        self.setFocusPolicy(Qt.FocusPolicy.StrongFocus)
        self.setMouseTracking(True)
        self.setToolTip("드래그로 이동 · 우클릭으로 캐릭터 선택 및 메뉴")
        self.atlases = collection.atlases if collection else {name: Atlas(name) for name in CHARACTERS}
        self.library = collection.library if collection else CharacterLibrary(settings.path.parent / "characters")
        self.profiles = {profile.id: profile for profile in self.library.all()}
        self.character_names = {**CHARACTERS, **{key: p.name for key, p in self.profiles.items()}}
        if settings.character not in self.atlases:
            try:
                self.atlases[settings.character] = Atlas(settings.character, profile=self.profiles[settings.character])
            except Exception:
                LOG.exception("Saved custom character could not be loaded; using puppy")
                settings.character = "puppy"
        self.atlas = self.atlases[settings.character]
        self.creator_dialog = None
        self.creating = False
        self.drag_offset: QPointF | None = None
        self.previous_application = 0
        self.last_external_application = native.external_foreground()
        self.suspended = False
        self._closed = False
        self.current_screen = QApplication.primaryScreen()
        if settings.x is not None and settings.y is not None:
            self.current_screen = QApplication.screenAt(QPoint(round(settings.x), round(-settings.y))) or self.current_screen
        self.space, area = self._screen_space(self.current_screen)
        feet = Point(settings.x, settings.y) if settings.x is not None and settings.y is not None else Point(area.right - 100, area.y)
        physics = Physics(feet, area, settings.height)
        physics.wrap_half_width = settings.height * self.atlas.width_ratio / 2
        carry = CursorCarry(self.cursor_world, self.move_cursor_world, native.buttons)
        now = time.monotonic()
        self.engine = PetEngine(physics, carry, self.grip, now)
        if collection:
            self.engine.can_begin_cursor = lambda: collection.can_catch_cursor(self)
            self.engine.menu_open = collection.ui_paused
        physics.teleport(self.clamp_feet(feet))
        physics.advance(1 / 120)
        self.sprite, self.mirrored = self.atlas.rest, False
        self.last_tick = now
        self.next_scene = self.next_save = now
        self.tray = QSystemTrayIcon(self)
        self.menu = self._make_menu()
        self.tray.setContextMenu(self.menu)
        self.tray.activated.connect(self._tray_activated)
        self._sync_menu()
        self.position_pet()
        native.no_activate(int(self.winId()), True)
        self.timer = QTimer(self)
        self.timer.setInterval(33)
        self.timer.setTimerType(Qt.TimerType.PreciseTimer)
        self.timer.timeout.connect(self.tick)
        if timers:
            self.timer.start()
            if not collection:
                self.tray.show()
        application = QApplication.instance()
        application.aboutToQuit.connect(self.shutdown)
        application.screenAdded.connect(self.display_changed)
        application.screenAdded.connect(self.watch_screen)
        application.screenRemoved.connect(self.display_changed)
        application.primaryScreenChanged.connect(self.display_changed)
        for screen in application.screens():
            self.watch_screen(screen)

    def watch_screen(self, screen) -> None:
        screen.geometryChanged.connect(self.display_changed)
        screen.availableGeometryChanged.connect(self.display_changed)
        screen.logicalDotsPerInchChanged.connect(self.display_changed)

    @property
    def height_points(self) -> float:
        return self.settings.height

    def _screen_space(self, screen) -> tuple[ScreenSpace, Rect]:
        monitors = self.native.monitors()

        def name(value: str) -> str:
            return value.upper().replace("\\\\.\\", "")

        monitor = next((m for m in monitors if name(m.name) == name(screen.name())), None)
        if monitor is None and len(monitors) == 1:
            monitor = monitors[0]
        if monitor is None:
            raise RuntimeError(f"모니터 좌표를 연결할 수 없습니다: {screen.name()}")
        origin = screen.geometry().topLeft()
        space = ScreenSpace(monitor.bounds, Point(origin.x(), origin.y()), screen.devicePixelRatio())
        return space, space.rect(monitor.work)

    def cursor_world(self) -> Point:
        return self.space.to_world(self.native.cursor())

    def move_cursor_world(self, point: Point) -> bool:
        return self.native.move_cursor(self.space.to_native(point))

    def grip(self, rolling: bool, frame: int, mirrored: bool) -> Point:
        return self.atlas.grip(rolling, frame, mirrored, self.height_points)

    def clamp_feet(self, point: Point) -> Point:
        area = self.engine.physics.area
        half = (self.height_points * self.atlas.width_ratio + 12) / 2
        return Point(max(area.x + half, min(point.x, area.right - half)),
                     max(area.y, min(point.y, area.top - self.height_points - 6)))

    def _make_menu(self) -> QMenu:
        menu = QMenu(self)
        self.title_action = menu.addAction("")
        self.title_action.setEnabled(False)
        if self.collection:
            self._action(menu, "캐릭터 관리 (+ / −)…", self.collection.open_library)
            self._action(menu, "+ 같은 캐릭터 추가", lambda: self.collection.add_character(self.settings.character, scale=self.settings.scale))
            self._action(menu, "− 이 캐릭터 없애기", lambda: self.collection.remove(self))
        self._action(menu, "캐릭터 생성…", self.create_character)
        self.character_menu = QMenu("캐릭터 선택", menu)
        menu.addMenu(self.character_menu)
        characters = self.character_menu
        self.character_actions = {}
        self.character_group = QActionGroup(self)
        self.character_group.setExclusive(True)
        self.populate_character_menu()
        menu.addSeparator()
        self.examples_menu = QMenu("동작 예시", menu)
        menu.addMenu(self.examples_menu)
        examples = self.examples_menu
        self.idle_action = self._action(examples, "", self.play_idle)
        self._action(examples, "커서 잡기 (잠시 멈춰 주세요)", self.catch_cursor)
        self._action(examples, "걷기", lambda: self.move_now("walking"))
        self._action(examples, "뛰기", lambda: self.move_now("running"))
        self._action(examples, "위로 점프", self.jump_now)
        self._action(examples, "아래로 내려가기", self.drop_now)
        self._action(examples, "방향 바꾸기", self.turn_now)
        self.keyboard_action = self._action(menu, "", lambda: self.set_manual(not self.engine.manual))
        self.keyboard_action.setCheckable(True)
        self.pause_action = self._action(menu, "", self.toggle_pause)
        self.hide_action = self._action(menu, "", self.toggle_hidden)
        menu.addSeparator()
        self.sizes_menu = QMenu("크기 배율", menu)
        menu.addMenu(self.sizes_menu)
        sizes = self.sizes_menu
        self.size_actions = {}
        self.size_group = QActionGroup(self)
        self.size_group.setExclusive(True)
        for scale in SCALES:
            action = sizes.addAction(f"{scale:g}배" + (" (기본)" if scale == 1 else ""))
            action.setCheckable(True)
            self.size_group.addAction(action)
            action.triggered.connect(lambda _checked=False, value=scale: self.choose_scale(value))
            self.size_actions[scale] = action
        self._action(menu, "위치 초기화", self.reset_position)
        menu.addSeparator()
        self._action(menu, "모두 종료" if self.collection else "종료", QApplication.instance().quit)
        menu.aboutToShow.connect(self.before_menu)
        menu.aboutToHide.connect(self.after_menu)
        return menu

    @staticmethod
    def _action(menu: QMenu, label: str, handler) -> QAction:
        action = menu.addAction(label)
        action.triggered.connect(lambda _checked=False: handler())
        return action

    def _sync_menu(self) -> None:
        character = self.settings.character
        title = f"바탕화면 친구 · {self.atlas.display_name}"
        self.setWindowTitle(title)
        self.title_action.setText(title)
        self.tray.setToolTip(title)
        self.idle_action.setText("지금 꼬리 흔들기" if character == "puppy" else "지금 대기 동작 보기")
        self.keyboard_action.setText("키보드 조종 끄기 (Esc)" if self.engine.manual else "키보드 조종 켜기")
        self.keyboard_action.setChecked(self.engine.manual)
        self.pause_action.setText("다시 움직이기" if self.engine.paused else "일시정지")
        self.hide_action.setText(f"{self.atlas.display_name} {'보이기' if self.engine.hidden else '숨기기'}")
        for key, action in self.character_actions.items():
            action.setChecked(key == character)
        for scale, action in self.size_actions.items():
            action.setChecked(scale == self.settings.scale)
        icon = QIcon(QPixmap.fromImage(self.atlas.rest.image).scaled(40, 40, Qt.AspectRatioMode.KeepAspectRatio, Qt.TransformationMode.FastTransformation))
        self.tray.setIcon(icon)
        self.setWindowIcon(icon)

    def before_menu(self) -> None:
        if self.collection:
            self.collection.menu_opened(self.menu)
        self.engine.menu_open = True
        self.engine.stop(time.monotonic())

    def after_menu(self) -> None:
        if self.collection:
            self.collection.menu_closed(self.menu)
        self.engine.menu_open = self.creating or bool(self.collection and self.collection.ui_paused)
        self.last_tick = time.monotonic()
        self.engine.reschedule_auto(self.last_tick)
        if self.engine.manual and not self.creating:
            QTimer.singleShot(0, self.take_keyboard_focus)

    def _tray_activated(self, reason) -> None:
        if reason == QSystemTrayIcon.ActivationReason.DoubleClick:
            if self.engine.hidden:
                self.toggle_hidden()
            else:
                self.raise_()

    def refresh_scene(self) -> None:
        windows = self.native.windows(self.space)
        self.engine.physics.update_ledges(window_ledges(windows, self.engine.physics.area))

    def tick(self) -> None:
        if self._closed:
            return
        try:
            now = time.monotonic()
            dt = now - self.last_tick
            self.last_tick = now
            if self.suspended or not self.engine.active:
                return
            if dt > 1:
                self.engine.stop(now)
                self.engine.reschedule_auto(now)
            if now >= self.next_scene:
                if not self.engine.manual:
                    self.last_external_application = self.native.external_foreground() or self.last_external_application
                self.refresh_scene()
                self.next_scene = now + 0.2
            self.engine.tick(dt, now, self.cursor_world(), self.native.buttons(), self.isActiveWindow())
            self.position_pet()
            self.update_sprite(now)
            if now >= self.next_save:
                self.save_settings()
                self.next_save = now + 2
        except Exception:
            LOG.exception("Desktop update failed; pausing the pet")
            try:
                self.engine.stop(time.monotonic())
            except OSError:
                LOG.exception("Cursor release failed")
            self.engine.paused = True
            self._sync_menu()

    def update_sprite(self, now: float) -> None:
        engine, p = self.engine, self.engine.physics
        if engine.trick:
            trick = engine.trick
            sprite, mirrored = (self.atlas.cursor_roll if trick.phase == "rolling" else self.atlas.cursor_jump)[trick.frame], trick.mirrored
        elif engine.hop and not engine.dragging:
            sprite, mirrored = self.atlas.hopping(engine.hop, p.vy), p.facing_left
        elif p.moving and engine.active:
            sprite, mirrored = self.atlas.movement(engine.gait, p.facing_left, now)
        elif engine.idle_frame is not None:
            sprite, mirrored = self.atlas.idle[engine.idle_frame], False
        elif p.grounded and not engine.dragging:
            sprite, mirrored = self.atlas.gaze[engine.gaze], False
        else:
            sprite, mirrored = self.atlas.rest, False
        if self.sprite is not sprite or self.mirrored != mirrored:
            self.sprite, self.mirrored = sprite, mirrored
            self.update()

    def position_pet(self) -> None:
        width = ceil(self.height_points * self.atlas.width_ratio + 12)
        height = ceil(self.height_points + 12)
        if self.width() != width or self.height() != height:
            self.resize(width, height)
        feet = self.engine.feet
        self.move(round(feet.x - width / 2), round(-feet.y - height + 6))

    def paintEvent(self, _event) -> None:
        painter = QPainter(self)
        painter.setRenderHint(QPainter.RenderHint.SmoothPixmapTransform, False)
        painter.setCompositionMode(QPainter.CompositionMode.CompositionMode_Source)
        painter.fillRect(self.rect(), QColor(0, 0, 0, 0))
        painter.setCompositionMode(QPainter.CompositionMode.CompositionMode_SourceOver)
        feet = self.engine.feet
        # Preserve subpixel contact despite QWidget.move's integer coordinates.
        if not self.engine.dragging:
            painter.translate(feet.x - (self.x() + self.width() / 2), -feet.y - (self.y() + self.height() - 6))
        if self.mirrored:
            painter.translate(self.width(), 0)
            painter.scale(-1, 1)
        painter.drawImage(self.sprite.rect(self.width(), self.height(), self.height_points), self.sprite.image)
        painter.resetTransform()
        if self.engine.manual and self.isActiveWindow():
            painter.setPen(QPen(QColor(30, 205, 200, 180), 1.5))
            painter.setBrush(Qt.BrushStyle.NoBrush)
            painter.drawRoundedRect(self.rect().adjusted(2, 2, -2, -2), 6, 6)

    def _reset_motion(self) -> None:
        self.engine.stop(time.monotonic())
        self.engine.cancel_hop()

    def choose_character(self, name: str) -> None:
        if name == self.settings.character:
            return
        if name not in self.atlases:
            try:
                self.atlases[name] = Atlas(name, profile=self.profiles[name])
            except Exception as error:
                QMessageBox.warning(self, "캐릭터를 불러오지 못했습니다", str(error))
                self._sync_menu()
                return
        self._reset_motion()
        self.settings.character = name
        self.atlas = self.atlases[name]
        self.sprite, self.mirrored = self.atlas.rest, False
        p = self.engine.physics
        p.wrap_half_width = self.height_points * self.atlas.width_ratio / 2
        p.teleport(self.clamp_feet(p.feet))
        self.engine.next_cursor = time.monotonic() + PetEngine.CURSOR_INTERVAL
        self.refresh_scene()
        self.position_pet()
        self._sync_menu()
        self.save_settings()
        self.update()
        if self.collection:
            self.collection.changed()

    def populate_character_menu(self) -> None:
        for action in self.character_group.actions():
            self.character_group.removeAction(action)
        self.character_menu.clear()
        self.character_actions = {}
        for key, title in self.character_names.items():
            action = self.character_menu.addAction(title.replace("&", "&&"))
            action.setCheckable(True)
            self.character_group.addAction(action)
            action.triggered.connect(lambda _checked=False, name=key: self.choose_character(name))
            self.character_actions[key] = action

    def create_character(self) -> None:
        if self.collection:
            self.collection.open_creator()
            return
        if self.creator_dialog:
            self.creator_dialog.show()
            self.creator_dialog.raise_()
            self.creator_dialog.activateWindow()
            return
        from .creator import CharacterCreator
        self._reset_motion()
        self.creating = True
        self.engine.menu_open = True
        try:
            dialog = CharacterCreator(self.library, self.atlas.template, self)
        except Exception:
            self.creating = False
            self.engine.menu_open = False
            raise
        dialog.created.connect(self.register_character)
        dialog.finished.connect(self.creator_finished)
        self.creator_dialog = dialog
        dialog.show()
        dialog.raise_()
        dialog.activateWindow()

    def register_character(self, profile, atlas) -> None:
        self.profiles[profile.id] = profile
        self.atlases[profile.id] = atlas
        self.character_names[profile.id] = profile.name
        self.populate_character_menu()
        self.choose_character(profile.id)

    def creator_finished(self, *_args) -> None:
        self.creator_dialog = None
        self.creating = False
        self.engine.menu_open = False
        self.last_tick = time.monotonic()
        self.engine.reschedule_auto(self.last_tick)
        if self.engine.manual and not self._closed:
            QTimer.singleShot(0, self.take_keyboard_focus)

    def choose_scale(self, scale: float) -> None:
        self._reset_motion()
        self.settings.scale = scale
        p = self.engine.physics
        p.height = self.height_points
        p.wrap_half_width = p.height * self.atlas.width_ratio / 2
        p.teleport(self.clamp_feet(p.feet))
        self.refresh_scene()
        self.position_pet()
        self._sync_menu()
        self.save_settings()
        self.update()

    def set_manual(self, enabled: bool) -> None:
        if enabled:
            self.previous_application = self.native.external_foreground() or self.last_external_application
        self.engine.set_manual(enabled, time.monotonic())
        self.native.no_activate(int(self.winId()), not enabled)
        if enabled:
            self.show()
            self.take_keyboard_focus()
            QTimer.singleShot(0, self.take_keyboard_focus)
        else:
            self.clearFocus()
            self.native.activate(self.previous_application)
            self.previous_application = 0
        self._sync_menu()
        self.update()

    def take_keyboard_focus(self) -> None:
        if self.engine.manual and not self.engine.hidden and not self._closed and not (self.collection and self.collection.ui_paused):
            self.native.activate(int(self.winId()))
            self.activateWindow()
            self.setFocus(Qt.FocusReason.OtherFocusReason)
            self.engine.reset_keys()

    def toggle_pause(self) -> None:
        self.engine.stop(time.monotonic())
        self.engine.paused = not self.engine.paused
        self.last_tick = time.monotonic()
        self._sync_menu()
        self.update()

    def toggle_hidden(self) -> None:
        self.engine.stop(time.monotonic())
        self.engine.hidden = not self.engine.hidden
        self.setVisible(not self.engine.hidden)
        self._sync_menu()

    def _wake(self) -> None:
        self.engine.paused = self.engine.hidden = False
        self.engine.reschedule_auto(time.monotonic())
        self.show()
        self._sync_menu()

    def play_idle(self) -> None:
        self._reset_motion()
        self._wake()
        self.engine.physics.set_speed(0)
        self.engine.idle_frame = 0
        self.engine.next_idle = time.monotonic() + 0.16
        self.update_sprite(time.monotonic())

    def move_now(self, gait: str) -> None:
        self._reset_motion()
        self._wake()
        self.engine.gait = gait
        self.engine.physics.set_speed((-1 if self.engine.physics.facing_left else 1) * self.engine.speed)
        self.engine.walk_until = time.monotonic() + 7
        self.engine.next_action = time.monotonic() + 7

    def turn_now(self) -> None:
        left = self.engine.physics.facing_left
        self.move_now(self.engine.gait)
        self.engine.physics.set_speed(self.engine.speed if left else -self.engine.speed)

    def jump_now(self) -> None:
        self._wake()
        self.refresh_scene()
        if not self.engine.attempt_climb():
            self.engine.begin_hop("in_place", self.height_points * 1.2)
        self.engine.walk_until = time.monotonic() + 4

    def drop_now(self) -> None:
        self._wake()
        self.engine.climbing = self.engine.approaching = False
        self.engine.begin_hop("down", None)

    def catch_cursor(self) -> None:
        if self.engine.manual:
            self.set_manual(False)
        self.engine.request_cursor(time.monotonic())
        self._wake()

    def reset_position(self) -> None:
        self._reset_motion()
        self.current_screen = QApplication.primaryScreen()
        self.space, area = self._screen_space(self.current_screen)
        self.engine.physics.area = area
        self.engine.physics.teleport(self.clamp_feet(Point(area.right - 100, area.y)))
        self.refresh_scene()
        self.position_pet()
        self.save_settings()

    def display_changed(self, *_args) -> None:
        if self._closed:
            return
        try:
            self._reset_motion()
            self.current_screen = QApplication.screenAt(self.frameGeometry().center()) or QApplication.primaryScreen()
            self.space, area = self._screen_space(self.current_screen)
            self.engine.physics.area = area
            self.engine.physics.teleport(self.clamp_feet(self.engine.physics.feet))
            self.refresh_scene()
            self.position_pet()
            self.last_tick = time.monotonic()
            self.engine.reschedule_auto(self.last_tick)
        except Exception:
            LOG.exception("Screen configuration changed")
            self.engine.paused = True
            self._sync_menu()

    def contextMenuEvent(self, event) -> None:
        self.menu.exec(event.globalPos())

    def mousePressEvent(self, event) -> None:
        if event.button() == Qt.MouseButton.LeftButton:
            self.engine.dragging = True
            self._reset_motion()
            self.drag_offset = event.globalPosition() - QPointF(self.pos())
            self.update_sprite(time.monotonic())
            if self.engine.manual:
                self.take_keyboard_focus()
            event.accept()
        else:
            super().mousePressEvent(event)

    def mouseMoveEvent(self, event) -> None:
        if self.drag_offset is None:
            super().mouseMoveEvent(event)
            return
        proposed = event.globalPosition() - self.drag_offset
        screen = QApplication.screenAt(event.globalPosition().toPoint()) or self.current_screen
        area = screen.availableGeometry()
        self.move(round(max(area.left(), min(proposed.x(), area.right() + 1 - self.width()))),
                  round(max(area.top(), min(proposed.y(), area.bottom() + 1 - self.height()))))

    def mouseReleaseEvent(self, event) -> None:
        if event.button() == Qt.MouseButton.LeftButton and self.drag_offset is not None:
            self.drag_offset = None
            self.engine.dragging = False
            self.current_screen = QApplication.screenAt(self.frameGeometry().center()) or QApplication.primaryScreen()
            self.space, area = self._screen_space(self.current_screen)
            self.engine.physics.area = area
            self.engine.physics.teleport(self.clamp_feet(Point(self.x() + self.width() / 2, -self.y() - self.height() + 6)))
            self.refresh_scene()
            self.last_tick = time.monotonic()
            self.save_settings()
            event.accept()
        else:
            super().mouseReleaseEvent(event)

    @staticmethod
    def _key(event) -> str | None:
        return {Qt.Key.Key_A: "a", Qt.Key.Key_D: "d", Qt.Key.Key_W: "w", Qt.Key.Key_S: "s", Qt.Key.Key_Space: "space"}.get(event.key())

    def keyPressEvent(self, event) -> None:
        if not self.engine.manual:
            event.ignore()
            return
        if event.key() == Qt.Key.Key_Escape:
            self.set_manual(False)
            event.accept()
            return
        if event.modifiers() & (Qt.KeyboardModifier.ControlModifier | Qt.KeyboardModifier.AltModifier | Qt.KeyboardModifier.MetaModifier):
            self.engine.reset_keys()
            event.ignore()
            return
        self.engine.running = bool(event.modifiers() & Qt.KeyboardModifier.ShiftModifier) or event.key() == Qt.Key.Key_Shift
        key = self._key(event)
        if key:
            self.engine.key_down(key, event.isAutoRepeat())
            event.accept()
        else:
            super().keyPressEvent(event)

    def keyReleaseEvent(self, event) -> None:
        if event.isAutoRepeat():
            event.accept()
            return
        self.engine.running = bool(event.modifiers() & Qt.KeyboardModifier.ShiftModifier) and event.key() != Qt.Key.Key_Shift
        key = self._key(event)
        if key:
            self.engine.key_up(key)
            event.accept()
        else:
            super().keyReleaseEvent(event)

    def focusOutEvent(self, event) -> None:
        self.engine.reset_keys()
        self.update()
        super().focusOutEvent(event)

    def nativeEvent(self, event_type, message):
        if bytes(event_type) in (b"windows_generic_MSG", b"windows_dispatcher_MSG"):
            msg = ctypes.cast(int(message), ctypes.POINTER(wintypes.MSG)).contents
            if msg.message == 0x0218:  # WM_POWERBROADCAST: suspend / automatic resume.
                if msg.wParam == 4:
                    self.suspended = True
                    self.engine.stop(time.monotonic())
                elif msg.wParam in (7, 18):
                    self.suspended = False
                    self.last_tick = time.monotonic()
                    QTimer.singleShot(0, self.display_changed)
        return super().nativeEvent(event_type, message)

    def save_settings(self) -> None:
        if not self.persist:
            return
        if self.collection:
            self.collection.save()
            return
        self.settings.x, self.settings.y = self.engine.physics.feet.x, self.engine.physics.feet.y
        self.settings.save()

    def saved_instance(self) -> dict:
        p = self.engine.physics.feet
        return {"id": self.instance_id, "character": self.settings.character, "base_height": 60,
                "scale": self.settings.scale, "x": p.x, "y": p.y}

    def shutdown(self) -> None:
        if self._closed:
            return
        self._closed = True
        self.timer.stop()
        if self.creator_dialog:
            self.creator_dialog.reject()
        try:
            self.engine.stop(time.monotonic())
        except OSError:
            LOG.exception("Cursor release at exit")
        self.engine.paused = True
        self.save_settings()
        self.tray.hide()

    def closeEvent(self, event) -> None:
        if self.collection:
            self.collection.remove(self)
            event.accept()
            return
        self.shutdown()
        event.accept()
        QApplication.instance().quit()
