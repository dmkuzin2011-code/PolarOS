# PolarOS container image builder (Windows / PowerShell)
#
# Builds an ARM64 image on any host: Docker Desktop uses binfmt/QEMU to
# emulate aarch64 when the host is x86_64.
#
#   .\scripts\docker-build.ps1            # build
#   .\scripts\docker-build.ps1 -Run       # build and open a shell
#   .\scripts\docker-build.ps1 -Compose   # build via docker compose

[CmdletBinding()]
param(
    [string]$Tag = "polaros:1.0-arm64",
    [string]$Platform = "linux/arm64",
    [switch]$Run,
    [switch]$Compose
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    throw "docker not found in PATH. Install Docker Desktop and make sure it is running."
}

Push-Location $root
try {
    if ($Compose) {
        Write-Host "Building via docker compose ..." -ForegroundColor Cyan
        docker compose build
        if ($LASTEXITCODE -ne 0) { throw "docker compose build failed" }
        Write-Host "Starting container ..." -ForegroundColor Cyan
        docker compose run --rm polaros
        return
    }

    Write-Host "Building $Tag for $Platform ..." -ForegroundColor Cyan
    docker buildx build --platform $Platform -t $Tag --load .
    if ($LASTEXITCODE -ne 0) { throw "docker buildx build failed" }

    Write-Host "Built: $Tag" -ForegroundColor Green

    if ($Run) {
        Write-Host "Opening shell ..." -ForegroundColor Cyan
        docker run --rm -it --platform $Platform $Tag
    }
}
finally {
    Pop-Location
}
