"""Offline contract/security/UI checks. All credentials and HTTP are test doubles."""
from __future__ import annotations

import base64
from dataclasses import replace
import io
import json
from pathlib import Path
import tempfile
import threading
import time
import uuid


def run():
    from PIL import Image, ImageDraw
    from PySide6.QtWidgets import QApplication
    from .ai_motion import (Connection, ConnectionStore, Cancelled, catalog, check_cancel, choose_chroma,
                            decode_image, generate, image_input, make_request, motion_prompt, prepare_sheet, verify)
    from .ai_ui import APIConnectionsDialog
    from .assets import image_directory
    from .creator import CharacterCreator
    from .custom import CharacterLibrary, SLOTS, example_path, validate_png

    class MemoryVault:
        def __init__(self): self.values = {}
        def put(self, id, value): self.values[id] = value
        def get(self, id): return self.values[id]
        def delete(self, id): self.values.pop(id, None)

    def rejects(operation):
        try: operation()
        except (ValueError, Cancelled): return
        raise AssertionError("Invalid AI input was accepted")

    def wait(predicate):
        deadline = time.monotonic()+15
        while not predicate() and time.monotonic() < deadline:
            QApplication.processEvents(); time.sleep(.005)
        assert predicate(), "AI UI job timed out"

    model = catalog()["defaults"]
    root = image_directory()
    standing = example_path(root, "puppy", "standing")
    slot = next(s for s in SLOTS if s.key == "walk")
    reference = example_path(root, "puppy", "walk")
    connections = [Connection(str(uuid.uuid4()), p, p, model[p], time.time()) for p in model]
    original = standing.read_bytes()
    inputs = [image_input(standing), image_input(reference)]
    for c in connections:
        captured = []
        def metadata(url, auth, body=None, **kwargs):
            captured.append((url,auth,body))
            return {"id": c.model, "name": "models/"+c.model, "supportedGenerationMethods": ["generateContent"]}
        verify(c, "test-only-key", metadata)
        assert len(captured)==1 and captured[0][2] is None and "/models/" in captured[0][0]
        assert "test-only-key" not in captured[0][0]
        prompt = motion_prompt(slot, "split", "Transparent alpha")
        url, auth, body = make_request(c, "test-only-key", prompt, inputs)
        if c.provider == "openai":
            assert url == "https://api.openai.com/v1/images/edits"
            assert [v["image_url"].split(",",1)[1] for v in body["images"]] == [base64.b64encode(b).decode() for b in inputs]
            assert body["background"]=="transparent"
        elif c.provider == "gemini":
            assert url.startswith("https://generativelanguage.googleapis.com/")
            assert len([p for p in body["contents"][0]["parts"] if "inlineData" in p])==2
            assert body["generationConfig"]["imageConfig"]["aspectRatio"]=="16:9"
        else:
            assert url=="https://api.anthropic.com/v1/messages"
            assert len([p for p in body["messages"][0]["content"] if p["type"]=="image"])==2
        rejects(lambda: replace(c,model="https://bad.example/").validate())
    renderer, gemini, director = (next(c for c in connections if c.provider==p) for p in ("openai","gemini","anthropic"))
    with tempfile.TemporaryDirectory(prefix="DesktopCharacter-ai-check-") as folder:
        folder = Path(folder)
        output = folder/"result.png"
        calls=[]
        def fake(url, auth, body=None, **kwargs):
            calls.append((url,body))
            if url.endswith("/messages"): return {"content": [{"type":"text","text":"Preserve character identity; use a grounded walking cycle."}]}
            return {"data":[{"b64_json":base64.b64encode(reference.read_bytes()).decode()}]}
        generate(renderer,"test-only-key",slot,"split",standing,reference,output,director=director,director_key="test-only-director",transport=fake)
        validate_png(output,slot)
        assert len(calls)==2 and calls[0][0].endswith("messages")
        cancelled=threading.Event(); cancelled.set(); calls.clear()
        rejects(lambda:generate(renderer,"test-only-key",slot,"split",standing,reference,output,cancel=cancelled,transport=fake))
        assert not calls
        def cancel_after_director(url, auth, body=None, **kwargs):
            calls.append(url); cancelled.set()
            return {"content":[{"type":"text","text":"test"}]}
        cancelled.clear()
        rejects(lambda:generate(renderer,"test-only-key",slot,"split",standing,reference,output,director=director,director_key="test-only-director",cancel=cancelled,transport=cancel_after_director))
        assert len(calls)==1
        rejects(lambda:decode_image({"candidates":[{"content":{"parts":[{"text":"blocked"}]}}]},"gemini"))
        rejects(lambda:prepare_sheet(b"not an image",slot,output))
        opaque=Image.new("RGB",(128,64),"white"); encoded=io.BytesIO(); opaque.save(encoded,"PNG")
        rejects(lambda:prepare_sheet(encoded.getvalue(),slot,output))
        # Every cell has a blue border enclosing a key-colored interior pixel.
        # Edge flood fill must retain that interior while removing the exterior.
        image=Image.new("RGBA",(128,64),(255,0,255,255)); draw=ImageDraw.Draw(image)
        for y in range(2):
            for x in range(4):
                draw.rectangle((x*32+8,y*32+8,x*32+23,y*32+23),fill="blue")
                image.putpixel((x*32+16,y*32+16),(255,0,255,255))
        raw=io.BytesIO(); image.save(raw,"PNG")
        prepare_sheet(raw.getvalue(),slot,output,(255,0,255))
        with Image.open(output) as cleaned:
            assert cleaned.getpixel((0,0))[3]==0 and cleaned.getpixel((16,16))[3]==255
        # Gemini can return JPEG; normalize and remove its requested key color.
        chroma=choose_chroma(inputs[0])
        def fake_gemini(url, auth, body=None, **kwargs):
            with Image.open(reference) as original_image:
                rgba=original_image.convert("RGBA"); background=Image.new("RGBA",rgba.size,chroma+(255,))
                background.alpha_composite(rgba); raw=io.BytesIO(); background.convert("RGB").save(raw,"JPEG",quality=96)
            return {"candidates":[{"content":{"parts":[{"thought":True,"inlineData":{"mimeType":"image/png","data":"bad"}},
                    {"inlineData":{"mimeType":"image/jpeg","data":base64.b64encode(raw.getvalue()).decode()}}]}}]}
        generate(gemini,"test-only-key",slot,"split",standing,reference,output,transport=fake_gemini)
        validate_png(output,slot)
        vault=MemoryVault(); store=ConnectionStore(folder/"ai-connections.json",vault)
        store.save(renderer,"test-only-key"); store.save(director,"test-only-director")
        assert "test-only-key" not in store.path.read_text() and "test-only-director" not in store.path.read_text()
        assert len(ConnectionStore(store.path,vault).connections)==2
        editor=APIConnectionsDialog(store)
        editor.reload(renderer.id); editor.select_account()
        assert editor.verified_at is not None and editor.key_field.text()==""
        editor.invalidate(); assert editor.verified_at is None
        editor.reject()
        store.delete(director); assert director.id not in vault.values
        library=CharacterLibrary(folder/"characters")
        dialog=CharacterCreator(library,"puppy")
        dialog.ai_store=store; dialog.reload_ai()
        dialog.make_motions([slot]); assert "정지" in dialog.ai_status.text() and dialog.ai_job is None
        dialog.assign(standing,SLOTS[0]); dialog.assign(reference,slot)
        generated=[]
        def fake_generator(_c,_k,s,_layout,_standing,example,destination,**kwargs):
            check_cancel(kwargs.get("cancel")); generated.append(s.key)
            shutil_source=example_path(root,"puppy",s.key)
            destination.write_bytes(shutil_source.read_bytes())
            return destination
        dialog.ai_generate=fake_generator
        dialog.generate_all(); wait(lambda:dialog.ai_job is None)
        assert len(generated)==7 and "walk" not in generated and len(dialog.files)==9
        assert dialog.save_button.isEnabled() and dialog.files["standing"]==standing and dialog.files["walk"]==reference
        previous=dict(dialog.files); generated.clear()
        dialog.make_motions([slot]); wait(lambda:dialog.ai_job is None)
        assert generated==["walk"] and all(dialog.files[k]==v for k,v in previous.items() if k!="walk")
        old=dialog.files["walk"]
        def fail(*_args,**_kwargs): raise ValueError("Offline failure")
        dialog.ai_generate=fail; dialog.make_motions([slot]); wait(lambda:dialog.ai_job is None)
        assert dialog.files["walk"]==old and "Offline failure" in dialog.ai_status.text()
        entered=threading.Event(); released=threading.Event()
        def pending(*args,**kwargs):
            entered.set(); released.wait(5); check_cancel(kwargs["cancel"])
        dialog.ai_generate=pending; dialog.make_motions([slot]); wait(entered.is_set)
        dialog.cancel_ai(); released.set(); wait(lambda:dialog.ai_job is None)
        assert dialog.files["walk"]==old and "취소" in dialog.ai_status.text()
        dialog.reject()
    assert standing.read_bytes()==original
    print("PASS: AI 공식 호스트·두 이미지 전송·모델 조회 검증·키 비노출 저장·Claude 보조·투명 PNG·Gemini 배경·전체/개별 생성·실패 보존·취소 (외부 API 호출 없음)")
