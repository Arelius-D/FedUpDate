# ==============================================================================
# FedUpDate Configuration Manager
# Manages user settings, engine toggles, watchdog rules, and defaults
# ==============================================================================

. "$PSScriptRoot\Logger.ps1"

function Get-FedDataDirectory {
    $scriptDir = Split-Path -Parent $PSScriptRoot
    $dataDir = Join-Path $scriptDir "data"
    if (-not (Test-Path $dataDir)) {
        New-Item -ItemType Directory -Path $dataDir -Force | Out-Null
    }
    return $dataDir
}

function Get-FedDefaultConfig {
    return [PSCustomObject]@{
        lastUpdated = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ")
        engines     = [PSCustomObject]@{
            osUpdates           = $true
            defenderDefinitions = $true
            wingetApps          = $true
            storeApps           = $true
        }
        # "Smart" reports what is pending and leaves the decision to the user.
        # "Never", "Notify", "Prompt", "Schedule", "Force" and "Shutdown" are
        # also accepted. The three that power the machine off will not act on
        # routine installer cleanup unless allowRebootOnAdvisory is set.
        rebootPolicy = "Smart"
        rebootScheduleTime = "03:00"
        allowRebootOnAdvisory = $false
        # Which releases this installation is offered, and which branch an update
        # is installed from. "stable" takes published releases and installs from
        # main. "beta" takes prereleases as well and installs from dev, so that
        # what is offered and what arrives are the same thing.
        updateChannel = "stable"
        watchdog    = [PSCustomObject]@{
            enabled                    = $true
            enforceOnBoot              = $true
            disableAutoUpdateService   = $true
            disableUpdateOrchestrator  = $true
            disableDeliveryOptimization = $false
        }
        scheduler   = [PSCustomObject]@{
            enabled        = $false
            frequency      = "Daily" # "Daily", "Weekly", "OnIdle"
            time           = "02:00"
            dayOfWeek      = "Sunday"
            onlyOnACPower  = $true
        }
        exclusions  = [PSCustomObject]@{
            wingetPackageIds = @("Microsoft.Edge", "Microsoft.OneDrive")
            skipPinnedApps   = $true
        }
        ui          = [PSCustomObject]@{
            theme        = "System" # "System", "Dark", "Light"
            micaBackdrop = $true
            compactMode  = $false
        }
    }
}

function Get-FedConfig {
    [CmdletBinding()]
    param()

    $dataDir = Get-FedDataDirectory
    $configFile = Join-Path $dataDir "config.json"

    if (-not (Test-Path $configFile)) {
        $defaultConfig = Get-FedDefaultConfig
        $json = $defaultConfig | ConvertTo-Json -Depth 10
        Set-Content -Path $configFile -Value $json -Encoding UTF8
        Write-FedLog "Initialized default configuration at $configFile" -Level "INFO" -Component "Config"
        return $defaultConfig
    }

    try {
        $raw = Get-Content -Path $configFile -Raw -Encoding UTF8
        $config = $raw | ConvertFrom-Json
        return $config
    } catch {
        Write-FedLog "Failed to parse config.json, falling back to defaults: $_" -Level "ERROR" -Component "Config"
        return Get-FedDefaultConfig
    }
}

function Update-FedConfig {
    <#
        .SYNOPSIS
            Applies a partial change to the stored configuration.

        .DESCRIPTION
            Writing a caller's object straight to disk replaces the whole file,
            so a caller that knows about two settings silently deletes every
            other one. This merges instead: keys present in the patch are
            written, nested objects are merged a level at a time, and anything
            the caller did not mention is left exactly as it was.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Patch
    )

    $config = Get-FedConfig

    foreach ($property in $Patch.PSObject.Properties) {
        $name = $property.Name
        $value = $property.Value

        $existing = $config.PSObject.Properties[$name]
        if ($null -ne $existing -and
            $existing.Value -is [PSCustomObject] -and
            $value -is [PSCustomObject]) {

            foreach ($child in $value.PSObject.Properties) {
                $existing.Value | Add-Member -NotePropertyName $child.Name -NotePropertyValue $child.Value -Force
            }
            continue
        }

        $config | Add-Member -NotePropertyName $name -NotePropertyValue $value -Force
    }

    return Set-FedConfig -Config $config
}

function Set-FedConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Config
    )

    $dataDir = Get-FedDataDirectory
    $configFile = Join-Path $dataDir "config.json"

    try {
        $Config.lastUpdated = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ")
        $json = $Config | ConvertTo-Json -Depth 10
        Set-Content -Path $configFile -Value $json -Encoding UTF8
        Write-FedLog "Configuration updated successfully." -Level "SUCCESS" -Component "Config"
        return $true
    } catch {
        Write-FedLog "Failed to write configuration: $_" -Level "ERROR" -Component "Config"
        return $false
    }
}

function Reset-FedConfig {
    [CmdletBinding()]
    param()

    $defaultConfig = Get-FedDefaultConfig
    return Set-FedConfig -Config $defaultConfig
}

Export-ModuleMember -Function Get-FedDataDirectory, Get-FedDefaultConfig, Get-FedConfig, Set-FedConfig, Update-FedConfig, Reset-FedConfig -ErrorAction SilentlyContinue
