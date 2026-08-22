# Changelog

All notable changes to the **FedUpDate** (`fedupdate`) project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [0.4.3-beta] - 2026-08-22

### Fixed

- **Rollback Reapplying Enforced Policy (`core/RollbackEngine.ps1`)**:
  - Enforcing the watchdog while it was already enforced recorded entries whose original and new values were identical. Reverting such an entry wrote the enforced value back, so rolling back the full ledger reapplied the policy it was meant to remove. An uninstall could therefore leave Windows Update fully locked down in both `HKCU` and `HKLM` while reporting success.
  - Registry, service, and scheduled-task entries that record no actual change are now skipped during rollback, so a later transaction that correctly cleared a value is no longer undone by an earlier no-op.

---

## [0.4.2-beta] - 2026-08-22

### Fixed

- **Rollback of HKCU Policy Values (`core/RollbackEngine.ps1`)**:
  - `Record-FedRegistryChange` opened `LocalMachine` for every path, so an `HKCU:` key resolved to nothing and its value kind was never recorded. Rollback then failed on those entries with a type binding error, and uninstall reported success while leaving user policy in place.
  - The value kind is now read from the hive the path belongs to, for both `HKCU:` and `HKLM:` and their long forms.
  - Restore tolerates a missing value kind, inferring it from the recorded change instead of failing. Ledgers written before this fix can therefore still be rolled back.

---

## [0.4.1-beta] - 2026-08-22

### Fixed

- **Windows Update Scanning While the Watchdog Is Active (`core/OSUpdateEngine.ps1`)**:
  - The watchdog disables `wuauserv` by design, and the Windows Update Agent COM API needs it. A scan run in that state returned an empty result that was indistinguishable from genuinely having no updates, so enabling the shield made pending updates appear to vanish.
  - `Invoke-FedWithUpdateService` now starts the service for the duration of a query and restores its original start type and running state afterwards. The restore runs in a `finally` block, so a failed or interrupted scan cannot leave the service enabled and the shield silently off.
  - Without elevation the service cannot be started, so the scan reports that its result may be incomplete instead of returning a silent zero.
  - The search timeout is raised from 4 to 30 seconds. Four seconds was frequently shorter than a genuine online query, which was reported as the service being busy.

---

## [0.4.0-beta] - 2026-08-22

### Added

- **Version Awareness and Self-Update (`core/Version.ps1`)**:
  - The installed version is read from the topmost entry in `CHANGELOG.md`. That file already records every release, so the version cannot drift from the changelog: it is the changelog.
  - `Get-FedLatestRelease` queries the GitHub releases API, and `Compare-FedVersion` orders releases numerically with prerelease handling, so `0.10.0` is correctly newer than `0.9.0` and `1.0.0-beta` is older than `1.0.0`.
  - `Get-FedVersionStatus` reports the installed version, the published version, and whether an update is available. A failed network call is not an error: the installed version is still reported.
  - `Invoke-FedSelfUpdate` updates in place by re-running the published installer, which already upgrades an existing installation and preserves the `data/` directory. There is one upgrade path rather than a second that could diverge.
- **Version Surfaces Across All Three Interfaces**:
  - CLI: `fedupdate version` shows the installed version and checks for a newer release; `fedupdate self-update` installs it. Both support `-WhatIf`.
  - TUI: the banner reads the real version, and menu option 9 checks for and applies updates.
  - GUI: `GET /api/version` and `POST /api/self-update`, with the remote check cached per server process so opening Settings repeatedly does not repeatedly call the GitHub API.
  - GUI Settings shows a GitHub link with the repository glyph. When a newer release exists the glyph pulses, an update badge appears, and an update button is offered.

### Fixed

- **Hardcoded Version Strings (`gui/index.html`, `tui/TuiEngine.ps1`)**:
  - The GUI titlebar badge and the TUI banner both displayed a literal `v0.1.0-beta` that was never updated and did not reflect the running release. Both now read the real version.

### Removed

- **Dead Code**:
  - `mockInitialData()` in `gui/app.js`, which held placeholder package rows with fabricated version numbers. It was defined but never called.
  - The `version` field from `Get-FedDefaultConfig` (`core/Config.ps1`). It was written into `config.json` on first run and never read back, so it recorded whichever version created the file rather than the version in use.

---

## [0.3.2-beta] - 2026-08-22

### Changed

- **Notification Centre Height (`gui/styles.css`)**:
  - `--sys-dim-flyout-max-height` is derived from the window rather than fixed at `22rem`: `calc(100vh - var(--sys-dim-titlebar-height) - var(--sys-dim-dock-height) - var(--sys-space-xl))`. The flyout now grows with its contents until it reaches the docked drawer, instead of stopping at a constant height regardless of how much room the window offers.
  - The limit moved from `.notif-flyout-list` to `.notif-flyout`, so the header counts toward it and the outer edge is what stops above the dock.
  - The list takes the remaining space with `flex: 1 1 auto` and `min-height: 0`, which allows it to shrink below its content and engage its own scrollbar.

---

## [0.3.1-beta] - 2026-08-22

### Fixed

- **Shortcut Creation on Redirected User Folders (`install.ps1`)**:
  - Start Menu and Desktop locations are resolved through the Windows special-folder API rather than assumed to sit under `%USERPROFILE%`. Where OneDrive Known Folder Move has redirected the Desktop, the literal path does not exist and shortcut creation failed.
  - Each shortcut is created independently, so a failure on one no longer prevents the other from being written.
  - Uninstall resolves the same locations, so redirected shortcuts are removed cleanly.
- **Shortcut Target (`install.ps1`)**:
  - Start Menu and Desktop shortcuts launch `gui/bin/FedUpDate.UI.exe` directly, so they open the frameless application window and take their icon from the executable's embedded resource. They previously ran the VBS launcher, which serves the interface through Edge in app mode: that window carries a native title bar above the in-app one, and the shortcut icon came from `wscript.exe`.
  - The VBS launcher remains the fallback when the GUI has not been compiled, with the application icon set explicitly.

### Changed

- **Uninstall Prompt Defaults (`install.ps1`)**:
  - Both questions accept Enter. Restoring Windows Update services and settings defaults to yes, shown as `[Y/n]`; keeping backup snapshots and logs defaults to no, shown as `[y/N]`.
  - Unrecognised input re-asks instead of falling through to a branch that was not chosen.
  - A non-interactive uninstall now restores Windows Update defaults as well, so an unattended removal cannot leave update services disabled.

---

## [0.3.0-beta] - 2026-08-21

### Added

- **Remote Bootstrap Installation (`install.ps1`)**:
  - The installer now runs directly from the network with no files on disk: `irm https://raw.githubusercontent.com/Arelius-D/FedUpDate/main/install.ps1 | iex`.
  - Source-only distribution: the installer downloads the project source archive, never a packaged installer or a prebuilt binary. The command fetches a plain PowerShell script that can be read in full before it is run.
  - Compiles the desktop GUI locally during installation, using the C# compiler that ships with the .NET Framework on every Windows 10/11 machine, so no developer tooling is required. The only binaries involved are Microsoft's WebView2 libraries, fetched from Microsoft's NuGet CDN.
  - A failed or skipped GUI build is non-fatal and reports the two commands that retry it. The CLI and TUI are pure PowerShell and require no compilation.
  - Added `-Branch` to install from a specific source branch and `-SkipGuiBuild` to bypass compilation.
  - Unpacks to `%LOCALAPPDATA%\Programs\FedUpDate` by default, overridable with `-InstallPath`.
  - Added `-FromPath` to install from an already-downloaded copy without any network access.
  - Detects an existing installation and upgrades it in place, leaving the `data/` directory untouched so configuration, logs, the state ledger, and rollback snapshots survive upgrades.
  - Unwraps the single nested directory present in GitHub source archives (`FedUpDate-main/`) before installing.
  - Resolves installation paths from a verified payload root, so the User PATH entry, profile alias, and shortcuts register against the real install directory in every mode.
  - Uninstall locates an existing installation through the script directory, `-InstallPath`, the default install location, or the User PATH.
  - Running from a complete local copy continues to install in place exactly as before.
- **WebView2 SDK Restore from NuGet (`gui/SetupLibs.ps1`)**:
  - Retrieves the managed WebView2 assemblies (`lib/net462`) and the x64 native loader (`runtimes/win-x64/native`) from the official `Microsoft.Web.WebView2` package on nuget.org, keeping `gui/lib` and `gui/bin` on a single pinned version.
  - Resolves the newest stable version automatically, skipping prerelease builds; a specific version may be pinned with `-Version`.
  - Requires no NuGet client, .NET SDK, or Visual Studio: a `.nupkg` is an ordinary ZIP archive, so `Invoke-WebRequest` and `Expand-Archive` are sufficient.
  - Skips the download when the libraries are already present unless `-Force` is supplied.
  - Restores into `gui/bin` only. A second copy was previously written to `gui/lib`, which no build or runtime path reads.
- **Windows 11 Rounded Window Shell (`gui/src/Program.cs`)**:
  - The frameless host window now opts into the Windows 11 rounded shell, setting `DWMWA_WINDOW_CORNER_PREFERENCE` (attribute 33) to `DWMWCP_ROUND` once the window handle becomes available.
- **GitHub Repository Metadata (`.github/FUNDING.yml`, `.gitattributes`)**:
  - Added a funding manifest listing the project's GitHub Sponsors account.
  - Added `.gitattributes` normalising the tree to CRLF and marking image and binary types, so the `.cmd` and `.vbs` launchers keep correct line endings when the installer extracts a downloaded source archive on a user's machine.
- **`CONTRIBUTING.md` and `SECURITY.md`**:
  - Contribution guide covering the noncommercial licence terms that apply to submitted work, the build steps, and the requirement that both audits pass before a pull request.
  - Security policy documenting private vulnerability reporting, the registry, service, and scheduled-task changes the watchdog makes, the rollback paths that reverse them, and what is in and out of scope.
- **`LICENSE`**:
  - Added the PolyForm Noncommercial License 1.0.0 with the project copyright notice.

### Changed

- **Silent On-Boot Watchdog Guard (`core/AntiTamperWatchdog.ps1`)**:
  - `FedUpDate-Watchdog-Enforcer` is now registered under the SYSTEM account with `New-ScheduledTaskPrincipal -LogonType ServiceAccount -RunLevel Highest`, matching the update scheduler. The guard runs in session 0, so signing in no longer flashes a console window or raises a UAC prompt.
  - The trigger is now `-AtStartup`, enforcing machine-wide policy before any user signs in, rather than once per interactive logon.
  - Registration requires an elevated session and reports clearly when elevation is missing, instead of registering a task that cannot apply HKLM policy.
  - `-WhatIf` now reports the executable and arguments that are actually registered; the simulated and real registration paths previously differed.
- **Documented CLI Syntax (`README.md`, `fedupdate.ps1`)**:
  - Command examples and the built-in `help` output now use PowerShell parameter syntax (`-All`, `-WhatIf`, `-Latest`, `-Count`). The previously documented double-dash forms do not bind: value flags such as `--count 50` raise a parameter error, and switches such as `--all` and `--latest` were absorbed as a positional argument and silently ignored.
  - The help listing covers every routed command and its columns are aligned.
- **Single Simulation Flag (`fedupdate.ps1`, `tui/TuiEngine.ps1`, `gui/index.html`, `gui/app.js`)**:
  - Removed the `-DryRun` switch and its `simulate` alias. `-WhatIf` is the one simulation flag, matching PowerShell convention and the engine layer, which already used `-WhatIf` exclusively.
  - The TUI menu, the GUI action button, and the log-level filter now read WhatIf rather than mixing both names.
  - The `WHATIF` log level and the `whatif` field in the local GUI API are unchanged, so simulation output and the GUI request contract behave exactly as before.
- **Project License (`README.md`, `LICENSE`)**:
  - Relicensed from MIT to PolyForm Noncommercial License 1.0.0. Use, modification, and redistribution remain free for any noncommercial purpose; commercial use is not permitted.
- **Repository Exclusions (`.gitignore`)**:
  - Excluded `data/config.json`. Configuration is generated on first run by `Get-FedDefaultConfig` (`core/Config.ps1`), so every installation starts from the documented defaults.
  - Excluded `gui/lib/` and `gui/bin/*.dll`. WebView2 libraries are restored at build time by `gui/SetupLibs.ps1`.
  - Narrowed the build-artifact rules to compiled output. A directory-wide `bin/` pattern also matched `gui/bin/`, which would have withheld `gui/bin/build.ps1` — the script that compiles the GUI during installation — from the published source.
  - Excluded `audit/` (internal development reports and tooling), `archive/` (retired files kept locally for reference), and the `dist/` and `release/` packaging directories.
- **Design System Audit Scope (`audit/audit-css.ps1`)**:
  - LAW 22 (Native Host DWM Shell Compliance) now validates `gui/src/Program.cs`, the compiled host that ships, confirming both `WindowChrome` and the rounded corner preference.
- **Syntax Audit Reporting (`audit/audit-syntax.ps1`)**:
  - Results are sorted and reported as project-relative paths, so identically named scripts in different directories (`gui/build.ps1` and `gui/bin/build.ps1`) stay distinguishable.
  - `archive/` is excluded from the gate: retired code is kept for reference only and can no longer fail the audit.
- **Removed `gui/lib/`**:
  - The directory held a duplicate set of WebView2 assemblies read only by the retired PowerShell host. `gui/bin` is the single location for build and runtime libraries.
- **Retired `gui/Host.ps1`**:
  - The legacy PowerShell WPF host is superseded by `gui/src/Program.cs`, compiled as `FedUpDate.UI.exe`. It is retained locally under `archive/` for reference and excluded from the repository.
- **Default Configuration Version (`core/Config.ps1`)**:
  - `Get-FedDefaultConfig` now reports `0.3.0-beta`, matching the release.
- **Documented Architecture (`README.md`)**:
  - The directory tree reflects the current GUI layout.

---

## [0.2.0-beta] - 2026-08-19

### Added

- **"Update & Shut Down" / Direct Power Management Suite (`core/RebootEngine.ps1`, `gui/Server.ps1`, `fedupdate.ps1`, `gui/app.js`, `gui/index.html`)**:
  - Added dedicated system shutdown power action alongside reboot, allowing users to finalize pending updates and turn off their PC cleanly.
  - Added `POST /api/reboot/shutdown` server endpoint invoking `Invoke-FedRebootPolicy -PolicyOverride "Shutdown"`.
  - Added `Shutdown` case to `core/RebootEngine.ps1` calling `Stop-Computer -Force`.
  - Added `Update & Shut Down` option to the Reboot Enforcement Policy settings dropdown (`#rebootPolicySelect`).
  - Added `-Shutdown` switch parameter to CLI (`fedupdate.ps1 update -All -Shutdown`).
  - Dual action buttons rendered side-by-side in Notification Center when a reboot is pending: **Restart Now** and **Shut Down**.
- **Per-Level "Clear View" Log Management (`gui/app.js`)**:
  - Implemented granular per-level clearance tracking (`state.clearedLevels`).
  - Clearing logs while filtered by a specific severity (e.g. `ERROR`, `WARN`, `INFO`, `SUCCESS`, `WHATIF`) clears only that level, preserving all other log streams.
  - Selecting `ALL` clears the entire terminal buffer.
- **Dynamic Level-Filtered Log Export (`gui/app.js`)**:
  - Export now respects the active dropdown filter, exporting only the visible/selected severity levels.
  - Automatically generates descriptive, timestamped filenames: `fedupdate-logs-<filter>-<timestamp>.log` (e.g. `fedupdate-logs-error-2026-08-19T22-33-00.log`).
- **High-Definition Title Bar Branding (`gui/index.html`, `gui/styles.css`)**:
  - Replaced generic placeholder SVG icon with the master transparent icon (`assets/fedupdate-icon.png`) with strict tokenized sizing and `object-fit: contain;`.
- **Automatic Administrator UAC Elevation for Watchdog Enforcement (`core/AntiTamperWatchdog.ps1`)**:
  - Detects elevation status on `Enforce-FedWatchdog`. When running non-elevated, prompts via UAC (`Start-Process -Verb RunAs`) to write HKLM Group Policies and register system-wide Scheduled Tasks with graceful direct-execution fallback.

### Fixed

- **Terminal Scroll-Lock & Idle DOM Thrashing (`gui/app.js`)**:
  - Fixed the 600ms scroll jumping bug where the terminal would repeatedly pull the scrollbar back down to the bottom while idle.
  - Implemented signature hashing (`state.lastLogSig`): DOM is not re-rendered when no new log lines have arrived.
  - Implemented scroll proximity detection (`scrollHeight - scrollTop - clientHeight < 40`): Terminal only auto-scrolls if the user was already at the very bottom, allowing smooth inspection and reading at any scroll position.
- **Anti-Tamper Drift Audit False-Positive Clearance (`core/AntiTamperWatchdog.ps1`, `core/Config.ps1`)**:
  - Aligned Delivery Optimization configuration (`disableDeliveryOptimization = false`) with Windows 11 Microsoft Store streaming requirements, eliminating recurring service drift notifications.
  - Refined boot persistence task verification to prevent optional task states from triggering false policy drift alarms.
  - Verified 100% hardened compliance with zero drift (`Policy Drift Detected: False`).
- **HKLM & HKCU Registry Key Creation (`core/RollbackEngine.ps1`)**:
  - Replaced basic PowerShell `New-Item` with .NET `[Microsoft.Win32.Registry]::CurrentUser.CreateSubKey` and `LocalMachine.CreateSubKey` to create nested Group Policy registry paths without access exceptions.
- **Notification Action Routing & Client State Synchronization (`gui/app.js`)**:
  - Fixed single-quote HTML escaping for `window.navigateTo('packages')` and `window.navigateTo('osupdates')`.
  - Added instant package state recalculation upon upgrading (filters upgraded packages, decrements badge counts, and dismisses notifications immediately).
  - Added "Clear" / dismiss-all button to the notification flyout header (`#notifDismissAllBtn`).
- **Startup Splash Screen & Frame Transition (`gui/src/Program.cs`)**:
  - Eliminated the intermediate black frame on startup by initializing WebView2 directly with solid theme canvas and smooth 2.5s branding splash presentation.

### Removed

- **Obsolete Scratchpad Reference Files**:
  - Deleted `themes.md` (initial LucID theme reference document).
  - Deleted `UI and UX stuff.md` (initial WinUI 3 architecture draft).
  - Deleted `core functions.md` (initial brainstorming notes).

---

## [0.1.0-beta] - 2026-08-16

### Fixed

- **API Scan Data Hydration & Background Job Dispatch (`gui/Server.ps1`, `gui/app.js`)**:
  - Re-architected `/api/scan` in `gui/Server.ps1` to accurately extract the final audit summary PSCustomObject from the PowerShell Runspace result stream, resolving the issue where UI scan was waiting on empty arrays.
  - Automatically triggers background system audit at server boot, populating live update badges and package tables immediately.
- **WinGet Engine Output Parsing (`core/WingetEngine.ps1`)**:
  - Added strict non-empty string validation for package names, IDs, and versions to prevent phantom whitespace rows.
- **Anti-Tamper Watchdog Scheduled Task Query (`core/AntiTamperWatchdog.ps1`)**:
  - Replaced CLI string queries with native PowerShell `Get-ScheduledTask` to prevent `NativeCommandError` failures under strict `$ErrorActionPreference = "Stop"`.
- **Same-Origin API Communication & Live Data Hydration (`gui/src/Program.cs`, `gui/app.js`)**:
  - Routed WebView2 navigation directly to the local API server origin (`http://localhost:$port/`), completely eliminating Chromium Mixed Content blocks.
  - Live system audit scans now immediately populate all dashboard cards, pending Windows Update KBs, WinGet packages, Store state, and live terminal logs.
- **Terminal View Theming in Light Mode (`gui/styles.css`)**:
  - Styled `.terminal-container`, `.terminal-toolbar`, and `.terminal-body` using design tokens (`var(--sys-color-surface-card)`), eliminating the unwanted dark background in light theme.
- **Task Progress Dock Idle Management (`gui/styles.css`, `gui/app.js`)**:
  - Configured `#taskProgressDock` to hide completely (`.dock-idle`) when the system is idle, removing the perpetual indeterminate animation bar.
- **File-Backed Persistent Logging (`core/Logger.ps1`)**:
  - Enhanced `Get-FedLogs` to read historical logs from `data/logs/fedupdate.log` when starting fresh.

### Added

- **Native Compiled Standalone Desktop Executable (`gui/bin/FedUpDate.UI.exe`, `fedupdate.ps1 gui`)**:
  - Standalone native C# WPF desktop executable targeting .NET Framework 4.8 and bundling WebView2.
  - Zero OS title bar at the Desktop Window Manager (DWM) level.
  - In-app Fluent caption controls (`#winMinBtn`, `#winMaxBtn`, `#winCloseBtn`) are the sole window controls on screen.
- **Design System Audit & Compliance Suite ([`audit/CSS_AUDIT.md`](audit/CSS_AUDIT.md), [`audit/audit-css.ps1`](audit/audit-css.ps1))**:
  - Mechanical automated audit passing with zero `!important` declarations, zero fixed `px` units, zero inline style violations, and 100% OKLCH color space verification.
- **OS Default Theme Detection & Synchronization**:
  - Automatically queries the Windows OS system theme (`prefers-color-scheme: light/dark`) on initial application launch and defaults to the user's OS preference.
  - Dynamically responds to real-time OS theme switching.
- **Full 100% Clean Uninstallation Suite (`install.ps1 -Uninstall`, `fedupdate uninstall`, UI Settings Modal)**:
  - Clean removal engine unregistering PATH entries, profile integrations, scheduled tasks, and shortcuts.
- **State Ledger, Backup & Rollback Engine (`core/RollbackEngine.ps1`)**:
  - Timestamped state snapshots (`data/state_ledger.json` and `data/backups/`) for all registry, service, and task modifications.
- **Core Update Orchestration Engines**:
  - `core/OSUpdateEngine.ps1`: Direct Windows Update Agent COM integration.
  - `core/WingetEngine.ps1`: Structured WinGet package manager scanner and updater.
  - `core/StoreEngine.ps1`: Microsoft Store update trigger via WMI/CIM MDM Enterprise sync.
  - `core/RebootEngine.ps1`: Multi-registry pending reboot detection.
  - `core/AntiTamperWatchdog.ps1`: Auditing and disabling of intrusive Windows Update auto-reboot tasks and background hijacking services.
- **Standalone Build Automation Tooling (`gui/bin/build.ps1`, `gui/build.ps1`)**:
  - Added dedicated one-command compilation scripts invoking the platform C# compiler (`csc.exe`) with all required assembly references to rebuild `FedUpDate.UI.exe` deterministically without external build dependencies.
  - Implemented dynamic runtime discovery in `build.ps1` to detect the latest available `csc.exe` (PATH, Visual Studio / MSBuild Roslyn, Framework64/Framework) and WPF assembly directories with zero hardcoded path strings.
- **LucID Flagship Design System Integration: Dusk Ember & Warm Linen (`gui/styles.css`, `gui/src/Program.cs`)**:
  - Implemented full 100% OKLCH color token architecture from `themes.md`.
  - **Dusk Ember (`dusk-ember` / Dark default)**: Deep slate-charcoal canvas (`oklch(0.239 0.014 267)`), matte panel surfaces, and radiant metallic warm gold/amber brand accents (`oklch(0.773 0.14 78.6)`).
  - **Warm Linen (`warm-linen` / Light flagship)**: Warm artisanal linen canvas (`oklch(0.976 0.026 92.4)`), deep espresso typography (`oklch(0.267 0.019 84.5)`), and antique caramel-bronze brand accents (`oklch(0.643 0.055 81.4)`).
  - Verified 100% WCAG 2.1 AA contrast compliance and passed mechanical CSS audit with zero `!important` declarations, zero raw `px`, and 100% OKLCH color space.
- **Safe Ephemeral Port Allocation Range (`gui/Server.ps1`, `gui/src/Program.cs`, `gui/app.js`)**:
  - Migrated HTTP server and WebView2 navigation from restricted X11 port range (`6000-6050`) to safe ephemeral range (`58100-58150`), eliminating Chromium's `ERR_UNSAFE_PORT` error completely.
- **Asynchronous Non-Blocking Engine Scanning & Real-Time Log Streaming (`gui/Server.ps1`, `gui/app.js`)**:
  - Re-architected `/api/scan` and `/api/update` to execute on background threads via `ThreadPool`, eliminating server loop freezing and allowing `/api/logs` to stream live system events in real-time.
  - Initialized `startLogPolling()` immediately on DOM load so the terminal stream is populated from startup.
- **Navigation Toggle & Progress Dock Alignment (`gui/index.html`, `gui/styles.css`)**:
  - Moved the hamburger navigation toggle button `#navToggleBtn` directly into the top of `.nav-rail`, aligning it in the same vertical column with all navigation tab icons.
  - Re-anchored `#taskProgressDock` inside the content viewport and applied `.dock-idle` hiding by default, eliminating mismatched border outlines.
- **Terminal View Theming in Light and Dark Modes (`gui/styles.css`)**:
  - Styled `.terminal-container`, `.terminal-toolbar`, `.terminal-body`, and `.term-title` with semantic surface and typography tokens (`--sys-color-surface-card`, `--sys-color-surface-terminal`, `--sys-color-text-primary`), ensuring both Light (Warm Linen) and Dark (Dusk Ember) modes render properly.
- **Microsoft Store Pending App Scanner Integration (`core/StoreEngine.ps1`, `core/Engine.psm1`, `gui/app.js`)**:
  - Added pending Microsoft Store app detection via `winget upgrade --source msstore --disable-interactivity`.
  - Displayed real-time pending Store update counts in the dashboard Store card and badges.
- **WinGet Engine Non-Interactive Execution & Path Resolver (`core/WingetEngine.ps1`)**:
  - Added `--disable-interactivity` flag to WinGet upgrade queries, preventing escape-code table corruption and spinner hang in headless background processes.
  - Added fallback search for `winget.exe` in `Program Files\WindowsApps\Microsoft.DesktopAppInstaller_*`.
- **Anti-Tamper Shield State Handling & Safe Fetch Bridge (`gui/app.js`)**:
  - Fixed `runWatchdogAudit()` state initialization to prevent `null` property reference errors on cold startup.
- **Stationary Navigation Rail Alignment (`gui/styles.css`)**:
  - Fixed navigation item layout so icons remain 100% stationary (0px horizontal or vertical movement) when collapsing or expanding the sidebar.
- **Engine Script ASCII Encoding & Parser Fixes (`core/WingetEngine.ps1`, `core/StoreEngine.ps1`)**:
  - Replaced non-ASCII Unicode separator characters (`─`) with standard ASCII delimiters (`-`), resolving PowerShell script parser failures across all Windows execution environments.
- **Full CLI Operations & Verification Suite Validation (`fedupdate.ps1`)**:
  - Validated all core CLI modes directly on host system:
    - `.\fedupdate.ps1 watchdog audit` -> Returns complete 4-point anti-tamper posture audit with exit code 0.
    - `.\fedupdate.ps1 scan` -> Correctly returns parsed counts across Windows Update (0), WinGet (1: Meld), and Store (0), plus multi-registry reboot diagnostics.
    - `.\fedupdate.ps1 update -WhatIf` -> Simulates full 6-phase pipeline across Defender, OS updates, WinGet packages, MDM Store sync, Anti-Tamper enforcement, and reboot policies with exit code 0.
- **Native Win32 Window Manager: Dragging, Resizing & Full Maximization (`gui/src/Program.cs`)**:
  - Implemented native `ReleaseCapture` + `SendMessage(WM_NCLBUTTONDOWN, HTCAPTION)` title bar dragging, bypassing WebView2 input capture limitations.
  - Implemented `HwndSource` `WndProc` hook with `WM_NCHITTEST` supporting edge and corner drag-resizing in all directions with 8px grab boundaries.
  - Resolved window maximize snap-back by properly binding `ResizeMode.CanResize` and `WindowChrome`.
- **Custom Fluent Select Dropdown & Input System (`gui/styles.css`)**:
  - Created bespoke themed styling for all `<select>`, `<option>`, and `.fluent-select` form elements matching **Dusk Ember** and **Warm Linen** palettes with custom SVG chevrons, focus rings, and hover states.
- **PowerShell Runspace Isolated Background Execution (`gui/Server.ps1`)**:
  - Migrated background scan and update routines from uninitialized .NET ThreadPool workers to dedicated PowerShell Runspaces, resolving `Start-FedScan` missing cmdlet errors in the GUI server.
- **Manual Dashboard Scan Action (`gui/index.html`, `gui/app.js`)**:
  - Added dedicated "Scan for Updates" button to the unified dashboard header.
- **PSScriptAnalyzer & IDE Linter Cleanup Across All Core Scripts**:
  - Removed invalid `Export-ModuleMember` invocations from all dot-sourced `.ps1` files (`OSUpdateEngine.ps1`, `StoreEngine.ps1`, `WingetEngine.ps1`, `Scheduler.ps1`, `RollbackEngine.ps1`, `RebootEngine.ps1`, `Logger.ps1`, `Config.ps1`, `AntiTamperWatchdog.ps1`), consolidating all public exports strictly in `core/Engine.psm1`.
  - Replaced legacy `Get-WmiObject` with modern `Get-CimInstance` in `StoreEngine.ps1`, eliminating `PSAvoidUsingWMICmdlet` warnings.
- **Sub-Second Fast Scan Optimization (`core/OSUpdateEngine.ps1`, `core/StoreEngine.ps1`)**:
  - Configured Windows Update COM search to query local cached catalog first with fallback, preventing multi-minute cloud handshake lockups on GUI startup.
  - Added 3.5s timeout guard and fast-path AppX status check in `StoreEngine.ps1` to prevent `winget upgrade --source msstore` from blocking background operations.
