#Requires -RunAsAdministrator

$ErrorActionPreference = 'Stop'
$capability = 'OpenSSH.Server~~~~0.0.1.0'
$logDir = Join-Path $env:ProgramData 'AcumaticaLinuxKit'
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
Start-Transcript -Path (Join-Path $logDir 'openssh-bootstrap.log') -Append | Out-Null

try {
    if ((Get-WindowsCapability -Online -Name $capability).State -ne 'Installed') {
        $install = Add-WindowsCapability -Online -Name $capability
        if ($install.RestartNeeded) {
            throw 'OpenSSH requires a restart. Restart Windows and rerun this script.'
        }
    }

    Set-Service -Name sshd -StartupType Automatic
    if ((Get-Service -Name sshd).Status -ne 'Running') { Start-Service -Name sshd }

    $rule = 'OpenSSH-Server-In-TCP'
    if (Get-NetFirewallRule -Name $rule -ErrorAction SilentlyContinue) {
        Enable-NetFirewallRule -Name $rule
    } else {
        $settings = @{
            Name = $rule
            DisplayName = 'OpenSSH Server (sshd)'
            Enabled = 'True'
            Direction = 'Inbound'
            Protocol = 'TCP'
            Action = 'Allow'
            LocalPort = 22
        }
        New-NetFirewallRule @settings | Out-Null
    }

    if ((Get-Service -Name sshd).Status -ne 'Running') { throw 'OpenSSH service did not start.' }
    Write-Output 'OpenSSH Server is running.'
} finally {
    Stop-Transcript | Out-Null
}
