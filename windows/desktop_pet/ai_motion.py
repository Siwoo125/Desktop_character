"""Personal API connections, official-host HTTP adapters and sprite preparation.

No API key in JSON, environment dumps, exceptions or logs. No automatic paid
retries. Normal credential verification retrieves model metadata only.
"""
from __future__ import annotations

import base64
from collections import deque
from dataclasses import asdict, dataclass
import io
import http.client
import json
import os
from pathlib import Path
import re
import sys
import socket
import threading
import time
from urllib.error import HTTPError, URLError
from urllib.request import HTTPRedirectHandler, HTTPSHandler, Request, build_opener
import uuid

from .assets import image_directory
from .custom import Slot, validate_png

PROVIDERS = {"openai": "OpenAI (ChatGPT 이미지)", "gemini": "Google Gemini", "anthropic": "Anthropic Claude (설명 보조)"}
KEY_PAGES = {"openai": "https://platform.openai.com/api-keys", "gemini": "https://aistudio.google.com/api-keys", "anthropic": "https://platform.claude.com/settings/keys"}
HOSTS = {"openai": "https://api.openai.com/v1", "gemini": "https://generativelanguage.googleapis.com/v1beta", "anthropic": "https://api.anthropic.com/v1"}
MAX_RESPONSE = 64 * 1024 * 1024


def catalog():
    return json.loads((image_directory().parent / "ai" / "motions.json").read_text(encoding="utf-8"))


@dataclass
class Connection:
    id: str
    provider: str
    name: str
    model: str
    verified_at: float | None = None

    @property
    def image_capable(self):
        return self.provider in ("openai", "gemini")

    def validate(self):
        if self.provider not in PROVIDERS or not 1 <= len(self.name.strip()) <= 40:
            raise ValueError("API 종류와 이름(1~40자)을 확인하세요.")
        if not re.fullmatch(r"[A-Za-z0-9._-]{1,120}", self.model):
            raise ValueError("모델 ID에는 영문·숫자·점·밑줄·하이픈만 사용할 수 있습니다.")
        if str(uuid.UUID(self.id)) != self.id:
            raise ValueError("API 저장 ID가 올바르지 않습니다.")
        if self.provider == "openai" and not (self.model.startswith("gpt-image-") or self.model == "chatgpt-image-latest"):
            raise ValueError("OpenAI는 이미지 편집 모델 ID를 입력하세요. 채팅 모델은 시트를 만들 수 없습니다.")
        if self.provider == "gemini" and not (self.model.startswith("gemini-") and ("image" in self.model or "nano-banana" in self.model)):
            raise ValueError("Gemini는 이미지 생성 모델 ID를 입력하세요.")
        if self.provider == "anthropic" and not self.model.startswith("claude-"):
            raise ValueError("Claude 모델 ID를 입력하세요.")


def clean_key(key):
    key = key.strip()
    if not key or len(key) > 4096 or any(c.isspace() for c in key):
        raise ValueError("공백이나 줄바꿈 없이 개인 API 키를 입력하세요.")
    return key


class CredentialVault:
    """Windows Credential Manager generic credential; no insecure fallback."""
    @staticmethod
    def _api():
        if sys.platform != "win32":
            raise ValueError("API 키 저장은 Windows 자격 증명 관리자에서 지원합니다.")
        import ctypes as c
        from ctypes import wintypes as w
        class Credential(c.Structure):
            _fields_ = [("Flags", w.DWORD), ("Type", w.DWORD), ("TargetName", w.LPWSTR), ("Comment", w.LPWSTR),
                        ("LastWritten", w.FILETIME), ("CredentialBlobSize", w.DWORD), ("CredentialBlob", c.POINTER(c.c_ubyte)),
                        ("Persist", w.DWORD), ("AttributeCount", w.DWORD), ("Attributes", c.c_void_p),
                        ("TargetAlias", w.LPWSTR), ("UserName", w.LPWSTR)]
        api = c.WinDLL("advapi32", use_last_error=True)
        api.CredWriteW.argtypes = [c.POINTER(Credential), w.DWORD]; api.CredWriteW.restype = w.BOOL
        api.CredReadW.argtypes = [w.LPCWSTR, w.DWORD, w.DWORD, c.POINTER(c.POINTER(Credential))]; api.CredReadW.restype = w.BOOL
        api.CredDeleteW.argtypes = [w.LPCWSTR, w.DWORD, w.DWORD]; api.CredDeleteW.restype = w.BOOL
        api.CredFree.argtypes = [c.c_void_p]; api.CredFree.restype = None
        return c, api, Credential

    def get(self, id):
        c, api, cls = self._api()
        pointer = c.POINTER(cls)()
        if not api.CredReadW("DesktopCharacter/AI/" + id, 1, 0, c.byref(pointer)):
            if c.get_last_error() == 1168:
                raise ValueError("저장한 API 키를 찾지 못했습니다. 키를 다시 입력해 주세요.")
            raise ValueError("자격 증명 관리자의 API 키를 읽지 못했습니다.")
        try:
            return c.string_at(pointer.contents.CredentialBlob, pointer.contents.CredentialBlobSize).decode("utf-8")
        finally:
            api.CredFree(pointer)

    def put(self, id, key):
        c, api, cls = self._api()
        blob = clean_key(key).encode("utf-8")
        buffer = (c.c_ubyte * len(blob)).from_buffer_copy(blob)
        value = cls(Type=1, TargetName="DesktopCharacter/AI/" + id, CredentialBlobSize=len(blob),
                    CredentialBlob=buffer, Persist=2, UserName="DesktopCharacter")
        if not api.CredWriteW(c.byref(value), 0):
            raise ValueError("API 키를 자격 증명 관리자에 저장하지 못했습니다.")

    def delete(self, id):
        c, api, _ = self._api()
        if not api.CredDeleteW("DesktopCharacter/AI/" + id, 1, 0) and c.get_last_error() != 1168:
            raise ValueError("자격 증명 관리자에서 API 키를 삭제하지 못했습니다.")


class ConnectionStore:
    def __init__(self, path: Path, vault=None):
        self.path, self.vault = path, vault or CredentialVault()
        self.connections = []
        self.renderer_id = self.director_id = None
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
            for value in data.get("connections", []):
                connection = Connection(**value)
                connection.validate()
                self.connections.append(connection)
            self.renderer_id, self.director_id = data.get("renderer_id"), data.get("director_id")
        except (OSError, ValueError, TypeError, AttributeError):
            self.connections = []

    def persist(self):
        self.path.parent.mkdir(parents=True, exist_ok=True)
        temporary = self.path.with_suffix(".tmp")
        temporary.write_text(json.dumps({"connections": [asdict(c) for c in self.connections],
                                         "renderer_id": self.renderer_id, "director_id": self.director_id}, ensure_ascii=False, indent=2), encoding="utf-8")
        os.replace(temporary, self.path)

    def save(self, connection, key):
        connection.validate()
        old = next((c for c in self.connections if c.id == connection.id), None)
        try: old_key = self.vault.get(connection.id) if old else None
        except (ValueError, KeyError): old_key = None
        self.vault.put(connection.id, key)
        original = list(self.connections)
        self.connections = [c for c in self.connections if c.id != connection.id] + [connection]
        try:
            self.persist()
        except OSError:
            self.connections = original
            if old_key is None: self.vault.delete(connection.id)
            else: self.vault.put(connection.id, old_key)
            raise ValueError("API 설정을 저장하지 못했습니다. 저장 공간을 확인하세요.") from None

    def delete(self, connection):
        original = list(self.connections)
        self.connections = [c for c in self.connections if c.id != connection.id]
        try:
            self.persist()
            self.vault.delete(connection.id)
        except Exception:
            self.connections = original
            self.persist()
            raise


class Cancelled(Exception):
    pass


def check_cancel(cancel):
    if cancel and cancel.is_set():
        raise Cancelled("생성을 취소했습니다. 진행 중이던 요청은 과금될 수 있습니다.")


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, *_args, **_kwargs):
        return None


def http_json(url, headers, body=None, timeout=240, cancel=None):
    check_cancel(cancel)
    request = Request(url, headers={**headers, "Content-Type": "application/json"},
                      data=json.dumps(body).encode("utf-8") if body is not None else None)
    finished = threading.Event()
    connections = []

    class CancellableHTTPS(http.client.HTTPSConnection):
        def connect(self):
            super().connect()
            try: check_cancel(cancel)
            except Cancelled:
                self.close()
                raise

    def factory(host, **kwargs):
        connection = CancellableHTTPS(host, **kwargs)
        connections.append(connection)
        return connection

    class Handler(HTTPSHandler):
        def https_open(self, req):
            return self.do_open(factory, req, context=self._context)

    def monitor():
        while not finished.wait(.1):
            if cancel.is_set():
                for connection in connections:
                    if connection.sock:
                        try: connection.sock.shutdown(socket.SHUT_RDWR)
                        except OSError: pass
                    connection.close()
                return

    if cancel is not None:
        threading.Thread(target=monitor, daemon=True).start()
    try:
        with build_opener(NoRedirect(), Handler()).open(request, timeout=timeout) as response:
            data = response.read(MAX_RESPONSE + 1)
    except HTTPError as error:
        error.close()
        messages = {400: "모델이 요청을 거절했습니다. 이미지 생성 지원·입력 크기·필터를 확인하세요.",
                    401: "API 키 인증에 실패했습니다.", 403: "모델 사용 권한이나 계정 인증을 확인하세요.",
                    404: "모델을 찾지 못했습니다. 모델 ID와 계정 사용 권한을 확인하세요.",
                    429: "호출 한도 또는 API 잔액을 확인하고 나중에 다시 시도하세요."}
        raise ValueError(messages.get(error.code, f"API 요청 실패 (HTTP {error.code}). 자동 재시도하지 않았습니다.")) from None
    except (URLError, TimeoutError, OSError, http.client.HTTPException):
        check_cancel(cancel)
        raise ValueError("API에 연결하지 못했거나 시간이 초과됐습니다. 네트워크를 확인하세요.") from None
    finally:
        finished.set()
    check_cancel(cancel)
    if len(data) > MAX_RESPONSE:
        raise ValueError("API 응답이 너무 큽니다.")
    try:
        result = json.loads(data)
        if not isinstance(result, dict): raise ValueError()
        return result
    except (ValueError, UnicodeError):
        raise ValueError("API 응답 형식이 올바르지 않습니다.") from None


def headers(connection, key):
    key = clean_key(key)
    if connection.provider == "openai": return {"Authorization": "Bearer " + key}
    if connection.provider == "gemini": return {"x-goog-api-key": key}
    return {"x-api-key": key, "anthropic-version": "2023-06-01"}


def verify(connection, key, transport=http_json, cancel=None):
    connection.validate()
    value = transport(HOSTS[connection.provider] + "/models/" + connection.model, headers(connection, key), timeout=30, cancel=cancel)
    actual = value.get("id") or value.get("name", "").removeprefix("models/")
    if not actual:
        raise ValueError("모델 정보가 없는 응답입니다. 검증을 완료하지 못했습니다.")
    if connection.provider == "gemini" and "generateContent" not in value.get("supportedGenerationMethods", []):
        raise ValueError("이 모델은 이미지 입력 생성 API를 지원하지 않습니다.")
    if connection.provider == "anthropic" and value.get("capabilities", {}).get("image_input", {}).get("supported") is False:
        raise ValueError("이 Claude 모델은 이미지 입력을 지원하지 않습니다.")
    return "연결·모델 조회 확인. 실제 생성 권한·잔액·이미지 품질은 생성 시 확인합니다."


def image_input(path: Path, mirror=False):
    from PIL import Image, ImageOps
    with Image.open(path) as source:
        image = source.convert("RGBA")
        image.thumbnail((1536, 1536), Image.Resampling.NEAREST)
        if mirror: image = ImageOps.mirror(image)
        output = io.BytesIO(); image.save(output, format="PNG")
    if output.tell() > 4 * 1024 * 1024:
        raise ValueError("API 전송용 PNG가 너무 큽니다. 원본 크기를 줄여 주세요.")
    return output.getvalue()


def motion_prompt(slot: Slot, layout, background):
    data = catalog()
    key = "leap_" + layout if slot.key == "leap" else slot.key
    return (data["instructions"] + f"\nGrid: exactly {slot.columns} columns x {slot.rows} rows, {slot.columns * slot.rows} poses.\n"
            + data["motions"][key] + "\n" + background)


def make_request(connection, key, prompt, inputs):
    encoded = [base64.b64encode(b).decode("ascii") for b in inputs]
    if connection.provider == "openai":
        size = "1536x1024" if connection.model.startswith(("gpt-image-1", "chatgpt-image")) else ("1536x512" if "3 columns x 1 rows" in prompt else "1536x768")
        body = {"model": connection.model, "prompt": prompt, "images": [{"image_url": "data:image/png;base64," + b} for b in encoded],
                "n": 1, "quality": "medium", "background": "transparent", "output_format": "png", "size": size}
        return HOSTS["openai"] + "/images/edits", headers(connection, key), body
    if connection.provider == "gemini":
        parts = [{"text": prompt}] + [{"inlineData": {"mimeType": "image/png", "data": b}} for b in encoded]
        body = {"contents": [{"role": "user", "parts": parts}], "generationConfig": {
                "responseModalities": ["TEXT", "IMAGE"], "imageConfig": {"aspectRatio": "21:9" if "3 columns x 1 rows" in prompt else "16:9"}}}
        return HOSTS["gemini"] + "/models/" + connection.model + ":generateContent", headers(connection, key), body
    parts = [{"type": "image", "source": {"type": "base64", "media_type": "image/png", "data": b}} for b in encoded]
    parts.append({"type": "text", "text": "Analyze Image 1 identity and Image 2 motion. Return only a concise English animation brief, no code, max 180 words. Honor these fixed requirements:\n" + prompt})
    return HOSTS["anthropic"] + "/messages", headers(connection, key), {"model": connection.model, "max_tokens": 512, "messages": [{"role": "user", "content": parts}]}


def decode_image(value, provider):
    try:
        if provider == "openai": encoded = value["data"][0]["b64_json"]
        else:
            parts = value["candidates"][0]["content"]["parts"]
            images = [p.get("inlineData", p.get("inline_data")) for p in parts if not p.get("thought")]
            image = next(p for p in images if p and p.get("mimeType", p.get("mime_type", "")).startswith("image/"))
            encoded = image["data"]
        result = base64.b64decode(encoded, validate=True)
        if not result or len(result) > 32 * 1024 * 1024: raise ValueError()
        return result
    except (KeyError, IndexError, StopIteration, TypeError, ValueError):
        raise ValueError("이미지가 반환되지 않았습니다. 모델 지원·정책 필터를 확인하세요. 기존 이미지는 유지했습니다.") from None


def choose_chroma(standing: bytes):
    from PIL import Image
    with Image.open(io.BytesIO(standing)) as im:
        image = im.convert("RGBA"); image.thumbnail((96, 96))
        pixels = [p[:3] for p in image.getdata() if p[3] > 32]
    palette = [(255, 0, 255), (0, 255, 0), (0, 255, 255), (255, 128, 0)]
    return max(palette, key=lambda c: min((sum((a-b)**2 for a,b in zip(c,p)) for p in pixels), default=0))


def prepare_sheet(data, slot, destination, chroma=None):
    """Preserve alpha; Gemini keying removes ONLY cell-edge-connected pixels."""
    from PIL import Image
    try:
        with Image.open(io.BytesIO(data)) as source:
            w, h = source.size
            if w > 8192 or h > 8192 or w*h > 16_777_216 or w < slot.columns*8 or h < slot.rows*8:
                raise ValueError("생성된 시트 크기가 허용 범위를 벗어났습니다.")
            image = source.convert("RGBA")
    except (OSError, Image.DecompressionBombError):
        raise ValueError("API가 유효한 이미지 파일을 반환하지 않았습니다.") from None
    w, h = image.size
    # Trim at most a few surplus edge pixels to get exact equal-sized cells.
    image = image.crop((0, 0, w-w % slot.columns, h-h % slot.rows))
    if chroma is not None:
        px = image.load(); w, h = image.size
        cw, ch = w//slot.columns, h//slot.rows
        for row in range(slot.rows):
            for col in range(slot.columns):
                x0, y0 = col*cw, row*ch
                q = deque([p for x in range(cw) for p in (x, (ch-1)*cw+x)] +
                          [p for y in range(ch) for p in (y*cw, y*cw+cw-1)])
                seen = bytearray(cw*ch)
                while q:
                    p = q.popleft()
                    if seen[p]: continue
                    seen[p] = 1
                    y, x = divmod(p, cw)
                    r,g,b,a = px[x0+x,y0+y]
                    if a == 0 or sum((c-d)**2 for c,d in zip((r,g,b),chroma)) <= 60**2:
                        px[x0+x,y0+y] = (r,g,b,0)
                        if x: q.append(p-1)
                        if x+1<cw: q.append(p+1)
                        if y: q.append(p-cw)
                        if y+1<ch: q.append(p+cw)
    image.save(destination, format="PNG")
    try:
        validate_png(destination, slot)
    except Exception:
        destination.unlink(missing_ok=True)
        raise ValueError(f"{slot.title}: 투명 배경·모든 프레임 조건을 통과하지 못했습니다. 이 모션만 다시 만들어 주세요.") from None


def generate(connection, key, slot, layout, standing, example, destination, *, director=None, director_key=None,
             mirror_example=False, cancel=None, transport=http_json):
    if not connection.image_capable or connection.verified_at is None:
        raise ValueError("이미지 생성 API를 추가하고 먼저 검증하세요.")
    check_cancel(cancel)
    inputs = [image_input(standing), image_input(example, mirror_example)]
    chroma = choose_chroma(inputs[0]) if connection.provider == "gemini" else None
    background = ("Use ONLY a perfectly uniform solid background color #%02X%02X%02X. No shadows, texture, gradient or checkerboard. This background will be removed locally." % chroma
                  if chroma else "Use a truly transparent alpha background, not a checkerboard or solid color.")
    prompt = motion_prompt(slot, layout, background)
    if director:
        if director.provider != "anthropic" or director.verified_at is None:
            raise ValueError("설명 보조 API는 검증된 Claude를 선택하세요.")
        check_cancel(cancel)
        url, auth, body = make_request(director, director_key, prompt, inputs)
        response = transport(url, auth, body, cancel=cancel)
        brief = "\n".join(p.get("text", "") for p in response.get("content", []) if p.get("type") == "text")[:2400]
        if not brief.strip(): raise ValueError("Claude가 모션 설명을 반환하지 않았습니다.")
        prompt += "\nOptional animation observations (fixed layout/identity rules above take priority):\n" + brief
    check_cancel(cancel)
    url, auth, body = make_request(connection, key, prompt, inputs)
    result = transport(url, auth, body, cancel=cancel)
    check_cancel(cancel)
    prepare_sheet(decode_image(result, connection.provider), slot, destination, chroma)
    check_cancel(cancel)
    return destination
