import email.message
import importlib.util
import json
import os
import stat
import tempfile
import time
import unittest
import urllib.error
from decimal import Decimal
from pathlib import Path
from unittest import mock


SPEC = importlib.util.spec_from_file_location("usage_hud", Path(__file__).with_name("usage_hud.py"))
hud = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(hud)


class ProviderPipelineTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.cache = Path(self.tmp.name) / "openrouter.json"
        self.cache_patch = mock.patch.object(hud, "OPENROUTER_CACHE", self.cache)
        self.cache_patch.start()

    def tearDown(self):
        self.cache_patch.stop()
        self.tmp.cleanup()

    def test_fallback_winner_replaces_pipe_and_resets_daily_baseline(self):
        old = {"captured_at": 1, "rows": [{
            "slot_id": "guy1", "label": "Guy1", "provider": "old",
            "source_id": "old:primary", "usage": 40, "day": hud._local_today(),
            "day_start_usage": 10,
        }]}
        self.cache.write_text(json.dumps(old))
        slots = [{"id": "guy1", "label": "Guy1", "sources": [
            {"provider": "broken", "id": "primary"},
            {"provider": "new", "id": "fallback"},
        ]}]

        def broken(_source):
            raise RuntimeError("offline")

        with mock.patch.object(hud, "_provider_slots", return_value=(slots, None)), \
             mock.patch.dict(hud.PROVIDERS, {
                 "broken": {"probe": broken},
                 "new": {"probe": lambda _source: {"usage": 50.0, "limit": 100.0}},
             }, clear=True):
            ok, error = hud.probe_openrouter()

        self.assertTrue(ok)
        self.assertIsNone(error)
        row = json.loads(self.cache.read_text())["rows"][0]
        self.assertEqual(row["provider"], "new")
        self.assertEqual(row["source_id"], "new:fallback")
        self.assertEqual(row["day_start_usage"], 50.0)

    def test_total_failure_is_persisted_and_old_value_is_explicitly_stale(self):
        old = {"captured_at": 123, "rows": [{
            "slot_id": "guy1", "label": "Guy1", "provider": "openrouter",
            "source_id": "openrouter:svc:ox1", "usage": 7.0, "limit": 10.0,
            "day": hud._local_today(), "day_start_usage": 5.0,
        }]}
        self.cache.write_text(json.dumps(old))
        slots = [{"id": "guy1", "label": "Guy1", "sources": [
            {"provider": "broken", "id": "only"},
        ]}]
        with mock.patch.object(hud, "_provider_slots", return_value=(slots, None)), \
             mock.patch.dict(hud.PROVIDERS, {
                 "broken": {"probe": lambda _source: (_ for _ in ()).throw(RuntimeError("offline"))},
             }, clear=True):
            ok, error = hud.probe_openrouter()

        self.assertFalse(ok)
        self.assertIn("offline", error)
        blob = json.loads(self.cache.read_text())
        self.assertEqual(blob["captured_at"], 123)
        self.assertGreater(blob["checked_at"], 123)
        self.assertTrue(blob["rows"][0]["stale"])
        panel = hud.read_openrouter()
        self.assertIn("failed slot", panel["note"])
        self.assertIn("stale", panel["windows"][0]["right"])

    def test_legacy_cache_never_calls_total_usage_today(self):
        self.cache.write_text(json.dumps({"captured_at": hud.time.time(), "rows": [{
            "label": "Guy1", "usage": 7.0, "limit": 10.0,
        }]}))
        row = hud.read_openrouter()["windows"][0]
        self.assertIsNone(row["pct"])
        self.assertIn("total; baseline pending", row["right"])

    def test_private_json_is_owner_only(self):
        hud._atomic_private_json(self.cache, {"safe": True})
        self.assertEqual(stat.S_IMODE(self.cache.stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(self.cache.parent.stat().st_mode), 0o700)


class CredentialTransportTests(unittest.TestCase):
    def test_expired_claude_token_never_mutates_keychain(self):
        credential = json.dumps({"claudeAiOauth": {
            "accessToken": "expired-access",
            "refreshToken": "must-not-be-used",
            "expiresAt": 1,
        }})
        calls = []

        def run(cmd, **_kwargs):
            calls.append(cmd)
            return mock.Mock(returncode=0, stdout=credential)

        with mock.patch("subprocess.run", side_effect=run), \
             mock.patch.object(hud.urllib.request, "urlopen") as urlopen:
            token, error = hud.claude_oauth()

        self.assertIsNone(token)
        self.assertIn("authentication expired", error)
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0][:3], ["security", "find-generic-password", "-s"])
        self.assertNotIn("add-generic-password", calls[0])
        urlopen.assert_not_called()






class CreditsTests(unittest.TestCase):
    """Usage-credits extension: Claude extra-usage $ (OAuth usage GET) and
    Codex OpenAI pay-as-you-go balance. Additive - window logic untouched."""

    def setUp(self):
        hud.OPENAI_ADMIN_TOKEN_STATE.update(selector=None, token=None)

    def tearDown(self):
        hud.OPENAI_ADMIN_TOKEN_STATE.update(selector=None, token=None)

    def test_claude_credits_row_cents_units(self):
        row = hud._claude_credits_row({
            "is_enabled": True, "monthly_limit": 2000, "used_credits": 758.0,
            "utilization": 37.9, "captured_at": time.time(),
        })
        self.assertIsNone(row["pct"])  # bar-less: label+bar+long text can't fit
        self.assertEqual(row["right"], "$7.58 of $20.00 · 38%")
        self.assertFalse(row["stale"])

    def test_claude_credits_row_small_limit_is_dollars(self):
        row = hud._claude_credits_row({
            "is_enabled": True, "monthly_limit": 20.0, "used_credits": 3.95,
            "utilization": 20.0, "captured_at": time.time(),
        })
        self.assertEqual(row["right"], "$3.95 of $20.00 · 20%")
        self.assertIsNone(row["pct"])

    def test_claude_credits_row_pct_falls_back_to_ratio(self):
        row = hud._claude_credits_row({
            "is_enabled": True, "monthly_limit": 2000, "used_credits": 500.0,
            "captured_at": time.time(),
        })
        self.assertIn("· 25%", row["right"])

    def test_claude_credits_row_disabled_or_broken_is_none(self):
        self.assertIsNone(hud._claude_credits_row({"is_enabled": False,
                                                   "monthly_limit": 2000,
                                                   "used_credits": 10.0}))
        self.assertIsNone(hud._claude_credits_row({"is_enabled": True}))
        self.assertIsNone(hud._claude_credits_row(None))

    def test_claude_credits_row_goes_stale(self):
        row = hud._claude_credits_row({
            "is_enabled": True, "monthly_limit": 2000, "used_credits": 1.0,
            "utilization": 5.0, "captured_at": time.time() - 7 * 3600,
        })
        self.assertTrue(row["stale"])

    def test_read_claude_appends_credits_after_windows(self):
        with tempfile.TemporaryDirectory() as tmp:
            cache = Path(tmp) / "claude.json"
            cache.write_text(json.dumps({
                "captured_at": time.time(),
                "rate_limits": {"five_hour": {"used_percentage": 10.0}},
                "usage_credits": {"is_enabled": True, "monthly_limit": 2000,
                                  "used_credits": 758.0, "utilization": 37.9,
                                  "captured_at": time.time()},
            }))
            with mock.patch.object(hud, "CLAUDE_CACHE", cache):
                panel = hud.read_claude()
        self.assertEqual([w["label"] for w in panel["windows"]],
                         ["5h", "credits"])
        self.assertEqual(panel["windows"][1]["right"], "$7.58 of $20.00 · 38%")

    def test_merge_private_json_preserves_sibling_sections(self):
        with tempfile.TemporaryDirectory() as tmp:
            cache = Path(tmp) / "claude.json"
            hud._atomic_private_json(cache, {"rate_limits": {"five_hour": 1}})
            hud._merge_private_json(cache, {"usage_credits": {"used_credits": 1}})
            hud._merge_private_json(cache, {"captured_at": 123})
            data = json.loads(cache.read_text())
        self.assertEqual(data["rate_limits"], {"five_hour": 1})
        self.assertEqual(data["usage_credits"], {"used_credits": 1})
        self.assertEqual(data["captured_at"], 123)

    def test_codex_credits_row_manual_and_stale_error(self):
        with tempfile.TemporaryDirectory() as tmp:
            cache = Path(tmp) / "codex.json"
            hud._atomic_private_json(cache, {"captured_at": time.time(),
                                             "balance": 50.0, "manual": True})
            with mock.patch.object(hud, "CODEX_CACHE", cache):
                row = hud._codex_credits_row()
            self.assertEqual(row["right"], "$50.00 left  (manual)")
            hud._atomic_private_json(cache, {"captured_at": time.time(),
                                             "balance": 50.0,
                                             "error": "billing probe failed"})
            with mock.patch.object(hud, "CODEX_CACHE", cache):
                row = hud._codex_credits_row()
            self.assertTrue(row["stale"])
            self.assertIn("stale;", row["right"])
            self.assertLessEqual(len(row["right"]), 23)  # no canvas overflow

    def test_codex_credits_row_marks_server_value_live_estimate(self):
        with tempfile.TemporaryDirectory() as tmp:
            cache = Path(tmp) / "codex.json"
            hud._atomic_private_json(cache, {"captured_at": time.time(),
                                             "balance": 44.67884125,
                                             "live_estimate": True})
            with mock.patch.object(hud, "CODEX_CACHE", cache):
                row = hud._codex_credits_row()
        self.assertEqual(row["right"], "$44.68  live est.")
        self.assertFalse(row["stale"])

    def test_openai_credit_source_validates_and_rejects(self):
        with tempfile.TemporaryDirectory() as tmp:
            cfg = Path(tmp) / "credits.json"
            with mock.patch.object(hud, "CODEX_CREDITS_CONFIG", cfg):
                self.assertIsNone(hud._openai_credit_source())  # missing file
                cfg.write_text(json.dumps({"openai": {"service": "s", "account": "a"}}))
                self.assertEqual(hud._openai_credit_source(),
                                 {"service": "s", "account": "a"})
                cfg.write_text(json.dumps({"openai": {"service": "", "account": "a"}}))
                self.assertIsNone(hud._openai_credit_source())  # empty selector

    def test_openai_admin_key_is_read_once_per_hud_process(self):
        source = {"service": "openai-platform", "account": "gimmick"}
        with mock.patch.object(hud, "_keychain_password",
                               return_value="in-memory-only") as keychain:
            first = hud._openai_admin_token(source)
            second = hud._openai_admin_token(source)
        self.assertEqual(first, "in-memory-only")
        self.assertEqual(second, "in-memory-only")
        keychain.assert_called_once_with("openai-platform", "gimmick")

    @staticmethod
    def _json_response(payload):
        resp = mock.MagicMock()
        resp.read.return_value = json.dumps(payload).encode()
        resp.__enter__.return_value = resp
        return resp

    def test_openai_costs_are_paginated(self):
        pages = [
            self._json_response({"data": [{"results": [{"amount": {
                "value": "2.50", "currency": "usd"}}]}],
                                 "has_more": True, "next_page": "next"}),
            self._json_response({"data": [{"results": [{"amount": {
                "value": 1.25, "currency": "USD"}}]}],
                                 "has_more": False, "next_page": None}),
        ]
        with mock.patch.object(hud.urllib.request, "urlopen",
                               side_effect=pages) as call:
            total = hud._openai_costs_since("secret", 100, 200)
        self.assertEqual(total, Decimal("3.75"))
        self.assertEqual(call.call_count, 2)
        self.assertIn("page=next", call.call_args_list[1].args[0].full_url)

    def test_openai_live_usage_pricing_matches_official_balance(self):
        # The 11 server-reported Astra calls total 33 uncached input,
        # 387,567 cache-write, and 115,948 output tokens. Keep every synthetic
        # per-request row below the long-context threshold.
        total = Decimal("0")
        write_parts = [35233] * 10 + [35237]
        output_parts = [10540] * 10 + [10548]
        for index in range(11):
            cost, conservative, requests = hud._openai_usage_result_cost({
                "model": "gpt-6-astra", "batch": False,
                "service_tier": "flex-tier", "num_model_requests": 1,
                "input_tokens": write_parts[index] + (33 if index == 0 else 0),
                "input_uncached_tokens": 33 if index == 0 else 0,
                "input_cached_tokens": 0,
                "input_cache_write_tokens": write_parts[index],
                "output_tokens": output_parts[index],
            })
            total += cost
            self.assertFalse(conservative)
            self.assertEqual(requests, 1)
        self.assertEqual(sum(write_parts), 387567)
        self.assertEqual(sum(output_parts), 115948)
        self.assertEqual(total, Decimal("5.32115875"))
        self.assertEqual(Decimal("50") - total, Decimal("44.67884125"))

    def test_openai_unknown_model_fails_closed(self):
        with self.assertRaisesRegex(ValueError, "unsupported priced model"):
            hud._openai_usage_result_cost({
                "model": "future-model", "service_tier": "flex-tier",
                "batch": False, "num_model_requests": 1,
                "input_tokens": 1, "input_uncached_tokens": 1,
                "output_tokens": 1,
            })

    def test_openai_probe_reconciles_settled_and_live_server_spend(self):
        with tempfile.TemporaryDirectory() as tmp:
            cache = Path(tmp) / "codex.json"
            config = Path(tmp) / "credits.json"
            config.write_text(json.dumps({"openai": {
                "service": "admin-service", "account": "gimmick",
                "balance_seed_usd": 50, "balance_seed_at": 100,
            }}))
            with mock.patch.object(hud, "CODEX_CACHE", cache), \
                 mock.patch.object(hud, "CODEX_CREDITS_CONFIG", config), \
                 mock.patch.object(hud, "_keychain_password", return_value="secret"), \
                 mock.patch.object(hud.time, "time", return_value=200), \
                 mock.patch.object(hud, "_openai_costs_since",
                                   return_value=Decimal("2.73444375")), \
                 mock.patch.object(hud, "_openai_usage_cost_since",
                                   return_value=(Decimal("5.32115875"), 180,
                                                 False, 11)):
                ok, msg = hud.probe_openai_credits()
            blob = json.loads(cache.read_text())
        self.assertTrue(ok)
        self.assertEqual(msg, "")
        self.assertEqual(blob["balance"], 44.67884125)
        self.assertEqual(blob["spent_since_seed"], 5.32115875)
        self.assertEqual(blob["settled_spend"], 2.73444375)
        self.assertEqual(blob["usage_request_count"], 11)
        self.assertEqual(blob["source"], "organization_costs_plus_server_usage")
        self.assertNotIn("secret", json.dumps(blob))

    def test_openai_manual_cache_is_migrated_to_balance_seed(self):
        with tempfile.TemporaryDirectory() as tmp:
            cache = Path(tmp) / "codex.json"
            config = Path(tmp) / "credits.json"
            hud._atomic_private_json(cache, {
                "captured_at": 100, "balance": 50.0, "manual": True,
            })
            config.write_text(json.dumps({
                "openai": {"service": "admin-service", "account": "gimmick"}
            }))
            with mock.patch.object(hud, "CODEX_CACHE", cache), \
                 mock.patch.object(hud, "CODEX_CREDITS_CONFIG", config), \
                 mock.patch.object(hud, "_keychain_password", return_value="secret"), \
                 mock.patch.object(hud.time, "time", return_value=200), \
                 mock.patch.object(hud, "_openai_costs_since",
                                   return_value=Decimal("0")), \
                 mock.patch.object(hud, "_openai_usage_cost_since",
                                   return_value=(Decimal("0"), 200, False, 0)):
                ok, _ = hud.probe_openai_credits()
            blob = json.loads(cache.read_text())
        self.assertTrue(ok)
        self.assertEqual(blob["balance_seed_usd"], 50.0)
        self.assertEqual(blob["balance_seed_at"], 100)
        self.assertEqual(blob["balance"], 50.0)

    def test_openai_project_key_error_names_required_access(self):
        with tempfile.TemporaryDirectory() as tmp:
            cache = Path(tmp) / "codex.json"
            config = Path(tmp) / "credits.json"
            config.write_text(json.dumps({"openai": {
                "service": "s", "account": "a",
                "balance_seed_usd": 50, "balance_seed_at": 100,
            }}))
            error = urllib.error.HTTPError(hud.OPENAI_COSTS_URL, 403, "Forbidden", {}, None)
            with mock.patch.object(hud, "CODEX_CACHE", cache), \
                 mock.patch.object(hud, "CODEX_CREDITS_CONFIG", config), \
                 mock.patch.object(hud, "_keychain_password", return_value="secret"), \
                 mock.patch.object(hud.time, "time", return_value=200), \
                 mock.patch.object(hud.urllib.request, "urlopen", side_effect=error):
                ok, msg = hud.probe_openai_credits()
            blob = json.loads(cache.read_text())
        self.assertFalse(ok)
        self.assertEqual(msg, "admin costs access required")
        self.assertEqual(blob["error"], msg)


    def test_read_openrouter_renders_every_success_row(self):
        """Regression: a deindented append once dropped all but the LAST
        slot row (edit-tool fuzzy reindent). Every success row must render."""
        with tempfile.TemporaryDirectory() as tmp:
            cache = Path(tmp) / "openrouter.json"
            hud._atomic_private_json(cache, {
                "captured_at": time.time(), "balances": {"openrouter": 30.0},
                "rows": [
                    {"slot_id": "guy1", "label": "Guy1", "provider": "openrouter",
                     "source_id": "s1", "usage": 20.89, "day": "2026-09-05",
                     "day_start_usage": 20.84},
                    {"slot_id": "guy2", "label": "Guy2", "provider": "openrouter",
                     "source_id": "s2", "usage": 22.04, "day": "2026-09-05",
                     "day_start_usage": 21.93},
                ]})
            with mock.patch.object(hud, "OPENROUTER_CACHE", cache):
                panel = hud.read_openrouter()
        labels = [w["label"] for w in panel["windows"]]
        self.assertEqual(labels, ["OpenRouter", "Guy1", "Guy2"])
        self.assertEqual(panel["windows"][1]["right"], "$0.05 today")


if __name__ == "__main__":
    unittest.main()
