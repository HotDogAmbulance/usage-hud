import json
import time
import urllib.request
import urllib.error
from datetime import datetime
ID = 'claude'
TITLE = 'Claude'
AUTO = True

def fetch(hud):
    token, error = hud.claude_oauth()
    if error: raise RuntimeError(error)
    request = urllib.request.Request('https://api.anthropic.com/api/oauth/usage', headers={
        'Authorization': 'Bearer ' + token, 'anthropic-beta': 'oauth-2025-04-20',
        'anthropic-version': '2023-06-01', 'Accept': 'application/json'})
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            data = json.load(response)
    except urllib.error.HTTPError as exc:
        if exc.code in (401, 403): raise RuntimeError('Claude needs sign-in: claude auth login') from None
        if exc.code == 429: raise RuntimeError('Claude usage endpoint throttled; retry later') from None
        raise RuntimeError('Claude usage HTTP ' + str(exc.code)) from None
    windows = {}
    for key in ('five_hour', 'seven_day', 'seven_day_sonnet', 'seven_day_opus'):
        window = data.get(key)
        if not isinstance(window, dict) or hud.as_float(window.get('utilization')) is None: continue
        reset = window.get('resets_at')
        if isinstance(reset, str): reset = datetime.fromisoformat(reset.replace('Z', '+00:00')).timestamp()
        windows[key] = {'used_percentage': float(window['utilization']), 'resets_at': reset}
    if not windows: raise RuntimeError('Claude usage response has no quota windows')
    updates = {'captured_at': time.time(), 'rate_limits': hud.preserve_quota(hud.CLAUDE_CACHE, windows), 'source': 'oauth-usage-get',
        'error': None, 'depleted': False, 'probe_blocked_until': None}
    if isinstance(data.get('extra_usage'), dict):
        updates['usage_credits'] = dict(data['extra_usage'], captured_at=time.time())
    hud._merge_private_json(hud.CLAUDE_CACHE, updates)

def read(hud):
    panel = hud.read_claude()
    if time.time() - panel.get('captured_at', 0) > 600:
        panel['note'] = 'Cached usage; refresh needed'
        for window in panel['windows']: window['stale'] = True
    return panel
