# dbatools MODULE NEEDED
if (!(Get-Module -ListAvailable -Name dbatools)) {
    Write-Host "dbatools module not found. Installing module..."
    Install-Module -Name dbatools -Force -AllowClobber
    Write-Host "dbatools module installed successfully."
} else {
    Write-Host "dbatools module is already installed."
}

# Helper function for validating non-empty inputs
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
$sourceDB = Get-ValidatedInput -PromptMessage "Enter the Source Database Name to be Schema Backed Up (e.g., MyDatabaseName)" `
    -ErrorMessage "Database name cannot be empty. Please provide a valid database name."

# Detect AutoPilot root directory based on the script's current location
if ($PSScriptRoot) {
    $defaultProjectDir = Split-Path -Path $PSScriptRoot -Parent
    Write-Host "Detected AutoPilot Root Project path: $defaultProjectDir" -ForegroundColor Green
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

$backupDir = Join-Path $projectDir "backups"

$serverName = Get-ValidatedInput -PromptMessage "Enter the SQL Server Name (Source Database should reside here)" `
    -ErrorMessage "Server name cannot be empty. Please provide a valid server name."

$backupFileName = "AutoBackup_$sourceDB.bak"
$backupPath = Join-Path $backupDir $backupFileName

# Ensure the backup directory exists
if (!(Test-Path -Path $backupDir)) {
    New-Item -Path $backupDir -ItemType Directory | Out-Null
}

# Prompt for server certificate and encryption settings
do {
    $trustCert = Read-Host "Do you need to trust the Server Certificate? (Y/N)"
    $trustCert = $trustCert.ToUpper()
} until ($trustCert -match "^(Y|N)$")

do {
    $encryptConnection = Read-Host "Do you need to encrypt the connection? (Y/N)"
    $encryptConnection = $encryptConnection.ToUpper()
} until ($encryptConnection -match "^(Y|N)$")

# Generate the SQL Server connection based on user preferences
if ($trustCert -eq 'Y' -and $encryptConnection -eq 'Y') {
    $SqlConnection = Connect-DbaInstance -SqlInstance $serverName -TrustServerCertificate -EncryptConnection
} elseif ($trustCert -eq 'Y' -and $encryptConnection -eq 'N') {
    $SqlConnection = Connect-DbaInstance -SqlInstance $serverName -TrustServerCertificate
} elseif ($trustCert -eq 'N' -and $encryptConnection -eq 'Y') {
    $SqlConnection = Connect-DbaInstance -SqlInstance $serverName -EncryptConnection
} else {
    $SqlConnection = Connect-DbaInstance -SqlInstance $serverName
}

# Start timing the entire process
$processDuration = Measure-Command {

    # Step 1: Create the schema backup
    Write-Host "Creating a schema backup for $sourceDB..."
    $sqlCreateBackup = @"
    DECLARE @SourceDB NVARCHAR(128) = N'$sourceDB';
    DECLARE @BackupDB NVARCHAR(128) = @SourceDB + N'_Schema';
    DECLARE @BackupPath NVARCHAR(256) = N'$backupPath';

    DBCC CLONEDATABASE (@SourceDB, @BackupDB) WITH NO_STATISTICS, NO_QUERYSTORE, VERIFY_CLONEDB;

    DECLARE @BackupCommand NVARCHAR(MAX) = 
    N'BACKUP DATABASE [' + @BackupDB + N'] TO DISK = ''' + @BackupPath + N''' WITH INIT, FORMAT, MEDIANAME = ''SQLServerBackups'', NAME = ''Full Backup of ' + @BackupDB + N''';';

    EXEC sp_executesql @BackupCommand;

    -- Drop the temporary schema database
    IF DB_ID(@BackupDB) IS NOT NULL
        EXEC('DROP DATABASE ' + @BackupDB);
"@

    Invoke-DbaQuery -Query $sqlCreateBackup -SqlInstance $SqlConnection

    # Step 2: Retrieve logical file names from the source database
    Write-Host "Retrieving logical file names from $sourceDB..."
    $sqlFindPaths = @"
    USE $sourceDB;

    SELECT name AS LogicalFileName, type_desc
    FROM sys.database_files;
"@

    $paths = Invoke-DbaQuery -Query $sqlFindPaths -SqlInstance $SqlConnection
    $logicalDataFileName = $paths | Where-Object { $_.type_desc -eq 'ROWS' } | Select-Object -ExpandProperty LogicalFileName
    $logicalLogFileName = $paths | Where-Object { $_.type_desc -eq 'LOG' } | Select-Object -ExpandProperty LogicalFileName

    Write-Host "Logical Data File Name: $logicalDataFileName"
    Write-Host "Logical Log File Name: $logicalLogFileName"

    # Step 3: Restore the backup to multiple environments
    Write-Host "Creating AutoPilot databases using provided backup..."
    $sqlRestore = @"
    DECLARE @BackupFilePath NVARCHAR(128) = N'$backupPath'; 
    DECLARE @LogicalDataFileName NVARCHAR(128) = N'$logicalDataFileName'; 
    DECLARE @LogicalLogFileName NVARCHAR(128) = N'$logicalLogFileName'; 
    DECLARE @DataFilePath NVARCHAR(260);  
    DECLARE @LogFilePath NVARCHAR(260);  
    DECLARE @DatabaseName NVARCHAR(128);  

    DECLARE @mdfLocation NVARCHAR(256) = CAST(SERVERPROPERTY('InstanceDefaultDataPath') AS NVARCHAR(200));
    DECLARE @ldfLocation NVARCHAR(256) = CAST(SERVERPROPERTY('InstanceDefaultLogPath') AS NVARCHAR(200));

    DECLARE @mySQL NVARCHAR(MAX);

    DECLARE @DatabaseList TABLE (DatabaseName NVARCHAR(128)); 
    INSERT INTO @DatabaseList (DatabaseName)
    VALUES ('AutoPilotDev'), ('AutoPilotTest'), ('AutoPilotProd'), ('AutoPilotShadow'), ('AutoPilotBuild'), ('AutoPilotCheck');

    DECLARE @Counter INT = 1;
    DECLARE @TotalCount INT = (SELECT COUNT(*) FROM @DatabaseList);

    WHILE @Counter <= @TotalCount
    BEGIN
        SET @DatabaseName = (SELECT DatabaseName FROM (
            SELECT ROW_NUMBER() OVER (ORDER BY DatabaseName) AS RowNum, DatabaseName 
            FROM @DatabaseList
        ) AS TempDB
        WHERE TempDB.RowNum = @Counter);

        SET @DataFilePath = @mdfLocation + @DatabaseName + '_Data.mdf';
        SET @LogFilePath = @ldfLocation + @DatabaseName + '_Log.ldf';

        USE [master];

        IF EXISTS (SELECT name FROM sys.databases WHERE name = @DatabaseName)
        BEGIN
            BEGIN TRY
                SET @mySQL = N'ALTER DATABASE [' + @DatabaseName + '] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;';
                EXEC sp_executesql @mySQL;
                SET @mySQL = N'DROP DATABASE [' + @DatabaseName + '];';
                EXEC sp_executesql @mySQL;
            END TRY
            BEGIN CATCH
                PRINT 'Error occurred while altering or dropping the existing database ' + @DatabaseName;
                PRINT ERROR_MESSAGE();
                RETURN;
            END CATCH
        END

        BEGIN TRY
            SET @mySQL = N'RESTORE DATABASE [' + @DatabaseName + ']
            FROM DISK = ''' + @BackupFilePath + '''
            WITH REPLACE,
            MOVE ''' + @LogicalDataFileName + ''' TO ''' + @DataFilePath + ''',
            MOVE ''' + @LogicalLogFileName + ''' TO ''' + @LogFilePath + ''';';
            EXEC sp_executesql @mySQL;

            SET @mySQL = N'ALTER DATABASE [' + @DatabaseName + '] SET MULTI_USER;';
            EXEC sp_executesql @mySQL;
            SET @mySQL = N'ALTER DATABASE [' + @DatabaseName + '] SET READ_WRITE;';
            EXEC sp_executesql @mySQL;
        END TRY
        BEGIN CATCH
            PRINT 'Error occurred during the restore operation for database ' + @DatabaseName;
            PRINT ERROR_MESSAGE();
            RETURN;
        END CATCH

        SET @Counter = @Counter + 1;
    END
"@

    try {
        Invoke-DbaQuery -Query $sqlRestore -SqlInstance $SqlConnection
        Write-Host "Databases restored successfully and set to READ_WRITE mode."
    } catch {
        Write-Host "An error occurred during the restoration process: $($_.Exception.Message)" -ForegroundColor Red
        exit
    }
}

# Calculate minutes and seconds separately and round to appropriate values
$minutes = [math]::Floor($processDuration.TotalMinutes)
$seconds = $processDuration.Seconds

# Display process completion summary
Write-Host "All AutoPilot databases have been successfully created in the environment named '$serverName'." -ForegroundColor Green
Write-Host "The overall process took $minutes minutes and $seconds seconds."

Write-Host "Updating Flyway.toml project file to reference new backup file location ($backupPath)" -ForegroundColor Yellow
# Path to Flyway TOML file
$tomlFilePath = Join-Path $defaultProjectDir "flyway.toml"

# Ensure the file exists before attempting to modify it
if (Test-Path -Path $tomlFilePath) {
    # Read the TOML file content
    $tomlContent = Get-Content -Path $tomlFilePath -Raw

    # Regular expression pattern to find all occurrences of backupFilePath = "somepath"
    $pattern = '(backupFilePath\s*=\s*)".*?"'

    # Escape the new backup path for TOML format (only double slashes)
    $escapedBackupPath = $backupPath -replace '\\', '\\'

    # Replace all instances of backupFilePath with the new path
    $updatedTomlContent = $tomlContent -replace $pattern, "`$1`"$escapedBackupPath`""

    # Write back the modified content
    Set-Content -Path $tomlFilePath -Value $updatedTomlContent

    Write-Host "Updated flyway.toml: All 'backupFilePath' entries now point to $backupPath" -ForegroundColor Green
} else {
    Write-Host "flyway.toml file not found at: $tomlFilePath" -ForegroundColor Red
    Write-Host "Tip - Either update the flyway.toml file manually or edit environments Shadow/Check/Build in Flyway Desktop to point to the new backup location"
    Write-Host "New backup location - $backupPath"
}

Write-Host "Autopilot for Flyway - Database Creation Complete" 
# Await user key press before closing the window
Write-Host "Press any key to close this window..."
[System.Console]::ReadKey() | Out-Null