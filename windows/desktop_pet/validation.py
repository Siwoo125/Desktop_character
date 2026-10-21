from __future__ import annotations

from pathlib import Path
import tempfile
import unicodedata

from PySide6.QtCore import QRectF
from PySide6.QtGui import QColor, QImage, QPainter
from PySide6.QtWidgets import QApplication

from .animation import Hop, SCALES
from .assets import Atlas, CHARACTERS, resolve_asset
from .physics import DesktopWindow, Point, Rect
from .settings import Settings
from .win32 import Monitor, NativeRect


def render_grid(entries, path: Path, atlas: Atlas) -> None:
    rows = (len(entries) + 3) // 4
    image = QImage(960, rows * 220, QImage.Format.Format_ARGB32_Premultiplied)
    image.fill(QColor("#1a2435"))
    painter = QPainter(image)
    painter.setRenderHint(QPainter.RenderHint.SmoothPixmapTransform, False)
    for i, (sprite, label, mirror) in enumerate(entries):
        x, y = (i % 4) * 240, (i // 4) * 220
        painter.save()
        painter.translate(x, y)
        if mirror:
            painter.translate(240, 0)
            painter.scale(-1, 1)
        painter.drawImage(sprite.rect(240, 172, 160), sprite.image)
        painter.restore()
        painter.setPen(QColor("white"))
        painter.drawText(x + 30, y + 198, label)
    painter.end()
    path.parent.mkdir(parents=True, exist_ok=True)
    if not image.save(str(path)):
        raise RuntimeError(f"미리보기를 저장할 수 없습니다: {path}")


def validate_assets(preview_dir: Path | None = None) -> dict[str, Atlas]:
    atlases = {name: Atlas(name) for name in CHARACTERS}
    for name, atlas in atlases.items():
        assert len(atlas.walk) == len(atlas.run) == len(atlas.idle) == 8
        assert len(atlas.cursor_jump) == len(atlas.cursor_roll) == 8
        assert len(atlas.gaze) == 3
        for scale in SCALES:
            height = 60 * scale
            canvas = QRectF(0, 0, height * atlas.width_ratio + 12, height + 12)
            for sprite in atlas.sprites:
                assert not sprite.image.isNull() and sprite.image.hasAlphaChannel()
                assert canvas.contains(sprite.rect(canvas.width(), canvas.height(), height)), (name, "clipped pose")
            for mirror in (False, True):
                for rolling in (False, True):
                    frames = atlas.cursor_roll if rolling else atlas.cursor_jump
                    for i in range(0 if rolling else 4, 8):
                        offset = atlas.grip(rolling, i, mirror, height)
                        assert abs(offset.x) <= height * atlas.width_ratio / 2
                        assert 0 <= offset.y <= height
        left, mirror = atlas.movement("walking", True, 0)
        if name == "bonobono":
            assert atlas.left_walk and len(atlas.left_walk) == 8
            assert left is atlas.left_walk[0] and not mirror
            hop = Hop("upward")
            seen = {id(atlas.hopping(hop, 0))}
            hop.transition("airborne")
            seen.add(id(atlas.hopping(hop, 300)))
            hop.elapsed = 0.1
            for velocity in (300, 0, -200):
                seen.add(id(atlas.hopping(hop, velocity)))
            hop.transition("before_landing")
            seen.add(id(atlas.hopping(hop, -200)))
            hop.transition("landing")
            seen.add(id(atlas.hopping(hop, 0)))
            hop.elapsed = 0.13
            seen.add(id(atlas.hopping(hop, 0)))
            assert len(seen) == 8
        else:
            assert left is atlas.walk[0] and mirror
        assert atlas.movement("running", True, 0)[1]
        if preview_dir:
            movement = [(atlas.rest, "기본 자세", False)] + [(s, f"시선 {i + 1}", False) for i, s in enumerate(atlas.gaze)]
            for label, sprites, mirror in [("대기", atlas.idle, False), ("오른쪽 걷기", atlas.walk, False),
                                           ("왼쪽 걷기", atlas.left_walk or atlas.walk, atlas.left_walk is None),
                                           ("오른쪽 달리기", atlas.run, False), ("왼쪽 달리기", atlas.run, True)]:
                movement.extend((s, f"{label} {i + 1}", mirror) for i, s in enumerate(sprites))
            render_grid(movement, preview_dir / f"{name}-movement.png", atlas)
            render_grid([(s, f"점프 {i + 1}", False) for i, s in enumerate(atlas.leap or atlas.up + atlas.down)], preview_dir / f"{name}-jump.png", atlas)
            render_grid([(s, f"커서 잡기 {i + 1}", False) for i, s in enumerate(atlas.cursor_jump)] +
                        [(s, f"구르기 {i + 1}", False) for i, s in enumerate(atlas.cursor_roll)], preview_dir / f"{name}-cursor.png", atlas)
        print(f"PASS: {CHARACTERS[name]} 이미지·전 배율·좌우 이동·도약·손 접점")
    with tempfile.TemporaryDirectory() as folder:
        root = Path(folder)
        nfd = root / unicodedata.normalize("NFD", "유휴상태.png")
        nfd.touch()
        assert resolve_asset(root, "유휴상태.png").samefile(nfd)
    print("PASS: macOS/Windows 한글 파일명 정규화")
    return atlases


class FakeNative:
    """No native input, activation or real window enumeration during Qt checks."""
    def __init__(self):
        screen = QApplication.primaryScreen()
        geo = screen.geometry()
        self.monitor = Monitor(screen.name(), NativeRect(geo.left(), geo.top(), geo.right() + 1, geo.bottom() + 1),
                               NativeRect(geo.left(), geo.top(), geo.right() + 1, geo.bottom() + 1))
        self.pointer = Point(geo.left() + 500, geo.top() + 250)
        self.no_activation = True

    def monitors(self):
        return [self.monitor]

    def cursor(self):
        return self.pointer

    def move_cursor(self, point):
        self.pointer = point
        return True

    def buttons(self):
        return False

    def no_activate(self, _handle, enabled):
        self.no_activation = enabled

    def activate(self, _handle):
        pass

    def foreground(self):
        return 0

    def external_foreground(self):
        return 0

    def windows(self, _space):
        return []


def validate_widget(preview_dir: Path | None = None) -> None:
    from .app import PetWindow
    with tempfile.TemporaryDirectory() as folder:
        settings = Settings(Path(folder) / "settings.json")
        native = FakeNative()
        window = PetWindow(native, settings, timers=False)
        try:
            examples = next(action.menu() for action in window.menu.actions() if action.text() == "동작 예시")
            assert len(examples.actions()) == 7
            for character in ("puppy", "bonobono", "puppy"):
                window.character_actions[character].trigger()
                assert window.atlas.character == character and settings.character == character
                assert window.character_actions[character].isChecked()
                for scale in SCALES:
                    window.size_actions[scale].trigger()
                    assert settings.scale == scale
                    window.engine.physics.advance(1 / 120)
                    window.update_sprite(1)
                    window.position_pet()
                    image = QImage(window.size(), QImage.Format.Format_ARGB32_Premultiplied)
                    image.fill(QColor(0, 0, 0, 0))
                    window.render(image)
                    assert not image.isNull()
            window.choose_scale(1)
            # A drag moves the QWidget before physics catches up on release. Rendering
            # must follow the widget, not compensate back to the old desktop position.
            window.engine.dragging = True
            window.move(window.x() + 180, window.y() - 100)
            image = QImage(window.size(), QImage.Format.Format_ARGB32_Premultiplied)
            image.fill(QColor(0, 0, 0, 0))
            window.render(image)
            assert any(image.pixelColor(x, y).alpha() for y in range(image.height()) for x in range(image.width()))
            window.engine.dragging = False
            p = window.engine.physics
            p.teleport(Point(p.area.x + p.area.width / 2, p.area.y))
            p.advance(1 / 120)
            grip = window.grip(False, 4, False)
            target = Point(p.feet.x + 80, min(p.area.top - 100, p.feet.y + 220))
            native.pointer = window.space.to_native(target)
            assert window.engine.begin_trick(window.cursor_world(), 0, False)
            for i in range(100):
                window.engine.tick(1 / 30, (i + 1) / 30, window.cursor_world())
                if window.engine.carry.active:
                    break
            assert window.engine.carry.active
            window.character_actions["bonobono"].trigger()
            assert not window.engine.carry.active and window.engine.trick is None
            assert native.pointer == window.space.to_native(target)
            examples.actions()[0].trigger()
            assert window.engine.idle_frame == 0
            window.keyboard_action.trigger()
            assert window.engine.manual and not native.no_activation
            window.keyboard_action.trigger()
            assert not window.engine.manual and native.no_activation
            restored = Settings(settings.path)
            assert restored.character == "bonobono"
            validate_creator(window, Path(folder), preview_dir)
        finally:
            window.shutdown()
            window.deleteLater()
    print("PASS: Qt 투명 창 그리기·캐릭터/배율 메뉴·동작 예시·조종 전환·커서 잡기 중 캐릭터 전환 (Win32는 테스트 대역)")
    validate_collection(preview_dir)
    from .ai_checks import run as ai_checks
    ai_checks()


def validate_creator(window, folder: Path, preview_dir: Path | None) -> None:
    from dataclasses import replace
    import shutil
    from PIL import Image
    from .app import PetWindow
    from .assets import image_directory
    from .custom import SLOTS, validate_png

    def rejects(operation):
        try:
            operation()
        except (ValueError, OSError):
            return
        raise AssertionError("잘못된 입력을 허용했습니다")

    root = image_directory()
    examples = window.library.export_examples("bonobono", root, folder)
    assert len(list(examples.iterdir())) == 12
    window.create_character()
    dialog = window.creator_dialog
    assert dialog and window.creating and not window.engine.active
    assert not dialog.save_button.isEnabled() and dialog.name_field.text()
    dialog.template_picker.setCurrentIndex(0)
    assert dialog.template == "puppy" and dialog.layout_picker.currentIndex() == 0
    assert all(not label.pixmap().isNull() for label in dialog.sample_labels.values())
    dialog.template_picker.setCurrentIndex(1)
    for slot in SLOTS:
        if slot.required:
            dialog.assign(examples / slot.filename, slot)
    assert dialog.save_button.isEnabled()
    dialog.name_field.setText(" ")
    assert not dialog.save_button.isEnabled()
    dialog.name_field.setText("  나의 & 친구  ")
    assert dialog.save_button.isEnabled()
    jump_slot = next(slot for slot in SLOTS if slot.key == "cursor_jump")
    dialog.preview_slot(jump_slot)
    viewer = dialog.preview_dialog
    viewer.picker.setCurrentIndex(4)
    viewer.toggle_play()
    assert viewer.timer.isActive()
    viewer.pick_grip(.61, .52)
    assert not viewer.timer.isActive() and dialog.grips["jump"][4] == {"x": .61, "y": .52}
    viewer.toggle_play()
    viewer.reject()
    assert not viewer.timer.isActive()
    QApplication.processEvents()
    assert dialog.scroll.widget().height() > dialog.scroll.height()
    if preview_dir:
        preview_dir.mkdir(parents=True, exist_ok=True)
        assert dialog.grab().save(str(preview_dir / "character-creator.png"))
    files, grips = dict(dialog.files), dialog.grips
    dialog.save_character()
    QApplication.processEvents()
    profile = window.profiles[window.settings.character]
    atlas = window.atlas
    assert profile.name == "나의 & 친구" and atlas.display_name == profile.name
    assert not window.creating and window.creator_dialog is None and window.engine.active
    assert window.character_actions[profile.id].isChecked()
    assert window.character_actions[profile.id].text() == "나의 && 친구"
    assert atlas.leap and len(atlas.leap) == 8 and atlas.left_walk is None
    assert atlas.movement("walking", True, 0)[1]
    assert atlas.custom_grips["jump"][4] == {"x": .61, "y": .52}
    for slot in SLOTS:
        if slot.required:
            assert (examples / slot.filename).read_bytes() == (profile.directory / slot.filename).read_bytes()
    reloaded = window.library.all()
    assert len(reloaded) == 1 and reloaded[0].id == profile.id
    restored = PetWindow(FakeNative(), Settings(window.settings.path), timers=False)
    try:
        assert restored.settings.character == profile.id and restored.atlas.display_name == profile.name
        assert restored.atlas.custom_grips["jump"][4] == {"x": .61, "y": .52}
        restored.create_character()
        restored.creator_dialog.reject()
        QApplication.processEvents()
        assert not restored.creating and restored.engine.active
    finally:
        restored.shutdown()
        restored.deleteLater()
    split = Atlas(profile.id, profile=replace(profile, leap_layout="split"))
    assert not split.leap and len(split.up) == len(split.down) == 4
    left_slot = next(slot for slot in SLOTS if not slot.required)
    shutil.copyfile(examples / left_slot.filename, profile.directory / left_slot.filename)
    left_profile = replace(profile, assets={**profile.assets, left_slot.key: left_slot.filename})
    left_atlas = Atlas(profile.id, profile=left_profile)
    assert len(left_atlas.left_walk) == 8 and not left_atlas.movement("walking", True, 0)[1]
    rejects(lambda: window.library.create("나의 & 친구", "bonobono", "continuous", files, grips))
    rejects(lambda: window.library.create("누락", "puppy", "split", {}, grips))
    rejects(lambda: window.library.create(" ", "puppy", "split", files, grips))
    invalid = folder / "invalid.png"
    invalid.write_text("not a PNG", encoding="utf-8")
    rejects(lambda: validate_png(invalid, SLOTS[0]))
    for color in ((255, 255, 255, 255), (0, 0, 0, 0)):
        Image.new("RGBA", (64, 32), color).save(invalid)
        rejects(lambda: validate_png(invalid, SLOTS[2]))
    assert not any(p.name.startswith(".pending-") for p in window.library.root.iterdir())
    window.character_actions["puppy"].trigger()
    assert window.atlas.character == "puppy"
    print("PASS: 캐릭터 생성 UI·예시 저장·PNG 검사·이름·보관함·재실행·프레임별 손 위치·메뉴 선택·취소 복구")


def validate_collection(preview_dir: Path | None):
    import uuid
    from .collection import PetCollection
    from .custom import SLOTS, example_path
    from .assets import image_directory

    def state(character, scale=1, x=None):
        return {"id": str(uuid.uuid4()), "character": character, "base_height": 60, "scale": scale, "x": x}

    with tempfile.TemporaryDirectory() as folder:
        settings = Settings(Path(folder) / "settings.json")
        native = FakeNative()
        fresh_startup = PetCollection(native, settings, timers=False, persist=False)
        try:
            fresh_startup.restore()
            assert len(fresh_startup.windows) == 1 and fresh_startup.count("puppy") == 1
        finally:
            fresh_startup.shutdown()
        collection = PetCollection(native, settings, timers=False)
        try:
            a = collection.spawn(state("puppy", .5))
            b = collection.spawn(state("bonobono", 1.5))
            c = collection.spawn(state("puppy", 2))
            assert len(collection.windows) == 3 and collection.count("puppy") == 2
            assert len({w.instance_id for w in collection.windows}) == 3
            assert a.atlas is c.atlas and a.engine is not c.engine and a.engine.physics is not c.engine.physics
            assert [w.settings.scale for w in collection.windows] == [.5, 1.5, 2]
            assert len({w.engine.feet.x for w in collection.windows}) == 3
            before = b.engine.feet
            a.move_now("running")
            a.engine.physics.advance(.1)
            assert b.engine.feet == before and b.engine.physics.vx == 0
            collection.open_library()
            dialog = collection.library_dialog
            assert not dialog.delete_buttons["puppy"].isEnabled() and not dialog.delete_buttons["bonobono"].isEnabled()
            assert collection.ui_paused and all(not w.engine.active for w in collection.windows)
            dialog.add_buttons["bonobono"].click()
            assert collection.count("bonobono") == 2
            dialog.remove_buttons["puppy"].click()
            assert collection.count("puppy") == 1 and a in collection.windows and c not in collection.windows
            QApplication.processEvents()
            if preview_dir:
                preview_dir.mkdir(parents=True, exist_ok=True)
                assert dialog.grab().save(str(preview_dir / "character-library.png"))
            dialog.accept()
            QApplication.processEvents()
            assert not collection.ui_paused
            p = a.engine.physics
            p.teleport(Point(p.area.x + p.area.width / 2, p.area.y))
            p.update_ledges([])
            p.advance(1 / 120)
            target = Point(p.feet.x + 80, min(p.area.top - 100, p.feet.y + 200))
            native.pointer = a.space.to_native(target)
            assert a.engine.begin_trick(target, 0, False)
            assert not b.engine.begin_trick(b.cursor_world(), 0, False)
            for i in range(100):
                a.engine.tick(1 / 30, (i + 1) / 30, a.cursor_world())
                if a.engine.carry.active:
                    break
            assert a.engine.carry.active
            collection.remove(a)
            assert not a.engine.carry.active and not a.timer.isActive() and native.pointer == a.space.to_native(target)
            collection.open_creator()
            creator = collection.creator_dialog
            for slot in SLOTS:
                if slot.required:
                    creator.assign(example_path(image_directory(), "puppy", slot.key), slot)
            creator.name_field.setText("내 복사본 친구")
            before_count = len(collection.windows)
            creator.save_character()
            QApplication.processEvents()
            assert collection.creator_dialog is None and not collection.ui_paused
            assert len(collection.windows) == before_count + 1 and collection.count("bonobono") == 2
            profile = next(iter(collection.profiles.values()))
            collection.add_character(profile.id)
            assert collection.count(profile.id) == 2
            collection.save()
            restored = PetCollection(FakeNative(), Settings(settings.path), timers=False, persist=False)
            try:
                restored.restore()
                assert len(restored.windows) == len(collection.windows) and restored.count(profile.id) == 2
                assert [w.saved_instance() for w in restored.windows] == Settings(settings.path).instances
            finally:
                restored.shutdown()
            for id in ("puppy", "bonobono", "../puppy"):
                try:
                    collection.delete_character(id)
                except ValueError:
                    pass
                else:
                    raise AssertionError("기본 캐릭터 삭제를 허용했습니다")
            collection.delete_character(profile.id)
            assert collection.count(profile.id) == 0 and profile.id not in collection.names and collection.count("bonobono") == 2
            assert not profile.directory.exists() and collection.library.all() == []
            assert any((collection.library.root / ".trash").iterdir())
            for window in list(collection.windows):
                collection.remove(window)
            assert Settings(settings.path).instances == []
            empty_startup = PetCollection(FakeNative(), Settings(settings.path), timers=False, persist=False)
            try:
                empty_startup.restore()
                assert len(empty_startup.windows) == 1 and empty_startup.count("puppy") == 1
                empty_startup.remove_one("puppy")
                assert empty_startup.windows == []
            finally:
                empty_startup.shutdown()
            collection.open_library()
            assert not collection.library_dialog.remove_buttons["puppy"].isEnabled()
            collection.library_dialog.add_buttons["puppy"].click()
            assert len(collection.windows) == 1
            collection.library_dialog.reject()
        finally:
            collection.shutdown()
            QApplication.processEvents()
    print("PASS: 다중·중복 캐릭터·독립 물리/크기·+/− UI·0마리 복구·목록 복원·커서 제거 복구·사용자 삭제·기본 보호")
