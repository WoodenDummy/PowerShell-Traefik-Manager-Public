# TraefikManager.Config.psm1
# Configuration generation and deployment functions

#Requires -Version 5.1
Set-StrictMode -Version Latest

# --- Configuration Initialization ---
function Initialize-TraefikConfiguration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConfigPath
    )

    Write-Host "`n=== Traefik Manager Configuration Setup ===" -ForegroundColor Green
    Write-Host "This wizard will help you configure Traefik Manager for your environment.`n" -ForegroundColor Cyan

    # Get Traefik server details
    Write-Host "--- Traefik Server Configuration ---" -ForegroundColor Yellow
    
    $traefikIp = Get-ValidatedInput -Prompt "Enter the IP address of your Traefik server" -ValidationFunction { param($ip) Test-IPAddress $ip } -ErrorMessage "Invalid IP address format (e.g., 192.168.1.100)"
    
    $sshUser = Get-ValidatedInput -Prompt "Enter the SSH username for the Traefik server" -ValidationFunction { param($user) $user -and $user.Trim().Length -gt 0 } -ErrorMessage "Username cannot be empty"
    
    $sshPort = Get-ValidatedInput -Prompt "Enter the SSH port (default: 22)" -ValidationFunction { param($port) if ([string]::IsNullOrWhiteSpace($port)) { $true } else { Test-PortNumber $port } } -ErrorMessage "Invalid port number"
    if ([string]::IsNullOrWhiteSpace($sshPort)) { $sshPort = "22" }
    
    $configDir = Read-Host -Prompt "Enter the remote Traefik configuration directory (default: /etc/traefik/conf.d)"
    if ([string]::IsNullOrWhiteSpace($configDir)) { $configDir = "/etc/traefik/conf.d" }

    # Get domain configuration
    Write-Host "`n--- Domain Configuration ---" -ForegroundColor Yellow
    Write-Host "Configure the domains that will be used for your services." -ForegroundColor Cyan
    
    $domains = @{}
    $domainIndex = 1
    
    do {
        $domain = Read-Host -Prompt "Enter domain $domainIndex (e.g., example.com)"
        if ($domain -and $domain.Trim()) {
            $domains[$domainIndex.ToString()] = $domain.Trim()
            $domainIndex++
        }
        
        if ($domainIndex -eq 2) {
            $addMore = Get-YesNoInput -Prompt "Add another domain?" -DefaultToNo $true
        } elseif ($domainIndex -gt 2) {
            $addMore = Get-YesNoInput -Prompt "Add another domain?" -DefaultToNo $true
        } else {
            $addMore = $true
        }
    } while ($addMore -and $domainIndex -le 10)

    if ($domains.Count -eq 0) {
        Write-Host "No domains configured. Adding a default placeholder." -ForegroundColor Yellow
        $domains["1"] = "example.com"
    }

    # Get editor preference
    Write-Host "`n--- Editor Configuration ---" -ForegroundColor Yellow
    Write-Host "Choose your preferred text editor for editing service configurations:" -ForegroundColor Cyan
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

    # Get backup preferences
    Write-Host "`n--- Backup Configuration ---" -ForegroundColor Yellow
    $backupEnabled = Get-YesNoInput -Prompt "Enable automatic backups when editing/removing services?" -DefaultToNo $false

    # Get advanced settings
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

    # Create configuration object
    $config = [PSCustomObject]@{
        TraefikLxcIp = $traefikIp
        TraefikSshUser = $sshUser
        RemoteConfigDir = $configDir
        DomainOptions = [PSCustomObject]$domains
        ConnectionSettings = [PSCustomObject]@{
            MaxRetries = $maxRetries
            RetryDelaySeconds = $retryDelay
            TimeoutSeconds = $timeout
            SSHPort = [int]$sshPort
        }
        LogLevel = "Info"
        Editor = $editor
        BackupEnabled = $backupEnabled
        BackupDirectory = "backups"
        ConfigVersion = "1.0"
        CreatedDate = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    }

    # Show configuration summary
    Write-Host "`n--- Configuration Summary ---" -ForegroundColor Green
    Write-Host "Traefik Server: $($config.TraefikSshUser)@$($config.TraefikLxcIp):$($config.ConnectionSettings.SSHPort)" -ForegroundColor Cyan
    Write-Host "Configuration Directory: $($config.RemoteConfigDir)" -ForegroundColor Cyan
    Write-Host "Domains: $($domains.Values -join ', ')" -ForegroundColor Cyan
    Write-Host "Editor: $($config.Editor)" -ForegroundColor Cyan
    Write-Host "Backups Enabled: $($config.BackupEnabled)" -ForegroundColor Cyan
    Write-Host "----------------------------" -ForegroundColor Green

    $confirm = Get-YesNoInput -Prompt "Save this configuration?" -DefaultToNo $false
    if (-not $confirm) {
        Write-Host "Configuration cancelled." -ForegroundColor Yellow
        return $null
    }

    # Save configuration
    try {
        $config | ConvertTo-Json -Depth 10 | Set-Content $ConfigPath -ErrorAction Stop
        Write-Host "`nConfiguration saved successfully to: $ConfigPath" -ForegroundColor Green
        Write-TraefikLog "Configuration initialized and saved to: $ConfigPath" -Level "Success"
        return $config
    }
    catch {
        Write-Host "Failed to save configuration: $($_.Exception.Message)" -ForegroundColor Red
        Write-TraefikLog "Failed to save configuration: $($_.Exception.Message)" -Level "Error"
        return $null
    }
}

# --- YAML Configuration Generation ---
function New-TraefikServiceYaml {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ServiceName,
        
        [Parameter(Mandatory = $true)]
        [string]$ServiceIP,
        
        [Parameter(Mandatory = $true)]
        [int]$ServicePort,
        
        [Parameter(Mandatory = $true)]
        [string]$DomainName,
        
        [Parameter(Mandatory = $false)]
        [bool]$UseHttps = $false,
        
        [Parameter(Mandatory = $false)]
        [string[]]$Middlewares = @(),
        
        [Parameter(Mandatory = $false)]
        [hashtable]$CustomLabels = @{}
    )

    $protocol = if ($UseHttps) { "https" } else { "http" }
    $fullDomain = "$ServiceName.$DomainName"

    # Prepare middlewares list
    $allMiddlewares = @()
    $allMiddlewares += $Middlewares

    # Build YAML content using string concatenation to avoid variable expansion issues
    $yamlContent = "http:`n"
    $yamlContent += "  routers:`n"
    $yamlContent += "    $ServiceName-router:`n"
    $yamlContent += "      entryPoints:`n"
    $yamlContent += "        - `"websecure`"`n"
    $yamlContent += "      rule: `"Host(``$fullDomain``)`"`n"
    $yamlContent += "      service: `"$ServiceName-service`"`n"
    $yamlContent += "      tls:`n"
    $yamlContent += "        certResolver: `"letsencrypt`"`n"

    # Add middlewares if any are specified
    if ($allMiddlewares.Count -gt 0) {
        $yamlContent += "      middlewares:`n"
        foreach ($middleware in $allMiddlewares) {
            $yamlContent += "        - `"$middleware`"`n"
        }
    }

    # Add services section
    $yamlContent += "  services:`n"
    $yamlContent += "    $ServiceName-service:`n"
    $yamlContent += "      loadBalancer:`n"
    $yamlContent += "        servers:`n"
    $yamlContent += "          - url: `"$protocol`://$ServiceIP`:$ServicePort`"`n"

    # Add HTTPS-specific configuration if needed
    if ($UseHttps) {
        $transportName = "$ServiceName-insecure-transport"
        $yamlContent += "        serversTransport: `"$transportName`"`n"
        $yamlContent += "  serversTransports:`n"
        $yamlContent += "    $transportName`:`n"
        $yamlContent += "      insecureSkipVerify: true`n"
    }

    Write-TraefikLog "Generated YAML configuration for service: $ServiceName" -Level "Debug"
    return $yamlContent
}

function Deploy-ServiceConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ServiceName,
        
        [Parameter(Mandatory = $true)]
        [string]$YamlContent,
        
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
        [bool]$CreateBackup = $true
    )

    $remoteConfigFile = "$RemoteConfigDir/$ServiceName.yml"
    $tempLocalFile = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "$ServiceName`_traefik_config_$(Get-Random).yml"

    try {
        # Create backup if service already exists and backup is enabled
        if ($CreateBackup) {
            # Check if the service file exists before trying to backup
            $checkCommand = "test -f `"$remoteConfigFile`" && echo 'EXISTS' || echo 'NOT_EXISTS'"
            $checkResult = Invoke-SSHCommand -User $User -SshHost $SshHost -Password $Password -Port $Port -Command $checkCommand
            
            if ($checkResult.Success -and $checkResult.Stdout.Trim() -eq "EXISTS") {
                Write-TraefikLog "Service already exists, creating backup..." -Level "Info"
                $existingContent = Get-ServiceContent -ServiceName $ServiceName -User $User -SshHost $SshHost -Password $Password -RemoteConfigDir $RemoteConfigDir -Port $Port
                if ($existingContent) {
                    Save-ServiceBackup -ServiceName $ServiceName -Content $existingContent
                }
            } else {
                Write-TraefikLog "New service - no existing configuration to backup." -Level "Info"
            }
        }

        # Save YAML content to temporary file
        $YamlContent | Set-Content -Path $tempLocalFile -Encoding UTF8 -ErrorAction Stop
        Write-TraefikLog "Created temporary config file: $tempLocalFile" -Level "Debug"

        # Upload configuration
        $uploadSuccess = Invoke-FileUpload -LocalPath $tempLocalFile -RemotePath $remoteConfigFile -User $User -SshHost $SshHost -Password $Password -Port $Port

        if ($uploadSuccess) {
            Write-TraefikLog "Successfully deployed configuration for service: $ServiceName" -Level "Success"
            return $true
        }
        else {
            Write-TraefikLog "Failed to deploy configuration for service: $ServiceName" -Level "Error"
            return $false
        }
    }
    catch {
        Write-TraefikLog "Error during deployment of $ServiceName`: $($_.Exception.Message)" -Level "Error"
        return $false
    }
    finally {
        # Cleanup temporary file
        if (Test-Path $tempLocalFile) {
            Remove-Item $tempLocalFile -Force -ErrorAction SilentlyContinue
            Write-TraefikLog "Cleaned up temporary file: $tempLocalFile" -Level "Debug"
        }
    }
}

function Edit-ServiceConfig {
    [CmdletBinding()]
    param(
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
        [string]$Editor = "notepad.exe"
    )

    $tempLocalFile = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "edit_$ServiceName`_$(Get-Random).yml"
    $remoteFile = "$RemoteConfigDir/$ServiceName.yml"

    try {
        # Download current configuration
        Write-TraefikLog "Downloading configuration for editing: $ServiceName" -Level "Info"
        
        $downloadSuccess = Invoke-FileDownload -RemotePath $remoteFile -LocalPath $tempLocalFile -User $User -SshHost $SshHost -Password $Password -Port $Port
        
        if (-not $downloadSuccess) {
            Write-TraefikLog "Failed to download configuration for editing: $ServiceName" -Level "Error"
            return $false
        }

        # Get original content for comparison
        $originalContent = Get-Content -Path $tempLocalFile -Raw -ErrorAction SilentlyContinue

        # Create backup before editing
        if ($originalContent) {
            Save-ServiceBackup -ServiceName $ServiceName -Content $originalContent -BackupSuffix "pre_edit"
        }

        # Open in editor
        Write-TraefikLog "Opening editor: $Editor" -Level "Info"
        Write-Host "Opening $ServiceName configuration in $Editor..." -ForegroundColor Cyan
        Write-Host "Please save and close the editor when finished." -ForegroundColor Yellow
        
        $editorProcess = Start-Process -FilePath $Editor -ArgumentList "`"$tempLocalFile`"" -Wait -PassThru
        $editorProcess.WaitForExit()

        # Check if file was modified
        $newContent = Get-Content -Path $tempLocalFile -Raw -ErrorAction SilentlyContinue
        if ($newContent -eq $originalContent) {
            Write-Host "No changes detected. Upload cancelled." -ForegroundColor Yellow
            Write-TraefikLog "No changes made to: $ServiceName" -Level "Info"
            return $true
        }

        # Validate YAML syntax (basic check)
        if (-not (Test-BasicYamlSyntax -Content $newContent)) {
            Write-Host "Warning: Potential YAML syntax issues detected!" -ForegroundColor Red
            $proceed = Read-Host "Continue with upload anyway? (y/N)"
            if ($proceed -ne 'y' -and $proceed -ne 'Y') {
                Write-TraefikLog "Upload cancelled due to YAML syntax concerns: $ServiceName" -Level "Info"
                return $false
            }
        }

        # Confirm upload
        $confirm = Read-Host "Upload modified configuration to Traefik? (y/N)"
        if ($confirm -eq 'y' -or $confirm -eq 'Y') {
            Write-Host "Uploading configuration..." -ForegroundColor Cyan
            
            $uploadSuccess = Invoke-FileUpload -LocalPath $tempLocalFile -RemotePath $remoteFile -User $User -SshHost $SshHost -Password $Password -Port $Port
            
            if ($uploadSuccess) {
                Write-TraefikLog "Successfully updated configuration: $ServiceName" -Level "Success"
                Write-Host "Configuration updated successfully!" -ForegroundColor Green
                Write-Host "Traefik will automatically detect the changes." -ForegroundColor Green
                return $true
            }
            else {
                Write-TraefikLog "Failed to upload modified configuration: $ServiceName" -Level "Error"
                Write-Host "Failed to upload configuration!" -ForegroundColor Red
                return $false
            }
        }
        else {
            Write-TraefikLog "User cancelled upload: $ServiceName" -Level "Info"
            Write-Host "Upload cancelled." -ForegroundColor Yellow
            return $true
        }
    }
    catch {
        Write-TraefikLog "Error during edit operation for $ServiceName`: $($_.Exception.Message)" -Level "Error"
        Write-Host "Error during edit operation: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
    finally {
        # Cleanup temporary file
        if (Test-Path $tempLocalFile) {
            Remove-Item $tempLocalFile -Force -ErrorAction SilentlyContinue
            Write-TraefikLog "Cleaned up temporary edit file: $tempLocalFile" -Level "Debug"
        }
    }
}

function Test-BasicYamlSyntax {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Content
    )

    try {
        # Basic YAML validation checks
        $lines = $Content -split "`n"
        $hasValidStructure = $false
        
        foreach ($line in $lines) {
            $trimmed = $line.Trim()
            
            # Skip empty lines and comments
            if ([string]::IsNullOrEmpty($trimmed) -or $trimmed.StartsWith("#")) {
                continue
            }
            
            # Check for basic YAML structure
            if ($trimmed.Contains(":") -or $trimmed.StartsWith("-")) {
                $hasValidStructure = $true
            }
            
            # Check for obvious syntax errors
            if ($trimmed.Contains("`t")) {
                Write-TraefikLog "YAML validation warning: Contains tabs (should use spaces)" -Level "Warning"
            }
        }
        
        if (-not $hasValidStructure) {
            Write-TraefikLog "YAML validation error: No valid YAML structure found" -Level "Error"
            return $false
        }
        
        return $true
    }
    catch {
        Write-TraefikLog "YAML validation error: $($_.Exception.Message)" -Level "Error"
        return $false
    }
}

# Export functions
Export-ModuleMember -Function @(
    'Initialize-TraefikConfiguration',
    'New-TraefikServiceYaml',
    'Deploy-ServiceConfig',
    'Edit-ServiceConfig',
    'Test-BasicYamlSyntax'
)