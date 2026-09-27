; ============================================================================
; inno_setup_x86.iss — Whiteboard Windows installer (x86).
; ============================================================================
; Implements docs/构建打包与发布设计.md §11.2, adapted to the real repository
; layout. This file is UTF-8 with BOM (required by Inno Setup 6 for the
; non-ASCII UI strings below) — keep the BOM when editing.
;
; NOTE: the x86 desktop runner is not built by default. To produce one, a
; 32-bit Flutter/CMake toolchain and a 32-bit wb_core.dll are required; the
; primary target is x64 (see docs §6/§7).
;
; Build (Inno Setup 6, iscc.exe — not installed on the dev machine):
;   iscc tools\packaging\windows\inno_setup_x86.iss
;
; Input (must exist first):
;   apps\desktop\build\windows\x86\runner\Release\*
;
; Output (docs §11.3):
;   dist\whiteboard-1.0.0-windows-x86.exe
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
OutputBaseFilename=whiteboard-1.0.0-windows-x86
Compression=lzma2
SolidCompression=yes
ArchitecturesAllowed=x86
; SetupIconFile=assets\icon.ico   ; enable once an .ico exists (none shipped yet)
UninstallDisplayIcon={app}\whiteboard_desktop.exe

[Files]
Source: "..\..\..\apps\desktop\build\windows\x86\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs

[Icons]
Name: "{group}\Whiteboard"; Filename: "{app}\whiteboard_desktop.exe"
Name: "{group}\卸载 Whiteboard"; Filename: "{uninstallexe}"
Name: "{autodesktop}\Whiteboard"; Filename: "{app}\whiteboard_desktop.exe"; Tasks: desktopicon

[Tasks]
Name: "desktopicon"; Description: "创建桌面快捷方式"; GroupDescription: "附加图标:"

[Run]
Filename: "{app}\whiteboard_desktop.exe"; Description: "启动 Whiteboard"; Flags: nowait postinstall skipifsilent
