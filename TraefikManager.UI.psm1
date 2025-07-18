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
    Write-Host "6. Show Configuration" -ForegroundColor Yellow
    Write-Host "7. Test Connection" -ForegroundColor Yellow
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
    'Show-ConnectionTest',
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
)