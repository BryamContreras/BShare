; Compile through build-installer.ps1 so version and staged payload are checked.
#ifndef AppVersion
  #error AppVersion must be supplied by build-installer.ps1
#endif
#ifndef AppFileVersion
  #error AppFileVersion must be supplied by build-installer.ps1
#endif
#ifndef AppFullVersion
  #error AppFullVersion must be supplied by build-installer.ps1
#endif
#ifndef AppSourceDir
  #error AppSourceDir must be supplied by build-installer.ps1
#endif
#ifndef AppOutputDir
  #error AppOutputDir must be supplied by build-installer.ps1
#endif

[Setup]
AppId={{B7BB9A02-7C54-4DD3-A239-3FA13514A93F}
AppName=BShare
AppVersion={#AppVersion}
AppVerName=BShare {#AppFullVersion}
AppPublisher=BShare
VersionInfoVersion={#AppFileVersion}
VersionInfoProductName=BShare
VersionInfoCompany=BShare
VersionInfoDescription=BShare installer
VersionInfoProductVersion={#AppFileVersion}
VersionInfoProductTextVersion={#AppFullVersion}
DefaultDirName={localappdata}\Programs\BShare
DefaultGroupName=BShare
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
UninstallDisplayIcon={app}\BShare.exe
SetupIconFile=..\..\windows\runner\resources\app_icon.ico
OutputDir={#AppOutputDir}
OutputBaseFilename=BShare-{#AppFullVersion}-windows-x64-setup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes
RestartApplications=no

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "spanish"; MessagesFile: "compiler:Languages\Spanish.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#AppSourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\BShare"; Filename: "{app}\BShare.exe"; WorkingDir: "{app}"
Name: "{autodesktop}\BShare"; Filename: "{app}\BShare.exe"; WorkingDir: "{app}"; Tasks: desktopicon

[Run]
Filename: "{app}\BShare.exe"; Description: "{cm:LaunchProgram,BShare}"; Flags: nowait postinstall skipifsilent
