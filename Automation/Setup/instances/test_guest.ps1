$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'guest.ps1') -LibraryOnly
. (Join-Path $PSScriptRoot 'builds.ps1')
. (Join-Path $PSScriptRoot 'storage.ps1')

function Assert-Rejected([scriptblock]$Call, [string]$Message) {
    $failure = $null
    try { & $Call } catch { $failure = $_.Exception.Message }
    if (-not $failure -or $failure -notmatch $Message) { throw "Expected rejection matching $Message; got $failure" }
}

# PowerShell 5 ConvertFrom-Json returns the catalog array as one pipeline object.
# A wrapped pipeline must not accidentally select both releases' values.
foreach ($case in @(@('25.101.0153', '25r1', 'classic'), @('26.101.0225', '26r1', 'modern'))) {
    $build = Get-InstanceBuild @{ build=$case[0] }
    if ($build.release -cne $case[1] -or $build.ui -cne $case[2]) { throw 'Guest chose the wrong build/UI preset' }
}
Assert-Rejected { Get-InstanceBuild @{ build='25.101.0153.6' } } 'Unsupported build'
$profile = @{
    id='clean'; application='Acu_clean'; pool='Acu_clean'; path='D:\AcumaticaInstances\clean'
    database='Acu_clean'; build='26.101.0225'; installerRoot='C:\AcumaticaBuilds\26.101.0225\Acumatica ERP'
    protected=$false; packages=@()
}
$profile.build = '25.101.0153'
Assert-Rejected { Assert-StorageProfile $profile } 'Invalid installer identity'
$profile.installerRoot = 'C:\AcumaticaBuilds\25.101.0153\Acumatica ERP'
Assert-StorageProfile $profile
$canonical = Get-Content (Join-Path $PSScriptRoot 'profiles\default.json') -Raw | ConvertFrom-Json
Assert-Rejected { Assert-StorageProfile $canonical } 'Only named'

# Exercise fast native exits repeatedly; a handle captured after Start-Process
# returns can already be too late. Also prove private pipe capture and timeout.
$logs = Join-Path ([IO.Path]::GetTempPath()) ('instance-process-test-' + [guid]::NewGuid().ToString('N'))
New-PrivateDirectory $logs
try {
    foreach ($expected in @(0, 7)) {
        foreach ($iteration in 1..20) {
            $actual = Invoke-InstallerProcess -Exe $env:ComSpec -Arguments @('/c', "exit $expected") `
                -TimeoutMilliseconds 10000 -LogDirectory $logs
            if ($null -eq $actual -or $actual -ne $expected) { throw "Lost native exit code $expected" }
        }
    }
    $actual = Invoke-InstallerProcess -Exe $env:ComSpec -Arguments @('/c', 'echo private-out & echo private-error 1>&2 & exit 7') `
        -TimeoutMilliseconds 10000 -LogDirectory $logs
    if ($actual -ne 7 -or (Get-Content (Join-Path $logs 'installer.stdout.log') -Raw).Trim() -ne 'private-out' -or
        (Get-Content (Join-Path $logs 'installer.stderr.log') -Raw).Trim() -ne 'private-error') { throw 'Native log capture failed' }
    Assert-Rejected {
        Invoke-InstallerProcess -Exe (Get-Process -Id $PID).Path -Arguments @('-NoProfile', '-NonInteractive', '-Command', '"Start-Sleep -Seconds 10"') `
            -TimeoutMilliseconds 100 -LogDirectory $logs
    } 'exceeded its time limit'
} finally { Remove-Item -LiteralPath $logs -Recurse -Force }
Write-Output 'Guest build isolation and native exit-code regressions passed.'
