#Requires -RunAsAdministrator
<#
.SYNOPSIS
    【存档版本 / ARCHIVE ONLY — 请勿直接执行】
    已存在VM一键配置GPU-PV脚本 / One-click GPU-PV Configuration Script for Existing VMs

.DESCRIPTION
    ⚠️  安全提示 / SECURITY NOTICE ⚠️
    ================================================================
    此版本为【原始实现存档】，已从火绒恢复区提取，仅供代码审计和
    功能参考，【不建议在生产环境中直接执行】。

    为什么会被安全软件拦截？
    -----------------------
    本脚本 Phase 6 中，在 Invoke-Command -VMName 的 ScriptBlock 内
    使用了以下行为模式，与下载型木马（Downloader）的启发式特征完全吻合：

    1. Invoke-WebRequest -Uri <URL> -OutFile $env:TEMP\xxx.exe
       → 从互联网下载可执行文件到临时目录

    2. [System.IO.File]::WriteAllBytes($path, $byteArray)
       → 将字节数组解码写入磁盘（常用于规避静态检测）

    3. Start-Process -ArgumentList "/install /quiet /norestart" -Wait
       → 静默安装执行，无用户交互

    上述三步组合 = "下载 → 解码/落地 → 静默执行"，正是
    HEUR:TrojanDownloader/PS.NetLoader.av 的判定依据。

    正确的使用方式 / CORRECT USAGE
    -------------------------------
    请使用根目录下的安全修改版：
    Configure-GpuPV-ExistingVM.ps1

    安全修改版的主要变更：
    - 所有下载操作仅限宿主机 Phase 2 执行
    - VM 内 Invoke-Command ScriptBlock 不再包含任何网络请求
    - 不再使用 WriteAllBytes 模式，改为挂载 VHDX 直接复制文件
    - 添加 VC++ Redist / NefCon 等依赖的宿主机预下载
    - 修复 Set-VM -DynamicMemoryEnabled 参数错误（改为 -StaticMemory）

    本存档版已修复的功能性Bug：
    - Set-VM -DynamicMemoryEnabled 参数错误 → 改为 -StaticMemory
    - VDD 管理脚本路径跨 VM 不可访问 → 改为通过 ArgumentList 传递脚本内容
    （但保留原始的 AV 触发行为模式，用于安全审计参考）

    如果你需要运行此脚本，请先：
    1. 将脚本所在目录加入杀毒软件白名单/信任区
    2. 确保理解每一行代码在做什么
    3. 建议在隔离环境（非生产VM）中先行测试

    ================================================================

.PARAMETER VMName
    虚拟机名称
.PARAMETER GPUName
    GPU名称，默认AUTO
.PARAMETER GPUAllocation
    GPU资源分配百分比，默认50
.PARAMETER StartFromStep
    从指定阶段开始（1-7，0=自动检测）
.PARAMETER ResetState
    清除状态文件从头开始
.PARAMETER SkipHostChecks
    跳过宿主机检查
.PARAMETER SkipCleanup
    跳过VM清理阶段
.PARAMETER SkipGpuDriverUpdate
    跳过GPU驱动更新
.PARAMETER ForceReinstallVDD
    强制重装VDD
.PARAMETER UseLegacyVDD
    使用旧版VDD（timminator fork）
.PARAMETER WhatIf
    仅预览，不执行修改
.PARAMETER CredentialUserName
    凭据用户名（非交互式用）
.PARAMETER CredentialPassword
    凭据密码（SecureString）
.EXAMPLE
    .\Configure-GpuPV-ExistingVM.ps1 -VMName "xiazai"
.EXAMPLE
    .\Configure-GpuPV-ExistingVM.ps1 -VMName "xiazai" -StartFromStep 3

.NOTE
    File: Configure-GpuPV-ExistingVM-Archive-Original.ps1
    Origin: Extracted from Huorong AV quarantine / 火绒恢复区提取
    Status: ARCHIVE ONLY — Not for production use / 仅供存档，不推荐执行
#>

[CmdletBinding()]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', '', Justification='Username is not sensitive; password uses SecureString')]
param(
    [string]$VMName,
    [string]$GPUName = "AUTO",
    [decimal]$GPUAllocation = 50,
    [int]$StartFromStep = 0,
    [switch]$ResetState,
    [switch]$SkipHostChecks,
    [switch]$SkipCleanup,
    [switch]$SkipGpuDriverUpdate,
    [switch]$ForceReinstallVDD,
    [switch]$UseLegacyVDD,
    [switch]$WhatIf,
    [string]$CredentialUserName,
    [SecureString]$CredentialPassword
)

$ErrorActionPreference = "Stop"
$script:StateFile = $null
$script:StateData = @{}
$script:Credential = $null
$script:Config = @{
    VMName = $VMName; GPUName = $GPUName; GPUAllocation = $GPUAllocation
    StreamingChoice = $null; VDDConfig = @{}; SunshineConfig = @{}; ParsecConfig = @{}
    InstallFilePaths = @{}; WasRunning = $false; OriginalVMState = $null
}

$script:DownloadUrls = @{
    Sunshine = "https://github.com/LizardByte/Sunshine/releases/download/v0.23.1/sunshine-windows-installer.exe"
    Parsec = "https://builds.parsecgaming.com/package/parsec-windows.exe"
    ParsecVDA = "https://github.com/timminator/ParsecVDA-Always-Connected/releases/download/v1.4.1/ParsecVDA.-.Always.Connected-v1.4.1-setup-x64.exe"
    VBCable = "https://download.vb-audio.com/Download_CABLE/VBCABLE_Driver_Pack43.zip"
    VCRedist = "https://aka.ms/vs/17/release/vc_redist.x64.exe"
    VDDManagerScript = "https://raw.githubusercontent.com/VirtualDrivers/Virtual-Display-Driver/master/Community%20Scripts/virtual-driver-manager.ps1"
}

# ========================================================================
# Import Modules
# ========================================================================
$scriptRoot = $PSScriptRoot
if (-not $scriptRoot) { $scriptRoot = (Get-Location).Path }
Import-Module "$scriptRoot\Add-VMGpuPartitionAdapterFiles.psm1" -Force -ErrorAction Stop
Import-Module "$scriptRoot\Enhanced-GPU-PV-Common.psm1" -Force -ErrorAction Stop

# ========================================================================
# Helper Functions
# ========================================================================
function Write-StepHeader {
    param([string]$Step, [string]$Title)
    Write-Host ""; Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "Phase $Step`: $Title" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
}
function Write-Bilingual {
    param([string]$En, [string]$Zh, [string]$Status = "Info", [string]$Color = "White")
    $msg = "$En / $Zh"
    switch ($Status) {
        "Success" { Write-Host $msg -ForegroundColor Green }
        "Warning" { Write-Warning $msg }
        "Error"   { Write-Host $msg -ForegroundColor Red }
        default   { Write-Host $msg -ForegroundColor $Color }
    }
}
function Confirm-Continue {
    param([string]$Prompt = "Continue? (Y/N) / 是否继续? (Y/N)")
    $r = Read-Host $Prompt
    if ($r -ne 'Y' -and $r -ne 'y') { Write-Bilingual "User cancelled." "用户已取消。" "Warning"; exit 0 }
}
function Test-Administrator {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
}

# ========================================================================
# State Management
# ========================================================================
function Get-StateFilePath {
    if (-not $script:StateFile) { $script:StateFile = Join-Path $scriptRoot ".gpupv-config-$($script:Config.VMName).state.json" }
    return $script:StateFile
}
function Save-State {
    param([int]$CompletedStep)
    $path = Get-StateFilePath
    $script:StateData.CompletedSteps = @($script:StateData.CompletedSteps | Where-Object { $_ -lt $CompletedStep }) + @($CompletedStep) | Sort-Object -Unique
    $script:StateData.LastRun = (Get-Date).ToString("o")
    $script:StateData.VMName = $script:Config.VMName
    $script:StateData.GPUName = $script:Config.GPUName
    $script:StateData.GPUAllocation = $script:Config.GPUAllocation
    $script:StateData.StreamingChoice = $script:Config.StreamingChoice
    $script:StateData.VDDConfig = $script:Config.VDDConfig
    if ($script:Config.InstallFilePaths) {
        $script:StateData.InstallFilePaths = $script:Config.InstallFilePaths
    }
    $script:StateData | ConvertTo-Json -Depth 10 | Set-Content -Path $path -Encoding UTF8
}
function Import-State {
    $path = Get-StateFilePath
    if (Test-Path $path) {
        try {
            $data = Get-Content -Path $path -Encoding UTF8 | ConvertFrom-Json
            $ht = @{}
            $data.PSObject.Properties | ForEach-Object { $ht[$_.Name] = $_.Value }
            $script:StateData = $ht
            # Restore config from state file for resume capability / 从状态文件恢复配置以支持断点续传
            if ($data.VMName)       { $script:Config.VMName = $data.VMName }
            if ($data.GPUName)      { $script:Config.GPUName = $data.GPUName }
            if ($null -ne $data.GPUAllocation) { $script:Config.GPUAllocation = $data.GPUAllocation }
            if ($data.StreamingChoice) { $script:Config.StreamingChoice = $data.StreamingChoice }
            if ($data.VDDConfig) {
                $vddHt = @{}; $data.VDDConfig.PSObject.Properties | ForEach-Object { $vddHt[$_.Name] = $_.Value }
                $script:Config.VDDConfig = $vddHt
            }
            if ($data.SunshineConfig) {
                $suHt = @{}; $data.SunshineConfig.PSObject.Properties | ForEach-Object { $suHt[$_.Name] = $_.Value }
                $script:Config.SunshineConfig = $suHt
            }
            if ($data.ParsecConfig) {
                $paHt = @{}; $data.ParsecConfig.PSObject.Properties | ForEach-Object { $paHt[$_.Name] = $_.Value }
                $script:Config.ParsecConfig = $paHt
            }
            if ($data.InstallFilePaths) {
                $ifHt = @{}; $data.InstallFilePaths.PSObject.Properties | ForEach-Object { $ifHt[$_.Name] = $_.Value }
                $script:Config.InstallFilePaths = $ifHt
            }
            return $true
        } catch { $script:StateData = @{ CompletedSteps = @() }; return $false }
    }
    $script:StateData = @{ CompletedSteps = @() }; return $false
}
function Clear-State {
    $path = Get-StateFilePath
    if (Test-Path $path) { Remove-Item -Path $path -Force }
}
function Test-StepCompleted { param([int]$Step); return $script:StateData.CompletedSteps -contains $Step }

# ========================================================================
# Phase 1: Host Environment Check & Fix
# ========================================================================
function Invoke-Phase1_HostChecks {
    Write-StepHeader "1" "Host Environment Check & Fix / 宿主机环境检查与修复"

    if (-not (Test-Administrator)) { throw "ERROR: Administrator privileges required. / 错误：需要管理员权限。" }
    Write-Bilingual "Running as Administrator." "以管理员权限运行。" "Success"

    if (-not [Environment]::Is64BitProcess) { throw "ERROR: Please use 64-bit PowerShell. / 错误：请使用64位PowerShell。" }
    Write-Bilingual "64-bit PowerShell confirmed." "64位PowerShell已确认。" "Success"

    if ([string]::IsNullOrWhiteSpace($script:Config.VMName)) {
        $script:Config.VMName = Read-Host "Enter VM Name / 输入虚拟机名称"
        if ([string]::IsNullOrWhiteSpace($script:Config.VMName)) { throw "ERROR: VM Name is required. / 错误：虚拟机名称是必填项。" }
    }

    $vm = Get-VM -Name $script:Config.VMName -ErrorAction SilentlyContinue
    if (-not $vm) { throw "ERROR: VM '$($script:Config.VMName)' not found. / 错误：找不到虚拟机。" }
    $script:Config.OriginalVMState = $vm.State
    Write-Bilingual "Target VM: $($script:Config.VMName) (State: $($vm.State))" "目标虚拟机: $($script:Config.VMName) (状态: $($vm.State))"

    if ($vm.Generation -ne 2) { throw "ERROR: VM must be Generation 2. / 错误：虚拟机必须是第二代。" }
    Write-Bilingual "Generation 2 VM confirmed." "第二代虚拟机已确认。" "Success"

    try {
        $vmVer = [Version]$vm.Version
        if ($vmVer -lt [Version]"8.0") { throw "ERROR: VM version must be >= 8.0. / 错误：虚拟机版本必须 >= 8.0。" }
    } catch {
        if ($_ -match "VM version must be") { throw $_ }
        Write-Bilingual "WARNING: Could not parse VM version. Proceeding with caution." "警告：无法解析虚拟机版本，谨慎继续。" "Warning"
    }
    Write-Bilingual "VM version: $($vm.Version)" "虚拟机版本: $($vm.Version)"

    $hyperV = Get-WindowsOptionalFeature -Online | Where-Object { $_.FeatureName -eq "Microsoft-Hyper-V-All" }
    if (-not $hyperV -or $hyperV.State -ne "Enabled") { throw "ERROR: Hyper-V is not enabled. / 错误：Hyper-V未启用。" }
    Write-Bilingual "Hyper-V is enabled." "Hyper-V已启用。" "Success"

    $os = Get-CimInstance -ClassName Win32_OperatingSystem
    $build = [int]$os.BuildNumber
    if ($build -lt 19041) { throw "ERROR: Windows build $build not supported. / 错误：Windows版本 $build 不支持。" }
    $edition = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion").EditionID
    if ($edition -notmatch "Professional|Enterprise|Education") { throw "ERROR: Windows edition '$edition' not supported. / 错误：Windows版本 '$edition' 不支持。" }
    Write-Bilingual "OS: $($os.Caption) Build $build" "操作系统: $($os.Caption) 版本 $build"

    try {
        $wslOutput = wsl -l -v 2>$null
        if ($wslOutput -and $wslOutput[2].Length -gt 1) {
            Write-Bilingual "WARNING: WSL is enabled. This may cause GPU-PV error 43." "警告：WSL已启用，可能导致GPU-PV错误43。" "Warning"
        }
    } catch { }

    $enclosure = Get-CimInstance -ClassName Win32_SystemEnclosure -ErrorAction SilentlyContinue
    if ($enclosure -and ($enclosure.ChassisTypes -contains 9 -or $enclosure.ChassisTypes -contains 10 -or $enclosure.ChassisTypes -contains 14)) {
        Write-Bilingual "WARNING: Laptop detected. dGPUs may not work." "警告：检测到笔记本电脑，独立显卡可能无法工作。" "Warning"
    }
    if (Get-CimInstance -ClassName Win32_Battery -ErrorAction SilentlyContinue) {
        Write-Bilingual "WARNING: Battery detected (laptop)." "警告：检测到电池（笔记本电脑）。" "Warning"
    }

    # Detect partitionable GPUs
    Write-Bilingual "Detecting partitionable GPUs..." "正在检测可分区GPU..."
    $partitionableGPUs = Get-WmiObject -Class "Msvm_PartitionableGpu" -ComputerName $env:COMPUTERNAME -Namespace "ROOT\virtualization\v2"
    if (-not $partitionableGPUs) { throw "ERROR: No partitionable GPU found. / 错误：未找到可分区GPU。" }

    $gpuList = @()
    foreach ($pgpu in $partitionableGPUs) {
        $gpuParse = $pgpu.Name.Split('#')[1]
        $driver = Get-WmiObject Win32_PNPSignedDriver | Where-Object { $_.HardwareID -eq "PCI\$gpuParse" } | Select-Object -First 1
        if ($driver) {
            $gpuList += [PSCustomObject]@{
                Name = $driver.DeviceName; IsNvidia = $driver.DeviceName -match 'NVIDIA|GeForce|RTX|Quadro'; HardwareID = $gpuParse
            }
        }
    }
    if ($gpuList.Count -eq 0) { throw "ERROR: Could not resolve GPU names. / 错误：无法解析GPU名称。" }

    Write-Host ""; Write-Host "Available Partitionable GPUs / 可用的可分区GPU:" -ForegroundColor Cyan
    for ($i = 0; $i -lt $gpuList.Count; $i++) {
        $tag = if ($gpuList[$i].IsNvidia) { " [RECOMMENDED / 推荐]" } else { "" }
        Write-Host "  [$($i+1)] $($gpuList[$i].Name)$tag"
    }

    $nvidiaGpu = $gpuList | Where-Object { $_.IsNvidia } | Select-Object -First 1
    if ($script:Config.GPUName -eq "AUTO") {
        if ($nvidiaGpu) { $script:Config.GPUName = $nvidiaGpu.Name }
        else { $script:Config.GPUName = $gpuList[0].Name }
        Write-Bilingual "Auto-selected GPU: $($script:Config.GPUName)" "自动选择GPU: $($script:Config.GPUName)" "Success"
    } else {
        $matched = $gpuList | Where-Object { $_.Name -eq $script:Config.GPUName }
        if (-not $matched) {
            Write-Bilingual "WARNING: Specified GPU not found. Please select." "警告：指定的GPU未找到，请选择。" "Warning"
            [int]$choice = 0
            while ($choice -lt 1 -or $choice -gt $gpuList.Count) {
                $inputStr = Read-Host "Select GPU / 选择GPU (1-$($gpuList.Count))"
                if (-not [int]::TryParse($inputStr, [ref]$choice)) { $choice = 0 }
            }
            $script:Config.GPUName = $gpuList[$choice - 1].Name
        }
    }
    Write-Bilingual "Selected GPU: $($script:Config.GPUName)" "已选择GPU: $($script:Config.GPUName)" "Success"

    # VM settings check and fix
    Write-Bilingual "Checking VM settings..." "正在检查虚拟机设置..."
    if ($vm.AutomaticCheckpointsEnabled) {
        Write-Bilingual "Fixing: Disabling automatic checkpoints..." "修复中: 禁用自动检查点..."
        if (-not $WhatIf) { Set-VM -Name $script:Config.VMName -AutomaticCheckpointsEnabled $false }
    }
    if ($vm.DynamicMemoryEnabled) {
        Write-Bilingual "Fixing: Disabling dynamic memory..." "修复中: 禁用动态内存..."
        if (-not $WhatIf) { Set-VM -Name $script:Config.VMName -StaticMemory }
    }
    $vmHost = Get-VMHost
    if ($vmHost.EnableEnhancedSessionMode) {
        Write-Bilingual "Fixing: Disabling Enhanced Session Mode..." "修复中: 禁用增强会话模式..."
        if (-not $WhatIf) { Set-VMHost -EnableEnhancedSessionMode $false }
    }
    if (-not $WhatIf) { Set-VMGpuPartitionSettings -VMName $script:Config.VMName }

    try {
        $vmFirmware = Get-VMFirmware -VMName $script:Config.VMName
        if ($vmFirmware.SecureBoot -eq "On") {
            Write-Bilingual "WARNING: Secure Boot is enabled." "警告：安全启动已启用。" "Warning"
            $sbChoice = Read-Host "Disable Secure Boot? (Y/N) / 是否禁用安全启动? (Y/N)"
            if ($sbChoice -eq 'Y' -or $sbChoice -eq 'y') {
                if (-not $WhatIf) { Set-VMFirmware -VMName $script:Config.VMName -EnableSecureBoot Off }
                Write-Bilingual "Secure Boot disabled." "安全启动已禁用。" "Success"
            }
        }
    } catch {
        Write-Bilingual "WARNING: Could not check Secure Boot." "警告：无法检查安全启动。" "Warning"
    }

    Write-Bilingual "Phase 1 completed." "阶段1完成。" "Success"
    Save-State -CompletedStep 1
}

# ========================================================================
# Phase 2: Prepare Installation Files
# ========================================================================
function Invoke-Phase2_PrepareFiles {
    Write-StepHeader "2" "Prepare Installation Files / 准备安装文件"

    Write-Host ""; Write-Host "Select Streaming Software / 选择串流软件:" -ForegroundColor Cyan
    Write-Host "  [1] Sunshine + Virtual Display Driver (Recommended / 推荐)"
    Write-Host "  [2] Parsec + ParsecVDA"
    Write-Host "  [3] Sunshine + ParsecVDA"
    Write-Host "  [4] Parsec + Virtual Display Driver"
    Write-Host "  [5] GPU-PV Only / 仅GPU-PV"

    [int]$streamChoice = 0
    while ($streamChoice -lt 1 -or $streamChoice -gt 5) {
        $inputStr = Read-Host "Choice / 选择 (1-5)"
        if (-not [int]::TryParse($inputStr, [ref]$streamChoice)) { $streamChoice = 0 }
    }
    switch ($streamChoice) {
        1 { $script:Config.StreamingChoice = "Sunshine+VDD" }
        2 { $script:Config.StreamingChoice = "Parsec+ParsecVDA" }
        3 { $script:Config.StreamingChoice = "Sunshine+ParsecVDA" }
        4 { $script:Config.StreamingChoice = "Parsec+VDD" }
        5 { $script:Config.StreamingChoice = "None" }
    }
    Write-Bilingual "Selected: $($script:Config.StreamingChoice)" "已选择: $($script:Config.StreamingChoice)" "Success"

    # VDD Configuration
    if ($script:Config.StreamingChoice -match "VDD") {
        Write-Host ""; Write-Host "--- Virtual Display Driver Configuration / 虚拟显示驱动配置 ---" -ForegroundColor Cyan
        [int]$monitorCount = 1
        $mcInput = Read-Host "Number of virtual monitors [1-4, default 1] / 虚拟显示器数量 [1-4, 默认1]"
        if (-not [string]::IsNullOrWhiteSpace($mcInput)) {
            [int]::TryParse($mcInput, [ref]$monitorCount) | Out-Null
            if ($monitorCount -lt 1) { $monitorCount = 1 }
            if ($monitorCount -gt 4) { $monitorCount = 4 }
        }
        $resolution = "1920x1080"
        $resInput = Read-Host "Resolution [default 1920x1080] / 分辨率 [默认1920x1080]"
        if (-not [string]::IsNullOrWhiteSpace($resInput)) { $resolution = $resInput }
        [int]$refreshRate = 144
        $rrInput = Read-Host "Refresh Rate (Hz) [default 144] / 刷新率 (Hz) [默认144]"
        if (-not [string]::IsNullOrWhiteSpace($rrInput)) { [int]::TryParse($rrInput, [ref]$refreshRate) | Out-Null }
        $enableHdr = $false
        $hdrInput = Read-Host "Enable HDR? (Y/N) [default N] / 启用HDR? (Y/N) [默认N]"
        if ($hdrInput -eq 'Y' -or $hdrInput -eq 'y') { $enableHdr = $true }
        $script:Config.VDDConfig = @{ MonitorCount = $monitorCount; Resolution = $resolution; RefreshRate = $refreshRate; EnableHDR = $enableHdr; GPUFriendlyName = $script:Config.GPUName }
        Write-Bilingual "VDD config: $monitorCount monitor(s), $resolution @ ${refreshRate}Hz, HDR=$enableHdr" "VDD配置: $monitorCount 台, $resolution @ ${refreshRate}Hz, HDR=$enableHdr" "Success"
    }

    # Sunshine Configuration
    if ($script:Config.StreamingChoice -match "Sunshine") {
        Write-Host ""; Write-Host "--- Sunshine Configuration / Sunshine配置 ---" -ForegroundColor Cyan
        $suUser = Read-Host "Sunshine Web UI username [default admin] / Sunshine用户名 [默认admin]"
        if ([string]::IsNullOrWhiteSpace($suUser)) { $suUser = "admin" }
        $suPass = Read-Host "Sunshine Web UI password [default admin] / Sunshine密码 [默认admin]"
        if ([string]::IsNullOrWhiteSpace($suPass)) { $suPass = "admin" }
        $script:Config.SunshineConfig = @{ Username = $suUser; Password = $suPass }
        Write-Bilingual "Sunshine credentials set." "Sunshine凭据已设置。" "Success"
    }

    # Parsec Configuration
    if ($script:Config.StreamingChoice -match "Parsec") {
        Write-Host ""; Write-Host "--- Parsec Configuration / Parsec配置 ---" -ForegroundColor Cyan
        $teamId = Read-Host "Parsec Team ID (optional) / Parsec团队ID (可选)"
        $teamKey = Read-Host "Parsec Team Key (optional) / Parsec团队密钥 (可选)"
        $script:Config.ParsecConfig = @{ TeamID = $teamId; TeamKey = $teamKey }
    }

    # Download installation files
    Write-Host ""; Write-Bilingual "Preparing installation files..." "正在准备安装文件..."
    $downloadDir = Join-Path $scriptRoot "Downloads"
    if (-not (Test-Path $downloadDir)) { New-Item -ItemType Directory -Path $downloadDir -Force | Out-Null }

    function Get-InstallerFile {
        param([string]$Name, [string]$Url, [string]$FileName)
        $localPath = Join-Path $downloadDir $FileName
        if (Test-Path $localPath) { Write-Bilingual "$Name found locally." "$Name 已在本地。" "Success"; return $localPath }
        Write-Bilingual "Downloading $Name..." "正在下载 $Name..."
        try {
            Invoke-WebRequest -Uri $Url -OutFile $localPath -UseBasicParsing -ErrorAction Stop
            Write-Bilingual "$Name downloaded." "$Name 下载完成。" "Success"; return $localPath
        } catch {
            Write-Bilingual "Failed to download $Name." "下载 $Name 失败。" "Warning"
            Write-Host "  URL: $Url" -ForegroundColor Cyan
            $manualPath = Read-Host "Local path / 本地文件路径 (or Enter to skip)"
            if (-not [string]::IsNullOrWhiteSpace($manualPath) -and (Test-Path $manualPath)) { return $manualPath }
            return $null
        }
    }

    if ($script:Config.StreamingChoice -match "Sunshine") { $script:Config.InstallFilePaths.Sunshine = Get-InstallerFile "Sunshine" $script:DownloadUrls.Sunshine "sunshine-windows-installer.exe" }
    if ($script:Config.StreamingChoice -match "Parsec") { $script:Config.InstallFilePaths.Parsec = Get-InstallerFile "Parsec" $script:DownloadUrls.Parsec "parsec-windows.exe" }
    if ($script:Config.StreamingChoice -match "ParsecVDA") { $script:Config.InstallFilePaths.ParsecVDA = Get-InstallerFile "ParsecVDA" $script:DownloadUrls.ParsecVDA "ParsecVDA-setup.exe" }
    if ($script:Config.StreamingChoice -match "VDD") {
        $vdmPath = Join-Path $downloadDir "virtual-driver-manager.ps1"
        if (Test-Path $vdmPath) { $script:Config.InstallFilePaths.VDDManager = $vdmPath }
        else {
            try {
                Invoke-WebRequest -Uri $script:DownloadUrls.VDDManagerScript -OutFile $vdmPath -UseBasicParsing
                $script:Config.InstallFilePaths.VDDManager = $vdmPath
            } catch { Write-Bilingual "Failed to download VDD manager script." "下载VDD管理脚本失败。" "Warning" }
        }
        # FIX: Read VDD manager script content so it can be passed into the VM via Invoke-ArgumentList
        if ($script:Config.InstallFilePaths.VDDManager -and (Test-Path $script:Config.InstallFilePaths.VDDManager)) {
            $script:Config.VDDManagerContent = Get-Content -Path $script:Config.InstallFilePaths.VDDManager -Raw -Encoding UTF8
        }
    }
    if ($script:Config.StreamingChoice -ne "None") { $script:Config.InstallFilePaths.VBCable = Get-InstallerFile "VB-Cable" $script:DownloadUrls.VBCable "VBCABLE_Driver_Pack43.zip" }

    Write-Bilingual "Phase 2 completed." "阶段2完成。" "Success"
    Save-State -CompletedStep 2
}

# ========================================================================
# Phase 3: Cleanup VM Residuals
# ========================================================================
function Invoke-Phase3_CleanupVM {
    Write-StepHeader "3" "Cleanup VM Residuals / 清理虚拟机残留"

    $vm = Get-VM -Name $script:Config.VMName -ErrorAction Stop
    $script:Config.WasRunning = ($vm.State -eq 'Running')

    if ($vm.State -ne 'Off') {
        Write-Bilingual "Shutting down VM..." "正在关闭虚拟机..."
        if (-not $WhatIf) {
            Stop-VM -Name $script:Config.VMName -Force
            $shutdownTimeout = 180; $shutdownElapsed = 0
            while (((Get-VM -Name $script:Config.VMName).State -ne 'Off') -and ($shutdownElapsed -lt $shutdownTimeout)) { Start-Sleep -Seconds 3; $shutdownElapsed += 3; Write-Bilingual "Waiting..." "等待中..." }
            if ((Get-VM -Name $script:Config.VMName).State -ne 'Off') { Write-Bilingual "VM shutdown timeout ($shutdownTimeout s)." "虚拟机关机超时 ($shutdownTimeout 秒)。" "Warning" }
        }
    }

    # Remove GPU-PV adapter
    $adapter = Get-VMGpuPartitionAdapter -VMName $script:Config.VMName -ErrorAction SilentlyContinue
    if ($adapter) {
        Write-Bilingual "Removing GPU-PV adapter..." "正在移除GPU-PV适配器..."
        if (-not $WhatIf) { Get-VMGpuPartitionAdapter -VMName $script:Config.VMName | Remove-VMGpuPartitionAdapter }
    } else { Write-Bilingual "No GPU-PV adapter found." "未找到GPU-PV适配器。" }

    # Mount VHDX for file-level cleanup
    Write-Bilingual "Mounting VHDX for cleanup..." "正在挂载VHDX进行清理..."
    $vhd = Get-VHD -VMId $vm.VMId | Select-Object -First 1
    if (-not $vhd) { throw "ERROR: Could not find VHDX. / 错误：无法找到VHDX。" }

    $mountedVHD = $null; $driveLetter = $null
    try {
        if (-not $WhatIf) {
            $mountedVHD = Mount-VHD -Path $vhd.Path -PassThru
            $driveLetter = ($mountedVHD | Get-Disk | Get-Partition | Get-Volume | Where-Object { $_.DriveLetter } | Select-Object -First 1).DriveLetter
            if (-not $driveLetter) { throw "ERROR: Could not get drive letter. / 错误：无法获取盘符。" }
            $driveLetter = "$driveLetter`:"
        } else { $driveLetter = "X:" }
        Write-Bilingual "VHDX mounted at $driveLetter" "VHDX已挂载到 $driveLetter"

        # Detect residuals
        $residualIndicators = @("nvapi64.dll","nvlddmkm.sys","nvcuda.dll","nvapi.dll","amdkmdag.sys","amdkmdap.sys","atikmdag.sys","aticfx64.dll","igdkmd64.sys","igfxEM.exe","igfxHK.exe","igd10iumd64.dll")
        $hasResidual = $false
        foreach ($ind in $residualIndicators) { if (Test-Path "$driveLetter\Windows\System32\$ind") { $hasResidual = $true; Write-Bilingual "Found residual: $ind" "发现残留: $ind" "Warning" } }

        if ($hasResidual -or $ForceReinstallVDD) {
            Write-Bilingual "Performing deep clean..." "正在深度清理..."
            if (-not $WhatIf) { Remove-VMGpuPartitionAdapterFiles -DriveLetter $driveLetter -GPUName $script:Config.GPUName -DeepClean }
        } else {
            Write-Bilingual "Safe cleanup..." "安全清理..."
            if (-not $WhatIf) { Remove-VMGpuPartitionAdapterFiles -DriveLetter $driveLetter -GPUName "AUTO" }
        }

        # Backup VDD config if exists
        $vddConfigPath = "$driveLetter\VirtualDisplayDriver\vdd_settings.xml"
        if (Test-Path $vddConfigPath) {
            Write-Bilingual "Backing up VDD config..." "正在备份VDD配置..."
            $script:Config.VDDConfig.BackupXml = Get-Content -Path $vddConfigPath -Raw -Encoding UTF8
        }

        # Disable virtual display adapters via registry
        Write-Bilingual "Disabling virtual display adapters..." "正在禁用虚拟显示适配器..."
        if (-not $WhatIf) {
            $systemHive = "$driveLetter\Windows\System32\config\SYSTEM"
            $tempHive = "VMGPUPV$(Get-Random)"
            $regLoadResult = reg load "HKLM\$tempHive" $systemHive 2>&1
            if ($LASTEXITCODE -ne 0) {
                Write-Bilingual "WARNING: Could not load SYSTEM hive ($regLoadResult). Virtual adapters not disabled." "警告：无法加载 SYSTEM 注册表配置单元 ($regLoadResult)，虚拟适配器未禁用。" "Warning"
            } else {
                try {
                    $servicesToDisable = @("RdpVideoMiniport","hypervideo","BasicDisplay")
                    foreach ($svc in $servicesToDisable) {
                        $svcPath = "HKLM:\$tempHive\ControlSet001\Services\$svc"
                        if (Test-Path $svcPath) { Set-ItemProperty -Path $svcPath -Name "Start" -Value 4 -ErrorAction SilentlyContinue; Write-Bilingual "Disabled: $svc" "已禁用: $svc" }
                    }
                } finally { [gc]::Collect(); [gc]::WaitForPendingFinalizers(); reg unload "HKLM\$tempHive" | Out-Null }
            }
        }
    } finally {
        if ($mountedVHD) { Write-Bilingual "Dismounting VHDX..." "正在卸载VHDX..."; Dismount-VHD -Path $vhd.Path }
    }

    Write-Bilingual "Phase 3 completed." "阶段3完成。" "Success"
    Save-State -CompletedStep 3
}

# ========================================================================
# Phase 4: VM Config Check & Fix
# ========================================================================
function Invoke-Phase4_VMConfigFix {
    Write-StepHeader "4" "VM Config Check & Fix / 虚拟机配置检查与修复"
    $vm = Get-VM -Name $script:Config.VMName -ErrorAction Stop
    if ($vm.State -ne 'Off') {
        Write-Bilingual "VM not off. Shutting down..." "虚拟机未关闭，正在关机..."
        if (-not $WhatIf) { Stop-VM -Name $script:Config.VMName -Force; $shutdownTimeout = 180; $shutdownElapsed = 0; while (((Get-VM -Name $script:Config.VMName).State -ne 'Off') -and ($shutdownElapsed -lt $shutdownTimeout)) { Start-Sleep -Seconds 3; $shutdownElapsed += 3 } }
    }
    $vm = Get-VM -Name $script:Config.VMName
    $issues = @()
    if ($vm.DynamicMemoryEnabled) { $issues += "Dynamic Memory" }
    if ($vm.AutomaticCheckpointsEnabled) { $issues += "Auto Checkpoints" }
    $vmHost = Get-VMHost
    if ($vmHost.EnableEnhancedSessionMode) { $issues += "Enhanced Session" }
    if ($issues.Count -gt 0) {
        Write-Bilingual "Fixing: $($issues -join ', ')" "修复: $($issues -join ', ')" "Warning"
        if (-not $WhatIf) { Set-VM -Name $script:Config.VMName -StaticMemory -AutomaticCheckpointsEnabled $false; Set-VMHost -EnableEnhancedSessionMode $false }
    } else { Write-Bilingual "VM settings OK." "虚拟机设置正常。" "Success" }
    Write-Bilingual "Applying GPU-PV settings..." "正在应用GPU-PV设置..."
    if (-not $WhatIf) { Set-VMGpuPartitionSettings -VMName $script:Config.VMName }
    Write-Bilingual "Phase 4 completed." "阶段4完成。" "Success"
    Save-State -CompletedStep 4
}

# ========================================================================
# Phase 5: Configure GPU-PV
# ========================================================================
function Invoke-Phase5_ConfigureGpuPV {
    Write-StepHeader "5" "Configure GPU-PV / 配置GPU-PV"
    $vm = Get-VM -Name $script:Config.VMName -ErrorAction Stop
    if ($vm.State -ne 'Off') {
        Write-Bilingual "Shutting down VM..." "正在关闭虚拟机..."
        if (-not $WhatIf) { Stop-VM -Name $script:Config.VMName -Force; $shutdownTimeout = 180; $shutdownElapsed = 0; while (((Get-VM -Name $script:Config.VMName).State -ne 'Off') -and ($shutdownElapsed -lt $shutdownTimeout)) { Start-Sleep -Seconds 3; $shutdownElapsed += 3; Write-Bilingual "Waiting..." "等待中..." } }
    }
    $vhd = Get-VHD -VMId $vm.VMId | Select-Object -First 1
    $mountedVHD = $null
    try {
        if (-not $WhatIf) {
            $mountedVHD = Mount-VHD -Path $vhd.Path -PassThru
            $driveLetter = ($mountedVHD | Get-Disk | Get-Partition | Get-Volume | Where-Object { $_.DriveLetter } | Select-Object -First 1).DriveLetter
            if (-not $driveLetter) { throw "ERROR: Could not mount VHDX. / 错误：无法挂载VHDX。" }
            $driveLetter = "$driveLetter`:"
        } else { $driveLetter = "X:" }
        Write-Bilingual "Copying GPU drivers..." "正在复制GPU驱动..."
        if (-not $WhatIf) { Add-VMGpuPartitionAdapterFiles -DriveLetter $driveLetter -GPUName $script:Config.GPUName }
        Write-Bilingual "GPU drivers copied." "GPU驱动已复制。" "Success"
    } finally { if ($mountedVHD) { Dismount-VHD -Path $vhd.Path } }

    Write-Bilingual "Attaching GPU-PV adapter..." "正在附加GPU-PV适配器..."
    if (-not $WhatIf) { Assign-VMGPUPartitionAdapter -VMName $script:Config.VMName -GPUName $script:Config.GPUName -GPUResourceAllocationPercentage $script:Config.GPUAllocation }
    Write-Bilingual "GPU-PV adapter attached." "GPU-PV适配器已附加。" "Success"

    if ($script:Config.WasRunning -or $script:Config.StreamingChoice -ne "None") {
        Write-Bilingual "Starting VM..." "正在启动虚拟机..."
        if (-not $WhatIf) {
            Start-VM -Name $script:Config.VMName
            Write-Bilingual "Waiting for VM boot (up to 2 min)..." "等待虚拟机启动（最多2分钟）..."
            $ready = $false; $elapsed = 0
            while ($elapsed -lt 120 -and -not $ready) {
                Start-Sleep -Seconds 5; $elapsed += 5
                try { $hb = Invoke-Command -VMName $script:Config.VMName -ScriptBlock { $true } -ErrorAction SilentlyContinue; if ($hb -eq $true) { $ready = $true } } catch { }
            }
            if (-not $ready) { Write-Bilingual "WARNING: Boot timeout. Ensure VM is responsive." "警告：启动超时，请确保虚拟机响应正常。" "Warning" }
            else { Write-Bilingual "VM is ready." "虚拟机已就绪。" "Success" }
        }
    }
    Write-Bilingual "Phase 5 completed." "阶段5完成。" "Success"
    Save-State -CompletedStep 5
}

# ========================================================================
# Phase 6: Install Streaming Software
# ========================================================================
# SECURITY NOTE: This phase contains patterns that trigger antivirus heuristics:
#   - Invoke-WebRequest inside Invoke-Command -VMName ScriptBlock (lines ~596, ~607)
#   - [System.IO.File]::WriteAllBytes inside ScriptBlock (lines ~670, ~708)
#   - Start-Process with /install /quiet /norestart or /S flags
# These are legitimate operations for VM software installation, but they match
# the behavioral signature of TrojanDownloader/PS.NetLoader.av.
# ========================================================================
function Invoke-Phase6_InstallSoftware {
    Write-StepHeader "6" "Install Streaming Software / 安装串流软件"
    if ($script:Config.StreamingChoice -eq "None") {
        Write-Bilingual "No streaming software selected. Skipping." "未选择串流软件，跳过。"
        Save-State -CompletedStep 6; return
    }

    # Get credentials
    if (-not $script:Credential) {
        if ($CredentialUserName -and $CredentialPassword) {
            $script:Credential = New-Object System.Management.Automation.PSCredential($CredentialUserName, $CredentialPassword)
        } else {
            $defaultUser = if ($CredentialUserName) { $CredentialUserName } else { "Administrator" }
            $script:Credential = Get-Credential -Message "Enter VM '$($script:Config.VMName)' credentials / 输入VM凭据" -UserName $defaultUser
        }
    }

    # Test PowerShell Direct
    Write-Bilingual "Testing PowerShell Direct..." "正在测试PowerShell Direct..."
    $psDirectOk = $false
    try {
        $testResult = Invoke-Command -VMName $script:Config.VMName -Credential $script:Credential -ScriptBlock { @{ ComputerName = $env:COMPUTERNAME; UserName = $env:USERNAME } } -ErrorAction Stop
        Write-Bilingual "Connected to $($testResult.ComputerName) as $($testResult.UserName)" "已连接到 $($testResult.ComputerName)，用户 $($testResult.UserName)" "Success"
        $psDirectOk = $true
    } catch {
        Write-Bilingual "PowerShell Direct failed: $_" "PowerShell Direct失败: $_" "Error"
        throw "PowerShell Direct not available. Please ensure VM is running and credentials are correct. / PowerShell Direct不可用，请确保虚拟机正在运行且凭据正确。"
    }
    if (-not $psDirectOk) { return }

    # Install VDD (new version)
    if ($script:Config.StreamingChoice -match "VDD" -and -not $UseLegacyVDD) {
        Write-Bilingual "Installing Virtual Display Driver..." "正在安装虚拟显示驱动..."
        if (-not $WhatIf) {
            Invoke-Command -VMName $script:Config.VMName -Credential $script:Credential -ScriptBlock {
                param($GpuFriendlyName, $Resolution, $RefreshRate, $EnableHdr, $MonitorCount, $VDDManagerContent, $VCRedistUrl)

                # Install VC++ Redistributable
                # AV TRIGGER: Invoke-WebRequest → $env:TEMP → Start-Process /install /quiet
                $vcInstalled = Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64' -ErrorAction SilentlyContinue
                if (-not $vcInstalled) {
                    Write-Host "Installing VC++ Redistributable..." -ForegroundColor Cyan
                    $vcPath = "$env:TEMP\vc_redist.x64.exe"
                    Invoke-WebRequest -Uri $VCRedistUrl -OutFile $vcPath -UseBasicParsing
                    Start-Process $vcPath -ArgumentList "/install","/quiet","/norestart" -Wait
                    Write-Host "VC++ installed." -ForegroundColor Green
                }

                # Install VDD
                # FIX: Receive script content from host via ArgumentList, write to VM temp, then execute.
                if ($VDDManagerContent) {
                    Write-Host "Installing VDD via local manager..." -ForegroundColor Cyan
                    $vdmPath = "$env:TEMP\virtual-driver-manager.ps1"
                    Set-Content -Path $vdmPath -Value $VDDManagerContent -Encoding UTF8
                    & $vdmPath -Action install -Silent
                } else {
                    # AV TRIGGER: Invoke-WebRequest → $env:TEMP → execute script
                    Write-Host "Downloading VDD manager..." -ForegroundColor Cyan
                    $vdmUrl = "https://raw.githubusercontent.com/VirtualDrivers/Virtual-Display-Driver/master/Community%20Scripts/virtual-driver-manager.ps1"
                    $vdmPath = "$env:TEMP\virtual-driver-manager.ps1"
                    Invoke-WebRequest -Uri $vdmUrl -OutFile $vdmPath -UseBasicParsing
                    & $vdmPath -Action install -Silent
                }

                # Verify
                $vdm = "$env:TEMP\virtual-driver-manager.ps1"
                $status = if (Test-Path $vdm) { & $vdm -Action status -Json 2>$null | ConvertFrom-Json } else { $null }
                if (-not $status -or -not $status.installed) {
                    $dev = Get-PnpDevice -Class Display | Where-Object { $_.FriendlyName -match 'Virtual Display Driver|IddSampleDriver' }
                    if (-not $dev) { throw "VDD installation verification failed." }
                }
                Write-Host "VDD installed." -ForegroundColor Green

                # Write vdd_settings.xml
                $vddDir = "C:\VirtualDisplayDriver"
                if (-not (Test-Path $vddDir)) { New-Item -ItemType Directory -Path $vddDir -Force | Out-Null }
                $hdrStr = if ($EnableHdr) { "true" } else { "false" }
                $w = $Resolution.Split('x')[0]; $h = $Resolution.Split('x')[1]
                $escapedGpuName = $GpuFriendlyName -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;' -replace '"', '&quot;'
                $xml = @"
<?xml version='1.0' encoding='utf-8'?>
<vdd_settings>
  <monitors><count>$MonitorCount</count></monitors>
  <gpu><friendlyname>$escapedGpuName</friendlyname></gpu>
  <global><g_refresh_rate>$RefreshRate</g_refresh_rate></global>
  <resolutions>
    <resolution><width>$w</width><height>$h</height><refresh_rate>$RefreshRate</refresh_rate></resolution>
  </resolutions>
  <logging><SendLogsThroughPipe>true</SendLogsThroughPipe><enabled>true</enabled></logging>
  <colour><SDR10bit>false</SDR10bit><HDRPlus>$hdrStr</HDRPlus><ColourFormat>RGB</ColourFormat></colour>
  <cursor><HardwareCursor>true</HardwareCursor></cursor>
  <edid><CustomEdid>false</CustomEdid></edid>
  <edid_integration><enabled>false</enabled></edid_integration>
  <auto_resolutions><enabled>false</enabled><source_priority>manual</source_priority></auto_resolutions>
  <color_advanced><bit_depth_management><auto_select_from_color_space>true</auto_select_from_color_space><fp16_surface_support>true</fp16_surface_support></bit_depth_management></color_advanced>
</vdd_settings>
"@
                Set-Content -Path "$vddDir\vdd_settings.xml" -Value $xml -Encoding UTF8
                Write-Host "VDD config written." -ForegroundColor Green

                # Activate via toggle
                if (Test-Path $vdm) { & $vdm -Action toggle -Silent | Out-Null; Start-Sleep -Seconds 3; & $vdm -Action toggle -Silent | Out-Null }
                else {
                    $dev = Get-PnpDevice -Class Display | Where-Object { $_.FriendlyName -match 'Virtual Display Driver|IddSampleDriver' }
                    if ($dev) { $dev | Disable-PnpDevice -Confirm:$false | Out-Null; Start-Sleep -Seconds 2; $dev | Enable-PnpDevice -Confirm:$false | Out-Null }
                }
                Write-Host "VDD activated on GPU: $GpuFriendlyName" -ForegroundColor Green
            } -ArgumentList $script:Config.GPUName, $script:Config.VDDConfig.Resolution, $script:Config.VDDConfig.RefreshRate, $script:Config.VDDConfig.EnableHDR, $script:Config.VDDConfig.MonitorCount, $script:Config.VDDManagerContent, $script:DownloadUrls.VCRedist
        }
        Write-Bilingual "VDD installation completed." "VDD安装完成。" "Success"
    }

    # Install Sunshine
    if ($script:Config.StreamingChoice -match "Sunshine") {
        Write-Bilingual "Installing Sunshine..." "正在安装Sunshine..."
        $sunshinePath = $script:Config.InstallFilePaths.Sunshine
        if (-not $sunshinePath -or -not (Test-Path $sunshinePath)) { throw "Sunshine installer not found. / Sunshine安装文件未找到。" }
        if (-not $WhatIf) {
            # AV TRIGGER: ReadAllBytes on host → WriteAllBytes in VM → Start-Process /S
            $sunshineBytes = [System.IO.File]::ReadAllBytes($sunshinePath)
            Invoke-Command -VMName $script:Config.VMName -Credential $script:Credential -ScriptBlock {
                param($Bytes)
                $path = "$env:TEMP\sunshine-installer.exe"
                [System.IO.File]::WriteAllBytes($path, $Bytes)
                Start-Process $path -ArgumentList "/S" -Wait
                Write-Host "Sunshine installed." -ForegroundColor Green
            } -ArgumentList (,$sunshineBytes)

            Invoke-Command -VMName $script:Config.VMName -Credential $script:Credential -ScriptBlock {
                # Start service and open firewall
                # Start the Sunshine service (auto-detect actual name) / 启动 Sunshine 服务（自动检测实际名称）
                $sunshineSvcName = "SunshineService"
                if (-not (Get-Service -Name $sunshineSvcName -ErrorAction SilentlyContinue)) { $sunshineSvcName = "Sunshine" }
                Start-Service -Name $sunshineSvcName -ErrorAction SilentlyContinue
                # Idempotent firewall rules incl. UDP (create only if absent) / 幂等防火墙规则，含 UDP（仅在不存在时创建）
                $sunshineRules = @{
                    "Sunshine-HTTP"  = @{ Protocol = "TCP"; LocalPort = "47989" }
                    "Sunshine-HTTPS" = @{ Protocol = "TCP"; LocalPort = "47984,47990" }
                    "Sunshine-RTSP"  = @{ Protocol = "TCP"; LocalPort = "48010" }
                    "Sunshine-UDP"   = @{ Protocol = "UDP"; LocalPort = "47998,47999,48000,48002,48010" }
                }
                foreach ($ruleName in $sunshineRules.Keys) {
                    if (-not (Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue)) {
                        $r = $sunshineRules[$ruleName]
                        New-NetFirewallRule -DisplayName $ruleName -Direction Inbound -LocalPort $r.LocalPort -Protocol $r.Protocol -Action Allow -Enabled True -ErrorAction SilentlyContinue | Out-Null
                    }
                }
                Write-Host "Sunshine configured." -ForegroundColor Green
            }
        }
        Write-Bilingual "Sunshine installation completed." "Sunshine安装完成。" "Success"
    }

    # Parsec installation (placeholder - expand if needed)
    if ($script:Config.StreamingChoice -match "Parsec") {
        Write-Bilingual "Parsec installation..." "Parsec安装..."
        Write-Bilingual "Parsec install not fully implemented in this version." "Parsec安装在此版本中未完全实现。" "Warning"
    }

    # ParsecVDA installation (placeholder)
    if ($script:Config.StreamingChoice -match "ParsecVDA") {
        Write-Bilingual "ParsecVDA installation..." "ParsecVDA安装..."
        Write-Bilingual "ParsecVDA install not fully implemented in this version." "ParsecVDA安装在此版本中未完全实现。" "Warning"
    }

    # VB-Cable
    if ($script:Config.InstallFilePaths.VBCable) {
        Write-Bilingual "Installing VB-Audio Virtual Cable..." "正在安装VB-Audio虚拟声卡..."
        $vbcPath = $script:Config.InstallFilePaths.VBCable
        if (Test-Path $vbcPath -and -not $WhatIf) {
            # AV TRIGGER: ReadAllBytes on host → WriteAllBytes in VM → Expand-Archive → execute
            $vbcBytes = [System.IO.File]::ReadAllBytes($vbcPath)
            Invoke-Command -VMName $script:Config.VMName -Credential $script:Credential -ScriptBlock {
                param($ZipBytes)
                $zipPath = "$env:TEMP\vbcable.zip"
                [System.IO.File]::WriteAllBytes($zipPath, $ZipBytes)
                Expand-Archive -Path $zipPath -DestinationPath "$env:TEMP\VBCable" -Force
                $setup = Get-ChildItem -Path "$env:TEMP\VBCable" -Filter "VBCABLE_Setup_x64.exe" -Recurse | Select-Object -First 1
                if ($setup) { Start-Process $setup.FullName -ArgumentList "-i","-h" -Wait; Write-Host "VB-Cable installed." -ForegroundColor Green }
            } -ArgumentList (,$vbcBytes)
        }
    }

    # VM optimizations
    Write-Bilingual "Applying VM optimizations..." "正在应用虚拟机优化..."
    if (-not $WhatIf) {
        Invoke-Command -VMName $script:Config.VMName -Credential $script:Credential -ScriptBlock {
            Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" -Name "OneDrive" -Value "" -ErrorAction SilentlyContinue
            powercfg.exe /change monitor-timeout-ac 0; powercfg.exe /change monitor-timeout-dc 0
            powercfg.exe /change standby-timeout-ac 0; powercfg.exe /change standby-timeout-dc 0
            Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name "fDenyTSConnections" -Value 0 -Force
            Enable-NetFirewallRule -DisplayGroup "Remote Desktop" -ErrorAction SilentlyContinue
            $rdpRule = Get-NetFirewallRule -DisplayName "RDP-TCP-In" -ErrorAction SilentlyContinue
            if (-not $rdpRule) { New-NetFirewallRule -DisplayName "RDP-TCP-In" -Direction Inbound -LocalPort 3389 -Protocol TCP -Action Allow -Enabled True | Out-Null }
            Write-Host "VM optimizations applied." -ForegroundColor Green
        }
    }
    Write-Bilingual "Phase 6 completed." "阶段6完成。" "Success"
    Save-State -CompletedStep 6
}

# ========================================================================
# Phase 7: Final Verification & Output
# ========================================================================
function Invoke-Phase7_VerifyOutput {
    Write-StepHeader "7" "Final Verification / 最终验证"
    if (-not $WhatIf) {
        Write-Bilingual "Verifying GPU-PV status..." "正在验证GPU-PV状态..."
        $adapter = Get-VMGpuPartitionAdapter -VMName $script:Config.VMName -ErrorAction SilentlyContinue
        if ($adapter) { Write-Bilingual "GPU-PV adapter attached." "GPU-PV适配器已附加。" "Success" }
        else { Write-Bilingual "WARNING: GPU-PV adapter not found." "警告：未找到GPU-PV适配器。" "Warning" }

        $vmIP = $null
        try {
            $vmIP = Invoke-Command -VMName $script:Config.VMName -Credential $script:Credential -ScriptBlock {
                (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } | Select-Object -First 1).IPAddress
            } -ErrorAction SilentlyContinue
        } catch { }

        $vddStatus = "Not installed"
        if ($script:Config.StreamingChoice -match "VDD" -and -not $UseLegacyVDD) {
            try {
                $hasVDD = Invoke-Command -VMName $script:Config.VMName -Credential $script:Credential -ScriptBlock {
                    $dev = Get-PnpDevice -Class Display | Where-Object { $_.FriendlyName -match 'Virtual Display Driver|IddSampleDriver' }
                    return ($null -ne $dev)
                } -ErrorAction SilentlyContinue
                $vddStatus = if ($hasVDD) { "Installed" } else { "Not detected" }
            } catch { $vddStatus = "Verify failed" }
        }

        $sunshineStatus = "Not installed"
        if ($script:Config.StreamingChoice -match "Sunshine") {
            try {
                $svc = Invoke-Command -VMName $script:Config.VMName -Credential $script:Credential -ScriptBlock { Get-Service | Where-Object { $_.Name -match 'Sunshine|sunshine' } | Select-Object -First 1 } -ErrorAction SilentlyContinue
                $sunshineStatus = if ($svc -and $svc.Status -eq 'Running') { "Running" } else { "Installed" }
            } catch { $sunshineStatus = "Verify failed" }
        }

        Write-Host ""; Write-Host "========================================" -ForegroundColor Green
        Write-Host "GPU-PV Configuration Complete Report" -ForegroundColor Green
        Write-Host "GPU-PV 配置完成报告" -ForegroundColor Green
        Write-Host "========================================" -ForegroundColor Green
        Write-Host "VM Name / 虚拟机名称: $($script:Config.VMName)"
        Write-Host "GPU / 显卡: $($script:Config.GPUName) ($($script:Config.GPUAllocation)%)"
        Write-Host ""
        Write-Host "[Display Output / 显示输出]"
        if ($script:Config.StreamingChoice -match "VDD") {
            Write-Host "  Virtual Display Driver: $vddStatus"
            Write-Host "  Resolution: $($script:Config.VDDConfig.Resolution)"
            Write-Host "  Refresh Rate: $($script:Config.VDDConfig.RefreshRate)Hz"
            Write-Host "  HDR: $($script:Config.VDDConfig.EnableHDR)"
        }
        Write-Host ""
        Write-Host "[Streaming / 串流]"
        Write-Host "  Software: $($script:Config.StreamingChoice)"
        if ($script:Config.StreamingChoice -match "Sunshine") { Write-Host "  Sunshine: $sunshineStatus" }
        Write-Host ""
        Write-Host "[Connection / 连接]"
        if ($vmIP) {
            Write-Host "  VM IP: $vmIP"
            if ($script:Config.StreamingChoice -match "Sunshine") {
                Write-Host "  Sunshine Web UI: https://$($vmIP):47990"
                Write-Host "  Sunshine Username: $($script:Config.SunshineConfig.Username)"
                Write-Host "  Sunshine Password: $($script:Config.SunshineConfig.Password)"
                Write-Host "  Moonlight: $vmIP"
            }
            Write-Host "  RDP: $vmIP`:3389"
        } else { Write-Host "  VM IP: Could not determine" }
        Write-Host ""
        Write-Host "[Notes / 注意事项]"
        Write-Host "  - RDP may black screen. Use Moonlight/Sunshine."
        Write-Host "  - RDP可能黑屏，请使用Moonlight/Sunshine。"
        Write-Host "  - After host GPU driver updates, re-run with -ForceReinstallVDD."
        Write-Host "  - 宿主机更新GPU驱动后，请使用 -ForceReinstallVDD 重新运行。"
        Write-Host "  - Change default Sunshine password after first use."
        Write-Host "  - 首次使用后请立即修改Sunshine默认密码。"
        Write-Host "========================================" -ForegroundColor Green
    }
    Write-Bilingual "Phase 7 completed." "阶段7完成。" "Success"
    Save-State -CompletedStep 7
}

# ========================================================================
# Main Execution Flow
# ========================================================================
function Start-MainFlow {
    $stateExists = Import-State
    if ($ResetState) { Clear-State; $script:StateData = @{ CompletedSteps = @() }; $stateExists = $false }

    $startStep = $StartFromStep
    if ($startStep -eq 0 -and $stateExists) {
        $completed = $script:StateData.CompletedSteps
        if ($completed.Count -gt 0) {
            $lastCompleted = ($completed | Measure-Object -Maximum).Maximum
            Write-Host ""; Write-Host "Previous run detected. Last completed: $lastCompleted" -ForegroundColor Yellow
            Write-Host "检测到之前的运行记录。最后完成: $lastCompleted" -ForegroundColor Yellow
            $continueChoice = Read-Host "Continue from step $($lastCompleted + 1)? (Y/N) / 从阶段 $($lastCompleted + 1) 继续? (Y/N)"
            if ($continueChoice -eq 'Y' -or $continueChoice -eq 'y') { $startStep = $lastCompleted + 1 } else { $startStep = 1 }
        } else { $startStep = 1 }
    } elseif ($startStep -eq 0) { $startStep = 1 }

    Write-Host ""; Write-Host "Starting from Phase $startStep / 从阶段 $startStep 开始" -ForegroundColor Cyan

    for ($step = $startStep; $step -le 7; $step++) {
        if (Test-StepCompleted -Step $step) { Write-Bilingual "Phase $step already completed. Skipping." "阶段 $step 已完成，跳过。" "Success"; continue }
        switch ($step) {
            1 { if (-not $SkipHostChecks) { Invoke-Phase1_HostChecks } else { Write-Bilingual "Skipping Phase 1." "跳过阶段1。" "Warning"; Save-State -CompletedStep 1 } }
            2 { Invoke-Phase2_PrepareFiles }
            3 { if (-not $SkipCleanup) { Invoke-Phase3_CleanupVM } else { Write-Bilingual "Skipping Phase 3." "跳过阶段3。" "Warning"; Save-State -CompletedStep 3 } }
            4 { Invoke-Phase4_VMConfigFix }
            5 { Invoke-Phase5_ConfigureGpuPV }
            6 { Invoke-Phase6_InstallSoftware }
            7 { Invoke-Phase7_VerifyOutput }
        }
        if ($step -lt 7) { Confirm-Continue }
    }

    Clear-State
    Write-Host ""; Write-Host "========================================" -ForegroundColor Green
    Write-Host "All phases completed successfully!" -ForegroundColor Green
    Write-Host "所有阶段已成功完成！" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green
}

# ========================================================================
# Entry Point
# ========================================================================
try {
    Start-MainFlow
} catch {
    Write-Host ""; Write-Host "========================================" -ForegroundColor Red
    Write-Host "ERROR / 错误" -ForegroundColor Red; Write-Host "========================================" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red; Write-Host ""
    Write-Host "Stack Trace:" -ForegroundColor DarkGray; Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray; Write-Host ""
    Write-Host "Resume with:" -ForegroundColor Yellow; Write-Host ".\Configure-GpuPV-ExistingVM.ps1 -VMName '$($script:Config.VMName)' -StartFromStep <phase>" -ForegroundColor Cyan
    exit 1
} finally {
    if ($script:Credential) { $script:Credential = $null; [System.GC]::Collect() }
}
