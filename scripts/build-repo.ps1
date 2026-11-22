# Build PolarOS .deb packages and the signed apt repository (Windows / PowerShell)
#
#   .\scripts\build-repo.ps1          # build packages + repository
#   .\scripts\build-repo.ps1 -Serve   # build, then serve on http://127.0.0.1:8080
#
# Output:
#   build/repo/                       apt repository (dists + pool)
#   build/keys/polaros-archive-keyring.asc   public key
#   build/keys/gnupg/                 signing key (keep private!)

[CmdletBinding()]
param(
    [switch]$Serve,
    [int]$Port = 8080
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    throw "docker not found in PATH."
}

Write-Host "Building packages and repository in a Debian container ..." -ForegroundColor Cyan
docker run --rm --platform linux/amd64 `
    -v "${root}:/work" -w /work debian:trixie-slim `
    bash -c "apt-get update -qq && apt-get install -y -qq --no-install-recommends dpkg-dev gnupg apt-utils gzip >/dev/null 2>&1 && bash scripts/build-repo.sh"

if ($LASTEXITCODE -ne 0) { throw "repository build failed" }

Write-Host "Repository: build\repo" -ForegroundColor Green
Write-Host "Public key: build\keys\polaros-archive-keyring.asc" -ForegroundColor Green

if ($Serve) {
    Write-Host "Serving build\repo on http://127.0.0.1:$Port (Ctrl+C to stop)" -ForegroundColor Yellow
    Write-Host "From the VM use http://10.0.2.2:$Port" -ForegroundColor DarkGray
    Push-Location (Join-Path $root "build\repo")
    try { python -m http.server $Port --bind 0.0.0.0 }
    finally { Pop-Location }
}
