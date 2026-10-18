# Enhanced-GPU-PV

Windows PowerShell automation for Hyper-V GPU partitioning, virtual displays, Parsec or Sunshine and optional virtual audio. Based on Easy-GPU-PV; GPL v3.

This revision was checked with PowerShell 5.1 parsing and isolated tests. It has not been run against Hyper-V, a guest installer or a streaming client during this repair. The repair workstation must not be used for these operations.

## Current paths

| Entry | Behavior |
|---|---|
| CopyFilesToVM.ps1 | New VM from ISO with sources/install.wim, or direct WIM; HostDownload only; ESD-only media is rejected |
| Configure-GpuPV-ExistingVM.ps1 | Full existing-VM configuration, explicit resume/restart/rerun |
| Configure-GpuPV-ExistingVM-SecureNote.ps1 | Thin wrapper around the same core |
| Enhanced-GPU-PV.ps1 | Menu; option 5 runs full ExistingVM configuration; option 9 changes GPU quotas only |
| Set-GpuPVAllocation.ps1 | Quota-only change on an already Off VM with one existing adapter; no driver/deployment work |
| Update-VMGpuPartitionDriver.ps1 | Driver refresh through the identity-bound offline target |
| VMScripts/PostBoot-Installer.ps1 | Shared guest installer and independent VerifyOnly checks |
| VMScripts/Activate-VDD.ps1 | Manual VDD activation without forced restart |

Archive-Original and the old User/VMScripts guest-download scripts remain executable historical source. They are not repaired supported entrypoints and must not be launched as a fallback. Templates may be under User/User; they were not moved. SecureNote is not an antivirus exemption. Do not disable antivirus or expand exclusions to make a rejected action proceed.

## GPU allocation inputs

GPU allocation defaults to 50 percent across supported entrypoints and the internal helper. Interactive prompts accept `70` or `70%`, retry invalid input, and use 50 only for blank input. Entering `4GiB` sets VRAM bytes and then asks compute, encode and decode percentages separately. Menu option 9 changes quotas on an existing adapter without rerunning deployment; the VM must already be Off. Read [GPU_ALLOCATION.md](GPU_ALLOCATION.md) for CLI arguments, exact state encoding, resume behavior and verification limits.

The allocation update passed 65 PowerShell 5.1 parser/structure checks. Behavior suites remain pending after a PowerShell AMSI compilation crash; this is not runtime acceptance. Its audit is E:\codex\_gpu_allocation_20261015. Earlier test totals below belong to earlier source revisions.

## Choices and packages

StreamingChoice: None, Parsec+ParsecVDA, Parsec+VDD, Sunshine+ParsecVDA or Sunshine+VDD. AudioDriver: None, VBCable or VirtualAudioDriver. Sunshine+ParsecVDA does not install the Parsec streaming app. Current VDD configuration supports one monitor.

Every active path prepares packages on the host, checks hashes, copies them into a checked guest volume, and verifies the exact manifest again inside the guest. VMDownload is rejected. Configure Parsec accounts/Teams and Sunshine first-run accounts manually in their applications; automatic Teams enrollment is unsupported. A running service does not prove login or streaming.

| Package | Pinned version | Hash source |
|---|---|---|
| Sunshine | v2026.914.233613, MSI | GitHub release asset digest |
| VDD / Virtual Audio Driver | 25.7.23 | GitHub release asset digest |
| NefCon | v1.17.40 | GitHub release asset digest |
| Parsec | 150.104.1.0 | Microsoft WinGet manifest |
| VC++ x64 runtime | 14.51.36247.0 | Microsoft WinGet manifest |
| ParsecVDA Always Connected | v1.4.1 | Direct HTTPS release bytes measured on 2026-10-12 |
| VB-Cable | Pack43 | Direct HTTPS vendor bytes measured on 2026-10-12 |

InstallerPolicy.json records the exact sources and hashes. The last two are locally computed hashes of upstream downloads, not independently published checksums or malware-free guarantees. Pack43 is retained to avoid an untested installer upgrade; VB-Audio also publishes Pack45. Parsec uses a mutable vendor URL: an upstream replacement will fail the pinned hash check. Review and update the policy deliberately instead of disabling verification. No downloaded program was executed during this audit.

## Recovery

State schema 2 binds an entrypoint and target. ExistingVM uses the exact VM name and GUID. NewVM determines the name before state lookup and records the GUID after creation. A different VM reusing a name is rejected. ExistingVM now also persists the selected VHD, disk, partition and volume identity before offline mutation. A saved Phase 3 or later without that binding is rejected: preserve the old state and explicitly ResetState on a suitable host. ResetState restarts the workflow; it is not a rollback. Legacy state may contain secrets; it is neither silently loaded nor deleted.

- Resume continues pending phases and reacquires runtime credentials/readiness.
- ResetState uses current configuration; it does not undo previous VM changes.
- ExistingVM StartFromStep accepts 1–7; 0 means normal resume. Rerunning invalidates the chosen phase and its downstream phases, and requires earlier successful phases.
- NewVM StartFromStep accepts Phase1–Phase7. A partially created VM is not automatically deleted or adopted; inspect it on an authorized host before recovering.
- Failed installation, missing components and restart-required results leave completion pending. A restart is an explicit operator action on an authorized host.
- Completion state is retained. Manual client acceptance remains separate.

State uses a non-secret allowlist, explicit UTF-8 decoding, typed configuration validation and atomic writes. NewVM completed phases must form a contiguous prefix with the VM GUID present after creation. The source autounattend.xml is preserved; a temporary host copy is deleted in finally. Windows setup still needs a provisioning credential in the guest answer file; manage that account and guest setup artifacts appropriately. No automatic transcript is enabled.

## Storage, switches and RDP

Multiple attached disks require an explicit SystemVhdPath; multiple candidate Windows partitions require SystemPartitionNumber. VM/VHD/disk/partition/volume identities are checked together. Missing access paths, host volumes, identity changes and reparse traversal are rejected. Disk identity is checked again before releasing an owned mount. If a successful mount cannot be identified, it is left for manual inspection rather than detached by a guessed disk number. Driver functions require that checked target rather than a drive letter. Saved/paused VMs are refused for offline driver changes; shutdown is graceful. TimeoutSeconds limits follow-up polling, not the synchronous Stop-VM call itself.

SkipCleanup still stages required installers. SkipGpuDriverUpdate suppresses GPU-driver cleanup/copy, not every VM setting. ExistingVM Auto disables RDP connections; KeepRdp enables the checked rule for the configured port. NewVM display policy does not itself certify RDP connection policy. Menu option 6 reports local listener/rule observations; remote login is unverified.

## Later real-host acceptance

Use Windows PowerShell 5.1 and an appropriate Windows/Hyper-V installation, compatible GPU drivers, administrator access and a recoverable disposable test VM. This repair does not certify hardware/OS combinations. PreChecks runs real host queries and is not an isolated test.

On an authorized suitable host, record host/guest builds, GPU/driver, packages and disk identity; exercise normal installation, controlled resume and fresh verification. Test actual client login, picture, audio, requested HDR and RDP behavior from another machine. Keep failure injection isolated; do not force power loss or kill installers for testing.

ExistingVM PlanOnly/WhatIf emits a plan, not a host inspection. Here only its pure functions and AST ordering were tested; the entrypoint was not run.

See REPAIR_NOTES_20261015.md for the second static repair, evidence and remaining acceptance. REPAIR_NOTES_20261012.md retains the first-round GPU-01 through GPU-15 mapping. Current audit scripts, evidence and backups are under E:\codex\_gpu_repair_20261013; first-round evidence remains under E:\codex\_gpu_repair_20261011. Old CHANGES/EVOLUTION files are historical and may conflict with this revision.

## Second static repair notes

Conversion errors and failed cleanup stop the workflow. A pre-existing final VHD is never deleted or replaced. ISO mounts are released only by their owner. Failed/unknown WIM or hive cleanup leaves a diagnostic path for inspection; do not recursively delete that path while it may still be mounted. Partial VM creation remains an explicit recovery task.

Archive layouts are tied to the pinned versions in InstallerPolicy.json. NefCon, VDD, Virtual Audio and VB-Cable use exact archive members instead of the first matching filename. The VDD package named x86 actually declares NTamd64 in its INF; its filename alone does not select a 32-bit driver. VDD uses the pinned 25.7.23 XML format and one explicitly selected or uniquely healthy guest GPU. A conflicting VDD registry override is reported, not overwritten. Virtual Audio 25.7.23 requires guest build 22000 or later; this pinned VDD's HDR mode requires build 22631 or later. These are package/source checks, not proof of working audio or HDR.

Sunshine rules are program-scoped TCP/UDP rules matching the pinned publisher setup. Verification reads the effective firewall rules and filters. Existing conflicting project rules stop verification; unrelated rules and administrator execution policy are preserved. Existing installations may have legacy broad rules; this repair does not identify those rules as owned merely by their display names.

A required restart is recorded under the guest installer directory and must be resolved before completion. Keep those records when restaging packages. Unknown/interrupted installer state needs inspection; it must not be erased merely to obtain a green result. See the repair notes for recovery details.

Before the allocation update, the second round was a static candidate with incomplete regression: 323 checks passed, while 227 checks remain pending (77 NewVM, 37 reboot-journal, and 113 prior PostBoot checks needing current-revision rerun). Several test processes crashed inside AMSI during compilation. The 12 supported PowerShell source files passed PowerShell 5.1 parsing. See REPAIR_NOTES_20261015.md and final_validation.json; this is not real deployment acceptance.
