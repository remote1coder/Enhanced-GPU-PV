<# 
If you are opening this file in Powershell ISE you should modify the params section like so...
Remember: GPU Name must match the name of the GPU you assigned when creating the VM...

Param (
[string]$VMName = "NameofyourVM",
[string]$GPUName = "NameofyourGPU",
[string]$Hostname = $ENV:Computername,
[string]$SystemVhdPath,
[ValidateRange(0,2147483647)][int]$SystemPartitionNumber = 0
)

#>

Param (
[string]$VMName,
[string]$GPUName = "AUTO",
[string]$Hostname = $ENV:Computername,
[string]$SystemVhdPath,
[ValidateRange(0,2147483647)][int]$SystemPartitionNumber = 0
)

Import-Module $PSScriptRoot\Add-VMGpuPartitionAdapterFiles.psm1
Import-Module $PSScriptRoot\GpuPV-TargetSafety.psm1 -ErrorAction Stop

$VM = Get-GpuPVExactVM -Name $VMName
if (-not $VM) {
    Write-Error "VM '$VMName' not found."
    return
}
# Resolve attachment ambiguity before any shutdown or writable mount.
$selectedDisk = Select-GpuPVAttachedDisk -Disks @(Get-VMHardDiskDrive -VM $VM -ErrorAction Stop) -VhdPath $SystemVhdPath

# Preserve the original state; saved/paused VMs are never discarded by an update.
$originalState = $VM.State
$VM = Stop-GpuPVVMForOfflineAccess -VM $VM

Write-Host "Opening the verified offline Windows target..."
$target = Open-GpuPVOfflineTarget -VM (Get-VM -Id $VM.VMId -ErrorAction Stop) -VhdPath $selectedDisk.Path -PartitionNumber $SystemPartitionNumber
try {
    Add-VMGpuPartitionAdapterFiles -hostname $Hostname -Target $target -GPUName $GPUName -ErrorAction Stop
}
finally {
    Close-GpuPVOfflineTarget -Target $target
}

If ($originalState -eq "Running"){
    Write-Host "Previous State was running so starting VM..."
    Start-VM -VM (Get-VM -Id $VM.VMId -ErrorAction Stop) -ErrorAction Stop
    }

Write-Host "Done..."