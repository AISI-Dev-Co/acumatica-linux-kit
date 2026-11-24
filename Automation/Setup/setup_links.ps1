$ErrorActionPreference = 'Stop'
$link = 'C:\Acumatica-ERP'
$target = '\\host.lan\Data'
$existing = Get-Item -LiteralPath $link -Force -ErrorAction SilentlyContinue

if ($existing -and ($existing.LinkType -ne 'SymbolicLink' -or ($existing.Target -join ';').TrimEnd('\') -ine $target)) {
    throw "$link already exists and is not the Dockur workspace link. Refusing to replace it."
}
if (!(Test-Path -LiteralPath "$target\Automation\Setup" -PathType Container)) {
    throw "Cannot reach the kit workspace at $target. Check the Dockur workspace share."
}
if (!$existing) {
    New-Item -ItemType SymbolicLink -Path $link -Target $target | Out-Null
}
if (!(Test-Path -LiteralPath "$link\Automation\Setup" -PathType Container)) {
    throw "$link cannot resolve the kit workspace. Check the share and local-to-remote symbolic link policy."
}
Write-Output "Workspace link verified: $link"
