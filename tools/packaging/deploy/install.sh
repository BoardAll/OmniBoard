#!/usr/bin/env bash
# ============================================================================
# install.sh — Whiteboard 服务器端部署脚本（Ubuntu，直连 IP + 端口模式）
# ============================================================================
# 部署内容：
#   * realtime 协同服务（services/realtime，Node 20 + systemd，默认 :8790）
#   * Web 静态应用（web/，nginx 托管，默认 :80，已注入 realtime 地址）
#
# 用法（在服务器上，需要 root）：
#   sudo bash install.sh whiteboard-server-deploy.tar.gz
#   sudo bash install.sh whiteboard-server-deploy.tar.gz --app-dir /opt/whiteboard --port 8790
#
# 幂等：可重复执行（= 重新解包 + 重新构建 + 重启服务），用于更新部署。
# ============================================================================
set -euo pipefail

APP_DIR=/opt/whiteboard
PORT=8790
RUN_USER=""
NPM_REGISTRY=""
SKIP_DEPS=0
TAR_PATH=""
MIN_NODE_MAJOR=18

log()  { printf '\033[1;32m[install]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[install]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[install] 错误：\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
用法: sudo bash install.sh <whiteboard-server-deploy.tar.gz> [选项]

选项:
  --app-dir DIR        安装目录（默认 /opt/whiteboard）
  --port N             realtime 监听端口（默认 8790）
  --user NAME          systemd 运行用户（默认：sudo 调用者）
  --npm-registry URL   npm 镜像（如 https://registry.npmmirror.com）
  --skip-deps          跳过 Node/nginx 自动安装（缺失时报错退出）
  -h, --help           显示本帮助
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app-dir)      APP_DIR="${2:?--app-dir 需要参数}"; shift 2 ;;
    --port)         PORT="${2:?--port 需要参数}"; shift 2 ;;
    --user)         RUN_USER="${2:?--user 需要参数}"; shift 2 ;;
    --npm-registry) NPM_REGISTRY="${2:?--npm-registry 需要参数}"; shift 2 ;;
    --skip-deps)    SKIP_DEPS=1; shift ;;
    -h|--help)      usage; exit 0 ;;
    -*)             usage; die "未知参数: $1" ;;
    *)              [[ -z "$TAR_PATH" ]] || die "只能指定一个部署包"; TAR_PATH="$1"; shift ;;
  esac
done

# ---------------------------------------------------------------------------
# 前置检查
# ---------------------------------------------------------------------------
[[ $EUID -eq 0 ]] || die '需要 root 权限，请用：sudo bash install.sh <部署包>'
[[ -n "$TAR_PATH" ]] || { usage; die '缺少部署包参数'; }
[[ -f "$TAR_PATH" ]] || die "部署包不存在: $TAR_PATH"
[[ "$PORT" =~ ^[0-9]+$ ]] && (( PORT >= 1 && PORT <= 65535 )) || die "--port 必须是 1-65535 的整数"

if [[ -z "$RUN_USER" ]]; then
  RUN_USER="${SUDO_USER:-root}"
fi
id "$RUN_USER" >/dev/null 2>&1 || die "用户不存在: $RUN_USER"

log "安装目录 : $APP_DIR"
log "服务端口 : $PORT"
log "运行用户 : $RUN_USER"

# ---------------------------------------------------------------------------
# 1. 依赖（Node 20 LTS / nginx）
# ---------------------------------------------------------------------------
if command -v node >/dev/null 2>&1; then
  node_major="$(node -v | sed 's/^v//' | cut -d. -f1)"
  (( node_major >= MIN_NODE_MAJOR )) || die "Node $(node -v) 过旧（需要 >= ${MIN_NODE_MAJOR}，推荐 20 LTS）"
  log "Node 已安装: $(node -v)"
else
  if (( SKIP_DEPS )); then
    die '缺少 Node.js（--skip-deps 模式不自动安装）。请先安装 Node 20 LTS：https://nodejs.org/'
  fi
  command -v apt-get >/dev/null 2>&1 || die '自动安装依赖需要 apt（Debian/Ubuntu）。请手动安装 Node 20 后重跑。'
  log '安装 Node.js 20 LTS（NodeSource 官方源，需要外网）...'
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
  apt-get install -y nodejs
  log "Node 安装完成: $(node -v)"
fi

if command -v nginx >/dev/null 2>&1; then
  log "nginx 已安装: $(nginx -v 2>&1 | sed 's/^nginx version: //')"
else
  if (( SKIP_DEPS )); then
    die '缺少 nginx（--skip-deps 模式不自动安装）。'
  fi
  log '安装 nginx...'
  export DEBIAN_FRONTEND=noninteractive
  apt-get install -y nginx
fi

# ---------------------------------------------------------------------------
# 2. 解包
# ---------------------------------------------------------------------------
log "解包部署包: $TAR_PATH"
mkdir -p "$APP_DIR"
tar -xzf "$TAR_PATH" -C "$APP_DIR"

[[ -f "$APP_DIR/services/realtime/src/server.ts" ]] || die '部署包结构异常：缺少 services/realtime/src'
[[ -f "$APP_DIR/web/index.html" ]]                || die '部署包结构异常：缺少 web/index.html'
TEMPLATES="$APP_DIR/deploy/templates"
[[ -d "$TEMPLATES" ]] || die '部署包结构异常：缺少 deploy/templates（请用 pack_server_deploy.ps1 重新打包）'

# ---------------------------------------------------------------------------
# 3. 构建 realtime 服务
# ---------------------------------------------------------------------------
log '安装依赖并构建 realtime 服务（npm ci + tsc → dist/）...'
pushd "$APP_DIR/services/realtime" >/dev/null
npm_args=(--no-audit --no-fund)
if [[ -n "$NPM_REGISTRY" ]]; then
  npm_args+=(--registry "$NPM_REGISTRY")
fi
npm ci "${npm_args[@]}"
npm run build
[[ -f dist/server.js ]] || die '构建失败：dist/server.js 不存在'
popd >/dev/null
log 'realtime 构建完成（dist/server.js）'

# 统一属主：服务以 RUN_USER 运行，需读写安装目录
chown -R "$RUN_USER:$RUN_USER" "$APP_DIR"
mkdir -p "$APP_DIR/data"   # 可选审计 JSONL 目录（见 wb-realtime.service 注释）

# ---------------------------------------------------------------------------
# 4. systemd 单元（wb-realtime）
# ---------------------------------------------------------------------------
log '写入 systemd 单元 /etc/systemd/system/wb-realtime.service ...'
# node 实际路径（模板占位 /usr/bin/node；NVM/自定义安装时正确替换）
NODE_BIN="$(command -v node)"
[[ -n "$NODE_BIN" ]] || die '找不到 node 可执行文件'
log "systemd 将使用 node: $NODE_BIN"
sed -e "s|__WB_USER__|$RUN_USER|g" \
    -e "s|__WB_APP_DIR__|$APP_DIR|g" \
    -e "s|__WB_PORT__|$PORT|g" \
    -e "s|ExecStart=/usr/bin/node|ExecStart=$NODE_BIN|" \
    "$TEMPLATES/wb-realtime.service" > /etc/systemd/system/wb-realtime.service

systemctl daemon-reload
systemctl enable wb-realtime.service >/dev/null 2>&1 || true
systemctl restart wb-realtime.service
log 'wb-realtime 服务已启动'

# ---------------------------------------------------------------------------
# 5. nginx 站点（Web 静态站）
# ---------------------------------------------------------------------------
log '配置 nginx 站点（whiteboard.conf）...'
SITE=/etc/nginx/sites-available/whiteboard.conf
sed -e "s|__WB_APP_DIR__|$APP_DIR|g" "$TEMPLATES/whiteboard-web.conf" > "$SITE"
ln -sf "$SITE" /etc/nginx/sites-enabled/whiteboard.conf

# Debian/Ubuntu 默认欢迎站占用 :80；仅当没有其他站点时移出（保留原文件可恢复）
if [[ -e /etc/nginx/sites-enabled/default ]]; then
  other="$(find /etc/nginx/sites-enabled -mindepth 1 ! -name default ! -name whiteboard.conf -print -quit 2>/dev/null || true)"
  if [[ -z "$other" ]]; then
    mv /etc/nginx/sites-enabled/default /etc/nginx/sites-available/default.disabled-by-whiteboard
    log '已禁用 nginx 默认站点（原文件保留于 sites-available/default.disabled-by-whiteboard）'
  else
    warn "检测到已有其他站点（$other）：未自动处理 80 端口冲突，请确认 whiteboard.conf 生效。"
  fi
fi

nginx -t
systemctl enable nginx >/dev/null 2>&1 || true
if systemctl is-active --quiet nginx; then
  systemctl reload nginx
else
  systemctl start nginx
fi
log 'nginx 已就绪（静态站 → http://<本机IP>/）'

# ---------------------------------------------------------------------------
# 6. 防火墙（仅当 ufw 处于启用状态）
# ---------------------------------------------------------------------------
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
  log "放行防火墙端口 80 与 ${PORT} ..."
  ufw allow 80/tcp >/dev/null || true
  ufw allow "${PORT}"/tcp >/dev/null || true
fi

# ---------------------------------------------------------------------------
# 7. 健康检查
# ---------------------------------------------------------------------------
log '等待 realtime 服务就绪...'
healthy=0
for _ in $(seq 1 15); do
  if command -v curl >/dev/null 2>&1; then
    if curl -fsS "http://127.0.0.1:${PORT}/healthz" >/dev/null 2>&1; then healthy=1; break; fi
  elif command -v wget >/dev/null 2>&1; then
    if wget -qO- "http://127.0.0.1:${PORT}/healthz" >/dev/null 2>&1; then healthy=1; break; fi
  else
    # 无 curl/wget：退化为仅检查进程存活（给启动留 2 秒）
    sleep 2
    if systemctl is-active --quiet wb-realtime; then healthy=1; fi
    break
  fi
  sleep 1
done

if (( healthy != 1 )); then
  echo '----- wb-realtime 最近日志 -----' >&2
  journalctl -u wb-realtime -n 30 --no-pager >&2 || true
  die "realtime 健康检查失败（http://127.0.0.1:${PORT}/healthz）"
fi
log 'realtime 健康检查通过（/healthz）'

# ---------------------------------------------------------------------------
# 完成汇总
# ---------------------------------------------------------------------------
server_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
[[ -n "$server_ip" ]] || server_ip='<服务器IP>'

cat <<EOF

============================================================================
 部署完成

   Web 应用      http://${server_ip}/
   协同服务      http://${server_ip}:${PORT}   （健康检查路径 /healthz）
   服务状态      systemctl status wb-realtime
   实时日志      journalctl -u wb-realtime -f

   桌面端        「设置 → 协作服务器地址」填 http://${server_ip}:${PORT}
   Web 端        已在构建时注入（WB_REALTIME_ENDPOINT=http://${server_ip}:${PORT}）

   更新部署      重新打包上传后，重跑本脚本即可（幂等）。

 注意：当前为匿名协同模式（无登录 token）——能访问该端口的人都可以加入
 房间。接入登录体系前请勿直接公网长期暴露；详见 deploy/README.md「安全」。
============================================================================
EOF
