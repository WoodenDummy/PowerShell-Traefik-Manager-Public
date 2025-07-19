# TraefikManager.Backup.psm1
# Backup and restore functionality for Traefik Manager

#Requires -Version 5.1
Set-StrictMode -Version Latest

# --- Backup Creation Functions ---
function Save-ServiceBackup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ServiceName,
        
        [Parameter(Mandatory = $true)]
        [string]$Content,
        
        [Parameter(Mandatory = $false)]
        [string]$BackupSuffix = ""
    )

    try {
        $backupDir = Join-Path (Get-Location) "backups"
        if (-not (Test-Path $backupDir)) {
            New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
            Write-TraefikLog "Created backup directory: $backupDir" -Level "Info"
        }

        $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
        $backupFileName = if ($BackupSuffix) {
            "$ServiceName`_$BackupSuffix`_$timestamp.yml"
        } else {
            "$ServiceName`_$timestamp.yml"
        }
        $backupFile = Join-Path $backupDir $backupFileName

        $Content | Set-Content -Path $backupFile -Encoding UTF8 -ErrorAction Stop
        Write-TraefikLog "Created backup: $backupFile" -Level "Success"
        return $backupFile
    }
    catch {
        Write-TraefikLog "Failed to create backup for $ServiceName`: $($_.Exception.Message)" -Level "Warning"
        return $null
    }
}

# --- Backup Discovery Functions ---
function Get-ServiceBackups {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$ServiceName = $null
    )

    try {
        $backupDir = Join-Path (Get-Location) "backups"
        if (-not (Test-Path $backupDir)) {
            Write-TraefikLog "No backup directory found." -Level "Warning"
            return @()
        }

        $backupFiles = @()
        
        if ($ServiceName) {
            # Get backups for specific service
            $pattern = "$ServiceName`_*.yml"
            $backupFiles = @(Get-ChildItem -Path $backupDir -Filter $pattern -ErrorAction SilentlyContinue)
        } else {
            # Get all service backup files (exclude static config backups)
            $backupFiles = @(Get-ChildItem -Path $backupDir -Filter "*.yml" -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch '^static_config_' })
        }

        $backups = @()
        foreach ($file in $backupFiles) {
            # Parse filename: servicename_[suffix_]yyyyMMdd_HHmmss.yml
            if ($file.Name -match '^(.+?)_(?:(.+?)_)?(\d{8})_(\d{6})\.yml$') {
                $serviceName = $matches[1]
                $suffix = if ($matches[2]) { $matches[2] } else { "" }
                $dateStr = $matches[3]
                $timeStr = $matches[4]
                
                try {
                    $backupDate = [DateTime]::ParseExact("$dateStr$timeStr", "yyyyMMddHHmmss", $null)
                    
                    $backups += [PSCustomObject]@{
                        ServiceName = $serviceName
                        BackupType = if ($suffix) { $suffix } else { "manual" }
                        FileName = $file.Name
                        FilePath = $file.FullName
                        BackupDate = $backupDate
                        FormattedDate = $backupDate.ToString("yyyy-MM-dd HH:mm:ss")
                        SizeKB = [Math]::Round($file.Length / 1KB, 2)
                        ConfigType = "Service"
                    }
                } catch {
                    Write-TraefikLog "Could not parse date from backup file: $($file.Name)" -Level "Warning"
                }
            }
        }

        # Sort by backup date (newest first)
        $backups = @($backups | Sort-Object BackupDate -Descending)
        
        Write-TraefikLog "Found $($backups.Count) service backup files" -Level "Info"
        return $backups
    }
    catch {
        Write-TraefikLog "Error retrieving service backups: $($_.Exception.Message)" -Level "Error"
        return @()
    }
}

function Get-StaticConfigBackups {
    [CmdletBinding()]
    param()

    try {
        $backupDir = Join-Path (Get-Location) "backups"
        if (-not (Test-Path $backupDir)) {
            Write-TraefikLog "No backup directory found." -Level "Warning"
            return @()
        }

        # Get static config backup files
        $backupFiles = @(Get-ChildItem -Path $backupDir -Filter "static_config_*.yaml" -ErrorAction SilentlyContinue)

        $backups = @()
        foreach ($file in $backupFiles) {
            # Parse filename: static_config_[suffix_]yyyyMMdd_HHmmss.yaml
            if ($file.Name -match '^static_config_(?:(.+?)_)?(\d{8})_(\d{6})\.yaml$') {
                $suffix = if ($matches[1]) { $matches[1] } else { "manual" }
                $dateStr = $matches[2]
                $timeStr = $matches[3]
                
                try {
                    $backupDate = [DateTime]::ParseExact("$dateStr$timeStr", "yyyyMMddHHmmss", $null)
                    
                    $backups += [PSCustomObject]@{
                        BackupType = $suffix
                        FileName = $file.Name
                        FilePath = $file.FullName
                        BackupDate = $backupDate
                        FormattedDate = $backupDate.ToString("yyyy-MM-dd HH:mm:ss")
                        SizeKB = [Math]::Round($file.Length / 1KB, 2)
                        ConfigType = "Static"
                    }
                } catch {
                    Write-TraefikLog "Could not parse date from static backup file: $($file.Name)" -Level "Warning"
                }
            }
        }

        # Sort by backup date (newest first)
        $backups = @($backups | Sort-Object BackupDate -Descending)
        
        Write-TraefikLog "Found $($backups.Count) static config backup files" -Level "Info"
        return $backups
    }
    catch {
        Write-TraefikLog "Error retrieving static config backups: $($_.Exception.Message)" -Level "Error"
        return @()
    }
}

function Get-AllBackups {
    [CmdletBinding()]
    param()

    $serviceBackups = @(Get-ServiceBackups)
    $staticBackups = @(Get-StaticConfigBackups)
    
    return @{
        ServiceBackups = $serviceBackups
        StaticBackups = $staticBackups
        TotalCount = $serviceBackups.Count + $staticBackups.Count
    }
}

function Get-BackupContent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$BackupFilePath
    )

    try {
        if (-not (Test-Path $BackupFilePath)) {
            Write-TraefikLog "Backup file not found: $BackupFilePath" -Level "Error"
            return $null
        }

        $content = Get-Content -Path $BackupFilePath -Raw -ErrorAction Stop
        return $content
    }
    catch {
        Write-TraefikLog "Error reading backup file: $($_.Exception.Message)" -Level "Error"
        return $null
    }
}

# --- Backup Restore Functions ---
function Restore-ServiceFromBackup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$BackupFilePath,
        
        [Parameter(Mandatory = $true)]
        [string]$ServiceName,
        
        [Parameter(Mandatory = $true)]
        [string]$User,
        
        [Parameter(Mandatory = $true)]
        [string]$SshHost,
        
        [Parameter(Mandatory = $true)]
        [string]$Password,
        
        [Parameter(Mandatory = $true)]
        [string]$RemoteConfigDir,
        
        [Parameter(Mandatory = $true)]
        [int]$Port,
        
        [Parameter(Mandatory = $false)]
        [bool]$CreateBackupBeforeRestore = $true
    )

    try {
        # Read backup content
        $backupContent = Get-BackupContent -BackupFilePath $BackupFilePath
        if (-not $backupContent) {
            Write-TraefikLog "Failed to read backup content" -Level "Error"
            return $false
        }

        # Create backup of current configuration before restoring (if it exists)
        if ($CreateBackupBeforeRestore) {
            $checkCommand = "test -f `"$RemoteConfigDir/$ServiceName.yml`" && echo 'EXISTS' || echo 'NOT_EXISTS'"
            $checkResult = Invoke-SSHCommand -User $User -SshHost $SshHost -Password $Password -Port $Port -Command $checkCommand
            
            if ($checkResult.Success -and $checkResult.Stdout.Trim() -eq "EXISTS") {
                Write-TraefikLog "Creating backup of current configuration before restore..." -Level "Info"
                $currentContent = Get-ServiceContent -ServiceName $ServiceName -User $User -SshHost $SshHost -Password $Password -RemoteConfigDir $RemoteConfigDir -Port $Port
                if ($currentContent) {
                    Save-ServiceBackup -ServiceName $ServiceName -Content $currentContent -BackupSuffix "pre_restore"
                }
            }
        }

        # Deploy the backup content
        $success = Deploy-ServiceConfig -ServiceName $ServiceName -YamlContent $backupContent -User $User -SshHost $SshHost -Password $Password -RemoteConfigDir $RemoteConfigDir -Port $Port -CreateBackup $false

        if ($success) {
            Write-TraefikLog "Successfully restored service '$ServiceName' from backup" -Level "Success"
            return $true
        } else {
            Write-TraefikLog "Failed to restore service '$ServiceName' from backup" -Level "Error"
            return $false
        }
    }
    catch {
        Write-TraefikLog "Error during restore operation: $($_.Exception.Message)" -Level "Error"
        return $false
    }
}

function Restore-StaticConfigFromBackup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$BackupFilePath,
        
        [Parameter(Mandatory = $true)]
        [string]$User,
        
        [Parameter(Mandatory = $true)]
        [string]$SshHost,
        
        [Parameter(Mandatory = $true)]
        [string]$Password,
        
        [Parameter(Mandatory = $false)]
        [int]$Port = 22,
        
        [Parameter(Mandatory = $false)]
        [string]$RemoteConfigPath = "/etc/traefik/traefik.yaml",
        
        [Parameter(Mandatory = $false)]
        [bool]$CreateBackupBeforeRestore = $true
    )

    try {
        # Read backup content
        $backupContent = Get-BackupContent -BackupFilePath $BackupFilePath
        if (-not $backupContent) {
            Write-TraefikLog "Failed to read static config backup content" -Level "Error"
            return $false
        }

        # Create backup of current static config before restoring (if it exists)
        if ($CreateBackupBeforeRestore) {
            Write-TraefikLog "Creating backup of current static configuration before restore..." -Level "Info"
            $backupResult = Backup-StaticConfig -User $User -SshHost $SshHost -Password $Password -Port $Port -RemoteConfigPath $RemoteConfigPath -BackupSuffix "pre_restore"
            if ($backupResult) {
                Write-TraefikLog "Current static config backed up to: $backupResult" -Level "Success"
            }
        }

        # Deploy the backup content
        $success = Deploy-StaticConfig -StaticConfigContent $backupContent -User $User -SshHost $SshHost -Password $Password -Port $Port -RemoteConfigPath $RemoteConfigPath -CreateBackup $false

        if ($success) {
            Write-TraefikLog "Successfully restored static configuration from backup" -Level "Success"
            return $true
        } else {
            Write-TraefikLog "Failed to restore static configuration from backup" -Level "Error"
            return $false
        }
    }
    catch {
        Write-TraefikLog "Error during static config restore operation: $($_.Exception.Message)" -Level "Error"
        return $false
    }
}

# --- Backup Management Functions ---
function Remove-OldBackups {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [int]$DaysToKeep = 30,
        
        [Parameter(Mandatory = $false)]
        [int]$MaxBackupsPerService = 10
    )

    try {
        $backupDir = Join-Path (Get-Location) "backups"
        if (-not (Test-Path $backupDir)) {
            return
        }

        $cutoffDate = (Get-Date).AddDays(-$DaysToKeep)
        $allBackups = @(Get-ServiceBackups)
        $removedCount = 0

        # Group by service name
        $serviceGroups = $allBackups | Group-Object ServiceName

        foreach ($group in $serviceGroups) {
            $serviceBackups = @($group.Group | Sort-Object BackupDate -Descending)
            
            # Remove backups older than cutoff date
            $oldBackups = @($serviceBackups | Where-Object { $_.BackupDate -lt $cutoffDate })
            foreach ($oldBackup in $oldBackups) {
                try {
                    Remove-Item -Path $oldBackup.FilePath -Force -ErrorAction Stop
                    Write-TraefikLog "Removed old backup: $($oldBackup.FileName)" -Level "Info"
                    $removedCount++
                } catch {
                    Write-TraefikLog "Failed to remove backup: $($oldBackup.FileName)" -Level "Warning"
                }
            }

            # Keep only the most recent N backups per service
            $recentBackups = @($serviceBackups | Where-Object { $_.BackupDate -ge $cutoffDate })
            if ($recentBackups.Count -gt $MaxBackupsPerService) {
                $excessBackups = @($recentBackups | Select-Object -Skip $MaxBackupsPerService)
                foreach ($excessBackup in $excessBackups) {
                    try {
                        Remove-Item -Path $excessBackup.FilePath -Force -ErrorAction Stop
                        Write-TraefikLog "Removed excess backup: $($excessBackup.FileName)" -Level "Info"
                        $removedCount++
                    } catch {
                        Write-TraefikLog "Failed to remove backup: $($excessBackup.FileName)" -Level "Warning"
                    }
                }
            }
        }

        if ($removedCount -gt 0) {
            Write-TraefikLog "Cleanup completed: Removed $removedCount old backup files" -Level "Success"
        }
    }
    catch {
        Write-TraefikLog "Error during backup cleanup: $($_.Exception.Message)" -Level "Error"
    }
}

# Export functions
Export-ModuleMember -Function @(
    'Save-ServiceBackup',
    'Get-ServiceBackups',
    'Get-StaticConfigBackups',
    'Get-AllBackups',
    'Get-BackupContent',
    'Restore-ServiceFromBackup',
    'Restore-StaticConfigFromBackup',
    'Remove-OldBackups'
)