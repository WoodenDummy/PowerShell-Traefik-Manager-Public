# Traefik Service Manager

A PowerShell-based tool for managing Traefik service configurations via SSH. This tool provides a user-friendly interface for adding, removing, editing, and managing Traefik service configurations on a remote server.

## Features

- 🚀 **Easy Service Management**: Add, remove, edit, and view Traefik service configurations
- 🔧 **Interactive Setup**: Guided configuration wizard for first-time setup
- 🔒 **Secure SSH**: Encrypted password storage and secure SSH connections
- 📋 **Service Discovery**: Automatically discover existing Traefik services
- 💾 **Automatic Backups**: Optional backup system for service configurations
- 🎯 **Multiple Domains**: Support for multiple domain configurations
- 📝 **Editor Integration**: Works with your preferred text editor
- 🔄 **Service Restoration**: Restore services from backups

## Prerequisites

1. **PowerShell 5.1 or later**
2. **PuTTY Tools** (plink.exe and pscp.exe must be in your PATH)
   - Download from: [PuTTY Download Page](https://www.putty.org/)
   - Or install via Chocolatey: `choco install putty`
   - Or install via Windows Package Manager: `winget install PuTTY.PuTTY`
3. **SSH access** to your Traefik server
4. **Traefik** configured with file provider watching a configuration directory

## Installation

1. Download all the PowerShell module files:
   - `TraefikManager-Modular.ps1` (main script)
   - `TraefikManager.Core.psm1`
   - `TraefikManager.SSH.psm1`
   - `TraefikManager.Services.psm1`
   - `TraefikManager.Config.psm1`
   - `TraefikManager.Backup.psm1`
   - `TraefikManager.UI.psm1`

2. Place all files in the same directory

3. Run the main script:
   ```powershell
   .\TraefikManager-Modular.ps1
   ```

## First Run Setup

When you run the script for the first time, you'll be guided through a configuration wizard that will ask for:

### Traefik Server Configuration
- **Server IP Address**: The IP address of your Traefik server
- **SSH Username**: Username for SSH access (typically `root` or your admin user)
- **SSH Port**: SSH port (default: 22)
- **Configuration Directory**: Remote path where Traefik reads configurations (default: `/etc/traefik/conf.d`)

### Domain Configuration
- **Primary Domain**: Your main domain (e.g., `example.com`)
- **Additional Domains**: Any additional domains you want to use
- Services will be created as subdomains (e.g., `servicename.example.com`)

### Editor Configuration
Choose your preferred text editor:
- Notepad (Windows default)
- Visual Studio Code
- Notepad++
- Custom editor path

### Backup Settings
- Enable/disable automatic backups when editing or removing services
- Backups are stored locally in a `backups` folder

### Advanced Settings (Optional)
- Connection timeout settings
- Retry configuration
- SSH connection parameters

## Usage

### Main Menu Options

1. **Add New Service**: Create a new Traefik service configuration
2. **List Services**: View all discovered Traefik services
3. **Remove Service**: Delete a service configuration (with optional backup)
4. **View Service Content**: Display the YAML configuration of a service
5. **Edit Service Content**: Edit service configuration in your preferred editor
6. **Restore from Backup**: Restore a service from a previously created backup
7. **Show Configuration**: Display current tool configuration
8. **Test Connection**: Test SSH connectivity to your Traefik server

### Adding a Service

When adding a service, you'll be prompted for:
- **Service IP**: Internal IP address of your service (e.g., `192.168.1.100`)
- **Service Name**: Short, unique identifier (e.g., `nextcloud`, `jellyfin`)
- **Service Port**: Internal port your service runs on (e.g., `8080`, `80`)
- **Domain**: Choose from your configured domains
- **HTTPS Backend**: Whether your service uses HTTPS internally

### Example Service Configuration

The tool generates Traefik configurations like this:
```yaml
http:
  routers:
    myservice-router:
      entryPoints:
        - "websecure"
      rule: "Host(`myservice.example.com`)"
      service: "myservice-service"
      tls:
        certResolver: "letsencrypt"
  services:
    myservice-service:
      loadBalancer:
        servers:
          - url: "http://192.168.1.100:8080"
```

## Configuration File

The tool creates a `config.json` file with your settings:

```json
{
  "TraefikLxcIp": "192.168.1.10",
  "TraefikSshUser": "root",
  "RemoteConfigDir": "/etc/traefik/conf.d",
  "DomainOptions": {
    "1": "example.com",
    "2": "internal.example.com"
  },
  "ConnectionSettings": {
    "MaxRetries": 3,
    "RetryDelaySeconds": 2,
    "TimeoutSeconds": 30,
    "SSHPort": 22
  },
  "LogLevel": "Info",
  "Editor": "notepad.exe",
  "BackupEnabled": true,
  "BackupDirectory": "backups"
}
```

## Backup System

If enabled, the tool automatically creates backups:
- Before editing services (`servicename_pre_edit_timestamp.yml`)
- Before removing services (`servicename_pre_delete_timestamp.yml`)
- Before restoring services (`servicename_pre_restore_timestamp.yml`)

Backups are stored in the `backups` folder and can be restored through the tool's restore function.

## Troubleshooting

### Common Issues

1. **"plink.exe not found"**
   - Install PuTTY and ensure it's in your system PATH
   - Verify installation: `plink.exe -V` in Command Prompt

2. **SSH Host Key Issues**
   - The tool will attempt to automatically accept host keys
   - If prompted manually, run: `plink.exe -ssh user@server -P port` and accept the key

3. **Permission Denied**
   - Ensure your SSH user has write access to the Traefik configuration directory
   - Check that the remote directory path is correct

4. **Services Not Appearing in Traefik**
   - Verify Traefik is configured to watch your configuration directory
   - Check Traefik logs for configuration errors
   - Ensure YAML syntax is valid

### Configuration Reset

To reset your configuration, simply delete the `config.json` file and run the script again.

## Security Notes

- SSH passwords are stored encrypted using Windows DPAPI
- Temporary credential files are automatically cleaned up
- All sensitive data is cleared from memory on exit
- Backup files contain service configurations (review before sharing)

## Contributing

This tool is designed to be modular and extensible. Each module handles specific functionality:
- **Core**: Configuration and validation
- **SSH**: SSH communication and file transfer
- **Services**: Service discovery and management
- **Config**: YAML generation and deployment
- **Backup**: Backup and restore functionality
- **UI**: User interface and menus

## License

This project is provided as-is for educational and personal use. Please review and test thoroughly before using in production environments.

## Support

For issues or questions:
1. Check the troubleshooting section above
2. Review Traefik documentation for configuration requirements
3. Ensure all prerequisites are properly installed
4. Check the generated log file (`traefik-manager.log`) for detailed error information