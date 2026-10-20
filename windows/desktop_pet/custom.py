"""User-created character manifests, shared with the native macOS format."""
from __future__ import annotations

from dataclasses import dataclass
import json
from pathlib import Path
import random
import shutil
import unicodedata
import uuid

from .settings import state_directory


@dataclass(frozen=True)
class Slot:
    key: str
    title: str
    columns: int = 4
    rows: int = 2
    required: bool = True

    @property
    def filename(self) -> str:
        return self.key + ".png"

    @property
    def guide(self) -> str:
        if self.key == "standing":
            return "투명 배경 PNG 1장 · 몸 전체가 보이게"
        if self.key == "gaze":
            return "가로 3칸 · 왼쪽 위 → 정면 위 → 오른쪽 위"
        if self.key == "walk_left":
            return "4칸 × 2줄 · 없으면 오른쪽 걷기를 자동 좌우 반전"
        if self.key == "leap":
            return "4칸 × 2줄 · 위의 점프 순서 설정에 맞추세요"
        if self.key.startswith("cursor_"):
            return "4칸 × 2줄 · 커서 없이 그리기 · 미리보기에서 손 위치 조절 가능"
        return "4칸 × 2줄 · 윗줄 왼쪽부터, 다음 아랫줄 왼쪽부터"


SLOTS = (Slot("standing", "기본 정지 자세", 1, 1), Slot("gaze", "커서 바라보기", 3, 1),
         Slot("run", "오른쪽 달리기"), Slot("walk", "오른쪽 걷기"), Slot("walk_left", "왼쪽 걷기 (선택)", required=False),
         Slot("idle", "대기 · 눈 깜빡이기"), Slot("leap", "점프 · 하강"),
         Slot("cursor_jump", "커서 잡기 점프"), Slot("cursor_roll", "커서를 잡고 구르기"))


def default_grips(template: str) -> dict[str, list[dict[str, float]]]:
    if template == "bonobono":
        jump = ((0, 0),) * 4 + ((.84, .64), (.79, .39), (.76, .25), (.72, .33))
        roll = ((.72, .15), (.75, .17), (.59, .40), (.34, .40), (.34, .47), (.37, .25), (.31, .16), (.23, .16))
    else:
        jump = ((0, 0),) * 4 + ((.80, .49), (.80, .40), (.79, .23), (.74, .37))
        roll = ((.80, .23), (.61, .20), (.67, .51), (.50, .39), (.42, .48), (.56, .28), (.76, .23), (.76, .25))
    return {"jump": [{"x": x, "y": y} for x, y in jump], "roll": [{"x": x, "y": y} for x, y in roll]}


def example_path(root: Path, template: str, key: str) -> Path:
    from .assets import resolve_asset
    if template == "bonobono":
        folder = root / "bonobono-sprites"
        names = dict(zip((s.key for s in SLOTS), ("01-standing.png", "02-look-up.png", "03-run-right.png", "04-walk-right.png",
                    "05-walk-left.png", "06-idle.png", "07-leap.png", "09-jump-no-cursor.png", "11-roll-no-cursor.png")))
    else:
        folder = root
        names = dict(zip((s.key for s in SLOTS), ("정지상태.png", "세 방향으로 올려보는 픽셀 강아지.png", "오른쪽 뛰는 상태.png",
                    "오른쪽으로 걷는 상태.png", "오른쪽으로 걷는 상태.png", "유휴상태.png", "픽셀 강아지의 힘찬 도약 스프라이트 시트.png",
                    "puppy-jump-8frames-no-cursor.png", "puppy-roll-8frames-no-cursor.png")))
    return resolve_asset(folder, names[key])


@dataclass
class CustomProfile:
    id: str
    name: str
    template: str
    leap_layout: str
    assets: dict[str, str]
    grips: dict[str, list[dict[str, float]]]
    directory: Path
    version: int = 1

    def validate(self) -> None:
        try:
            valid_id = self.id.startswith("custom-") and str(uuid.UUID(self.id[7:])) == self.id[7:].lower()
        except (ValueError, TypeError, AttributeError):
            valid_id = False
        if not valid_id or self.version != 1 or not isinstance(self.name, str) or not self.name.strip() or len(self.name) > 40:
            raise ValueError("캐릭터 이름이나 저장 형식이 올바르지 않습니다.")
        if self.template not in ("puppy", "bonobono") or self.leap_layout not in ("split", "continuous"):
            raise ValueError("예시 종류나 점프 시트 순서를 확인해 주세요.")
        if not isinstance(self.assets, dict) or not isinstance(self.grips, dict):
            raise ValueError("캐릭터 이미지 정보가 올바르지 않습니다.")
        for slot in SLOTS:
            if slot.required or slot.key in self.assets:
                if self.assets.get(slot.key) != slot.filename:
                    raise ValueError(f"{slot.title} 이미지가 필요합니다.")
        for key in ("jump", "roll"):
            points = self.grips.get(key)
            if not isinstance(points, list) or len(points) != 8:
                raise ValueError("각 동작의 손 위치 8개가 필요합니다.")
            for point in points:
                if not isinstance(point, dict) or any(not isinstance(point.get(k), (int, float)) or not 0 <= point[k] <= 1 for k in ("x", "y")):
                    raise ValueError("커서 손 위치는 이미지 안에 있어야 합니다.")

    def manifest(self) -> dict:
        return {"version": self.version, "id": self.id, "name": self.name, "template": self.template,
                "leap_layout": self.leap_layout, "assets": self.assets, "grips": self.grips}


def validate_png(path: Path, slot: Slot):
    from PIL import Image
    from .assets import frames
    with Image.open(path) as image:
        w, h = image.size
        if image.format != "PNG":
            raise ValueError("PNG 파일을 선택해 주세요.")
        if w < slot.columns * 8 or h < slot.rows * 8 or w > 8192 or h > 8192 or w * h > 16_777_216:
            raise ValueError("각 칸은 최소 8픽셀, 전체는 8192픽셀·1600만 화소 이하 PNG를 사용해 주세요.")
        if image.convert("RGBA").getchannel("A").getextrema()[0] >= 24:
            raise ValueError("배경을 투명하게 만든 PNG를 선택해 주세요.")
    return frames(path, slot.columns, slot.rows, whole=slot.key not in ("standing", "gaze", "idle"), feet=slot.key in ("standing", "gaze", "idle"))


class CharacterLibrary:
    def __init__(self, root: Path | None = None):
        self.root = root or state_directory() / "characters"

    def delete(self, id: str) -> None:
        if id in ("puppy", "bonobono") or id not in {p.id for p in self.all()}:
            raise ValueError("직접 만든 캐릭터만 삭제할 수 있습니다. 강아지와 보노보노는 삭제할 수 없습니다.")
        trash = self.root / ".trash"
        trash.mkdir(exist_ok=True)
        (self.root / id).rename(trash / (id + "-" + uuid.uuid4().hex))

    @staticmethod
    def export_examples(template: str, images_root: Path, parent: Path) -> Path:
        folder = parent / f"캐릭터예시-{template}-{uuid.uuid4().hex[:8]}"
        folder.mkdir()
        try:
            for slot in SLOTS:
                if template == "puppy" and slot.key == "walk_left":
                    continue
                shutil.copyfile(example_path(images_root, template, slot.key), folder / slot.filename)
            for name in ("08-cursor-jump.png", "10-cursor-roll.png"):
                shutil.copyfile(images_root / "bonobono-sprites" / name, folder / ("reference-" + name))
            leap = "윗줄 위로 점프, 아랫줄 하강. 각 줄 준비 → 공중 → 착지 직전 → 착지" if template == "puppy" else "준비 → 발구르기 → 상승 → 정점 → 하강 → 착지 직전 → 착지 → 회복"
            (folder / "만드는방법.txt").write_text(
                "캐릭터 만들기\n예시를 참고해 새 PNG를 준비한 뒤 앱 메뉴 → 캐릭터 생성 → 이미지 선택으로 등록하세요.\n"
                "배경은 투명하게, 몸 전체는 각 칸 안에 넣어 주세요. 모든 칸에 자세가 있어야 합니다.\n"
                "8프레임: 4칸 × 2줄, 윗줄 왼쪽 → 오른쪽, 아랫줄 왼쪽 → 오른쪽. 예: 2048 × 1024.\n"
                "standing.png: 정지 자세 1장 / gaze.png: 가로 3칸 (왼쪽 위, 정면 위, 오른쪽 위).\n"
                "walk_left.png는 선택이며 없으면 오른쪽 걷기를 좌우 반전합니다. 강아지 예시에는 전용 왼쪽 걷기 이미지가 없으므로 포함하지 않습니다. 나머지 8종은 필수입니다.\n"
                f"leap.png: {leap}. 앱의 점프 시트 순서도 맞춰 주세요.\n"
                "cursor_jump.png / cursor_roll.png에는 커서를 그리지 마세요. 미리보기에서 프레임을 고르고 손을 클릭해 접점을 맞추세요. 점프 5~8번, 구르기 전체에 적용됩니다.\n"
                "reference-*는 커서가 그려진 참고용 이미지이므로 실제 동작으로 등록하지 않습니다.\n"
                "이름을 직접 입력하거나 이름 추천을 누른 뒤 ‘저장하고 사용’을 누르면 새 캐릭터 한 마리를 띄웁니다.\n", encoding="utf-8")
            return folder
        except Exception:
            shutil.rmtree(folder, ignore_errors=True)
            raise

    def all(self) -> list[CustomProfile]:
        result = []
        if not self.root.is_dir():
            return result
        for folder in self.root.iterdir():
            if folder.name.startswith(".") or not folder.is_dir():
                continue
            try:
                data = json.loads((folder / "character.json").read_text(encoding="utf-8"))
                profile = CustomProfile(**data, directory=folder)
                profile.validate()
                if profile.id == folder.name:
                    result.append(profile)
            except (OSError, ValueError, TypeError, KeyError):
                continue
        return sorted(result, key=lambda p: p.name.casefold())

    def suggested_name(self) -> str:
        used = {profile.name.casefold() for profile in self.all()}
        randomizer = random.SystemRandom()
        for _ in range(100):
            name = randomizer.choice(("포근한", "느긋한", "반짝이는", "말랑한", "산뜻한", "씩씩한", "졸린", "장난꾸러기")) + " " + randomizer.choice(("모찌", "토리", "구름이", "별이", "콩이", "두리", "루루", "몽이"))
            if name.casefold() not in used:
                return name
        index = 1
        while f"나의 캐릭터 {index}" in used:
            index += 1
        return f"나의 캐릭터 {index}"

    def create(self, name: str, template: str, layout: str, files: dict[str, Path], grips: dict):
        from .assets import Atlas
        name = unicodedata.normalize("NFC", name.strip())
        if not name or len(name) > 40:
            raise ValueError("캐릭터 이름을 1~40자로 입력해 주세요.")
        if any(p.name.casefold() == name.casefold() for p in self.all()):
            raise ValueError("같은 이름의 캐릭터가 있습니다. 다른 이름을 입력해 주세요.")
        for slot in SLOTS:
            if slot.required and slot.key not in files:
                raise ValueError(f"{slot.title} 이미지를 먼저 선택해 주세요.")
        for slot in SLOTS:
            if slot.key in files:
                validate_png(files[slot.key], slot)
        id = "custom-" + str(uuid.uuid4())
        self.root.mkdir(parents=True, exist_ok=True)
        staging = self.root / (".pending-" + str(uuid.uuid4()))
        staging.mkdir()
        try:
            assets = {slot.key: slot.filename for slot in SLOTS if slot.key in files}
            profile = CustomProfile(id, name, template, layout, assets, grips, staging)
            profile.validate()
            for key, filename in assets.items():
                shutil.copyfile(files[key], staging / filename)
            atlas = Atlas(id, profile=profile)
            (staging / "character.json").write_text(json.dumps(profile.manifest(), ensure_ascii=False, indent=2, allow_nan=False), encoding="utf-8")
            destination = self.root / id
            staging.rename(destination)
            profile.directory = destination
            return profile, atlas
        except Exception:
            shutil.rmtree(staging, ignore_errors=True)
            raise
