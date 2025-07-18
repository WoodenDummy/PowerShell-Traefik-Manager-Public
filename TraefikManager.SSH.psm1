# TraefikManager.SSH.psm1
# SSH communication functions for Traefik Manager

#Requires -Version 5.1
Set-StrictMode -Version Latest

# --- Simple SSH Command Execution ---
function Invoke-SSHCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$User,
        
        [Parameter(Mandatory = $true)]
        [string]$SshHost,
        
        [Parameter(Mandatory = $true)]
        [string]$Password,
        
        [Parameter(Mandatory = $true)]
        [string]$Command,
        
        [Parameter(Mandatory = $false)]
        [int]$Port = 22,
        
        [Parameter(Mandatory = $false)]
        [int]$TimeoutSeconds = 30
    )

    # Check for plink.exe
    $plinkPath = Get-Command plink.exe -ErrorAction SilentlyContinue
    if (-not $plinkPath) {
        Write-TraefikLog "plink.exe not found. Ensure PuTTY is installed and in PATH." -Level "Error"
        return [PSCustomObject]@{
            ExitCode = 1
            Stdout = ""
            Stderr = "plink.exe not found"
            Success = $false
        }
    }

    try {
        Write-TraefikLog "Executing SSH command: $Command" -Level "Debug"
        
        # First, try to add the host key automatically
        $hostKeyResult = Add-HostKeyIfNeeded -User $User -SshHost $SshHost -Password $Password -Port $Port
        if (-not $hostKeyResult) {
            Write-TraefikLog "Failed to add host key, but continuing..." -Level "Warning"
        }
        
        # Use simple & operator for more predictable behavior
        $arguments = @(
            "-ssh",
            "-pw", $Password,
            "-batch",
            "-P", $Port.ToString(),
            "$User@$SshHost",
            $Command
        )
        
        # Simple execution without complex process handling
        $output = & $plinkPath.Source $arguments 2>&1
        $exitCode = $LASTEXITCODE
        
        if ($exitCode -eq 0) {
            Write-TraefikLog "SSH command executed successfully." -Level "Success"
            return [PSCustomObject]@{
                ExitCode = $exitCode
                Stdout = ($output | Out-String).Trim()
                Stderr = ""
                Success = $true
            }
        }
        else {
            Write-TraefikLog "SSH command failed with exit code: $exitCode" -Level "Warning"
            return [PSCustomObject]@{
                ExitCode = $exitCode
                Stdout = ""
                Stderr = ($output | Out-String).Trim()
                Success = $false
            }
        }
    }
    catch {
        Write-TraefikLog "SSH command error: $($_.Exception.Message)" -Level "Error"
        return [PSCustomObject]@{
            ExitCode = 1
            Stdout = ""
            Stderr = $_.Exception.Message
            Success = $false
        }
    }
}

# --- Host Key Management ---
function Add-HostKeyIfNeeded {
    [CmdletBinding()]
    param(
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
        # Check if host key is already cached
        $plinkPath = Get-Command plink.exe -ErrorAction SilentlyContinue
        if (-not $plinkPath) {
            return $false
        }

        # Try a simple connection test first
        $testArgs = @(
            "-ssh",
            "-pw", $Password,
            "-batch",
            "-P", $Port.ToString(),
            "$User@$SshHost",
            "echo test"
        )
        
        $testOutput = & $plinkPath.Source $testArgs 2>&1
        $testExitCode = $LASTEXITCODE
        
        # If it succeeds, host key is already cached
        if ($testExitCode -eq 0) {
            Write-TraefikLog "Host key already cached for $SshHost" -Level "Debug"
            return $true
        }
        
        # Check if the error is about host key
        $errorText = ($testOutput | Out-String)
        if ($errorText -match "host key.*not cached" -or $errorText -match "Cannot confirm.*host key") {
            Write-TraefikLog "Host key not cached for $SshHost. Attempting to add..." -Level "Info"
            
            # Use echo y to accept the host key
            $acceptArgs = @(
                "-ssh",
                "-pw", $Password,
                "-P", $Port.ToString(),
                "$User@$SshHost",
                "echo connected"
            )
            
            # Use echo y | plink to auto-accept the host key
            $acceptCommand = "echo y | `"$($plinkPath.Source)`" " + ($acceptArgs -join " ")
            $acceptOutput = cmd /c $acceptCommand 2>&1
            $acceptExitCode = $LASTEXITCODE
            
            if ($acceptExitCode -eq 0) {
                Write-TraefikLog "Successfully added host key for $SshHost" -Level "Success"
                return $true
            }
            else {
                Write-TraefikLog "Failed to add host key: $acceptOutput" -Level "Warning"
                
                # Alternative method: Try manual host key acceptance
                Write-Host "SSH host key verification failed. You may need to manually accept the host key." -ForegroundColor Yellow
                Write-Host "Run this command manually to accept the host key:" -ForegroundColor Yellow
                Write-Host "plink.exe -ssh $User@$SshHost -P $Port" -ForegroundColor Cyan
                Write-Host "Then type 'y' to accept the key and exit the session." -ForegroundColor Yellow
                
                $proceed = Read-Host "Have you manually accepted the host key? (y/N)"
                return ($proceed -eq 'y' -or $proceed -eq 'Y')
            }
        }
        
        return $false
    }
    catch {
        Write-TraefikLog "Error managing host key: $($_.Exception.Message)" -Level "Warning"
        return $false
    }
}

# --- File Transfer Functions ---
function Invoke-FileUpload {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$LocalPath,
        
        [Parameter(Mandatory = $true)]
        [string]$RemotePath,
        
        [Parameter(Mandatory = $true)]
        [string]$User,
        
        [Parameter(Mandatory = $true)]
        [string]$SshHost,
        
        [Parameter(Mandatory = $true)]
        [string]$Password,
        
        [Parameter(Mandatory = $false)]
        [int]$Port = 22
    )

    $pscpPath = Get-Command pscp.exe -ErrorAction SilentlyContinue
    if (-not $pscpPath) {
        Write-TraefikLog "pscp.exe not found. Ensure PuTTY is installed and in PATH." -Level "Error"
        return $false
    }

    try {
        # Ensure host key is cached first
        $hostKeyResult = Add-HostKeyIfNeeded -User $User -SshHost $SshHost -Password $Password -Port $Port
        if (-not $hostKeyResult) {
            Write-TraefikLog "Warning: Host key issue may cause file transfer to fail" -Level "Warning"
        }

        Write-TraefikLog "Uploading file from $LocalPath to $RemotePath..." -Level "Info"
        
        $arguments = @(
            "-pw", $Password,
            "-batch",
            "-P", $Port.ToString(),
            "`"$LocalPath`"",
            "$User@$SshHost`:`"$RemotePath`""
        )

        $result = & $pscpPath.Source $arguments 2>&1
        $exitCode = $LASTEXITCODE

        if ($exitCode -eq 0) {
            Write-TraefikLog "File upload completed successfully." -Level "Success"
            return $true
        }
        else {
            Write-TraefikLog "File upload failed. Exit code: $exitCode" -Level "Error"
            Write-TraefikLog "PSCP Output: $($result | Out-String)" -Level "Error"
            return $false
        }
    }
    catch {
        Write-TraefikLog "File upload error: $($_.Exception.Message)" -Level "Error"
        return $false
    }
}

function Invoke-FileDownload {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$RemotePath,
        
        [Parameter(Mandatory = $true)]
        [string]$LocalPath,
        
        [Parameter(Mandatory = $true)]
        [string]$User,
        
        [Parameter(Mandatory = $true)]
        [string]$SshHost,
        
        [Parameter(Mandatory = $true)]
        [string]$Password,
        
        [Parameter(Mandatory = $false)]
        [int]$Port = 22
    )

    $pscpPath = Get-Command pscp.exe -ErrorAction SilentlyContinue
    if (-not $pscpPath) {
        Write-TraefikLog "pscp.exe not found. Ensure PuTTY is installed and in PATH." -Level "Error"
        return $false
    }

    try {
        # Ensure host key is cached first
        $hostKeyResult = Add-HostKeyIfNeeded -User $User -SshHost $SshHost -Password $Password -Port $Port
        if (-not $hostKeyResult) {
            Write-TraefikLog "Warning: Host key issue may cause file transfer to fail" -Level "Warning"
        }

        Write-TraefikLog "Downloading file from $RemotePath to $LocalPath..." -Level "Info"
        
        $arguments = @(
            "-pw", $Password,
            "-batch", 
            "-P", $Port.ToString(),
            "$User@$SshHost`:`"$RemotePath`"",
            "`"$LocalPath`""
        )

        $result = & $pscpPath.Source $arguments 2>&1
        $exitCode = $LASTEXITCODE

        if ($exitCode -eq 0) {
            Write-TraefikLog "File download completed successfully." -Level "Success"
            return $true
        }
        else {
            Write-TraefikLog "File download failed. Exit code: $exitCode" -Level "Error"
            Write-TraefikLog "PSCP Output: $($result | Out-String)" -Level "Error"
            return $false
        }
    }
    catch {
        Write-TraefikLog "File download error: $($_.Exception.Message)" -Level "Error"
        return $false
    }
}

# --- Connection Test Function ---
function Test-SSHConnection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$User,
        
        [Parameter(Mandatory = $true)]
        [string]$SshHost,
        
        [Parameter(Mandatory = $true)]
        [string]$Password,
        
        [Parameter(Mandatory = $false)]
        [int]$Port = 22
    )

    Write-TraefikLog "Testing SSH connection to $User@$SshHost..." -Level "Info"
    
    $result = Invoke-SSHCommand -User $User -SshHost $SshHost -Password $Password -Port $Port -Command "echo 'Connection successful' && whoami && pwd"
    
    if ($result.Success) {
        Write-TraefikLog "SSH connection test successful!" -Level "Success"
        
        # Parse output safely
        $outputLines = @($result.Stdout -split "`n" | Where-Object { $_ -and $_.Trim() })
        
        $connectionInfo = [PSCustomObject]@{
            Success = $true
            Message = "Connection successful"
            RemoteUser = if ($outputLines.Length -ge 2) { $outputLines[1].Trim() } else { "Unknown" }
            RemoteDirectory = if ($outputLines.Length -ge 3) { $outputLines[2].Trim() } else { "Unknown" }
        }
        
        return $connectionInfo
    }
    else {
        Write-TraefikLog "SSH connection test failed: $($result.Stderr)" -Level "Error"
        return [PSCustomObject]@{
            Success = $false
            Message = $result.Stderr
            RemoteUser = ""
            RemoteDirectory = ""
        }
    }
}

# Export functions
Export-ModuleMember -Function @(
    'Invoke-SSHCommand',
    'Invoke-FileUpload',
    'Invoke-FileDownload', 
    'Test-SSHConnection',
    'Add-HostKeyIfNeeded'
)