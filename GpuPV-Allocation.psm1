# Pure allocation policy parsing and arithmetic for all supported GPU-PV entrypoints.
# Importing this module does not discover GPUs or virtual machines.

function ConvertTo-GpuPVDecimal {
    param([AllowNull()]$Value, [string]$Name)
    $numericTypes = @([byte],[sbyte],[int16],[uint16],[int32],[uint32],[int64],[uint64],[single],[double],[decimal])
    if ($null -eq $Value -or $Value.GetType() -notin $numericTypes) { throw "$Name must be a numeric value, not a string, Boolean or null." }
    if (($Value -is [double] -and ([double]::IsNaN($Value) -or [double]::IsInfinity($Value))) -or
        ($Value -is [single] -and ([single]::IsNaN($Value) -or [single]::IsInfinity($Value)))) { throw "$Name must be finite." }
    try { return [decimal]$Value } catch { throw "$Name is outside the supported numeric range." }
}

function ConvertTo-GpuPVPercentage {
    param([AllowNull()]$Value, [string]$Name = 'Percentage')
    $number = ConvertTo-GpuPVDecimal -Value $Value -Name $Name
    if ($number -lt 1 -or $number -gt 100) { throw "$Name must be between 1 and 100." }
    return $number
}

function Get-GpuPVDecimalRatio {
    param([decimal]$Value)
    $text = $Value.ToString('0.############################', [Globalization.CultureInfo]::InvariantCulture)
    $parts = $text.Split('.')
    $scale = 0
    if ($parts.Count -eq 2) { $scale = $parts[1].Length }
    return @{
        Numerator = [System.Numerics.BigInteger]::Parse($text.Replace('.',''), [Globalization.CultureInfo]::InvariantCulture)
        Denominator = [System.Numerics.BigInteger]::Pow([System.Numerics.BigInteger]10, $scale)
    }
}

function ConvertFrom-GpuPVPercentageText {
    param([AllowNull()][AllowEmptyString()][string]$Text, [decimal]$DefaultPercentage = 50)
    $fallback = ConvertTo-GpuPVPercentage -Value $DefaultPercentage -Name 'DefaultPercentage'
    $clean = if ($null -eq $Text) { '' } else { $Text.Trim() }
    if ($clean.Length -eq 0) { return $fallback }
    if ($clean -notmatch '^(?<number>(?:[0-9]+(?:\.[0-9]+)?|\.[0-9]+))\s*%?$') { throw 'Enter a percentage such as 70 or 70%, between 1 and 100, using a dot for decimals.' }
    $numberText = $Matches['number']
    [decimal]$number = 0
    if (-not [decimal]::TryParse($numberText, [Globalization.NumberStyles]::AllowDecimalPoint, [Globalization.CultureInfo]::InvariantCulture, [ref]$number)) { throw 'The percentage is outside the supported numeric precision.' }
    $ratio = Get-GpuPVDecimalRatio -Value $number
    $parts = $numberText.Split('.')
    $digits = $numberText.Replace('.','')
    $scale = if ($parts.Count -eq 2) { $parts[1].Length } else { 0 }
    $requested = [System.Numerics.BigInteger]::Parse($digits, [Globalization.CultureInfo]::InvariantCulture)
    $denominator = [System.Numerics.BigInteger]::Pow([System.Numerics.BigInteger]10, $scale)
    if (($requested * $ratio.Denominator) -ne ($ratio.Numerator * $denominator)) { throw 'The percentage has too many decimal places to preserve exactly.' }
    return ConvertTo-GpuPVPercentage -Value $number
}

function ConvertTo-GpuPVUInt64 {
    param([AllowNull()]$Value, [string]$Name, [switch]$AllowZero, [switch]$AllowString)
    if ($AllowString -and $Value -is [string]) {
        [uint64]$parsed = 0
        if ($Value -notmatch '^[0-9]+$' -or -not [uint64]::TryParse($Value, [ref]$parsed)) { throw "$Name must be an exact unsigned 64-bit integer." }
        if (-not $AllowZero -and $parsed -eq 0) { throw "$Name must be greater than zero." }
        return $parsed
    }
    $number = ConvertTo-GpuPVDecimal -Value $Value -Name $Name
    # Binary floating-point values above their exact-integer ranges cannot be trusted as byte counts.
    if (($Value -is [double] -and [Math]::Abs($Value) -gt 9007199254740991) -or
        ($Value -is [single] -and [Math]::Abs($Value) -gt 16777215)) { throw "$Name must use an integer or Decimal type to preserve precision." }
    if ($number -lt 0 -or $number -gt [decimal][uint64]::MaxValue -or [decimal]::Truncate($number) -ne $number) { throw "$Name must be an exact unsigned 64-bit integer." }
    if (-not $AllowZero -and $number -eq 0) { throw "$Name must be greater than zero." }
    return [uint64]$number
}

function ConvertTo-GpuPVPolicyMap {
    param([AllowNull()]$Policy)
    if ($null -eq $Policy) { throw 'Allocation policy is required.' }
    $map = @{}
    if ($Policy -is [System.Collections.IDictionary]) {
        foreach ($key in $Policy.Keys) {
            if ($key -isnot [string] -or [string]::IsNullOrWhiteSpace($key) -or $map.ContainsKey($key)) { throw 'Allocation policy contains invalid or duplicate keys.' }
            $map[$key] = $Policy[$key]
        }
    } elseif ($Policy -is [System.Management.Automation.PSCustomObject]) {
        foreach ($property in $Policy.PSObject.Properties) {
            if ($property.MemberType -ne [System.Management.Automation.PSMemberTypes]::NoteProperty -or $map.ContainsKey($property.Name)) { throw 'Allocation policy must contain plain data properties.' }
            $map[$property.Name] = $property.Value
        }
    } else { throw 'Allocation policy must be a dictionary or a JSON object.' }
    return $map
}

function ConvertTo-GpuPVAllocationPolicy {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowNull()]$Policy)
    $map = ConvertTo-GpuPVPolicyMap -Policy $Policy
    if (-not $map.ContainsKey('Mode') -or $map.Mode -isnot [string]) { throw 'Allocation policy requires a string Mode.' }
    if ($map.Mode -ceq 'Percent') {
        $required = @('Mode','Percentage')
        foreach ($key in $map.Keys) { if ($key -notin $required) { throw "Unknown Percent allocation field: $key." } }
        foreach ($key in $required) { if (-not $map.ContainsKey($key)) { throw "Missing Percent allocation field: $key." } }
        return @{ Mode = 'Percent'; Percentage = (ConvertTo-GpuPVPercentage -Value $map.Percentage) }
    }
    if ($map.Mode -ceq 'VramBytes') {
        $required = @('Mode','VramBytes','ComputePercentage','EncodePercentage','DecodePercentage')
        foreach ($key in $map.Keys) { if ($key -notin $required) { throw "Unknown VramBytes allocation field: $key." } }
        foreach ($key in $required) { if (-not $map.ContainsKey($key)) { throw "Missing VramBytes allocation field: $key." } }
        return @{
            Mode = 'VramBytes'
            VramBytes = (ConvertTo-GpuPVUInt64 -Value $map.VramBytes -Name 'VramBytes')
            ComputePercentage = (ConvertTo-GpuPVPercentage -Value $map.ComputePercentage -Name 'ComputePercentage')
            EncodePercentage = (ConvertTo-GpuPVPercentage -Value $map.EncodePercentage -Name 'EncodePercentage')
            DecodePercentage = (ConvertTo-GpuPVPercentage -Value $map.DecodePercentage -Name 'DecodePercentage')
        }
    }
    throw 'Allocation Mode must be Percent or VramBytes (case-sensitive).'
}

function ConvertFrom-GpuPVAllocationInput {
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$InputText, [decimal]$DefaultPercentage = 50)
    $fallback = ConvertTo-GpuPVPercentage -Value $DefaultPercentage -Name 'DefaultPercentage'
    $clean = if ($null -eq $InputText) { '' } else { $InputText.Trim() }
    if ($clean -match '^(?<number>(?:[0-9]+(?:\.[0-9]+)?|\.[0-9]+))\s*(?<unit>B|KiB|MiB|GiB|TiB)$') {
        $numberText = $Matches['number']
        $unit = $Matches['unit']
        $units = @{ B = 0; KiB = 1; MiB = 2; GiB = 3; TiB = 4 }
        $parts = $numberText.Split('.')
        $scale = if ($parts.Count -eq 2) { $parts[1].Length } else { 0 }
        $numerator = [System.Numerics.BigInteger]::Parse($numberText.Replace('.',''), [Globalization.CultureInfo]::InvariantCulture)
        $factor = [System.Numerics.BigInteger]::Pow([System.Numerics.BigInteger]1024, $units[$unit])
        $denominator = [System.Numerics.BigInteger]::Pow([System.Numerics.BigInteger]10, $scale)
        $product = $numerator * $factor
        if (($product % $denominator) -ne [System.Numerics.BigInteger]::Zero) { throw 'VRAM capacity must resolve to a whole number of bytes.' }
        $bytes = [System.Numerics.BigInteger]::Divide($product, $denominator)
        if ($bytes -le [System.Numerics.BigInteger]::Zero -or $bytes -gt [System.Numerics.BigInteger][uint64]::MaxValue) { throw 'VRAM capacity must be greater than zero and fit in an unsigned 64-bit byte count.' }
        return @{ Mode = 'VramBytes'; VramBytes = [uint64]$bytes; ComputePercentage = $fallback; EncodePercentage = $fallback; DecodePercentage = $fallback }
    }
    return @{ Mode = 'Percent'; Percentage = (ConvertFrom-GpuPVPercentageText -Text $clean -DefaultPercentage $fallback) }
}

function New-GpuPVAllocationPolicy {
    [CmdletBinding()]
    param(
        [AllowNull()][AllowEmptyString()][string]$Allocation = '50',
        [AllowNull()][AllowEmptyString()][string]$ComputePercentage,
        [AllowNull()][AllowEmptyString()][string]$EncodePercentage,
        [AllowNull()][AllowEmptyString()][string]$DecodePercentage
    )
    $policy = ConvertFrom-GpuPVAllocationInput -InputText $Allocation
    foreach ($resource in @('Compute','Encode','Decode')) {
        $key = $resource + 'Percentage'
        if ($PSBoundParameters.ContainsKey($key)) {
            if ($policy.Mode -ne 'VramBytes') { throw 'Separate Compute/Encode/Decode percentages are only valid with a VRAM capacity such as 4GiB.' }
            $policy[$key] = ConvertFrom-GpuPVPercentageText -Text $PSBoundParameters[$key]
        }
    }
    return ConvertTo-GpuPVAllocationPolicy -Policy $policy
}

function Get-GpuPVAllocationValues {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Policy, [Parameter(Mandatory)]$Capabilities)
    $normalized = ConvertTo-GpuPVAllocationPolicy -Policy $Policy
    $values = @{}
    foreach ($resource in @('VRAM','Compute','Encode','Decode')) {
        $minKey = 'MinPartition' + $resource
        $maxKey = 'MaxPartition' + $resource
        $minimum = ConvertTo-GpuPVUInt64 -Value $Capabilities.$minKey -Name $minKey -AllowZero -AllowString
        $maximum = ConvertTo-GpuPVUInt64 -Value $Capabilities.$maxKey -Name $maxKey -AllowZero -AllowString
        if ($minimum -gt $maximum) { throw "GPU capability $resource has a minimum greater than its maximum." }
        if ($normalized.Mode -eq 'VramBytes' -and $resource -eq 'VRAM') {
            [uint64]$value = $normalized.VramBytes
        } else {
            $percentage = if ($normalized.Mode -eq 'Percent') { $normalized.Percentage } else { $normalized[$resource + 'Percentage'] }
            $ratio = Get-GpuPVDecimalRatio -Value $percentage
            $product = [System.Numerics.BigInteger]$maximum * $ratio.Numerator
            $divisor = $ratio.Denominator * [System.Numerics.BigInteger]100
            [uint64]$value = [System.Numerics.BigInteger]::Divide($product, $divisor)
        }
        if ($value -lt $minimum -or $value -gt $maximum) { throw "Requested $resource allocation $value is outside the GPU driver range [$minimum, $maximum]. Choose another allocation." }
        foreach ($prefix in @('MinPartition','MaxPartition','OptimalPartition')) { $values[$prefix + $resource] = $value }
    }
    return $values
}

function Read-GpuPVAllocationPolicy {
    [CmdletBinding()]
    param([decimal]$DefaultPercentage = 50)
    $fallback = ConvertTo-GpuPVPercentage -Value $DefaultPercentage -Name 'DefaultPercentage'
    while ($true) {
        $inputText = Read-Host "GPU allocation / GPU 分配: 70 or 70% / 百分比, 4GiB / 显存容量; blank / 留空 = $fallback%"
        try {
            $policy = ConvertFrom-GpuPVAllocationInput -InputText $inputText -DefaultPercentage $fallback
            break
        } catch { Write-Host ("Invalid allocation: " + $_.Exception.Message) -ForegroundColor Yellow }
    }
    if ($policy.Mode -eq 'VramBytes') {
        foreach ($resource in @('Compute','Encode','Decode')) {
            while ($true) {
                $inputText = Read-Host "$resource / 资源比例: percentage only / 仅百分比; blank / 留空 = $fallback%"
                try {
                    $policy[$resource + 'Percentage'] = ConvertFrom-GpuPVPercentageText -Text $inputText -DefaultPercentage $fallback
                    break
                } catch { Write-Host ("Invalid $resource percentage: " + $_.Exception.Message) -ForegroundColor Yellow }
            }
        }
    }
    return ConvertTo-GpuPVAllocationPolicy -Policy $policy
}

function Format-GpuPVAllocationPolicy {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Policy)
    $normalized = ConvertTo-GpuPVAllocationPolicy -Policy $Policy
    $culture = [Globalization.CultureInfo]::InvariantCulture
    if ($normalized.Mode -eq 'Percent') { return ($normalized.Percentage.ToString($culture) + '% of each GPU driver maximum (VRAM, compute, encode, decode)') }
    return ('VRAM: ' + $normalized.VramBytes.ToString($culture) + ' bytes; compute: ' + $normalized.ComputePercentage.ToString($culture) + '%; encode: ' + $normalized.EncodePercentage.ToString($culture) + '%; decode: ' + $normalized.DecodePercentage.ToString($culture) + '%')
}


function ConvertTo-GpuPVStoredAllocationConfig {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Config,[Parameter(Mandatory)][ValidateSet('GPUAllocation','GPUResourceAllocationPercentage')][string]$LegacyField)
    $copy = @{}; foreach ($key in $Config.Keys) { $copy[$key] = $Config[$key] }
    $policy = ConvertTo-GpuPVAllocationPolicy -Policy $copy.GPUAllocationPolicy
    $legacy = if ($policy.Mode -eq 'Percent') { $policy.Percentage } else { [decimal]50 }
    if (-not $copy.ContainsKey($LegacyField) -or (ConvertTo-GpuPVPercentage -Value $copy[$LegacyField]) -ne $legacy) { throw 'Stored allocation conflicts with the legacy percentage.' }
    # JSON readers may turn decimals/large integers into Double. Encode only this
    # versioned policy as invariant numeric text, retaining exact quota intent.
    $record = @{Encoding='InvariantNumericTextV1';Mode=$policy.Mode}
    foreach ($key in $policy.Keys) { if ($key -ne 'Mode') { $record[$key] = $policy[$key].ToString([Globalization.CultureInfo]::InvariantCulture) } }
    $copy.GPUAllocationPolicy = $record
    $copy[$LegacyField] = $legacy.ToString([Globalization.CultureInfo]::InvariantCulture)
    return $copy
}

function ConvertFrom-GpuPVStoredAllocationConfig {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Config,[Parameter(Mandatory)][ValidateSet('GPUAllocation','GPUResourceAllocationPercentage')][string]$LegacyField)
    $copy = @{}; foreach ($key in $Config.Keys) { $copy[$key] = $Config[$key] }
    if (-not $copy.ContainsKey('GPUAllocationPolicy')) { return $copy }
    $record = ConvertTo-GpuPVPolicyMap -Policy $copy.GPUAllocationPolicy
    if (-not $record.ContainsKey('Encoding')) { return $copy }
    if ($record.Encoding -cne 'InvariantNumericTextV1') { throw 'Unknown stored GPU allocation encoding.' }
    $record.Remove('Encoding')
    foreach ($key in @($record.Keys)) {
        if ($key -eq 'Mode') { continue }
        if ($record[$key] -isnot [string] -or $record[$key] -notmatch '^[0-9]+(\.[0-9]+)?$') { throw "Stored GPU allocation field $key must be invariant numeric text." }
        if ($key -eq 'VramBytes') { $record[$key] = ConvertTo-GpuPVUInt64 -Value $record[$key] -Name $key -AllowString }
        else { $record[$key] = ConvertFrom-GpuPVPercentageText -Text $record[$key] }
    }
    $policy = ConvertTo-GpuPVAllocationPolicy -Policy $record
    $legacy = if ($policy.Mode -eq 'Percent') { $policy.Percentage } else { [decimal]50 }
    if (-not $copy.ContainsKey($LegacyField) -or $copy[$LegacyField] -isnot [string] -or $copy[$LegacyField] -notmatch '^[0-9]+(\.[0-9]+)?$' -or (ConvertFrom-GpuPVPercentageText -Text $copy[$LegacyField]) -ne $legacy) { throw 'Stored GPU allocation has a conflicting legacy percentage.' }
    $copy.GPUAllocationPolicy = $policy
    $copy[$LegacyField] = $legacy
    return $copy
}

Export-ModuleMember -Function ConvertFrom-GpuPVAllocationInput, ConvertTo-GpuPVAllocationPolicy, Get-GpuPVAllocationValues, Read-GpuPVAllocationPolicy, Format-GpuPVAllocationPolicy, New-GpuPVAllocationPolicy, ConvertTo-GpuPVStoredAllocationConfig, ConvertFrom-GpuPVStoredAllocationConfig
