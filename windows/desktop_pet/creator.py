from __future__ import annotations

import copy
import shutil
import tempfile
import uuid
from pathlib import Path

from PySide6.QtCore import QRectF, QTimer, Qt, QUrl, Signal
from PySide6.QtGui import QColor, QDesktopServices, QImage, QPainter, QPen, QPixmap
from PySide6.QtWidgets import (QComboBox, QDialog, QFileDialog, QGroupBox, QHBoxLayout,
                               QCheckBox, QLabel, QLineEdit, QPushButton, QScrollArea, QVBoxLayout, QWidget)

from .assets import Sprite, image_directory
from .custom import CharacterLibrary, SLOTS, Slot, default_grips, example_path, validate_png
from .ai_motion import ConnectionStore, generate, check_cancel
from .ai_ui import AIJob, APIConnectionsDialog


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
        self.ai_store = ConnectionStore(library.root.parent / "ai-connections.json")
        self.ai_job = None
        self.ai_closed = False
        self.ai_completed = 0
        self.ai_total = 0
        self.ai_folder = tempfile.TemporaryDirectory(prefix="DesktopCharacter-AI-")
        self.ai_buttons = {}
        self.choose_buttons = []
        self.ai_generate = generate
        self.setWindowTitle("캐릭터 생성")
        self.resize(1040, 840)
        self.setMinimumSize(940, 700)
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
        api_row = QHBoxLayout()
        api_row.addWidget(QLabel("이미지 API"))
        self.ai_picker = QComboBox(); api_row.addWidget(self.ai_picker, 1)
        self.api_manage = QPushButton("API 추가 · 검증…")
        self.api_manage.clicked.connect(self.open_api_settings); api_row.addWidget(self.api_manage)
        layout.addLayout(api_row)
        ai_row = QHBoxLayout()
        self.generate_all_button = QPushButton("전체 모션 만들기")
        self.generate_all_button.clicked.connect(self.generate_all); ai_row.addWidget(self.generate_all_button)
        self.overwrite_ai = QCheckBox("기존 모션도 다시 만들기"); ai_row.addWidget(self.overwrite_ai)
        self.cancel_ai_button = QPushButton("생성 중단"); self.cancel_ai_button.setEnabled(False)
        self.cancel_ai_button.clicked.connect(self.cancel_ai); ai_row.addWidget(self.cancel_ai_button)
        ai_row.addWidget(QLabel("Claude 보조 (선택)"))
        self.director_picker = QComboBox(); self.director_picker.setMaximumWidth(250); ai_row.addWidget(self.director_picker, 1)
        layout.addLayout(ai_row)
        self.ai_status = QLabel("정지 PNG만 선택한 뒤 API를 추가·검증하세요. 생성 시 정지 이미지 + 동작 예시를 해당 서비스에 전송하며 API 요금이 발생할 수 있습니다.")
        self.ai_status.setWordWrap(True); self.ai_status.setTextFormat(Qt.TextFormat.PlainText)
        layout.addWidget(self.ai_status)
        self.reload_ai()
        self.ai_picker.currentIndexChanged.connect(self.select_ai)
        self.director_picker.currentIndexChanged.connect(self.select_ai)
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
            self.choose_buttons.append(choose)
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
            make = QPushButton("이 정지 자세로 전체 만들기" if slot.key == "standing" else "이 모션만 다시 만들기")
            make.clicked.connect(lambda _checked=False, s=slot: self.generate_all() if s.key == "standing" else self.make_motions([s]))
            self.ai_buttons[slot.key] = make
            controls.addWidget(make)
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
        self.save_button.setEnabled(count == 8 and 1 <= len(self.name_field.text().strip()) <= 40 and self.ai_job is None)

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
        self.ai_closed = True
        if self.ai_job:
            self.ai_job.cancel.set()
            self.ai_job = None
        elif self.ai_folder:
            self.ai_folder.cleanup()
        self.ai_folder = None
        if self.preview_dialog:
            self.preview_dialog.close()
        super().done(result)

    def reload_ai(self):
        for picker in (self.ai_picker, self.director_picker): picker.blockSignals(True); picker.clear()
        self.ai_picker.addItem("이미지 생성 API 선택", None)
        self.director_picker.addItem("사용 안 함", None)
        for c in self.ai_store.connections:
            picker = self.ai_picker if c.image_capable else self.director_picker
            picker.addItem(("✓ " if c.verified_at else "미검증 · ") + c.name, c.id)
        ri = self.ai_picker.findData(self.ai_store.renderer_id)
        self.ai_picker.setCurrentIndex(ri if ri >= 1 else min(1, self.ai_picker.count()-1))
        self.director_picker.setCurrentIndex(max(0, self.director_picker.findData(self.ai_store.director_id)))
        for picker in (self.ai_picker, self.director_picker): picker.blockSignals(False)

    def select_ai(self, *_):
        self.ai_store.renderer_id, self.ai_store.director_id = self.ai_picker.currentData(), self.director_picker.currentData()
        try: self.ai_store.persist()
        except Exception as error: self.ai_status.setText(str(error))

    def open_api_settings(self):
        dialog = APIConnectionsDialog(self.ai_store, self)
        dialog.changed.connect(self.reload_ai)
        dialog.exec()
        dialog.deleteLater()

    def generate_all(self):
        self.make_motions([s for s in SLOTS if s.key != "standing" and (self.overwrite_ai.isChecked() or s.key not in self.files)])

    def set_ai_busy(self, busy):
        for widget in [self.generate_all_button, self.overwrite_ai, self.ai_picker, self.director_picker, self.api_manage,
                       self.template_picker, self.layout_picker, *self.choose_buttons, *self.ai_buttons.values()]:
            widget.setEnabled(not busy)
        self.cancel_ai_button.setEnabled(busy)
        self.update_status()

    def make_motions(self, slots):
        if self.ai_job is not None: return
        try:
            if not slots: raise ValueError("모든 모션이 있습니다. 개별 재생성 또는 ‘기존 모션도 다시 만들기’를 선택하세요.")
            if "standing" not in self.files: raise ValueError("기본 정지 자세 PNG를 먼저 선택하세요.")
            renderer = next((c for c in self.ai_store.connections if c.id == self.ai_picker.currentData()), None)
            if renderer is None or renderer.verified_at is None: raise ValueError("이미지 API를 추가·검증하고 선택하세요.")
            director = next((c for c in self.ai_store.connections if c.id == self.director_picker.currentData()), None)
            if director is not None and director.verified_at is None: raise ValueError("Claude 보조 API도 먼저 검증하세요.")
            key = self.ai_store.vault.get(renderer.id)
            director_key = self.ai_store.vault.get(director.id) if director else None
            temporary = self.ai_folder  # Worker retains temp files safely if the dialog closes.
            folder = Path(temporary.name)
            standing = folder / (uuid.uuid4().hex + "-standing.png")
            shutil.copyfile(self.files["standing"], standing)
            layout = "split" if self.layout_picker.currentIndex() == 0 else "continuous"
            template, operation = self.template, self.ai_generate
            self.ai_completed, self.ai_total = 0, len(slots)

            def run(job):
                for index, slot in enumerate(slots):
                    check_cancel(job.cancel)
                    job.signals.progress.emit(f"{index}/{len(slots)} · {slot.title} 생성 중… 정지 이미지 + 모션 예시 전송")
                    output = Path(temporary.name) / (uuid.uuid4().hex + "-" + slot.filename)
                    operation(renderer, key, slot, layout, standing, example_path(image_directory(), template, slot.key), output,
                              director=director, director_key=director_key, mirror_example=template == "puppy" and slot.key == "walk_left", cancel=job.cancel)
                    check_cancel(job.cancel)
                    job.signals.generated.emit(slot, output)

            job = AIJob(run)
            job.signals.progress.connect(self.ai_progress, Qt.ConnectionType.QueuedConnection)
            job.signals.generated.connect(self.ai_generated, Qt.ConnectionType.QueuedConnection)
            job.signals.finished.connect(self.ai_finished, Qt.ConnectionType.QueuedConnection)
            self.ai_job = job
            self.ai_status.setStyleSheet(""); self.set_ai_busy(True); job.start()
        except Exception as error:
            self.ai_status.setStyleSheet("color: #d04444"); self.ai_status.setText(str(error))

    def ai_progress(self, text):
        if not self.ai_closed: self.ai_status.setText(text)

    def ai_generated(self, slot, path):
        if self.ai_closed or not self.ai_job or self.ai_job.cancel.is_set(): return
        try:
            self.assign(path, slot)
            if slot.key == "cursor_jump": self.grips["jump"] = default_grips(self.template)["jump"]
            if slot.key == "cursor_roll": self.grips["roll"] = default_grips(self.template)["roll"]
            self.ai_completed += 1
        except Exception as error:
            self.ai_job.cancel.set(); self.ai_status.setText(str(error))

    def ai_finished(self, _result, error):
        cancelled = self.ai_job is not None and self.ai_job.cancel.is_set()
        self.ai_job = None
        if self.ai_closed: return
        self.set_ai_busy(False)
        if error or cancelled:
            self.ai_status.setStyleSheet("color: #d04444")
            self.ai_status.setText(f"{self.ai_completed}/{self.ai_total} 완료 · " +
                ("생성을 취소했습니다. 진행 중 요청은 과금될 수 있습니다." if cancelled else str(error)) + " 완료한 모션과 기존 이미지는 유지합니다.")
        else:
            self.ai_status.setText(f"{self.ai_completed}개 모션 생성 완료. 미리보기로 자세와 커서 손 위치를 확인한 뒤 저장하세요.")

    def cancel_ai(self):
        if self.ai_job:
            self.ai_job.cancel.set(); self.cancel_ai_button.setEnabled(False)
            self.ai_status.setText("취소 요청 중… 진행 중이던 요청은 과금될 수 있습니다. 완료한 모션은 유지합니다.")
