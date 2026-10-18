# Workflow primitives. Importing this module does not query or modify the host.
Import-Module (Join-Path $PSScriptRoot 'GpuPV-Allocation.psm1') -Force -ErrorAction Stop
function Get-GpuPVStreamingPlan {
 param([Parameter(Mandatory=$true)][ValidateSet('None','Parsec+ParsecVDA','Parsec+VDD','Sunshine+VDD','Sunshine+ParsecVDA')][string]$Choice)
 [pscustomobject]@{Parsec=($Choice -in @('Parsec+ParsecVDA','Parsec+VDD'));Sunshine=($Choice -in @('Sunshine+ParsecVDA','Sunshine+VDD'));ParsecVDA=($Choice -in @('Parsec+ParsecVDA','Sunshine+ParsecVDA'));VDD=($Choice -in @('Parsec+VDD','Sunshine+VDD'))}
}
function ConvertTo-GpuPVHashtable {
 param($Value)
 if ($null -eq $Value) { return $null }
 if ($Value -is [string] -or $Value -is [ValueType]) { return $Value }
 if ($Value -is [System.Collections.IDictionary]) { $h=@{};foreach($k in $Value.Keys){$h[$k]=ConvertTo-GpuPVHashtable $Value[$k]};return $h }
 if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) { $a=@();foreach($v in $Value){$a+=,(ConvertTo-GpuPVHashtable $v)};return ,$a }
 if ($Value -is [pscustomobject]) { $h=@{};foreach($p in $Value.PSObject.Properties){$h[$p.Name]=ConvertTo-GpuPVHashtable $p.Value};return $h }
 return $Value
}
function Get-GpuPVPhaseSet {
 param($Value)
 if ($null -eq $Value) { return ,@() }
 if ($Value -is [string] -or $Value -is [System.Collections.IDictionary] -or $Value -isnot [System.Collections.IEnumerable]) { throw 'PhaseCompleted must be an array.' }
 $a=@();foreach($p in $Value){if($p -isnot [string] -or $p -notmatch '^Phase[1-7]$'){throw 'Invalid checkpoint phase.'};if($a -notcontains $p){$a+=$p}};return ,$a
}
function Assert-GpuPVNumericField {
 param($Value,[decimal]$Minimum,[decimal]$Maximum,[string]$Name,[switch]$Integral,[switch]$AllowText)
 if($Value -is [string]){
  if(-not $AllowText -or $Value -notmatch '^\d+(\.\d+)?$'){throw "Invalid numeric field: $Name"}
  $number=[decimal]::Parse($Value,[Globalization.CultureInfo]::InvariantCulture)
 } else {
  if($null -eq $Value -or [Type]::GetTypeCode($Value.GetType()) -notin @([TypeCode]::Byte,[TypeCode]::SByte,[TypeCode]::Int16,[TypeCode]::UInt16,[TypeCode]::Int32,[TypeCode]::UInt32,[TypeCode]::Int64,[TypeCode]::UInt64,[TypeCode]::Single,[TypeCode]::Double,[TypeCode]::Decimal)){throw "Invalid numeric type: $Name"}
  if([double]::IsNaN([double]$Value) -or [double]::IsInfinity([double]$Value)){throw "Nonfinite number: $Name"}
  $number=[decimal]$Value
 }
 if($number -lt $Minimum -or $number -gt $Maximum -or ($Integral -and [decimal]::Truncate($number) -ne $number)){throw "Numeric field out of range: $Name"}
}
function Assert-GpuPVCheckpointFields {
 param([hashtable]$Config)
 foreach($key in @('SourcePath','VHDPath','VhdFormat','DiskLayout','NetworkSwitch','GPUName','StreamingChoice','SecurityModel','ConnectionMethod','AudioDriver','Username','Language','Timezone','Team_ID','TargetVMId')){
  if($Config.ContainsKey($key) -and $null -ne $Config[$key] -and $Config[$key] -isnot [string]){throw "Expected text: $key"}
 }
 foreach($key in @('CPUCores','MemoryAmount','SizeBytes')){if($Config.ContainsKey($key)){Assert-GpuPVNumericField $Config[$key] 1 ([long]::MaxValue) $key -Integral}}
 if($Config.ContainsKey('GPUResourceAllocationPercentage')){Assert-GpuPVNumericField $Config.GPUResourceAllocationPercentage 1 100 'GPUResourceAllocationPercentage'}
 if($Config.ContainsKey('GPUAllocationPolicy')){
  $policy=ConvertTo-GpuPVAllocationPolicy -Policy $Config.GPUAllocationPolicy
  $legacyPercentage=if($policy.Mode -eq 'Percent'){[decimal]$policy.Percentage}else{[decimal]50}
  if($Config.ContainsKey('GPUResourceAllocationPercentage') -and [decimal]$Config.GPUResourceAllocationPercentage -ne $legacyPercentage){throw 'GPUResourceAllocationPercentage conflicts with GPUAllocationPolicy. Use the canonical percentage or 50 for VRAM mode.'}
  $Config.GPUResourceAllocationPercentage=$legacyPercentage
 }else{
  $allocation=if($Config.ContainsKey('GPUResourceAllocationPercentage')){[Convert]::ToString($Config.GPUResourceAllocationPercentage,[Globalization.CultureInfo]::InvariantCulture)}else{'50'}
  $policy=New-GpuPVAllocationPolicy -Allocation $allocation
  $Config.GPUResourceAllocationPercentage=[decimal]$policy.Percentage
 }
 $Config.GPUAllocationPolicy=$policy
 $enums=@{StreamingChoice=@('None','Parsec+ParsecVDA','Parsec+VDD','Sunshine+VDD','Sunshine+ParsecVDA');SecurityModel=@('HostDownload');ConnectionMethod=@('Auto','KeepRdp');AudioDriver=@('None','VBCable','VirtualAudioDriver');VhdFormat=@('VHD','VHDX');DiskLayout=@('UEFI','BIOS')}
 foreach($key in $enums.Keys){if($Config.ContainsKey($key) -and $null -ne $Config[$key] -and $Config[$key] -notin $enums[$key]){throw "Invalid checkpoint choice: $key"}}
 if($Config.ContainsKey('Autologon') -and $Config.Autologon -isnot [bool] -and ($Config.Autologon -isnot [string] -or $Config.Autologon -notin @('true','false'))){throw 'Autologon must be true or false.'}
 if($Config.TargetVMId){$id=[guid]::Empty;if(-not [guid]::TryParse([string]$Config.TargetVMId,[ref]$id) -or $id -eq [guid]::Empty){throw 'Invalid target VM GUID.'}}
 if($null -ne $Config.VDDConfig){
  $v=ConvertTo-GpuPVHashtable $Config.VDDConfig
  if($v -isnot [hashtable]){throw 'VDDConfig must be an object.'}
  if($v.ContainsKey('GPUFriendlyName') -and $v.GPUFriendlyName -isnot [string]){throw 'GPUFriendlyName must be text.'}
  if($v.ContainsKey('HDR') -and $v.HDR -isnot [bool]){throw 'VDD HDR must be boolean.'}
  if($v.ContainsKey('Resolution') -and ($v.Resolution -isnot [string] -or $v.Resolution -notmatch '^[1-9][0-9]{1,4}x[1-9][0-9]{1,4}$')){throw 'Invalid VDD resolution.'}
  if($v.ContainsKey('RefreshRate')){Assert-GpuPVNumericField $v.RefreshRate 1 1000 'VDD RefreshRate' -Integral -AllowText}
 }
 if($null -ne $Config.SunshineStreamConfig){
  $v=ConvertTo-GpuPVHashtable $Config.SunshineStreamConfig
  if($v -isnot [hashtable]){throw 'SunshineStreamConfig must be an object.'}
  foreach($key in @('HEVCMode','AV1Mode')){if($v.ContainsKey($key)){Assert-GpuPVNumericField $v[$key] 0 3 $key -Integral -AllowText}}
  if($v.ContainsKey('FPS')){Assert-GpuPVNumericField $v.FPS 1 1000 'FPS' -Integral -AllowText}
  if($v.ContainsKey('Bitrate')){Assert-GpuPVNumericField $v.Bitrate 0 1000000 'Bitrate' -Integral -AllowText}
  if($v.ContainsKey('HDRMode') -and $v.HDRMode -notin @('auto','disabled')){throw 'Invalid Sunshine HDRMode.'}
 }
}
function Get-GpuPVCheckpoint {
 param([Parameter(Mandatory=$true)][hashtable]$Config)
 Assert-GpuPVCheckpointFields $Config
 if ($Config.VMName -isnot [string] -or [string]$Config.VMName -notmatch '^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$') {throw 'Invalid VM identity in checkpoint.'}
 $s=@{SchemaVersion=2;EntryPoint='NewVmHostDownload';VMName=[string]$Config.VMName;PhaseCompleted=(Get-GpuPVPhaseSet $Config.PhaseCompleted)}
 $fields=@('SourcePath','VHDPath','Edition','VhdFormat','DiskLayout','SizeBytes','MemoryAmount','CPUCores','NetworkSwitch','GPUName','GPUResourceAllocationPercentage','StreamingChoice','SecurityModel','ConnectionMethod','AudioDriver','Username','Autologon','Language','Timezone','Team_ID','TargetVMId')
 foreach($f in $fields){if($Config.ContainsKey($f) -and $null -ne $Config[$f]){if($Config[$f] -isnot [string] -and $Config[$f] -isnot [ValueType]){throw "Invalid checkpoint field type: $f"};$s[$f]=$Config[$f]}}
 $s.GPUAllocationPolicy=ConvertTo-GpuPVAllocationPolicy -Policy $Config.GPUAllocationPolicy
 $nested=@{SunshineStreamConfig=@('Preset','Resolution','FPS','HEVCMode','AV1Mode','HDRMode','Bitrate','OutputName','OutputNameSource');VDDConfig=@('Resolution','RefreshRate','HDR','GPUFriendlyName');InstallFilePaths=@('SunshineInstaller','VDDZip','ParsecInstaller','ParsecVDAInstaller','VBCableZip','VirtualAudioDriverZip','NefConZip','VCRedist')}
 foreach($n in $nested.Keys){$s[$n]=@{};if($null -ne $Config[$n]){$v=ConvertTo-GpuPVHashtable $Config[$n];if($v -isnot [hashtable]){throw "Invalid checkpoint object: $n"};foreach($f in $nested[$n]){if($v.ContainsKey($f) -and $null -ne $v[$f]){if($v[$f] -isnot [string] -and $v[$f] -isnot [ValueType]){throw "Invalid checkpoint field type: $n.$f"};$s[$n][$f]=$v[$f]}}}}
 return $s
}
function Write-GpuPVJsonAtomic {
 param([Parameter(Mandatory=$true)][string]$Path,[Parameter(Mandatory=$true)]$Value)
 $full=[IO.Path]::GetFullPath($Path);$parent=[IO.Path]::GetDirectoryName($full)
 if(-not [IO.Directory]::Exists($parent)){throw 'Checkpoint parent directory is missing.'}
 $temporary=Join-Path $parent ('.checkpoint-'+[guid]::NewGuid().ToString('N')+'.tmp')
 try{$json=$Value|ConvertTo-Json -Depth 12;[IO.File]::WriteAllText($temporary,$json,(New-Object Text.UTF8Encoding($false)));if([IO.File]::Exists($full)){[IO.File]::Replace($temporary,$full,[System.Management.Automation.Language.NullString]::Value)}else{[IO.File]::Move($temporary,$full)}}finally{if([IO.File]::Exists($temporary)){[IO.File]::Delete($temporary)}}
}
function Read-GpuPVCheckpoint {
 param([string]$Path,[string]$ExpectedVMName)
 if(-not(Test-Path -LiteralPath $Path)){return $null}
 try{$s=ConvertTo-GpuPVHashtable (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop|ConvertFrom-Json -ErrorAction Stop)}catch{throw 'Checkpoint is unreadable or invalid JSON; it was not reset.'}
 if($s -isnot [hashtable] -or ($s.SchemaVersion -isnot [int] -and $s.SchemaVersion -isnot [long]) -or $s.SchemaVersion -ne 2 -or $s.EntryPoint -ne 'NewVmHostDownload'){throw 'Unsupported checkpoint schema/entry point. Preserve it and explicitly restart; legacy secrets are not imported.'}
 if($ExpectedVMName -and $s.VMName -ine $ExpectedVMName){throw 'Checkpoint belongs to a different VM.'}
 if(-not $s.ContainsKey('PhaseCompleted') -or $null -eq $s.PhaseCompleted){throw 'Checkpoint is missing its completed phase array.'}
 $phases=@(Get-GpuPVPhaseSet $s.PhaseCompleted | ForEach-Object {$_} | Sort-Object)
 for($i=0;$i -lt $phases.Count;$i++){if($phases[$i] -cne ('Phase'+($i+1))){throw 'Checkpoint phases must form a contiguous successful prefix.'}}
 if($phases -contains 'Phase3' -and [string]::IsNullOrWhiteSpace([string]$s.TargetVMId)){throw 'A created VM checkpoint must retain its target GUID.'}
 $s=ConvertFrom-GpuPVStoredAllocationConfig -Config $s -LegacyField GPUResourceAllocationPercentage
 return (Get-GpuPVCheckpoint $s)
}
function Get-GpuPVRemainingPhases {
 param([hashtable]$Config,[ValidateSet('','Phase1','Phase2','Phase3','Phase4','Phase5','Phase6','Phase7')][string]$StartFromStep='')
 $complete=Get-GpuPVPhaseSet $Config.PhaseCompleted;$all=@('Phase1','Phase2','Phase3','Phase4','Phase5','Phase6','Phase7')
 if($StartFromStep){$start=$all.IndexOf($StartFromStep);$complete=@($complete|Where-Object{$all.IndexOf($_) -lt $start})}
 $all|Where-Object{$complete -notcontains $_}
}
function Invoke-GpuPVPostBootWorkflow {
 param([hashtable]$Config,[scriptblock]$WaitReady,[scriptblock]$Install,[scriptblock]$Verify,[scriptblock]$SavePhase)
 if(@(Get-GpuPVRemainingPhases $Config|Where-Object{$_ -in @('Phase5','Phase6','Phase7')}).Count -eq 0){return}
 $ready=& $WaitReady
 if($ready -isnot [bool] -or -not $ready){throw 'Guest readiness was not established; pending phases are unchanged.'}
 if($Config.PhaseCompleted -notcontains 'Phase5'){& $SavePhase 'Phase5'}
 if($Config.PhaseCompleted -notcontains 'Phase6'){
  $result=& $Install
  if($null -eq $result -or $result.SchemaVersion -ne 1 -or $result.Success -isnot [bool] -or -not $result.Success){throw 'Installation did not return a successful checked result.'}
  if($result.RebootRequired -isnot [bool] -or $result.RebootRequired){throw 'Installation requires a guest restart. State retained; restart explicitly and resume.'}
  & $SavePhase 'Phase6'
 }
 if($Config.PhaseCompleted -notcontains 'Phase7'){$verified=& $Verify;if($verified -isnot [bool] -or -not $verified){throw 'Post-install verification failed; completion is not recorded.'};& $SavePhase 'Phase7'}
}
function Assert-GpuPVGuestResult {
 param([Parameter(Mandatory)]$Result,[Parameter(Mandatory)][hashtable]$Config)
 $map=ConvertTo-GpuPVHashtable $Result
 if($map -isnot [hashtable]){throw 'A structured guest result is required.'}
 foreach($key in @('SchemaVersion','Success','RebootRequired','Components')){if(-not $map.ContainsKey($key)){throw "Missing guest field: $key"}}
 if(($map.SchemaVersion -isnot [int] -and $map.SchemaVersion -isnot [long]) -or $map.SchemaVersion -ne 1 -or $map.Success -isnot [bool] -or -not $map.Success){throw 'Invalid guest success result.'}
 if($map.RebootRequired -isnot [bool] -or $map.RebootRequired){throw 'Guest reboot is required or its state was not reported.'}
 $plan=Get-GpuPVStreamingPlan $Config.StreamingChoice
 $expected=@('VCRedist')
 foreach($name in @('Parsec','Sunshine','ParsecVDA','VDD')){if($plan.$name){$expected+=$name}}
 if($Config.AudioDriver -notin @('None','VBCable','VirtualAudioDriver')){throw 'Invalid audio plan.'}
 if($Config.AudioDriver -ne 'None'){$expected+=$Config.AudioDriver}
 if($null -eq $map.Components -or $map.Components -isnot [array]){throw 'Component result array is required.'}
 $seen=@()
 foreach($component in $map.Components){
  if($component -isnot [hashtable]){throw 'Invalid component result.'}
  foreach($key in @('Name','Status','Verified','ExitCode','RebootRequired')){if(-not $component.ContainsKey($key)){throw "Missing guest component field: $key"}}
  if($component.Name -isnot [string] -or $component.Name -cnotin $expected -or $component.Name -in $seen -or $component.Verified -isnot [bool] -or -not $component.Verified){throw 'Unexpected, duplicate or unverified component.'}
  if($component.Status -cne 'Installed' -or ($component.ExitCode -isnot [int] -and $component.ExitCode -isnot [long]) -or $component.ExitCode -ne 0 -or $component.RebootRequired -isnot [bool] -or $component.RebootRequired){throw 'Guest component status, exit code or reboot requirement contradicts success.'}
  $seen+=$component.Name
 }
 if($seen.Count -ne $expected.Count){throw 'A required component was omitted from the result.'}
}
function Read-GpuPVSecret {
 param([string]$Prompt='Password')
 $secret=Read-Host -Prompt $Prompt -AsSecureString
 (New-Object System.Net.NetworkCredential('',$secret)).Password
}
function Resolve-GpuPVUserTemplate {
 param([string]$ScriptRoot,[string]$FileName)
 if([IO.Path]::GetFileName($FileName) -ne $FileName){throw 'A template basename is required.'}
 foreach($relative in @('User','User\User')){$path=Join-Path (Join-Path $ScriptRoot $relative) $FileName;if(Test-Path -LiteralPath $path -PathType Leaf){return $path}}
 throw "Required user template is missing: $FileName"
}
function Get-GpuPVInstallerPolicy {
 param([Parameter(Mandatory=$true)][string]$DisplayName,[string]$PolicyPath=(Join-Path $PSScriptRoot 'InstallerPolicy.json'))
 $c=Get-Content -LiteralPath $PolicyPath -Raw -Encoding UTF8 -ErrorAction Stop|ConvertFrom-Json -ErrorAction Stop
 if($c.SchemaVersion -ne 1){throw 'Unsupported installer policy schema.'}
 $p=$c.Components.PSObject.Properties[$DisplayName];if($null -eq $p){throw "No installer policy for $DisplayName."};$p=$p.Value
 if($p.Sha256 -notmatch '^[a-fA-F0-9]{64}$'){throw "No trusted SHA256 pin for $DisplayName. Obtain approved publisher version/hash in InstallerPolicy.json before deployment."}
 if($p.Url -notmatch '^https://' -or [string]::IsNullOrWhiteSpace($p.Version)){throw 'An HTTPS source and explicit version are required.'}
 if([string]::IsNullOrWhiteSpace($p.FileName) -or [IO.Path]::GetFileName([string]$p.FileName) -ne [string]$p.FileName){throw 'Invalid installer policy filename.'}
 return $p
}
function Assert-GpuPVArtifact {
 param([string]$Path,[string]$ExpectedSha256,[long]$ExpectedSize=0)
 if($ExpectedSha256 -notmatch '^[a-fA-F0-9]{64}$'){throw 'A trusted SHA256 pin is required.'}
 $item=Get-Item -LiteralPath $Path -ErrorAction Stop
 if($item.PSIsContainer -or $item.Length -le 0 -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Artifact is empty or not a regular file.'}
 if($ExpectedSize -gt 0 -and $item.Length -ne $ExpectedSize){throw 'Artifact size does not match publisher metadata.'}
 if((Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash -ine $ExpectedSha256){throw 'Artifact SHA256 verification failed.'}
}
function Receive-GpuPVArtifact {
 param([string]$Url,[string]$DestinationPath,[string]$ExpectedSha256,[long]$ExpectedSize=0,[string]$LocalPath='')
 if($ExpectedSha256 -notmatch '^[a-fA-F0-9]{64}$'){throw 'A trusted SHA256 pin is required before file or network operations.'}
 if(Test-Path -LiteralPath $DestinationPath){Assert-GpuPVArtifact $DestinationPath $ExpectedSha256 $ExpectedSize;return}
 $full=[IO.Path]::GetFullPath($DestinationPath);$parent=[IO.Path]::GetDirectoryName($full)
 if(-not [IO.Directory]::Exists($parent)){[IO.Directory]::CreateDirectory($parent)|Out-Null}
 $temp=Join-Path $parent ('.artifact-'+[guid]::NewGuid().ToString('N')+'.tmp')
 try{
  if($LocalPath){Assert-GpuPVArtifact $LocalPath $ExpectedSha256 $ExpectedSize;Copy-Item -LiteralPath $LocalPath -Destination $temp -ErrorAction Stop}
  else{if($Url -notmatch '^https://'){throw 'Installer source must use HTTPS.'};$old=[Net.ServicePointManager]::SecurityProtocol;$client=New-Object Net.WebClient;try{[Net.ServicePointManager]::SecurityProtocol=$old -bor [Net.SecurityProtocolType]::Tls12;$client.DownloadFile($Url,$temp)}finally{$client.Dispose();[Net.ServicePointManager]::SecurityProtocol=$old}}
  Assert-GpuPVArtifact $temp $ExpectedSha256 $ExpectedSize
  [IO.File]::Move($temp,$full)
 }finally{if([IO.File]::Exists($temp)){[IO.File]::Delete($temp)}}
}
Export-ModuleMember -Function *
