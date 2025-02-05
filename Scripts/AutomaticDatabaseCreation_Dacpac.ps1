# AutoPilot Database Setup Script
# This script automates the setup of AutoPilot databases using Redgate's Flyway and dbatools.
# The following steps outline the process, which can also be performed manually in SSMS:
#
# 1. Ensures the dbatools module is installed.
# 2. Collects user input for the source database and SQL Server instance.
# 3. Retrieve the default SQL Server database file paths.
# 4. Export the schema of the source database to a fixed DACPAC file.
# 5. Retrieve the logical file names from the source database.
# 6. Deploy AutoPilotDev, AutoPilotTest, and AutoPilotProd using the DACPAC.
# 7. Backup AutoPilotDev as a Schema Only Backup for use as a baseline in Flyway.
# 8. Update Flyway.toml to reference the new backup file.

# Parameter List - These are optional input parameters
param (
    [string]$projectDir,
    [string]$serverName,
    [string]$sourceDB,
    [ValidateSet("Y", "N")][string]$TrustCert,
    [ValidateSet("Y", "N")][string]$EncryptConnection,
    [string]$backupDir,
    [string]$dacpacFile
)


# Ensure dbatools module is installed
if (!(Get-Module -ListAvailable -Name dbatools)) {
  Write-Host "dbatools module not found. Installing module..."
  Install-Module -Name dbatools -Force -AllowClobber
  Write-Host "dbatools module installed successfully."
} else {
  Write-Host "dbatools module is already installed."
}

# Function for validated input
function Get-ValidatedInput {
  param (
      [string]$PromptMessage,
      [string]$ErrorMessage
  )
  do {
      $inputValue = Read-Host $PromptMessage
      if ([string]::IsNullOrWhiteSpace($inputValue)) {
          Write-Host $ErrorMessage -ForegroundColor Red
      }
  } until (![string]::IsNullOrWhiteSpace($inputValue))
  return $inputValue
}

Write-Host "Flyway AutoPilot Backup & Running Setup - To get up and running, it's necessary to create a Schema Only backup of a chosen database. This will then be used to create your AutoPilot project databases."
Write-Host "Step 1: Provide the connection details for your preferred PoC database"
Write-Host "Tip - Restore your preferred database into a non-production SQL Server Instance. This will help to create our PoC sandbox, where the AutoPilot databases will also exist."

# Prompt for inputs with validation
if (-not $sourceDB) { $sourceDB = Get-ValidatedInput -PromptMessage "Enter the Source Database Name to be Schema Backed Up (e.g., MyDatabaseName)" `
  -ErrorMessage "Database name cannot be empty. Please provide a valid database name." }

# Detect AutoPilot root directory based on the script's current location
if ($PSScriptRoot -and -not $projectDir) {
  $defaultProjectDir = Split-Path -Path $PSScriptRoot -Parent
  Write-Host "Detected Autopilot Root Project path: $defaultProjectDir" -ForegroundColor Green
} else {
  Write-Host "Script root path could not be detected. Please provide the AutoPilot Root Project path."
  $defaultProjectDir = $null
}

if (-not $projectDir) {
  $projectDir = Read-Host "Do you want to use this path? Press Enter to confirm or provide a new path"
}

if ([string]::IsNullOrWhiteSpace($projectDir)) {
  $projectDir = $defaultProjectDir
}


# Validate project directory exists
if (!(Test-Path -Path $projectDir)) {
  Write-Host "The specified project directory does not exist. Please check the path." -ForegroundColor Red
  exit
}

Write-Host "Project directory confirmed: $projectDir"

# Setup backup directory and paths
$defaultBackupDir = Join-Path $projectDir "backups"

# Ensure backup directory exists
if (!(Test-Path -Path $defaultBackupDir)) {
  New-Item -Path $defaultBackupDir -ItemType Directory | Out-Null
}

if ($backupDir) {
  Write-Host "Detected Autopilot Parameter Backup Folder: $backupDir"
}
else {
   Write-Host "Detected Autopilot Default Backup Folder: $defaultBackupDir"
}

if (-not $backupDir) {
  $backupDir = Read-Host "Do you want to use this path? Press Enter to confirm or provide a new backup folder path"
}

# Use detected path if user doesn't provide a new one
if ([string]::IsNullOrWhiteSpace($backupDir)) {
  $backupDir = $defaultBackupDir
}

$backupFileName = "AutoBackup_$sourceDB.bak"
$backupPath = Join-Path $backupDir $backupFileName
$dacpacName = "$sourceDB.dacpac"
$dacpacPath = Join-Path $backupDir $dacpacName

Write-Host "Final backup path is: $backupPath"

if (-not $serverName) { $serverName = Get-ValidatedInput -PromptMessage "Enter the SQL Server Name (Source Database should reside here)" `
  -ErrorMessage "Server name cannot be empty. Please provide a valid server name."
}


if (-not $trustCert) {
  do {
      $trustCert = Read-Host "Do you need to trust the Server Certificate? (Y/N)"
      $trustCert = $trustCert.ToUpper()
  } until ($trustCert -match "^(Y|N)$")
}

if (-not $encryptConnection) {
  do {
      $encryptConnection = Read-Host "Do you need to encrypt the connection? (Y/N)"
      $encryptConnection = $encryptConnection.ToUpper()
  } until ($encryptConnection -match "^(Y|N)$")
}

# Determine SQL Connection Parameters
$sqlParams = "-SqlInstance `"$serverName`""
if ($trustCert -eq 'Y') { $sqlParams += " -TrustServerCertificate" }
if ($encryptConnection -eq 'Y') { $sqlParams += " -EncryptConnection" }
Invoke-Expression "Connect-DbaInstance $sqlParams"

# Start timer
$startTime = Get-Date

# Create DACPAC file if not passed in as a parameter
if ($dacpacFile) {
  Write-Host "Using provided DACPAC file: $dacpacFile"
  $dacpacPath = $dacpacFile
} else {
  Write-Host "Exporting database schema to DACPAC..."
  try{
      Export-DbaDacPackage -SqlInstance $ServerName -Database $sourceDB -FilePath $dacpacPath
      # Verify if the DACPAC file was created
      if (!(Test-Path -Path $dacpacPath)) {
        throw "DACPAC export failed: File was not created at $dacpacPath."
      }
      Write-Host "DACPAC export complete. Saved as $dacpacName."
   } catch {
      Write-Host "Error exporting DACPAC: $_" -ForegroundColor Red
      exit 1
    }
}


# Autopilot Database List
$databases = @("AutoPilotDev", "AutoPilotTest", "AutoPilotProd", "AutoPilotShadow", "AutoPilotBuild", "AutoPilotCheck")

# Check for existing databases
Write-Host "Checking if Autopilot databases already exist in target environment"
$existingDatabases = @()
foreach ($db in $databases) {
  if (Get-DbaDatabase -SqlInstance $serverName -Database $db -ErrorAction SilentlyContinue) {
      $existingDatabases += $db
  }
}

# Outline if any databases already exist
if ($existingDatabases.Count -gt 0) {
  Write-Host "The following databases already exist: $($existingDatabases -join ', ')" -ForegroundColor Yellow
  $overwrite = Read-Host "Do you want to overwrite them? (Y/N)" | ForEach-Object { $_.ToUpper() }
  if ($overwrite -ne 'Y') {
      Write-Host "Process aborted. No databases were overwritten." -ForegroundColor Red
      exit
  }
}

# Create AutoPilotDev/Test/Prod using DACPAC & Create AutoPilotBuild/Check/Shadow as an empty databases
foreach ($db in $databases) {
  Write-Host "Creating database: $db..."
  try {
      if ($db -in @("AutoPilotDev", "AutoPilotTest", "AutoPilotProd")) {
          # Deploy database from DACPAC
          Publish-DbaDacPackage -SqlInstance $serverName -Database $db -Path $dacpacPath
          Write-Host "$db deployed from DACPAC."
      } else {
          New-DbaDatabase -SqlInstance $serverName -Name $db
      }
    } catch {
        Write-Host "Error deploying database $db : $_" -ForegroundColor Red
        exit 1
    }
}

# Backup AutoPilotDev database to use as baseline
Write-Host "Backing up AutoPilotDev..."
try {
      Backup-DbaDatabase -SqlInstance $serverName -Database "AutoPilotDev" -FilePath $backupPath -Type Full -IgnoreFileChecks
      Write-Host "Schema Only Backup of AutoPilotDev created at $backupPath."
    } catch {
      Write-Host "Error creating backup: $_" -ForegroundColor Red
      exit 1
    }

# Calculate duration of above steps
$endTime = Get-Date
$duration = $endTime - $startTime
Write-Host "All AutoPilot databases created on '$serverName' in $($duration.Minutes) minutes and $($duration.Seconds) seconds."

# Update Flyway.toml with latest backup location
$tomlFilePath = Join-Path $projectDir "flyway.toml"
if (Test-Path -Path $tomlFilePath) {
  $tomlContent = Get-Content -Path $tomlFilePath -Raw
  $pattern = '(backupFilePath\s*=\s*)".*?"'
  $escapedBackupPath = $backupPath -replace '\\', '\\\\'
  $updatedTomlContent = $tomlContent -replace $pattern, "`$1`"$escapedBackupPath`""
  Set-Content -Path $tomlFilePath -Value $updatedTomlContent
  Write-Host "Updated Flyway.toml to reference $backupPath" -ForegroundColor Green
} else {
  Write-Host "Flyway.toml not found. Please update manually." -ForegroundColor Red
}

Write-Host "Autopilot for Flyway - Database Creation Complete" 
# Require key press to complete PowerShell terminal
Write-Host "Press any key to close this window..."
[System.Console]::ReadKey() | Out-Null