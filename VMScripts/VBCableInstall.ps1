# Load local installer paths if available / 加载本地安装程序路径（如果可用）
$localPathsFile = "C:\ProgramData\Easy-GPU-P\LocalInstallers\LocalPaths.ps1"
if (Test-Path $localPathsFile) { . $localPathsFile }
# Force TLS 1.2 (required by GitHub/vb-audio.com; PS 5.1 WebClient does not enable it by default on older OS)
# 强制使用 TLS 1.2（GitHub/vb-audio.com 要求；旧系统上 PS 5.1 的 WebClient 默认未启用）
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
$taskName = "Install VB Cable"

# Install VB Cable
if (!(Get-WmiObject Win32_SoundDevice | Where-Object name -like "VB-Audio Virtual Cable")) {
    $vbZipPath = if ($LocalVBCableZipPath -and (Test-Path $LocalVBCableZipPath)) { $LocalVBCableZipPath } else { "C:\Users\$env:USERNAME\Downloads\VBCable.zip" }
    if (-not (Test-Path $vbZipPath)) {
        (New-Object System.Net.WebClient).DownloadFile("https://download.vb-audio.com/Download_CABLE/VBCABLE_Driver_Pack43.zip", $vbZipPath)
    }
    $vbExtractDir = "C:\Users\$env:Username\Downloads\VBCable"
    if (!(Test-Path $vbExtractDir)) {
        New-Item -Path $vbExtractDir -ItemType Directory | Out-Null
    }
    Expand-Archive -Path $vbZipPath -DestinationPath $vbExtractDir -Force
    $pathToCatFile = "C:\Users\$env:USERNAME\Downloads\VBCable\vbaudio_cable64_win7.cat"
    $FullCertificateExportPath = "C:\Users\$env:USERNAME\Downloads\VBCable\VBCert.cer"
    $VB = @{}
    $VB.DriverFile = $pathToCatFile;
    $VB.CertName = $FullCertificateExportPath;
    $VB.ExportType = [System.Security.Cryptography.X509Certificates.X509ContentType]::Cert;
    $VB.Cert = (Get-AuthenticodeSignature -filepath $VB.DriverFile).SignerCertificate;
    if (-not $VB.Cert) {
        Write-Warning "Could not extract a signer certificate from $($VB.DriverFile). VB-Cable may not install silently. / 无法从 $($VB.DriverFile) 提取签名者证书，VB-Cable 可能无法静默安装。"
    } else {
        [System.IO.File]::WriteAllBytes($VB.CertName, $VB.Cert.Export($VB.ExportType))
    }
    $certRetry = 0; $certMaxRetry = 12
    while (((Get-ChildItem Cert:\LocalMachine\TrustedPublisher) | Where-Object {$_.Subject -like '*Vincent Burel*'}) -eq $NULL -and $certRetry -lt $certMaxRetry) {
        certutil -Enterprise -Addstore "TrustedPublisher" "$VB.CertName"
        Start-Sleep -s 5
        $certRetry++
        }
    if ($certRetry -ge $certMaxRetry) {
        Write-Warning "Certificate installation retry limit reached. VB-Cable may not install correctly."
        }
    Start-Process -FilePath "C:\Users\$env:Username\Downloads\VBCable\VBCABLE_Setup_x64.exe" -ArgumentList '-i','-h' -Wait
    # Remove the scheduled task to prevent further executions
    Remove-ScheduledTask -taskName $taskName  
}