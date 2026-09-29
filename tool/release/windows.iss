#ifndef AppVersion
  #define AppVersion "0.4.0"
#endif
[Setup]
AppId={{BF792AC6-FB1E-4B89-9918-5D7AD5E652C7}
AppName=Tsukuyomi Space
AppVersion={#AppVersion}
AppPublisher=Tsukuyomi Space
AppPublisherURL=https://github.com/redchenk/tsukuyomi-space-app
DefaultDirName={localappdata}\Programs\Tsukuyomi Space
DefaultGroupName=Tsukuyomi Space
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=..\..\dist
OutputBaseFilename=tsukuyomi-space-{#AppVersion}-windows-x64-setup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
UninstallDisplayIcon={app}\tsukuyomi_space_app.exe
LicenseFile=..\..\THIRD_PARTY_NOTICES.md
[Files]
Source: "..\..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "..\..\docs\release-guide.md"; DestDir: "{app}"; Flags: ignoreversion
[Icons]
Name: "{group}\Tsukuyomi Space"; Filename: "{app}\tsukuyomi_space_app.exe"
Name: "{autodesktop}\Tsukuyomi Space"; Filename: "{app}\tsukuyomi_space_app.exe"; Tasks: desktopicon
[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; Flags: unchecked
[Run]
Filename: "{app}\tsukuyomi_space_app.exe"; Description: "Launch Tsukuyomi Space"; Flags: nowait postinstall skipifsilent
