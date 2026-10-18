# Function to disable OneDrive autostart
Function Disable-OneDriveAutostart {
    param (
        [string]$onedrivePath
    )
    # Disable its autostart by setting the value to an empty string
    Set-ItemProperty -Path $onedrivePath -Name "OneDrive" -Value ""
    Get-Process -Name "OneDrive" -ErrorAction SilentlyContinue | Stop-Process -Force
}

# Function to remove the scheduled task
Function Remove-ScheduledTask {
    param (
        [string]$taskName
    )
    # Guard against the task already being absent (e.g. re-runs) / 防止任务已不存在（如重复运行）
    try { Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction Stop } catch {}
}

# Variables
$onedrivePath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
$taskName = "DisableOneDriveAutostart"
$onedriveInstalled = $false
$odRetry = 0; $odMaxRetry = 60  # Max wait ~5 minutes / 最多等待约 5 分钟

# Check for OneDrive installation (bounded so the task does not hang if OneDrive is absent)
# 检查 OneDrive 是否安装（有上限，避免 OneDrive 不存在时任务无限挂起）
while (-not $onedriveInstalled -and $odRetry -lt $odMaxRetry) {
    $runKeys = Get-ItemProperty -Path $onedrivePath -ErrorAction SilentlyContinue
    if ($runKeys -and $runKeys.PSObject.Properties.Name -contains "OneDrive") {
        $onedriveInstalled = $true
    } else {
        Start-Sleep -Seconds 5
        $odRetry++
    }
}

# If OneDrive never appeared, self-unregister and exit / 若 OneDrive 始终未出现，注销任务并退出
if (-not $onedriveInstalled) {
    Write-Warning "OneDrive not detected after $odMaxRetry attempts. Exiting task. / 未检测到 OneDrive，退出任务。"
    Remove-ScheduledTask -taskName $taskName
    exit
}

# Disable OneDrive autostart
Disable-OneDriveAutostart -onedrivePath $onedrivePath

# Remove the scheduled task to prevent further executions
Remove-ScheduledTask -taskName $taskName