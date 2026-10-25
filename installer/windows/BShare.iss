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
#ifndef FirewallScriptBase64
  #error FirewallScriptBase64 must be supplied by build-installer.ps1
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
Name: "networkaccess"; Description: "{cm:PrivateNetworkAccess}"; GroupDescription: "{cm:NetworkOptions}"; Flags: unchecked

[CustomMessages]
english.NetworkOptions=Local network:
spanish.NetworkOptions=Red local:
english.PrivateNetworkAccess=Allow connections on private networks (requires administrator approval)
spanish.PrivateNetworkAccess=Permitir conexiones en redes privadas (requiere autorización de administrador)
english.FirewallFailed=Windows did not confirm the firewall configuration. BShare was installed, but receiving files or video may remain blocked. Review Windows Defender Firewall and the network-setup.log file in the installation folder. Existing Block rules are preserved.
spanish.FirewallFailed=Windows no confirmó la configuración del firewall. BShare se instaló, pero la recepción de archivos o video puede seguir bloqueada. Revisa el Firewall de Windows Defender y network-setup.log en la carpeta de instalación. Se conservan las reglas de bloqueo existentes.
english.FirewallCleanupFailed=Windows did not confirm removal of BShare's firewall rules. Review the BShare LAN entries in Windows Defender Firewall.
spanish.FirewallCleanupFailed=Windows no confirmó la eliminación de las reglas de BShare. Revisa las entradas BShare LAN en el Firewall de Windows Defender.

[Files]
Source: "{#AppSourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\BShare"; Filename: "{app}\BShare.exe"; WorkingDir: "{app}"
Name: "{autodesktop}\BShare"; Filename: "{app}\BShare.exe"; WorkingDir: "{app}"; Tasks: desktopicon

[Run]
Filename: "{app}\BShare.exe"; Description: "{cm:LaunchProgram,BShare}"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
Type: files; Name: "{app}\network-setup.log"
Type: files; Name: "{app}\bshare-firewall.json"

[Code]
function PowerShellLiteral(const Value: String): String;
var
  Escaped: String;
begin
  Escaped := Value;
  StringChangeEx(Escaped, '''', '''''', True);
  Result := '''' + Escaped + '''';
end;

function ConfigureNetwork(const Mode: String): Boolean;
var
  ResultCode: Integer;
  Parameters: String;
  Command: String;
  StatePath: String;
  CreatedState: Boolean;
begin
  StatePath := ExpandConstant('{app}\bshare-firewall.json');
  CreatedState := False;
  if (Mode = 'Add') and not FileExists(StatePath) then
  begin
    { Ensure cleanup state can be recorded before requesting elevation. }
    CreatedState := SaveStringToFile(StatePath, '{"configured":true}', False);
    if not CreatedState then
    begin
      Result := False;
      Exit;
    end;
  end;
  { Embed the reviewed payload in installer bytecode. Never elevate the
    standalone .ps1 in the user's writable installation directory. }
  Command := '$ErrorActionPreference=''Stop''; & ([ScriptBlock]::Create(' +
    '[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(''' +
    '{#FirewallScriptBase64}' + ''')))) -Mode ' + PowerShellLiteral(Mode) +
    ' -ProgramPath ' + PowerShellLiteral(ExpandConstant('{app}\BShare.exe'));
  Parameters := '-NoProfile -ExecutionPolicy Bypass -Command "' + Command + '"';
  { Elevate only the explicit network setup operation, never the application. }
  Result := ShellExec('runas',
    ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'),
    Parameters, '', SW_SHOWNORMAL, ewWaitUntilTerminated, ResultCode);
  Result := Result and (ResultCode = 0);
  { Files are written by the installer with its own user permissions. The
    elevated helper only changes this executable's firewall rules. }
  if (Result and (Mode = 'Remove')) or (not Result and CreatedState) then
    DeleteFile(StatePath);
  SaveStringToFile(ExpandConstant('{app}\network-setup.log'),
    Mode + ': Windows/PowerShell result ' + IntToStr(ResultCode) + #13#10,
    False);
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if (CurStep = ssPostInstall) and not WizardSilent and
    WizardIsTaskSelected('networkaccess') then
  begin
    if not ConfigureNetwork('Add') then
      MsgBox(CustomMessage('FirewallFailed'), mbError, MB_OK);
  end;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if (CurUninstallStep = usUninstall) and
    FileExists(ExpandConstant('{app}\bshare-firewall.json')) then
  begin
    if not ConfigureNetwork('Remove') and not UninstallSilent then
      MsgBox(CustomMessage('FirewallCleanupFailed'), mbError, MB_OK);
  end;
end;
