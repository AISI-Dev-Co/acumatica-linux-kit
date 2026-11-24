# Sourced by guest.ps1. Only fresh named sites, never a copy of a live website.
function Assert-ProvisionVacant($Profile, $Connection) {
    if (Test-Path -LiteralPath $Profile.path) { throw 'Instance website path already exists.' }
    if (Test-Path -LiteralPath ('HKLM:\SOFTWARE\Acumatica ERP\' + $Profile.application)) {
        throw 'Instance is already registered with the Acumatica Configuration Wizard.'
    }
    $paths = Get-StoragePaths $Profile '_provision'
    if (Test-Path -LiteralPath $paths.state) { throw 'Instance private state already exists.' }
    Add-Type -Path "$env:windir\System32\inetsrv\Microsoft.Web.Administration.dll"
    $manager = [Microsoft.Web.Administration.ServerManager]::new()
    try {
        if ($null -ne $manager.ApplicationPools[$Profile.pool]) { throw 'Instance application pool already exists.' }
        foreach ($site in $manager.Sites) {
            foreach ($app in $site.Applications) {
                if ($app.Path -ieq ('/' + $Profile.application)) { throw 'IIS application name already exists.' }
            }
        }
        if ($null -eq $manager.Sites['Default Web Site']) { throw 'Default Web Site is missing.' }
    } finally { $manager.Dispose() }
    $occupied = Invoke-Sql $Connection "SELECT DB_ID($(Quote-Sql $Profile.database)) AS db, SUSER_ID($(Quote-Sql ('acu_' + $Profile.id))) AS [login]"
    if ($occupied.Rows[0].db -isnot [DBNull] -or $occupied.Rows[0].login -isnot [DBNull]) {
        throw 'Instance SQL database or login already exists.'
    }
}

function Set-InstanceSiteIsolation($Profile, [switch]$InitializeUi) {
    Set-PoolDirectoryAcl $Profile.path $Profile.pool -ResetChildren
    $config = Get-SiteConfig $Profile
    [xml]$canonical = [IO.File]::ReadAllText('C:\AcumaticaERP\web.config')
    $node = @($canonical.configuration.appSettings.add | Where-Object { $_.key -eq 'NodeJs:NodeJsPath' })
    if ($node.Count -ne 1 -or -not (Test-Path -LiteralPath $node[0].value -PathType Container)) {
        throw 'Installed Node runtime from the canonical site is unavailable.'
    }
    $settings = @{
        'NodeJs:NodeJsPath' = [string]$node[0].value
        'NodeJs:NpmCachePath' = "C:\NpmCache\$($Profile.application)"
        'NodeJs:NodeTempPath' = "C:\NodeTemp\$($Profile.application)"
        'CustomizationTempFilesPath' = "C:\Customization\$($Profile.application)"
        'SnapshotsFolder' = "C:\Snapshots\$($Profile.application)"
        'BackupFolder' = "C:\BackUp\Sites\$($Profile.application)"
    }
    if ($InitializeUi) {
        # Persist the preset explicitly; the wizard can omit this XML option.
        # Reset must retain the checkpoint's UI configuration instead.
        $settings['EnableSiteMapSwitchUI'] = [string]((Get-InstanceBuild $Profile).ui -eq 'modern')
    }
    foreach ($key in $settings.Keys) {
        $entries = @($config.configuration.appSettings.add | Where-Object { $_.key -ceq $key })
        if ($entries.Count -gt 1) { throw "Duplicate configuration setting $key" }
        if ($entries.Count -eq 1) { $entries[0].value = $settings[$key] }
        else {
            $entry = $config.CreateElement('add')
            $entry.SetAttribute('key', $key)
            $entry.SetAttribute('value', $settings[$key])
            [void]$config.configuration.appSettings.AppendChild($entry)
        }
        if ($key -notin @('NodeJs:NodeJsPath', 'EnableSiteMapSwitchUI')) {
            Set-PoolDirectoryAcl $settings[$key] $Profile.pool
        }
    }
    $asp = "C:\TemporaryAspFiles\$($Profile.application)"
    Set-PoolDirectoryAcl $asp $Profile.pool
    $compilation = $config.configuration.'system.web'.compilation
    if ($null -eq $compilation) { throw 'Installer did not produce ASP.NET compilation configuration.' }
    $compilation.SetAttribute('tempDirectory', $asp)
    $config.Save((Join-Path $Profile.path 'web.config'))
}

function Invoke-InstanceProvision($Profile) {
    Assert-StorageProfile $Profile
    $build = Get-InstanceBuild $Profile
    Ensure-InstanceBuild $Profile
    $exe = Join-Path $Profile.installerRoot 'Data\ac.exe'
    $connection = Get-AdminConnection
    $begun = $false
    try {
        Assert-ProvisionVacant $Profile $connection
        $assets = Join-Path $Profile.installerRoot 'Files'
        if (-not (Test-Path -LiteralPath $assets -PathType Container)) { throw 'Matching installer Files directory is missing.' }
        $assetBytes = (Get-ChildItem -LiteralPath $assets -Recurse -File -Force | Measure-Object -Property Length -Sum).Sum
        if (-not $assetBytes) { throw 'Matching installer Files directory is empty.' }
        Assert-VolumeSpace 'D:\' ([decimal]$assetBytes * 2)
        Assert-SqlSpace $connection $null 0
        # The guest's private request carries the SQL administrator credential.
        # Never fetch it from the existing website's non-administrator login.
        if (-not $request.sqlPassword -or $request.sqlServer -cne '172.30.0.1') {
            throw 'Private SQL administration request is required for provisioning.'
        }
        $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
        try {
            $bytes = New-Object byte[] 48
            $rng.GetBytes($bytes)
            $password = 'Acu1!' + [Convert]::ToBase64String($bytes)
        } finally { $rng.Dispose() }
        New-PrivateDirectory 'C:\ProgramData\AcumaticaInstances'
        $paths = Get-StoragePaths $Profile '_provision'
        $begun = $true
        Set-InstanceBlocked $Profile 'provision in progress; do not start this instance'
        New-PrivateDirectory $paths.state
        $temporary = Join-Path $paths.state 'provision.xml'
        $values = [ordered]@{
            configmode = 'NewInstance'; dbsrvtype = 'MSSqlServer'; dbsrvname = [string]$request.sqlServer
            dbsrvwinauth = 'False'; dbsrvuser = 'sa'; dbsrvpass = [string]$request.sqlPassword
            dbname = $Profile.database; dbnew = 'True'; dbwinauth = 'False'; dbnewuser = 'True'
            dbuser = ('acu_' + $Profile.id); dbpass = $password; iname = $Profile.application
            ipath = $Profile.path; swebsite = 'Default Web Site'; svirtdir = $Profile.application
            spool = $Profile.pool; skipcompile = 'True'; newUI = [string]($build.ui -eq 'modern'); output = 'Quiet'
        }
        $xml = New-Object Xml.XmlDocument
        [void]$xml.AppendChild($xml.CreateXmlDeclaration('1.0', 'utf-8', $null))
        $root = $xml.CreateElement('Root'); [void]$xml.AppendChild($root)
        foreach ($key in $values.Keys) {
            $element = $xml.CreateElement($key)
            $element.SetAttribute('Value', [string]$values[$key])
            [void]$root.AppendChild($element)
        }
        $tempDir = Join-Path $paths.state 'installer-temp'
        New-PrivateDirectory $tempDir
        $priorTemp = $env:TEMP; $priorTmp = $env:TMP
        try {
            $env:TEMP = $tempDir; $env:TMP = $tempDir
            $xml.Save($temporary)
            # ac.exe has no documented guarantee against printing credentials.
            # Capture both streams privately and do not quote their contents in errors.
            $exitCode = Invoke-InstallerProcess -Exe $exe -Arguments @('-f:' + $temporary, '-c:"ci=1;"', '-c:"ci=2;cp=1;cv=True;cn=Company;"') `
                -WorkingDirectory (Split-Path -Parent $exe) -LogDirectory $paths.state -TimeoutMilliseconds 1200000
            if ($exitCode -ne 0) { throw "Acumatica installer failed ($exitCode); inspect the private installer logs." }
        } finally {
            $env:TEMP = $priorTemp; $env:TMP = $priorTmp
            if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
            $values.dbsrvpass = $null; $values.dbpass = $null; $password = $null
        }
        # The installer may have started the pool. Stop it before editing config;
        # Stop-Instance's full validation only becomes possible after isolation.
        Stop-InstancePool $Profile
        Set-InstanceSiteIsolation $Profile -InitializeUi
        $manager = [Microsoft.Web.Administration.ServerManager]::new()
        try {
            $pool = $manager.ApplicationPools[$Profile.pool]
            if ($null -eq $pool) { throw 'Installer did not create the expected IIS pool.' }
            $pool.AutoStart = $false
            $pool.ProcessModel.IdentityType = [Microsoft.Web.Administration.ProcessModelIdentityType]::ApplicationPoolIdentity
            $manager.CommitChanges()
        } finally { $manager.Dispose() }
        Stop-Instance $Profile
        Assert-SiteIdentity $Profile
        Assert-RuntimeLogin $connection $Profile
        Clear-InstanceBlocked $Profile
        return @{ status = 'provisioned'; id = $Profile.id; application = $Profile.application; database = $Profile.database }
    } catch {
        # No automatic deletion of a partially installed website, SQL login, or DB.
        $failure = $_
        if ($begun) {
            Set-InstanceBlocked $Profile 'provision incomplete; inspect site, pool and database before repair'
            try { if (Test-Path "IIS:\AppPools\$($Profile.pool)") { Stop-InstancePool $Profile } }
            catch { [Console]::Error.WriteLine('Also failed to stop incomplete pool: ' + $_.Exception.Message) }
        }
        throw $failure
    } finally { $connection.Dispose() }
}
