# Enhanced-GPU-PV.ps1
# Main menu script for Enhanced-GPU-PV / Enhanced-GPU-PV 主菜单脚本
# Provides interactive options to create VMs, add/remove GPU-PV, update drivers,
# and install streaming software on existing VMs without recreation.
# 提供交互式选项，用于创建虚拟机、添加/移除 GPU-PV、更新驱动，
# 以及在现有虚拟机上安装串流软件，而无需重新创建虚拟机。

Import-Module $PSScriptRoot\Add-VMGpuPartitionAdapterFiles.psm1
Import-Module $PSScriptRoot\Enhanced-GPU-PV-Common.psm1
Import-Module (Join-Path $PSScriptRoot 'GpuPV-Allocation.psm1') -ErrorAction Stop
Import-Module $PSScriptRoot\GpuPV-TargetSafety.psm1 -ErrorAction Stop

function Read-GpuPVMenuTargetSelection {
    param([Parameter(Mandatory)]$VM)
    $disks = @(Get-VMHardDiskDrive -VM $VM -ErrorAction Stop)
    $path = $null
    if ($disks.Count -gt 1) {
        $disks | Select-Object Path,ControllerType,ControllerNumber,ControllerLocation | Format-Table | Out-Host
        $path = Read-Host 'Exact Windows VHD path / 输入系统盘的完整 VHD 路径'
        if ([string]::IsNullOrWhiteSpace($path)) { throw 'An explicit disk choice is required.' }
    }
    $disk = Select-GpuPVAttachedDisk -Disks $disks -VhdPath $path
    $partitionText = Read-Host 'Verified Windows partition number (blank = require unique detected Windows volume) / 已核实的 Windows 分区编号（留空要求唯一）'
    $partitionNumber = 0
    if ($partitionText -and (-not [int]::TryParse($partitionText,[ref]$partitionNumber) -or $partitionNumber -lt 1)) { throw 'Invalid partition number.' }
    [pscustomobject]@{ VhdPath = $disk.Path; PartitionNumber = $partitionNumber }
}

function Show-MainMenu {
    Clear-Host
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "Enhanced-GPU-PV Management Menu" -ForegroundColor Cyan
    Write-Host "Enhanced-GPU-PV 管理菜单" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "1. Create New GPU-PV VM / 创建新的 GPU-PV 虚拟机"
    Write-Host "2. Add GPU-PV to Existing VM / 为现有虚拟机添加 GPU-PV"
    Write-Host "3. Remove GPU-PV from Existing VM / 从现有虚拟机移除 GPU-PV"
    Write-Host "4. Update GPU Drivers in Existing VM / 更新现有虚拟机的 GPU 驱动"
    Write-Host "5. Full Existing-VM Configuration / 完整配置现有虚拟机"
    Write-Host "6. Enable RDP on Existing VM / 在现有虚拟机中启用远程桌面"
    Write-Host "7. Run PreChecks / 运行兼容性检查"
    Write-Host "8. Exit / 退出"
    Write-Host "9. Change GPU Quota Only / 仅调整 GPU 配额（VM 必须已关机）"
    Write-Host "========================================" -ForegroundColor Cyan
}

function Invoke-CreateNewVM {
    Write-Host "`n=== Create New GPU-PV VM / 创建新的 GPU-PV 虚拟机 ===" -ForegroundColor Cyan
    Write-Host "[1] Interactive Wizard (Recommended) / 交互式向导（推荐）" -ForegroundColor Green
    Write-Host "    Step-by-step configuration. No need to edit files." -ForegroundColor Gray
    Write-Host "    逐步配置，无需编辑文件。" -ForegroundColor Gray
    Write-Host "[2] Legacy Mode / 传统模式" -ForegroundColor Yellow
    Write-Host "    Edit the params block in CopyFilesToVM.ps1 manually." -ForegroundColor Gray
    Write-Host "    手动编辑 CopyFilesToVM.ps1 中的 params 配置块。" -ForegroundColor Gray
    $mode = Read-Host "Select mode / 选择模式 (1-2)"

    if ($mode -eq "1") {
        Start-Process powershell -ArgumentList "-ExecutionPolicy Bypass -File `"$PSScriptRoot\CopyFilesToVM.ps1`" -Interactive" -Wait
    } elseif ($mode -eq "2") {
        Write-Host "Please ensure you have edited the params block in CopyFilesToVM.ps1 first. / 请先确保您已编辑 CopyFilesToVM.ps1 中的 params 配置块。" -ForegroundColor Yellow
        $confirm = Read-Host "Continue? (Y/N) / 是否继续? (Y/N)"
        if ($confirm -eq 'Y' -or $confirm -eq 'y') {
            Start-Process powershell -ArgumentList "-ExecutionPolicy Bypass -File `"$PSScriptRoot\CopyFilesToVM.ps1`"" -Wait
        }
    }
}

function Invoke-AddGpuPVToExistingVM {
    Write-Host "`n=== Add GPU-PV to Existing VM / 为现有虚拟机添加 GPU-PV ===" -ForegroundColor Cyan
    $vmName = Read-Host "Enter VM Name / 输入虚拟机名称"

    $vm = Get-GpuPVExactVM -Name $vmName
    if (-not $vm) {
        Write-Host "ERROR: VM '$vmName' not found. / 错误: 找不到虚拟机 '$vmName'。" -ForegroundColor Red
        return
    }

    $gpuName = Read-Host "Enter GPU Name (or AUTO) / 输入 GPU 名称 (或输入 AUTO)"
    if ([string]::IsNullOrWhiteSpace($gpuName)) { $gpuName = "AUTO" }

    $allocationPolicy = Read-GpuPVAllocationPolicy
    Write-Host (Format-GpuPVAllocationPolicy -Policy $allocationPolicy)

    $selection = Read-GpuPVMenuTargetSelection -VM $vm
    $wasRunning = $vm.State -eq 'Running'
    $vm = Stop-GpuPVVMForOfflineAccess -VM $vm

    Write-Host "INFO   : Mounting VHDX... / 正在挂载 VHDX..."
    $offlineTarget = Open-GpuPVOfflineTarget -VM (Get-VM -Id $vm.VMId -ErrorAction Stop) -VhdPath $selection.VhdPath -PartitionNumber $selection.PartitionNumber
    $driveLetter = $offlineTarget.DriveLetter

    try {
        # Detect and remove residual GPU drivers from other hosts before copying new ones
        # 在复制新驱动前检测并移除来自其他宿主机的残留 GPU 驱动
        $hasResidualGPU = $false
        $residualIndicators = @("nvapi64.dll","nvlddmkm.sys","nvcuda.dll","igfxEM.exe","amdkmdag.sys")
        foreach ($indicator in $residualIndicators) {
            if (Test-Path "$driveLetter\Windows\System32\$indicator") {
                $hasResidualGPU = $true
                break
            }
        }
        if ($hasResidualGPU) {
            Write-Host "WARN   : Existing GPU driver files detected in VM. Removing residuals before copying new drivers... / 警告: 检测到虚拟机中存在现有 GPU 驱动文件。在复制新驱动前移除残留..." -ForegroundColor Yellow
            Remove-VMGpuPartitionAdapterFiles -Target $offlineTarget -GPUName $gpuName
        }

        Write-Host "INFO   : Copying GPU driver files... / 正在复制 GPU 驱动文件..."
        Add-VMGpuPartitionAdapterFiles -Target $offlineTarget -GPUName $gpuName
    }
    finally {
        Write-Host "INFO   : Dismounting VHDX... / 正在卸载 VHDX..."
        Close-GpuPVOfflineTarget -Target $offlineTarget
    }

    Write-Host "INFO   : Assigning GPU-PV adapter... / 正在分配 GPU-PV 适配器..."
    Assign-VMGPUPartitionAdapter -VMName $vmName -GPUName $gpuName -AllocationPolicy $allocationPolicy

    Write-Host "INFO   : Configuring VM GPU-PV settings... / 正在配置虚拟机 GPU-PV 设置..."
    Set-VMGpuPartitionSettings -VMName $vmName

    if ($wasRunning) {
        Write-Host "INFO   : Starting VM... / 正在启动虚拟机..."
        Start-VM -VM (Get-VM -Id $vm.VMId -ErrorAction Stop) -ErrorAction Stop
    }

    Write-Host "INFO   : Done! GPU-PV has been added to '$vmName'. / 完成! 已为 '$vmName' 添加 GPU-PV。" -ForegroundColor Green
}

function Invoke-RemoveGpuPVFromExistingVM {
    Write-Host "`n=== Remove GPU-PV from Existing VM / 从现有虚拟机移除 GPU-PV ===" -ForegroundColor Cyan
    $vmName = Read-Host "Enter VM Name / 输入虚拟机名称"

    $vm = Get-GpuPVExactVM -Name $vmName
    if (-not $vm) {
        Write-Host "ERROR: VM '$vmName' not found. / 错误: 找不到虚拟机 '$vmName'。" -ForegroundColor Red
        return
    }

    $adapter = Get-VMGpuPartitionAdapter -VM (Get-VM -Id $vm.VMId -ErrorAction Stop) -ErrorAction SilentlyContinue
    if (-not $adapter) {
        Write-Host "WARN   : No GPU-PV adapter found on '$vmName'. Proceeding with driver cleanup only. / 警告: '$vmName' 上未找到 GPU-PV 适配器。仅执行驱动清理。" -ForegroundColor Yellow
    }

    $gpuName = Read-Host "Enter GPU Name for thorough cleanup (or leave empty for safe mode) / 输入 GPU 名称以进行彻底清理 (留空则为安全模式)"
    if ([string]::IsNullOrWhiteSpace($gpuName)) { $gpuName = "AUTO" }

    $doDeepClean = $false
    if ($gpuName -ne "AUTO") {
        $deepCleanChoice = Read-Host "Perform deep clean to remove ALL residual GPU files from other hosts? (Y/N) / 执行深度清理以移除所有来自其他宿主机的残留 GPU 文件? (Y/N)"
        if ($deepCleanChoice -eq 'Y' -or $deepCleanChoice -eq 'y') { $doDeepClean = $true }
    }

    $selection = Read-GpuPVMenuTargetSelection -VM $vm
    $wasRunning = $vm.State -eq 'Running'
    $vm = Stop-GpuPVVMForOfflineAccess -VM $vm

    Write-Host "INFO   : Mounting VHDX... / 正在挂载 VHDX..."
    $offlineTarget = Open-GpuPVOfflineTarget -VM (Get-VM -Id $vm.VMId -ErrorAction Stop) -VhdPath $selection.VhdPath -PartitionNumber $selection.PartitionNumber
    $driveLetter = $offlineTarget.DriveLetter

    try {
        Write-Host "INFO   : Cleaning up GPU driver files... / 正在清理 GPU 驱动文件..."
        if ($doDeepClean) {
            Remove-VMGpuPartitionAdapterFiles -Target $offlineTarget -GPUName $gpuName -DeepClean
        } else {
            Remove-VMGpuPartitionAdapterFiles -Target $offlineTarget -GPUName $gpuName
        }
    }
    finally {
        Write-Host "INFO   : Dismounting VHDX... / 正在卸载 VHDX..."
        Close-GpuPVOfflineTarget -Target $offlineTarget
    }

    if ($adapter) { Get-VMGpuPartitionAdapter -VM (Get-VM -Id $vm.VMId -ErrorAction Stop) | Remove-VMGpuPartitionAdapter -ErrorAction Stop }

    if ($wasRunning) {
        Write-Host "INFO   : Starting VM... / 正在启动虚拟机..."
        Start-VM -VM (Get-VM -Id $vm.VMId -ErrorAction Stop) -ErrorAction Stop
    }

    Write-Host "INFO   : Done! GPU-PV has been removed from '$vmName'. / 完成! 已从 '$vmName' 移除 GPU-PV。" -ForegroundColor Green
}

function Invoke-UpdateGpuDrivers {
    Write-Host "`n=== Update GPU Drivers in Existing VM / 更新现有虚拟机的 GPU 驱动 ===" -ForegroundColor Cyan
    $vmName = Read-Host "Enter VM Name / 输入虚拟机名称"
    $gpuName = Read-Host "Enter GPU Name (or AUTO) / 输入 GPU 名称 (或输入 AUTO)"
    if ([string]::IsNullOrWhiteSpace($gpuName)) { $gpuName = "AUTO" }

    & $PSScriptRoot\Update-VMGpuPartitionDriver.ps1 -VMName $vmName -GPUName $gpuName
}

function Invoke-InstallVMSoftware {
    Write-Host "This opens the full supported ExistingVM workflow, including GPU and connection settings. / 此项打开完整的现有虚拟机配置流程，包含 GPU 与连接设置。" -ForegroundColor Yellow
    & (Join-Path $PSScriptRoot 'Configure-GpuPV-ExistingVM.ps1')
}

function Invoke-EnableRDPOnExistingVM {
    Write-Host "`n=== Enable RDP on Existing VM / 在现有虚拟机中启用远程桌面 ===" -ForegroundColor Cyan
    $vmName = Read-Host "Enter VM Name / 输入虚拟机名称"

    $vm = Get-GpuPVExactVM -Name $vmName
    if (-not $vm) {
        Write-Host "ERROR: VM '$vmName' not found. / 错误: 找不到虚拟机 '$vmName'。" -ForegroundColor Red
        return
    }

    $originalState = $vm.State
    if ($originalState -eq 'Off' -or $originalState -eq 'Saved' -or $originalState -eq 'Paused') {
        Write-Host "INFO   : Starting/resuming VM... / 正在启动/恢复虚拟机..." -ForegroundColor Yellow
        if ($originalState -eq 'Paused') { Resume-VM -VM (Get-VM -Id $vm.VMId -ErrorAction Stop) -ErrorAction Stop } else { Start-VM -VM (Get-VM -Id $vm.VMId -ErrorAction Stop) -ErrorAction Stop }
        Write-Host "INFO   : Waiting for VM to boot... / 等待虚拟机启动..." -ForegroundColor Yellow
        Start-Sleep -Seconds 45
    }

    Write-Host "INFO   : Enabling RDP and firewall rules... / 正在启用远程桌面和防火墙规则..." -ForegroundColor Yellow
    try {
        $credential = Get-Credential -Message "Guest administrator credentials / 来宾管理员凭据"
        if (-not $credential) { throw 'Guest credentials are required.' }
        $applied=@(Invoke-Command -VMId $vm.VMId -Credential $credential -ErrorAction Stop -ScriptBlock (Get-GpuPVGuestRdpConfigurationScript) -ArgumentList $true)
        if($applied.Count -ne 1 -or $applied[0].SettingsApplied -isnot [bool] -or -not $applied[0].SettingsApplied){throw 'Expected one guest RDP settings result.'}
        $effective=@(Invoke-Command -VMId $vm.VMId -Credential $credential -ErrorAction Stop -ScriptBlock (Get-GpuPVGuestRdpObservationScript) -ArgumentList $true)
        if($effective.Count -ne 1 -or $effective[0].ConfigurationVerified -isnot [bool] -or -not $effective[0].ConfigurationVerified){throw 'RDP effective configuration verification failed.'}
        Write-Host "RDP port: $($effective[0].Port); configuration/listener checks: $($effective[0].ConfigurationVerified)."
        Write-Host 'Firewall scope: Domain/Private. Network reachability, other blocking policies and an authorized client login remain unverified.' -ForegroundColor Yellow
    } catch {
        Write-Host "ERROR: Failed to enable RDP via PowerShell Direct. / 错误: 无法通过 PowerShell Direct 启用远程桌面。" -ForegroundColor Red
        Write-Host "Ensure the VM is running and credentials work. / 请确保虚拟机正在运行且凭据有效。" -ForegroundColor Yellow
        Write-Host "You can manually enable RDP inside the VM: / 您可以在虚拟机内手动启用远程桌面:" -ForegroundColor Yellow
        Write-Host "  1. System Properties -> Remote -> Enable Remote Desktop" -ForegroundColor Cyan
        Write-Host "  2. Windows Defender Firewall -> Allow an app -> Remote Desktop [checked]" -ForegroundColor Cyan
    }

    if ($originalState -eq 'Off') {
        $shutdown = Read-Host "Shutdown VM? (Y/N) / 是否关闭虚拟机? (Y/N)"
        if ($shutdown -eq 'Y' -or $shutdown -eq 'y') {
            $null=Stop-GpuPVVMForOfflineAccess -VM $vm
            Write-Host "VM shut down. / 虚拟机已关闭。" -ForegroundColor Green
        }
    } elseif ($originalState -eq 'Paused' -or $originalState -eq 'Saved') {
        Write-Host "INFO   : VM was originally $originalState and is now running. Adjust its state manually as needed. / 提示: 虚拟机原状态为 $originalState，现已运行，请按需手动调整状态。" -ForegroundColor Yellow
    }
}

function Invoke-PreChecks {
    & $PSScriptRoot\PreChecks.ps1
}

# Main loop / 主循环
while ($true) {
    Show-MainMenu
    $choice = Read-Host "Select an option / 选择一个选项 (1-9)"
    try {
    switch ($choice) {
        "1" { Invoke-CreateNewVM }
        "2" { Invoke-AddGpuPVToExistingVM }
        "3" { Invoke-RemoveGpuPVFromExistingVM }
        "4" { Invoke-UpdateGpuDrivers }
        "5" { Invoke-InstallVMSoftware }
        "6" { Invoke-EnableRDPOnExistingVM }
        "7" { Invoke-PreChecks }
        "8" { Write-Host "Exiting... / 正在退出..."; break }
        "9" { & (Join-Path $PSScriptRoot 'Set-GpuPVAllocation.ps1') }
        default { Write-Host "Invalid option. Please try again. / 无效选项，请重试。" -ForegroundColor Red }
    }
    } catch { Write-Host "Operation stopped: $($_.Exception.Message)" -ForegroundColor Red }
    if ($choice -eq "8") { break }
    Read-Host "`nPress Enter to return to menu... / 按回车键返回菜单..."
}
