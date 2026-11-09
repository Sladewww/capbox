#!/usr/bin/env python3
"""`capbox mcp serve` 日常路径的固定默认值。

工具调用不能抬高这些默认值；只有显式 CLI 标志才能改用共享
工作区或 restricted 网络。本模块不导入其它依赖，便于测试与
argparse 在没有 CapBox 运行时上下文时加载。
"""

DEFAULT_PROFILE = 'untrusted'
DEFAULT_NET = 'none'
DEFAULT_WORKSPACE_MODE = 'isolated'
DEFAULT_MAX_TIMEOUT = 600
MAX_OUTPUT_BYTES = 8 * 1024 * 1024
ALLOWED_PROFILES = ('untrusted', 'strict')
ALLOWED_NET = ('none', 'restricted')
ALLOWED_WORKSPACE_MODES = ('isolated', 'shared')
