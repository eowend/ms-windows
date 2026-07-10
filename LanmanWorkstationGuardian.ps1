<#
.SYNOPSIS
Diagnoses, repairs, and keeps the Windows Workstation service running.

.DESCRIPTION
This script:

- Configures LanmanWorkstation as Automatic.
- Repairs the registry Start value.
- Disables DelayedAutoStart.
- Configures automatic service recovery.
- Checks and starts service dependencies.
- Verifies required service files.
- Searches for scheduled tasks that may stop the service.
- Searches local scripts for references that may stop or disable the service.
- Reviews recent service-related Windows events.
- Generates a Group Policy Results report.
- Creates a watchdog process running as SYSTEM.
- Checks the service every 500 milliseconds.
- Re-enables the service if another process disables it.
- Restarts the service if it stops.

.NOTES
Author: Juan Ortiz
Company: KOX
Version: 1.1.0
Date: 2026-07-10

Run usiging:

Set-ExecutionPolicy Bypass -Scope Process -Force
.\LanmanWorkstationGuardian.ps1 -Mode Install


#>

[CmdletBinding()]
param(
    [ValidateSet(
        'Install',
        'Watchdog',
        'Diagnose',
        'Remove'
    )]
    [string]$Mode = 'Diagnose',

    [switch]$RunSystemRepair
)

$ErrorActionPreference = 'Continue'

$ServiceName = 'LanmanWorkstation'
$ServiceDisplayName = 'Workstation'

$InstallDirectory = 'C:\ProgramData\KOX\LanmanWorkstationGuardian'
$InstalledScript = Join-Path $InstallDirectory 'LanmanWorkstationGuardian.ps1'
$LogDirectory = Join-Path $InstallDirectory 'Logs'
$LogFile = Join-Path $LogDirectory 'LanmanWorkstationGuardian.log'
$ReportFile = Join-Path $LogDirectory 'LanmanWorkstation-Diagnostic.txt'
$GPResultFile = Join-Path $LogDirectory 'GPResult-Computer.html'

$TaskName = 'KOX - LanmanWorkstation Guardian'
$MutexName = 'Global\KOX-LanmanWorkstationGuardian'

function Initialize-Directories {
    foreach ($Directory in @($InstallDirectory, $LogDirectory)) {
        if (-not (Test-Path $Directory)) {
            New-Item -Path $Directory -ItemType Directory -Force |
                Out-Null
        }
    }
}

function Write-GuardianLog {
    param(
        [Parameter(Mandatory)]
        [string]$Message,

        [ValidateSet('INFO', 'WARNING', 'ERROR', 'REMEDIATION')]
        [string]$Level = 'INFO'
    )

    Initialize-Directories

    $Timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
    $Entry = "[$Timestamp] [$Level] $Message"

    Add-Content -Path $LogFile -Value $Entry -Encoding UTF8

    if ($Mode -ne 'Watchdog') {
        Write-Host $Entry
    }
}

function Test-IsAdministrator {
    $Identity = [Security.Principal.WindowsIdentity]::GetCurrent()

    $Principal = New-Object Security.Principal.WindowsPrincipal(
        $Identity
    )

    return $Principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )
}

function Assert-Administrator {
    if (-not (Test-IsAdministrator)) {
        throw 'This script must be run as administrator.'
    }
}

function Get-WorkstationServiceInformation {
    try {
        return Get-CimInstance Win32_Service `
            -Filter "Name='$ServiceName'" `
            -ErrorAction Stop
    }
    catch {
        Write-GuardianLog `
            -Message "Unable to query $ServiceName. $($_.Exception.Message)" `
            -Level ERROR

        return $null
    }
}

function Get-ServiceRegistryStartValue {
    $RegistryPath = "HKLM:\SYSTEM\CurrentControlSet\Services\$ServiceName"

    try {
        return Get-ItemPropertyValue `
            -Path $RegistryPath `
            -Name Start `
            -ErrorAction Stop
    }
    catch {
        return $null
    }
}

function Set-ServiceAutomatic {
    $RegistryPath = "HKLM:\SYSTEM\CurrentControlSet\Services\$ServiceName"

    try {
        $Service = Get-WorkstationServiceInformation

        if (-not $Service) {
            return
        }

        if ($Service.StartMode -ne 'Auto') {
            Set-Service `
                -Name $ServiceName `
                -StartupType Automatic `
                -ErrorAction Stop

            Write-GuardianLog `
                -Message "$ServiceName was configured as Automatic." `
                -Level REMEDIATION
        }

        $StartValue = Get-ServiceRegistryStartValue

        if ($StartValue -ne 2) {
            Set-ItemProperty `
                -Path $RegistryPath `
                -Name Start `
                -Type DWord `
                -Value 2 `
                -Force `
                -ErrorAction Stop

            Write-GuardianLog `
                -Message "The registry Start value was changed from $StartValue to 2." `
                -Level REMEDIATION
        }

        $DelayedAutoStart = Get-ItemProperty `
            -Path $RegistryPath `
            -Name DelayedAutoStart `
            -ErrorAction SilentlyContinue

        if ($null -ne $DelayedAutoStart) {
            if ($DelayedAutoStart.DelayedAutoStart -ne 0) {
                Set-ItemProperty `
                    -Path $RegistryPath `
                    -Name DelayedAutoStart `
                    -Type DWord `
                    -Value 0 `
                    -Force

                Write-GuardianLog `
                    -Message 'DelayedAutoStart was disabled.' `
                    -Level REMEDIATION
            }
        }
    }
    catch {
        Write-GuardianLog `
            -Message "Unable to configure automatic startup. $($_.Exception.Message)" `
            -Level ERROR
    }
}

function Set-ServiceRecoveryConfiguration {
    try {
        & sc.exe failure $ServiceName `
            reset= 86400 `
            actions= restart/1000/restart/1000/restart/1000 |
            Out-Null

        & sc.exe failureflag $ServiceName 1 |
            Out-Null

        Write-GuardianLog `
            -Message 'Three automatic service restarts were configured with a one-second delay.' `
            -Level REMEDIATION
    }
    catch {
        Write-GuardianLog `
            -Message "Unable to configure service recovery. $($_.Exception.Message)" `
            -Level ERROR
    }
}

function Repair-ServiceDependencies {
    try {
        $Service = Get-Service `
            -Name $ServiceName `
            -ErrorAction Stop

        foreach ($Dependency in $Service.ServicesDependedOn) {
            try {
                $DependencyCim = Get-CimInstance Win32_Service `
                    -Filter "Name='$($Dependency.Name)'" `
                    -ErrorAction SilentlyContinue

                if (
                    $DependencyCim -and
                    $DependencyCim.StartMode -eq 'Disabled'
                ) {
                    Set-Service `
                        -Name $Dependency.Name `
                        -StartupType Automatic `
                        -ErrorAction Stop

                    Write-GuardianLog `
                        -Message "Dependency $($Dependency.Name) was disabled and was changed to Automatic." `
                        -Level REMEDIATION
                }

                $Dependency.Refresh()

                if ($Dependency.Status -ne 'Running') {
                    Start-Service `
                        -Name $Dependency.Name `
                        -ErrorAction Stop

                    Write-GuardianLog `
                        -Message "Dependency $($Dependency.Name) was started." `
                        -Level REMEDIATION
                }
            }
            catch {
                Write-GuardianLog `
                    -Message "Unable to repair dependency $($Dependency.Name). $($_.Exception.Message)" `
                    -Level WARNING
            }
        }
    }
    catch {
        Write-GuardianLog `
            -Message "Unable to review service dependencies. $($_.Exception.Message)" `
            -Level ERROR
    }
}

function Test-ServiceFiles {
    $Files = @(
        "$env:SystemRoot\System32\wkssvc.dll",
        "$env:SystemRoot\System32\svchost.exe",
        "$env:SystemRoot\System32\drivers\mrxsmb.sys",
        "$env:SystemRoot\System32\drivers\mrxsmb20.sys",
        "$env:SystemRoot\System32\drivers\rdbss.sys"
    )

    foreach ($File in $Files) {
        if (Test-Path $File) {
            Write-GuardianLog `
                -Message "Required file found: $File"
        }
        else {
            Write-GuardianLog `
                -Message "Required file not found: $File" `
                -Level ERROR
        }
    }
}

function Start-WorkstationService {
    Set-ServiceAutomatic
    Repair-ServiceDependencies

    try {
        $Service = Get-Service `
            -Name $ServiceName `
            -ErrorAction Stop

        if ($Service.Status -ne 'Running') {
            Start-Service `
                -Name $ServiceName `
                -ErrorAction Stop

            Start-Sleep -Milliseconds 300

            $Service.Refresh()

            if ($Service.Status -eq 'Running') {
                Write-GuardianLog `
                    -Message "$ServiceDisplayName was started successfully." `
                    -Level REMEDIATION
            }
            else {
                Write-GuardianLog `
                    -Message "$ServiceDisplayName did not remain running after the start attempt." `
                    -Level ERROR
            }
        }
    }
    catch {
        Write-GuardianLog `
            -Message "Failed to start $ServiceDisplayName. $($_.Exception.Message)" `
            -Level ERROR
    }
}

function Find-SuspiciousScheduledTasks {
    Write-GuardianLog `
        -Message 'Searching for scheduled tasks that may stop the service.'

    try {
        $Results = foreach ($Task in Get-ScheduledTask -ErrorAction SilentlyContinue) {
            foreach ($Action in $Task.Actions) {
                $ActionText = "$($Action.Execute) $($Action.Arguments)"

                if (
                    $ActionText -match '(?i)LanmanWorkstation' -or
                    $ActionText -match '(?i)Stop-Service.+Workstation' -or
                    $ActionText -match '(?i)sc(\.exe)?\s+stop\s+(LanmanWorkstation|Workstation)' -or
                    $ActionText -match '(?i)net\s+stop\s+(LanmanWorkstation|Workstation)' -or
                    $ActionText -match '(?i)Set-Service.+Disabled'
                ) {
                    [PSCustomObject]@{
                        TaskPath  = $Task.TaskPath
                        TaskName  = $Task.TaskName
                        State     = $Task.State
                        Execute   = $Action.Execute
                        Arguments = $Action.Arguments
                    }
                }
            }
        }

        if ($Results) {
            $Results |
                Format-List |
                Out-String |
                Add-Content -Path $ReportFile

            foreach ($Result in $Results) {
                Write-GuardianLog `
                    -Message "Suspicious scheduled task found: $($Result.TaskPath)$($Result.TaskName) | $($Result.Execute) $($Result.Arguments)" `
                    -Level WARNING
            }
        }
        else {
            Write-GuardianLog `
                -Message 'No local scheduled tasks referencing the service were found.'
        }
    }
    catch {
        Write-GuardianLog `
            -Message "Unable to review scheduled tasks. $($_.Exception.Message)" `
            -Level WARNING
    }
}

function Find-SuspiciousLocalScripts {
    Write-GuardianLog `
        -Message 'Searching for local scripts that may stop the service.'

    $SearchPaths = @(
        'C:\Scripts',
        'C:\ProgramData',
        "$env:SystemRoot\System32\GroupPolicy",
        "$env:SystemRoot\System32\GroupPolicyUsers"
    )

    $ExistingPaths = $SearchPaths |
        Where-Object { Test-Path $_ }

    try {
        $Files = Get-ChildItem `
            -Path $ExistingPaths `
            -Recurse `
            -File `
            -Include *.ps1, *.cmd, *.bat, *.vbs `
            -ErrorAction SilentlyContinue

        $Matches = $Files |
            Select-String `
                -Pattern @(
                    'LanmanWorkstation',
                    'Stop-Service.+Workstation',
                    'sc(\.exe)?\s+stop\s+(LanmanWorkstation|Workstation)',
                    'net\s+stop\s+(LanmanWorkstation|Workstation)',
                    'Set-Service.+Disabled'
                ) `
                -ErrorAction SilentlyContinue

        if ($Matches) {
            $Matches |
                Select-Object Path, LineNumber, Line |
                Format-Table -AutoSize |
                Out-String |
                Add-Content -Path $ReportFile

            foreach ($Match in $Matches) {
                Write-GuardianLog `
                    -Message "Suspicious reference found: $($Match.Path):$($Match.LineNumber)" `
                    -Level WARNING
            }
        }
        else {
            Write-GuardianLog `
                -Message 'No suspicious references were found in the reviewed local scripts.'
        }
    }
    catch {
        Write-GuardianLog `
            -Message "Unable to review local scripts. $($_.Exception.Message)" `
            -Level WARNING
    }
}

function Export-ServiceEvents {
    Write-GuardianLog `
        -Message 'Exporting recent service-related events.'

    try {
        $Events = Get-WinEvent `
            -FilterHashtable @{
                LogName   = 'System'
                StartTime = (Get-Date).AddDays(-3)
            } `
            -ErrorAction SilentlyContinue |
            Where-Object {
                (
                    $_.ProviderName -eq 'Service Control Manager' -or
                    $_.ProviderName -eq 'Microsoft-Windows-GroupPolicy'
                ) -and
                (
                    $_.Message -match '(?i)Workstation' -or
                    $_.Message -match '(?i)LanmanWorkstation'
                )
            } |
            Select-Object `
                TimeCreated,
                Id,
                LevelDisplayName,
                ProviderName,
                Message

        if ($Events) {
            $Events |
                Format-List |
                Out-String |
                Add-Content -Path $ReportFile

            Write-GuardianLog `
                -Message "$($Events.Count) related events were added to the diagnostic report."
        }
        else {
            Write-GuardianLog `
                -Message 'No recent related events were found.'
        }
    }
    catch {
        Write-GuardianLog `
            -Message "Unable to export Windows events. $($_.Exception.Message)" `
            -Level WARNING
    }
}

function Export-GroupPolicyReport {
    try {
        Write-GuardianLog `
            -Message 'Generating the Group Policy Results report.'

        & gpresult.exe `
            /Scope Computer `
            /H $GPResultFile `
            /F |
            Out-Null

        if (Test-Path $GPResultFile) {
            Write-GuardianLog `
                -Message "Group Policy report created: $GPResultFile"
        }
        else {
            Write-GuardianLog `
                -Message 'GPResult did not create the expected report file.' `
                -Level WARNING
        }
    }
    catch {
        Write-GuardianLog `
            -Message "Unable to generate the Group Policy report. $($_.Exception.Message)" `
            -Level WARNING
    }
}

function Export-ServiceConfiguration {
    $Service = Get-WorkstationServiceInformation
    $RegistryPath = "HKLM:\SYSTEM\CurrentControlSet\Services\$ServiceName"

    "============================================================" |
        Set-Content -Path $ReportFile -Encoding UTF8

    "LanmanWorkstation Diagnostic Report" |
        Add-Content -Path $ReportFile

    "Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" |
        Add-Content -Path $ReportFile

    "Computer: $env:COMPUTERNAME" |
        Add-Content -Path $ReportFile

    "Domain: $env:USERDOMAIN" |
        Add-Content -Path $ReportFile

    "============================================================`r`n" |
        Add-Content -Path $ReportFile

    if ($Service) {
        $Service |
            Select-Object `
                Name,
                DisplayName,
                State,
                StartMode,
                ExitCode,
                ServiceSpecificExitCode,
                ProcessId,
                PathName |
            Format-List |
            Out-String |
            Add-Content -Path $ReportFile
    }

    "`r`nRegistry configuration:" |
        Add-Content -Path $ReportFile

    Get-ItemProperty `
        -Path $RegistryPath `
        -ErrorAction SilentlyContinue |
        Format-List |
        Out-String |
        Add-Content -Path $ReportFile

    "`r`nSC.EXE QC output:" |
        Add-Content -Path $ReportFile

    & sc.exe qc $ServiceName 2>&1 |
        Out-String |
        Add-Content -Path $ReportFile

    "`r`nSC.EXE QUERYEX output:" |
        Add-Content -Path $ReportFile

    & sc.exe queryex $ServiceName 2>&1 |
        Out-String |
        Add-Content -Path $ReportFile

    "`r`nDependencies:" |
        Add-Content -Path $ReportFile

    Get-Service -Name $ServiceName -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty ServicesDependedOn |
        Format-Table Name, Status, StartType -AutoSize |
        Out-String |
        Add-Content -Path $ReportFile
}

function Invoke-WindowsSystemRepair {
    Write-GuardianLog `
        -Message 'Running DISM RestoreHealth. This process may consume system resources.'

    try {
        & DISM.exe `
            /Online `
            /Cleanup-Image `
            /RestoreHealth |
            Tee-Object `
                -FilePath (Join-Path $LogDirectory 'DISM-RestoreHealth.log') |
            Out-Null

        Write-GuardianLog `
            -Message 'DISM RestoreHealth completed.'
    }
    catch {
        Write-GuardianLog `
            -Message "DISM failed. $($_.Exception.Message)" `
            -Level ERROR
    }

    Write-GuardianLog `
        -Message 'Running SFC Scannow.'

    try {
        & sfc.exe /scannow |
            Tee-Object `
                -FilePath (Join-Path $LogDirectory 'SFC-Scannow.log') |
            Out-Null

        Write-GuardianLog `
            -Message 'SFC Scannow completed.'
    }
    catch {
        Write-GuardianLog `
            -Message "SFC failed. $($_.Exception.Message)" `
            -Level ERROR
    }
}

function Install-GuardianScheduledTask {
    try {
        $PowerShellArguments = @(
            '-NoLogo'
            '-NoProfile'
            '-NonInteractive'
            '-ExecutionPolicy Bypass'
            "-File `"$InstalledScript`""
            '-Mode Watchdog'
        ) -join ' '

        $Action = New-ScheduledTaskAction `
            -Execute 'PowerShell.exe' `
            -Argument $PowerShellArguments

        $Trigger = New-ScheduledTaskTrigger -AtStartup

        $Principal = New-ScheduledTaskPrincipal `
            -UserId 'SYSTEM' `
            -LogonType ServiceAccount `
            -RunLevel Highest

        $Settings = New-ScheduledTaskSettingsSet `
            -AllowStartIfOnBatteries `
            -DontStopIfGoingOnBatteries `
            -StartWhenAvailable `
            -ExecutionTimeLimit ([TimeSpan]::Zero) `
            -RestartCount 999 `
            -RestartInterval (New-TimeSpan -Minutes 1) `
            -MultipleInstances IgnoreNew

        Register-ScheduledTask `
            -TaskName $TaskName `
            -Action $Action `
            -Trigger $Trigger `
            -Principal $Principal `
            -Settings $Settings `
            -Description 'Maintains the Windows Workstation service in a running and automatic state.' `
            -Force |
            Out-Null

        Write-GuardianLog `
            -Message "Scheduled task created: $TaskName" `
            -Level REMEDIATION

        Start-ScheduledTask `
            -TaskName $TaskName `
            -ErrorAction Stop

        Write-GuardianLog `
            -Message 'The watchdog was started as SYSTEM.' `
            -Level REMEDIATION
    }
    catch {
        Write-GuardianLog `
            -Message "Unable to create or start the scheduled task. $($_.Exception.Message)" `
            -Level ERROR
    }
}

function Install-Guardian {
    Assert-Administrator
    Initialize-Directories

    Write-GuardianLog `
        -Message 'Starting installation and remediation.'

    $CurrentScript = $MyInvocation.ScriptName

    if (
        -not $CurrentScript -or
        -not (Test-Path $CurrentScript)
    ) {
        throw 'Save the script as a .ps1 file before installing it.'
    }

    $ResolvedCurrentScript = (Resolve-Path $CurrentScript).Path

    if ($ResolvedCurrentScript -ne $InstalledScript) {
        Copy-Item `
            -Path $ResolvedCurrentScript `
            -Destination $InstalledScript `
            -Force

        Write-GuardianLog `
            -Message "Script installed at $InstalledScript"
    }

    Export-ServiceConfiguration
    Test-ServiceFiles
    Find-SuspiciousScheduledTasks
    Find-SuspiciousLocalScripts
    Export-ServiceEvents
    Export-GroupPolicyReport

    Set-ServiceAutomatic
    Set-ServiceRecoveryConfiguration
    Repair-ServiceDependencies
    Start-WorkstationService

    if ($RunSystemRepair) {
        Invoke-WindowsSystemRepair
        Start-WorkstationService
    }

    Install-GuardianScheduledTask

    Write-GuardianLog `
        -Message 'Installation completed.'

    Write-Host ''
    Write-Host "Log: $LogFile"
    Write-Host "Diagnostic report: $ReportFile"
    Write-Host "Group Policy report: $GPResultFile"
}

function Start-GuardianWatchdog {
    Initialize-Directories

    $CreatedNew = $false

    $Mutex = New-Object System.Threading.Mutex(
        $true,
        $MutexName,
        [ref]$CreatedNew
    )

    if (-not $CreatedNew) {
        exit 0
    }

    Write-GuardianLog `
        -Message 'Watchdog started as a persistent process.'

    $LastKnownStartValue = $null
    $LastKnownStatus = $null
    $LastEnforcement = [DateTime]::MinValue
    $ConsecutiveFailures = 0

    try {
        while ($true) {
            try {
                $CurrentStartValue = Get-ServiceRegistryStartValue
                $Service = Get-Service `
                    -Name $ServiceName `
                    -ErrorAction Stop

                if ($CurrentStartValue -ne $LastKnownStartValue) {
                    Write-GuardianLog `
                        -Message "The registry Start value changed from $LastKnownStartValue to $CurrentStartValue." `
                        -Level WARNING

                    $LastKnownStartValue = $CurrentStartValue
                }

                if ($Service.Status -ne $LastKnownStatus) {
                    Write-GuardianLog `
                        -Message "The service status changed from $LastKnownStatus to $($Service.Status)."

                    $LastKnownStatus = $Service.Status
                }

                if ($CurrentStartValue -ne 2) {
                    Set-ServiceAutomatic
                    $LastKnownStartValue = 2
                }

                if ($Service.Status -ne 'Running') {
                    Write-GuardianLog `
                        -Message "The service was found in state $($Service.Status). Attempting to start it." `
                        -Level WARNING

                    Start-WorkstationService

                    Start-Sleep -Milliseconds 250

                    $Service = Get-Service `
                        -Name $ServiceName `
                        -ErrorAction SilentlyContinue

                    if ($Service.Status -eq 'Running') {
                        $ConsecutiveFailures = 0
                        $LastKnownStatus = 'Running'
                    }
                    else {
                        $ConsecutiveFailures++

                        Write-GuardianLog `
                            -Message "The service did not remain running. Consecutive failures: $ConsecutiveFailures." `
                            -Level ERROR
                    }
                }
                else {
                    $ConsecutiveFailures = 0
                }

                if (
                    ((Get-Date) - $LastEnforcement).TotalSeconds -ge 30
                ) {
                    Set-ServiceAutomatic
                    Set-ServiceRecoveryConfiguration
                    $LastEnforcement = Get-Date
                }
            }
            catch {
                Write-GuardianLog `
                    -Message "Error inside the watchdog loop. $($_.Exception.Message)" `
                    -Level ERROR
            }

            Start-Sleep -Milliseconds 500
        }
    }
    finally {
        if ($Mutex) {
            $Mutex.ReleaseMutex()
            $Mutex.Dispose()
        }
    }
}

function Invoke-Diagnosis {
    Assert-Administrator
    Initialize-Directories

    Write-GuardianLog `
        -Message 'Starting manual diagnosis.'

    Export-ServiceConfiguration
    Test-ServiceFiles
    Find-SuspiciousScheduledTasks
    Find-SuspiciousLocalScripts
    Export-ServiceEvents
    Export-GroupPolicyReport

    Write-GuardianLog `
        -Message 'Diagnosis completed.'

    Write-Host ''
    Write-Host "Diagnostic report: $ReportFile"
    Write-Host "Group Policy report: $GPResultFile"
    Write-Host "Log: $LogFile"
}

function Remove-Guardian {
    Assert-Administrator

    Write-GuardianLog `
        -Message 'Removing the watchdog.'

    try {
        Stop-ScheduledTask `
            -TaskName $TaskName `
            -ErrorAction SilentlyContinue

        Unregister-ScheduledTask `
            -TaskName $TaskName `
            -Confirm:$false `
            -ErrorAction SilentlyContinue

        Write-GuardianLog `
            -Message "Scheduled task removed: $TaskName" `
            -Level REMEDIATION
    }
    catch {
        Write-GuardianLog `
            -Message "Unable to remove the scheduled task. $($_.Exception.Message)" `
            -Level ERROR
    }

    Write-Host ''
    Write-Host 'The watchdog was removed.'
    Write-Host "Logs remain available at: $InstallDirectory"
}

try {
    switch ($Mode) {
        'Install' {
            Install-Guardian
        }

        'Watchdog' {
            Start-GuardianWatchdog
        }

        'Diagnose' {
            Invoke-Diagnosis
        }

        'Remove' {
            Remove-Guardian
        }
    }
}
catch {
    Write-GuardianLog `
        -Message $_.Exception.Message `
        -Level ERROR

    throw
}
