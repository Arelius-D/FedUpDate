# ==============================================================================
# FedUpDate Zero-Dependency Transparent Installer & Uninstaller
# Safe, auditable installation and 100% reversible uninstallation engine
#
# Supports two execution modes:
#
#   Local     - run from a folder that already contains FedUpDate. Installs
#               in place, exactly as before.
#                 .\install.ps1
#
#   Bootstrap - run directly from the network with no files on disk. Downloads
#               the project source, unpacks it, installs, and compiles the
#               desktop GUI locally. No prebuilt binary is ever distributed.
#                 irm https://raw.githubusercontent.com/Arelius-D/FedUpDate/main/install.ps1 | iex
#
#               To pass switches in bootstrap mode, create the script block first:
#                 & ([scriptblock]::Create((irm <url>))) -InstallPath 'D:\Tools\FedUpDate'
# ==============================================================================

[CmdletBinding()]
param(
    [Parameter()]
    [switch]$Uninstall,

    # What happens to the update settings FedUpDate applied, and to the ledger
    # that records them. There is deliberately no default. A machine's update
    # policy belongs to the person using it, so an unattended run has to state
    # the outcome it wants rather than have one chosen on its behalf.
    #
    #   RestoreDefaults       undo every change, then remove everything
    #   KeepSettings          leave the settings in place and keep the ledger,
    #                         so they can still be reverted by hand later
    #   KeepSettingsAndPurge  leave the settings in place and delete the ledger,
    #                         which makes them permanent
    [Parameter()]
    [string]$UninstallMode,

    [Parameter()]
    [switch]$NonInteractive,

    # Target directory for bootstrap installs. Ignored when installing in place.
    [Parameter()]
    [string]$InstallPath,

    # Install from an already-downloaded copy instead of fetching the source.
    [Parameter()]
    [string]$FromPath,

    # Source branch to install from.
    [Parameter()]
    [string]$Branch = "main",

    # Skip compiling the desktop GUI. CLI and TUI are unaffected.
    [Parameter()]
    [switch]$SkipGuiBuild
)

$RepoSlug = "Arelius-D/FedUpDate"
$DefaultInstallPath = Join-Path $env:LOCALAPPDATA "Programs\FedUpDate"

# The marker file that identifies a directory as a real FedUpDate payload.
$PayloadMarker = "fedupdate.ps1"

# The outcomes an uninstall can have. Declared here rather than as a ValidateSet
# on the parameter itself: the documented installer runs through 'irm | iex',
# which evaluates the parameter block in the caller's scope, and a validation
# attribute on an optional string rejects its own empty default there. The value
# is checked in the uninstall block instead.
$FedUninstallModes = @("RestoreDefaults", "KeepSettings", "KeepSettingsAndPurge")

# ==============================================================================
# Helpers
# ==============================================================================

function Get-FedProfilePath {
    <#
        Every PowerShell profile this installation could have written to.

        $PROFILE resolves two ways at once. The directory differs by edition:
        PowerShell 7 uses Documents\PowerShell and Windows PowerShell uses
        Documents\WindowsPowerShell. The current-host file name differs by host:
        Microsoft.PowerShell_profile.ps1 in a console, Microsoft.VSCode_profile.ps1
        inside the editor, Microsoft.PowerShellISE_profile.ps1 in the ISE, and
        whatever a host not yet written names itself.

        Installing from one host and removing from another would otherwise leave
        a fedupdate function behind pointing at a directory that no longer
        exists, so rather than guessing host names this lists what is actually
        present. Install writes only to the host it was run from, because PATH
        already covers the others.
    #>
    $roots = [System.Collections.Generic.List[string]]::new()

    foreach ($docs in @([Environment]::GetFolderPath('MyDocuments'), (Join-Path $env:USERPROFILE "Documents"))) {
        if ([string]::IsNullOrWhiteSpace($docs)) { continue }
        $roots.Add((Join-Path $docs "PowerShell"))
        $roots.Add((Join-Path $docs "WindowsPowerShell"))
    }

    $paths = [System.Collections.Generic.List[string]]::new()

    # Whatever the running host reports, in case Documents is redirected
    # somewhere neither directory above finds.
    foreach ($known in @($PROFILE.CurrentUserAllHosts, $PROFILE.CurrentUserCurrentHost)) {
        if ($known) {
            $paths.Add($known)
            $roots.Add((Split-Path -Parent $known))
        }
    }

    foreach ($root in ($roots | Where-Object { $_ } | Select-Object -Unique)) {
        $paths.Add((Join-Path $root "profile.ps1"))
        $paths.Add((Join-Path $root "Microsoft.PowerShell_profile.ps1"))

        if (Test-Path $root) {
            foreach ($f in @(Get-ChildItem -Path $root -Filter "Microsoft.*_profile.ps1" -File -ErrorAction SilentlyContinue)) {
                $paths.Add($f.FullName)
            }
        }
    }

    return @($paths | Select-Object -Unique)
}
function Remove-FedProfileHook {
    <#
        Strips the FedUpDate alias from a PowerShell profile.

        Removal is line based rather than a multiline regex. A regex that tried
        to match the comment through the function body matched lazily and left
        the body behind, and an orphaned scriptblock literal is evaluated and
        printed by PowerShell on every new session. Matching any line that
        mentions the entry script also clears fragments left by earlier builds.
    #>
    param([Parameter(Mandatory = $true)][string]$ProfilePath)

    if (-not (Test-Path $ProfilePath)) { return $false }

    $lines = @(Get-Content -Path $ProfilePath -ErrorAction SilentlyContinue)
    if ($lines.Count -eq 0) { return $false }

    $kept = @($lines | Where-Object {
        $trimmed = $_.Trim()
        -not ($trimmed -eq '# FedUpDate Alias Integration' -or
              $trimmed.StartsWith('function fedupdate') -or
              $_ -like '*fedupdate.ps1*')
    })

    if ($kept.Count -eq $lines.Count) { return $false }

    $text = ($kept -join [Environment]::NewLine).TrimEnd()
    Set-Content -Path $ProfilePath -Value $text -Encoding UTF8
    return $true
}

function Read-FedYesNo {
    <#
        Prompts for a yes/no answer with a default that pressing Enter accepts.
        The default is shown as the capitalised letter, so [Y/n] means Enter
        chooses yes. Anything unrecognised re-asks rather than silently taking
        a branch the user did not choose.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Question,
        [Parameter(Mandatory = $true)][ValidateSet("Y", "N")][string]$Default
    )

    $hint = if ($Default -eq "Y") { "[Y/n]" } else { "[y/N]" }

    while ($true) {
        $answer = (Read-Host "$Question $hint").Trim()
        if ([string]::IsNullOrEmpty($answer)) { return ($Default -eq "Y") }
        if ($answer -match '^(y|yes)$') { return $true }
        if ($answer -match '^(n|no)$')  { return $false }
        Write-Host "  Please answer y or n." -ForegroundColor Yellow
    }
}

function Read-FedUninstallMode {
    <#
        Asks what should become of the update settings and of the ledger that
        records them. Follows the same rule as Read-FedYesNo: an unrecognised
        answer re-asks rather than silently taking a branch the user did not
        choose. There is no default, because every branch here is a decision
        about the machine's own update policy.
    #>
    Write-Host ""
    Write-Host "  What should happen to the update settings FedUpDate applied?" -ForegroundColor Cyan
    Write-Host "    1  Restore Windows defaults. Undo every change FedUpDate made."
    Write-Host "    2  Keep the settings, and keep the ledger so they can be reverted later."
    Write-Host "    3  Keep the settings, and delete the ledger. They become permanent."
    Write-Host ""
    Write-Host "  The on-boot enforcer is removed with the application in every case, so" -ForegroundColor Gray
    Write-Host "  kept settings are no longer defended and Windows may revert them later." -ForegroundColor Gray
    Write-Host ""

    while ($true) {
        $answer = (Read-Host "  Choose 1, 2 or 3").Trim()
        switch ($answer) {
            "1"     { return "RestoreDefaults" }
            "2"     { return "KeepSettings" }
            "3"     { return "KeepSettingsAndPurge" }
            Default { Write-Host "  Please answer 1, 2 or 3." -ForegroundColor Yellow }
        }
    }
}

function Start-FedDetachedRemoval {
    <#
        Removes directories that cannot be deleted by the process standing in
        them. A detached host waits for this process to exit, then clears each
        path, retrying briefly while the last file handles are released. This
        is what lets an uninstall remove the application it is running from
        without leaving the removal until the next restart.
    #>
    param(
        [Parameter(Mandatory = $true)][string[]]$Path
    )

    $targets = @($Path | Where-Object { $_ -and (Test-Path -LiteralPath $_) })
    if ($targets.Count -eq 0) { return $true }

    $quoted = ($targets | ForEach-Object { "'" + ($_ -replace "'", "''") + "'" }) -join ","

    $waiter = @"
try { Wait-Process -Id $PID -Timeout 120 -ErrorAction SilentlyContinue } catch { }
Start-Sleep -Milliseconds 750
foreach (`$target in @($quoted)) {
    for (`$attempt = 0; `$attempt -lt 12; `$attempt++) {
        if (-not (Test-Path -LiteralPath `$target)) { break }
        Remove-Item -LiteralPath `$target -Recurse -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 400
    }
}
"@

    # Encoded so that no path quoting has to survive a command line.
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($waiter))

    $hostExe = try { (Get-Process -Id $PID).Path } catch { $null }
    if (-not $hostExe) { $hostExe = "powershell.exe" }

    try {
        Start-Process -FilePath $hostExe `
            -ArgumentList @("-NoProfile", "-NonInteractive", "-WindowStyle", "Hidden", "-EncodedCommand", $encoded) `
            -WorkingDirectory ([IO.Path]::GetTempPath()) `
            -WindowStyle Hidden | Out-Null
        return $true
    } catch {
        return $false
    }
}

function Get-FedShellFolder {
    <#
        Resolves a Windows shell folder to its real location.

        Desktop and Documents are frequently redirected into OneDrive by Known
        Folder Move, in which case %USERPROFILE%\Desktop does not exist. The
        .NET special-folder API follows that redirection; the literal path is
        only a fallback for the rare case where it returns nothing.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [System.Environment+SpecialFolder]$Folder,
        [string]$Fallback
    )

    try {
        $resolved = [Environment]::GetFolderPath($Folder)
        if ($resolved -and (Test-Path $resolved)) { return $resolved }
    } catch { }

    if ($Fallback -and (Test-Path $Fallback)) { return $Fallback }
    return $null
}

function Test-FedPayloadRoot {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    return (Test-Path (Join-Path $Path $PayloadMarker))
}

function Get-FedExistingInstallRoot {
    <#
        Locates an existing installation without downloading anything.
        Used by the uninstaller and to detect in-place upgrades.
    #>

    # 1. The folder this script is running from, when there is one.
    if (Test-FedPayloadRoot $PSScriptRoot) { return $PSScriptRoot }

    # 2. An explicitly supplied path.
    if (Test-FedPayloadRoot $InstallPath) { return $InstallPath }

    # 3. The default bootstrap location.
    if (Test-FedPayloadRoot $DefaultInstallPath) { return $DefaultInstallPath }

    # 4. Any FedUpDate directory already registered on the User PATH.
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    if ($userPath) {
        foreach ($entry in ($userPath -split ";" | Where-Object { $_ })) {
            if (Test-FedPayloadRoot $entry) { return $entry }
        }
    }

    return $null
}

function Expand-FedPayload {
    <#
        Expands an archive and returns the directory that actually holds the
        payload. GitHub source archives nest everything one level deep inside
        a single folder (FedUpDate-main), so that level is unwrapped here.
    #>
    param(
        [string]$ArchivePath,
        [string]$Destination
    )

    Expand-Archive -Path $ArchivePath -DestinationPath $Destination -Force

    if (Test-FedPayloadRoot $Destination) { return $Destination }

    $rootEntries = @(Get-ChildItem -Path $Destination -Force)
    $rootDirs = @($rootEntries | Where-Object { $_.PSIsContainer })
    if ($rootDirs.Count -eq 1 -and (Test-FedPayloadRoot $rootDirs[0].FullName)) {
        return $rootDirs[0].FullName
    }

    return $null
}

function Get-FedSourcePayload {
    <#
        Downloads the project source into a temporary directory and returns the
        extracted payload path.

        Only source is published. The desktop GUI is compiled locally at install
        time, so nothing opaque is ever distributed: every line that runs on the
        machine arrives as readable text.
    #>
    param([string]$WorkDir)

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    $archivePath = Join-Path $WorkDir "payload.zip"
    $extractDir = Join-Path $WorkDir "extracted"
    $downloadUrl = "https://github.com/$RepoSlug/archive/refs/heads/$Branch.zip"

    Write-Host "[INFO] Downloading FedUpDate source ($Branch)..." -ForegroundColor Cyan

    $progressPreferenceOriginal = $ProgressPreference
    $ProgressPreference = "SilentlyContinue"   # Restores throughput lost to the progress bar
    try {
        Invoke-WebRequest -Uri $downloadUrl -OutFile $archivePath -UseBasicParsing
    } finally {
        $ProgressPreference = $progressPreferenceOriginal
    }

    $payloadRoot = Expand-FedPayload -ArchivePath $archivePath -Destination $extractDir
    if (-not $payloadRoot) {
        throw "Downloaded archive did not contain $PayloadMarker."
    }

    return $payloadRoot
}

function Invoke-FedGuiBuild {
    <#
        Restores the WebView2 libraries from Microsoft's NuGet CDN and compiles
        the desktop GUI on this machine. build.ps1 discovers whichever C#
        compiler is present, including the csc.exe that ships with the .NET
        Framework on every Windows 10/11 installation, so no developer tooling
        is required.

        A failure here is not fatal: the CLI and TUI are pure PowerShell and
        work without any compilation.
    #>
    param([string]$Root)

    $setupLibs = Join-Path $Root "gui\SetupLibs.ps1"
    $buildScript = Join-Path $Root "gui\bin\build.ps1"
    $exePath = Join-Path $Root "gui\bin\FedUpDate.UI.exe"

    if (-not (Test-Path $setupLibs) -or -not (Test-Path $buildScript)) {
        Write-Host "[WARN] GUI build scripts not found; skipping desktop GUI." -ForegroundColor Yellow
        return $false
    }

    try {
        Write-Host "[INFO] Restoring WebView2 libraries from nuget.org..." -ForegroundColor Cyan
        & $setupLibs | Out-Null

        Write-Host "[INFO] Compiling the desktop GUI on this machine..." -ForegroundColor Cyan
        & $buildScript | Out-Null

        if (Test-Path $exePath) {
            Write-Host "[OK] Desktop GUI compiled successfully." -ForegroundColor Green
            return $true
        }
        throw "Compiler reported success but produced no executable."
    } catch {
        Write-Host "[WARN] Could not build the desktop GUI: $_" -ForegroundColor Yellow
        Write-Host "       The CLI and TUI are unaffected and ready to use." -ForegroundColor Yellow
        Write-Host "       To retry later: gui\SetupLibs.ps1 then gui\bin\build.ps1" -ForegroundColor Yellow
        return $false
    }
}

function Copy-FedPayload {
    <#
        Copies payload files into the install root. The data directory is left
        untouched so that upgrades preserve configuration, logs, the state
        ledger, and rollback snapshots.
    #>
    param(
        [string]$Source,
        [string]$Destination
    )

    if (-not (Test-Path $Destination)) {
        New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    }

    foreach ($item in Get-ChildItem -Path $Source -Force) {
        if ($item.PSIsContainer -and $item.Name -eq "data") { continue }
        Copy-Item -Path $item.FullName -Destination $Destination -Recurse -Force
    }
}

# ==============================================================================
# Uninstall Section
# ==============================================================================

if ($Uninstall) {
    Write-Host "`n=== Uninstalling FedUpDate ===" -ForegroundColor Yellow

    $scriptDir = Get-FedExistingInstallRoot
    if (-not $scriptDir) {
        Write-Host "[WARN] No FedUpDate installation found. Nothing to uninstall." -ForegroundColor Yellow
        return
    }
    Write-Host "[INFO] Found installation at: $scriptDir" -ForegroundColor Cyan

    $enginePath = Join-Path $scriptDir "core\Engine.psm1"
    $dataDir = Join-Path $scriptDir "data"

    # Step 1: Establish the outcome. It is asked for, passed in, or refused.
    # It is never assumed, because every branch decides what happens to update
    # policy on a machine that belongs to somebody else.
    $mode = $UninstallMode
    if ($mode -and $mode -notin $FedUninstallModes) {
        Write-Host "[ERROR] Unrecognised -UninstallMode '$mode'." -ForegroundColor Red
        Write-Host "        Choose one of: $($FedUninstallModes -join ', ')" -ForegroundColor Red
        Write-Host "        Nothing has been changed." -ForegroundColor Red
        return
    }
    if (-not $mode) {
        if ($NonInteractive) {
            Write-Host "[ERROR] -NonInteractive requires -UninstallMode." -ForegroundColor Red
            Write-Host "        Choose RestoreDefaults, KeepSettings or KeepSettingsAndPurge." -ForegroundColor Red
            Write-Host "        Nothing has been changed." -ForegroundColor Red
            return
        }
        $mode = Read-FedUninstallMode
    }

    $restoreState = ($mode -eq "RestoreDefaults")
    $keepLedger = ($mode -eq "KeepSettings")

    # Step 2: Settings, and the tasks that maintain them. The enforcer and any
    # scheduled run are removed whatever the choice, because both invoke the
    # application and neither can do anything once it is gone.
    if (Test-Path $enginePath) {
        try {
            Import-Module $enginePath -Force -DisableNameChecking

            if ($restoreState) {
                Write-Host "Reverting settings and re-enabling Windows Update defaults..." -ForegroundColor Cyan
                Restore-FedState -All -ErrorAction SilentlyContinue | Out-Null
                Write-Host "[OK] Windows defaults restored." -ForegroundColor Green
            } else {
                Write-Host "[OK] Update settings left exactly as they are." -ForegroundColor Green
            }

            Uninstall-FedWatchdogTask -ErrorAction SilentlyContinue | Out-Null
            Remove-FedScheduleTask -ErrorAction SilentlyContinue | Out-Null
            Write-Host "[OK] Removed the on-boot enforcer and any scheduled run." -ForegroundColor Green
        } catch {
            Write-Host "[WARN] Could not complete the settings step: $_" -ForegroundColor Yellow
        }
    }

    # Step 3: The ledger. Keeping the settings without it would leave changes
    # on the machine with no record of what they were, so it is copied out
    # before the installation directory goes.
    if ($keepLedger -and (Test-Path $dataDir)) {
        $exportDir = "$env:USERPROFILE\Documents\FedUpDate-Backups"
        try {
            if (-not (Test-Path $exportDir)) { New-Item -ItemType Directory -Path $exportDir -Force | Out-Null }
            Copy-Item -Path "$dataDir\*" -Destination $exportDir -Recurse -Force -ErrorAction SilentlyContinue
            Write-Host "[OK] Ledger, snapshots and logs saved to: $exportDir" -ForegroundColor Green
        } catch {
            Write-Host "[WARN] Failed to export the ledger: $_" -ForegroundColor Yellow
        }
    }

    # Step 4: Remove from User PATH
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    if ($userPath -like "*$scriptDir*") {
        $newPath = ($userPath -split ";" | Where-Object { $_ -ne $scriptDir -and $_ -ne "" }) -join ";"
        [Environment]::SetEnvironmentVariable("Path", $newPath, "User")
        Write-Host "[OK] Removed from User PATH." -ForegroundColor Green
    }

    # Step 5: Clean PowerShell profile hooks
    foreach ($p in (Get-FedProfilePath)) {
        if (Test-Path $p) {
            if (Remove-FedProfileHook -ProfilePath $p) {
                Write-Host "[OK] Removed alias from profile: $p" -ForegroundColor Green
            }
        }
    }

    # Step 6: Remove Shortcuts
    $startMenuDir = Get-FedShellFolder -Folder Programs -Fallback "$env:APPDATA\Microsoft\Windows\Start Menu\Programs"
    $desktopDir = Get-FedShellFolder -Folder DesktopDirectory -Fallback "$env:USERPROFILE\Desktop"
    $shortcutsToRemove = @($startMenuDir, $desktopDir) |
        Where-Object { $_ } |
        ForEach-Object { Join-Path $_ "FedUpDate.lnk" }
    foreach ($s in $shortcutsToRemove) {
        if (Test-Path $s) {
            Remove-Item $s -Force -ErrorAction SilentlyContinue
            Write-Host "[OK] Removed shortcut: $s" -ForegroundColor Green
        }
    }

    # Step 7: Remove the application itself, including the desktop interface's
    # browser profile, which lives outside the installation directory. This
    # cannot be done from inside the directory being deleted, so it is handed
    # to a detached process that waits for this one to exit.
    $webViewDir = Join-Path $env:LOCALAPPDATA "FedUpDate"
    $removalTargets = @($scriptDir, $webViewDir)

    if (Start-FedDetachedRemoval -Path $removalTargets) {
        Write-Host "[OK] Application files are removed as this process exits." -ForegroundColor Green
    } else {
        Write-Host "[WARN] Could not remove the following. Delete them by hand:" -ForegroundColor Yellow
        foreach ($t in $removalTargets) { Write-Host "         $t" -ForegroundColor Yellow }
    }

    Write-Host "`nFedUpDate uninstalled." -ForegroundColor Green
    if ($keepLedger) {
        Write-Host "Update settings were kept. The ledger is in Documents\FedUpDate-Backups," -ForegroundColor Cyan
        Write-Host "which is what makes those settings reversible by hand later." -ForegroundColor Cyan
    } elseif (-not $restoreState) {
        Write-Host "Update settings were kept and the ledger was deleted, so they are permanent." -ForegroundColor Cyan
    }
    if (-not $restoreState) {
        Write-Host "Nothing enforces them on boot any more, so Windows may revert them." -ForegroundColor Gray
    }
    return
}

# ==============================================================================
# Installation Section
# ==============================================================================
Write-Host "`n=== Installing FedUpDate (fedupdate) ===" -ForegroundColor Cyan

# 1. Resolve the payload.
#    Running from a complete copy installs in place. Otherwise - piped through
#    iex, where $PSScriptRoot is empty - the payload is fetched first.
$scriptDir = $null
$workDir = $null

try {
    if (Test-FedPayloadRoot $PSScriptRoot) {
        $scriptDir = $PSScriptRoot
        Write-Host "[INFO] Installing in place from: $scriptDir" -ForegroundColor Cyan
    } else {
        $targetRoot = if ($InstallPath) { $InstallPath } else { $DefaultInstallPath }

        if ($FromPath) {
            if (-not (Test-FedPayloadRoot $FromPath)) {
                Write-Error "No $PayloadMarker found in -FromPath: $FromPath"
                exit 1
            }
            $payloadRoot = $FromPath
        } else {
            $workDir = Join-Path ([IO.Path]::GetTempPath()) ("fedupdate-install-" + [Guid]::NewGuid().ToString("N"))
            New-Item -ItemType Directory -Path $workDir -Force | Out-Null
            $payloadRoot = Get-FedSourcePayload -WorkDir $workDir
        }

        $existing = Get-FedExistingInstallRoot
        if ($existing) {
            $targetRoot = $existing
            Write-Host "[INFO] Existing installation detected, upgrading: $targetRoot" -ForegroundColor Cyan
        }

        Write-Host "[INFO] Unpacking to: $targetRoot" -ForegroundColor Cyan
        Copy-FedPayload -Source $payloadRoot -Destination $targetRoot
        $scriptDir = $targetRoot
        Write-Host "[OK] Files installed." -ForegroundColor Green

        if (-not $SkipGuiBuild) { [void](Invoke-FedGuiBuild -Root $scriptDir) }
    }
} catch {
    Write-Error "Installation failed: $_"
    exit 1
} finally {
    if ($workDir -and (Test-Path $workDir)) {
        Remove-Item $workDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$cmdPath = Join-Path $scriptDir "fedupdate.cmd"
$ps1Path = Join-Path $scriptDir "fedupdate.ps1"
$vbsPath = Join-Path $scriptDir "fedupdate-gui.vbs"

# 2. Check Elevation Context
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if ($isAdmin) {
    Write-Host "[INFO] Running with Administrator privileges." -ForegroundColor Cyan
} else {
    Write-Host "[INFO] Running in Standard User mode (Admin only needed for on-boot tasks/rebooting)." -ForegroundColor Gray
}

# 3. Add to User PATH
$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
if ($userPath -notlike "*$scriptDir*") {
    $newPath = "$userPath;$scriptDir"
    [Environment]::SetEnvironmentVariable("Path", $newPath, "User")
    Write-Host "[OK] Added '$scriptDir' to User PATH." -ForegroundColor Green
} else {
    Write-Host "[OK] Already in User PATH." -ForegroundColor Gray
}
$env:Path = "$env:Path;$scriptDir"

# 4. Inject global PowerShell Profile alias
$profileHook = @"

# FedUpDate Alias Integration
function fedupdate { & "$ps1Path" @args }
"@

$profilePaths = @($PROFILE.CurrentUserAllHosts, $PROFILE.CurrentUserCurrentHost) | Select-Object -Unique
foreach ($p in $profilePaths) {
    if ($p) {
        try {
            $pDir = Split-Path -Parent $p
            if (-not (Test-Path $pDir)) { New-Item -ItemType Directory -Path $pDir -Force | Out-Null }
            # Clear any previous hook, including fragments left by older
            # builds, so repeated installs cannot stack duplicates.
            [void](Remove-FedProfileHook -ProfilePath $p)
            Add-Content -Path $p -Value $profileHook -Encoding UTF8
            Write-Host "[OK] Registered 'fedupdate' in PowerShell Profile ($p)." -ForegroundColor Green
        } catch { }
    }
}

# 5. Create Start Menu & Desktop Shortcuts
#    Shortcuts target the compiled GUI executable directly. It is a /target:winexe
#    build, so it opens the frameless WindowChrome window with no console and no
#    native title bar, and Windows draws the shortcut icon from the executable's
#    own embedded resource.
#
#    If the GUI was not compiled, fall back to the silent VBS launcher, which
#    serves the interface through Edge in app mode. That window carries Edge's
#    own title bar, so it is a fallback rather than the intended experience.
$wshShell = $null
try { $wshShell = New-Object -ComObject WScript.Shell } catch {
    Write-Host "[WARN] Windows Script Host unavailable; skipping shortcuts." -ForegroundColor Yellow
}

if ($wshShell) {
    $guiExe = Join-Path $scriptDir "gui\bin\FedUpDate.UI.exe"
    $appIcon = Join-Path $scriptDir "assets\fedupdate.ico"

    if (Test-Path $guiExe) {
        $linkTarget = $guiExe
        $linkArguments = ""
        $linkIcon = $guiExe
    } else {
        Write-Host "[WARN] GUI executable not found; shortcuts will use the fallback launcher." -ForegroundColor Yellow
        $linkTarget = "wscript.exe"
        $linkArguments = "`"$vbsPath`""
        $linkIcon = if (Test-Path $appIcon) { $appIcon } else { $null }
    }

    $shortcutTargets = @(
        @{ Name = "Start Menu"; Dir = (Get-FedShellFolder -Folder Programs -Fallback "$env:APPDATA\Microsoft\Windows\Start Menu\Programs") },
        @{ Name = "Desktop";    Dir = (Get-FedShellFolder -Folder DesktopDirectory -Fallback "$env:USERPROFILE\Desktop") }
    )

    foreach ($target in $shortcutTargets) {
        if (-not $target.Dir) {
            Write-Host "[WARN] Could not locate the $($target.Name) folder; shortcut skipped." -ForegroundColor Yellow
            continue
        }
        try {
            $lnkPath = Join-Path $target.Dir "FedUpDate.lnk"
            $lnk = $wshShell.CreateShortcut($lnkPath)
            $lnk.TargetPath = $linkTarget
            $lnk.Arguments = $linkArguments
            $lnk.WorkingDirectory = $scriptDir
            $lnk.Description = "FedUpDate - Unified Windows Update Suite"
            if ($linkIcon) { $lnk.IconLocation = "$linkIcon,0" }
            $lnk.Save()
            Write-Host "[OK] Created $($target.Name) shortcut." -ForegroundColor Green
        } catch {
            Write-Host "[WARN] Failed to create $($target.Name) shortcut: $_" -ForegroundColor Yellow
        }
    }
}

Write-Host "`nInstallation Complete! Available commands:" -ForegroundColor Green
Write-Host "  fedupdate              (Launches interactive TUI)" -ForegroundColor White
Write-Host "  fedupdate gui          (Launches modern Desktop GUI with 1 clean window)" -ForegroundColor White
Write-Host "  fedupdate scan         (Runs quick command-line audit)" -ForegroundColor White
Write-Host "  fedupdate update       (Runs unified updates)" -ForegroundColor White
Write-Host "  fedupdate uninstall    (Cleanly uninstalls with OS restore & backup options)" -ForegroundColor White
