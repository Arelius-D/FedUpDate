<#
.SYNOPSIS
    FedUpDate GUI Backend Server
.DESCRIPTION
    Lightweight native HttpListener serving the desktop user interface and REST API with Win32 frameless window integration.
#>

[CmdletBinding()]
param(
    [Parameter()]
    [switch]$Headless
)

$port = 58100
[System.Net.HttpListener]$listener = $null

for ($p = 58100; $p -le 58150; $p++) {
    try {
        $candidate = New-Object System.Net.HttpListener
        $candidate.Prefixes.Add("http://localhost:$p/")
        $candidate.Start()
        $port = $p
        $listener = $candidate
        break
    } catch {
        if ($null -ne $candidate) {
            try { $candidate.Close() } catch {}
        }
    }
}

if ($null -eq $listener) {
    Write-Error "Failed to bind to any port between 58100 and 58150."
    exit 1
}

$scriptRoot = Split-Path -Parent $PSScriptRoot
$enginePath = Join-Path $scriptRoot "core\Engine.psm1"
Import-Module $enginePath -Force -DisableNameChecking

# Safe Win32 Frameless Window Manager (only needed for standalone Edge window mode, not WPF)
if (-not $Headless -and -not ([System.Management.Automation.PSTypeName]'FedNativeWindow').Type) {
    Add-Type -TypeDefinition @"
    using System;
    using System.Runtime.InteropServices;

    public static class FedNativeWindow {
        [DllImport("user32.dll", SetLastError = true)]
        public static extern int GetWindowLong(IntPtr hWnd, int nIndex);

        [DllImport("user32.dll", SetLastError = true)]
        public static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);

        [DllImport("user32.dll", SetLastError = true)]
        public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

        [DllImport("user32.dll", SetLastError = true)]
        public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);

        public const int GWL_STYLE = -16;
        public const int WS_CAPTION = 0x00C00000;
        public const int SW_MINIMIZE = 6;
        public const int SW_MAXIMIZE = 3;
        public const int SW_RESTORE = 9;
        public const uint SWP_FRAMECHANGED = 0x0020;
        public const uint SWP_NOMOVE = 0x0002;
        public const uint SWP_NOSIZE = 0x0001;
        public const uint SWP_NOZORDER = 0x0004;

        public static void RemoveTitleBar(IntPtr hWnd) {
            if (hWnd == IntPtr.Zero) return;
            try {
                int style = GetWindowLong(hWnd, GWL_STYLE);
                style &= ~WS_CAPTION;
                SetWindowLong(hWnd, GWL_STYLE, style);
                SetWindowPos(hWnd, IntPtr.Zero, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_FRAMECHANGED);
            } catch {}
        }
    }
"@
}

if ($null -eq $listener) {
    Write-Error "Failed to bind to any port between 58100 and 58150."
    exit 1
}

$prefix = "http://localhost:$port/"
Write-FedLog "GUI Server listening on $prefix" -Level "SUCCESS" -Component "GUI"

function Set-EdgeProfileTheme {
    param(
        [string]$Theme = "System"
    )
    
    $profileDir = Join-Path $scriptRoot "data\gui_profile\Default"
    if (-not (Test-Path $profileDir)) {
        New-Item -ItemType Directory -Path $profileDir -Force | Out-Null
    }
    
    $scheme = 2
    if ($Theme.ToLower() -eq "light") {
        $scheme = 1
    } elseif ($Theme.ToLower() -eq "dark") {
        $scheme = 2
    } else {
        try {
            $regVal = Get-ItemPropertyValue -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize" -Name "AppsUseLightTheme" -ErrorAction SilentlyContinue
            if ($regVal -eq 1) {
                $scheme = 1
            } else {
                $scheme = 2
            }
        } catch {
            $scheme = 2
        }
    }
    
    $prefPath = Join-Path $profileDir "Preferences"
    $pref = @{
        browser = @{
            theme = @{
                color_scheme = $scheme
            }
        }
    }
    $pref | ConvertTo-Json -Depth 5 | Set-Content -Path $prefPath -Encoding UTF8
}

# Configure Profile Theme
$cfg = Get-FedConfig
$themePref = "System"
if ($cfg.general -and $cfg.general.theme) {
    $themePref = $cfg.general.theme
} elseif ($cfg.ui -and $cfg.ui.theme) {
    $themePref = $cfg.ui.theme
}
Set-EdgeProfileTheme -Theme $themePref

# Launch Edge App Window with Dedicated Profile
$global:EdgeProcess = $null
$edgePath = $null

$progFilesX86 = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::ProgramFilesX86)
$progFiles = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::ProgramFiles)
$localApp = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::LocalApplicationData)

$possiblePaths = @(
    (Join-Path $progFilesX86 "Microsoft\Edge\Application\msedge.exe"),
    (Join-Path $progFiles "Microsoft\Edge\Application\msedge.exe"),
    (Join-Path $localApp "Microsoft\Edge\Application\msedge.exe")
)

foreach ($pathCandidate in $possiblePaths) {
    if (-not [string]::IsNullOrWhiteSpace($pathCandidate) -and (Test-Path $pathCandidate)) {
        $edgePath = $pathCandidate
        break
    }
}

if (-not $Headless) {
    if ($edgePath) {
        $edgeArgs = @(
            "--app=$prefix",
            "--no-first-run",
            "--no-default-browser-check"
        )
        try {
            $global:EdgeProcess = Start-Process -FilePath $edgePath -ArgumentList $edgeArgs -PassThru -ErrorAction Stop
        } catch {
            Start-Process $prefix
        }
    } else {
        Start-Process $prefix
    }
}

function Send-FedResponse {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)]$Content,
        [string]$ContentType = "text/html",
        [int]$StatusCode = 200
    )

    $response = $Context.Response
    $response.StatusCode = $StatusCode
    $response.ContentType = $ContentType
    $response.Headers.Add("Access-Control-Allow-Origin", "*")
    $response.Headers.Add("Access-Control-Allow-Headers", "*")
    $response.Headers.Add("Access-Control-Allow-Methods", "GET, POST, OPTIONS")

    if ($ContentType -eq "application/json" -and $Content -isnot [string]) {
        $Content = $Content | ConvertTo-Json -Depth 10
    }

    $bytes = [System.Text.Encoding]::UTF8.GetBytes([string]$Content)
    $response.ContentLength64 = $bytes.Length
    $response.OutputStream.Write($bytes, 0, $bytes.Length)
    $response.OutputStream.Close()
}

function Read-RequestBody {
    param(
        [Parameter(Mandatory = $true)]$Context
    )
    $reader = New-Object System.IO.StreamReader($Context.Request.InputStream, $Context.Request.ContentEncoding)
    $body = $reader.ReadToEnd()
    $reader.Close()
    if (-not [string]::IsNullOrWhiteSpace($body)) {
        try {
            return ($body | ConvertFrom-Json)
        } catch {
            return $null
        }
    }
    return $null
}

# Pre-load cached scan data for 0ms instantaneous UI hydration
$global:LastScanData = $null
try {
    $cacheFile = Join-Path $scriptRoot "data\last_scan.json"
    if (Test-Path $cacheFile) {
        $rawCache = Get-Content -Path $cacheFile -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
        if ($rawCache) {
            $global:LastScanData = ($rawCache | ConvertFrom-Json)
        }
    }
} catch { }

$global:IsScanRunning = $false
$global:ScanJob = $null
$global:LastUpdateResult = $null
$global:IsUpdateRunning = $false
$global:UpdateJob = $null

function Start-BackgroundScan {
    if ($global:IsScanRunning) { return }
    $global:IsScanRunning = $true
    
    try {
        $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
        $rs.Open()
        $rs.SessionStateProxy.SetVariable("scriptRoot", $scriptRoot)
        
        $ps = [System.Management.Automation.PowerShell]::Create()
        $ps.Runspace = $rs
        $ps.AddScript({
            param($root)
            Import-Module (Join-Path $root "core\Engine.psm1") -Force -DisableNameChecking
            return Start-FedScan
        }).AddArgument($scriptRoot) | Out-Null
        
        $async = $ps.BeginInvoke()
        $global:ScanJob = [PSCustomObject]@{
            PowerShell = $ps
            Runspace   = $rs
            Async      = $async
        }
    } catch {
        Write-FedLog "Failed to start async scan: $_" -Level "ERROR" -Component "GUI"
        $global:IsScanRunning = $false
    }
}

function Start-BackgroundUpdate {
    param($updateParams)
    if ($global:IsUpdateRunning) { return }
    $global:IsUpdateRunning = $true
    
    try {
        $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
        $rs.Open()
        $rs.SessionStateProxy.SetVariable("scriptRoot", $scriptRoot)
        $rs.SessionStateProxy.SetVariable("uParams", $updateParams)
        
        $ps = [System.Management.Automation.PowerShell]::Create()
        $ps.Runspace = $rs
        $ps.AddScript({
            param($root, $params)
            Import-Module (Join-Path $root "core\Engine.psm1") -Force -DisableNameChecking
            if ($params.ContainsKey("Packages") -and $params.Packages -and $params.Packages.Count -gt 0) {
                $upRes = Update-FedWingetPackages -PackageIds @($params.Packages)
            } else {
                $upRes = Start-FedUpdate @params
            }
            $scanRes = Start-FedScan
            return [PSCustomObject]@{ Update = $upRes; Scan = $scanRes }
        }).AddArgument($scriptRoot).AddArgument($updateParams) | Out-Null
        
        $async = $ps.BeginInvoke()
        $global:UpdateJob = [PSCustomObject]@{
            PowerShell = $ps
            Runspace   = $rs
            Async      = $async
        }
    } catch {
        Write-FedLog "Failed to start async update: $_" -Level "ERROR" -Component "GUI"
        $global:IsUpdateRunning = $false
    }
}

# Kick off initial scan in background immediately
Start-BackgroundScan

Write-FedLog "FedUpDate Desktop GUI ready. Press Ctrl+C in terminal to stop." -Level "INFO" -Component "GUI"

try {
    while ($null -ne $listener -and $listener.IsListening) {
        try {
            $contextTask = $listener.GetContextAsync()
            while (-not $contextTask.AsyncWaitHandle.WaitOne(200)) {
                # Non-blocking wait loop allows Ctrl+C to terminate immediately
            }
            $context = $contextTask.GetAwaiter().GetResult()
            $req = $context.Request
            $urlPath = $req.Url.AbsolutePath
            $method = $req.HttpMethod

            if ($method -eq "OPTIONS") {
                Send-FedResponse -Context $context -Content "" -StatusCode 200
                continue
            }

            # Static Assets
            if ($urlPath -eq "/" -or $urlPath -eq "/index.html") {
                $html = Get-Content -Path (Join-Path $PSScriptRoot "index.html") -Raw -Encoding UTF8
                Send-FedResponse -Context $context -Content $html -ContentType "text/html"
                continue
            }
            if ($urlPath -eq "/styles.css") {
                $css = Get-Content -Path (Join-Path $PSScriptRoot "styles.css") -Raw -Encoding UTF8
                Send-FedResponse -Context $context -Content $css -ContentType "text/css"
                continue
            }
            if ($urlPath -eq "/app.js") {
                $js = Get-Content -Path (Join-Path $PSScriptRoot "app.js") -Raw -Encoding UTF8
                Send-FedResponse -Context $context -Content $js -ContentType "application/javascript"
                continue
            }
            if ($urlPath -eq "/manifest.json") {
                $cfg = Get-FedConfig
                $isLight = $false
                if ($cfg.general -and $cfg.general.theme -eq "Light") {
                    $isLight = $true
                } else {
                    $regCheck = Get-ItemPropertyValue -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize" -Name "AppsUseLightTheme" -ErrorAction SilentlyContinue
                    if ($regCheck -eq 1) {
                        $isLight = $true
                    }
                }
                $themeColor = if ($isLight) { "#f8fafc" } else { "#141622" }
                $manifestObj = @{
                    name = "FedUpDate"
                    short_name = "FedUpDate"
                    start_url = "/"
                    display = "standalone"
                    theme_color = $themeColor
                    background_color = $themeColor
                }
                $manifestJson = $manifestObj | ConvertTo-Json -Depth 5
                Send-FedResponse -Context $context -Content $manifestJson -ContentType "application/manifest+json"
                continue
            }
            if ($urlPath.StartsWith("/assets/") -or $urlPath -eq "/favicon.ico") {
                $assetRel = if ($urlPath -eq "/favicon.ico") { "assets\fedupdate.ico" } else { $urlPath.Substring(1).Replace("/", "\") }
                $assetFile = Join-Path $scriptRoot $assetRel
                if (Test-Path $assetFile) {
                    $mime = if ($assetFile.EndsWith(".png")) { "image/png" } elseif ($assetFile.EndsWith(".ico")) { "image/x-icon" } else { "application/octet-stream" }
                    $fileBytes = [System.IO.File]::ReadAllBytes($assetFile)
                    $res = $context.Response
                    $res.ContentType = $mime
                    $res.StatusCode = 200
                    $res.ContentLength64 = $fileBytes.Length
                    $res.OutputStream.Write($fileBytes, 0, $fileBytes.Length)
                    $res.OutputStream.Close()
                    continue
                }
            }

            # API Endpoints
            switch ($urlPath) {
                "/api/scan" {
                    if ($null -ne $global:ScanJob -and $global:ScanJob.Async.IsCompleted) {
                        try {
                            $scanRes = $global:ScanJob.PowerShell.EndInvoke($global:ScanJob.Async)
                            if ($null -ne $scanRes) {
                                foreach ($item in $scanRes) {
                                    if ($null -ne $item -and $null -ne $item.WingetUpdateCount) {
                                        $global:LastScanData = $item
                                        break
                                    }
                                }
                                if ($null -eq $global:LastScanData -and $scanRes.Count -gt 0) {
                                    $global:LastScanData = $scanRes[$scanRes.Count - 1]
                                }
                            }
                        } catch {
                            Write-FedLog "Error retrieving scan results: $_" -Level "ERROR" -Component "GUI"
                        } finally {
                            $global:ScanJob.PowerShell.Dispose()
                            $global:ScanJob.Runspace.Dispose()
                            $global:ScanJob = $null
                            $global:IsScanRunning = $false
                        }
                    }

                    if ($method -eq "POST" -or ($null -eq $global:LastScanData -and -not $global:IsScanRunning)) {
                        Start-BackgroundScan
                    }
                    
                    $resp = @{
                        isScanning = [bool]$global:IsScanRunning
                        scanData   = $global:LastScanData
                    }
                    Send-FedResponse -Context $context -Content $resp -ContentType "application/json"
                }
                "/api/update" {
                    if ($null -ne $global:UpdateJob -and $global:UpdateJob.Async.IsCompleted) {
                        try {
                            $updRes = $global:UpdateJob.PowerShell.EndInvoke($global:UpdateJob.Async)
                            if ($null -ne $updRes) {
                                foreach ($item in $updRes) {
                                    if ($null -ne $item -and $null -ne $item.Scan) {
                                        $global:LastScanData = $item.Scan
                                    }
                                }
                            }
                        } catch {
                            Write-FedLog "Error retrieving update results: $_" -Level "ERROR" -Component "GUI"
                        } finally {
                            $global:UpdateJob.PowerShell.Dispose()
                            $global:UpdateJob.Runspace.Dispose()
                            $global:UpdateJob = $null
                            $global:IsUpdateRunning = $false
                        }
                    }

                    if ($method -eq "POST") {
                        $body = Read-RequestBody -Context $context
                        $osParam = [bool]($body.os -eq $true)
                        $wingetParam = [bool]($body.winget -eq $true)
                        $storeParam = [bool]($body.store -eq $true)
                        $whatIfParam = [bool]($body.whatif -eq $true)
                        $rebootOverride = if ($body.rebootPolicy) { [string]$body.rebootPolicy } else { "Smart" }
                        
                        $updateParams = @{
                            OS                   = $osParam
                            Winget               = $wingetParam
                            Store                = $storeParam
                            WhatIf               = $whatIfParam
                            RebootPolicyOverride = $rebootOverride
                        }
                        Start-BackgroundUpdate -updateParams $updateParams
                    }

                    Send-FedResponse -Context $context -Content @{ isRunning = [bool]$global:IsUpdateRunning } -ContentType "application/json"
                }
                "/api/update/winget" {
                    $body = Read-RequestBody -Context $context
                    $packages = if ($body.packages) { @($body.packages) } else { @() }
                    $updateParams = @{
                        Packages = $packages
                    }
                    Start-BackgroundUpdate -updateParams $updateParams
                    Send-FedResponse -Context $context -Content @{ isRunning = $true } -ContentType "application/json"
                }
                "/api/watchdog/audit" {
                    try {
                        $audit = Get-FedWatchdogAudit
                        if ($null -ne $global:LastScanData) {
                            $global:LastScanData.WatchdogDrifted = [bool]$audit.HasDrifted
                        }
                        Send-FedResponse -Context $context -Content $audit -ContentType "application/json"
                    } catch {
                        Write-FedLog "Watchdog audit failed: $_" -Level "ERROR" -Component "Watchdog"
                        Send-FedResponse -Context $context -Content @{ HasDrifted = $false; Error = $_.ToString() } -ContentType "application/json"
                    }
                }
                "/api/watchdog/enforce" {
                    $body = Read-RequestBody -Context $context
                    $whatIfParam = [bool]($body.whatif -eq $true)
                    $res = Enforce-FedWatchdog -WhatIf:$whatIfParam
                    if (-not $whatIfParam -and $null -ne $global:LastScanData) {
                        $global:LastScanData.WatchdogDrifted = $false
                        try {
                            $cacheFile = Join-Path $scriptRoot "data\last_scan.json"
                            $global:LastScanData | ConvertTo-Json -Depth 10 | Set-Content -Path $cacheFile -Encoding UTF8 -Force -ErrorAction SilentlyContinue
                        } catch { }
                    }
                    Send-FedResponse -Context $context -Content @{ success = $res } -ContentType "application/json"
                }
                "/api/rollback/ledger" {
                    $ledger = Get-FedLedger
                    Send-FedResponse -Context $context -Content $ledger -ContentType "application/json"
                }
                "/api/rollback/restore" {
                    $body = Read-RequestBody -Context $context
                    $latestParam = [bool]($body.latest -eq $true)
                    $whatIfParam = [bool]($body.whatif -eq $true)
                    $txId = if ($body.transactionId) { [string]$body.transactionId } else { "" }
                    $res = Restore-FedState -TransactionId $txId -Latest:$latestParam -WhatIf:$whatIfParam
                    Send-FedResponse -Context $context -Content @{ success = $res } -ContentType "application/json"
                }
                "/api/schedule" {
                    $sched = Get-FedScheduleTask
                    Send-FedResponse -Context $context -Content $sched -ContentType "application/json"
                }
                "/api/schedule/set" {
                    $body = Read-RequestBody -Context $context
                    if ($body.enabled) {
                        $res = Set-FedScheduleTask -Frequency $body.frequency -Time $body.time
                    } else {
                        $res = Remove-FedScheduleTask
                    }
                    Send-FedResponse -Context $context -Content @{ success = $res } -ContentType "application/json"
                }
                "/api/version" {
                    # The remote check is cached for the life of the server process:
                    # opening Settings repeatedly must not hammer the GitHub API.
                    if ($method -eq "POST" -or $null -eq $global:FedVersionStatus) {
                        $global:FedVersionStatus = Get-FedVersionStatus
                    }
                    Send-FedResponse -Context $context -Content $global:FedVersionStatus -ContentType "application/json"
                }
                "/api/changelog" {
                    # Cached per server process: the unauthenticated GitHub API
                    # allows 60 requests an hour for the whole machine, so the
                    # popover must not fetch every time it is opened.
                    if ($method -eq "POST" -or $null -eq $global:FedReleaseNotes) {
                        $global:FedReleaseNotes = @(Get-FedReleaseNotes)
                    }
                    Send-FedResponse -Context $context -Content @{ releases = $global:FedReleaseNotes } -ContentType "application/json"
                }
                "/api/self-update" {
                    $res = Invoke-FedSelfUpdate
                    $global:FedVersionStatus = $null
                    $global:FedReleaseNotes = $null
                    Send-FedResponse -Context $context -Content @{ success = $res } -ContentType "application/json"
                }
                "/api/config" {
                    if ($method -eq "POST") {
                        $body = Read-RequestBody -Context $context
                        $res = Set-FedConfig -Config $body
                        Send-FedResponse -Context $context -Content @{ success = $res } -ContentType "application/json"
                    } else {
                        $cfg = Get-FedConfig
                        Send-FedResponse -Context $context -Content $cfg -ContentType "application/json"
                    }
                }
                "/api/logs" {
                    $logs = Get-FedLogs -Count 150
                    Send-FedResponse -Context $context -Content $logs -ContentType "application/json"
                }
                "/api/reboot/force" {
                    Invoke-FedRebootPolicy -PolicyOverride "Force" | Out-Null
                    Send-FedResponse -Context $context -Content @{ success = $true } -ContentType "application/json"
                }
                "/api/reboot/shutdown" {
                    Invoke-FedRebootPolicy -PolicyOverride "Shutdown" | Out-Null
                    Send-FedResponse -Context $context -Content @{ success = $true } -ContentType "application/json"
                }
                "/api/uninstall" {
                    $body = Read-RequestBody -Context $context
                    $installer = Join-Path $scriptRoot "install.ps1"
                    $argList = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $installer, "-Uninstall")
                    if ($body.restoreOS) { $argList += "-RestoreOSDefaults" }
                    if ($body.keepBackups) { $argList += "-KeepBackups" } else { $argList += "-PurgeAll" }
                    $argList += "-NonInteractive"
                    
                    $pwshExe = (Get-Process -Id $PID).Path
                    Start-Process -FilePath $pwshExe -ArgumentList ($argList -join " ") -WindowStyle Hidden
                    
                    Send-FedResponse -Context $context -Content @{ success = $true } -ContentType "application/json"
                    Start-Sleep -Milliseconds 800
                    $listener.Stop()
                    exit 0
                }
                "/api/theme" {
                    if ($method -eq "POST") {
                        $body = Read-RequestBody -Context $context
                        Set-EdgeProfileTheme -Theme $body.theme
                        Send-FedResponse -Context $context -Content @{ success = $true } -ContentType "application/json"
                    } else {
                        Send-FedResponse -Context $context -Content @{ success = $true } -ContentType "application/json"
                    }
                }
                "/api/window/min" {
                    $wnd = [IntPtr]::Zero
                    if ($global:EdgeProcess -and $global:EdgeProcess.MainWindowHandle -ne [IntPtr]::Zero) {
                        $wnd = $global:EdgeProcess.MainWindowHandle
                    } else {
                        $procs = Get-Process -Name "msedge", "FedUpDate.UI" -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowTitle -match "FedUpDate" -and $_.MainWindowHandle -ne [IntPtr]::Zero }
                        if ($procs) { $wnd = ($procs | Select-Object -First 1).MainWindowHandle }
                    }
                    if ($wnd -ne [IntPtr]::Zero) {
                        [FedNativeWindow]::ShowWindow($wnd, [FedNativeWindow]::SW_MINIMIZE)
                    }
                    Send-FedResponse -Context $context -Content @{ success = $true } -ContentType "application/json"
                }
                "/api/window/max" {
                    $wnd = [IntPtr]::Zero
                    if ($global:EdgeProcess -and $global:EdgeProcess.MainWindowHandle -ne [IntPtr]::Zero) {
                        $wnd = $global:EdgeProcess.MainWindowHandle
                    } else {
                        $procs = Get-Process -Name "msedge", "FedUpDate.UI" -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowTitle -match "FedUpDate" -and $_.MainWindowHandle -ne [IntPtr]::Zero }
                        if ($procs) { $wnd = ($procs | Select-Object -First 1).MainWindowHandle }
                    }
                    if ($wnd -ne [IntPtr]::Zero) {
                        $style = [FedNativeWindow]::GetWindowLong($wnd, [FedNativeWindow]::GWL_STYLE)
                        if (($style -band 0x01000000) -ne 0) {
                            [FedNativeWindow]::ShowWindow($wnd, [FedNativeWindow]::SW_RESTORE)
                        } else {
                            [FedNativeWindow]::ShowWindow($wnd, [FedNativeWindow]::SW_MAXIMIZE)
                        }
                    }
                    Send-FedResponse -Context $context -Content @{ success = $true } -ContentType "application/json"
                }
                "/api/window/close" {
                    Send-FedResponse -Context $context -Content @{ success = $true } -ContentType "application/json"
                    Start-Sleep -Milliseconds 300
                    if ($global:EdgeProcess -and -not $global:EdgeProcess.HasExited) {
                        try { $global:EdgeProcess.Kill() } catch {}
                    }
                    $listener.Stop()
                    exit 0
                }
                "/api/shutdown" {
                    Send-FedResponse -Context $context -Content @{ success = $true } -ContentType "application/json"
                    if ($global:EdgeProcess -and -not $global:EdgeProcess.HasExited) {
                        try { $global:EdgeProcess.Kill() } catch {}
                    }
                    $listener.Stop()
                    exit 0
                }
                Default {
                    Send-FedResponse -Context $context -Content "Endpoint Not Found" -StatusCode 404
                }
            }
        } catch {
            # Ignore individual request handling errors
        }
    }
} finally {
    if ($null -ne $listener -and $listener.IsListening) {
        $listener.Stop()
        $listener.Close()
    }
    Write-FedLog "GUI Server stopped." -Level "INFO" -Component "GUI"
}
