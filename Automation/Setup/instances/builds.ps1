# Build presets are shared with the host CLI. Installers remain outside the repo.
function Get-InstanceBuild($Profile) {
    $records = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'builds.json') -Raw | ConvertFrom-Json
    $match = @($records | Where-Object { $_.build -ceq $Profile.build })
    if ($match.Count -ne 1) { throw "Unsupported build $($Profile.build); select a pinned build preset." }
    $build = $match[0]
    if ($build.release -cnotin @('25r1', '26r1') -or $build.ui -cnotin @('classic', 'modern') -or
        $build.build -cnotmatch ('^' + $build.release.Substring(0, 2) + '\.1\d{2}\.\d{4}$')) {
        throw 'Invalid build preset.'
    }
    return $build
}

function Assert-AcumaticaSignature([string]$Path) {
    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch '(^|,\s*)O=Acumatica INC(,|$)') {
        throw "Missing or invalid Acumatica signature: $Path"
    }
    return $signature.SignerCertificate.Subject
}

function Assert-InstallerBuild([string]$Root, [string]$Build) {
    foreach ($relative in @('Data\ac.exe', 'Files\Bin\PX.Data.dll')) {
        $file = Join-Path $Root $relative
        if (-not (Test-Path -LiteralPath $file -PathType Leaf) -or
            [Diagnostics.FileVersionInfo]::GetVersionInfo($file).FileVersion -cnotmatch ('^' + [regex]::Escape($Build) + '(?:\.0)?$')) {
            throw "Installer must contain $Build at $file"
        }
    }
}

function Invoke-InstallerProcess([string]$Exe, [string[]]$Arguments, [int]$TimeoutMilliseconds,
        [string]$LogDirectory, [string]$WorkingDirectory) {
    # Start-Process -PassThru can lose ExitCode before the caller can capture its
    # handle. Direct Process.Start retains the original handle, even for fast exits.
    $process = New-Object Diagnostics.Process
    $process.StartInfo.FileName = $Exe
    $process.StartInfo.Arguments = $Arguments -join ' '
    $process.StartInfo.UseShellExecute = $false
    $process.StartInfo.CreateNoWindow = $true
    $process.StartInfo.RedirectStandardOutput = $true
    $process.StartInfo.RedirectStandardError = $true
    if ($WorkingDirectory) { $process.StartInfo.WorkingDirectory = $WorkingDirectory }
    $stdout = $null; $stderr = $null; $started = $false
    try {
        $stdout = [IO.File]::Create((Join-Path $LogDirectory 'installer.stdout.log'))
        $stderr = [IO.File]::Create((Join-Path $LogDirectory 'installer.stderr.log'))
        $started = $process.Start()
        if (-not $started) { throw 'Installer process did not start.' }
        # Drain both pipes concurrently: private logs may contain credentials,
        # and a full pipe must not deadlock the bounded process wait.
        $copies = [Threading.Tasks.Task[]]@(
            $process.StandardOutput.BaseStream.CopyToAsync($stdout)
            $process.StandardError.BaseStream.CopyToAsync($stderr)
        )
        if (-not $process.WaitForExit($TimeoutMilliseconds)) {
            throw 'Installer process exceeded its time limit.'
        }
        if (-not [Threading.Tasks.Task]::WaitAll($copies, 10000)) { throw 'Installer log capture did not finish.' }
        return $process.ExitCode
    } finally {
        try {
            if ($started -and -not $process.HasExited) {
                $process.Kill()
                [void]$process.WaitForExit(10000)
            }
        } finally {
            $process.Dispose()
            if ($stdout) { $stdout.Dispose() }
            if ($stderr) { $stderr.Dispose() }
        }
    }
}

function Ensure-InstanceBuild($Profile) {
    $build = Get-InstanceBuild $Profile
    $destination = Split-Path -Parent $Profile.installerRoot
    if (Test-Path -LiteralPath $destination) {
        Assert-InstallerBuild $Profile.installerRoot $build.build
        $receiptPath = Join-Path $destination 'source.json'
        if (Test-Path -LiteralPath $receiptPath) {
            $receipt = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json
            if ($receipt.build -cne $build.build -or
                $receipt.acSha256 -cne (Get-FileHash -LiteralPath (Join-Path $Profile.installerRoot 'Data\ac.exe') -Algorithm SHA256).Hash -or
                $receipt.dataSha256 -cne (Get-FileHash -LiteralPath (Join-Path $Profile.installerRoot 'Files\Bin\PX.Data.dll') -Algorithm SHA256).Hash) {
                throw 'Prepared installer differs from its signed-MSI extraction receipt.'
            }
        } elseif ($build.release -ceq '26r1') {
            # The original approved 26R1 image predates receipts. Its ac.exe is
            # signed; PX.Data.dll is unsigned but version-checked above.
            $null = Assert-AcumaticaSignature (Join-Path $Profile.installerRoot 'Data\ac.exe')
        } else { throw 'Prepared build has no signed-MSI extraction receipt.' }
        return
    }
    $root = 'C:\AcumaticaBuilds'
    New-PrivateDirectory $root
    $downloads = Join-Path $root 'Downloads'
    New-PrivateDirectory $downloads
    $msi = Join-Path $downloads ($build.build + '.msi')
    $family = $build.release.Substring(0, 2) + '.1'
    $url = "https://acumatica-builds.s3.amazonaws.com/builds/$family/$($build.build)/AcumaticaERP/AcumaticaERPInstall.msi"
    if (-not (Test-Path -LiteralPath $msi)) {
        $partial = $msi + '.partial.msi'
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $client = New-Object Net.WebClient
        try {
            Write-Host "Downloading signed installer $($build.build)"
            $client.DownloadFile($url, $partial)
            $null = Assert-AcumaticaSignature $partial
            Move-Item -LiteralPath $partial -Destination $msi
        } finally {
            $client.Dispose()
            if (Test-Path -LiteralPath $partial) { Remove-Item -LiteralPath $partial -Force }
        }
    }
    $signer = Assert-AcumaticaSignature $msi
    # Administrative extraction does not replace the installed Configuration Wizard.
    $stage = Join-Path $root ('.stage-' + $build.build + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-PrivateDirectory $stage
    try {
        Assert-VolumeSpace 'C:\' ((Get-Item -LiteralPath $msi).Length * 5)
        $arguments = @('/a', ('"' + $msi + '"'), '/qn', '/norestart', ('TARGETDIR="' + $stage + '"'), '/L*v', ('"' + (Join-Path $stage 'extract.log') + '"'))
        $exitCode = Invoke-InstallerProcess -Exe "$env:windir\System32\msiexec.exe" -Arguments $arguments `
            -TimeoutMilliseconds 600000 -LogDirectory $stage
        if ($exitCode -ne 0) { throw "Installer extraction failed with exit code $exitCode." }
        Assert-InstallerBuild (Join-Path $stage 'Acumatica ERP') $build.build
        # 25R1's contained EXE/DLL are unsigned. Trust the verified MSI, and pin the
        # extracted installer and assembly so later reuse cannot mix builds.
        @{ build=$build.build; url=$url; sha256=(Get-FileHash -LiteralPath $msi -Algorithm SHA256).Hash; signer=$signer;
            acSha256=(Get-FileHash -LiteralPath (Join-Path $stage 'Acumatica ERP\Data\ac.exe') -Algorithm SHA256).Hash;
            dataSha256=(Get-FileHash -LiteralPath (Join-Path $stage 'Acumatica ERP\Files\Bin\PX.Data.dll') -Algorithm SHA256).Hash } |
            ConvertTo-Json | Set-Content -LiteralPath (Join-Path $stage 'source.json') -Encoding UTF8
        Move-Item -LiteralPath $stage -Destination $destination
    } catch {
        throw "Build preparation failed; inspect $stage before retrying: $($_.Exception.Message)"
    }
}
