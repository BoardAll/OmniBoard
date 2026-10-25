#!/usr/bin/env bash
# ============================================================================
# https_selfsigned_ip.sh — 无域名场景：用「自签证书 + IP SAN」把 Web 站升级到 HTTPS
# ============================================================================
# 为什么需要：投屏采集 getDisplayMedia/getUserMedia 只在安全上下文
# （HTTPS / localhost）可用；http://<IP>/ 下 navigator.mediaDevices 为
# undefined，页面报 "Null check operator used on a null value"。
#
# 前置：
#   * 部署包已用 `-Scheme https` 打好并上传（包内 deploy/INFO.txt 的
#     web-scheme 必须是 https，web-endpoint 形如 https://<IP>）；
#   * 云厂商安全组 + ufw 放行 80、443；
#   * 以 root 执行。
#
# 用法（服务器上）：
#   sudo bash https_selfsigned_ip.sh [部署包路径]
#   sudo bash https_selfsigned_ip.sh              # 自动在常见路径查找
#
# 幂等：可重复执行（证书已存在则复用；install.sh 本身幂等）。
# ============================================================================
set -euo pipefail

log()  { printf '\033[1;32m[wb-tls]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[wb-tls]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[wb-tls] 错误：\033[0m %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die '需要 root，请用：sudo bash https_selfsigned_ip.sh'
command -v openssl >/dev/null 2>&1 || die '缺少 openssl（apt-get install -y openssl）'

# --- 1. 定位部署包 -----------------------------------------------------------
TAR="${1:-}"
if [[ -z "$TAR" ]]; then
  TAR="$(ls -1t \
      /tmp/whiteboard-server-deploy.tar.gz \
      /root/whiteboard-server-deploy.tar.gz \
      "$HOME/whiteboard-server-deploy.tar.gz" 2>/dev/null | head -n1 || true)"
fi
[[ -n "$TAR" && -f "$TAR" ]] || die '找不到部署包，请把 tar.gz 路径作为第一个参数传入'
log "部署包 : $TAR"

# --- 2. 读包内 INFO.txt，确认是 https 包 ------------------------------------
INFO="$(tar -xzOf "$TAR" ./deploy/INFO.txt 2>/dev/null)" || die '包内缺少 deploy/INFO.txt（请用 pack_server_deploy.ps1 重新打包）'
HOST="$(printf '%s\n' "$INFO" | awk -F': *' '/^server-address/{print $2}')"
SCHEME="$(printf '%s\n' "$INFO" | awk -F': *' '/^web-scheme/{print $2}')"
ENDPOINT="$(printf '%s\n' "$INFO" | awk -F': *' '/^web-endpoint/{print $2}')"

log "注入地址 : ${HOST:-<缺失>}"
log "Web 端点 : ${ENDPOINT:-<缺失>}（scheme=${SCHEME:-<缺失>}）"
[[ -n "$HOST" ]] || die 'INFO.txt 缺少 server-address'
[[ "$SCHEME" == "https" ]] || die "这个包不是 -Scheme https 打的（当前：${SCHEME:-http}）。HTTPS 页面会因混合内容连不上信令，请先在本地重新打包。"

# --- 3. 找 install.sh（优先包内版本，与模板同源；其次 /tmp） -----------------
INSTALL=""
mkdir -p /tmp/wb-unpack
rm -rf /tmp/wb-unpack/deploy
if tar -xzf "$TAR" -C /tmp/wb-unpack ./deploy/install.sh 2>/dev/null; then
  INSTALL=/tmp/wb-unpack/deploy/install.sh
elif [[ -f /tmp/install.sh ]]; then
  INSTALL=/tmp/install.sh
fi
[[ -n "$INSTALL" && -f "$INSTALL" ]] || die '找不到 install.sh（包里没有，/tmp 也没有）'
log "安装脚本 : $INSTALL"

# --- 3.5 兼容旧包：模板 CRLF → LF -------------------------------------------
# 2026-10 之前的模板可能以 CRLF 落盘（Windows 编辑器），nginx/systemd 对
# CRLF 的容忍度不一致。生成一份 LF 修正版包，不改动原包。
TLS_TPL="$(tar -xzOf "$TAR" ./deploy/templates/whiteboard-web-tls.conf 2>/dev/null || true)"
if printf '%s' "$TLS_TPL" | grep -q $'\r'; then
  log '检测到包内模板为 CRLF，生成 LF 修正版包...'
  FIX_DIR=/tmp/wb-lf-fix
  rm -rf "$FIX_DIR"
  mkdir -p "$FIX_DIR"
  tar -xzf "$TAR" -C "$FIX_DIR"
  find "$FIX_DIR/deploy" -type f \( -name '*.conf' -o -name '*.service' -o -name '*.sh' \) \
    -exec sed -i 's/\r$//' {} +
  TAR=/tmp/whiteboard-server-deploy.lf.tar.gz
  tar -czf "$TAR" -C "$FIX_DIR" .
  log "修正版包 : $TAR"
fi

# --- 4. 生成自签证书（IP 写进 SAN；已存在则复用） ----------------------------
CERT_DIR=/etc/ssl/wb
CERT="$CERT_DIR/wb.crt"
KEY="$CERT_DIR/wb.key"
if [[ -f "$CERT" && -f "$KEY" ]]; then
  log "复用已有证书 : $CERT"
else
  mkdir -p "$CERT_DIR"
  log "生成自签证书（CN=$HOST, SAN=IP:$HOST, 825 天）..."
  openssl req -x509 -newkey rsa:2048 -nodes -days 825 \
    -keyout "$KEY" -out "$CERT" \
    -subj "/CN=$HOST" -addext "subjectAltName=IP:$HOST" >/dev/null 2>&1 \
    || die 'openssl 生成证书失败（需 OpenSSL 1.1.1+，Ubuntu 20.04+ 自带）'
  chmod 600 "$KEY"
fi
log '证书信息：'
openssl x509 -in "$CERT" -noout -subject -dates -ext subjectAltName | sed 's/^/    /'

# --- 5. 部署（渲染 nginx 443 + /socket.io/ 同源反代） ------------------------
log '开始部署（install.sh --tls-domain）...'
if ! bash "$INSTALL" "$TAR" --tls-domain "$HOST" --tls-cert "$CERT" --tls-key "$KEY"; then
  die 'install.sh 执行失败，请把上面的输出与 journalctl -u wb-realtime -n 50 带回排查'
fi

# --- 6. 自检 ----------------------------------------------------------------
log 'nginx 配置检查...'
nginx -t

# 用 127.0.0.1 + Host 头访问：HOST 是 IP 时 --resolve 不生效，且避免绕公网回环。
if command -v curl >/dev/null 2>&1; then
  log '本机 HTTPS 首页（-k 忽略自签告警）：'
  curl -k -sS -o /dev/null -w '    HTTP %{http_code}\n' \
    -H "Host: $HOST" https://127.0.0.1/ || warn '首页请求失败'

  log '同源 Socket.IO 反代（应返回 0{"sid":...}）：'
  curl -k -sS -H "Host: $HOST" \
    'https://127.0.0.1/socket.io/?EIO=4&transport=polling' 2>/dev/null | head -c 120 || true
  printf '\n'
else
  warn '无 curl，跳过 HTTP 自检（可手动：wget --no-check-certificate -qO- https://127.0.0.1/）'
fi

cat <<EOF

============================================================================
 HTTPS（自签 + IP）部署完成

   访问地址   https://${HOST}/
   证书       ${CERT}
   私钥       ${KEY}（600，勿外传）

 首次访问会提示「证书不受信任」：
   * Windows：高级 → 继续前往；
   * 想彻底去掉警告：把 wb.crt 装到「受信任的根证书颁发机构」。
 手机（Android/iOS）需安装该 CA 才能正常打开（手机只能观看投屏，不能发起）。

 若外网打不开，检查云厂商安全组是否放行 443（80 用于跳转）。
 证书 825 天后过期：删除 ${CERT_DIR} 下两个文件后重跑本脚本即可重签。
============================================================================
EOF
