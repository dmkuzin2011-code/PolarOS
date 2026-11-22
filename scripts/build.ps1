# PolarOS Build Orchestration (Windows / PowerShell)
#
#   .\scripts\build.ps1                          # build all: ISO + SBC + Docker
#   .\scripts\build.ps1 -Target iso              # build ISO only
#   .\scripts\build.ps1 -Target sbc --board rpi4 # build Raspberry Pi 4 image
#   .\scripts\build.ps1 -Target repo             # build apt repository
#   .\scripts\build.ps1 -Target docker           # build Docker image
#   .\scripts\build.ps1 -Target iso -Serve       # build ISO + serve it on HTTP
#   .\scripts\build.ps1 -Target iso -NoAccount   # ISO without UNIX account (root, no password)
#   .\scripts\build.ps1 -Target iso -Fast        # fast ISO (gzip squashfs, fewer packages)
#
# Prerequisites:
#   - Docker Desktop running (with WSL2 backend)
#   - QEMU for Windows (for testing ISO after build)

[CmdletBinding()]
param(
    [ValidateSet('all', 'iso', 'sbc', 'repo', 'docker')]
    [string]$Target = 'all',

    [string]$Board = 'rpi4',

    [switch]$Serve,

    [switch]$NoAccount,

    [switch]$Fast,

    [int]$SshPort = 2222
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$buildDir = Join-Path $root "build"

function Write-Step {
    param([string]$Message)
    Write-Host "`n>> $Message" -ForegroundColor Cyan
}

function Test-Requirements {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        throw "docker not found. Install Docker Desktop and make sure it is running."
    }
    $ver = docker version --format "{{.Server.Version}}" 2>&1
    if (-not $?) { throw "Docker Desktop is not running." }
    Write-Host "Docker: $ver" -ForegroundColor DarkGray
}

# ---------------------------------------------------------------------------
# Targets
# ---------------------------------------------------------------------------
function Build-Repo {
    Write-Step "Building apt repository"
    docker run --rm --platform linux/amd64 `
        -v "${root}:/work" -w /work debian:trixie-slim `
        bash -c "apt-get update -qq && apt-get install -y -qq --no-install-recommends dpkg-dev gnupg apt-utils gzip >/dev/null 2>&1 && bash scripts/build-repo.sh"
    if ($LASTEXITCODE -ne 0) { throw "Repository build failed" }
}

function Build-ISO {
    Write-Step "Building PolarOS live ISO (ARM64)"
    $log = Join-Path $buildDir "iso-build.log"
    $err = Join-Path $buildDir "iso-build.err"
    Remove-Item $log, $err -ErrorAction SilentlyContinue

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "docker.exe"
    $envArgs = ''
    if ($NoAccount) { $envArgs += '-e "POLAROS_NO_ACCOUNT=1" ' }
    if ($Fast) { $envArgs += '-e "POLAROS_FAST=1" ' }

    # Mount a host-side apt cache so repeated builds re-download fewer packages.
    $aptCache = Join-Path $buildDir "apt-cache"
    if (-not (Test-Path $aptCache)) { New-Item -ItemType Directory -Path $aptCache -Force | Out-Null }
    $envArgs += '-v "{0}:/var/cache/apt/archives" ' -f $aptCache

    $psi.Arguments = ('run --rm --privileged --platform linux/arm64 {0}-v "{1}:/work" -w /work debian:trixie-slim bash scripts/build-iso.sh' -f $envArgs, $root)
    $psi.WorkingDirectory = $root
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true

    $p = [System.Diagnostics.Process]::Start($psi)
    $p.Id | Out-File (Join-Path $buildDir "iso.pid")
    Write-Host "  PID: $($p.Id) (building in background)" -ForegroundColor DarkGray

    # Wait for completion or timeout.
    $timeout = New-TimeSpan -Minutes 30
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while (-not $p.HasExited -and $sw.Elapsed -lt $timeout) {
        Start-Sleep -Seconds 10
        $logLines = Get-Content $log -ErrorAction SilentlyContinue | Select-String "==>" | ForEach-Object { $_.Line } | Select-Object -Last 1
        if ($logLines) { Write-Host "  $logLines" -ForegroundColor DarkGray }
    }

    if ($p.HasExited) {
        $p.WaitForExit()
        if ($p.ExitCode -eq 0) {
            $iso = Get-ChildItem (Join-Path $buildDir "*.iso") -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($iso) {
                Write-Host "  ISO ready: $($iso.Name) ($([math]::Round($iso.Length/1MB,1)) MB)" -ForegroundColor Green
            } else {
                Write-Host "  ISO build finished but no .iso found in build/" -ForegroundColor Yellow
            }
        } else {
            Write-Host "  ISO build FAILED (exit $($p.ExitCode))" -ForegroundColor Red
            Get-Content $err -ErrorAction SilentlyContinue | Select-Object -Last 5 | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
        }
    } else {
        Write-Host "  ISO build still running (30 min timeout reached)" -ForegroundColor Yellow
        Write-Host "  Monitor with: Get-Content build\iso-build.log" -ForegroundColor DarkGray
    }
}

function Build-SBC {
    Write-Step "Building SBC image for $Board"
    docker run --rm --privileged --platform linux/arm64 `
        -v "${root}:/work" -w /work debian:trixie-slim `
        bash -c "apt-get update -qq && apt-get install -y -qq --no-install-recommends dpkg-dev gnupg apt-utils gzip >/dev/null 2>&1 && bash scripts/build-sbc.sh --board $Board"
    if ($LASTEXITCODE -ne 0) { throw "SBC build failed" }
}

function Build-Docker {
    Write-Step "Building Docker image"
    docker buildx build --platform linux/arm64 -t polaros:1.0-arm64 --load .
    if ($LASTEXITCODE -ne 0) { throw "Docker build failed" }
    $img = docker images polaros --format "{{.Repository}}:{{.Tag}}  {{.Size}}"
    Write-Host "  $img" -ForegroundColor Green
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
Test-Requirements

switch ($Target) {
    'all' {
        Build-Repo
        Build-ISO
        Build-SBC
        Build-Docker
    }
    'repo'  { Build-Repo }
    'iso'   { Build-ISO }
    'sbc'   { Build-SBC }
    'docker' { Build-Docker }
}

if ($Serve -and (Test-Path (Join-Path $buildDir "*.iso"))) {
    $iso = Get-ChildItem (Join-Path $buildDir "*.iso") | Select-Object -First 1
    Write-Host "`nServing build/$($iso.Name) on http://127.0.0.1:8080" -ForegroundColor Yellow
    Write-Host "From the VM use http://10.0.2.2:8080" -ForegroundColor DarkGray
    Push-Location $buildDir
    try { python -m http.server 8080 --bind 0.0.0.0 }
    finally { Pop-Location }
}
