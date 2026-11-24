# Sourced by guest.ps1. Checkpoints match one website, database and exact build.
function Assert-StorageProfile($Profile) {
    Assert-Profile $Profile
    if ($Profile.protected) { throw 'Only named, unprotected instances can use storage operations.' }
}

function Assert-CheckpointName([string]$Name) {
    if ($Name -cnotmatch '^[a-z0-9][a-z0-9-]{0,39}$') {
        throw 'Checkpoint name must be a lowercase slug of at most 40 characters.'
    }
}

function Quote-Sql([string]$Value) { return "N'" + $Value.Replace("'", "''") + "'" }
function Quote-Ident([string]$Value) { return '[' + $Value.Replace(']', ']]') + ']' }

function New-PrivateDirectory([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        [void][IO.Directory]::CreateDirectory($Path)
    }
    Invoke-Native "$env:windir\System32\icacls.exe" @($Path, '/inheritance:r', '/grant:r', 'SYSTEM:(OI)(CI)F', 'Administrators:(OI)(CI)F')
}

function Set-PoolDirectoryAcl([string]$Path, [string]$Pool, [switch]$ResetChildren) {
    [void][IO.Directory]::CreateDirectory($Path)
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($name in @('SYSTEM', 'Administrators', "IIS AppPool\$Pool")) {
        $rights = if ($name -eq "IIS AppPool\$Pool") { 'Modify' } else { 'FullControl' }
        $rule = New-Object Security.AccessControl.FileSystemAccessRule($name, $rights, 'ContainerInherit,ObjectInherit', 'None', 'Allow')
        $acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
    if ($ResetChildren -and @(Get-ChildItem -LiteralPath $Path -Force).Count) {
        Invoke-Native "$env:windir\System32\icacls.exe" @((Join-Path $Path '*'), '/reset', '/T', '/Q', '/L')
    }
}

function Assert-VolumeSpace([string]$Drive, [decimal]$Required) {
    $free = [decimal]([IO.DriveInfo]::new($Drive)).AvailableFreeSpace
    if ($free -lt ($Required + 1GB)) { throw "Insufficient free space on $Drive for isolated website data." }
}

function Assert-SqlSpace($Connection, $Profile, [decimal]$Growth) {
    $database = if ($Profile) { Quote-Sql $Profile.database } else { "N'master'" }
    $volume = Invoke-Sql $Connection "SELECT MIN(vs.available_bytes) AS free_bytes FROM sys.master_files mf CROSS APPLY sys.dm_os_volume_stats(mf.database_id, mf.file_id) vs WHERE mf.database_id = DB_ID($database)"
    if ($volume.Rows.Count -ne 1 -or $volume.Rows[0].free_bytes -is [DBNull] -or
        [decimal]$volume.Rows[0].free_bytes -lt ($Growth + 1GB)) {
        throw 'SQL data volume lacks space for this instance operation.'
    }
}

function Get-StoragePaths($Profile, [string]$Name) {
    $state = Join-Path 'C:\ProgramData\AcumaticaInstances' $Profile.id
    $archive = Join-Path (Join-Path 'D:\AcumaticaInstanceCheckpoints' $Profile.id) $Name
    return @{ state = $state; archive = $archive; backup = "/var/opt/mssql/data/acu_$($Profile.id)_$Name.bak" }
}

function Get-SiteConfig($Profile) {
    $configPath = Join-Path $Profile.path 'web.config'
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) { throw "Missing website configuration: $configPath" }
    [xml]$config = [IO.File]::ReadAllText($configPath)
    $settings = @{}
    foreach ($item in $config.configuration.appSettings.add) { $settings[[string]$item.key] = [string]$item.value }
    # This build's FileStorage is site-local (App_Data/Projects). Unknown storage
    # providers and explicit out-of-site attachment locations are not captured.
    if ($settings.StorageType -cne 'FileStorage') { throw 'Unknown or external attachment storage; checkpoint cannot cover it.' }
    foreach ($key in $settings.Keys) {
        if ($key -match '(?i)(attachment|filestorage|storagepath|upload|blob)' -and $key -cne 'StorageType') {
            $value = $settings[$key]
            if ($value -match '^(?:[A-Za-z]:\\|\\\\)' -and
                -not $value.StartsWith($Profile.path + '\', [StringComparison]::OrdinalIgnoreCase)) {
                throw "External storage setting $key is not captured by the website archive."
            }
            if ($value -match '(^|[/\\])\.\.([/\\]|$)') { throw "Storage setting $key escapes the website." }
        }
    }
    return $config
}

function Assert-SiteIdentity($Profile) {
    Assert-Instance $Profile
    $null = Get-SiteConfig $Profile
    $cs = Get-ConnectionSettings $Profile.path
    if ([string]$cs.get_Item('Initial Catalog') -ine $Profile.database -or
        [string]$cs.get_Item('User ID') -ine ('acu_' + $Profile.id)) {
        throw 'Website does not use its private SQL login and database.'
    }
}

function Assert-RuntimeLogin($Connection, $Profile) {
    $login = Quote-Sql ('acu_' + $Profile.id)
    $db = Quote-Ident $Profile.database
    $mapping = Invoke-Sql $Connection "SELECT dp.name AS dbuser FROM $db.sys.database_principals dp JOIN sys.server_principals sp ON dp.sid = sp.sid WHERE dp.name = $login AND sp.name = $login AND sp.type = 'S' AND IS_SRVROLEMEMBER('sysadmin', $login) = 0"
    if ($mapping.Rows.Count -ne 1) { throw 'Private database login mapping is missing or has server administrator access.' }
}

function Assert-LocalAttachments($Connection, $Profile) {
    $db = Quote-Ident $Profile.database
    $external = Invoke-Sql $Connection "SELECT (SELECT COUNT_BIG(*) FROM $db.dbo.BlobStorageConfig WHERE IsActive = 1) + (SELECT COUNT_BIG(*) FROM $db.dbo.UploadFileRevision WHERE BlobHandler IS NOT NULL) AS ExternalCount"
    if ([long]$external.Rows[0].ExternalCount -gt 0) {
        throw 'External attachment providers or blob references are present; a website/database checkpoint would be incomplete.'
    }
}


function Get-CheckpointManifest($Profile, [string]$Name) {
    $paths = Get-StoragePaths $Profile $Name
    $manifestPath = Join-Path $paths.archive 'complete.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw 'Checkpoint is absent or incomplete.' }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    if ($manifest.schema -ne 1 -or $manifest.id -cne $Profile.id -or
        $manifest.application -cne $Profile.application -or $manifest.pool -cne $Profile.pool -or
        $manifest.path -cne $Profile.path -or $manifest.database -cne $Profile.database -or
        $manifest.build -cne $Profile.build -or $manifest.name -cne $Name -or
        $manifest.backup -cne $paths.backup -or
        $manifest.runtimeLogin -cne ('acu_' + $Profile.id)) { throw 'Checkpoint identity does not match this profile.' }
    $siteZip = Join-Path $paths.archive 'site.zip'
    if ((Get-FileHash -LiteralPath $siteZip -Algorithm SHA256).Hash -cne $manifest.siteSha256) {
        throw 'Checkpoint website archive checksum mismatch.'
    }
    return @{ paths = $paths; manifest = $manifest; zip = $siteZip }
}

function Assert-Backup($Connection, $Profile, $Manifest) {
    $source = Quote-Sql $Manifest.backup
    $header = Invoke-Sql $Connection "RESTORE HEADERONLY FROM DISK = $source"
    if ($header.Rows.Count -ne 1 -or $header.Rows[0].DatabaseName -cne $Profile.database -or
        [string]$header.Rows[0].BackupSetGUID -cne $Manifest.backupSetGuid -or
        [int]$header.Rows[0].HasBackupChecksums -ne 1) { throw 'SQL backup identity or checksum metadata mismatch.' }
    $null = Invoke-Sql $Connection "RESTORE VERIFYONLY FROM DISK = $source WITH CHECKSUM"
}

function Assert-NoReparsePoints([string]$Path) {
    $pending = New-Object 'System.Collections.Generic.Stack[System.IO.DirectoryInfo]'
    $pending.Push([IO.DirectoryInfo]::new($Path))
    [decimal]$bytes = 0
    while ($pending.Count -gt 0) {
        foreach ($item in $pending.Pop().GetFileSystemInfos()) {
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Website contains an external or opaque filesystem link: $($item.FullName)"
            }
            if ($item -is [IO.DirectoryInfo]) { $pending.Push($item) }
            else { $bytes += $item.Length }
        }
    }
    return $bytes
}

function Invoke-InstanceCheckpoint($Profile, [string]$Name) {
    Assert-StorageProfile $Profile
    Assert-CheckpointName $Name
    $paths = Get-StoragePaths $Profile $Name
    if (Test-Path -LiteralPath $paths.archive) { throw 'Checkpoint name already exists.' }
    Assert-SiteIdentity $Profile
    if (Test-Path (Join-Path $StateRoot ($Profile.id + '.blocked'))) { throw 'Cannot checkpoint a blocked instance.' }
    $connection = Get-AdminConnection
    $begun = $false
    try {
        Assert-RuntimeLogin $connection $Profile
        Assert-LocalAttachments $connection $Profile
        $siteBytes = Assert-NoReparsePoints $Profile.path
        Assert-VolumeSpace 'D:\' $siteBytes
        $dbBytes = Invoke-Sql $connection "SELECT SUM(CAST(size AS bigint) * 8192) AS bytes FROM sys.master_files WHERE database_id = DB_ID($(Quote-Sql $Profile.database))"
        Assert-SqlSpace $connection $Profile ([decimal]$dbBytes.Rows[0].bytes)
        $exists = Invoke-Sql $connection "DECLARE @e int; EXEC master.dbo.xp_fileexist $(Quote-Sql $paths.backup), @e OUTPUT; SELECT @e AS Present"
        if ([int]$exists.Rows[0].Present -ne 0) { throw 'SQL backup path already exists.' }
        # No archive or SQL backup is created before the pool has stopped.
        $begun = $true
        Stop-Instance $Profile
        Set-InstanceBlocked $Profile 'checkpoint in progress; keep this instance stopped'
        Assert-LocalAttachments $connection $Profile
        New-PrivateDirectory 'D:\AcumaticaInstanceCheckpoints'
        New-PrivateDirectory (Split-Path -Parent $paths.archive)
        New-PrivateDirectory $paths.archive
        $db = Quote-Ident $Profile.database
        $source = Quote-Sql $paths.backup
        $null = Invoke-Sql $connection "BACKUP DATABASE $db TO DISK = $source WITH COPY_ONLY, CHECKSUM, INIT"
        $header = Invoke-Sql $connection "RESTORE HEADERONLY FROM DISK = $source"
        if ($header.Rows.Count -ne 1 -or $header.Rows[0].DatabaseName -cne $Profile.database) { throw 'SQL backup header identity mismatch.' }
        $null = Invoke-Sql $connection "RESTORE VERIFYONLY FROM DISK = $source WITH CHECKSUM"
        $null = Assert-NoReparsePoints $Profile.path
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = Join-Path $paths.archive 'site.zip'
        [IO.Compression.ZipFile]::CreateFromDirectory($Profile.path, $zip, [IO.Compression.CompressionLevel]::Optimal, $false)
        $manifest = [ordered]@{
            schema = 1; id = $Profile.id; name = $Name; application = $Profile.application
            pool = $Profile.pool; path = $Profile.path; database = $Profile.database
            build = $Profile.build; runtimeLogin = ('acu_' + $Profile.id)
            configSha256 = (Get-FileHash -LiteralPath (Join-Path $Profile.path 'web.config') -Algorithm SHA256).Hash
            backup = $paths.backup
            backupSetGuid = [string]$header.Rows[0].BackupSetGUID
            siteSha256 = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash
        }
        # Completion marker is written last. Failed checkpoints are intentionally retained
        # for inspection and never mistaken for restorable checkpoints.
        [IO.File]::WriteAllText((Join-Path $paths.archive 'complete.json'), ($manifest | ConvertTo-Json -Depth 4))
        Clear-InstanceBlocked $Profile
        return @{ status = 'checkpointed'; id = $Profile.id; name = $Name; archive = $paths.archive }
    } catch {
        if ($begun) { Set-InstanceBlocked $Profile 'checkpoint incomplete; inspect database backup and website archive' }
        throw
    } finally { $connection.Dispose() }
}

function Assert-ZipSafe([string]$ZipPath, [string]$Destination) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        $root = [IO.Path]::GetFullPath($Destination).TrimEnd('\') + '\'
        foreach ($entry in $archive.Entries) {
            $target = [IO.Path]::GetFullPath((Join-Path $Destination $entry.FullName))
            if (-not $target.StartsWith($root, [StringComparison]::OrdinalIgnoreCase) -or
                ($entry.ExternalAttributes -band 0xF0000000) -eq 0xA0000000) {
                throw 'Unsafe website archive entry.'
            }
        }
    } finally { $archive.Dispose() }
}

function Get-RestoreMoves($Connection, $Profile, [string]$Backup) {
    $db = Quote-Sql $Profile.database
    $current = Invoke-Sql $Connection "SELECT mf.type_desc, mf.physical_name FROM sys.master_files mf WHERE mf.database_id = DB_ID($db) ORDER BY mf.file_id"
    $files = Invoke-Sql $Connection "RESTORE FILELISTONLY FROM DISK = $(Quote-Sql $Backup)"
    if ($current.Rows.Count -lt 2 -or $files.Rows.Count -ne $current.Rows.Count) {
        throw 'SQL backup file layout differs from this instance; refusing restore.'
    }
    $moves = @()
    for ($i = 0; $i -lt $files.Rows.Count; $i++) {
        $file = $files.Rows[$i]
        $physical = [string]$current.Rows[$i].physical_name
        $kind = if ([string]$file.Type -ceq 'D') { 'ROWS' } elseif ([string]$file.Type -ceq 'L') { 'LOG' } else { throw 'Unsupported SQL backup file type.' }
        if ($current.Rows[$i].type_desc -cne $kind -or
            $physical -notmatch '^/var/opt/mssql/data/' -or
            $physical -notmatch ('(?i)(^|/)' + [regex]::Escape($Profile.database) + '[^/]*$')) {
            throw 'SQL physical files are not exclusively owned by this profile.'
        }
        $owner = Invoke-Sql $Connection "SELECT DB_NAME(database_id) AS db FROM sys.master_files WHERE physical_name = $(Quote-Sql $physical)"
        if ($owner.Rows.Count -ne 1 -or $owner.Rows[0].db -cne $Profile.database) {
            throw 'SQL physical file is shared with another database.'
        }
        $moves += "MOVE $(Quote-Sql ([string]$file.LogicalName)) TO $(Quote-Sql $physical)"
    }
    return ($moves -join ', ')
}

function Invoke-InstanceReset($Profile, [string]$Name) {
    Assert-StorageProfile $Profile
    Assert-CheckpointName $Name
    $checkpoint = Get-CheckpointManifest $Profile $Name
    $connection = Get-AdminConnection
    $begun = $false
    try {
        Assert-Backup $connection $Profile $checkpoint.manifest
        Assert-SiteIdentity $Profile
        Assert-RuntimeLogin $connection $Profile
        $moves = Get-RestoreMoves $connection $Profile $checkpoint.paths.backup
        Assert-ZipSafe $checkpoint.zip $Profile.path
        $archive = [IO.Compression.ZipFile]::OpenRead($checkpoint.zip)
        try {
            [decimal]$websiteBytes = 0
            foreach ($entry in $archive.Entries) { $websiteBytes += $entry.Length }
        } finally { $archive.Dispose() }
        Assert-VolumeSpace 'D:\' $websiteBytes
        $files = Invoke-Sql $connection "RESTORE FILELISTONLY FROM DISK = $(Quote-Sql $checkpoint.paths.backup)"
        $growth = 0
        foreach ($file in $files.Rows) { $growth += [decimal]$file.Size }
        Assert-SqlSpace $connection $Profile $growth
        $begun = $true
        Stop-Instance $Profile
        Set-InstanceBlocked $Profile 'reset in progress; keep the pool stopped until validation completes'
        # Framework ZipFile still hits MAX_PATH with long sibling names. Keep
        # both temporary roots shorter than the deployed website's root.
        New-PrivateDirectory 'D:\AcuTmp'
        $work = Join-Path 'D:\AcuTmp' ([guid]::NewGuid().ToString('N').Substring(0, 8))
        if (Test-Path -LiteralPath $work) { throw 'Restore staging path already exists.' }
        New-PrivateDirectory $work
        $stage = Join-Path $work 's'
        $old = Join-Path $work 'o'
        [void][IO.Directory]::CreateDirectory($stage)
        try {
            [IO.Compression.ZipFile]::ExtractToDirectory($checkpoint.zip, $stage)
            $null = Get-SiteConfig @{ path = $stage }
            if ((Get-FileHash -LiteralPath (Join-Path $stage 'web.config') -Algorithm SHA256).Hash -cne
                $checkpoint.manifest.configSha256) { throw 'Archived website configuration checksum mismatch.' }
            # Quarantine old files rather than deleting them during an uncertain restore.
            [IO.Directory]::Move($Profile.path, $old)
            [IO.Directory]::Move($stage, $Profile.path)
            $db = Quote-Ident $Profile.database
            $null = Invoke-Sql $connection "ALTER DATABASE $db SET SINGLE_USER WITH ROLLBACK IMMEDIATE"
            try {
                $null = Invoke-Sql $connection "RESTORE DATABASE $db FROM DISK = $(Quote-Sql $checkpoint.paths.backup) WITH REPLACE, RECOVERY, CHECKSUM, $moves"
            } finally {
                $null = Invoke-Sql $connection "IF DB_ID($(Quote-Sql $Profile.database)) IS NOT NULL ALTER DATABASE $db SET MULTI_USER"
            }
            # Check login mapping after restoring a database created under this profile.
            $login = Quote-Ident ('acu_' + $Profile.id)
            $user = Quote-Ident ('acu_' + $Profile.id)
            $mapped = Invoke-Sql $connection "SELECT 1 AS present FROM sys.server_principals WHERE name = $(Quote-Sql ('acu_' + $Profile.id)) AND type = 'S'"
            if ($mapped.Rows.Count -ne 1) { throw 'Instance SQL login no longer exists.' }
            $null = Invoke-Sql $connection "USE $db; IF DATABASE_PRINCIPAL_ID($(Quote-Sql ('acu_' + $Profile.id))) IS NULL THROW 50000, 'Instance database user missing', 1; ALTER USER $user WITH LOGIN = $login"
            Set-InstanceSiteIsolation $Profile
            Assert-SiteIdentity $Profile
            Assert-RuntimeLogin $connection $Profile
            Remove-Item -LiteralPath $old -Recurse -Force
            Remove-Item -LiteralPath $work -Force
            $receipt = Join-Path $StateRoot ($Profile.id + '.publication.json')
            if (Test-Path -LiteralPath $receipt) { Remove-Item -LiteralPath $receipt -Force }
            Clear-InstanceBlocked $Profile
            return @{ status = 'reset'; id = $Profile.id; name = $Name }
        } catch {
            # The blocked marker and stopped pool remain. The staged and previous
            # directories are left available for manual recovery.
            throw
        }
    } catch {
        if ($begun) { Set-InstanceBlocked $Profile 'reset incomplete; inspect stopped site and SQL database' }
        throw
    } finally { $connection.Dispose() }
}
