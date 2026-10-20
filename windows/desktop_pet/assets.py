"""Load the original PNGs for both characters without rewriting source assets."""
from __future__ import annotations

from collections import deque
from dataclasses import dataclass
from pathlib import Path
import sys
import unicodedata

from PIL import Image
from PySide6.QtCore import QRectF
from PySide6.QtGui import QImage

from .animation import Hop
from .physics import Point

CHARACTERS = {"puppy": "강아지", "bonobono": "보노보노"}


def image_directory() -> Path:
    if getattr(sys, "frozen", False):
        return Path(sys._MEIPASS) / "img"
    return Path(__file__).resolve().parents[2] / "img"


def resolve_asset(folder: Path, name: str) -> Path:
    candidate = folder / name
    if candidate.is_file():
        return candidate
    # APFS often stores Korean filenames as NFD; Windows does not normalize them.
    wanted = unicodedata.normalize("NFC", name)
    if folder.is_dir():
        for path in folder.iterdir():
            if unicodedata.normalize("NFC", path.name) == wanted and path.is_file():
                return path
    raise FileNotFoundError(f"이미지를 찾을 수 없습니다: {folder / name}")


@dataclass
class Sprite:
    image: QImage
    width: int
    height: int
    anchor_x: float
    reference: float

    def rect(self, canvas_width: float, canvas_height: float, height: float) -> QRectF:
        scale = height / self.reference
        # Qt draws downwards; bottom alignment is the same as the Swift app's +6 paws.
        return QRectF(canvas_width / 2 - self.anchor_x * scale, canvas_height - 6 - self.height * scale,
                      self.width * scale, self.height * scale)


def trimmed(image: Image.Image, *, whole: bool = False, feet: bool = False) -> Sprite:
    image = image.convert("RGBA")
    mask = image.getchannel("A").point(lambda value: 255 if value > 24 else 0)
    box = mask.getbbox()
    if box is None:
        raise ValueError("투명한 프레임에는 캐릭터가 없습니다.")
    image, mask = image.crop(box), mask.crop(box)
    width, height = image.size
    if whole:
        anchor = width / 2
    else:
        head = mask.crop((0, 0, width, max(1, int(height * 0.55)))).getbbox()
        anchor = (head[0] + head[2] - 1) / 2 if head else width / 2
    if feet:
        foot = mask.crop((0, int(height * 0.85), width, height)).getbbox()
        if foot:
            anchor = (foot[0] + foot[2] - 1) / 2
    data = image.tobytes()
    qt_image = QImage(data, width, height, width * 4, QImage.Format.Format_RGBA8888).copy()
    return Sprite(qt_image, width, height, anchor, float(height))


def frames(path: Path, columns: int = 4, rows: int = 2, *, whole: bool = False, feet: bool = False) -> list[Sprite]:
    with Image.open(path) as sheet:
        width, height = sheet.size
        return [trimmed(sheet.crop((c * width // columns, r * height // rows,
                                    (c + 1) * width // columns, (r + 1) * height // rows)), whole=whole, feet=feet)
                for r in range(rows) for c in range(columns)]


def subjects(path: Path) -> list[Sprite]:
    """Find eight silhouettes, including poses spilling across equal tile borders.

    Component discovery uses a small alpha mask. Crops are padded and trimmed again
    from full-resolution pixels; actual character pixels are never downsampled.
    """
    with Image.open(path) as source:
        sheet = source.convert("RGBA")
    factor = 4
    w, h = max(1, sheet.width // factor), max(1, sheet.height // factor)
    mask = sheet.getchannel("A").resize((w, h), Image.Resampling.NEAREST).point(lambda v: 255 if v > 24 else 0)
    pixels = bytearray(mask.tobytes())
    boxes: dict[int, tuple[int, int, int, int]] = {}
    for seed in range(len(pixels)):
        if pixels[seed] == 0:
            continue
        queue = deque([seed])
        pixels[seed] = 0
        left = right = seed % w
        top = bottom = seed // w
        count = 0
        while queue:
            current = queue.popleft()
            x, y = current % w, current // w
            left, right, top, bottom = min(left, x), max(right, x), min(top, y), max(bottom, y)
            count += 1
            for dy in (-1, 0, 1):
                for dx in (-1, 0, 1):
                    nx, ny = x + dx, y + dy
                    if 0 <= nx < w and 0 <= ny < h:
                        index = ny * w + nx
                        if pixels[index]:
                            pixels[index] = 0
                            queue.append(index)
        if count < max(32, w * h // 1000):
            continue
        column = min(3, int((left + right) * 2 / w))
        row = min(1, int((top + bottom) / h))
        slot = row * 4 + column
        # Work in exact source-space ratios: sheet dimensions need not be multiples of 4.
        pad = factor * 3
        box = (max(0, int(left * sheet.width / w) - pad), max(0, int(top * sheet.height / h) - pad),
               min(sheet.width, int((right + 1) * sheet.width / w) + pad), min(sheet.height, int((bottom + 1) * sheet.height / h) + pad))
        if slot in boxes:
            old = boxes[slot]
            box = min(old[0], box[0]), min(old[1], box[1]), max(old[2], box[2]), max(old[3], box[3])
        boxes[slot] = box
    if set(boxes) != set(range(8)):
        raise ValueError(f"{path.name}: 4열 × 2행에서 캐릭터 8개를 분리할 수 없습니다.")
    return [trimmed(sheet.crop(boxes[i]), whole=True) for i in range(8)]


def common_scale(sprites: list[Sprite]) -> list[Sprite]:
    reference = max(s.height for s in sprites)
    for sprite in sprites:
        sprite.reference = reference
    return sprites


class Atlas:
    def __init__(self, character: str, root: Path | None = None, *, profile=None):
        if profile is None and character not in CHARACTERS:
            raise ValueError(f"알 수 없는 캐릭터: {character}")
        self.character = character
        self.template = profile.template if profile else character
        self.display_name = profile.name if profile else CHARACTERS[character]
        self.custom_grips = profile.grips if profile else None
        root = root or image_directory()
        folder = root / "bonobono-sprites" if character == "bonobono" else root

        def path(name: str) -> Path:
            return resolve_asset(folder, name)

        self.left_walk: list[Sprite] | None = None
        self.leap: list[Sprite] = []
        if profile:
            from .custom import SLOTS
            profile.validate()
            def load(key):
                slot = next(s for s in SLOTS if s.key == key)
                return frames(profile.directory / profile.assets[key], slot.columns, slot.rows,
                              whole=key not in ("standing", "gaze", "idle"), feet=key in ("standing", "gaze", "idle"))
            self.rest = load("standing")[0]
            self.idle = common_scale(load("idle"))
            self.gaze = common_scale(load("gaze"))
            self.walk = common_scale(load("walk"))
            self.left_walk = common_scale(load("walk_left")) if "walk_left" in profile.assets else None
            self.run = common_scale(load("run"))
            leap = common_scale(load("leap"))
            if profile.leap_layout == "continuous":
                self.leap = leap
                self.up, self.down = [leap[i] for i in (0, 2, 5, 6)], [leap[i] for i in (3, 4, 5, 6)]
            else:
                self.up, self.down = leap[:4], leap[4:]
            cursor = common_scale(load("cursor_jump") + load("cursor_roll"))
        elif character == "bonobono":
            self.rest = frames(path("01-standing.png"), 1, 1, feet=True)[0]
            self.idle = common_scale(frames(path("06-idle.png"), feet=True))
            self.gaze = common_scale(frames(path("02-look-up.png"), 3, 1, feet=True))
            walks = common_scale(subjects(path("04-walk-right.png")) + subjects(path("05-walk-left.png")))
            self.walk, self.left_walk = walks[:8], walks[8:]
            self.run = common_scale(subjects(path("03-run-right.png")))
            self.leap = common_scale(subjects(path("07-leap.png")))
            self.up = [self.leap[i] for i in (0, 2, 5, 6)]
            self.down = [self.leap[i] for i in (3, 4, 5, 6)]
            cursor = common_scale(subjects(path("09-jump-no-cursor.png")) + subjects(path("11-roll-no-cursor.png")))
        else:
            self.idle = frames(path("유휴상태.png"))
            self.rest = self.idle[0]
            self.walk = frames(path("오른쪽으로 걷는 상태.png"), whole=True)
            self.run = common_scale(subjects(path("오른쪽 뛰는 상태.png")))
            hop = common_scale(subjects(path("픽셀 강아지의 힘찬 도약 스프라이트 시트.png")))
            self.up, self.down = hop[:4], hop[4:]
            self.gaze = common_scale(frames(path("세 방향으로 올려보는 픽셀 강아지.png"), 3, 1, feet=True))
            cursor = common_scale(subjects(path("puppy-jump-8frames-no-cursor.png")) + subjects(path("puppy-roll-8frames-no-cursor.png")))
        self.cursor_jump, self.cursor_roll = cursor[:8], cursor[8:]
        self.sprites = [self.rest] + self.idle + self.gaze + self.walk + (self.left_walk or []) + self.run + self.up + self.down + self.leap + cursor
        self.width_ratio = max(1.25, *(2 * max(s.anchor_x, s.width - s.anchor_x) / s.reference for s in self.sprites))

    def movement(self, gait: str, left: bool, now: float) -> tuple[Sprite, bool]:
        index = int(now / (0.065 if gait == "running" else 0.1)) % 8
        if gait == "walking" and left and self.left_walk:
            return self.left_walk[index], False
        return (self.run if gait == "running" else self.walk)[index], left

    def hopping(self, hop: Hop, vy: float) -> Sprite:
        if not self.leap:
            index = ("preparing", "airborne", "before_landing", "landing").index(hop.phase)
            return (self.up if hop.kind == "upward" else self.down)[index]
        if hop.phase == "preparing":
            index = 0
        elif hop.phase == "airborne":
            index = 1 if hop.kind == "upward" and hop.elapsed < 0.09 else 2 if vy > 90 else 3 if vy >= -90 else 4
        elif hop.phase == "before_landing":
            index = 5
        else:
            index = 6 if hop.elapsed < 0.12 else 7
        return self.leap[index]

    def grip(self, rolling: bool, frame: int, mirrored: bool, height: float) -> Point:
        if self.custom_grips:
            coords = [(p["x"], p["y"]) for p in self.custom_grips["roll" if rolling else "jump"]]
        elif self.template == "bonobono":
            coords = ((.72, .15), (.75, .17), (.59, .40), (.34, .40), (.34, .47), (.37, .25), (.31, .16), (.23, .16)) if rolling else ((0, 0),) * 4 + ((.84, .64), (.79, .39), (.76, .25), (.72, .33))
        else:
            coords = ((.80, .23), (.61, .20), (.67, .51), (.50, .39), (.42, .48), (.56, .28), (.76, .23), (.76, .25)) if rolling else ((0, 0),) * 4 + ((.80, .49), (.80, .40), (.79, .23), (.74, .37))
        sprite = (self.cursor_roll if rolling else self.cursor_jump)[frame]
        x, y = coords[frame]
        scale = height / sprite.reference
        offset_x = (x * sprite.width - sprite.anchor_x) * scale
        return Point(-offset_x if mirrored else offset_x, y * sprite.height * scale)
