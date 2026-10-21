"""Qt connection editor and cancellable background jobs; no live API on startup."""
from __future__ import annotations

import threading
import time
import uuid

from PySide6.QtCore import QObject, QRunnable, QThreadPool, Qt, Signal, QUrl
from PySide6.QtGui import QDesktopServices
from PySide6.QtWidgets import QComboBox, QDialog, QFormLayout, QHBoxLayout, QLabel, QLineEdit, QPushButton, QVBoxLayout

from .ai_motion import Connection, PROVIDERS, KEY_PAGES, catalog, clean_key, verify


class JobSignals(QObject):
    finished = Signal(object, object)
    progress = Signal(str)
    generated = Signal(object, object)


class AIJob(QRunnable):
    def __init__(self, operation):
        super().__init__()
        self.operation = operation
        self.signals = JobSignals()
        self.cancel = threading.Event()

    def run(self):
        result = error = None
        try:
            result = self.operation(self)
        except Exception as value:
            error = value
        self.signals.finished.emit(result, error)

    def start(self):
        QThreadPool.globalInstance().start(self)


class APIConnectionsDialog(QDialog):
    changed = Signal()

    def __init__(self, store, parent=None):
        super().__init__(parent)
        self.store = store
        self.job = None
        self.verified_at = None
        self.closed = False
        self.setWindowTitle("개인 API 추가 · 검증")
        self.resize(700, 440)
        layout = QVBoxLayout(self)
        form = QFormLayout()
        self.accounts = QComboBox()
        self.providers = QComboBox()
        for key, title in PROVIDERS.items(): self.providers.addItem(title, key)
        self.name_field, self.model_field, self.key_field = QLineEdit(), QLineEdit(), QLineEdit()
        self.name_field.setMaxLength(40)
        self.key_field.setEchoMode(QLineEdit.EchoMode.Password)
        for title, field in (("저장한 API", self.accounts), ("서비스", self.providers), ("이름", self.name_field),
                             ("모델 ID", self.model_field), ("API 키", self.key_field)):
            form.addRow(title, field)
        layout.addLayout(form)
        help_label = QLabel("API 키는 Windows 자격 증명 관리자에 저장합니다. 웹 구독과 API 요금은 별도일 수 있습니다.\n"
                            "검증은 모델 조회만 하며 이미지 생성 요청은 보내지 않습니다. 생성 권한·잔액·품질은 실제 생성 시 확인합니다.\n"
                            "Claude는 설명 보조용입니다. 실제 시트에는 OpenAI 또는 Gemini 이미지 API가 필요합니다.")
        help_label.setWordWrap(True); layout.addWidget(help_label)
        row = QHBoxLayout()
        self.add_button, self.update_button = QPushButton("추가"), QPushButton("변경 저장")
        self.verify_button, self.delete_button = QPushButton("검증"), QPushButton("삭제")
        for button, callback in ((self.add_button, lambda: self.save(True)), (self.update_button, lambda: self.save(False)),
                                 (self.verify_button, self.verify), (self.delete_button, self.remove)):
            button.clicked.connect(callback); row.addWidget(button)
        layout.addLayout(row)
        key_page = QPushButton("API 키 발급 페이지")
        key_page.clicked.connect(lambda: QDesktopServices.openUrl(QUrl(KEY_PAGES[self.providers.currentData()])))
        row.addWidget(key_page)
        self.status = QLabel(); self.status.setWordWrap(True); self.status.setTextFormat(Qt.TextFormat.PlainText)
        layout.addWidget(self.status)
        self.accounts.currentIndexChanged.connect(self.select_account)
        self.providers.currentIndexChanged.connect(self.change_provider)
        for field in (self.name_field, self.model_field, self.key_field): field.textEdited.connect(self.invalidate)
        self.reload(); self.select_account()

    def selected(self):
        id = self.accounts.currentData()
        return next((c for c in self.store.connections if c.id == id), None)

    def reload(self, id=None):
        self.accounts.blockSignals(True)
        self.accounts.clear(); self.accounts.addItem("새 API 추가", None)
        for c in self.store.connections:
            self.accounts.addItem(("✓ " if c.verified_at else "미검증 · ") + c.name, c.id)
        index = self.accounts.findData(id)
        self.accounts.setCurrentIndex(max(0, index)); self.accounts.blockSignals(False)

    def select_account(self, *_):
        current = self.selected()
        self.verified_at = current.verified_at if current else None
        self.key_field.clear()
        self.providers.blockSignals(True)
        self.providers.setCurrentIndex(self.providers.findData(current.provider if current else "openai"))
        self.providers.blockSignals(False)
        if current:
            self.name_field.setText(current.name); self.model_field.setText(current.model)
            self.key_field.setPlaceholderText("키 유지 · 변경할 때만 새 키 입력")
        else:
            self.change_provider(); self.key_field.setPlaceholderText("개인 API 키")
        self.set_busy(False)
        self.status.setText("검증 후 추가 또는 변경 저장을 누르세요.")

    def change_provider(self, *_):
        provider = self.providers.currentData()
        self.name_field.setText(PROVIDERS[provider])
        self.model_field.setText(catalog()["defaults"][provider])
        self.invalidate()

    def invalidate(self, *_):
        self.verified_at = None
        self.status.setText("설정이 바뀌었습니다. 다시 검증하세요.")

    def values(self, fresh=False):
        current = self.selected()
        connection = Connection(str(uuid.uuid4()) if fresh or not current else current.id, self.providers.currentData(),
                                self.name_field.text().strip(), self.model_field.text().strip(), self.verified_at)
        connection.validate()
        key = clean_key(self.key_field.text()) if self.key_field.text() else self.store.vault.get(current.id) if current else clean_key("")
        return connection, key

    def set_busy(self, busy):
        for field in (self.accounts, self.providers, self.name_field, self.model_field, self.key_field, self.add_button, self.verify_button):
            field.setEnabled(not busy)
        self.update_button.setEnabled(not busy and self.selected() is not None)
        self.delete_button.setEnabled(not busy and self.selected() is not None)

    def verify(self):
        try:
            connection, key = self.values()
            self.set_busy(True); self.status.setText("모델 조회로 API 연결을 확인하는 중…")
            self.job = AIJob(lambda _job: verify(connection, key, cancel=_job.cancel))
            self.job.signals.finished.connect(self.verified, Qt.ConnectionType.QueuedConnection)
            self.job.start()
        except Exception as error:
            self.show_error(error)

    def verified(self, result, error):
        self.job = None
        if self.closed: return
        self.set_busy(False)
        if error:
            self.verified_at = None; self.show_error(error)
        else:
            self.verified_at = time.time()
            self.status.setStyleSheet("")
            self.status.setText("연결·모델 조회 성공. 추가 또는 변경 저장을 누르세요. " + result)

    def save(self, fresh):
        try:
            connection, key = self.values(fresh)
            self.store.save(connection, key)
            self.changed.emit(); self.reload(connection.id); self.select_account()
            self.status.setText("검증한 API를 저장했습니다." if connection.verified_at else "저장했습니다. 사용 전에 검증하고 변경 저장을 누르세요.")
        except Exception as error: self.show_error(error)

    def remove(self):
        current = self.selected()
        if current:
            try:
                self.store.delete(current); self.changed.emit(); self.reload(); self.select_account()
                self.status.setText("API 설정과 키를 삭제했습니다.")
            except Exception as error: self.show_error(error)

    def show_error(self, error):
        self.status.setStyleSheet("color: #d04444"); self.status.setText(str(error))

    def done(self, result):
        self.closed = True
        if self.job: self.job.cancel.set()
        self.key_field.clear()
        super().done(result)
