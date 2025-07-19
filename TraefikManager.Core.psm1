# TraefikManager.Core.psm1
# Core functionality for Traefik Manager

#Requires -Version 5.1
Set-StrictMode -Version Latest

# Module variables
$script:ModuleConfig = $null
$script:SecurePassword = $null
$script:EncryptedCredentialFile = $null

# --- Logging Functions ---
function Write-TraefikLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,
        
        [Parameter(Mandatory = $false)]
        [ValidateSet("Info", "Warning", "Error", "Success", "Debug")]
        [string]$Level = "Info",
        
        [Parameter(Mandatory = $false)]
        [string]$LogPath
    )
    
    if (-not $LogPath) {
        $LogPath = Join-Path (Get-Location) "traefik-manager.log"
    }
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "[$timestamp] [$Level] $Message"
    
    $colors = @{
        "Info"    = "White"
        "Warning" = "Yellow" 
        "Error"   = "Red"
        "Success" = "Green"
        "Debug"   = "Gray"
    }
    
    # Only show debug messages if in debug mode
    if ($Level -eq "Debug" -and $DebugPreference -ne "Continue") {
        return
    }
    
    Write-Host $logEntry -ForegroundColor $colors[$Level]
    
    # Safe logging with retry
    $maxRetries = 3
    $retryCount = 0
    
    do {
        try {
            $logEntry | Add-Content -Path $LogPath -ErrorAction Stop
            break
        }
        catch {
            $retryCount++
            if ($retryCount -ge $maxRetries) {
                Write-Warning "Failed to write to log file after $maxRetries attempts: $($_.Exception.Message)"
                break
            }
            Start-Sleep -Milliseconds 100
        }
    } while ($retryCount -lt $maxRetries)
}

# --- Configuration Management ---
function Get-TraefikConfiguration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$ConfigPath = "config.json"
    )
    
    if (Test-Path $ConfigPath) {
        try {
            $configContent = Get-Content $ConfigPath -Raw -ErrorAction Stop
            $config = $configContent | ConvertFrom-Json -ErrorAction Stop
            
            # Validate configuration
            $validationResult = Test-ConfigurationFile -Config $config
            
            if (-not $validationResult.Valid) {
                Write-TraefikLog "Configuration file validation failed: $($validationResult.Issues -join ', ')" -Level "Warning"
                Write-Host "Configuration file exists but has issues:" -ForegroundColor Yellow
                foreach ($issue in $validationResult.Issues) {
                    Write-Host "  • $issue" -ForegroundColor Red
                }
                
                $recreate = Get-YesNoInput -Prompt "Would you like to run the configuration wizard again?" -DefaultToNo $false
                
                if ($recreate) {
                    $newConfig = Start-FirstRunWizard -ConfigPath $ConfigPath
                    if ($newConfig) {
                        $script:ModuleConfig = $newConfig
                        return $newConfig
                    }
                }
                
                throw "Configuration file has issues and user declined to recreate it."
            }
            
            Write-TraefikLog "Configuration loaded successfully from: $ConfigPath" -Level "Success"
            $script:ModuleConfig = $config
            return $config
        }
        catch {
            Write-TraefikLog "Error reading config file: $($_.Exception.Message)" -Level "Error"
            Write-Host "Error reading configuration file: $($_.Exception.Message)" -ForegroundColor Red
            
            $recreate = Get-YesNoInput -Prompt "Would you like to run the configuration wizard to create a new configuration?" -DefaultToNo $false
            
            if ($recreate) {
                $newConfig = Start-FirstRunWizard -ConfigPath $ConfigPath
                if ($newConfig) {
                    $script:ModuleConfig = $newConfig
                    return $newConfig
                }
            }
            
            throw "Failed to load or create configuration."
        }
    }
    
    # No config file exists - run initialization wizard
    Write-Host "No configuration file found. Running the setup wizard..." -ForegroundColor Yellow
    $newConfig = Start-FirstRunWizard -ConfigPath $ConfigPath
    
    if (-not $newConfig) {
        throw "Configuration setup was cancelled or failed."
    }
    
    $script:ModuleConfig = $newConfig
    return $newConfig
}

function Test-ConfigurationFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Config
    )
    
    $issues = @()
    $requiredProperties = @('TraefikLxcIp', 'TraefikSshUser', 'RemoteConfigDir', 'DomainOptions')
    
    # Check required properties
    foreach ($prop in $requiredProperties) {
        if (-not $Config.PSObject.Properties.Name.Contains($prop)) {
            $issues += "Missing required property: $prop"
        }
    }
    
    # Check ConnectionSettings
    if (-not $Config.PSObject.Properties.Name.Contains('ConnectionSettings')) {
        $issues += "Missing ConnectionSettings section"
    } elseif (-not $Config.ConnectionSettings.PSObject.Properties.Name.Contains('SSHPort')) {
        $issues += "Missing SSH port in ConnectionSettings"
    }
    
    # Check for certificate resolver (new in v1.1)
    if (-not $Config.PSObject.Properties.Name.Contains('CertificateResolver')) {
        $issues += "Missing certificate resolver configuration (legacy config detected)"
    }
    
    # Validate IP address format
    if ($Config.TraefikLxcIp -and -not (Test-IPAddress $Config.TraefikLxcIp)) {
        $issues += "Invalid IP address format: $($Config.TraefikLxcIp)"
    }
    
    return [PSCustomObject]@{
        Valid = ($issues.Count -eq 0)
        Issues = $issues
    }
}

# --- Input Validation Functions ---
function Test-IPAddress {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$IPAddress
    )
    
    if ([string]::IsNullOrWhiteSpace($IPAddress)) {
        return $false
    }
    
    try {
        $null = [System.Net.IPAddress]::Parse($IPAddress)
        return $true
    }
    catch {
        return $false
    }
}

function Test-ServiceName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$ServiceName
    )
    
    if ([string]::IsNullOrWhiteSpace($ServiceName)) {
        return $false
    }
    
    $servicePattern = '^[a-zA-Z0-9]([a-zA-Z0-9_-]*[a-zA-Z0-9])?$'
    return ($ServiceName -match $servicePattern) -and 
           ($ServiceName.Length -ge 2) -and 
           ($ServiceName.Length -le 50) -and
           ($ServiceName -notmatch '^-|-$|^_|_$')
}

function Test-PortNumber {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Port
    )
    
    if ([string]::IsNullOrWhiteSpace($Port)) {
        return $false
    }
    
    $portNum = 0
    if ([int]::TryParse($Port, [ref]$portNum)) {
        return ($portNum -ge 1 -and $portNum -le 65535)
    }
    return $false
}

function Get-ValidatedInput {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Prompt,
        
        [Parameter(Mandatory = $true)]
        [scriptblock]$ValidationFunction,
        
        [Parameter(Mandatory = $true)]
        [string]$ErrorMessage,
        
        [Parameter(Mandatory = $false)]
        [int]$MaxAttempts = 3
    )
    
    $attempts = 0
    do {
        $attempts++
        $input = Read-Host -Prompt $Prompt
        
        if (& $ValidationFunction $input) {
            return $input
        }
        
        Write-TraefikLog $ErrorMessage -Level "Warning"
        
        if ($attempts -ge $MaxAttempts) {
            Write-TraefikLog "Maximum validation attempts reached." -Level "Error"
            throw "Input validation failed after $MaxAttempts attempts"
        }
    } while ($attempts -lt $MaxAttempts)
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

# --- SSH Password Management ---
function Get-SshPassword {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$User,
        
        [Parameter(Mandatory = $true)]
        [string]$SshHost
    )

    # Initialize credential file path if not set
    if (-not $script:EncryptedCredentialFile) {
        $script:EncryptedCredentialFile = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "temp_ssh_cred_$(Get-Random).xml"
    }

    # Try cached password first
    if ($script:SecurePassword -and (Test-Path $script:EncryptedCredentialFile)) {
        try {
            $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($script:SecurePassword)
            $password = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
            [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
            return $password
        }
        catch {
            Write-TraefikLog "Failed to use cached password: $($_.Exception.Message)" -Level "Warning"
        }
    }

    # Try encrypted file
    if (Test-Path $script:EncryptedCredentialFile) {
        try {
            $script:SecurePassword = Import-CliXml -Path $script:EncryptedCredentialFile -ErrorAction Stop
            
            if ($script:SecurePassword -is [System.Security.SecureString]) {
                $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($script:SecurePassword)
                $password = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
                [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
                Write-TraefikLog "Password retrieved from encrypted file." -Level "Success"
                return $password
            }
        }
        catch {
            Write-TraefikLog "Could not retrieve password from encrypted file: $($_.Exception.Message)" -Level "Warning"
        }
    }

    # Prompt for new password
    Write-TraefikLog "Prompting for SSH password..." -Level "Info"
    $script:SecurePassword = Read-Host -Prompt "Enter SSH password for $User@$SshHost" -AsSecureString
    
    # Save to encrypted file
    try {
        $script:SecurePassword | Export-CliXml -Path $script:EncryptedCredentialFile -Force -ErrorAction Stop
Write-TraefikLog "Password saved to encrypted file." -Level "Success"
    }
    catch {
        Write-TraefikLog "Failed to save password: $($_.Exception.Message)" -Level "Warning"
    }

    # Convert to plain text
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($script:SecurePassword)
    $password = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
    [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    
    return $password
}

# --- Cleanup Functions ---
function Clear-TraefikSensitiveData {
    [CmdletBinding()]
    param()
    
    Write-TraefikLog "Clearing sensitive data from memory..." -Level "Debug"
    
    try {
        if ($script:SecurePassword -is [System.Security.SecureString]) {
            $script:SecurePassword.Dispose()
            $script:SecurePassword = $null
        }
        
        [System.GC]::Collect()
        [System.GC]::WaitForPendingFinalizers()
        [System.GC]::Collect()
        
        Write-TraefikLog "Sensitive data cleared from memory." -Level "Success"
    }
    catch {
        Write-TraefikLog "Error clearing sensitive data: $($_.Exception.Message)" -Level "Warning"
    }
}

function Remove-TraefikTemporaryFiles {
    [CmdletBinding()]
    param()
    
    Write-TraefikLog "Cleaning up temporary files..." -Level "Debug"
    
    try {
        if ($script:EncryptedCredentialFile -and (Test-Path $script:EncryptedCredentialFile)) {
            Remove-Item $script:EncryptedCredentialFile -Force -ErrorAction SilentlyContinue
            Write-TraefikLog "Temporary encrypted credential file removed." -Level "Success"
        }
        
        # Clean up other temp files
        $tempPath = [System.IO.Path]::GetTempPath()
        $tempFiles = @()
        
        try {
            $tempFiles += Get-ChildItem -Path $tempPath -Filter "*_traefik_config*.yml" -ErrorAction SilentlyContinue
            $tempFiles += Get-ChildItem -Path $tempPath -Filter "edit_*.yml" -ErrorAction SilentlyContinue
            $tempFiles += Get-ChildItem -Path $tempPath -Filter "temp_ssh_cred_*.xml" -ErrorAction SilentlyContinue
        }
        catch {
            # Ignore errors finding temp files
        }
        
        foreach ($file in $tempFiles) {
            try {
                Remove-Item $file.FullName -Force -ErrorAction SilentlyContinue
            }
            catch {
                # Ignore errors removing individual files
            }
        }
    }
    catch {
        Write-TraefikLog "Error cleaning temporary files: $($_.Exception.Message)" -Level "Warning"
    }
}

# Export functions
Export-ModuleMember -Function @(
    'Write-TraefikLog',
    'Get-TraefikConfiguration',
    'Test-ConfigurationFile',
    'Test-IPAddress',
    'Test-ServiceName', 
    'Test-PortNumber',
    'Get-ValidatedInput',
    'Get-YesNoInput',
    'Get-SshPassword',
    'Clear-TraefikSensitiveData',
    'Remove-TraefikTemporaryFiles'
)