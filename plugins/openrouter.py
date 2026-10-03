ID = 'openrouter'
TITLE = 'OpenRouter'
AUTO = False  # Preserve manual Keychain access.
def fetch(hud):
    ok, error = hud.probe_openrouter()
    if not ok: raise RuntimeError(error or 'OpenRouter unavailable')
def read(hud):
    return hud.read_openrouter()
