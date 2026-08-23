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

Export-ModuleMember -Function Get-FedDataDirectory, Get-FedDefaultConfig, Get-FedConfig, Set-FedConfig, Reset-FedConfig -ErrorAction SilentlyContinue
