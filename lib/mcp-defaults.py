#!/usr/bin/env python3
"""Fixed daily-path defaults for `capbox mcp serve`.

Tool calls cannot raise these; only explicit CLI flags may opt into shared
workspace or restricted network. Keep this module free of imports so tests and
argparse can load it without a CapBox runtime context.
"""

DEFAULT_PROFILE = 'untrusted'
DEFAULT_NET = 'none'
DEFAULT_WORKSPACE_MODE = 'isolated'
DEFAULT_MAX_TIMEOUT = 600
MAX_OUTPUT_BYTES = 8 * 1024 * 1024
ALLOWED_PROFILES = ('untrusted', 'strict')
ALLOWED_NET = ('none', 'restricted')
ALLOWED_WORKSPACE_MODES = ('isolated', 'shared')
