$ErrorActionPreference = 'Stop'
try {
    [xml]$config = Get-Content -LiteralPath 'C:\AcumaticaERP\web.config' -Raw
    $entry = @($config.configuration.connectionStrings.add | Where-Object { $_.name -eq 'ProjectX' })
    if ($entry.Count -ne 1 -or !$entry[0].connectionString) { throw 'Missing ProjectX.' }
    $settings = [System.Data.SqlClient.SqlConnectionStringBuilder]::new([string]$entry[0].connectionString)
} catch {
    throw 'Cannot read the canonical ProjectX SQL connection settings. Do not print the connection string.'
}
if ($settings.DataSource -ne '172.30.0.1' -or $settings.InitialCatalog -ne 'AcumaticaDB') {
    throw 'Canonical ProjectX does not target AcumaticaDB on the Dockur SQL bridge.'
}
$settings.ConnectTimeout = 5
$connection = [System.Data.SqlClient.SqlConnection]::new($settings.ConnectionString)
try {
    $connection.Open()
    $command = $connection.CreateCommand()
    try {
        $command.CommandTimeout = 5
        $command.CommandText = 'SELECT DB_NAME()'
        if ($command.ExecuteScalar() -ne $settings.InitialCatalog) { throw 'Unexpected SQL database.' }
    } finally { $command.Dispose() }
} catch {
    throw 'Windows could not query AcumaticaDB with the site runtime login. Check the SQL bridge, login and database permissions.'
} finally { $connection.Dispose() }
Write-Output 'Windows SQL authentication verified: AcumaticaDB'
