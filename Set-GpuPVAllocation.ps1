#Requires -Version 5.1
<#
.SYNOPSIS
Adjust quotas on one existing GPU-PV adapter without reinstalling drivers.
.DESCRIPTION
The VM must already be Off and have exactly one identifiable GPU partition
adapter. This entrypoint does not start/stop a VM, add/remove an adapter,
mount disks, stage files or change deployment checkpoints.
.EXAMPLE
.\Set-GpuPVAllocation.ps1 -VMName Workstation -GPUAllocation '70%'
.EXAMPLE
.\Set-GpuPVAllocation.ps1 -VMName Workstation -GPUAllocation 4GiB -GPUComputePercentage 60 -GPUEncodePercentage 40 -GPUDecodePercentage 40
#>
[CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='High')]
param(
    [string]$VMName,
    [string]$GPUAllocation,
    [string]$GPUComputePercentage,
    [string]$GPUEncodePercentage,
    [string]$GPUDecodePercentage
)

function Assert-GpuPVQuotaVMName {
    param([Parameter(Mandatory)][string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name) -or [System.Management.Automation.WildcardPattern]::ContainsWildcardCharacters($Name) -or $Name.Contains('`')) {
        throw 'Enter an exact VM name without wildcard or escape characters.'
    }
}

function Get-GpuPVQuotaSnapshot {
    [CmdletBinding(DefaultParameterSetName='Name')]
    param(
        [Parameter(Mandatory,ParameterSetName='Name')][string]$Name,
        [Parameter(Mandatory,ParameterSetName='Id')][guid]$VMId,
        [Parameter(ParameterSetName='Id')][string]$ExpectedName
    )
    if ($PSCmdlet.ParameterSetName -eq 'Name') {
        Assert-GpuPVQuotaVMName -Name $Name
        $vms = @(Get-VM -Name $Name -ErrorAction Stop)
    } else {
        if ($VMId -eq [guid]::Empty) { throw 'The captured VM GUID is empty.' }
        $vms = @(Get-VM -Id $VMId -ErrorAction Stop)
    }
    if ($vms.Count -ne 1) { throw 'The target must resolve to exactly one VM.' }
    $vm = $vms[0]
    $wantedName = if ($PSCmdlet.ParameterSetName -eq 'Name') { $Name } else { $ExpectedName }
    if ($wantedName -and -not [string]::Equals([string]$vm.Name,$wantedName,[StringComparison]::OrdinalIgnoreCase)) { throw 'The resolved VM name does not match the requested target.' }
    [guid]$resolvedId = [guid]::Empty
    if (-not [guid]::TryParse([string]$vm.VMId,[ref]$resolvedId) -or $resolvedId -eq [guid]::Empty) { throw 'The VM has no valid GUID.' }
    if ($PSCmdlet.ParameterSetName -eq 'Id' -and $resolvedId -ne $VMId) { throw 'The VM GUID changed.' }
    if ([string]$vm.State -ne 'Off') { throw 'Shut down the VM normally before adjusting quotas; its state must be Off.' }
    $adapters = @(Get-VMGpuPartitionAdapter -VM $vm -ErrorAction Stop)
    if ($adapters.Count -ne 1) { throw 'Quota-only adjustment requires exactly one existing GPU partition adapter. No adapter will be created or removed.' }
    $adapter = $adapters[0]
    $adapterId = [string]$adapter.Id
    $instancePath = [string]$adapter.InstancePath
    if ([string]::IsNullOrWhiteSpace($adapterId) -or [string]::IsNullOrWhiteSpace($instancePath)) { throw 'The existing GPU adapter lacks an Id or InstancePath.' }
    $gpus = @(Get-VMHostPartitionableGpu -ErrorAction Stop | Where-Object { [string]::Equals([string]$_.Name,$instancePath,[StringComparison]::OrdinalIgnoreCase) })
    if ($gpus.Count -ne 1) { throw 'The adapter InstancePath does not match exactly one host partitionable GPU; refusing to guess a GPU.' }
    $values = @{}
    foreach ($resource in @('VRAM','Compute','Encode','Decode')) {
        foreach ($prefix in @('Min','Max','Optimal')) {
            $field = $prefix + 'Partition' + $resource
            [uint64]$number = 0
            if ($null -eq $adapter.$field -or -not [uint64]::TryParse([string]$adapter.$field,[Globalization.NumberStyles]::None,[Globalization.CultureInfo]::InvariantCulture,[ref]$number)) { throw "The adapter does not expose a valid UInt64 $field value." }
            $values[$field] = $number
        }
    }
    return [pscustomobject]@{VM=$vm;VMId=$resolvedId;VMName=[string]$vm.Name;Adapter=$adapter;AdapterId=$adapterId;InstancePath=$instancePath;Capabilities=$gpus[0];Values=$values}
}

function Assert-GpuPVQuotaSnapshotIdentity {
    param([Parameter(Mandatory)]$Before,[Parameter(Mandatory)]$After)
    foreach ($field in @('VMId','VMName','AdapterId','InstancePath')) {
        if (-not [string]::Equals([string]$Before.$field,[string]$After.$field,[StringComparison]::OrdinalIgnoreCase)) { throw "Target identity changed ($field). No further automatic change is allowed." }
    }
}

function Assert-GpuPVQuotaValuesEqual {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Expected,[Parameter(Mandatory)][System.Collections.IDictionary]$Actual,[string]$Context='GPU quota')
    $mismatches = @()
    foreach ($resource in @('VRAM','Compute','Encode','Decode')) {
        foreach ($prefix in @('Min','Max','Optimal')) {
            $field = $prefix + 'Partition' + $resource
            if (-not $Expected.Contains($field) -or -not $Actual.Contains($field) -or [decimal]$Expected[$field] -ne [decimal]$Actual[$field]) { $mismatches += $field }
        }
    }
    if ($mismatches.Count) { throw "$Context mismatch: $($mismatches -join ', ')." }
}

function Invoke-GpuPVQuotaChange {
    [CmdletBinding(SupportsShouldProcess=$true,ConfirmImpact='High')]
    param([Parameter(Mandatory)][string]$VMName,[Parameter(Mandatory)]$Policy)
    $policy = ConvertTo-GpuPVAllocationPolicy -Policy $Policy
    $before = Get-GpuPVQuotaSnapshot -Name $VMName
    $target = Get-GpuPVAllocationValues -Policy $policy -Capabilities $before.Capabilities
    Write-Host ("VM: {0}; GUID: {1}; adapter: {2}" -f $before.VMName,$before.VMId,$before.AdapterId)
    Write-Host ("GPU: {0}" -f $before.InstancePath)
    Write-Host (Format-GpuPVAllocationPolicy -Policy $policy)
    Write-Host 'Current -> target (VRAM in bytes; other resources use driver-defined units):'
    foreach ($resource in @('VRAM','Compute','Encode','Decode')) {
        foreach ($prefix in @('Min','Max','Optimal')) {
            $field = $prefix + 'Partition' + $resource
            Write-Host ("  {0}: {1} -> {2}" -f $field,$before.Values[$field],$target[$field])
        }
    }
    Write-Warning 'Deployment checkpoints are unchanged. Rerunning a deployment with its earlier allocation settings can overwrite this adjustment.'
    if (-not $PSCmdlet.ShouldProcess(("{0} ({1}), adapter {2}" -f $before.VMName,$before.VMId,$before.AdapterId),'Set the 12 GPU partition quota values shown above')) {
        return [pscustomobject]@{Changed=$false;QuotaReadbackVerified=$false;VMId=$before.VMId;AdapterId=$before.AdapterId;Target=$target}
    }
    # Revalidate after the interactive delay and operate on the captured object,
    # never on a freshly reused display name or an unqualified default adapter.
    $current = Get-GpuPVQuotaSnapshot -VMId $before.VMId -ExpectedName $before.VMName
    Assert-GpuPVQuotaSnapshotIdentity -Before $before -After $current
    Assert-GpuPVQuotaValuesEqual -Expected $before.Values -Actual $current.Values -Context 'Current quotas changed after the preview'
    $currentTarget = Get-GpuPVAllocationValues -Policy $policy -Capabilities $current.Capabilities
    Assert-GpuPVQuotaValuesEqual -Expected $target -Actual $currentTarget -Context 'GPU capabilities changed after the preview'
    try {
        Set-VMGpuPartitionAdapter -VMGpuPartitionAdapter $current.Adapter @target -Confirm:$false -ErrorAction Stop | Out-Null
        $after = Get-GpuPVQuotaSnapshot -VMId $before.VMId -ExpectedName $before.VMName
        Assert-GpuPVQuotaSnapshotIdentity -Before $before -After $after
        Assert-GpuPVQuotaValuesEqual -Expected $target -Actual $after.Values -Context 'GPU quota readback'
    } catch {
        throw "GPU quota update or readback failed. The adapter may have been changed; no rollback was attempted. Inspect the captured VM GUID $($before.VMId) and adapter $($before.AdapterId) before retrying. Details: $($_.Exception.Message)"
    }
    Write-Host 'All 12 configured quota values match readback. Guest rendering, performance and streaming have not been tested.'
    return [pscustomobject]@{Changed=$true;QuotaReadbackVerified=$true;VMId=$before.VMId;AdapterId=$before.AdapterId;Target=$target}
}

Import-Module (Join-Path $PSScriptRoot 'GpuPV-Allocation.psm1') -Force -ErrorAction Stop
if ([string]::IsNullOrWhiteSpace($VMName)) {
    do {
        $VMName = Read-Host 'Exact name of the powered-off VM / 已关机虚拟机的准确名称'
        try { Assert-GpuPVQuotaVMName -Name $VMName; $validName = $true }
        catch { Write-Warning $_.Exception.Message; $validName = $false }
    } until ($validName)
}
Assert-GpuPVQuotaVMName -Name $VMName
$allocationParameters = @('GPUAllocation','GPUComputePercentage','GPUEncodePercentage','GPUDecodePercentage')
$explicitAllocation = @($allocationParameters | Where-Object { $PSBoundParameters.ContainsKey($_) }).Count -gt 0
if ($explicitAllocation) {
    $policyArgs = @{}
    foreach ($pair in @(@('GPUAllocation','Allocation'),@('GPUComputePercentage','ComputePercentage'),@('GPUEncodePercentage','EncodePercentage'),@('GPUDecodePercentage','DecodePercentage'))) {
        if ($PSBoundParameters.ContainsKey($pair[0])) { $policyArgs[$pair[1]] = $PSBoundParameters[$pair[0]] }
    }
    $allocationPolicy = New-GpuPVAllocationPolicy @policyArgs
} else { $allocationPolicy = Read-GpuPVAllocationPolicy }
Import-Module Hyper-V -ErrorAction Stop
$changeArgs = @{VMName=$VMName;Policy=$allocationPolicy}
foreach ($preference in @('Confirm','WhatIf')) {
    if ($PSBoundParameters.ContainsKey($preference)) { $changeArgs[$preference] = $PSBoundParameters[$preference] }
}
Invoke-GpuPVQuotaChange @changeArgs
