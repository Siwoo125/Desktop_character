$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
$version = (Get-Content (Join-Path $projectRoot 'VERSION') -Raw).Trim()
$toolDir = Join-Path $projectRoot '.build/inno-setup-7.1.0'
$download = Join-Path $projectRoot '.build/innosetup-7.1.0-x64.exe'
New-Item -ItemType Directory -Force (Join-Path $projectRoot '.build') | Out-Null
# Official release asset, pinned independently of the download connection.
Invoke-WebRequest 'https://github.com/jrsoftware/issrc/releases/download/is-7_1_0/innosetup-7.1.0-x64.exe' -OutFile $download
$expected = '0362a383ed217d4c4239b5933866dd96d3eb2102737da92f80f6057a4b40df2f'
if ((Get-FileHash $download -Algorithm SHA256).Hash.ToLowerInvariant() -ne $expected) {
    throw 'Inno Setup download SHA256 mismatch'
}
$install = Start-Process -FilePath $download -ArgumentList "/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP- /CURRENTUSER /DIR=`"$toolDir`"" -Wait -PassThru
if ($install.ExitCode -ne 0) { throw "Inno Setup installation failed: $($install.ExitCode)" }
& (Join-Path $toolDir 'ISCC.exe') "/DAppVersion=$version" "/DProjectRoot=$projectRoot" (Join-Path $projectRoot 'installers/windows/DesktopCharacter.iss')
if ($LASTEXITCODE -ne 0) { throw 'Installer compilation failed' }
