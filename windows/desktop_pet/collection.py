"""One tray and library, with an independent engine/window for each pet copy."""
from __future__ import annotations

import logging
import time
import uuid

from PySide6.QtCore import QObject, Qt
from PySide6.QtGui import QIcon, QPixmap
from PySide6.QtWidgets import (QApplication, QDialog, QHBoxLayout, QLabel, QMenu, QMessageBox,
                               QPushButton, QScrollArea, QSystemTrayIcon, QVBoxLayout, QWidget)

from .app import PetWindow
from .assets import Atlas, CHARACTERS
from .custom import CharacterLibrary
from .settings import Settings, valid_instance

LOG = logging.getLogger(__name__)


class LibraryDialog(QDialog):
    def __init__(self, collection):
        super().__init__()
        self.collection = collection
        self.setWindowTitle("캐릭터 관리 (+ / −)")
        self.resize(740, 520)
        self.setMinimumSize(660, 360)
        self.setAttribute(Qt.WidgetAttribute.WA_DeleteOnClose)
        layout = QVBoxLayout(self)
        heading = QLabel("바탕화면에 친구 더하기")
        heading.setStyleSheet("font-size: 23px; font-weight: 600")
        layout.addWidget(heading)
        guide = QLabel("+ 는 한 마리 추가, − 는 한 마리 내리기입니다. 같은 캐릭터도 여러 마리 띄울 수 있어요.\n"
                       "삭제는 직접 만든 캐릭터를 보관함에서 지웁니다. 강아지·보노보노는 삭제할 수 없습니다.")
        guide.setWordWrap(True)
        layout.addWidget(guide)
        self.summary = QLabel()
        layout.addWidget(self.summary)
        self.scroll = QScrollArea()
        self.scroll.setWidgetResizable(True)
        layout.addWidget(self.scroll, 1)
        footer = QHBoxLayout()
        create = QPushButton("캐릭터 생성…")
        create.clicked.connect(collection.open_creator)
        footer.addWidget(create)
        footer.addStretch()
        done = QPushButton("닫기")
        done.clicked.connect(self.accept)
        footer.addWidget(done)
        layout.addLayout(footer)
        self.refresh()

    def refresh(self):
        position = self.scroll.verticalScrollBar().value()
        self.add_buttons, self.remove_buttons, self.delete_buttons = {}, {}, {}
        old = self.scroll.takeWidget()
        if old:
            old.deleteLater()
        content = QWidget()
        layout = QVBoxLayout(content)
        self.summary.setText(f"화면에 총 {len(self.collection.windows)}마리 · 모두 내려도 메뉴에서 다시 추가할 수 있어요.")
        for id, name in self.collection.names.items():
            row = QHBoxLayout()
            image = QLabel()
            image.setFixedSize(56, 64)
            image.setAlignment(Qt.AlignmentFlag.AlignCenter)
            try:
                image.setPixmap(QPixmap.fromImage(self.collection.atlas(id).rest.image).scaled(56, 64, Qt.AspectRatioMode.KeepAspectRatio, Qt.TransformationMode.FastTransformation))
            except Exception:
                LOG.exception("Character thumbnail failed")
            row.addWidget(image)
            labels = QVBoxLayout()
            label = QLabel(name)
            label.setTextFormat(Qt.TextFormat.PlainText)
            label.setWordWrap(True)
            label.setStyleSheet("font-weight: 600; font-size: 15px")
            labels.addWidget(label)
            labels.addWidget(QLabel("기본 캐릭터 · 삭제 불가" if id in CHARACTERS else "내 캐릭터"))
            row.addLayout(labels, 1)
            count = self.collection.count(id)
            row.addWidget(QLabel(f"{count}마리"))
            plus, minus, delete = QPushButton("+"), QPushButton("−"), QPushButton("삭제")
            for button in (plus, minus):
                button.setFixedWidth(42)
                button.setStyleSheet("font-weight: bold; font-size: 20px")
            plus.setToolTip(f"{name} 한 마리 추가")
            minus.setToolTip(f"{name} 한 마리 내리기")
            minus.setEnabled(count > 0)
            delete.setEnabled(id not in CHARACTERS)
            plus.clicked.connect(lambda _checked=False, key=id: self.collection.add_character(key))
            minus.clicked.connect(lambda _checked=False, key=id: self.collection.remove_one(key))
            delete.clicked.connect(lambda _checked=False, key=id: self.collection.confirm_delete(key))
            for button in (plus, minus, delete):
                row.addWidget(button)
            self.add_buttons[id], self.remove_buttons[id], self.delete_buttons[id] = plus, minus, delete
            layout.addLayout(row)
        layout.addStretch()
        self.scroll.setWidget(content)
        self.scroll.verticalScrollBar().setValue(position)


class PetCollection(QObject):
    def __init__(self, native, settings: Settings, *, timers=True, persist=True):
        super().__init__()
        self.native, self.settings, self.timers, self.persist = native, settings, timers, persist
        self.atlases = {id: Atlas(id) for id in CHARACTERS}
        self.library = CharacterLibrary(settings.path.parent / "characters")
        self.profiles = {p.id: p for p in self.library.all()}
        self.windows: list[PetWindow] = []
        self.library_dialog = self.creator_dialog = None
        self.ui_paused = self.restoring = self.closed = False
        self.tracking_menus = set()
        self.tray = QSystemTrayIcon(self)
        self.menu = QMenu()
        self.menu.aboutToShow.connect(self.status_opened)
        self.menu.aboutToHide.connect(self.status_closed)
        self.tray.setContextMenu(self.menu)
        self.tray.activated.connect(self.tray_activated)
        QApplication.instance().aboutToQuit.connect(self.shutdown)
        self.refresh_menu()
        if timers:
            self.tray.show()

    @property
    def names(self):
        return {**CHARACTERS, **{id: p.name for id, p in self.profiles.items()}}

    def atlas(self, id):
        if id not in self.atlases:
            self.atlases[id] = Atlas(id, profile=self.profiles[id])
        return self.atlases[id]

    def restore(self, states=None):
        if states is None:
            states = self.settings.instances
            if states is None:
                states = [{"id": str(uuid.uuid4()), "character": self.settings.character, "scale": self.settings.scale,
                           "base_height": 60, "x": self.settings.x, "y": self.settings.y}]
        self.restoring = True
        try:
            for state in states:
                if valid_instance(state):
                    try:
                        self.spawn(state)
                    except Exception:
                        LOG.exception("Saved pet copy could not be restored")
            if not self.windows:
                self.spawn({"id": str(uuid.uuid4()), "character": "puppy", "base_height": 60, "scale": 1})
        finally:
            self.restoring = False
        self.changed()

    def spawn(self, state):
        if not valid_instance(state):
            raise ValueError("캐릭터 설정이 올바르지 않습니다.")
        self.atlas(state["character"])
        settings = Settings(self.settings.path)
        settings.character, settings.scale = state["character"], state["scale"]
        settings.x, settings.y = state.get("x"), state.get("y")
        if settings.x is None:
            geo = QApplication.primaryScreen().availableGeometry()
            settings.x = geo.right() - 100 - len(self.windows) % 8 * 75
            settings.y = -(geo.bottom() + 1)
        id = state["id"]
        if any(w.instance_id == id for w in self.windows):
            id = str(uuid.uuid4())
        window = PetWindow(self.native, settings, timers=self.timers, persist=self.persist, collection=self, instance_id=id)
        self.windows.append(window)
        window.show()
        self.changed()
        return window

    def add_character(self, id, *, scale=1):
        try:
            return self.spawn({"id": str(uuid.uuid4()), "character": id, "base_height": 60, "scale": scale})
        except Exception as error:
            QMessageBox.warning(self.library_dialog, "캐릭터를 추가하지 못했습니다", str(error))

    def remove(self, window):
        if window not in self.windows:
            return
        self.windows.remove(window)
        window.shutdown()
        window.close()
        window.deleteLater()
        self.changed()

    def remove_one(self, id):
        window = next((w for w in reversed(self.windows) if w.settings.character == id), None)
        if window:
            self.remove(window)

    def count(self, id):
        return sum(w.settings.character == id for w in self.windows)

    def can_catch_cursor(self, window):
        return not any(w is not window and w.engine.trick for w in self.windows)

    def save(self):
        if self.persist and not self.restoring and not self.closed:
            self.settings.instances = [window.saved_instance() for window in self.windows]
            self.settings.save()

    def changed(self):
        if self.restoring or self.closed:
            return
        self.refresh_menu()
        if self.library_dialog:
            self.library_dialog.refresh()
        self.save()

    def refresh_menu(self):
        self.menu.clear()
        PetWindow._action(self.menu, "캐릭터 관리 (+ / −)…", self.open_library)
        PetWindow._action(self.menu, "캐릭터 생성…", self.open_creator)
        if self.windows:
            self.menu.addSeparator()
        for index, window in enumerate(self.windows):
            window.menu.setTitle(f"{window.atlas.display_name} · {index + 1}".replace("&", "&&"))
            self.menu.addMenu(window.menu)
        self.menu.addSeparator()
        PetWindow._action(self.menu, "모두 종료", QApplication.instance().quit)
        self.tray.setToolTip(f"바탕화면 친구 {len(self.windows)}마리 · + / −로 관리")
        self.tray.setIcon(QIcon(QPixmap.fromImage(self.atlases["puppy"].rest.image).scaled(40, 40, Qt.AspectRatioMode.KeepAspectRatio)))

    def update_suspension(self):
        self.ui_paused = self.library_dialog is not None or self.creator_dialog is not None or bool(self.tracking_menus)
        for window in self.windows:
            window.engine.stop(time.monotonic())
            window.engine.menu_open = self.ui_paused
            window.last_tick = time.monotonic()
            window.engine.reschedule_auto(window.last_tick)

    def status_opened(self):
        self.menu_opened(self.menu)

    def status_closed(self):
        self.menu_closed(self.menu)

    def menu_opened(self, menu):
        self.tracking_menus.add(id(menu))
        self.update_suspension()

    def menu_closed(self, menu):
        self.tracking_menus.discard(id(menu))
        self.update_suspension()

    def open_library(self):
        if self.library_dialog is None:
            self.library_dialog = LibraryDialog(self)
            self.library_dialog.finished.connect(self.library_finished)
        self.update_suspension()
        self.library_dialog.show()
        self.library_dialog.raise_()
        self.library_dialog.activateWindow()

    def library_finished(self, *_args):
        self.library_dialog = None
        self.update_suspension()

    def open_creator(self):
        if self.creator_dialog is None:
            from .creator import CharacterCreator
            self.creator_dialog = CharacterCreator(self.library, "puppy")
            self.creator_dialog.created.connect(self.register_character)
            self.creator_dialog.finished.connect(self.creator_finished)
        self.update_suspension()
        self.creator_dialog.show()
        self.creator_dialog.raise_()
        self.creator_dialog.activateWindow()

    def register_character(self, profile, atlas):
        self.profiles[profile.id] = profile
        self.atlases[profile.id] = atlas
        self.refresh_library()
        self.add_character(profile.id)

    def creator_finished(self, *_args):
        self.creator_dialog = None
        self.update_suspension()

    def refresh_library(self):
        self.profiles = {p.id: p for p in self.library.all()}
        for window in self.windows:
            window.profiles = dict(self.profiles)
            window.character_names = dict(self.names)
            window.populate_character_menu()
            window._sync_menu()
        self.changed()

    def confirm_delete(self, id):
        if id not in self.profiles:
            return
        name = self.profiles[id].name
        answer = QMessageBox.question(self.library_dialog, "캐릭터 삭제",
            f"‘{name}’ 캐릭터를 삭제할까요?\n보관함에서 삭제하고 화면의 이 캐릭터 {self.count(id)}마리도 모두 내립니다.",
            QMessageBox.StandardButton.Yes | QMessageBox.StandardButton.Cancel, QMessageBox.StandardButton.Cancel)
        if answer == QMessageBox.StandardButton.Yes:
            try:
                self.delete_character(id)
            except Exception as error:
                QMessageBox.warning(self.library_dialog, "삭제하지 못했습니다", str(error))

    def delete_character(self, id):
        self.library.delete(id)
        for window in list(self.windows):
            if window.settings.character == id:
                self.remove(window)
        self.atlases.pop(id, None)
        self.refresh_library()

    def tray_activated(self, reason):
        if reason == QSystemTrayIcon.ActivationReason.DoubleClick:
            self.open_library()

    def shutdown(self):
        if self.closed:
            return
        self.save()
        self.closed = True
        if self.library_dialog:
            self.library_dialog.reject()
        if self.creator_dialog:
            self.creator_dialog.reject()
        for window in list(self.windows):
            window.shutdown()
            window.hide()
            window.deleteLater()
        self.windows.clear()
        self.tray.hide()
