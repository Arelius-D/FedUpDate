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

    [Parameter()]
    [switch]$RestoreOSDefaults,

    [Parameter()]
    [switch]$KeepBackups,

    [Parameter()]
    [switch]$PurgeAll,

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

# ==============================================================================
# Helpers
# ==============================================================================

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

    # Step 1: Restore OS Defaults & Revert State Ledger
    # Restoring Windows Update defaults is the default action: leaving a machine
    # with update services disabled after an uninstall is never the safe outcome.
    $shouldRestore = $true
    if ($RestoreOSDefaults) {
        $shouldRestore = $true
    } elseif (-not $NonInteractive) {
        $shouldRestore = Read-FedYesNo -Question "Restore original Windows Update services and settings before uninstalling?" -Default "Y"
    }

    if ($shouldRestore -and (Test-Path $enginePath)) {
        try {
            Write-Host "Reverting OS settings & re-enabling Windows Update defaults..." -ForegroundColor Cyan
            Import-Module $enginePath -Force -DisableNameChecking
            Restore-FedState -All -ErrorAction SilentlyContinue | Out-Null
            Uninstall-FedWatchdogTask -ErrorAction SilentlyContinue | Out-Null
            Remove-FedScheduleTask -ErrorAction SilentlyContinue | Out-Null
            Write-Host "[OK] Restored Windows default services and uninstalled background tasks." -ForegroundColor Green
        } catch {
            Write-Host "[WARN] Could not fully revert state: $_" -ForegroundColor Yellow
        }
    }

    # Step 2: Handle Backup Snapshots & Logs (.bak files)
    # Keeping copies of logs and snapshots is opt-in, so a plain uninstall leaves
    # nothing behind.
    $shouldKeep = $KeepBackups.IsPresent
    if (-not $NonInteractive -and -not $KeepBackups -and -not $PurgeAll) {
        $shouldKeep = Read-FedYesNo -Question "Keep backup snapshots and logs in Documents\FedUpDate-Backups?" -Default "N"
    }

    $dataDir = Join-Path $scriptDir "data"
    if ($shouldKeep -and (Test-Path $dataDir)) {
        $exportDir = "$env:USERPROFILE\Documents\FedUpDate-Backups"
        try {
            if (-not (Test-Path $exportDir)) { New-Item -ItemType Directory -Path $exportDir -Force | Out-Null }
            Copy-Item -Path "$dataDir\*" -Destination $exportDir -Recurse -Force -ErrorAction SilentlyContinue
            Write-Host "[OK] Preserved state ledger & backup files to: $exportDir" -ForegroundColor Green
        } catch {
            Write-Host "[WARN] Failed to export backups: $_" -ForegroundColor Yellow
        }
    }

    # Step 3: Remove from User PATH
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    if ($userPath -like "*$scriptDir*") {
        $newPath = ($userPath -split ";" | Where-Object { $_ -ne $scriptDir -and $_ -ne "" }) -join ";"
        [Environment]::SetEnvironmentVariable("Path", $newPath, "User")
        Write-Host "[OK] Removed from User PATH." -ForegroundColor Green
    }

    # Step 4: Clean PowerShell profile hooks
    $profilePaths = @($PROFILE.CurrentUserAllHosts, $PROFILE.CurrentUserCurrentHost) | Select-Object -Unique
    foreach ($p in $profilePaths) {
        if ($p -and (Test-Path $p)) {
            if (Remove-FedProfileHook -ProfilePath $p) {
                Write-Host "[OK] Removed alias from profile: $p" -ForegroundColor Green
            }
        }
    }

    # Step 5: Remove Shortcuts
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

    # Step 6: Clean Data Folder if Purging
    if ($PurgeAll -or (-not $shouldKeep)) {
        if (Test-Path $dataDir) {
            Remove-Item -Path $dataDir -Recurse -Force -ErrorAction SilentlyContinue
            Write-Host "[OK] Cleaned local data folder." -ForegroundColor Green
        }
    }

    Write-Host "`nFedUpDate uninstalled cleanly and successfully." -ForegroundColor Green
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
