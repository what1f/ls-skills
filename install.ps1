# Install a CLI from ls-skills GitHub Releases on Windows.
#
#   & ([scriptblock]::Create((irm https://raw.githubusercontent.com/what1f/ls-skills/main/install.ps1))) <tool> [version]
#
# Env: LS_INSTALL_DIR (default %LOCALAPPDATA%\ls-skills\bin), GITHUB_TOKEN (optional).
param(
    [Parameter(Mandatory = $true)][string]$Tool,
    [string]$Version = ''
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$Repo = 'what1f/ls-skills'
if ($Tool -notmatch '^[a-z0-9-]+$') { throw "invalid tool name: $Tool" }
$Dir = if ($env:LS_INSTALL_DIR) { $env:LS_INSTALL_DIR } else { Join-Path $env:LOCALAPPDATA 'ls-skills\bin' }
$Arch = switch ($env:PROCESSOR_ARCHITECTURE) {
    'AMD64' { 'amd64' }
    'ARM64' { 'arm64' }
    default { throw "unsupported architecture $env:PROCESSOR_ARCHITECTURE" }
}
$Asset = "$Tool-windows-$Arch.exe"
$Headers = @{ 'User-Agent' = 'ls-skills-installer' }
if ($env:GITHUB_TOKEN) { $Headers['Authorization'] = "Bearer $env:GITHUB_TOKEN" }

if ($Version) {
    $Tag = "$Tool-v$($Version.TrimStart('v'))"
} else {
    $pattern = '^' + [regex]::Escape($Tool) + '-v\d+\.\d+\.\d+$'
    $Tag = Invoke-RestMethod "https://api.github.com/repos/$Repo/releases?per_page=100" -Headers $Headers |
        Where-Object { -not $_.draft -and -not $_.prerelease -and $_.tag_name -match $pattern -and ($_.assets.name -contains $Asset) } |
        Select-Object -First 1 -ExpandProperty tag_name
    if (-not $Tag) { throw "no release with $Asset found for $Tool" }
}

$Base = "https://github.com/$Repo/releases/download/$Tag"
$Tmp = Join-Path ([IO.Path]::GetTempPath()) ([IO.Path]::GetRandomFileName())
New-Item -ItemType Directory -Path $Tmp | Out-Null
try {
    Invoke-WebRequest "$Base/$Asset" -OutFile (Join-Path $Tmp $Asset) -Headers $Headers
    Invoke-WebRequest "$Base/checksums.txt" -OutFile (Join-Path $Tmp 'checksums.txt') -Headers $Headers
    $line = Get-Content (Join-Path $Tmp 'checksums.txt') | Where-Object { ($_ -split '\s+')[1] -eq $Asset }
    $expected = ($line -split '\s+')[0]
    $actual = (Get-FileHash (Join-Path $Tmp $Asset) -Algorithm SHA256).Hash.ToLower()
    if (-not $expected -or $expected -ne $actual) { throw "checksum mismatch for $Asset" }

    New-Item -ItemType Directory -Force -Path $Dir | Out-Null
    Move-Item -Force (Join-Path $Tmp $Asset) (Join-Path $Dir "$Tool.exe")
} finally {
    Remove-Item -Recurse -Force $Tmp
}
Write-Host "installed $Tool $($Tag.Substring($Tool.Length + 2)) to $Dir\$Tool.exe"

$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if (($userPath -split ';') -notcontains $Dir) {
    [Environment]::SetEnvironmentVariable('Path', "$userPath;$Dir", 'User')
    Write-Host "added $Dir to your user PATH; restart the terminal to use $Tool"
}
