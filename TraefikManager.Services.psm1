# TraefikManager.Services.psm1
# Service discovery and management functions

#Requires -Version 5.1
Set-StrictMode -Version Latest

# --- Service Discovery Functions ---
function Get-TraefikServices {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$User,
        
        [Parameter(Mandatory = $true)]
        [string]$SshHost,
        
        [Parameter(Mandatory = $true)]
        [string]$Password,
        
        [Parameter(Mandatory = $true)]
        [string]$RemoteConfigDir,
        
        [Parameter(Mandatory = $true)]
        [int]$Port
    )

    # Use find command to get .yml files
    $command = "find $RemoteConfigDir -name '*.yml' -type f -exec basename {} \;"
    $result = Invoke-SSHCommand -User $User -SshHost $SshHost -Password $Password -Port $Port -Command $command

    $services = @{}
    $serviceNames = @()
    
    if ($result.Success) {
        $files = @($result.Stdout.Trim() -split "`n" | Where-Object { $_ -and $_.Trim() -ne "" -and $_.Trim() -ne ".yml" })
        Write-TraefikLog "Raw file list output: '$($result.Stdout)'" -Level "Debug"
        Write-TraefikLog "Processed files: $($files -join ', ')" -Level "Debug"
        
        foreach ($file in $files) {
            $cleanFile = $file.Trim()
            # Validate file: must end with .yml and have content before .yml
            if ($cleanFile -and $cleanFile.EndsWith(".yml") -and $cleanFile.Length -gt 4) {
                $serviceName = $cleanFile.Replace(".yml", "")
                if ($serviceName -and $serviceName.Trim()) {
                    $serviceNames += $serviceName
                    $services[$serviceName] = $cleanFile
                    Write-TraefikLog "Found service: $serviceName ($cleanFile)" -Level "Debug"
                }
            }
        }
    }
    else {
        Write-TraefikLog "Failed to list files with find, trying fallback: $($result.Stderr)" -Level "Warning"
        
        # Fallback to ls command
        $fallbackCommand = "ls -1 $RemoteConfigDir/*.yml 2>/dev/null || echo 'NO_FILES'"
        $fallbackResult = Invoke-SSHCommand -User $User -SshHost $SshHost -Password $Password -Port $Port -Command $fallbackCommand
        
        if ($fallbackResult.Success -and $fallbackResult.Stdout -ne "NO_FILES") {
            $files = @($fallbackResult.Stdout.Trim() -split "`n" | Where-Object { $_ -and $_.Trim() })
            foreach ($filePath in $files) {
                $file = Split-Path -Leaf $filePath.Trim()
                if ($file -and $file.EndsWith(".yml") -and $file.Length -gt 4) {
                    $serviceName = $file.Replace(".yml", "")
                    if ($serviceName -and $serviceName.Trim()) {
                        $serviceNames += $serviceName
                        $services[$serviceName] = $file
                        Write-TraefikLog "Found service (fallback): $serviceName ($file)" -Level "Debug"
                    }
                }
            }
        }
    }

    # Sort service names for consistent ordering
    $serviceNames = $serviceNames | Sort-Object
    
    # Create numeric index mapping in sorted order
    $indexedServices = @{}
    $i = 1
    foreach ($serviceName in $serviceNames) {
        $fileName = $services[$serviceName]
        $indexedServices[$serviceName] = $fileName
        $indexedServices[$i] = $fileName
        Write-TraefikLog "Index $i = $serviceName ($fileName)" -Level "Debug"
        $i++
    }
    
    Write-TraefikLog "Total services discovered: $($serviceNames.Count)" -Level "Info"
    return $indexedServices
}

function Get-ServiceContent {
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
        [int]$Port
    )

    $remoteFile = "$RemoteConfigDir/$ServiceName.yml"
    $command = "cat `"$remoteFile`" 2>/dev/null || echo 'FILE_NOT_FOUND'"
    $result = Invoke-SSHCommand -User $User -SshHost $SshHost -Password $Password -Port $Port -Command $command

    if ($result.Success -and $result.Stdout -ne "FILE_NOT_FOUND") {
        Write-TraefikLog "Successfully retrieved content for service: $ServiceName" -Level "Success"
        return $result.Stdout
    }
    else {
        Write-TraefikLog "Failed to retrieve content for service: $ServiceName" -Level "Error"
        return $null
    }
}

function Remove-ServiceFile {
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
        [int]$Port
    )

    $remoteFile = "$RemoteConfigDir/$ServiceName.yml"
    $command = "rm -f `"$remoteFile`""
    $result = Invoke-SSHCommand -User $User -SshHost $SshHost -Password $Password -Port $Port -Command $command

    if ($result.Success) {
        Write-TraefikLog "Successfully removed service file: $ServiceName" -Level "Success"
        return $true
    }
    else {
        Write-TraefikLog "Failed to remove service file $ServiceName`: $($result.Stderr)" -Level "Error"
        return $false
    }
}

function Test-ServiceExists {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ServiceName,
        
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [hashtable]$ExistingServices
    )

    # Safely check if service exists without relying on Count property
    if ($null -eq $ExistingServices) {
        Write-TraefikLog "ExistingServices is null" -Level "Debug"
        return $false
    }
    
    # Check if the hashtable has any keys at all
    try {
        $hasKeys = $ExistingServices.Keys.Count -gt 0
        if (-not $hasKeys) {
            Write-TraefikLog "ExistingServices hashtable has no keys" -Level "Debug"
            return $false
        }
    }
    catch {
        Write-TraefikLog "Error checking ExistingServices keys: $($_.Exception.Message)" -Level "Debug"
        return $false
    }
    
    # Check if the specific service name exists as a key
    $serviceExists = $ExistingServices.ContainsKey($ServiceName)
    Write-TraefikLog "Service '$ServiceName' exists check: $serviceExists" -Level "Debug"
    
    return $serviceExists
}

# Export functions
Export-ModuleMember -Function @(
    'Get-TraefikServices',
    'Get-ServiceContent',
    'Remove-ServiceFile',
    'Test-ServiceExists'
)