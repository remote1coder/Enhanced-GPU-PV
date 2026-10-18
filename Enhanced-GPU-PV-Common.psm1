Import-Module (Join-Path $PSScriptRoot 'GpuPV-Allocation.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'GpuPV-Workflow.psm1') -ErrorAction Stop
# Enhanced-GPU-PV-Common.psm1
# Common host-side functions for Enhanced-GPU-PV / Enhanced-GPU-PV 主机端公共函数
# Extracted from CopyFilesToVM.ps1 to enable reuse by the menu script and other modules.
# 从 CopyFilesToVM.ps1 提取，以便菜单脚本和其他模块复用。

Function Is-Administrator {
    # Check if the current session is running with Administrator privileges / 检查当前会话是否以管理员权限运行
    $CurrentUser = [Security.Principal.WindowsIdentity]::GetCurrent();
    (New-Object Security.Principal.WindowsPrincipal $CurrentUser).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
}

Function Set-VMGpuPartitionSettings {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$VMName,
        [ValidateRange(1,[long]::MaxValue)][long]$LowMemoryMappedIoSpace = 3GB,
        [ValidateRange(1,[long]::MaxValue)][long]$HighMemoryMappedIoSpace = 32GB
    )
    # A failing Hyper-V operation must terminate the caller's phase.
    Set-VM -Name $VMName -GuestControlledCacheTypes $true -LowMemoryMappedIoSpace $LowMemoryMappedIoSpace -HighMemoryMappedIoSpace $HighMemoryMappedIoSpace -ErrorAction Stop
    Write-Host 'VM GPU-PV settings applied. Runtime GPU functionality is not verified by this operation.'
}

Function Dismount-ISO {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$SourcePath)
    $path=[IO.Path]::GetFullPath($SourcePath)
    $images=@(Get-DiskImage -ImagePath $path -StorageType ISO -ErrorAction Stop)
    if($images.Count -ne 1 -or [string]::IsNullOrWhiteSpace([string]$images[0].ImagePath) -or [IO.Path]::GetFullPath([string]$images[0].ImagePath) -ine $path){throw 'ISO identity did not match the requested source.'}
    if($images[0].Attached){Dismount-DiskImage -InputObject $images[0] -ErrorAction Stop}
}

Function Get-NewDriveLetter {
    # Generate a random unused drive letter / 生成一个随机的未使用盘符
    $UsedDriveLetters = ((Get-Volume).DriveLetter) -join ""
    Do {
        $DriveLetter = (65..90) | Get-Random | ForEach-Object { [char]$_ }
    } Until (!$UsedDriveLetters.Contains("$DriveLetter"))
    $DriveLetter
}

Function Mount-ISOReliable {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$SourcePath,
          [ValidateRange(1,600)][int]$TimeoutSeconds=120)
    $path=[IO.Path]::GetFullPath($SourcePath)
    $mounted=$false
    try {
        # PassThru is required: Mount-DiskImage normally returns no image object.
        $images=@(Mount-DiskImage -ImagePath $path -StorageType ISO -PassThru -ErrorAction Stop)
        $mounted=$true
        if($images.Count -ne 1){throw 'ISO mount did not return one image identity.'}
        for($attempt=0;$attempt -le $TimeoutSeconds;$attempt++){
            # Inspect only volumes associated with this exact image. Never rewrite
            # drive letters on a host-wide label match.
            $volumes=@($images[0] | Get-Volume -ErrorAction Stop)
            if($volumes.Count -gt 1){throw 'ISO volume is ambiguous.'}
            if($volumes.Count -eq 1 -and [string]$volumes[0].DriveLetter -match '^[A-Za-z]$'){
                return [string]$volumes[0].DriveLetter
            }
            if($attempt -lt $TimeoutSeconds){Start-Sleep -Seconds 1}
        }
        throw 'ISO did not acquire a drive letter before the timeout.'
    } catch {
        $originalError=$_
        if($mounted){
            try { Dismount-DiskImage -ImagePath $path -ErrorAction Stop }
            catch { throw 'ISO preparation failed and its cleanup also failed. Inspect the requested ISO on the authorized host before retrying.' }
        }
        throw $originalError
    }
}

Function ConcatenateVHDPath {
param(
    [string]$VHDPath,
    [string]$VMName
)
    # Build the full VHDX file path from directory and VM name / 根据目录和虚拟机名称构建完整的 VHDX 文件路径
    if ([string]::IsNullOrWhiteSpace($VHDPath)) {
        $VHDPath = "."
    }
    if ($VHDPath[-1] -eq '\') {
        $VHDPath + $VMName + ".vhdx"
    }
    else {
        $VHDPath + "\" +  $VMName + ".vhdx"
    }
}

Function SmartExit {
param (
    [switch]$NoHalt,
    [string]$ExitReason
)
    # Exit gracefully, prompting in standard console but not in ISE/VS Code / 优雅退出，在标准控制台中提示按键，但在 ISE/VS Code 中不提示
    if (($host.name -eq 'Windows PowerShell ISE Host') -or ($host.Name -eq 'Visual Studio Code Host')) {
        Write-Host $ExitReason
        Exit
    }
    else {
        if ($NoHalt) {
            Write-Host $ExitReason
            Exit
        }
        else {
            Write-Host $ExitReason
            Read-host -Prompt "Press any key to Exit... / 按任意键退出..."
            Exit
        }
    }
}

Function Modify-AutoUnattend {
param (
    [string]$username,
    [string]$password,
    [string]$autologon,
    [string]$hostname,
    [string]$language,
    [string]$timezone,
    [string]$UnattendPath
)
    # Rewrite autounattend.xml with runtime values / 使用运行时值重写 autounattend.xml
    [xml]$xml = Get-Content -Path $UnattendPath

    # Modify autologon settings / 修改自动登录设置
    ($xml.unattend.settings.component | Where-Object { $_.AutoLogon }).AutoLogon.Password.Value = $password
    ($xml.unattend.settings.component | Where-Object { $_.AutoLogon }).AutoLogon.Username = $username
    ($xml.unattend.settings.component | Where-Object { $_.AutoLogon }).AutoLogon.Enabled = $autologon

    # Modify local account settings / 修改本地账户设置
    ($xml.unattend.settings.component | Where-Object { $_.UserAccounts }).UserAccounts.LocalAccounts.LocalAccount.Group = "Administrators"
    ($xml.unattend.settings.component | Where-Object { $_.UserAccounts }).UserAccounts.LocalAccounts.LocalAccount.Name = $username
    ($xml.unattend.settings.component | Where-Object { $_.UserAccounts }).UserAccounts.LocalAccounts.LocalAccount.DisplayName = $username
    ($xml.unattend.settings.component | Where-Object { $_.UserAccounts }).UserAccounts.LocalAccounts.LocalAccount.Password.Value = $password

    # Modify computer name / 修改计算机名
    ($xml.unattend.settings.component | Where-Object { $_.ComputerName }).ComputerName = $hostname

    # Modify language and input locale settings (both occurrences) / 修改语言和输入区域设置（两处）
    $internationalCoreWinPE = ($xml.unattend.settings.component | Where-Object { $_.SetupUILanguage })
    $internationalCoreWinPE.SetupUILanguage.UILanguage = $language
    $internationalCoreWinPE.InputLocale = $language
    $internationalCoreWinPE.SystemLocale = $language
    $internationalCoreWinPE.UILanguage = $language
    $internationalCoreWinPE.UILanguageFallback = $language
    $internationalCoreWinPE.UserLocale = $language

    $internationalCore = ($xml.unattend.settings.component | Where-Object { $_.name -eq 'Microsoft-Windows-International-Core' })
    $internationalCore.InputLocale = $language
    $internationalCore.SystemLocale = $language
    $internationalCore.UILanguage = $language
    $internationalCore.UILanguageFallback = $language
    $internationalCore.UserLocale = $language

    # Modify timezone / 修改时区
    $oobeSystemComponent = $xml.unattend.settings | Where-Object { $_.pass -eq 'oobeSystem' }
    $shellSetupComponent = $oobeSystemComponent.component | Where-Object { $_.name -eq 'Microsoft-Windows-Shell-Setup' }
    $shellSetupComponent.TimeZone = $timezone

    # Fix Password Never Expires command to use the correct username / 修复密码永不过期命令，使用正确的用户名
    # Replace deprecated wmic with Set-LocalUser (compatible with PowerShell 5.1+) / 将已弃用的 wmic 替换为 Set-LocalUser（兼容 PowerShell 5.1+）
    if ($shellSetupComponent.FirstLogonCommands) {
        $passwordCmd = $shellSetupComponent.FirstLogonCommands.SynchronousCommand | Where-Object { $_.Description -eq 'Password Never Expires' }
        if ($passwordCmd) {
            $passwordCmd.CommandLine = "powershell.exe -ExecutionPolicy Bypass -Command `"Set-LocalUser -Name '$username' -PasswordNeverExpires 1`""
        }
    }

    $xml.Save("$UnattendPath")
}

Function Assign-VMGPUPartitionAdapter {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$VMName,
        [ValidateNotNullOrEmpty()][string]$GPUName = 'AUTO',
        [ValidateRange(1,100)][decimal]$GPUResourceAllocationPercentage = 50,
        $AllocationPolicy = $null
    )
    $policy = if ($null -eq $AllocationPolicy) {
        ConvertTo-GpuPVAllocationPolicy -Policy @{Mode='Percent';Percentage=$GPUResourceAllocationPercentage}
    } else { ConvertTo-GpuPVAllocationPolicy -Policy $AllocationPolicy }
    if ($null -ne $AllocationPolicy -and $PSBoundParameters.ContainsKey('GPUResourceAllocationPercentage')) {
        $legacyPercentage = if ($policy.Mode -eq 'Percent') { $policy.Percentage } else { [decimal]50 }
        if ($GPUResourceAllocationPercentage -ne $legacyPercentage) { throw 'Legacy GPU percentage conflicts with the explicit allocation policy.' }
    }
    $partitionable = @(Get-WmiObject -Class Msvm_PartitionableGpu -ComputerName $env:COMPUTERNAME -Namespace 'ROOT\virtualization\v2' -ErrorAction Stop)
    if ($partitionable.Count -eq 0) { throw 'No partitionable GPU found.' }
    if ($GPUName -eq 'AUTO') {
        if ($partitionable.Count -ne 1) { throw 'AUTO requires exactly one partitionable GPU. Select an explicit GPU name or instance path.' }
        $selected = $partitionable[0]
    } else {
        $matches = @($partitionable | Where-Object { [string]$_.Name -eq $GPUName })
        if ($matches.Count -eq 0) {
            $drivers = @(Get-WmiObject -Class Win32_PNPSignedDriver -ErrorAction Stop | Where-Object { $_.DeviceName -eq $GPUName })
            $hardwareIds = @($drivers | ForEach-Object { @($_.HardwareID) } | Where-Object { $_ -match '^PCI\\[^\\]+$' } | ForEach-Object { $_.Split('\')[1] } | Select-Object -Unique)
            $matches = @($partitionable | Where-Object {
                $instanceName = [string]$_.Name
                @($hardwareIds | Where-Object { $instanceName.IndexOf($_,[StringComparison]::OrdinalIgnoreCase) -ge 0 }).Count -gt 0
            })
        }
        if ($matches.Count -ne 1) { throw 'The requested GPU does not resolve to one partitionable instance.' }
        $selected = $matches[0]
    }
    $instancePath = [string]$selected.Name
    if ([string]::IsNullOrWhiteSpace($instancePath) -or $instancePath.Length -lt 8) { throw 'Invalid partitionable GPU instance path.' }
    # Pure allocation calculation validates every driver range before any adapter change.
    $allocation = Get-GpuPVAllocationValues -Policy $policy -Capabilities $selected
    $existing = @(Get-VMGpuPartitionAdapter -VMName $VMName -ErrorAction Stop)
    if ($existing.Count -gt 1) { throw 'Multiple GPU adapters already exist; explicit reconciliation is required.' }
    if ($existing.Count -eq 1) {
        if ([string]$existing[0].InstancePath -ne $instancePath) { throw 'Existing adapter GPU identity differs or is unknown. Refusing to add a duplicate or silently replace it.' }
        Set-VMGpuPartitionAdapter -VMGpuPartitionAdapter $existing[0] @allocation -ErrorAction Stop
    } else {
        Add-VMGpuPartitionAdapter -VMName $VMName -InstancePath $instancePath @allocation -ErrorAction Stop | Out-Null
    }
    Write-Host 'GPU partition configuration applied. Guest driver and rendering readiness still require verification.'
}

# =============================================================================
# New Functions for Interactive Mode / 交互模式新增函数
# Extracted and generalized from Configure-GpuPV-ExistingVM.ps1
# =============================================================================

Function Write-Bilingual {
<#
.SYNOPSIS
    Write a bilingual INFO message to console.
    向控制台输出双语 INFO 消息。
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$En,
        [Parameter(Mandatory=$true)]
        [string]$Zh
    )
    Write-Host "INFO   : $En / $Zh"
}

Function Write-StepHeader {
<#
.SYNOPSIS
    Write a formatted step header.
    输出格式化的阶段标题。
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$StepNumber,
        [Parameter(Mandatory=$true)]
        [string]$EnTitle,
        [Parameter(Mandatory=$true)]
        [string]$ZhTitle
    )
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "Step $StepNumber : $EnTitle / $ZhTitle" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
}

Function Confirm-Continue {
<#
.SYNOPSIS
    Prompt user for Y/N confirmation.
    提示用户进行 Y/N 确认。
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$MessageEn,
        [string]$MessageZh = ""
    )
    $fullMsg = if ($MessageZh) { "$MessageEn / $MessageZh" } else { $MessageEn }
    $response = Read-Host "$fullMsg (Y/N)"
    return ($response -eq 'Y' -or $response -eq 'y')
}

Function Get-StateFilePath {
 param([Parameter(Mandatory=$true)][string]$VMName,[string]$Prefix='NewVm',[string]$ScriptRoot=$PSScriptRoot)
 if($VMName -notmatch '^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$' -or $Prefix -notmatch '^[A-Za-z][A-Za-z0-9_-]*$'){throw 'Invalid state identity; names are not silently normalized.'}
 Join-Path $ScriptRoot "$Prefix-$VMName.state.json"
}
Function Save-State {
 param([Parameter(Mandatory=$true)][hashtable]$Config,[Parameter(Mandatory=$true)][string]$StateFilePath)
 $stored = ConvertTo-GpuPVStoredAllocationConfig -Config (Get-GpuPVCheckpoint $Config) -LegacyField GPUResourceAllocationPercentage
 Write-GpuPVJsonAtomic -Path $StateFilePath -Value $stored
}
Function Import-State {
 param([Parameter(Mandatory=$true)][string]$StateFilePath,[string]$ExpectedVMName='')
 Read-GpuPVCheckpoint -Path $StateFilePath -ExpectedVMName $ExpectedVMName
}
Function Test-StepCompleted {
 param([Parameter(Mandatory=$true)][string]$Step,[Parameter(Mandatory=$true)][hashtable]$Config)
 return (Get-GpuPVPhaseSet $Config.PhaseCompleted) -contains $Step
}
Function Add-PhaseCompleted {
 param([Parameter(Mandatory=$true)][ValidatePattern('^Phase[1-7]$')][string]$Step,[Parameter(Mandatory=$true)][hashtable]$Config,[Parameter(Mandatory=$true)][string]$StateFilePath)
 $candidate=$Config.Clone();$candidate.PhaseCompleted=Get-GpuPVPhaseSet @(@($Config.PhaseCompleted)+@($Step))
 Save-State -Config $candidate -StateFilePath $StateFilePath
 $Config.PhaseCompleted=$candidate.PhaseCompleted
}
Function Invoke-DownloadWithCache {
 param([Parameter(Mandatory=$true)][string]$Url,[Parameter(Mandatory=$true)][string]$DestinationPath,[string]$DisplayName='File',[string[]]$FallbackFileNames=@(),[string]$ExpectedSha256='',[string]$LocalPath='')
 $expectedSize=0
 if(-not $ExpectedSha256){$policy=Get-GpuPVInstallerPolicy -DisplayName $DisplayName;$ExpectedSha256=$policy.Sha256;$expectedSize=[long]$policy.Size;$Url=$policy.Url;if([IO.Path]::GetExtension($DestinationPath) -ine [IO.Path]::GetExtension([string]$policy.FileName)){throw 'Destination extension must match the pinned artifact policy FileName.'}}
 Receive-GpuPVArtifact -Url $Url -DestinationPath $DestinationPath -ExpectedSha256 $ExpectedSha256 -ExpectedSize $expectedSize -LocalPath $LocalPath
}

Function Invoke-ExtractNefCon {
<#
.SYNOPSIS
    Extract NefCon ZIP and locate the x64 nefconw.exe.
    Filters out ARM/ARM64 paths to avoid "not a valid application" error.
    解压 NefCon ZIP 并定位 x64 版本的 nefconw.exe。
    过滤掉 ARM/ARM64 路径以避免"不是有效的应用程序"错误。
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$ZipPath,
        [Parameter(Mandatory=$true)]
        [string]$ExtractDir
    )
    if (-not (Test-Path $ExtractDir)) {
        New-Item -ItemType Directory -Path $ExtractDir -Force | Out-Null
    }
    Expand-Archive -Path $ZipPath -DestinationPath $ExtractDir -Force

    $nefconExe = Get-ChildItem -Path $ExtractDir -Filter "nefconw.exe" -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch "ARM|arm" -and $_.FullName -match "x64|amd64" } |
        Select-Object -First 1

    if (-not $nefconExe) {
        # Fallback: any nefconw.exe excluding ARM
        $nefconExe = Get-ChildItem -Path $ExtractDir -Filter "nefconw.exe" -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notmatch "ARM|arm" } |
            Select-Object -First 1
    }

    if (-not $nefconExe) {
        throw "nefconw.exe not found in $ExtractDir"
    }

    Write-Bilingual -En "NefCon x64 found at: $($nefconExe.FullName)" -Zh "NefCon x64 位置: $($nefconExe.FullName)"
    return $nefconExe
}

Function Get-AvailableGPUName {
<#
.SYNOPSIS
    Auto-detect the best GPU for GPU-PV. Prefers NVIDIA dGPU over iGPU.
    自动检测最适合 GPU-PV 的 GPU。优先选择 NVIDIA 独显而非核显。
#>
    [CmdletBinding()]
    param()
    $gpus = Get-WmiObject Win32_VideoController | Where-Object { $_.Name -notmatch "Basic|Remote|Virtual|Hyper-V|BasicDisplay" }
    if (-not $gpus) {
        return "AUTO"
    }
    $nvidiaGpu = $gpus | Where-Object { $_.Name -match "NVIDIA|GeForce|RTX|GTX|Quadro" } | Select-Object -First 1
    if ($nvidiaGpu) {
        return $nvidiaGpu.Name
    }
    return $gpus[0].Name
}
