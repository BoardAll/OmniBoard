"""Whiteboard AI Gateway（Wave 2.9）。

目录结构对齐《Flutter + C++ 工程结构设计》§7：
    src/app.py                  FastAPI 应用装配
    src/providers/              OpenAI / Anthropic / Custom(OpenAI 兼容) Provider
    src/tools/                  工具注册表与执行器
    src/asr/whisper.py          ASR（函数级惰性导入 openai-whisper，未装 → 501）
    src/tts/azure.py            TTS（函数级惰性导入 azure SDK，未装 → 501）
    src/session/manager.py      会话管理
    src/errors.py               统一错误模型（补充支持模块）

约束：
- 所有第三方 SDK（openai / anthropic / whisper / azure）**必须惰性导入**，
  本包的 import 不得触碰它们。
- 凭据只从环境变量读取，绝不打印/记录。
"""

SERVICE_NAME = "whiteboard-ai-gateway"
__version__ = "0.1.0"

__all__ = ["SERVICE_NAME", "__version__"]
