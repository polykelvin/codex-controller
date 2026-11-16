import datetime as dt
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("controller", Path(__file__).parents[1] / "backend/controller.py")
c = importlib.util.module_from_spec(spec)
spec.loader.exec_module(c)

BASE = '''# User preferences
model = "gpt-6.1-sol" # personal model
model_reasoning_effort = "high"
web_search = "live"

[desktop]
theme = "dark"
[plugins."browser@openai-bundled"]
enabled = true
[mcp_servers.example]
command = "/path with spaces/tool"
args = ["one", "two"]
'''
ENDPOINT = "https://example.openai.azure.com/openai/v1"
HELPER = "/some path/Codex Controller.app/Contents/MacOS/CodexController"


class ConfigTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.codex = self.root / "codex"
        self.codex.mkdir()
        self.config = self.codex / "config.toml"
        self.config.write_text(BASE)
        self.controller = c.Controller(self.codex, self.root / "state")

    def tearDown(self):
        self.tmp.cleanup()

    def switch(self, mode):
        return self.controller.apply(mode, ENDPOINT, "gpt-6.1-sol", HELPER)

    def test_azure_preserves_plugins_and_mcp(self):
        self.switch("azure")
        data = c.parse(self.config.read_text())
        self.assertEqual(data["model_provider"], c.PROVIDER)
        self.assertEqual(data["plugins"], c.parse(BASE)["plugins"])
        self.assertEqual(data["mcp_servers"], c.parse(BASE)["mcp_servers"])
        self.assertEqual(data["model_reasoning_effort"], "high")
        self.assertNotIn("api_key", self.config.read_text())
        self.assertEqual(data["model_providers"][c.PROVIDER]["auth"]["command"], HELPER)

    def test_round_trip_restores_personal_settings(self):
        self.switch("azure")
        self.switch("personal")
        self.assertEqual(c.parse(self.config.read_text()), c.parse(BASE))

    def test_azure_repeat_has_one_provider(self):
        self.switch("azure")
        self.switch("azure")
        self.assertEqual(self.config.read_text().count(c.BEGIN), 1)

    def test_user_edits_during_azure_are_preserved(self):
        self.switch("azure")
        text = self.config.read_text().replace('theme = "dark"', 'theme = "light"')
        self.config.write_text(text)
        self.switch("personal")
        self.assertEqual(c.parse(self.config.read_text())["desktop"]["theme"], "light")

    def test_backups_match_previous_contents_and_private(self):
        self.switch("azure")
        status = self.controller.status()
        p = Path(status["backup_path"])
        self.assertEqual(p.read_text(), BASE)
        self.assertEqual(p.stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.config.stat().st_mode & 0o777, 0o600)

    def test_refuses_unknown_initial_provider(self):
        self.config.write_text('model_provider = "someone_else"\n')
        with self.assertRaises(ValueError): self.switch("azure")

    def test_invalid_toml_is_untouched(self):
        original = 'model = "unfinished\n'
        self.config.write_text(original)
        with self.assertRaises(ValueError): self.switch("azure")
        self.assertEqual(self.config.read_text(), original)

    def test_multiline_strings_and_arrays_survive(self):
        text = 'model = "old"\nnotes = """\nmodel = "fake"\n[fake]\n"""\nitems = [\n"a",\n"b"\n]\n[desktop]\nx = true\n'
        self.config.write_text(text)
        self.switch("azure")
        self.switch("personal")
        self.assertEqual(c.parse(self.config.read_text()), c.parse(text))

    def test_quoted_managed_key_refuses_safely(self):
        self.config.write_text('"model" = "gpt-6.1-sol"\n')
        with self.assertRaises(ValueError): self.switch("azure")

    def test_unmanaged_provider_collision_refuses(self):
        self.config.write_text(BASE + '\n[model_providers.' + c.PROVIDER + ']\nname="Existing"\n')
        with self.assertRaises(ValueError): self.switch("azure")

    def test_endpoint_validation(self):
        for url in ['http://example.com/openai/v1', 'https://key:secret@example.com/openai/v1', 'https://example.com/wrong', 'https://example.com/openai/v1?key=secret']:
            with self.subTest(url=url), self.assertRaises(ValueError):
                self.controller.apply("azure", url, "model", HELPER)
        self.assertEqual(self.config.read_text(), BASE)

    def test_symlink_refuses(self):
        real = self.codex / "real.toml"
        self.config.rename(real)
        self.config.symlink_to(real)
        with self.assertRaises(ValueError): self.switch("azure")
        self.assertEqual(real.read_text(), BASE)

    def test_status_does_not_modify_config(self):
        before = self.config.read_bytes()
        self.controller.status()
        self.assertEqual(self.config.read_bytes(), before)
        self.assertFalse(self.controller.state.exists())


def event(kind, payload, timestamp="2026-11-16T01:00:00Z"):
    return {"type": kind, "payload": payload, "timestamp": timestamp}

def usage(amount, output=10):
    return {"input_tokens": amount, "cached_input_tokens": amount // 2, "output_tokens": output, "total_tokens": amount + output}


class UsageTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.sessions = self.root / "codex/sessions"
        self.sessions.mkdir(parents=True)
        self.controller = c.Controller(self.root / "codex", self.root / "state")

    def tearDown(self): self.tmp.cleanup()

    def write(self, name, records):
        (self.sessions / name).write_text("".join(json.dumps(x) + "\n" for x in records))

    def test_deduplicates_response_ids_across_forked_files_and_events(self):
        records = [event("session_meta", {"id": "parent", "model_provider": "openai"}),
                   event("turn_context", {"model": "gpt-6.1-sol"}),
                   event("token_usage_record", {"response_id": "same-response", "usage": usage(100)}),
                   event("event_msg", {"type": "token_count", "info": {"total_token_usage": usage(100), "last_token_usage": usage(100)}})]
        self.write("one.jsonl", records)
        self.write("fork.jsonl", records)
        result = self.controller.usage()
        self.assertEqual(result["periods"]["all"]["total"], 110)
        self.assertEqual(result["periods"]["all"]["input"], 100)
        self.assertEqual(result["periods"]["all"]["cached"], 50)
        self.assertEqual(result["periods"]["all"]["requests"], 1)

    def test_legacy_cumulative_counters_are_not_summed(self):
        records = [event("session_meta", {"id": "old", "model_provider": "company_azure"})]
        for n in [100, 100, 200]:
            records.append(event("event_msg", {"type": "token_count", "info": {"total_token_usage": usage(n), "last_token_usage": usage(100)}}))
        self.write("old.jsonl", records)
        result = self.controller.usage()
        self.assertEqual(result["periods"]["all"]["total"], 210)
        self.assertEqual(result["approximate_records"], 2)

    def test_cache_contains_no_prompt_text_and_invalidates_on_append(self):
        records = [event("response_item", {"text": "TOP SECRET PROMPT"}),
                   event("token_usage_record", {"response_id": "r1", "usage": usage(100)})]
        self.write("one.jsonl", records)
        self.controller.usage()
        cache = (self.root / "state/usage-cache.json").read_text()
        self.assertNotIn("TOP SECRET", cache)
        records.append(event("token_usage_record", {"response_id": "r2", "usage": usage(200)}))
        self.write("one.jsonl", records)
        self.assertEqual(self.controller.usage()["periods"]["all"]["total"], 320)

    def test_partial_last_line_is_ignored(self):
        self.write("partial.jsonl", [event("token_usage_record", {"response_id": "r", "usage": usage(100)})])
        with (self.sessions / "partial.jsonl").open("a") as f: f.write('{"type":')
        self.assertEqual(self.controller.usage()["periods"]["all"]["total"], 110)

    def test_inherited_cumulative_total_does_not_become_new_usage(self):
        self.write("inherited.jsonl", [event("event_msg", {"type": "token_count", "info": {"total_token_usage": usage(10000), "last_token_usage": usage(100)}})])
        self.assertEqual(self.controller.usage()["periods"]["all"]["total"], 110)

    def test_profile_filter_excludes_other_profiles(self):
        for provider, value in [("openai", 100), ("company_azure", 200), ("codex_controller_azure", 300), ("unrelated", 400)]:
            self.write(provider + ".jsonl", [event("session_meta", {"model_provider": provider}),
                       event("token_usage_record", {"response_id": provider, "usage": usage(value)})])
        self.assertEqual(self.controller.usage("personal")["periods"]["all"]["total"], 110)
        self.assertEqual(self.controller.usage("company-azure")["periods"]["all"]["total"], 520)
        self.assertEqual(self.controller.usage()["periods"]["all"]["total"], 1040)

    def test_new_profile_and_rename_keep_usage_identity(self):
        profile = self.controller.save_profile({"name": "Research", "color": "#FFAA00", "endpoint": ENDPOINT, "deployment": "research"})["profile"]
        self.write("research.jsonl", [event("session_meta", {"model_provider": profile["provider"]}),
                   event("token_usage_record", {"response_id": "research", "usage": usage(300)})])
        updated = self.controller.save_profile({"name": "Research renamed", "color": "#AA00FF", "endpoint": ENDPOINT, "deployment": "research"}, profile["id"])["profile"]
        self.assertEqual(updated["provider"], profile["provider"])
        self.assertEqual(self.controller.usage(updated["id"])["periods"]["all"]["total"], 310)
        self.controller.delete_profile(profile["id"])
        self.assertEqual(self.controller.usage()["periods"]["all"]["total"], 310)


class ProfileTests(unittest.TestCase):
    setUp = ConfigTests.setUp
    tearDown = ConfigTests.tearDown
    def create(self, name="Research", color="#FFAA00"):
        return self.controller.save_profile({"name": name, "color": color, "endpoint": ENDPOINT, "deployment": "research"})["profile"]

    def test_defaults_migrate_without_writing_config(self):
        before = self.config.read_bytes()
        status = self.controller.status()
        self.assertEqual(len(status["profiles"]), 2)
        self.assertEqual(status["active_profile_id"], "personal")
        self.create()
        self.assertEqual(self.config.read_bytes(), before)

    def test_full_profile_lifecycle(self):
        profile = self.create()
        updated = self.controller.save_profile({"name": "Renamed", "color": "#abcdef", "endpoint": ENDPOINT, "deployment": "other"}, profile["id"])["profile"]
        self.assertEqual(updated["id"], profile["id"])
        self.assertEqual(updated["provider"], profile["provider"])
        self.assertEqual(updated["color"], "#ABCDEF")
        self.controller.delete_profile(profile["id"])
        with self.assertRaises(ValueError): self.controller.profile(profile["id"])
        self.assertEqual(self.config.read_text(), BASE)

    def test_duplicate_name_and_invalid_color_are_rejected(self):
        self.create()
        for name, color in [("research", "#ffffff"), ("", "#ffffff"), ("Another", "red")]:
            with self.assertRaises(ValueError): self.create(name, color)

    def test_personal_can_be_renamed_and_recolored_but_not_deleted(self):
        self.controller.save_profile({"name": "My subscription", "color": "#CCAABB"}, "personal")
        self.assertEqual(self.controller.profile("personal")["name"], "My subscription")
        with self.assertRaises(ValueError): self.controller.delete_profile("personal")

    def test_profile_application_uses_unique_provider_and_keychain_account(self):
        profile = self.create()
        self.controller.apply(None, "", "", HELPER, profile["id"])
        config = c.parse(self.config.read_text())
        self.assertEqual(config["model_provider"], profile["provider"])
        self.assertEqual(config["model"], "research")
        self.assertEqual(config["model_providers"][profile["provider"]]["auth"]["args"], ["--print-azure-key", "--profile-id", profile["id"]])
        self.assertEqual(self.controller.status()["active_profile_id"], profile["id"])
        with self.assertRaises(ValueError): self.controller.delete_profile(profile["id"])
        self.controller.apply(None, "", "", HELPER, "personal")
        self.assertEqual(c.parse(self.config.read_text()), c.parse(BASE))


    def test_switching_between_azure_profiles_preserves_unrelated_settings(self):
        a, b = self.create("Azure A"), self.create("Azure B")
        for profile in [a, b, a]:
            self.controller.apply(None, "", "", HELPER, profile["id"])
            config = c.parse(self.config.read_text())
            self.assertEqual(config["model_provider"], profile["provider"])
            self.assertEqual(config["plugins"], c.parse(BASE)["plugins"])
        self.controller.apply(None, "", "", HELPER, "personal")
        self.assertEqual(c.parse(self.config.read_text()), c.parse(BASE))


class ActivityTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        (self.root / "codex/sessions").mkdir(parents=True)
        self.controller = c.Controller(self.root / "codex", self.root / "state")

    def tearDown(self): self.tmp.cleanup()

    def write(self, name, records):
        p = self.root / "codex/sessions" / name
        p.write_text("".join(json.dumps(r) + "\n" for r in records))
        return p

    def test_visible_tools_results_and_reasoning_summaries_only(self):
        path = self.write("activity.jsonl", [
            event("response_item", {"type": "function_call", "name": "exec_command", "arguments": '{"cmd":"npm test"}'}),
            event("response_item", {"type": "function_call_output", "output": "Tests passed"}),
            event("response_item", {"type": "reasoning", "summary": [{"text": "Checking the tests."}], "content": "HIDDEN_CONTENT"}),
            event("response_item", {"type": "message", "role": "assistant", "channel": "analysis", "content": [{"text": "HIDDEN_ANALYSIS"}]}),
            event("event_msg", {"type": "agent_reasoning", "text": "HIDDEN_EVENT"}),
            event("response_item", {"type": "message", "role": "assistant", "channel": "final", "content": [{"text": "Done."}]})
        ])
        rows = c.read_activity_file(path)
        encoded = json.dumps(rows)
        self.assertEqual([r["category"] for r in rows], ["tool", "result", "summary", "message"])
        self.assertIn("Checking the tests.", encoded)
        self.assertNotIn("HIDDEN", encoded)

    def test_profile_filter_and_session_selection(self):
        for name, provider in [("personal", "openai"), ("work", "company_azure")]:
            self.write(name+".jsonl", [event("session_meta", {"model_provider": provider}), event("event_msg", {"type": "user_message", "message": name}), event("event_msg", {"type": "task_started"})])
        data = self.controller.activity("personal")
        self.assertEqual(len(data["sessions"]), 1)
        self.assertEqual(data["sessions"][0]["title"], "personal")
        self.assertEqual(data["events"][0]["title"], "Started")
        with self.assertRaises(ValueError): self.controller.activity("personal", "../../auth.json")

    def test_activity_does_not_persist_content(self):
        self.write("one.jsonl", [event("response_item", {"type": "function_call_output", "output": "LOCAL_ONLY_CONTENT"})])
        self.assertIn("LOCAL_ONLY_CONTENT", json.dumps(self.controller.activity()))
        self.assertFalse(self.controller.state.exists())



if __name__ == "__main__": unittest.main()
