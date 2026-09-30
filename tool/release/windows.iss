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
Filename: "{app}\MicrosoftEdgeWebview2Setup.exe"; Parameters: "/silent /install"; StatusMsg: "Installing Microsoft Edge WebView2 for QQ sign-in..."; Flags: runhidden; Check: NeedsWebView2
Filename: "{app}\tsukuyomi_space_app.exe"; Description: "Launch Tsukuyomi Space"; Flags: nowait postinstall skipifsilent
[Code]
function NeedsWebView2: Boolean;
var
  Version: String;
  RuntimeKey: String;
begin
  RuntimeKey := 'Software\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}';
  Result := not ((RegQueryStringValue(HKLM32, RuntimeKey, 'pv', Version) and
    (Version <> '') and (Version <> '0.0.0.0')) or
    (RegQueryStringValue(HKCU, RuntimeKey, 'pv', Version) and
    (Version <> '') and (Version <> '0.0.0.0')));
end;
