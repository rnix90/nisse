# SPDX-License-Identifier: GPL-2.0-or-later
# Start, stop or recreate the Fedora build VM (QEMU with WHPX on Windows). See docs/build-host.md.
#   build-vm.ps1 start | stop | status | recreate
# recreate throws the VM disk away and builds a fresh one from the Fedora Cloud image (cloud-init seed in
# $VmDir\seed). Afterwards: bash tools/build/vm.sh sync; bash tools/build/vm.sh ssh 'bash ~/nisse/tools/build/provision-vm.sh'
param(
    [Parameter(Mandatory = $true)][ValidateSet('start', 'stop', 'status', 'recreate')][string]$Action,
    [string]$VmDir = 'D:\nisse-build-vm',
    [string]$Qemu = 'C:\Program Files\qemu',
    [int]$Cpus = 8,
    [int]$MemMB = 16384,
    [int]$SshPort = 2222,
    [string]$DiskSize = '120G'
)
$pidFile = Join-Path $VmDir 'qemu.pid'

function Get-VmProcess {
    if (Test-Path $pidFile) {
        $id = [int](Get-Content $pidFile -Raw)
        return Get-Process -Id $id -ErrorAction SilentlyContinue
    }
}

function Start-Vm([switch]$WithSeed) {
    $args = @('-machine', 'q35', '-accel', 'whpx,kernel-irqchip=off', '-cpu', 'max',
        '-smp', $Cpus, '-m', $MemMB,
        '-drive', "file=$VmDir\nisse-build.qcow2,if=virtio,format=qcow2",
        '-netdev', "user,id=n0,hostfwd=tcp:127.0.0.1:${SshPort}-:22",
        '-device', 'virtio-net-pci,netdev=n0',
        '-display', 'none', '-serial', "file:$VmDir\serial.log", '-pidfile', $pidFile)
    if ($WithSeed) { $args += @('-smbios', 'type=1,serial=ds=nocloud-net;s=http://10.0.2.2:8000/') }
    Start-Process "$Qemu\qemu-system-x86_64.exe" -ArgumentList $args -WindowStyle Hidden `
        -RedirectStandardError "$VmDir\qemu.err" | Out-Null
}

function Stop-Vm {
    $p = Get-VmProcess
    if ($p) { Stop-Process -Id $p.Id -Force; Start-Sleep 2 }
}

switch ($Action) {
    'status' {
        if (Get-VmProcess) { 'running' } else { 'stopped' }
    }
    'start' {
        if (Get-VmProcess) { 'already running'; return }
        Start-Vm
        "started; ssh in about 30 s: bash tools/build/vm.sh ssh"
    }
    'stop' {
        $key = Join-Path $env:USERPROFILE '.ssh\nisse_build'
        ssh -i $key -p $SshPort -o BatchMode=yes -o StrictHostKeyChecking=accept-new `
            -o UserKnownHostsFile="$env:USERPROFILE\.ssh\known_hosts_nisse" builder@127.0.0.1 'sudo poweroff' 2>$null
        'poweroff sent'
    }
    'recreate' {
        foreach ($f in 'fedora-cloud.qcow2', 'seed\user-data', 'seed\meta-data') {
            if (-not (Test-Path (Join-Path $VmDir $f))) { throw "missing $VmDir\$f (see docs/build-host.md, 'Rebuilding the VM from scratch')" }
        }
        Stop-Vm
        Remove-Item "$VmDir\nisse-build.qcow2" -Force -ErrorAction SilentlyContinue
        & "$Qemu\qemu-img.exe" convert -O qcow2 "$VmDir\fedora-cloud.qcow2" "$VmDir\nisse-build.qcow2"
        & "$Qemu\qemu-img.exe" resize "$VmDir\nisse-build.qcow2" $DiskSize | Out-Null
        # the new VM has new host keys
        $known = "$env:USERPROFILE\.ssh\known_hosts_nisse"
        if (Test-Path $known) { Remove-Item $known -Force }
        # cloud-init fetches user-data from this loopback web server on first boot only
        Start-Process python -ArgumentList '-I', '-m', 'http.server', '8000', '--bind', '127.0.0.1', '--directory', "$VmDir\seed" `
            -WindowStyle Hidden | Out-Null
        Start-Vm -WithSeed
        'recreated; first boot takes about a minute. Then: bash tools/build/vm.sh sync and provision-vm.sh (see docs/build-host.md)'
    }
}
