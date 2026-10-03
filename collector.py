"""Isolated provider refresh and cache snapshots for the menu bar."""
import argparse
import json
import time
import usage_hud as hud
from plugins import PLUGINS

def panels(refresh=None):
    results = []
    for plugin in PLUGINS:
        error_file = hud.STATE_DIR / (plugin.ID + '-status.json')
        try:
            if refresh == plugin.ID or (refresh == 'automatic' and plugin.AUTO):
                plugin.fetch(hud)
                hud._atomic_private_json(error_file, {'error': None, 'checked_at': time.time()})
        except Exception as exc:
            # Provider errors cannot terminate the other providers. Do not log raw HTTP bodies.
            message = str(exc) if isinstance(exc, RuntimeError) else type(exc).__name__
            hud._atomic_private_json(error_file, {'error': message, 'checked_at': time.time()})
        try:
            panel = plugin.read(hud)
            status = json.loads(error_file.read_text()) if error_file.exists() else {}
            if status.get('error'):
                panel['note'] = status['error']
                for window in panel['windows']: window['stale'] = True
            panel.update(id=plugin.ID, name=plugin.TITLE)
            results.append(panel)
        except Exception:
            results.append({'id': plugin.ID, 'name': plugin.TITLE, 'windows': [], 'note': 'Usage unavailable'})
    return results

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--refresh', choices=['automatic', 'openai-credits'] + [p.ID for p in PLUGINS])
    args = parser.parse_args()
    if args.refresh == "openai-credits":
        hud.probe_openai_credits()
    print(json.dumps(panels(args.refresh)))
