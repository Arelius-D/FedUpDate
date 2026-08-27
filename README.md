<div align="center">
  <img src="assets/readme/logo-512.png" width="128" height="128" alt="FedUpDate Logo" />
  <h1>FedUpDate</h1>
  <p><strong>Unified Windows 11 Update &amp; Anti-Tamper Orchestrator</strong></p>
  <p><em>"Because Microsoft needs three separate corporate divisions and zero communication to update one operating system."</em></p>
</div>

An ultra-lightweight, transparent, and modern Windows 11 update management suite. It unifies Windows' fragmented update engines into a single, cohesive command center while protecting user control through an active Anti-Tamper State Watchdog and a true 1-Click Rollback Engine.

---

## 🌟 Key Capabilities

- **The 3-in-1 Unified Update Engine**:
  - **OS & Defender Ring**: Native Windows Update Agent COM API (`Microsoft.Update.Session`) + Microsoft Defender Antivirus signatures (`MpCmdRun.exe`). No mid-flight forced restarts.
  - **WinGet Applications Ring**: Automated detection and upgrade of third-party software, developer tools, and runtimes via `winget.exe`.
  - **Microsoft Store Sync Ring**: WMI/CIM MDM Enterprise scan method (`MDM_EnterpriseModernAppManagement_AppManagement01:UpdateScanMethod`) and Store background sync queue.

- **Anti-Tamper & Policy Watchdog**:
  - Audits and suppresses invasive Windows background update services (`wuauserv`, `DoSvc`, `UsoSvc`) and scheduled auto-reboot tasks.
  - Includes an on-boot persistence guard (`FedUpDate-Watchdog-Enforcer`) that audits and restores your chosen policies even after major Windows patches try to revert them.

- **100% Reversible State Ledger & Rollback Engine**:
  - Every registry modification, service configuration, and task change is snapshotted into `data/state_ledger.json` and timestamped `.bak` files.
  - Full 1-Click Rollback (`fedupdate rollback` or in GUI) reverts settings cleanly back to previous states.

- **Full `-WhatIf` Simulation**:
  - Simulate update scans, installations, watchdog enforcements, and rollbacks without modifying a single byte on your system.

- **Honest Restart Handling**:
  - A pending restart is graded, not assumed. Servicing flags and files replaced in place mean the system is waiting; an installer's temporary folder queued for deletion is routine cleanup and is reported as exactly that, with the paths named. The interfaces never demand a restart that would not change anything.

- **Update Channels & In-Place Updates**:
  - Follow published releases on the stable channel or prereleases on beta. Self-update pulls from the branch the chosen channel is cut from, so the version offered is always the version delivered.

- **Triple-Interface Flexibility**:
  - **Modern Fluent 2 Desktop GUI**: Glassmorphic Mica/Acrylic backdrops, custom 48px extended title bar, 3 glowing status rings, SettingsCards, badge pills, and a real-time docked task progress drawer with a live terminal stream.
  - **Interactive Terminal TUI**: Fast keyboard-driven ANSI dashboard with interactive checkboxes and meters.
  - **Headless CLI**: Scriptable, pipe-friendly command line for power users and automation.

- **Zero Opaque Dependencies**:
  - 100% transparent C# host and PowerShell architecture with zero bloat and zero false positives.

---

## ⚡ Quick Start

### Installation (Zero External Dependencies)

Run in PowerShell:

```powershell
irm https://raw.githubusercontent.com/Arelius-D/FedUpDate/main/install.ps1 | iex
```

No packaged installer, no prebuilt binary. The source is downloaded, `fedupdate`
is added to your User PATH, and Start Menu and Desktop shortcuts are created.

The desktop GUI is compiled on your machine during installation with the C#
compiler that ships with Windows. The only binaries involved are Microsoft's
WebView2 libraries, pulled from Microsoft's NuGet CDN.

CLI and TUI are pure PowerShell and need no compilation.

### Updating

FedUpDate updates itself in place, from inside the app or from the command line:

```powershell
fedupdate self-update
```

Two update channels are available, chosen under Settings or as `updateChannel`
in `data/config.json`:

| Channel  | Offered                          | Installs from |
|----------|----------------------------------|---------------|
| `stable` | Published releases only          | `main`        |
| `beta`   | Prereleases as well              | `dev`         |

What is offered and what arrives always come from the same place, so an
installation can never be told about a version it cannot get.

### Uninstalling

```powershell
fedupdate uninstall
```

You are asked what should happen to the update settings FedUpDate applied,
because they belong to you, not to the installer:

| Outcome                | Settings | Ledger                              |
|------------------------|----------|-------------------------------------|
| Restore defaults       | Reverted | Removed                             |
| Keep settings          | Kept     | Saved to `Documents\FedUpDate-Backups`, so they can be reverted by hand later |
| Keep settings, purge   | Kept     | Removed. The settings become permanent |

The on-boot guard is removed in every case, so kept settings are no longer
defended and Windows may revert them later. Unattended:

```powershell
.\install.ps1 -Uninstall -UninstallMode RestoreDefaults -NonInteractive
```

---

## 🖥️ Interfaces

### Desktop GUI

```powershell
fedupdate gui
```

![The dashboard in the dark theme](assets/screenshots/gui-dashboard-dark.png)

![The dashboard in the light theme](assets/screenshots/gui-dashboard-light.png)

### Terminal TUI

```powershell
fedupdate tui
# or simply
fedupdate
```

```text
    ______         ____  __      ____        __
   / ____/__  ____/ / / / /___  / __ \____ _/ /____
  / /_  / _ \/ __  / / / / __ \/ / / / __ `/ __/ _ \
 / __/ /  __/ /_/ / /_/ / /_/ / /_/ / /_/ / /_/  __/
/_/    \___/\__,_/\____/ .___/_____/\__,_/\__/\___/
                      /_/
FedUpDate v1.0.14 | Unified Windows Update & Anti-Tamper Suite
--------------------------------------------------------------------------------
 OS Updates: 0 KBs | WinGet: 2 Apps | Store: Synced | Reboot:  CLEANUP QUEUED  | Guard:  SHIELD ACTIVE
--------------------------------------------------------------------------------
MAIN MENU
 [1] Update All (Executes OS + WinGet + Store + Post-Check)
 [2] WhatIf Simulation (Simulate an update run without touching the system)
 [3] Scan & Audit System (Deep check of all 3 engines & reboot flags)
 [4] Anti-Tamper Watchdog Center (Lock down Windows update auto-hijackers)
 [5] Rollback & State Ledger (1-Click restore of original OS settings/registry)
 [6] Task Scheduler Automation (Configure automated background runs)
 [7] Launch Modern Desktop GUI (Open Fluent 2 Desktop Window)
 [8] View System Logs (Browse real-time rolling logs)
 [9] Version & Update (Check for a new release and update in place)
 [Q] Quit
```

### Command Line

| Command | What it does |
|---------|--------------|
| `fedupdate scan` | Audit all three engines, reboot state and the anti-tamper shield |
| `fedupdate check` | Same audit, exit code only: `0` clean, `1` updates pending |
| `fedupdate update -All` | Run every engine, enforce the shield, then evaluate the reboot policy |
| `fedupdate update -OS` / `-Winget` / `-Store` | One engine only |
| `fedupdate update -All -WhatIf` | Simulate the whole run without touching anything |
| `fedupdate watchdog audit` / `enforce` | Inspect or re-apply the anti-tamper shield |
| `fedupdate rollback` | List the state ledger |
| `fedupdate rollback -Latest` / `-All` / `-TransactionId <id>` | Revert recorded changes |
| `fedupdate schedule set -Frequency Daily -Time "02:00"` | Register an automated run |
| `fedupdate schedule remove` | Remove it |
| `fedupdate logs -Count 50` | Recent log entries |
| `fedupdate config` | Print the active configuration |
| `fedupdate version` | Installed version, and whether a newer one is published |
| `fedupdate self-update` | Update in place |
| `fedupdate uninstall` | Remove, with the choices described above |
| `fedupdate help` | This list. `-h`, `--help`, `-?` and `/?` work too |

Restart handling on `update` can be overridden per run with `-RebootPolicy`,
`-NoReboot`, `-ForceReboot` or `-Shutdown`. A restart is only ever forced for
something the system is genuinely waiting on, never for routine installer
cleanup.

---

## 📁 Directory Structure

``` shell
FedUpDate/
├── CHANGELOG.md               # Versioning and exhaustive changelog
├── README.md                  # Documentation and user guide
├── install.ps1                # One-liner zero-dependency installer
├── fedupdate.ps1              # Master CLI / TUI / GUI entry point
├── fedupdate.cmd              # Windows CMD/terminal wrapper
├── fedupdate-gui.vbs          # Zero-terminal silent GUI launcher
├── assets/                    # Brand marks, every size the project ships
│   ├── master.png             # 1024px source the rest is rendered from
│   ├── app/                   # Splash and title bar marks used by the GUI
│   ├── desktop/               # app.ico for Windows, iconset and hicolor sets
│   ├── readme/                # Documentation marks
│   ├── screenshots/           # Interface captures used by this README
│   └── web/                   # Favicon, touch icon and PWA marks
├── core/                      # PowerShell Engine Core
│   ├── Engine.psm1            # Master module orchestrator
│   ├── OSUpdateEngine.ps1     # Native Windows Update Agent & Defender updater
│   ├── WingetEngine.ps1       # WinGet package manager parser & updater
│   ├── StoreEngine.ps1        # Microsoft Store MDM CIM update engine
│   ├── RebootEngine.ps1       # Multi-registry reboot detection & policy handler
│   ├── AntiTamperWatchdog.ps1 # Windows update service auditor & boot enforcer
│   ├── RollbackEngine.ps1     # State ledger, registry/service snapshot & restore
│   ├── Scheduler.ps1          # Windows Scheduled Task automation
│   ├── Config.ps1             # Configuration manager (config.json)
│   └── Logger.ps1             # Structured, colorized rolling logger
├── tui/                       # Terminal User Interface
│   └── TuiEngine.ps1          # Interactive keyboard-driven ANSI dashboard
├── gui/                       # Fluent 2 Modern Desktop Interface
│   ├── index.html             # Semantic Windows 11 Fluent 2 layout
│   ├── styles.css             # Vanilla CSS design system (Mica, Acrylic, Fluent Cards)
│   ├── app.js                 # Reactive UI controller & state management
│   ├── Server.ps1             # Lightweight local HTTP/IPC bridge
│   └── src/Program.cs         # C# native WPF WebView2 desktop window host
└── data/                      # Local App Data & Snapshots
    ├── config.json            # User preferences and rules
    ├── state_ledger.json      # Complete change ledger for rollbacks
    ├── backups/               # Timestamped state and file backups
    └── logs/                  # Rolling execution logs (fedupdate.log)
```

---

## 📜 License

[PolyForm Noncommercial License 1.0.0](LICENSE). Free to use, modify, and share for any noncommercial purpose. No person or company may use this software, or work based on it, for a commercial purpose. Built for users who want complete control, transparency, and peace of mind over their operating system updates.
