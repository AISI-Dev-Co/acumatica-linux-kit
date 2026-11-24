[CmdletBinding()]
param([Parameter(Mandatory)][System.Net.IPAddress]$DockerBridgeGateway)

$ErrorActionPreference = 'Stop'
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (!$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run share setup from the elevated Windows dev account.'
}
if ($DockerBridgeGateway.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
    throw 'The Docker bridge gateway must be IPv4.'
}

$root = 'D:\AcumaticaERP'
$name = 'AcumaticaData'
$account = $identity.Name
$link = Get-Item -LiteralPath 'C:\AcumaticaERP' -Force
if (($link.Target -join ';') -ne $root -or !(Test-Path -LiteralPath "$root\Bin\PX.Data.dll" -PathType Leaf)) {
    throw 'Deploy the canonical Acumatica site to the NTFS data disk before sharing it.'
}
$share = Get-SmbShare -Name $name -ErrorAction SilentlyContinue
if ($share -and $share.Path.TrimEnd('\') -ne $root) {
    throw "$name already points somewhere else. Refusing to replace it."
}

# This is the Windows login used for Linux CIFS, not the IIS identity.
& icacls.exe $root /grant ('{0}:(OI)(CI)M' -f $account)
if ($LASTEXITCODE -ne 0) { throw 'Could not grant NTFS access to the development account.' }
if (!$share) {
    New-SmbShare -Name $name -Path $root -ChangeAccess $account | Out-Null
} else {
    $grant = Get-SmbShareAccess -Name $name | Where-Object {
        $_.AccountName -eq $account -and $_.AccessControlType -eq 'Allow' -and $_.AccessRight -in 'Change','Full'
    }
    if (!$grant) {
        Grant-SmbShareAccess -Name $name -AccountName $account -AccessRight Change -Force | Out-Null
    }
}

$settings = @{
    Name = 'AcumaticaLinuxKit-SMB'
    Enabled = 'True'
    Direction = 'Inbound'
    Action = 'Allow'
    Protocol = 'TCP'
    LocalPort = 445
    RemoteAddress = @('172.30.0.1', $DockerBridgeGateway.ToString()) | Select-Object -Unique
}
if (Get-NetFirewallRule -Name $settings.Name -ErrorAction SilentlyContinue) {
    Set-NetFirewallRule @settings | Out-Null
} else {
    New-NetFirewallRule @settings -DisplayName 'Acumatica dev share from Dockur' | Out-Null
}
Write-Output "SMB share $name configured at $root for $account."
