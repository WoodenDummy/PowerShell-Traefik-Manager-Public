# TraefikManager.ConfigSync.psm1
# Configuration synchronization and compatibility checking for Traefik Manager

#Requires -Version 5.1
Set-StrictMode -Version Latest

# --- Configuration Compatibility Testing ---
function Test-ConfigCompatibility {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Config,
        
        [Parameter(Mandatory = $true)]
        [string]$User,
        
        [Parameter(Mandatory = $true)]
        [string]$SshHost,
        
        [Parameter(Mandatory = $true)]
        [string]$Password,
        
        [Parameter(Mandatory = $false)]
        [int]$Port = 22
    )

    try {
        Write-TraefikLog "Testing configuration compatibility..." -Level "Info"
        
        # Get current static configuration
        $staticConfig = Get-StaticConfigContent -User $User -SshHost $SshHost -Password $Password -Port $Port
        
        if (-not $staticConfig) {
            return [PSCustomObject]@{
                Compatible = $false
                Issues = @("Could not retrieve static configuration from server")
                Recommendations = @("Ensure Traefik static configuration exists at /etc/traefik/traefik.yaml")
                StaticConfig = $null
            }
        }

        # Parse static configuration
        $parsedStatic = Parse-StaticConfiguration -ConfigContent $staticConfig
        
        # Compare with tool configuration
        $issues = @()
        $recommendations = @()
        
        # Check certificate resolver
        if ($parsedStatic.CertResolvers -notcontains $Config.CertificateResolver) {
            $issues += "Certificate resolver '$($Config.CertificateResolver)' not found in static config"
            if ($parsedStatic.CertResolvers.Count -gt 0) {
                $recommendations += "Available resolvers: $($parsedStatic.CertResolvers -join ', ')"
                $recommendations += "Update tool config or add resolver to static config"
            } else {
                $recommendations += "Add certificate resolver '$($Config.CertificateResolver)' to static configuration"
            }
        }
        
        # Check entry points
        if ($parsedStatic.EntryPoints -notcontains "websecure") {
            $issues += "Entry point 'websecure' not found in static config"
            if ($parsedStatic.EntryPoints.Count -gt 0) {
                $recommendations += "Available entry points: $($parsedStatic.EntryPoints -join ', ')"
                $recommendations += "Update static config or modify dynamic service templates"
            } else {
                $recommendations += "Add 'websecure' entry point to static configuration"
            }
        }
        
        # Check file provider configuration
        if (-not $parsedStatic.FileProviderEnabled) {
            $issues += "File provider not enabled in static configuration"
            $recommendations += "Add file provider with directory: $($Config.RemoteConfigDir)"
        } elseif ($parsedStatic.FileProviderDirectory -ne $Config.RemoteConfigDir) {
            $issues += "File provider directory mismatch: static config uses '$($parsedStatic.FileProviderDirectory)', tool uses '$($Config.RemoteConfigDir)'"
            $recommendations += "Update tool config to match static config directory"
        }

        $isCompatible = $issues.Count -eq 0
        
        Write-TraefikLog "Configuration compatibility check completed. Compatible: $isCompatible, Issues: $($issues.Count)" -Level "Info"
        
        return [PSCustomObject]@{
            Compatible = $isCompatible
            Issues = $issues
            Recommendations = $recommendations
            StaticConfig = $parsedStatic
        }
    }
    catch {
        Write-TraefikLog "Error during compatibility check: $($_.Exception.Message)" -Level "Error"
        return [PSCustomObject]@{
            Compatible = $false
            Issues = @("Error checking compatibility: $($_.Exception.Message)")
            Recommendations = @("Check network connectivity and SSH access")
            StaticConfig = $null
        }
    }
}

# --- Static Configuration Parsing ---
function Parse-StaticConfiguration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConfigContent
    )

    try {
        $config = [PSCustomObject]@{
            EntryPoints = @()
            CertResolvers = @()
            FileProviderEnabled = $false
            FileProviderDirectory = ""
            APIEnabled = $false
        }

        # Parse YAML content (basic parsing for key information)
        $lines = $ConfigContent -split "`n"
        $currentSection = ""
        $inEntryPoints = $false
        $inCertResolvers = $false
        $inProviders = $false
        
        foreach ($line in $lines) {
            $trimmed = $line.Trim()
            
            # Skip comments and empty lines
            if ([string]::IsNullOrEmpty($trimmed) -or $trimmed.StartsWith("#")) {
                continue
            }
            
            # Detect main sections
            if ($trimmed -eq "entryPoints:") {
                $inEntryPoints = $true
                $inCertResolvers = $false
                $inProviders = $false
                continue
            }
            elseif ($trimmed -eq "certificatesResolvers:") {
                $inEntryPoints = $false
                $inCertResolvers = $true
                $inProviders = $false
                continue
            }
            elseif ($trimmed -eq "providers:") {
                $inEntryPoints = $false
                $inCertResolvers = $false
                $inProviders = $true
                continue
            }
            elseif ($trimmed.EndsWith(":") -and -not $trimmed.Contains(" ")) {
                # New main section
                $inEntryPoints = $false
                $inCertResolvers = $false
                $inProviders = $false
                continue
            }
            
            # Parse entry points
            if ($inEntryPoints -and $trimmed.Contains(":") -and -not $trimmed.StartsWith("-")) {
                $entryPointName = ($trimmed -split ":")[0].Trim()
                if ($entryPointName -and -not $entryPointName.Contains(" ")) {
                    $config.EntryPoints += $entryPointName
                }
            }
            
            # Parse certificate resolvers
            if ($inCertResolvers -and $trimmed.Contains(":") -and -not $trimmed.StartsWith("-")) {
                $resolverName = ($trimmed -split ":")[0].Trim()
                if ($resolverName -and -not $resolverName.Contains(" ")) {
                    $config.CertResolvers += $resolverName
                }
            }
            
            # Parse file provider
            if ($inProviders) {
                if ($trimmed -eq "file:") {
                    $config.FileProviderEnabled = $true
                }
                elseif ($config.FileProviderEnabled -and $trimmed.StartsWith("directory:")) {
                    $directory = ($trimmed -replace "directory:", "").Trim()
                    $directory = $directory -replace "[`"']", ""  # Remove quotes
                    $directory = $directory -replace "/$", ""     # Remove trailing slash
                    $config.FileProviderDirectory = $directory
                }
            }
            
            # Check for API
            if ($trimmed -eq "api:" -or ($trimmed.StartsWith("api:") -and $trimmed.Length -gt 4)) {
                $config.APIEnabled = $true
            }
        }
        
        Write-TraefikLog "Parsed static config - Entry Points: $($config.EntryPoints.Count), Cert Resolvers: $($config.CertResolvers.Count), File Provider: $($config.FileProviderEnabled)" -Level "Debug"
        return $config
    }
    catch {
        Write-TraefikLog "Error parsing static configuration: $($_.Exception.Message)" -Level "Error"
        throw
    }
}

# --- Configuration Synchronization ---
function Sync-DynamicConfigTemplate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConfigPath,
        
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$StaticConfigInfo
    )

    try {
        Write-TraefikLog "Synchronizing dynamic config template with static configuration..." -Level "Info"
        
        # Load current tool configuration
        if (-not (Test-Path $ConfigPath)) {
            throw "Configuration file not found: $ConfigPath"
        }
        
        $config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
        $updated = $false
        
        # Update certificate resolver if different
        if ($StaticConfigInfo.CertResolvers.Count -gt 0) {
            $newResolver = $StaticConfigInfo.CertResolvers[0]  # Use first available resolver
            if ($config.CertificateResolver -ne $newResolver) {
                Write-TraefikLog "Updating certificate resolver from '$($config.CertificateResolver)' to '$newResolver'" -Level "Info"
                $config.CertificateResolver = $newResolver
                $updated = $true
            }
        }
        
        # Update remote config directory if different
        if ($StaticConfigInfo.FileProviderDirectory -and $config.RemoteConfigDir -ne $StaticConfigInfo.FileProviderDirectory) {
            Write-TraefikLog "Updating config directory from '$($config.RemoteConfigDir)' to '$($StaticConfigInfo.FileProviderDirectory)'" -Level "Info"
            $config.RemoteConfigDir = $StaticConfigInfo.FileProviderDirectory
            $updated = $true
        }
        
        # Update configuration version and sync date
        if ($updated) {
            $config.ConfigVersion = "1.1"
            $config.LastSyncDate = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
            
            # Save updated configuration
            $config | ConvertTo-Json -Depth 10 | Set-Content $ConfigPath -ErrorAction Stop
            Write-TraefikLog "Configuration synchronized and saved" -Level "Success"
            
            return [PSCustomObject]@{
                Updated = $true
                Changes = @(
                    if ($config.CertificateResolver) { "Certificate resolver updated" }
                    if ($StaticConfigInfo.FileProviderDirectory) { "Config directory updated" }
                )
            }
        }
        else {
            Write-TraefikLog "No synchronization changes needed" -Level "Info"
            return [PSCustomObject]@{
                Updated = $false
                Changes = @()
            }
        }
    }
    catch {
        Write-TraefikLog "Error synchronizing configuration: $($_.Exception.Message)" -Level "Error"
        throw
    }
}

# --- Configuration Mismatch Warnings ---
function Show-ConfigMismatchWarning {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$CompatibilityResult
    )

    if ($CompatibilityResult.Compatible) {
        Write-Host "✓ Configuration compatibility check passed!" -ForegroundColor Green
        return
    }

    Write-Host "`n⚠️  Configuration Compatibility Issues Found" -ForegroundColor Yellow
    Write-Host "=" * 50 -ForegroundColor Yellow
    
    Write-Host "`nIssues:" -ForegroundColor Red
    foreach ($issue in $CompatibilityResult.Issues) {
        Write-Host "  • $issue" -ForegroundColor Red
    }
    
    Write-Host "`nRecommendations:" -ForegroundColor Cyan
    foreach ($recommendation in $CompatibilityResult.Recommendations) {
        Write-Host "  → $recommendation" -ForegroundColor Cyan
    }
    
    Write-Host "`n" + "=" * 50 -ForegroundColor Yellow
    Write-Host "These issues may cause service deployments to fail." -ForegroundColor Yellow
    Write-Host "Please resolve them before adding services." -ForegroundColor Yellow
}

function Invoke-ConfigurationSync {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConfigPath,
        
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Config,
        
        [Parameter(Mandatory = $true)]
        [string]$Password
    )

    try {
        Write-Host "`n--- Configuration Synchronization ---" -ForegroundColor Yellow
        Write-Host "Checking compatibility between static and dynamic configurations..." -ForegroundColor Cyan
        
        # Test compatibility
        $compatResult = Test-ConfigCompatibility -Config $Config -User $Config.TraefikSshUser -SshHost $Config.TraefikLxcIp -Password $Password -Port $Config.ConnectionSettings.SSHPort
        
        if ($compatResult.Compatible) {
            Write-Host "✓ Configurations are compatible!" -ForegroundColor Green
            return $true
        }
        
        # Show issues
        Show-ConfigMismatchWarning -CompatibilityResult $compatResult
        
        # Offer to auto-sync if possible
        if ($compatResult.StaticConfig -and ($compatResult.StaticConfig.CertResolvers.Count -gt 0 -or $compatResult.StaticConfig.FileProviderDirectory)) {
            Write-Host "`nI can attempt to automatically sync your tool configuration with the static config." -ForegroundColor Cyan
            $autoSync = Get-YesNoInput -Prompt "Automatically sync configurations?" -DefaultToNo $false
            
            if ($autoSync) {
                $syncResult = Sync-DynamicConfigTemplate -ConfigPath $ConfigPath -StaticConfigInfo $compatResult.StaticConfig
                
                if ($syncResult.Updated) {
                    Write-Host "✓ Configuration synchronized successfully!" -ForegroundColor Green
                    Write-Host "Changes made:" -ForegroundColor Green
                    foreach ($change in $syncResult.Changes) {
                        Write-Host "  • $change" -ForegroundColor Green
                    }
                    Write-Host "`n💡 Please restart this tool to load the updated configuration." -ForegroundColor Cyan
                    return $true
                }
                else {
                    Write-Host "No automatic sync was possible. Please manually resolve the issues." -ForegroundColor Yellow
                    return $false
                }
            }
        }
        
        return $false
    }
    catch {
        Write-TraefikLog "Error during configuration sync: $($_.Exception.Message)" -Level "Error"
        Write-Host "Error during synchronization: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}

# Export functions
Export-ModuleMember -Function @(
    'Test-ConfigCompatibility',
    'Parse-StaticConfiguration',
    'Sync-DynamicConfigTemplate',
    'Show-ConfigMismatchWarning',
    'Invoke-ConfigurationSync'
)