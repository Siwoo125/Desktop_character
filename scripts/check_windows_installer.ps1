$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
$version = (Get-Content (Join-Path $projectRoot 'VERSION') -Raw).Trim()
$setup = Join-Path $projectRoot "dist/DesktopCharacter-$version-Windows-x64-Setup.exe"
$destination = Join-Path $projectRoot '.build/installed-windows'
$report = Join-Path $projectRoot '.build/installed-checks.log'
$userData = Join-Path $env:LOCALAPPDATA 'DesktopFriends'
New-Item -ItemType Directory -Force $userData | Out-Null
$sentinel = Join-Path $userData "installer-preserve-$([guid]::NewGuid()).txt"
Set-Content $sentinel 'keep-user-data'
try {
    $install = Start-Process -FilePath $setup -ArgumentList "/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP- /DIR=`"$destination`"" -Wait -PassThru
    if ($install.ExitCode -ne 0) { throw "App installation failed: $($install.ExitCode)" }
    $exe = Join-Path $destination 'DesktopCharacter.exe'
    foreach ($file in @($exe, (Join-Path $destination 'unins000.exe'), (Join-Path $destination 'licenses/Qt-6.10.2/pyside-setup/LICENSES/LGPL-3.0-only.txt'))) {
        if (!(Test-Path $file)) { throw "Installed file missing: $file" }
    }
    $info = Get-Content (Join-Path $destination 'BUILD-INFO.json') -Raw | ConvertFrom-Json
    if ($info.version -ne $version -or $info.commit -ne (git -C $projectRoot rev-parse HEAD)) {
        throw 'Installed application version or build commit mismatch'
    }
    # Silent installation must not start a desktop pet on a headless runner.
    if (Get-Process DesktopCharacter -ErrorAction SilentlyContinue) { throw 'Silent installer unexpectedly launched the app' }
    $test = Start-Process -FilePath $exe -ArgumentList "--self-test --validate-assets --widget-check --check-report `"$report`"" -WorkingDirectory $projectRoot -Wait -PassThru
    if (Test-Path $report) { Get-Content $report }
    if ($test.ExitCode -ne 0) { throw "Installed app checks failed: $($test.ExitCode)" }
    $uninstall = Start-Process -FilePath (Join-Path $destination 'unins000.exe') -ArgumentList '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART' -Wait -PassThru
    if ($uninstall.ExitCode -ne 0) { throw "App removal failed: $($uninstall.ExitCode)" }
    if (Test-Path $exe) { throw 'Uninstaller left the application executable' }
    if (!(Test-Path $sentinel)) { throw 'Uninstaller removed user data' }
    Write-Output 'PASS: Windows installer, installed EXE, silent launch suppression and user-data-preserving uninstall'
} finally {
    Remove-Item $sentinel -ErrorAction SilentlyContinue
}
