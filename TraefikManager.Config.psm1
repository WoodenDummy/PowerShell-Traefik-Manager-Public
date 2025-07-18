# TraefikManager.Config.psm1
# Configuration generation and deployment functions

#Requires -Version 5.1
Set-StrictMode -Version Latest

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
        [bool]$UseCrowdSecBouncer = $false,
        
        [Parameter(Mandatory = $false)]
        [string[]]$Middlewares = @(),
        
        [Parameter(Mandatory = $false)]
        [hashtable]$CustomLabels = @{}
    )

    $protocol = if ($UseHttps) { "https" } else { "http" }
    $fullDomain = "$ServiceName.$DomainName"

    # Prepare middlewares list
    $allMiddlewares = @()
    if ($UseCrowdSecBouncer) {
        $allMiddlewares += "crowdsec-bouncer"
    }
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

function Save-ServiceBackup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ServiceName,
        
        [Parameter(Mandatory = $true)]
        [string]$Content
    )

    try {
        $backupDir = Join-Path (Get-Location) "backups"
        if (-not (Test-Path $backupDir)) {
            New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
            Write-TraefikLog "Created backup directory: $backupDir" -Level "Info"
        }

        $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
        $backupFile = Join-Path $backupDir "$ServiceName`_$timestamp.yml"

        $Content | Set-Content -Path $backupFile -Encoding UTF8 -ErrorAction Stop
        Write-TraefikLog "Created backup: $backupFile" -Level "Success"
    }
    catch {
        Write-TraefikLog "Failed to create backup for $ServiceName`: $($_.Exception.Message)" -Level "Warning"
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
            Save-ServiceBackup -ServiceName $ServiceName -Content $originalContent
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
    'New-TraefikServiceYaml',
    'Deploy-ServiceConfig',
    'Save-ServiceBackup',
    'Edit-ServiceConfig',
    'Test-BasicYamlSyntax'
)