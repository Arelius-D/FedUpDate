# ==============================================================================
# FedUpDate Smart Reboot Detection & Policy Engine
# Registry and disk facts are gathered in one reader, graded by a pure
# classifier, and acted on by a policy handler whose system calls are injected
# so that every path can be exercised without restarting anything.
# ==============================================================================

. "$PSScriptRoot\Logger.ps1"
. "$PSScriptRoot\Config.ps1"

# Policies that power the machine off. None of them may act on an advisory
# signal alone; see Invoke-FedRebootPolicy.
$script:FedHardRebootPolicies = @("Force", "Shutdown", "Schedule")

function ConvertTo-FedNtPath {
    [CmdletBinding()]
    param(
        [Parameter()]
        [AllowNull()]
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }

    # A source may carry flag characters ahead of the NT namespace prefix, as in
    # "*1\??\C:\...". Everything before "\??\" is a flag rather than path text.
    $marker = $Value.IndexOf('\??\')
    if ($marker -ge 0) { return $Value.Substring($marker + 4) }

    return $Value.TrimStart('!', '*')
}

function ConvertFrom-FedPendingFileRename {
    <#
        .SYNOPSIS
            Turns the raw PendingFileRenameOperations value into operations.

        .DESCRIPTION
            The value is a REG_MULTI_SZ of source and destination pairs. An
            empty destination means the source is deleted during boot rather
            than moved, which is how installers clean up their own temporary
            folders. Reading the array as a flat list of strings loses that
            distinction and miscounts the operations, so the pairing is kept.
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [AllowNull()]
        [string[]]$Raw
    )

    $operations = [System.Collections.Generic.List[PSObject]]::new()
    if ($null -eq $Raw -or @($Raw).Count -eq 0) { return @() }

    $entries = @($Raw)
    for ($i = 0; $i -lt $entries.Count; $i += 2) {
        $source = $entries[$i]
        $destination = if (($i + 1) -lt $entries.Count) { $entries[$i + 1] } else { $null }

        if ([string]::IsNullOrWhiteSpace($source)) { continue }

        $isDelete = [string]::IsNullOrWhiteSpace($destination)
        $operations.Add([PSCustomObject]@{
            Source          = $source
            Destination     = $destination
            SourcePath      = ConvertTo-FedNtPath -Value $source
            DestinationPath = if ($isDelete) { $null } else { ConvertTo-FedNtPath -Value $destination }
            Operation       = if ($isDelete) { "Delete" } else { "Replace" }
        })
    }

    return @($operations)
}

function New-FedRebootSignal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$Source,
        [Parameter(Mandatory = $true)] [ValidateSet("Advisory", "Required")] [string]$Severity,
        [Parameter(Mandatory = $true)] [string]$Detail,
        [Parameter()] [string[]]$Items = @(),
        [Parameter()] [bool]$StagedAfterLastBoot = $true
    )

    return [PSCustomObject]@{
        Source              = $Source
        Severity            = $Severity
        Detail              = $Detail
        Items               = @($Items)
        StagedAfterLastBoot = $StagedAfterLastBoot
    }
}

function Get-FedRebootSignalData {
    <#
        .SYNOPSIS
            Gathers every fact the classifier needs, and nothing else.

        .DESCRIPTION
            This is the only function in the engine that reads the registry, the
            file system or the boot time. Keeping the reads here means the
            grading logic can be run against captured fixtures rather than
            against the live machine.
    #>
    [CmdletBinding()]
    param()

    $data = [PSCustomObject]@{
        CollectedAt           = Get-Date
        LastBootTime          = $null
        CbsRebootPending      = $false
        CbsRebootInProgress   = $false
        CbsPackagesPending    = $false
        WuRebootRequired      = $false
        WuServicesPending     = $false
        ServerManagerReboot   = $false
        ComputerRenamePending = $false
        DomainJoinPending     = $false
        UpdateExeVolatile     = 0
        PendingFileRenameRaw  = @()
        PathInfo              = @{}
    }

    try {
        $data.LastBootTime = (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime
    } catch { }

    # Component Based Servicing. PackagesPending marks a servicing operation
    # that has been staged but not yet committed, and was previously missed.
    try {
        $cbsKey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing"
        $data.CbsRebootPending    = Test-Path "$cbsKey\RebootPending"
        $data.CbsRebootInProgress = Test-Path "$cbsKey\RebootInProgress"
        $data.CbsPackagesPending  = Test-Path "$cbsKey\PackagesPending"
    } catch { }

    # Windows Update. The reboot flag stands on its own; the pending services
    # list has to be looked inside, see below.
    try {
        $wuKey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate"
        $data.WuRebootRequired  = Test-Path "$wuKey\Auto Update\RebootRequired"

        # The Pending key exists on a healthy system as an empty container, so
        # its presence alone proves nothing. Only a registration inside it means
        # an update is genuinely waiting on a restart.
        $pendingKey = "$wuKey\Services\Pending"
        if (Test-Path $pendingKey) {
            $data.WuServicesPending = (@(Get-ChildItem -Path $pendingKey -ErrorAction SilentlyContinue).Count -gt 0)
        }
    } catch { }

    try {
        $smMgr = "HKLM:\SOFTWARE\Microsoft\ServerManager\CurrentState"
        if (Test-Path $smMgr) {
            $val = (Get-ItemProperty $smMgr -ErrorAction SilentlyContinue).IsRebootRequired
            $data.ServerManagerReboot = ($val -eq 1 -or $val -eq $true)
        }
    } catch { }

    # A rename that has been accepted but not yet applied leaves the active name
    # and the configured name disagreeing until the machine restarts.
    try {
        $cnBase = "HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName"
        $active = (Get-ItemProperty "$cnBase\ActiveComputerName" -Name ComputerName -ErrorAction SilentlyContinue).ComputerName
        $configured = (Get-ItemProperty "$cnBase\ComputerName" -Name ComputerName -ErrorAction SilentlyContinue).ComputerName
        if ($active -and $configured -and $active -ne $configured) {
            $data.ComputerRenamePending = $true
        }
    } catch { }

    try {
        $netlogon = "HKLM:\SYSTEM\CurrentControlSet\Services\Netlogon"
        $data.DomainJoinPending = ((Test-Path "$netlogon\JoinDomain") -or (Test-Path "$netlogon\AvoidSpnSet"))
    } catch { }

    try {
        $uev = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Updates" -Name UpdateExeVolatile -ErrorAction SilentlyContinue).UpdateExeVolatile
        if ($null -ne $uev) { $data.UpdateExeVolatile = [int]$uev }
    } catch { }

    try {
        $smKey = "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager"
        $item = Get-ItemProperty -Path $smKey -Name "PendingFileRenameOperations" -ErrorAction SilentlyContinue
        if ($null -ne $item -and $null -ne $item.PendingFileRenameOperations) {
            $data.PendingFileRenameRaw = @($item.PendingFileRenameOperations)
        }
    } catch { }

    # Stat the referenced paths so the classifier can tell a queued operation
    # from residue, and can date the queue against the last boot, without
    # touching the disk itself.
    $info = @{}
    foreach ($op in (ConvertFrom-FedPendingFileRename -Raw $data.PendingFileRenameRaw)) {
        foreach ($path in @($op.SourcePath, $op.DestinationPath)) {
            if ([string]::IsNullOrWhiteSpace($path) -or $info.ContainsKey($path)) { continue }
            $entry = @{ Exists = $false; Timestamp = $null }
            try {
                $fsItem = Get-Item -LiteralPath $path -Force -ErrorAction Stop
                $entry.Exists = $true
                $stamps = @($fsItem.CreationTime, $fsItem.LastWriteTime) | Where-Object { $_ }
                if ($stamps.Count -gt 0) {
                    $entry.Timestamp = ($stamps | Sort-Object -Descending)[0]
                }
            } catch { }
            $info[$path] = $entry
        }
    }
    $data.PathInfo = $info

    return $data
}

function Get-FedRebootVerdict {
    <#
        .SYNOPSIS
            Grades gathered signals. Pure: no registry, no disk, no clock.

        .DESCRIPTION
            Servicing flags mean the system is genuinely mid-change and are
            graded Required. A pending file rename is graded on what it actually
            asks for: replacing a file in place is a real change and is
            Required, while deleting a file at boot is how installers tidy their
            own temporary folders and is only Advisory. Grading every pending
            rename as Required is what caused a routine browser update to be
            reported as a reboot the user had to act on.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$SignalData
    )

    $signals = [System.Collections.Generic.List[PSObject]]::new()

    $hardFlags = @(
        @{ Test = $SignalData.CbsRebootPending;      Source = "CBS";           Detail = "Component Based Servicing has updates pending a restart." }
        @{ Test = $SignalData.CbsRebootInProgress;   Source = "CBS";           Detail = "Component Based Servicing is applying updates across a restart." }
        @{ Test = $SignalData.CbsPackagesPending;    Source = "CBS";           Detail = "Component Based Servicing has packages staged but not committed." }
        @{ Test = $SignalData.WuRebootRequired;      Source = "WindowsUpdate"; Detail = "Windows Update has flagged a pending restart." }
        @{ Test = $SignalData.WuServicesPending;     Source = "WindowsUpdate"; Detail = "Windows Update has services awaiting a restart to finish installing." }
        @{ Test = $SignalData.ServerManagerReboot;   Source = "ServerManager"; Detail = "Server Manager reports a restart is required." }
        @{ Test = $SignalData.ComputerRenamePending; Source = "ComputerName";  Detail = "A computer rename is applied on the next restart." }
        @{ Test = $SignalData.DomainJoinPending;     Source = "DomainJoin";    Detail = "A domain join is completed on the next restart." }
        @{ Test = ($SignalData.UpdateExeVolatile -ne 0); Source = "Updates";   Detail = "An update installer stopped part way and finishes on restart." }
    )

    foreach ($flag in $hardFlags) {
        if ($flag.Test) {
            $signals.Add((New-FedRebootSignal -Source $flag.Source -Severity "Required" -Detail $flag.Detail))
        }
    }

    $operations = @(ConvertFrom-FedPendingFileRename -Raw $SignalData.PendingFileRenameRaw)
    if ($operations.Count -gt 0) {
        $replaces = @($operations | Where-Object { $_.Operation -eq "Replace" })
        $deletes  = @($operations | Where-Object { $_.Operation -eq "Delete" })

        # Date the queue by the newest thing it points at. A queue whose targets
        # all predate the last boot has already survived a restart, which is the
        # difference between "restart to finish this" and "restarting will not
        # change this".
        $newest = $null
        foreach ($op in $operations) {
            foreach ($path in @($op.SourcePath, $op.DestinationPath)) {
                if ([string]::IsNullOrWhiteSpace($path)) { continue }
                $entry = $SignalData.PathInfo[$path]
                if ($null -eq $entry -or -not $entry.Exists -or $null -eq $entry.Timestamp) { continue }
                if ($null -eq $newest -or $entry.Timestamp -gt $newest) { $newest = $entry.Timestamp }
            }
        }
        $stagedAfterBoot = $true
        if ($null -ne $newest -and $null -ne $SignalData.LastBootTime) {
            $stagedAfterBoot = ($newest -gt $SignalData.LastBootTime)
        }

        if ($replaces.Count -gt 0) {
            $noun = if ($replaces.Count -eq 1) { "file is" } else { "files are" }
            $signals.Add((New-FedRebootSignal `
                -Source "PendingFileRename" `
                -Severity "Required" `
                -Detail "$($replaces.Count) $noun replaced in place on the next restart." `
                -Items @($replaces | ForEach-Object { "$($_.SourcePath) -> $($_.DestinationPath)" }) `
                -StagedAfterLastBoot $stagedAfterBoot))
        }

        if ($deletes.Count -gt 0) {
            $noun = if ($deletes.Count -eq 1) { "item is" } else { "items are" }
            $signals.Add((New-FedRebootSignal `
                -Source "PendingFileRename" `
                -Severity "Advisory" `
                -Detail "$($deletes.Count) $noun queued for deletion on the next restart, which is routine installer cleanup." `
                -Items @($deletes | ForEach-Object { $_.SourcePath }) `
                -StagedAfterLastBoot $stagedAfterBoot))
        }
    }

    $severity = "None"
    if (@($signals | Where-Object { $_.Severity -eq "Required" }).Count -gt 0) {
        $severity = "Required"
    } elseif ($signals.Count -gt 0) {
        $severity = "Advisory"
    }

    # Reasons stays a flat list of sentences because the command line, the text
    # interface and the notification list all render it directly.
    $reasons = @($signals | ForEach-Object { $_.Detail })
    $pendingFiles = @($signals | Where-Object { $_.Source -eq "PendingFileRename" } | ForEach-Object { $_.Items } )

    return [PSCustomObject]@{
        Severity          = $severity
        IsRebootRequired  = ($severity -eq "Required")
        HasAdvisory       = (@($signals | Where-Object { $_.Severity -eq "Advisory" }).Count -gt 0)
        ReasonCount       = $signals.Count
        Reasons           = @($reasons)
        Signals           = @($signals)
        PendingFiles      = @($pendingFiles)
        SurvivedLastBoot  = (@($signals | Where-Object { -not $_.StagedAfterLastBoot }).Count -gt 0)
        LastBootTime      = $SignalData.LastBootTime
        EvaluatedAt       = $SignalData.CollectedAt
    }
}

function Get-FedRebootState {
    [CmdletBinding()]
    param(
        # Supplying captured data runs the grading without reading the machine.
        [Parameter()]
        [PSCustomObject]$SignalData
    )

    $data = if ($SignalData) { $SignalData } else { Get-FedRebootSignalData }
    return Get-FedRebootVerdict -SignalData $data
}

function Invoke-FedRebootPolicy {
    <#
        .SYNOPSIS
            Applies the configured policy to the current reboot state.

        .DESCRIPTION
            Restarting, shutting down and scheduling are reached through
            injected script blocks so the decision can be tested without the
            machine acting on it. A policy that powers the machine off is
            refused when the only pending signals are advisory, because routine
            installer cleanup is not grounds for closing a user's applications.
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$PolicyOverride,

        [Parameter()]
        [switch]$WhatIf,

        # Set when a person asked for this directly rather than a policy deciding.
        [Parameter()]
        [switch]$UserInitiated,

        [Parameter()]
        [PSCustomObject]$State,

        [Parameter()]
        [PSCustomObject]$Config,

        [Parameter()]
        [scriptblock]$RestartAction,

        [Parameter()]
        [scriptblock]$ShutdownAction,

        [Parameter()]
        [scriptblock]$ScheduleAction,

        [Parameter()]
        [datetime]$Now = (Get-Date)
    )

    $state = if ($State) { $State } else { Get-FedRebootState }
    $config = if ($Config) { $Config } else { Get-FedConfig }

    if (-not $RestartAction)  { $RestartAction  = { Restart-Computer -Force -Confirm:$false } }
    if (-not $ShutdownAction) { $ShutdownAction = { Stop-Computer -Force -Confirm:$false } }
    if (-not $ScheduleAction) { $ScheduleAction = { param($Seconds, $Message) & shutdown.exe /r /t $Seconds /c $Message } }

    $result = [PSCustomObject]@{
        Action          = "None"
        RebootTriggered = $false
        Severity        = $state.Severity
        Downgraded      = $false
        ScheduleTime    = $null
        State           = $state
        WhatIf          = [bool]$WhatIf
    }

    if ($state.Severity -eq "None" -and -not $UserInitiated) {
        Write-FedLog "Reboot check passed: nothing is pending." -Level "SUCCESS" -Component "Reboot"
        return $result
    }

    $policy = if ($PolicyOverride) { $PolicyOverride } else { $config.rebootPolicy }
    if ([string]::IsNullOrWhiteSpace($policy)) { $policy = "Smart" }

    $summary = ($state.Reasons -join '; ')

    if ($state.Severity -eq "None") {
        Write-FedLog "A restart was requested directly with nothing pending. Policy: $policy" -Level "INFO" -Component "Reboot"
    } elseif ($state.Severity -eq "Advisory") {
        Write-FedLog "Advisory only: $summary Policy: $policy" -Level "INFO" -Component "Reboot"
    } else {
        Write-FedLog "System reboot is required ($summary). Policy: $policy" -Level "WARN" -Component "Reboot"
    }

    if ($state.SurvivedLastBoot) {
        Write-FedLog "One or more pending items predate the last restart, so restarting again will not clear them." -Level "WARN" -Component "Reboot"
    }

    # Safety gate. Advisory signals never justify powering the machine off.
    $allowOnAdvisory = $false
    if ($null -ne $config.PSObject.Properties['allowRebootOnAdvisory']) {
        $allowOnAdvisory = [bool]$config.allowRebootOnAdvisory
    }
    if ($policy -in $script:FedHardRebootPolicies -and $state.Severity -ne "Required" -and -not $allowOnAdvisory -and -not $UserInitiated) {
        Write-FedLog "Policy '$policy' was requested, but the only pending items are routine cleanup. No restart will be issued." -Level "WARN" -Component "Reboot"
        $result.Downgraded = $true
        $policy = "Notify"
    }

    if ($WhatIf) {
        Write-FedLog "[WHATIF] Reboot policy '$policy' would be applied." -Level "WHATIF" -Component "Reboot"
        $result.Action = $policy
        return $result
    }

    switch ($policy) {
        "Never" {
            Write-FedLog "Policy is 'Never': no reboot action will be taken." -Level "INFO" -Component "Reboot"
            $result.Action = "Suppressed"
        }
        "Notify" {
            Write-FedLog "Policy is 'Notify': restart when convenient to finish the pending work." -Level "WARN" -Component "Reboot"
            $result.Action = "Notified"
        }
        "Prompt" {
            # The engine has no console and no window of its own, so the asking
            # is left to whichever interface invoked it.
            Write-FedLog "Policy is 'Prompt': awaiting a decision from the interface." -Level "INFO" -Component "Reboot"
            $result.Action = "PromptRequired"
        }
        "Schedule" {
            $schedTime = if ($config.rebootScheduleTime) { [string]$config.rebootScheduleTime } else { "03:00" }
            try {
                $target = $Now.Date.Add([timespan]::Parse($schedTime))
                if ($target -le $Now) { $target = $target.AddDays(1) }
                $seconds = [int](($target - $Now).TotalSeconds)

                & $ScheduleAction $seconds "FedUpDate is restarting this computer to finish installing updates."

                Write-FedLog "Policy is 'Schedule': restart scheduled for $($target.ToString('yyyy-MM-dd HH:mm')). Run 'shutdown /a' to cancel." -Level "WARN" -Component "Reboot"
                $result.Action = "Scheduled"
                $result.ScheduleTime = $target
            } catch {
                Write-FedLog "Could not schedule a restart for '$schedTime': $_" -Level "ERROR" -Component "Reboot"
                $result.Action = "ScheduleFailed"
            }
        }
        "Force" {
            Write-FedLog "Policy is 'Force': restarting now." -Level "WARN" -Component "Reboot"
            $result.Action = "RestartInitiated"
            $result.RebootTriggered = $true
            & $RestartAction
        }
        "Shutdown" {
            Write-FedLog "Policy is 'Shutdown': shutting down now." -Level "WARN" -Component "Reboot"
            $result.Action = "ShutdownInitiated"
            $result.RebootTriggered = $true
            & $ShutdownAction
        }
        Default {
            # 'Smart' and anything unrecognised. Report what is pending and let
            # the person decide; never power the machine off on our own.
            if ($state.Severity -eq "Required") {
                Write-FedLog "Updates are waiting on a restart. Restart when convenient." -Level "WARN" -Component "Reboot"
                $result.Action = "Notified"
            } else {
                Write-FedLog "Routine cleanup is queued for the next restart. Nothing needs doing." -Level "INFO" -Component "Reboot"
                $result.Action = "Informational"
            }
        }
    }

    return $result
}


Export-ModuleMember -Function Get-FedRebootState, Get-FedRebootSignalData, Get-FedRebootVerdict, ConvertFrom-FedPendingFileRename, ConvertTo-FedNtPath, Invoke-FedRebootPolicy -ErrorAction SilentlyContinue
