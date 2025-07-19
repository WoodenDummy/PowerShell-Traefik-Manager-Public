# TraefikManager.Wizard.psm1
# First-run setup wizard and configuration guidance for Traefik Manager

#Requires -Version 5.1
Set-StrictMode -Version Latest

# --- Main Wizard Orchestration ---
function Start-FirstRunWizard {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConfigPath
    )

    try {
        Write-Host "`n=== Traefik Manager Configuration Setup ===" -ForegroundColor Green
        Write-Host "This wizard will help you configure Traefik Manager for your environment.`n" -ForegroundColor Cyan

        # Step 1: Check experience level
        $isNewUser = Get-ExperienceLevel
        
        # Step 2: Static configuration for new users
        $staticConfigInfo = $null
        if ($isNewUser) {
            $staticConfigInfo = Get-StaticConfigurationWizard
        }

        # Step 3: Get Traefik server details
        $serverConfig = Get-TraefikServerConfiguration

        # Step 4: Get domain configuration
        $domainConfig = Get-DomainConfiguration -StaticConfigInfo $staticConfigInfo

        # Step 5: Get editor and backup preferences
        $editorConfig = Get-EditorConfiguration
        $backupConfig = Get-BackupConfiguration

        # Step 6: Advanced settings (optional)
        $advancedConfig = Get-AdvancedConfiguration

        # Step 7: Build final configuration
        $finalConfig = Build-FinalConfiguration -ServerConfig $serverConfig -DomainConfig $domainConfig -EditorConfig $editorConfig -BackupConfig $backupConfig -AdvancedConfig $advancedConfig -StaticConfigInfo $staticConfigInfo

        # Step 8: Show summary and confirm
        $confirmed = Show-ConfigurationSummary -Config $finalConfig
        if (-not $confirmed) {
            Write-Host "Configuration cancelled." -ForegroundColor Yellow
            return $null
        }

        # Step 9: Save configuration
        try {
            $finalConfig | ConvertTo-Json -Depth 10 | Set-Content $ConfigPath -ErrorAction Stop
            Write-Host "`nConfiguration saved successfully to: $ConfigPath" -ForegroundColor Green
            Write-TraefikLog "Configuration initialized and saved to: $ConfigPath" -Level "Success"
            
            # Step 10: Deploy static config if generated
            if ($staticConfigInfo -and $staticConfigInfo.ShouldDeploy) {
                Deploy-GeneratedStaticConfig -StaticConfigInfo $staticConfigInfo -ServerConfig $serverConfig
            }
            
            Show-SetupCompletionMessage -StaticConfigGenerated ($null -ne $staticConfigInfo)
            return $finalConfig
        }
        catch {
            Write-Host "Failed to save configuration: $($_.Exception.Message)" -ForegroundColor Red
            Write-TraefikLog "Failed to save configuration: $($_.Exception.Message)" -Level "Error"
            return $null
        }
    }
    catch {
        Write-TraefikLog "Error in wizard: $($_.Exception.Message)" -Level "Error"
        Write-Host "An error occurred during setup: $($_.Exception.Message)" -ForegroundColor Red
        return $null
    }
}

# --- Experience Level Check ---
function Get-ExperienceLevel {
    Write-Host "--- Experience Level Check ---" -ForegroundColor Yellow
    $isNew = Get-YesNoInput -Prompt "Are you new to Traefik reverse proxy?" -DefaultToNo $false
    Write-TraefikLog "User experience level - New user: $isNew" -Level "Info"
    return $isNew
}

# --- Static Configuration Wizard ---
function Get-StaticConfigurationWizard {
    Write-Host "`n--- Static Configuration Generation ---" -ForegroundColor Yellow
    Write-Host "I can generate a basic Traefik static configuration file for you." -ForegroundColor Cyan
    Write-Host "This will create a complete working Traefik setup with SSL certificates." -ForegroundColor Cyan
    
    $wantStaticConfig = Get-YesNoInput -Prompt "Generate static configuration?" -DefaultToNo $false
    
    if (-not $wantStaticConfig) {
        Write-TraefikLog "User declined static config generation" -Level "Info"
        return $null
    }

    # Domain ownership check
    $domainInfo = Get-DomainOwnershipConfiguration
    
    # DNS provider setup
    $dnsInfo = Get-DNSProviderConfiguration -DomainInfo $domainInfo
    
    # Email for Let's Encrypt
    $email = Get-LetsEncryptEmail
    
    # Upload preference
    $shouldUpload = Get-YesNoInput -Prompt "Upload static configuration to your Traefik server after generation?" -DefaultToNo $false

    return @{
        Domain = $domainInfo.Domain
        DNSProvider = $dnsInfo.Provider
        APIToken = $dnsInfo.Token
        Email = $email
        ShouldDeploy = $shouldUpload
        CertResolver = "letsencrypt"
    }
}

function Get-DomainOwnershipConfiguration {
    Write-Host "`n--- Domain Configuration ---" -ForegroundColor Yellow
    $ownsDomain = Get-YesNoInput -Prompt "Do you own a domain?" -DefaultToNo $true
    
    if ($ownsDomain) {
        $domain = Get-ValidatedInput -Prompt "Enter your domain (e.g., example.com)" -ValidationFunction { 
            param($d) $d -and $d.Trim() -and $d -match '^[a-zA-Z0-9][a-zA-Z0-9\-\.]*[a-zA-Z0-9]$' 
        } -ErrorMessage "Invalid domain format"
        
        return @{
            Domain = $domain.Trim()
            IsDuckDNS = $false
        }
    }
    else {
        Write-Host "`n--- Free Domain Option ---" -ForegroundColor Yellow
        Write-Host "I can help you set up a free subdomain with Duck DNS (yourname.duckdns.org)." -ForegroundColor Cyan
        Write-Host "This is perfect for getting started and supports Let's Encrypt certificates." -ForegroundColor Cyan
        
        $useDuckDNS = Get-YesNoInput -Prompt "Use Duck DNS for free subdomain?" -DefaultToNo $false
        
        if ($useDuckDNS) {
            Show-DuckDNSSetupGuidance
            
            $subdomain = Get-ValidatedInput -Prompt "Enter your Duck DNS subdomain (without .duckdns.org)" -ValidationFunction {
                param($s) $s -and $s.Trim() -and $s -match '^[a-zA-Z0-9][a-zA-Z0-9\-]*[a-zA-Z0-9]$'
            } -ErrorMessage "Invalid subdomain format (letters, numbers, hyphens only)"
            
            return @{
                Domain = "$($subdomain.Trim()).duckdns.org"
                IsDuckDNS = $true
                Subdomain = $subdomain.Trim()
            }
        }
        else {
            throw "Domain is required for Traefik setup. Please obtain a domain or use Duck DNS."
        }
    }
}

function Get-DNSProviderConfiguration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$DomainInfo
    )

    if ($DomainInfo.IsDuckDNS) {
        # Duck DNS setup
        $token = Get-ValidatedInput -Prompt "Enter your Duck DNS token" -ValidationFunction {
            param($t) $t -and $t.Trim() -and $t.Length -gt 10
        } -ErrorMessage "Duck DNS token appears invalid"
        
        Write-Host "Testing Duck DNS credentials..." -ForegroundColor Cyan
        $isValid = Test-DNSCredentials -Provider "duckdns" -Token $token.Trim() -Domain $DomainInfo.Subdomain
        
        if ($isValid) {
            Write-Host "✓ Duck DNS credentials validated successfully!" -ForegroundColor Green
        }
        else {
            Write-Host "❌ Duck DNS credential validation failed. Please check your token and subdomain." -ForegroundColor Red
            throw "Invalid Duck DNS credentials"
        }
        
        return @{
            Provider = "duckdns"
            Token = $token.Trim()
        }
    }
    else {
        # Cloudflare setup (recommended for owned domains)
        Write-Host "`n--- DNS Provider Selection ---" -ForegroundColor Yellow
        Write-Host "For Let's Encrypt certificates with your domain, you'll need a DNS provider." -ForegroundColor Cyan
        Write-Host "Cloudflare is recommended for beginners (free tier available)." -ForegroundColor Cyan
        
        $useCloudflare = Get-YesNoInput -Prompt "Use Cloudflare as your DNS provider?" -DefaultToNo $false
        
        if ($useCloudflare) {
            Show-CloudflareSetupGuidance
            
            $token = Get-ValidatedInput -Prompt "Enter your Cloudflare API token" -ValidationFunction {
                param($t) $t -and $t.Trim() -and $t.Length -gt 10
            } -ErrorMessage "Cloudflare API token appears invalid"
            
            Write-Host "Testing Cloudflare credentials..." -ForegroundColor Cyan
            $isValid = Test-DNSCredentials -Provider "cloudflare" -Token $token.Trim()
            
            if ($isValid) {
                Write-Host "✓ Cloudflare credentials validated successfully!" -ForegroundColor Green
            }
            else {
                Write-Host "❌ Cloudflare credential validation failed. Please check your API token permissions." -ForegroundColor Red
                throw "Invalid Cloudflare credentials"
            }
            
            return @{
                Provider = "cloudflare"
                Token = $token.Trim()
            }
        }
        else {
            Write-Host "Other DNS providers are not currently supported in this wizard." -ForegroundColor Yellow
            Write-Host "You can manually configure your static configuration later." -ForegroundColor Yellow
            throw "DNS provider configuration cancelled"
        }
    }
}

function Get-LetsEncryptEmail {
    $email = Get-ValidatedInput -Prompt "Enter your email address for Let's Encrypt certificates" -ValidationFunction {
        param($e) $e -and $e.Trim() -and $e -match '^[^@]+@[^@]+\.[^@]+$'
    } -ErrorMessage "Invalid email address format"
    
    return $email.Trim()
}

# --- Server Configuration ---
function Get-TraefikServerConfiguration {
    Write-Host "`n--- Traefik Server Configuration ---" -ForegroundColor Yellow
    
    $traefikIp = Get-ValidatedInput -Prompt "Enter the IP address of your Traefik server" -ValidationFunction { 
        param($ip) Test-IPAddress $ip 
    } -ErrorMessage "Invalid IP address format (e.g., 192.168.1.100)"
    
    $sshUser = Get-ValidatedInput -Prompt "Enter the SSH username for the Traefik server (typically 'root')" -ValidationFunction { 
        param($user) $user -and $user.Trim().Length -gt 0 
    } -ErrorMessage "Username cannot be empty"
    
    $sshPort = Get-ValidatedInput -Prompt "Enter the SSH port (default: 22)" -ValidationFunction { 
        param($port) if ([string]::IsNullOrWhiteSpace($port)) { $true } else { Test-PortNumber $port } 
    } -ErrorMessage "Invalid port number"
    if ([string]::IsNullOrWhiteSpace($sshPort)) { $sshPort = "22" }
    
    $configDir = Read-Host -Prompt "Enter the remote Traefik configuration directory (default: /etc/traefik/conf.d)"
    if ([string]::IsNullOrWhiteSpace($configDir)) { $configDir = "/etc/traefik/conf.d" }

    return @{
        TraefikLxcIp = $traefikIp
        TraefikSshUser = $sshUser.Trim()
        RemoteConfigDir = $configDir
        SSHPort = [int]$sshPort
    }
}

# --- Domain Configuration ---
function Get-DomainConfiguration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [hashtable]$StaticConfigInfo = $null
    )

    Write-Host "`n--- Domain Configuration for Services ---" -ForegroundColor Yellow
    
    $domains = @{}
    $domainIndex = 1
    
    # If static config was generated, use that domain as primary
    if ($StaticConfigInfo) {
        Write-Host "Domain 1 will be automatically set to: $($StaticConfigInfo.Domain)" -ForegroundColor Green
        $domains["1"] = $StaticConfigInfo.Domain
        $domainIndex = 2
    }
    
    # Ask for additional domains
    do {
        if ($domainIndex -eq 1) {
            $domain = Read-Host -Prompt "Enter domain $domainIndex (e.g., example.com)"
        } else {
            $domain = Read-Host -Prompt "Enter additional domain $domainIndex (or press Enter to skip)"
        }
        
        if ($domain -and $domain.Trim()) {
            $domains[$domainIndex.ToString()] = $domain.Trim()
            $domainIndex++
        }
        
        if ($domainIndex -eq 2 -and $domains.Count -eq 0) {
            # No primary domain set, continue asking
            $addMore = $true
        } elseif ($domainIndex -gt 2) {
            $addMore = Get-YesNoInput -Prompt "Add another domain?" -DefaultToNo $true
        } else {
            $addMore = Get-YesNoInput -Prompt "Add another domain?" -DefaultToNo $true
        }
    } while ($addMore -and $domainIndex -le 10)

    if ($domains.Count -eq 0) {
        Write-Host "No domains configured. Adding a default placeholder." -ForegroundColor Yellow
        $domains["1"] = "example.com"
    }

    return $domains
}

# --- Editor Configuration ---
function Get-EditorConfiguration {
    Write-Host "`n--- Editor Configuration ---" -ForegroundColor Yellow
    Write-Host "Choose your preferred text editor for editing configurations:" -ForegroundColor Cyan
    Write-Host "1. Notepad (Windows default)" -ForegroundColor White
    Write-Host "2. Visual Studio Code" -ForegroundColor White
    Write-Host "3. Notepad++" -ForegroundColor White
    Write-Host "4. Custom editor" -ForegroundColor White
    
    do {
        $editorChoice = Read-Host -Prompt "Enter your choice (1-4)"
        $editor = switch ($editorChoice) {
            "1" { "notepad.exe" }
            "2" { "code.exe" }
            "3" { "notepad++.exe" }
            "4" { 
                $customEditor = Read-Host -Prompt "Enter the full path or command for your editor"
                if ($customEditor -and $customEditor.Trim()) { $customEditor.Trim() } else { "notepad.exe" }
            }
            default { $null }
        }
    } while (-not $editor)

    return $editor
}

# --- Backup Configuration ---
function Get-BackupConfiguration {
    Write-Host "`n--- Backup Configuration ---" -ForegroundColor Yellow
    $backupEnabled = Get-YesNoInput -Prompt "Enable automatic backups when editing/removing configurations?" -DefaultToNo $false

    return @{
        BackupEnabled = $backupEnabled
        BackupDirectory = "backups"
    }
}

# --- Advanced Configuration ---
function Get-AdvancedConfiguration {
    Write-Host "`n--- Advanced Settings ---" -ForegroundColor Yellow
    $showAdvanced = Get-YesNoInput -Prompt "Configure advanced connection settings?" -DefaultToNo $true
    
    $maxRetries = 3
    $retryDelay = 2
    $timeout = 30
    
    if ($showAdvanced) {
        $maxRetriesInput = Read-Host -Prompt "Maximum connection retries (default: 3)"
        if ($maxRetriesInput -and $maxRetriesInput -match "^\d+$") { $maxRetries = [int]$maxRetriesInput }
        
        $retryDelayInput = Read-Host -Prompt "Retry delay in seconds (default: 2)"
        if ($retryDelayInput -and $retryDelayInput -match "^\d+$") { $retryDelay = [int]$retryDelayInput }
        
        $timeoutInput = Read-Host -Prompt "Connection timeout in seconds (default: 30)"
        if ($timeoutInput -and $timeoutInput -match "^\d+$") { $timeout = [int]$timeoutInput }
    }

    return @{
        MaxRetries = $maxRetries
        RetryDelaySeconds = $retryDelay
        TimeoutSeconds = $timeout
    }
}

# --- Configuration Building ---
function Build-FinalConfiguration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$ServerConfig,
        
        [Parameter(Mandatory = $true)]
        [hashtable]$DomainConfig,
        
        [Parameter(Mandatory = $true)]
        [string]$EditorConfig,
        
        [Parameter(Mandatory = $true)]
        [hashtable]$BackupConfig,
        
        [Parameter(Mandatory = $true)]
        [hashtable]$AdvancedConfig,
        
        [Parameter(Mandatory = $false)]
        [hashtable]$StaticConfigInfo = $null
    )

    $config = [PSCustomObject]@{
        TraefikLxcIp = $ServerConfig.TraefikLxcIp
        TraefikSshUser = $ServerConfig.TraefikSshUser
        RemoteConfigDir = $ServerConfig.RemoteConfigDir
        DomainOptions = [PSCustomObject]$DomainConfig
        ConnectionSettings = [PSCustomObject]@{
            MaxRetries = $AdvancedConfig.MaxRetries
            RetryDelaySeconds = $AdvancedConfig.RetryDelaySeconds
            TimeoutSeconds = $AdvancedConfig.TimeoutSeconds
            SSHPort = $ServerConfig.SSHPort
        }
        LogLevel = "Info"
        Editor = $EditorConfig
        BackupEnabled = $BackupConfig.BackupEnabled
        BackupDirectory = $BackupConfig.BackupDirectory
        ConfigVersion = "1.1"
        CreatedDate = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    }

    # Add static config info if generated
    if ($StaticConfigInfo) {
        $config | Add-Member -NotePropertyName "StaticConfigGenerated" -NotePropertyValue $true
        $config | Add-Member -NotePropertyName "CertificateResolver" -NotePropertyValue $StaticConfigInfo.CertResolver
        $config | Add-Member -NotePropertyName "DNSProvider" -NotePropertyValue $StaticConfigInfo.DNSProvider
        $config | Add-Member -NotePropertyName "PrimaryDomain" -NotePropertyValue $StaticConfigInfo.Domain
    } else {
        $config | Add-Member -NotePropertyName "StaticConfigGenerated" -NotePropertyValue $false
        $config | Add-Member -NotePropertyName "CertificateResolver" -NotePropertyValue "letsencrypt"
    }

    return $config
}

# --- Configuration Summary ---
function Show-ConfigurationSummary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Config
    )

    Write-Host "`n--- Configuration Summary ---" -ForegroundColor Green
    Write-Host "Traefik Server: $($Config.TraefikSshUser)@$($Config.TraefikLxcIp):$($Config.ConnectionSettings.SSHPort)" -ForegroundColor Cyan
    Write-Host "Configuration Directory: $($Config.RemoteConfigDir)" -ForegroundColor Cyan
    
    if ($Config.StaticConfigGenerated) {
        Write-Host "Static Config: Generated for $($Config.PrimaryDomain) using $($Config.DNSProvider)" -ForegroundColor Cyan
    } else {
        Write-Host "Static Config: Will use existing configuration" -ForegroundColor Cyan
    }
    
    $domainList = @()
    $Config.DomainOptions.PSObject.Properties | ForEach-Object { $domainList += $_.Value }
    Write-Host "Domains: $($domainList -join ', ')" -ForegroundColor Cyan
    Write-Host "Certificate Resolver: $($Config.CertificateResolver)" -ForegroundColor Cyan
    Write-Host "Editor: $($Config.Editor)" -ForegroundColor Cyan
    Write-Host "Backups Enabled: $($Config.BackupEnabled)" -ForegroundColor Cyan
    Write-Host "----------------------------" -ForegroundColor Green

    $confirm = Get-YesNoInput -Prompt "Save this configuration?" -DefaultToNo $false
    return $confirm
}

# --- Static Config Deployment ---
function Deploy-GeneratedStaticConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$StaticConfigInfo,
        
        [Parameter(Mandatory = $true)]
        [hashtable]$ServerConfig
    )

    try {
        Write-Host "`n--- Deploying Static Configuration ---" -ForegroundColor Yellow
        
        # Generate static config content
        $staticContent = New-TraefikStaticYaml -Email $StaticConfigInfo.Email -Domain $StaticConfigInfo.Domain -DNSProvider $StaticConfigInfo.DNSProvider -APIToken $StaticConfigInfo.APIToken -CertResolver $StaticConfigInfo.CertResolver -ConfigDirectory $ServerConfig.RemoteConfigDir

        # Get SSH password
        $password = Get-SshPassword -User $ServerConfig.TraefikSshUser -SshHost $ServerConfig.TraefikLxcIp
        if (-not $password) { 
            Write-Host "SSH authentication cancelled. Static configuration not deployed." -ForegroundColor Yellow
            return 
        }

        # Deploy static config
        Write-Host "Uploading static configuration..." -ForegroundColor Cyan
        $success = Deploy-StaticConfig -StaticConfigContent $staticContent -User $ServerConfig.TraefikSshUser -SshHost $ServerConfig.TraefikLxcIp -Password $password -Port $ServerConfig.SSHPort

        if ($success) {
            Write-Host "✓ Static configuration uploaded successfully!" -ForegroundColor Green
        } else {
            Write-Host "❌ Failed to upload static configuration." -ForegroundColor Red
        }
    }
    catch {
        Write-TraefikLog "Error deploying static config: $($_.Exception.Message)" -Level "Error"
        Write-Host "Error deploying static configuration: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# --- Setup Guidance Functions ---
function Show-DuckDNSSetupGuidance {
    Write-Host "`n--- Duck DNS Setup Guide ---" -ForegroundColor Yellow
    Write-Host "1. Go to https://www.duckdns.org" -ForegroundColor White
    Write-Host "2. Sign in with your preferred account (Google, GitHub, etc.)" -ForegroundColor White
    Write-Host "3. Create a subdomain (e.g., 'mytraefik' → mytraefik.duckdns.org)" -ForegroundColor White
    Write-Host "4. Copy your Duck DNS token from the dashboard" -ForegroundColor White
    Write-Host ""
}

function Show-CloudflareSetupGuidance {
    Write-Host "`n--- Cloudflare Setup Guide ---" -ForegroundColor Yellow
    Write-Host "To use Cloudflare with Let's Encrypt:" -ForegroundColor White
    Write-Host "1. Create a Cloudflare account at https://cloudflare.com" -ForegroundColor White
    Write-Host "2. Add your domain to Cloudflare" -ForegroundColor White
    Write-Host "3. Update your domain's nameservers to Cloudflare's" -ForegroundColor White
    Write-Host "4. Go to My Profile → API Tokens → Create Token" -ForegroundColor White
    Write-Host "5. Use 'Custom token' with Zone:Zone:Read, Zone:DNS:Edit permissions" -ForegroundColor White
    Write-Host ""
}

function Show-SetupCompletionMessage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [bool]$StaticConfigGenerated
    )

    Write-Host "`n--- Setup Complete ---" -ForegroundColor Green
    
    if ($StaticConfigGenerated) {
        Write-Host "✓ Static configuration generated and uploaded" -ForegroundColor Green
        Write-Host "✓ Dynamic configuration template ready" -ForegroundColor Green
        Write-Host "✓ SSL certificates will be automatically generated" -ForegroundColor Green
        Write-Host "`nNext steps:" -ForegroundColor Yellow
        Write-Host "1. Restart Traefik: sudo systemctl restart traefik" -ForegroundColor White
        Write-Host "2. Use this tool to add your first service" -ForegroundColor White
        Write-Host "3. Services will be available at: servicename.yourdomain.com" -ForegroundColor White
    } else {
        Write-Host "✓ Dynamic configuration template ready" -ForegroundColor Green
        Write-Host "✓ Tool configured for your existing Traefik setup" -ForegroundColor Green
        Write-Host "`nNext steps:" -ForegroundColor Yellow
        Write-Host "1. Use this tool to add your first service" -ForegroundColor White
        Write-Host "2. Ensure your static configuration is compatible" -ForegroundColor White
    }
    
    Write-Host "`n💡 Tip: Use 'Test Connection' to verify your setup before adding services." -ForegroundColor Cyan
}

# Export functions
Export-ModuleMember -Function @(
    'Start-FirstRunWizard',
    'Get-ExperienceLevel',
    'Show-DuckDNSSetupGuidance',
    'Show-CloudflareSetupGuidance',
    'Show-SetupCompletionMessage'
)