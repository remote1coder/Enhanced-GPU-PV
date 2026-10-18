

Function Get-DesktopPC
{
 $isDesktop = $true
 if(Get-WmiObject -Class win32_systemenclosure | Where-Object { $_.chassistypes -contains 8 -or $_.chassistypes -contains 9 -or $_.chassistypes -contains 10 -or $_.chassistypes -contains 11 -or $_.chassistypes -contains 14 -or $_.chassistypes -contains 30 -or $_.chassistypes -contains 31 -or $_.chassistypes -contains 32})
   {
   Write-Warning "Computer is a laptop. Laptop dedicated GPU's that are partitioned and assigned to VM may not work with Parsec." 
   Write-Warning "Thunderbolt 3 or 4 dock based GPU's may work"
   $isDesktop = $false }
 if (Get-WmiObject -Class win32_battery)
   { $isDesktop = $false }
 $isDesktop
}

Function Get-WindowsCompatibleOS {
$build = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
if ($build.CurrentBuild -ge 19041 -and ($($build.editionid -like 'Professional*') -or $($build.editionid -like 'Enterprise*') -or $($build.editionid -like 'Education*'))) {
    Return $true
    }
Else {
    Write-Warning "Only Windows 10 20H1 or Windows 11 (Pro or Enterprise) is supported"
    Return $false
    }
}


Function Get-HyperVEnabled {
$hyperV = Get-WindowsOptionalFeature -Online | Where-Object FeatureName -Like 'Microsoft-Hyper-V-All'
if ($hyperV -and $hyperV.State -eq 'Enabled'){
    Return $true
    }
Else {
    Write-Warning "You need to enable Virtualisation in your motherboard and then add the Hyper-V Windows Feature and reboot"
    Return $false
    }
}

Function Get-WSLEnabled {
    try {
        # wsl.exe emits UTF-16LE; treat any non-header line as an installed distro (avoids the
        # brittle fixed index [2] assumption which false-negatives on no-distro installs).
        # wsl.exe 输出为 UTF-16LE；将任何非表头行视为已安装的发行版
        # （避免使用固定的 [2] 索引，该索引在无发行版安装时会产生漏报）。
        $wslOutput = wsl -l -v 2>$null
        if ($LASTEXITCODE -eq 0 -and $wslOutput) {
            $hasDistro = $false
            foreach ($line in $wslOutput) {
                if (-not $line) { continue }
                $trim = $line.Trim()
                if ($trim.Length -eq 0 -or $trim -match 'NAME\s+STATE\s+VERSION' -or $trim -match 'Windows Subsystem for Linux') { continue }
                $hasDistro = $true
                break
            }
            if ($hasDistro) {
                Write-Warning "WSL is Enabled. This may interferre with GPU-P and produce an error 43 in the VM"
                Return $true
            }
        }
    }
    catch {
        # WSL command not available / WSL 命令不可用
    }
    Return $false
}

Function Get-VMGpuPartitionAdapterFriendlyName {
    $Devices = (Get-WmiObject -Class "Msvm_PartitionableGpu" -ComputerName $env:COMPUTERNAME -Namespace "ROOT\virtualization\v2").name
    Foreach ($GPU in $Devices) {
        $GPUParse = $GPU.Split('#')[1]
        Get-WmiObject Win32_PNPSignedDriver | where {($_.HardwareID -eq "PCI\$GPUParse")} | select DeviceName -ExpandProperty DeviceName
        }
}

If ((Get-DesktopPC) -and  (Get-WindowsCompatibleOS) -and (Get-HyperVEnabled)) {
"System Compatible"
"Printing a list of compatible GPUs...May take a second"
"Copy the name of the GPU you want to share..."
Get-VMGpuPartitionAdapterFriendlyName
Read-Host -Prompt "Press Enter to Exit"
}
else {
Read-Host -Prompt "Press Enter to Exit"
}
