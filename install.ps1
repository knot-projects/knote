[CmdletBinding()]
param(
    [switch]$Uninstall,
    [switch]$NoStart
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$Repository = "knot-projects/knote"
$Program = "knot"
$DefaultInstallDirectory = Join-Path ([Environment]::GetFolderPath("LocalApplicationData")) "Programs\Knot\bin"
$InstallDirectory = if ($env:KNOT_INSTALL_DIR) { $env:KNOT_INSTALL_DIR } else { $DefaultInstallDirectory }
$InstallDirectory = [IO.Path]::GetFullPath($InstallDirectory)
$InstallPath = Join-Path $InstallDirectory "$Program.exe"
$ServerAddress = if ($env:KNOT_ADDR) { $env:KNOT_ADDR } else { "127.0.0.1:7330" }
$ServerUrl = "http://$ServerAddress"

function Start-ManagedKnot {
    if ($NoStart) {
        return
    }

    Start-Process -FilePath $InstallPath -ArgumentList @("serve", "--addr", $ServerAddress)
    Write-Host "Knot Server is starting at $ServerUrl."
}

function Stop-ManagedKnot {
    $normalizedInstallPath = [IO.Path]::GetFullPath($InstallPath)
    $managedProcesses = @(Get-Process -Name $Program -ErrorAction SilentlyContinue | Where-Object {
        try {
            [StringComparer]::OrdinalIgnoreCase.Equals(
                [IO.Path]::GetFullPath($_.Path),
                $normalizedInstallPath
            )
        }
        catch {
            $false
        }
    })

    foreach ($process in $managedProcesses) {
        Write-Host "Stopping Knot Server (PID $($process.Id))..."
        Stop-Process -Id $process.Id
        Wait-Process -Id $process.Id -Timeout 15 -ErrorAction SilentlyContinue
        if (Get-Process -Id $process.Id -ErrorAction SilentlyContinue) {
            throw "Knot Server did not stop within 15 seconds"
        }
    }
}

function Update-UserPath([bool]$Remove) {
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    $entries = @($userPath -split ";" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $matchingEntries = @($entries | Where-Object {
        [StringComparer]::OrdinalIgnoreCase.Equals($_.TrimEnd("\"), $InstallDirectory.TrimEnd("\"))
    })

    if ($Remove) {
        if ($matchingEntries.Count -gt 0) {
            $newPath = ($entries | Where-Object {
                -not [StringComparer]::OrdinalIgnoreCase.Equals($_.TrimEnd("\"), $InstallDirectory.TrimEnd("\"))
            }) -join ";"
            [Environment]::SetEnvironmentVariable("Path", $newPath, "User")
        }
        return
    }

    if ($matchingEntries.Count -eq 0) {
        $newPath = if ([string]::IsNullOrWhiteSpace($userPath)) {
            $InstallDirectory
        }
        else {
            "$InstallDirectory;$userPath"
        }
        [Environment]::SetEnvironmentVariable("Path", $newPath, "User")
        Write-Host "Added $InstallDirectory to your user PATH. Open a new terminal to use 'knot'."
    }
}

if ($Uninstall) {
    if (-not (Test-Path -LiteralPath $InstallPath -PathType Leaf)) {
        Write-Host "Knot is not installed at $InstallPath."
        return
    }

    $identity = (& $InstallPath version 2>$null | Out-String).Trim()
    if ($identity -notmatch '^knot\s+') {
        throw "$InstallPath does not identify itself as Knot"
    }

    Stop-ManagedKnot
    Remove-Item -LiteralPath $InstallPath -Force
    Update-UserPath $true
    if ((Test-Path -LiteralPath $InstallDirectory -PathType Container) -and
        @(Get-ChildItem -LiteralPath $InstallDirectory -Force).Count -eq 0) {
        Remove-Item -LiteralPath $InstallDirectory -Force
    }
    Write-Host "Knot executable removed from $InstallPath."
    Write-Host "User data was kept."
    return
}

$machineArchitecture = if ($env:PROCESSOR_ARCHITEW6432) {
    $env:PROCESSOR_ARCHITEW6432
}
else {
    $env:PROCESSOR_ARCHITECTURE
}
$TargetArchitecture = switch ($machineArchitecture.ToUpperInvariant()) {
    "AMD64" { "amd64" }
    "ARM64" { "arm64" }
    default { throw "Unsupported Windows architecture: $machineArchitecture" }
}

$headers = @{
    Accept = "application/vnd.github+json"
    "X-GitHub-Api-Version" = "2022-11-28"
}
$release = Invoke-RestMethod `
    -Uri "https://api.github.com/repos/$Repository/releases/latest" `
    -Headers $headers `
    -UserAgent "Knot-Installer" `
    -UseBasicParsing
$ReleaseTag = [string]$release.tag_name
if ($ReleaseTag -notmatch '^v[0-9]+\.[0-9]+\.[0-9]+$') {
    throw "Could not determine the latest release"
}
$TargetVersion = $ReleaseTag.Substring(1)
$AssetName = "knot-$ReleaseTag-windows-$TargetArchitecture.exe"
$matchingAssets = @($release.assets | Where-Object { $_.name -eq $AssetName })
if ($matchingAssets.Count -ne 1) {
    throw "Release $ReleaseTag does not contain $AssetName"
}
$asset = $matchingAssets[0]
$digest = [string]$asset.digest
if ($digest -notmatch '^sha256:([0-9a-fA-F]{64})$') {
    throw "GitHub release metadata has no valid SHA-256 digest for $AssetName"
}
$ExpectedChecksum = $Matches[1].ToLowerInvariant()

$CurrentVersion = ""
if (Test-Path -LiteralPath $InstallPath -PathType Leaf) {
    $currentIdentity = (& $InstallPath version 2>$null | Out-String).Trim()
    if ($currentIdentity -match '^knot\s+(.+)$') {
        $CurrentVersion = $Matches[1]
    }
}
if ($CurrentVersion -eq $TargetVersion) {
    Write-Host "Knot $TargetVersion is already installed at $InstallPath."
    Update-UserPath $false
    Start-ManagedKnot
    return
}

if ($CurrentVersion) {
    Write-Host "Upgrading Knot $CurrentVersion to $TargetVersion..."
}
else {
    Write-Host "Installing Knot $TargetVersion..."
}

$TemporaryDirectory = Join-Path ([IO.Path]::GetTempPath()) ("knot-install-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $TemporaryDirectory | Out-Null
try {
    $SourceBinary = Join-Path $TemporaryDirectory $AssetName
    Invoke-WebRequest `
        -Uri ([string]$asset.browser_download_url) `
        -OutFile $SourceBinary `
        -Headers @{ Accept = "application/octet-stream" } `
        -UserAgent "Knot-Installer" `
        -UseBasicParsing

    $ActualChecksum = (Get-FileHash -LiteralPath $SourceBinary -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($ActualChecksum -ne $ExpectedChecksum) {
        throw "Checksum verification failed for $AssetName"
    }
    Write-Host "Checksum verified against GitHub release metadata."

    if (-not (Test-Path -LiteralPath $SourceBinary -PathType Leaf)) {
        throw "Downloaded asset is missing $Program.exe"
    }
    $DownloadedIdentity = (& $SourceBinary version 2>$null | Out-String).Trim()
    if ($DownloadedIdentity -ne "knot $TargetVersion") {
        throw "Downloaded binary failed version verification"
    }

    Stop-ManagedKnot
    New-Item -ItemType Directory -Path $InstallDirectory -Force | Out-Null
    Copy-Item -LiteralPath $SourceBinary -Destination $InstallPath -Force

    $InstalledIdentity = (& $InstallPath version 2>$null | Out-String).Trim()
    if ($InstalledIdentity -ne "knot $TargetVersion") {
        throw "Installed binary failed version verification"
    }
}
finally {
    if (Test-Path -LiteralPath $TemporaryDirectory) {
        Remove-Item -LiteralPath $TemporaryDirectory -Recurse -Force
    }
}

Update-UserPath $false
Write-Host "Knot $TargetVersion installed at $InstallPath."
Start-ManagedKnot
