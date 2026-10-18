# Load local installer paths if available / 加载本地安装程序路径（如果可用）
$localPathsFile = "C:\ProgramData\Easy-GPU-P\LocalInstallers\LocalPaths.ps1"
if (Test-Path $localPathsFile) { . $localPathsFile }
# Force TLS 1.2 (required by GitHub; PS 5.1 WebClient does not enable it by default on older OS)
# 强制使用 TLS 1.2（GitHub 要求；旧系统上 PS 5.1 的 WebClient 默认未启用）
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Function to remove the scheduled task
Function Remove-ScheduledTask {
    param (
        [string]$taskName
    )
    # Guard against the task already being absent (e.g. re-runs) / 防止任务已不存在（如重复运行）
    try { Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction Stop } catch {}
}

# Variables
$taskName = "Install VirtualDisplayDriverHDR"
$downloadUrl = "https://github.com/timminator/Virtual-Display-Driver/releases/download/v1.0.1/Virtual.Display.Driver.HDR-v1.0.1-setup-x64.exe"
$downloadPath = if ($LocalVirtualDisplayDriverHDRPath -and (Test-Path $LocalVirtualDisplayDriverHDRPath)) { $LocalVirtualDisplayDriverHDRPath } else { "C:\Users\$env:USERNAME\Downloads\Virtual.Display.Driver.HDR-v1.0.1-setup-x64.exe" }
$scriptFolder = (Get-Item -Path $MyInvocation.MyCommand.Definition).DirectoryName
$desktopPath = [System.Environment]::GetFolderPath('Desktop')
$vbScriptPath = "$scriptFolder\SwitchDisplayVDD.vbs"
$iconPath = "$scriptFolder\VirtualDisplayDriver.ico"
$shortcutPath = "$desktopPath\Switch Display to Virtual Display.lnk"

# Download and install Virtual Display Driver HDR / 下载并安装虚拟显示驱动 HDR
if (-not (Test-Path $downloadPath)) {
    (New-Object System.Net.WebClient).DownloadFile($downloadUrl, $downloadPath)
}
Start-Process $downloadPath -ArgumentList "/VERYSILENT", "/SUPPRESSMSGBOXES" -Wait

# Create a new shortcut on the user's desktop
$WScriptShell = New-Object -ComObject WScript.Shell
$shortcut = $WScriptShell.CreateShortcut($shortcutPath)
$shortcut.TargetPath = $vbScriptPath
$shortcut.IconLocation = $iconPath
$shortcut.Save()

# Remove the scheduled task to prevent further executions
Remove-ScheduledTask -taskName $taskName