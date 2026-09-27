; ============================================================================
; inno_setup_x64.iss — Whiteboard Windows installer (x64).
; ============================================================================
; Implements docs/构建打包与发布设计.md §11.1, adapted to the real repository
; layout. This file is UTF-8 with BOM (required by Inno Setup 6 for the
; non-ASCII UI strings below) — keep the BOM when editing.
;
; Build (Inno Setup 6, iscc.exe — not installed on the dev machine):
;   iscc tools\packaging\windows\inno_setup_x64.iss
;
; Input (must exist first):
;   apps\desktop\build\windows\x64\runner\Release\*
;     built by `flutter build windows --release` (tools\scripts\build_flutter.ps1
;     -Target windows); contains whiteboard_desktop.exe, flutter_windows.dll,
;     wb_core.dll and the plugin DLLs.
;
; Output (docs §11.3):
;   dist\whiteboard-1.0.0-windows-x64.exe
;
; Version handling (docs §16): the VERSION file at the repository root is the
; single source of truth. Bump AppVersion and OutputBaseFilename together with
; it and validate using `tools\scripts\version_sync.ps1 -Check`.
;
; Relative paths below are resolved against this file's directory
; (tools\packaging\windows\), hence three "..\" levels up to the repo root.
; ============================================================================

[Setup]
AppName=Whiteboard
AppVersion=1.0.0
AppPublisher=Example Inc
DefaultDirName={autopf}\Whiteboard
DefaultGroupName=Whiteboard
OutputDir=..\..\..\dist
OutputBaseFilename=whiteboard-1.0.0-windows-x64
Compression=lzma2
SolidCompression=yes
ArchitecturesAllowed=x64
ArchitecturesInstallIn64BitMode=x64
; SetupIconFile=assets\icon.ico   ; enable once an .ico exists (none shipped yet)
UninstallDisplayIcon={app}\whiteboard_desktop.exe

[Files]
Source: "..\..\..\apps\desktop\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs

[Icons]
Name: "{group}\Whiteboard"; Filename: "{app}\whiteboard_desktop.exe"
Name: "{group}\卸载 Whiteboard"; Filename: "{uninstallexe}"
Name: "{autodesktop}\Whiteboard"; Filename: "{app}\whiteboard_desktop.exe"; Tasks: desktopicon

[Tasks]
Name: "desktopicon"; Description: "创建桌面快捷方式"; GroupDescription: "附加图标:"

[Run]
Filename: "{app}\whiteboard_desktop.exe"; Description: "启动 Whiteboard"; Flags: nowait postinstall skipifsilent
