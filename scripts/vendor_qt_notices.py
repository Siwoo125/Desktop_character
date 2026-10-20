"""Refresh Qt 6.10.2 license texts and third-party attributions from upstream.

Run manually before committing a dependency update; normal builds use the
checked-in notices and do not fetch the network. No upstream code is executed.
"""
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
from pathlib import Path, PurePosixPath
import shutil
import tarfile
from urllib.request import urlopen

ROOT = Path(__file__).resolve().parents[1]
VERSION = "6.10.2"
SOURCES = {
    name: f"https://download.qt.io/archive/qt/6.10/{VERSION}/submodules/{name}-everywhere-src-{VERSION}.tar.xz"
    for name in ("qtbase", "qtsvg", "qtimageformats")
}
SOURCES["pyside-setup"] = f"https://download.qt.io/official_releases/QtForPython/pyside6/PySide6-{VERSION}-src/pyside-setup-everywhere-src-{VERSION}.tar.xz"


def collect(item):
    name, url = item
    cache = ROOT / ".build" / "upstream-sources" / url.rsplit("/", 1)[-1]
    cache.parent.mkdir(parents=True, exist_ok=True)
    if not cache.exists():
        with urlopen(url, timeout=120) as response, cache.open("wb") as output:
            while block := response.read(1024 * 1024):
                output.write(block)
    target = ROOT / "licenses" / f"Qt-{VERSION}" / name
    if target.exists():
        shutil.rmtree(target)
    count = 0
    with tarfile.open(cache, "r:xz") as archive:
        for member in archive:
            parts = PurePosixPath(member.name).parts[1:]
            if not member.isfile() or not parts or ".." in parts:
                continue
            lower = parts[-1].lower()
            legal = ("LICENSES" in parts or lower.startswith(
                     ("license", "licence", "copying", "copyright", "notice")) or lower == "qt_attribution.json")
            # Notices from the source modules and their bundled dependencies;
            # omit build tooling/test fixtures that happen to mention licenses.
            if (not legal or lower == "licenserule.json" or PurePosixPath(lower).suffix in
                (".png", ".py", ".yaml", ".cmake", ".cpp", ".h") or
                any(p in ("tests", "examples", ".git") for p in parts)):
                continue
            path = target.joinpath(*parts)
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(archive.extractfile(member).read())
            count += 1
    print(f"{name}: {count} notice files", flush=True)
    with cache.open("rb") as source:
        digest = hashlib.file_digest(source, "sha256").hexdigest()
    return name, {"url": url, "sha256": digest, "notice_files": count}


if __name__ == "__main__":
    with ThreadPoolExecutor(max_workers=4) as executor:
        records = dict(executor.map(collect, SOURCES.items()))
    path = ROOT / "licenses" / f"Qt-{VERSION}" / "UPSTREAM-SOURCES.json"
    path.write_text(json.dumps(records, indent=2) + "\n")
