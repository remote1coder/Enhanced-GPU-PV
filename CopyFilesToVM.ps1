[CmdletBinding()]
param(
    [switch]$Interactive,
    [ValidateSet("", "Phase1", "Phase2", "Phase3", "Phase4", "Phase5", "Phase6", "Phase7")]
    [string]$StartFromStep = "",
    [string]$TargetVMName = "",
    [switch]$ResetState,
    [string]$GPUAllocation,
    [string]$GPUComputePercentage,
    [string]$GPUEncodePercentage,
    [string]$GPUDecodePercentage
)

# Do not record a successful phase after a nonterminating provisioning error.
$ErrorActionPreference = 'Stop'

# ============================================================================
# Global Config Structure for Interactive Mode / 交互模式全局配置结构
# ============================================================================
$script:Config = @{
    VMName = "GPUPV"
    SourcePath = $null
    VHDPath = $null
    Edition = 6
    VhdFormat = "VHDX"
    DiskLayout = "UEFI"
    SizeBytes = 40GB
    MemoryAmount = 8GB
    CPUCores = 4
    NetworkSwitch = "Default Switch"
    GPUName = "AUTO"
    GPUResourceAllocationPercentage = 50
    GPUAllocationPolicy = $null # Optional canonical policy; null uses the legacy percentage.
    StreamingChoice = $null
    SecurityModel = "HostDownload"
    SunshineStreamConfig = @{
        Preset = "Default"
        Resolution = "3840x2160"
        FPS = "120"
        HEVCMode = "0"
        AV1Mode = "0"
        HDRMode = "disabled"
        Bitrate = "50000"
    }
    VDDConfig = @{
        Resolution = "3840x2160"
        RefreshRate = "120"
        HDR = $false
    }
    ConnectionMethod = "Auto"
    AudioDriver = "VBCable"
    Username = "GPUVM"
    Password = $null
    Autologon = "true"
    Language = ""
    Timezone = ""
    Team_ID = ""
    Key = ""
    InstallFilePaths = @{
        SunshineInstaller = $null
        VDDZip = $null
        ParsecInstaller = $null
        ParsecVDAInstaller = $null
        VBCableZip = $null
        VirtualAudioDriverZip = $null
        NefConZip = $null
        VCRedist = $null
    }
    PhaseCompleted = @()
}

# ============================================================================
# Backward-compatible params hashtable / 向后兼容的 params 哈希表
# ============================================================================
# When -Interactive is NOT used, this serves as the configuration source.
# 当不使用 -Interactive 时，此哈希表作为配置来源。
$params = @{
    VMName = "GPUPV"
    SourcePath = "C:\Users\james\Downloads\Win11_English_x64.iso"
    Edition    = 6
    VhdFormat  = "VHDX"
    DiskLayout = "UEFI"
    SizeBytes  = 40GB
    MemoryAmount = 8GB
    CPUCores = 4
    # Make sure your specified switch is configured for the external network. A internet connection is required on the first boot.
    NetworkSwitch = "Default Switch"
    VHDPath = "C:\ProgramData\Microsoft\Windows\Virtual Hard Disks\"
    UnattendPath = "$PSScriptRoot"+"\autounattend.xml"
    GPUName = "AUTO"
    GPUResourceAllocationPercentage = 50
    GPUAllocationPolicy = $null # Optional canonical policy; null uses the legacy percentage.

    # Valid combinations are: 
    # 1. All four false (just a machine with GPU-PV support) 
    # 2. Parsec + ParsecVDA
    # 3. Parsec + Virtual-Display-Driver (with or without HDR support depending on the build version of your specified ISO) 
    # 4. Sunshine + Virtual-Display-Driver (with or without HDR support depending on the build version of your specified ISO)
    # 5. Sunshine + ParsecVDA
    Parsec = $true
    ParsecVDA = $true
    Sunshine = $false
    VirtualDisplayDriver = $false

    # Optional: provide local installer files to avoid downloading from the internet / 可选：提供本地安装文件以避免从互联网下载
    LocalParsecPath = ""
    LocalSunshinePath = ""
    LocalVBCableZipPath = ""
    LocalVirtualAudioDriverPath = ""
    LocalParsecVDAPath = ""
    LocalVirtualDisplayDriverPath = ""
    LocalVirtualDisplayDriverHDRPath = ""

    Team_ID = ""
    Key = ""
    Username = "GPUVM"
    Password = $null
    Autologon = "true"
    # Only affects keyboard layout and other minor settings, language is predetermined by the specified ISO
    # If you want to use the default settings by your ISO leave this parameter empty like this: ""  
    # To find languages/region tags use the following link: https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/available-language-packs-for-windows?view=windows-11
    Language = ""
    # If you want to use the default setting by your ISO leave this parameter empty like this: ""
    # To find your timezone use the following link: https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/default-time-zones?view=windows-11
    Timezone = ""
}

Import-Module (Join-Path $PSScriptRoot 'GpuPV-Allocation.psm1') -ErrorAction Stop
Import-Module $PSScriptRoot\Add-VMGpuPartitionAdapterFiles.psm1
Import-Module $PSScriptRoot\Enhanced-GPU-PV-Common.psm1
Import-Module (Join-Path $PSScriptRoot "GpuPV-Workflow.psm1") -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot "GpuPV-TargetSafety.psm1") -ErrorAction Stop

# Resolve explicit allocation text without querying the host. Prompt only when it is absent.
$script:RequestedGpuAllocationPolicy = $null
$allocationArgs = @{}
foreach ($pair in @(@('GPUAllocation','Allocation'),@('GPUComputePercentage','ComputePercentage'),@('GPUEncodePercentage','EncodePercentage'),@('GPUDecodePercentage','DecodePercentage'))) {
    if ($PSBoundParameters.ContainsKey($pair[0])) { $allocationArgs[$pair[1]] = $PSBoundParameters[$pair[0]] }
}
if ($allocationArgs.Count -gt 0) { $script:RequestedGpuAllocationPolicy = New-GpuPVAllocationPolicy @allocationArgs }

function Set-NewVmAllocationPolicy {
    if ($null -eq $script:Config.GPUAllocationPolicy) {
        $script:Config.GPUAllocationPolicy = ConvertTo-GpuPVAllocationPolicy -Policy @{Mode='Percent';Percentage=$script:Config.GPUResourceAllocationPercentage}
    } else { $script:Config.GPUAllocationPolicy = ConvertTo-GpuPVAllocationPolicy -Policy $script:Config.GPUAllocationPolicy }
    $script:Config.GPUResourceAllocationPercentage = if ($script:Config.GPUAllocationPolicy.Mode -eq 'Percent') { $script:Config.GPUAllocationPolicy.Percentage } else { [decimal]50 }
}

# ============================================================================
# Interactive Configuration Wizard Functions / 交互式配置向导函数
# ============================================================================

Function Invoke-ConfigWizard {
<#
.SYNOPSIS
    Run the interactive configuration wizard and populate $script:Config.
    运行交互式配置向导并填充 $script:Config。
#>
    [CmdletBinding()]
    param([string]$KnownVMName)
    Clear-Host
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "Enhanced-GPU-PV VM Creation Wizard" -ForegroundColor Cyan
    Write-Host "Enhanced-GPU-PV 虚拟机创建向导" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "This wizard will guide you through creating a GPU-PV VM." -ForegroundColor Yellow
    Write-Host "本向导将引导您完成 GPU-PV 虚拟机的创建。" -ForegroundColor Yellow
    Write-Host ""

    # Step 1: VM Basic Info
    Write-StepHeader -StepNumber "1" -EnTitle "VM Basic Information" -ZhTitle "虚拟机基本信息"
    $script:Config.VMName = $KnownVMName
    if (-not $KnownVMName) { $script:Config.VMName = Read-Host "VM Name / 虚拟机名称 (default: GPUVM)" }
    if ([string]::IsNullOrWhiteSpace($script:Config.VMName)) { $script:Config.VMName = "GPUVM" }
    $script:Config.SourcePath = Read-Host "ISO Path / ISO 路径"
    $script:Config.VHDPath = Read-Host "VHD Directory / VHD 目录 (default: C:\ProgramData\Microsoft\Windows\Virtual Hard Disks\)"
    if ([string]::IsNullOrWhiteSpace($script:Config.VHDPath)) { $script:Config.VHDPath = "C:\ProgramData\Microsoft\Windows\Virtual Hard Disks\" }
    $memInput = Read-Host "Memory (GB) / 内存(GB) (default: 8)"
    if ([string]::IsNullOrWhiteSpace($memInput)) { $memInput = "8" }
    try { $memVal = [int64]$memInput } catch { Write-Warning "Invalid memory '$memInput', using 8. / 无效内存 '$memInput'，使用 8。"; $memVal = 8 }
    if ($memVal -lt 1) { $memVal = 8 }
    $script:Config.MemoryAmount = $memVal * 1GB
    $cpuInput = Read-Host "CPU Cores / CPU 核心数 (default: 4)"
    if ([string]::IsNullOrWhiteSpace($cpuInput)) { $cpuInput = "4" }
    try { $cpuVal = [int]$cpuInput } catch { Write-Warning "Invalid CPU '$cpuInput', using 4. / 无效 CPU '$cpuInput'，使用 4。"; $cpuVal = 4 }
    if ($cpuVal -lt 1) { $cpuVal = 4 }
    $script:Config.CPUCores = $cpuVal
    $diskInput = Read-Host "Disk Size (GB) / 磁盘大小(GB) (default: 40)"
    if ([string]::IsNullOrWhiteSpace($diskInput)) { $diskInput = "40" }
    try { $diskVal = [int64]$diskInput } catch { Write-Warning "Invalid disk '$diskInput', using 40. / 无效磁盘 '$diskInput'，使用 40。"; $diskVal = 40 }
    if ($diskVal -lt 20) { $diskVal = 40 }
    $script:Config.SizeBytes = $diskVal * 1GB
    $script:Config.NetworkSwitch = Read-Host "Network Switch / 网络交换机 (default: Default Switch)"
    if ([string]::IsNullOrWhiteSpace($script:Config.NetworkSwitch)) { $script:Config.NetworkSwitch = "Default Switch" }

    # Step 2: GPU Config
    Write-StepHeader -StepNumber "2" -EnTitle "GPU Configuration" -ZhTitle "GPU 配置"
    Write-Host "Detecting GPUs... / 正在检测 GPU..." -ForegroundColor Yellow
    $gpus = Get-WmiObject Win32_VideoController | Where-Object { $_.Name -notmatch "Basic|Remote|Virtual|Hyper-V" }
    if ($gpus) {
        Write-Host "Available GPUs / 可用 GPU:" -ForegroundColor Green
        for ($i = 0; $i -lt $gpus.Count; $i++) {
            Write-Host "  [$i] $($gpus[$i].Name)"
        }
        Write-Host "  [A] AUTO (let script choose)"
        $gpuChoice = Read-Host "Select GPU / 选择 GPU (0-$($gpus.Count-1) or A)"
        if ($gpuChoice -eq "A" -or $gpuChoice -eq "a") {
            $script:Config.GPUName = "AUTO"
        } elseif ($gpuChoice -match "^\d+$" -and [int]$gpuChoice -lt $gpus.Count) {
            $script:Config.GPUName = $gpus[[int]$gpuChoice].Name
        } else {
            $script:Config.GPUName = "AUTO"
        }
    } else {
        $script:Config.GPUName = "AUTO"
    }
    # Windows 10 must use AUTO (specific GPU selection is Win11+ only) / Windows 10 必须用 AUTO（指定 GPU 仅 Win11+ 支持）
    try {
        $osBuild = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop).CurrentBuild
        if ([int]$osBuild -lt 22000) { $script:Config.GPUName = "AUTO" }
    } catch { }
    $script:Config.GPUAllocationPolicy = if ($null -ne $script:RequestedGpuAllocationPolicy) { $script:RequestedGpuAllocationPolicy } else { Read-GpuPVAllocationPolicy }
    Set-NewVmAllocationPolicy
    Write-Host (Format-GpuPVAllocationPolicy -Policy $script:Config.GPUAllocationPolicy)

    # Step 3: Streaming Choice
    Write-StepHeader -StepNumber "3" -EnTitle "Streaming Software" -ZhTitle "串流软件"
    Write-Host "[1] Parsec + ParsecVDA"
    Write-Host "[2] Parsec + Virtual Display Driver"
    Write-Host "[3] Sunshine + ParsecVDA"
    Write-Host "[4] Sunshine + Virtual Display Driver"
    Write-Host "[5] Just GPU-PV (no streaming software)"
    $streamChoice = Read-Host "Choice / 选择 (1-5)"
    switch ($streamChoice) {
        "1" { $script:Config.StreamingChoice = "Parsec+ParsecVDA" }
        "2" { $script:Config.StreamingChoice = "Parsec+VDD" }
        "3" { $script:Config.StreamingChoice = "Sunshine+ParsecVDA" }
        "4" { $script:Config.StreamingChoice = "Sunshine+VDD" }
        default { $script:Config.StreamingChoice = "None" }
    }

    # Packages are prepared and verified on the host for every supported path.
    Write-StepHeader -StepNumber "4" -EnTitle "Installer preparation" -ZhTitle "安装包准备"
    Write-Host "HostDownload: pinned packages are checked on host and guest. / 宿主与来宾均核验安装包。"
    Write-Host "Legacy VMDownload templates are retained for reference and are not used. / 旧模板仅保留参考。"
    $script:Config.SecurityModel = "HostDownload"

    # Step 4.5: Audio Driver / 音频驱动
    Write-StepHeader -StepNumber "4.5" -EnTitle "Audio Driver" -ZhTitle "音频驱动"
    Write-Host "[1] VB-Audio Virtual Cable (Default, Mature)" -ForegroundColor Green
    Write-Host "    默认选项，成熟稳定。"
    Write-Host "[2] Virtual Audio Driver by VirtualDrivers (+Virtual Mic)" -ForegroundColor Cyan
    Write-Host "    VirtualDrivers 官方虚拟音频驱动，附带虚拟麦克风。"
    Write-Host "[3] None / Do not install audio driver" -ForegroundColor Yellow
    Write-Host "    不安装音频驱动。"
    $audioChoice = Read-Host "Choice / 选择 (1-3, default: 1)"
    switch ($audioChoice) {
        "2" { $script:Config.AudioDriver = "VirtualAudioDriver" }
        "3" { $script:Config.AudioDriver = "None" }
        default { $script:Config.AudioDriver = "VBCable" }
    }

    # Step 5: Sunshine Advanced Config (if Sunshine selected)
    if ($script:Config.StreamingChoice -match "Sunshine") {
        Write-StepHeader -StepNumber "5" -EnTitle "Sunshine Advanced Configuration" -ZhTitle "Sunshine 高级配置"
        Write-Host "[1] Default - Balanced settings"
        Write-Host "[2] Performance - Low latency, medium quality"
        Write-Host "[3] Quality - High quality, higher latency"
        Write-Host "[4] Custom - Configure manually"
        $sunPreset = Read-Host "Preset / 预设 (1-4)"
        # Reset AV1Mode so non-Custom presets don't inherit a stale value from a previous run / 重置 AV1Mode，避免非 Custom 预设继承上次运行的残留值
        $script:Config.SunshineStreamConfig.AV1Mode = "0"
        switch ($sunPreset) {
            "2" {
                $script:Config.SunshineStreamConfig.Preset = "Performance"
                $script:Config.SunshineStreamConfig.Resolution = "1920x1080"
                $script:Config.SunshineStreamConfig.FPS = "120"
                $script:Config.SunshineStreamConfig.HEVCMode = "0"
                $script:Config.SunshineStreamConfig.HDRMode = "disabled"
                $script:Config.SunshineStreamConfig.Bitrate = "20000"
            }
            "3" {
                $script:Config.SunshineStreamConfig.Preset = "Quality"
                $script:Config.SunshineStreamConfig.Resolution = "3840x2160"
                $script:Config.SunshineStreamConfig.FPS = "60"
                $script:Config.SunshineStreamConfig.HEVCMode = "0"
                $script:Config.SunshineStreamConfig.HDRMode = "disabled"
                $script:Config.SunshineStreamConfig.Bitrate = "80000"
            }
            "4" {
                $script:Config.SunshineStreamConfig.Preset = "Custom"
                $script:Config.SunshineStreamConfig.Resolution = Read-Host "Resolution / 分辨率 (e.g. 3840x2160)"
                if ([string]::IsNullOrWhiteSpace($script:Config.SunshineStreamConfig.Resolution)) { $script:Config.SunshineStreamConfig.Resolution = "3840x2160" }
                $script:Config.SunshineStreamConfig.FPS = Read-Host "FPS / 帧率 (default: 120)"
                if ([string]::IsNullOrWhiteSpace($script:Config.SunshineStreamConfig.FPS)) { $script:Config.SunshineStreamConfig.FPS = "120" }
                $script:Config.SunshineStreamConfig.HEVCMode = Read-Host "HEVC Mode (0=auto, 1=disabled, 2=Main, 3=Main10, default: 0)"
                if ([string]::IsNullOrWhiteSpace($script:Config.SunshineStreamConfig.HEVCMode)) { $script:Config.SunshineStreamConfig.HEVCMode = "0" }
                $script:Config.SunshineStreamConfig.AV1Mode = Read-Host "AV1 Mode (0=auto, 1=disabled, 2=Main8, 3=Main10, default: 0)"
                if ([string]::IsNullOrWhiteSpace($script:Config.SunshineStreamConfig.AV1Mode)) { $script:Config.SunshineStreamConfig.AV1Mode = "0" }
                $script:Config.SunshineStreamConfig.HDRMode = Read-Host "HDR Mode (disabled or auto, default: disabled)"
                if ([string]::IsNullOrWhiteSpace($script:Config.SunshineStreamConfig.HDRMode)) { $script:Config.SunshineStreamConfig.HDRMode = "disabled" }
                $script:Config.SunshineStreamConfig.Bitrate = Read-Host "Bitrate (kbps, default: 50000)"
                if ([string]::IsNullOrWhiteSpace($script:Config.SunshineStreamConfig.Bitrate)) { $script:Config.SunshineStreamConfig.Bitrate = "50000" }
            }
            default {
                $script:Config.SunshineStreamConfig.Preset = "Default"
                $script:Config.SunshineStreamConfig.Resolution = "1920x1080"
                $script:Config.SunshineStreamConfig.FPS = "60"
                $script:Config.SunshineStreamConfig.HEVCMode = "0"
                $script:Config.SunshineStreamConfig.HDRMode = "disabled"
                $script:Config.SunshineStreamConfig.Bitrate = "20000"
            }
        }

    }

    # Step 6: VDD Config (if VDD selected, regardless of Sunshine) / 第 6 步: VDD 配置（只要选了 VDD，不限 Sunshine）
    if ($script:Config.StreamingChoice -match "VDD") {
        Write-StepHeader -StepNumber "6" -EnTitle "Virtual Display Driver Configuration" -ZhTitle "虚拟显示驱动器配置"
        $vddRes = Read-Host "Resolution / 分辨率 (default: 3840x2160)"
        if ([string]::IsNullOrWhiteSpace($vddRes)) { $vddRes = "3840x2160" }
        $script:Config.VDDConfig.Resolution = $vddRes
        $vddHz = Read-Host "Refresh Rate / 刷新率 (default: 120)"
        if ([string]::IsNullOrWhiteSpace($vddHz)) { $vddHz = "120" }
        $script:Config.VDDConfig.RefreshRate = $vddHz
    }

    # Step 7: Connection Method (if Sunshine or VDD) / 第 7 步: 连接方式（Sunshine 或 VDD）
    if ($script:Config.StreamingChoice -match "Sunshine|VDD") {
        Write-StepHeader -StepNumber "7" -EnTitle "Connection Method" -ZhTitle "连接方式"
        Write-Host "[1] Auto - Disable RDP virtual adapters, pair Sunshine via browser" -ForegroundColor Green
        Write-Host "    Auto 模式 - 禁用 RDP 虚拟适配器，通过浏览器配对 Sunshine"
        Write-Host "[2] KeepRDP - Keep RDP available, place VDD activation script on Desktop" -ForegroundColor Yellow
        Write-Host "    KeepRDP 模式 - 保留 RDP，桌面放置 VDD 激活脚本"
        $connChoice = Read-Host "Choice / 选择 (1-2)"
        if ($connChoice -eq "2") {
            $script:Config.ConnectionMethod = "KeepRdp"
        } else {
            $script:Config.ConnectionMethod = "Auto"
        }
    }

    # Step 8: Account Info
    Write-StepHeader -StepNumber "8" -EnTitle "Account Information" -ZhTitle "账户信息"
    $script:Config.Username = Read-Host "Username / 用户名 (default: GPUVM)"
    if ([string]::IsNullOrWhiteSpace($script:Config.Username)) { $script:Config.Username = "GPUVM" }
    $pwInput = Read-GpuPVSecret -Prompt "Windows password (required; not saved in checkpoint)"
    if ([string]::IsNullOrWhiteSpace($pwInput)) { throw "A nonempty Windows password is required." }
    $script:Config.Password = $pwInput
    # Parsec Teams credentials (optional, only for Parsec) / Parsec Teams 凭据（可选，仅 Parsec）
    if ((Get-GpuPVStreamingPlan $script:Config.StreamingChoice).Parsec) {
        $script:Config.Team_ID = Read-Host "Parsec Team ID (leave empty if not a Teams subscriber) / Parsec 团队 ID（非 Teams 订阅留空）"
        $script:Config.Key = Read-GpuPVSecret -Prompt "Parsec Team Key (optional; automatic Teams enrollment is not supported)"
    }
    $script:Config.Language = Read-Host "Language / 语言 (e.g. en-US, zh-CN, leave empty for default)"
    $script:Config.Timezone = Read-Host "Timezone / 时区 (leave empty for default)"

    Write-Host ""
    Write-Host "========================================" -ForegroundColor Green
    Write-Host "Configuration Complete! / 配置完成！" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green
    Write-Host "Press Enter to begin VM creation... / 按回车键开始创建虚拟机..."
    Read-Host
}

Function Sync-ConfigToParams {
<#
.SYNOPSIS
    Map $script:Config values back to $params for backward compatibility.
    将 $script:Config 的值映射回 $params 以保持向后兼容。
#>
    [CmdletBinding()]
    param()
    Set-NewVmAllocationPolicy
    $params.GPUAllocationPolicy = $script:Config.GPUAllocationPolicy
    $params.VMName = $script:Config.VMName
    $params.SourcePath = $script:Config.SourcePath
    $params.VHDPath = $script:Config.VHDPath
    $params.Edition = $script:Config.Edition
    $params.VhdFormat = $script:Config.VhdFormat
    $params.DiskLayout = $script:Config.DiskLayout
    $params.SizeBytes = $script:Config.SizeBytes
    $params.MemoryAmount = $script:Config.MemoryAmount
    $params.CPUCores = $script:Config.CPUCores
    $params.NetworkSwitch = $script:Config.NetworkSwitch
    $params.GPUName = $script:Config.GPUName
    $params.GPUResourceAllocationPercentage = $script:Config.GPUResourceAllocationPercentage
    $params.Username = $script:Config.Username
    $params.Password = $script:Config.Password
    $params.Autologon = $script:Config.Autologon
    $params.Language = $script:Config.Language
    $params.Timezone = $script:Config.Timezone
    $params.Team_ID = $script:Config.Team_ID
    $params.Key = $script:Config.Key

    # Map streaming choice to boolean flags / 将串流选择映射为布尔标志
    $sc = $script:Config.StreamingChoice
    $params.Parsec = ($sc -eq "Parsec+ParsecVDA" -or $sc -eq "Parsec+VDD")
    $params.ParsecVDA = ($sc -eq "Parsec+ParsecVDA" -or $sc -eq "Sunshine+ParsecVDA")
    $params.Sunshine = ($sc -eq "Sunshine+ParsecVDA" -or $sc -eq "Sunshine+VDD")
    $params.VirtualDisplayDriver = ($sc -eq "Parsec+VDD" -or $sc -eq "Sunshine+VDD")

    # Map local installer paths / 映射本地安装文件路径
    $ifps = $script:Config.InstallFilePaths
    if ($ifps.SunshineInstaller) { $params.LocalSunshinePath = $ifps.SunshineInstaller }
    if ($ifps.ParsecInstaller) { $params.LocalParsecPath = $ifps.ParsecInstaller }
    if ($ifps.ParsecVDAInstaller) { $params.LocalParsecVDAPath = $ifps.ParsecVDAInstaller }
    if ($ifps.VBCableZip) { $params.LocalVBCableZipPath = $ifps.VBCableZip }
    if ($ifps.VirtualAudioDriverZip) { $params.LocalVirtualAudioDriverPath = $ifps.VirtualAudioDriverZip }
    if ($ifps.VDDZip) { $params.LocalVirtualDisplayDriverPath = $ifps.VDDZip }
    # VDD HDR variant removed - VirtualDrivers official version uses single ZIP / VDD HDR 变体已移除 - VirtualDrivers 官方版本使用单一 ZIP
}

# ============================================================================
# Host File Preparation / 宿主机文件准备
# ============================================================================

Function Invoke-HostFilePreparation {
<#
.SYNOPSIS
    Download all required installer files on the host for HostDownload mode.
    在宿主机下载 HostDownload 模式所需的所有安装文件。
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [hashtable]$Config
    )
    $downloadDir = Join-Path $PSScriptRoot "Downloads"
    if (-not (Test-Path $downloadDir)) {
        New-Item -ItemType Directory -Path $downloadDir -Force | Out-Null
    }

    $sc = $Config.StreamingChoice
    $plan = Get-GpuPVStreamingPlan -Choice $sc
    Write-StepHeader -StepNumber "2-H" -EnTitle "Host File Preparation" -ZhTitle "宿主机文件准备"

    # Sunshine installer / Sunshine 安装程序
    if ($plan.Sunshine) {
        $dest = Join-Path $downloadDir (Get-GpuPVInstallerPolicy -DisplayName "Sunshine").FileName
        Invoke-DownloadWithCache -Url "https://github.com/LizardByte/Sunshine/releases/latest/download/Sunshine-Windows-AMD64-installer.exe" -DestinationPath $dest -DisplayName "Sunshine"
        $Config.InstallFilePaths.SunshineInstaller = $dest
    }

    # VDD / 虚拟显示驱动器 (VirtualDrivers official / VirtualDrivers 官方版本)
    if ($plan.VDD) {
        $dest = Join-Path $downloadDir "VirtualDisplayDriver-x86.Driver.Only.zip"
        Invoke-DownloadWithCache -Url "https://github.com/VirtualDrivers/Virtual-Display-Driver/releases/latest/download/VirtualDisplayDriver-x86.Driver.Only.zip" -DestinationPath $dest -DisplayName "VDD" -FallbackFileNames @("vdd-driver.zip")
        $Config.InstallFilePaths.VDDZip = $dest
    }

    # Parsec / Parsec
    if ($plan.Parsec) {
        $dest = Join-Path $downloadDir "parsec-windows.exe"
        Invoke-DownloadWithCache -Url "https://builds.parsecgaming.com/package/parsec-windows.exe" -DestinationPath $dest -DisplayName "Parsec"
        $Config.InstallFilePaths.ParsecInstaller = $dest
    }

    # ParsecVDA / ParsecVDA
    if ($plan.ParsecVDA) {
        $dest = Join-Path $downloadDir "ParsecVDA.-.Always.Connected-v1.4.1-setup-x64.exe"
        Invoke-DownloadWithCache -Url "https://github.com/timminator/ParsecVDA-Always-Connected/releases/download/v1.4.1/ParsecVDA.-.Always.Connected-v1.4.1-setup-x64.exe" -DestinationPath $dest -DisplayName "ParsecVDA"
        $Config.InstallFilePaths.ParsecVDAInstaller = $dest
    }

    # Audio Driver / 音频驱动
    switch ($Config.AudioDriver) {
        "VirtualAudioDriver" {
            $dest = Join-Path $downloadDir "VirtualAudioDriver.zip"
            Invoke-DownloadWithCache -Url "https://github.com/VirtualDrivers/Virtual-Display-Driver/releases/latest/download/VirtualAudioDriver-x86.Driver.Only.zip" -DestinationPath $dest -DisplayName "Virtual Audio Driver" -FallbackFileNames @("VirtualAudioDriver-x86.Driver.Only.zip")
            $Config.InstallFilePaths.VirtualAudioDriverZip = $dest
        }
        "VBCable" {
            $dest = Join-Path $downloadDir "VBCable.zip"
            Invoke-DownloadWithCache -Url "https://download.vb-audio.com/Download_CABLE/VBCABLE_Driver_Pack43.zip" -DestinationPath $dest -DisplayName "VB-Cable"
            $Config.InstallFilePaths.VBCableZip = $dest
        }
        "None" { }
        default { throw "Unknown audio driver choice." }
    }

    # NefCon (required for VDD installation) / NefCon（VDD 安装必需）
    if ($plan.VDD -or $Config.AudioDriver -eq "VirtualAudioDriver") {
        $dest = Join-Path $downloadDir "nefcon_v1.17.40.zip"
        Invoke-DownloadWithCache -Url "https://github.com/nefarius/nefcon/releases/download/v1.17.40/nefcon_v1.17.40.zip" -DestinationPath $dest -DisplayName "NefCon" -FallbackFileNames @("nefcon.zip")
        $Config.InstallFilePaths.NefConZip = $dest
        # Extract now so we can reference the x64 exe later / 现在解压以便后续引用 x64 版本
        $nefconExtractDir = Join-Path $downloadDir "NefCon"
        # Guest extraction uses the verified ZIP and a fresh per-run directory.
    }

    # VC++ Redistributable / VC++ 运行库
    $dest = Join-Path $downloadDir "vc_redist.x64.exe"
    Invoke-DownloadWithCache -Url "https://aka.ms/vs/17/release/vc_redist.x64.exe" -DestinationPath $dest -DisplayName "VC++ Redist"
    $Config.InstallFilePaths.VCRedist = $dest

    Write-Bilingual -En "All files prepared in $downloadDir" -Zh "所有文件已准备到 $downloadDir"
}

Function Copy-InstallerFilesToVHDX {
    param([Parameter(Mandatory=$true)]$Target,[Parameter(Mandatory=$true)][hashtable]$Config)
    Assert-GpuPVTarget -Target $Target
    $progData = Assert-GpuPVTargetPath -Target $Target -Path ($Target.Root + 'ProgramData\Easy-GPU-P')
    $installersDir = Assert-GpuPVTargetPath -Target $Target -Path (Join-Path $progData 'Installers')
    New-Item -ItemType Directory -Path $installersDir -Force -ErrorAction Stop | Out-Null
    $componentMap = @{SunshineInstaller=@('Sunshine','Sunshine');VDDZip=@('VDD','VDD');ParsecInstaller=@('Parsec','Parsec');ParsecVDAInstaller=@('ParsecVDA','ParsecVDA');VBCableZip=@('VBCable','VB-Cable');VirtualAudioDriverZip=@('VirtualAudioDriver','Virtual Audio Driver');NefConZip=@('NefCon','NefCon');VCRedist=@('VCRedist','VC++ Redist')}
    $files = @{}
    foreach ($key in $Config.InstallFilePaths.Keys) {
        $source = $Config.InstallFilePaths[$key]
        if (-not $source) { continue }
        if (-not $componentMap.ContainsKey($key)) { throw 'Unknown staged installer component.' }
        $component,$displayName = $componentMap[$key]
        $policy = Get-GpuPVInstallerPolicy -DisplayName $displayName
        Assert-GpuPVArtifact -Path $source -ExpectedSha256 $policy.Sha256 -ExpectedSize $policy.Size
        $destination = Assert-GpuPVTargetPath -Target $Target -Path (Join-Path $installersDir $policy.FileName)
        Copy-Item -LiteralPath $source -Destination $destination -Force -ErrorAction Stop
        Assert-GpuPVArtifact -Path $destination -ExpectedSha256 $policy.Sha256 -ExpectedSize $policy.Size
        $files[$component] = @{FileName=$policy.FileName;Sha256=$policy.Sha256;Size=(Get-Item -LiteralPath $destination -ErrorAction Stop).Length;Version=$policy.Version}
    }
    foreach ($name in @('PostBoot-Installer.ps1','Activate-VDD.ps1')) {
        $source = Join-Path (Join-Path $PSScriptRoot 'VMScripts') $name
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Required guest helper is missing: $name" }
        $destination = Assert-GpuPVTargetPath -Target $Target -Path (Join-Path $progData $name)
        Copy-Item -LiteralPath $source -Destination $destination -Force -ErrorAction Stop
    }
    foreach ($name in @('Parsec.lnk','SwitchDisplayParsecVDA.vbs','ParsecVDA.ico','Switch Display to ParsecVDA.bat')) {
        $source = Join-Path (Join-Path $PSScriptRoot 'VMScripts') $name
        if (Test-Path -LiteralPath $source -PathType Leaf) {
            $destination = Assert-GpuPVTargetPath -Target $Target -Path (Join-Path $progData $name)
            Copy-Item -LiteralPath $source -Destination $destination -Force -ErrorAction Stop
        }
    }
    $guestConfig = @{InstallerFiles=$files;StreamingChoice=$Config.StreamingChoice;ConnectionMethod=$Config.ConnectionMethod;SecurityModel=$Config.SecurityModel;AudioDriver=$Config.AudioDriver;SunshineStreamConfig=$Config.SunshineStreamConfig;VDDConfig=$Config.VDDConfig;ParsecConfig=@{}}
    $configPath = Assert-GpuPVTargetPath -Target $Target -Path (Join-Path $installersDir 'config.json')
    Write-GpuPVJsonAtomic -Path $configPath -Value $guestConfig
}

# Reacquire by immutable identity at every phase, never by a reusable display name.
function Resolve-NewVmIdentity {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$VMName, [Parameter(Mandatory=$true)][string]$VMId)
    $id = [guid]::Empty
    if (-not [guid]::TryParse($VMId, [ref]$id) -or $id -eq [guid]::Empty) { throw 'A valid saved target VM identity is required.' }
    $targets = @(Get-VM -Id $id -ErrorAction Stop)
    if ($targets.Count -ne 1 -or [string]$targets[0].VMId -ine [string]$id -or [string]$targets[0].Name -cne $VMName) {
        throw 'Target VM identity/name no longer matches this task; no replacement VM will be adopted.'
    }
    return $targets[0]
}

function Start-NewVmTarget {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$VMName, [Parameter(Mandatory=$true)][string]$VMId)
    $target = Resolve-NewVmIdentity -VMName $VMName -VMId $VMId
    if ([string]$target.State -eq 'Running') { return }
    if ([string]$target.State -ne 'Off') { throw 'VM must be Off or Running; inspect its current state before resuming.' }
    Start-VM -VM $target -ErrorAction Stop
}

Function Invoke-Phase5_WaitForVM {
<#
.SYNOPSIS
    Wait for the VM to finish first boot and become reachable via PowerShell Direct.
    等待 VM 完成首次启动并通过 PowerShell Direct 可达。
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$VMName,
        [Parameter(Mandatory=$true)]
        [string]$VMId,
        [Parameter(Mandatory=$true)]
        [pscredential]$Credential,
        [int]$TimeoutSeconds = 300
    )
    Write-StepHeader -StepNumber "5" -EnTitle "Waiting for VM First Boot" -ZhTitle "等待 VM 首次启动"
    Write-Bilingual -En "Waiting up to $TimeoutSeconds seconds for VM to be ready..." -Zh "最多等待 $TimeoutSeconds 秒让 VM 就绪..."

    $elapsed = 0
    $ready = $false
    while ($elapsed -lt $TimeoutSeconds -and -not $ready) {
        $vm = Resolve-NewVmIdentity -VMName $VMName -VMId $VMId
        if ($vm -and $vm.State -eq 'Running') {
            try {
                $testResult = Invoke-Command -VMId ([guid]$VMId) -Credential $Credential -ScriptBlock {
                    return "READY"
                } -ErrorAction Stop -ArgumentList @()
                if ($testResult -eq "READY") {
                    $ready = $true
                    break
                }
            }
            catch {
                Write-Verbose "PowerShell Direct not ready yet: $_"
            }
        }
        Start-Sleep -Seconds 5
        $elapsed += 5
        Write-Host "." -NoNewline
    }
    Write-Host ""

    if ($ready) {
        Write-Bilingual -En "VM is ready for PowerShell Direct." -Zh "VM 已准备好 PowerShell Direct。"
        return $true
    } else {
        Write-Warning "VM did not become ready within $TimeoutSeconds seconds."
        return $false
    }
}

Function Invoke-Phase6_PostBootInstall {
    param([Parameter(Mandatory=$true)][string]$VMName,[Parameter(Mandatory=$true)][string]$VMId,[Parameter(Mandatory=$true)][pscredential]$Credential)
    $target = Resolve-NewVmIdentity -VMName $VMName -VMId $VMId
    if ([string]$target.State -ne 'Running') { throw 'Target VM must be running before guest installation.' }
    $results = @(Invoke-Command -VMId ([guid]$VMId) -Credential $Credential -ScriptBlock {
        $postBootPath = 'C:\ProgramData\Easy-GPU-P\PostBoot-Installer.ps1'
        if (-not (Test-Path -LiteralPath $postBootPath -PathType Leaf)) { throw 'PostBoot installer is missing.' }
        & $postBootPath
    } -ErrorAction Stop)
    $checked = @($results | Where-Object { $_.PSObject.Properties['SchemaVersion'] -and $_.PSObject.Properties['Components'] })
    if ($checked.Count -ne 1) { throw 'Guest did not return exactly one installation result.' }
    Assert-GpuPVGuestResult -Result $checked[0] -Config $script:Config
    return $checked[0]
}

Function Invoke-Phase7_VerifyAndOutput {
    param([Parameter(Mandatory=$true)][string]$VMName,[Parameter(Mandatory=$true)][hashtable]$Config,[Parameter(Mandatory=$true)][pscredential]$Credential)
    $vm = Resolve-NewVmIdentity -VMName $VMName -VMId $Config.TargetVMId
    if ($vm.State -ne 'Running') { throw 'VM state/identity no longer matches this task.' }
    if (-not (Get-VMGpuPartitionAdapter -VM $vm -ErrorAction Stop)) { throw 'The requested GPU partition adapter is missing.' }
    $results = @(Invoke-Command -VMId ([guid]$Config.TargetVMId) -Credential $Credential -ScriptBlock {
        & 'C:\ProgramData\Easy-GPU-P\PostBoot-Installer.ps1' -VerifyOnly
    } -ErrorAction Stop)
    $checked = @($results | Where-Object { $_.PSObject.Properties['SchemaVersion'] -and $_.PSObject.Properties['Components'] })
    if ($checked.Count -ne 1) { throw 'Guest did not return exactly one verification result.' }
    Assert-GpuPVGuestResult -Result $checked[0] -Config $Config
    Write-Host 'Required guest components were observed. Client pairing, login and picture quality still require manual acceptance.'
    foreach ($action in @($checked[0].ManualActions)) { Write-Host ([string]$action) }
    return $true
}

# Borrowed ISO mounts are never released by this workflow.
function Open-NewVmInstallMedia {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$SourcePath)
    $resolved = (Resolve-Path -LiteralPath $SourcePath -ErrorAction Stop).ProviderPath
    $sourceItem = Get-Item -LiteralPath $resolved -ErrorAction Stop
    if ($sourceItem.PSIsContainer) { throw "Installation media must be a file: $resolved" }
    $extension = [IO.Path]::GetExtension($resolved)
    if ($extension -ieq '.wim') {
        return [pscustomobject]@{ SourcePath=$resolved; ImagePath=$resolved; DriveLetter=$null; MountedByUs=$false }
    }
    if ($extension -ine '.iso') { throw 'Supported media is an ISO containing sources\install.wim, or a WIM file.' }
    $media = [pscustomobject]@{ SourcePath=$resolved; ImagePath=$null; DriveLetter=$null; MountedByUs=$false }
    try {
        $diskImage = Get-DiskImage -ImagePath $resolved -StorageType ISO -ErrorAction Stop
        if (-not $diskImage.Attached) {
            $null = Mount-DiskImage -ImagePath $resolved -StorageType ISO -Access ReadOnly -PassThru -ErrorAction Stop
            $media.MountedByUs = $true
            $diskImage = Get-DiskImage -ImagePath $resolved -StorageType ISO -ErrorAction Stop
        }
        $candidates = @()
        foreach ($volume in @($diskImage | Get-Volume -ErrorAction Stop)) {
            $letter = [string]$volume.DriveLetter
            if ($letter -notmatch '^[A-Za-z]$') { continue }
            $imagePath = "$($letter):\sources\install.wim"
            if (Test-Path -LiteralPath $imagePath -PathType Leaf) {
                $candidates += [pscustomobject]@{ ImagePath=$imagePath; DriveLetter=$letter }
            }
        }
        if ($candidates.Count -ne 1) {
            throw "Expected one accessible sources\install.wim on the ISO; found $($candidates.Count). ESD-only media and ambiguous volumes are unsupported."
        }
        $media.ImagePath = $candidates[0].ImagePath
        $media.DriveLetter = $candidates[0].DriveLetter
        return $media
    }
    catch {
        $failure = $_
        try { Close-NewVmInstallMedia -Media $media }
        catch { Write-Warning "ISO cleanup also failed; inspect the owned mount at '$resolved': $($_.Exception.Message)" }
        throw $failure
    }
}

function Close-NewVmInstallMedia {
    [CmdletBinding()]
    param([AllowNull()][object]$Media)
    if ($null -ne $Media -and $Media.MountedByUs) {
        $null = Dismount-DiskImage -ImagePath $Media.SourcePath -ErrorAction Stop
        $Media.MountedByUs = $false
    }
}

function Select-NewVmWindowsImage {
    [CmdletBinding()]
    param([AllowEmptyCollection()][object[]]$Images, [string[]]$Edition)
    $imagesFound = @($Images | Where-Object { $null -ne $_ })
    if ($imagesFound.Count -eq 0) { throw 'No Windows images were found in the WIM.' }
    $selectors = @($Edition | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($selectors.Count -gt 1) { throw 'Specify exactly one Windows edition or image index.' }
    if ($selectors.Count -eq 0) {
        if ($imagesFound.Count -ne 1) { throw 'This WIM contains multiple images; specify an edition or image index.' }
        return $imagesFound[0]
    }
    $selector = $selectors[0]
    $index = 0
    if ([int]::TryParse($selector, [ref]$index)) {
        if ($index -lt 1) { throw 'The Windows image index must be positive.' }
        $matches = @($imagesFound | Where-Object { $_.ImageIndex -eq $index })
    }
    else {
        $matches = @($imagesFound | Where-Object { $_.ImageName -ieq $selector })
        if ($matches.Count -eq 0) {
            # Preserve suffix shorthand, but treat user wildcard characters literally.
            $pattern = '*' + [Management.Automation.WildcardPattern]::Escape($selector)
            $matches = @($imagesFound | Where-Object { $_.ImageName -ilike $pattern })
        }
    }
    if ($matches.Count -ne 1) { throw "Requested Windows image '$selector' matched $($matches.Count) images; exactly one is required." }
    return $matches[0]
}

function Publish-NewVmVhd {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$TemporaryPath, [Parameter(Mandatory=$true)][string]$FinalPath)
    $source = Get-Item -LiteralPath $TemporaryPath -ErrorAction Stop
    if ($source.PSIsContainer -or $source.Length -le 0) { throw 'Conversion did not produce a nonempty VHD file.' }
    if (Test-Path -LiteralPath $FinalPath) { throw "Refusing to replace existing VHD '$FinalPath'. Temporary output is retained at '$TemporaryPath'." }
    if ([IO.Path]::GetFullPath((Split-Path -Parent $TemporaryPath)) -ine [IO.Path]::GetFullPath((Split-Path -Parent $FinalPath))) {
        throw 'Final VHD publication must stay in the same directory.'
    }
    Rename-Item -LiteralPath $TemporaryPath -NewName (Split-Path -Leaf $FinalPath) -ErrorAction Stop
}

Function Check-Params {

$ExitReason = @()

if ([ENVIRONMENT]::Is64BitProcess -eq $false) {
    $ExitReason += "You are not using the correct version of Powershell, do not use Powershell(x86)."
    }
if ((Is-Administrator) -eq $false) {
    $ExitReason += "Script not running as Administrator, please run script as Administrator."
    }
if (!(Test-Path $params.VHDPath)) {
    $ExitReason += "VHDPath Directory doesn't exist, please create it before running this script."
    }
if (!(test-path $params.SourcePath)) {
    $ExitReason += "ISO Path Invalid. Please enter a valid ISO Path in the SourcePath section of Params."
    }
else {
    $validationMedia = $null
    try { $validationMedia = Open-NewVmInstallMedia -SourcePath $params.SourcePath }
    finally { Close-NewVmInstallMedia -Media $validationMedia }
    }
if ($params.Username -eq $params.VMName ) {
    $ExitReason += "Username cannot be the same as VMName."
    }
if (!($params.Username -match "^[a-zA-Z0-9]+$")) {
    $ExitReason += "Username cannot contain special characters."
    }
if (($params.VMName -notmatch "^[a-zA-Z0-9]+$") -or ($params.VMName.Length -gt 15)) {
    $ExitReason += "VMName cannot contain special characters, or be more than 15 characters long"
    }
if (([Environment]::OSVersion.Version.Build -lt 22000) -and ($params.GPUName -ne "AUTO")) {
    $ExitReason += "GPUName must be set to AUTO on Windows 10."
    }

$A = $params.Parsec
$B = $params.ParsecVDA
$C = $params.Sunshine
$D = $params.VirtualDisplayDriver

$countTrue = ($A, $B, $C, $D | Where-Object { $_ }).Count

if (($countTrue -ne 0 -and $countTrue -ne 2) -or
    ($A -and $C) -or
    ($B -and $D)) {
    $ExitReason += "Invalid combination of Parsec, ParsecVDA, Sunshine, and VirtualDisplayDriver. Either all must be false, or exactly two must be true, excluding the cases where both Parsec and Sunshine are true, or both ParsecVDA and VirtualDisplayDriver are true."
}
If ($ExitReason.Count -gt 0) {
    Write-Host "Script failed params check due to the following reasons:" -ForegroundColor DarkYellow
    ForEach ($IndividualReason in $ExitReason) {
        Write-Host "ERROR: $IndividualReason" -ForegroundColor RED
        }
    SmartExit -ExitReason ($ExitReason -join "`n")
    }
}

Function Get-BuildVersionSimple {
param (
    [string]$SourcePath,
    [int]$ImageIndex
)
    $WindowsImage = Get-WindowsImage -ImagePath $SourcePath -Index $ImageIndex
    return $WindowsImage.Version
}

Function Get-BuildVersionExact {
    [CmdletBinding()]
    param(
        [string]$DriveLetter,
        [Parameter(Mandatory=$true)][ValidateRange(1,2147483647)][int]$ImageIndex,
        [string]$ImagePath,
        [string]$TempRoot = $env:TEMP
    )
    if ([string]::IsNullOrWhiteSpace($ImagePath)) {
        if ($DriveLetter -notmatch '^[A-Za-z]$') { throw 'An explicit WIM path or a single ISO drive letter is required.' }
        $ImagePath = "$($DriveLetter):\sources\install.wim"
    }
    $token = [guid]::NewGuid().ToString('N')
    $mountPath = Join-Path $TempRoot ('GpuPV-Wim-' + $token)
    $hiveDirectory = Join-Path $TempRoot ('GpuPV-Hive-' + $token)
    $hiveCopy = Join-Path $hiveDirectory 'SOFTWARE.hiv'
    $hiveDirectoryOwned = $false
    $hiveName = 'GpuPV_' + $token
    $nativeHive = 'HKLM\' + $hiveName
    $registryKey = 'Registry::HKEY_LOCAL_MACHINE\' + $hiveName + '\Microsoft\Windows NT\CurrentVersion'
    $wimMounted = $false
    $hiveLoaded = $false
    $mountAttempted = $false
    $primaryFailure = $null
    $cleanupErrors = @()
    $null = New-Item -ItemType Directory -Path $mountPath -ErrorAction Stop
    try {
        $mountAttempted = $true
        $null = Mount-WindowsImage -ImagePath $ImagePath -Path $mountPath -Index $ImageIndex -ReadOnly -ErrorAction Stop
        $wimMounted = $true
        $registryPath = Join-Path $mountPath 'Windows\system32\config\SOFTWARE'
        $null = New-Item -ItemType Directory -Path $hiveDirectory -ErrorAction Stop
        $hiveDirectoryOwned = $true
        Copy-Item -LiteralPath $registryPath -Destination $hiveCopy -ErrorAction Stop
        # Copying a read-only source can preserve its attribute; change only our copy.
        (Get-Item -LiteralPath $hiveCopy -ErrorAction Stop).IsReadOnly = $false
        & reg.exe load $nativeHive $hiveCopy | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "reg load failed with exit code $LASTEXITCODE" }
        $hiveLoaded = $true
        $property = Get-ItemProperty -LiteralPath $registryKey -Name CurrentBuild -ErrorAction Stop
        $build = 0
        if (-not [int]::TryParse([string]$property.CurrentBuild, [ref]$build) -or $build -le 0) { throw 'The offline CurrentBuild value is missing or invalid.' }
        return $build
    }
    catch { $primaryFailure = $_; throw }
    finally {
        if ($hiveLoaded) {
            try {
                & reg.exe unload $nativeHive | Out-Null
                if ($LASTEXITCODE -ne 0) { throw "reg unload failed with exit code $LASTEXITCODE" }
                $hiveLoaded = $false
            }
            catch { $cleanupErrors += "Hive '$nativeHive' remains loaded: $($_.Exception.Message)" }
        }
        if ($wimMounted) {
            try {
                $null = Dismount-WindowsImage -Path $mountPath -Discard -ErrorAction Stop
                $wimMounted = $false
                $mountAttempted = $false
            }
            catch { $cleanupErrors += "WIM mount '$mountPath' remains attached: $($_.Exception.Message)" }
        }
        if (-not $mountAttempted -and -not $wimMounted) {
            # Never recurse into a mount whose release has not been confirmed.
            try { [IO.Directory]::Delete($mountPath, $false) }
            catch { $cleanupErrors += "Could not remove empty mount directory '$mountPath': $($_.Exception.Message)" }
        }
        elseif (-not $wimMounted -and $mountAttempted) {
            $cleanupErrors += "WIM mount failed before ownership was confirmed. Inspect '$mountPath'; it was left untouched."
        }
        if ($hiveDirectoryOwned -and -not $hiveLoaded) {
            try { [IO.Directory]::Delete($hiveDirectory, $true) }
            catch { $cleanupErrors += "Could not remove owned hive copy '$hiveDirectory': $($_.Exception.Message)" }
        }
        if ($cleanupErrors.Count -gt 0) {
            $message = $cleanupErrors -join '; '
            if ($null -ne $primaryFailure) { Write-Warning $message }
            else { throw $message }
        }
    }
}

Function Check-BuildVersionforParsecVDA {
param (
    [string]$Driveletter,
    [string]$SourcePath,
    [int]$ImageIndex,
    [bool]$ParsecVDA
)
    if (!$ParsecVDA) {
        return
    }

    $buildVersion = Get-BuildVersionSimple -SourcePath $SourcePath -ImageIndex $ImageIndex
    
    # Define version constants
    $win10_22H2_version = [version]"10.0.19045"
    $win2004 = [version]"10.0.19041"
    
    # Check if build version is between 19041 and 19045
    if ($buildVersion -lt $win10_22H2_version -and $buildVersion -ge $win2004) {
        Write-Host "INFO   : Checking ParsecVDA compatibility under specified Windows 10 ISO. This could take awhile..."
        $buildVersion = Get-BuildVersionExact -Driveletter $Driveletter -ImageIndex $ImageIndex -ImagePath $SourcePath
        
        # Define version constants
        $win10_21H2_int = "19044"
       
        # Check if build version is less than Windows 10 21H2 when the ParsecVDA is selected
        if ($buildVersion -lt $win10_21H2_int) {
            throw "Specified Windows image does not meet the requirements to install the ParsecVDA."
        } 
    } elseif ($buildVersion -ge $win10_22H2_version) {
        return
    } else {
        throw "Specified Windows image does not meet the requirements to install the ParsecVDA."
    }
}

Function Check-BuildVersionforVDD {
param (
    [string]$SourcePath,
    [int]$ImageIndex,
    [bool]$VirtualDisplayDriver
)
    # Initialize $withHDR
    $withHDR = $false

    $buildVersion = Get-BuildVersionSimple -SourcePath $SourcePath -ImageIndex $ImageIndex

    # Define version constants
    $win11_23H2 = [version]"10.0.22621"
       
    # Check if build version is greater than or equal to Windows 11 23H2
    if ($buildVersion -ge $win11_23H2 -and $VirtualDisplayDriver) {
        $withHDR = $true
    }

    # Return the value of $withHDR
    return $withHDR
}

Function Setup-ParsecInstall {
param(
[string]$DriveLetter,
[bool]$Parsec,
[bool]$ParsecVDA,
[bool]$Sunshine,
[bool]$VirtualDisplayDriver,
[string]$Team_ID,
[string]$Key,
[string]$LocalParsecPath = "",
[string]$LocalSunshinePath = "",
[string]$LocalVBCableZipPath = "",
[string]$LocalParsecVDAPath = "",
[string]$LocalVirtualDisplayDriverPath = "",
[string]$LocalVirtualDisplayDriverHDRPath = "",
[string]$SecurityModel = "HostDownload",
[string]$SourcePath = "",
[int]$ImageIndex = 1
)
    # Ensure target directory exists / 确保目标目录存在
    if (-not (Test-Path -Path "$DriveLetter\ProgramData\Easy-GPU-P")) {
        New-Item -Path "$DriveLetter\ProgramData\Easy-GPU-P" -ItemType Directory -Force | Out-Null
    }

    # Copy VMScripts to VM (always needed for display shortcuts etc.) / 复制 VMScripts 到 VM（显示快捷方式等始终需要）
    Copy-Item -Path $psscriptroot\VMScripts\VBCableInstall.ps1 -Destination $DriveLetter\ProgramData\Easy-GPU-P -Force -ErrorAction SilentlyContinue
    Copy-Item -Path $psscriptroot\VMScripts\ParsecVDAInstall.ps1 -Destination $DriveLetter\ProgramData\Easy-GPU-P -Force -ErrorAction SilentlyContinue
    Copy-Item -Path $psscriptroot\VMScripts\VirtualDisplayDriverInstall.ps1 -Destination $DriveLetter\ProgramData\Easy-GPU-P -Force -ErrorAction SilentlyContinue
    Copy-Item -Path $psscriptroot\VMScripts\VirtualDisplayDriverHDRInstall.ps1 -Destination $DriveLetter\ProgramData\Easy-GPU-P -Force -ErrorAction SilentlyContinue
    Copy-Item -Path "$psscriptroot\VMScripts\Switch Display to ParsecVDA.bat" -Destination $DriveLetter\ProgramData\Easy-GPU-P -Force -ErrorAction SilentlyContinue
    Copy-Item -Path "$psscriptroot\VMScripts\Switch Display to Virtual Display.bat" -Destination $DriveLetter\ProgramData\Easy-GPU-P -Force -ErrorAction SilentlyContinue
    Copy-Item -Path $psscriptroot\VMScripts\ParsecVDA.ico -Destination $DriveLetter\ProgramData\Easy-GPU-P -Force -ErrorAction SilentlyContinue
    Copy-Item -Path $psscriptroot\VMScripts\VirtualDisplayDriver.ico -Destination $DriveLetter\ProgramData\Easy-GPU-P -Force -ErrorAction SilentlyContinue
    Copy-Item -Path $psscriptroot\VMScripts\SwitchDisplayParsecVDA.vbs -Destination $DriveLetter\ProgramData\Easy-GPU-P -Force -ErrorAction SilentlyContinue
    Copy-Item -Path $psscriptroot\VMScripts\SwitchDisplayVDD.vbs -Destination $DriveLetter\ProgramData\Easy-GPU-P -Force -ErrorAction SilentlyContinue
    Copy-Item -Path $psscriptroot\VMScripts\Parsec.lnk -Destination $DriveLetter\ProgramData\Easy-GPU-P -Force -ErrorAction SilentlyContinue
    Copy-Item -Path $psscriptroot\VMScripts\DisableOneDriveAutostart.ps1 -Destination $DriveLetter\ProgramData\Easy-GPU-P -Force -ErrorAction SilentlyContinue

    # Copy local installer files if provided / 如果提供了本地安装文件，则复制到虚拟机
    $localInstallersDir = "$DriveLetter\ProgramData\Easy-GPU-P\LocalInstallers"
    $localPathsContent = @()
    $localFiles = @{
        LocalParsecPath = $LocalParsecPath
        LocalSunshinePath = $LocalSunshinePath
        LocalVBCableZipPath = $LocalVBCableZipPath
        LocalVirtualAudioDriverPath = $LocalVirtualAudioDriverPath
        LocalParsecVDAPath = $LocalParsecVDAPath
        LocalVirtualDisplayDriverPath = $LocalVirtualDisplayDriverPath
        LocalVirtualDisplayDriverHDRPath = $LocalVirtualDisplayDriverHDRPath
    }
    foreach ($key in $localFiles.Keys) {
        $src = $localFiles[$key]
        if ($src -and (Test-Path $src)) {
            if (-not (Test-Path $localInstallersDir)) {
                New-Item -ItemType Directory -Path $localInstallersDir -Force | Out-Null
            }
            $dest = Join-Path $localInstallersDir (Split-Path $src -Leaf)
            Copy-Item -Path $src -Destination $dest -Force
            $localPathsContent += "`$$key = `"$dest`""
        }
    }
    if ($localPathsContent.Count -gt 0) {
        Set-Content -Path "$localInstallersDir\LocalPaths.ps1" -Value ($localPathsContent -join "`r`n") -Encoding UTF8
    }

    # Skip Group Policy setup for HostDownload mode (PowerShell Direct will handle installation)
    # HostDownload 模式跳过 Group Policy 设置（PowerShell Direct 将处理安装）
    if ($SecurityModel -eq "HostDownload") {
        Write-Host "INFO   : HostDownload mode - skipping Group Policy logon scripts." -ForegroundColor Green
        return
    }

    # --- VMDownload mode: set up Group Policy logon scripts ---
    $new = @()
    $content = Get-Content -LiteralPath (Resolve-GpuPVUserTemplate $PSScriptRoot "psscripts.ini")
    foreach ($line in $content) {
        if ($line -like "0Parameters="){
            $line = "0Parameters=$Team_ID $Key"
            $new += $line
        } else {
            $new += $line
        }
    }
    # The source template is never rewritten with account-specific data.
    if (-not (Test-Path -Path "$DriveLetter\Windows\system32\GroupPolicy\User\Scripts\Logon")) {
        New-Item -Path "$DriveLetter\Windows\system32\GroupPolicy\User\Scripts\Logon" -ItemType Directory -Force | Out-Null
    }
    Copy-Item -Path $psscriptroot\gpt.ini -Destination "$DriveLetter\Windows\system32\GroupPolicy" -Force
    Set-Content -Value $new -LiteralPath "$DriveLetter\Windows\system32\GroupPolicy\User\Scripts\psscripts.ini" -Encoding UTF8

    $withHDR = Check-BuildVersionforVDD -SourcePath $SourcePath -ImageIndex $ImageIndex -VirtualDisplayDriver $VirtualDisplayDriver

    # Check which streaming software and Virtual Display was chosen and copy the appropriate script
    $targetScript = $null
    if ($Parsec -and $ParsecVDA) {
        $targetScript = "$PSScriptRoot\User\Installation with Parsec + ParsecVDA.ps1"
    } elseif ($Parsec -and $VirtualDisplayDriver -and $withHDR) {
        $targetScript = "$PSScriptRoot\User\Installation with Parsec + VirtualDisplayDriverHDR.ps1"
    } elseif ($Parsec -and $VirtualDisplayDriver) {
        $targetScript = "$PSScriptRoot\User\Installation with Parsec + VirtualDisplayDriver.ps1"
    } elseif ($Sunshine -and $ParsecVDA) {
        $targetScript = "$PSScriptRoot\User\Installation with Sunshine + ParsecVDA.ps1"
    } elseif ($Sunshine -and $VirtualDisplayDriver -and $withHDR) {
        $targetScript = "$PSScriptRoot\User\Installation with Sunshine + VirtualDisplayDriverHDR.ps1"
    } elseif ($Sunshine -and $VirtualDisplayDriver) {
        $targetScript = "$PSScriptRoot\User\Installation with Sunshine + VirtualDisplayDriver.ps1"
    } else {
        $targetScript = "$PSScriptRoot\User\Installation just GPU-PV.ps1"
    }
    $targetScript = Resolve-GpuPVUserTemplate $PSScriptRoot ([IO.Path]::GetFileName($targetScript))
    Copy-Item -LiteralPath $targetScript -Destination "$DriveLetter\Windows\system32\GroupPolicy\User\Scripts\Logon\Install.ps1" -Force
}

Function Convert-WindowsImage {
    <#
    .NOTES
        Copyright (c) Microsoft Corporation.  All rights reserved.

        Use of this sample source code is subject to the terms of the Microsoft
        license agreement under which you licensed this sample source code. If
        you did not accept the terms of the license agreement, you are not
        authorized to use this sample source code. For the terms of the license,
        please see the license agreement between you and Microsoft or, if applicable,
        see the LICENSE.RTF on your install media or the root of your tools installation.
        THE SAMPLE SOURCE CODE IS PROVIDED "AS IS", WITH NO WARRANTIES.

    .SYNOPSIS
        Creates a bootable VHD(X) based on Windows 7 or Windows 8 installation media.

    .DESCRIPTION
        Creates a bootable VHD(X) based on Windows 7 or Windows 8 installation media.

    .PARAMETER SourcePath
        The complete path to the WIM or ISO file that will be converted to a Virtual Hard Disk.
        The ISO file must be valid Windows installation media to be recognized successfully.

    .PARAMETER CacheSource
        If the source WIM/ISO was copied locally, we delete it by default.
        Pass $true to cache the source image from the temp directory.

    .PARAMETER VHDPath
        The name and path of the Virtual Hard Disk to create.
        Omitting this parameter will create the Virtual Hard Disk is the current directory, (or,
        if specified by the -WorkingDirectory parameter, the working directory) and will automatically
        name the file in the following format:

        <build>.<revision>.<architecture>.<branch>.<timestamp>_<skufamily>_<sku>_<language>.<extension>
        i.e.:
        9200.0.amd64fre.winmain_win8rtm.120725-1247_client_professional_en-us.vhd(x)

    .PARAMETER WorkingDirectory
        Specifies the directory where the VHD(X) file should be generated.
        If specified along with -VHDPath, the -WorkingDirectory value is ignored.
        The default value is the current directory ($pwd).

    .PARAMETER TempDirectory
        Specifies the directory where the logs and ISO files should be placed.
        The default value is the temp directory ($env:Temp).

    .PARAMETER SizeBytes
        The size of the Virtual Hard Disk to create.
        For fixed disks, the VHD(X) file will be allocated all of this space immediately.
        For dynamic disks, this will be the maximum size that the VHD(X) can grow to.
        The default value is 40GB.

    .PARAMETER VHDFormat
        Specifies whether to create a VHD or VHDX formatted Virtual Hard Disk.
        The default is AUTO, which will create a VHD if using the BIOS disk layout or
        VHDX if using UEFI or WindowsToGo layouts.

    .PARAMETER DiskLayout
        Specifies whether to build the image for BIOS (MBR), UEFI (GPT), or WindowsToGo (MBR).
        Generation 1 VMs require BIOS (MBR) images.  Generation 2 VMs require UEFI (GPT) images.
        Windows To Go images will boot in UEFI or BIOS but are not technically supported (upgrade
        doesn't work)

    .PARAMETER UnattendPath
        The complete path to an unattend.xml file that can be injected into the VHD(X).

    .PARAMETER Edition
        The name or image index of the image to apply from the WIM.

    .PARAMETER Passthru
        Specifies that the full path to the VHD(X) that is created should be
        returned on the pipeline.

    .PARAMETER BCDBoot
        By default, the version of BCDBOOT.EXE that is present in \Windows\System32
        is used by Convert-WindowsImage.  If you need to specify an alternate version,
        use this parameter to do so.

    .PARAMETER MergeFolder
        Specifies additional MergeFolder path to be added to the root of the VHD(X)

    .PARAMETER BCDinVHD
        Specifies the purpose of the VHD(x). Use NativeBoot to skip cration of BCD store
        inside the VHD(x). Use VirtualMachine (or do not specify this option) to ensure
        the BCD store is created inside the VHD(x).

    .PARAMETER Driver
        Full path to driver(s) (.inf files) to inject to the OS inside the VHD(x).

    .PARAMETER ExpandOnNativeBoot
        Specifies whether to expand the VHD(x) to its maximum suze upon native boot.
        The default is True. Set to False to disable expansion.

    .PARAMETER RemoteDesktopEnable
        Enable Remote Desktop to connect to the OS inside the VHD(x) upon provisioning.
        Does not include Windows Firewall rules (firewall exceptions). The default is False.

    .PARAMETER Feature
        Enables specified Windows Feature(s). Note that you need to specify the Internal names
        understood by DISM and DISM CMDLets (e.g. NetFx3) instead of the "Friendly" names
        from Server Manager CMDLets (e.g. NET-Framework-Core).

    .PARAMETER Package
        Injects specified Windows Package(s). Accepts path to either a directory or individual
        CAB or MSU file.

    .PARAMETER ShowUI
        Specifies that the Graphical User Interface should be displayed.

    .PARAMETER EnableDebugger
        Configures kernel debugging for the VHD(X) being created.
        EnableDebugger takes a single argument which specifies the debugging transport to use.
        Valid transports are: None, Serial, 1394, USB, Network, Local.

        Depending on the type of transport selected, additional configuration parameters will become
        available.

        Serial:
            -ComPort   - The COM port number to use while communicating with the debugger.
                         The default value is 1 (indicating COM1).
            -BaudRate  - The baud rate (in bps) to use while communicating with the debugger.
                         The default value is 115200, valid values are:
                         9600, 19200, 38400, 56700, 115200

        1394:
            -Channel   - The 1394 channel used to communicate with the debugger.
                         The default value is 10.

        USB:
            -Target    - The target name used for USB debugging.
                         The default value is "debugging".

        Network:
            -IPAddress - The IP address of the debugging host computer.
            -Port      - The port on which to connect to the debugging host.
                         The default value is 50000, with a minimum value of 49152.
            -Key       - The key used to encrypt the connection.  Only [0-9] and [a-z] are allowed.
            -nodhcp    - Prevents the use of DHCP to obtain the target IP address.
            -newkey    - Specifies that a new encryption key should be generated for the connection.

    .PARAMETER DismPath
        Full Path to an alternative version of the Dism.exe tool. The default is the current OS version.

    .PARAMETER ApplyEA
        Specifies that any EAs captured in the WIM should be applied to the VHD.
        The default is False.

    .EXAMPLE
        .\Convert-WindowsImage.ps1 -SourcePath D:\foo\install.wim -Edition Professional -WorkingDirectory D:\foo

        This command will create a 40GB dynamically expanding VHD in the D:\foo folder.
        The VHD will be based on the Professional edition from D:\foo\install.wim,
        and will be named automatically.

    .EXAMPLE
        .\Convert-WindowsImage.ps1 -SourcePath D:\foo\Win7SP1.iso -Edition Ultimate -VHDPath D:\foo\Win7_Ultimate_SP1.vhd

        This command will parse the ISO file D:\foo\Win7SP1.iso and try to locate
        \sources\install.wim.  If that file is found, it will be used to create a
        dynamically-expanding 40GB VHD containing the Ultimate SKU, and will be
        named D:\foo\Win7_Ultimate_SP1.vhd

    .EXAMPLE
        .\Convert-WindowsImage.ps1 -SourcePath D:\foo\install.wim -Edition Professional -EnableDebugger Serial -ComPort 2 -BaudRate 38400

        This command will create a VHD from D:\foo\install.wim of the Professional SKU.
        Serial debugging will be enabled in the VHD via COM2 at a baud rate of 38400bps.

    .OUTPUTS
        System.IO.FileInfo
    #>
    [CmdletBinding(DefaultParameterSetName="SRC",
        HelpURI="https://github.com/Microsoft/Virtualization-Documentation/tree/master/hyperv-tools/Convert-WindowsImage")]

    param(
        [Parameter(ParameterSetName="SRC", Mandatory=$true, ValueFromPipeline=$true)]
        [Alias("WIM")]
        [string]
        [ValidateNotNullOrEmpty()]
        [ValidateScript({ Test-Path $(Resolve-Path $_) })]
        $SourcePath,

        [Parameter(ParameterSetName="SRC")]
        [Alias("DriveLetter")]
        [string]
        [ValidateNotNullOrEmpty()]
        [string]$ISODriveLetter,

        [Parameter(ParameterSetName="SRC")]
        #[Alias("Parsec")]
        [bool]
        [ValidateNotNullOrEmpty()]
        [bool]$Parsec,

        [Parameter(ParameterSetName="SRC")]
        #[Alias("ParsecVDA")]
        [bool]
        [ValidateNotNullOrEmpty()]
        [bool]$ParsecVDA,

        [Parameter(ParameterSetName="SRC")]
        #[Alias("Sunshine")]
        [bool]
        [ValidateNotNullOrEmpty()]
        [bool]$Sunshine,

        [Parameter(ParameterSetName="SRC")]
        #[Alias("VirtualDisplayDriver")]
        [bool]
        [ValidateNotNullOrEmpty()]
        [bool]$VirtualDisplayDriver,

        [Parameter(ParameterSetName="SRC")]
        [Alias("GPU")]
        [string]
        [ValidateNotNullOrEmpty()]
        [string]$GPUName,

        [Parameter(ParameterSetName="SRC")]
        [Alias("TeamID")]
        [string]
        #[ValidateNotNullOrEmpty()]
        [string]$Team_ID,

        [Parameter(ParameterSetName="SRC")]
        [Alias("Teamkey")]
        [string]
        #[ValidateNotNullOrEmpty()]
        [string]$Key,

        [Parameter(ParameterSetName="SRC")]
        [string]$LocalParsecPath = "",

        [Parameter(ParameterSetName="SRC")]
        [string]$LocalSunshinePath = "",

        [Parameter(ParameterSetName="SRC")]
        [string]$LocalVBCableZipPath = "",

        [Parameter(ParameterSetName="SRC")]
        [string]$LocalVirtualAudioDriverPath = "",

        [Parameter(ParameterSetName="SRC")]
        [string]$LocalParsecVDAPath = "",

        [Parameter(ParameterSetName="SRC")]
        [string]$LocalVirtualDisplayDriverPath = "",

        [Parameter(ParameterSetName="SRC")]
        [string]$LocalVirtualDisplayDriverHDRPath = "",

        [Parameter(ParameterSetName="SRC")]
        [string]$SecurityModel = "HostDownload",

        [Parameter(ParameterSetName="SRC")]
        [switch]
        $CacheSource = $false,

        [Parameter(ParameterSetName="SRC")]
        [Alias("SKU")]
        [string[]]
        [ValidateNotNullOrEmpty()]
        $Edition,

        [Parameter(ParameterSetName="SRC")]
        [Alias("WorkDir")]
        [string]
        [ValidateNotNullOrEmpty()]
        [ValidateScript({ Test-Path $_ })]
        $WorkingDirectory = $pwd,

        [Parameter(ParameterSetName="SRC")]
        [Alias("TempDir")]
        [string]
        [ValidateNotNullOrEmpty()]
        $TempDirectory = $env:Temp,

        [Parameter(ParameterSetName="SRC")]
        [Alias("VHD")]
        [string]
        [ValidateNotNullOrEmpty()]
        $VHDPath,

        [Parameter(ParameterSetName="SRC")]
        [Alias("Size")]
        [UInt64]
        [ValidateNotNullOrEmpty()]
        [ValidateRange(512MB, 64TB)]
        $SizeBytes = 25GB,

        [Parameter(ParameterSetName="SRC")]
        [Alias("Format")]
        [string]
        [ValidateNotNullOrEmpty()]
        [ValidateSet("VHD", "VHDX", "AUTO")]
        $VHDFormat = "AUTO",

        [Parameter(ParameterSetName="SRC")]
        [Alias("MergeFolder")]
        [string]
        [ValidateNotNullOrEmpty()]
        $MergeFolderPath = "",

        [Parameter(ParameterSetName="SRC", Mandatory=$true)]
        [Alias("Layout")]
        [string]
        [ValidateNotNullOrEmpty()]
        [ValidateSet("BIOS", "UEFI", "WindowsToGo")]
        $DiskLayout,

        [Parameter(ParameterSetName="SRC")]
        [string]
        [ValidateNotNullOrEmpty()]
        [ValidateSet("NativeBoot", "VirtualMachine")]
        $BCDinVHD = "VirtualMachine",

        [Parameter(ParameterSetName="SRC")]
        [Parameter(ParameterSetName="UI")]
        [string]
        $BCDBoot = "bcdboot.exe",

        [Parameter(ParameterSetName="SRC")]
        [Parameter(ParameterSetName="UI")]
        [string]
        [ValidateNotNullOrEmpty()]
        [ValidateSet("None", "Serial", "1394", "USB", "Local", "Network")]
        $EnableDebugger = "None",

        [Parameter(ParameterSetName="SRC")]
        [string[]]
        [ValidateNotNullOrEmpty()]
        $Feature,

        [Parameter(ParameterSetName="SRC")]
        [string[]]
        [ValidateNotNullOrEmpty()]
        [ValidateScript({ Test-Path $(Resolve-Path $_) })]
        $Driver,

        [Parameter(ParameterSetName="SRC")]
        [string[]]
        [ValidateNotNullOrEmpty()]
        [ValidateScript({ Test-Path $(Resolve-Path $_) })]
        $Package,

        [Parameter(ParameterSetName="SRC")]
        [switch]
        $ExpandOnNativeBoot = $true,

        [Parameter(ParameterSetName="SRC")]
        [switch]
        $RemoteDesktopEnable = $false,

        [Parameter(ParameterSetName="SRC")]
        [Alias("Unattend")]
        [string]
        [ValidateNotNullOrEmpty()]
        [ValidateScript({ Test-Path $(Resolve-Path $_) })]
        $UnattendPath,

        [Parameter(ParameterSetName="SRC")]
        [Parameter(ParameterSetName="UI")]
        [switch]
        $Passthru,

        [Parameter(ParameterSetName="SRC")]
        [string]
        [ValidateNotNullOrEmpty()]
        [ValidateScript({ Test-Path $(Resolve-Path $_) })]
        $DismPath,

        [Parameter(ParameterSetName="SRC")]
        [switch]
        $ApplyEA = $false,

        [Parameter(ParameterSetName="UI")]
        [switch]
        $ShowUI
    )
    #region Code

    # Begin Dynamic Parameters
    # Create the parameters for the various types of debugging.
    DynamicParam
    {
        #Set-StrictMode -version 3

        # Set up the dynamic parameters.
        # Dynamic parameters are only available if certain conditions are met, so they'll only show up
        # as valid parameters when those conditions apply.  Here, the conditions are based on the value of
        # the EnableDebugger parameter.  Depending on which of a set of values is the specified argument
        # for EnableDebugger, different parameters will light up, as outlined below.

        $parameterDictionary = New-Object System.Management.Automation.RuntimeDefinedParameterDictionary

        if (!(Test-Path Variable:Private:EnableDebugger))
        {
            return $parameterDictionary
        }

        switch ($EnableDebugger)
        {
            "Serial"
            {
                #region ComPort

                $ComPortAttr                   = New-Object System.Management.Automation.ParameterAttribute
                $ComPortAttr.ParameterSetName  = "__AllParameterSets"
                $ComPortAttr.Mandatory         = $false

                $ComPortValidator              = New-Object System.Management.Automation.ValidateRangeAttribute(
                                                    1,
                                                    10   # Is that a good maximum?
                                                 )

                $ComPortNotNull                = New-Object System.Management.Automation.ValidateNotNullOrEmptyAttribute

                $ComPortAttrCollection         = New-Object System.Collections.ObjectModel.Collection[System.Attribute]
                $ComPortAttrCollection.Add($ComPortAttr)
                $ComPortAttrCollection.Add($ComPortValidator)
                $ComPortAttrCollection.Add($ComPortNotNull)

                $ComPort                       = New-Object System.Management.Automation.RuntimeDefinedParameter(
                                                    "ComPort",
                                                    [UInt16],
                                                    $ComPortAttrCollection
                                                 )

                # By default, use COM1
                $ComPort.Value                 = 1
                $parameterDictionary.Add("ComPort", $ComPort)
                #endregion ComPort

                #region BaudRate
                $BaudRateAttr                  = New-Object System.Management.Automation.ParameterAttribute
                $BaudRateAttr.ParameterSetName = "__AllParameterSets"
                $BaudRateAttr.Mandatory        = $false

                $BaudRateValidator             = New-Object System.Management.Automation.ValidateSetAttribute(
                                                    9600, 19200,38400, 57600, 115200
                                                 )

                $BaudRateNotNull               = New-Object System.Management.Automation.ValidateNotNullOrEmptyAttribute

                $BaudRateAttrCollection        = New-Object System.Collections.ObjectModel.Collection[System.Attribute]
                $BaudRateAttrCollection.Add($BaudRateAttr)
                $BaudRateAttrCollection.Add($BaudRateValidator)
                $BaudRateAttrCollection.Add($BaudRateNotNull)

                $BaudRate                      = New-Object System.Management.Automation.RuntimeDefinedParameter(
                                                     "BaudRate",
                                                     [UInt32],
                                                     $BaudRateAttrCollection
                                                 )

                # By default, use 115,200.
                $BaudRate.Value                = 115200
                $parameterDictionary.Add("BaudRate", $BaudRate)
                #endregion BaudRate

                break
            }

            "1394"
            {
                $ChannelAttr                   = New-Object System.Management.Automation.ParameterAttribute
                $ChannelAttr.ParameterSetName  = "__AllParameterSets"
                $ChannelAttr.Mandatory         = $false

                $ChannelValidator              = New-Object System.Management.Automation.ValidateRangeAttribute(
                                                    0,
                                                    62
                                                 )

                $ChannelNotNull                = New-Object System.Management.Automation.ValidateNotNullOrEmptyAttribute

                $ChannelAttrCollection         = New-Object System.Collections.ObjectModel.Collection[System.Attribute]
                $ChannelAttrCollection.Add($ChannelAttr)
                $ChannelAttrCollection.Add($ChannelValidator)
                $ChannelAttrCollection.Add($ChannelNotNull)

                $Channel                       = New-Object System.Management.Automation.RuntimeDefinedParameter(
                                                     "Channel",
                                                     [UInt16],
                                                     $ChannelAttrCollection
                                                 )

                # By default, use channel 10
                $Channel.Value                 = 10
                $parameterDictionary.Add("Channel", $Channel)
                break
            }

            "USB"
            {
                $TargetAttr                    = New-Object System.Management.Automation.ParameterAttribute
                $TargetAttr.ParameterSetName   = "__AllParameterSets"
                $TargetAttr.Mandatory          = $false

                $TargetNotNull                 = New-Object System.Management.Automation.ValidateNotNullOrEmptyAttribute

                $TargetAttrCollection          = New-Object System.Collections.ObjectModel.Collection[System.Attribute]
                $TargetAttrCollection.Add($TargetAttr)
                $TargetAttrCollection.Add($TargetNotNull)

                $Target                        = New-Object System.Management.Automation.RuntimeDefinedParameter(
                                                     "Target",
                                                     [string],
                                                     $TargetAttrCollection
                                                 )

                # By default, use target = "debugging"
                $Target.Value                  = "Debugging"
                $parameterDictionary.Add("Target", $Target)
                break
            }

            "Network"
            {
                #region IP
                $IpAttr                        = New-Object System.Management.Automation.ParameterAttribute
                $IpAttr.ParameterSetName       = "__AllParameterSets"
                $IpAttr.Mandatory              = $true

                $IpValidator                   = New-Object System.Management.Automation.ValidatePatternAttribute(
                                                    "\b(?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\b"
                                                 )
                $IpNotNull                     = New-Object System.Management.Automation.ValidateNotNullOrEmptyAttribute

                $IpAttrCollection              = New-Object System.Collections.ObjectModel.Collection[System.Attribute]
                $IpAttrCollection.Add($IpAttr)
                $IpAttrCollection.Add($IpValidator)
                $IpAttrCollection.Add($IpNotNull)

                $IP                            = New-Object System.Management.Automation.RuntimeDefinedParameter(
                                                     "IPAddress",
                                                     [string],
                                                     $IpAttrCollection
                                                 )

                # There's no good way to set a default value for this.
                $parameterDictionary.Add("IPAddress", $IP)
                #endregion IP

                #region Port
                $PortAttr                      = New-Object System.Management.Automation.ParameterAttribute
                $PortAttr.ParameterSetName     = "__AllParameterSets"
                $PortAttr.Mandatory            = $false

                $PortValidator                 = New-Object System.Management.Automation.ValidateRangeAttribute(
                                                    49152,
                                                    50039
                                                 )

                $PortNotNull                   = New-Object System.Management.Automation.ValidateNotNullOrEmptyAttribute

                $PortAttrCollection            = New-Object System.Collections.ObjectModel.Collection[System.Attribute]
                $PortAttrCollection.Add($PortAttr)
                $PortAttrCollection.Add($PortValidator)
                $PortAttrCollection.Add($PortNotNull)


                $Port                          = New-Object System.Management.Automation.RuntimeDefinedParameter(
                                                     "Port",
                                                     [UInt16],
                                                     $PortAttrCollection
                                                 )

                # By default, use port 50000
                $Port.Value                    = 50000
                $parameterDictionary.Add("Port", $Port)
                #endregion Port

                #region Key
                $KeyAttr                       = New-Object System.Management.Automation.ParameterAttribute
                $KeyAttr.ParameterSetName      = "__AllParameterSets"
                $KeyAttr.Mandatory             = $true

                $KeyValidator                  = New-Object System.Management.Automation.ValidatePatternAttribute(
                                                    "\b([A-Z0-9]+).([A-Z0-9]+).([A-Z0-9]+).([A-Z0-9]+)\b"
                                                 )

                $KeyNotNull                    = New-Object System.Management.Automation.ValidateNotNullOrEmptyAttribute

                $KeyAttrCollection             = New-Object System.Collections.ObjectModel.Collection[System.Attribute]
                $KeyAttrCollection.Add($KeyAttr)
                $KeyAttrCollection.Add($KeyValidator)
                $KeyAttrCollection.Add($KeyNotNull)

                $Key                           = New-Object System.Management.Automation.RuntimeDefinedParameter(
                                                     "Key",
                                                     [string],
                                                     $KeyAttrCollection
                                                 )

                # Don't set a default key.
                $parameterDictionary.Add("Key", $Key)
                #endregion Key

                #region NoDHCP
                $NoDHCPAttr                    = New-Object System.Management.Automation.ParameterAttribute
                $NoDHCPAttr.ParameterSetName   = "__AllParameterSets"
                $NoDHCPAttr.Mandatory          = $false

                $NoDHCPAttrCollection          = New-Object System.Collections.ObjectModel.Collection[System.Attribute]
                $NoDHCPAttrCollection.Add($NoDHCPAttr)

                $NoDHCP                        = New-Object System.Management.Automation.RuntimeDefinedParameter(
                                                     "NoDHCP",
                                                     [switch],
                                                     $NoDHCPAttrCollection
                                                 )

                $parameterDictionary.Add("NoDHCP", $NoDHCP)
                #endregion NoDHCP

                #region NewKey
                $NewKeyAttr                    = New-Object System.Management.Automation.ParameterAttribute
                $NewKeyAttr.ParameterSetName   = "__AllParameterSets"
                $NewKeyAttr.Mandatory          = $false

                $NewKeyAttrCollection          = New-Object System.Collections.ObjectModel.Collection[System.Attribute]
                $NewKeyAttrCollection.Add($NewKeyAttr)

                $NewKey                        = New-Object System.Management.Automation.RuntimeDefinedParameter(
                                                     "NewKey",
                                                     [switch],
                                                     $NewKeyAttrCollection
                                                 )

                # Don't set a default key.
                $parameterDictionary.Add("NewKey", $NewKey)
                #endregion NewKey

                break
            }

            # There's nothing to do for local debugging.
            # Synthetic debugging is not yet implemented.

            default
            {
               break
            }
        }

        return $parameterDictionary
    }

    Begin
    {
        if ($ShowUI) { throw 'The legacy Convert-WindowsImage UI is unsupported. Use the checked NewVM configuration wizard.' }
        ##########################################################################################
        #                             Constants and Pseudo-Constants
        ##########################################################################################
        $PARTITION_STYLE_MBR    = 0x00000000                                   # The default value
        $PARTITION_STYLE_GPT    = 0x00000001                                   # Just in case...

        # Version information that can be populated by timebuild.
        $ScriptVersion = DATA
        {
    ConvertFrom-StringData -StringData @"
        Major     = 10
        Minor     = 0
        Build     = 14278
        Qfe       = 1000
        Branch    = rs1_es_media
        Timestamp = 160201-1707
        Flavor    = amd64fre
"@
}

        $myVersion              = "$($ScriptVersion.Major).$($ScriptVersion.Minor).$($ScriptVersion.Build).$($ScriptVersion.QFE).$($ScriptVersion.Flavor).$($ScriptVersion.Branch).$($ScriptVersion.Timestamp)"
        $scriptName             = "Convert-WindowsImage"                       # Name of the script, obviously.
        $sessionKey             = [Guid]::NewGuid().ToString()                 # Session key, used for keeping records unique between multiple runs.
        $logFolder              = "$($TempDirectory)\$($scriptName)\$($sessionKey)" # Log folder path.
        $vhdMaxSize             = 2040GB                                       # Maximum size for VHD is ~2040GB.
        $vhdxMaxSize            = 64TB                                         # Maximum size for VHDX is ~64TB.
        $lowestSupportedVersion = New-Object Version "6.1"                     # The lowest supported *image* version; making sure we don't run against Vista/2k8.
        $lowestSupportedBuild   = 9200                                         # The lowest supported *host* build.  Set to Win8 CP.
        $transcripting          = $false

        # Since we use the VHDFormat in output, make it uppercase.
        # We'll make it lowercase again when we use it as a file extension.
        $VHDFormat              = $VHDFormat.ToUpper()
        ##########################################################################################
        #                                      Here Strings
        ##########################################################################################

        # Banner text displayed during each run.
        $header    = @"

Windows(R) Image to Virtual Hard Disk Converter for Windows(R) 10
Copyright (C) Microsoft Corporation.  All rights reserved.
Version $myVersion

"@

        # Text used as the banner in the UI.
        $uiHeader  = @"
You can use the fields below to configure the VHD or VHDX that you want to create!
"@

        #region Helper Functions

        ##########################################################################################
        #                                   Helper Functions
        ##########################################################################################

        <#
            Functions to mount and dismount registry hives.
            These hives will automatically be accessible via the HKLM:\ registry PSDrive.

            It should be noted that I have more confidence in using the RegLoadKey and
            RegUnloadKey Win32 APIs than I do using REG.EXE - it just seems like we should
            do things ourselves if we can, instead of using yet another binary.

            Consider this a TODO for future versions.
        #>
        Function Mount-RegistryHive
        {
            [CmdletBinding()]
            param(
                [Parameter(Mandatory = $true, ValueFromPipeline = $true, Position = 0)]
                [System.IO.FileInfo]
                [ValidateNotNullOrEmpty()]
                [ValidateScript({ $_.Exists })]
                $Hive
            )

            $mountKey = [System.Guid]::NewGuid().ToString()
            $regPath  = "REG.EXE"

            if (Test-Path HKLM:\$mountKey)
            {
                throw "The registry path already exists.  I should just regenerate it, but I'm lazy."
            }

            $regArgs = (
                "LOAD",
                "HKLM\$mountKey",
                $Hive.Fullname
            )
            try
            {

                Run-Executable -Executable $regPath -Arguments $regArgs

            }
            catch
            {
                throw
            }

            # Record ownership in the per-conversion object.
            $conversionResources.Hives += $mountKey

            return $mountKey
        }

        ##########################################################################################

        Function Dismount-RegistryHive
        {
            [CmdletBinding()]
            param(
                [Parameter(Mandatory = $true, ValueFromPipeline = $true, Position = 0)]
                [string]
                [ValidateNotNullOrEmpty()]
                $HiveMountPoint
            )

            $regPath = "REG.EXE"

            $regArgs = (
                "UNLOAD",
                "HKLM\$($HiveMountPoint)"
            )

            Run-Executable -Executable $regPath -Arguments $regArgs

            $conversionResources.Hives = @($conversionResources.Hives | Where-Object { $_ -ne $HiveMountPoint })
        }

        ##########################################################################################

        function
        Test-Admin
        {
            <#
                .SYNOPSIS
                    Short function to determine whether the logged-on user is an administrator.

                .EXAMPLE
                    Do you honestly need one?  There are no parameters!

                .OUTPUTS
                    $true if user is admin.
                    $false if user is not an admin.
            #>
            [CmdletBinding()]
            param()

            $currentUser = New-Object Security.Principal.WindowsPrincipal $([Security.Principal.WindowsIdentity]::GetCurrent())
            $isAdmin = $currentUser.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
            Write-W2VTrace "isUserAdmin? $isAdmin"

            return $isAdmin
        }

        ##########################################################################################

        function
        Get-WindowsBuildNumber
        {
            $os = Get-WmiObject -Class Win32_OperatingSystem
            return [int]($os.BuildNumber)
        }

        ##########################################################################################

        function
        Test-WindowsVersion
        {
            $isWin8 = ((Get-WindowsBuildNumber) -ge [int]$lowestSupportedBuild)

            Write-W2VTrace "is Windows 8 or Higher? $isWin8"
            return $isWin8
        }

        ##########################################################################################

        function
        Write-W2VInfo
        {
        # Function to make the Write-Host output a bit prettier.
            [CmdletBinding()]
            param(
                [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
                [string]
                [ValidateNotNullOrEmpty()]
                $text
            )
            Write-Host "INFO   : $($text)"
        }

        ##########################################################################################

        function
        Write-W2VTrace
        {
        # Function to make the Write-Verbose output... well... exactly the same as it was before.
            [CmdletBinding()]
            param(
                [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
                [string]
                [ValidateNotNullOrEmpty()]
                $text
            )
            Write-Verbose $text
        }

        ##########################################################################################

        function
        Write-W2VError
        {
        # Function to make the Write-Host (NOT Write-Error) output prettier in the case of an error.
            [CmdletBinding()]
            param(
                [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
                [string]
                [ValidateNotNullOrEmpty()]
                $text
            )
            Write-Host "ERROR  : $($text)"
        }

        ##########################################################################################

        function
        Write-W2VWarn
        {
        # Function to make the Write-Host (NOT Write-Warning) output prettier.
            [CmdletBinding()]
            param(
                [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
                [string]
                [ValidateNotNullOrEmpty()]
                $text
            )
            Write-Host "WARN   : $($text)" -ForegroundColor (Get-Host).PrivateData.WarningForegroundColor
        }

        ##########################################################################################

        function
        Run-Executable
        {
            <#
                .SYNOPSIS
                    Runs an external executable file, and validates the error level.

                .PARAMETER Executable
                    The path to the executable to run and monitor.

                .PARAMETER Arguments
                    An array of arguments to pass to the executable when it's executed.

                .PARAMETER SuccessfulErrorCode
                    The error code that means the executable ran successfully.
                    The default value is 0.
            #>

            [CmdletBinding()]
            param(
                [Parameter(Mandatory=$true)]
                [string]
                [ValidateNotNullOrEmpty()]
                $Executable,

                [Parameter(Mandatory=$true)]
                [string[]]
                [ValidateNotNullOrEmpty()]
                $Arguments,

                [Parameter()]
                [int]
                [ValidateNotNullOrEmpty()]
                $SuccessfulErrorCode = 0

            )

            Write-W2VTrace "Running $Executable $Arguments"
            $ret = Start-Process           `
                -FilePath $Executable      `
                -ArgumentList $Arguments   `
                -NoNewWindow               `
                -Wait                      `
                -RedirectStandardOutput "$($TempDirectory)\$($scriptName)\$($sessionKey)\$($Executable)-StandardOutput.txt" `
                -RedirectStandardError  "$($TempDirectory)\$($scriptName)\$($sessionKey)\$($Executable)-StandardError.txt"  `
                -Passthru

            Write-W2VTrace "Return code was $($ret.ExitCode)."

            if ($ret.ExitCode -ne $SuccessfulErrorCode)
            {
                throw "$Executable failed with code $($ret.ExitCode)!"
            }
        }

        ##########################################################################################
        Function Test-IsNetworkLocation
        {
            <#
                .SYNOPSIS
                    Determines whether or not a given path is a network location or a local drive.

                .DESCRIPTION
                    Function to determine whether or not a specified path is a local path, a UNC path,
                    or a mapped network drive.

                .PARAMETER Path
                    The path that we need to figure stuff out about,
            #>

            [CmdletBinding()]
            param(
                [Parameter(ValueFromPipeLine = $true)]
                [string]
                [ValidateNotNullOrEmpty()]
                $Path
            )

            $result = $false

            if ([bool]([URI]$Path).IsUNC)
            {
                $result = $true
            }
            else
            {
                $driveInfo = [IO.DriveInfo]((Resolve-Path $Path).Path)

                if ($driveInfo.DriveType -eq "Network")
                {
                    $result = $true
                }
            }

            return $result
        }
        ##########################################################################################

        #endregion Helper Functions
    }

    Process
    {
        Write-Host $header
        
        $disk           = $null
        $openWim        = $null
        $openIso        = $null
        $openImage      = $null
        $vhdFinalName   = $null
        $vhdFinalPath   = $null
        $conversionResources = @{ Hives=@(); VhdMounted=$false }
        $conversionMedia = $null
        $conversionFailure = $null
        $driveLetter = $ISODriveLetter
        $tempSource = $null
        $transcripting = $false

        if (Get-Command Get-WindowsOptionalFeature -ErrorAction SilentlyContinue)
        {
            try
            {
                $hyperVEnabled  = $((Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V).State -eq "Enabled")
            }
            catch
            {
                # WinPE DISM does not support online queries.  This will throw on non-WinPE machines
                $winpeVersion = (Get-ItemProperty -Path 'HKLM:\Software\Microsoft\Windows NT\CurrentVersion\WinPE').Version

                Write-W2VInfo "Running WinPE version $winpeVersion"

                $hyperVEnabled = $false
            }
        }
        else
        {
            $hyperVEnabled = $false
        }

        $vhd            = @()

        try
        {
            # Create log folder
            if (Test-Path $logFolder)
            {
                $null = rd $logFolder -Force -Recurse
            }

            $null = md $logFolder -Force

            # No automatic transcript: unattended setup may contain credentials.
            $transcripting = $false

            #
            # Add types
            #
            Add-WindowsImageTypes

            # Check to make sure we're running as Admin.
            if (!(Test-Admin))
            {
                throw "Images can only be applied by an administrator.  Please launch PowerShell elevated and run this script again."
            }

            # Check to make sure we're running on Win8.
            if (!(Test-WindowsVersion))
            {
                throw "$scriptName requires Windows 8 Consumer Preview or higher.  Please use WIM2VHD.WSF (http://code.msdn.microsoft.com/wim2vhd) if you need to create VHDs from Windows 7."
            }

            # Resolve the path for the unattend file.
            if (![string]::IsNullOrEmpty($UnattendPath))
            {
                $UnattendPath = (Resolve-Path $UnattendPath).Path
            }

            if ($ShowUI)
            {

                Write-W2VInfo "Launching UI..."
                Add-Type -AssemblyName System.Drawing,System.Windows.Forms

                #region Form Objects
                $frmMain                = New-Object System.Windows.Forms.Form
                $groupBox4              = New-Object System.Windows.Forms.GroupBox
                $btnGo                  = New-Object System.Windows.Forms.Button
                $groupBox3              = New-Object System.Windows.Forms.GroupBox
                $txtVhdName             = New-Object System.Windows.Forms.TextBox
                $label6                 = New-Object System.Windows.Forms.Label
                $btnWrkBrowse           = New-Object System.Windows.Forms.Button
                $cmbVhdSizeUnit         = New-Object System.Windows.Forms.ComboBox
                $numVhdSize             = New-Object System.Windows.Forms.NumericUpDown
                $cmbVhdFormat           = New-Object System.Windows.Forms.ComboBox
                $label5                 = New-Object System.Windows.Forms.Label
                $txtWorkingDirectory    = New-Object System.Windows.Forms.TextBox
                $label4                 = New-Object System.Windows.Forms.Label
                $label3                 = New-Object System.Windows.Forms.Label
                $label2                 = New-Object System.Windows.Forms.Label
                $label7                 = New-Object System.Windows.Forms.Label
                $txtUnattendFile        = New-Object System.Windows.Forms.TextBox
                $btnUnattendBrowse      = New-Object System.Windows.Forms.Button
                $groupBox2              = New-Object System.Windows.Forms.GroupBox
                $cmbSkuList             = New-Object System.Windows.Forms.ComboBox
                $label1                 = New-Object System.Windows.Forms.Label
                $groupBox1              = New-Object System.Windows.Forms.GroupBox
                $txtSourcePath          = New-Object System.Windows.Forms.TextBox
                $btnBrowseWim           = New-Object System.Windows.Forms.Button
                $openFileDialog1        = New-Object System.Windows.Forms.OpenFileDialog
                $openFolderDialog1      = New-Object System.Windows.Forms.FolderBrowserDialog
                $InitialFormWindowState = New-Object System.Windows.Forms.FormWindowState

                #endregion Form Objects

                #region Event scriptblocks.

                $btnGo_OnClick                          = {
                    $frmMain.Close()
                }

                $btnWrkBrowse_OnClick                   = {
                    $openFolderDialog1.RootFolder       = "Desktop"
                    $openFolderDialog1.Description      = "Select the folder you'd like your VHD(X) to be created in."
                    $openFolderDialog1.SelectedPath     = $WorkingDirectory

                    $ret = $openFolderDialog1.ShowDialog()

                    if ($ret -ilike "ok")
                    {
                        $WorkingDirectory = $txtWorkingDirectory = $openFolderDialog1.SelectedPath
                        Write-W2VInfo "Selected Working Directory is $WorkingDirectory..."
                    }
                }

                $btnUnattendBrowse_OnClick              = {
                    $openFileDialog1.InitialDirectory   = $pwd
                    $openFileDialog1.Filter             = "XML files (*.xml)|*.XML|All files (*.*)|*.*"
                    $openFileDialog1.FilterIndex        = 1
                    $openFileDialog1.CheckFileExists    = $true
                    $openFileDialog1.CheckPathExists    = $true
                    $openFileDialog1.FileName           = $null
                    $openFileDialog1.ShowHelp           = $false
                    $openFileDialog1.Title              = "Select an unattend file..."

                    $ret = $openFileDialog1.ShowDialog()

                    if ($ret -ilike "ok")
                    {
                        $UnattendPath = $txtUnattendFile.Text = $openFileDialog1.FileName
                    }
                }

                $btnBrowseWim_OnClick                   = {
                    $openFileDialog1.InitialDirectory   = $pwd
                    $openFileDialog1.Filter             = "All compatible files (*.ISO, *.WIM)|*.ISO;*.WIM|All files (*.*)|*.*"
                    $openFileDialog1.FilterIndex        = 1
                    $openFileDialog1.CheckFileExists    = $true
                    $openFileDialog1.CheckPathExists    = $true
                    $openFileDialog1.FileName           = $null
                    $openFileDialog1.ShowHelp           = $false
                    $openFileDialog1.Title              = "Select a source file..."

                    $ret = $openFileDialog1.ShowDialog()

                    if ($ret -ilike "ok")
                    {

                        if (([IO.FileInfo]$openFileDialog1.FileName).Extension -ilike ".iso")
                        {

                            if (Test-IsNetworkLocation $openFileDialog1.FileName)
                            {
                                Write-W2VInfo "Copying ISO $(Split-Path $openFileDialog1.FileName -Leaf) to temp folder..."
                                Write-W2VWarn "The UI may become non-responsive while this copy takes place..."
                                Copy-Item -Path $openFileDialog1.FileName -Destination $TempDirectory -Force
                                $openFileDialog1.FileName = "$($TempDirectory)\$(Split-Path $openFileDialog1.FileName -Leaf)"
                            }

                            $txtSourcePath.Text = $isoPath = (Resolve-Path $openFileDialog1.FileName).Path
                            Write-W2VInfo "Opening ISO $(Split-Path $isoPath -Leaf)..."

                            $script:SourcePath  = "$($driveLetter):\sources\install.wim"

                            # Check to see if there's a WIM file we can muck about with.
                            Write-W2VInfo "Looking for $($SourcePath)..."
                            if (!(Test-Path $SourcePath))
                            {
                                throw "The specified ISO does not appear to be valid Windows installation media."
                            }
                        }
                        else
                        {
                            $txtSourcePath.Text = $script:SourcePath = $openFileDialog1.FileName
                        }

                        # Check to see if the WIM is local, or on a network location.  If the latter, copy it locally.
                        if (Test-IsNetworkLocation $SourcePath)
                        {
                            Write-W2VInfo "Copying WIM $(Split-Path $SourcePath -Leaf) to temp folder..."
                            Write-W2VWarn "The UI may become non-responsive while this copy takes place..."
                            Copy-Item -Path $SourcePath -Destination $TempDirectory -Force
                            $txtSourcePath.Text = $script:SourcePath = "$($TempDirectory)\$(Split-Path $SourcePath -Leaf)"
                        }

                        $script:SourcePath = (Resolve-Path $SourcePath).Path

                        Write-W2VInfo "Scanning WIM metadata..."

                        $tempOpenWim = $null

                        try
                        {
                            $tempOpenWim   = New-Object WIM2VHD.WimFile $SourcePath

                            # Let's see if we're running against an unstaged build.  If we are, we need to blow up.
                            if ($tempOpenWim.ImageNames.Contains("Windows Longhorn Client") -or
                                $tempOpenWim.ImageNames.Contains("Windows Longhorn Server") -or
                                $tempOpenWim.ImageNames.Contains("Windows Longhorn Server Core"))
                            {
                                [Windows.Forms.MessageBox]::Show(
                                    "Convert-WindowsImage cannot run against unstaged builds. Please try again with a staged build.",
                                    "WIM is incompatible!",
                                    "OK",
                                    "Error"
                                )

                                return
                            }
                            else
                            {
                                $tempOpenWim.Images | %{ $cmbSkuList.Items.Add($_.ImageFlags) }
                                $cmbSkuList.SelectedIndex = 0
                            }

                        }
                        catch
                        {
                            throw "Unable to load WIM metadata!"
                        }
                        finally
                        {
                            if ($null -ne $tempOpenWim) { $tempOpenWim.Close() }
                            Write-W2VTrace "Closing WIM metadata..."
                        }
                    }
                }

                $OnLoadForm_StateCorrection = {

                    # Correct the initial state of the form to prevent the .Net maximized form issue
                    $frmMain.WindowState      = $InitialFormWindowState
                }

                #endregion Event scriptblocks

                # Figure out VHD size and size unit.
                $unit = $null
                switch ([Math]::Round($SizeBytes.ToString().Length / 3))
                {
                    3 { $unit = "MB"; break }
                    4 { $unit = "GB"; break }
                    5 { $unit = "TB"; break }
                    default { $unit = ""; break }
                }

                $quantity = Invoke-Expression -Command "$($SizeBytes) / 1$($unit)"

                #region Form Code
                #region frmMain
                $frmMain.DataBindings.DefaultDataSourceUpdateMode = 0
                $System_Drawing_Size          = New-Object System.Drawing.Size
                $System_Drawing_Size.Height   = 579
                $System_Drawing_Size.Width    = 512
                $frmMain.ClientSize           = $System_Drawing_Size
                $frmMain.Font                 = New-Object System.Drawing.Font("Segoe UI",10,0,3,1)
                $frmMain.FormBorderStyle      = 1
                $frmMain.MaximizeBox          = $False
                $frmMain.MinimizeBox          = $False
                $frmMain.Name                 = "frmMain"
                $frmMain.StartPosition        = 1
                $frmMain.Text                 = "Convert-WindowsImage UI"
                #endregion frmMain

                #region groupBox4
                $groupBox4.DataBindings.DefaultDataSourceUpdateMode = 0
                $System_Drawing_Point         = New-Object System.Drawing.Point
                $System_Drawing_Point.X       = 10
                $System_Drawing_Point.Y       = 498
                $groupBox4.Location           = $System_Drawing_Point
                $groupBox4.Name               = "groupBox4"
                $System_Drawing_Size          = New-Object System.Drawing.Size
                $System_Drawing_Size.Height   = 69
                $System_Drawing_Size.Width    = 489
                $groupBox4.Size               = $System_Drawing_Size
                $groupBox4.TabIndex           = 8
                $groupBox4.TabStop            = $False
                $groupBox4.Text               = "4. Make the VHD!"

                $frmMain.Controls.Add($groupBox4)
                #endregion groupBox4

                #region btnGo
                $btnGo.DataBindings.DefaultDataSourceUpdateMode = 0
                $System_Drawing_Point         = New-Object System.Drawing.Point
                $System_Drawing_Point.X       = 39
                $System_Drawing_Point.Y       = 24
                $btnGo.Location               = $System_Drawing_Point
                $btnGo.Name                   = "btnGo"
                $System_Drawing_Size          = New-Object System.Drawing.Size
                $System_Drawing_Size.Height   = 33
                $System_Drawing_Size.Width    = 415
                $btnGo.Size                   = $System_Drawing_Size
                $btnGo.TabIndex               = 0
                $btnGo.Text                   = "&Make my VHD"
                $btnGo.UseVisualStyleBackColor = $True
                $btnGo.DialogResult           = "OK"
                $btnGo.add_Click($btnGo_OnClick)

                $groupBox4.Controls.Add($btnGo)
                $frmMain.AcceptButton = $btnGo
                #endregion btnGo

                #region groupBox3
                $groupBox3.DataBindings.DefaultDataSourceUpdateMode = 0
                $System_Drawing_Point         = New-Object System.Drawing.Point
                $System_Drawing_Point.X       = 10
                $System_Drawing_Point.Y       = 243
                $groupBox3.Location           = $System_Drawing_Point
                $groupBox3.Name               = "groupBox3"
                $System_Drawing_Size          = New-Object System.Drawing.Size
                $System_Drawing_Size.Height   = 245
                $System_Drawing_Size.Width    = 489
                $groupBox3.Size               = $System_Drawing_Size
                $groupBox3.TabIndex           = 7
                $groupBox3.TabStop            = $False
                $groupBox3.Text               = "3. Choose configuration options"

                $frmMain.Controls.Add($groupBox3)
                #endregion groupBox3

                #region txtVhdName
                $txtVhdName.DataBindings.DefaultDataSourceUpdateMode = 0
                $System_Drawing_Point         = New-Object System.Drawing.Point
                $System_Drawing_Point.X       = 25
                $System_Drawing_Point.Y       = 150
                $txtVhdName.Location          = $System_Drawing_Point
                $txtVhdName.Name              = "txtVhdName"
                $System_Drawing_Size          = New-Object System.Drawing.Size
                $System_Drawing_Size.Height   = 25
                $System_Drawing_Size.Width    = 418
                $txtVhdName.Size              = $System_Drawing_Size
                $txtVhdName.TabIndex          = 10

                $groupBox3.Controls.Add($txtVhdName)
                #endregion txtVhdName

                #region txtUnattendFile
                $txtUnattendFile.DataBindings.DefaultDataSourceUpdateMode = 0
                $System_Drawing_Point         = New-Object System.Drawing.Point
                $System_Drawing_Point.X       = 25
                $System_Drawing_Point.Y       = 198
                $txtUnattendFile.Location     = $System_Drawing_Point
                $txtUnattendFile.Name         = "txtUnattendFile"
                $System_Drawing_Size          = New-Object System.Drawing.Size
                $System_Drawing_Size.Height   = 25
                $System_Drawing_Size.Width    = 418
                $txtUnattendFile.Size         = $System_Drawing_Size
                $txtUnattendFile.TabIndex     = 11

                $groupBox3.Controls.Add($txtUnattendFile)
                #endregion txtUnattendFile

                #region label7
                $label7.DataBindings.DefaultDataSourceUpdateMode = 0
                $System_Drawing_Point         = New-Object System.Drawing.Point
                $System_Drawing_Point.X       = 23
                $System_Drawing_Point.Y       = 180
                $label7.Location              = $System_Drawing_Point
                $label7.Name                  = "label7"
                $System_Drawing_Size          = New-Object System.Drawing.Size
                $System_Drawing_Size.Height   = 23
                $System_Drawing_Size.Width    = 175
                $label7.Size                  = $System_Drawing_Size
                $label7.Text                  = "Unattend File (Optional)"

                $groupBox3.Controls.Add($label7)
                #endregion label7

                #region label6
                $label6.DataBindings.DefaultDataSourceUpdateMode = 0
                $System_Drawing_Point         = New-Object System.Drawing.Point
                $System_Drawing_Point.X       = 23
                $System_Drawing_Point.Y       = 132
                $label6.Location              = $System_Drawing_Point
                $label6.Name                  = "label6"
                $System_Drawing_Size          = New-Object System.Drawing.Size
                $System_Drawing_Size.Height   = 23
                $System_Drawing_Size.Width    = 175
                $label6.Size                  = $System_Drawing_Size
                $label6.Text                  = "VHD Name (Optional)"

                $groupBox3.Controls.Add($label6)
                #endregion label6

                #region btnUnattendBrowse
                $btnUnattendBrowse.DataBindings.DefaultDataSourceUpdateMode = 0
                $System_Drawing_Point         = New-Object System.Drawing.Point
                $System_Drawing_Point.X       = 449
                $System_Drawing_Point.Y       = 199
                $btnUnattendBrowse.Location   = $System_Drawing_Point
                $btnUnattendBrowse.Name       = "btnUnattendBrowse"
                $System_Drawing_Size          = New-Object System.Drawing.Size
                $System_Drawing_Size.Height   = 25
                $System_Drawing_Size.Width    = 27
                $btnUnattendBrowse.Size       = $System_Drawing_Size
                $btnUnattendBrowse.TabIndex   = 9
                $btnUnattendBrowse.Text       = "..."
                $btnUnattendBrowse.UseVisualStyleBackColor = $True
                $btnUnattendBrowse.add_Click($btnUnattendBrowse_OnClick)

                $groupBox3.Controls.Add($btnUnattendBrowse)
                #endregion btnUnattendBrowse

                #region btnWrkBrowse
                $btnWrkBrowse.DataBindings.DefaultDataSourceUpdateMode = 0
                $System_Drawing_Point         = New-Object System.Drawing.Point
                $System_Drawing_Point.X       = 449
                $System_Drawing_Point.Y       = 98
                $btnWrkBrowse.Location        = $System_Drawing_Point
                $btnWrkBrowse.Name            = "btnWrkBrowse"
                $System_Drawing_Size          = New-Object System.Drawing.Size
                $System_Drawing_Size.Height   = 25
                $System_Drawing_Size.Width    = 27
                $btnWrkBrowse.Size            = $System_Drawing_Size
                $btnWrkBrowse.TabIndex        = 9
                $btnWrkBrowse.Text            = "..."
                $btnWrkBrowse.UseVisualStyleBackColor = $True
                $btnWrkBrowse.add_Click($btnWrkBrowse_OnClick)

                $groupBox3.Controls.Add($btnWrkBrowse)
                #endregion btnWrkBrowse

                #region cmbVhdSizeUnit
                $cmbVhdSizeUnit.DataBindings.DefaultDataSourceUpdateMode = 0
                $cmbVhdSizeUnit.FormattingEnabled = $True
                $cmbVhdSizeUnit.Items.Add("MB") | Out-Null
                $cmbVhdSizeUnit.Items.Add("GB") | Out-Null
                $cmbVhdSizeUnit.Items.Add("TB") | Out-Null
                $System_Drawing_Point         = New-Object System.Drawing.Point
                $System_Drawing_Point.X       = 409
                $System_Drawing_Point.Y       = 42
                $cmbVhdSizeUnit.Location      = $System_Drawing_Point
                $cmbVhdSizeUnit.Name          = "cmbVhdSizeUnit"
                $System_Drawing_Size          = New-Object System.Drawing.Size
                $System_Drawing_Size.Height   = 25
                $System_Drawing_Size.Width    = 67
                $cmbVhdSizeUnit.Size          = $System_Drawing_Size
                $cmbVhdSizeUnit.TabIndex      = 5
                $cmbVhdSizeUnit.Text          = $unit

                $groupBox3.Controls.Add($cmbVhdSizeUnit)
                #endregion cmbVhdSizeUnit

                #region numVhdSize
                $numVhdSize.DataBindings.DefaultDataSourceUpdateMode = 0
                $System_Drawing_Point         = New-Object System.Drawing.Point
                $System_Drawing_Point.X       = 340
                $System_Drawing_Point.Y       = 42
                $numVhdSize.Location          = $System_Drawing_Point
                $numVhdSize.Name              = "numVhdSize"
                $System_Drawing_Size          = New-Object System.Drawing.Size
                $System_Drawing_Size.Height   = 25
                $System_Drawing_Size.Width    = 63
                $numVhdSize.Size              = $System_Drawing_Size
                $numVhdSize.TabIndex          = 4
                $numVhdSize.Value             = $quantity

                $groupBox3.Controls.Add($numVhdSize)
                #endregion numVhdSize

                #region cmbVhdFormat
                $cmbVhdFormat.DataBindings.DefaultDataSourceUpdateMode = 0
                $cmbVhdFormat.FormattingEnabled = $True
                $cmbVhdFormat.Items.Add("VHD")  | Out-Null
                $cmbVhdFormat.Items.Add("VHDX") | Out-Null
                $System_Drawing_Point         = New-Object System.Drawing.Point
                $System_Drawing_Point.X       = 25
                $System_Drawing_Point.Y       = 42
                $cmbVhdFormat.Location        = $System_Drawing_Point
                $cmbVhdFormat.Name            = "cmbVhdFormat"
                $System_Drawing_Size          = New-Object System.Drawing.Size
                $System_Drawing_Size.Height   = 25
                $System_Drawing_Size.Width    = 136
                $cmbVhdFormat.Size            = $System_Drawing_Size
                $cmbVhdFormat.TabIndex        = 0
                $cmbVhdFormat.Text            = $VHDFormat

                $groupBox3.Controls.Add($cmbVhdFormat)
                #endregion cmbVhdFormat

                #region label5
                $label5.DataBindings.DefaultDataSourceUpdateMode = 0
                $System_Drawing_Point         = New-Object System.Drawing.Point
                $System_Drawing_Point.X       = 23
                $System_Drawing_Point.Y       = 76
                $label5.Location              = $System_Drawing_Point
                $label5.Name                  = "label5"
                $System_Drawing_Size          = New-Object System.Drawing.Size
                $System_Drawing_Size.Height   = 23
                $System_Drawing_Size.Width    = 264
                $label5.Size                  = $System_Drawing_Size
                $label5.TabIndex              = 8
                $label5.Text                  = "Working Directory"

                $groupBox3.Controls.Add($label5)
                #endregion label5

                #region txtWorkingDirectory
                $txtWorkingDirectory.DataBindings.DefaultDataSourceUpdateMode = 0
                $System_Drawing_Point         = New-Object System.Drawing.Point
                $System_Drawing_Point.X       = 25
                $System_Drawing_Point.Y       = 99
                $txtWorkingDirectory.Location = $System_Drawing_Point
                $txtWorkingDirectory.Name     = "txtWorkingDirectory"
                $System_Drawing_Size          = New-Object System.Drawing.Size
                $System_Drawing_Size.Height   = 25
                $System_Drawing_Size.Width    = 418
                $txtWorkingDirectory.Size     = $System_Drawing_Size
                $txtWorkingDirectory.TabIndex = 7
                $txtWorkingDirectory.Text     = $WorkingDirectory

                $groupBox3.Controls.Add($txtWorkingDirectory)
                #endregion txtWorkingDirectory

                #region label4
                $label4.DataBindings.DefaultDataSourceUpdateMode = 0
                $System_Drawing_Point         = New-Object System.Drawing.Point
                $System_Drawing_Point.X       = 340
                $System_Drawing_Point.Y       = 21
                $label4.Location              = $System_Drawing_Point
                $label4.Name                  = "label4"
                $System_Drawing_Size          = New-Object System.Drawing.Size
                $System_Drawing_Size.Height   = 27
                $System_Drawing_Size.Width    = 86
                $label4.Size                  = $System_Drawing_Size
                $label4.TabIndex              = 6
                $label4.Text                  = "VHD Size"

                $groupBox3.Controls.Add($label4)
                #endregion label4

                #region label3
                $label3.DataBindings.DefaultDataSourceUpdateMode = 0
                $System_Drawing_Point         = New-Object System.Drawing.Point
                $System_Drawing_Point.X       = 176
                $System_Drawing_Point.Y       = 21
                $label3.Location              = $System_Drawing_Point
                $label3.Name                  = "label3"
                $System_Drawing_Size          = New-Object System.Drawing.Size
                $System_Drawing_Size.Height   = 27
                $System_Drawing_Size.Width    = 92
                $label3.Size                  = $System_Drawing_Size
                $label3.TabIndex              = 3
                $label3.Text                  = "VHD Type"

                $groupBox3.Controls.Add($label3)
                #endregion label3

                #region label2
                $label2.DataBindings.DefaultDataSourceUpdateMode = 0
                $System_Drawing_Point         = New-Object System.Drawing.Point
                $System_Drawing_Point.X       = 25
                $System_Drawing_Point.Y       = 21
                $label2.Location              = $System_Drawing_Point
                $label2.Name                  = "label2"
                $System_Drawing_Size          = New-Object System.Drawing.Size
                $System_Drawing_Size.Height   = 30
                $System_Drawing_Size.Width    = 118
                $label2.Size                  = $System_Drawing_Size
                $label2.TabIndex              = 1
                $label2.Text                  = "VHD Format"

                $groupBox3.Controls.Add($label2)
                #endregion label2

                #region groupBox2
                $groupBox2.DataBindings.DefaultDataSourceUpdateMode = 0
                $System_Drawing_Point         = New-Object System.Drawing.Point
                $System_Drawing_Point.X       = 10
                $System_Drawing_Point.Y       = 169
                $groupBox2.Location           = $System_Drawing_Point
                $groupBox2.Name               = "groupBox2"
                $System_Drawing_Size          = New-Object System.Drawing.Size
                $System_Drawing_Size.Height   = 68
                $System_Drawing_Size.Width    = 490
                $groupBox2.Size               = $System_Drawing_Size
                $groupBox2.TabIndex           = 6
                $groupBox2.TabStop            = $False
                $groupBox2.Text               = "2. Choose a SKU from the list"

                $frmMain.Controls.Add($groupBox2)
                #endregion groupBox2

                #region cmbSkuList
                $cmbSkuList.DataBindings.DefaultDataSourceUpdateMode = 0
                $cmbSkuList.FormattingEnabled = $True
                $System_Drawing_Point         = New-Object System.Drawing.Point
                $System_Drawing_Point.X       = 25
                $System_Drawing_Point.Y       = 24
                $cmbSkuList.Location          = $System_Drawing_Point
                $cmbSkuList.Name              = "cmbSkuList"
                $System_Drawing_Size          = New-Object System.Drawing.Size
                $System_Drawing_Size.Height   = 25
                $System_Drawing_Size.Width    = 452
                $cmbSkuList.Size              = $System_Drawing_Size
                $cmbSkuList.TabIndex          = 2

                $groupBox2.Controls.Add($cmbSkuList)
                #endregion cmbSkuList

                #region label1
                $label1.DataBindings.DefaultDataSourceUpdateMode = 0
                $System_Drawing_Point         = New-Object System.Drawing.Point
                $System_Drawing_Point.X       = 23
                $System_Drawing_Point.Y       = 21
                $label1.Location              = $System_Drawing_Point
                $label1.Name                  = "label1"
                $System_Drawing_Size          = New-Object System.Drawing.Size
                $System_Drawing_Size.Height   = 71
                $System_Drawing_Size.Width    = 464
                $label1.Size                  = $System_Drawing_Size
                $label1.TabIndex              = 5
                $label1.Text                  = $uiHeader

                $frmMain.Controls.Add($label1)
                #endregion label1

                #region groupBox1
                $groupBox1.DataBindings.DefaultDataSourceUpdateMode = 0
                $System_Drawing_Point         = New-Object System.Drawing.Point
                $System_Drawing_Point.X       = 10
                $System_Drawing_Point.Y       = 95
                $groupBox1.Location           = $System_Drawing_Point
                $groupBox1.Name               = "groupBox1"
                $System_Drawing_Size          = New-Object System.Drawing.Size
                $System_Drawing_Size.Height   = 68
                $System_Drawing_Size.Width    = 490
                $groupBox1.Size               = $System_Drawing_Size
                $groupBox1.TabIndex           = 4
                $groupBox1.TabStop            = $False
                $groupBox1.Text               = "1. Choose a source"

                $frmMain.Controls.Add($groupBox1)
                #endregion groupBox1

                #region txtSourcePath
                $txtSourcePath.DataBindings.DefaultDataSourceUpdateMode = 0
                $System_Drawing_Point         = New-Object System.Drawing.Point
                $System_Drawing_Point.X       = 25
                $System_Drawing_Point.Y       = 24
                $txtSourcePath.Location       = $System_Drawing_Point
                $txtSourcePath.Name           = "txtSourcePath"
                $System_Drawing_Size          = New-Object System.Drawing.Size
                $System_Drawing_Size.Height   = 25
                $System_Drawing_Size.Width    = 418
                $txtSourcePath.Size           = $System_Drawing_Size
                $txtSourcePath.TabIndex       = 0

                $groupBox1.Controls.Add($txtSourcePath)
                #endregion txtSourcePath

                #region btnBrowseWim
                $btnBrowseWim.DataBindings.DefaultDataSourceUpdateMode = 0
                $System_Drawing_Point         = New-Object System.Drawing.Point
                $System_Drawing_Point.X       = 449
                $System_Drawing_Point.Y       = 24
                $btnBrowseWim.Location        = $System_Drawing_Point
                $btnBrowseWim.Name            = "btnBrowseWim"
                $System_Drawing_Size          = New-Object System.Drawing.Size
                $System_Drawing_Size.Height   = 25
                $System_Drawing_Size.Width    = 28
                $btnBrowseWim.Size            = $System_Drawing_Size
                $btnBrowseWim.TabIndex        = 1
                $btnBrowseWim.Text            = "..."
                $btnBrowseWim.UseVisualStyleBackColor = $True
                $btnBrowseWim.add_Click($btnBrowseWim_OnClick)

                $groupBox1.Controls.Add($btnBrowseWim)
                #endregion btnBrowseWim

                $openFileDialog1.FileName     = "openFileDialog1"
                $openFileDialog1.ShowHelp     = $True

                #endregion Form Code

                # Save the initial state of the form
                $InitialFormWindowState       = $frmMain.WindowState

                # Init the OnLoad event to correct the initial state of the form
                $frmMain.add_Load($OnLoadForm_StateCorrection)

                # Return the constructed form.
                $ret = $frmMain.ShowDialog()

                if (!($ret -ilike "OK"))
                {
                    throw "Form session has been cancelled."
                }

                if ([string]::IsNullOrEmpty($SourcePath))
                {
                    throw "No source path specified."
                }

                # VHD Format
                $VHDFormat        = $cmbVhdFormat.SelectedItem

                # VHD Size
                $SizeBytes        = Invoke-Expression "$($numVhdSize.Value)$($cmbVhdSizeUnit.SelectedItem)"

                # Working Directory
                $WorkingDirectory = $txtWorkingDirectory.Text

                # VHDPath
                if (![string]::IsNullOrEmpty($txtVhdName.Text))
                {
                    $VHDPath      = "$($WorkingDirectory)\$($txtVhdName.Text)"
                }

                # Edition
                if (![string]::IsNullOrEmpty($cmbSkuList.SelectedItem))
                {
                    $Edition      = $cmbSkuList.SelectedItem
                }

                # Because we used ShowDialog, we need to manually dispose of the form.
                # This probably won't make much of a difference, but let's free up all of the resources we can
                # before we start the conversion process.

                $frmMain.Dispose()
            }

            if ($VHDFormat -ilike "AUTO")
            {
                if ($DiskLayout -eq "BIOS")
                {
                    $VHDFormat = "VHD"
                }
                else
                {
                    $VHDFormat = "VHDX"
                }
            }

            #
            # Choose smallest supported block size for dynamic VHD(X)
            #
            $BlockSizeBytes = 1MB

            # There's a difference between the maximum sizes for VHDs and VHDXs.  Make sure we follow it.
            if ("VHD" -ilike $VHDFormat)
            {
                if ($SizeBytes -gt $vhdMaxSize)
                {
                    Write-W2VWarn "For the VHD file format, the maximum file size is ~2040GB.  We're automatically setting the size to 2040GB for you."
                    $SizeBytes = 2040GB
                }

                $BlockSizeBytes = 512KB
            }

            # Check if -VHDPath and -WorkingDirectory were both specified.
            if ((![String]::IsNullOrEmpty($VHDPath)) -and (![String]::IsNullOrEmpty($WorkingDirectory)))
            {
                if ($WorkingDirectory -ne $pwd)
                {
                    # If the WorkingDirectory is anything besides $pwd, tell people that the WorkingDirectory is being ignored.
                    Write-W2VWarn "Specifying -VHDPath and -WorkingDirectory at the same time is contradictory."
                    Write-W2VWarn "Ignoring the WorkingDirectory specification."
                    $WorkingDirectory = Split-Path $VHDPath -Parent
                }
            }

            if ($VHDPath)
            {
                # Check to see if there's a conflict between the specified file extension and the VHDFormat being used.
                $ext = ([IO.FileInfo]$VHDPath).Extension

                if (!($ext -ilike ".$($VHDFormat)"))
                {
                    throw "There is a mismatch between the VHDPath file extension ($($ext.ToUpper())), and the VHDFormat (.$($VHDFormat)).  Please ensure that these match and try again."
                }
            }

            # Create a temporary name for the VHD(x).  We'll name it properly at the end of the script.
            if ([String]::IsNullOrEmpty($VHDPath))
            {
                $VHDPath      = Join-Path $WorkingDirectory "$($sessionKey).$($VHDFormat.ToLower())"
            }
            else
            {
                # Since we can't do Resolve-Path against a file that doesn't exist, we need to get creative in determining
                # the full path that the user specified (or meant to specify if they gave us a relative path).
                # Check to see if the path has a root specified.  If it doesn't, use the working directory.
                if (![IO.Path]::IsPathRooted($VHDPath))
                {
                    $VHDPath  = Join-Path $WorkingDirectory $VHDPath
                }

                $vhdFinalName = Split-Path $VHDPath -Leaf
                $VHDPath      = Join-Path (Split-Path $VHDPath -Parent) "$($sessionKey).$($VHDFormat.ToLower())"
            }

            Write-W2VTrace "Temporary $VHDFormat path is : $VHDPath"

            if (([IO.Path]::GetExtension($SourcePath)) -ieq '.iso')
            {
                if (Test-IsNetworkLocation $SourcePath) { throw 'ISO path must be local.' }
                $conversionMedia = Open-NewVmInstallMedia -SourcePath $SourcePath
                $SourcePath = $conversionMedia.ImagePath
                $driveLetter = $conversionMedia.DriveLetter
            }
            if (Test-IsNetworkLocation $SourcePath)
            {
                # Use the unique session directory, never a shared temporary filename.
                $tempSource = Join-Path $logFolder ('source-' + [IO.Path]::GetFileName($SourcePath))
                Copy-Item -LiteralPath $SourcePath -Destination $tempSource -ErrorAction Stop
                $SourcePath = $tempSource
            }
            $SourcePath = (Resolve-Path -LiteralPath $SourcePath -ErrorAction Stop).ProviderPath
            $WindowsImage = Select-NewVmWindowsImage -Images @(Get-WindowsImage -ImagePath $SourcePath -ErrorAction Stop) -Edition $Edition
            $ImageIndex = $WindowsImage.ImageIndex

            # Call the Check-BuildVersion function
            Check-BuildVersionforParsecVDA -Driveletter $Driveletter -SourcePath $SourcePath -ImageIndex $ImageIndex -ParsecVDA $ParsecVDA

            # We're good.  Open the WIM container.
            # NOTE: this is only required because we want to get the XML-based meta-data at the end.  Is there a better way?
            # If we can get this information from DISM cmdlets, we can remove the openWim constructs
            $openWim     = New-Object WIM2VHD.WimFile $SourcePath

            $openImage = $openWim[[Int32]$ImageIndex]

            if ($null -eq $openImage)
            {
                Write-W2VError "The specified edition does not appear to exist in the specified WIM."
                Write-W2VError "Valid edition names are:"
                $openWim.Images | %{ Write-W2VError "  $($_.ImageFlags)" }
                throw
            }

            Write-W2VInfo "Image $($openImage.ImageIndex) selected ($($openImage.ImageFlags))..."

            # Check to make sure that the image we're applying is Windows 7 or greater.
            if ($openImage.ImageVersion -lt $lowestSupportedVersion)
            {
                if ($openImage.ImageVersion -eq "0.0.0.0")
                {
                    Write-W2VWarn "The specified WIM does not encode the Windows version."
                }
                else
                {
                    throw "Convert-WindowsImage only supports Windows 7 and Windows 8 WIM files.  The specified image (version $($openImage.ImageVersion)) does not appear to contain one of those operating systems."
                }
            }

            if ($hyperVEnabled)
            {
                Write-W2VInfo "Creating sparse disk..."
                $newVhd = New-VHD -Path $VHDPath -SizeBytes $SizeBytes -BlockSizeBytes $BlockSizeBytes -Dynamic

                Write-W2VInfo "Mounting $VHDFormat..."
                $mountedVhd = $newVhd | Mount-VHD -PassThru -ErrorAction Stop
                $conversionResources.VhdMounted = $true
                $disk = $mountedVhd | Get-Disk -ErrorAction Stop
            }
            else
            {
                <#
                    Create the VHD using the VirtDisk Win32 API.
                    So, why not use the New-VHD cmdlet here?

                    New-VHD depends on the Hyper-V Cmdlets, which aren't installed by default.
                    Installing those cmdlets isn't a big deal, but they depend on the Hyper-V WMI
                    APIs, which in turn depend on Hyper-V.  In order to prevent Convert-WindowsImage
                    from being dependent on Hyper-V (and thus, x64 systems only), we're using the
                    VirtDisk APIs directly.
                #>

                Write-W2VInfo "Creating sparse disk..."
                [WIM2VHD.VirtualHardDisk]::CreateSparseDisk(
                    $VHDFormat,
                    $VHDPath,
                    $SizeBytes,
                    $true
                )

                # Attach the VHD.\
                Write-W2VInfo "Attaching $VHDFormat..."
                $mountedVhd = Mount-DiskImage -ImagePath $VHDPath -PassThru -ErrorAction Stop
                $conversionResources.VhdMounted = $true
                $disk = $mountedVhd | Get-DiskImage -ErrorAction Stop | Get-Disk -ErrorAction Stop
            }

            switch ($DiskLayout)
            {
                "BIOS"
                {
                    Write-W2VInfo "Initializing disk..."
                    Initialize-Disk -Number $disk.Number -PartitionStyle MBR

                    #
                    # Create the Windows/system partition
                    #
                    Write-W2VInfo "Creating single partition..."
                    $systemPartition = New-Partition -DiskNumber $disk.Number -UseMaximumSize -MbrType IFS -IsActive
                    $windowsPartition = $systemPartition

                    Write-W2VInfo "Formatting windows volume..."
                    $systemVolume = Format-Volume -Partition $systemPartition -FileSystem NTFS -Force -Confirm:$false
                    $windowsVolume = $systemVolume
                }

                "UEFI"
                {
                    Write-W2VInfo "Initializing disk..."
                    Initialize-Disk -Number $disk.Number -PartitionStyle GPT

                    if ((Get-WindowsBuildNumber) -ge 10240)
                    {
                        #
                        # Create the system partition.  Create a data partition so we can format it, then change to ESP
                        #
                        Write-W2VInfo "Creating EFI system partition..."
                        $systemPartition = New-Partition -DiskNumber $disk.Number -Size 200MB -GptType '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}'

                        Write-W2VInfo "Formatting system volume..."
                        $systemVolume = Format-Volume -Partition $systemPartition -FileSystem FAT32 -Force -Confirm:$false

                        Write-W2VInfo "Setting system partition as ESP..."
                        $systemPartition | Set-Partition -GptType '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'
                        $systemPartition | Add-PartitionAccessPath -AssignDriveLetter
                    }
                    else
                    {
                        #
                        # Create the system partition
                        #
                        Write-W2VInfo "Creating EFI system partition (ESP)..."
                        $systemPartition = New-Partition -DiskNumber $disk.Number -Size 200MB -GptType '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}' -AssignDriveLetter

                        Write-W2VInfo "Formatting ESP..."
                        $formatArgs = @(
                            "$($systemPartition.DriveLetter):", # Partition drive letter
                            "/FS:FAT32",                        # File system
                            "/Q",                               # Quick format
                            "/Y"                                # Suppress prompt
                            )

                        Run-Executable -Executable format -Arguments $formatArgs
                    }

                    #
                    # Create the reserved partition
                    #
                    Write-W2VInfo "Creating MSR partition..."
                    $reservedPartition = New-Partition -DiskNumber $disk.Number -Size 128MB -GptType '{e3c9e316-0b5c-4db8-817d-f92df00215ae}'

                    #
                    # Create the Windows partition
                    #
                    Write-W2VInfo "Creating windows partition..."
                    $windowsPartition = New-Partition -DiskNumber $disk.Number -UseMaximumSize -GptType '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}'

                    Write-W2VInfo "Formatting windows volume..."
                    $windowsVolume = Format-Volume -Partition $windowsPartition -FileSystem NTFS -Force -Confirm:$false
                }

                "WindowsToGo"
                {
                    Write-W2VInfo "Initializing disk..."
                    Initialize-Disk -Number $disk.Number -PartitionStyle MBR

                    #
                    # Create the system partition
                    #
                    Write-W2VInfo "Creating system partition..."
                    $systemPartition = New-Partition -DiskNumber $disk.Number -Size 350MB -MbrType FAT32 -IsActive

                    Write-W2VInfo "Formatting system volume..."
                    $systemVolume    = Format-Volume -Partition $systemPartition -FileSystem FAT32 -Force -Confirm:$false

                    #
                    # Create the Windows partition
                    #
                    Write-W2VInfo "Creating windows partition..."
                    $windowsPartition = New-Partition -DiskNumber $disk.Number -UseMaximumSize -MbrType IFS

                    Write-W2VInfo "Formatting windows volume..."
                    $windowsVolume    = Format-Volume -Partition $windowsPartition -FileSystem NTFS -Force -Confirm:$false
                }
            }

            #
            # Assign drive letter to Windows partition.  This is required for bcdboot
            #

            $attempts = 1
            $assigned = $false

            do
            {
                $windowsPartition | Add-PartitionAccessPath -AssignDriveLetter
                $windowsPartition = $windowsPartition | Get-Partition
                if($windowsPartition.DriveLetter -ne 0)
                {
                    $assigned = $true
                }
                else
                {
                    #sleep for up to 10 seconds and retry
                    Get-Random -Minimum 1 -Maximum 10 | Start-Sleep

                    $attempts++
                }
            }
            while ($attempts -le 100 -and -not($assigned))

            if (-not($assigned))
            {
                throw "Unable to get Partition after retry"
            }

            $windowsDrive = $(Get-Partition -Volume $windowsVolume).AccessPaths[0].substring(0,2)
            Write-W2VInfo "Windows path ($windowsDrive) has been assigned."
            Write-W2VInfo "Windows path ($windowsDrive) took $attempts attempts to be assigned."

            #
            # Refresh access paths (we have now formatted the volume)
            #
            $systemPartition = $systemPartition | Get-Partition
            $systemDrive = $systemPartition.AccessPaths[0].trimend("\").replace("\?", "??")
            Write-W2VInfo "System volume location: $systemDrive"

            ####################################################################################################
            # APPLY IMAGE FROM WIM TO THE NEW VHD
            ####################################################################################################

            Write-W2VInfo "Applying image to $VHDFormat. This could take a while..."
            if ((Get-Command Expand-WindowsImage -ErrorAction SilentlyContinue) -and ((-not $ApplyEA) -and ([string]::IsNullOrEmpty($DismPath))))
            {
                Expand-WindowsImage -ApplyPath $windowsDrive -ImagePath $SourcePath -Index $ImageIndex -LogPath "$($logFolder)\DismLogs.log" | Out-Null
            }
            else
            {
                if (![string]::IsNullOrEmpty($DismPath))
                {
                    $dismPath = $DismPath
                }
                else
                {
                    $dismPath = $(Join-Path (get-item env:\windir).value "system32\dism.exe")
                }

                $applyImage = "/Apply-Image"
                if ($ApplyEA)
                {
                    $applyImage = $applyImage + " /EA"
                }

                $dismArgs = @("$applyImage /ImageFile:`"$SourcePath`" /Index:$ImageIndex /ApplyDir:$windowsDrive /LogPath:`"$($logFolder)\DismLogs.log`"")
                Write-W2VInfo "Applying image: $dismPath $dismArgs"
                $process  = Start-Process -Passthru -Wait -NoNewWindow -FilePath $dismPath `
                            -ArgumentList $dismArgs `

                if ($process.ExitCode -ne 0)
                {
 	                throw "Image Apply failed! See DismImageApply logs for details"
                }
            }
            Write-W2VInfo "Image was applied successfully. "

            #
            # Here we copy in the unattend file (if specified by the command line)
            #
            if (![string]::IsNullOrEmpty($UnattendPath))
            {
                Write-W2VInfo "Applying unattend file ($(Split-Path $UnattendPath -Leaf))..."
                Copy-Item -Path $UnattendPath -Destination (Join-Path $windowsDrive "unattend.xml") -Force
            }

            if (![string]::IsNullOrEmpty($MergeFolderPath))
            {
                Write-W2VInfo "Applying merge folder ($MergeFolderPath)..."
                Copy-Item -Recurse -Path (Join-Path $MergeFolderPath "*") -Destination $windowsDrive -Force #added to handle merge folders
            }

            if (($openImage.ImageArchitecture -ne "ARM") -and       # No virtualization platform for ARM images
                ($openImage.ImageArchitecture -ne "ARM64") -and     # No virtualization platform for ARM64 images
                ($BCDinVHD -ne "NativeBoot"))                       # User asked for a non-bootable image
            {
                if (Test-Path "$($systemDrive)\boot\bcd")
                {
                    Write-W2VInfo "Image already has BIOS BCD store..."
                }
                elseif (Test-Path "$($systemDrive)\efi\microsoft\boot\bcd")
                {
                    Write-W2VInfo "Image already has EFI BCD store..."
                }
                else
                {
                    Write-W2VInfo "Making image bootable..."
                    $bcdBootArgs = @(
                        "$($windowsDrive)\Windows", # Path to the \Windows on the VHD
                        "/s $systemDrive",          # Specifies the volume letter of the drive to create the \BOOT folder on.
                        "/v"                        # Enabled verbose logging.
                        )

                    switch ($DiskLayout)
                    {
                        "BIOS"
                        {
                            $bcdBootArgs += "/f BIOS"   # Specifies the firmware type of the target system partition
                        }

                        "UEFI"
                        {
                            $bcdBootArgs += "/f UEFI"   # Specifies the firmware type of the target system partition
                        }

                        "WindowsToGo"
                        {
                            # Create entries for both UEFI and BIOS if possible
                            if (Test-Path "$($windowsDrive)\Windows\boot\EFI\bootmgfw.efi")
                            {
                                $bcdBootArgs += "/f ALL"
                            }
                        }
                    }

                    Run-Executable -Executable $BCDBoot -Arguments $bcdBootArgs

                    # The following is added to mitigate the VMM diff disk handling
                    # We're going to change from MBRBootOption to LocateBootOption.

                    if ($DiskLayout -eq "BIOS")
                    {
                        Write-W2VInfo "Fixing the Device ID in the BCD store on $($VHDFormat)..."
                        Run-Executable -Executable "BCDEDIT.EXE" -Arguments (
                            "/store $($systemDrive)\boot\bcd",
                            "/set `{bootmgr`} device locate"
                        )
                        Run-Executable -Executable "BCDEDIT.EXE" -Arguments (
                            "/store $($systemDrive)\boot\bcd",
                            "/set `{default`} device locate"
                        )
                        Run-Executable -Executable "BCDEDIT.EXE" -Arguments (
                            "/store $($systemDrive)\boot\bcd",
                            "/set `{default`} osdevice locate"
                        )
                    }
                }

                Write-W2VInfo "Drive is bootable.  Cleaning up..."

                # Are we turning the debugger on?
                if ($EnableDebugger -inotlike "None")
                {
                    $bcdEditArgs = $null;

                    # Configure the specified debugging transport and other settings.
                    switch ($EnableDebugger)
                    {
                        "Serial"
                        {
                            $bcdEditArgs = @(
                                "/dbgsettings SERIAL",
                                "DEBUGPORT:$($ComPort.Value)",
                                "BAUDRATE:$($BaudRate.Value)"
                                )
                        }

                        "1394"
                        {
                            $bcdEditArgs = @(
                                "/dbgsettings 1394",
                                "CHANNEL:$($Channel.Value)"
                                )
                        }

                        "USB"
                        {
                            $bcdEditArgs = @(
                                "/dbgsettings USB",
                                "TARGETNAME:$($Target.Value)"
                                )
                        }

                        "Local"
                        {
                            $bcdEditArgs = @(
                                "/dbgsettings LOCAL"
                                )
                        }

                        "Network"
                        {
                            $bcdEditArgs = @(
                                "/dbgsettings NET",
                                "HOSTIP:$($IP.Value)",
                                "PORT:$($Port.Value)",
                                "KEY:$($Key.Value)"
                                )
                        }
                    }

                    $bcdStores = @(
                        "$($systemDrive)\boot\bcd",
                        "$($systemDrive)\efi\microsoft\boot\bcd"
                        )

                    foreach ($bcdStore in $bcdStores)
                    {
                        if (Test-Path $bcdStore)
                        {
                            Write-W2VInfo "Turning kernel debugging on in the $($VHDFormat) for $($bcdStore)..."
                            Run-Executable -Executable "BCDEDIT.EXE" -Arguments (
                                "/store $($bcdStore)",
                                "/set `{default`} debug on"
                                )

                            $bcdEditArguments = @("/store $($bcdStore)") + $bcdEditArgs

                            Run-Executable -Executable "BCDEDIT.EXE" -Arguments $bcdEditArguments
                        }
                    }
                }
            }
            else
            {
                # Don't bother to check on debugging.  We can't boot WoA VHDs in VMs, and
                # if we're native booting, the changes need to be made to the BCD store on the
                # physical computer's boot volume.

                Write-W2VInfo "Image applied. It is not bootable."
            }

            if ($RemoteDesktopEnable -or (-not $ExpandOnNativeBoot))
            {
                $hive = Mount-RegistryHive -Hive (Join-Path $windowsDrive "Windows\System32\Config\System")

                if ($RemoteDesktopEnable)
                {
                    Write-W2VInfo -text "Enabling Remote Desktop"
                    Set-ItemProperty -Path "HKLM:\$($hive)\ControlSet001\Control\Terminal Server" -Name "fDenyTSConnections" -Value 0
                }

                if (-not $ExpandOnNativeBoot)
                {
                    Write-W2VInfo -text "Disabling automatic $VHDFormat expansion for Native Boot"
                    Set-ItemProperty -Path "HKLM:\$($hive)\ControlSet001\Services\FsDepends\Parameters" -Name "VirtualDiskExpandOnMount" -Value 4
                }

                Dismount-RegistryHive -HiveMountPoint $hive
            }

            if ($Driver)
            {
                Write-W2VInfo -text "Adding Windows Drivers to the Image"
                $Driver | ForEach-Object -Process {
                    Write-W2VInfo -text "Driver path: $PSItem"
                    Add-WindowsDriver -Path $windowsDrive -Recurse -Driver $PSItem -Verbose | Out-Null
                }
            }

            If ($Feature)
            {
                Write-W2VInfo -text "Installing Windows Feature(s) $Feature to the Image"
                if ($driveLetter -notmatch '^[A-Za-z]$') { throw 'Installing optional features requires an explicit mounted ISO source.' }
                $FeatureSourcePath = Join-Path -Path "$($driveLetter):" -ChildPath "sources\sxs"
                Write-W2VInfo -text "From $FeatureSourcePath"
                Enable-WindowsOptionalFeature -FeatureName $Feature -Source $FeatureSourcePath -Path $windowsDrive -All | Out-Null
            }

            if ($Package)
            {
                Write-W2VInfo -text "Adding Windows Packages to the Image"

                $Package | ForEach-Object -Process {
                    Write-W2VInfo -text "Package path: $PSItem"
                    Add-WindowsPackage -Path $windowsDrive -PackagePath $PSItem | Out-Null
                }
            }

            #
            # Remove system partition access path, if necessary
            #

            if (($GPUName)) {
            $gpuTarget = New-GpuPVTargetFromMountedDisk -VhdPath $VHDPath -DiskNumber $disk.Number -CreationOwned -PartitionNumber $windowsPartition.PartitionNumber
            Add-VMGpuPartitionAdapterFiles -GPUName $GPUName -Target $gpuTarget
            }

            Write-W2VInfo "Setting up programs to install at boot"
            Setup-ParsecInstall -DriveLetter $WindowsDrive -Parsec $Parsec -ParsecVDA $ParsecVDA -Sunshine $Sunshine -VirtualDisplayDriver $VirtualDisplayDriver -Team_ID $Team_ID -Key $Key -LocalParsecPath $LocalParsecPath -LocalSunshinePath $LocalSunshinePath -LocalVBCableZipPath $LocalVBCableZipPath -LocalVirtualAudioDriverPath $LocalVirtualAudioDriverPath -LocalParsecVDAPath $LocalParsecVDAPath -LocalVirtualDisplayDriverPath $LocalVirtualDisplayDriverPath -LocalVirtualDisplayDriverHDRPath $LocalVirtualDisplayDriverHDRPath -SecurityModel $SecurityModel -SourcePath $SourcePath -ImageIndex $ImageIndex

            if ($DiskLayout -eq "UEFI")
            {
                $systemPartition | Remove-PartitionAccessPath -AccessPath $systemPartition.AccessPaths[0]
            }

            if ([String]::IsNullOrEmpty($vhdFinalName))
            {
                # We need to generate a file name.
                Write-W2VInfo "Generating name for $($VHDFormat)..."
                $hive         = Mount-RegistryHive -Hive (Join-Path $windowsDrive "Windows\System32\Config\Software")

                $buildLabEx   = (Get-ItemProperty "HKLM:\$($hive)\Microsoft\Windows NT\CurrentVersion").BuildLabEx
                $installType  = (Get-ItemProperty "HKLM:\$($hive)\Microsoft\Windows NT\CurrentVersion").InstallationType
                $editionId    = (Get-ItemProperty "HKLM:\$($hive)\Microsoft\Windows NT\CurrentVersion").EditionID
                $skuFamily    = $null

                Dismount-RegistryHive -HiveMountPoint $hive

                # Is this ServerCore?
                # Since we're only doing this string comparison against the InstallType key, we won't get
                # false positives with the Core SKU.
                if ($installType.ToUpper().Contains("CORE"))
                {
                    $editionId += "Core"
                }

                # What type of SKU are we?
                if ($installType.ToUpper().Contains("SERVER"))
                {
                    $skuFamily = "Server"
                }
                elseif ($installType.ToUpper().Contains("CLIENT"))
                {
                    $skuFamily = "Client"
                }
                else
                {
                    $skuFamily = "Unknown"
                }

                #
                # ISSUE - do we want VL here?
                #
                $vhdFinalName = "$($buildLabEx)_$($skuFamily)_$($editionId)_$($openImage.ImageDefaultLanguage).$($VHDFormat.ToLower())"
                Write-W2VTrace "$VHDFormat final name is : $vhdFinalName"
            }

            if ($hyperVEnabled)
            {
                Write-W2VInfo "Dismounting $VHDFormat..."
                Dismount-VHD -Path $VHDPath -ErrorAction Stop
            }
            else
            {
                Write-W2VInfo "Closing $VHDFormat..."
                Dismount-DiskImage -ImagePath $VHDPath -ErrorAction Stop
            }
            $conversionResources.VhdMounted = $false

            $vhdFinalPath = Join-Path (Split-Path $VHDPath -Parent) $vhdFinalName
            Write-W2VTrace "$VHDFormat final path is : $vhdFinalPath"

            Publish-NewVmVhd -TemporaryPath $VHDPath -FinalPath $vhdFinalPath
            $vhd += Get-DiskImage -ImagePath $vhdFinalPath

            $vhdFinalName = $null
        }
        catch
        {
            $conversionFailure = $_
            Write-W2VError $_
            Write-W2VInfo "Log folder is $logFolder"
            throw
        }
        finally
        {
            $cleanupErrors = @()
            if ($null -ne $openWim)
            {
                try { $openWim.Close(); $openWim = $null }
                catch { $cleanupErrors += "WIM handle close failed: $($_.Exception.Message)" }
            }
            foreach ($ownedHive in @($conversionResources.Hives))
            {
                try { Dismount-RegistryHive -HiveMountPoint $ownedHive }
                catch { $cleanupErrors += "Registry hive '$ownedHive' remains loaded: $($_.Exception.Message)" }
            }
            if ($conversionResources.VhdMounted)
            {
                if ($conversionResources.Hives.Count -gt 0) {
                    $cleanupErrors += "VHD '$VHDPath' retained because an owned registry hive is still loaded."
                }
                else {
                    try {
                        if ($hyperVEnabled) { Dismount-VHD -Path $VHDPath -ErrorAction Stop }
                        else { Dismount-DiskImage -ImagePath $VHDPath -ErrorAction Stop }
                        $conversionResources.VhdMounted = $false
                    }
                    catch { $cleanupErrors += "VHD '$VHDPath' dismount failed: $($_.Exception.Message)" }
                }
            }
            try { Close-NewVmInstallMedia -Media $conversionMedia }
            catch { $cleanupErrors += "ISO dismount failed: $($_.Exception.Message)" }
            if (-not $CacheSource -and $tempSource -and $null -eq $openWim)
            {
                try { if (Test-Path -LiteralPath $tempSource) { Remove-Item -LiteralPath $tempSource -Force -ErrorAction Stop } }
                catch { $cleanupErrors += "Owned cached WIM removal failed: $($_.Exception.Message)" }
            }
            if ($transcripting)
            {
                try { $null = Stop-Transcript -ErrorAction Stop }
                catch { $cleanupErrors += "Transcript close failed: $($_.Exception.Message)" }
            }
            if ($cleanupErrors.Count -gt 0)
            {
                $message = $cleanupErrors -join '; '
                if ($null -ne $conversionFailure) { Write-Warning $message }
                else { throw $message }
            }
            if ($null -eq $conversionFailure) { Write-W2VInfo 'Done.' }
        }
    }

    End
    {
        if ($Passthru)
        {
            return $vhd
        }
    }
    #endregion Code

}

Function Add-WindowsImageTypes {
        $code      = @"
using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Security;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Xml.Linq;
using System.Xml.XPath;
using Microsoft.Win32.SafeHandles;

namespace WIM2VHD
{

/// <summary>
/// P/Invoke methods and associated enums, flags, and structs.
/// </summary>
public class
NativeMethods
{

    #region Delegates and Callbacks
    #region WIMGAPI

    ///<summary>
    ///User-defined function used with the RegisterMessageCallback or UnregisterMessageCallback function.
    ///</summary>
    ///<param name="MessageId">Specifies the message being sent.</param>
    ///<param name="wParam">Specifies additional message information. The contents of this parameter depend on the value of the
    ///MessageId parameter.</param>
    ///<param name="lParam">Specifies additional message information. The contents of this parameter depend on the value of the
    ///MessageId parameter.</param>
    ///<param name="UserData">Specifies the user-defined value passed to RegisterCallback.</param>
    ///<returns>
    ///To indicate success and to enable other subscribers to process the message return WIM_MSG_SUCCESS.
    ///To prevent other subscribers from receiving the message, return WIM_MSG_DONE.
    ///To cancel an image apply or capture, return WIM_MSG_ABORT_IMAGE when handling the WIM_MSG_PROCESS message.
    ///</returns>
    public delegate uint
    WimMessageCallback(
        uint   MessageId,
        IntPtr wParam,
        IntPtr lParam,
        IntPtr UserData
    );

    public static void
    RegisterMessageCallback(
        WimFileHandle hWim,
        WimMessageCallback callback)
        {

        uint _callback = NativeMethods.WimRegisterMessageCallback(hWim, callback, IntPtr.Zero);
        int rc = Marshal.GetLastWin32Error();
        if (0 != rc)
        {
            // Throw an exception if something bad happened on the Win32 end.
            throw
                new InvalidOperationException(
                    string.Format(
                        CultureInfo.CurrentCulture,
                        "Unable to register message callback."
            ));
        }
    }

    public static void
    UnregisterMessageCallback(
        WimFileHandle hWim,
        WimMessageCallback registeredCallback)
        {

        bool status = NativeMethods.WimUnregisterMessageCallback(hWim, registeredCallback);
        int rc = Marshal.GetLastWin32Error();
        if (!status)
        {
            throw
                new InvalidOperationException(
                    string.Format(
                        CultureInfo.CurrentCulture,
                        "Unable to unregister message callback."
            ));
        }
    }

    #endregion WIMGAPI
    #endregion Delegates and Callbacks

    #region Constants

    #region VDiskInterop

    /// <summary>
    /// The default depth in a VHD parent chain that this library will search through.
    /// If you want to go more than one disk deep into the parent chain, provide a different value.
    /// </summary>
    public   const uint  OPEN_VIRTUAL_DISK_RW_DEFAULT_DEPTH   = 0x00000001;

    public   const uint  DEFAULT_BLOCK_SIZE                   = 0x00080000;
    public   const uint  DISK_SECTOR_SIZE                     = 0x00000200;

    internal const uint  ERROR_VIRTDISK_NOT_VIRTUAL_DISK      = 0xC03A0015;
    internal const uint  ERROR_NOT_FOUND                      = 0x00000490;
    internal const uint  ERROR_IO_PENDING                     = 0x000003E5;
    internal const uint  ERROR_INSUFFICIENT_BUFFER            = 0x0000007A;
    internal const uint  ERROR_ERROR_DEV_NOT_EXIST            = 0x00000037;
    internal const uint  ERROR_BAD_COMMAND                    = 0x00000016;
    internal const uint  ERROR_SUCCESS                        = 0x00000000;

    public   const uint  GENERIC_READ                         = 0x80000000;
    public   const uint  GENERIC_WRITE                        = 0x40000000;
    public   const short FILE_ATTRIBUTE_NORMAL                = 0x00000080;
    public   const uint  CREATE_NEW                           = 0x00000001;
    public   const uint  CREATE_ALWAYS                        = 0x00000002;
    public   const uint  OPEN_EXISTING                        = 0x00000003;
    public   const short INVALID_HANDLE_VALUE                 = -1;

    internal static Guid VirtualStorageTypeVendorUnknown      = new Guid("00000000-0000-0000-0000-000000000000");
    internal static Guid VirtualStorageTypeVendorMicrosoft    = new Guid("EC984AEC-A0F9-47e9-901F-71415A66345B");

    #endregion VDiskInterop

    #region WIMGAPI

    public   const uint  WIM_FLAG_VERIFY                      = 0x00000002;
    public   const uint  WIM_FLAG_INDEX                       = 0x00000004;

    public   const uint  WM_APP                               = 0x00008000;

    #endregion WIMGAPI

    #endregion Constants

    #region Enums and Flags

    #region VDiskInterop

    /// <summary>
    /// Indicates the version of the virtual disk to create.
    /// </summary>
    public enum CreateVirtualDiskVersion : int
    {
        VersionUnspecified         = 0x00000000,
        Version1                   = 0x00000001,
        Version2                   = 0x00000002
    }

    public enum OpenVirtualDiskVersion : int
    {
        VersionUnspecified         = 0x00000000,
        Version1                   = 0x00000001,
        Version2                   = 0x00000002
    }

    /// <summary>
    /// Contains the version of the virtual hard disk (VHD) ATTACH_VIRTUAL_DISK_PARAMETERS structure to use in calls to VHD functions.
    /// </summary>
    public enum AttachVirtualDiskVersion : int
    {
        VersionUnspecified         = 0x00000000,
        Version1                   = 0x00000001,
        Version2                   = 0x00000002
    }

    public enum CompactVirtualDiskVersion : int
    {
        VersionUnspecified         = 0x00000000,
        Version1                   = 0x00000001
    }

    /// <summary>
    /// Contains the type and provider (vendor) of the virtual storage device.
    /// </summary>
    public enum VirtualStorageDeviceType : int
    {
        /// <summary>
        /// The storage type is unknown or not valid.
        /// </summary>
        Unknown                    = 0x00000000,
        /// <summary>
        /// For internal use only.  This type is not supported.
        /// </summary>
        ISO                        = 0x00000001,
        /// <summary>
        /// Virtual Hard Disk device type.
        /// </summary>
        VHD                        = 0x00000002,
        /// <summary>
        /// Virtual Hard Disk v2 device type.
        /// </summary>
        VHDX                       = 0x00000003
    }

    /// <summary>
    /// Contains virtual hard disk (VHD) open request flags.
    /// </summary>
    [Flags]
    public enum OpenVirtualDiskFlags
    {
        /// <summary>
        /// No flags. Use system defaults.
        /// </summary>
        None                       = 0x00000000,
        /// <summary>
        /// Open the VHD file (backing store) without opening any differencing-chain parents. Used to correct broken parent links.
        /// </summary>
        NoParents                  = 0x00000001,
        /// <summary>
        /// Reserved.
        /// </summary>
        BlankFile                  = 0x00000002,
        /// <summary>
        /// Reserved.
        /// </summary>
        BootDrive                  = 0x00000004,
    }

    /// <summary>
    /// Contains the bit mask for specifying access rights to a virtual hard disk (VHD).
    /// </summary>
    [Flags]
    public enum VirtualDiskAccessMask
    {
        /// <summary>
        /// Only Version2 of OpenVirtualDisk API accepts this parameter
        /// </summary>
        None                       = 0x00000000,
        /// <summary>
        /// Open the virtual disk for read-only attach access. The caller must have READ access to the virtual disk image file.
        /// </summary>
        /// <remarks>
        /// If used in a request to open a virtual disk that is already open, the other handles must be limited to either
        /// VIRTUAL_DISK_ACCESS_DETACH or VIRTUAL_DISK_ACCESS_GET_INFO access, otherwise the open request with this flag will fail.
        /// </remarks>
        AttachReadOnly             = 0x00010000,
        /// <summary>
        /// Open the virtual disk for read-write attaching access. The caller must have (READ | WRITE) access to the virtual disk image file.
        /// </summary>
        /// <remarks>
        /// If used in a request to open a virtual disk that is already open, the other handles must be limited to either
        /// VIRTUAL_DISK_ACCESS_DETACH or VIRTUAL_DISK_ACCESS_GET_INFO access, otherwise the open request with this flag will fail.
        /// If the virtual disk is part of a differencing chain, the disk for this request cannot be less than the readWriteDepth specified
        /// during the prior open request for that differencing chain.
        /// </remarks>
        AttachReadWrite            = 0x00020000,
        /// <summary>
        /// Open the virtual disk to allow detaching of an attached virtual disk. The caller must have
        /// (FILE_READ_ATTRIBUTES | FILE_READ_DATA) access to the virtual disk image file.
        /// </summary>
        Detach                     = 0x00040000,
        /// <summary>
        /// Information retrieval access to the virtual disk. The caller must have READ access to the virtual disk image file.
        /// </summary>
        GetInfo                    = 0x00080000,
        /// <summary>
        /// Virtual disk creation access.
        /// </summary>
        Create                     = 0x00100000,
        /// <summary>
        /// Open the virtual disk to perform offline meta-operations. The caller must have (READ | WRITE) access to the virtual
        /// disk image file, up to readWriteDepth if working with a differencing chain.
        /// </summary>
        /// <remarks>
        /// If the virtual disk is part of a differencing chain, the backing store (host volume) is opened in RW exclusive mode up to readWriteDepth.
        /// </remarks>
        MetaOperations             = 0x00200000,
        /// <summary>
        /// Reserved.
        /// </summary>
        Read                       = 0x000D0000,
        /// <summary>
        /// Allows unrestricted access to the virtual disk. The caller must have unrestricted access rights to the virtual disk image file.
        /// </summary>
        All                        = 0x003F0000,
        /// <summary>
        /// Reserved.
        /// </summary>
        Writable                   = 0x00320000
    }

    /// <summary>
    /// Contains virtual hard disk (VHD) creation flags.
    /// </summary>
    [Flags]
    public enum CreateVirtualDiskFlags
    {
        /// <summary>
        /// Contains virtual hard disk (VHD) creation flags.
        /// </summary>
        None                       = 0x00000000,
        /// <summary>
        /// Pre-allocate all physical space necessary for the size of the virtual disk.
        /// </summary>
        /// <remarks>
        /// The CREATE_VIRTUAL_DISK_FLAG_FULL_PHYSICAL_ALLOCATION flag is used for the creation of a fixed VHD.
        /// </remarks>
        FullPhysicalAllocation     = 0x00000001
    }

    /// <summary>
    /// Contains virtual disk attach request flags.
    /// </summary>
    [Flags]
    public enum AttachVirtualDiskFlags
    {
        /// <summary>
        /// No flags. Use system defaults.
        /// </summary>
        None                       = 0x00000000,
        /// <summary>
        /// Attach the virtual disk as read-only.
        /// </summary>
        ReadOnly                   = 0x00000001,
        /// <summary>
        /// No drive letters are assigned to the disk's volumes.
        /// </summary>
        /// <remarks>Oddly enough, this doesn't apply to NTFS mount points.</remarks>
        NoDriveLetter              = 0x00000002,
        /// <summary>
        /// Will decouple the virtual disk lifetime from that of the VirtualDiskHandle.
        /// The virtual disk will be attached until the Detach() function is called, even if all open handles to the virtual disk are closed.
        /// </summary>
        PermanentLifetime          = 0x00000004,
        /// <summary>
        /// Reserved.
        /// </summary>
        NoLocalHost                = 0x00000008
    }

    [Flags]
    public enum DetachVirtualDiskFlag
    {
        None                       = 0x00000000
    }

    [Flags]
    public enum CompactVirtualDiskFlags
    {
        None                       = 0x00000000,
        NoZeroScan                 = 0x00000001,
        NoBlockMoves               = 0x00000002
    }

    #endregion VDiskInterop

    #region WIMGAPI

    [FlagsAttribute]
    internal enum
    WimCreateFileDesiredAccess : uint
        {
        WimQuery                   = 0x00000000,
        WimGenericRead             = 0x80000000
    }

    public enum WimMessage : uint
    {
        WIM_MSG                    = WM_APP + 0x1476,
        WIM_MSG_TEXT,
        ///<summary>
        ///Indicates an update in the progress of an image application.
        ///</summary>
        WIM_MSG_PROGRESS,
        ///<summary>
        ///Enables the caller to prevent a file or a directory from being captured or applied.
        ///</summary>
        WIM_MSG_PROCESS,
        ///<summary>
        ///Indicates that volume information is being gathered during an image capture.
        ///</summary>
        WIM_MSG_SCANNING,
        ///<summary>
        ///Indicates the number of files that will be captured or applied.
        ///</summary>
        WIM_MSG_SETRANGE,
        ///<summary>
        ///Indicates the number of files that have been captured or applied.
        ///</summary>
        WIM_MSG_SETPOS,
        ///<summary>
        ///Indicates that a file has been either captured or applied.
        ///</summary>
        WIM_MSG_STEPIT,
        ///<summary>
        ///Enables the caller to prevent a file resource from being compressed during a capture.
        ///</summary>
        WIM_MSG_COMPRESS,
        ///<summary>
        ///Alerts the caller that an error has occurred while capturing or applying an image.
        ///</summary>
        WIM_MSG_ERROR,
        ///<summary>
        ///Enables the caller to align a file resource on a particular alignment boundary.
        ///</summary>
        WIM_MSG_ALIGNMENT,
        WIM_MSG_RETRY,
        ///<summary>
        ///Enables the caller to align a file resource on a particular alignment boundary.
        ///</summary>
        WIM_MSG_SPLIT,
        WIM_MSG_SUCCESS            = 0x00000000,
        WIM_MSG_ABORT_IMAGE        = 0xFFFFFFFF
    }

    internal enum
    WimCreationDisposition : uint
        {
        WimOpenExisting            = 0x00000003,
    }

    internal enum
    WimActionFlags : uint
        {
        WimIgnored                 = 0x00000000
    }

    internal enum
    WimCompressionType : uint
        {
        WimIgnored                 = 0x00000000
    }

    internal enum
    WimCreationResult : uint
        {
        WimCreatedNew              = 0x00000000,
        WimOpenedExisting          = 0x00000001
    }

    #endregion WIMGAPI

    #endregion Enums and Flags

    #region Structs

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct CreateVirtualDiskParameters
    {
        /// <summary>
        /// A CREATE_VIRTUAL_DISK_VERSION enumeration that specifies the version of the CREATE_VIRTUAL_DISK_PARAMETERS structure being passed to or from the virtual hard disk (VHD) functions.
        /// </summary>
        public CreateVirtualDiskVersion Version;

        /// <summary>
        /// Unique identifier to assign to the virtual disk object. If this member is set to zero, a unique identifier is created by the system.
        /// </summary>
        public Guid UniqueId;

        /// <summary>
        /// The maximum virtual size of the virtual disk object. Must be a multiple of 512.
        /// If a ParentPath is specified, this value must be zero.
        /// If a SourcePath is specified, this value can be zero to specify the size of the source VHD to be used, otherwise the size specified must be greater than or equal to the size of the source disk.
        /// </summary>
        public ulong MaximumSize;

        /// <summary>
        /// Internal size of the virtual disk object blocks.
        /// The following are predefined block sizes and their behaviors. For a fixed VHD type, this parameter must be zero.
        /// </summary>
        public uint BlockSizeInBytes;

        /// <summary>
        /// Internal size of the virtual disk object sectors. Must be set to 512.
        /// </summary>
        public uint SectorSizeInBytes;

        /// <summary>
        /// Optional path to a parent virtual disk object. Associates the new virtual disk with an existing virtual disk.
        /// If this parameter is not NULL, SourcePath must be NULL.
        /// </summary>
        public string ParentPath;

        /// <summary>
        /// Optional path to pre-populate the new virtual disk object with block data from an existing disk. This path may refer to a VHD or a physical disk.
        /// If this parameter is not NULL, ParentPath must be NULL.
        /// </summary>
        public string SourcePath;

        /// <summary>
        /// Flags for opening the VHD
        /// </summary>
        public OpenVirtualDiskFlags OpenFlags;

        /// <summary>
        /// GetInfoOnly flag for V2 handles
        /// </summary>
        public bool GetInfoOnly;

        /// <summary>
        /// Virtual Storage Type of the parent disk
        /// </summary>
        public VirtualStorageType ParentVirtualStorageType;

        /// <summary>
        /// Virtual Storage Type of the source disk
        /// </summary>
        public VirtualStorageType SourceVirtualStorageType;

        /// <summary>
        /// A GUID to use for fallback resiliency over SMB.
        /// </summary>
        public Guid ResiliencyGuid;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct VirtualStorageType
    {
        public VirtualStorageDeviceType DeviceId;
        public Guid VendorId;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct SecurityDescriptor
    {
        public byte revision;
        public byte size;
        public short control;
        public IntPtr owner;
        public IntPtr group;
        public IntPtr sacl;
        public IntPtr dacl;
    }

    #endregion Structs

    #region VirtDisk.DLL P/Invoke

    [DllImport("virtdisk.dll", CharSet = CharSet.Unicode)]
    public static extern uint
    CreateVirtualDisk(
        [In, Out] ref VirtualStorageType VirtualStorageType,
        [In]          string Path,
        [In]          VirtualDiskAccessMask VirtualDiskAccessMask,
        [In, Out] ref SecurityDescriptor SecurityDescriptor,
        [In]          CreateVirtualDiskFlags Flags,
        [In]          uint ProviderSpecificFlags,
        [In, Out] ref CreateVirtualDiskParameters Parameters,
        [In]          IntPtr Overlapped,
        [Out]     out SafeFileHandle Handle);

    #endregion VirtDisk.DLL P/Invoke

    #region Win32 P/Invoke

    [DllImport("advapi32", SetLastError = true)]
    public static extern bool InitializeSecurityDescriptor(
        [Out]     out SecurityDescriptor pSecurityDescriptor,
        [In]          uint dwRevision);

    #endregion Win32 P/Invoke

    #region WIMGAPI P/Invoke

    #region SafeHandle wrappers for WimFileHandle and WimImageHandle

    public sealed class WimFileHandle : SafeHandle
    {

        public WimFileHandle(
            string wimPath)
            : base(IntPtr.Zero, true)
            {

            if (String.IsNullOrEmpty(wimPath))
            {
                throw new ArgumentNullException("wimPath");
            }

            if (!File.Exists(Path.GetFullPath(wimPath)))
            {
                throw new FileNotFoundException((new FileNotFoundException()).Message, wimPath);
            }

            NativeMethods.WimCreationResult creationResult;

            this.handle = NativeMethods.WimCreateFile(
                wimPath,
                NativeMethods.WimCreateFileDesiredAccess.WimGenericRead,
                NativeMethods.WimCreationDisposition.WimOpenExisting,
                NativeMethods.WimActionFlags.WimIgnored,
                NativeMethods.WimCompressionType.WimIgnored,
                out creationResult
            );

            // Check results.
            if (creationResult != NativeMethods.WimCreationResult.WimOpenedExisting)
            {
                throw new Win32Exception();
            }

            if (this.handle == IntPtr.Zero)
            {
                throw new Win32Exception();
            }

            // Set the temporary path.
            NativeMethods.WimSetTemporaryPath(
                this,
                Environment.ExpandEnvironmentVariables("%TEMP%")
            );
        }

        protected override bool ReleaseHandle()
        {
            return NativeMethods.WimCloseHandle(this.handle);
        }

        public override bool IsInvalid
        {
            get { return this.handle == IntPtr.Zero; }
        }
    }

    public sealed class WimImageHandle : SafeHandle
    {
        public WimImageHandle(
            WimFile Container,
            uint ImageIndex)
            : base(IntPtr.Zero, true)
            {

            if (null == Container)
            {
                throw new ArgumentNullException("Container");
            }

            if ((Container.Handle.IsClosed) || (Container.Handle.IsInvalid))
            {
                throw new ArgumentNullException("The handle to the WIM file has already been closed, or is invalid.", "Container");
            }

            if (ImageIndex > Container.ImageCount)
            {
                throw new ArgumentOutOfRangeException("ImageIndex", "The index does not exist in the specified WIM file.");
            }

            this.handle = NativeMethods.WimLoadImage(
                Container.Handle.DangerousGetHandle(),
                ImageIndex);
        }

        protected override bool ReleaseHandle()
        {
            return NativeMethods.WimCloseHandle(this.handle);
        }

        public override bool IsInvalid
        {
            get { return this.handle == IntPtr.Zero; }
        }
    }

    #endregion SafeHandle wrappers for WimFileHandle and WimImageHandle

    [DllImport("Wimgapi.dll", CharSet = CharSet.Unicode, SetLastError = true, EntryPoint = "WIMCreateFile")]
    internal static extern IntPtr
    WimCreateFile(
        [In, MarshalAs(UnmanagedType.LPWStr)] string WimPath,
        [In]    WimCreateFileDesiredAccess DesiredAccess,
        [In]    WimCreationDisposition CreationDisposition,
        [In]    WimActionFlags FlagsAndAttributes,
        [In]    WimCompressionType CompressionType,
        [Out, Optional] out WimCreationResult CreationResult
    );

    [DllImport("Wimgapi.dll", CharSet = CharSet.Unicode, SetLastError = true, EntryPoint = "WIMCloseHandle")]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool
    WimCloseHandle(
        [In]    IntPtr Handle
    );

    [DllImport("Wimgapi.dll", CharSet = CharSet.Unicode, SetLastError = true, EntryPoint = "WIMLoadImage")]
    internal static extern IntPtr
    WimLoadImage(
        [In]    IntPtr Handle,
        [In]    uint ImageIndex
    );

    [DllImport("Wimgapi.dll", CharSet = CharSet.Unicode, SetLastError = true, EntryPoint = "WIMGetImageCount")]
    internal static extern uint
    WimGetImageCount(
        [In]    WimFileHandle Handle
    );

    [DllImport("Wimgapi.dll", CharSet = CharSet.Unicode, SetLastError = true, EntryPoint = "WIMGetImageInformation")]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool
    WimGetImageInformation(
        [In]        SafeHandle Handle,
        [Out]   out StringBuilder ImageInfo,
        [Out]   out uint SizeOfImageInfo
    );

    [DllImport("Wimgapi.dll", CharSet = CharSet.Unicode, SetLastError = true, EntryPoint = "WIMSetTemporaryPath")]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool
    WimSetTemporaryPath(
        [In]    WimFileHandle Handle,
        [In]    string TempPath
    );

    [DllImport("Wimgapi.dll", CharSet = CharSet.Unicode, SetLastError = true, EntryPoint = "WIMRegisterMessageCallback", CallingConvention = CallingConvention.StdCall)]
    internal static extern uint
    WimRegisterMessageCallback(
        [In, Optional] WimFileHandle      hWim,
        [In]           WimMessageCallback MessageProc,
        [In, Optional] IntPtr             ImageInfo
    );

    [DllImport("Wimgapi.dll", CharSet = CharSet.Unicode, SetLastError = true, EntryPoint = "WIMUnregisterMessageCallback", CallingConvention = CallingConvention.StdCall)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool
    WimUnregisterMessageCallback(
        [In, Optional] WimFileHandle      hWim,
        [In]           WimMessageCallback MessageProc
    );


    #endregion WIMGAPI P/Invoke
}

#region WIM Interop

public class WimFile
{

    internal XDocument m_xmlInfo;
    internal List<WimImage> m_imageList;

    private static NativeMethods.WimMessageCallback wimMessageCallback;

    #region Events

    /// <summary>
    /// DefaultImageEvent handler
    /// </summary>
    public delegate void DefaultImageEventHandler(object sender, DefaultImageEventArgs e);

    ///<summary>
    ///ProcessFileEvent handler
    ///</summary>
    public delegate void ProcessFileEventHandler(object sender, ProcessFileEventArgs e);

    ///<summary>
    ///Enable the caller to prevent a file resource from being compressed during a capture.
    ///</summary>
    public event ProcessFileEventHandler ProcessFileEvent;

    ///<summary>
    ///Indicate an update in the progress of an image application.
    ///</summary>
    public event DefaultImageEventHandler ProgressEvent;

    ///<summary>
    ///Alert the caller that an error has occurred while capturing or applying an image.
    ///</summary>
    public event DefaultImageEventHandler ErrorEvent;

    ///<summary>
    ///Indicate that a file has been either captured or applied.
    ///</summary>
    public event DefaultImageEventHandler StepItEvent;

    ///<summary>
    ///Indicate the number of files that will be captured or applied.
    ///</summary>
    public event DefaultImageEventHandler SetRangeEvent;

    ///<summary>
    ///Indicate the number of files that have been captured or applied.
    ///</summary>
    public event DefaultImageEventHandler SetPosEvent;

    #endregion Events

    private
    enum
    ImageEventMessage : uint
    {
        ///<summary>
        ///Enables the caller to prevent a file or a directory from being captured or applied.
        ///</summary>
        Progress = NativeMethods.WimMessage.WIM_MSG_PROGRESS,
        ///<summary>
        ///Notification sent to enable the caller to prevent a file or a directory from being captured or applied.
        ///To prevent a file or a directory from being captured or applied, call WindowsImageContainer.SkipFile().
        ///</summary>
        Process = NativeMethods.WimMessage.WIM_MSG_PROCESS,
        ///<summary>
        ///Enables the caller to prevent a file resource from being compressed during a capture.
        ///</summary>
        Compress = NativeMethods.WimMessage.WIM_MSG_COMPRESS,
        ///<summary>
        ///Alerts the caller that an error has occurred while capturing or applying an image.
        ///</summary>
        Error = NativeMethods.WimMessage.WIM_MSG_ERROR,
        ///<summary>
        ///Enables the caller to align a file resource on a particular alignment boundary.
        ///</summary>
        Alignment = NativeMethods.WimMessage.WIM_MSG_ALIGNMENT,
        ///<summary>
        ///Enables the caller to align a file resource on a particular alignment boundary.
        ///</summary>
        Split = NativeMethods.WimMessage.WIM_MSG_SPLIT,
        ///<summary>
        ///Indicates that volume information is being gathered during an image capture.
        ///</summary>
        Scanning = NativeMethods.WimMessage.WIM_MSG_SCANNING,
        ///<summary>
        ///Indicates the number of files that will be captured or applied.
        ///</summary>
        SetRange = NativeMethods.WimMessage.WIM_MSG_SETRANGE,
        ///<summary>
        ///Indicates the number of files that have been captured or applied.
        /// </summary>
        SetPos = NativeMethods.WimMessage.WIM_MSG_SETPOS,
        ///<summary>
        ///Indicates that a file has been either captured or applied.
        ///</summary>
        StepIt = NativeMethods.WimMessage.WIM_MSG_STEPIT,
        ///<summary>
        ///Success.
        ///</summary>
        Success = NativeMethods.WimMessage.WIM_MSG_SUCCESS,
        ///<summary>
        ///Abort.
        ///</summary>
        Abort = NativeMethods.WimMessage.WIM_MSG_ABORT_IMAGE
    }

    ///<summary>
    ///Event callback to the Wimgapi events
    ///</summary>
    private
    uint
    ImageEventMessagePump(
        uint MessageId,
        IntPtr wParam,
        IntPtr lParam,
        IntPtr UserData)
        {

        uint status = (uint) NativeMethods.WimMessage.WIM_MSG_SUCCESS;

        DefaultImageEventArgs eventArgs = new DefaultImageEventArgs(wParam, lParam, UserData);

        switch ((ImageEventMessage)MessageId)
        {

            case ImageEventMessage.Progress:
                ProgressEvent(this, eventArgs);
                break;

            case ImageEventMessage.Process:
                if (null != ProcessFileEvent)
                {
                    string fileToImage = Marshal.PtrToStringUni(wParam);
                    ProcessFileEventArgs fileToProcess = new ProcessFileEventArgs(fileToImage, lParam);
                    ProcessFileEvent(this, fileToProcess);

                    if (fileToProcess.Abort == true)
                    {
                        status = (uint)ImageEventMessage.Abort;
                    }
                }
                break;

            case ImageEventMessage.Error:
                if (null != ErrorEvent)
                {
                    ErrorEvent(this, eventArgs);
                }
                break;

            case ImageEventMessage.SetRange:
                if (null != SetRangeEvent)
                {
                    SetRangeEvent(this, eventArgs);
                }
                break;

            case ImageEventMessage.SetPos:
                if (null != SetPosEvent)
                {
                    SetPosEvent(this, eventArgs);
                }
                break;

            case ImageEventMessage.StepIt:
                if (null != StepItEvent)
                {
                    StepItEvent(this, eventArgs);
                }
                break;

            default:
                break;
        }
        return status;

    }

    /// <summary>
    /// Constructor.
    /// </summary>
    /// <param name="wimPath">Path to the WIM container.</param>
    public
    WimFile(string wimPath)
    {
        if (string.IsNullOrEmpty(wimPath))
        {
            throw new ArgumentNullException("wimPath");
        }

        if (!File.Exists(Path.GetFullPath(wimPath)))
        {
            throw new FileNotFoundException((new FileNotFoundException()).Message, wimPath);
        }

        Handle = new NativeMethods.WimFileHandle(wimPath);

        // Hook up the events before we return.
        //wimMessageCallback = new NativeMethods.WimMessageCallback(ImageEventMessagePump);
        //NativeMethods.RegisterMessageCallback(this.Handle, wimMessageCallback);
    }

    /// <summary>
    /// Closes the WIM file.
    /// </summary>
    public void
    Close()
    {
        foreach (WimImage image in Images)
        {
            image.Close();
        }

        if (null != wimMessageCallback)
        {
            NativeMethods.UnregisterMessageCallback(this.Handle, wimMessageCallback);
            wimMessageCallback = null;
        }

        if ((!Handle.IsClosed) && (!Handle.IsInvalid))
        {
            Handle.Close();
        }
    }

    /// <summary>
    /// Provides a list of WimImage objects, representing the images in the WIM container file.
    /// </summary>
    public List<WimImage>
    Images
    {
        get
        {
            if (null == m_imageList)
            {

                int imageCount = (int)ImageCount;
                m_imageList = new List<WimImage>(imageCount);
                for (int i = 0; i < imageCount; i++)
                {

                    // Load up each image so it's ready for us.
                    m_imageList.Add(
                        new WimImage(this, (uint)i + 1));
                }
            }

            return m_imageList;
        }
    }

    /// <summary>
    /// Provides a list of names of the images in the specified WIM container file.
    /// </summary>
    public List<string>
    ImageNames
    {
        get
        {
            List<string> nameList = new List<string>();
            foreach (WimImage image in Images)
            {
                nameList.Add(image.ImageName);
            }
            return nameList;
        }
    }

    /// <summary>
    /// Indexer for WIM images inside the WIM container, indexed by the image number.
    /// The list of Images is 0-based, but the WIM container is 1-based, so we automatically compensate for that.
    /// this[1] returns the 0th image in the WIM container.
    /// </summary>
    /// <param name="ImageIndex">The 1-based index of the image to retrieve.</param>
    /// <returns>WinImage object.</returns>
    public WimImage
    this[int ImageIndex]
    {
        get { return Images[ImageIndex - 1]; }
    }

    /// <summary>
    /// Indexer for WIM images inside the WIM container, indexed by the image name.
    /// WIMs created by different processes sometimes contain different information - including the name.
    /// Some images have their name stored in the Name field, some in the Flags field, and some in the EditionID field.
    /// We take all of those into account in while searching the WIM.
    /// </summary>
    /// <param name="ImageName"></param>
    /// <returns></returns>
    public WimImage
    this[string ImageName]
    {
        get
        {
            return
                Images.Where(i => (
                    i.ImageName.ToUpper()  == ImageName.ToUpper() ||
                    i.ImageFlags.ToUpper() == ImageName.ToUpper() ))
                .DefaultIfEmpty(null)
                    .FirstOrDefault<WimImage>();
        }
    }

    /// <summary>
    /// Returns the number of images in the WIM container.
    /// </summary>
    internal uint
    ImageCount
    {
        get { return NativeMethods.WimGetImageCount(Handle); }
    }

    /// <summary>
    /// Returns an XDocument representation of the XML metadata for the WIM container and associated images.
    /// </summary>
    internal XDocument
    XmlInfo
    {
        get
        {

            if (null == m_xmlInfo)
            {
                StringBuilder builder;
                uint bytes;
                if (!NativeMethods.WimGetImageInformation(Handle, out builder, out bytes))
                {
                    throw new Win32Exception();
                }

                // Ensure the length of the returned bytes to avoid garbage characters at the end.
                int charCount = (int)bytes / sizeof(char);
                if (null != builder)
                {
                    // Get rid of the unicode file marker at the beginning of the XML.
                    builder.Remove(0, 1);
                    builder.EnsureCapacity(charCount - 1);
                    builder.Length = charCount - 1;

                    // This isn't likely to change while we have the image open, so cache it.
                    m_xmlInfo = XDocument.Parse(builder.ToString().Trim());
                }
                else
                {
                    m_xmlInfo = null;
                }
            }

            return m_xmlInfo;
        }
    }

    public NativeMethods.WimFileHandle Handle
    {
        get;
        private set;
    }
}

public class
WimImage
{

    internal XDocument m_xmlInfo;

    public
    WimImage(
        WimFile Container,
        uint ImageIndex)
        {

        if (null == Container)
        {
            throw new ArgumentNullException("Container");
        }

        if ((Container.Handle.IsClosed) || (Container.Handle.IsInvalid))
        {
            throw new ArgumentNullException("The handle to the WIM file has already been closed, or is invalid.", "Container");
        }

        if (ImageIndex > Container.ImageCount)
        {
            throw new ArgumentOutOfRangeException("ImageIndex", "The index does not exist in the specified WIM file.");
        }

        Handle = new NativeMethods.WimImageHandle(Container, ImageIndex);
    }

    public enum
    Architectures : uint
    {
        x86   = 0x0,
        ARM   = 0x5,
        IA64  = 0x6,
        AMD64 = 0x9,
        ARM64 = 0xC
    }

    public void
    Close()
    {
        if ((!Handle.IsClosed) && (!Handle.IsInvalid))
        {
            Handle.Close();
        }
    }

    public NativeMethods.WimImageHandle
    Handle
    {
        get;
        private set;
    }

    internal XDocument
    XmlInfo
    {
        get
        {

            if (null == m_xmlInfo)
            {
                StringBuilder builder;
                uint bytes;
                if (!NativeMethods.WimGetImageInformation(Handle, out builder, out bytes))
                {
                    throw new Win32Exception();
                }

                // Ensure the length of the returned bytes to avoid garbage characters at the end.
                int charCount = (int)bytes / sizeof(char);
                if (null != builder)
                {
                    // Get rid of the unicode file marker at the beginning of the XML.
                    builder.Remove(0, 1);
                    builder.EnsureCapacity(charCount - 1);
                    builder.Length = charCount - 1;

                    // This isn't likely to change while we have the image open, so cache it.
                    m_xmlInfo = XDocument.Parse(builder.ToString().Trim());
                }
                else
                {
                    m_xmlInfo = null;
                }
            }

            return m_xmlInfo;
        }
    }

    public string
    ImageIndex
    {
        get { return XmlInfo.Element("IMAGE").Attribute("INDEX").Value; }
    }

    public string
    ImageName
    {
        get { return XmlInfo.XPathSelectElement("/IMAGE/NAME").Value; }
    }

    public string
    ImageEditionId
    {
        get { return XmlInfo.XPathSelectElement("/IMAGE/WINDOWS/EDITIONID").Value; }
    }

    public string
    ImageFlags
    {
        get
        {
            string flagValue = String.Empty;

            try
            {
                flagValue = XmlInfo.XPathSelectElement("/IMAGE/FLAGS").Value;
            }
            catch
            {

                // Some WIM files don't contain a FLAGS element in the metadata.
                // In an effort to support those WIMs too, inherit the EditionId if there
                // are no Flags.

                if (String.IsNullOrEmpty(flagValue))
                {
                    flagValue = this.ImageEditionId;

                    // Check to see if the EditionId is "ServerHyper".  If so,
                    // tweak it to be "ServerHyperCore" instead.

                    if (0 == String.Compare("serverhyper", flagValue, true))
                    {
                        flagValue = "ServerHyperCore";
                    }
                }

            }

            return flagValue;
        }
    }

    public string
    ImageProductType
    {
        get { return XmlInfo.XPathSelectElement("/IMAGE/WINDOWS/PRODUCTTYPE").Value; }
    }

    public string
    ImageInstallationType
    {
        get { return XmlInfo.XPathSelectElement("/IMAGE/WINDOWS/INSTALLATIONTYPE").Value; }
    }

    public string
    ImageDescription
    {
        get { return XmlInfo.XPathSelectElement("/IMAGE/DESCRIPTION").Value; }
    }

    public ulong
    ImageSize
    {
        get { return ulong.Parse(XmlInfo.XPathSelectElement("/IMAGE/TOTALBYTES").Value); }
    }

    public Architectures
    ImageArchitecture
    {
        get
        {
            int arch = -1;
            try
            {
                arch = int.Parse(XmlInfo.XPathSelectElement("/IMAGE/WINDOWS/ARCH").Value);
            }
            catch { }

            return (Architectures)arch;
        }
    }

    public string
    ImageDefaultLanguage
    {
        get
        {
            string lang = null;
            try
            {
                lang = XmlInfo.XPathSelectElement("/IMAGE/WINDOWS/LANGUAGES/DEFAULT").Value;
            }
            catch { }

            return lang;
        }
    }

    public Version
    ImageVersion
    {
        get
        {
            int major = 0;
            int minor = 0;
            int build = 0;
            int revision = 0;

            try
            {
                major = int.Parse(XmlInfo.XPathSelectElement("/IMAGE/WINDOWS/VERSION/MAJOR").Value);
                minor = int.Parse(XmlInfo.XPathSelectElement("/IMAGE/WINDOWS/VERSION/MINOR").Value);
                build = int.Parse(XmlInfo.XPathSelectElement("/IMAGE/WINDOWS/VERSION/BUILD").Value);
                revision = int.Parse(XmlInfo.XPathSelectElement("/IMAGE/WINDOWS/VERSION/SPBUILD").Value);
            }
            catch { }

            return (new Version(major, minor, build, revision));
        }
    }

    public string
    ImageDisplayName
    {
        get { return XmlInfo.XPathSelectElement("/IMAGE/DISPLAYNAME").Value; }
    }

    public string
    ImageDisplayDescription
    {
        get { return XmlInfo.XPathSelectElement("/IMAGE/DISPLAYDESCRIPTION").Value; }
    }
}

///<summary>
///Describes the file that is being processed for the ProcessFileEvent.
///</summary>
public class
DefaultImageEventArgs : EventArgs
{
    ///<summary>
    ///Default constructor.
    ///</summary>
    public
    DefaultImageEventArgs(
        IntPtr wideParameter,
        IntPtr leftParameter,
        IntPtr userData)
    {

        WideParameter = wideParameter;
        LeftParameter = leftParameter;
        UserData      = userData;
    }

    ///<summary>
    ///wParam
    ///</summary>
    public IntPtr WideParameter
    {
        get;
        private set;
    }

    ///<summary>
    ///lParam
    ///</summary>
    public IntPtr LeftParameter
    {
        get;
        private set;
    }

    ///<summary>
    ///UserData
    ///</summary>
    public IntPtr UserData
    {
        get;
        private set;
    }
}

///<summary>
///Describes the file that is being processed for the ProcessFileEvent.
///</summary>
public class
ProcessFileEventArgs : EventArgs
{
    ///<summary>
    ///Default constructor.
    ///</summary>
    ///<param name="file">Fully qualified path and file name. For example: c:\file.sys.</param>
    ///<param name="skipFileFlag">Default is false - skip file and continue.
    ///Set to true to abort the entire image capture.</param>
    public
    ProcessFileEventArgs(
        string file,
        IntPtr skipFileFlag)
        {

        m_FilePath = file;
        m_SkipFileFlag = skipFileFlag;
    }

    ///<summary>
    ///Skip file from being imaged.
    ///</summary>
    public void
    SkipFile()
    {
        byte[] byteBuffer =
        {
                0
        };
        int byteBufferSize = byteBuffer.Length;
        Marshal.Copy(byteBuffer, 0, m_SkipFileFlag, byteBufferSize);
    }

    ///<summary>
    ///Fully qualified path and file name.
    ///</summary>
    public string
    FilePath
    {
        get
        {
            string stringToReturn = "";
            if (m_FilePath != null)
            {
                stringToReturn = m_FilePath;
            }
            return stringToReturn;
        }
    }

    ///<summary>
    ///Flag to indicate if the entire image capture should be aborted.
    ///Default is false - skip file and continue. Setting to true will
    ///abort the entire image capture.
    ///</summary>
    public bool Abort
    {
        set { m_Abort = value; }
        get { return m_Abort;  }
    }

    private string m_FilePath;
    private bool m_Abort;
    private IntPtr m_SkipFileFlag;

}

#endregion WIM Interop

#region VHD Interop
// Based on code written by the Hyper-V Test team.
/// <summary>
/// The Virtual Hard Disk class provides methods for creating and manipulating Virtual Hard Disk files.
/// </summary>
public class
VirtualHardDisk
{
    #region Static Methods

    #region Sparse Disks

    /// <summary>
    /// Abbreviated signature of CreateSparseDisk so it's easier to use from WIM2VHD.
    /// </summary>
    /// <param name="virtualStorageDeviceType">The type of disk to create, VHD or VHDX.</param>
    /// <param name="path">The path of the disk to create.</param>
    /// <param name="size">The maximum size of the disk to create.</param>
    /// <param name="overwrite">Overwrite the VHD if it already exists.</param>
    public static void
    CreateSparseDisk(
        NativeMethods.VirtualStorageDeviceType virtualStorageDeviceType,
        string path,
        ulong size,
        bool overwrite)
        {

        CreateSparseDisk(
            path,
            size,
            overwrite,
            null,
            IntPtr.Zero,
            (virtualStorageDeviceType == NativeMethods.VirtualStorageDeviceType.VHD)
                ? NativeMethods.DEFAULT_BLOCK_SIZE
                : 0,
            virtualStorageDeviceType,
            NativeMethods.DISK_SECTOR_SIZE);
    }

    /// <summary>
    /// Creates a new sparse (dynamically expanding) virtual hard disk (.vhd). Supports both sync and async modes.
    /// The VHD image file uses only as much space on the backing store as needed to store the actual data the VHD currently contains.
    /// </summary>
    /// <param name="path">The path and name of the VHD to create.</param>
    /// <param name="size">The size of the VHD to create in bytes.
    /// When creating this type of VHD, the VHD API does not test for free space on the physical backing store based on the maximum size requested,
    /// therefore it is possible to successfully create a dynamic VHD with a maximum size larger than the available physical disk free space.
    /// The maximum size of a dynamic VHD is 2,040 GB.  The minimum size is 3 MB.</param>
    /// <param name="source">Optional path to pre-populate the new virtual disk object with block data from an existing disk
    /// This path may refer to a VHD or a physical disk.  Use NULL if you don't want a source.</param>
    /// <param name="overwrite">If the VHD exists, setting this parameter to 'True' will delete it and create a new one.</param>
    /// <param name="overlapped">If not null, the operation runs in async mode</param>
    /// <param name="blockSizeInBytes">Block size for the VHD.</param>
    /// <param name="virtualStorageDeviceType">VHD format version (VHD1 or VHD2)</param>
    /// <param name="sectorSizeInBytes">Sector size for the VHD.</param>
    /// <exception cref="ArgumentOutOfRangeException">Thrown when an invalid size is specified</exception>
    /// <exception cref="FileNotFoundException">Thrown when source VHD is not found.</exception>
    /// <exception cref="SecurityException">Thrown when there was an error while creating the default security descriptor.</exception>
    /// <exception cref="Win32Exception">Thrown when an error occurred while creating the VHD.</exception>
    public static void
    CreateSparseDisk(
        string path,
        ulong size,
        bool overwrite,
        string source,
        IntPtr overlapped,
        uint blockSizeInBytes,
        NativeMethods.VirtualStorageDeviceType virtualStorageDeviceType,
        uint sectorSizeInBytes)
        {

        // Validate the virtualStorageDeviceType
        if (virtualStorageDeviceType != NativeMethods.VirtualStorageDeviceType.VHD && virtualStorageDeviceType != NativeMethods.VirtualStorageDeviceType.VHDX)
        {

            throw (
                new ArgumentOutOfRangeException(
                    "virtualStorageDeviceType",
                    virtualStorageDeviceType,
                    "VirtualStorageDeviceType must be VHD or VHDX."
            ));
        }

        // Validate size.  It needs to be a multiple of DISK_SECTOR_SIZE (512)...
        if ((size % NativeMethods.DISK_SECTOR_SIZE) != 0)
        {

            throw (
                new ArgumentOutOfRangeException(
                    "size",
                    size,
                    "The size of the virtual disk must be a multiple of 512."
            ));
        }

        if ((!String.IsNullOrEmpty(source)) && (!System.IO.File.Exists(source)))
        {

            throw (
                new System.IO.FileNotFoundException(
                    "Unable to find the source file.",
                    source
            ));
        }

        if ((overwrite) && (System.IO.File.Exists(path)))
        {

            System.IO.File.Delete(path);
        }

        NativeMethods.CreateVirtualDiskParameters createParams = new NativeMethods.CreateVirtualDiskParameters();

        // Select the correct version.
        createParams.Version = (virtualStorageDeviceType == NativeMethods.VirtualStorageDeviceType.VHD)
            ? NativeMethods.CreateVirtualDiskVersion.Version1
            : NativeMethods.CreateVirtualDiskVersion.Version2;

        createParams.UniqueId                 = Guid.NewGuid();
        createParams.MaximumSize              = size;
        createParams.BlockSizeInBytes         = blockSizeInBytes;
        createParams.SectorSizeInBytes        = sectorSizeInBytes;
        createParams.ParentPath               = null;
        createParams.SourcePath               = source;
        createParams.OpenFlags                = NativeMethods.OpenVirtualDiskFlags.None;
        createParams.GetInfoOnly              = false;
        createParams.ParentVirtualStorageType = new NativeMethods.VirtualStorageType();
        createParams.SourceVirtualStorageType = new NativeMethods.VirtualStorageType();

        //
        // Create and init a security descriptor.
        // Since we're creating an essentially blank SD to use with CreateVirtualDisk
        // the VHD will take on the security values from the parent directory.
        //

        NativeMethods.SecurityDescriptor securityDescriptor;
        if (!NativeMethods.InitializeSecurityDescriptor(out securityDescriptor, 1))
        {

            throw (
                new SecurityException(
                    "Unable to initialize the security descriptor for the virtual disk."
            ));
        }

        NativeMethods.VirtualStorageType virtualStorageType = new NativeMethods.VirtualStorageType();
        virtualStorageType.DeviceId = virtualStorageDeviceType;
        virtualStorageType.VendorId = NativeMethods.VirtualStorageTypeVendorMicrosoft;

        SafeFileHandle vhdHandle;

        uint returnCode = NativeMethods.CreateVirtualDisk(
            ref virtualStorageType,
                path,
                (virtualStorageDeviceType == NativeMethods.VirtualStorageDeviceType.VHD)
                    ? NativeMethods.VirtualDiskAccessMask.All
                    : NativeMethods.VirtualDiskAccessMask.None,
            ref securityDescriptor,
                NativeMethods.CreateVirtualDiskFlags.None,
                0,
            ref createParams,
                overlapped,
            out vhdHandle);

        vhdHandle.Close();

        if (NativeMethods.ERROR_SUCCESS != returnCode && NativeMethods.ERROR_IO_PENDING != returnCode)
        {

            throw (
                new Win32Exception(
                    (int)returnCode
            ));
        }
    }

    #endregion Sparse Disks

    #endregion Static Methods

}
#endregion VHD Interop
}
"@
    #ifdef for Powershell V7 or greater which looks for assemblies in same path as powershell dll path
    if ($PSVersionTable.psversion.Major -ge 7){        
    Add-Type -TypeDefinition $code -ErrorAction SilentlyContinue 
    }
    else {
    Add-Type -TypeDefinition $code -ReferencedAssemblies "System.Xml","System.Linq","System.Xml.Linq" -ErrorAction SilentlyContinue
    }
}

Function New-GPUEnabledVM {
param(
[int64]$SizeBytes,
[int]$Edition,
[string]$VhdFormat,
[string]$VhdPath,
[string]$VMName,
[string]$DiskLayout,
[string]$UnattendPath,
[int64]$MemoryAmount,
[int]$CPUCores,
[string]$NetworkSwitch,
[string]$GPUName,
[decimal]$GPUResourceAllocationPercentage = 50,
$GPUAllocationPolicy = $null,
[string]$SourcePath,
[bool]$Parsec,
[bool]$ParsecVDA,
[bool]$Sunshine,
[bool]$VirtualDisplayDriver,
[string]$Team_ID,
[string]$Key,
[string]$username,
[string]$password,
[string]$language,
[string]$timezone,
[string]$autologon,
[string]$LocalParsecPath = "",
[string]$LocalSunshinePath = "",
[string]$LocalVBCableZipPath = "",
[string]$LocalVirtualAudioDriverPath = "",
[string]$LocalParsecVDAPath = "",
[string]$LocalVirtualDisplayDriverPath = "",
[string]$LocalVirtualDisplayDriverHDRPath = "",
[string]$SecurityModel = "HostDownload"
)
    $VHDPath = ConcatenateVHDPath -VHDPath $VHDPath -VMName $VMName

    # Validate VM/VHD do not exist BEFORE mounting the ISO, so SmartExit does not leave the ISO mounted.
    # 在挂载 ISO 前验证 VM/VHD 不存在，避免 SmartExit 导致 ISO 残留挂载。
    if ($(Get-VM -Name $VMName -ErrorAction SilentlyContinue) -ne $NULL) {
        throw "A VM named '$VMName' already exists. Inspect it manually or choose a new name; this workflow will not adopt or delete it."
        }
    if (Test-Path $vhdPath) {
        throw "A disk already exists at '$vhdPath'. Inspect it manually or choose a new name; it will not be overwritten."
        }
    $creationMedia = $null
    $creationFailure = $null
    $temporaryUnattend = Join-Path $PSScriptRoot (".unattend-" + [guid]::NewGuid().ToString("N") + ".xml")
    try {
        $creationMedia = Open-NewVmInstallMedia -SourcePath $SourcePath
        $DriveLetter = $creationMedia.DriveLetter
        Copy-Item -LiteralPath $UnattendPath -Destination $temporaryUnattend -ErrorAction Stop
        Modify-AutoUnattend -username $username -password $password -autologon $autologon -hostname $VMName -language $language -timezone $timezone -UnattendPath $temporaryUnattend
    $MaxAvailableVersion = (Get-VMHostSupportedVersion).Version | Where-Object {$_.Major -lt 254}| Select-Object -Last 1 
    Convert-WindowsImage -SourcePath $SourcePath -ISODriveLetter $DriveLetter -Edition $Edition -VHDFormat $Vhdformat -VHDPath $VhdPath -DiskLayout $DiskLayout -UnattendPath $temporaryUnattend -GPUName $GPUName -Parsec $Parsec -ParsecVDA $ParsecVDA -Sunshine $Sunshine -VirtualDisplayDriver $VirtualDisplayDriver -Team_ID $Team_ID -Key $Key -LocalParsecPath $LocalParsecPath -LocalSunshinePath $LocalSunshinePath -LocalVBCableZipPath $LocalVBCableZipPath -LocalVirtualAudioDriverPath $LocalVirtualAudioDriverPath -LocalParsecVDAPath $LocalParsecVDAPath -LocalVirtualDisplayDriverPath $LocalVirtualDisplayDriverPath -LocalVirtualDisplayDriverHDRPath $LocalVirtualDisplayDriverHDRPath -SecurityModel $SecurityModel -SizeBytes $SizeBytes | Out-Null

    }
    catch { $creationFailure = $_; throw }
    finally {
        $creationCleanupErrors = @()
        try { if (Test-Path -LiteralPath $temporaryUnattend) { Remove-Item -LiteralPath $temporaryUnattend -Force -ErrorAction Stop } }
        catch { $creationCleanupErrors += "Temporary unattended file removal failed: $($_.Exception.Message)" }
        try { Close-NewVmInstallMedia -Media $creationMedia }
        catch { $creationCleanupErrors += "ISO cleanup failed: $($_.Exception.Message)" }
        if ($creationCleanupErrors.Count -gt 0) {
            $message = $creationCleanupErrors -join '; '
            if ($null -ne $creationFailure) { Write-Warning $message } else { throw $message }
        }
    }
    $finalizedDisk = Get-Item -LiteralPath $VhdPath -ErrorAction Stop
    if ($finalizedDisk.PSIsContainer -or $finalizedDisk.Length -le 0) { throw 'Conversion did not produce a nonempty finalized VHD file.' }

    # HostDownload: copy installer files to VHDX / HostDownload: 复制安装文件到 VHDX
    if ($SecurityModel -eq "HostDownload" -and (Test-Path $VhdPath)) {
        Write-Host "INFO   : HostDownload mode - copying installer files to VHDX..." -ForegroundColor Green
        $mountedVHD = Mount-VHD -Path $VhdPath -PassThru -ErrorAction Stop
        $stagingFailure = $null
        try {
            $gpuStagingTarget = New-GpuPVTargetFromMountedDisk -VhdPath $VhdPath -DiskNumber $mountedVHD.DiskNumber -CreationOwned
            Copy-InstallerFilesToVHDX -Target $gpuStagingTarget -Config $script:Config
        }
        catch { $stagingFailure = $_; throw }
        finally {
            try { Dismount-VHD -Path $VhdPath -ErrorAction Stop }
            catch {
                if ($null -ne $stagingFailure) { Write-Warning "Staging VHD cleanup also failed: $($_.Exception.Message)" }
                else { throw }
            }
        }
        Write-Host "INFO   : Installer files copied to VHDX." -ForegroundColor Green
    }

    if (Test-Path $vhdPath) {
        if ($MaxAvailableVersion) {
            $createdVM = New-VM -Name $VMName -MemoryStartupBytes $MemoryAmount -VHDPath $VhdPath -Generation 2 -SwitchName $NetworkSwitch -Version $MaxAvailableVersion -ErrorAction Stop
        } else {
            # Could not determine a supported VM version; fall back to the default / 无法确定支持的 VM 版本，回退到默认值
            $createdVM = New-VM -Name $VMName -MemoryStartupBytes $MemoryAmount -VHDPath $VhdPath -Generation 2 -SwitchName $NetworkSwitch -ErrorAction Stop
            Write-Warning "Could not determine a supported VM version; using default. / 无法确定支持的 VM 版本，使用默认值。"
        }
        $createdVM = Resolve-NewVmIdentity -VMName $VMName -VMId ([string]$createdVM.VMId)
        $script:Config.TargetVMId = [string]$createdVM.VMId
        Set-VM -VM $createdVM -ProcessorCount $CPUCores -CheckpointType Disabled -LowMemoryMappedIoSpace 1GB -HighMemoryMappedIoSpace 32GB -GuestControlledCacheTypes $true -AutomaticStopAction Save -ErrorAction Stop
        Set-VMMemory -VM $createdVM -DynamicMemoryEnabled $false -ErrorAction Stop 
        $CPUManufacturer = Get-CimInstance -ClassName Win32_Processor | Foreach-Object Manufacturer
        $BuildVer = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
        if (($BuildVer.CurrentBuild -lt 22000) -and ($CPUManufacturer -eq "AuthenticAMD")) {
            }
        Else {
            Set-VMProcessor -VM $createdVM -ExposeVirtualizationExtensions $true -ErrorAction Stop
            }
        # Do not alter host-wide enhanced session policy for a single VM task.
        Set-VMKeyProtector -VM $createdVM -NewLocalKeyProtector -ErrorAction Stop
        Enable-VMTPM -VM $createdVM -ErrorAction Stop
        # The shared GPU helper currently accepts a name. Revalidate immediately before it.
        $null = Resolve-NewVmIdentity -VMName $VMName -VMId $script:Config.TargetVMId
        Assign-VMGPUPartitionAdapter -GPUName $GPUName -VMName $VMName -GPUResourceAllocationPercentage $GPUResourceAllocationPercentage -AllocationPolicy $GPUAllocationPolicy
        $null = Resolve-NewVmIdentity -VMName $VMName -VMId $script:Config.TargetVMId
        Write-Host 'VM configuration complete. Phase4 starts the saved target; open its console manually if needed.'
        }
    else {
    throw "Finalized VHD disappeared before VM creation; stopped."
    }
}

# ============================================================================
# Main Execution Flow / 主执行流程
# ============================================================================

# Transcripts are not enabled automatically: credential prompts and native command
# errors must not create an unreviewed secret-bearing transcript.
if ($Interactive) {
    $taskName = $TargetVMName
    if ([string]::IsNullOrWhiteSpace($taskName)) { $taskName = Read-Host 'Target VM name (choose before loading state)' }
    $stateFile = Get-StateFilePath -VMName $taskName -Prefix 'NewVm' -ScriptRoot $PSScriptRoot
    $savedState = $null
    if (-not $ResetState) { $savedState = Import-State -StateFilePath $stateFile -ExpectedVMName $taskName }
    if ($savedState -and (Read-Host 'Resume this task? Y=resume; N=new configuration') -eq 'Y') {
        $script:Config = $savedState
        Set-NewVmAllocationPolicy
        if ($null -ne $script:RequestedGpuAllocationPolicy) {
            $requested = $script:RequestedGpuAllocationPolicy
            $saved = $script:Config.GPUAllocationPolicy
            if ($requested.Count -ne $saved.Count) { throw 'Requested GPU allocation differs from the checkpoint. Resume preserves it; use the quota-only entry for a completed VM.' }
            foreach ($field in $requested.Keys) { if ($requested[$field] -cne $saved[$field]) { throw 'Requested GPU allocation differs from the checkpoint. Resume preserves it; use the quota-only entry for a completed VM.' } }
        }
        Write-Host ('Resuming saved GPU allocation: ' + (Format-GpuPVAllocationPolicy -Policy $script:Config.GPUAllocationPolicy))
    } else {
        Invoke-ConfigWizard -KnownVMName $taskName
        $script:Config.PhaseCompleted = @()
    }
    Sync-ConfigToParams
} else {
    # Preserve the editable legacy parameters, but use the checked host-download executor.
    if ($TargetVMName) { $params.VMName = $TargetVMName }
    foreach ($key in @($script:Config.Keys)) { if ($params.ContainsKey($key)) { $script:Config[$key] = $params[$key] } }
    if ($null -ne $script:RequestedGpuAllocationPolicy) { $script:Config.GPUAllocationPolicy = $script:RequestedGpuAllocationPolicy }
    Set-NewVmAllocationPolicy
    $script:Config.StreamingChoice = if ($params.Parsec -and $params.ParsecVDA) {'Parsec+ParsecVDA'} elseif ($params.Parsec -and $params.VirtualDisplayDriver) {'Parsec+VDD'} elseif ($params.Sunshine -and $params.ParsecVDA) {'Sunshine+ParsecVDA'} elseif ($params.Sunshine -and $params.VirtualDisplayDriver) {'Sunshine+VDD'} elseif (-not ($params.Parsec -or $params.ParsecVDA -or $params.Sunshine -or $params.VirtualDisplayDriver)) {'None'} else {throw 'Invalid streaming combination.'}
    $script:Config.SecurityModel = 'HostDownload'
    $stateFile = Get-StateFilePath -VMName $params.VMName -Prefix 'NewVm' -ScriptRoot $PSScriptRoot
    if ((Test-Path -LiteralPath $stateFile) -and -not $ResetState) { throw 'A checkpoint exists. Use -Interactive -TargetVMName to resume, or explicitly -ResetState for new configuration.' }
}
$securityModel = $script:Config.SecurityModel
if ($securityModel -ne 'HostDownload') { throw 'Legacy guest-download deployment is not a supported checked path. Choose HostDownload; legacy files are retained for reference.' }
if ($script:Config.Team_ID -or $script:Config.Key) { throw 'Automatic Parsec Teams enrollment is not supported; configure it manually after installation. No key has been saved.' }
if ([string]::IsNullOrWhiteSpace([string]$script:Config.Password)) { $script:Config.Password = Read-GpuPVSecret -Prompt 'Windows password (required again after resume; never stored in state)' }
if ([string]::IsNullOrWhiteSpace([string]$script:Config.Password)) { throw 'A nonempty Windows password is required.' }
Sync-ConfigToParams
if ($StartFromStep) {
    $remaining = @(Get-GpuPVRemainingPhases -Config $script:Config -StartFromStep $StartFromStep)
    $script:Config.PhaseCompleted = @($script:Config.PhaseCompleted | Where-Object { $remaining -notcontains $_ })
}
Save-State -Config $script:Config -StateFilePath $stateFile

# --- Phase 1: Parameter Validation / 阶段 1: 参数验证 ---
if (-not (Test-StepCompleted -Step "Phase1" -Config $script:Config)) {
    Write-StepHeader -StepNumber "1" -EnTitle "Parameter Validation" -ZhTitle "参数验证"
    Check-Params @params
    Add-PhaseCompleted -Step "Phase1" -Config $script:Config -StateFilePath $stateFile
} else {
    Write-Bilingual -En "Phase 1 already completed. Skipping." -Zh "阶段 1 已完成，跳过。"
}

# --- Phase 2: Host File Preparation (HostDownload only) / 阶段 2: 宿主机文件准备（仅 HostDownload）---
if ($securityModel -eq "HostDownload" -and -not (Test-StepCompleted -Step "Phase2" -Config $script:Config)) {
    Write-StepHeader -StepNumber "2" -EnTitle "Host File Preparation" -ZhTitle "宿主机文件准备"
    Invoke-HostFilePreparation -Config $script:Config
    Sync-ConfigToParams  # Re-sync after file paths are populated
    Add-PhaseCompleted -Step "Phase2" -Config $script:Config -StateFilePath $stateFile
} elseif ($securityModel -eq "HostDownload") {
    Write-Bilingual -En "Phase 2 already completed. Skipping." -Zh "阶段 2 已完成，跳过。"
}

# --- Phase 3: VHDX Creation / 阶段 3: VHDX 创建 ---
if (-not (Test-StepCompleted -Step "Phase3" -Config $script:Config)) {
    Write-StepHeader -StepNumber "3" -EnTitle "VHDX Creation" -ZhTitle "VHDX 创建"
    New-GPUEnabledVM @params -SecurityModel $securityModel
    Add-PhaseCompleted -Step "Phase3" -Config $script:Config -StateFilePath $stateFile
} else {
    Write-Bilingual -En "Phase 3 already completed. Skipping." -Zh "阶段 3 已完成，跳过。"
}

$currentTarget = Resolve-NewVmIdentity -VMName $params.VMName -VMId $script:Config.TargetVMId

# --- Phase 4: VM Startup / 阶段 4: 虚拟机启动 ---
if (-not (Test-StepCompleted -Step "Phase4" -Config $script:Config)) {
    Write-StepHeader -StepNumber "4" -EnTitle "VM Startup" -ZhTitle "虚拟机启动"
    Start-NewVmTarget -VMName $params.VMName -VMId $script:Config.TargetVMId
    Add-PhaseCompleted -Step "Phase4" -Config $script:Config -StateFilePath $stateFile
} else {
    Write-Bilingual -En "Phase 4 already completed. Skipping." -Zh "阶段 4 已完成，跳过。"
}

# Readiness and credentials are runtime prerequisites on every pending resume.
$securePassword = ConvertTo-SecureString -String $params.Password -AsPlainText -Force
$credential = New-Object System.Management.Automation.PSCredential($params.Username, $securePassword)
Invoke-GpuPVPostBootWorkflow -Config $script:Config -WaitReady {
    Invoke-Phase5_WaitForVM -VMName $params.VMName -VMId $script:Config.TargetVMId -Credential $credential -TimeoutSeconds 300
} -Install {
    Invoke-Phase6_PostBootInstall -VMName $params.VMName -VMId $script:Config.TargetVMId -Credential $credential
} -Verify {
    Invoke-Phase7_VerifyAndOutput -VMName $params.VMName -Config $script:Config -Credential $credential
} -SavePhase {
    param($step)
    Add-PhaseCompleted -Step $step -Config $script:Config -StateFilePath $stateFile
}
Write-Host 'Checked phases completed. Checkpoint retained for audit; client login and image quality remain manual acceptance tasks.'
