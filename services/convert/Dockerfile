# Whiteboard Convert —— PDF 转换服务容器镜像
#
# 端口约定：《构建打包与发布设计》未对 convert 服务规定固定端口
# （该文档仅给出 web 的 nginx:80 示例），本服务自选 8001 作为容器内端口
# （ai_gateway 约定 8000），运行时可用 WB_CONVERT_PORT / PORT 覆盖。
#
# 构建（在 services/convert 目录内）：
#   docker build -t whiteboard-convert:0.1.0 .
# 运行：
#   docker run --rm -p 8001:8001 whiteboard-convert:0.1.0

FROM python:3.13-slim

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    WB_CONVERT_HOST=0.0.0.0 \
    WB_CONVERT_PORT=8001

WORKDIR /app

# 依赖先于源码复制（最大化层缓存）；requirements.txt 为契约文件，保持锁定版本。
COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

COPY src ./src

# 非 root 运行（对齐安全与合规设计的最小权限原则）
RUN useradd --create-home --uid 10001 appuser \
    && chown -R appuser:appuser /app
USER appuser

EXPOSE 8001

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD python -c "import sys,urllib.request; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8001/health', timeout=3).status == 200 else 1)"

# 以模块方式启动：与 `python -m src.app`（本地/测试）同一入口
CMD ["python", "-m", "src.app"]
