"""Source and PyInstaller entry point. Keep setup-independent checks runnable anywhere."""
from __future__ import annotations

import argparse
from logging.handlers import RotatingFileHandler
import logging
import os
from pathlib import Path
import sys
import tempfile
import traceback


def qt_application():
    import PySide6
    from PySide6.QtCore import QCoreApplication, Qt
    from PySide6.QtGui import QGuiApplication
    from PySide6.QtWidgets import QApplication
    # PySide's generated qt.conf can parse commas in an installation path as a
    # list separator. Explicit plugin paths also support Korean/space/comma paths.
    package = Path(PySide6.__file__).resolve().parent
    paths = [str(path) for path in (package / "Qt" / "plugins", package / "plugins") if path.is_dir()]
    if paths:
        QCoreApplication.setLibraryPaths(paths)
    QGuiApplication.setHighDpiScaleFactorRoundingPolicy(Qt.HighDpiScaleFactorRoundingPolicy.PassThrough)
    return QApplication([sys.argv[0]])


def main() -> int:
    parser = argparse.ArgumentParser(description="Windows desktop companions: 강아지 / 보노보노")
    parser.add_argument("--self-test", action="store_true", help="Run portable physics/input/cursor checks")
    parser.add_argument("--validate-assets", action="store_true", help="Validate both original sprite sets")
    parser.add_argument("--widget-check", action="store_true", help="Test Qt widget with a fake native backend")
    parser.add_argument("--preview-dir", type=Path, help="Write character pose previews")
    parser.add_argument("--diagnose", action="store_true", help="Print Windows/DPI/visible ledge diagnostics")
    parser.add_argument("--character", choices=("puppy", "bonobono"))
    parser.add_argument("--check-report", type=Path, help="Write diagnostics/check output to this file")
    args = parser.parse_args()

    checking = args.self_test or args.validate_assets or args.widget_check or args.preview_dir
    if checking or args.diagnose:
        # A windowed PyInstaller EXE has no stdout/stderr. Keep unittest and
        # diagnostics usable without a console and without a blocking dialog.
        if args.check_report or sys.stdout is None or sys.stderr is None:
            report = args.check_report or Path(tempfile.gettempdir()) / "DesktopCharacter-checks.log"
            report.parent.mkdir(parents=True, exist_ok=True)
            sys.stdout = sys.stderr = report.open("w", encoding="utf-8", buffering=1)
    if args.self_test:
        from desktop_pet.checks import run
        if not run():
            return 1
    if checking:
        if args.validate_assets or args.widget_check or args.preview_dir:
            # No real desktop windows are shown or manipulated by validation.
            os.environ["QT_QPA_PLATFORM"] = "offscreen"
            from desktop_pet.validation import validate_assets, validate_widget
            app = qt_application()
            if args.validate_assets or args.preview_dir:
                validate_assets(args.preview_dir)
            if args.widget_check:
                validate_widget(args.preview_dir)
        return 0

    if sys.platform != "win32":
        print("이 실행부는 Windows 전용입니다. macOS에서는 실행.command를 사용하세요.", file=sys.stderr)
        return 2

    from PySide6.QtCore import QLockFile
    from PySide6.QtWidgets import QApplication, QMessageBox
    from desktop_pet import __version__
    from desktop_pet.app import PetWindow
    from desktop_pet.collection import PetCollection
    from desktop_pet.physics import window_ledges
    from desktop_pet.settings import Settings, state_directory
    from desktop_pet.win32 import Win32

    app = qt_application()
    app.setApplicationName("DesktopFriends")
    app.setApplicationVersion(__version__)
    app.setQuitOnLastWindowClosed(False)
    directory = state_directory()
    directory.mkdir(parents=True, exist_ok=True)
    log_path = directory / "desktop-pet.log"
    handler = RotatingFileHandler(log_path, maxBytes=1_000_000, backupCount=2, encoding="utf-8")
    logging.basicConfig(level=logging.INFO, handlers=[handler], format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    lock = QLockFile(str(directory / "desktop-pet.lock"))
    lock.setStaleLockTime(30_000)
    if not args.diagnose and not lock.tryLock(100):
        QMessageBox.information(None, "바탕화면 친구", "이미 실행 중입니다. 작업 표시줄의 숨겨진 아이콘(∧)에서 캐릭터 메뉴를 열어 주세요.")
        return 0
    window = collection = None
    try:
        settings = Settings()
        if args.character:
            settings.character = args.character
            settings.instances = None
        native = Win32()
        if args.diagnose:
            window = PetWindow(native, settings, timers=False, persist=False)
            windows = native.windows(window.space)
            ledges = window_ledges(windows, window.engine.physics.area)
            print(f"DesktopFriends {__version__} / Python {sys.version.split()[0]}")
            for monitor in native.monitors():
                print(f"Monitor: {monitor.name}, bounds={monitor.bounds}, work={monitor.work}")
            print(f"Qt screen: {window.current_screen.name()}, DPI ratio={window.space.ratio}")
            print(f"Visible application windows={len(windows)}, exposed ledges={len(ledges)}")
            print(f"Log: {log_path}")
            window.shutdown()
            return 0

        collection = PetCollection(native, settings)
        collection.restore()

        def exception_hook(kind, value, traceback):
            logging.critical("Unhandled UI exception", exc_info=(kind, value, traceback))
            try:
                for pet in collection.windows:
                    pet.engine.stop(__import__("time").monotonic())
                    pet.engine.paused = True
                    pet._sync_menu()
            except Exception:
                logging.exception("Stopping after UI exception")
            QMessageBox.critical(None, "바탕화면 친구", f"동작 중 오류가 발생해 일시정지했습니다.\n로그: {log_path}")

        sys.excepthook = exception_hook
        return app.exec()
    except Exception as error:
        logging.exception("Startup failure")
        if window:
            window.shutdown()
        if collection:
            collection.shutdown()
        if args.diagnose:
            print(f"Diagnostic failed: {error}\nLog: {log_path}", file=sys.stderr)
        else:
            QMessageBox.critical(None, "바탕화면 친구를 실행하지 못했습니다", f"{error}\n\n로그: {log_path}")
        return 1
    finally:
        lock.unlock()


if __name__ == "__main__":
    try:
        result = main()
    except Exception:
        if any(flag in sys.argv for flag in ("--self-test", "--validate-assets", "--widget-check", "--diagnose", "--preview-dir")):
            traceback.print_exc()
            result = 1
        else:
            raise
    raise SystemExit(result)
