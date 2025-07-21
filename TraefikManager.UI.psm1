# TraefikManager.UI.psm1  
# User interface and menu functions

#Requires -Version 5.1
Set-StrictMode -Version Latest

# --- Menu Display Functions ---
function Show-MainMenu {
    Write-Host "`n=== Traefik Service Manager ===" -ForegroundColor Green
    Write-Host "1. Add New Service" -ForegroundColor Yellow
    Write-Host "2. List Services" -ForegroundColor Yellow
    Write-Host "3. Remove Service" -ForegroundColor Yellow
    Write-Host "4. View Service Content" -ForegroundColor Yellow
    Write-Host "5. Edit Service Content" -ForegroundColor Yellow
    Write-Host "6. Restore from Backup" -ForegroundColor Yellow
    Write-Host "7. View Static Configuration" -ForegroundColor Yellow
    Write-Host "8. Edit Static Configuration" -ForegroundColor Yellow
    Write-Host "9. Upload Static Configuration" -ForegroundColor Yellow
    Write-Host "10. Test Configuration Compatibility" -ForegroundColor Yellow
    Write-Host "11. Show Configuration" -ForegroundColor Yellow
    Write-Host "12. Test Connection" -ForegroundColor Yellow
	Write-Host "13. Template Manager" -ForegroundColor Yellow
    Write-Host "q. Quit" -ForegroundColor Red
    Write-Host "===============================`n" -ForegroundColor Green
}

function Show-ServiceList {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Services,
        
        [Parameter(Mandatory = $false)]
        [string]$Title = "Traefik Service Configurations",
        
        [Parameter(Mandatory = $false)]
        [switch]$ShowPause
    )

    Write-Host "`n--- $Title ---" -ForegroundColor Yellow

    # Get service names and count safely
    $serviceNames = @()
    if ($null -ne $Services -and $Services.Count -gt 0) {
        foreach ($key in $Services.Keys) {
            if ($key -notmatch "^\d+$") {
                $serviceNames += $key
            }
        }
        $serviceNames = $serviceNames | Sort-Object
    }

    if ($serviceNames.Count -eq 0) {
        Write-Host "No services found." -ForegroundColor Yellow
        if ($ShowPause) {
            Read-Host "`nPress Enter to continue..."
        }
        return @()
    }

    Write-Host "Found $($serviceNames.Count) services:" -ForegroundColor Green

    $i = 1
    foreach ($serviceName in $serviceNames) {
        Write-Host "($i) $serviceName" -ForegroundColor White
        $i++
    }

    if ($ShowPause) {
        Read-Host "`nPress Enter to continue..."
    }

    return $serviceNames
}

function Show-Configuration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Config
    )

    Write-Host "`n--- Current Configuration ---" -ForegroundColor Yellow
    Write-Host "Traefik LXC IP: $($Config.TraefikLxcIp)" -ForegroundColor Cyan
    Write-Host "SSH User: $($Config.TraefikSshUser)" -ForegroundColor Cyan
    Write-Host "Remote Config Directory: $($Config.RemoteConfigDir)" -ForegroundColor Cyan
    Write-Host "SSH Port: $($Config.ConnectionSettings.SSHPort)" -ForegroundColor Cyan
    Write-Host "Max Retries: $($Config.ConnectionSettings.MaxRetries)" -ForegroundColor Cyan
    Write-Host "Retry Delay: $($Config.ConnectionSettings.RetryDelaySeconds)s" -ForegroundColor Cyan
    Write-Host "Timeout: $($Config.ConnectionSettings.TimeoutSeconds)s" -ForegroundColor Cyan
    Write-Host "Editor: $($Config.Editor)" -ForegroundColor Cyan
    Write-Host "Backup Enabled: $($Config.BackupEnabled)" -ForegroundColor Cyan
    Write-Host "`nDomain Options:" -ForegroundColor Yellow
    $Config.DomainOptions.PSObject.Properties | ForEach-Object {
        Write-Host "  $($_.Name): $($_.Value)" -ForegroundColor Cyan
    }
    Write-Host "-----------------------------" -ForegroundColor Yellow
}

function Show-ServiceContent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ServiceName,
        
        [Parameter(Mandatory = $true)]
        [string]$Content
    )

    Write-Host "`n--- Configuration for '$ServiceName' ---" -ForegroundColor Green
    Write-Host $Content -ForegroundColor Cyan
    Write-Host "----------------------------------------" -ForegroundColor Green
}

function Show-StaticConfigContent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Content
    )

    Write-Host "`n--- Static Configuration Content ---" -ForegroundColor Green
    Write-Host $Content -ForegroundColor Cyan
    Write-Host "-----------------------------------" -ForegroundColor Green
}

function Show-ConnectionTest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$ConnectionResult,
        
        [Parameter(Mandatory = $true)]
        [string]$TargetHost
    )

    Write-Host "`n--- Testing Connection ---" -ForegroundColor Yellow
    Write-Host "Testing connection to $TargetHost..." -ForegroundColor Cyan
    
    if ($ConnectionResult.Success) {
        Write-Host "Connection successful!" -ForegroundColor Green
        Write-Host "Remote user: $($ConnectionResult.RemoteUser)" -ForegroundColor Cyan
        Write-Host "Remote directory: $($ConnectionResult.RemoteDirectory)" -ForegroundColor Cyan
    }
    else {
        Write-Host "Connection test failed!" -ForegroundColor Red
        Write-Host "Error: $($ConnectionResult.Message)" -ForegroundColor Red
    }
}

# --- Backup UI Functions ---
function Show-BackupTypeSelection {
    Write-Host "`n--- Restore from Backup ---" -ForegroundColor Yellow
    Write-Host "What would you like to restore?" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "1. Service Configuration" -ForegroundColor White
    Write-Host "2. Static Configuration" -ForegroundColor White
    Write-Host "3. Show All Backups" -ForegroundColor White
    Write-Host ""
    
    do {
        $choice = Read-Host -Prompt "Enter your choice (1-3, or q to cancel)"
        if ($choice -eq 'q' -or $choice -eq 'Q') {
            return $null
        }
        if ($choice -match '^[1-3]$') {
            return [int]$choice
        }
        Write-Host "Invalid choice. Please enter 1, 2, 3, or q." -ForegroundColor Yellow
    } while ($true)
}

function Show-BackupList {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [array]$Backups,
        
        [Parameter(Mandatory = $false)]
        [string]$Title = "Available Backups",
        
        [Parameter(Mandatory = $false)]
        [string]$BackupType = "Service"
    )

    Write-Host "`n--- $Title ---" -ForegroundColor Yellow

    if ($Backups.Count -eq 0) {
        Write-Host "No $BackupType backups found." -ForegroundColor Yellow
        return @()
    }

    Write-Host "Found $($Backups.Count) $BackupType backup files:" -ForegroundColor Green
    Write-Host ""
    
    if ($BackupType -eq "Service") {
        Write-Host "  #  | Service Name     | Type         | Backup Date         | Size (KB)" -ForegroundColor Cyan
        Write-Host "  ---|------------------|--------------|---------------------|----------" -ForegroundColor Cyan

        $i = 1
        foreach ($backup in $Backups) {
            $serviceNamePadded = $backup.ServiceName.PadRight(16)
            $typePadded = $backup.BackupType.PadRight(12)
            $sizePadded = $backup.SizeKB.ToString().PadLeft(8)
            Write-Host "  $($i.ToString().PadLeft(2)) | $serviceNamePadded | $typePadded | $($backup.FormattedDate) | $sizePadded" -ForegroundColor White
            $i++
        }
    } else {
        Write-Host "  #  | Type             | Backup Date         | Size (KB)" -ForegroundColor Cyan
        Write-Host "  ---|------------------|---------------------|----------" -ForegroundColor Cyan

        $i = 1
        foreach ($backup in $Backups) {
            $typePadded = $backup.BackupType.PadRight(16)
            $sizePadded = $backup.SizeKB.ToString().PadLeft(8)
            Write-Host "  $($i.ToString().PadLeft(2)) | $typePadded | $($backup.FormattedDate) | $sizePadded" -ForegroundColor White
            $i++
        }
    }

    Write-Host ""
    return $Backups
}

function Show-AllBackupsView {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$AllBackups
    )

    Write-Host "`n--- All Backups Overview ---" -ForegroundColor Yellow
    
    Write-Host "`nService Configuration Backups ($($AllBackups.ServiceBackups.Count)):" -ForegroundColor Green
    if ($AllBackups.ServiceBackups.Count -eq 0) {
        Write-Host "  No service backups found." -ForegroundColor Gray
    } else {
        foreach ($backup in ($AllBackups.ServiceBackups | Select-Object -First 5)) {
            Write-Host "  • $($backup.ServiceName) - $($backup.BackupType) - $($backup.FormattedDate)" -ForegroundColor White
        }
        if ($AllBackups.ServiceBackups.Count -gt 5) {
            Write-Host "  ... and $($AllBackups.ServiceBackups.Count - 5) more" -ForegroundColor Gray
        }
    }
    
    Write-Host "`nStatic Configuration Backups ($($AllBackups.StaticBackups.Count)):" -ForegroundColor Green
    if ($AllBackups.StaticBackups.Count -eq 0) {
        Write-Host "  No static config backups found." -ForegroundColor Gray
    } else {
        foreach ($backup in ($AllBackups.StaticBackups | Select-Object -First 5)) {
            Write-Host "  • $($backup.BackupType) - $($backup.FormattedDate)" -ForegroundColor White
        }
        if ($AllBackups.StaticBackups.Count -gt 5) {
            Write-Host "  ... and $($AllBackups.StaticBackups.Count - 5) more" -ForegroundColor Gray
        }
    }
    
    Write-Host "`nTotal: $($AllBackups.TotalCount) backup files" -ForegroundColor Cyan
}

function Get-BackupSelection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Prompt,
        
        [Parameter(Mandatory = $true)]
        [array]$Backups
    )

    $choice = Read-Host -Prompt $Prompt
    if ($choice -eq 'q') {
        return $null
    }

    if ($choice -match "^\d+$") {
        $choiceInt = [int]$choice
        if ($choiceInt -ge 1 -and $choiceInt -le $Backups.Count) {
            return $Backups[$choiceInt - 1]
        }
else {
           Write-Warning "Invalid selection. Please enter a number between 1 and $($Backups.Count)."
           return "INVALID"
       }
   }
   else {
       Write-Warning "Invalid input. Please enter a number or 'q'."
       return "INVALID"
   }
}

function Show-BackupDetails {
   [CmdletBinding()]
   param(
       [Parameter(Mandatory = $true)]
       [PSCustomObject]$Backup,
       
       [Parameter(Mandatory = $true)]
       [string]$Content
   )

   Write-Host "`n--- Backup Details ---" -ForegroundColor Green
   
   if ($Backup.PSObject.Properties.Name -contains 'ServiceName') {
       Write-Host "Service Name: $($Backup.ServiceName)" -ForegroundColor Cyan
   } else {
       Write-Host "Configuration Type: Static Configuration" -ForegroundColor Cyan
   }
   
   Write-Host "Backup Type: $($Backup.BackupType)" -ForegroundColor Cyan
   Write-Host "Backup Date: $($Backup.FormattedDate)" -ForegroundColor Cyan
   Write-Host "File: $($Backup.FileName)" -ForegroundColor Cyan
   Write-Host "Size: $($Backup.SizeKB) KB" -ForegroundColor Cyan
   Write-Host "`n--- Configuration Content ---" -ForegroundColor Green
   Write-Host $Content -ForegroundColor White
   Write-Host "----------------------------" -ForegroundColor Green
}

# --- Input Functions ---
function Get-ServiceSelection {
   [CmdletBinding()]
   param(
       [Parameter(Mandatory = $true)]
       [string]$Prompt,
       
       [Parameter(Mandatory = $true)]
       [hashtable]$Services
   )

   $choice = Read-Host -Prompt $Prompt
   if ($choice -eq 'q') {
       return $null
   }

   if ($choice -match "^\d+$") {
       $choiceInt = [int]$choice
       if ($Services.ContainsKey($choiceInt)) {
           $selectedFile = $Services[$choiceInt]
           $serviceName = $selectedFile.Replace(".yml", "")
           return $serviceName
       }
       else {
           Write-Warning "Invalid selection. Please enter a valid number."
           return "INVALID"
       }
   }
   else {
       Write-Warning "Invalid input. Please enter a number or 'q'."
       return "INVALID"
   }
}

function Get-DomainSelection {
   [CmdletBinding()]
   param(
       [Parameter(Mandatory = $true)]
       [PSCustomObject]$DomainOptions
   )

   do {
       Write-Host "Choose your domain:" -ForegroundColor Cyan
       $DomainOptions.PSObject.Properties | ForEach-Object { 
           Write-Host "($($_.Name)) $($_.Value)" 
       }
       $domainChoice = Read-Host -Prompt "Enter choice"
       $domainName = $DomainOptions.$domainChoice
       if (-not $domainName) { 
           Write-TraefikLog "Invalid domain choice: $domainChoice" -Level "Warning"
           Write-Host "Invalid choice. Please select a valid option." -ForegroundColor Yellow
       }
   } while (-not $domainName)

   return $domainName
}

function Get-YesNoInput {
   [CmdletBinding()]
   param(
       [Parameter(Mandatory = $true)]
       [string]$Prompt,
       
       [Parameter(Mandatory = $false)]
       [bool]$DefaultToNo = $true
   )

   $defaultText = if ($DefaultToNo) { "(y/N)" } else { "(Y/n)" }
   $input = Read-Host -Prompt "$Prompt $defaultText"
   
   if ($DefaultToNo) {
       return ($input -eq 'y' -or $input -eq 'Y')
   }
   else {
       return ($input -ne 'n' -and $input -ne 'N')
   }
}

function Show-ConfigurationPreview {
   [CmdletBinding()]
   param(
       [Parameter(Mandatory = $true)]
       [string]$ServiceName,
       
       [Parameter(Mandatory = $true)]
       [string]$YamlContent
   )

   Write-Host "`n--- Configuration Preview for '$ServiceName' ---" -ForegroundColor Yellow
   Write-Host $YamlContent -ForegroundColor Cyan
   Write-Host "---------------------------------------------`n" -ForegroundColor Yellow
}

function Show-OperationResult {
   [CmdletBinding()]
   param(
       [Parameter(Mandatory = $true)]
       [bool]$Success,
       
       [Parameter(Mandatory = $true)]
       [string]$Operation,
       
       [Parameter(Mandatory = $true)]
       [string]$ServiceName,
       
       [Parameter(Mandatory = $false)]
       [string]$AdditionalMessage = ""
   )

   if ($Success) {
       Write-Host "$Operation completed successfully for '$ServiceName'!" -ForegroundColor Green
       if ($AdditionalMessage) {
           Write-Host $AdditionalMessage -ForegroundColor Green
       }
   }
   else {
       Write-Host "$Operation failed for '$ServiceName'!" -ForegroundColor Red
       if ($AdditionalMessage) {
           Write-Host $AdditionalMessage -ForegroundColor Red
       }
   }
}

function Show-WelcomeMessage {
   [CmdletBinding()]
   param(
       [Parameter(Mandatory = $true)]
       [string]$ConfigPath,
       
       [Parameter(Mandatory = $true)]
       [string]$LogPath
   )

   Write-Host "Welcome to Traefik Service Manager!" -ForegroundColor Green
   Write-Host "Configuration: $ConfigPath" -ForegroundColor DarkGray
   Write-Host "Log file: $LogPath" -ForegroundColor DarkGray
}

function Show-ErrorMessage {
   [CmdletBinding()]
   param(
       [Parameter(Mandatory = $true)]
       [string]$Message,
       
       [Parameter(Mandatory = $false)]
       [string]$Details = ""
   )

   Write-Host $Message -ForegroundColor Red
   if ($Details) {
       Write-Host "Details: $Details" -ForegroundColor Yellow
   }
}

function Show-WarningMessage {
   [CmdletBinding()]
   param(
       [Parameter(Mandatory = $true)]
       [string]$Message
   )

   Write-Host $Message -ForegroundColor Yellow
}

function Show-InfoMessage {
   [CmdletBinding()]
   param(
       [Parameter(Mandatory = $true)]
       [string]$Message
   )

   Write-Host $Message -ForegroundColor Cyan
}

function Show-SuccessMessage {
   [CmdletBinding()]
   param(
       [Parameter(Mandatory = $true)]
       [string]$Message
   )

   Write-Host $Message -ForegroundColor Green
}

function Wait-ForContinue {
   [CmdletBinding()]
   param(
       [Parameter(Mandatory = $false)]
       [string]$Message = "Press Enter to continue..."
   )

   Read-Host "`n$Message"
}

# Export functions
Export-ModuleMember -Function @(
   'Show-MainMenu',
   'Show-ServiceList',
   'Show-Configuration',
   'Show-ServiceContent',
   'Show-StaticConfigContent',
   'Show-ConnectionTest',
   'Show-BackupTypeSelection',
   'Show-BackupList',
   'Show-AllBackupsView',
   'Get-BackupSelection',
   'Show-BackupDetails',
   'Get-ServiceSelection',
   'Get-DomainSelection',
   'Get-YesNoInput',
   'Show-ConfigurationPreview',
   'Show-OperationResult',
   'Show-WelcomeMessage',
   'Show-ErrorMessage',
   'Show-WarningMessage',
   'Show-InfoMessage',
   'Show-SuccessMessage',
   'Wait-ForContinue'
   'Show-TemplateMenu',
   'Show-TemplateList',
   'Get-TemplateSelection',
   'Show-TemplatePreview'
)