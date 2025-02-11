# AutoPilot Database Setup Process - DACPAC Method
# This script automates the setup of the Autopilot project databases as well as creating a schema only backup for use as a baseline
# The following steps outline the process, which can also be performed manually in SSMS:
#
# 1. Ensures the dbatools module is installed (Required by PowerShell)
# 2. SQL Server and Source Database details captured
# 3. Export the schema of the source database to a fixed DACPAC file.
# 4. Create databases AutoPilotDev, AutoPilotTest, and AutoPilotProd using the DACPAC.
# 5. Backup AutoPilotDev as a Schema Only Backup for use as a baseline in Flyway.
# 6. Update Flyway.toml to reference the new backup file location.

# Parameter List - These are optional input parameters
# Use Case - DACPAC file created manually already and can be passed to the script for use
# Example Command - .\AutomaticDatabaseCreation_Dacpac.ps1 -projectDir "C:\Git\Flyway-AutoPilot-BackUp" -serverName "Localhost" -sourceDB "MySourceDBName" -trustCert "Y" -encryptConnection "Y" -backupPath "C:\Git\Flyway-AutoPilot-BackUp\Backups" -dacpacPath "C:\Git\Flyway-AutoPilot-BackUp\AdventureWorks.dacpac"
param (
    [string]$projectDir,
    [string]$serverName,
    [string]$sourceDB,
    [ValidateSet("Y", "N")][string]$trustCert,
    [ValidateSet("Y", "N")][string]$encryptConnection,
    [string]$backupPath,
    [string]$dacpacPath
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
      [ValidateScript({$_ -ne ''})] # Ensure input is not empty
      [string]$ErrorMessage
  )

  do {
      # Set the prompt message color to yellow
      $oldColor = $Host.UI.RawUI.ForegroundColor
      $Host.UI.RawUI.ForegroundColor = [ConsoleColor]::Yellow

      # Prompt the user and capture the input
      $inputValue = Read-Host $PromptMessage

      # Restore original color
      $Host.UI.RawUI.ForegroundColor = $oldColor

      # If input is empty or whitespace, show the error message in red
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

if ($backupPath) {
  Write-Host "Detected Autopilot Parameter Backup Folder: $backupPath" -ForegroundColor Green
}
else {
    # Setup backup directory and paths
    $defaultBackupDir = Join-Path $projectDir "backups"

    # Ensure backup directory exists
    if (!(Test-Path -Path $defaultBackupDir)) {
      New-Item -Path $defaultBackupDir -ItemType Directory | Out-Null
    }
    Write-Host "Detected Autopilot Default Backup Folder: $defaultBackupDir" -ForegroundColor Green
}

if (-not $backupPath) {
  $backupPath = Read-Host "Do you want to use backup path above? Press Enter to confirm or provide a new backup folder path"
}

# Use detected path if user doesn't provide a new one
if ([string]::IsNullOrWhiteSpace($backupPath)) {
  $backupPath = $defaultBackupDir
}

$backupFileName = "AutoBackup_$sourceDB.bak"
$backupFilePath = Join-Path $backupPath $backupFileName

Write-Host "Final backup path is: $backupPath"

if (-not $serverName) { 
    $serverName = Get-ValidatedInput -PromptMessage "Enter the SQL Server Name (Source Database should reside here)" `
    -ErrorMessage "Server name cannot be empty. Please provide a valid server name."
}

# Check if the server name is "." and change it to "localhost"
if ($serverName -eq '.') {
    $serverName = 'localhost'
    Write-Host "SQL Server name set to 'localhost'."
}


if (-not $trustCert) {
  do {
      $trustCert = Get-ValidatedInput -PromptMessage "Do you need to trust the Server Certificate? (Y/N)" -ErrorMessage "Trust Server Certificate cannot be left blank, please try again."
      $trustCert = $trustCert.ToUpper()
  } until ($trustCert -match "^(Y|N)$")
}

if (-not $encryptConnection) {
  do {
      $encryptConnection = Get-ValidatedInput -PromptMessage "Do you need to encrypt the connection? (Y/N)" -ErrorMessage "Encrypt connection cannot be left blank, please try again."
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
if ($dacpacPath) {
  Write-Host "Using provided DACPAC file: $dacpacPath"
  $dacpacPath = $dacpacPath
  if (!(Test-Path -Path $dacpacPath)) {
    throw "DACPAC export failed: File was not accessible at $dacpacPath."
  }
} else {
  Write-Host "Exporting database schema to DACPAC..."
  $dacpacName = "$sourceDB.dacpac"
  $dacpacPath = Join-Path $backupPath $dacpacName
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
          Publish-DbaDacPackage -SqlInstance $serverName -Database $db -Path $dacpacPath -EnableException
          Write-Host "$db deployed from DACPAC."
      } else {
          New-DbaDatabase -SqlInstance $serverName -Name $db -EnableException
      }
    } catch {
        Write-Host "Error deploying database $db : $_" -ForegroundColor Red
        exit 1
    }
}

# Backup AutoPilotDev database to use as baseline
Write-Host "Backing up AutoPilotDev..."
try {
      Backup-DbaDatabase -SqlInstance $serverName -Database "AutoPilotDev" -FilePath $backupFilePath -Type Full -IgnoreFileChecks -EnableException
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
  # Read the TOML file content
  $tomlContent = Get-Content -Path $tomlFilePath -Raw

  # Regular expression pattern to find all occurrences of backupFilePath = "somepath"
  $pattern = '(backupFilePath\s*=\s*)".*?"'

  # Escape the new backup path for TOML format (only double slashes)
  $escapedBackupPath = $backupFilePath -replace '\\', '\\'

  # Replace all instances of backupFilePath with the new path
  $updatedTomlContent = $tomlContent -replace $pattern, "`$1`"$escapedBackupPath`""

  # Write back the modified content
  Set-Content -Path $tomlFilePath -Value $updatedTomlContent

  Write-Host "Updated flyway.toml: All 'backupFilePath' entries now point to $backupFilePath" -ForegroundColor Green
} else {
  Write-Host "Flyway.toml not found. Please update manually." -ForegroundColor Red
}

Write-Host "Autopilot for Flyway - Database Creation Complete" 
Write-Host "Press Enter to close this window..."
Read-Host | Out-Null
