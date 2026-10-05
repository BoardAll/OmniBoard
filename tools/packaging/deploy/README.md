# 服务器部署（Ubuntu · realtime 协同 + Web 应用）

把 Whiteboard 的服务端部署到远程 Ubuntu 服务器：**realtime 协同服务**（Socket.IO，systemd 托管）
\+ **Web 应用静态站**（Flutter Web 产物，nginx 托管）。采用**直连 IP + 端口**模式。

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

## 前置条件

- 服务器：Ubuntu 20.04+（Debian 系），有 root/sudo，可访问外网（装 Node 与 npm 依赖）。
  国内网络 npm 慢时可加 `--npm-registry https://registry.npmmirror.com`。
- 本机（Windows）：Flutter SDK（构建 Web）、OpenSSH 的 `scp`（系统自带）。

## 三步部署

### 1. 本地打包

```powershell
cd e:\code\whiteboard
tools\packaging\deploy\pack_server_deploy.ps1 -ServerAddress <服务器IP>
```

- 重新构建 Flutter Web，并把 `WB_REALTIME_ENDPOINT=http://<服务器IP>:8790` **注入编译**；
- 连同 `services/realtime` 源码、安装脚本与 systemd/nginx 模板打成自包含包：

```text
dist\whiteboard-server-deploy.tar.gz          （约 13 MB）
dist\whiteboard-server-deploy.tar.gz.sha256
```

> **注意**：端点地址是编译期注入的——**服务器地址变了必须重新打包**。
> `-SkipWebBuild` 仅用于「Web 产物已经指向目标地址、只想重打服务端源码」的场景。

### 2. 上传

```powershell
scp .\dist\whiteboard-server-deploy.tar.gz <user>@<服务器IP>:/tmp/
scp .\tools\packaging\deploy\install.sh    <user>@<服务器IP>:/tmp/
```

### 3. 服务器部署（一键）

```bash
ssh <user>@<服务器IP>
sudo bash /tmp/install.sh /tmp/whiteboard-server-deploy.tar.gz
```

install.sh 会依次完成：安装 Node 20 LTS / nginx（缺失时）→ 解包到 `/opt/whiteboard`
→ `npm ci && npm run build` 构建 realtime → 写入并启动 systemd 服务 `wb-realtime`
→ 配置 nginx 静态站 → ufw 放行 80/8790（仅当 ufw 已启用）→ 健康检查。

## 验证

```bash
# 服务器自检
curl http://127.0.0.1:8790/healthz        # → {"ok":true}
```

- 浏览器打开 `http://<服务器IP>/` → 进入白板 → 协同状态就绪；
  开两个窗口加入同一房间，画一笔互相可见。
- 桌面端：「设置 → 协作服务器地址」填 `http://<服务器IP>:8790` → 连接。

## 更新部署

重新打包 → 上传 → **重跑 install.sh 即可**（幂等：重新解包、重建、重启服务）：

```powershell
tools\packaging\deploy\pack_server_deploy.ps1 -ServerAddress <服务器IP>
scp .\dist\whiteboard-server-deploy.tar.gz <user>@<服务器IP>:/tmp/
ssh <user>@<服务器IP> "sudo bash /tmp/install.sh /tmp/whiteboard-server-deploy.tar.gz"
```

更新后浏览器若仍是旧界面：强制刷新（Ctrl+F5），或清除该站点数据（Flutter Service Worker 缓存）。

## 参数参考

| pack_server_deploy.ps1 | 说明 |
| --- | --- |
| `-ServerAddress` | 必填；服务器 IP/域名（注入 Web 构建与文档） |
| `-RealtimePort` | realtime 端口，默认 8790 |
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
3. **无 TLS**：纯 HTTP（浏览器用 `https://` 直接访问会连接失败，属预期行为）。上 HTTPS 需要：
   域名（证书签发给域名，纯 IP 拿不到公共信任证书）+ 证书 + nginx 443 + socket.io 同源反代
   （WebSocket upgrade 配置块已备在 `templates/whiteboard-web.conf` 文末）。
4. **数据在内存**：realtime 房间重启即清空；本部署不包含 services/api（其数据同为内存版）。
5. **地址为编译期注入**：更换服务器地址 = 重新打包（Step 1），不能只改服务器配置。

## 故障排查

| 症状 | 排查 |
| --- | --- |
| `http://<IP>/` 打不开 | `systemctl status nginx`；80 端口占用；`ufw status`；云厂商安全组是否放行 80 |
| `https://<IP>/` 打不开 | **预期行为**：本部署为纯 HTTP（nginx 仅监听 80、无证书）。改用 `http://<IP>/` 访问；上 HTTPS 需域名 + 证书 + socket.io 同源反代 |
| 页面打开但协同连不上 | 浏览器 F12 看 socket 连接报错；`curl http://<IP>:8790/healthz`；ufw/安全组放行 8790 |
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

本套脚本与模板在本机（Windows）完成语法/结构校验（PowerShell AST 解析、bash 语法检查、
模板占位符一致性、打包链路实跑），**未在真实 Ubuntu 服务器上端到端执行**。
首次部署如遇问题，请把 `install.sh` 输出与 `journalctl -u wb-realtime` 日志带回排查。
