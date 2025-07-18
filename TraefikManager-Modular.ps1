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
        "TraefikManager.UI.psm1"
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
        $serviceIP = Get-ValidatedInput -Prompt "Enter the internal IP of the service LXC/VM (e.g., 10.10.10.30)" -ValidationFunction { param($ip) Test-IPAddress $ip } -ErrorMessage "Invalid IP address format"

        $serviceName = Get-ValidatedInput -Prompt "Enter a short, unique name for your service (e.g., jelly, nextcloud)" -ValidationFunction { param($name) Test-ServiceName $name } -ErrorMessage "Invalid service name format"

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

        # Get CrowdSec bouncer preference
        $useCrowdSecBouncer = Get-YesNoInput -Prompt "Enable CrowdSec bouncer middleware for this service?"

        # Generate configuration
        $yamlContent = New-TraefikServiceYaml -ServiceName $serviceName -ServiceIP $serviceIP -ServicePort $servicePort -DomainName $domainName -UseHttps $useHttps -UseCrowdSecBouncer $useCrowdSecBouncer

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
            Save-ServiceBackup -ServiceName $serviceName -Content $content
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
                    "6" { Invoke-ShowConfiguration }
                    "7" { Invoke-TestConnection }
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