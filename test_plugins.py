import json
import tempfile
import time
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch, MagicMock
import usage_hud as hud
import collector
from plugins import claude, codex

class AdapterTests(unittest.TestCase):
    def test_claude_get_preserves_context_and_credits_and_never_sends_message(self):
        with tempfile.TemporaryDirectory() as directory:
            cache = Path(directory) / 'claude.json'
            cache.write_text(json.dumps({'context_pct': 42, 'usage_credits': {'is_enabled': True}}))
            response = MagicMock()
            response.__enter__.return_value = response
            response.read.return_value = json.dumps({'five_hour': {'utilization': 12, 'resets_at': '2099-01-01T00:00:00Z'}}).encode()
            with patch.object(hud, 'CLAUDE_CACHE', cache), patch.object(hud, 'claude_oauth', return_value=('secret', None)), patch.object(claude.urllib.request, 'urlopen', return_value=response) as request:
                claude.fetch(hud)
            self.assertEqual(request.call_args.args[0].get_method(), 'GET')
            self.assertIsNone(request.call_args.args[0].data)
            saved = json.loads(cache.read_text())
            self.assertEqual(saved['context_pct'], 42)
            self.assertEqual(saved['rate_limits']['five_hour']['used_percentage'], 12)
            self.assertIn('usage_credits', saved)
            self.assertNotIn('secret', cache.read_text())

    def test_provider_failure_does_not_stop_other_provider_or_erase_cache(self):
        with tempfile.TemporaryDirectory() as directory:
            failure = SimpleNamespace(ID='broken', TITLE='Broken', AUTO=True,
                fetch=lambda _: (_ for _ in ()).throw(RuntimeError('offline')),
                read=lambda _: {'windows': [{'pct': 30}], 'note': ''})
            success = SimpleNamespace(ID='good', TITLE='Good', AUTO=True,
                fetch=lambda _: None, read=lambda _: {'windows': [{'pct': 50}], 'note': ''})
            with patch.object(hud, 'STATE_DIR', Path(directory)), patch.object(collector, 'PLUGINS', (failure, success)):
                panels = collector.panels('automatic')
            self.assertTrue(panels[0]['windows'][0]['stale'])
            self.assertEqual(panels[1]['windows'][0]['pct'], 50)
            self.assertEqual(panels[1]['note'], '')

    def test_cache_read_never_fetches_credentials(self):
        with patch.object(hud, 'claude_oauth') as credentials, patch.object(codex, 'fetch') as fetch:
            collector.panels()
            credentials.assert_not_called(); fetch.assert_not_called()

    def test_codex_reads_only_normalized_quota_cache(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'codex-quota.json').write_text(json.dumps({'captured_at': time.time(), 'rate_limits': {
                'primary': {'used_percentage': 41, 'window_minutes': 300, 'resets_at': time.time()+300}}}))
            with patch.object(hud, 'STATE_DIR', root):
                panel = hud.read_codex()
            self.assertEqual(panel['windows'][0]['pct'], 41)
            self.assertFalse(hasattr(hud, "newest_codex_logs"))

    def test_partial_quota_keeps_previous_week_and_marks_it_cached(self):
        with tempfile.TemporaryDirectory() as directory:
            cache = Path(directory) / "quota.json"
            cache.write_text(json.dumps({"captured_at": 123, "rate_limits": {
                "seven_day": {"used_percentage": 37, "resets_at": 9999999999}}}))
            windows = hud.preserve_quota(cache, {"five_hour": {"used_percentage": 12}})
            self.assertEqual(windows["seven_day"]["used_percentage"], 37)
            self.assertTrue(windows["seven_day"]["stale"])
            self.assertFalse(windows["five_hour"]["stale"])

    def test_missing_five_hour_is_not_made_fresh_by_weekly_response(self):
        with tempfile.TemporaryDirectory() as directory:
            cache = Path(directory) / "quota.json"
            cache.write_text(json.dumps({"captured_at": time.time(), "rate_limits": {
                "primary": {"used_percentage": 50, "window_minutes": 300}}}))
            windows = hud.preserve_quota(cache, {"secondary": {"used_percentage": 20, "window_minutes": 10080}})
            rows = hud.parse_windows(windows, time.time())
            self.assertTrue(rows[0]["stale"])
            self.assertFalse(rows[1]["stale"])

if __name__ == '__main__': unittest.main()
