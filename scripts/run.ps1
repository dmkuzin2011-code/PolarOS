# PolarOS QEMU launcher (Windows / PowerShell)
#
# Boots the PolarOS disk image on an emulated ARM64 "virt" machine with
# UEFI firmware. Serial console is attached to this terminal.
#
#   .\scripts\run.ps1              # boot with serial console
#   .\scripts\run.ps1 -Memory 4096 # more RAM
#   .\scripts\run.ps1 -Ssh         # print SSH command and boot in background

[CmdletBinding()]
param(
    [string]$Image = "",
    [int]$Memory = 2048,
    [int]$Cpus = 4,
    [int]$SshPort = 2222,
    [switch]$Ssh
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot

if (-not $Image) {
    $candidates = @(
        (Join-Path $root "build\polaros-arm64.qcow2"),
        (Join-Path $root "vendor\debian-13-generic-arm64.qcow2")
    )
    $Image = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
}
if (-not $Image -or -not (Test-Path $Image)) {
    throw "Disk image not found. Expected build\polaros-arm64.qcow2"
}

function Find-Qemu {
    $cmd = Get-Command qemu-system-aarch64 -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    foreach ($p in @("C:\Program Files\qemu\qemu-system-aarch64.exe", "C:\Program Files (x86)\qemu\qemu-system-aarch64.exe")) {
        if (Test-Path $p) { return $p }
    }
    throw "qemu-system-aarch64 not found. Install QEMU for Windows."
}

function Find-Firmware {
    $qemuDir = Split-Path -Parent (Find-Qemu)
    foreach ($p in @(
        (Join-Path $qemuDir "share\edk2-aarch64-code.fd"),
        (Join-Path $root "build\uefi-aarch64.fd")
    )) {
        if (Test-Path $p) { return $p }
    }
    throw "AArch64 UEFI firmware (edk2-aarch64-code.fd) not found."
}

$qemu = Find-Qemu
$firmware = Find-Firmware

$qemuArgs = @(
    "-M", "virt",
    "-cpu", "max",
    "-smp", "$Cpus",
    "-m", "$Memory",
    "-bios", $firmware,
    "-drive", "file=$Image,if=virtio,format=qcow2,cache=writeback",
    "-netdev", "user,id=net0,hostfwd=tcp::$SshPort-:22",
    "-device", "virtio-net-pci,netdev=net0",
    "-device", "virtio-rng-pci",
    "-device", "qemu-xhci",
    "-device", "usb-kbd"
)

Write-Host "PolarOS :: $Image" -ForegroundColor Cyan
Write-Host "  machine : virt (aarch64)   ram: ${Memory}MB   cpus: $Cpus" -ForegroundColor DarkGray
Write-Host "  ssh     : ssh -p $SshPort polaros@127.0.0.1  (password: polaros)" -ForegroundColor DarkGray
Write-Host "  exit    : Ctrl+A then X" -ForegroundColor DarkGray

if ($Ssh) {
    $proc = Start-Process -FilePath $qemu -ArgumentList $qemuArgs `
        -RedirectStandardError (Join-Path $root "build\qemu.err") -PassThru -WindowStyle Hidden
    Write-Host "  pid     : $($proc.Id) (running in background)" -ForegroundColor DarkGray
    Write-Host "Waiting for SSH on port $SshPort ..." -ForegroundColor Yellow
    for ($i = 0; $i -lt 60; $i++) {
        Start-Sleep -Seconds 2
        if ((Test-NetConnection 127.0.0.1 -Port $SshPort -InformationLevel Quiet -WarningAction SilentlyContinue)) {
            Write-Host "SSH is up: ssh -p $SshPort polaros@127.0.0.1" -ForegroundColor Green
            break
        }
    }
    return
}

& $qemu @qemuArgs -nographic
