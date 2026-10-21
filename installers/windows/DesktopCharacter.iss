#ifndef AppVersion
  #error AppVersion must be provided by the build script
#endif
#ifndef ProjectRoot
  #error ProjectRoot must be provided by the build script
#endif

[Setup]
AppId={{59A3070C-5D26-4D9A-AFEA-7D940039B3BA}
AppName=DesktopCharacter
AppVersion={#AppVersion}
AppPublisher=Siwoo125
AppPublisherURL=https://github.com/Siwoo125/Desktop_character
AppSupportURL=https://github.com/Siwoo125/Desktop_character/issues
DefaultDirName={localappdata}\Programs\DesktopCharacter
DefaultGroupName=DesktopCharacter
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
OutputDir={#ProjectRoot}\dist
OutputBaseFilename=DesktopCharacter-{#AppVersion}-Windows-x64-Setup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
UninstallDisplayIcon={app}\DesktopCharacter.exe
CloseApplications=yes
RestartApplications=no
DisableProgramGroupPage=yes
SetupLogging=yes

[Languages]
Name: "korean"; MessagesFile: "compiler:Languages\Korean.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Files]
Source: "{#ProjectRoot}\dist\windows\DesktopCharacter\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\DesktopCharacter"; Filename: "{app}\DesktopCharacter.exe"

[Run]
Filename: "{app}\DesktopCharacter.exe"; Description: "DesktopCharacter 실행 / Launch DesktopCharacter"; Flags: nowait postinstall skipifsilent
