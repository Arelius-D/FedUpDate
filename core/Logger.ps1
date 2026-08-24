# ==============================================================================
# FedUpDate Logger Module
# Structured, Colorized Logging with File Persistence and In-Memory Buffer
# ==============================================================================

if (-not (Get-Variable -Name "FedLoggerBuffer" -Scope Global -ErrorAction SilentlyContinue)) {
    $global:FedLoggerBuffer = [System.Collections.Generic.List[PSObject]]::new()
}

function Get-FedLogDirectory {
    $scriptDir = Split-Path -Parent $PSScriptRoot
    $logDir = Join-Path $scriptDir "data\logs"
    if (-not (Test-Path $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }
    return $logDir
}

function Write-FedLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$Message,

        [Parameter(Position = 1)]
        [ValidateSet("DEBUG", "INFO", "WARN", "ERROR", "SUCCESS", "WHATIF")]
        [string]$Level = "INFO",

        [Parameter()]
        [string]$Component = "Core",

        [Parameter()]
        [switch]$NoConsole
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
    $logObj = [PSCustomObject]@{
        Timestamp = $timestamp
        Level     = $Level
        Component = $Component
        Message   = $Message
    }

    # Add to global buffer (keep last 500 lines)
    if ($global:FedLoggerBuffer.Count -ge 500) {
        $global:FedLoggerBuffer.RemoveAt(0)
    }
    $global:FedLoggerBuffer.Add($logObj)

    # Console output with ANSI colors
    if (-not $NoConsole) {
        $prefix = switch ($Level) {
            "DEBUG"   { "`e[90m[DEBUG]`e[0m" }
            "INFO"    { "`e[36m[INFO ]`e[0m" }
            "WARN"    { "`e[33m[WARN ]`e[0m" }
            "ERROR"   { "`e[91m[ERROR]`e[0m" }
            "SUCCESS" { "`e[92m[OK   ]`e[0m" }
            "WHATIF"  { "`e[35m[WHAT ]`e[0m" }
            Default   { "[$Level]" }
        }
        $compStr = "`e[94m[$Component]`e[0m"
        Write-Host "$prefix $compStr $Message"
    }

    # Append to file
    try {
        $logDir = Get-FedLogDirectory
        $logFile = Join-Path $logDir "fedupdate.log"
        $fileLine = "[$timestamp] [$Level] [$Component] $Message"
        Add-Content -Path $logFile -Value $fileLine -Encoding UTF8 -ErrorAction SilentlyContinue
    } catch {
        # Silent catch to prevent logging failure from breaking app
    }
}

function Get-FedLogs {
    [CmdletBinding()]
    param(
        [int]$Count = 150,
        [string]$LevelFilter
    )
    $logs = [System.Collections.Generic.List[PSObject]]::new()
    
    $logDir = Get-FedLogDirectory
    $logFile = Join-Path $logDir "fedupdate.log"
    if (Test-Path $logFile) {
        try {
            $lines = Get-Content -Path $logFile -Tail $Count -Encoding UTF8 -ErrorAction SilentlyContinue
            if ($lines) {
                foreach ($line in $lines) {
                    if ($line -match '^\[(.*?)\]\s+\[(.*?)\]\s+\[(.*?)\]\s+(.*)$') {
                        $logs.Add([PSCustomObject]@{
                            Timestamp = $matches[1]
                            Level     = $matches[2]
                            Component = $matches[3]
                            Message   = $matches[4]
                        })
                    }
                }
            }
        } catch { }
    }

    if ($logs.Count -eq 0 -and $global:FedLoggerBuffer -and $global:FedLoggerBuffer.Count -gt 0) {
        foreach ($l in $global:FedLoggerBuffer) {
            $logs.Add($l)
        }
    }

    $resultList = @($logs)
    if ($LevelFilter -and $LevelFilter -ne "ALL") {
        $resultList = @($resultList | Where-Object { $_.Level -eq $LevelFilter })
    }
    if ($resultList.Count -gt $Count) {
        $resultList = $resultList[($resultList.Count - $Count)..($resultList.Count - 1)]
    }
    return $resultList
}

function Clear-FedLogs {
    [CmdletBinding()]
    param()

    if ($global:FedLoggerBuffer) {
        $global:FedLoggerBuffer.Clear()
    }
    $logDir = Get-FedLogDirectory
    $logFile = Join-Path $logDir "fedupdate.log"
    if (Test-Path $logFile) {
        Remove-Item -Path $logFile -Force -ErrorAction SilentlyContinue
    }
}

Export-ModuleMember -Function Write-FedLog, Get-FedLogs, Clear-FedLogs, Get-FedLogDirectory -ErrorAction SilentlyContinue
