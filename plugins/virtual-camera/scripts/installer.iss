#ifndef ProductVersion
  #define ProductVersion "0.1.0"
#endif
#ifndef BinaryDirectory
  #error BinaryDirectory must point to a Release build
#endif
#ifndef PackageDirectory
  #define PackageDirectory "..\..\..\dist\virtual-camera\packages"
#endif
[Setup]
AppId={{0CD4E9D7-C9BB-47DA-A462-74D083772C89}
AppName=BShare Virtual Camera
AppVersion={#ProductVersion}
AppPublisher=BShare
AppPublisherURL=https://github.com/BryamContreras/BShare
DefaultDirName={autopf}\BShare\VirtualCamera\{#ProductVersion}
DisableDirPage=yes
DisableProgramGroupPage=yes
UsePreviousAppDir=no
CloseApplications=no
RestartApplications=no
PrivilegesRequired=admin
ArchitecturesAllowed=x64os
ArchitecturesInstallIn64BitMode=x64os
MinVersion=10.0.22000
OutputDir={#PackageDirectory}
OutputBaseFilename=bshare-virtual-camera-{#ProductVersion}-windows-x64-setup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
UninstallDisplayName=BShare Virtual Camera
LicenseFile=..\MICROSOFT-LICENSE
[Files]
Source: "{#BinaryDirectory}\bshare-virtual-camera.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#BinaryDirectory}\bshare-camera.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\MICROSOFT-LICENSE"; DestDir: "{app}\licenses"; Flags: ignoreversion
Source: "..\README.md"; DestDir: "{app}"; Flags: ignoreversion
[Code]
procedure CurStepChanged(CurStep: TSetupStep);
var Code: Integer;
begin
  if CurStep = ssPostInstall then begin
    if not Exec(ExpandConstant('{app}\bshare-camera.exe'),
      '--register-source "' + ExpandConstant('{app}\bshare-virtual-camera.dll') + '"',
      '', SW_HIDE, ewWaitUntilTerminated, Code) or (Code <> 0) then
      RaiseException('Could not register the BShare camera component. Error: ' + IntToStr(Code));
    // Camera registration must run with the original user's identity, even
    // when UAC requested credentials belonging to a different administrator.
    if not ExecAsOriginalUser(ExpandConstant('{app}\bshare-camera.exe'), '--install',
      '', SW_HIDE, ewWaitUntilTerminated, Code) or (Code <> 0) then
      Log('The original user camera will be registered when BShare next starts.');
  end;
end;
procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var Code: Integer;
begin
  if CurUninstallStep = usUninstall then begin
    // Removes this account's device; other accounts remove theirs from BShare.
    Exec(ExpandConstant('{app}\bshare-camera.exe'), '--uninstall', '', SW_HIDE, ewWaitUntilTerminated, Code);
    Exec(ExpandConstant('{app}\bshare-camera.exe'),
      '--unregister-source "' + ExpandConstant('{app}\bshare-virtual-camera.dll') + '"',
      '', SW_HIDE, ewWaitUntilTerminated, Code);
  end;
end;
