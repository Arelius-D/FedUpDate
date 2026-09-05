# ==============================================================================
# FedUpDate Rollback & State Ledger Engine
# Records every registry, service, task, and file change with timestamped backups
# Allows true 100% reversible rollback of any OS settings or configurations
# ==============================================================================

. "$PSScriptRoot\Logger.ps1"
. "$PSScriptRoot\Config.ps1"

function Get-FedLedgerFile {
    $dataDir = Get-FedDataDirectory
    return Join-Path $dataDir "state_ledger.json"
}

function Get-FedBackupDirectory {
    $dataDir = Get-FedDataDirectory
    $backupDir = Join-Path $dataDir "backups"
    if (-not (Test-Path $backupDir)) {
        New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
    }
    return $backupDir
}

function Get-FedLedger {
    [CmdletBinding()]
    param()

    $ledgerFile = Get-FedLedgerFile
    if (-not (Test-Path $ledgerFile)) {
        return @()
    }

    try {
        $content = Get-Content -Path $ledgerFile -Raw -Encoding UTF8
        $ledger = $content | ConvertFrom-Json
        return @($ledger)
    } catch {
        Write-FedLog "Error reading state ledger: $_" -Level "ERROR" -Component "Rollback"
        return @()
    }
}

function Save-FedLedger {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [array]$Ledger
    )

    $ledgerFile = Get-FedLedgerFile
    try {
        $json = $Ledger | ConvertTo-Json -Depth 10
        Set-Content -Path $ledgerFile -Value $json -Encoding UTF8
        return $true
    } catch {
        Write-FedLog "Error saving state ledger: $_" -Level "ERROR" -Component "Rollback"
        return $false
    }
}

function New-FedTransaction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Description
    )

    $txId = "tx-" + (Get-Date -Format "yyyyMMdd-HHmmss-fff")
    $tx = [PSCustomObject]@{
        Id          = $txId
        Timestamp   = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ")
        Description = $Description
        Status      = "Draft"
        Changes     = [System.Collections.Generic.List[PSObject]]::new()
    }
    return $tx
}

function Record-FedRegistryChange {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Transaction,

        [Parameter(Mandatory = $true)]
        [string]$KeyPath,

        [Parameter(Mandatory = $true)]
        [string]$ValueName,

        [Parameter(Mandatory = $true)]
        [object]$NewValue,

        [Parameter()]
        [string]$ValueType = "DWord",

        [Parameter()]
        [switch]$WhatIf
    )

    $existed = $false
    $origValue = $null
    $origType = $null

    try {
        if (Test-Path $KeyPath) {
            $item = Get-ItemProperty -Path $KeyPath -Name $ValueName -ErrorAction SilentlyContinue
            if ($null -ne $item -and $null -ne $item.$ValueName) {
                $existed = $true
                $origValue = $item.$ValueName
                # Open the hive the path actually belongs to. Opening
                # LocalMachine for an HKCU path silently yields no key, which is
                # how HKCU value kinds went unrecorded and could not be restored.
                $hive = $null
                $subPath = $null
                $cmp = [StringComparison]::OrdinalIgnoreCase
                foreach ($prefix in @('HKCU:', 'HKEY_CURRENT_USER')) {
                    if ($KeyPath.StartsWith($prefix, $cmp)) {
                        $hive = [Microsoft.Win32.Registry]::CurrentUser
                        $subPath = $KeyPath.Substring($prefix.Length).TrimStart([char]92)
                        break
                    }
                }
                if (-not $hive) {
                    foreach ($prefix in @('HKLM:', 'HKEY_LOCAL_MACHINE')) {
                        if ($KeyPath.StartsWith($prefix, $cmp)) {
                            $hive = [Microsoft.Win32.Registry]::LocalMachine
                            $subPath = $KeyPath.Substring($prefix.Length).TrimStart([char]92)
                            break
                        }
                    }
                }

                if ($hive -and $subPath) {
                    $regKey = $hive.OpenSubKey($subPath)
                    if ($regKey) {
                        $origType = $regKey.GetValueKind($ValueName).ToString()
                        $regKey.Close()
                    }
                }
            }
        }
    } catch {
        # Registry inspection fallback
    }

    # What a setting was before this application first moved it is worth writing
    # down once. After that the answer does not change, and a run that finds the
    # setting already where it should be has moved nothing, so there is nothing
    # to undo and nothing to record. Writing it down regardless is what grew the
    # record by ten entries every quarter of an hour for as long as the
    # application stayed installed, all of them describing the same few settings.
    if ($existed -and $origValue -eq $NewValue -and
        ([string]::IsNullOrWhiteSpace($origType) -or $origType -eq $ValueType)) {
        Write-FedLog "Registry [$KeyPath] '$ValueName' is already '$NewValue'. Nothing changed, so nothing was recorded." -Level "INFO" -Component "Rollback"
        return
    }

    $change = [PSCustomObject]@{
        Type          = "Registry"
        KeyPath       = $KeyPath
        ValueName     = $ValueName
        ExistedBefore = $existed
        OriginalValue = $origValue
        OriginalType  = $origType
        NewValue      = $NewValue
        NewType       = $ValueType
        Timestamp     = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ")
    }

    $Transaction.Changes.Add($change)

    if ($WhatIf) {
        Write-FedLog "[WHATIF] Would set Registry [$KeyPath] '$ValueName' = '$NewValue' (was: '$origValue')" -Level "WHATIF" -Component "Rollback"
    } else {
        try {
            if (-not (Test-Path $KeyPath)) {
                if ($KeyPath.StartsWith("HKCU:\")) {
                    $subKey = $KeyPath.Substring(6)
                    [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($subKey) | Out-Null
                } elseif ($KeyPath.StartsWith("HKLM:\")) {
                    $subKey = $KeyPath.Substring(6)
                    [Microsoft.Win32.Registry]::LocalMachine.CreateSubKey($subKey) | Out-Null
                } else {
                    New-Item -Path $KeyPath -Force | Out-Null
                }
            }
            Set-ItemProperty -Path $KeyPath -Name $ValueName -Value $NewValue -Type $ValueType -Force | Out-Null
            Write-FedLog "Set Registry [$KeyPath] '$ValueName' = '$NewValue'" -Level "INFO" -Component "Rollback"
        } catch {
            Write-FedLog "Failed to apply registry change [$KeyPath] '$ValueName': $_" -Level "ERROR" -Component "Rollback"
        }
    }
}

function Record-FedServiceChange {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Transaction,

        [Parameter(Mandatory = $true)]
        [string]$ServiceName,

        [Parameter(Mandatory = $true)]
        [ValidateSet("Automatic", "Manual", "Disabled")]
        [string]$NewStartType,

        [Parameter()]
        [switch]$WhatIf
    )

    $service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    $origStartType = "Unknown"
    $origStatus = "Unknown"

    if ($service) {
        $origStartType = $service.StartType.ToString()
        $origStatus = $service.Status.ToString()
    }

    # Already set the way it is being asked for, so nothing is being changed.
    if ($service -and $origStartType -eq $NewStartType) {
        Write-FedLog "Service '$ServiceName' is already $NewStartType. Nothing changed, so nothing was recorded." -Level "INFO" -Component "Rollback"
        return
    }

    $change = [PSCustomObject]@{
        Type              = "Service"
        ServiceName       = $ServiceName
        OriginalStartType = $origStartType
        OriginalStatus    = $origStatus
        NewStartType      = $NewStartType
        Timestamp         = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ")
    }

    $Transaction.Changes.Add($change)

    if ($WhatIf) {
        Write-FedLog "[WHATIF] Would configure Service '$ServiceName' StartType to '$NewStartType' (was: '$origStartType')" -Level "WHATIF" -Component "Rollback"
    } else {
        try {
            if ($service) {
                Set-Service -Name $ServiceName -StartupType $NewStartType -ErrorAction SilentlyContinue
                $startVal = switch ($NewStartType) {
                    "Disabled"  { 4 }
                    "Manual"    { 3 }
                    "Automatic" { 2 }
                    default     { 3 }
                }
                $svcReg = "HKLM:\SYSTEM\CurrentControlSet\Services\$ServiceName"
                if (Test-Path $svcReg) {
                    Set-ItemProperty -Path $svcReg -Name "Start" -Value $startVal -ErrorAction SilentlyContinue
                }
                if ($NewStartType -eq "Disabled" -and $service.Status -eq "Running") {
                    Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
                }
                Write-FedLog "Configured Service '$ServiceName' -> StartupType: $NewStartType" -Level "INFO" -Component "Rollback"
            }
        } catch {
            Write-FedLog "Failed to configure service '$ServiceName': $_" -Level "WARN" -Component "Rollback"
        }
    }
}

function Record-FedTaskChange {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Transaction,

        [Parameter(Mandatory = $true)]
        [string]$TaskPath,

        [Parameter(Mandatory = $true)]
        [string]$TaskName,

        [Parameter(Mandatory = $true)]
        [ValidateSet("Enable", "Disable")]
        [string]$NewState,

        [Parameter()]
        [switch]$WhatIf
    )

    $task = Get-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction SilentlyContinue
    $origState = if ($task) { $task.State.ToString() } else { "NotFound" }

    # A task's state reads as Ready or Disabled, while the instruction is Enable
    # or Disable. Compared in those terms, a task already in the state being
    # asked for is not being changed.
    $alreadyInState = ($NewState -eq "Disable" -and $origState -eq "Disabled") -or
                      ($NewState -eq "Enable"  -and $origState -eq "Ready")
    if ($task -and $alreadyInState) {
        Write-FedLog "Scheduled task '$TaskPath$TaskName' is already $origState. Nothing changed, so nothing was recorded." -Level "INFO" -Component "Rollback"
        return
    }

    $change = [PSCustomObject]@{
        Type          = "ScheduledTask"
        TaskPath      = $TaskPath
        TaskName      = $TaskName
        OriginalState = $origState
        NewState      = $NewState
        Timestamp     = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ")
    }

    $Transaction.Changes.Add($change)

    if ($WhatIf) {
        Write-FedLog "[WHATIF] Would $NewState Scheduled Task '$TaskPath$TaskName' (was: '$origState')" -Level "WHATIF" -Component "Rollback"
    } else {
        try {
            if ($task) {
                if ($NewState -eq "Disable") {
                    Disable-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction SilentlyContinue | Out-Null
                } else {
                    Enable-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction SilentlyContinue | Out-Null
                }
                Write-FedLog "Scheduled Task '$TaskPath$TaskName' -> $NewState" -Level "INFO" -Component "Rollback"
            }
        } catch {
            Write-FedLog "Failed to alter scheduled task '$TaskPath$TaskName': $_" -Level "WARN" -Component "Rollback"
        }
    }
}

function Record-FedFileBackup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Transaction,

        [Parameter(Mandatory = $true)]
        [string]$FilePath,

        [Parameter()]
        [switch]$WhatIf
    )

    if (-not (Test-Path $FilePath)) {
        return
    }

    $backupDir = Get-FedBackupDirectory
    $fileName = [System.IO.Path]::GetFileName($FilePath)
    $stamp = Get-Date -Format "yyyyMMdd_HHmmss_fff"
    $backupPath = Join-Path $backupDir "${stamp}_${fileName}.bak"

    $change = [PSCustomObject]@{
        Type         = "File"
        OriginalPath = (Resolve-Path $FilePath).Path
        BackupPath   = $backupPath
        Timestamp    = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ")
    }

    $Transaction.Changes.Add($change)

    if ($WhatIf) {
        Write-FedLog "[WHATIF] Would create file backup of '$FilePath' -> '$backupPath'" -Level "WHATIF" -Component "Rollback"
    } else {
        try {
            Copy-Item -Path $FilePath -Destination $backupPath -Force
            Write-FedLog "Created file backup of '$FilePath' -> '$backupPath'" -Level "INFO" -Component "Rollback"
        } catch {
            Write-FedLog "Failed to create file backup for '$FilePath': $_" -Level "ERROR" -Component "Rollback"
        }
    }
}

function Commit-FedTransaction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Transaction,

        [Parameter()]
        [switch]$WhatIf
    )

    if ($WhatIf) {
        Write-FedLog "[WHATIF] Transaction '$($Transaction.Id)' simulation complete with $($Transaction.Changes.Count) changes." -Level "WHATIF" -Component "Rollback"
        return $true
    }

    # A run that found everything already as it should be has nothing to undo.
    # Writing that down anyway is what grew the ledger without bound: the shield
    # checks itself on a timer, and every check recorded the same settings again.
    if (@($Transaction.Changes).Count -eq 0) {
        Write-FedLog "Nothing changed in transaction '$($Transaction.Id)' ($($Transaction.Description)), so nothing was recorded." -Level "INFO" -Component "Rollback"
        return $true
    }

    $Transaction.Status = "Committed"
    $ledger = @(Get-FedLedger)
    $ledger += $Transaction
    Save-FedLedger -Ledger $ledger
    Write-FedLog "Committed state transaction '$($Transaction.Id)' ($($Transaction.Description)) with $($Transaction.Changes.Count) operations." -Level "SUCCESS" -Component "Rollback"
    return $true
}

function Restore-FedState {
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$TransactionId,

        [Parameter()]
        [switch]$Latest,

        [Parameter()]
        [switch]$All,

        [Parameter()]
        [switch]$WhatIf
    )

    # Reverting registry values under HKLM and service configuration needs
    # administrator rights. The watchdog already handles that by re-entering
    # through the CLI elevated, and rollback does the same, so a restore asked
    # for from an ordinary shell completes rather than failing quietly behind
    # SilentlyContinue while the caller reports that it succeeded.
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin -and -not $WhatIf) {
        try {
            $scriptRoot = Split-Path -Parent $PSScriptRoot
            $cliScript = Join-Path $scriptRoot "fedupdate.ps1"
            $scope = if ($All) { "-All" }
                     elseif ($TransactionId) { "-TransactionId `"$TransactionId`"" }
                     else { "-Latest" }

            Write-FedLog "Rollback needs administrator rights. Requesting elevation..." -Level "INFO" -Component "Rollback"
            $p = Start-Process -FilePath "powershell.exe" -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$cliScript`" rollback $scope" -Verb RunAs -PassThru -Wait -WindowStyle Hidden -ErrorAction Stop
            if ($null -ne $p -and $p.ExitCode -eq 0) {
                Write-FedLog "Elevated rollback completed successfully." -Level "SUCCESS" -Component "Rollback"
                return $true
            }
            Write-FedLog "The elevated rollback did not complete successfully." -Level "ERROR" -Component "Rollback"
            return $false
        } catch {
            # A declined prompt is an answer, not a failure to work around.
            Write-FedLog "Elevation was not granted ($($_.Exception.Message)). Nothing has been reverted; changes under HKLM need an elevated session." -Level "ERROR" -Component "Rollback"
            return $false
        }
    }

    $ledger = @(Get-FedLedger)
    if ($ledger.Count -eq 0) {
        Write-FedLog "No state ledger entries found to rollback." -Level "WARN" -Component "Rollback"
        return $false
    }

    $targets = @()
    if ($TransactionId) {
        $targets = @($ledger | Where-Object { $_.Id -eq $TransactionId })
    } elseif ($Latest) {
        $targets = @($ledger[-1])
    } elseif ($All) {
        # Undoing everything means putting each setting back to how it was before
        # this application first touched it. That is one value per setting, not
        # one per time it was written. The shield re-applies the same handful of
        # settings on every run and on a timer, so a ledger accumulates thousands
        # of records of the same values, and replaying them one by one turned an
        # uninstall into tens of thousands of registry writes that all end at the
        # same place. The earliest record of each setting is the original, and
        # applying that once is the whole of the work.
        $seen = @{}
        $collapsed = @()
        foreach ($tx in $ledger) {
            foreach ($ch in @($tx.Changes)) {
                $key = switch ($ch.Type) {
                    "Registry"      { "reg|$($ch.KeyPath)|$($ch.ValueName)" }
                    "Service"       { "svc|$($ch.ServiceName)" }
                    "ScheduledTask" { "task|$($ch.TaskName)|$($ch.TaskPath)" }
                    "File"          { "file|$($ch.OriginalPath)" }
                    Default         { "other|$($ch.Type)|$([string]$ch)" }
                }
                if (-not $seen.ContainsKey($key)) {
                    $seen[$key] = $true
                    $collapsed += $ch
                }
            }
        }

        Write-FedLog "Collapsed $($ledger.Count) recorded transactions into $($collapsed.Count) setting(s) to put back." -Level "INFO" -Component "Rollback"
        $targets = @([PSCustomObject]@{
            Id          = "collapsed-all"
            Description = "Every setting returned to how it was first found"
            Changes     = $collapsed
        })
    } else {
        $targets = @($ledger[-1])
    }

    if ($targets.Count -eq 0) {
        Write-FedLog "Specified transaction '$TransactionId' not found in ledger." -Level "ERROR" -Component "Rollback"
        return $false
    }

    Write-FedLog "Starting Rollback for $($targets.Count) transaction(s)..." -Level "INFO" -Component "Rollback"

    foreach ($tx in $targets) {
        Write-FedLog "Reverting Transaction '$($tx.Id)': $($tx.Description)" -Level "INFO" -Component "Rollback"
        
        # Reverse changes in transaction
        $changes = [array]$tx.Changes
        for ($i = $changes.Count - 1; $i -ge 0; $i--) {
            $ch = $changes[$i]
            switch ($ch.Type) {
                "Registry" {
                    if ($WhatIf) {
                        Write-FedLog "[WHATIF] Would revert Registry [$($ch.KeyPath)] '$($ch.ValueName)' -> Original: '$($ch.OriginalValue)' (Existed: $($ch.ExistedBefore))" -Level "WHATIF" -Component "Rollback"
                    } else {
                        try {
                            # A re-enforcement records the value it was already at.
                            # Reverting such an entry would write the enforced value
                            # back, undoing a newer transaction that correctly
                            # removed it. Nothing changed, so nothing is reverted.
                            if ($ch.ExistedBefore -eq $true -and $ch.OriginalValue -eq $ch.NewValue) {
                                Write-FedLog "Skipped [$($ch.KeyPath)] '$($ch.ValueName)': value was unchanged by this transaction." -Level "INFO" -Component "Rollback"
                            } elseif ($ch.ExistedBefore -eq $false -or $null -eq $ch.OriginalValue) {
                                Remove-ItemProperty -Path $ch.KeyPath -Name $ch.ValueName -ErrorAction SilentlyContinue | Out-Null
                                Write-FedLog "Removed Registry property [$($ch.KeyPath)] '$($ch.ValueName)'" -Level "SUCCESS" -Component "Rollback"
                            } else {
                                # Ledgers written before the hive fix carry no
                                # OriginalType for HKCU values. Infer the kind from
                                # the recorded value rather than failing the restore
                                # and leaving policy behind.
                                $restoreType = $ch.OriginalType
                                if ([string]::IsNullOrWhiteSpace($restoreType)) {
                                    $restoreType = if ($ch.PSObject.Properties['NewType'] -and -not [string]::IsNullOrWhiteSpace($ch.NewType)) {
                                        $ch.NewType
                                    } elseif ($ch.OriginalValue -is [int] -or $ch.OriginalValue -is [long]) {
                                        "DWord"
                                    } else {
                                        "String"
                                    }
                                    Write-FedLog "No recorded value kind for [$($ch.KeyPath)] '$($ch.ValueName)'; restoring as $restoreType." -Level "WARN" -Component "Rollback"
                                }
                                Set-ItemProperty -Path $ch.KeyPath -Name $ch.ValueName -Value $ch.OriginalValue -Type $restoreType -Force | Out-Null
                                Write-FedLog "Restored Registry property [$($ch.KeyPath)] '$($ch.ValueName)' = '$($ch.OriginalValue)'" -Level "SUCCESS" -Component "Rollback"
                            }
                        } catch {
                            Write-FedLog "Failed to rollback registry [$($ch.KeyPath)] '$($ch.ValueName)': $_" -Level "ERROR" -Component "Rollback"
                        }
                    }
                }
                "Service" {
                    if ($WhatIf) {
                        Write-FedLog "[WHATIF] Would restore Service '$($ch.ServiceName)' StartType -> '$($ch.OriginalStartType)'" -Level "WHATIF" -Component "Rollback"
                    } else {
                        try {
                            if ($ch.OriginalStartType -eq $ch.NewStartType) {
                                Write-FedLog "Skipped Service '$($ch.ServiceName)': start type was unchanged by this transaction." -Level "INFO" -Component "Rollback"
                            } elseif ($ch.OriginalStartType -ne "Unknown") {
                                Set-Service -Name $ch.ServiceName -StartupType $ch.OriginalStartType -ErrorAction SilentlyContinue
                                if ($ch.OriginalStatus -eq "Running") {
                                    Start-Service -Name $ch.ServiceName -ErrorAction SilentlyContinue
                                }
                                Write-FedLog "Restored Service '$($ch.ServiceName)' -> StartupType: $($ch.OriginalStartType)" -Level "SUCCESS" -Component "Rollback"
                            }
                        } catch {
                            Write-FedLog "Failed to rollback service '$($ch.ServiceName)': $_" -Level "ERROR" -Component "Rollback"
                        }
                    }
                }
                "ScheduledTask" {
                    if ($WhatIf) {
                        Write-FedLog "[WHATIF] Would restore Scheduled Task '$($ch.TaskPath)$($ch.TaskName)' -> '$($ch.OriginalState)'" -Level "WHATIF" -Component "Rollback"
                    } else {
                        try {
                            if ($ch.OriginalState -eq $ch.NewState) {
                                Write-FedLog "Skipped Scheduled Task '$($ch.TaskPath)$($ch.TaskName)': state was unchanged by this transaction." -Level "INFO" -Component "Rollback"
                            } elseif ($ch.OriginalState -eq "Ready" -or $ch.OriginalState -eq "Running") {
                                Enable-ScheduledTask -TaskPath $ch.TaskPath -TaskName $ch.TaskName -ErrorAction SilentlyContinue | Out-Null
                            } elseif ($ch.OriginalState -eq "Disabled") {
                                Disable-ScheduledTask -TaskPath $ch.TaskPath -TaskName $ch.TaskName -ErrorAction SilentlyContinue | Out-Null
                            }
                            Write-FedLog "Restored Scheduled Task '$($ch.TaskPath)$($ch.TaskName)' -> $($ch.OriginalState)" -Level "SUCCESS" -Component "Rollback"
                        } catch {
                            Write-FedLog "Failed to rollback scheduled task '$($ch.TaskPath)$($ch.TaskName)': $_" -Level "ERROR" -Component "Rollback"
                        }
                    }
                }
                "File" {
                    if ($WhatIf) {
                        Write-FedLog "[WHATIF] Would restore File from backup '$($ch.BackupPath)' -> '$($ch.OriginalPath)'" -Level "WHATIF" -Component "Rollback"
                    } else {
                        try {
                            if (Test-Path $ch.BackupPath) {
                                Copy-Item -Path $ch.BackupPath -Destination $ch.OriginalPath -Force
                                Write-FedLog "Restored File '$($ch.OriginalPath)' from '$($ch.BackupPath)'" -Level "SUCCESS" -Component "Rollback"
                            }
                        } catch {
                            Write-FedLog "Failed to restore file '$($ch.OriginalPath)': $_" -Level "ERROR" -Component "Rollback"
                        }
                    }
                }
            }
        }
    }

    Write-FedLog "Rollback operation completed." -Level "SUCCESS" -Component "Rollback"
    return $true
}

Export-ModuleMember -Function Get-FedLedgerFile, Get-FedBackupDirectory, Get-FedLedger, Save-FedLedger, New-FedTransaction, Record-FedRegistryChange, Record-FedServiceChange, Record-FedTaskChange, Record-FedFileBackup, Commit-FedTransaction, Restore-FedState -ErrorAction SilentlyContinue
