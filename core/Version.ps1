# ==============================================================================
# FedUpDate Version & Self-Update Engine
# Resolves the installed version, queries the published release, and compares them
# ==============================================================================

. "$PSScriptRoot\Logger.ps1"
# The channel an installation follows is configuration, so this reads it.
. "$PSScriptRoot\Config.ps1"

$script:FedRepoSlug = "Arelius-D/FedUpDate"
$script:FedLatestReleaseUrl = "https://api.github.com/repos/$script:FedRepoSlug/releases/latest"

function Get-FedVersion {
    <#
    .SYNOPSIS
        Returns the installed version.
    .DESCRIPTION
        The version is read from the topmost entry in CHANGELOG.md, which is the
        single place a release is recorded. Keeping one source means the version
        cannot drift from the changelog, because it is the changelog.
    #>
    [CmdletBinding()]
    param()

    $root = Split-Path -Parent $PSScriptRoot

    # An installation is stamped with its version when it is installed. The
    # changelog is where a release is written down, and it belongs to the people
    # writing this application rather than to the people running it, so it is
    # not shipped. Reading the version out of it meant an installation without
    # it had no version at all, and an interface that cannot say which version
    # it is does not finish starting.
    $stamp = Join-Path $root "version.txt"
    if (Test-Path $stamp) {
        $stamped = (Get-Content -Path $stamp -Raw -ErrorAction SilentlyContinue)
        if (-not [string]::IsNullOrWhiteSpace($stamped)) { return $stamped.Trim() }
    }

    # Run from a copy of the source rather than from an installation, the
    # changelog is right there and is the authority.
    $changelog = Join-Path $root "CHANGELOG.md"
    if (Test-Path $changelog) {
        foreach ($line in (Get-Content -Path $changelog)) {
            # Matches: ## [0.4.0-beta] - 2026-08-22
            if ($line -match '^##\s*\[([^\]]+)\]') {
                return $Matches[1].Trim()
            }
        }
    }

    Write-FedLog "No version stamp and no changelog; version is unknown." -Level "WARN" -Component "Version"
    return $null
}

function Set-FedVersionStamp {
    <#
    .SYNOPSIS
        Writes the version an installation is.
    .DESCRIPTION
        Called by the installer, which knows what it is installing because it
        has the source in front of it. After that the installation carries its
        own version and needs nothing else on disk to answer for it.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root,

        [Parameter(Mandatory = $true)]
        [string]$Version
    )

    if ([string]::IsNullOrWhiteSpace($Version)) { return $false }
    try {
        Set-Content -Path (Join-Path $Root "version.txt") -Value $Version.Trim() -Encoding UTF8 -ErrorAction Stop
        return $true
    } catch {
        return $false
    }
}

function ConvertTo-FedVersionParts {
    <#
    .SYNOPSIS
        Splits a version string into a comparable structure.
    .DESCRIPTION
        Handles an optional leading 'v' and an optional prerelease suffix, so
        '0.4.0-beta' and 'v0.4.0' both parse. Under semantic versioning a
        prerelease sorts before the release of the same number.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowNull()][string]$Version)

    if ([string]::IsNullOrWhiteSpace($Version)) { return $null }

    $clean = $Version.Trim().TrimStart('v', 'V')
    if ($clean -notmatch '^(\d+)\.(\d+)\.(\d+)(?:-(.+))?$') { return $null }

    return [PSCustomObject]@{
        Major      = [int]$Matches[1]
        Minor      = [int]$Matches[2]
        Patch      = [int]$Matches[3]
        PreRelease = if ($Matches[4]) { $Matches[4] } else { $null }
    }
}

function Compare-FedVersion {
    <#
    .SYNOPSIS
        Returns -1, 0 or 1 for Left older than, equal to, or newer than Right.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowNull()][string]$Left,
        [Parameter(Mandatory = $true)][AllowNull()][string]$Right
    )

    $a = ConvertTo-FedVersionParts -Version $Left
    $b = ConvertTo-FedVersionParts -Version $Right
    if ($null -eq $a -or $null -eq $b) { return 0 }

    foreach ($field in @("Major", "Minor", "Patch")) {
        if ($a.$field -lt $b.$field) { return -1 }
        if ($a.$field -gt $b.$field) { return 1 }
    }

    # Equal numbers: a prerelease is older than the finished release.
    if ($a.PreRelease -and -not $b.PreRelease) { return -1 }
    if (-not $a.PreRelease -and $b.PreRelease) { return 1 }
    if ($a.PreRelease -and $b.PreRelease) {
        return [string]::Compare($a.PreRelease, $b.PreRelease, $true)
    }
    return 0
}

function Get-FedUpdateChannel {
    <#
    .SYNOPSIS
        The channel this installation follows: "stable" or "beta".
    .DESCRIPTION
        Anything unrecognised, missing, or written by an older configuration
        resolves to stable, because offering someone a prerelease they did not
        ask for is the worse of the two mistakes.
    #>
    [CmdletBinding()]
    param([PSCustomObject]$Config)

    try {
        $cfg = if ($Config) { $Config } else { Get-FedConfig }
        if ($null -ne $cfg -and $null -ne $cfg.PSObject.Properties['updateChannel']) {
            if ([string]$cfg.updateChannel -eq "beta") { return "beta" }
        }
    } catch { }

    return "stable"
}

function Get-FedChannelBranch {
    <#
    .SYNOPSIS
        The branch a channel installs from.
    .DESCRIPTION
        An update is installed from a branch, not from the tag it was detected
        by. If the two disagree the application reports an update, installs
        something that is not it, and reports the same update again, which is a
        loop no amount of updating clears.
    #>
    [CmdletBinding()]
    param([string]$Channel)

    if ($Channel -eq "beta") { return "dev" }
    return "main"
}

function Get-FedInstallScriptUrl {
    [CmdletBinding()]
    param([string]$Branch = "main")

    return "https://raw.githubusercontent.com/$script:FedRepoSlug/$Branch/install.ps1"
}

function Get-FedLatestRelease {
    <#
    .SYNOPSIS
        Queries the published release for a channel.
    .DESCRIPTION
        Stable reads the latest-release endpoint, which excludes prereleases by
        definition. Beta reads the list and takes the most recent entry of any
        kind.

        The latest-release endpoint answers 404 when a repository has published
        nothing but prereleases. That is an answer, not a failure: it means no
        stable release exists yet, and it is reported as such rather than as a
        network problem the caller should retry.
    #>
    [CmdletBinding()]
    param(
        [ValidateSet("stable", "beta")]
        [string]$Channel = "stable",

        # Retained for callers that ask for prereleases directly.
        [switch]$IncludePreRelease
    )

    if ($IncludePreRelease) { $Channel = "beta" }

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $headers = @{ "User-Agent" = "FedUpDate" }

    try {
        if ($Channel -eq "beta") {
            $all = Invoke-RestMethod -Uri "https://api.github.com/repos/$script:FedRepoSlug/releases?per_page=10" -Headers $headers -UseBasicParsing
            $release = @($all)[0]
        } else {
            $release = Invoke-RestMethod -Uri $script:FedLatestReleaseUrl -Headers $headers -UseBasicParsing
        }

        if (-not $release) { return $null }

        return [PSCustomObject]@{
            Version     = $release.tag_name
            Name        = $release.name
            Url         = $release.html_url
            PublishedAt = $release.published_at
            PreRelease  = [bool]$release.prerelease
        }
    } catch {
        $statusCode = 0
        try { $statusCode = [int]$_.Exception.Response.StatusCode } catch { }

        if ($Channel -eq "stable" -and $statusCode -eq 404) {
            Write-FedLog "No stable release has been published yet." -Level "INFO" -Component "Version"
            return $null
        }

        Write-FedLog "Could not query the latest release: $_" -Level "WARN" -Component "Version"
        return $null
    }
}

function Get-FedVersionStatus {
    <#
    .SYNOPSIS
        Reports the installed version alongside the published one.
    .DESCRIPTION
        Never throws on a network failure: an offline machine reports the
        installed version with UpdateAvailable false, so callers can render a
        version without depending on connectivity.
    #>
    [CmdletBinding()]
    param([switch]$SkipRemote)

    $current = Get-FedVersion
    $channel = Get-FedUpdateChannel
    $status = [PSCustomObject]@{
        Current         = $current
        Latest          = $null
        UpdateAvailable = $false
        ReleaseUrl      = $null
        Channel         = $channel
        Branch          = (Get-FedChannelBranch -Channel $channel)
        Checked         = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ")
        RemoteReachable = $false
    }

    if ($SkipRemote) { return $status }

    $release = Get-FedLatestRelease -Channel $channel
    if (-not $release) { return $status }

    $status.RemoteReachable = $true
    $status.Latest = $release.Version
    $status.ReleaseUrl = $release.Url
    $status.UpdateAvailable = ((Compare-FedVersion -Left $current -Right $release.Version) -lt 0)

    return $status
}

function Get-FedReleaseNotes {
    <#
    .SYNOPSIS
        Returns the release notes for every version newer than the installed one.
    .DESCRIPTION
        Lets the user read what an update actually contains without leaving the
        application. Notes come from the releases API, newest first.

        The trailing install instructions are stripped: inside the application
        the user already has an update control, so repeating the bootstrap
        command is noise. The published release keeps it.
    #>
    [CmdletBinding()]
    param(
        [int]$Limit = 10,

        # Overrides the installed version. Used for testing and by callers that
        # already resolved it.
        [string]$CurrentVersion
    )

    $current = if ($CurrentVersion) { $CurrentVersion } else { Get-FedVersion }
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $headers = @{ "User-Agent" = "FedUpDate" }

    try {
        $releases = Invoke-RestMethod -Uri "https://api.github.com/repos/$script:FedRepoSlug/releases?per_page=$Limit" -Headers $headers -UseBasicParsing
    } catch {
        Write-FedLog "Could not retrieve release notes: $_" -Level "WARN" -Component "Version"
        return @()
    }

    # A stable installation is never offered a prerelease, so it must not be
    # shown the notes for one either. Otherwise the panel lists versions that
    # will never arrive.
    $channel = Get-FedUpdateChannel

    $notes = foreach ($release in @($releases)) {
        if ($channel -ne "beta" -and [bool]$release.prerelease) { continue }
        if ((Compare-FedVersion -Left $current -Right $release.tag_name) -ge 0) { continue }

        $body = if ($release.body) { $release.body } else { "" }

        # Drop the bootstrap instructions and anything after them.
        $kept = New-Object System.Collections.Generic.List[string]
        foreach ($line in ($body -split "`r?`n")) {
            if ($line.Trim() -eq "Install:") { break }
            $kept.Add($line)
        }

        [PSCustomObject]@{
            Version     = $release.tag_name
            PublishedAt = if ($release.published_at) { ([datetime]$release.published_at).ToString('yyyy-MM-dd') } else { "" }
            Body        = (($kept -join [Environment]::NewLine).Trim())
            Url         = $release.html_url
        }
    }

    return @($notes)
}

function Invoke-FedSelfUpdate {
    <#
    .SYNOPSIS
        Updates FedUpDate in place by re-running the published installer.
    .DESCRIPTION
        The installer already detects an existing installation, upgrades it, and
        leaves the data directory untouched, so configuration, logs, the state
        ledger and rollback snapshots survive. Reusing it keeps one upgrade path
        rather than a second one that could drift.

        The installer runs in a process of its own. Run inside this one, it
        re-imports the engine it is running inside of, which tears down the
        scope its own functions live in, and the next call to one of them
        failed. A separate process also survives the window being closed to
        rebuild it, which this process does not when it is that window's
        server. Detached, the update is started and reported as started;
        otherwise it is waited on and its exit code decides the outcome.
    #>
    [CmdletBinding()]
    param([switch]$Force, [switch]$WhatIf, [switch]$Detach)

    $status = Get-FedVersionStatus

    # The branch the update is taken from has to be the one the offered release
    # was cut from. Detecting an update by tag and then installing a different
    # branch reports the update again the moment it finishes.
    $branch = if ($status.Branch) { $status.Branch } else { Get-FedChannelBranch -Channel (Get-FedUpdateChannel) }
    $installerUrl = Get-FedInstallScriptUrl -Branch $branch

    if (-not $status.RemoteReachable) {
        Write-FedLog "Update check failed; not attempting a self-update." -Level "ERROR" -Component "Version"
        return [PSCustomObject]@{ Success = $false; Started = $false; Completed = $false }
    }

    if (-not $status.UpdateAvailable -and -not $Force) {
        Write-FedLog "Already on the latest version ($($status.Current)) on the $($status.Channel) channel." -Level "SUCCESS" -Component "Version"
        return [PSCustomObject]@{ Success = $true; Started = $false; Completed = $false }
    }

    if ($WhatIf) {
        Write-FedLog "[WHATIF] Would update from $($status.Current) to $($status.Latest) via $installerUrl" -Level "WHATIF" -Component "Version"
        return [PSCustomObject]@{ Success = $true; Started = $false; Completed = $false }
    }

    Write-FedLog "Updating from $($status.Current) to $($status.Latest) from the $branch branch..." -Level "INFO" -Component "Version"

    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $installer = Invoke-RestMethod -Uri $installerUrl -UseBasicParsing

        # Written to a file and run from there, in a process of its own.
        $scriptDir = Join-Path ([IO.Path]::GetTempPath()) "FedUpDate"
        if (-not (Test-Path $scriptDir)) { New-Item -ItemType Directory -Path $scriptDir -Force | Out-Null }
        Get-ChildItem -Path $scriptDir -Filter "self-update-*.ps1" -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-1) } |
            Remove-Item -Force -ErrorAction SilentlyContinue
        $script = Join-Path $scriptDir ("self-update-" + [guid]::NewGuid().ToString("N") + ".ps1")
        Set-Content -Path $script -Value $installer -Encoding UTF8

        if ($Detach) {
            # The window is closed part way through to be rebuilt, and the
            # server that started this stops with it. What the installer prints
            # is kept in the log directory, where it can be read afterwards.
            $transcript = Join-Path (Get-FedLogDirectory) "self-update.log"
            $wrapped = "& { Start-Transcript -Path '$transcript' -Force | Out-Null; & '$script' -Branch '$branch'; exit `$LASTEXITCODE }"
            $arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command `"$wrapped`""
            $p = Start-Process -FilePath "powershell.exe" -ArgumentList $arguments -WindowStyle Hidden -PassThru -ErrorAction Stop
            Write-FedLog "Self-update started in its own process (PID $($p.Id)). The window closes while the new version is built and opens again by itself. The installer's output is kept in $transcript." -Level "INFO" -Component "Version"
            return [PSCustomObject]@{ Success = $true; Started = $true; Completed = $false; ProcessId = $p.Id }
        }

        $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$script`" -Branch `"$branch`""
        $p = Start-Process -FilePath "powershell.exe" -ArgumentList $arguments -NoNewWindow -Wait -PassThru -ErrorAction Stop
        Remove-Item -Path $script -Force -ErrorAction SilentlyContinue
        if ($p.ExitCode -eq 0) {
            Write-FedLog "Self-update completed." -Level "SUCCESS" -Component "Version"
            return [PSCustomObject]@{ Success = $true; Started = $true; Completed = $true; ExitCode = 0 }
        }
        Write-FedLog "Self-update failed: the installer exited with code $($p.ExitCode)." -Level "ERROR" -Component "Version"
        return [PSCustomObject]@{ Success = $false; Started = $true; Completed = $true; ExitCode = $p.ExitCode }
    } catch {
        Write-FedLog "Self-update failed: $_" -Level "ERROR" -Component "Version"
        return [PSCustomObject]@{ Success = $false; Started = $false; Completed = $false }
    }
}

function Get-FedBranchPosition {
    <#
    .SYNOPSIS
        How many commits the channel branch has gained since a release.
    .DESCRIPTION
        Answers "what has happened since the version I am running", which a tag
        alone cannot say. GitHub's compare endpoint reports the distance between
        the installed version's tag and the head of the branch that channel
        installs from.

        This is a third call against an API that allows sixty an hour for the
        whole machine unauthenticated, so callers are expected to hold the
        result rather than ask again each time a panel opens.
    #>
    [CmdletBinding()]
    param(
        [string]$FromTag,
        [string]$Branch
    )

    $from = if ($FromTag) { $FromTag } else { Get-FedVersion }
    if ([string]::IsNullOrWhiteSpace($from)) { return $null }

    $target = if ($Branch) { $Branch } else { Get-FedChannelBranch -Channel (Get-FedUpdateChannel) }

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $headers = @{ "User-Agent" = "FedUpDate" }

    # Releases have been tagged both with and without a leading v, so a miss on
    # one spelling is retried with the other before giving up.
    foreach ($tag in @($from, "v$($from.TrimStart('v','V'))" ) | Select-Object -Unique) {
        try {
            $uri = "https://api.github.com/repos/$script:FedRepoSlug/compare/$tag...$target"
            $cmp = Invoke-RestMethod -Uri $uri -Headers $headers -UseBasicParsing

            return [PSCustomObject]@{
                FromTag      = $tag
                Branch       = $target
                Status       = [string]$cmp.status
                CommitsSince = [int]$cmp.ahead_by
                TotalCommits = [int]$cmp.total_commits
                CompareUrl   = [string]$cmp.html_url
            }
        } catch { }
    }

    Write-FedLog "Could not compare $from against $target." -Level "DEBUG" -Component "Version"
    return $null
}
