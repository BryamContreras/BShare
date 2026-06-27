param(
    [string]$Alias = 'bshare',
    [string]$KeystorePath = 'android/upload-keystore.jks'
)

$ErrorActionPreference = 'Stop'

$root = Resolve-Path (Join-Path $PSScriptRoot '..')
Set-Location $root

$keytool = Get-Command keytool -ErrorAction SilentlyContinue
if (-not $keytool) {
    throw 'keytool was not found. Install a JDK or use Android Studio JBR on PATH.'
}

if (Test-Path -LiteralPath $KeystorePath) {
    throw "Keystore already exists: $KeystorePath"
}

$securePassword = Read-Host 'Upload key password' -AsSecureString
$bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePassword)
try {
    $password = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
} finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
}

if ([string]::IsNullOrWhiteSpace($password)) {
    throw 'Password cannot be empty.'
}

$keystoreFullPath = [System.IO.Path]::GetFullPath((Join-Path $root $KeystorePath))
$keystoreDir = Split-Path -Parent $keystoreFullPath
New-Item -ItemType Directory -Path $keystoreDir -Force | Out-Null

& $keytool.Source `
    -genkeypair `
    -v `
    -keystore $keystoreFullPath `
    -storetype JKS `
    -keyalg RSA `
    -keysize 2048 `
    -validity 10000 `
    -alias $Alias `
    -storepass $password `
    -keypass $password `
    -dname 'CN=BShare, OU=BShare, O=BShare, L=Local, S=Local, C=US'

$appProjectDir = [System.IO.Path]::GetFullPath((Join-Path $root 'android/app'))
$relativeStoreFile = [System.IO.Path]::GetRelativePath($appProjectDir, $keystoreFullPath).Replace('\', '/')
Set-Content -Path 'android/key.properties' -Encoding UTF8 -Value @"
storePassword=$password
keyPassword=$password
keyAlias=$Alias
storeFile=$relativeStoreFile
"@

Write-Host 'Android upload key created.'
Write-Host 'Keep android/upload-keystore.jks and android/key.properties private and backed up.'
