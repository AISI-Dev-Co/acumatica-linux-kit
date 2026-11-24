$log = "\\host.lan\Data\ssh_setup.log"
"Starting SSH Setup..." | Out-File $log
try {
    "Installing OpenSSH Server..." | Out-File $log -Append
    Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0 -ErrorAction Stop

    "Starting Service..." | Out-File $log -Append
    Start-Service sshd
    Set-Service -Name sshd -StartupType 'Automatic'

    "Configuring Firewall..." | Out-File $log -Append
    if (!(Get-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -DisplayName "OpenSSH Server (sshd)" -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22
    }

    "SSH Setup Complete!" | Out-File $log -Append
} catch {
    "ERROR: $($_.Exception.Message)" | Out-File $log -Append
}
