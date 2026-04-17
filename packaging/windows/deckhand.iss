; Deckhand Windows installer — Inno Setup
;
; Builds an unsigned Setup.exe from the Flutter + Go build outputs:
;   - app\build\windows\x64\runner\Release\       (Flutter app)
;   - sidecar\dist\deckhand-sidecar.exe            (Go sidecar)
;   - sidecar\dist\deckhand-elevated-helper.exe    (Go elevated helper)
;
; Usage (from the deckhand repo root):
;   iscc /dVersion=0.1.0 packaging\windows\deckhand.iss
;
; CI (.github/workflows/release.yml) invokes this with the tag's
; version. Signing happens post-build if a WINDOWS_SIGN_CERT secret is
; present; unsigned otherwise.

#ifndef Version
#define Version "0.0.0-dev"
#endif

#define AppName "Deckhand"
#define AppExe  "deckhand.exe"
#define Publisher "Cepheus Labs"
#define AppURL "https://github.com/CepheusLabs/deckhand"

[Setup]
AppId={{7C5A2D0E-5C7B-4B1F-93D4-0CA0E4C2A2B1}
AppName={#AppName}
AppVersion={#Version}
AppPublisher={#Publisher}
AppPublisherURL={#AppURL}
AppSupportURL={#AppURL}
AppUpdatesURL={#AppURL}
DefaultDirName={autopf}\{#AppName}
DisableProgramGroupPage=yes
OutputDir=dist
OutputBaseFilename=Deckhand-{#Version}-win-x64
Compression=lzma
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64
ArchitecturesInstallIn64BitMode=x64
; The elevated-helper runs with UAC on demand; Deckhand itself doesn't
; need admin at install time if the user opts into per-user install.
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=commandline dialog
UninstallDisplayIcon={app}\{#AppExe}
LicenseFile=..\..\LICENSE

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; \
  GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
; Flutter build output — entire directory gets copied.
Source: "..\..\app\build\windows\x64\runner\Release\*"; DestDir: "{app}"; \
  Flags: ignoreversion recursesubdirs createallsubdirs

; Sidecar + elevated helper alongside the app exe.
Source: "..\..\sidecar\dist\deckhand-sidecar.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\..\sidecar\dist\deckhand-elevated-helper.exe"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\{#AppExe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExe}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExe}"; Description: "{cm:LaunchProgram,{#StringChange(AppName, '&', '&&')}}"; \
  Flags: nowait postinstall skipifsilent
