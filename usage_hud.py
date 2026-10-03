#!/usr/bin/env python3
"""Usage HUD data utilities and Claude Code compatibility hooks. No window UI."""
from __future__ import annotations
import argparse
import json
import os
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from decimal import Decimal, InvalidOperation
from pathlib import Path
HOME = Path.home()
CODEX_HOME = Path(os.environ.get('CODEX_HOME', HOME / '.codex'))
STATE_DIR = Path(os.environ.get('USAGE_HUD_HOME', HOME / '.usage-hud'))
CLAUDE_CACHE = STATE_DIR / 'claude.json'
CODEX_CACHE = STATE_DIR / 'codex.json'
CODEX_CREDITS_CONFIG = STATE_DIR / 'credits.json'
OPENAI_COSTS_URL = 'https://api.openai.com/v1/organization/costs'
OPENAI_USAGE_URL = 'https://api.openai.com/v1/organization/usage/completions'
OPENAI_PRICING_REVISION = 'gpt-6-astra-2026-09-08'
OPENAI_MODEL_PRICES = {'gpt-6-astra': {'input_uncached': Decimal('10'), 'input_cached': Decimal('1'), 'input_cache_write': Decimal('12.5'), 'output': Decimal('50')}}
OPENAI_LONG_CONTEXT_THRESHOLD = 272000
STALE_AFTER = 6 * 3600
KEYCHAIN_ITEM = 'Claude Code-credentials'
OPENROUTER_CACHE = STATE_DIR / 'openrouter.json'
OPENROUTER_SERVICE = os.environ.get('USAGE_HUD_OPENROUTER_SERVICE', '')
OPENROUTER_ACCOUNTS = [tuple(pair.split(':', 1)) for pair in os.environ.get('USAGE_HUD_OPENROUTER_KEYS', '').split(',') if ':' in pair]
PROVIDER_SLOTS_RAW = os.environ.get('USAGE_HUD_PROVIDER_SLOTS', '')
PROVIDER_CONFIG = STATE_DIR / 'providers.json'
OPENROUTER_KEY_URL = 'https://openrouter.ai/api/v1/key'
OPENROUTER_CREDITS_URL = 'https://openrouter.ai/api/v1/credits'
OPENAI_CREDITS_FRESH = 600
OPENAI_ADMIN_TOKEN_STATE = {'selector': None, 'token': None}
_LABELS = {'five_hour': '5h', 'seven_day': '7d', 'primary': '5h', 'secondary': '7d'}
_WINDOW_SECONDS = {'five_hour': 5 * 3600, 'seven_day': 7 * 86400, 'primary': 5 * 3600, 'secondary': 7 * 86400}

def label_for(key: str, window_minutes=None) -> str:
    if window_minutes:
        m = int(window_minutes)
        if m % 10080 == 0:
            return f'{m // 10080 * 7}d'
        if m % 1440 == 0:
            return f'{m // 1440}d'
        if m % 60 == 0:
            return f'{m // 60}h'
        return f'{m}m'
    if key in _LABELS:
        return _LABELS[key]
    for (prefix, short) in _LABELS.items():
        if key.startswith(prefix):
            rest = key[len(prefix):].strip('_').replace('_', ' ')
            return f'{short} {rest}'.strip()
    return key.replace('_', ' ')[:8]

def window_seconds(key, window_minutes):
    mins = as_float(window_minutes)
    if mins:
        return mins * 60
    return _WINDOW_SECONDS.get(key)

def fmt_delta(seconds) -> str:
    if seconds is None:
        return ''
    seconds = int(seconds)
    if seconds <= 0:
        return 'now'
    (d, rem) = divmod(seconds, 86400)
    (h, rem) = divmod(rem, 3600)
    m = rem // 60
    if d:
        return f'{d}d{h}h'
    if h:
        return f'{h}h{m:02d}m'
    return f'{m}m'

def as_float(x):
    try:
        return float(x)
    except (TypeError, ValueError):
        return None

def _private_dir(path: Path):
    path.mkdir(parents=True, exist_ok=True, mode=448)
    try:
        path.chmod(448)
    except OSError:
        pass

def _atomic_private_json(path: Path, payload):
    _private_dir(path.parent)
    tmp = path.with_name(f'.{path.name}.{os.getpid()}.{threading.get_ident()}.tmp')
    try:
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 384)
        with os.fdopen(fd, 'w', encoding='utf-8') as fh:
            json.dump(payload, fh)
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp, path)
        path.chmod(384)
    finally:
        try:
            tmp.unlink()
        except FileNotFoundError:
            pass

def _merge_private_json(path: Path, updates: dict):
    try:
        merged = json.loads(path.read_text(encoding='utf-8'))
        if not isinstance(merged, dict):
            merged = {}
    except Exception:
        merged = {}
    merged.update(updates)
    _atomic_private_json(path, merged)

def find_key(obj, name):
    if isinstance(obj, dict):
        if name in obj:
            return obj[name]
        for v in obj.values():
            found = find_key(v, name)
            if found is not None:
                return found
    elif isinstance(obj, list):
        for v in obj:
            found = find_key(v, name)
            if found is not None:
                return found
    return None

def parse_windows(rate_limits: dict, captured_at: float):
    out = []
    if not isinstance(rate_limits, dict):
        return out
    for (key, val) in rate_limits.items():
        if not isinstance(val, dict):
            continue
        pct = as_float(val.get('used_percentage'))
        if pct is None:
            pct = as_float(val.get('used_percent'))
        if pct is None:
            continue
        resets_at = as_float(val.get('resets_at'))
        if resets_at is None:
            rin = as_float(val.get('resets_in_seconds'))
            if rin is not None:
                resets_at = captured_at + rin
        out.append({'label': label_for(key, val.get('window_minutes')), 'seconds': window_seconds(key, val.get('window_minutes')), 'pct': max(0.0, min(100.0, pct)), 'resets_at': resets_at, 'expired': bool(resets_at and resets_at < time.time()), 'stale': bool(val.get('stale')) or time.time() - (as_float(val.get('captured_at')) or captured_at) > 600})
    out.sort(key=lambda w: (w['seconds'] is None, w['seconds'] if w['seconds'] is not None else 0.0, w['resets_at'] or float('inf')))
    return out

def read_claude():
    panel = {'name': 'CLAUDE', 'windows': [], 'note': ''}
    try:
        blob = json.loads(CLAUDE_CACHE.read_text(encoding='utf-8'))
    except FileNotFoundError:
        panel['note'] = 'Refresh Claude from its menu'
        return panel
    except Exception as exc:
        panel['note'] = f'cache unreadable ({exc.__class__.__name__})'
        return panel
    captured = as_float(blob.get('captured_at')) or time.time()
    panel['windows'] = parse_windows(blob.get('rate_limits') or {}, captured)
    panel['captured_at'] = captured
    if not panel['windows']:
        panel['note'] = 'No quota yet; refresh Claude'
    elif time.time() - captured > STALE_AFTER:
        for w in panel['windows']:
            w['stale'] = True
    credits = _claude_credits_row(blob.get('usage_credits'))
    if credits:
        panel['windows'].append(credits)
    return panel

def _claude_credits_row(credits):
    if not isinstance(credits, dict) or not credits.get('is_enabled'):
        return None
    limit = as_float(credits.get('monthly_limit'))
    used = as_float(credits.get('used_credits'))
    if not limit or used is None:
        return None
    scale = 100.0 if limit >= 500 else 1.0
    pct = as_float(credits.get('utilization'))
    if pct is None:
        pct = used / limit * 100.0
    stale = time.time() - (as_float(credits.get('captured_at')) or 0) > STALE_AFTER
    return {'label': 'credits', 'pct': None, 'right': f'${used / scale:,.2f} of ${limit / scale:,.2f} · {pct:.0f}%', 'stale': stale}

def claude_statusline():
    try:
        payload = json.load(sys.stdin)
    except Exception:
        print('')
        return 0
    ctx = as_float(find_key(payload.get('context_window') or {}, 'used_percentage'))
    updates = {}
    if isinstance(payload.get('rate_limits'), dict):
        updates['captured_at'] = time.time()
        updates['rate_limits'] = payload['rate_limits']
    if ctx is not None:
        updates['context_pct'] = ctx
        updates['context_captured_at'] = time.time()
    if updates:
        _merge_private_json(CLAUDE_CACHE, updates)
    model = payload.get('model')
    model = model.get('display_name') if isinstance(model, dict) else model or ''
    bits = [b for b in [model, f'ctx {ctx:.0f}%' if ctx is not None else ''] if b]
    for w in parse_windows(payload.get('rate_limits') or {}, time.time()):
        left = fmt_delta(w['resets_at'] - time.time() if w['resets_at'] else None)
        bits.append(f"{w['label']} {w['pct']:.0f}%" + (f' ({left})' if left else ''))
    print(' | '.join(bits))
    return 0

def claude_oauth():
    import subprocess
    try:
        raw = subprocess.run(['security', 'find-generic-password', '-s', KEYCHAIN_ITEM, '-w'], capture_output=True, text=True, timeout=10).stdout.strip()
    except Exception:
        return (None, 'no macOS keychain access')
    if not raw:
        return (None, 'no Claude Code credentials in keychain')
    try:
        blob = json.loads(raw)
        oauth = blob.get('claudeAiOauth') or blob
        (tok, exp) = (oauth.get('accessToken'), oauth.get('expiresAt'))
    except Exception:
        return (None, 'keychain credential unreadable')
    if not tok:
        return (None, 'keychain credential has no token')
    if not (exp and exp / 1000 < time.time()):
        return (tok, None)
    return (None, 'Claude authentication expired - open Claude Code to refresh it')

def read_codex():
    panel = {'name': 'CODEX', 'windows': [], 'note': ''}
    try:
        blob = json.loads((STATE_DIR / 'codex-quota.json').read_text())
        captured = float(blob.get('captured_at', 0))
        panel['windows'] = parse_windows(blob.get('rate_limits', {}), captured)
        panel['captured_at'] = captured
        if time.time() - captured > 600:
            panel['note'] = 'Cached quota; refresh needed'
            for w in panel['windows']:
                w['stale'] = True
    except (OSError, ValueError, TypeError):
        panel['note'] = 'Refresh Codex to read quota'
    credits = _codex_credits_row()
    if credits:
        panel['windows'].append(credits)
    return panel

def _keychain_password(service: str, account: str):
    import subprocess
    try:
        raw = subprocess.run(['security', 'find-generic-password', '-s', service, '-a', account, '-w'], capture_output=True, text=True, timeout=120).stdout.strip()
    except Exception:
        return None
    return raw or None

def _provider_slots():
    raw = PROVIDER_SLOTS_RAW
    if not raw:
        try:
            raw = PROVIDER_CONFIG.read_text(encoding='utf-8')
        except FileNotFoundError:
            pass
        except OSError as exc:
            return ([], f'provider slot config unreadable ({exc.__class__.__name__})')
    if raw:
        try:
            slots = json.loads(raw)
            if not isinstance(slots, list):
                raise ValueError('slots must be a list')
            seen = set()
            clean = []
            for slot in slots:
                slot_id = slot.get('id') if isinstance(slot, dict) else None
                label = slot.get('label') if isinstance(slot, dict) else None
                sources = slot.get('sources') if isinstance(slot, dict) else None
                if not isinstance(slot_id, str) or not slot_id or slot_id in seen or (not isinstance(label, str)) or (not label) or (not isinstance(sources, list)) or (not sources):
                    raise ValueError('invalid or duplicate slot')
                if not all((isinstance(s, dict) and isinstance(s.get('provider'), str) for s in sources)):
                    raise ValueError('invalid source')
                seen.add(slot_id)
                clean.append({'id': slot_id, 'label': label, 'sources': sources})
            return (clean, None)
        except Exception as exc:
            return ([], f'provider slot config invalid ({exc.__class__.__name__})')
    slots = []
    for (index, (label, account)) in enumerate(OPENROUTER_ACCOUNTS, 1):
        slots.append({'id': f'legacy-{index}', 'label': label, 'sources': [{'provider': 'openrouter', 'service': OPENROUTER_SERVICE, 'account': account}]})
    return (slots, None)

def _source_id(source: dict):
    provider = source.get('provider', 'unknown')
    if provider == 'openrouter':
        return f"openrouter:{source.get('service', '')}:{source.get('account', '')}"
    return f"{provider}:{source.get('id', 'default')}"

def _provider_get(url: str, key: str):
    req = urllib.request.Request(url, headers={'Authorization': f'Bearer {key}'})
    with urllib.request.urlopen(req, timeout=15) as resp:
        raw = resp.read(1024 * 1024 + 1)
        if len(raw) > 1024 * 1024:
            raise ValueError('provider response too large')
        return json.loads(raw.decode())

def _probe_openrouter_source(source: dict):
    (service, account) = (source.get('service'), source.get('account'))
    if not isinstance(service, str) or not service or (not isinstance(account, str)) or (not account):
        raise ValueError('openrouter source requires service and account')
    tok = _keychain_password(service, account)
    if not tok:
        raise PermissionError('keychain locked')
    data = _provider_get(OPENROUTER_KEY_URL, tok).get('data', {})
    usage = as_float(data.get('usage'))
    if usage is None:
        raise ValueError('key response missing usage')
    result = {'usage': max(0.0, usage), 'limit': as_float(data.get('limit'))}
    try:
        cdata = _provider_get(OPENROUTER_CREDITS_URL, tok).get('data', {})
        (total, used) = (as_float(cdata.get('total_credits')), as_float(cdata.get('total_usage')))
        if total is not None and used is not None:
            result['credits_remaining'] = total - used
    except Exception:
        pass
    return result

def _local_today():
    import datetime
    return datetime.date.today().isoformat()

def probe_openrouter():
    (slots, config_error) = _provider_slots()
    if config_error:
        return (False, config_error)
    (prev, prev_blob) = ({}, {})
    try:
        prev_blob = json.loads(OPENROUTER_CACHE.read_text(encoding='utf-8'))
        for row in prev_blob.get('rows', []):
            key = row.get('slot_id') or row.get('label')
            if key:
                prev[key] = row
    except Exception:
        pass
    today = _local_today()
    (rows, balances, successes) = ([], {}, 0)
    for slot in slots:
        old = prev.get(slot['id']) or prev.get(slot['label']) or {}
        (errors, winner) = ([], None)
        for source in slot['sources']:
            provider = source.get('provider')
            entry = PROVIDERS.get(provider)
            if entry is None:
                errors.append(f'{provider}: unsupported')
                continue
            try:
                result = entry['probe'](source)
                winner = (source, result)
                break
            except Exception as exc:
                detail = str(exc).strip()[:80]
                errors.append(f'{provider}: {detail or exc.__class__.__name__}')
        if winner:
            (source, result) = winner
            source_id = _source_id(source)
            usage = result['usage']
            same_pipe = old.get('source_id') == source_id
            if same_pipe and old.get('day') == today and ('day_start_usage' in old):
                day_start = old['day_start_usage']
            else:
                day_start = usage
            row = {'slot_id': slot['id'], 'label': slot['label'], 'provider': source['provider'], 'source_id': source_id, 'usage': usage, 'limit': result.get('limit'), 'day': today, 'day_start_usage': day_start}
            rows.append(row)
            successes += 1
            if result.get('credits_remaining') is not None:
                balances.setdefault(source['provider'], result['credits_remaining'])
        else:
            carry = {k: old[k] for k in ('provider', 'source_id', 'usage', 'limit', 'day', 'day_start_usage') if k in old}
            rows.append({'slot_id': slot['id'], 'label': slot['label'], 'error': '; '.join(errors) or 'no sources', 'stale': True, **carry})
    checked_at = time.time()
    _atomic_private_json(OPENROUTER_CACHE, {'captured_at': checked_at if successes else prev_blob.get('captured_at', 0), 'checked_at': checked_at, 'balances': balances, 'rows': rows})
    failures = [f"{r['label']}: {r['error']}" for r in rows if r.get('error')]
    return (bool(successes), '; '.join(failures) or None)

def read_openrouter():
    panel = {'name': 'AGENT USAGE', 'windows': [], 'note': ''}
    try:
        blob = json.loads(OPENROUTER_CACHE.read_text(encoding='utf-8'))
    except FileNotFoundError:
        panel['note'] = 'Refresh OpenRouter from its menu'
        return panel
    except Exception as exc:
        panel['note'] = f'cache unreadable ({exc.__class__.__name__})'
        return panel
    captured = as_float(blob.get('captured_at')) or time.time()
    panel['captured_at'] = captured
    balances = blob.get('balances') or {}
    if not balances and blob.get('credits_remaining') is not None:
        balances = {'openrouter': blob['credits_remaining']}
    for (provider, remaining) in balances.items():
        label = PROVIDERS.get(provider, {}).get('label', provider)
        panel['windows'].append({'label': label, 'pct': None, 'right': f'${remaining:,.2f} left'})
    for row in blob.get('rows', []):
        if row.get('error'):
            right = f"stale; {row['error']}" if 'usage' in row else row['error']
            panel['windows'].append({'label': row['label'], 'pct': None, 'right': f'({right[:34]})', 'stale': True})
            continue
        usage = row.get('usage') or 0.0
        day_start = row.get('day_start_usage')
        used_today = max(0.0, usage - day_start) if day_start is not None else None
        right = f'${used_today:,.2f} today' if used_today is not None else f'${usage:,.2f} total; baseline pending'
        panel['windows'].append({'label': row['label'], 'pct': None, 'right': right})
    failures = [r for r in blob.get('rows', []) if r.get('error')]
    if failures:
        panel['note'] = f'last check had {len(failures)} failed slot(s)'
    elif time.time() - captured > STALE_AFTER:
        panel['note'] = f'stale, last seen {fmt_delta(time.time() - captured)} ago'
        for w in panel['windows']:
            w['stale'] = True
    return panel

def _openai_credit_source():
    try:
        cfg = json.loads(CODEX_CREDITS_CONFIG.read_text(encoding='utf-8'))
    except Exception:
        return None
    src = cfg.get('openai') if isinstance(cfg, dict) else None
    if isinstance(src, dict) and isinstance(src.get('service'), str) and src['service'] and isinstance(src.get('account'), str) and src['account']:
        return src
    return None

def _openai_balance_seed(src: dict):
    balance = as_float(src.get('balance_seed_usd'))
    started = as_float(src.get('balance_seed_at'))
    if balance is None or started is None:
        try:
            cached = json.loads(CODEX_CACHE.read_text(encoding='utf-8'))
        except Exception:
            cached = {}
        balance = as_float(cached.get('balance_seed_usd', cached.get('balance')))
        started = as_float(cached.get('balance_seed_at', cached.get('captured_at')))
    if balance is None or balance < 0 or started is None or (started <= 0):
        return None
    return (balance, int(started))

def _openai_admin_token(src: dict):
    selector = (src['service'], src['account'])
    if OPENAI_ADMIN_TOKEN_STATE['selector'] == selector and OPENAI_ADMIN_TOKEN_STATE['token']:
        return OPENAI_ADMIN_TOKEN_STATE['token']
    token = _keychain_password(*selector)
    if token:
        OPENAI_ADMIN_TOKEN_STATE.update(selector=selector, token=token)
    return token

def _forget_openai_admin_token():
    OPENAI_ADMIN_TOKEN_STATE.update(selector=None, token=None)

def _openai_costs_since(token: str, start_time: int, end_time: int):
    total = Decimal('0')
    page = None
    seen_pages = set()
    for _ in range(1000):
        query = {'start_time': start_time, 'end_time': end_time, 'bucket_width': '1d', 'limit': 180}
        if page:
            query['page'] = page
        url = f'{OPENAI_COSTS_URL}?{urllib.parse.urlencode(query)}'
        req = urllib.request.Request(url, headers={'Authorization': f'Bearer {token}', 'Content-Type': 'application/json'})
        with urllib.request.urlopen(req, timeout=20) as resp:
            raw = resp.read(4 * 1024 * 1024 + 1)
        if len(raw) > 4 * 1024 * 1024:
            raise ValueError('cost response too large')
        payload = json.loads(raw.decode())
        buckets = payload.get('data') if isinstance(payload, dict) else None
        if not isinstance(buckets, list):
            raise ValueError('cost response missing data')
        for bucket in buckets:
            results = bucket.get('results') if isinstance(bucket, dict) else None
            if not isinstance(results, list):
                raise ValueError('cost bucket missing results')
            for result in results:
                amount = result.get('amount') if isinstance(result, dict) else None
                currency = amount.get('currency') if isinstance(amount, dict) else None
                if not isinstance(currency, str) or currency.lower() != 'usd':
                    raise ValueError('cost response currency is not USD')
                try:
                    value = Decimal(str(amount.get('value')))
                except (InvalidOperation, TypeError, ValueError):
                    raise ValueError('cost response has invalid amount') from None
                if not value.is_finite():
                    raise ValueError('cost response has invalid amount')
                total += value
        if not payload.get('has_more'):
            return total
        next_page = payload.get('next_page')
        if not isinstance(next_page, str) or not next_page or next_page in seen_pages:
            raise ValueError('cost pagination invalid')
        seen_pages.add(next_page)
        page = next_page
    raise ValueError('too many cost pages')

def _nonnegative_int(value, field: str):
    if isinstance(value, bool):
        raise ValueError(f'usage response has invalid {field}')
    try:
        number = int(value)
    except (TypeError, ValueError, OverflowError):
        raise ValueError(f'usage response has invalid {field}') from None
    if number < 0 or str(value).strip() not in (str(number), f'{number}.0'):
        raise ValueError(f'usage response has invalid {field}')
    return number

def _openai_usage_result_cost(result: dict):
    if not isinstance(result, dict):
        raise ValueError('usage result is not an object')
    model = result.get('model')
    prices = OPENAI_MODEL_PRICES.get(model)
    if prices is None:
        raise ValueError(f'unsupported priced model: {model!r}')
    batch = result.get('batch')
    if batch not in (None, True, False):
        raise ValueError('usage response has invalid batch')
    tier = result.get('service_tier')
    if tier in ('flex', 'flex-tier') or batch is True:
        tier_multiplier = Decimal('0.5')
    elif tier in (None, 'default', 'standard', 'auto'):
        tier_multiplier = Decimal('1')
    else:
        raise ValueError(f'unsupported service tier: {tier!r}')
    cached = _nonnegative_int(result.get('input_cached_tokens', 0), 'input_cached_tokens')
    cache_write = _nonnegative_int(result.get('input_cache_write_tokens', 0), 'input_cache_write_tokens')
    uncached_raw = result.get('input_uncached_tokens')
    total_input_raw = result.get('input_tokens')
    if uncached_raw is None:
        total_input = _nonnegative_int(total_input_raw, 'input_tokens')
        uncached = total_input - cached - cache_write
        if uncached < 0:
            raise ValueError('usage input token components exceed total')
    else:
        uncached = _nonnegative_int(uncached_raw, 'input_uncached_tokens')
        total_input = _nonnegative_int(total_input_raw, 'input_tokens') if total_input_raw is not None else uncached + cached + cache_write
    output = _nonnegative_int(result.get('output_tokens', 0), 'output_tokens')
    requests = _nonnegative_int(result.get('num_model_requests', 0), 'num_model_requests')
    if requests == 0 and (total_input or output):
        raise ValueError('usage tokens reported without a request')
    long_context = total_input > OPENAI_LONG_CONTEXT_THRESHOLD
    conservative = long_context and requests > 1
    input_multiplier = Decimal('2') if long_context else Decimal('1')
    output_multiplier = Decimal('1.5') if long_context else Decimal('1')
    million = Decimal('1000000')
    cost = (Decimal(uncached) * prices['input_uncached'] * input_multiplier + Decimal(cached) * prices['input_cached'] * input_multiplier + Decimal(cache_write) * prices['input_cache_write'] * input_multiplier + Decimal(output) * prices['output'] * output_multiplier) * tier_multiplier / million
    return (cost, conservative, requests)

def _openai_usage_cost_since(token: str, start_time: int, end_time: int):
    total = Decimal('0')
    page = None
    seen_pages = set()
    coverage_end = start_time
    conservative = False
    request_count = 0
    for _ in range(1000):
        query = {'start_time': start_time, 'end_time': end_time, 'bucket_width': '1m', 'limit': 1440, 'group_by': ['model', 'batch', 'service_tier']}
        if page:
            query['page'] = page
        url = f'{OPENAI_USAGE_URL}?{urllib.parse.urlencode(query, doseq=True)}'
        req = urllib.request.Request(url, headers={'Authorization': f'Bearer {token}', 'Content-Type': 'application/json'})
        with urllib.request.urlopen(req, timeout=20) as resp:
            raw = resp.read(8 * 1024 * 1024 + 1)
        if len(raw) > 8 * 1024 * 1024:
            raise ValueError('usage response too large')
        payload = json.loads(raw.decode())
        buckets = payload.get('data') if isinstance(payload, dict) else None
        if not isinstance(buckets, list):
            raise ValueError('usage response missing data')
        for bucket in buckets:
            if not isinstance(bucket, dict):
                raise ValueError('usage bucket is not an object')
            bucket_end = _nonnegative_int(bucket.get('end_time'), 'end_time')
            coverage_end = max(coverage_end, bucket_end)
            results = bucket.get('results')
            if not isinstance(results, list):
                raise ValueError('usage bucket missing results')
            for result in results:
                (cost, upper_bound, requests) = _openai_usage_result_cost(result)
                total += cost
                conservative = conservative or upper_bound
                request_count += requests
        if not payload.get('has_more'):
            return (total, coverage_end, conservative, request_count)
        next_page = payload.get('next_page')
        if not isinstance(next_page, str) or not next_page or next_page in seen_pages:
            raise ValueError('usage pagination invalid')
        seen_pages.add(next_page)
        page = next_page
    raise ValueError('too many usage pages')

def probe_openai_credits():
    src = _openai_credit_source()
    if not src:
        return (False, 'no credits.json')
    seed = _openai_balance_seed(src)
    if not seed:
        msg = 'missing balance seed'
        _merge_private_json(CODEX_CACHE, {'error': msg})
        return (False, msg)
    (seed_balance, seed_at) = seed
    now = int(time.time())
    if seed_at >= now:
        msg = 'balance seed is not in the past'
        _merge_private_json(CODEX_CACHE, {'error': msg})
        return (False, msg)
    tok = _openai_admin_token(src)
    if not tok:
        _merge_private_json(CODEX_CACHE, {'error': 'keychain read failed'})
        return (False, 'keychain read failed')
    try:
        settled_spend = _openai_costs_since(tok, seed_at, now)
        (usage_spend, coverage_end, conservative, requests) = _openai_usage_cost_since(tok, seed_at, now)
    except urllib.error.HTTPError as exc:
        if exc.code in (401, 403):
            _forget_openai_admin_token()
        msg = 'admin costs access required' if exc.code in (401, 403) else f'HTTP {exc.code}'
        _merge_private_json(CODEX_CACHE, {'error': msg})
        return (False, msg)
    except Exception as exc:
        msg = f'err ({exc.__class__.__name__})'
        _merge_private_json(CODEX_CACHE, {'error': msg})
        return (False, msg)
    spent = max(settled_spend, usage_spend)
    balance = Decimal(str(seed_balance)) - spent
    _merge_private_json(CODEX_CACHE, {'captured_at': time.time(), 'balance': float(balance), 'currency': 'USD', 'manual': False, 'estimated': True, 'live_estimate': True, 'balance_seed_usd': seed_balance, 'balance_seed_at': seed_at, 'spent_since_seed': float(spent), 'settled_spend': float(settled_spend), 'usage_estimated_spend': float(usage_spend), 'usage_coverage_end': coverage_end, 'usage_request_count': requests, 'conservative_long_context': conservative, 'pricing_revision': OPENAI_PRICING_REVISION, 'source': 'organization_costs_plus_server_usage', 'error': None})
    return (True, '')

def _codex_credits_row():
    try:
        blob = json.loads(CODEX_CACHE.read_text(encoding='utf-8'))
    except Exception:
        return None
    balance = as_float(blob.get('balance'))
    if balance is None:
        return None
    if blob.get('error'):
        right = f"(stale; {blob['error']})"[:23]
        stale = True
    else:
        if blob.get('manual'):
            right = f'${balance:,.2f} left  (manual)'[:23]
        elif blob.get('live_estimate'):
            right = f'${balance:,.2f}  live est.'[:23]
        else:
            right = (f'${balance:,.2f} left' + ('  (est.)' if blob.get('estimated') else ''))[:23]
        stale_after = OPENAI_CREDITS_FRESH if blob.get('live_estimate') else STALE_AFTER
        stale = time.time() - (as_float(blob.get('captured_at')) or 0) > stale_after
    return {'label': 'credits', 'pct': None, 'right': right, 'stale': stale}
PROVIDERS = {'openrouter': {'probe': _probe_openrouter_source, 'label': 'OpenRouter'}}

def preserve_quota(cache, windows):
    now = time.time()
    try:
        blob = json.loads(cache.read_text())
        old = blob.get("rate_limits", {})
        captured = blob.get("captured_at", 0)
    except (OSError, ValueError, AttributeError):
        old, captured = {}, 0
    result = {key: dict(value, stale=True, captured_at=value.get("captured_at", captured))
              for key, value in old.items() if isinstance(value, dict)}
    result.update({key: dict(value, stale=False, captured_at=now) for key, value in windows.items()})
    return result

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--claude-statusline', action='store_true')
    parser.add_argument('--probe-if-stale', action='store_true')
    parser.add_argument('--probe-claude', action='store_true')
    parser.add_argument('--probe-openrouter', action='store_true')
    parser.add_argument('--probe-openai-credits', action='store_true')
    parser.add_argument('--json', action='store_true')
    parser.add_argument('--once', action='store_true')
    args = parser.parse_args()
    if args.claude_statusline:
        return claude_statusline()
    if args.probe_openai_credits:
        (ok, error) = probe_openai_credits()
        print('ok' if ok else error)
        return 0 if ok else 1
    from collector import panels
    refresh = 'claude' if args.probe_claude else 'openrouter' if args.probe_openrouter else None
    if args.probe_if_stale:
        try:
            captured = json.loads(CLAUDE_CACHE.read_text()).get('captured_at', 0)
        except (OSError, ValueError):
            captured = 0
        if time.time() - captured < 300:
            return 0
        panels('claude')
        return 0
    print(json.dumps(panels(refresh), indent=2))
    return 0
if __name__ == '__main__':
    sys.exit(main())
