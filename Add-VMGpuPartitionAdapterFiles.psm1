Import-Module (Join-Path $PSScriptRoot "GpuPV-TargetSafety.psm1") -ErrorAction Stop

# Device IDs are accepted only in the PCI layouts this project supports; unknown formats fail closed.
function Get-GpuPVDeviceIdentityKey {
    param([Parameter(Mandatory)][string]$Value)
    $normalized = $Value -replace '^\\\\\?\\',''
    $parts = @($normalized -split '[\\#]')
    if ($parts.Count -lt 3 -or $parts[0] -ne 'PCI' -or -not $parts[1] -or -not $parts[2]) { throw 'Unsupported GPU device identity format.' }
    return (($parts[0..2] -join '\').ToUpperInvariant())
}

function Resolve-GpuPVDriverSelection {
    [CmdletBinding()]
    param([ValidateNotNullOrEmpty()][string]$GPUName = 'AUTO')
    $partitionable = @(Get-WmiObject -Class Msvm_PartitionableGpu -ComputerName $env:COMPUTERNAME -Namespace 'ROOT\virtualization\v2' -ErrorAction Stop)
    if ($partitionable.Count -eq 0) { throw 'No partitionable GPU found.' }
    $pnp = @(Get-PnpDevice -Class Display -PresentOnly -Status OK -ErrorAction Stop)
    if ($GPUName -eq 'AUTO') {
        if ($partitionable.Count -ne 1) { throw 'AUTO requires exactly one partitionable GPU.' }
        $selected = $partitionable[0]
    } else {
        $matches = @($partitionable | Where-Object { [string]$_.Name -eq $GPUName })
        if ($matches.Count -eq 0) {
            $namedPnp = @($pnp | Where-Object { $_.FriendlyName -eq $GPUName -or $_.Name -eq $GPUName -or $_.InstanceId -eq $GPUName })
            if ($namedPnp.Count -ne 1) { throw 'GPU name must identify exactly one present, healthy display device.' }
            $pnpKey = Get-GpuPVDeviceIdentityKey -Value $namedPnp[0].InstanceId
            $matches = @($partitionable | Where-Object { (Get-GpuPVDeviceIdentityKey -Value $_.Name) -eq $pnpKey })
        }
        if ($matches.Count -ne 1) { throw 'GPU identity does not resolve to exactly one partitionable instance.' }
        $selected = $matches[0]
    }
    $key = Get-GpuPVDeviceIdentityKey -Value $selected.Name
    $pnpMatches = @($pnp | Where-Object { $_.InstanceId -match '^PCI\\' -and (Get-GpuPVDeviceIdentityKey -Value $_.InstanceId) -eq $key })
    if ($pnpMatches.Count -ne 1) { throw 'Partitionable GPU must resolve to exactly one PnP display device.' }
    $device = $pnpMatches[0]
    $drivers = @(Get-WmiObject -Class Win32_PNPSignedDriver -ErrorAction Stop | Where-Object { $_.DeviceID -eq $device.InstanceId })
    if ($drivers.Count -ne 1) { throw 'The selected device must have one identifiable signed-driver record.' }
    $service = [string]$device.Service
    if ([string]::IsNullOrWhiteSpace($service)) {
        $serviceProperty = @(Get-PnpDeviceProperty -InstanceId $device.InstanceId -KeyName 'DEVPKEY_Device_Service' -ErrorAction Stop)
        if ($serviceProperty.Count -ne 1) { throw 'GPU service identity is ambiguous.' }
        $service = [string]$serviceProperty[0].Data
    }
    if ([string]::IsNullOrWhiteSpace($service)) { throw 'GPU service identity is missing.' }
    [pscustomobject]@{ InstancePath = [string]$selected.Name; PnpDevice = $device; ServiceName = $service; Drivers = @($drivers); GPUName = [string]$device.FriendlyName }
}

Function Add-VMGpuPartitionAdapterFiles {
param(
    [string]$hostname = $ENV:COMPUTERNAME,
    [string]$DriveLetter,
    [object]$Target,
    [string]$GPUName = "AUTO"
)

if (-not $Target) { throw "A verified Target object is required; a naked drive letter is unsafe." }
Assert-GpuPVTarget -Target $Target
if ($DriveLetter -and $DriveLetter.TrimEnd("\") -ne $Target.DriveLetter) { throw "DriveLetter does not match Target." }
$DriveLetter = $Target.DriveLetter

$selection = Resolve-GpuPVDriverSelection -GPUName $GPUName
$GPU = $selection.PnpDevice
$GPUName = $selection.GPUName
$GPUServiceName = $selection.ServiceName
# Get Third Party drivers used, that are not provided by Microsoft and presumably included in the OS / 获取正在使用的第三方驱动程序

Write-Host "INFO   : Finding and copying driver files for $GPUName to VM. This could take a while..."

$Drivers = @($selection.Drivers)

$null = Assert-GpuPVTargetPath -Target $Target -Path "$DriveLetter\windows\system32\HostDriverStore"
New-Item -ItemType Directory -Path "$DriveLetter\windows\system32\HostDriverStore" -Force -ErrorAction Stop | Out-Null

#copy directory associated with sys file / 复制与 sys 文件关联的目录
$servicePath = (Get-WmiObject Win32_SystemDriver | Where-Object {$_.Name -eq "$GPUServiceName"}).Pathname
if (-not $servicePath) {
    throw "Could not locate the GPU service driver path."
} else {
    if ($servicePath -notmatch "^[A-Za-z]:\\Windows\\System32\\DriverStore\\FileRepository\\") { throw "Unexpected GPU service driver path." }
    $ServiceDriverDir = $servicepath.split('\')[0..5] -join('\')
    $ServicedriverDest = ("$driveletter" + "\" + $($servicepath.split('\')[1..5] -join('\'))) -replace 'driverstore', 'HostDriverStore'
    if (!(Test-Path $ServicedriverDest)) {
        $null = Assert-GpuPVTargetPath -Target $Target -Path $ServicedriverDest
        Assert-GpuPVTreeNoReparse -Root $Target.Root -Path $ServicedriverDest
        Copy-Item -LiteralPath $ServiceDriverDir -Destination $ServicedriverDest -Recurse -ErrorAction Stop
    }
}

foreach ($d in $drivers) {

    $DriverFiles = @()
    $ModifiedDeviceID = $d.DeviceID -replace "\\", "\\"
    $Antecedent = "\\" + $hostname + "\ROOT\cimv2:Win32_PNPSignedDriver.DeviceID=""$ModifiedDeviceID"""
    $DriverFiles += Get-WmiObject Win32_PNPSignedDriverCIMDataFile | Where-Object {$_.Antecedent -eq $Antecedent}
    if ($d.DeviceName -like "NVIDIA*") {
        $null = Assert-GpuPVTargetPath -Target $Target -Path "$driveletter\Windows\System32\drivers\Nvidia Corporation"
        New-Item -ItemType Directory -Path "$driveletter\Windows\System32\drivers\Nvidia Corporation\" -Force -ErrorAction Stop | Out-Null
    }
    foreach ($i in $DriverFiles) {
        $path = $i.Dependent.Split("=")[1] -replace '\\\\', '\'
        $path2 = $path.Substring(1,$path.Length-2)
        if ($path2 -notmatch "^[A-Za-z]:\\") { throw "Driver source must be absolute." }
        $path2 = [IO.Path]::GetFullPath($path2)
        if ($path2 -notmatch "^[A-Za-z]:\\Windows\\(System32|SysWOW64)\\") { throw "Unsupported driver source path: $path2" }
        If ($path2 -like "c:\windows\system32\driverstore\*") {
            $DriverDir = $path2.split('\')[0..5] -join('\')
            $driverDest = ("$driveletter" + "\" + $($path2.split('\')[1..5] -join('\'))) -replace 'driverstore', 'HostDriverStore'
            if (!(Test-Path $driverDest)) {
                $null = Assert-GpuPVTargetPath -Target $Target -Path $driverDest
                Assert-GpuPVTreeNoReparse -Root $Target.Root -Path $driverDest
                Copy-Item -LiteralPath $DriverDir -Destination $driverDest -Recurse -ErrorAction Stop
            }
        }
        Else {
            # Fix case-sensitive path replacement bug / 修复大小写敏感的路径替换缺陷
            # Original: $path2.Replace("c:", "$driveletter") fails if path starts with uppercase C:\n            # 原始代码: $path2.Replace("c:", "$driveletter") 在路径以大写 C: 开头时会失败
            if ($path2 -match '^[a-zA-Z]:\\') {
                $ParseDestination = Join-Path $driveletter $path2.Substring(3)
            }
            else {
                throw "Refusing a non-absolute driver path: $path2"
            }
            $null = Assert-GpuPVTargetPath -Target $Target -Path $ParseDestination
            $Destination = $ParseDestination.Substring(0, $ParseDestination.LastIndexOf('\'))
            if (!$(Test-Path -Path $Destination)) {
                New-Item -ItemType Directory -Path $Destination -Force -ErrorAction Stop | Out-Null
            }
            $null = Assert-GpuPVTargetPath -Target $Target -Path $ParseDestination
            Copy-Item -LiteralPath $path2 -Destination $Destination -Force -ErrorAction Stop
        }
    }
}

}

Function Remove-VMGpuPartitionAdapterFiles {
param(
    [string]$hostname = $ENV:COMPUTERNAME,
    [string]$DriveLetter,
    [object]$Target,
    [string]$GPUName = "AUTO",
    [switch]$DeepClean
)
# Remove host GPU driver files copied into a VM VHDX for GPU-PV.
# 从虚拟机 VHDX 中移除为 GPU-PV 复制的主机 GPU 驱动文件。
# Designed for safe cleanup across Intel, AMD, and NVIDIA GPUs.
# 设计为在 Intel、AMD 和 NVIDIA 显卡间安全清理。

if (-not $Target) { throw "A verified Target object is required; a naked drive letter is unsafe." }
Assert-GpuPVTarget -Target $Target
if ($DriveLetter -and $DriveLetter.TrimEnd("\") -ne $Target.DriveLetter) { throw "DriveLetter does not match Target." }
$DriveLetter = $Target.DriveLetter

$selection = Resolve-GpuPVDriverSelection -GPUName $GPUName

# Global exclusion list: non-GPU drivers that share vendor signatures must never be deleted.
# 全局排除列表: 与 GPU 厂商共享签名但非 GPU 的驱动，绝不可删除。
$globalExclusions = @("nvstor.sys","nvraid.sys","nvdimm.sys","nvmedisk.sys")

# 1. Cleanup requires the identity-bound target and a reparse-free tree.
$hostDriverStorePath = "$DriveLetter\windows\system32\HostDriverStore"
if (Test-Path $hostDriverStorePath) {
    Write-Host "INFO   : Removing HostDriverStore... / 正在移除 HostDriverStore..."
    Remove-GpuPVTargetTree -Target $Target -Path $hostDriverStorePath
}

# 2. Remove the known GPU-PV directory only after validating the exact target.
$nvidiaCorpPath = "$DriveLetter\Windows\System32\drivers\Nvidia Corporation"
if (Test-Path $nvidiaCorpPath) {
    Write-Host "INFO   : Removing Nvidia Corporation driver directory... / 正在移除 Nvidia Corporation 驱动目录..."
    Remove-GpuPVTargetTree -Target $Target -Path $nvidiaCorpPath
}

# 3. Conditional cleanup: specific driver files in System32 / 条件清理: System32 中的特定驱动文件
# Only performed when a specific GPUName is provided. / 仅在提供了具体的 GPUName 时执行。
if ($GPUName -ne "AUTO") {
    Write-Host "INFO   : Removing specific driver files for $GPUName... / 正在移除 $GPUName 的特定驱动文件..."
    $GPU = $selection.PnpDevice
    if ($GPU) {
        $Drivers = @($selection.Drivers)
        foreach ($d in $drivers) {
            $DriverFiles = @()
            $ModifiedDeviceID = $d.DeviceID -replace "\\", "\\"
            $Antecedent = "\\" + $hostname + "\ROOT\cimv2:Win32_PNPSignedDriver.DeviceID=""$ModifiedDeviceID"""
            $DriverFiles += Get-WmiObject Win32_PNPSignedDriverCIMDataFile | Where-Object {$_.Antecedent -eq $Antecedent}
            foreach ($i in $DriverFiles) {
                $path = $i.Dependent.Split("=")[1] -replace '\\\\', '\'
                $path2 = $path.Substring(1,$path.Length-2)
        if ($path2 -notmatch "^[A-Za-z]:\\") { throw "Driver source must be absolute." }
        $path2 = [IO.Path]::GetFullPath($path2)
        if ($path2 -notmatch "^[A-Za-z]:\\Windows\\(System32|SysWOW64)\\") { throw "Unsupported driver source path: $path2" }
                # DriverStore files were already removed with HostDriverStore / DriverStore 文件已随 HostDriverStore 移除
                If ($path2 -like "c:\windows\system32\driverstore\*") {
                    continue
                }
                Else {
                    # Skip non-GPU drivers that share vendor signatures (e.g., NVIDIA storage/RAID)
                    # 跳过与 GPU 厂商共享签名但非 GPU 的驱动（如 NVIDIA 存储/RAID）
                    $fileName = Split-Path $path2 -Leaf
                    if ($fileName -in $globalExclusions) {
                        Write-Host "INFO   : Skipping excluded non-GPU driver $fileName / 跳过排除的非 GPU 驱动 $fileName"
                        continue
                    }
                    # Map host path to VM path using case-insensitive logic / 使用不区分大小写的逻辑映射主机路径到虚拟机路径
                    if ($path2 -match '^[a-zA-Z]:\\') {
                        $vmPath = Join-Path $DriveLetter $path2.Substring(3)
                    }
                    else {
                        throw "Refusing a non-absolute driver path: $path2"
                    }
                    $null = Assert-GpuPVTargetPath -Target $Target -Path $vmPath
                    if (Test-Path -LiteralPath $vmPath) {
                        Write-Host "INFO   : Removing $vmPath ... / 正在移除 $vmPath ..."
                        Remove-GpuPVTargetTree -Target $Target -Path $vmPath
                    }
                }
            }
        }
    }
    else {
        Write-Warning "GPU '$GPUName' not found on host. Skipping specific System32 cleanup. / 在宿主机上未找到 GPU '$GPUName'。跳过特定的 System32 清理。"
    }

    # 4. Deep-clean: remove all known GPU vendor files regardless of WMI match / 深度清理: 移除所有已知的 GPU 厂商文件（不依赖 WMI 匹配）
    # Uses exact-filename whitelist to avoid deleting non-GPU drivers (e.g., nvstor.sys storage, AMD chipset, Intel NIC).
    # 使用精确文件名白名单，避免误删非 GPU 驱动（如 nvstor.sys 存储驱动、AMD 芯片组、Intel 网卡等）。
    if ($DeepClean) {
        Write-Host "INFO   : Performing deep clean of residual GPU driver files... / 正在深度清理残留的 GPU 驱动文件..."

        # Determine vendor from GPU name / 根据 GPU 名称判断厂商
        $vendor = $null
        if ($GPUName -like "*NVIDIA*" -or $GPUName -like "*GeForce*" -or $GPUName -like "*RTX*" -or $GPUName -like "*Quadro*") { $vendor = "NVIDIA" }
        elseif ($GPUName -like "*AMD*" -or $GPUName -like "*Radeon*") { $vendor = "AMD" }
        elseif ($GPUName -like "*Intel*" -or $GPUName -like "*Arc*") { $vendor = "Intel" }

        if ($vendor) {
            # Search paths within the VM / 虚拟机内的搜索路径
            $searchPaths = @(
                "$DriveLetter\Windows\System32",
                "$DriveLetter\Windows\SysWOW64",
                "$DriveLetter\Windows\System32\drivers"
            )

            # Exact-filename whitelist by vendor / 按厂商的精确文件名白名单
            # These filenames are stable across driver versions and are unique to GPU drivers.
            # 这些文件名在多年驱动版本中非常稳定，且为 GPU 驱动独有。
            $exactFiles = switch ($vendor) {
                "NVIDIA" {
                    @(
                        # Kernel drivers / 内核驱动
                        "nvlddmkm.sys","nvvad64v.sys","nvaudcap64v.sys",
                        # Core DLLs / 核心 DLL
                        "nvapi64.dll","nvapi.dll","nvcuda.dll","nvcudadebugger.dll",
                        "nvcuvid.dll","nvEncodeAPI64.dll","NvFBC64.dll","NvIFR64.dll",
                        "nvofapi64.dll","nvcpl.dll","nvml.dll","NvAgent.dll",
                        "nvaudcap64v.dll","NvRtmpStreamer64.dll","nvspcap64.dll",
                        # Tools / 工具
                        "nvidia-smi.exe","nvdebugdump.exe","nvinfo.pb","nvcpl.cpl"
                    )
                }
                "AMD" {
                    @(
                        # Kernel drivers / 内核驱动
                        "amdkmdag.sys","amdkmdap.sys","atikmdag.sys","atikmpag.sys",
                        # Core DLLs / 核心 DLL
                        "atiadlxx.dll","atiadlxy.dll","aticfx64.dll","aticfx32.dll",
                        "atidxx64.dll","atidxx32.dll","atiuxp64.dll","atiuxp32.dll",
                        "amdmantle64.dll","amdmantle32.dll","amdvlk64.dll","amdvlk32.dll"
                    )
                }
                "Intel" {
                    @(
                        # Kernel drivers / 内核驱动
                        "igdkmd64.sys","igdkmdn.sys",
                        # Core DLLs / 核心 DLL
                        "igfxDH.dll","igfxDI.dll","igfxEM.dll","igfxHK.dll",
                        "igd10iumd64.dll","igd11dxva64.dll","igd12dxva64.dll",
                        # Executables / 可执行文件
                        "igfxEM.exe","igfxHK.exe","igfxCUIService.exe","IntelCpHeciSvc.exe"
                    )
                }
            }

            $deepCleanCount = 0
            foreach ($searchPath in $searchPaths) {
                if (!(Test-Path $searchPath)) { continue }
                foreach ($fileName in $exactFiles) {
                    $filePath = Join-Path $searchPath $fileName
                    if (Test-Path $filePath) {
                        Write-Host "INFO   : Deep-clean removing $filePath ... / 深度清理移除 $filePath ..."
                        Remove-GpuPVTargetTree -Target $Target -Path $filePath
                        $deepCleanCount++
                    }
                }
            }
            Write-Host "INFO   : Deep-clean removed $deepCleanCount residual file(s). / 深度清理移除了 $deepCleanCount 个残留文件。" -ForegroundColor Green
        }
        else {
            Write-Warning "Could not determine GPU vendor from '$GPUName'. Skipping deep clean. / 无法从 '$GPUName' 判断 GPU 厂商。跳过深度清理。"
        }
    }
}
else {
    Write-Host "WARN   : GPUName is AUTO. Only HostDriverStore and Nvidia Corporation directories were removed. / GPUName 为 AUTO。仅移除了 HostDriverStore 和 Nvidia Corporation 目录。"
    Write-Host "WARN   : To remove specific System32 driver files, re-run with a specific GPU name. / 要移除特定的 System32 驱动文件，请使用具体的 GPU 名称重新运行。"
}
}
