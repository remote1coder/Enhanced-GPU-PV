# Enhanced-GPU-PV

Windows PowerShell automation for Hyper-V GPU partitioning (GPU-PV), virtual displays,
Parsec or Sunshine streaming and optional virtual audio. Based on Easy-GPU-PV; GPL v3.

Everything below describes this revision only. Execution paths that are kept as
historical source (for example `Configure-GpuPV-ExistingVM-Archive-Original.ps1`) are
not supported entrypoints and must not be launched as a fallback.

## Requirements

| Requirement | Details |
|---|---|
| Host | Windows 10 or 11 Pro / Enterprise / Education with the Hyper-V role enabled |
| Host build | Windows build 19041 or later; the existing-VM workflow checks this |
| VM version | VM configuration version 8.0 or later for existing-VM workflows |
| Shell | Windows PowerShell 5.1 (supported and tested), 64-bit, started with **Run as Administrator** |
| GPU | Vendor driver installed on the host and returned by `Get-VMHostPartitionableGpu` |
| Install media | ISO containing `sources/install.wim`, or a `.wim` file. ESD-only media is rejected |
| Network | Host internet access while packages are staged; an external switch for the guest |
| Disk | Free space for the new VHD, plus the staged packages |

Check the host before starting:

```powershell
Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All | Select-Object State
Get-VMHostPartitionableGpu | Select-Object Name
```

`State` must be `Enabled` and your GPU must be listed. If the list is empty, fix the GPU
driver or the Hyper-V configuration first; no script in this repository can work around it.

## Quick start

```powershell
Set-Location "C:\path\to\Enhanced-GPU-PV"
Set-ExecutionPolicy -Scope Process Bypass -Force
.\Enhanced-GPU-PV.ps1
```

## Menu

`Enhanced-GPU-PV.ps1` is the entrypoint. Options 1, 4, 5, 7 and 9 map to standalone
scripts; options 2, 3 and 6 are implemented inside the menu script.

| Option | Action | Script |
|---|---|---|
| 1 | Create a new GPU-PV VM | `CopyFilesToVM.ps1` |
| 2 | Add GPU-PV to an existing VM | `Enhanced-GPU-PV.ps1` internal |
| 3 | Remove GPU-PV from an existing VM | `Enhanced-GPU-PV.ps1` internal |
| 4 | Update GPU drivers in an existing VM | `Update-VMGpuPartitionDriver.ps1` |
| 5 | Full existing-VM configuration | `Configure-GpuPV-ExistingVM.ps1` |
| 6 | Enable RDP on an existing VM | `Enhanced-GPU-PV.ps1` internal |
| 7 | Run host compatibility checks | `PreChecks.ps1` |
| 8 | Exit | - |
| 9 | Change GPU quota only (VM must be Off) | `Set-GpuPVAllocation.ps1` |

Options 2 and 3 stop a running VM gracefully and start it again afterwards; option 4 does
the same for the offline driver copy, and option 6 starts a stopped VM or resumes a paused
one and leaves it running. Offline options refuse a `Saved`, `Paused` or transitioning VM
with an explicit error; resolve its state manually first. No option forces a shutdown.

## 1. Create a new VM

Option 1 offers two modes.

**Interactive wizard (recommended).** It walks through VM basics (name, install media,
edition, virtual disk, memory, CPU count, switch), GPU configuration, streaming software,
installer sources, Sunshine and virtual display settings, connection method and the guest
account, then runs the deployment. No file editing is required.

**Legacy mode.** Edit the `$params` block at the top of `CopyFilesToVM.ps1`, then choose
mode 2. The block supplies the configuration; the allocation switches still override it.

Key parameters:

| Key | Meaning |
|---|---|
| `VMName` | Must match `[A-Za-z0-9][A-Za-z0-9_.-]{0,63}` - no spaces, because it names the checkpoint file |
| `SourcePath` | ISO or WIM to install from |
| `Edition` | Image index (1-based) or image name, for example `6` or `Professional` |
| `VhdFormat` | `VHD`, `VHDX` or `AUTO` |
| `DiskLayout` | `BIOS`, `UEFI` or `WindowsToGo` |
| `SizeBytes` / `MemoryAmount` / `CPUCores` | Virtual hardware sizing |
| `NetworkSwitch` | External switch, for example `Default Switch` |
| `VHDPath` | Must already exist; the script refuses a missing directory |
| `UnattendPath` | Defaults to `autounattend.xml` in the repository |
| `GPUName` | `AUTO` or the exact host GPU name |
| `GPUResourceAllocationPercentage` | Legacy percentage form; default `50` |
| `Username` / `Password` / `Autologon` | Guest account created by the answer file |

`Team_ID` and `Key` are rejected: automatic Parsec Teams enrollment is unsupported.
Configure Teams manually inside the Parsec application after installation.

Streaming and audio combinations:

| `Parsec` | `ParsecVDA` | `Sunshine` | `VirtualDisplayDriver` | Result |
|---|---|---|---|---|
| `$false` | `$false` | `$false` | `$false` | GPU-PV only |
| `$true` | `$true` | `$false` | `$false` | Parsec + ParsecVDA |
| `$true` | `$false` | `$false` | `$true` | Parsec + VDD |
| `$false` | `$false` | `$true` | `$true` | Sunshine + VDD |
| `$false` | `$true` | `$true` | `$false` | Sunshine + ParsecVDA |

Any other combination throws `Invalid streaming combination`. Sunshine + ParsecVDA does
not install the Parsec streaming application. The current VDD configuration supports one
monitor.

Resume and restart:

```powershell
# Resume an interrupted deployment (keeps the saved allocation policy)
.\CopyFilesToVM.ps1 -Interactive -TargetVMName "GPUPV"

# Start over and discard the checkpoint
.\CopyFilesToVM.ps1 -Interactive -TargetVMName "GPUPV" -ResetState
```

In legacy mode a checkpoint causes an error until you pass `-ResetState`. `StartFromStep`
accepts `Phase1` through `Phase7` for a new VM. A partially created VM is never deleted or
adopted automatically; inspect it on an authorized host first.

## 2. Add or remove GPU-PV on an existing VM

Options 2 and 3 prompt for the VM name. Option 2 asks for the GPU name and the allocation.
Option 3 asks for an optional GPU name (empty means safe mode) and offers a deep clean that
removes residual GPU files left by other hosts. When more than one disk or Windows partition
is attached, both ask for the exact VHD path and partition number instead of guessing.

## 3. Update GPU drivers

Option 4, or directly:

```powershell
.\Update-VMGpuPartitionDriver.ps1 -VMName "GPUPV"
.\Update-VMGpuPartitionDriver.ps1 -VMName "GPUPV" -GPUName "AUTO" `
    -SystemVhdPath "D:\Hyper-V\GPUPV\Virtual Hard Disks\GPUPV.vhdx" -SystemPartitionNumber 3
```

`-VMName` is required. `-SystemVhdPath` and `-SystemPartitionNumber` are only needed when
the VM has several attached disks or several candidate Windows partitions. The VM must be
`Off` or `Running`; `Saved` and `Paused` are refused.

## 4. Full existing-VM configuration (option 5)

This is the supported path for changing streaming software, audio driver, GPU settings or
RDP policy on a VM that already exists.

```powershell
# Preview the plan without touching the host
.\Configure-GpuPV-ExistingVM.ps1 -VMName "GPUPV" -PlanOnly

# Full configuration
.\Configure-GpuPV-ExistingVM.ps1 -VMName "GPUPV" -StreamingChoice "Sunshine+VDD" `
    -AudioDriver VBCable -ConnectionMethod KeepRdp

# Resume at a specific phase (1-7); 0 means ask
.\Configure-GpuPV-ExistingVM.ps1 -VMName "GPUPV" -StartFromStep 3

# Discard the checkpoint and use the current parameters
.\Configure-GpuPV-ExistingVM.ps1 -VMName "GPUPV" -ResetState
```

`-PlanOnly` and `-WhatIf` return the plan before any VM inspection. A plan is not proof
that the host is suitable.

| Parameter | Default | Purpose |
|---|---|---|
| `-VMName` | prompted if empty | Exact VM name, no wildcards |
| `-GPUName` | `AUTO` | Host GPU to assign |
| `-GPUAllocation` | `50` | Percentage or VRAM size; see below |
| `-GPUComputePercentage` / `-GPUEncodePercentage` / `-GPUDecodePercentage` | - | Only valid together with a VRAM size |
| `-AudioDriver` | `VBCable` | `VBCable`, `VirtualAudioDriver` or `None` |
| `-StreamingChoice` | `None` | `None`, `Parsec+ParsecVDA`, `Parsec+VDD`, `Sunshine+ParsecVDA`, `Sunshine+VDD` |
| `-ConnectionMethod` | `KeepRdp` | `KeepRdp` enables the checked rule; `Auto` disables RDP connections |
| `-VDDConfig` | 1 monitor, 1920x1080, 144 Hz, HDR off | Virtual display settings |
| `-SunshineStreamConfig` | HEVC/AV1 on, HDR off | Sunshine stream settings |
| `-StartFromStep` | `0` | `0` resumes; `1`-`7` invalidates that phase and all downstream phases |
| `-ResetState` | off | Restart with current parameters; not a rollback |
| `-SkipHostChecks` | off | Skips the Hyper-V and build 19041 checks; VM version and state checks still run |
| `-SkipCleanup` | off | Keep staged packages; required installers are still copied |
| `-SkipGpuDriverUpdate` | off | Skips GPU driver cleanup and copy; adapter assignment and other settings still run |
| `-PlanOnly` | off | Emit the plan and return |
| `-CredentialUserName` / `-CredentialPassword` | prompted | Guest credential for PowerShell Direct; never written to state |

Example with a virtual display and HDR:

```powershell
.\Configure-GpuPV-ExistingVM.ps1 -VMName "GPUPV" -StreamingChoice "Sunshine+VDD" `
    -VDDConfig @{MonitorCount=1; Resolution='2560x1440'; RefreshRate=144; EnableHDR=$true}
```

Rerunning a phase invalidates that phase and its downstream phases, and requires the
earlier phases to have completed. A saved Phase 3 or later state without the recorded VHD,
disk, partition and volume identity is rejected; preserve it and use `-ResetState` on a
suitable host.

`-ForceReinstallVDD` and `-UseLegacyVDD` are accepted for compatibility, but only the
archived `Configure-GpuPV-ExistingVM-Archive-Original.ps1` implements them. They have no
effect in this supported entrypoint.

## 5. Enable RDP (option 6)

Prompts for the VM name and guest administrator credentials, starts the VM if needed,
enables Remote Desktop and the firewall rule for the configured port through PowerShell
Direct, then reports the port and the effective configuration result.

Only the guest configuration and its local listener are verified. Network reachability,
other blocking policies and an authorized client login remain manual checks.

## 6. Host compatibility checks (option 7)

Runs `PreChecks.ps1` and reports host build, Hyper-V state, GPU presence and other
prerequisites. It performs real host queries and changes nothing.

## 7. Change GPU quota only (option 9)

```powershell
.\Set-GpuPVAllocation.ps1 -VMName "GPUPV" -GPUAllocation "70%"
.\Set-GpuPVAllocation.ps1 -VMName "GPUPV" -GPUAllocation 4GiB `
    -GPUComputePercentage 60 -GPUEncodePercentage 40 -GPUDecodePercentage 40
```

The VM must be `Off` and have exactly one identifiable GPU partition adapter. This
entrypoint never starts or stops the VM, never adds or removes an adapter, and never
mounts a disk or stages files. Input is previewed, confirmed, revalidated and read back.

## GPU allocation formats

| Input | Result |
|---|---|
| blank | 50 percent |
| `70` or `70%` | 70 percent of every resource (1-100, dot for decimals) |
| `4GiB` | VRAM byte count; compute, encode and decode percentages are then asked separately |

Units `B`, `KiB`, `MiB`, `GiB` and `TiB` are accepted. Separate compute/encode/decode
percentages are rejected unless a VRAM size was given. Resume keeps the policy saved in
the checkpoint; a different allocation on resume throws instead of being applied.

## State files and recovery

| Workflow | State file |
|---|---|
| New VM | `NewVm-<VMName>.state.json` next to the scripts |
| Existing VM | `.gpupv-existing-v2-<hash>.state.json` next to the scripts |

State is bound to the entrypoint and to the VM identity (name and GUID for an existing VM;
name first, GUID after creation for a new one). Reusing a name for a different VM is
rejected. Legacy state files may contain secrets and are neither loaded nor deleted.

- Resume continues pending phases and asks for credentials again.
- `-ResetState` restarts with the current parameters; it does not undo VM changes.
- Missing components, a failed installer or a required restart leave completion pending.
  Resolve it deliberately; do not delete state just to obtain a passing result.

## Troubleshooting

| Message | Cause and fix |
|---|---|
| `Administrator privileges required` | Start Windows PowerShell 5.1 as Administrator, 64-bit |
| `Script not running as Administrator` | Same as above; `CopyFilesToVM.ps1` exits before doing anything |
| `VHDPath Directory doesn't exist` | Create the directory or change `VHDPath` |
| `ISO Path Invalid` | `SourcePath` does not exist or points to unsupported media |
| `This WIM contains multiple images` | Set `Edition` to one index or one image name |
| `ESD-only` rejection | Use media that contains `sources/install.wim` |
| `VM name must resolve to one exact VM` | Provide the exact name, without wildcards; duplicate names are refused |
| `Invalid state identity` | New-VM names must match `[A-Za-z0-9][A-Za-z0-9_.-]{0,63}` |
| `Disk identity is ambiguous or missing` | Pass `-SystemVhdPath`; no first or largest disk fallback is used |
| `Windows-volume identity is ambiguous or missing` | Pass `-SystemPartitionNumber` for a verified Windows partition |
| `The selected disk belongs to the running host` | The chosen VHD resolves to a host disk; select the attached VM disk |
| `Saved, paused or transitioning VM requires an explicit owner decision` | Resume or shut down the VM manually; no force shutdown is performed |
| `Refusing to replace existing VHD` | Choose a new VM name or VHD path; existing VHDs are never overwritten |
| `No trusted SHA256 pin for ...` | The package version changed upstream; update `InstallerPolicy.json` deliberately |
| Hash mismatch during staging | Package bytes differ from the pinned hash; do not disable verification |
| `A checkpoint exists` | Resume with `-Interactive -TargetVMName`, or pass `-ResetState` |
| RDP test fails | The VM must be running and the guest credential must work through PowerShell Direct |

## Packages

Versions and hashes are pinned in `InstallerPolicy.json`. That file is the source of truth;
the table is a summary.

| Package | Pinned version |
|---|---|
| Sunshine | v2026.914.233613 (MSI) |
| Virtual Display Driver / Virtual Audio Driver | 25.7.23 |
| NefCon | v1.17.40 |
| Parsec | 150.104.1.0 |
| VC++ x64 runtime | 14.51.36247.0 |
| ParsecVDA Always Connected | v1.4.1 |
| VB-Cable | Pack43 |

Packages are staged on the host, hash-checked, copied into a checked guest volume and
verified again inside the guest. `VMDownload` (guest-side download) is rejected. A running
service does not prove that a client is logged in or that streaming works.

## Verification status

The project has been exercised end to end on a real Hyper-V host. That covers the
deployment and guest installation path actually used; it does not automatically extend to
every entrypoint, option or streaming combination, so treat an untried combination as
unverified.

The PowerShell sources also pass PowerShell 5.1 parsing and isolated checks, and the
allocation update passed 65 parser and structure checks. The automated behavior suites
remain incomplete after an AMSI compilation crash; they are regression evidence, not a
substitute for a host run.

Client-side acceptance is still a separate manual step. A completed installation does not
by itself prove that a client can log in, that picture and audio work, that requested HDR
is applied or that RDP is reachable from another machine. Re-check those after changing GPU
drivers or package versions, and record the host and guest builds, GPU driver version,
package versions and disk identity when you do.

## License

GPL v3. See `LICENSE`. The embedded Microsoft copyright header and the Easy-GPU-PV
attribution must be preserved.
