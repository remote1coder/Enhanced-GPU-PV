# Pure data helpers. Importing this module does not inspect or modify the host.
Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'GpuPV-Allocation.psm1') -Force -ErrorAction Stop
function ConvertTo-ExistingMap {
    param($Value)
    if ($null -eq $Value) { return @{} }
    if ($Value -is [System.Collections.IDictionary]) { return $Value }
    # A pipeline-wrapped scalar also passes -is [pscustomobject]. It is not a map.
    if ($Value -is [string] -or $Value -is [ValueType] -or $Value -is [System.Collections.IEnumerable]) { throw 'Expected a configuration object, not a scalar or collection.' }
    if ($Value -isnot [pscustomobject]) { throw 'Expected a configuration object.' }
    $map = @{}; foreach ($p in $Value.PSObject.Properties) { $map[$p.Name] = $p.Value }; return $map
}
function Get-ExistingSafeConfig {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Config)
    $out = @{}
    foreach ($key in @('VMName','VMId','GPUName','GPUAllocation','AudioDriver','StreamingChoice','ConnectionMethod','SystemVhdPath','SystemPartitionNumber','WasRunning','SkipCleanup','SkipGpuDriverUpdate','ForceReinstallVDD','UseLegacyVDD')) {
        if ($Config.Contains($key)) { if($null -ne $Config[$key] -and $Config[$key] -isnot [string] -and $Config[$key] -isnot [ValueType]){throw 'Invalid scalar config field.'};$out[$key] = $Config[$key] }
    }
    $schemas = @{
        OfflineTargetIdentity = @('VhdPath','DiskUniqueId','PartitionIdentity','VolumeUniqueId','PartitionNumber')
        VDDConfig = @('MonitorCount','Resolution','RefreshRate','EnableHDR','GPUFriendlyName')
        SunshineStreamConfig = @('Resolution','RefreshRate','FPS','EnableHDR','Encoder','Bitrate','MinThreads','HEVCMode','AV1Mode','HDRMode','OutputName','OutputNameSource')
        InstallFilePaths = @('VCRedist','Sunshine','Parsec','ParsecVDA','NefCon','VDDDriver','VBCable','VirtualAudioDriver')
    }
    foreach ($name in $schemas.Keys) {
        $out[$name] = @{}
        if ($Config.Contains($name)) {
            $nested = ConvertTo-ExistingMap $Config[$name]
            foreach ($key in $schemas[$name]) { if ($nested.Contains($key)) { if($null -ne $nested[$key] -and $nested[$key] -isnot [string] -and $nested[$key] -isnot [ValueType]){throw 'Invalid nested config field.'};$out[$name][$key] = $nested[$key] } }
        }
    }
    if ($Config.Contains('GPUAllocationPolicy')) { $out.GPUAllocationPolicy = ConvertTo-GpuPVAllocationPolicy -Policy $Config.GPUAllocationPolicy }
    # Runtime credentials, SunshineConfig and ParsecConfig never enter this schema.
    Assert-ExistingSafeValues -Config $out
    return $out
}
function Assert-ExistingSafeValues {
    param([System.Collections.IDictionary]$Config)
    foreach($key in @('VMName','GPUName','AudioDriver','StreamingChoice','ConnectionMethod')) {
        if(-not $Config.Contains($key) -or $Config[$key] -isnot [string]){throw "Invalid or missing text field: $key"}
    }
    foreach($key in @('VMId','SystemVhdPath')) {
        if(-not $Config.Contains($key)){$Config[$key]=$null}
        elseif($null -ne $Config[$key] -and $Config[$key] -isnot [string]){throw "Invalid text field: $key"}
    }
    foreach($key in @('WasRunning','SkipCleanup','SkipGpuDriverUpdate','ForceReinstallVDD','UseLegacyVDD')) {
        if(-not $Config.Contains($key)){$Config[$key]=$false}
        elseif($Config[$key] -isnot [bool]){throw "Boolean field must contain true or false: $key"}
    }
    Assert-ExistingNumber -Value $Config['GPUAllocation'] -Minimum 1 -Maximum 100 -Name GPUAllocation
    if ($Config.Contains('GPUAllocationPolicy')) {
        $policy = ConvertTo-GpuPVAllocationPolicy -Policy $Config.GPUAllocationPolicy
        $legacyPercentage = if ($policy.Mode -eq 'Percent') { [decimal]$policy.Percentage } else { [decimal]50 }
        if ([decimal]$Config.GPUAllocation -ne $legacyPercentage) { throw 'GPUAllocation conflicts with GPUAllocationPolicy. Use the canonical percentage or 50 for VRAM mode.' }
    } else {
        $policy = New-GpuPVAllocationPolicy -Allocation ([Convert]::ToString($Config.GPUAllocation,[Globalization.CultureInfo]::InvariantCulture))
    }
    $Config.GPUAllocationPolicy = $policy
    if(-not $Config.Contains('SystemPartitionNumber')){$Config.SystemPartitionNumber=0}
    Assert-ExistingNumber -Value $Config.SystemPartitionNumber -Minimum 0 -Maximum 128 -Name SystemPartitionNumber -Integral
    if($Config.AudioDriver -notin @('None','VBCable','VirtualAudioDriver')){throw 'Unsupported AudioDriver.'}
    if($Config.StreamingChoice -notin @('None','Sunshine+VDD','Sunshine+ParsecVDA','Parsec+VDD','Parsec+ParsecVDA')){throw 'Unsupported StreamingChoice.'}
    if($Config.ConnectionMethod -notin @('Auto','KeepRdp')){throw 'Unsupported ConnectionMethod.'}
    $binding=$Config.OfflineTargetIdentity
    if($binding.Count -gt 0){$null=Get-ExistingTargetIdentity -Target $binding}
    $vdd=$Config.VDDConfig
    $defaults=@{MonitorCount=1;Resolution='1920x1080';RefreshRate=144;EnableHDR=$false}
    foreach($key in $defaults.Keys){if(-not $vdd.Contains($key)){$vdd[$key]=$defaults[$key]}}
    Assert-ExistingNumber -Value $vdd.MonitorCount -Minimum 1 -Maximum 1 -Name MonitorCount -Integral
    Assert-ExistingNumber -Value $vdd.RefreshRate -Minimum 1 -Maximum 1000 -Name RefreshRate -Integral
    if($vdd.Resolution -isnot [string] -or $vdd.Resolution -notmatch '^[1-9][0-9]{1,4}x[1-9][0-9]{1,4}$'){throw 'Invalid VDD resolution.'}
    if($vdd.EnableHDR -isnot [bool]){throw 'EnableHDR must be boolean.'}
    if($vdd.Contains('GPUFriendlyName') -and $vdd.GPUFriendlyName -isnot [string]){throw 'GPUFriendlyName must be text.'}
    $stream=$Config.SunshineStreamConfig
    foreach($key in @('HEVCMode','AV1Mode')){if($stream.Contains($key)){Assert-ExistingNumber -Value $stream[$key] -Minimum 0 -Maximum 3 -Name $key -Integral}}
    foreach($key in @('FPS','RefreshRate')){if($stream.Contains($key)){Assert-ExistingNumber -Value $stream[$key] -Minimum 1 -Maximum 1000 -Name $key -Integral}}
    foreach($key in @('Bitrate','MinThreads')){if($stream.Contains($key)){Assert-ExistingNumber -Value $stream[$key] -Minimum 0 -Maximum 1000000 -Name $key -Integral}}
    if($stream.Contains('EnableHDR') -and $stream.EnableHDR -isnot [bool]){throw 'Stream EnableHDR must be boolean.'}
    if($stream.Contains('HDRMode') -and $stream.HDRMode -notin @('auto','disabled')){throw 'Invalid HDRMode.'}
    foreach($key in @('Resolution','Encoder','OutputName','OutputNameSource')){if($stream.Contains($key) -and $stream[$key] -isnot [string]){throw "Invalid stream text field: $key"}}
    foreach($key in $Config.InstallFilePaths.Keys){if($Config.InstallFilePaths[$key] -isnot [string]){throw 'Installer path must be text.'}}
}
function Assert-ExistingNumber {
    param($Value,[decimal]$Minimum,[decimal]$Maximum,[string]$Name,[switch]$Integral)
    if($null -eq $Value -or [Type]::GetTypeCode($Value.GetType()) -notin @([TypeCode]::Byte,[TypeCode]::SByte,[TypeCode]::Int16,[TypeCode]::UInt16,[TypeCode]::Int32,[TypeCode]::UInt32,[TypeCode]::Int64,[TypeCode]::UInt64,[TypeCode]::Single,[TypeCode]::Double,[TypeCode]::Decimal)){throw "Expected numeric field: $Name"}
    if([double]::IsNaN([double]$Value) -or [double]::IsInfinity([double]$Value) -or $Value -lt $Minimum -or $Value -gt $Maximum){throw "Numeric field out of range: $Name"}
    if($Integral -and [math]::Truncate([decimal]$Value) -ne [decimal]$Value){throw "Expected integral field: $Name"}
}
function Get-ExistingStateName {
    param([Parameter(Mandatory)][string]$VMName)
    if ([string]::IsNullOrWhiteSpace($VMName)) { throw 'VMName is required before state lookup.' }
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $digest = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($VMName.ToUpperInvariant()))).Replace('-','').ToLowerInvariant() }
    finally { $sha.Dispose() }
    return ".gpupv-existing-v2-$digest.state.json"
}
function Get-ExistingPlan {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Config)
    $Config = Get-ExistingSafeConfig $Config
    $choice = [string]$Config.StreamingChoice
    if ($choice -notin @('None','Sunshine+VDD','Sunshine+ParsecVDA','Parsec+VDD','Parsec+ParsecVDA')) { throw 'Unsupported StreamingChoice.' }
    if ($Config.AudioDriver -notin @('VBCable','VirtualAudioDriver','None')) { throw 'Unsupported AudioDriver.' }
    if ($Config.ConnectionMethod -notin @('Auto','KeepRdp')) { throw 'Unsupported ConnectionMethod.' }
    if ($Config.Contains('UseLegacyVDD') -and $Config.UseLegacyVDD) { throw 'UseLegacyVDD is not supported by this verified installation path.' }
    $components = @()
    if ($choice -ne 'None' -or $Config.AudioDriver -ne 'None') { $components += 'VCRedist' }
    if ($choice -like 'Sunshine+*') { $components += 'Sunshine' }
    if ($choice -like 'Parsec+*') { $components += 'Parsec' }
    if ($choice -like '*+ParsecVDA') { $components += 'ParsecVDA' }
    if ($choice -like '*+VDD') { $components += @('NefCon','VDDDriver') }
    if ($Config.AudioDriver -eq 'VBCable') { $components += 'VBCable' }
    if ($Config.AudioDriver -eq 'VirtualAudioDriver') { $components += @('NefCon','VirtualAudioDriver') }
    $components = @($components | Select-Object -Unique)
    [pscustomobject]@{
        SchemaVersion = 2; EntryPoint = 'ExistingVM'; VMName = [string]$Config.VMName
        GPUAllocationPolicy = $Config.GPUAllocationPolicy
        GPUAllocationDescription = Format-GpuPVAllocationPolicy -Policy $Config.GPUAllocationPolicy
        Components = $components; TransferPayloads = ($components.Count -gt 0)
        CleanupGpuDrivers = (-not [bool]$Config.SkipCleanup -and -not [bool]$Config.SkipGpuDriverUpdate)
        CopyGpuDrivers = (-not [bool]$Config.SkipGpuDriverUpdate)
        RdpEnabled = ($Config.ConnectionMethod -eq 'KeepRdp')
        Phases = @(1,2,3,4,5,6,7)
        Requires = @('Confirmed VM identity','Unambiguous offline system volume','Validated installers','Runtime guest credential')
        ManualActions = $(if ($choice -like 'Sunshine+*') { @('Set up Sunshine account in its first-run UI; pair client and verify picture/audio manually') } else { @('Verify client connection, picture and audio manually') })
        ObservationStatus = 'PlanOnly: no VM, volume, package, service or guest was inspected'
    }
}
function ConvertFrom-ExistingState {
    param([Parameter(Mandatory)]$State,[Parameter(Mandatory)][string]$ExpectedVMName)
    $map = ConvertTo-ExistingMap $State
    if ($map.SchemaVersion -ne 2 -or $map.EntryPoint -ne 'ExistingVM') { throw 'Unsupported state schema or entry point. Preserve the old file and use ResetState to start a new task.' }
    $config = ConvertTo-ExistingMap $map.Config
    $config = ConvertFrom-GpuPVStoredAllocationConfig -Config $config -LegacyField GPUAllocation
    if ($config.VMName -ine $ExpectedVMName -or [string]::IsNullOrWhiteSpace([string]$config.VMId)) { throw 'State target identity is absent or does not match the requested VM.' }
    $id = [guid]::Empty
    if (-not [guid]::TryParse([string]$config.VMId,[ref]$id) -or $id -eq [guid]::Empty) { throw 'Invalid VM identity in state.' }
    if ($null -eq $map.CompletedSteps -or $map.CompletedSteps -is [string] -or $map.CompletedSteps -is [System.Collections.IDictionary] -or $map.CompletedSteps -isnot [System.Collections.IEnumerable]) { throw 'CompletedSteps must be an array.' }
    $steps = @()
    foreach ($s in $map.CompletedSteps) { if ($s -isnot [int] -and $s -isnot [long]) { throw 'Invalid completed phase type.' }; if ($s -lt 1 -or $s -gt 7) { throw 'Invalid completed phase value.' }; $steps += [int]$s }
    $steps = @($steps | Sort-Object -Unique)
    for ($i=0; $i -lt $steps.Count; $i++) { if ($steps[$i] -ne ($i+1)) { throw 'State phases must form a contiguous successful prefix.' } }
    $safe = Get-ExistingSafeConfig $config
    if($steps -contains 3 -and $safe.OfflineTargetIdentity.Count -eq 0){throw 'Saved Phase 3 has no offline disk/volume binding. Preserve the old state and use ResetState; legacy completion cannot authorize writes to the current disk.'}
    $null = Get-ExistingPlan $safe
    return @{ SchemaVersion = 2; EntryPoint = 'ExistingVM'; Config = $safe; CompletedSteps = $steps }
}
function Get-ExistingRunDecision {
    param([ValidateSet('Resume','Restart','RerunFrom')][string]$Mode,[int[]]$CompletedSteps = @(),[ValidateRange(0,7)][int]$StartFromStep = 0)
    $completed = @($CompletedSteps | Sort-Object -Unique)
    if ($Mode -eq 'Restart') { $completed = @(); $start = 1 }
    elseif ($Mode -eq 'RerunFrom') {
        if ($StartFromStep -lt 1) { throw 'RerunFrom requires StartFromStep 1 through 7.' }
        foreach ($previous in @(1..$StartFromStep | Where-Object { $_ -lt $StartFromStep })) { if ($completed -notcontains $previous) { throw 'Earlier successful phases are required before rerunning this phase.' } }
        $start = $StartFromStep; $completed = @($completed | Where-Object { $_ -lt $start })
    } else { $start = $completed.Count + 1 }
    $run = @(); if ($start -le 7) { $run = @($start..7) }
    return [pscustomobject]@{ CompletedSteps = $completed; RunSteps = $run; Mode = $Mode }
}
function Test-ExistingConfigValueEqual {
    param($Left,$Right)
    if($null -eq $Left -or $null -eq $Right){return ($null -eq $Left -and $null -eq $Right)}
    # Classify scalars before PSObject, which also matches wrapped strings/numbers.
    if($Left -is [bool] -or $Right -is [bool]){return ($Left -is [bool] -and $Right -is [bool] -and $Left -eq $Right)}
    if($Left -is [string] -or $Right -is [string]){return ($Left -is [string] -and $Right -is [string] -and $Left -ceq $Right)}
    $leftMap=$Left -is [System.Collections.IDictionary] -or ($Left -is [pscustomobject] -and $Left -isnot [ValueType] -and $Left -isnot [System.Collections.IEnumerable])
    $rightMap=$Right -is [System.Collections.IDictionary] -or ($Right -is [pscustomobject] -and $Right -isnot [ValueType] -and $Right -isnot [System.Collections.IEnumerable])
    if($leftMap -or $rightMap){
        if(-not($leftMap -and $rightMap)){return $false}
        $a=ConvertTo-ExistingMap $Left;$b=ConvertTo-ExistingMap $Right
        if($a.Count -ne $b.Count){return $false}
        foreach($key in $a.Keys){if(-not $b.Contains($key) -or -not(Test-ExistingConfigValueEqual $a[$key] $b[$key])){return $false}}
        return $true
    }
    try{Assert-ExistingNumber $Left ([decimal]::MinValue) ([decimal]::MaxValue) 'comparison';Assert-ExistingNumber $Right ([decimal]::MinValue) ([decimal]::MaxValue) 'comparison';return ([decimal]$Left -eq [decimal]$Right)}catch{return $false}
}
function Get-ExistingInstalledComponentNames {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Config)
    $plan=Get-ExistingPlan $Config
    $names=@($plan.Components|Where-Object {$_ -ne 'NefCon'}|ForEach-Object {if($_ -eq 'VDDDriver'){'VDD'}else{$_}})
    return ,$names
}
function Assert-ExistingInstallResult {
    param([Parameter(Mandatory)]$Result,[Parameter(Mandatory)][AllowEmptyCollection()][string[]]$ExpectedComponents)
    $map=ConvertTo-ExistingMap $Result
    foreach($key in @('SchemaVersion','Success','Components','RebootRequired')){if(-not $map.Contains($key)){throw "Guest result omitted $key."}}
    if(($map.SchemaVersion -isnot [int] -and $map.SchemaVersion -isnot [long]) -or $map.SchemaVersion -ne 1){throw 'Invalid guest result schema.'}
    if($map.Success -isnot [bool] -or -not $map.Success -or $map.RebootRequired -isnot [bool]){throw 'Guest result flags must be boolean and successful.'}
    if($null -eq $map.Components -or $map.Components -is [string] -or $map.Components -is [System.Collections.IDictionary] -or $map.Components -isnot [System.Collections.IEnumerable]){throw 'Guest component results must be an array.'}
    $actual=@();$componentReboot=$false
    foreach($entry in $map.Components){
        $component=ConvertTo-ExistingMap $entry
        foreach($key in @('Name','Status','Verified','ExitCode','RebootRequired')){if(-not $component.Contains($key)){throw "Guest component omitted $key."}}
        if($component.Name -isnot [string] -or $actual -contains $component.Name){throw 'Invalid or duplicate guest component name.'}
        if($component.Status -cne 'Installed' -or $component.Verified -isnot [bool] -or -not $component.Verified -or $component.RebootRequired -isnot [bool]){throw 'Guest component was not strictly verified.'}
        if(($component.ExitCode -isnot [int] -and $component.ExitCode -isnot [long]) -or $component.ExitCode -notin @(0,3010)){throw 'Guest component exit code was not successful.'}
        if(($component.ExitCode -eq 3010) -ne $component.RebootRequired){throw 'Guest component reboot flags contradict the exit code.'}
        $actual+=$component.Name;$componentReboot=$componentReboot -or $component.RebootRequired
    }
    if($actual.Count -ne $ExpectedComponents.Count -or @($ExpectedComponents|Where-Object{$actual -cnotcontains $_}).Count -gt 0){throw 'Guest component set does not match the requested plan.'}
    if($map.RebootRequired -ne $componentReboot){throw 'Guest aggregate reboot flag contradicts component results.'}
    if($map.RebootRequired){throw 'Installer requests guest reboot. State retained; reboot manually on an authorized host, then rerun Phase 6.'}
    return $true
}
function Get-ExistingTargetIdentity {
    param([Parameter(Mandatory)]$Target)
    $map=ConvertTo-ExistingMap $Target;$identity=@{}
    foreach($key in @('VhdPath','DiskUniqueId','PartitionIdentity','VolumeUniqueId')){
        if(-not $map.Contains($key) -or $map[$key] -isnot [string] -or [string]::IsNullOrWhiteSpace($map[$key])){throw "Missing offline target identity: $key"}
        $identity[$key]=$map[$key]
    }
    if($identity.VhdPath -notmatch '^[A-Za-z]:\\' -or $identity.VhdPath -match '[*?]'){throw 'Offline VHD identity must be an absolute literal local path.'}
    $identity.VhdPath=[IO.Path]::GetFullPath($identity.VhdPath)
    if(-not $map.Contains('PartitionNumber')){throw 'Missing offline partition number.'}
    Assert-ExistingNumber -Value $map.PartitionNumber -Minimum 1 -Maximum 128 -Name PartitionNumber -Integral
    $identity.PartitionNumber=[int]$map.PartitionNumber
    return $identity
}
function Assert-ExistingTargetIdentity {
    param([Parameter(Mandatory)]$Expected,[Parameter(Mandatory)]$Actual)
    $a=Get-ExistingTargetIdentity $Expected;$b=Get-ExistingTargetIdentity $Actual
    foreach($key in $a.Keys){if($a[$key] -ine $b[$key]){throw "Offline target changed ($key); no staged completion may apply to this disk."}}
    return $true
}
Export-ModuleMember -Function Get-ExistingTargetIdentity,Assert-ExistingTargetIdentity,ConvertTo-ExistingMap,Get-ExistingSafeConfig,Get-ExistingStateName,Get-ExistingPlan,ConvertFrom-ExistingState,Get-ExistingRunDecision,Get-ExistingInstalledComponentNames,Test-ExistingConfigValueEqual,Assert-ExistingInstallResult
