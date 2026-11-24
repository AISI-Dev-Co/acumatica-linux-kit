param([string]$RequestBase64, [string]$RequestFile, [switch]$Initialize, [switch]$LibraryOnly)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$StateRoot = 'C:\ProgramData\AcumaticaInstances'

function Invoke-Native($Exe, $Arguments) {
    $output = & $Exe @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "$([IO.Path]::GetFileName($Exe)) failed with exit code $LASTEXITCODE`: $(@($output | Select-Object -Last 12) -join [Environment]::NewLine)" }
}

function Initialize-State {
    if (-not (Test-Path $StateRoot)) { New-Item -ItemType Directory $StateRoot | Out-Null }
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($sid in @('S-1-5-18', 'S-1-5-32-544')) {
        $identity = New-Object Security.Principal.SecurityIdentifier($sid)
        $rule = New-Object Security.AccessControl.FileSystemAccessRule($identity, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
        $acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $StateRoot -AclObject $acl
}

function Set-InstanceBlocked($Profile, [string]$Reason) {
    Set-Content -LiteralPath (Join-Path $StateRoot ($Profile.id + '.blocked')) -Value $Reason
}

function Clear-InstanceBlocked($Profile) {
    $path = Join-Path $StateRoot ($Profile.id + '.blocked')
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
}

function Get-ConnectionSettings([string]$Path) {
    [xml]$config = Get-Content -LiteralPath (Join-Path $Path 'web.config')
    $entry = @($config.configuration.connectionStrings.add | Where-Object { $_.name -eq 'ProjectX' })
    if ($entry.Count -ne 1) { throw 'Expected exactly one ProjectX database connection' }
    $builder = New-Object System.Data.Common.DbConnectionStringBuilder
    $builder.set_ConnectionString([string]$entry[0].connectionString)
    return ,$builder
}

function Get-AdminConnection {
    if (-not $request.sqlPassword) { throw 'This operation requires a private SQL administration request' }
    $builder = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
    $builder.set_DataSource([string]$request.sqlServer)
    $builder.set_InitialCatalog('master')
    $builder.set_UserID('sa')
    $builder.set_Password([string]$request.sqlPassword)
    $builder.set_Encrypt($false)
    $builder.set_ConnectTimeout(15)
    $connection = New-Object System.Data.SqlClient.SqlConnection($builder.get_ConnectionString())
    $connection.Open()
    return $connection
}

function Invoke-Sql($Connection, [string]$Query) {
    $command = $Connection.CreateCommand()
    $command.CommandText = $Query
    $command.CommandTimeout = 600
    try {
        $reader = $command.ExecuteReader()
        try {
            $table = New-Object System.Data.DataTable
            $table.Load($reader)
            return ,$table
        } finally { $reader.Dispose() }
    } finally { $command.Dispose() }
}

function Assert-Profile($Profile) {
    if ($Profile.id -notmatch '^[a-z][a-z0-9-]{0,23}$' -or $Profile.build -notmatch '^\d{2}\.\d{3}\.\d{4}$') {
        throw 'Invalid instance identity'
    }
    $null = Get-InstanceBuild $Profile
    if ($Profile.id -eq 'default') {
        if (-not $Profile.protected -or $Profile.path -ne 'C:\AcumaticaERP' -or $Profile.database -ne 'AcumaticaDB' -or
            $Profile.application -ne 'AcumaticaERP' -or $Profile.pool -ne 'AcumaticaERPAppPool') { throw 'Invalid canonical identity' }
    } else {
        $name = 'Acu_' + $Profile.id
        if ($Profile.protected -or $Profile.path -ne "D:\AcumaticaInstances\$($Profile.id)" -or
            $Profile.database -ne $name -or $Profile.application -ne $name -or $Profile.pool -ne $name) { throw 'Invalid named instance identity' }
    }
    if ($Profile.installerRoot -ne "C:\AcumaticaBuilds\$($Profile.build)\Acumatica ERP") { throw 'Invalid installer identity' }
}

function Assert-Instance($Profile) {
    Assert-Profile $Profile
    $app = Get-WebApplication -Site 'Default Web Site' -Name $Profile.application
    if (-not $app -or $app.applicationPool -ne $Profile.pool -or
        ([string]$app.physicalPath).TrimEnd('\') -ne $Profile.path) { throw "IIS identity mismatch for $($Profile.id)" }
    $users = @(Get-WebApplication | Where-Object { $_.applicationPool -eq $Profile.pool })
    if ($users.Count -ne 1) { throw "Pool $($Profile.pool) is shared with another application" }
    $item = Get-Item -LiteralPath $Profile.path -Force
    if ($Profile.protected) {
        if ([string]($item.Target -join ';') -ne 'D:\AcumaticaERP') { throw 'Canonical data-volume link mismatch' }
    } elseif ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Named instance root cannot be a reparse point' }
    $version = (Get-Item -LiteralPath (Join-Path $Profile.path 'Bin\PX.Data.dll')).VersionInfo.FileVersion
    if ($version -ne $Profile.build) { throw "Build mismatch: expected $($Profile.build), found $version" }
    $connection = Get-ConnectionSettings $Profile.path
    if ($connection.get_Item('Initial Catalog') -ne $Profile.database -or $connection.get_Item('Data Source') -ne '172.30.0.1') {
        throw "Database target mismatch for $($Profile.id)"
    }
    if (-not $Profile.protected) {
        if ($connection.get_Item('User ID') -ine ('acu_' + $Profile.id)) { throw 'Named instance must use its database-scoped login' }
        [xml]$config = Get-Content -LiteralPath (Join-Path $Profile.path 'web.config')
        if ($config.configuration.'system.web'.compilation.tempDirectory -ne "C:\TemporaryAspFiles\$($Profile.pool)") {
            throw 'Compilation cache must be isolated per instance'
        }
    }
}

function Stop-Instance($Profile) {
    Assert-Instance $Profile
    Stop-InstancePool $Profile
}

function Stop-InstancePool($Profile) {
    if ((Get-WebAppPoolState -Name $Profile.pool).Value -ne 'Stopped') { Stop-WebAppPool -Name $Profile.pool }
    $deadline = (Get-Date).AddSeconds(120)
    do {
        $workers = @(Get-InstanceWorkers $Profile)
        if ($workers.Count -eq 0) { return }
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)
    throw "Pool $($Profile.pool) still has workers after 120 seconds"
}

function Start-Instance($Profile) {
    Assert-Instance $Profile
    $blocked = Join-Path $StateRoot ($Profile.id + '.blocked')
    if (Test-Path $blocked) { throw "Instance $($Profile.id) is blocked: $(Get-Content $blocked -Raw)" }
    foreach ($name in @('WAS', 'W3SVC')) { if ((Get-Service $name).Status -ne 'Running') { Start-Service $name } }
    if ((Get-WebAppPoolState -Name $Profile.pool).Value -ne 'Started') { Start-WebAppPool -Name $Profile.pool }
}

function Get-Published($Profile) {
    $file = Join-Path $Profile.path 'App_Data\CustomizationPublishedInfo.xml'
    if (-not (Test-Path $file)) { return @() }
    [xml]$info = Get-Content -LiteralPath $file
    return @(([string]$info.Content.project -split '[,|;]' | Where-Object { $_.Trim() } | ForEach-Object { $_.Trim() }) | Sort-Object)
}

function Get-InstanceWorkers($Profile) {
    $manager = New-Object Microsoft.Web.Administration.ServerManager
    try { return @($manager.WorkerProcesses | Where-Object { $_.AppPoolName -eq $Profile.pool } | ForEach-Object { $_.ProcessId }) }
    finally { $manager.Dispose() }
}

function Get-InstanceStatus($Profile) {
    $blocked = Join-Path $StateRoot ($Profile.id + '.blocked')
    $app = Get-WebApplication -Site 'Default Web Site' -Name $Profile.application
    if (-not $app) { return @{ id=$Profile.id; state=$(if (Test-Path $blocked) {'blocked'} else {'not-provisioned'}); published=@() } }
    Assert-Instance $Profile
    $workerIds = @(Get-InstanceWorkers $Profile)
    $memory = 0
    foreach ($workerId in $workerIds) { $p = Get-Process -Id ([int]$workerId) -ErrorAction SilentlyContinue; if ($p) { $memory += $p.PrivateMemorySize64 } }
    return @{ id=$Profile.id; state=$(if (Test-Path $blocked) { 'blocked' } else { (Get-WebAppPoolState -Name $Profile.pool).Value });
        database=$Profile.database; build=$Profile.build; published=@(Get-Published $Profile); privateMiB=[math]::Round($memory/1MB) }
}

if ($LibraryOnly) { return }

$mutex = $null
$locked = $false
try {
    Initialize-State
    if ($Initialize) { exit 0 }
    if ($RequestFile) {
        if ([IO.Path]::GetDirectoryName($RequestFile) -ne $StateRoot -or [IO.Path]::GetFileName($RequestFile) -notmatch '^request-[a-f0-9]{32}\.json$') {
            throw 'Invalid private request path'
        }
        try { $request = Get-Content -LiteralPath $RequestFile -Raw | ConvertFrom-Json }
        finally { Remove-Item -LiteralPath $RequestFile -Force }
    } else {
        $request = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($RequestBase64)) | ConvertFrom-Json
    }
    $mutex = New-Object Threading.Mutex($false, 'Global\AcumaticaInstanceOperations')
    $locked = $mutex.WaitOne(0)
    if (-not $locked) { throw 'Another instance operation is still running inside Windows' }
    Import-Module WebAdministration
    Add-Type -Path "$env:windir\System32\inetsrv\Microsoft.Web.Administration.dll"
    . (Join-Path $PSScriptRoot 'storage.ps1')
    . (Join-Path $PSScriptRoot 'builds.ps1')
    . (Join-Path $PSScriptRoot 'provision.ps1')
    . (Join-Path $PSScriptRoot 'publication.ps1')
    if ($request.profile) { Assert-Profile $request.profile }
    switch ($request.action) {
        'status' { $result = @($request.profiles | ForEach-Object { Assert-Profile $_; Get-InstanceStatus $_ }) }
        'start' { Start-Instance $request.profile; $result = Get-InstanceStatus $request.profile }
        'stop' { Stop-Instance $request.profile; $result = @{ id=$request.profile.id; state=(Get-WebAppPoolState -Name $request.profile.pool).Value } }
        'provision' { $result = Invoke-InstanceProvision $request.profile }
        'checkpoint' { $result = Invoke-InstanceCheckpoint $request.profile $request.name }
        'reset' { $result = Invoke-InstanceReset $request.profile $request.name }
        'publish' { $result = Invoke-InstancePublication $request.profile $request.packages }
        default { throw "Unknown guest action $($request.action)" }
    }
    Write-Output ('ACU_RESULT:' + (ConvertTo-Json -InputObject $result -Depth 12 -Compress))
} catch {
    [Console]::Error.WriteLine('Instance operation failed: ' + $_.Exception.Message)
    exit 1
} finally {
    if ($locked) { $mutex.ReleaseMutex() }
    if ($mutex) { $mutex.Dispose() }
}
