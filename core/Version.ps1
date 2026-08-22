# ==============================================================================
# FedUpDate Version & Self-Update Engine
# Resolves the installed version, queries the published release, and compares them
# ==============================================================================

. "$PSScriptRoot\Logger.ps1"

$script:FedRepoSlug = "Arelius-D/FedUpDate"
$script:FedLatestReleaseUrl = "https://api.github.com/repos/$script:FedRepoSlug/releases/latest"
$script:FedInstallScriptUrl = "https://raw.githubusercontent.com/$script:FedRepoSlug/main/install.ps1"

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

    $changelog = Join-Path (Split-Path -Parent $PSScriptRoot) "CHANGELOG.md"
    if (-not (Test-Path $changelog)) {
        Write-FedLog "CHANGELOG.md not found; version is unknown." -Level "WARN" -Component "Version"
        return $null
    }

    foreach ($line in (Get-Content -Path $changelog)) {
        # Matches: ## [0.4.0-beta] - 2026-08-22
        if ($line -match '^##\s*\[([^\]]+)\]') {
            return $Matches[1].Trim()
        }
    }

    Write-FedLog "No version heading found in CHANGELOG.md." -Level "WARN" -Component "Version"
    return $null
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

function Get-FedLatestRelease {
    <#
    .SYNOPSIS
        Queries the published release from the GitHub API.
    .DESCRIPTION
        Prereleases are not returned by the latest-release endpoint, so while the
        project is in beta this falls back to the most recent tag published.
    #>
    [CmdletBinding()]
    param([switch]$IncludePreRelease)

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $headers = @{ "User-Agent" = "FedUpDate" }

    try {
        if ($IncludePreRelease) {
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
    $status = [PSCustomObject]@{
        Current         = $current
        Latest          = $null
        UpdateAvailable = $false
        ReleaseUrl      = $null
        Checked         = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ")
        RemoteReachable = $false
    }

    if ($SkipRemote) { return $status }

    # While the project ships prereleases, include them in the comparison.
    $release = Get-FedLatestRelease -IncludePreRelease
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

    $notes = foreach ($release in @($releases)) {
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
    #>
    [CmdletBinding()]
    param([switch]$Force, [switch]$WhatIf)

    $status = Get-FedVersionStatus

    if (-not $status.RemoteReachable) {
        Write-FedLog "Update check failed; not attempting a self-update." -Level "ERROR" -Component "Version"
        return $false
    }

    if (-not $status.UpdateAvailable -and -not $Force) {
        Write-FedLog "Already on the latest version ($($status.Current))." -Level "SUCCESS" -Component "Version"
        return $true
    }

    if ($WhatIf) {
        Write-FedLog "[WHATIF] Would update from $($status.Current) to $($status.Latest) via $script:FedInstallScriptUrl" -Level "WHATIF" -Component "Version"
        return $true
    }

    Write-FedLog "Updating from $($status.Current) to $($status.Latest)..." -Level "INFO" -Component "Version"

    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $installer = Invoke-RestMethod -Uri $script:FedInstallScriptUrl -UseBasicParsing
        & ([scriptblock]::Create($installer))
        Write-FedLog "Self-update completed. Restart FedUpDate to run the new version." -Level "SUCCESS" -Component "Version"
        return $true
    } catch {
        Write-FedLog "Self-update failed: $_" -Level "ERROR" -Component "Version"
        return $false
    }
}
