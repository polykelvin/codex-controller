#!/usr/bin/env python3
"""Local configuration and usage only. Never calls an inference API."""
import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import re
import sys
import tempfile
import uuid

sys.path.insert(0, str(Path(__file__).parent / "vendor"))
import tomli

PROVIDER = "codex_controller_azure"
BEGIN = "# BEGIN CODEX CONTROLLER AZURE"
END = "# END CODEX CONTROLLER AZURE"
ROOT_KEYS = ("model", "model_provider", "web_search")
DEFAULT_ENDPOINT = ""


def default_profiles(settings):
    return [
        {"id": "personal", "name": "Personal subscription", "kind": "personal", "color": "#8170E9",
         "endpoint": "", "deployment": "", "provider": "openai", "usage_providers": ["openai"]},
        {"id": "company-azure", "name": "Company Azure", "kind": "azure", "color": "#19AAA5",
         "endpoint": settings.get("endpoint", DEFAULT_ENDPOINT),
         "deployment": settings.get("deployment", "gpt-6.1-sol"), "provider": PROVIDER,
         "usage_providers": [PROVIDER, "company_azure"]}
    ]


def validate_endpoint(endpoint):
    from urllib.parse import urlparse
    url = urlparse(endpoint)
    if not endpoint.startswith("https://") or not url.hostname or any(c.isspace() for c in endpoint):
        raise ValueError("Use your HTTPS Azure endpoint, including /openai/v1.")
    if url.username or url.password or url.query or url.fragment:
        raise ValueError("The endpoint must not contain credentials, query parameters or fragments.")
    if not url.path.rstrip("/").endswith("/openai/v1"):
        raise ValueError("Expected your Azure endpoint ending in /openai/v1.")


def atomic_write(path, text):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, name = tempfile.mkstemp(prefix=".controller-", dir=str(path.parent))
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w") as f:
            f.write(text)
            f.flush()
            os.fsync(f.fileno())
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def read_json(path, default):
    if not path.exists():
        return default
    return json.loads(path.read_text())


def quoted(s):
    return json.dumps(s, ensure_ascii=False)


def root_spans(text):
    """Locate complete root assignments, respecting strings, arrays and comments.

    TOML parsing and post-edit semantic validation provide a second guard.
    Dotted and quoted root keys are rejected when editing our managed settings.
    """
    lines = text.splitlines(keepends=True)
    assignments, start, key = {}, None, None
    quote, multiline, escaped, depth = None, False, False, 0
    offset = 0
    for line in lines:
        if quote is None and depth == 0:
            stripped = line.lstrip()
            if stripped.startswith("["):
                break
            m = re.match(r"\s*([A-Za-z0-9_-]+)\s*=", line)
            if m:
                start, key = offset, m.group(1)
        i = 0
        while i < len(line):
            c = line[i]
            if quote:
                if quote == '"' and escaped:
                    escaped = False
                elif quote == '"' and c == "\\":
                    escaped = True
                elif multiline and line[i:i+3] == quote * 3:
                    quote, multiline = None, False
                    i += 2
                elif not multiline and c == quote:
                    quote = None
            elif c == "#":
                break
            elif c in "\"'":
                quote = c
                multiline = line[i:i+3] == c * 3
                if multiline:
                    i += 2
            elif c in "[{":
                depth += 1
            elif c in "]}":
                depth -= 1
            i += 1
        offset += len(line)
        if start is not None and quote is None and depth == 0:
            assignments[key] = (start, offset)
            start, key = None, None
    return assignments


def parse(text):
    return tomli.loads(text)


def strip_managed(text):
    if BEGIN not in text and END not in text:
        return text
    if text.count(BEGIN) != 1 or text.count(END) != 1:
        raise ValueError("Controller section markers were changed. Restore a backup before switching.")
    pattern = re.compile(r"(?m)^" + re.escape(BEGIN) + r"\n.*?^" + re.escape(END) + r"\n?", re.S)
    result, count = pattern.subn("", text)
    if count != 1:
        raise ValueError("Cannot safely locate the controller's Azure section.")
    return result


def change_config(text, mode, personal, endpoint, model, helper, profile=None, managed_providers=None):
    provider = profile["provider"] if profile else PROVIDER
    managed_providers = set(managed_providers or [PROVIDER]) | {PROVIDER, provider}
    old = parse(text)
    if old.get("forced_login_method") == "chatgpt" and mode == "azure":
        raise ValueError("This configuration requires ChatGPT login. Resolve that requirement before using Azure.")
    unmanaged = strip_managed(text)
    clean = parse(unmanaged)
    if any(p in clean.get("model_providers", {}) for p in managed_providers if p != "openai"):
        raise ValueError("The controller's provider name already exists outside its managed section.")
    spans = root_spans(unmanaged)
    for k in ROOT_KEYS:
        if k in clean and k not in spans:
            raise ValueError("Cannot safely edit the root setting %s; use a plain top-level key." % k)
    for a, b in sorted((spans[k] for k in ROOT_KEYS if k in spans), reverse=True):
        unmanaged = unmanaged[:a] + unmanaged[b:]
    values = dict(personal) if mode == "personal" else {
        "model": model, "model_provider": provider, "web_search": "disabled"
    }
    prefix = "".join("%s = %s\n" % (k, quoted(values[k])) for k in ROOT_KEYS if k in values)
    result = prefix + unmanaged
    if mode == "azure":
        validate_endpoint(endpoint)
        if not model.strip() or "\n" in model:
            raise ValueError("Enter an Azure deployment name.")
        if not os.path.isabs(helper):
            raise ValueError("The credential helper must use an absolute path.")
        result += "\n" + BEGIN + "\n"
        result += "[model_providers.%s]\n" % provider
        result += 'name = %s\n' % quoted(profile["name"] if profile else "Company Azure (Controller)")
        result += "base_url = %s\n" % quoted(endpoint.rstrip("/"))
        result += 'wire_api = "responses"\nrequires_openai_auth = false\n'
        result += "[model_providers.%s.auth]\n" % provider
        result += "command = %s\n" % quoted(helper)
        args = ["--print-azure-key"] + (["--profile-id", profile["id"]] if profile else [])
        result += 'args = %s\ntimeout_ms = 30000\nrefresh_interval_ms = 300000\n' % json.dumps(args)
        result += END + "\n"
    new = parse(result)
    # All unrelated settings must remain semantically identical.
    def unrelated(config):
        config = json.loads(json.dumps(config, default=str))
        for k in ROOT_KEYS:
            config.pop(k, None)
        providers = config.get("model_providers", {})
        for p in managed_providers:
            if p != "openai":
                providers.pop(p, None)
        if not providers:
            config.pop("model_providers", None)
        return config
    if unrelated(old) != unrelated(new):
        raise ValueError("Refusing to modify unrelated Codex settings.")
    return result


class Controller:
    def __init__(self, home, state):
        self.home, self.state = Path(home), Path(state)
        self.config = self.home / "config.toml"
        self.settings = self.state / "settings.json"

    def profiles(self, settings=None):
        settings = settings if settings is not None else read_json(self.settings, {})
        return settings.get("profiles", default_profiles(settings))

    def profile(self, profile_id, settings=None):
        profile = next((p for p in self.profiles(settings) if p["id"] == profile_id), None)
        if profile is None:
            raise ValueError("That profile no longer exists. Refresh and choose another profile.")
        return profile

    def save_profile(self, data, profile_id=None):
        settings = read_json(self.settings, {})
        profiles = self.profiles(settings)
        old = self.profile(profile_id, settings) if profile_id else None
        name = data.get("name", "").strip()
        if not name or len(name) > 60 or any(ord(c) < 32 for c in name):
            raise ValueError("Enter a profile name between 1 and 60 characters.")
        if any(p["name"].casefold() == name.casefold() and p["id"] != profile_id for p in profiles):
            raise ValueError("Another profile already uses this name.")
        color = data.get("color", "")
        if not re.fullmatch(r"#[0-9a-fA-F]{6}", color):
            raise ValueError("Choose a valid wave color.")
        kind = old["kind"] if old else "azure"
        endpoint = data.get("endpoint", "").strip().rstrip("/")
        deployment = data.get("deployment", "").strip()
        if kind == "azure":
            validate_endpoint(endpoint)
            if not deployment or len(deployment) > 200 or any(ord(c) < 32 for c in deployment):
                raise ValueError("Enter a valid Azure deployment name.")
        else:
            endpoint, deployment = "", ""
        identity = old["id"] if old else uuid.uuid4().hex
        provider = old["provider"] if old else "cc_azure_" + identity
        profile = {"id": identity, "name": name, "kind": kind, "color": color.upper(),
                   "endpoint": endpoint, "deployment": deployment, "provider": provider,
                   "usage_providers": old["usage_providers"] if old else [provider]}
        settings["profiles"] = [profile if p["id"] == identity else p for p in profiles] if old else profiles + [profile]
        atomic_write(self.settings, json.dumps(settings, indent=2))
        return {"profile": profile, "profiles": settings["profiles"]}

    def delete_profile(self, profile_id):
        settings = read_json(self.settings, {})
        profile = self.profile(profile_id, settings)
        if profile["kind"] == "personal":
            raise ValueError("Keep the personal profile as your recovery option. You can rename or recolor it.")
        if self.status()["active_profile_id"] == profile_id:
            raise ValueError("Switch Codex to another profile before deleting its configured profile.")
        profiles = [p for p in self.profiles(settings) if p["id"] != profile_id]
        settings["profiles"] = profiles
        settings.setdefault("deleted_profiles", []).append(profile)
        atomic_write(self.settings, json.dumps(settings, indent=2))
        return {"profiles": profiles}

    def status(self):
        settings = read_json(self.settings, {})
        config = parse(self.config.read_text()) if self.config.exists() else {}
        provider = config.get("model_provider", "openai")
        profiles = self.profiles(settings)
        active = next((p for p in profiles if provider in p["usage_providers"]), None)
        return {"provider": provider, "mode": active["kind"] if active else "other",
                "profiles": profiles, "active_profile_id": active["id"] if active else None,
                "model": config.get("model", "Codex default"), "config_path": str(self.config),
                "endpoint": settings.get("endpoint", DEFAULT_ENDPOINT),
                "deployment": settings.get("deployment", "gpt-6.1-sol"),
                "has_personal_snapshot": "personal" in settings,
                "last_switch": settings.get("last_switch"),
                "backup_path": settings.get("backup_path"),
                "auth_note": "Existing ChatGPT sign-in is preserved. Sign in in Codex if needed."}

    def apply(self, mode, endpoint, model, helper, profile_id=None):
        if self.config.is_symlink():
            raise ValueError("config.toml is a symbolic link. Switch manually to preserve your setup.")
        original = self.config.read_text() if self.config.exists() else ""
        digest = hashlib.sha256(original.encode()).hexdigest()
        config = parse(original)
        settings = read_json(self.settings, {})
        profile = self.profile(profile_id, settings) if profile_id else None
        settings["profiles"] = self.profiles(settings)
        if profile:
            mode, endpoint, model = profile["kind"], profile["endpoint"], profile["deployment"]
        if "personal" not in settings:
            if config.get("model_provider", "openai") != "openai":
                raise ValueError("First run needs your personal OpenAI configuration active, so it can be saved safely.")
            settings["personal"] = {k: config[k] for k in ROOT_KEYS if k in config}
        elif config.get("model_provider", "openai") == "openai":
            settings["personal"] = {k: config[k] for k in ROOT_KEYS if k in config}
        managed_providers = [p["provider"] for p in self.profiles(settings) if p["kind"] == "azure"]
        managed_providers += [p["provider"] for p in settings.get("deleted_profiles", [])]
        result = change_config(original, mode, settings["personal"], endpoint, model, helper, profile, managed_providers)
        stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
        backup = self.state / "backups" / (stamp + ".toml")
        atomic_write(backup, original)
        settings.update(endpoint=endpoint, deployment=model, last_switch=stamp, backup_path=str(backup))
        # Persist the personal baseline before the config, allowing recovery after a crash.
        atomic_write(self.settings, json.dumps(settings, indent=2))
        if self.config.exists() and hashlib.sha256(self.config.read_bytes()).hexdigest() != digest:
            raise ValueError("Codex settings changed while switching. Nothing was applied; try again.")
        atomic_write(self.config, result)
        return self.status()

    def usage(self, profile_id=None):
        """Read local rollout usage; cache only counters/metadata, never prompt text."""
        cache_path = self.state / "usage-cache.json"
        cache = read_json(cache_path, {"version": 1, "files": {}})
        files = []
        for folder in ("sessions", "archived_sessions"):
            root = self.home / folder
            if root.exists():
                files.extend(root.rglob("*.jsonl"))
        rows, fallback = {}, {}
        errors = 0
        alive = set()
        for path in files:
            key = str(path)
            alive.add(key)
            try:
                stat = path.stat()
                signature = [stat.st_mtime_ns, stat.st_size]
                entry = cache["files"].get(key)
                if not entry or entry["signature"] != signature:
                    records, approximate = read_usage_file(path)
                    entry = {"signature": signature, "records": records, "fallback": approximate}
                    cache["files"][key] = entry
                if entry["records"]:
                    for row in entry["records"]:
                        rows.setdefault(row["id"], row)
                else:
                    for row in entry["fallback"]:
                        fallback.setdefault(row["id"], row)
            except (OSError, ValueError, KeyError):
                errors += 1
        cache["files"] = {k: v for k, v in cache["files"].items() if k in alive}
        atomic_write(cache_path, json.dumps(cache, separators=(",", ":")))
        all_rows = list(rows.values()) + list(fallback.values())
        profile = self.profile(profile_id) if profile_id else None
        if profile:
            accepted = set(profile["usage_providers"])
            all_rows = [r for r in all_rows if r.get("provider") in accepted]
        # Match the user's day/week boundaries, independent of the execution host timezone.
        hkt = dt.timezone(dt.timedelta(hours=8))
        now = dt.datetime.now(hkt)
        today = now.date()
        week = today - dt.timedelta(days=today.weekday())
        month = today.replace(day=1)
        days = {}
        periods = {k: empty_totals() for k in ("today", "week", "month", "all")}
        providers = {}
        for row in all_rows:
            try:
                date = dt.datetime.fromisoformat(row["timestamp"].replace("Z", "+00:00")).astimezone(hkt).date()
            except (ValueError, KeyError):
                continue
            if date > today:
                continue
            for period, start in (("today", today), ("week", week), ("month", month), ("all", dt.date.min)):
                if date >= start:
                    add_usage(periods[period], row)
            if date >= month:
                provider = row.get("provider") or "unknown"
                add_usage(providers.setdefault(provider, empty_totals()), row)
            if date >= today - dt.timedelta(days=13):
                add_usage(days.setdefault(date.isoformat(), empty_totals()), row)
        day_rows = []
        for i in range(13, -1, -1):
            d = today - dt.timedelta(days=i)
            day_rows.append({"date": d.isoformat(), **days.get(d.isoformat(), empty_totals())})
        return {"periods": periods, "providers_month": providers, "days": day_rows,
                "profile_id": profile_id, "profile_name": profile["name"] if profile else "All profiles",
                "files": len(files), "unreadable_files": errors, "approximate_records": len(fallback),
                "timezone": "Asia/Hong_Kong", "updated": now.isoformat(),
                "scope": "Local Codex session records on this Mac. Not an account-wide bill or remaining subscription allowance."}

    def activity(self, profile_id=None, session_id=None):
        accepted = set(self.profile(profile_id)["usage_providers"]) if profile_id else None
        files = []
        for folder in ("sessions", "archived_sessions"):
            root = self.home / folder
            if root.exists():
                files.extend(root.rglob("*.jsonl"))
        sessions = []
        chosen = None
        for path in sorted(files, key=lambda p: p.stat().st_mtime, reverse=True):
            identity = hashlib.sha256(str(path.relative_to(self.home)).encode()).hexdigest()[:24]
            provider, model, title, started = "unknown", "", "", ""
            try:
                # Session metadata and the first user message appear near the start.
                with path.open() as f:
                    for index, line in enumerate(f):
                        if index > 150:
                            break
                        try:
                            record = json.loads(line)
                        except ValueError:
                            continue
                        payload = record.get("payload") or {}
                        kind = record.get("type")
                        if kind == "session_meta":
                            provider = payload.get("model_provider") or provider
                            started = record.get("timestamp", "")
                        elif kind == "turn_context":
                            model = payload.get("model", model)
                        elif kind == "event_msg" and payload.get("type") == "user_message" and not title:
                            title = str(payload.get("message", ""))[:150]
                if accepted is not None and provider not in accepted:
                    continue
                if identity == session_id:
                    chosen = path
                sessions.append({"id": identity, "title": title or "Codex session", "provider": provider,
                                 "model": model, "started": started, "modified": path.stat().st_mtime})
            except (OSError, ValueError):
                continue
        sessions = sessions[:80]
        if session_id and chosen is None:
            raise ValueError("Session not found for this profile.")
        if chosen is None and sessions:
            identity = sessions[0]["id"]
            chosen = next((p for p in files if hashlib.sha256(str(p.relative_to(self.home)).encode()).hexdigest()[:24] == identity), None)
        events = read_activity_file(chosen) if chosen else []
        return {"sessions": sessions, "session_id": session_id or (sessions[0]["id"] if sessions else None), "events": events}


def empty_totals():
    return {"input": 0, "cached": 0, "output": 0, "total": 0, "requests": 0}


def add_usage(total, row):
    for k in ("input", "cached", "output", "total"):
        total[k] += row.get(k, 0)
    total["requests"] += 1


def usage_row(identity, timestamp, usage, provider, model):
    return {"id": identity, "timestamp": timestamp, "provider": provider, "model": model,
            "input": int(usage.get("input_tokens", 0)),
            "cached": int(usage.get("cached_input_tokens", 0)),
            "output": int(usage.get("output_tokens", 0)),
            "total": int(usage.get("total_tokens", 0))}


def read_usage_file(path):
    records, fallback = [], []
    provider, model, session = "unknown", "unknown", path.stem
    previous = None
    with path.open() as f:
        for ordinal, line in enumerate(f):
            try:
                record = json.loads(line)
            except ValueError:
                continue  # A running Codex may have an incomplete final line.
            kind, payload = record.get("type"), record.get("payload") or {}
            if kind == "session_meta":
                provider = payload.get("model_provider") or provider
                session = payload.get("id") or session
            elif kind == "turn_context":
                model = payload.get("model") or model
                provider = payload.get("model_provider") or provider
            elif kind == "token_usage_record":
                u = payload.get("usage")
                identity = payload.get("response_id")
                if u and identity:
                    records.append(usage_row(identity, record.get("timestamp"), u, provider, model))
            elif kind == "event_msg" and payload.get("type") == "token_count":
                info = payload.get("info") or {}
                total = info.get("total_token_usage")
                last = info.get("last_token_usage")
                if total and last:
                    if previous is None:
                        delta = last
                    else:
                        delta = {k: max(0, total.get(k, 0) - previous.get(k, 0)) for k in total}
                    previous = total
                    if delta.get("total_tokens", 0) > 0:
                        identity = "%s:%s:%s" % (session, record.get("timestamp"), total.get("total_tokens"))
                        fallback.append(usage_row(identity, record.get("timestamp"), delta, provider, model))
    return records, fallback


def display_text(value, limit=12000):
    if isinstance(value, str):
        result = value
    elif isinstance(value, list):
        result = "\n".join(str(x.get("text", "")) for x in value if isinstance(x, dict))
    else:
        result = json.dumps(value, ensure_ascii=False, indent=2)
    return result[:limit] + ("\n…" if len(result) > limit else "")


def read_activity_file(path):
    """Allowlisted visible events only; never surface hidden reasoning content."""
    from collections import deque
    events = deque(maxlen=200)
    seen = set()
    with path.open() as f:
        for line in f:
            try:
                record = json.loads(line)
            except ValueError:
                continue
            payload = record.get("payload") or {}
            kind = record.get("type")
            title, detail, category = None, "", ""
            if kind == "response_item":
                item = payload.get("type")
                if item in ("function_call", "custom_tool_call", "tool_call"):
                    title, category = payload.get("name", "Tool call"), "tool"
                    detail = display_text(payload.get("arguments", payload.get("input", "")))
                elif item in ("function_call_output", "custom_tool_call_output", "tool_result"):
                    title, category = "Tool result", "result"
                    detail = display_text(payload.get("output", payload.get("content", "")))
                elif item == "reasoning" and payload.get("summary"):
                    title, category = "Reasoning summary", "summary"
                    detail = display_text(payload["summary"])
                elif item == "message" and payload.get("role") == "assistant" and payload.get("channel") in ("final", "commentary"):
                    title, category = "Codex", "message"
                    detail = display_text(payload.get("content", []))
            elif kind == "event_msg":
                event = payload.get("type")
                if event in ("task_started", "task_complete", "turn_aborted"):
                    title = {"task_started": "Started", "task_complete": "Completed", "turn_aborted": "Stopped"}[event]
                    category = "status"
                # user_message and agent_reasoning are intentionally not part of this allowlist.
            if title:
                stamp = record.get("timestamp", "")
                key = (stamp, title, detail)
                if key not in seen:
                    seen.add(key)
                    events.append({"timestamp": stamp, "title": title, "detail": detail, "category": category})
    return list(events)


def main():
    p = argparse.ArgumentParser()
    p.add_argument("action", choices=["status", "apply", "usage", "activity", "profile-save", "profile-delete"])
    p.add_argument("--home", default=os.environ.get("CODEX_HOME", str(Path.home() / ".codex")))
    p.add_argument("--state", default=str(Path.home() / "Library/Application Support/Codex Controller"))
    p.add_argument("--mode", choices=["personal", "azure"])
    p.add_argument("--endpoint", default=DEFAULT_ENDPOINT)
    p.add_argument("--model", default="gpt-6.1-sol")
    p.add_argument("--helper", default="")
    p.add_argument("--profile-id")
    p.add_argument("--name", default="")
    p.add_argument("--color", default="#19AAA5")
    p.add_argument("--session-id")
    a = p.parse_args()
    c = Controller(a.home, a.state)
    try:
        if a.action == "status":
            result = c.status()
        elif a.action == "usage":
            result = c.usage(a.profile_id)
        elif a.action == "activity":
            result = c.activity(a.profile_id, a.session_id)
        elif a.action == "profile-save":
            result = c.save_profile({"name": a.name, "color": a.color, "endpoint": a.endpoint, "deployment": a.model}, a.profile_id)
        elif a.action == "profile-delete":
            result = c.delete_profile(a.profile_id)
        else:
            if not a.mode and not a.profile_id:
                raise ValueError("Choose a provider.")
            result = c.apply(a.mode, a.endpoint, a.model, a.helper, a.profile_id)
        print(json.dumps({"ok": True, "data": result}))
    except Exception as e:
        print(json.dumps({"ok": False, "error": str(e)}))
        sys.exit(1)


if __name__ == "__main__":
    main()
