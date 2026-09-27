# tools/packaging — 安装包与 Web 部署制品

实现 `docs/构建打包与发布设计.md` §11（Inno Setup 安装包）与 §14（Web/Docker 部署）。
**本机（Windows 22H2）未安装 Inno Setup（iscc）与 Docker**，因此这些文件经过结构性
校验（路径解析、编码、必需段/指令），但**未在本机实际编译/构建**。

## 内容

| 文件 | 用途 | 本机可验证性 |
| --- | --- | --- |
| `windows/inno_setup_x64.iss` | Windows x64 安装包脚本（Inno Setup 6） | 未编译（无 iscc）；结构校验 PASS |
| `windows/inno_setup_x86.iss` | Windows x86 安装包脚本（需先有 x86 产物） | 同上 |
| `web/Dockerfile` | 把 `apps/web/build/web` 打进 nginx:alpine 镜像 | 未构建（无 Docker）；结构校验 PASS |
| `web/nginx.conf` | 静态站点配置：COOP/COEP、wasm MIME、SPA、/api+/ws 反代 | 未用 nginx 加载验证；结构校验 PASS |

## Windows 安装包（Inno Setup 6）

1. **前置产物**（先构建应用）：

   ```powershell
   tools\scripts\build_all.ps1 -SkipWeb -SkipWasm
   # 或： tools\scripts\build_flutter.ps1 -Target windows
   ```

   需要 `apps\desktop\build\windows\x64\runner\Release\` 下有
   `whiteboard_desktop.exe`、`wb_core.dll`、`flutter_windows.dll` 与插件 DLL。

2. **编译安装包**（安装 Inno Setup 6 后；命令行编译器 `iscc.exe`）：

   ```powershell
   iscc tools\packaging\windows\inno_setup_x64.iss
   ```

3. **输出**：`dist\whiteboard-1.0.0-windows-x64.exe`（`OutputDir=..\..\..\dist`，
   相对 `.iss` 所在目录解析，iscc 会自动创建 `dist\`）。

要点与适配说明：

* **相对路径**：`.iss` 中的 `Source`/`OutputDir` 均以文件自身目录
  （`tools\packaging\windows\`）为基准，向上一层三次 `..\` 到仓库根。
  移动 `.iss` 文件时必须同步调整这些路径。
* **UTF-8 BOM**：两个 `.iss` 均为 UTF-8 带 BOM —— Inno Setup 6 对含非 ASCII
  （中文 UI 文案如“创建桌面快捷方式”）的脚本要求 BOM，编辑时务必保留。
* **版本**：`AppVersion=1.0.0`、`OutputBaseFilename=whiteboard-1.0.0-windows-x64`
  与根 `VERSION` 同步维护；发布前跑 `tools\scripts\version_sync.ps1 -Check`。
* **图标**：`SetupIconFile` 暂时注释（仓库暂无 `assets/images` 图标资源）；
  放入 `.ico` 后取消注释并把路径指到该文件。
* **x86**：`inno_setup_x86.iss` 对应 `build\windows\x86\runner\Release\`，
  默认不构建 x86 产物（需要 32 位 Flutter/CMake 工具链与 32 位 `wb_core.dll`），
  其 `Source` 目录当前不存在属于预期，编译前请先准备产物。
* **未编译验证原因**：本机无 iscc；安装 Inno Setup 6 后按上述命令即可验证。

## Web 部署（Docker + nginx）

1. **前置产物**：

   ```powershell
   tools\scripts\build_flutter.ps1 -Target web     # -> apps\web\build\web
   ```

2. **构建镜像**（构建上下文 = 仓库根）：

   ```bash
   docker build -f tools/packaging/web/Dockerfile -t whiteboard-web:1.0.0 .
   ```

3. **运行**：

   ```bash
   docker run --rm -p 8080:80 whiteboard-web:1.0.0
   # 浏览器打开 http://localhost:8080
   ```

4. **离线分发**（可选，§14.2）：

   ```bash
   docker save whiteboard-web:1.0.0 | gzip > dist/whiteboard-web-1.0.0-docker.tar.gz
   ```

`nginx.conf` 要点：

* **COOP/COEP**：WASM + SharedArrayBuffer 需要
  `Cross-Origin-Opener-Policy: same-origin` 与
  `Cross-Origin-Embedder-Policy: require-corp`。nginx 的 `add_header`
  **不会**继承进自带 `add_header` 的 `location`，因此这两个头在每个
  `location` 中重复声明（修改时不要删掉重复项）。
* **wasm MIME + 缓存**：`.wasm` → `application/wasm`，hashed 资源
  `Cache-Control: immutable`；`index.html` 显式 `no-cache`。
* **SPA 回退**：`try_files $uri $uri/ /index.html`。
* **反代占位**：`/api/` 与 `/ws` 指向 `api.whiteboard.example.com` 占位域名，
  上线前替换为真实后端；TLS 场景把 `listen 80` 换成 `443 ssl http2` 并加证书。
* **不使用 Docker 的替代**：把 `apps/web/build/web` 部署到任意静态服务器
  （或系统 nginx：把 `root` 指向部署目录，其余照抄本配置），保持同样的
  COOP/COEP 响应头即可满足 WASM 需求。

**未构建验证原因**：本机无 Docker；有 Docker 的环境按上述命令即可验证。

## 发布流程衔接（§15）

发布（详见 `docs/构建打包与发布设计.md` §15 与 `.github/workflows/release.yml`）：

1. `tools\scripts\version_sync.ps1 -Check` —— 版本一致性。
2. `tools\scripts\build_all.ps1` —— 构建全部产物。
3. `iscc` 编译 x64 安装包 → `dist\`。
4. `tools\scripts\sign_windows.ps1` —— （配置证书时）签名安装包与 runner 产物。
5. `tools\scripts\checksum.ps1 -Path dist -PerFile` —— 生成 `SHA256SUMS`。
6. 按 §15 流程发布 `dist\` 制品与校验和。

## 未验证清单（本机）

| 项 | 原因 |
| --- | --- |
| `iscc` 编译两个 `.iss` | 本机未安装 Inno Setup 6 |
| `docker build` / `docker run` | 本机未安装 Docker |
| nginx 实际加载 `nginx.conf`（`nginx -t`） | 本机未安装 nginx |
| x86 安装包端到端 | x86 产物默认不构建（需 32 位工具链） |
| 真实代码签名后的安装包 | 无代码签名证书 |

以上各项已做**结构级校验**：编码（BOM）、必需段（`[Setup]/[Files]/[Icons]/[Tasks]/[Run]`）、
`Source`/`OutputDir` 相对路径可解析、Dockerfile COPY 源路径存在、
nginx 配置括号平衡与关键指令存在 —— 全部 PASS（详见构建报告）。
