import json
import os
import selectors
import subprocess
import time
from pathlib import Path
ID = 'codex'
TITLE = 'Codex'
AUTO = True

def fetch(hud):
    binary = Path.home() / '.local/bin/codex'
    if not binary.is_file():
        raise RuntimeError('Install standalone Codex CLI and sign in')
    env = dict(os.environ, CODEX_HOME=str(hud.CODEX_HOME))
    process = subprocess.Popen([str(binary), 'app-server', '--stdio'], stdin=subprocess.PIPE,
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=env)
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)
    buffered = b''
    deadline = time.monotonic() + 25
    def send(message):
        process.stdin.write((json.dumps(message) + '\n').encode()); process.stdin.flush()
    def receive(identifier):
        nonlocal buffered
        while time.monotonic() < deadline:
            while b'\n' in buffered:
                line, buffered = buffered.split(b'\n', 1)
                message = json.loads(line)
                if message.get('id') == identifier:
                    if 'error' in message:
                        raise RuntimeError('Codex quota unavailable; check codex login status')
                    return message['result']
            if selector.select(min(1, max(0, deadline - time.monotonic()))):
                chunk = os.read(process.stdout.fileno(), 65536)
                if not chunk: raise RuntimeError('Codex quota connection closed')
                buffered += chunk
        raise RuntimeError('Codex quota request timed out')
    try:
        send({'id': 1, 'method': 'initialize', 'params': {'clientInfo': {'name': 'usage_hud', 'version': '2.0'}}})
        receive(1)
        send({'method': 'initialized', 'params': {}})
        send({'id': 2, 'method': 'account/rateLimits/read'})
        result = receive(2)
        buckets = result.get('rateLimitsByLimitId') or {}
        bucket = buckets.get('codex') if buckets else result.get('rateLimits')
        if not isinstance(bucket, dict): raise RuntimeError('Codex quota bucket missing')
        if bucket.get('limitId') not in (None, 'codex'): raise RuntimeError('Unexpected Codex quota bucket')
        windows = {}
        for name in ('primary', 'secondary'):
            window = bucket.get(name)
            if isinstance(window, dict) and window.get('usedPercent') is not None:
                windows[name] = {'used_percentage': window['usedPercent'],
                    'window_minutes': window.get('windowDurationMins'), 'resets_at': window.get('resetsAt')}
        if not windows: raise RuntimeError('Codex returned no quota windows')
        hud._atomic_private_json(hud.STATE_DIR / 'codex-quota.json', {
            'captured_at': time.time(), 'rate_limits': hud.preserve_quota(hud.STATE_DIR / 'codex-quota.json', windows), 'source': 'standalone-cli', 'error': None})
    finally:
        selector.close()
        process.terminate()
        try: process.wait(timeout=3)
        except subprocess.TimeoutExpired: process.kill(); process.wait()
        process.stdin.close(); process.stdout.close()

def read(hud):
    return hud.read_codex()
