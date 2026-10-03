"""Provider adapters: no UI, no credentials in returned snapshots."""
from . import claude, codex, openrouter
PLUGINS = (claude, codex, openrouter)
