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

        # Parse YAML content with improved logic
        $lines = $ConfigContent -split "`n"
        $inEntryPoints = $false
        $inCertResolvers = $false
        $inProviders = $false
        $inFileProvider = $false
        
        foreach ($line in $lines) {
            $trimmed = $line.Trim()
            
            # Skip comments and empty lines
            if ([string]::IsNullOrEmpty($trimmed) -or $trimmed.StartsWith("#")) {
                continue
            }
            
            # Detect main sections (case insensitive, flexible matching)
            if ($trimmed -match '^entrypoints?\s*:' -or $trimmed -match '^entryPoints?\s*:') {
                $inEntryPoints = $true
                $inCertResolvers = $false
                $inProviders = $false
                $inFileProvider = $false
                Write-TraefikLog "Found entryPoints section" -Level "Debug"
                continue
            }
            elseif ($trimmed -match '^certificatesresolvers?\s*:' -or $trimmed -match '^certificateResolvers?\s*:') {
                $inEntryPoints = $false
                $inCertResolvers = $true
                $inProviders = $false
                $inFileProvider = $false
                Write-TraefikLog "Found certificatesResolvers section" -Level "Debug"
                continue
            }
            elseif ($trimmed -match '^providers?\s*:') {
                $inEntryPoints = $false
                $inCertResolvers = $false
                $inProviders = $true
                $inFileProvider = $false
                Write-TraefikLog "Found providers section" -Level "Debug"
                continue
            }
            elseif ($trimmed -match '^[a-zA-Z][a-zA-Z0-9]*\s*:' -and -not $trimmed.Contains(" ") -and $trimmed -notmatch '^\s') {
                # New main section that's not indented
                $inEntryPoints = $false
                $inCertResolvers = $false
                $inProviders = $false
                $inFileProvider = $false
                continue
            }
            
            # Parse entry points (look for any indented item under entryPoints)
            if ($inEntryPoints -and $trimmed -match '^\s*([a-zA-Z][a-zA-Z0-9\-_]*)\s*:') {
                $entryPointName = $matches[1]
                if ($entryPointName -and $entryPointName -ne "address") {
                    $config.EntryPoints += $entryPointName
                    Write-TraefikLog "Found entry point: $entryPointName" -Level "Debug"
                }
            }
            
            # Parse certificate resolvers (look for any indented item under certificatesResolvers)
            if ($inCertResolvers -and $trimmed -match '^\s*([a-zA-Z][a-zA-Z0-9\-_]*)\s*:') {
                $resolverName = $matches[1]
                if ($resolverName -and $resolverName -ne "acme") {
                    $config.CertResolvers += $resolverName
                    Write-TraefikLog "Found certificate resolver: $resolverName" -Level "Debug"
                }
            }
            
            # Parse file provider
            if ($inProviders) {
                if ($trimmed -match '^\s*file\s*:' -or $trimmed -eq "file:") {
                    $config.FileProviderEnabled = $true
                    $inFileProvider = $true
                    Write-TraefikLog "Found file provider enabled" -Level "Debug"
                }
                elseif ($inFileProvider -and $trimmed -match '^\s*directory\s*:\s*["\']?([^"\']+)["\']?') {
                    $directory = $matches[1].Trim()
                    $directory = $directory -replace "/$", ""  # Remove trailing slash
                    $config.FileProviderDirectory = $directory
                    Write-TraefikLog "Found file provider directory: $directory" -Level "Debug"
                }
            }
            
            # Check for API (more flexible)
            if ($trimmed -match '^api\s*:' -or $trimmed -match '^\s*dashboard\s*:\s*true') {
                $config.APIEnabled = $true
                Write-TraefikLog "Found API/dashboard enabled" -Level "Debug"
            }
        }
        
        Write-TraefikLog "Parsed static config - Entry Points: $($config.EntryPoints.Count) [$($config.EntryPoints -join ', ')], Cert Resolvers: $($config.CertResolvers.Count) [$($config.CertResolvers -join ', ')], File Provider: $($config.FileProviderEnabled)" -Level "Info"
        return $config
    }
    catch {
        Write-TraefikLog "Error parsing static configuration: $($_.Exception.Message)" -Level "Error"
        throw
    }
}

# --- Debug Function (Optional - for troubleshooting) ---
function Debug-StaticConfiguration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConfigContent
    )

    Write-Host "`n=== DEBUGGING STATIC CONFIGURATION ===" -ForegroundColor Yellow
    
    $lines = $ConfigContent -split "`n"
    $lineNumber = 1
    
    foreach ($line in $lines) {
        $trimmed = $line.Trim()
        
        # Skip empty lines but show comments
        if ([string]::IsNullOrEmpty($trimmed)) {
            $lineNumber++
            continue
        }
        
        $color = "White"
        $annotation = ""
        
        # Highlight important sections
        if ($trimmed -match '^entrypoints?\s*:' -or $trimmed -match '^entryPoints?\s*:') {
            $color = "Green"
            $annotation = " ← ENTRY POINTS SECTION"
        }
        elseif ($trimmed -match '^certificatesresolvers?\s*:' -or $trimmed -match '^certificateResolvers?\s*:') {
            $color = "Green"
            $annotation = " ← CERTIFICATE RESOLVERS SECTION"
        }
        elseif ($trimmed -match '^providers?\s*:') {
            $color = "Green"
            $annotation = " ← PROVIDERS SECTION"
        }
        elseif ($trimmed -match '^\s*file\s*:') {
            $color = "Cyan"
            $annotation = " ← FILE PROVIDER"
        }
        elseif ($trimmed -match '^\s*directory\s*:') {
            $color = "Cyan"
            $annotation = " ← DIRECTORY SETTING"
        }
        elseif ($trimmed -match '^\s*([a-zA-Z][a-zA-Z0-9\-_]*)\s*:' -and $line -match '^\s+') {
            $color = "Yellow"
            $annotation = " ← POTENTIAL ENTRY POINT OR RESOLVER"
        }
        
        Write-Host ("{0:D3}: {1}{2}" -f $lineNumber, $line, $annotation) -ForegroundColor $color
        $lineNumber++
    }
    
    Write-Host "`n=== END DEBUG ===" -ForegroundColor Yellow
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
        Write-Host "Configuration compatibility check passed!" -ForegroundColor Green
        return
    }

    Write-Host "`nConfiguration Compatibility Issues Found" -ForegroundColor Yellow
    Write-Host ("=" * 50) -ForegroundColor Yellow
    
    Write-Host "`nIssues:" -ForegroundColor Red
    foreach ($issue in $CompatibilityResult.Issues) {
        Write-Host "  • $issue" -ForegroundColor Red
    }
    
    Write-Host "`nRecommendations:" -ForegroundColor Cyan
    foreach ($recommendation in $CompatibilityResult.Recommendations) {
        Write-Host "  → $recommendation" -ForegroundColor Cyan
    }
    
    Write-Host "`n" + ("=" * 50) -ForegroundColor Yellow
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
            Write-Host "Configurations are compatible!" -ForegroundColor Green
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
                    Write-Host "Configuration synchronized successfully!" -ForegroundColor Green
                    Write-Host "Changes made:" -ForegroundColor Green
                    foreach ($change in $syncResult.Changes) {
                        Write-Host "  • $change" -ForegroundColor Green
                    }
                    Write-Host "`nPlease restart this tool to load the updated configuration." -ForegroundColor Cyan
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
    'Debug-StaticConfiguration',
    'Sync-DynamicConfigTemplate',
    'Show-ConfigMismatchWarning',
    'Invoke-ConfigurationSync'
)