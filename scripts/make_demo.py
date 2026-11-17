#!/usr/bin/env python3
"""Build a demo app with synthetic usage for screenshots. Never reads user data."""
import datetime as dt
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / "backend"))
import controller

target = root / "dist/Codex Controller Demo.app"
shutil.copytree(root / "dist/Codex Controller.app", target, dirs_exist_ok=True)
resources = target / "Contents/Resources"
codex, state = resources / "demo/codex", resources / "demo/state"
(codex / "sessions").mkdir(parents=True, exist_ok=True)
state.mkdir(parents=True, exist_ok=True)
profiles = controller.default_profiles({"endpoint": "https://example.openai.azure.com/openai/v1", "deployment": "coding-model"})
profiles[1]["name"] = "Work Azure"
(state / "settings.json").write_text(json.dumps({"profiles": profiles}))
(codex / "config.toml").write_text('model = "coding-model"\nmodel_provider = "openai"\n')
today = dt.datetime.now(dt.timezone(dt.timedelta(hours=8))).date()
for index, profile in enumerate(profiles):
    lines = []
    provider = profile["provider"]
    for day in range(14):
        date = today - dt.timedelta(days=13-day)
        stamp = date.isoformat() + "T04:30:00Z"
        lines.append({"type": "session_meta", "timestamp": stamp, "payload": {"id": f"demo-{index}", "model_provider": provider}})
        lines.append({"type": "turn_context", "timestamp": stamp, "payload": {"model": "coding-model" if day % 3 else "reasoning-model"}})
        amount = [35000, 52000, 28000, 76000, 41000, 64000, 90000, 47000, 81000, 60000, 98000, 72000, 54000, 88000][day] * (index+1)
        lines.append({"type": "token_usage_record", "timestamp": stamp, "payload": {"response_id": f"demo-{index}-{day}", "usage": {
            "input_tokens": amount, "cached_input_tokens": amount//2, "output_tokens": amount//8, "total_tokens": amount+amount//8}}})
    lines += [
        {"type": "event_msg", "timestamp": stamp, "payload": {"type": "user_message", "message": "Polish the settings screen"}},
        {"type": "response_item", "timestamp": stamp, "payload": {"type": "function_call", "name": "exec_command", "arguments": '{"cmd":"npm test"}'}},
        {"type": "response_item", "timestamp": stamp, "payload": {"type": "function_call_output", "output": "12 tests passed"}},
        {"type": "response_item", "timestamp": stamp, "payload": {"type": "reasoning", "summary": [{"text": "I’ll check the layout and run the relevant tests."}]}},
        {"type": "event_msg", "timestamp": stamp, "payload": {"type": "task_complete"}}
    ]
    (codex / "sessions" / f"demo-{index}.jsonl").write_text("".join(json.dumps(line)+"\n" for line in lines))

info = target / "Contents/Info.plist"
data = plistlib.loads(info.read_bytes())
data.update(CFBundleIdentifier="com.kelvin.codex-controller.demo", CFBundleName="Codex Controller Demo", ControllerDemo=True,
            ControllerScreenshotPath=str(root / "docs/screenshot.png"))
info.write_bytes(plistlib.dumps(data))
(root / "docs").mkdir(exist_ok=True)
subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", str(target)], check=True)
print(target)
