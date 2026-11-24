$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'publication.ps1')
$StateRoot = $PSScriptRoot

function Assert-Instance($Profile) { }
function Get-Published($Profile) { return $script:published }
function Get-PublicationFingerprint($Profile, $Packages) { throw 'Reached publication effects' }

function Assert-PublicationFailure($Profile, $Packages, [string]$Message) {
    try { Invoke-InstancePublication $Profile $Packages | Out-Null }
    catch {
        if ($_.Exception.Message -notmatch $Message) { throw }
        return
    }
    throw "Expected publication failure: $Message"
}

$profile = @{ id='clean25'; build='25.101.0153'; protected=$false }
$script:published = @()
$result = Invoke-InstancePublication $profile @()
if ($result.changed -or @($result.published).Count) { throw 'Empty 25R1 baseline must remain a no-op' }

$script:published = @('CreatorBaseA')
Assert-PublicationFailure $profile @() 'empty package set is not a clean reset'
Assert-PublicationFailure $profile @(@{ name='CreatorBaseA' }) 'Automated publication is unavailable'

# A nonempty 26R1 request must still reach its existing publication path.
$profile.build = '26.101.0225'
Assert-PublicationFailure $profile @(@{ name='CreatorBaseA' }) 'Reached publication effects'
Write-Output 'Publication release boundary and pre-mutation guard passed.'
