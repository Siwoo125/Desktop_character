from __future__ import annotations

import json
import math
import os
import uuid
from pathlib import Path

from .animation import SCALES


def state_directory() -> Path:
    root = Path(os.environ.get("LOCALAPPDATA", str(Path.home() / ".local" / "share")))
    return root / "DesktopFriends"


def valid_character(value) -> bool:
    if value in ("puppy", "bonobono"):
        return True
    try:
        return isinstance(value, str) and value.startswith("custom-") and str(uuid.UUID(value[7:])) == value[7:].lower()
    except (ValueError, AttributeError):
        return False


def valid_instance(value) -> bool:
    if not isinstance(value, dict) or not valid_character(value.get("character")):
        return False
    try:
        uuid.UUID(value["id"])
        return value.get("scale") in SCALES and value.get("base_height", 60) == 60 and all(
            value.get(k) is None or Settings._number(value[k]) is not None for k in ("x", "y"))
    except (KeyError, ValueError, TypeError, AttributeError):
        return False


class Settings:
    def __init__(self, path: Path | None = None):
        self.path = path or state_directory() / "settings.json"
        try:
            data = json.loads(self.path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            data = {}
        if not isinstance(data, dict):
            data = {}
        selected = data.get("character")
        self.character = selected if valid_character(selected) else "puppy"
        self.scale = data.get("scale") if data.get("scale") in SCALES else 1.0
        self.base_height = 60.0
        self.x = self._number(data.get("x"))
        self.y = self._number(data.get("y"))
        self.instances = [dict(state) for state in data["instances"] if valid_instance(state)] if isinstance(data.get("instances"), list) else None

    @staticmethod
    def _number(value) -> float | None:
        if isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value):
            return float(value)
        return None

    @property
    def height(self) -> float:
        return self.base_height * self.scale

    def save(self) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        temporary = self.path.with_suffix(".tmp")
        data = {"character": self.character, "scale": self.scale, "x": self.x, "y": self.y}
        if self.instances is not None:
            data["instances"] = self.instances
        temporary.write_text(json.dumps(data, ensure_ascii=False, indent=2, allow_nan=False), encoding="utf-8")
        os.replace(temporary, self.path)
