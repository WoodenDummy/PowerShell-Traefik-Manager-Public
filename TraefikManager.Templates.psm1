# TraefikManager.Templates.psm1
# Template management for Traefik services

#Requires -Version 5.1
Set-StrictMode -Version Latest

# --- Template Management Functions ---
function Get-TemplateDirectory {
    $templateDir = Join-Path (Get-Location) "templates"
    if (-not (Test-Path $templateDir)) {
        New-Item -ItemType Directory -Path $templateDir -Force | Out-Null
        Write-TraefikLog "Created templates directory: $templateDir" -Level "Info"
    }
    return $templateDir
}

function Get-ServiceTemplates {
    [CmdletBinding()]
    param()

    try {
        $templateDir = Get-TemplateDirectory
        $templateFiles = @(Get-ChildItem -Path $templateDir -Filter "*.yml" -ErrorAction SilentlyContinue)
        
        $templates = @()
        foreach ($file in $templateFiles) {
            try {
                $content = Get-Content -Path $file.FullName -Raw -ErrorAction Stop
                $metadata = Get-TemplateMetadata -Content $content -FileName $file.Name
                
                $templates += [PSCustomObject]@{
                    Name = $file.BaseName
                    FileName = $file.Name
                    FilePath = $file.FullName
                    Description = $metadata.Description
                    Variables = $metadata.Variables
                    Category = $metadata.Category
                    CreatedDate = $file.CreationTime
                    Size = [Math]::Round($file.Length / 1KB, 2)
                }
            }
            catch {
                Write-TraefikLog "Error reading template $($file.Name): $($_.Exception.Message)" -Level "Warning"
            }
        }
        
        Write-TraefikLog "Found $($templates.Count) service templates" -Level "Info"
        return $templates | Sort-Object Name
    }
    catch {
        Write-TraefikLog "Error retrieving templates: $($_.Exception.Message)" -Level "Error"
        return @()
    }
}

function Get-TemplateMetadata {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Content,
        
        [Parameter(Mandatory = $true)]
        [string]$FileName
    )

    $metadata = [PSCustomObject]@{
        Description = "Custom template"
        Variables = @()
        Category = "General"
    }

    # Parse template metadata from comments
    $lines = $Content -split "`n"
    foreach ($line in $lines) {
        $trimmed = $line.Trim()
        
        if ($trimmed -match '^#\s*Description:\s*(.+)$') {
            $metadata.Description = $matches[1].Trim()
        }
        elseif ($trimmed -match '^#\s*Category:\s*(.+)$') {
            $metadata.Category = $matches[1].Trim()
        }
        elseif ($trimmed -match '^#\s*Variables?:\s*(.+)$') {
            $variableList = $matches[1].Trim() -split '[,;]'
            $metadata.Variables = @($variableList | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        }
    }

    # Auto-detect variables from template placeholders
    $autoVariables = @()
    if ($Content -match '\{\{(\w+)\}\}') {
        $autoVariables = @([regex]::Matches($Content, '\{\{(\w+)\}\}') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
    }
    
    if ($autoVariables.Count -gt 0) {
        $metadata.Variables = $autoVariables
    }

    return $metadata
}

function Import-ServiceTemplate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourcePath,
        
        [Parameter(Mandatory = $false)]
        [string]$TemplateName = ""
    )

    try {
        if (-not (Test-Path $SourcePath)) {
            throw "Template file not found: $SourcePath"
        }

        $templateDir = Get-TemplateDirectory
        
        # Generate template name if not provided
        if ([string]::IsNullOrWhiteSpace($TemplateName)) {
            $TemplateName = [System.IO.Path]::GetFileNameWithoutExtension($SourcePath)
        }
        
        # Ensure .yml extension
        if (-not $TemplateName.EndsWith(".yml")) {
            $TemplateName += ".yml"
        }

        $destinationPath = Join-Path $templateDir $TemplateName
        
        # Check if template already exists
        if (Test-Path $destinationPath) {
            $overwrite = Get-YesNoInput -Prompt "Template '$TemplateName' already exists. Overwrite?" -DefaultToNo $true
            if (-not $overwrite) {
                Write-TraefikLog "Template import cancelled by user" -Level "Info"
                return $false
            }
        }

        # Copy the template
        Copy-Item -Path $SourcePath -Destination $destinationPath -Force -ErrorAction Stop
        
        Write-TraefikLog "Successfully imported template: $TemplateName" -Level "Success"
        return $true
    }
    catch {
        Write-TraefikLog "Error importing template: $($_.Exception.Message)" -Level "Error"
        return $false
    }
}

function New-ServiceFromTemplate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Template,
        
        [Parameter(Mandatory = $true)]
        [hashtable]$Variables
    )

    try {
        # Read template content
        $templateContent = Get-Content -Path $Template.FilePath -Raw -ErrorAction Stop
        
        # Replace variables in template
        $processedContent = $templateContent
        foreach ($variable in $Variables.Keys) {
            $placeholder = "{{$variable}}"
            $value = $Variables[$variable]
            $processedContent = $processedContent -replace [regex]::Escape($placeholder), $value
            Write-TraefikLog "Replaced $placeholder with $value" -Level "Debug"
        }
        
        # Check for unreplaced variables
        $unreplacedMatches = [regex]::Matches($processedContent, '\{\{(\w+)\}\}')
        if ($unreplacedMatches.Count -gt 0) {
            $unreplacedVars = @($unreplacedMatches | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
            Write-TraefikLog "Warning: Unreplaced variables found: $($unreplacedVars -join ', ')" -Level "Warning"
        }
        
        Write-TraefikLog "Successfully processed template: $($Template.Name)" -Level "Success"
        return $processedContent
    }
    catch {
        Write-TraefikLog "Error processing template: $($_.Exception.Message)" -Level "Error"
        return $null
    }
}

function Remove-ServiceTemplate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$TemplateName
    )

    try {
        $templateDir = Get-TemplateDirectory
        $templatePath = Join-Path $templateDir "$TemplateName.yml"
        
        if (-not (Test-Path $templatePath)) {
            Write-TraefikLog "Template not found: $TemplateName" -Level "Warning"
            return $false
        }

        $confirm = Get-YesNoInput -Prompt "Are you sure you want to delete template '$TemplateName'?" -DefaultToNo $true
        if (-not $confirm) {
            Write-TraefikLog "Template deletion cancelled" -Level "Info"
            return $false
        }

        Remove-Item -Path $templatePath -Force -ErrorAction Stop
        Write-TraefikLog "Successfully deleted template: $TemplateName" -Level "Success"
        return $true
    }
    catch {
        Write-TraefikLog "Error deleting template: $($_.Exception.Message)" -Level "Error"
        return $false
    }
}

function Show-TemplateContent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Template
    )

    try {
        $content = Get-Content -Path $Template.FilePath -Raw -ErrorAction Stop
        
        Write-Host "`n--- Template: $($Template.Name) ---" -ForegroundColor Green
        Write-Host "Description: $($Template.Description)" -ForegroundColor Cyan
        Write-Host "Category: $($Template.Category)" -ForegroundColor Cyan
        Write-Host "Variables: $($Template.Variables -join ', ')" -ForegroundColor Cyan
        Write-Host "`n--- Template Content ---" -ForegroundColor Yellow
        Write-Host $content -ForegroundColor White
        Write-Host "------------------------" -ForegroundColor Yellow
    }
    catch {
        Write-TraefikLog "Error displaying template content: $($_.Exception.Message)" -Level "Error"
        Write-Host "Error reading template content" -ForegroundColor Red
    }
}

function Get-TemplateVariables {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Template
    )

    $variables = @{}
    
    foreach ($varName in $Template.Variables) {
        switch ($varName.ToLower()) {
            "servicename" {
                $value = Get-ValidatedInput -Prompt "Enter service name" -ValidationFunction { param($name) Test-ServiceName $name } -ErrorMessage "Invalid service name format"
                $variables[$varName] = $value
            }
            "serviceip" {
                $value = Get-ValidatedInput -Prompt "Enter service IP address" -ValidationFunction { param($ip) Test-IPAddress $ip } -ErrorMessage "Invalid IP address format"
                $variables[$varName] = $value
            }
            "serviceport" {
                $value = Get-ValidatedInput -Prompt "Enter service port" -ValidationFunction { param($port) Test-PortNumber $port } -ErrorMessage "Invalid port number"
                $variables[$varName] = $value
            }
            "domain" {
                Write-Host "Available domains:" -ForegroundColor Cyan
                $script:Config.DomainOptions.PSObject.Properties | ForEach-Object { 
                    Write-Host "($($_.Name)) $($_.Value)" 
                }
                $domainChoice = Read-Host -Prompt "Select domain number"
                $variables[$varName] = $script:Config.DomainOptions.$domainChoice
            }
            "certresolver" {
                $variables[$varName] = $script:Config.CertificateResolver
            }
            default {
                $value = Read-Host -Prompt "Enter value for $varName"
                $variables[$varName] = $value
            }
        }
    }
    
    return $variables
}

# --- Built-in Template Creation ---
function New-DefaultTemplates {
    [CmdletBinding()]
    param()

    $templateDir = Get-TemplateDirectory
    
    # NextCloud Template
    $nextcloudTemplate = @"
# Description: NextCloud file sharing service
# Category: Productivity
# Variables: ServiceName, ServiceIP, ServicePort, Domain, CertResolver

http:
  routers:
    {{ServiceName}}-router:
      entryPoints:
        - "websecure"
      rule: "Host(``{{ServiceName}}.{{Domain}}``)"
      service: "{{ServiceName}}-service"
      middlewares:
        - "{{ServiceName}}-headers"
      tls:
        certResolver: "{{CertResolver}}"
  
  services:
    {{ServiceName}}-service:
      loadBalancer:
        servers:
          - url: "http://{{ServiceIP}}:{{ServicePort}}"
  
  middlewares:
    {{ServiceName}}-headers:
      headers:
        customRequestHeaders:
          X-Forwarded-Proto: "https"
        customResponseHeaders:
          X-Frame-Options: "SAMEORIGIN"
          X-Content-Type-Options: "nosniff"
"@

    # Jellyfin Template
    $jellyfinTemplate = @"
# Description: Jellyfin media server
# Category: Media
# Variables: ServiceName, ServiceIP, ServicePort, Domain, CertResolver

http:
  routers:
    {{ServiceName}}-router:
      entryPoints:
        - "websecure"
      rule: "Host(``{{ServiceName}}.{{Domain}}``)"
      service: "{{ServiceName}}-service"
      tls:
        certResolver: "{{CertResolver}}"
  
  services:
    {{ServiceName}}-service:
      loadBalancer:
        servers:
          - url: "http://{{ServiceIP}}:{{ServicePort}}"
"@

    # Home Assistant Template
    $homeAssistantTemplate = @"
# Description: Home Assistant home automation
# Category: Smart Home
# Variables: ServiceName, ServiceIP, ServicePort, Domain, CertResolver

http:
  routers:
    {{ServiceName}}-router:
      entryPoints:
        - "websecure"
      rule: "Host(``{{ServiceName}}.{{Domain}}``)"
      service: "{{ServiceName}}-service"
      middlewares:
        - "{{ServiceName}}-headers"
      tls:
        certResolver: "{{CertResolver}}"
  
  services:
    {{ServiceName}}-service:
      loadBalancer:
        servers:
          - url: "http://{{ServiceIP}}:{{ServicePort}}"
  
  middlewares:
    {{ServiceName}}-headers:
      headers:
        customRequestHeaders:
          X-Forwarded-For: ""
          X-Forwarded-Proto: "https"
          X-Forwarded-Port: "443"
"@

    # Create default templates
    $templates = @{
        "nextcloud.yml" = $nextcloudTemplate
        "jellyfin.yml" = $jellyfinTemplate
        "homeassistant.yml" = $homeAssistantTemplate
    }

    $created = 0
    foreach ($templateName in $templates.Keys) {
        $templatePath = Join-Path $templateDir $templateName
        if (-not (Test-Path $templatePath)) {
            $templates[$templateName] | Set-Content -Path $templatePath -Encoding UTF8 -ErrorAction SilentlyContinue
            $created++
        }
    }

    if ($created -gt 0) {
        Write-TraefikLog "Created $created default templates" -Level "Success"
    }
}

# Initialize default templates on module import
New-DefaultTemplates

# Export functions
Export-ModuleMember -Function @(
    'Get-ServiceTemplates',
    'Import-ServiceTemplate',
    'New-ServiceFromTemplate',
    'Remove-ServiceTemplate',
    'Show-TemplateContent',
    'Get-TemplateVariables',
    'New-DefaultTemplates'
)