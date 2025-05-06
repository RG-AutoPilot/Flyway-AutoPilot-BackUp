----------------------------------------------------- Changes Required In This Section --------------------------------------------------------
DECLARE @BackupFilePath NVARCHAR(128) = 'C:\git\AutoPilot\backups\AutoBackup_Customer.bak';  -- Step 1. Change me to the backup location!
DECLARE @LogicalDataFiles TABLE ( [RowNo] INT IDENTITY(1,1), [LogicalName] nvarchar(128) NOT NULL)
DECLARE @LogicalLogFiles TABLE ( [RowNo] INT IDENTITY(1,1), [LogicalName] nvarchar(128)  NOT NULL)

-- Step 2a. Make these match the original DB! Psst, you can use 2.FindLogicalPaths.sql
INSERT INTO @LogicalDataFiles ([LogicalName])
VALUES
('AdventureWorks2016_Data')

-- Step 2b. Make these match the original DB! Psst, you can use 2.FindLogicalPaths.sql
INSERT INTO @LogicalLogFiles ([LogicalName])
VALUES
('AdventureWorks2016_Log')

----------------------------------------------------- DON'T CHANGE BELOW THIS LINE --------------------------------------------------------

DECLARE @DatabaseName NVARCHAR(128);  -- Declare a variable to hold the current database name
DECLARE @Msg NVARCHAR(MAX);

-- Attempts to Auto Find the Paths to the logical files!
DECLARE @mdfLocation NVARCHAR(256) = CAST(SERVERPROPERTY('InstanceDefaultDataPath') AS NVARCHAR(200));  -- Get the default data file path
DECLARE @ldfLocation NVARCHAR(256) = CAST(SERVERPROPERTY('InstanceDefaultLogPath') AS NVARCHAR(200));  -- Get the default log file path

DECLARE @mySQL NVARCHAR(MAX);  -- Declare a variable to hold SQL commands

DECLARE @DatabaseList TABLE (  -- Create a table variable to hold the list of databases
    DatabaseName NVARCHAR(128)  NOT NULL
);

-- Insert the database names into the table variable
INSERT INTO @DatabaseList (DatabaseName)
VALUES ('AutoPilotDev'), ('AutoPilotTest'), ('AutoPilotProd'), ('AutoPilotShadow'), ('AutoPilotBuild'), ('AutoPilotCheck');

DECLARE @Counter INT = 1;  -- Initialize a counter for the loop
DECLARE @TotalCount INT = (SELECT COUNT(*) FROM @DatabaseList);  -- Get the total count of databases

-- Loop through each database in the list
WHILE @Counter <= @TotalCount
BEGIN
    DECLARE @DataFileMovesSQL NVARCHAR(MAX) = ''
    DECLARE @LogFileMovesSQL NVARCHAR(MAX) = ''

    -- Get the current database name based on the counter
    SET @DatabaseName = (SELECT DatabaseName FROM (
        SELECT ROW_NUMBER() OVER (ORDER BY DatabaseName) AS RowNum, DatabaseName 
        FROM @DatabaseList
    ) AS TempDB
    WHERE TempDB.RowNum = @Counter);


    -- Use master database
    USE [master];

    -- Check if the database already exists, and if it does, drop it
    IF EXISTS (SELECT name FROM sys.databases WHERE name = @DatabaseName)
    BEGIN
        -- Try to set the database to single-user mode and drop it
        BEGIN TRY
            SET @mySQL = 'ALTER DATABASE [' + @DatabaseName + '] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;';
            RAISERROR (@mySQL, 10, 1) WITH NOWAIT
            EXEC sp_executesql @stmt = @mySQL;
            SET @mySQL = 'DROP DATABASE [' + @DatabaseName + '];';
            RAISERROR (@mySQL, 10, 1) WITH NOWAIT
            EXEC sp_executesql @stmt = @mySQL;
            RAISERROR ('', 10, 1) WITH NOWAIT
        END TRY
        BEGIN CATCH
            PRINT 'Error occurred while altering or dropping the existing database ' + @DatabaseName;
            PRINT ERROR_MESSAGE();
            RETURN;
        END CATCH
    END

    -- Restore the database from the backup with unique logical file names
    BEGIN TRY
        SELECT @DataFileMovesSQL = @DataFileMovesSQL + 'MOVE ''' + LogicalName + ''' TO ''' + @mdfLocation + @DatabaseName +  RIGHT('00' + CAST(RowNo AS VARCHAR(10)), 2) + '.mdf'','  + CHAR(13) + CHAR(10) + CHAR(9) FROM @LogicalDataFiles
        SELECT @LogFileMovesSQL = @LogFileMovesSQL + 'MOVE ''' + LogicalName + ''' TO ''' + @ldfLocation + @DatabaseName + RIGHT('00' + CAST(RowNo AS VARCHAR(10)), 2) + '.ldf'','  + CHAR(13) + CHAR(10) + CHAR(9) FROM @LogicalLogFiles
       

        SET @mySQL = N'RESTORE DATABASE [' + @DatabaseName + ']' + CHAR(13) + CHAR(10) + 
        'FROM DISK = ''' + @BackupFilePath + '''' + CHAR(13) + CHAR(10) +
        'WITH REPLACE,'  + CHAR(13) + CHAR(10) + CHAR(9) +
        @DataFileMovesSQL  + 
        @LogFileMovesSQL
        SET @mySQL = LEFT(@mySQL, LEN(@mySQL) -4)
        SET @Msg = 'RESTORING DATABASE: ' + @DatabaseName

        RAISERROR (@Msg, 10, 1) WITH NOWAIT
        EXEC sp_executesql @stmt = @mySQL;

        RAISERROR ('', 10, 1) WITH NOWAIT
        -- Put the database back in multi-user mode and set it to READ_WRITE
        SET @mySQL = 'ALTER DATABASE [' + @DatabaseName + '] SET MULTI_USER;';
        RAISERROR (@mySQL, 10, 1) WITH NOWAIT
        EXEC sp_executesql @stmt = @mySQL;
        SET @mySQL = 'ALTER DATABASE [' + @DatabaseName + '] SET READ_WRITE;';
        RAISERROR (@mySQL, 10, 1) WITH NOWAIT
        EXEC sp_executesql @stmt = @mySQL;
        RAISERROR ('', 10, 1) WITH NOWAIT

    END TRY
    BEGIN CATCH
        PRINT 'Error occurred during the restore operation for database ' + @DatabaseName;
        PRINT ERROR_MESSAGE();
        RETURN;
    END CATCH

    SET @Counter = @Counter + 1;  -- Increment the counter
END
