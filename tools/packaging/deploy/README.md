# 服务器部署（Ubuntu · realtime 协同 + Web 应用）

把 Whiteboard 的服务端部署到远程 Ubuntu 服务器：**realtime 协同服务**（Socket.IO，systemd 托管）
\+ **Web 应用静态站**（Flutter Web 产物，nginx 托管）。支持两种站点模式：

| 模式 | 访问地址 | 投屏采集（屏幕/摄像头） | 适用 |
| --- | --- | --- | --- |
| **HTTP 直连**（默认） | `http://<IP>/` | ❌ 不可用（浏览器安全限制） | 内网快速试用、只做协同白板 |
| **HTTPS 同源**（`-Scheme https`） | `https://<域名>/` | ✅ PC 浏览器可用 | 投屏、公网/内网正式使用 |

> **关键**：`getDisplayMedia` / `getUserMedia` 只在**安全上下文**（HTTPS、`localhost`、
> `127.0.0.1`）下可用。用 `http://<服务器IP>/` 访问时 `navigator.mediaDevices` 是
> `undefined`，点「投屏」会报
> `Unable to getDisplayMedia: Null check operator used on a null value`。
> 这是浏览器强制策略，**只能靠 HTTPS 解决**，无法用代码绕过。

## 模式 A：HTTP 直连（仅协同，投屏不可用）

```
 浏览器用户                     桌面端用户
    │  http://<IP>/               │
    ▼                             ▼
 ┌──────────────────┐     ┌────────────────────────────┐
 │ nginx :80        │     │ realtime :8790             │
 │  web/ 静态产物    │     │  Socket.IO /board + /healthz│
 │ （install.sh 安装）│     │ （systemd: wb-realtime）    │
 └──────────────────┘     └────────────────────────────┘
        Web 端连接地址在「构建时」注入：WB_REALTIME_ENDPOINT=http://<IP>:8790
        桌面端连接地址在「设置 → 协作服务器地址」中填写
```

## 模式 B：HTTPS 同源（投屏必需）

```
 浏览器用户（PC，可发起投屏）           桌面端用户
    │  https://<域名>/                   │
    ▼                                    ▼
 ┌──────────────────────────┐    ┌────────────────────────┐
 │ nginx :443（TLS 终止）     │    │ realtime :8790（可仅内网）│
 │  web/ 静态产物             │    │  Socket.IO /board      │
 │  /socket.io/ → 127.0.0.1:8790│   │  /cast（投屏信令）      │
 └──────────────────────────┘    └────────────────────────┘
        Web 端注入：WB_REALTIME_ENDPOINT=https://<域名>（443 同源，无混合内容）
```

为什么要「同源」：页面是 HTTPS 时，信令也必须是 `https/wss`，否则浏览器会以
混合内容（mixed content）为由拦截 socket.io。把 `/socket.io/` 反代到本机 realtime
即可让页面与信令共用一个域名，`8790` 也无需对外暴露。

## 前置条件

- 服务器：Ubuntu 20.04+（Debian 系），有 root/sudo，可访问外网（装 Node 与 npm 依赖）。
  国内网络 npm 慢时可加 `--npm-registry https://registry.npmmirror.com`。
- 本机（Windows）：Flutter SDK（构建 Web）、OpenSSH 的 `scp`（系统自带）。
- **HTTPS 模式额外需要**：
  - 一个指向服务器的**域名**（公共信任证书不能签发给纯 IP）；
  - 域名已解析到服务器公网 IP，且云厂商安全组 / ufw 放行 **80 与 443**；
  - 证书：用 [certbot](https://certbot.eff.org/) 免费签发（推荐），或自签证书。

## 三步部署

### 1. 本地打包

```powershell
cd e:\code\whiteboard
# 模式 A（HTTP，投屏不可用）
tools\packaging\deploy\pack_server_deploy.ps1 -ServerAddress <服务器IP>

# 模式 B（HTTPS 同源，投屏可用）：域名或 IP 均可
#   -Scheme https 会把 endpoint 注入为 https://<地址>（443 同源）
tools\packaging\deploy\pack_server_deploy.ps1 -ServerAddress wb.example.com -Scheme https
```

- 重新构建 Flutter Web，并把 `WB_REALTIME_ENDPOINT` **注入编译**：
  - HTTP 模式：`http://<服务器IP>:8790`
  - HTTPS 模式：`https://<域名>`（不带端口，`/socket.io/` 由 nginx 反代）
- 连同 `services/realtime` 源码、安装脚本与 systemd/nginx 模板打成自包含包：

```text
dist\whiteboard-server-deploy.tar.gz          （约 13 MB）
dist\whiteboard-server-deploy.tar.gz.sha256
```

> **注意**：端点地址是编译期注入的——**服务器地址或协议变了必须重新打包**。
> `-SkipWebBuild` 仅用于「Web 产物已经指向目标地址、只想重打服务端源码」的场景。
> 只想改信令地址（如单独的 wss 域名）可用 `-Endpoint https://rt.example.com` 直接覆盖。

### 2. 上传

```powershell
scp .\dist\whiteboard-server-deploy.tar.gz <user>@<服务器IP>:/tmp/
scp .\tools\packaging\deploy\install.sh    <user>@<服务器IP>:/tmp/
```

### 3. 服务器部署（一键）

```bash
ssh <user>@<服务器IP>
# 模式 A（HTTP）
sudo bash /tmp/install.sh /tmp/whiteboard-server-deploy.tar.gz

# 模式 B（HTTPS）：证书已在 /etc/letsencrypt/live/<域名>/ 时
sudo bash /tmp/install.sh /tmp/whiteboard-server-deploy.tar.gz --tls-domain wb.example.com
```

install.sh 会依次完成：安装 Node 20 LTS / nginx（缺失时）→ 解包到 `/opt/whiteboard`
→ `npm ci && npm run build` 构建 realtime → 写入并启动 systemd 服务 `wb-realtime`
→ 配置 nginx 站点（HTTP :80 或 HTTPS :443 + `/socket.io/` 反代）
→ ufw 放行 80/8790（HTTPS 模式加 443）→ 健康检查。

## HTTPS 首次部署完整流程（投屏必需）

前置：域名 `wb.example.com` 已解析到服务器公网 IP，安全组 / ufw 已放行 80、443。

```bash
# 1) 服务器：装 certbot，只签证书（不碰 nginx 配置）
sudo apt-get update && sudo apt-get install -y certbot
#   80 已被 nginx 占用时先停一下（standalone 需要独占 80）
sudo systemctl stop nginx || true
sudo certbot certonly --standalone -d wb.example.com
sudo systemctl start nginx || true
#    证书落点：/etc/letsencrypt/live/wb.example.com/{fullchain.pem,privkey.pem}

# 2) 服务器：部署（--tls-domain 渲染 HTTPS 站点 + /socket.io/ 反代）
sudo bash /tmp/install.sh /tmp/whiteboard-server-deploy.tar.gz --tls-domain wb.example.com

# 3) 验证
curl -I https://wb.example.com/                  # → 200
curl "https://wb.example.com/socket.io/?EIO=4&transport=polling"   # → 0{"sid":...}
```

用 `certonly` 而不是 `certbot --nginx`：后者会改写 nginx 配置，与 install.sh 的模板互相覆盖。
续期由 certbot 的 systemd timer 自动完成（`systemctl list-timers | grep certbot`）。

### 没有域名怎么办

HTTPS 只要求「页面用 `https://` 打开」，**不要求域名**。按使用场景选：

| 方案 | 成本 | 谁能用 | 适合 |
| --- | --- | --- | --- |
| 自签证书 + IP | 一次生成证书；每台设备信任一次 | 所有设备（手机需装 CA） | **长期使用、IP 固定**（推荐） |
| SSH 隧道 + localhost | 零改动 | 只有建隧道的那台 PC | 先验证 PC 能否投屏 |
| Tailscale / Cloudflare Tunnel | 装客户端 / 外部网络 | 加入网络或公网 | 无法改证书、又能出网 |

#### 方案 1：自签证书 + IP（推荐）

```bash
# 服务器：生成带 IP SAN 的自签证书（OpenSSL 1.1.1+，Ubuntu 20.04+ 自带）
sudo mkdir -p /etc/ssl/wb
sudo openssl req -x509 -newkey rsa:2048 -nodes -days 825 \
  -keyout /etc/ssl/wb/wb.key -out /etc/ssl/wb/wb.crt \
  -subj "/CN=<服务器IP>" -addext "subjectAltName=IP:<服务器IP>"

# 部署（注意打包时也要带 -Scheme https）
sudo bash /tmp/install.sh /tmp/whiteboard-server-deploy.tar.gz \
  --tls-domain <服务器IP> --tls-cert /etc/ssl/wb/wb.crt --tls-key /etc/ssl/wb/wb.key
```

```powershell
# 本地打包：域名位置直接填 IP
tools\packaging\deploy\pack_server_deploy.ps1 -ServerAddress <服务器IP> -Scheme https
```

客户端信任（每台设备一次）：

- **Windows PC**：两种都行
  1. 首次访问 `https://<IP>/` → 「高级」→「继续前往（不安全）」→ 页面加载后仍属安全上下文，
     实测 `isSecureContext=true`、`mediaDevices` 可用、`getDisplayMedia` 存在；
  2. 或把 `wb.crt` 下载到本地，双击 → 安装证书 → 存放到「受信任的根证书颁发机构」
     （之后地址栏不再报警告）。
- **Android**：设置 → 安全 → 加密与凭据 → 安装证书 → CA 证书，选 `wb.crt`。
- **iOS**：Safari 下载 `wb.crt` → 允许描述文件 → 设置 → 通用 → VPN 与设备管理 → 安装，
  再到 设置 → 通用 → 关于本机 → 证书信任设置 → 开启完全信任。

注意：自签证书有效期 825 天（Apple 上限），过期需重新生成并重跑 install.sh。

#### 方案 2：SSH 隧道 + localhost（PC 零成本验证）

`localhost` 天生是安全上下文，**不需要证书、不需要改服务器**：

```powershell
# 本机（Windows）建隧道：本地 8080 → 服务器的 80
ssh -L 8080:127.0.0.1:80 <user>@<服务器IP>
```

然后用浏览器打开 **`http://localhost:8080/`**（注意是 localhost，不是服务器 IP）。
此时页面 origin 是 `http://localhost:8080`，`getDisplayMedia` 可用；
信令仍连打包时注入的 `http://<服务器IP>:8790`（跨源 CORS 已放开），协同与投屏都能跑通。

限制：只有建隧道的这台 PC 能用，手机不行；适合先用 1 分钟确认「投屏链路本身是好的」。

前提：服务器上是**默认 HTTP 部署**（`-Scheme http` 打包，endpoint 为 `http://<IP>:8790`），
这种情形下不用重新打包；若之前已打成 `-Scheme https` 的包，信令会连不上，需改回 HTTP 包。

#### 方案 3：临时公共信任域名（有公网 IP 且能出网）

- **Cloudflare Quick Tunnel**（无需账号/域名）：
  ```bash
  cloudflared tunnel --url http://localhost:80
  # → https://<随机>.trycloudflare.com
  ```
  证书公共信任，手机也能直接用；但**地址每次重启会变**，而 endpoint 是编译期注入，
  变了就得重新打包，只适合临时演示。
- **Tailscale**：所有访问设备装 Tailscale，`tailscale cert <machine>.tailnet-name.ts.net`
  可拿公共信任证书；适合固定小范围设备。
- `sslip.io` / `nip.io` + certbot：解析到公网 IP，但这类泛解析域名申请 Let's Encrypt
  存在限流与政策不确定性，不作为推荐路径。


## 验证

```bash
# 服务器自检
curl http://127.0.0.1:8790/healthz        # → {"ok":true}
```

- HTTP 模式：浏览器打开 `http://<服务器IP>/` → 进入白板 → 协同状态就绪；
- HTTPS 模式：浏览器打开 `https://<域名>/` → 地址栏出现锁标识（无证书警告）；
- 开两个窗口加入同一房间，画一笔互相可见。
- 桌面端：「设置 → 协作服务器地址」填 `http://<服务器IP>:8790`（或 `https://<域名>`）。
- **投屏验证**：PC 浏览器进入「局域网投屏」→ 发起投屏 → 弹出系统屏幕选择框
  （若提示「当前页面不是安全上下文」则 HTTPS 未生效）。

## 更新部署

重新打包 → 上传 → **重跑 install.sh 即可**（幂等：重新解包、重建、重启服务）：

```powershell
tools\packaging\deploy\pack_server_deploy.ps1 -ServerAddress <服务器IP>
scp .\dist\whiteboard-server-deploy.tar.gz <user>@<服务器IP>:/tmp/
ssh <user>@<服务器IP> "sudo bash /tmp/install.sh /tmp/whiteboard-server-deploy.tar.gz"
```

更新后浏览器若仍是旧界面：强制刷新（Ctrl+F5），或清除该站点数据（Flutter Service Worker 缓存）。

> HTTPS 模式同样幂等；但**切换 HTTP/HTTPS 必须重新打包**
> （endpoint 是编译期注入的），仅重跑 install.sh 不够。

## 参数参考

| pack_server_deploy.ps1 | 说明 |
| --- | --- |
| `-ServerAddress` | 必填；服务器 IP/域名（注入 Web 构建与文档） |
| `-Scheme` | `http`（默认）或 `https`；https 时 endpoint = `https://<地址>`（443 同源），**投屏必需** |
| `-Endpoint` | 完整覆盖注入地址（高级，如 `https://rt.example.com`） |
| `-RealtimePort` | realtime 端口，默认 8790（https 同源模式下不对外暴露） |
| `-SkipWebBuild` | 跳过 Web 重新构建（仅当产物已指向目标地址） |
| `-OutDir` | 产物目录，默认 `<repo>\dist` |
| `-FlutterPath` / `-BuildName` | 转发给 `tools\scripts\build_flutter.ps1` |

| install.sh | 说明 |
| --- | --- |
| `--app-dir DIR` | 安装目录，默认 `/opt/whiteboard` |
| `--port N` | realtime 端口，默认 8790 |
| `--user NAME` | systemd 运行用户，默认 sudo 调用者 |
| `--npm-registry URL` | npm 镜像 |
| `--skip-deps` | 不自动安装 Node/nginx（缺失时报错） |
| `--tls-domain HOST` | 启用 HTTPS 同源站点（域名或 IP），投屏必需 |
| `--tls-cert PATH` | fullchain 路径（默认 `/etc/letsencrypt/live/<HOST>/fullchain.pem`） |
| `--tls-key PATH` | 私钥路径（默认 `/etc/letsencrypt/live/<HOST>/privkey.pem`） |

## 服务器落点

```text
/opt/whiteboard/
├── services/realtime/    源码 + node_modules + dist/server.js
├── web/                  Flutter Web 静态产物（nginx 的 root）
├── deploy/               install.sh、templates/、INFO.txt（含打包目标地址）
└── data/                 预留：审计 JSONL 目录
/etc/systemd/system/wb-realtime.service
/etc/nginx/sites-available/whiteboard.conf  （→ sites-enabled 软链）
```

## 安全与限制（重要）

1. **匿名协同模式**：客户端尚未接入登录 token，realtime 处于「无密钥 + 非 production =
   匿名回落」。意味着**能访问 8790 端口的人都可以加入房间**——先用于内测，勿长期裸奔公网。
   收紧路径：接入登录签发 JWT → 设置 `WB_JWT_SECRET` + `NODE_ENV=production`
   （见 `templates/wb-realtime.service` 注释）。
2. **CORS**：realtime 当前 `cors: { origin: '*' }`（POC 放开，见 `services/realtime/src/server.ts`），与本模式一致。
3. **投屏必须 HTTPS**：`getDisplayMedia`/`getUserMedia` 只在安全上下文可用。HTTP 直连部署
   下 `navigator.mediaDevices` 为 `undefined`，点投屏会报
   `Unable to getDisplayMedia: Null check operator used on a null value`。
   → 用模式 B：`-Scheme https` 打包 + `--tls-domain` 部署（见上文「HTTPS 首次部署完整流程」）。
   **手机浏览器即使 HTTPS 也普遍不支持 `getDisplayMedia`**（Android Chrome / iOS Safari），
   手机只能作为投屏观看端，或改用摄像头采集。
   （代码已加前置检测：非安全上下文时给出中文提示，不再抛底层空断言。）
4. **数据在内存**：realtime 房间重启即清空；本部署不包含 services/api（其数据同为内存版）。
5. **地址为编译期注入**：更换服务器地址 = 重新打包（Step 1），不能只改服务器配置。

## 故障排查

| 症状 | 排查 |
| --- | --- |
| `http://<IP>/` 打不开 | `systemctl status nginx`；80 端口占用；`ufw status`；云厂商安全组是否放行 80 |
| `https://<域名>/` 打不开 | 是否用 `--tls-domain` 部署；`nginx -t`；443 是否放行；证书路径是否存在 |
| 投屏报 `Null check operator used on a null value` | **当前是 HTTP，非安全上下文**。改用 `-Scheme https` 打包 + `--tls-domain` 部署；临时调试可用 `chrome://flags/#unsafely-treat-insecure-origin-as-secure`（仅 PC） |
| 投屏报「当前页面不是安全上下文」 | 同上；确认地址栏是 `https://` 且无证书错误 |
| 投屏报「当前浏览器不支持屏幕采集」 | 手机浏览器不支持 `getDisplayMedia`，改用桌面浏览器发起或用摄像头 |
| HTTPS 页面连不上协同 | 混合内容：endpoint 必须是 `https://<域名>`（不带 8790）；检查 `/socket.io/` 反代：`curl "https://<域名>/socket.io/?EIO=4&transport=polling"` |
| 页面打开但协同连不上 | 浏览器 F12 看 socket 连接报错；`curl http://<IP>:8790/healthz`；ufw/安全组放行 8790（HTTP 模式） |
| wb-realtime 起不来 | `journalctl -u wb-realtime -n 50 --no-pager`（常见：Node 版本过旧） |
| npm ci 慢或超时 | 加 `--npm-registry https://registry.npmmirror.com` 重跑 |
| Node 自动安装失败 | 检查外网；或手动装 Node 20 后加 `--skip-deps` 重跑 |
| 更新后仍是旧页面 | Ctrl+F5 强刷；设置中清除站点数据（Service Worker 缓存） |
| 想换端口 | 重新打包（`-RealtimePort`）+ `install.sh --port` 同值使用 |

常用运维命令：

```bash
systemctl status wb-realtime     # 服务状态
journalctl -u wb-realtime -f     # 实时日志
systemctl restart wb-realtime    # 重启
nginx -t && systemctl reload nginx
```

## 未验证声明

本套脚本与模板在本机（Windows）完成语法/结构校验与打包链路实跑：

- `pack_server_deploy.ps1`：HTTP / `-Scheme https` / `-Endpoint` 三种注入均实跑通过
  （INFO.txt 与末尾提示命令正确，非法 endpoint 能报错退出）；
- 模板：`whiteboard-web.conf`（HTTP）与 `whiteboard-web-tls.conf`（HTTPS + 反代）
  占位符已核对；
- `install.sh`：本次新增的 `--tls-*` 分支未跑 `bash -n`（本机无 POSIX shell），
  结构已人工核对；上服务器前建议先跑：`bash -n install.sh`。

**未在真实 Ubuntu 服务器上端到端执行**（尤其 certbot 签证、nginx 443、WebSocket 反代）。
首次部署如遇问题，请把 `install.sh` 输出与 `journalctl -u wb-realtime` 日志带回排查。
