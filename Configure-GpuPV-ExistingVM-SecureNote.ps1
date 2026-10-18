<#
.SYNOPSIS
Compatibility entry point; forwards every parameter to the single supported core.
.NOTES
This wrapper is not an antivirus exemption or a separate safety implementation.
The historical Archive-Original file is preserved separately and is not a supported deployment entry.
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
& (Join-Path $PSScriptRoot 'Configure-GpuPV-ExistingVM.ps1') @PSBoundParameters
