# TraefikManager-Modular.ps1
# Modular Traefik Service Manager

#Requires -Version 5.1
[CmdletBinding()]
param()

Set-StrictMode -Version Latest

# Get script directory
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Definition

# Import all modules
Write-Host "Loading Traefik Manager modules..." -ForegroundColor Cyan

try {
    $modules = @(
        "TraefikManager.Core.psm1",
        "TraefikManager.SSH.psm1", 
        "TraefikManager.Services.psm1",
        "TraefikManager.Config.psm1",
        "TraefikManager.Backup.psm1",
        "TraefikManager.UI.psm1",
        "TraefikManager.StaticConfig.psm1",
        "TraefikManager.Wizard.psm1",
        "TraefikManager.ConfigSync.psm1"
    )
    
    foreach ($module in $modules) {
        $modulePath = Join-Path $ScriptRoot $module
        if (-not (Test-Path $modulePath)) {
            throw "Module not found: $modulePath"
        }
        Write-Host "Importing $module..." -ForegroundColor Gray
        Import-Module -Name $modulePath -Force -ErrorAction Stop
    }
    
    Write-Host "All modules loaded successfully!" -ForegroundColor Green
}
catch {
    Write-Error "Failed to import modules: $($_.Exception.Message)"
    Read-Host "Press Enter to exit..."
    exit 1
}

# Script variables
$script:Config = $null

# --- Core Business Logic Functions ---
function Invoke-ListServices {
    try {
        Write-TraefikLog "Listing services..." -Level "Info"
        
        $password = Get-SshPassword -User $script:Config.TraefikSshUser -SshHost $script:Config.TraefikLxcIp
        if (-not $password) { return }
        
        $services = Get-TraefikServices -User $script:Config.TraefikSshUser -SshHost $script:Config.TraefikLxcIp -Password $password -RemoteConfigDir $script:Config.RemoteConfigDir -Port $script:Config.ConnectionSettings.SSHPort
        
        Show-ServiceList -Services $services -ShowPause
    }
    catch {
        Show-ErrorMessage "Error listing services" $_.Exception.Message
        Write-TraefikLog "Error in Invoke-ListServices: $($_.Exception.Message)" -Level "Error"
    }
}

function Invoke-AddService {
    try {
        Write-TraefikLog "Starting add service workflow..." -Level "Info"
        Show-InfoMessage "--- Add New Traefik Service Configuration ---"

        # Get validated inputs
        $serviceIP = Get-ValidatedInput -Prompt "Enter the internal IP of the service LXC/VM (e.g., 192.168.1.100)" -ValidationFunction { param($ip) Test-IPAddress $ip } -ErrorMessage "Invalid IP address format"

        $serviceName = Get-ValidatedInput -Prompt "Enter a short, unique name for your service (e.g., nextcloud, jellyfin)" -ValidationFunction { param($name) Test-ServiceName $name } -ErrorMessage "Invalid service name format"

        # Check if service already exists
        $password = Get-SshPassword -User $script:Config.TraefikSshUser -SshHost $script:Config.TraefikLxcIp
        if (-not $password) { return }
        
        $existingServices = Get-TraefikServices -User $script:Config.TraefikSshUser -SshHost $script:Config.TraefikLxcIp -Password $password -RemoteConfigDir $script:Config.RemoteConfigDir -Port $script:Config.ConnectionSettings.SSHPort
        
        # Safe check for existing services - handle case where services might be null or empty
        if ($null -ne $existingServices -and (Test-ServiceExists -ServiceName $serviceName -ExistingServices $existingServices)) {
            Show-ErrorMessage "Service '$serviceName' already exists!"
            return
        }

        # Get domain selection
        $domainName = Get-DomainSelection -DomainOptions $script:Config.DomainOptions

        # Get port
        $servicePortStr = Get-ValidatedInput -Prompt "Enter the internal port of the service (e.g., 80, 8080, 443)" -ValidationFunction { param($port) Test-PortNumber $port } -ErrorMessage "Invalid port number"
        $servicePort = [int]$servicePortStr

        # Get HTTPS preference
        $useHttps = Get-YesNoInput -Prompt "Use HTTPS for the backend service URL?"

        # Generate configuration
        $yamlContent = New-TraefikServiceYaml -ServiceName $serviceName -ServiceIP $serviceIP -ServicePort $servicePort -DomainName $domainName -UseHttps $useHttps -CertResolver $script:Config.CertificateResolver

        # Show preview
        Show-ConfigurationPreview -ServiceName $serviceName -YamlContent $yamlContent

        # Confirm deployment
        $deploy = Get-YesNoInput -Prompt "Deploy this configuration?"
        if (-not $deploy) {
            Show-InfoMessage "Deployment cancelled."
            return
        }

        # Deploy
        $success = Deploy-ServiceConfig -ServiceName $serviceName -YamlContent $yamlContent -User $script:Config.TraefikSshUser -SshHost $script:Config.TraefikLxcIp -Password $password -RemoteConfigDir $script:Config.RemoteConfigDir -Port $script:Config.ConnectionSettings.SSHPort -CreateBackup $script:Config.BackupEnabled

        Show-OperationResult -Success $success -Operation "Service deployment" -ServiceName $serviceName -AdditionalMessage "Traefik will automatically detect the new configuration."
    }
    catch {
        Show-ErrorMessage "Error adding service" $_.Exception.Message
        Write-TraefikLog "Error in Invoke-AddService: $($_.Exception.Message)" -Level "Error"
    }
}

function Invoke-RemoveService {
    try {
        Write-TraefikLog "Starting remove service workflow..." -Level "Info"
        Show-InfoMessage "--- Remove Traefik Service Configuration ---"
        
        $password = Get-SshPassword -User $script:Config.TraefikSshUser -SshHost $script:Config.TraefikLxcIp
        if (-not $password) { return }
        
        $services = Get-TraefikServices -User $script:Config.TraefikSshUser -SshHost $script:Config.TraefikLxcIp -Password $password -RemoteConfigDir $script:Config.RemoteConfigDir -Port $script:Config.ConnectionSettings.SSHPort
        
        $serviceNames = Show-ServiceList -Services $services -Title "Services Available for Removal"
        if ($serviceNames.Count -eq 0) { return }

        $serviceName = Get-ServiceSelection -Prompt "Enter the number of the service to remove, or 'q' to cancel" -Services $services
        if (-not $serviceName) { 
            Show-InfoMessage "Removal cancelled."
            return 
        }
        if ($serviceName -eq "INVALID") { return }

        # Show current configuration before removal
        $content = Get-ServiceContent -ServiceName $serviceName -User $script:Config.TraefikSshUser -SshHost $script:Config.TraefikLxcIp -Password $password -RemoteConfigDir $script:Config.RemoteConfigDir -Port $script:Config.ConnectionSettings.SSHPort
        if ($content) {
            Show-ServiceContent -ServiceName $serviceName -Content $content
        }

        # Confirm removal
        $remove = Get-YesNoInput -Prompt "Are you sure you want to delete '$serviceName'?"
        if (-not $remove) {
            Show-InfoMessage "Removal cancelled."
            return
        }

        # Create backup before removal
        if ($script:Config.BackupEnabled -and $content) {
            Save-ServiceBackup -ServiceName $serviceName -Content $content -BackupSuffix "pre_delete"
        }

        # Remove service
        $success = Remove-ServiceFile -ServiceName $serviceName -User $script:Config.TraefikSshUser -SshHost $script:Config.TraefikLxcIp -Password $password -RemoteConfigDir $script:Config.RemoteConfigDir -Port $script:Config.ConnectionSettings.SSHPort

        Show-OperationResult -Success $success -Operation "Service removal" -ServiceName $serviceName -AdditionalMessage "Traefik will automatically detect the removal."
    }
    catch {
        Show-ErrorMessage "Error removing service" $_.Exception.Message
        Write-TraefikLog "Error in Invoke-RemoveService: $($_.Exception.Message)" -Level "Error"
    }
}

function Invoke-ViewService {
    try {
        Write-TraefikLog "Starting view service workflow..." -Level "Info"
        Show-InfoMessage "--- View Service Configuration ---"
        
        $password = Get-SshPassword -User $script:Config.TraefikSshUser -SshHost $script:Config.TraefikLxcIp
        if (-not $password) { return }
        
        $services = Get-TraefikServices -User $script:Config.TraefikSshUser -SshHost $script:Config.TraefikLxcIp -Password $password -RemoteConfigDir $script:Config.RemoteConfigDir -Port $script:Config.ConnectionSettings.SSHPort
        
        $serviceNames = Show-ServiceList -Services $services -Title "Services Available to View"
        if ($serviceNames.Count -eq 0) { return }

        $serviceName = Get-ServiceSelection -Prompt "Enter the number of the service to view, or 'q' to cancel" -Services $services
        if (-not $serviceName) { 
            Show-InfoMessage "View cancelled."
            return 
        }
        if ($serviceName -eq "INVALID") { return }

        $content = Get-ServiceContent -ServiceName $serviceName -User $script:Config.TraefikSshUser -SshHost $script:Config.TraefikLxcIp -Password $password -RemoteConfigDir $script:Config.RemoteConfigDir -Port $script:Config.ConnectionSettings.SSHPort

        if ($content) {
            Show-ServiceContent -ServiceName $serviceName -Content $content
        }
        else {
            Show-ErrorMessage "Failed to retrieve configuration for '$serviceName'"
        }

        Wait-ForContinue
    }
    catch {
        Show-ErrorMessage "Error viewing service" $_.Exception.Message
        Write-TraefikLog "Error in Invoke-ViewService: $($_.Exception.Message)" -Level "Error"
    }
}

function Invoke-EditService {
   try {
       Write-TraefikLog "Starting edit service workflow..." -Level "Info"
       Show-InfoMessage "--- Edit Service Configuration ---"
       
       $password = Get-SshPassword -User $script:Config.TraefikSshUser -SshHost $script:Config.TraefikLxcIp
       if (-not $password) { return }
       
       $services = Get-TraefikServices -User $script:Config.TraefikSshUser -SshHost $script:Config.TraefikLxcIp -Password $password -RemoteConfigDir $script:Config.RemoteConfigDir -Port $script:Config.ConnectionSettings.SSHPort
       
       $serviceNames = Show-ServiceList -Services $services -Title "Services Available for Editing"
       if ($serviceNames.Count -eq 0) { return }

       $serviceName = Get-ServiceSelection -Prompt "Enter the number of the service to edit, or 'q' to cancel" -Services $services
       if (-not $serviceName) { 
           Show-InfoMessage "Edit cancelled."
           return 
       }
       if ($serviceName -eq "INVALID") { return }

       $success = Edit-ServiceConfig -ServiceName $serviceName -User $script:Config.TraefikSshUser -SshHost $script:Config.TraefikLxcIp -Password $password -RemoteConfigDir $script:Config.RemoteConfigDir -Port $script:Config.ConnectionSettings.SSHPort -Editor $script:Config.Editor

       if ($success) {
           Show-SuccessMessage "Edit operation completed for '$serviceName'"
       }
   }
   catch {
       Show-ErrorMessage "Error editing service" $_.Exception.Message
       Write-TraefikLog "Error in Invoke-EditService: $($_.Exception.Message)" -Level "Error"
   }
}

function Invoke-RestoreService {
   try {
       Write-TraefikLog "Starting restore workflow..." -Level "Info"
       
       # Get backup type selection
       $backupType = Show-BackupTypeSelection
       if ($null -eq $backupType) {
           Show-InfoMessage "Restore cancelled."
           return
       }

       switch ($backupType) {
           1 { Invoke-RestoreServiceConfig }
           2 { Invoke-RestoreStaticConfig }
           3 { Invoke-ShowAllBackups }
       }
   }
   catch {
       Show-ErrorMessage "Error during restore operation" $_.Exception.Message
       Write-TraefikLog "Error in Invoke-RestoreService: $($_.Exception.Message)" -Level "Error"
       Wait-ForContinue
   }
}

function Invoke-RestoreServiceConfig {
   try {
       # Get all available service backups
       $backups = @(Get-ServiceBackups)
       
       if ($backups.Count -eq 0) {
           Show-WarningMessage "No service backup files found in the backups directory."
           Show-InfoMessage "Backups are automatically created when you edit or remove services."
           Wait-ForContinue
           return
       }

       # Show backup list
       $backupList = Show-BackupList -Backups $backups -Title "Service Configuration Backups" -BackupType "Service"
       
       # Get user selection
       $selectedBackup = $null
       do {
           $selectedBackup = Get-BackupSelection -Prompt "Enter the number of the backup to restore, or 'q' to cancel" -Backups $backups
           if ($selectedBackup -eq $null) {
               Show-InfoMessage "Restore cancelled."
               return
           }
           if ($selectedBackup -eq "INVALID") {
               continue
           }
           break
       } while ($true)

       # Show backup content for review
       $backupContent = Get-BackupContent -BackupFilePath $selectedBackup.FilePath
       if (-not $backupContent) {
           Show-ErrorMessage "Failed to read backup content"
           Wait-ForContinue
           return
       }

       Show-BackupDetails -Backup $selectedBackup -Content $backupContent

       # Confirm restore
       Write-Host "`nThis will restore the service '$($selectedBackup.ServiceName)' to the configuration shown above." -ForegroundColor Yellow
       Write-Host "The current configuration (if any) will be backed up before restoring." -ForegroundColor Yellow
       
       $confirm = Get-YesNoInput -Prompt "Do you want to proceed with the restore?"
       if (-not $confirm) {
           Show-InfoMessage "Restore cancelled."
           return
       }

       # Get SSH connection
       $password = Get-SshPassword -User $script:Config.TraefikSshUser -SshHost $script:Config.TraefikLxcIp
       if (-not $password) { return }

       # Perform restore
       Write-Host "Restoring service configuration..." -ForegroundColor Cyan
       $success = Restore-ServiceFromBackup -BackupFilePath $selectedBackup.FilePath -ServiceName $selectedBackup.ServiceName -User $script:Config.TraefikSshUser -SshHost $script:Config.TraefikLxcIp -Password $password -RemoteConfigDir $script:Config.RemoteConfigDir -Port $script:Config.ConnectionSettings.SSHPort

       # Show result
       if ($success) {
           Show-SuccessMessage "Service '$($selectedBackup.ServiceName)' has been successfully restored!"
           Show-InfoMessage "Traefik will automatically detect the restored configuration."
       } else {
           Show-ErrorMessage "Failed to restore service '$($selectedBackup.ServiceName)'"
       }
       
       Wait-ForContinue
   }
   catch {
       Show-ErrorMessage "Error during service restore operation" $_.Exception.Message
       Write-TraefikLog "Error in Invoke-RestoreServiceConfig: $($_.Exception.Message)" -Level "Error"
       Wait-ForContinue
   }
}

function Invoke-RestoreStaticConfig {
   try {
       # Get all available static config backups
       $backups = @(Get-StaticConfigBackups)
       
       if ($backups.Count -eq 0) {
           Show-WarningMessage "No static configuration backup files found."
           Show-InfoMessage "Static config backups are created when you edit or upload static configurations."
           Wait-ForContinue
           return
       }

       # Show backup list
       $backupList = Show-BackupList -Backups $backups -Title "Static Configuration Backups" -BackupType "Static"
       
       # Get user selection
       $selectedBackup = $null
       do {
           $selectedBackup = Get-BackupSelection -Prompt "Enter the number of the backup to restore, or 'q' to cancel" -Backups $backups
           if ($selectedBackup -eq $null) {
               Show-InfoMessage "Restore cancelled."
               return
           }
           if ($selectedBackup -eq "INVALID") {
               continue
           }
           break
       } while ($true)

       # Show backup content for review
       $backupContent = Get-BackupContent -BackupFilePath $selectedBackup.FilePath
       if (-not $backupContent) {
           Show-ErrorMessage "Failed to read backup content"
           Wait-ForContinue
           return
       }

       Show-BackupDetails -Backup $selectedBackup -Content $backupContent

       # Confirm restore
       Write-Host "`nThis will restore the static configuration to the version shown above." -ForegroundColor Yellow
       Write-Host "The current static configuration will be backed up before restoring." -ForegroundColor Yellow
       Write-Host "⚠️  You will need to restart Traefik after the restore!" -ForegroundColor Red
       
       $confirm = Get-YesNoInput -Prompt "Do you want to proceed with the restore?"
       if (-not $confirm) {
           Show-InfoMessage "Restore cancelled."
           return
       }

       # Get SSH connection
       $password = Get-SshPassword -User $script:Config.TraefikSshUser -SshHost $script:Config.TraefikLxcIp
       if (-not $password) { return }

       # Perform restore
       Write-Host "Restoring static configuration..." -ForegroundColor Cyan
       $success = Restore-StaticConfigFromBackup -BackupFilePath $selectedBackup.FilePath -User $script:Config.TraefikSshUser -SshHost $script:Config.TraefikLxcIp -Password $password -Port $script:Config.ConnectionSettings.SSHPort

       # Show result
       if ($success) {
           Show-SuccessMessage "Static configuration has been successfully restored!"
           Show-InfoMessage "Remember to restart Traefik: sudo systemctl restart traefik"
           Show-InfoMessage "Consider running 'Test Configuration Compatibility' after restart."
       } else {
           Show-ErrorMessage "Failed to restore static configuration"
       }
       
       Wait-ForContinue
   }
   catch {
       Show-ErrorMessage "Error during static config restore operation" $_.Exception.Message
       Write-TraefikLog "Error in Invoke-RestoreStaticConfig: $($_.Exception.Message)" -Level "Error"
       Wait-ForContinue
   }
}

function Invoke-ShowAllBackups {
   try {
       $allBackups = Get-AllBackups
       Show-AllBackupsView -AllBackups $allBackups
       Wait-ForContinue
   }
   catch {
       Show-ErrorMessage "Error showing backups" $_.Exception.Message
       Write-TraefikLog "Error in Invoke-ShowAllBackups: $($_.Exception.Message)" -Level "Error"
       Wait-ForContinue
   }
}

function Invoke-ViewStaticConfig {
   try {
       Write-TraefikLog "Starting view static config workflow..." -Level "Info"
       Show-InfoMessage "--- View Static Configuration ---"
       
       $password = Get-SshPassword -User $script:Config.TraefikSshUser -SshHost $script:Config.TraefikLxcIp
       if (-not $password) { return }

       Write-Host "Retrieving static configuration..." -ForegroundColor Cyan
       $content = Get-StaticConfigContent -User $script:Config.TraefikSshUser -SshHost $script:Config.TraefikLxcIp -Password $password -Port $script:Config.ConnectionSettings.SSHPort

       if ($content) {
           Show-StaticConfigContent -Content $content
       }
       else {
           Show-ErrorMessage "Failed to retrieve static configuration" "File may not exist or is not accessible"
       }

       Wait-ForContinue
   }
   catch {
       Show-ErrorMessage "Error viewing static configuration" $_.Exception.Message
       Write-TraefikLog "Error in Invoke-ViewStaticConfig: $($_.Exception.Message)" -Level "Error"
       Wait-ForContinue
   }
}

function Invoke-EditStaticConfig {
   try {
       Write-TraefikLog "Starting edit static config workflow..." -Level "Info"
       Show-InfoMessage "--- Edit Static Configuration ---"
       
       $password = Get-SshPassword -User $script:Config.TraefikSshUser -SshHost $script:Config.TraefikLxcIp
       if (-not $password) { return }

       $success = Edit-StaticConfig -User $script:Config.TraefikSshUser -SshHost $script:Config.TraefikLxcIp -Password $password -Port $script:Config.ConnectionSettings.SSHPort -Editor $script:Config.Editor

       if ($success) {
           Show-SuccessMessage "Static configuration edit operation completed"
       }
       
       Wait-ForContinue
   }
   catch {
       Show-ErrorMessage "Error editing static configuration" $_.Exception.Message
       Write-TraefikLog "Error in Invoke-EditStaticConfig: $($_.Exception.Message)" -Level "Error"
       Wait-ForContinue
   }
}

function Invoke-UploadStaticConfig {
   try {
       Write-TraefikLog "Starting upload static config workflow..." -Level "Info"
       Show-InfoMessage "--- Upload Static Configuration ---"
       
       # Check if there's a local static config to upload
       $localConfigPath = Join-Path (Get-Location) "traefik_static.yaml"
       
       if (-not (Test-Path $localConfigPath)) {
           Show-WarningMessage "No local static configuration file found at: $localConfigPath"
           
           $generate = Get-YesNoInput -Prompt "Would you like to generate a new static configuration?"
           if ($generate) {
               # This would need to be implemented - simplified static config generation
               Show-InfoMessage "Static configuration generation from this menu is not yet implemented."
               Show-InfoMessage "Use the first-run wizard or manually create the file."
               Wait-ForContinue
               return
           } else {
               Show-InfoMessage "Upload cancelled."
               Wait-ForContinue
               return
           }
       }

       # Read local config content
       $staticContent = Get-Content -Path $localConfigPath -Raw -ErrorAction Stop
       
       # Show preview
       Write-Host "`n--- Static Configuration Preview ---" -ForegroundColor Yellow
       Write-Host $staticContent -ForegroundColor Cyan
       Write-Host "-------------------------------------" -ForegroundColor Yellow
       
       $confirm = Get-YesNoInput -Prompt "Upload this static configuration to the server?"
       if (-not $confirm) {
           Show-InfoMessage "Upload cancelled."
           Wait-ForContinue
           return
       }

       $password = Get-SshPassword -User $script:Config.TraefikSshUser -SshHost $script:Config.TraefikLxcIp
       if (-not $password) { return }

       Write-Host "Uploading static configuration..." -ForegroundColor Cyan
       $success = Deploy-StaticConfig -StaticConfigContent $staticContent -User $script:Config.TraefikSshUser -SshHost $script:Config.TraefikLxcIp -Password $password -Port $script:Config.ConnectionSettings.SSHPort

       if ($success) {
           Show-SuccessMessage "Static configuration uploaded successfully!"
           Show-InfoMessage "Remember to restart Traefik: sudo systemctl restart traefik"
       } else {
           Show-ErrorMessage "Failed to upload static configuration"
       }
       
       Wait-ForContinue
   }
   catch {
       Show-ErrorMessage "Error uploading static configuration" $_.Exception.Message
       Write-TraefikLog "Error in Invoke-UploadStaticConfig: $($_.Exception.Message)" -Level "Error"
       Wait-ForContinue
   }
}

function Invoke-TestCompatibility {
   try {
       Write-TraefikLog "Starting configuration compatibility test..." -Level "Info"
       Show-InfoMessage "--- Test Configuration Compatibility ---"
       
       $password = Get-SshPassword -User $script:Config.TraefikSshUser -SshHost $script:Config.TraefikLxcIp
       if (-not $password) { return }

       $configPath = Join-Path $ScriptRoot "config.json"
       $syncResult = Invoke-ConfigurationSync -ConfigPath $configPath -Config $script:Config -Password $password
       
       if (-not $syncResult) {
           Show-InfoMessage "Please resolve configuration issues before adding services."
       }
       
       Wait-ForContinue
   }
   catch {
       Show-ErrorMessage "Error testing configuration compatibility" $_.Exception.Message
       Write-TraefikLog "Error in Invoke-TestCompatibility: $($_.Exception.Message)" -Level "Error"
       Wait-ForContinue
   }
}

function Invoke-TestConnection {
   try {
       Write-TraefikLog "Starting connection test..." -Level "Info"
       
       $password = Get-SshPassword -User $script:Config.TraefikSshUser -SshHost $script:Config.TraefikLxcIp
       if (-not $password) { return }

       $connectionResult = Test-SSHConnection -User $script:Config.TraefikSshUser -SshHost $script:Config.TraefikLxcIp -Password $password -Port $script:Config.ConnectionSettings.SSHPort
       
       Show-ConnectionTest -ConnectionResult $connectionResult -TargetHost "$($script:Config.TraefikSshUser)@$($script:Config.TraefikLxcIp)"
       
       if ($connectionResult.Success) {
           # Test Traefik directory access
           Show-InfoMessage "Testing Traefik directory access..."
           $dirResult = Invoke-SSHCommand -User $script:Config.TraefikSshUser -SshHost $script:Config.TraefikLxcIp -Password $password -Port $script:Config.ConnectionSettings.SSHPort -Command "ls -la $($script:Config.RemoteConfigDir)"
           
           if ($dirResult.Success) {
               Show-SuccessMessage "Traefik config directory accessible!"
           }
           else {
               Show-WarningMessage "Warning: Traefik config directory may not be accessible"
           }
       }

       Wait-ForContinue
   }
   catch {
       Show-ErrorMessage "Connection test error" $_.Exception.Message
       Write-TraefikLog "Error in Invoke-TestConnection: $($_.Exception.Message)" -Level "Error"
   }
}

function Invoke-ShowConfiguration {
   try {
       Show-Configuration -Config $script:Config
       Wait-ForContinue
   }
   catch {
       Show-ErrorMessage "Error showing configuration" $_.Exception.Message
       Write-TraefikLog "Error in Invoke-ShowConfiguration: $($_.Exception.Message)" -Level "Error"
   }
}

# --- Main Application ---
function Start-TraefikManager {
   try {
       Write-TraefikLog "=== Traefik Service Manager Started ===" -Level "Info"
       
       $configPath = Join-Path $ScriptRoot "config.json"
       $logPath = Join-Path $ScriptRoot "traefik-manager.log"
       
       Show-WelcomeMessage -ConfigPath $configPath -LogPath $logPath
       
       # Load configuration
       $script:Config = Get-TraefikConfiguration -ConfigPath $configPath
       
       # Clean up old backups on startup
       if ($script:Config.BackupEnabled) {
           Remove-OldBackups -DaysToKeep 30 -MaxBackupsPerService 10
       }
       
       # Main menu loop
       $exitRequested = $false
       while (-not $exitRequested) {
           try {
               Show-MainMenu
               
               $choice = Read-Host -Prompt "Enter your choice"
               Write-TraefikLog "User selected menu option: $choice" -Level "Debug"

               switch ($choice) {
                   "1" { Invoke-AddService }
                   "2" { Invoke-ListServices }
                   "3" { Invoke-RemoveService }
                   "4" { Invoke-ViewService }
                   "5" { Invoke-EditService }
                   "6" { Invoke-RestoreService }
                   "7" { Invoke-ViewStaticConfig }
                   "8" { Invoke-EditStaticConfig }
                   "9" { Invoke-UploadStaticConfig }
                   "10" { Invoke-TestCompatibility }
                   "11" { Invoke-ShowConfiguration }
                   "12" { Invoke-TestConnection }
                   "q" { 
                       Write-TraefikLog "User requested to quit the application." -Level "Info"
                       $exitRequested = $true
                   }
                   default { 
                       Write-TraefikLog "Invalid menu choice: $choice" -Level "Warning"
                       Show-WarningMessage "Invalid choice. Please try again."
                       Start-Sleep -Seconds 1
                   }
               }
           }
           catch {
               Write-TraefikLog "Error in main menu loop: $($_.Exception.Message)" -Level "Error"
               Show-ErrorMessage "An error occurred. Please try again." $_.Exception.Message
               Start-Sleep -Seconds 2
           }
       }
   }
   catch {
       Write-TraefikLog "Critical error in main application: $($_.Exception.Message)" -Level "Error"
       Show-ErrorMessage "A critical error occurred. Check the log file for details." $_.Exception.Message
       Wait-ForContinue "Press Enter to exit..."
   }
   finally {
       Write-TraefikLog "Exiting Traefik Service Manager." -Level "Info"
       Show-InfoMessage "Exiting Traefik Service Manager. Goodbye!"
   }
}

# --- Main Execution ---
try {
   Start-TraefikManager
}
catch {
   Write-Error "Critical error in main execution: $($_.Exception.Message)"
   Write-Host "Critical error occurred. Check the details above." -ForegroundColor Red
   Read-Host "Press Enter to exit..."
}
finally {
   Write-TraefikLog "=== Performing cleanup ===" -Level "Info"
   Remove-TraefikTemporaryFiles
   Clear-TraefikSensitiveData
   Write-TraefikLog "=== Cleanup completed ===" -Level "Info"
   
   # Always pause at the end so window doesn't close immediately
   Write-Host "`nScript execution completed." -ForegroundColor Green
   Read-Host "Press Enter to close this window..."
}