from __future__ import annotations

import copy
from pathlib import Path

from PySide6.QtCore import QRectF, QTimer, Qt, QUrl, Signal
from PySide6.QtGui import QColor, QDesktopServices, QImage, QPainter, QPen, QPixmap
from PySide6.QtWidgets import (QComboBox, QDialog, QFileDialog, QGroupBox, QHBoxLayout,
                               QLabel, QLineEdit, QPushButton, QScrollArea, QVBoxLayout, QWidget)

from .assets import Sprite, image_directory
from .custom import CharacterLibrary, SLOTS, Slot, default_grips, example_path, validate_png


class FrameCanvas(QWidget):
    picked = Signal(float, float)

    def __init__(self, parent=None):
        super().__init__(parent)
        self.sprite = None
        self.grip = None
        self.image_rect = QRectF()
        self.setMinimumSize(400, 290)

    def paintEvent(self, _event):
        painter = QPainter(self)
        painter.fillRect(self.rect(), QColor("#202630"))
        if self.sprite is None:
            return
        sprite = self.sprite
        scale = min((self.width() - 40) / sprite.width, (self.height() - 40) / sprite.height)
        self.image_rect = QRectF((self.width() - sprite.width * scale) / 2, (self.height() - sprite.height * scale) / 2,
                                sprite.width * scale, sprite.height * scale)
        painter.setRenderHint(QPainter.RenderHint.SmoothPixmapTransform, False)
        painter.drawImage(self.image_rect, sprite.image)
        if self.grip is not None:
            x = self.image_rect.left() + self.grip["x"] * self.image_rect.width()
            y = self.image_rect.bottom() - self.grip["y"] * self.image_rect.height()
            painter.setPen(QPen(QColor("white"), 2))
            painter.setBrush(QColor("#14caba"))
            painter.drawEllipse(QRectF(x - 6, y - 6, 12, 12))
            painter.drawLine(round(x - 12), round(y), round(x + 12), round(y))
            painter.drawLine(round(x), round(y - 12), round(x), round(y + 12))

    def mousePressEvent(self, event):
        if self.grip is None or not self.image_rect.contains(event.position()):
            return
        p = event.position()
        self.picked.emit((p.x() - self.image_rect.left()) / self.image_rect.width(),
                         1 - (p.y() - self.image_rect.top()) / self.image_rect.height())


class AnimationPreview(QDialog):
    grip_changed = Signal(int, float, float)

    def __init__(self, title: str, sprites: list[Sprite], points=None, parent=None):
        super().__init__(parent)
        self.setWindowTitle(title)
        self.resize(660, 500)
        self.sprites, self.points = sprites, copy.deepcopy(points)
        layout = QVBoxLayout(self)
        self.canvas = FrameCanvas()
        layout.addWidget(self.canvas, 1)
        row = QHBoxLayout()
        self.picker = QComboBox()
        self.picker.addItems([f"프레임 {i + 1}" for i in range(len(sprites))])
        self.picker.currentIndexChanged.connect(self.update_frame)
        row.addWidget(self.picker)
        self.play_button = QPushButton("재생")
        self.play_button.setEnabled(len(sprites) > 1)
        self.play_button.clicked.connect(self.toggle_play)
        row.addWidget(self.play_button)
        row.addStretch()
        layout.addLayout(row)
        help_text = "재생으로 프레임 순서를 확인하세요."
        if points is not None:
            help_text = "프레임을 고른 뒤 잡는 손 부분을 클릭하세요. 청록색 점이 커서 접점입니다. 점프는 5~8번 프레임, 구르기는 모든 프레임에 적용됩니다."
        help_label = QLabel(help_text)
        help_label.setWordWrap(True)
        layout.addWidget(help_label)
        self.timer = QTimer(self)
        self.timer.setInterval(140)
        self.timer.timeout.connect(lambda: self.picker.setCurrentIndex((self.picker.currentIndex() + 1) % len(self.sprites)))
        self.canvas.picked.connect(self.pick_grip)
        self.update_frame()

    def update_frame(self, *_args):
        index = self.picker.currentIndex()
        self.canvas.sprite = self.sprites[index]
        self.canvas.grip = self.points[index] if self.points is not None else None
        self.canvas.update()

    def toggle_play(self):
        if self.timer.isActive():
            self.timer.stop()
            self.play_button.setText("재생")
        else:
            self.timer.start()
            self.play_button.setText("정지")

    def pick_grip(self, x, y):
        self.timer.stop()
        self.play_button.setText("재생")
        index = self.picker.currentIndex()
        self.points[index] = {"x": x, "y": y}
        self.grip_changed.emit(index, x, y)
        self.update_frame()

    def done(self, result):
        self.timer.stop()
        super().done(result)


class CharacterCreator(QDialog):
    created = Signal(object, object)

    def __init__(self, library: CharacterLibrary, template: str, parent=None):
        super().__init__(parent)
        self.library, self.template = library, template
        self.files: dict[str, Path] = {}
        self.selected_frames = {}
        self.grips = default_grips(template)
        self.sample_labels = {}
        self.upload_labels = {}
        self.filename_labels = {}
        self.preview_buttons = {}
        self.preview_dialog = None
        self.setWindowTitle("캐릭터 생성")
        self.resize(1000, 760)
        self.setMinimumSize(880, 600)
        self.setWindowModality(Qt.WindowModality.WindowModal)
        self.setAttribute(Qt.WidgetAttribute.WA_DeleteOnClose)
        layout = QVBoxLayout(self)
        heading = QLabel("내 이미지로 만드는 바탕화면 친구")
        heading.setStyleSheet("font-size: 22px; font-weight: 600")
        layout.addWidget(heading)
        guide = QLabel("① 예시처럼 동작별 PNG 준비 → ② 이미지 선택 · 미리보기 → ③ 이름을 정하고 저장\n"
                       "투명 배경으로 몸 전체를 각 칸 안에 그려 주세요. 8프레임은 4칸 × 2줄, 윗줄 왼쪽부터 재생합니다. 예: 2048 × 1024 시트. 필수 8종이며 왼쪽 걷기는 선택입니다.")
        guide.setWordWrap(True)
        layout.addWidget(guide)
        row = QHBoxLayout()
        row.addWidget(QLabel("이름"))
        self.name_field = QLineEdit(library.suggested_name())
        self.name_field.setPlaceholderText("캐릭터 이름 (1~40자)")
        self.name_field.textChanged.connect(self.update_status)
        row.addWidget(self.name_field, 1)
        suggest = QPushButton("이름 추천")
        suggest.clicked.connect(lambda: self.name_field.setText(library.suggested_name()))
        row.addWidget(suggest)
        self.template_picker = QComboBox()
        self.template_picker.addItems(["강아지 예시", "보노보노 예시"])
        self.template_picker.setCurrentIndex(1 if template == "bonobono" else 0)
        self.template_picker.currentIndexChanged.connect(self.change_template)
        row.addWidget(self.template_picker)
        export = QPushButton("예시 세트 저장…")
        export.clicked.connect(self.export_examples)
        row.addWidget(export)
        layout.addLayout(row)
        jump_row = QHBoxLayout()
        jump_row.addWidget(QLabel("점프 시트 순서"))
        self.layout_picker = QComboBox()
        self.layout_picker.addItems(["두 동작: 윗줄 위로 점프 4장 / 아랫줄 하강 4장", "한 동작: 준비 → 발구르기 → 상승 → 정점 → 하강 → 착지 직전 → 착지 → 회복"])
        self.layout_picker.setCurrentIndex(1 if template == "bonobono" else 0)
        jump_row.addWidget(self.layout_picker, 1)
        layout.addLayout(jump_row)
        self.scroll = QScrollArea()
        self.scroll.setWidgetResizable(True)
        content = QWidget()
        cards = QVBoxLayout(content)
        for slot in SLOTS:
            group = QGroupBox(slot.title)
            grid = QHBoxLayout(group)
            sample = QVBoxLayout()
            sample.addWidget(QLabel("예시"))
            sample_image = self.thumbnail()
            self.sample_labels[slot.key] = sample_image
            sample.addWidget(sample_image)
            grid.addLayout(sample)
            uploaded = QVBoxLayout()
            filename = QLabel("아직 선택하지 않았습니다 · 필수" if slot.required else "없으면 자동 좌우 반전")
            filename.setFixedWidth(192)
            filename.setWordWrap(True)
            filename.setTextFormat(Qt.TextFormat.PlainText)
            self.filename_labels[slot.key] = filename
            uploaded.addWidget(filename)
            uploaded_image = self.thumbnail()
            self.upload_labels[slot.key] = uploaded_image
            uploaded.addWidget(uploaded_image)
            grid.addLayout(uploaded)
            controls = QVBoxLayout()
            description = QLabel(slot.guide)
            description.setWordWrap(True)
            controls.addWidget(description)
            choose = QPushButton("이미지 선택…")
            choose.clicked.connect(lambda _checked=False, s=slot: self.choose_file(s))
            controls.addWidget(choose)
            preview = QPushButton("미리보기 · 재생")
            preview.setEnabled(False)
            preview.clicked.connect(lambda _checked=False, s=slot: self.preview_slot(s))
            self.preview_buttons[slot.key] = preview
            controls.addWidget(preview)
            example = QPushButton("예시 크게 보기")
            example.clicked.connect(lambda _checked=False, s=slot: self.show_example(s))
            controls.addWidget(example)
            grid.addLayout(controls, 1)
            cards.addWidget(group)
        extra_title = QLabel("커서가 그려진 원본도 참고하세요 (참고용 2장)\n실제 등록에는 위의 ‘커서 없는’ 점프·구르기 이미지를 사용하세요.")
        extra_title.setWordWrap(True)
        cards.addWidget(extra_title)
        extra = QHBoxLayout()
        for filename in ("08-cursor-jump.png", "10-cursor-roll.png"):
            col = QVBoxLayout()
            col.addWidget(QLabel(filename))
            view = self.thumbnail()
            self.set_thumbnail(view, image_directory() / "bonobono-sprites" / filename)
            col.addWidget(view)
            extra.addLayout(col)
        extra.addStretch()
        cards.addLayout(extra)
        self.scroll.setWidget(content)
        layout.addWidget(self.scroll, 1)
        self.status = QLabel()
        self.status.setWordWrap(True)
        layout.addWidget(self.status)
        footer = QHBoxLayout()
        footer.addStretch()
        cancel = QPushButton("취소")
        cancel.clicked.connect(self.reject)
        footer.addWidget(cancel)
        self.save_button = QPushButton("저장하고 사용")
        self.save_button.setDefault(True)
        self.save_button.clicked.connect(self.save_character)
        footer.addWidget(self.save_button)
        layout.addLayout(footer)
        self.update_examples()
        self.update_status()

    @staticmethod
    def thumbnail():
        label = QLabel()
        label.setFixedSize(192, 100)
        label.setAlignment(Qt.AlignmentFlag.AlignCenter)
        label.setStyleSheet("background: #202630; border-radius: 6px")
        return label

    @staticmethod
    def set_thumbnail(label, path):
        image = QImage(str(path))
        label.setPixmap(QPixmap.fromImage(image).scaled(192, 100, Qt.AspectRatioMode.KeepAspectRatio, Qt.TransformationMode.FastTransformation))

    def update_examples(self):
        for slot in SLOTS:
            self.set_thumbnail(self.sample_labels[slot.key], example_path(image_directory(), self.template, slot.key))

    def update_status(self, *_args):
        if not hasattr(self, "status"):
            return
        count = sum(slot.required and slot.key in self.files for slot in SLOTS)
        self.status.setText(f"필수 이미지 {count}/8 · 저장하면 이미지를 앱 보관함에 복사하고 새 캐릭터 한 마리를 추가합니다. 원본 파일은 수정하지 않습니다.")
        self.status.setStyleSheet("")
        self.save_button.setEnabled(count == 8 and 1 <= len(self.name_field.text().strip()) <= 40)

    def change_template(self, index):
        self.template = "puppy" if index == 0 else "bonobono"
        self.grips = default_grips(self.template)
        self.layout_picker.setCurrentIndex(index)
        if self.preview_dialog:
            self.preview_dialog.close()
        self.update_examples()

    def choose_file(self, slot):
        filename, _ = QFileDialog.getOpenFileName(self, f"{slot.title} · {slot.guide}", "", "PNG 이미지 (*.png)")
        if filename:
            try:
                self.assign(Path(filename), slot)
            except Exception as error:
                self.show_error(error)

    def export_examples(self):
        parent = QFileDialog.getExistingDirectory(self, "예시 PNG와 만드는 방법을 새 폴더로 저장할 위치")
        if parent:
            try:
                folder = self.library.export_examples(self.template, image_directory(), Path(parent))
                QDesktopServices.openUrl(QUrl.fromLocalFile(str(folder)))
            except Exception as error:
                self.show_error(error)

    def assign(self, path: Path, slot: Slot):
        sprites = validate_png(path, slot)
        self.files[slot.key] = path
        self.selected_frames[slot.key] = sprites
        self.set_thumbnail(self.upload_labels[slot.key], path)
        self.filename_labels[slot.key].setText(path.name)
        self.preview_buttons[slot.key].setEnabled(True)
        self.update_status()

    def _show_preview(self, viewer):
        if self.preview_dialog:
            self.preview_dialog.close()
            self.preview_dialog.deleteLater()
        self.preview_dialog = viewer
        viewer.show()
        viewer.raise_()
        viewer.activateWindow()

    def preview_slot(self, slot):
        if slot.key not in self.selected_frames:
            return
        key = "jump" if slot.key == "cursor_jump" else "roll" if slot.key == "cursor_roll" else None
        viewer = AnimationPreview(slot.title, self.selected_frames[slot.key], self.grips[key] if key else None, self)
        if key:
            viewer.grip_changed.connect(lambda i, x, y: self.grips[key].__setitem__(i, {"x": x, "y": y}))
        self._show_preview(viewer)

    def show_example(self, slot):
        image = QImage(str(example_path(image_directory(), self.template, slot.key)))
        sprite = Sprite(image, image.width(), image.height(), image.width() / 2, image.height())
        self._show_preview(AnimationPreview(f"예시 · {slot.title}", [sprite], parent=self))

    def save_character(self):
        try:
            profile, atlas = self.library.create(self.name_field.text(), self.template,
                    "split" if self.layout_picker.currentIndex() == 0 else "continuous", self.files, self.grips)
            self.created.emit(profile, atlas)
            self.accept()
        except Exception as error:
            self.show_error(error)

    def show_error(self, error):
        self.status.setText(str(error))
        self.status.setStyleSheet("color: #d04444")

    def done(self, result):
        if self.preview_dialog:
            self.preview_dialog.close()
        super().done(result)
