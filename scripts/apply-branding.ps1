# Apply PolarOS branding to a running VM over SSH (Windows / PowerShell)
#
#   .\scripts\apply-branding.ps1
#   .\scripts\apply-branding.ps1 -Port 2222 -User polaros -Key build\ssh\polaros_key

[CmdletBinding()]
param(
    [int]$Port = 2222,
    [string]$User = "polaros",
    [string]$Key = "build\ssh\polaros_key"
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$keyPath = Join-Path $root $Key

if (-not (Test-Path $keyPath)) {
    throw "SSH key not found: $keyPath"
}

$sshOpts = @(
    "-i", $keyPath,
    "-o", "StrictHostKeyChecking=no",
    "-o", "UserKnownHostsFile=NUL",
    "-o", "ConnectTimeout=15",
    "-o", "LogLevel=ERROR"
)

$files = @(
    (Join-Path $root "config\os-release"),
    (Join-Path $root "config\issue"),
    (Join-Path $root "config\motd"),
    (Join-Path $root "config\fastfetch\polaros-logo.txt"),
    (Join-Path $root "config\fastfetch\config.jsonc"),
    (Join-Path $root "scripts\provision.sh")
)

Write-Host "Uploading branding files to ${User}@127.0.0.1:$Port ..." -ForegroundColor Cyan
& scp @sshOpts -P $Port @files "${User}@127.0.0.1:/tmp/"
if ($LASTEXITCODE -ne 0) { throw "scp failed" }

Write-Host "Provisioning ..." -ForegroundColor Cyan
& ssh @sshOpts -p $Port "${User}@127.0.0.1" "bash /tmp/provision.sh"
if ($LASTEXITCODE -ne 0) { throw "provision failed" }

Write-Host "Branding applied." -ForegroundColor Green
