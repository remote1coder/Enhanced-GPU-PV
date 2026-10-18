<#
.SYNOPSIS
Configure an existing VM; PlanOnly/WhatIf emits a pure plan before VM inspection.
.NOTES
Live phases require an appropriate Hyper-V host. A plan does not validate that host.
#>
[CmdletBinding(SupportsShouldProcess=$true,ConfirmImpact='High')]
param(
 [string]$VMName,[string]$GPUName='AUTO',[string]$GPUAllocation='50',
 [string]$GPUComputePercentage,[string]$GPUEncodePercentage,[string]$GPUDecodePercentage,
 [ValidateRange(0,7)][int]$StartFromStep=0,[switch]$ResetState,[switch]$SkipHostChecks,
 [switch]$SkipCleanup,[switch]$SkipGpuDriverUpdate,[switch]$ForceReinstallVDD,[switch]$UseLegacyVDD,
 [switch]$PlanOnly,[string]$CredentialUserName,[SecureString]$CredentialPassword,
 [ValidateSet('VBCable','VirtualAudioDriver','None')][string]$AudioDriver='VBCable',
 [ValidateSet('None','Sunshine+VDD','Sunshine+ParsecVDA','Parsec+VDD','Parsec+ParsecVDA')][string]$StreamingChoice='None',
 [ValidateSet('Auto','KeepRdp')][string]$ConnectionMethod='KeepRdp',
 [hashtable]$VDDConfig=@{MonitorCount=1;Resolution='1920x1080';RefreshRate=144;EnableHDR=$false},
 [hashtable]$SunshineStreamConfig=@{HEVCMode=1;AV1Mode=1;HDRMode='disabled'},
 [string]$SystemVhdPath,[ValidateRange(0,128)][int]$SystemPartitionNumber=0
)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'GpuPV-Allocation.psm1') -Force -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'GpuPV-ExistingPlan.psm1') -Force -ErrorAction Stop
$allocationArguments=@{Allocation=$GPUAllocation}
$script:AllocationWasExplicit=$false
foreach($name in @('GPUAllocation','GPUComputePercentage','GPUEncodePercentage','GPUDecodePercentage')){
 if($PSBoundParameters.ContainsKey($name)){
  $script:AllocationWasExplicit=$true
  if($name -ne 'GPUAllocation'){$allocationArguments[$name.Substring(3)]=$PSBoundParameters[$name]}
 }
}
$initialAllocationPolicy=New-GpuPVAllocationPolicy @allocationArguments
$legacyAllocation=if($initialAllocationPolicy.Mode -eq 'Percent'){[decimal]$initialAllocationPolicy.Percentage}else{[decimal]50}
$script:Config=@{
 VMName=$VMName;VMId=$null;GPUName=$GPUName;GPUAllocation=$legacyAllocation;GPUAllocationPolicy=$initialAllocationPolicy;AudioDriver=$AudioDriver
 StreamingChoice=$StreamingChoice;ConnectionMethod=$ConnectionMethod;VDDConfig=$VDDConfig
 SunshineStreamConfig=$SunshineStreamConfig;InstallFilePaths=@{};SystemVhdPath=$SystemVhdPath
 SystemPartitionNumber=$SystemPartitionNumber;OfflineTargetIdentity=@{};WasRunning=$false;SkipCleanup=[bool]$SkipCleanup
 SkipGpuDriverUpdate=[bool]$SkipGpuDriverUpdate;ForceReinstallVDD=[bool]$ForceReinstallVDD;UseLegacyVDD=[bool]$UseLegacyVDD
}
# No operational imports, prompts, state access, transcript or host queries above this gate.
if($PlanOnly -or $WhatIfPreference){Get-ExistingPlan $script:Config;return}
$null=Get-ExistingPlan $script:Config
$script:InitialConfig=Get-ExistingSafeConfig $script:Config
$script:BoundConfiguration=@{}
foreach($k in @('GPUName','AudioDriver','StreamingChoice','ConnectionMethod','VDDConfig','SunshineStreamConfig','SystemVhdPath','SystemPartitionNumber','SkipCleanup','SkipGpuDriverUpdate','ForceReinstallVDD')){
 if($PSBoundParameters.ContainsKey($k)){$script:BoundConfiguration[$k]=$script:InitialConfig[$k]}
}
if($script:AllocationWasExplicit){$script:BoundConfiguration.GPUAllocationPolicy=$script:InitialConfig.GPUAllocationPolicy}
$script:Credential=$null;$script:StateData=@{CompletedSteps=@()};$script:ActivePhase=0;$script:StateLock=$null
Import-Module (Join-Path $PSScriptRoot 'Enhanced-GPU-PV-Common.psm1') -Force -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'GpuPV-Workflow.psm1') -Force -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'GpuPV-TargetSafety.psm1') -Force -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'Add-VMGpuPartitionAdapterFiles.psm1') -Force -ErrorAction Stop
function Get-StateFilePath{Join-Path $PSScriptRoot (Get-ExistingStateName $script:Config.VMName)}
function Save-State{
 param([ValidateRange(0,7)][int]$CompletedStep=0)
 $completed=@($script:StateData.CompletedSteps)
 if($CompletedStep -gt 0){$completed=@($completed+$CompletedStep|Sort-Object -Unique)}
 $data=@{SchemaVersion=2;EntryPoint='ExistingVM';Config=(Get-ExistingSafeConfig $script:Config);CompletedSteps=$completed;UpdatedUtc=[DateTime]::UtcNow.ToString('o')}
 $data.Config=ConvertTo-GpuPVStoredAllocationConfig -Config $data.Config -LegacyField GPUAllocation
 Write-GpuPVJsonAtomic -Path (Get-StateFilePath) -Value $data
 $script:StateData.CompletedSteps=$completed
}
function Import-State{
 $path=Get-StateFilePath
 if(-not(Test-Path -LiteralPath $path -PathType Leaf)){return $null}
 $data=Get-Content -LiteralPath $path -Raw -Encoding UTF8|ConvertFrom-Json
 ConvertFrom-ExistingState -State $data -ExpectedVMName $script:Config.VMName
}
function Backup-ExistingState {
 param([Parameter(Mandatory)][string]$Path)
 if(Test-Path -LiteralPath $Path -PathType Leaf){
  $backup="$Path.restart-$([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfff'))-$([guid]::NewGuid().ToString('N')).json"
  Copy-Item -LiteralPath $Path -Destination $backup -ErrorAction Stop
  return $backup
 }
}
function Get-ExistingVM{
 $matches=@(Get-VM -Name $script:Config.VMName -ErrorAction Stop)
 if($matches.Count -ne 1 -or $matches[0].Name -ine $script:Config.VMName){throw 'VM name must resolve to one exact VM.'}
 $vm=$matches[0]
 if($script:Config.VMId -and [string]$vm.Id -ine [string]$script:Config.VMId){throw 'VM identity changed; saved state cannot apply to another VM.'}
 if($vm.Generation -ne 2){throw 'Generation 2 VM required.'};return $vm
}
function Assert-ExistingAdministrator{
 $identity=[Security.Principal.WindowsIdentity]::GetCurrent();$principal=New-Object Security.Principal.WindowsPrincipal($identity)
 if(-not $principal.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)){throw 'Administrator privileges required for live execution.'}
 if(-not [Environment]::Is64BitProcess){throw '64-bit Windows PowerShell required.'}
}
function Set-ExistingInteractiveConfig{
 Write-Host 'Streaming: 1 Sunshine+VDD, 2 Parsec+ParsecVDA, 3 Sunshine+ParsecVDA, 4 Parsec+VDD, 5 None'
 $choices=@{'1'='Sunshine+VDD';'2'='Parsec+ParsecVDA';'3'='Sunshine+ParsecVDA';'4'='Parsec+VDD';'5'='None'}
 $selection=Read-Host 'Choose 1-5';if(-not $choices.ContainsKey($selection)){throw 'Invalid streaming selection.'}
 $script:Config.StreamingChoice=$choices[$selection]
 Write-Host 'Use VDDConfig/SunshineStreamConfig parameters for monitor and stream settings. Application accounts are set up manually in the application UI.'
 $null=Get-ExistingPlan $script:Config
}
function Ensure-ExistingCredential{
 if(-not $script:Credential){
  if($CredentialUserName -and $CredentialPassword){$script:Credential=New-Object System.Management.Automation.PSCredential($CredentialUserName,$CredentialPassword)}
  else{$script:Credential=Get-Credential -UserName $CredentialUserName -Message 'Guest credential for PowerShell Direct; never saved in state.'}
  if(-not $script:Credential){throw 'Guest credential required.'}
 }
}
function Stop-ExistingVMGracefully{
 $vm=Get-ExistingVM
 if($vm.State -in @('Saved','Paused')){throw 'Saved/paused VM requires an owner decision; no saved state is discarded.'}
 if($vm.State -eq 'Running'){
  Stop-VM -VM $vm -ErrorAction Stop;$deadline=[DateTime]::UtcNow.AddMinutes(3)
  do{$vm=Get-ExistingVM;if($vm.State -eq 'Off'){break};Start-Sleep -Seconds 3}while([DateTime]::UtcNow -lt $deadline)
 }
 if($vm.State -ne 'Off'){throw 'Clean shutdown failed. No force-off or disk write attempted.'};return $vm
}
function Get-ExistingOfflineTarget{
 param($VM)
 $target=Open-GpuPVOfflineTarget -VM $VM -VhdPath $script:Config.SystemVhdPath -PartitionNumber $script:Config.SystemPartitionNumber
 try{
  $identity=Get-ExistingTargetIdentity -Target $target
  if($script:Config.OfflineTargetIdentity.Count -gt 0){$null=Assert-ExistingTargetIdentity -Expected $script:Config.OfflineTargetIdentity -Actual $identity}
  else{
   $script:Config.OfflineTargetIdentity=$identity
   $script:Config.SystemVhdPath=$identity.VhdPath;$script:Config.SystemPartitionNumber=$identity.PartitionNumber
   Save-State
  }
  return $target
 }catch{Close-GpuPVOfflineTarget -Target $target;throw}
}
function Invoke-Phase1_HostChecks{
 $vm=Get-ExistingVM
 if(-not $SkipHostChecks){
  $feature=Get-WindowsOptionalFeature -Online -FeatureName 'Microsoft-Hyper-V-All' -ErrorAction Stop
  if($feature.State -ne 'Enabled'){throw 'Hyper-V must already be enabled; no host enable/reboot is performed.'}
  $os=Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
  if([int]$os.BuildNumber -lt 19041){throw 'Windows build 19041 or later required.'}
 }
 if([Version]$vm.Version -lt [Version]'8.0'){throw 'VM configuration version 8.0 or later required.'}
 if($vm.State -in @('Saved','Paused')){throw 'Resume or stop saved/paused VM manually first.'}
 Save-State -CompletedStep 1
}
function Get-ExistingPackageLabels{@{VCRedist='VC++ Redist';Sunshine='Sunshine';Parsec='Parsec';ParsecVDA='ParsecVDA';NefCon='NefCon';VDDDriver='VDD';VBCable='VB-Cable';VirtualAudioDriver='Virtual Audio Driver'}}
function Invoke-Phase2_PrepareFiles{
 $plan=Get-ExistingPlan $script:Config;$labels=Get-ExistingPackageLabels;$files=@{}
 foreach($name in $plan.Components){
  $policy=Get-GpuPVInstallerPolicy -DisplayName $labels[$name];$destination=Join-Path (Join-Path $PSScriptRoot 'Downloads') $policy.FileName
  $null=Invoke-DownloadWithCache -Url $policy.Url -DestinationPath $destination -DisplayName $labels[$name]
  if(-not(Test-Path -LiteralPath $destination -PathType Leaf)){throw 'Verified download helper did not produce required package.'};$files[$name]=$destination
 }
 $script:Config.InstallFilePaths=$files;Save-State -CompletedStep 2
}
function Copy-ExistingPayloads{
 param($Target)
 $plan=Get-ExistingPlan $script:Config;if(-not $plan.TransferPayloads){return}
 $dest=Join-Path $Target.Root 'ProgramData\Easy-GPU-P\Installers';$null=Assert-GpuPVTargetPath -Target $Target -Path $dest
 New-Item -ItemType Directory -Path $dest -Force -ErrorAction Stop|Out-Null;$labels=Get-ExistingPackageLabels;$manifest=@{}
 foreach($name in $plan.Components){
  $policy=Get-GpuPVInstallerPolicy -DisplayName $labels[$name];$source=[string]$script:Config.InstallFilePaths[$name]
  if([string]::IsNullOrWhiteSpace($source)){throw 'Payload absent from state; rerun Phase 2.'}
  Assert-GpuPVArtifact -Path $source -ExpectedSha256 $policy.Sha256 -ExpectedSize $policy.Size
  $targetPath=Join-Path $dest $policy.FileName;$null=Assert-GpuPVTargetPath -Target $Target -Path $targetPath
  Copy-Item -LiteralPath $source -Destination $targetPath -Force -ErrorAction Stop
  Assert-GpuPVArtifact -Path $targetPath -ExpectedSha256 $policy.Sha256 -ExpectedSize $policy.Size
  $component=if($name -eq 'VDDDriver'){'VDD'}else{$name}
  $manifest[$component]=@{FileName=$policy.FileName;Sha256=$policy.Sha256;Size=(Get-Item -LiteralPath $targetPath -ErrorAction Stop).Length;Version=$policy.Version}
 }
 foreach($helper in @('PostBoot-Installer.ps1','Activate-VDD.ps1')){
  $destination=Join-Path $dest $helper;$null=Assert-GpuPVTargetPath -Target $Target -Path $destination
  Copy-Item -LiteralPath (Join-Path $PSScriptRoot "VMScripts\$helper") -Destination $destination -Force -ErrorAction Stop
 }
 $cfgPath=Join-Path $dest 'config.json';$null=Assert-GpuPVTargetPath -Target $Target -Path $cfgPath
 $safe=Get-ExistingSafeConfig $script:Config;$safe.Remove('InstallFilePaths');$safe.Remove('SystemVhdPath')
 $safe.InstallerFiles=$manifest;$safe.SecurityModel='HostDownload';$safe.VDDConfig.HDR=[bool]$safe.VDDConfig.EnableHDR
 Write-GpuPVJsonAtomic -Path $cfgPath -Value $safe
}
function Invoke-Phase3_CleanupVM{
 $vm=Stop-ExistingVMGracefully;$target=$null
 try{
  $target=Get-ExistingOfflineTarget -VM $vm;$null=Assert-GpuPVTarget -Target $target;$plan=Get-ExistingPlan $script:Config
  if($plan.CleanupGpuDrivers){Remove-VMGpuPartitionAdapterFiles -Target $target -GPUName $script:Config.GPUName -ErrorAction Stop}
  Copy-ExistingPayloads -Target $target
 }finally{if($target){Close-GpuPVOfflineTarget -Target $target}}
 Save-State -CompletedStep 3
}
function Invoke-Phase4_VMConfigFix{
 $vm=Stop-ExistingVMGracefully
 Set-VM -VM $vm -StaticMemory -AutomaticCheckpointsEnabled $false -ErrorAction Stop
 Set-VMGpuPartitionSettings -VMName $script:Config.VMName
 Save-State -CompletedStep 4
}
function Invoke-Phase5_ConfigureGpuPV{
 $vm=Stop-ExistingVMGracefully;$target=$null
 if(-not $script:Config.SkipGpuDriverUpdate){
  try{$target=Get-ExistingOfflineTarget -VM $vm;$null=Assert-GpuPVTarget -Target $target;Add-VMGpuPartitionAdapterFiles -Target $target -GPUName $script:Config.GPUName -ErrorAction Stop}
  finally{if($target){Close-GpuPVOfflineTarget -Target $target}}
 }
 Assign-VMGPUPartitionAdapter -VMName $script:Config.VMName -GPUName $script:Config.GPUName -AllocationPolicy $script:Config.GPUAllocationPolicy
 Save-State -CompletedStep 5
}
function Ensure-ExistingGuestReady{
 Ensure-ExistingCredential;$vm=Get-ExistingVM
 if($vm.State -eq 'Off'){Start-VM -VM $vm -ErrorAction Stop|Out-Null}elseif($vm.State -ne 'Running'){throw 'Guest must be Off or Running; no saved-state conversion attempted.'}
 $ready=$false;$deadline=[DateTime]::UtcNow.AddMinutes(3)
 do{
  try{$ready=(Invoke-Command -VMId $script:Config.VMId -Credential $script:Credential -ScriptBlock {$true} -ErrorAction Stop) -eq $true}catch{$ready=$false}
  if(-not $ready){Start-Sleep -Seconds 3}
 }while(-not $ready -and [DateTime]::UtcNow -lt $deadline)
 if(-not $ready){throw 'PowerShell Direct not ready with supplied guest credential.'}
}
function Set-ExistingGuestRdp{
 $enabled=(Get-ExistingPlan $script:Config).RdpEnabled
 $results=@(Invoke-Command -VMId $script:Config.VMId -Credential $script:Credential -ErrorAction Stop -ScriptBlock (Get-GpuPVGuestRdpConfigurationScript) -ArgumentList $enabled)
 if($results.Count -ne 1 -or $results[0].SettingsApplied -isnot [bool] -or -not $results[0].SettingsApplied){throw 'Expected one guest RDP settings result.'}
 $null=Test-ExistingGuestRdp
}
function Test-ExistingGuestRdp {
 $enabled=(Get-ExistingPlan $script:Config).RdpEnabled
 $observed=@(Invoke-Command -VMId $script:Config.VMId -Credential $script:Credential -ErrorAction Stop -ScriptBlock (Get-GpuPVGuestRdpObservationScript) -ArgumentList $enabled)
 if($observed.Count -ne 1 -or $observed[0].ConfigurationVerified -isnot [bool] -or -not $observed[0].ConfigurationVerified){throw 'Expected one strictly verified RDP observation.'}
 return $observed[0]
}
function Get-ExistingVddActivationScript{
 Get-Content -LiteralPath (Join-Path $PSScriptRoot 'VMScripts\Activate-VDD.ps1') -Raw -ErrorAction Stop
}
function Invoke-Phase6_InstallSoftware{
 Ensure-ExistingGuestReady;$plan=Get-ExistingPlan $script:Config
 if($plan.TransferPayloads){
  $results=@(Invoke-Command -VMId $script:Config.VMId -Credential $script:Credential -ErrorAction Stop -ScriptBlock {
   $ErrorActionPreference='Stop';$dir='C:\ProgramData\Easy-GPU-P\Installers';$entry=Join-Path $dir 'PostBoot-Installer.ps1'
   if(-not(Test-Path -LiteralPath $entry -PathType Leaf)){throw 'Staged installer missing; rerun Phase 3.'}
   & $entry -ConfigJsonPath (Join-Path $dir 'config.json') -InstallersDir $dir
  })
  $structured=@($results|Where-Object {$null -ne $_ -and $_.PSObject.Properties['SchemaVersion'] -and $_.PSObject.Properties['Success']})
  if($structured.Count -ne 1){throw 'Expected one structured guest installation result.'}
  $null=Assert-ExistingInstallResult -Result $structured[0] -ExpectedComponents (Get-ExistingInstalledComponentNames $script:Config)
 }
 Set-ExistingGuestRdp
 if($script:Config.ConnectionMethod -eq 'KeepRdp' -and $script:Config.StreamingChoice -like '*+VDD'){
  $activation=Get-ExistingVddActivationScript
  Invoke-Command -VMId $script:Config.VMId -Credential $script:Credential -ErrorAction Stop -ScriptBlock {
   param($Content)
   Set-Content -LiteralPath (Join-Path ([Environment]::GetFolderPath('Desktop')) 'Activate-VDD.ps1') -Value $Content -Encoding UTF8 -ErrorAction Stop
  } -ArgumentList $activation
 }
 Save-State -CompletedStep 6
}
function Invoke-Phase7_VerifyOutput{
 # Reconstruct runtime credentials even for an isolated Phase 7 rerun.
 Ensure-ExistingGuestReady
 if((Get-ExistingPlan $script:Config).TransferPayloads){
  $results=@(Invoke-Command -VMId $script:Config.VMId -Credential $script:Credential -ErrorAction Stop -ScriptBlock {
   $dir='C:\ProgramData\Easy-GPU-P\Installers'
   & (Join-Path $dir 'PostBoot-Installer.ps1') -ConfigJsonPath (Join-Path $dir 'config.json') -InstallersDir $dir -VerifyOnly
  })
  $checked=@($results|Where-Object{$null -ne $_ -and $_.PSObject.Properties['SchemaVersion'] -and $_.PSObject.Properties['Components']})
  if($checked.Count -ne 1){throw 'Expected one verification result.'}
  $null=Assert-ExistingInstallResult -Result $checked[0] -ExpectedComponents (Get-ExistingInstalledComponentNames $script:Config)
 }
 $adapter=@(Get-VMGpuPartitionAdapter -VMName $script:Config.VMName -ErrorAction Stop)
 if($adapter.Count -ne 1){throw 'Exactly one GPU-PV adapter must be present.'}
 $observed=Invoke-Command -VMId $script:Config.VMId -Credential $script:Credential -ErrorAction Stop -ScriptBlock {
  param($Choice,$Audio,$KeepRdp)
  $ErrorActionPreference='Stop';$result=@{}
  $gpu=@(Get-PnpDevice -Class Display -ErrorAction Stop|Where-Object{$_.Status -eq 'OK' -and $_.FriendlyName -notmatch 'Basic|Remote|Virtual|Hyper-V|Microsoft'})
  if($gpu.Count -lt 1){throw 'Guest GPU device not healthy.'}
  if($Choice -like '*+VDD'){
   $vdd=@(Get-PnpDevice -Class Display -ErrorAction Stop|Where-Object{$_.FriendlyName -match 'Virtual Display Driver|IddSampleDriver' -and $_.Status -eq 'OK'})
   if($vdd.Count -lt 1){throw 'Required VDD device missing or unhealthy.'};$result.VDD='DeviceHealthy'
  }
  if($Choice -like 'Sunshine+*'){
   $svc=@(Get-Service -ErrorAction Stop|Where-Object{$_.Name -match 'Sunshine'})
   if($svc.Count -ne 1 -or $svc[0].Status -ne 'Running'){throw 'Sunshine service absent, ambiguous or stopped.'};$result.Sunshine='ServiceRunning; account/pairing/picture unverified'
  }
  if($Choice -like 'Parsec+*'){
   if(-not(Test-Path -LiteralPath (Join-Path $env:ProgramFiles 'Parsec\parsecd.exe') -PathType Leaf)){throw 'Parsec executable not detected.'};$result.Parsec='FilesPresent; login/stream unverified'
  }
  if($Choice -like '*+ParsecVDA'){
   $dev=@(Get-PnpDevice -Class Display -ErrorAction Stop|Where-Object{$_.FriendlyName -match 'Parsec' -and $_.Status -eq 'OK'})
   if($dev.Count -lt 1){throw 'Parsec virtual display not healthy.'};$result.ParsecVDA='DeviceHealthy'
  }
  if($Audio -ne 'None'){
   $pattern=if($Audio -eq 'VBCable'){'VB-Audio|CABLE'}else{'Virtual Audio|VirtualAudioDriver'}
   $dev=@(Get-PnpDevice -Class MEDIA -ErrorAction Stop|Where-Object{$_.FriendlyName -match $pattern -and $_.Status -eq 'OK'})
   if($dev.Count -lt 1){throw 'Required audio device missing or unhealthy.'};$result.Audio='DeviceHealthy; audible output unverified'
  }
  $key='HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server'
  $deny=[int](Get-ItemProperty -LiteralPath $key -Name fDenyTSConnections -ErrorAction Stop).fDenyTSConnections
  if(($deny -eq 0) -ne $KeepRdp){throw 'RDP setting contradicts ConnectionMethod.'}
  $result.RdpEnabled=($deny -eq 0);$result.RdpPort=(Get-ItemProperty -LiteralPath "$key\WinStations\RDP-Tcp" -Name PortNumber).PortNumber
  $result.RemoteLoginVerified=$false;$result.StreamingVerified=$false;[pscustomobject]$result
 } -ArgumentList $script:Config.StreamingChoice,$script:Config.AudioDriver,($script:Config.ConnectionMethod -eq 'KeepRdp')
 $rdpObserved=Test-ExistingGuestRdp
 $observed|Add-Member -NotePropertyName RdpObservation -NotePropertyValue $rdpObserved -Force
 Write-Host 'Automated component checks passed; client login, pairing, picture/HDR and audio require manual acceptance.'
 $observed|Format-List|Out-Host
 foreach($action in (Get-ExistingPlan $script:Config).ManualActions){Write-Host $action}
 Save-State -CompletedStep 7
}
function Start-MainFlow{
 Assert-ExistingAdministrator
 if([string]::IsNullOrWhiteSpace($script:Config.VMName)){$script:Config.VMName=Read-Host 'Exact VM name'}
 if([string]::IsNullOrWhiteSpace($script:Config.VMName) -or $script:Config.VMName -match '[*?\[\]]'){throw 'Supply nonempty exact VM name without wildcards.'}
 $script:InitialConfig.VMName=$script:Config.VMName;$path=Get-StateFilePath
 $script:StateLock=[IO.File]::Open("$path.lock",[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
 $loaded=$null
 if(-not $ResetState){
  $loaded=Import-State;$legacyName=$script:Config.VMName -replace '[\\/:*?"<>|]','_'
  if(-not $loaded -and (Test-Path -LiteralPath (Join-Path $PSScriptRoot ".gpupv-config-$legacyName.state.json"))){throw 'Legacy state may contain secrets. It was not loaded/deleted; protect it separately, then use ResetState for a new task.'}
 }
 $mode='Restart'
 if($loaded){
  $mode=if($StartFromStep -gt 0){'RerunFrom'}else{'Resume'}
  if($StartFromStep -eq 0){$answer=Read-Host 'Resume previous task? Y resumes; N restarts with current parameters';if($answer -notin @('Y','y','N','n')){throw 'Cancelled; reply Y or N.'};if($answer -in @('N','n')){$mode='Restart'}}
  if($mode -ne 'Restart'){
   foreach($key in $script:BoundConfiguration.Keys){
    if(-not(Test-ExistingConfigValueEqual $script:BoundConfiguration[$key] $loaded.Config[$key])){throw "Explicit setting differs from saved state ($key); use ResetState to use new settings."}
   }
   $script:Config=$loaded.Config;$script:StateData=@{CompletedSteps=@($loaded.CompletedSteps)}
  }
 }elseif($StartFromStep -gt 1){throw 'Starting after Phase 1 requires saved prior successful phases.'}
 if($mode -eq 'Restart'){
  $script:Config=Get-ExistingSafeConfig $script:InitialConfig;$script:StateData=@{CompletedSteps=@()}
  if(-not $script:AllocationWasExplicit){
   $script:Config.GPUAllocationPolicy=Read-GpuPVAllocationPolicy -DefaultPercentage 50
   $script:Config.GPUAllocation=if($script:Config.GPUAllocationPolicy.Mode -eq 'Percent'){[decimal]$script:Config.GPUAllocationPolicy.Percentage}else{[decimal]50}
   $script:Config=Get-ExistingSafeConfig $script:Config
  }
  if(-not $script:BoundConfiguration.ContainsKey('StreamingChoice')){Set-ExistingInteractiveConfig}
 }
 if($mode -eq 'Restart'){$null=Backup-ExistingState -Path $path}
 $decision=Get-ExistingRunDecision -Mode $mode -CompletedSteps $script:StateData.CompletedSteps -StartFromStep $StartFromStep
 $script:StateData.CompletedSteps=@($decision.CompletedSteps);$vm=Get-ExistingVM
 if(-not $script:Config.VMId){$script:Config.VMId=[string]$vm.Id;$script:Config.WasRunning=($vm.State -eq 'Running')}
 if($decision.RunSteps.Count -eq 0){Write-Host 'Automated phases already recorded complete. Rerun Phase 7 for a fresh observation; client acceptance remains separate.';return}
 Save-State
 foreach($step in $decision.RunSteps){
  $script:ActivePhase=$step
  if(-not $script:EntryCmdlet.ShouldProcess($script:Config.VMName,"Execute ExistingVM phase $step")){throw 'Phase declined; state retained.'}
  switch($step){1{Invoke-Phase1_HostChecks}2{Invoke-Phase2_PrepareFiles}3{Invoke-Phase3_CleanupVM}4{Invoke-Phase4_VMConfigFix}5{Invoke-Phase5_ConfigureGpuPV}6{Invoke-Phase6_InstallSoftware}7{Invoke-Phase7_VerifyOutput}}
 }
 Write-Host 'Automated phases completed; state retained for audit/rerun. Real client acceptance is not inferred.'
}
$script:EntryCmdlet=$PSCmdlet
try{Start-MainFlow}catch{
 # Remote exceptions can include installer arguments. Do not log raw exception text.
 Write-Error "ExistingVM stopped at phase $script:ActivePhase ($($_.Exception.GetType().Name)). State retained; no credential or raw remote exception logged." -ErrorAction Continue
 exit 1
}finally{if($script:StateLock){$script:StateLock.Dispose()};$script:Credential=$null;$CredentialPassword=$null}