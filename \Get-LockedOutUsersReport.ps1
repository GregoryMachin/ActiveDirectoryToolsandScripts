<#
.SYNOPSIS
    Generates a CSV report of Active Directory user accounts that are currently locked out or have a historical non‑zero LockoutTime, conforming to GDMTT PowerShell scripting standards.

.DESCRIPTION
    The script performs two Active Directory queries to capture every relevant account:
        1. `Search‑ADAccount -LockedOut` – returns accounts locked right now.
        2. `Get‑ADUser -Filter 'LockoutTime -gt 0'` – returns accounts that have ever been locked.

    The results are merged and deduplicated on **DistinguishedName**. A human‑readable report is exported to
    **C:\Users\<username>\git-cache\data** with a timestamped name `<FileBaseName>_YY_MM_DD_HH-MM.csv`.

    **Columns in the report**
        • GivenName
        • Surname
        • Email (mail)
        • Manager (GivenName Surname | DisplayName | CN fallback)
        • Enabled (True/False)
        • LockedOut (True if locked at runtime)
        • LockoutTimeUTC  – LockoutTime converted from FILETIME to UTC
        • LockoutTimeNZT  – LockoutTimeUTC shifted +12 hours (static New Zealand offset)
        • LastWeek        – True if **LockoutTimeNZT** is within the past 7 days
        • LastDay         – True if **LockoutTimeNZT** is within the past 24 hours
        • LastHour        – True if **LockoutTimeNZT** is within the past 60 minutes

    The final CSV is sorted by **LockoutTimeNZT** (newest → oldest) and then by Surname, GivenName.

    A log file is written to **C:\ProgramData\GDMTT\Logs** using the required format
        `YYYYMMDD HH:MM:SS <username> <Type> <Message>`
    Existing reports with the same timestamp are first moved to the Backup directory.

.PARAMETER FileBaseName
    The base name for the report file (without extension or timestamp). Default is "LockedOutUsers".

.PARAMETER DataDir
    Directory where the CSV report will be written. Default is the standard GDMTT data path under the current user profile.

.EXAMPLE
    # Run with defaults
    .\Get-LockedOutUsersReport.ps1

    # Specify a custom data directory
    .\Get-LockedOutUsersReport.ps1 -DataDir 'D:\Reports'

.NOTES
    Requires the ActiveDirectory module (RSAT) and connectivity to a writable DC.
    Folder structure created if missing:
        C:\ProgramData\GDMTT\{Logs,Backup,temp,cache}
        C:\Users\<username>\git-cache\data
#>

[CmdletBinding()]
param(
    [string]$FileBaseName = 'LockedOutUsers',
    [string]$DataDir = (Join-Path -Path $env:USERPROFILE -ChildPath 'git-cache\data')
)

function Write-GDMTTLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('Info','Warning','Error','Data')][string]$Type,
        [Parameter(Mandatory)][string]$Message
    )
    $user = try {
        (Get-WmiObject -Class Win32_ComputerSystem -ErrorAction Stop).UserName
    } catch { $env:USERNAME }
    $timestamp = Get-Date -Format 'yyyyMMdd HH:mm:ss'
    $logDir = 'C:\ProgramData\GDMTT\Logs'
    if (-not (Test-Path $logDir)) { New-Item -Path $logDir -ItemType Directory -Force | Out-Null }
    $logPath = Join-Path -Path $logDir -ChildPath 'Get-LockedOutUsersReport.log'
    Add-Content -Path $logPath -Value ("{0} {1} {2} {3}" -f $timestamp, $user, $Type, $Message)
}

function Get-LockedOutUsersReport {
    [CmdletBinding()]
    param(
        [string]$FileBaseName,
        [string]$DataDir,
        [string]$BackupDir = 'C:\ProgramData\GDMTT\Backup',
        [string]$TempDir   = 'C:\ProgramData\GDMTT\temp',
        [string]$CacheDir  = 'C:\ProgramData\GDMTT\cache'
    )

    # Ensure required directories exist
    foreach ($dir in @($DataDir,$BackupDir,$TempDir,$CacheDir)) {
        if (-not (Test-Path $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }
    }

    $timeStamp = Get-Date -Format 'yy_MM_dd_HH-mm'  # ':' not allowed in Windows filenames
    $fileName  = "{0}_{1}.csv" -f $FileBaseName, $timeStamp
    $outputPath = Join-Path -Path $DataDir -ChildPath $fileName

    # Backup existing file with same name (unlikely but safe)
    if (Test-Path $outputPath) {
        $backupPath = Join-Path -Path $BackupDir -ChildPath $fileName
        Move-Item -Path $outputPath -Destination $backupPath -Force
        Write-GglisLog -Type 'Warning' -Message "Existing report moved to backup: $backupPath"
    }

    try {
        Import-Module ActiveDirectory -ErrorAction Stop

        # --- 1. Accounts CURRENTLY locked --------------------------
        $lockedNow = Search-ADAccount -LockedOut -UsersOnly |
                     Get-ADUser -Properties GivenName,Surname,mail,manager,Enabled,LockedOut,LockoutTime

        # --- 2. Accounts EVER locked (includes still‑locked) --------
        $lockedEver = Get-ADUser -Filter 'LockoutTime -gt 0' -Properties GivenName,Surname,mail,manager,Enabled,LockedOut,LockoutTime

        # --- Merge & dedupe ----------------------------------------
        $users = @($lockedNow) + @($lockedEver) |
                 Where-Object { $_ } |
                 Group-Object -Property DistinguishedName |
                 ForEach-Object { $_.Group | Select-Object -First 1 }
    }
    catch {
        Write-GglisLog -Type 'Error' -Message "Failed to query Active Directory: $_"
        throw
    }

    # --- Build report objects --------------------------------------
    $nowUTC = (Get-Date).ToUniversalTime()
    $nowNZT = $nowUTC.AddHours(12)  # Static +12 offset (ignores DST)

    $report = foreach ($u in $users) {
        $managerName = ''
        if ($u.Manager) {
            try {
                $mgr = Get-ADUser -Identity $u.Manager -Properties GivenName,Surname,DisplayName
                if ($mgr) {
                    if ($mgr.GivenName -or $mgr.Surname) {
                        $managerName = ("$($mgr.GivenName) $($mgr.Surname)").Trim()
                    }
                    if (-not $managerName) { $managerName = $mgr.DisplayName }
                }
                if (-not $managerName -and ($u.Manager -match '^CN=([^,]+)')) { $managerName = $matches[1] }
            } catch {
                Write-GglisLog -Type 'Warning' -Message "Could not resolve manager for $($u.SamAccountName): $_"
                if ($u.Manager -match '^CN=([^,]+)') { $managerName = $matches[1] }
            }
        }

        # Convert FILETIME to DateTime (UTC)
        $lockoutDateUTC = if ($u.LockoutTime -gt 0) {
            [DateTime]::FromFileTimeUTC($u.LockoutTime)
        } else { $null }

        # Convert to NZT (+12)
        $lockoutDateNZT = if ($lockoutDateUTC) { $lockoutDateUTC.AddHours(12) } else { $null }

        # Boolean flags relative to NZT
        $lastWeek = $false
        $lastDay  = $false
        $lastHour = $false
        if ($lockoutDateNZT) {
            $lastWeek = ($lockoutDateNZT -gt $nowNZT.AddDays(-7))
            $lastDay  = ($lockoutDateNZT -gt $nowNZT.AddDays(-1))
            $lastHour = ($lockoutDateNZT -gt $nowNZT.AddHours(-1))
        }

        [pscustomobject]@{
            GivenName       = $u.GivenName
            Surname         = $u.Surname
            Email           = $u.mail
            Manager         = $managerName
            Enabled         = $u.Enabled
            LockedOut       = $u.LockedOut
            LockoutTimeUTC  = $lockoutDateUTC
            LockoutTimeNZT  = $lockoutDateNZT
            LastWeek        = $lastWeek
            LastDay         = $lastDay
            LastHour        = $lastHour
        }
    }

    # --- Export -----------------------------------------------------
    try {
        $report |
            Sort-Object -Property @{Expression='LockoutTimeNZT';Descending=$true}, 'Surname', 'GivenName' |
            Export-Csv -Path $outputPath -NoTypeInformation -Encoding UTF8
        Write-GglisLog -Type 'Info' -Message "Report exported to $outputPath"
    }
    catch {
        Write-GglisLog -Type 'Error' -Message "Failed to export CSV: $_"
        throw
    }

    return $outputPath
}

#===================================================================
#                               EXECUTION                          
#===================================================================

try {
    $reportGeneratedPath = Get-LockedOutUsersReport -FileBaseName $FileBaseName -DataDir $DataDir
    Write-Host "Report saved to $reportGeneratedPath"
} catch {
    Write-Error "Report generation failed: $_"
    exit 1
}
