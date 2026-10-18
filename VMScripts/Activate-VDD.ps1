# Activate-VDD.ps1
# Run manually in the intended guest after connecting via RDP.
# Device activation does not verify a Moonlight connection or Sunshine account.
[CmdletBinding()]
param()

function Invoke-VddActivation {
    $devices = @(Get-PnpDevice -Class Display -PresentOnly -ErrorAction Stop |
        Where-Object { $_.FriendlyName -eq 'Virtual Display Driver' })
    if ($devices.Count -ne 1) { throw "Expected exactly one present VDD device; found $($devices.Count). Select and verify the intended adapter manually." }
    $device = $devices[0]
    try {
        Disable-PnpDevice -InstanceId $device.InstanceId -Confirm:$false -ErrorAction Stop | Out-Null
        Start-Sleep -Seconds 2
    } finally {
        Enable-PnpDevice -InstanceId $device.InstanceId -Confirm:$false -ErrorAction Stop | Out-Null
    }
    $healthy = $false
    for ($attempt = 0; $attempt -lt 15; $attempt++) {
        $observed = Get-PnpDevice -InstanceId $device.InstanceId -PresentOnly -ErrorAction Stop
        if ($observed.Status -eq 'OK') { $healthy = $true; break }
        Start-Sleep -Seconds 2
    }
    if (-not $healthy) { throw 'VDD did not reach OK state. Keep RDP connected and inspect the guest device error.' }
    Write-Host 'VDD reports OK. Keep RDP connected until a real Moonlight session has been verified.' -ForegroundColor Green
    [pscustomobject]@{ SchemaVersion=1; Success=$true; DeviceId=$device.InstanceId; StreamingVerified=$false }
}

Invoke-VddActivation
