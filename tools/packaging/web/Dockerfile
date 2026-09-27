# ============================================================================
# Dockerfile — Whiteboard Web (static bundle served by nginx).
# ============================================================================
# Implements docs/构建打包与发布设计.md §14.2, adapted so the build context is
# the repository root: that way the same context provides both the compiled
# Flutter bundle and the nginx configuration below.
#
# Prerequisite (docs §14.1):
#   flutter build web --release        # -> apps/web/build/web
#   # or: tools\scripts\build_flutter.ps1 -Target web
#
# Build (run from the repository root):
#   docker build -f tools/packaging/web/Dockerfile -t whiteboard-web:1.0.0 .
#
# Export for air-gapped deploys (docs §14.2):
#   docker save whiteboard-web:1.0.0 | gzip > dist/whiteboard-web-1.0.0-docker.tar.gz
#
# Run locally:
#   docker run --rm -p 8080:80 whiteboard-web:1.0.0
#
# NOTE: Docker is not installed on the development machine — this file was
# reviewed structurally but not built locally (see tools/packaging/README.md).
# ============================================================================
FROM nginx:alpine

# Static Flutter web bundle produced by `flutter build web --release`.
COPY apps/web/build/web /usr/share/nginx/html

# Server configuration (mounted as the default vhost inside the container):
# COOP/COEP headers for WASM + SharedArrayBuffer, application/wasm MIME type,
# SPA fallback and the /api + /ws reverse proxies (docs §14.3).
COPY tools/packaging/web/nginx.conf /etc/nginx/conf.d/default.conf

EXPOSE 80

CMD ["nginx", "-g", "daemon off;"]
