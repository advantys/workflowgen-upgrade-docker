<#
.SYNOPSIS
    Entrypoint script for the upgrade container.
.DESCRIPTION
    This script will merge files for the App_Data and wfapps directory between
    the upgrade package of the destination version and the current installation
    ones (passed as volumes).

    It will also launch the required SQL migration scripts in order from lowest
    to highest version. Make sure to use a SQL account that has the proper rights
    to modify the database tables.

    The "Files", "LogFiles" and "Ws" subfolders in App_Data are always ignored.
    You don't have to specify them in the exclusion environment variables.
.PARAMETER FromVersion
    The current version of WorkflowGen. The starting version of the migration.
.PARAMETER ToVersion
    The version to which you want to migrate the current one.
.PARAMETER Command
    Indicates to execute a command inside the container. This is used in conjunction with RemainingArgs
.PARAMETER RemainingArgs
    Commands to execute inside the container. If versions are not passed, it is
    executed at the beginning and then it exits after the execution. If versions
    are passed, it is executed at the end of the script.
.PARAMETER Help
    Get full help for this script.
.PARAMETER Offline
    If provided, the script will not try to download the update package. This
    means that you have to provide the update package from a volume.
.EXAMPLE
    docker container run -i "..." advantys/workflowgen-upgrade:latest-ubuntu-18.04 -Help

    Displays the full help for the container.
.EXAMPLE
    docker container run -i "..." advantys/workflowgen-upgrade:latest-ubuntu-18.04 -Command dir /mnt/data

    This executes an arbitrary command inside the container. It can be useful for debugging
    network issues or other problems prior to the migration.
.EXAMPLE
    docker container run -i "..." advantys/workflowgen-upgrade:latest-ubuntu-18.04 -FromVersion 7.14.10 -ToVersion 7.18.3

    This will launch the migration process to upgrade WorkflowGen from version 7.14.10
    to the 7.18.3 version.
.EXAMPLE
    docker container run -i "..." advantys/workflowgen-upgrade:latest-ubuntu-18.04 -FromVersion 7.14.10 -ToVersion 7.18.2 dir /mnt/data

    This will launch the migration process to upgrade WorkflowGen from version 7.14.10
    to the 7.18.3 version. In addition, it will execute an arbitrary command at the
    end of the migration process.
.NOTES
    File name: docker-entrypoint.ps1
#>
#requires -Version 7.0
using namespace System
using namespace System.Data.SqlClient
using namespace System.Text
using namespace System.Text.RegularExpressions
using namespace System.Transactions

[CmdletBinding(DefaultParameterSetName="VersionUpgrade")]
param(
    [Parameter(Mandatory=$true, ParameterSetName="VersionUpgrade")]
    [ValidateNotNullOrEmpty()]
    [ValidatePattern("\d+\.\d+\.\d+")]
    [Alias("From")]
    [string]$FromVersion,
    [Parameter(Mandatory=$true, ParameterSetName="VersionUpgrade")]
    [ValidateNotNullOrEmpty()]
    [ValidatePattern("\d+\.\d+\.\d+")]
    [Alias("To")]
    [string]$ToVersion,
    [Parameter(Mandatory=$true, ParameterSetName="Exec")]
    [switch]$Command,
    [Parameter(Mandatory=$true, ValueFromRemainingArguments=$true, ParameterSetName="Exec")]
    [Parameter(ValueFromRemainingArguments=$true, ParameterSetName="VersionUpgrade")]
    $RemainingArgs,
    [Parameter(Mandatory=$true, ParameterSetName="Help")]
    [Alias("h")]
    [switch]$Help,
    [Parameter(ParameterSetName="VersionUpgrade")]
    [switch]$Offline
)

if ($Command) {
    Invoke-Expression ($RemainingArgs.ToArray() -join " ")
    exit $LASTEXITCODE
} elseif ($PSCmdlet.ParameterSetName -eq "Help") {
    Get-Help (Join-Path $PSScriptRoot $MyInvocation.MyCommand.Name) -Full
    exit 0
}

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

Import-Module $($IsLinux ? "/usr/local/lib/Utils.psm1" : "C:\Utils.psm1") `
    -Function "Write-Error", "Get-EnvVar", "Test-Error" `
    -Prefix WFG

function Split-SqlStatements {
    <#
    .SYNOPSIS
        Splits a script between "GO" instructions.
    .DESCRIPTION
        "GO" is not usable with ADO.NET. Therefore, the statements between the
        "GO" instructions must be executed separately.
    .LINK
        https://stackoverflow.com/questions/18596876/go-statements-blowing-up-sql-execution-in-net
    #>
    param(
        [Parameter(Mandatory=$true, ValueFromPipeline=$true, Position=0)]
        [ValidateNotNullOrEmpty()]
        [string]$Content
    )

    $statements = [regex]::Split(
        $Content,
        "^[\t\r\n]*GO[\t\r\n]*\d*[\t\r\n]*(?:--.*)?$",
        (
            [RegexOptions]::Multiline -bor
            [RegexOptions]::IgnorePatternWhitespace -bor
            [RegexOptions]::IgnoreCase
        )
    )

    return $statements `
        | Where-Object { -not ([string]::IsNullOrWhiteSpace($_)) } `
        | ForEach-Object { $_.Trim(" ", "`n", "`r", "`t") }
}

$dataPath = Get-WFGEnvVar "WFGEN_DATA_PATH" -DefaultValue $(
    $IsLinux ? (Join-Path "/" "mnt" "data") : (Join-Path "C:\" "wfgen" "data")
)
$appDataPath = Join-Path $dataPath "appdata"
$wfappsPath = Join-Path $dataPath "wfapps"
$updateVolumePath = Get-WFGEnvVar "WFGEN_UPGRADE_UPDATE_PACKAGES_PATH" -DefaultValue $(
    $IsLinux ? (Join-Path "/" "mnt" "updatepackages") : (Join-Path "C:\" "wfgen" "updatepackages")
)
$updatePackageFileName = Get-WFGEnvVar "WFGEN_UPGRADE_UPDATE_PACKAGE_FILE_NAME"
$connectionString = Get-WFGEnvVar "WFGEN_DATABASE_CONNECTION_STRING" -TryFile
$commonExcludedFiles = (Get-WFGEnvVar "WFGEN_UPGRADE_EXCLUDE_FILES" -DefaultValue "") -split "," | Where-Object { $_ }
$commonExcludedFolders = (Get-WFGEnvVar "WFGEN_UPGRADE_EXCLUDE_FOLDERS" -DefaultValue "") -split "," | Where-Object { $_ }
$excludedAppDataFiles = (Get-WFGEnvVar "WFGEN_UPGRADE_APPDATA_EXCLUDE_FILES" -DefaultValue "") -split "," | Where-Object { $_ }
$excludedWfappsFiles = (Get-WFGEnvVar "WFGEN_UPGRADE_WFAPPS_EXCLUDE_FILES" -DefaultValue "") -split "," | Where-Object { $_ }
$excludedAppDataFolders = (Get-WFGEnvVar "WFGEN_UPGRADE_APPDATA_EXCLUDE_FOLDERS" -DefaultValue "") -split "," | Where-Object { $_ }
$excludedWfappsFolders = (Get-WFGEnvVar "WFGEN_UPGRADE_WFAPPS_EXCLUDE_FOLDERS" -DefaultValue "") -split "," | Where-Object { $_ }
$migrationScriptsPath = $IsLinux `
    ? (Join-Path "/" "usr" "local" "wfgen" "migrations")
    : (Join-Path "C:\" "wfgen" "migrations")
$fv, $tv = $FromVersion, $ToVersion | ForEach-Object { [version]::new($_) }

Write-Debug "Common files to exclude: $commonExcludedFiles ; Count: $($commonExcludedFiles.Count)"
Write-Debug "Common folders to exclude: $commonExcludedFolders ; Count: $($commonExcludedFolders.Count)"
Write-Debug "App_Data files to exclude: $excludedAppDataFiles ; Count: $($excludedAppDataFiles.Count)"
Write-Debug "Wfapps files to exclude: $excludedWfappsFiles ; Count: $($excludedWfappsFiles.Count)"
Write-Debug "App_Data folders to exclude: $excludedAppDataFolders ; Count: $($excludedAppDataFolders.Count)"
Write-Debug "Wfapps folders to exclude: $excludedWfappsFolders ; Count: $($excludedWfappsFolders.Count)"

if ($fv -ge $tv -or $fv -lt ([version]::new("7.14.0"))) {
    Write-WFGError "FromVersion is greater or equal to ToVersion value or FromVersion is not supported. Cannot upgrade."
    exit 1
}

$updateScriptVersionRegex = [regex]"(?<=Update_WFG-V)\d+-\d+-\d+(?=\.sql)"
$tmpDir = Join-Path ($IsLinux ? "/tmp" : $env:TEMP) "wfgen"
$volumeUpdatePackagePath = $updatePackageFileName `
    ? (Join-Path $updateVolumePath $updatePackageFileName)
    : (Join-Path $updateVolumePath $ToVersion "update.zip")
$updatePackage = Join-Path $tmpDir "$ToVersion.zip"
$extractedPackage = Join-Path $tmpDir $ToVersion
$updateAppDataPath = Join-Path $extractedPackage "Inetpub" "wwwroot" "wfgen" "App_Data"
$updateWfappsPath = Join-Path $extractedPackage "Inetpub" "wwwroot" "wfgen" "wfapps"
$sqlScriptsPath = Join-Path $extractedPackage "Databases" "MsSQLServer"
$doneMessageCommon = @{
    ForegroundColor = [ConsoleColor]::Green
}
$getScriptsForCurrentVersion = {
    param(
        [Parameter(Mandatory=$true, ValueFromPipeline=$true, Position=0)]
        [string]$Path
    )

    $path `
        | Get-ChildItem `
        | Where-Object {
            $version = [version]::new($_.BaseName)

            return $fv -lt $version -and $version -le $ToVersion
        } `
        | Sort-Object { [version]::new($_.BaseName) }
}
$preMergeFilesScripts = Join-Path $migrationScriptsPath "pre-file-merge" "*.ps1" `
    | & $getScriptsForCurrentVersion
$preDatabaseScripts = Join-Path $migrationScriptsPath "pre-db-scripts" "*.ps1" `
    | & $getScriptsForCurrentVersion
$postDatabaseScripts = Join-Path $migrationScriptsPath "post-db-scripts" "*.ps1" `
    | & $getScriptsForCurrentVersion
$mergeFolders = { param([string]$Source, [string]$Destination, [string[]]$ExcludeFiles, [string[]]$ExcludeFolders)
    if ($IsLinux) {
        $Source = Join-Path $Source "*"
        $arguments = ,"--recursive"
        $arguments += $VerbosePreference -eq "Continue" `
            ? "--verbose" : "--quiet"

        ($ExcludeFiles + $ExcludeFolders) `
            | Where-Object { $_ } `
            | ForEach-Object { $arguments += "--exclude=""$_""" }
        Write-Debug "rsync $arguments $Source $Destination"
        bash -c "rsync $arguments $Source $Destination"
        Test-WFGError -ErrorMessage "There has been an error while merge App_Data files."
    } else {
        $arguments = "/XX", "/XO", "/E"
        $arguments += $VerbosePreference -ne "Continue" `
            ? "/NP", "/NS", "/NC", "/NFL", "/NDL", "/NJH", "/NJS"
            : "/V"

        if ($ExcludeFiles.Count -gt 0) {
            $arguments += ,"/XF" + $ExcludeFiles
        }

        if ($ExcludeFolders.Count -gt 0) {
            $arguments += ,"/XD" + $ExcludeFolders
        }

        Write-Debug (
            "robocopy $Source $Destination $arguments " +
            ($VerbosePreference -eq "Continue" ? "" : '1>$null')
        )
        robocopy $Source $Destination $arguments ($VerbosePreference -eq "Continue" ? "" : '1>$null')
        Write-Debug "Last exit code: $LASTEXITCODE"
        Test-WFGError `
            -ErrorMessage "There has been an error while merge App_Data files." `
            -AdditionalSuccessCodes @(1, 2, 3, 4, 5, 6, 7)
    }
}

class MergeFilesEnlistment : IEnlistmentNotification {
    hidden [string]$BackupFolder = $IsLinux `
        ? (Join-Path "/" "tmp" ([guid]::NewGuid().ToString()))
        : (Join-Path $env:TEMP ([guid]::NewGuid().ToString()))
    hidden [string]$FilesPath
    hidden [scriptblock]$Action

    MergeFilesEnlistment([scriptblock]$Action, [string]$FilesPath) {
        $this.FilesPath = $FilesPath
        $currentTran = [Transaction]::Current

        ${currentTran}?.EnlistVolatile($this, [EnlistmentOptions]::None)
        $this.Backup()
        $Action.Invoke()
    }

    hidden [void] Backup() {
        if (-not (Test-Path $this.BackupFolder)) {
            New-Item $this.BackupFolder -ItemType Directory | Out-Null
        }

        Write-Debug "Backing up $($this.FilesPath) to $($this.BackupFolder)"
        Write-Debug (
            Get-ChildItem $this.FilesPath -Exclude "Files", "LogFiles", "Ws" `
                | Format-List | Out-String
        )
        Get-ChildItem $this.FilesPath -Exclude "Files", "LogFiles", "Ws" `
            | Copy-Item -Destination $this.BackupFolder -Recurse -ErrorAction Stop
    }

    [void] Rollback([Enlistment]$Enlistment) {
        Get-ChildItem $this.FilesPath -Exclude "Files", "LogFiles", "Ws" `
            | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

        Write-Debug "Rolling back $($this.FilesPath) from $($this.BackupFolder)"
        Write-Debug (Get-ChildItem $this.BackupFolder | Format-List | Out-String)
        Get-ChildItem $this.BackupFolder | Copy-Item -Destination $this.FilesPath
        $Enlistment.Done()
    }

    [void] Prepare([PreparingEnlistment]$PreparingEnlistment) {
        $PreparingEnlistment.Prepared()
    }

    [void] Commit([Enlistment]$Enlistment) {
        $Enlistment.Done()
    }

    [void] InDoubt([Enlistment]$Enlistment) {
        $Enlistment.Done()
    }
}

if (-not (Test-Path $tmpDir)) {
    New-Item $tmpDir -ItemType Directory -Force | Out-Null
}

if (Test-Path $volumeUpdatePackagePath) {
    Write-Host "Copying update package ""$volumeUpdatePackagePath"" ... " -NoNewline
    Copy-Item $volumeUpdatePackagePath $updatePackage -Force | Out-Null
    Write-Host "done" @doneMessageCommon
} elseif (-not $Offline) {
    Write-Host "Downloading update package for version $ToVersion ... " -NoNewline
    Invoke-WebRequest `
        -Uri "https://github.com/advantys/workflowgen-releases/releases/download/$ToVersion/update.zip" `
        -OutFile $updatePackage `
        | Out-Null
    Write-Host "done" @doneMessageCommon
} else {
    Write-WFGError "Could not find the update package at path ""$volumeUpdatePackagePath""."
    exit 1
}

Write-Host "Extracting the update package ... " -NoNewline

if ($IsLinux) {
    unzip -qqO CP437 -d $extractedPackage $updatePackage
} else {
    if (-not (Test-Path $extractedPackage)) {
        New-Item $extractedPackage -ItemType Directory -Force | Out-Null
    }

    tar -xf $updatePackage -C $extractedPackage ($VerbosePreference -eq "Continue" ? "-v" : "")
}

Write-Host "done" @doneMessageCommon

try {
    $tran = [TransactionScope]::new()

    Write-Debug "Pre file merge scripts: $preMergeFilesScripts ; Count: $($preMergeFilesScripts.Count)"

    if ($preMergeFilesScripts.Count -gt 0) {
        $preMergeFilesScripts | ForEach-Object {
            Write-Host "Executing pre file merge script ""$($_.Name)"" ... " -NoNewline
            . $_
            Write-Host "done" @doneMessageCommon
        }
    }

    [MergeFilesEnlistment]::new({
        Write-Host "Merging files in App_Data folder ... " -NoNewline
        & $mergeFolders $updateAppDataPath $appDataPath `
            -ExcludeFiles ($commonExcludedFiles + $excludedAppDataFiles) `
            -ExcludeFolders ($commonExcludedFolders + $excludedAppDataFolders + @(
                "Files", "LogFiles", "Ws" # Mandatory exclusions to avoid loss of data
            ))
        Write-Host "done" @doneMessageCommon
    }, $appDataPath) | Out-Null
    [MergeFilesEnlistment]::new({
        Write-Host "Merging files and libraries in wfapps folder ... " -NoNewline
        & $mergeFolders $updateWfappsPath $wfappsPath `
            -ExcludeFiles ($commonExcludedFiles + $excludedWfappsFiles) `
            -ExcludeFolders ($commonExcludedFolders + $excludedWfappsFolders)
        Write-Host "done" @doneMessageCommon
    }, $wfappsPath) | Out-Null
    Write-Debug "Pre database scripts: $preDatabaseScripts ; Count: $($preDatabaseScripts.Count)"

    if ($preDatabaseScripts.Count -gt 0) {
        $preDatabaseScripts | ForEach-Object {
            Write-Host "Executing pre database script ""$($_.Name)"" ... " -NoNewline
            . $_
            Write-Host "done" @doneMessageCommon
        }
    }

    Write-Host "Beginning of SQL transaction"
    Write-Debug "Connection string exists: $([bool]$connectionString)"

    $conn = [SqlConnection]::new($connectionString)

    Write-Debug "Before opening SQL connection"

    $conn.Open()

    Write-Debug "After opening SQL connection"
    Write-Debug "Before creating SQL command"

    $sqlCommand = $conn.CreateCommand()

    Join-Path $sqlScriptsPath "*.sql" `
        | Get-ChildItem `
        | Where-Object {
            if ($_.Name -notmatch $updateScriptVersionRegex) {
                return $false
            }

            $version = [version]::new(($Matches.0 -replace "-", "."))
            # FromVersion < version <= ToVersion
            return $fv -lt $version -and $version -le $tv
        } `
        | Sort-Object { [version]::new(($updateScriptVersionRegex.Match($_.Name).Value -replace "-", ".")) } `
        | ForEach-Object {
            Write-Host "Executing SQL migration script ""$($_.Name)"" ... " -NoNewline
            Get-Content $_ -Raw -Encoding ([Encoding]::UTF8) `
                | Split-SqlStatements `
                | ForEach-Object {
                    $sqlCommand.CommandText = $_
                    $sqlCommand.ExecuteNonQuery() | Out-Null
                }
            Write-Host "done" @doneMessageCommon
        }

    Write-Debug "Post database scripts: $postDatabaseScripts ; Count: $($postDatabaseScripts.Count)"

    if ($postDatabaseScripts.Count -gt 0) {
        $postDatabaseScripts | ForEach-Object {
            Write-Host "Executing post database script ""$($_.Name)"" ... " -NoNewline
            . $_
            Write-Host "done" @doneMessageCommon
        }
    }

    $tran.Complete()
} catch {
    Write-Host "An error occured during the transaction process: $($Error[0].Exception.Message)"
    exit 1
} finally {
    ${conn}?.Dispose()
    $tran.Dispose()
}

Write-Host "WorkflowGen data migration completed"

if (${RemainingArgs}?.Count -gt 0) {
    Invoke-Expression ($RemainingArgs.ToArray() -join " ")
    exit $LASTEXITCODE
}
