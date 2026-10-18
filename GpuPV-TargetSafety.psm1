# Identity-bound offline target selection. Importing this module performs no discovery or mutation.
function Select-GpuPVAttachedDisk {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [object[]]$Disks, [string]$VhdPath)
    $candidates = @($Disks | Where-Object { $_.Path })
    if ($VhdPath) {
        if ($VhdPath -notmatch '^[A-Za-z]:\\' -or $VhdPath -match '[*?]') { throw 'An absolute local VHD path is required.' }
        $requested = [IO.Path]::GetFullPath($VhdPath)
        $candidates = @($candidates | Where-Object { [IO.Path]::GetFullPath($_.Path) -eq $requested })
    }
    if ($candidates.Count -ne 1) { throw 'Disk identity is ambiguous or missing. Specify the exact attached SystemVhdPath; no first/largest-disk fallback is allowed.' }
    if ($candidates[0].Path -notmatch '^[A-Za-z]:\\') { throw 'Only an absolute local attached VHD path is supported.' }
    return $candidates[0]
}

function Select-GpuPVWindowsVolume {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [object[]]$Candidates, [ValidateRange(0,2147483647)][int]$PartitionNumber = 0)
    $considered = @($Candidates)
    if ($PartitionNumber -gt 0) { $considered = @($considered | Where-Object { $_.PartitionNumber -eq $PartitionNumber }) }
    if (@($considered | Where-Object { $_.ProbeUnavailable }).Count) { throw 'A possible Windows partition could not be inspected. Select a verified partition explicitly or assign its access path before retrying.' }
    $windows = @($considered | Where-Object { $_.HasSystemHive -and $_.HasSoftwareHive -and $_.HasKernel })
    if ($windows.Count -ne 1) { throw 'Windows-volume identity is ambiguous or missing. Explicitly select a verified Windows partition.' }
    $target = $windows[0]
    foreach ($field in @('DiskUniqueId','VolumeUniqueId','PartitionIdentity')) {
        if ([string]::IsNullOrWhiteSpace([string]$target.$field)) { throw "Target lacks $field." }
    }
    if ($target.Root -notmatch '^[A-Za-z]:\\$') { throw 'The selected Windows volume has no supported drive-letter root. No other volume will be substituted.' }
    if ($target.IsBoot -or $target.IsSystem) { throw 'The selected disk belongs to the running host.' }
    return $target
}

function Get-GpuPVMountedVolumeCandidates {
    param([Parameter(Mandatory)]$Disk)
    foreach ($partition in @(Get-Partition -DiskNumber $Disk.Number -ErrorAction Stop)) {
        # Exclude identified EFI/MSR/Windows-RE utility partitions, never a basic data partition by size.
        if ([string]$partition.GptType -in @('{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}','{e3c9e316-0b5c-4db8-817d-f92df00215ae}','{de94bba4-06d1-4d40-a16a-bfd50179d6ac}')) { continue }
        $volumes = @($partition | Get-Volume -ErrorAction SilentlyContinue)
        if ($volumes.Count -ne 1) {
            [pscustomobject]@{ PartitionNumber = $partition.PartitionNumber; ProbeUnavailable = $true }
            continue
        }
        $volume = $volumes[0]
        $root = if ($volume.DriveLetter) { "$($volume.DriveLetter):\" } else { '' }
        $partitionIdentity = if ($partition.Guid) { [string]$partition.Guid } else { "$($partition.Offset):$($partition.Size)" }
        # A non-letter volume is deliberately not probed through a guessed drive or mount point.
        [pscustomobject]@{
            DiskNumber = $Disk.Number; DiskUniqueId = [string]$Disk.UniqueId
            PartitionNumber = $partition.PartitionNumber; PartitionIdentity = $partitionIdentity
            VolumeUniqueId = [string]$volume.UniqueId; Root = $root
            DriveLetter = if ($root) { $root.TrimEnd('\') } else { '' }
            IsBoot = [bool]$Disk.IsBoot; IsSystem = [bool]$Disk.IsSystem
            ProbeUnavailable = -not $root
            HasSystemHive = $root -and (Test-Path -LiteralPath ($root + 'Windows\System32\config\SYSTEM') -PathType Leaf -ErrorAction Stop)
            HasSoftwareHive = $root -and (Test-Path -LiteralPath ($root + 'Windows\System32\config\SOFTWARE') -PathType Leaf -ErrorAction Stop)
            HasKernel = $root -and (Test-Path -LiteralPath ($root + 'Windows\System32\ntoskrnl.exe') -PathType Leaf -ErrorAction Stop)
        }
    }
}

function New-GpuPVTargetFromMountedDisk {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$VhdPath, [Parameter(Mandatory)][int]$DiskNumber,
          [switch]$CreationOwned, [ValidateRange(0,2147483647)][int]$PartitionNumber = 0, [string]$VMId)
    if (-not $CreationOwned -and [string]::IsNullOrWhiteSpace($VMId)) { throw 'A VM identity or explicit current-operation creation ownership is required.' }
    $vhd = Get-VHD -Path $VhdPath -ErrorAction Stop
    if (-not $vhd.Attached -or $vhd.DiskNumber -ne $DiskNumber) { throw 'Mounted VHD disk identity changed.' }
    $disk = Get-Disk -Number $DiskNumber -ErrorAction Stop
    $candidate = Select-GpuPVWindowsVolume -Candidates @(Get-GpuPVMountedVolumeCandidates -Disk $disk) -PartitionNumber $PartitionNumber
    $candidate | Add-Member NoteProperty VhdPath ([IO.Path]::GetFullPath($VhdPath))
    $candidate | Add-Member NoteProperty VMId $VMId
    $candidate | Add-Member NoteProperty Ownership $(if ($CreationOwned) { 'CreatedByCurrentOperation' } else { 'AttachedToVM' })
    $candidate | Add-Member NoteProperty MountedByUs $false
    Assert-GpuPVTarget -Target $candidate
    return $candidate
}

function Open-GpuPVOfflineTarget {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$VM, [string]$VhdPath, [ValidateRange(0,2147483647)][int]$PartitionNumber = 0)
    if ([string]$VM.State -ne 'Off') { throw 'The VM must be Off before offline target discovery.' }
    $vmId = [string]$VM.VMId
    if (-not $vmId) { throw 'Missing VM identity.' }
    $selected = Select-GpuPVAttachedDisk -Disks @(Get-VMHardDiskDrive -VM $VM -ErrorAction Stop) -VhdPath $VhdPath
    $path = [IO.Path]::GetFullPath($selected.Path)
    if ((Get-VHD -Path $path -ErrorAction Stop).Attached) { throw 'The VHD is already mounted. Refusing to take ownership or dismount another operation.' }
    $mounted = $false; $ownedDisk = $null
    try {
        $probe = Mount-VHD -Path $path -ReadOnly -PassThru -ErrorAction Stop
        $mounted = $true
        $probeDisk = $probe | Get-Disk -ErrorAction Stop
        $ownedDisk = [pscustomobject]@{VhdPath=$path;DiskNumber=$probeDisk.Number;DiskUniqueId=[string]$probeDisk.UniqueId;MountedByUs=$true}
        $identity = Select-GpuPVWindowsVolume -Candidates @(Get-GpuPVMountedVolumeCandidates -Disk $probeDisk) -PartitionNumber $PartitionNumber
        Close-GpuPVOfflineTarget -Target $ownedDisk
        $mounted = $false; $ownedDisk = $null
        # Revalidate the attachment before obtaining writable access.
        $currentVM = Get-VM -Id $vmId -ErrorAction Stop
        if ([string]$currentVM.State -ne 'Off') { throw 'VM state changed during discovery.' }
        $null = Select-GpuPVAttachedDisk -Disks @(Get-VMHardDiskDrive -VM $currentVM -ErrorAction Stop) -VhdPath $path
        $writeMount = Mount-VHD -Path $path -PassThru -ErrorAction Stop
        $mounted = $true
        $writeDisk = $writeMount | Get-Disk -ErrorAction Stop
        $ownedDisk = [pscustomobject]@{VhdPath=$path;DiskNumber=$writeDisk.Number;DiskUniqueId=[string]$writeDisk.UniqueId;MountedByUs=$true}
        $target = New-GpuPVTargetFromMountedDisk -VhdPath $path -DiskNumber $writeDisk.Number -VMId $vmId -PartitionNumber $identity.PartitionNumber
        foreach ($field in @('DiskUniqueId','PartitionIdentity','VolumeUniqueId')) {
            if ($target.$field -ne $identity.$field) { throw "Target $field changed between discovery and writable mount." }
        }
        $target.MountedByUs = $true
        return $target
    } catch {
        if ($mounted) {
            if (-not $ownedDisk) { throw 'Mount returned but disk identity could not be captured. The mount was retained for manual inspection; no unverified dismount was attempted.' }
            Close-GpuPVOfflineTarget -Target $ownedDisk
        }
        throw
    }
}

function Assert-GpuPVTarget {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Target)
    if ($Target.Root -notmatch '^[A-Za-z]:\\$' -or $Target.Root.TrimEnd('\') -eq $env:SystemDrive) { throw 'An identity-bound, non-host volume root is required.' }
    if ($Target.Ownership -notin @('CreatedByCurrentOperation','AttachedToVM')) { throw 'Unrecognized target ownership.' }
    if ($Target.Ownership -eq 'AttachedToVM') {
        $vm = Get-VM -Id $Target.VMId -ErrorAction Stop
        if ([string]$vm.State -ne 'Off') { throw 'VM is no longer Off.' }
        $null = Select-GpuPVAttachedDisk -Disks @(Get-VMHardDiskDrive -VM $vm -ErrorAction Stop) -VhdPath $Target.VhdPath
    }
    $vhd = Get-VHD -Path $Target.VhdPath -ErrorAction Stop
    if (-not $vhd.Attached -or $vhd.DiskNumber -ne $Target.DiskNumber) { throw 'Target is detached or its disk number changed.' }
    $disk = Get-Disk -Number $Target.DiskNumber -ErrorAction Stop
    $current = Select-GpuPVWindowsVolume -Candidates @(Get-GpuPVMountedVolumeCandidates -Disk $disk) -PartitionNumber $Target.PartitionNumber
    foreach ($field in @('DiskUniqueId','PartitionIdentity','VolumeUniqueId','Root')) {
        if ($Target.$field -ne $current.$field) { throw "Target $field changed; refusing access." }
    }
    $null = Assert-GpuPVPathWithinRoot -Root $Target.Root -Path ($Target.Root + 'Windows\System32')
}

function Assert-GpuPVPathWithinRoot {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Path)
    if ($Root -notmatch '^[A-Za-z]:\\$' -or $Path -notmatch '^[A-Za-z]:\\' -or $Path -match '[*?]' -or $Path.Substring(2).Contains(':')) { throw 'Only literal absolute local paths are allowed.' }
    $full = [IO.Path]::GetFullPath($Path)
    if (-not $full.StartsWith($Root,[StringComparison]::OrdinalIgnoreCase) -or $full.TrimEnd('\') -eq $Root.TrimEnd('\')) { throw 'Target path escapes or equals the volume root.' }
    $current = $Root
    foreach ($part in $full.Substring($Root.Length).Split('\')) {
        if (-not $part) { continue }
        $current = [IO.Path]::Combine($current,$part)
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Reparse-point traversal refused: $current" }
        }
    }
    return $full
}

function Assert-GpuPVTargetPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Target, [Parameter(Mandatory)][string]$Path)
    Assert-GpuPVTarget -Target $Target
    return Assert-GpuPVPathWithinRoot -Root $Target.Root -Path $Path
}

function Assert-GpuPVTreeNoReparse {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Path)
    $safe = Assert-GpuPVPathWithinRoot -Root $Root -Path $Path
    if (-not (Test-Path -LiteralPath $safe)) { return }
    $queue = New-Object 'System.Collections.Generic.Queue[string]'
    $queue.Enqueue($safe)
    while ($queue.Count) {
        $entry = Get-Item -LiteralPath $queue.Dequeue() -Force -ErrorAction Stop
        if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Reparse point found in target tree.' }
        if ($entry.PSIsContainer) {
            foreach ($child in @(Get-ChildItem -LiteralPath $entry.FullName -Force -ErrorAction Stop)) {
                if ($child.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Reparse point found in target tree.' }
                $queue.Enqueue($child.FullName)
            }
        }
    }
}

function Remove-GpuPVTargetTree {
    param([Parameter(Mandatory)]$Target, [Parameter(Mandatory)][string]$Path)
    $safe = Assert-GpuPVTargetPath -Target $Target -Path $Path
    Assert-GpuPVTreeNoReparse -Root $Target.Root -Path $safe
    if (-not (Test-Path -LiteralPath $safe)) { return }
    # Do not give a recursive remover permission to follow an unchecked junction.
    $item = Get-Item -LiteralPath $safe -Force -ErrorAction Stop
    if ($item.PSIsContainer) {
        foreach ($child in @(Get-ChildItem -LiteralPath $safe -Force -ErrorAction Stop)) { Remove-GpuPVTargetTree -Target $Target -Path $child.FullName }
    }
    $null = Assert-GpuPVTargetPath -Target $Target -Path $safe
    Remove-Item -LiteralPath $safe -Force -ErrorAction Stop
}

function Close-GpuPVOfflineTarget {
    param([Parameter(Mandatory)]$Target)
    if ($Target.MountedByUs) {
        $vhd = Get-VHD -Path $Target.VhdPath -ErrorAction Stop
        if (-not $vhd.Attached -or $vhd.DiskNumber -ne $Target.DiskNumber) { throw 'Refusing to dismount a changed target.' }
        $disk=Get-Disk -Number $vhd.DiskNumber -ErrorAction Stop
        if([string]::IsNullOrWhiteSpace([string]$Target.DiskUniqueId) -or [string]$disk.UniqueId -ne [string]$Target.DiskUniqueId){throw 'Refusing to dismount a target whose disk identity changed.'}
        Dismount-VHD -Path $Target.VhdPath -ErrorAction Stop
        $Target.MountedByUs = $false
    }
}
function Get-GpuPVRdpReadiness {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Observation)
    $passed = $Observation.Port -ge 1 -and $Observation.Port -le 65535
    foreach ($field in @('RegistryEnabled','ServiceRunning','Listening','RuleEnabled','RuleInbound','RuleAllows','RulePortMatches')) {
        $passed = $passed -and ($Observation.$field -is [bool]) -and $Observation.$field
    }
    [pscustomobject]@{ Port = $Observation.Port; LocalChecksPassed = [bool]$passed; ClientLoginVerified = $false; NetworkReachabilityVerified = $false }
}
function Get-GpuPVExactVM {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    if([string]::IsNullOrWhiteSpace($Name) -or $Name -match '[*?\[\]]'){throw 'An exact nonempty VM name is required.'}
    $matches=@(Get-VM -Name $Name -ErrorAction Stop)
    if($matches.Count -ne 1 -or $matches[0].Name -ine $Name){throw 'VM name did not resolve to one exact VM.'}
    return $matches[0]
}
function Stop-GpuPVVMForOfflineAccess {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$VM,[ValidateRange(1,600)][int]$TimeoutSeconds=180)
    $id=[string]$VM.VMId
    if([string]::IsNullOrWhiteSpace($id)){throw 'Missing VM identity.'}
    $current=Get-VM -Id $id -ErrorAction Stop
    if($current.State -notin @('Off','Running')){throw 'Saved, paused or transitioning VM requires an explicit owner decision; no force shutdown is allowed.'}
    # TimeoutSeconds bounds polling after synchronous Stop-VM returns; it is not a hard deadline for that native call.
    if($current.State -eq 'Running'){Stop-VM -VM $current -ErrorAction Stop}
    for($elapsed=0;$elapsed -lt $TimeoutSeconds;$elapsed++){
        $current=Get-VM -Id $id -ErrorAction Stop
        if([string]$current.VMId -ne $id){throw 'VM identity changed during shutdown.'}
        if($current.State -eq 'Off'){return $current}
        Start-Sleep -Seconds 1
    }
    throw 'Graceful shutdown timed out. No writable mount or forced stop was attempted.'
}
function Get-GpuPVGuestRdpConfigurationScript {
    # This returns guest-side code as data. Callers must separately run the shared ActiveStore observation.
    return {
        param([bool]$Enable)
        $ErrorActionPreference='Stop'
        $key='HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server'
        $policy=Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services' -Name fDenyTSConnections -ErrorAction SilentlyContinue
        $desired=if($Enable){0}else{1}
        if($policy -and $policy.fDenyTSConnections -ne $desired){throw 'RDP policy conflicts with requested connection method.'}
        $port=[int](Get-ItemProperty -LiteralPath "$key\WinStations\RDP-Tcp" -Name PortNumber -ErrorAction Stop).PortNumber
        if($port -lt 1 -or $port -gt 65535){throw 'Invalid RDP listener port.'}
        $name='Enhanced-GPU-PV-RDP-TCP'
        $rule=@(Get-NetFirewallRule -Name $name -PolicyStore PersistentStore -ErrorAction SilentlyContinue)
        if($rule.Count -gt 1){throw 'Ambiguous project RDP rule.'}
        if($Enable -and $rule.Count -eq 1){
            $ports=@($rule|Get-NetFirewallPortFilter -ErrorAction Stop)
            $services=@($rule|Get-NetFirewallServiceFilter -ErrorAction Stop)
            $apps=@($rule|Get-NetFirewallApplicationFilter -ErrorAction Stop)
            $addresses=@($rule|Get-NetFirewallAddressFilter -ErrorAction Stop)
            if($ports.Count -ne 1 -or [string]$ports[0].RemotePort -ne 'Any' -or
               $services.Count -ne 1 -or [string]$services[0].Service -ne 'TermService' -or
               $apps.Count -ne 1 -or [string]$apps[0].Program -ne 'Any' -or [string]$apps[0].Package -ne 'Any' -or
               $addresses.Count -ne 1 -or [string]$addresses[0].LocalAddress -ne 'Any' -or [string]$addresses[0].RemoteAddress -ne 'Any'){
                throw 'Existing project RDP rule has custom filters. Review them explicitly; no restrictions were widened.'
            }
        }
        Set-ItemProperty -LiteralPath $key -Name fDenyTSConnections -Value $desired -ErrorAction Stop | Out-Null
        $legacy=@(Get-NetFirewallRule -Name 'EnhancedGPUPV-RDP-TCP' -PolicyStore PersistentStore -ErrorAction SilentlyContinue)
        if($legacy.Count){Disable-NetFirewallRule -Name 'EnhancedGPUPV-RDP-TCP' -PolicyStore PersistentStore -ErrorAction Stop | Out-Null}
        if($Enable){
            $parameters=@{PolicyStore='PersistentStore';Direction='Inbound';Protocol='TCP';LocalPort=$port;RemotePort='Any';Action='Allow';Enabled='True';Profile=@('Domain','Private');Service='TermService';Program='Any';Package='Any';LocalAddress='Any';RemoteAddress='Any';ErrorAction='Stop'}
            if($rule.Count){Set-NetFirewallRule -Name $name @parameters | Out-Null}
            else{New-NetFirewallRule -Name $name -DisplayName 'Enhanced GPU-PV RDP (Domain/Private)' @parameters | Out-Null}
            Start-Service -Name TermService -ErrorAction Stop | Out-Null
        }elseif($rule.Count){Disable-NetFirewallRule -Name $name -PolicyStore PersistentStore -ErrorAction Stop | Out-Null}
        if([int](Get-ItemProperty -LiteralPath $key -Name fDenyTSConnections -ErrorAction Stop).fDenyTSConnections -ne $desired){throw 'RDP registry readback failed.'}
        [pscustomobject]@{Enabled=$Enable;Port=$port;SettingsApplied=$true;ConfigurationVerified=$false;RemoteLoginVerified=$false;NetworkReachabilityVerified=$false}
    }
}
function Get-GpuPVGuestRdpObservationScript {
    # This returns guest-side code as data; obtaining it performs no query.
    return {
        param([bool]$ExpectedEnabled)
        $ErrorActionPreference='Stop'
        $key='HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server'
        $deny=[int](Get-ItemProperty -LiteralPath $key -Name fDenyTSConnections -ErrorAction Stop).fDenyTSConnections
        $port=[int](Get-ItemProperty -LiteralPath "$key\WinStations\RDP-Tcp" -Name PortNumber -ErrorAction Stop).PortNumber
        if($port -lt 1 -or $port -gt 65535){throw 'Invalid RDP port.'}
        $policy=Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services' -Name fDenyTSConnections -ErrorAction SilentlyContinue
        if(($deny -eq 0) -ne $ExpectedEnabled -or ($policy -and (($policy.fDenyTSConnections -eq 0) -ne $ExpectedEnabled))){throw 'RDP effective policy does not match requested mode.'}
        $names=@('Enhanced-GPU-PV-RDP-TCP','EnhancedGPUPV-RDP-TCP')
        $rules=@(Get-NetFirewallRule -Name $names -PolicyStore ActiveStore -ErrorAction SilentlyContinue)
        $rule=@($rules|Where-Object{$_.Name -eq $names[0]})
        $filters=@();$serviceFilters=@();$applicationFilters=@();$addressFilters=@()
        if($rule.Count -eq 1){
            $filters=@($rule|Get-NetFirewallPortFilter -ErrorAction Stop)
            $serviceFilters=@($rule|Get-NetFirewallServiceFilter -ErrorAction Stop)
            $applicationFilters=@($rule|Get-NetFirewallApplicationFilter -ErrorAction Stop)
            $addressFilters=@($rule|Get-NetFirewallAddressFilter -ErrorAction Stop)
        }
        $service=Get-CimInstance -ClassName Win32_Service -Filter "Name='TermService'" -ErrorAction Stop
        $listeners=@(Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue|Where-Object{$service -and $_.OwningProcess -eq $service.ProcessId})
        $allow=$rule.Count -eq 1 -and [string]$rule[0].Enabled -eq 'True' -and [string]$rule[0].Direction -eq 'Inbound' -and [string]$rule[0].Action -eq 'Allow'
        $profileMatches=$rule.Count -eq 1 -and (([string]$rule[0].Profile -replace '\s','') -in @('Domain,Private','Private,Domain','3'))
        $portMatches=$filters.Count -eq 1 -and [string]$filters[0].Protocol -in @('TCP','6') -and [string]$filters[0].LocalPort -eq [string]$port -and [string]$filters[0].RemotePort -eq 'Any'
        $serviceMatches=$serviceFilters.Count -eq 1 -and [string]$serviceFilters[0].Service -eq 'TermService'
        $applicationMatches=$applicationFilters.Count -eq 1 -and [string]$applicationFilters[0].Program -eq 'Any' -and [string]$applicationFilters[0].Package -eq 'Any'
        $addressMatches=$addressFilters.Count -eq 1 -and [string]$addressFilters[0].LocalAddress -eq 'Any' -and [string]$addressFilters[0].RemoteAddress -eq 'Any'
        if($ExpectedEnabled){
            # Preserve custom constraints rather than silently widen them; incompatible rules require owner review.
            if(-not $allow -or -not $portMatches -or -not $profileMatches -or -not $serviceMatches -or -not $applicationMatches -or -not $addressMatches -or -not $service -or $service.State -ne 'Running' -or $listeners.Count -eq 0){throw 'RDP effective rule filters, service or listener do not match the project policy. Review existing custom constraints; they were not widened.'}
        }elseif(@($rules|Where-Object{[string]$_.Enabled -eq 'True'}).Count){throw 'A project-owned RDP rule is still enabled.'}
        [pscustomobject]@{Enabled=$ExpectedEnabled;Port=$port;ConfigurationVerified=$true;ListenerObserved=($listeners.Count -gt 0);RemoteLoginVerified=$false;NetworkReachabilityVerified=$false;ProfileScope='Domain,Private';CheckedFirewallFilters=@('Port','Service','Application','Address');OtherFirewallConstraintsVerified=$false}
    }
}
Export-ModuleMember -Function Get-GpuPVGuestRdpConfigurationScript,Get-GpuPVGuestRdpObservationScript,Get-GpuPVExactVM,Stop-GpuPVVMForOfflineAccess,Get-GpuPVRdpReadiness,Select-GpuPVAttachedDisk,Select-GpuPVWindowsVolume,New-GpuPVTargetFromMountedDisk,Open-GpuPVOfflineTarget,Assert-GpuPVTarget,Assert-GpuPVTargetPath,Assert-GpuPVPathWithinRoot,Assert-GpuPVTreeNoReparse,Remove-GpuPVTargetTree,Close-GpuPVOfflineTarget
