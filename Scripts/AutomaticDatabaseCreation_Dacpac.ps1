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
$sourceDB = Get-ValidatedInput -PromptMessage "Enter the Source Database Name to be Schema Backed Up (e.g., MyDatabaseName)" `
  -ErrorMessage "Database name cannot be empty. Please provide a valid database name."

# Detect AutoPilot root directory based on the script's current location
if ($PSScriptRoot) {
  $defaultProjectDir = Split-Path -Path $PSScriptRoot -Parent
  Write-Host "Detected Autopilot Root Project path: $defaultProjectDir" -ForegroundColor Green
} else {
  Write-Host "Script root path could not be detected. Please provide the AutoPilot Root Project path."
  $defaultProjectDir = $null
}

$projectDir = Read-Host "Do you want to use this path? Press Enter to confirm or provide a new path"

# Use detected path if user doesn't provide a new one
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

Write-Host "Detected Autopilot Default Backup Folder: $defaultBackupDir"

$backupDir = Read-Host "Do you want to use this path? Press Enter to confirm or provide a new backup folder path"

# Use detected path if user doesn't provide a new one
if ([string]::IsNullOrWhiteSpace($backupDir)) {
  $backupDir = $defaultBackupDir
}

$backupFileName = "AutoBackup_$sourceDB.bak"
$backupPath = Join-Path $backupDir $backupFileName
$dacpacName = "$sourceDB.dacpac"
$dacpacPath = Join-Path $backupDir $dacpacName

$serverName = Get-ValidatedInput -PromptMessage "Enter the SQL Server Name (Source Database should reside here)" `
  -ErrorMessage "Server name cannot be empty. Please provide a valid server name."

# Prompt for server certificate and encryption settings
do {
  $trustCert = Read-Host "Do you need to trust the Server Certificate? (Y/N)"
  $trustCert = $trustCert.ToUpper()
} until ($trustCert -match "^(Y|N)$")

do {
  $encryptConnection = Read-Host "Do you need to encrypt the connection? (Y/N)"
  $encryptConnection = $encryptConnection.ToUpper()
} until ($encryptConnection -match "^(Y|N)$")

# Determine SQL Connection Parameters
$sqlParams = "-SqlInstance `"$serverName`""
if ($trustCert -eq 'Y') { $sqlParams += " -TrustServerCertificate" }
if ($encryptConnection -eq 'Y') { $sqlParams += " -EncryptConnection" }
$SqlConnection = Invoke-Expression "Connect-DbaInstance $sqlParams"

# Start timer
$startTime = Get-Date

# Export schema to DACPAC
Write-Host "Exporting database schema to DACPAC..."
Export-DbaDacPackage -SqlInstance $serverName -Database $sourceDB -FilePath $dacpacPath
Write-Host "DACPAC export complete. Saved as $dacpacName."

# Retrieve logical file names from the source database
Write-Host "Retrieving logical file names from source database..."
$sqlFileList = "SELECT name, type_desc FROM sys.master_files WHERE database_id = DB_ID('$sourceDB')"
$fileList = Invoke-DbaQuery -SqlInstance $serverName -Query $sqlFileList

$logicalDataFileName = $fileList | Where-Object { $_.type_desc -eq 'ROWS' } | Select-Object -ExpandProperty name
$logicalLogFileName = $fileList | Where-Object { $_.type_desc -eq 'LOG' } | Select-Object -ExpandProperty name

Write-Host "Logical Data File Name: $logicalDataFileName"
Write-Host "Logical Log File Name: $logicalLogFileName"

# Retrieve default database file locations
$sqlPaths = "SELECT CAST(SERVERPROPERTY('InstanceDefaultDataPath') AS NVARCHAR(200)) AS DataPath, CAST(SERVERPROPERTY('InstanceDefaultLogPath') AS NVARCHAR(200)) AS LogPath"
$defaultPaths = Invoke-DbaQuery -SqlInstance $serverName -Query $sqlPaths
$dataPath = $defaultPaths.DataPath
$logPath = $defaultPaths.LogPath

# Deploy AutoPilot databases
$databases = @("AutoPilotDev", "AutoPilotTest", "AutoPilotProd", "AutoPilotShadow", "AutoPilotBuild", "AutoPilotCheck")

# Check for existing databases
$existingDatabases = @()
foreach ($db in $databases) {
  if (Get-DbaDatabase -SqlInstance $serverName -Database $db -ErrorAction SilentlyContinue) {
      $existingDatabases += $db
  }
}

if ($existingDatabases.Count -gt 0) {
  Write-Host "The following databases already exist: $($existingDatabases -join ', ')" -ForegroundColor Yellow
  $overwrite = Read-Host "Do you want to overwrite them? (Y/N)" | ForEach-Object { $_.ToUpper() }
  if ($overwrite -ne 'Y') {
      Write-Host "Process aborted. No databases were overwritten." -ForegroundColor Red
      exit
  }
}

foreach ($db in $databases) {
  Write-Host "Creating database: $db..."
  if ($db -in @("AutoPilotDev", "AutoPilotTest", "AutoPilotProd")) {
      # Deploy database from DACPAC
      Publish-DbaDacPackage -SqlInstance $serverName -Database $db -Path $dacpacPath
      Write-Host "$db deployed from DACPAC."
  } else {
      New-DbaDatabase -SqlInstance $serverName -Name $db
  }
}

# Backup AutoPilotDev for future use
Write-Host "Backing up AutoPilotDev..."
Backup-DbaDatabase -SqlInstance $serverName -Database "AutoPilotDev" -Path $backupPath -Type Full -CompressBackup
Write-Host "Schema Only Backup of AutoPilotDev created at $backupPath."

# Calculate duration
$endTime = Get-Date
$duration = $endTime - $startTime
Write-Host "All AutoPilot databases created on '$serverName' in $($duration.Minutes) minutes and $($duration.Seconds) seconds."

# Update Flyway.toml
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
# Await user key press before closing the window
Write-Host "Press any key to close this window..."
[System.Console]::ReadKey() | Out-Null