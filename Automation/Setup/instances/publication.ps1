function Get-PublicationFingerprint($Profile, $Packages) {
    $body = [ordered]@{
        build = $Profile.build
        packages = @($Packages | ForEach-Object { [ordered]@{ name=$_.name; sha256=$_.sha256; level=$_.level; dependsOn=@($_.dependsOn) } })
    } | ConvertTo-Json -Depth 8 -Compress
    $hash = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($body))).Replace('-', '') }
    finally { $hash.Dispose() }
}

function Get-PublishedArchiveHash($Profile) {
    $file = Join-Path $Profile.path 'App_Data\CustomizationPublishedDoc.zip'
    if (-not (Test-Path $file)) { return '' }
    return (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash
}

function Invoke-InstancePublication($Profile, $Packages) {
    if ($Profile.protected) { throw 'Publication to the canonical instance is not managed here' }
    # 2025 R1 supports /name with a pipe-delimited complete project set and
    # /skipPreviouslyExecutedDbScripts. Omit /merge so omitted projects are unpublished.
    # https://help-2025r1.acumatica.com/Wiki/Print.aspx?PageID=88da87bb-faa2-4bf2-bf83-aa34ff9a9908&wikiname=HelpRoot_Dev_Customization
    if ([version]$Profile.build -lt [version]'25.100.0000') { throw 'Explicit multi-project publication requires 2025 R1 or newer' }
    Assert-Instance $Profile
    $expected = @($Packages | ForEach-Object { $_.name } | Sort-Object)
    $actual = @(Get-Published $Profile)
    if ($expected.Count -eq 0) {
        if ($actual.Count) { throw 'An empty package set is not a clean reset. Restore the baseline checkpoint.' }
        return @{ changed=$false; published=@() }
    }
    # In 25.101.0153 UploadCustomization /replace fails on an existing project
    # (even with a valid File package), and DeleteProject fails too. The first
    # upload works but would leave subsequent desired-set changes unusable.
    if ($Profile.build -ceq '25.101.0153') {
        throw 'Automated publication is unavailable for build 25.101.0153: PX.CommandLine /replace and DeleteProject fail on existing projects. Complete admin onboarding before using the authenticated Customization Web API. Do not delete projects to bypass this guard.'
    }
    $receiptPath = Join-Path $StateRoot ($Profile.id + '.publication.json')
    $fingerprint = Get-PublicationFingerprint $Profile $Packages
    if ((Test-Path $receiptPath) -and -not (Test-Path (Join-Path $StateRoot ($Profile.id + '.blocked')))) {
        $receipt = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json
        if ($receipt.fingerprint -ceq $fingerprint -and $receipt.archiveHash -ceq (Get-PublishedArchiveHash $Profile) -and
            ($expected -join '|') -ceq ($actual -join '|')) {
            return @{ changed=$false; published=$actual }
        }
    }
    $stage = Join-Path $StateRoot ('publish-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $stage | Out-Null
    try {
        foreach ($package in $Packages) {
            if ($package.name -notmatch '^[A-Za-z][A-Za-z0-9_]{0,99}$' -or $package.sha256 -notmatch '^[a-f0-9]{64}$') {
                throw 'Invalid package identity'
            }
            $zip = Join-Path $stage ($package.name + '.zip')
            Copy-Item -LiteralPath $package.guestPath -Destination $zip
            if ((Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash -ine $package.sha256) { throw "Package changed during transfer: $($package.name)" }
        }
        Stop-Instance $Profile
        Set-InstanceBlocked $Profile 'Customization publication in progress or failed; rerun publish or reset a checkpoint.'
        $tool = Join-Path $Profile.path 'Bin\PX.CommandLine.exe'
        foreach ($package in $Packages) {
            Invoke-Native $tool @('/method', 'UploadCustomization', '/website', $Profile.path,
                '/name', $package.name, '/path', (Join-Path $stage ($package.name + '.zip')), '/replace')
        }
        Invoke-Native $tool @('/method', 'PublishCustomization', '/website', $Profile.path,
            '/name', ($expected -join '|'), '/skipPreviouslyExecutedDbScripts')
        $actual = @(Get-Published $Profile)
        if (($expected -join '|') -cne ($actual -join '|')) { throw "Published project set differs from the profile: $($actual -join ', ')" }
        [xml]$status = Get-Content -LiteralPath (Join-Path $Profile.path 'App_Data\CustomizationStatus.xml')
        if ($status.Content.status -ne 'Published') { throw "Customization status is $($status.Content.status), not Published" }
        @{ fingerprint=$fingerprint; archiveHash=(Get-PublishedArchiveHash $Profile) } |
            ConvertTo-Json | Set-Content -LiteralPath $receiptPath -Encoding UTF8
        Clear-InstanceBlocked $Profile
        return @{ changed=$true; published=$actual }
    } finally {
        Remove-Item -LiteralPath $stage -Recurse -Force
    }
}
