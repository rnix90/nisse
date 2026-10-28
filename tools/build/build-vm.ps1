# SPDX-License-Identifier: GPL-2.0-or-later
# Start or stop the Fedora build VM (QEMU with WHPX on Windows). See docs/build-host.md.
#   build-vm.ps1 start | stop | status
param(
    [Parameter(Mandatory = $true)][ValidateSet('start', 'stop', 'status')][string]$Action,
    [string]$VmDir = 'D:\nisse-build-vm',
    [string]$Qemu = 'C:\Program Files\qemu',
    [int]$Cpus = 8,
    [int]$MemMB = 16384,
    [int]$SshPort = 2222
)
$pidFile = Join-Path $VmDir 'qemu.pid'

function Get-VmProcess {
    if (Test-Path $pidFile) {
        $id = [int](Get-Content $pidFile -Raw)
        return Get-Process -Id $id -ErrorAction SilentlyContinue
    }
}

switch ($Action) {
    'status' {
        if (Get-VmProcess) { 'running' } else { 'stopped' }
    }
    'start' {
        if (Get-VmProcess) { 'already running'; return }
        $args = @('-machine', 'q35', '-accel', 'whpx,kernel-irqchip=off', '-cpu', 'max',
            '-smp', $Cpus, '-m', $MemMB,
            '-drive', "file=$VmDir\nisse-build.qcow2,if=virtio,format=qcow2",
            '-netdev', "user,id=n0,hostfwd=tcp:127.0.0.1:${SshPort}-:22",
            '-device', 'virtio-net-pci,netdev=n0',
            '-display', 'none', '-serial', "file:$VmDir\serial.log", '-pidfile', $pidFile)
        Start-Process "$Qemu\qemu-system-x86_64.exe" -ArgumentList $args -WindowStyle Hidden `
            -RedirectStandardError "$VmDir\qemu.err" | Out-Null
        "started; ssh in about 30 s: bash tools/build/vm.sh ssh"
    }
    'stop' {
        $key = Join-Path $env:USERPROFILE '.ssh\nisse_build'
        ssh -i $key -p $SshPort -o BatchMode=yes -o StrictHostKeyChecking=accept-new `
            -o UserKnownHostsFile="$env:USERPROFILE\.ssh\known_hosts_nisse" builder@127.0.0.1 'sudo poweroff' 2>$null
        'poweroff sent'
    }
}
