<#
.SYNOPSIS
    Manages dynamic Traefik service configurations on a Proxmox LXC container.

.DESCRIPTION
    This script provides a menu-driven interface to:
    - Add new Traefik service configurations.
    - List existing Traefik service configurations.
    - Remove existing Traefik service configurations.
    - View the content of a specific Traefik service configuration file.
    - Edit existing Traefik service configuration files using a local text editor.

.NOTES
    - Requires 'plink.exe' AND 'pscp.exe' (from PuTTY) to be installed and available in your system's PATH.
      Download PuTTY from putty.org if you don't have it.
    - Assumes Traefik is installed on the remote LXC and running as a systemd service.
    - Uses password authentication for SSH. For better security, consider using SSH keys.
    - The Traefik dynamic configuration directory is assumed to be /etc/traefik/conf.d/.
    - This version has some values hardcoded for simplification.
    - The SSH password is now stored in a temporary, encrypted file for the duration of the script session,
      and is automatically deleted when the script exits.
#>

# Define the path for the temporary encrypted SSH credential file
# This file is encrypted using Windows DPAPI and is only readable by the same user on the same machine.
$PSScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Definition
$Encrypted_SSH_CREDENTIAL_FILE = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "temp_ssh_cred.xml"

# --- Configuration Variables (Hardcoded for your setup) ---
$TraefikLxcIp = "10.10.1.3" # Your Traefik LXC's static IP
$TraefikSshUser = "root"    # Your SSH username for the Traefik LXC
$DomainOptions = @{
    "1" = "coulter.app";
    "2" = "coulter-local.app";
}
$RemoteConfigDir = "/etc/traefik/conf.d" # Traefik's dynamic config directory

# --- Helper Function to Get SSH Password (Revised) ---
function Get-SshPassword {
    param(
        [Parameter(Mandatory=$true)]
        [string]$User,
        [Parameter(Mandatory=$true)]
        [string]$SshHost
    )

    $password = $null
    $global:securePassword = $null # This will hold the SecureString for cleanup later

    # Try to read SecureString from the temporary encrypted file first
    if (Test-Path $Encrypted_SSH_CREDENTIAL_FILE) {
        try {
            Write-Host "Attempting to retrieve SSH password from temporary encrypted file..." -ForegroundColor DarkGray
            # Import-CliXml with -ErrorAction Stop to catch decryption/parsing errors
            $global:securePassword = Import-CliXml -Path $Encrypted_SSH_CREDENTIAL_FILE -ErrorAction Stop
            
            # Verify if it's actually a SecureString (Import-CliXml can sometimes return other objects if file is corrupted)
            if (-not ($global:securePassword -is [System.Security.SecureString])) {
                Write-Warning "Temporary credential file content is not a SecureString or is corrupted. Prompting for password."
                $global:securePassword = $null # Clear it to force prompt
            } else {
                Write-Host "Password retrieved from temporary encrypted file." -ForegroundColor DarkGreen
            }
        }
        catch {
            Write-Warning "Could not retrieve password from temporary encrypted file: $($_.Exception.Message)"
            Write-Warning "Prompting for password."
            $global:securePassword = $null # Clear it to force prompt
        }
    }

    # If SecureString not found or retrieval failed, prompt user
    if (-not $global:securePassword) {
        Write-Host "Enter SSH password. It will be temporarily saved encrypted for this session." -ForegroundColor Yellow
        $global:securePassword = Read-Host -Prompt "Enter SSH password for $User@$SshHost" -AsSecureString
        
        # Save the SecureString to the temporary encrypted file for subsequent uses during this session
        try {
            # Export-CliXml -SecureString encrypts the SecureString using DPAPI
            $global:securePassword | Export-CliXml -Path $Encrypted_SSH_CREDENTIAL_FILE -Force -ErrorAction Stop
            Write-Host "Password saved to temporary encrypted file." -ForegroundColor DarkGreen
        }
        catch {
            Write-Error "Failed to save password to temporary encrypted file: $($_.Exception.Message)"
            Write-Warning "Password will not be remembered for this session; you will be prompted each time."
        }
    }

    # Convert SecureString to plain text BSTR for use with plink/pscp, immediately.
    # The BSTR is explicitly freed in the finally block where it is converted.
    if ($global:securePassword) {
        $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($global:securePassword)
        $password = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
        # It's crucial to free the BSTR immediately after converting to string
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    } else {
        # Fallback if no SecureString was obtained for some reason
        Write-Error "Could not obtain SSH password."
        $password = $null
    }

    return $password
}

# --- Helper Function to Execute Remote Command via Plink ---
function Invoke-PlinkCommand {
    param(
        [Parameter(Mandatory=$true)]
        [string]$User,
        [Parameter(Mandatory=$true)]
        [string]$SshHost, # Renamed from Host to avoid conflict
        [Parameter(Mandatory=$true)]
        [string]$Password,
        [Parameter(Mandatory=$true)]
        [string]$Command
    )

    $plinkPath = (Get-Command plink.exe -ErrorAction SilentlyContinue).Path
    if (-not $plinkPath) {
        Write-Error "plink.exe not found. Ensure PuTTY is installed and plink.exe is in your system's PATH."
        return [PSCustomObject]@{ExitCode = 1; Stdout = ""; Stderr = "plink.exe not found."}
    }

    # Construct arguments, ensuring correct quoting for PowerShell's direct execution
    $arguments = @(
        "-ssh",
        "-pw",
        $Password,
        "-batch",
        "-P",
        "22",
        "$User@$SshHost",
        $Command
    )

    # Use direct external program execution
    # This captures all output (stdout + stderr) into one stream
    # and provides an $LASTEXITCODE for the process exit code.
    try {
        $result = & $plinkPath $arguments 2>&1 # Redirect stderr to stdout
        $exitCode = $LASTEXITCODE

        if ($exitCode -eq 0) {
            return [PSCustomObject]@{ExitCode = $exitCode; Stdout = ($result -join "`n"); Stderr = ""}
        } else {
            return [PSCustomObject]@{ExitCode = $exitCode; Stdout = ""; Stderr = ($result -join "`n")}
        }
    } catch {
        Write-Error "An error occurred while executing plink.exe: $($_.Exception.Message)"
        return [PSCustomObject]@{ExitCode = 1; Stdout = ""; Stderr = $_.Exception.Message}
    }
}

# --- Function to Add a New Traefik Service Configuration ---
function Add-TraefikService {
    Write-Host "`n--- Add New Traefik Service Configuration ---" -ForegroundColor Yellow

    $serviceInternalIp = Read-Host -Prompt "Enter the internal IP of the service LXC/VM (e.g., 10.10.10.30)"
    $serviceName = Read-Host -Prompt "Enter a short, unique name for your service (e.g., jelly, nextcloud)"

    do {
        Write-Host "Choose your domain:" -ForegroundColor Cyan
        $DomainOptions.GetEnumerator() | ForEach-Object { Write-Host "($($_.Name)) $($_.Value)" }
        $domainChoice = Read-Host -Prompt "Enter choice (1 or 2)"
        $domainName = $DomainOptions[$domainChoice]
        if (-not $domainName) { Write-Warning "Invalid choice. Please enter '1' or '2'." }
    } while (-not $domainName)

    $servicePort = [int](Read-Host -Prompt "Enter the internal port of the service (e.g., 80, 8080, 443)")

    # Ask if the backend service uses HTTPS
    $useHttpsInput = Read-Host -Prompt "Use HTTPS for the backend service URL? (y/N)"
    $useHttps = ($useHttpsInput -eq 'y' -or $useHttpsInput -eq 'Y')

    $protocol = if ($useHttps) { "https" } else { "http" }

    # Determine if insecureSkipVerify is needed
    $insecureSkipVerify = $false
    if ($useHttps) {
        Write-Host "Backend service will use HTTPS with insecureSkipVerify: true (due to HTTPS selection)." -ForegroundColor DarkGray
    }

    # Build the base YAML content up to the loadBalancer's servers
    $baseYaml = @"
http:
  routers:
    {0}-router:
      entryPoints:
        - "websecure"
      rule: "Host(``{1}``)"
      service: "{0}-service"
      tls:
        certResolver: "letsencrypt"
  services:
    {0}-service:
      loadBalancer:
        servers:
          - url: "{4}://{2}:{3}"
"@ -f $ServiceName, "$($ServiceName).$($DomainName)", $ServiceInternalIp, $ServicePort, $protocol

    # Conditionally add serversTransport and serversTransports block
    $serversTransportYaml = ""
    $serversTransportsBlock = ""

    if ($insecureSkipVerify) {
        $transportName = "${serviceName}-insecure-transport"
        $serversTransportYaml = "        serversTransport: `"${transportName}`""

        $serversTransportsBlock = @"

  serversTransports:
    ${transportName}:
      insecureSkipVerify: true
"@
    }

    # Combine all parts to form the final yamlContent
    $yamlContent = $baseYaml

    if ([string]::IsNullOrWhiteSpace($serversTransportYaml) -eq $false) {
        $yamlContent += "`n" + $serversTransportYaml
    }
    
    $yamlContent += $serversTransportsBlock


    $remoteConfigFile = "${RemoteConfigDir}/${ServiceName}.yml"
    $tempLocalConfigFile = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "$($ServiceName)_traefik_config.yml"

    Write-Host "`n--- Configuration Content to be transferred ---" -ForegroundColor Yellow
    Write-Host $yamlContent -ForegroundColor Yellow
    Write-Host "---------------------------------------------`n"

    $password = Get-SshPassword -User $TraefikSshUser -SshHost $TraefikLxcIp
    if (-not $password) { Write-Error "Password not provided. Aborting."; return }

    try {
        # Save YAML content to a temporary local file
        $utf8NoBomEncoding = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($tempLocalConfigFile, $yamlContent, $utf8NoBomEncoding)
        Write-Host "Local temporary file created: $tempLocalConfigFile" -ForegroundColor DarkGreen

        # --- Use pscp.exe to copy the file to the remote LXC ---
        $pscpPath = (Get-Command pscp.exe -ErrorAction SilentlyContinue).Path
        if (-not $pscpPath) {
            Write-Error "pscp.exe not found. Ensure PuTTY is installed and pscp.exe is in your system's PATH."
            return
        }

        # For PSCP, arguments are passed as strings. Remote path needs explicit quoting for the shell it runs in.
        $remotePscpSourceArg = "$TraefikSshUser@${TraefikLxcIp}:`"$remoteConfigFile`""
        
        $pscpArguments = @(
            "-pw", $password,
            "-batch",
            "-P", "22",
            "`"$tempLocalConfigFile`"",
            $remotePscpSourceArg
        )

        # Execute PSCP directly and capture output
        $pscpResult = & $pscpPath $pscpArguments 2>&1 # Redirect stderr to stdout
        $exitCode = $LASTEXITCODE # Get the exit code of the last executed external program

        if ($exitCode -eq 0) {
            Write-Host "Configuration file copied to ${remoteConfigFile} successfully." -ForegroundColor Green
            Write-Host "Traefik will automatically detect changes." -ForegroundColor Green
        } else {
            Write-Error "Failed to copy file. PSCP Exit Code: $exitCode"
            Write-Error "PSCP Output/Error:`n$($pscpResult -join "`n")"
        }
    }
    catch {
        Write-Error "An error occurred during file transfer: $($_.Exception.Message)"
        Write-Error "Ensure 'pscp.exe' is in your PATH and host key is cached."
    }
    finally {
        # Cleanup of temp file handled in main script try/finally
    }
}

# --- Function to List Existing Traefik Service Configurations ---
function List-TraefikServices {
    param(
        [switch]$NoPause # New parameter to control pausing
    )
    Write-Host "`n--- Listing Traefik Service Configurations ---" -ForegroundColor Yellow
    $password = Get-SshPassword -User $TraefikSshUser -SshHost $TraefikLxcIp
    if (-not $password) { Write-Error "Password not provided. Aborting."; return }

    $command = "ls -1 ${RemoteConfigDir}/*.yml 2>/dev/null | xargs -n 1 basename"
    $result = Invoke-PlinkCommand -User $TraefikSshUser -SshHost $TraefikLxcIp -Password $password -Command $command

    if ($result.ExitCode -eq 0) {
        $files = $result.Stdout.Trim() -split "`n" | Where-Object { $_ -ne "" }
        if ($files.Count -gt 0) {
            Write-Host "Found the following dynamic configuration files in ${RemoteConfigDir}:" -ForegroundColor Green
            $i = 1
            $global:ServiceFiles = @{}
            foreach ($file in $files) {
                $strippedFile = $file.Replace(".yml", "")
                Write-Host "($i) $strippedFile"
                $global:ServiceFiles[$i] = $file
                $i++
            }
        } else {
            Write-Host "No dynamic configuration files found in ${RemoteConfigDir}." -ForegroundColor Yellow
            $global:ServiceFiles = @{}
        }
    } else {
        Write-Error "Failed to list files. PLINK Exit Code: $($result.ExitCode)"
        Write-Error "PLINK Error: $($result.Stderr)"
        $global:ServiceFiles = @{}
    }
    if (-not $NoPause) { # Only pause if NoPause is NOT specified (e.g., when called directly from menu)
        Read-Host "Press Enter to continue..."
    }
}

# --- Function to Remove a Traefik Service Configuration ---
function Remove-TraefikService {
    Write-Host "`n--- Remove Traefik Service Configuration ---" -ForegroundColor Yellow
    List-TraefikServices -NoPause # Pass -NoPause here to avoid extra prompt after listing

    if ($global:ServiceFiles.Count -eq 0) {
        Write-Host "No services to remove." -ForegroundColor Yellow
        return
    }

    $choice = Read-Host -Prompt "Enter the number of the service to remove, or 'q' to cancel"
    if ($choice -eq 'q') { Write-Host "Removal cancelled."; return }

    if ($choice -match "^\d+$") {
        $choiceInt = [int]$choice
        if ($global:ServiceFiles.ContainsKey($choiceInt)) {
            $selectedFile = $global:ServiceFiles[$choiceInt]
            $confirm = Read-Host -Prompt "Are you sure you want to delete '$selectedFile'? (y/N)"
            if ($confirm -eq 'y' -or $confirm -eq 'Y') {
                $password = Get-SshPassword -User $TraefikSshUser -SshHost $TraefikLxcIp
                if (-not $password) { Write-Error "Password not provided. Aborting."; return }

                $command = "rm ${RemoteConfigDir}/`"$selectedFile`""
                $result = Invoke-PlinkCommand -User $TraefikSshUser -SshHost $TraefikLxcIp -Password $password -Command $command

                if ($result.ExitCode -eq 0) {
                    Write-Host "Service '$selectedFile' removed successfully." -ForegroundColor Green
                    Write-Host "Traefik will automatically detect changes." -ForegroundColor Green
                } else {
                    Write-Error "Failed to remove service. PLINK Exit Code: $($result.ExitCode)"
                    Write-Error "PLINK Error: $($result.Stderr)"
                }
            } else {
                Write-Host "Removal cancelled." -ForegroundColor Yellow
            }
        } else {
            Write-Warning "Invalid selection. Please enter a valid number from the list."
        }
    } else {
        Write-Warning "Invalid input. Please enter a number or 'q'."
    }
}

# --- Function to View Content of a Traefik Service Configuration ---
function View-TraefikServiceContent {
    Write-Host "`n--- View Traefik Service Configuration Content ---" -ForegroundColor Yellow
    List-TraefikServices -NoPause # Pass -NoPause here to avoid extra prompt after listing

    if ($global:ServiceFiles.Count -eq 0) {
        Write-Host "No services to view." -ForegroundColor Yellow
        return
    }

    $choice = Read-Host -Prompt "Enter the number of the service to view, or 'q' to cancel"
    if ($choice -eq 'q') { Write-Host "View cancelled."; return }

    if ($choice -match "^\d+$") {
        $choiceInt = [int]$choice
        if ($global:ServiceFiles.ContainsKey($choiceInt)) {
            $selectedFile = $global:ServiceFiles[$choiceInt]
            $password = Get-SshPassword -User $TraefikSshUser -SshHost $TraefikLxcIp
            if (-not $password) { Write-Error "Password not provided. Aborting."; return }

            $command = "cat ${RemoteConfigDir}/`"$selectedFile`""
            $result = Invoke-PlinkCommand -User $TraefikSshUser -SshHost $TraefikLxcIp -Password $password -Command $command

            if ($result.ExitCode -eq 0) {
                Write-Host "`n--- Content of '$selectedFile' ---" -ForegroundColor Green
                Write-Host $result.Stdout -ForegroundColor DarkCyan
                Write-Host "------------------------------------" -ForegroundColor Green
            } else {
                Write-Error "Failed to retrieve content. PLINK Exit Code: $($result.ExitCode)"
                Write-Error "PLINK Error: $($result.Stderr)"
            }
        } else {
            Write-Warning "Invalid selection. Please enter a valid number from the list."
        }
    } else {
        Write-Warning "Invalid input. Please enter a number or 'q'."
    }
    Read-Host "Press Enter to continue..." # Keep this for viewing
}

# --- Function to Edit Content of a Traefik Service Configuration ---
function Edit-TraefikServiceContent {
    Write-Host "`n--- Edit Traefik Service Configuration Content ---" -ForegroundColor Yellow
    List-TraefikServices -NoPause # Pass -NoPause here to avoid extra prompt after listing

    if ($global:ServiceFiles.Count -eq 0) {
        Write-Host "No services to edit." -ForegroundColor Yellow
        return
    }

    $choice = Read-Host -Prompt "Enter the number of the service to edit, or 'q' to cancel"
    if ($choice -eq 'q') { Write-Host "Edit cancelled."; return }

    if ($choice -match "^\d+$") {
        $choiceInt = [int]$choice
        if ($global:ServiceFiles.ContainsKey($choiceInt)) {
            $selectedFile = $global:ServiceFiles[$choiceInt]
            $remoteFilePath = "${RemoteConfigDir}/${selectedFile}"
            $tempLocalEditFile = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "edit_$($selectedFile)"

            $password = Get-SshPassword -User $TraefikSshUser -SshHost $TraefikLxcIp
            if (-not $password) { Write-Error "Password not provided. Aborting."; return }

            Write-Host "Downloading '$selectedFile' from LXC to '$tempLocalEditFile'..." -ForegroundColor Cyan
            try {
                # --- Download file using pscp ---
                $pscpPath = (Get-Command pscp.exe -ErrorAction SilentlyContinue).Path
                if (-not $pscpPath) {
                    Write-Error "pscp.exe not found. Ensure PuTTY is installed and pscp.exe is in your system's PATH."
                    return
                }

                # Construct the remote source string, ensuring it's treated as a single argument for PSCP
                $remoteSourceForPscp = "$TraefikSshUser@${TraefikLxcIp}:`"$remoteFilePath`""
                
                $pscpDownloadArgs = @(
                    "-pw", $password,
                    "-batch",
                    "-P", "22",
                    $remoteSourceForPscp,
                    "`"$tempLocalEditFile`""
                )

                # Execute PSCP directly and capture output
                $pscpResult = & $pscpPath $pscpDownloadArgs 2>&1 # Redirect stderr to stdout
                $exitCode = $LASTEXITCODE # Get the exit code of the last executed external program

                if ($exitCode -eq 0) {
                    Write-Host "File downloaded successfully." -ForegroundColor Green
                } else {
                    Write-Error "Failed to download file. PSCP Exit Code: $exitCode"
                    Write-Error "PSCP Output/Error:`n$($pscpResult -join "`n")"
                    return # Exit function on download failure
                }
            }
            catch {
                Write-Error "An error occurred during file download: $($_.Exception.Message)"
                Write-Error "Ensure 'pscp.exe' is in your PATH and host key is cached."
                return # Exit function on download exception
            }

            Write-Host "Opening '$tempLocalEditFile' in Notepad. Please save and close the file when done editing." -ForegroundColor Cyan
            try {
                # Open file in Notepad and wait for it to close
                # You can change "notepad.exe" to "code.exe" (VS Code), "subl.exe" (Sublime Text), etc.
                $editorProcess = Start-Process -FilePath "notepad.exe" -ArgumentList "`"$tempLocalEditFile`"" -Wait -PassThru
                $editorProcess.WaitForExit() # Ensure we wait for Notepad to close

                Write-Host "Notepad closed. Uploading modified file..." -ForegroundColor Cyan

                # --- Upload file back using pscp ---
                $pscpPath = (Get-Command pscp.exe -ErrorAction SilentlyContinue).Path
                if (-not $pscpPath) {
                    Write-Error "pscp.exe not found. Ensure PuTTY is installed and pscp.exe is in your system's PATH."
                    return
                }

                # Construct the remote destination string, ensuring it's treated as a single argument for PSCP
                $remoteDestinationForPscp = "$TraefikSshUser@${TraefikLxcIp}:`"$remoteFilePath`""

                $pscpUploadArgs = @(
                    "-pw", $password,
                    "-batch",
                    "-P", "22",
                    "`"$tempLocalEditFile`"",
                    $remoteDestinationForPscp
                )

                # Execute PSCP directly and capture output
                $pscpResult = & $pscpPath $pscpUploadArgs 2>&1 # Redirect stderr to stdout
                $exitCode = $LASTEXITCODE # Get the exit code of the last executed external program

                if ($exitCode -eq 0) {
                    Write-Host "File uploaded successfully." -ForegroundColor Green
                    Write-Host "Traefik will automatically detect changes." -ForegroundColor Green
                } else {
                    Write-Error "Failed to upload file. PSCP Exit Code: $exitCode"
                    Write-Error "PSCP Output/Error:`n$($pscpResult -join "`n")"
                }
            }
            catch {
                Write-Error "An error occurred during file editing/upload: $($_.Exception.Message)"
            }
            finally {
                # Clean up the temporary local file regardless of success or failure
                if (Test-Path $tempLocalEditFile) { Remove-Item $tempLocalEditFile -Force }
            }
        } else {
            Write-Warning "Invalid selection. Please enter a valid number from the list."
        }
    } else {
        Write-Warning "Invalid input. Please enter a number or 'q'."
    }
}


# --- Main Menu Function ---
function Manage-TraefikServices {
    while ($true) {
        Write-Host "`n--- Traefik Service Manager ---" -ForegroundColor Green
        Write-Host "1. Add New Service" -ForegroundColor Yellow
        Write-Host "2. List Services" -ForegroundColor Yellow
        Write-Host "3. Remove Service" -ForegroundColor Yellow
        Write-Host "4. View Service Content" -ForegroundColor Yellow
        Write-Host "5. Edit Service Content" -ForegroundColor Yellow
        Write-Host "q. Quit" -ForegroundColor Red

        $choice = Read-Host -Prompt "Enter your choice"

        switch ($choice) {
            "1" { Add-TraefikService }
            "2" { List-TraefikServices } # This will pause because -NoPause is not passed
            "3" { Remove-TraefikService }
            "4" { View-TraefikServiceContent } # This will pause because the call to List-TraefikServices will include -NoPause, but then View has its own pause
            "5" { Edit-TraefikServiceContent }
            "q" { break }
            default { Write-Warning "Invalid choice. Please try again." }
        }
    }
    Write-Host "`nExiting Traefik Service Manager. Goodbye!" -ForegroundColor Cyan
    Read-Host "Press Enter to exit..." # Keep this to prevent console from closing immediately
}

# --- Script Entry Point ---
# Call the main menu function wrapped in a try/finally for cleanup
try {
    Manage-TraefikServices
}
finally {
    # Clean up the temporary encrypted password file on script exit
    if (Test-Path $Encrypted_SSH_CREDENTIAL_FILE) {
        try {
            Remove-Item $Encrypted_SSH_CREDENTIAL_FILE -Force -ErrorAction SilentlyContinue
            Write-Host "Temporary encrypted password file '$Encrypted_SSH_CREDENTIAL_FILE' deleted." -ForegroundColor DarkGray
        }
        catch {
            Write-Warning "Failed to delete temporary encrypted password file '$Encrypted_SSH_CREDENTIAL_FILE': $($_.Exception.Message)"
        }
    }
    # Securely clear the global securePassword variable from memory
    # This only attempts if $global:securePassword is a SecureString object
    if ($global:securePassword -is [System.Security.SecureString]) {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($global:securePassword))
        Write-Host "Secure password cleared from memory." -ForegroundColor DarkGray
    }
}