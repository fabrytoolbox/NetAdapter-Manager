# NetAdapter-Manager.ps1 - v1.1
# Gestore avanzato delle schede di rete con GUI
# Con validazione IP, conferma, log, ripristino

#Requires -Version 7.2

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ========================= AUTO-ELEVAZIONE ADMIN =========================
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    [System.Windows.Forms.MessageBox]::Show("Rilancio come Amministratore per consentire modifiche di rete...", "Privilegi", "OK", "Information")
    $pwshPath = Join-Path $PSHOME "pwsh.exe"
    if (-not (Test-Path $pwshPath)) { $pwshPath = "pwsh.exe" }
    Start-Process $pwshPath -ArgumentList "-NoProfile -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

# ========================= CARTELLA PROFILI E LOG =========================
$scriptPath = Split-Path -Parent $MyInvocation.MyCommand.Definition
$profilesFolder = Join-Path $scriptPath "NetworkProfiles"
if (-not (Test-Path $profilesFolder)) { New-Item -ItemType Directory -Path $profilesFolder | Out-Null }

$script:logFile = $null
$script:lastConfig = $null

function Start-Log {
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $script:logFile = Join-Path $scriptPath "netadapter_manager_$timestamp.log"
    @(
        "============================================================",
        " NETADAPTER MANAGER - LOG",
        "============================================================",
        "Data inizio: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')",
        "PS: $($PSVersionTable.PSVersion)",
        "============================================================",
        ""
    ) | Set-Content -Path $script:logFile -Encoding UTF8
}

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    if (-not $script:logFile) { return }
    $line = "[$(Get-Date -Format 'HH:mm:ss')] [$Level] $Message"
    Add-Content -Path $script:logFile -Value $line -Encoding UTF8
}

Start-Log

# ========================= FUNZIONI HELPER =========================
function ConvertFrom-CIDR ([int]$Cidr) {
    if ($Cidr -lt 0 -or $Cidr -gt 32) { return "Invalid" }
    
    # Calcolo robusto della maschera decimale
    $maskBytes = New-Object byte[] 4
    for ($i = 0; $i -lt 4; $i++) {
        if ($Cidr -ge 8) {
            $maskBytes[$i] = 255
            $Cidr -= 8
        } elseif ($Cidr -gt 0) {
            $maskBytes[$i] = 256 - [math]::Pow(2, (8 - $Cidr))
            $Cidr = 0
        } else {
            $maskBytes[$i] = 0
        }
    }
    
    return ([IPAddress]$maskBytes).ToString()
}

function ConvertTo-CIDR ([string]$Mask) {
    try {
        $bytes = ([IPAddress]$Mask).GetAddressBytes()
        $cidr = 0
        foreach ($b in $bytes) {
            for ($i = 7; $i -ge 0; $i--) { if ($b -band (1 -shl $i)) { $cidr++ } else { break } }
        }
        return $cidr
    } catch { return 0 }
}

function Test-ValidIP {
    param([string]$IP)
    if ([string]::IsNullOrWhiteSpace($IP)) { return $false }
    $octets = $IP -split '\.'
    if ($octets.Count -ne 4) { return $false }
    foreach ($o in $octets) {
        if ($o -notmatch '^\d+$') { return $false }
        $n = [int]$o
        if ($n -lt 0 -or $n -gt 255) { return $false }
    }
    return $true
}

function Test-ValidSubnet {
    param([string]$Mask)
    if ([string]::IsNullOrWhiteSpace($Mask)) { return $false }
    if (-not (Test-ValidIP $Mask)) { return $false }
    $cidr = ConvertTo-CIDR $Mask
    if ($cidr -eq 0) { return $false }
    # Verifica che la maschera sia "contigua" (es. 255.255.255.0 valida, 255.0.255.0 non valida)
    $reconstructed = ConvertFrom-CIDR $cidr
    return ($reconstructed -eq $Mask)
}

# ========================= PROFILI =========================
function Get-ProfileNames {
    (Get-ChildItem $profilesFolder -Filter "*.json" -File -ErrorAction SilentlyContinue).BaseName | Sort-Object
}

function Save-Profile ($name, $ip, $mask, $gw, $dns1, $dns2) {
    $clean = $name -replace '[^a-zA-Z0-9_.-]', ''
    if (-not $clean) { [System.Windows.Forms.MessageBox]::Show("Nome profilo non valido.", "Errore", "OK", "Error"); return }
    $path = Join-Path $profilesFolder "$clean.json"
    $data = [pscustomobject]@{
        IPAddress  = $ip
        SubnetMask = $mask
        Gateway    = $gw
        DNS1       = $dns1
        DNS2       = $dns2
    }
    try {
        $data | ConvertTo-Json | Set-Content $path -Encoding UTF8
        Write-Log "Profilo salvato: $clean" "OK"
        [System.Windows.Forms.MessageBox]::Show("Profilo '$name' salvato.", "Successo", "OK", "Information")
        Update-ProfileCombo
    } catch {
        Write-Log "Errore salvataggio profilo: $($_.Exception.Message)" "ERROR"
        [System.Windows.Forms.MessageBox]::Show("Errore salvataggio: $($_.Exception.Message)", "Errore", "OK", "Error")
    }
}

function Load-Profile ($name) {
    $path = Join-Path $profilesFolder "$name.json"
    if (-not (Test-Path $path)) { return $null }
    try { return Get-Content $path -Raw | ConvertFrom-Json } catch { return $null }
}

function Delete-Profile ($name) {
    $path = Join-Path $profilesFolder "$name.json"
    if (Test-Path $path) {
        Remove-Item $path -Force
        Write-Log "Profilo eliminato: $name" "OK"
        [System.Windows.Forms.MessageBox]::Show("Profilo '$name' eliminato.", "Successo", "OK", "Information")
        Update-ProfileCombo
    }
}

function Update-ProfileCombo {
    $global:cmbProfiles.Items.Clear()
    foreach ($n in Get-ProfileNames) { $global:cmbProfiles.Items.Add($n) }
    if ($global:cmbProfiles.Items.Count -gt 0) { $global:cmbProfiles.SelectedIndex = 0 }
}

# ========================= DETTAGLI RETE =========================
function Get-NetworkAdapters {
    $adapters = @()
    $netAdapters = Get-NetAdapter | Where-Object { $_.Status -ne "Disabled" -and $_.InterfaceDescription -notmatch "loopback|tunnel" }

    foreach ($adapter in $netAdapters) {
        $ip = "N/A"; $subnet = "N/A"; $gateway = "N/A"; $dhcpServer = "N/A"
        $dns1 = "N/A"; $dns2 = "N/A"; $isDhcp = "No"

        try {
            $cfg = Get-NetIPConfiguration -InterfaceIndex $adapter.IfIndex -ErrorAction Stop
            if ($cfg.IPv4Address) {
                $ip = $cfg.IPv4Address.IPAddress
                $subnet = $cfg.IPv4Address.PrefixLength
                $gateway = $cfg.IPv4DefaultGateway.NextHop ?? "N/A"
                $isDhcp = if ($cfg.IPv4Address.Source -eq "Dhcp") { "Sì" } else { "No" }
                $dhcpServer = $cfg.DhcpServer ?? "N/A"
            }
            $dnsRaw = Get-DnsClientServerAddress -InterfaceIndex $adapter.IfIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
            if ($dnsRaw) {
                $validDnsEntry = $dnsRaw | Where-Object { $_.ServerAddresses -and $_.ServerAddresses.Count -gt 0 } | Select-Object -First 1
                if ($validDnsEntry) {
                    $servers = $validDnsEntry.ServerAddresses
                    $dns1 = if ($servers.Count -ge 1) { $servers[0] } else { "N/A" }
                    $dns2 = if ($servers.Count -ge 2) { $servers[1] } else { "N/A" }
                }
            }
        } catch {
            $wmi = Get-WmiObject Win32_NetworkAdapterConfiguration -Filter "Index = '$($adapter.IfIndex)'" -ErrorAction SilentlyContinue
            if ($wmi -and $wmi.IPEnabled) {
                if ($wmi.IPAddress) { $ip = $wmi.IPAddress[0] }
                if ($wmi.IPSubnet) { $subnet = ConvertTo-CIDR $wmi.IPSubnet[0] }
                if ($wmi.DefaultIPGateway) { $gateway = $wmi.DefaultIPGateway[0] }
                $isDhcp = if ($wmi.DHCPEnabled) { "Sì" } else { "No" }
                if ($wmi.DNSServerSearchOrder) {
                    $dns1 = $wmi.DNSServerSearchOrder[0]
                    $dns2 = if ($wmi.DNSServerSearchOrder.Count -gt 1) { $wmi.DNSServerSearchOrder[1] } else { "N/A" }
                }
            }
        }

        $adapters += [pscustomobject]@{
            Name        = $adapter.Name
            Description = $adapter.InterfaceDescription
            Status      = $adapter.Status
            MacAddress  = $adapter.MacAddress
            LinkSpeed   = $adapter.LinkSpeed
            IfIndex     = $adapter.IfIndex
            IPAddress   = $ip
            SubnetMask  = $subnet
            Gateway     = $gateway
            DHCPServer  = $dhcpServer
            DNS1        = $dns1
            DNS2        = $dns2
            IsDHCP      = $isDhcp
        }
    }
    return $adapters
}

# ========================= APPLICA MODIFICHE =========================
function Apply-Changes ($index, $dhcp, $ip, $mask, $gw, $dns1, $dns2) {
    try {
        # Salva configurazione attuale per ripristino
        $currentAdapter = $global:adapters | Where-Object IfIndex -eq $index
        if ($currentAdapter) {
            $script:lastConfig = @{
                IfIndex = $index
                IP = $currentAdapter.IPAddress
                Subnet = $currentAdapter.SubnetMask
                Gateway = $currentAdapter.Gateway
                DNS1 = $currentAdapter.DNS1
                DNS2 = $currentAdapter.DNS2
                IsDHCP = ($currentAdapter.IsDHCP -eq "Sì")
            }
            Write-Log "Configurazione salvata per ripristino (IfIndex=$index)" "INFO"
        }

        Set-DnsClientServerAddress -InterfaceIndex $index -ResetServerAddresses -ErrorAction SilentlyContinue

        if ($dhcp) {
            Set-NetIPInterface -InterfaceIndex $index -Dhcp Enabled -ErrorAction Stop
            Get-NetIPAddress -InterfaceIndex $index -AddressFamily IPv4 | Where-Object PrefixOrigin -eq "Manual" | Remove-NetIPAddress -Confirm:$false
            Write-Log "DHCP abilitato su IfIndex=$index" "OK"
        } else {
            $cidr = ConvertTo-CIDR $mask
            if ($cidr -eq 0) { throw "Subnet Mask non valida" }
            
            # 1. Rimuovi tutti gli IP esistenti su questa scheda
            Write-Log "Rimozione IP esistenti..." "INFO"
            Get-NetIPAddress -InterfaceIndex $index -AddressFamily IPv4 -ErrorAction SilentlyContinue | 
                Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
            
            # 2. Aggiungi il nuovo IP (SENZA gateway!)
            Start-Sleep -Milliseconds 500
            New-NetIPAddress -InterfaceIndex $index -IPAddress $ip -PrefixLength $cidr -ErrorAction Stop | Out-Null
            Write-Log "IP statico impostato: $ip/$cidr" "OK"
            
            # 3. Imposta il Gateway (solo se specificato)
            if ($gw -and $gw -ne "N/A" -and $gw -ne "") {
                # Rimuovi eventuali rotte predefinite esistenti
                Remove-NetRoute -InterfaceIndex $index -AddressFamily IPv4 -DestinationPrefix "0.0.0.0/0" -Confirm:$false -ErrorAction SilentlyContinue
                # Aggiungi la nuova rotta predefinita
                New-NetRoute -InterfaceIndex $index -AddressFamily IPv4 -DestinationPrefix "0.0.0.0/0" -NextHop $gw -ErrorAction SilentlyContinue | Out-Null
                Write-Log "Gateway impostato: $gw" "OK"
            }

            # 4. DNS
            $dns = @()
            if ($dns1 -and $dns1 -ne "N/A" -and $dns1 -ne "") { $dns += $dns1 }
            if ($dns2 -and $dns2 -ne "N/A" -and $dns2 -ne "") { $dns += $dns2 }
            if ($dns.Count -gt 0) {
                Set-DnsClientServerAddress -InterfaceIndex $index -ServerAddresses $dns
                Write-Log "DNS impostati: $($dns -join ', ')" "OK"
            }
        }

        [System.Windows.Forms.MessageBox]::Show("Modifiche applicate con successo.`n`nSe hai perso la connessione, usa RECOVERY per ripristinare.", "Successo", "OK", "Information")
        $global:btnRefresh.PerformClick()
    } catch {
        Write-Log "Errore applicazione modifiche: $($_.Exception.Message)" "ERROR"
        [System.Windows.Forms.MessageBox]::Show("Errore: $($_.Exception.Message)", "Errore", "OK", "Error")
    }
}

# ========================= GUI =========================
$form = New-Object System.Windows.Forms.Form
$form.Text = "Network Adapter Manager v1.1"
$form.Size = New-Object System.Drawing.Size(720, 920)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = "FixedSingle"
$form.MaximizeBox = $false
$form.BackColor = [System.Drawing.Color]::FromArgb(240, 240, 245)

# Selezione scheda
$lblAdapter = New-Object System.Windows.Forms.Label
$lblAdapter.Text = "Scheda di rete:"
$lblAdapter.Location = New-Object System.Drawing.Point(20, 20)
$lblAdapter.Font = New-Object System.Drawing.Font("Segoe UI", 10)
$form.Controls.Add($lblAdapter)

$global:cmbAdapters = New-Object System.Windows.Forms.ComboBox
$global:cmbAdapters.Location = New-Object System.Drawing.Point(20, 50)
$global:cmbAdapters.Size = New-Object System.Drawing.Size(660, 30)
$global:cmbAdapters.DropDownStyle = "DropDownList"
$global:cmbAdapters.Font = New-Object System.Drawing.Font("Segoe UI", 10)
$form.Controls.Add($global:cmbAdapters)

# Dettagli
$gbDetails = New-Object System.Windows.Forms.GroupBox
$gbDetails.Text = "Dettagli e Configurazione"
$gbDetails.Location = New-Object System.Drawing.Point(20, 90)
$gbDetails.Size = New-Object System.Drawing.Size(660, 460)
$form.Controls.Add($gbDetails)

$y = 30
$controls = @{}

@("Descrizione", "Stato", "MACAddress", "VelocitàLink", "ServerDHCP") | ForEach-Object {
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = "${_}:"
    $lbl.Location = New-Object System.Drawing.Point(20, $y)
    $lbl.AutoSize = $true
    $gbDetails.Controls.Add($lbl)
    $txt = New-Object System.Windows.Forms.TextBox
    $txt.Location = New-Object System.Drawing.Point(160, ($y - 3))
    $txt.Size = New-Object System.Drawing.Size(460, 28)
    $txt.ReadOnly = $true
    $gbDetails.Controls.Add($txt)
    $controls["txt$_"] = $txt
    $y += 40
}

$global:chkDHCP = New-Object System.Windows.Forms.CheckBox
$global:chkDHCP.Text = "DHCP (Automatico)"
$global:chkDHCP.Location = New-Object System.Drawing.Point(160, $y)
$global:chkDHCP.AutoSize = $true
$gbDetails.Controls.Add($global:chkDHCP)
$controls["chkDHCP"] = $global:chkDHCP
$y += 40

@("IndirizzoIP", "SubnetMask", "Gateway", "DNSPrimario", "DNSSecondario") | ForEach-Object {
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = "${_}:"
    $lbl.Location = New-Object System.Drawing.Point(20, $y)
    $lbl.AutoSize = $true
    $gbDetails.Controls.Add($lbl)
    $txt = New-Object System.Windows.Forms.TextBox
    $txt.Location = New-Object System.Drawing.Point(160, ($y - 3))
    $txt.Size = New-Object System.Drawing.Size(460, 28)
    $gbDetails.Controls.Add($txt)
    $controls["txt$_"] = $txt
    $y += 40
}

# Pulsanti azione
$yPos = 570
$global:btnRefresh = New-Object System.Windows.Forms.Button
$global:btnRefresh.Text = "Aggiorna"
$global:btnRefresh.Location = New-Object System.Drawing.Point(20, $yPos)
$global:btnRefresh.Size = New-Object System.Drawing.Size(130, 40)
$global:btnRefresh.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 215)
$global:btnRefresh.ForeColor = "White"
$global:btnRefresh.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$form.Controls.Add($global:btnRefresh)

$btnApply = New-Object System.Windows.Forms.Button
$btnApply.Text = "Applica"
$btnApply.Location = New-Object System.Drawing.Point(160, $yPos)
$btnApply.Size = New-Object System.Drawing.Size(130, 40)
$btnApply.BackColor = [System.Drawing.Color]::FromArgb(0, 170, 0)
$btnApply.ForeColor = "White"
$btnApply.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$form.Controls.Add($btnApply)

$btnResetDHCP = New-Object System.Windows.Forms.Button
$btnResetDHCP.Text = "Reset DHCP"
$btnResetDHCP.Location = New-Object System.Drawing.Point(300, $yPos)
$btnResetDHCP.Size = New-Object System.Drawing.Size(130, 40)
$btnResetDHCP.BackColor = [System.Drawing.Color]::FromArgb(220, 50, 50)
$btnResetDHCP.ForeColor = "White"
$btnResetDHCP.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$form.Controls.Add($btnResetDHCP)

$btnFlushDNS = New-Object System.Windows.Forms.Button
$btnFlushDNS.Text = "Flush DNS"
$btnFlushDNS.Location = New-Object System.Drawing.Point(440, $yPos)
$btnFlushDNS.Size = New-Object System.Drawing.Size(120, 40)
$btnFlushDNS.BackColor = [System.Drawing.Color]::FromArgb(100, 100, 100)
$btnFlushDNS.ForeColor = "White"
$form.Controls.Add($btnFlushDNS)

$btnNetbios = New-Object System.Windows.Forms.Button
$btnNetbios.Text = "Reload NetBIOS"
$btnNetbios.Location = New-Object System.Drawing.Point(570, $yPos)
$btnNetbios.Size = New-Object System.Drawing.Size(110, 40)
$btnNetbios.BackColor = [System.Drawing.Color]::FromArgb(100, 100, 100)
$btnNetbios.ForeColor = "White"
$form.Controls.Add($btnNetbios)

# Recovery
$btnRecovery = New-Object System.Windows.Forms.Button
$btnRecovery.Text = "RECOVERY (ripristina ultima config)"
$btnRecovery.Location = New-Object System.Drawing.Point(20, 620)
$btnRecovery.Size = New-Object System.Drawing.Size(660, 35)
$btnRecovery.BackColor = [System.Drawing.Color]::FromArgb(180, 100, 0)
$btnRecovery.ForeColor = "White"
$btnRecovery.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$form.Controls.Add($btnRecovery)

# Profili
$gbProfiles = New-Object System.Windows.Forms.GroupBox
$gbProfiles.Text = "Profili di Rete"
$gbProfiles.Location = New-Object System.Drawing.Point(20, 670)
$gbProfiles.Size = New-Object System.Drawing.Size(660, 100)
$form.Controls.Add($gbProfiles)

$global:cmbProfiles = New-Object System.Windows.Forms.ComboBox
$global:cmbProfiles.Location = New-Object System.Drawing.Point(20, 30)
$global:cmbProfiles.Size = New-Object System.Drawing.Size(300, 30)
$global:cmbProfiles.DropDownStyle = "DropDownList"
$gbProfiles.Controls.Add($global:cmbProfiles)

$btnLoad = New-Object System.Windows.Forms.Button
$btnLoad.Text = "Carica"
$btnLoad.Location = New-Object System.Drawing.Point(330, 28)
$btnLoad.Size = New-Object System.Drawing.Size(90, 35)
$gbProfiles.Controls.Add($btnLoad)

$btnSave = New-Object System.Windows.Forms.Button
$btnSave.Text = "Salva"
$btnSave.Location = New-Object System.Drawing.Point(430, 28)
$btnSave.Size = New-Object System.Drawing.Size(90, 35)
$gbProfiles.Controls.Add($btnSave)

$btnDelete = New-Object System.Windows.Forms.Button
$btnDelete.Text = "Elimina"
$btnDelete.Location = New-Object System.Drawing.Point(530, 28)
$btnDelete.Size = New-Object System.Drawing.Size(90, 35)
$gbProfiles.Controls.Add($btnDelete)

# Exit
$btnExit = New-Object System.Windows.Forms.Button
$btnExit.Text = "Exit"
$btnExit.Location = New-Object System.Drawing.Point(570, 790)
$btnExit.Size = New-Object System.Drawing.Size(110, 40)
$btnExit.BackColor = [System.Drawing.Color]::FromArgb(150, 0, 0)
$btnExit.ForeColor = "White"
$btnExit.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$btnExit.Add_Click({ $form.Close() })
$form.Controls.Add($btnExit)

# ========================= EVENTI =========================
$global:cmbAdapters.Add_SelectedIndexChanged({
    $adapter = $global:adapters | Where-Object Name -eq $global:cmbAdapters.SelectedItem
    if ($adapter) {
        $controls.txtDescrizione.Text = $adapter.Description
        $controls.txtStato.Text = $adapter.Status
        $controls.txtMACAddress.Text = $adapter.MacAddress
        $controls.txtVelocitàLink.Text = $adapter.LinkSpeed
        $controls.txtServerDHCP.Text = $adapter.DHCPServer
        $global:chkDHCP.Checked = $adapter.IsDHCP -eq "Sì"
        $controls.txtIndirizzoIP.Text = $adapter.IPAddress
        $controls.txtSubnetMask.Text = if ($adapter.SubnetMask -ne "N/A") { ConvertFrom-CIDR $adapter.SubnetMask } else { "N/A" }
        $controls.txtGateway.Text = $adapter.Gateway
        $controls.txtDNSPrimario.Text = $adapter.DNS1
        $controls.txtDNSSecondario.Text = $adapter.DNS2
        $controls.txtIndirizzoIP.ReadOnly = $global:chkDHCP.Checked
        $controls.txtSubnetMask.ReadOnly = $global:chkDHCP.Checked
        $controls.txtGateway.ReadOnly = $global:chkDHCP.Checked
    }
})

$global:chkDHCP.Add_CheckedChanged({
    $controls.txtIndirizzoIP.ReadOnly = $global:chkDHCP.Checked
    $controls.txtSubnetMask.ReadOnly = $global:chkDHCP.Checked
    $controls.txtGateway.ReadOnly = $global:chkDHCP.Checked
})

$global:btnRefresh.Add_Click({
    $global:adapters = Get-NetworkAdapters
    $global:cmbAdapters.Items.Clear()
    foreach ($a in $global:adapters) { $global:cmbAdapters.Items.Add($a.Name) }
    if ($global:cmbAdapters.Items.Count -gt 0) { $global:cmbAdapters.SelectedIndex = 0 }
    Update-ProfileCombo
    Write-Log "Adattatori aggiornati ($($global:adapters.Count) schede)" "INFO"
})

$btnApply.Add_Click({
    $adapter = $global:adapters | Where-Object Name -eq $global:cmbAdapters.SelectedItem
    if (-not $adapter) { return }
    
    $ip = $controls.txtIndirizzoIP.Text
    $mask = $controls.txtSubnetMask.Text
    $gw = $controls.txtGateway.Text
    $dns1 = $controls.txtDNSPrimario.Text
    $dns2 = $controls.txtDNSSecondario.Text
    
    # Validazione (se non DHCP)
    if (-not $global:chkDHCP.Checked) {
        if (-not (Test-ValidIP $ip)) {
            [System.Windows.Forms.MessageBox]::Show("IP non valido: $ip", "Validazione", "OK", "Warning")
            return
        }
        if (-not (Test-ValidSubnet $mask)) {
            [System.Windows.Forms.MessageBox]::Show("Subnet non valida: $mask", "Validazione", "OK", "Warning")
            return
        }
        if ($gw -and $gw -ne "N/A" -and -not (Test-ValidIP $gw)) {
            [System.Windows.Forms.MessageBox]::Show("Gateway non valido: $gw", "Validazione", "OK", "Warning")
            return
        }
        if ($dns1 -and $dns1 -ne "N/A" -and -not (Test-ValidIP $dns1)) {
            [System.Windows.Forms.MessageBox]::Show("DNS1 non valido: $dns1", "Validazione", "OK", "Warning")
            return
        }
        if ($dns2 -and $dns2 -ne "N/A" -and -not (Test-ValidIP $dns2)) {
            [System.Windows.Forms.MessageBox]::Show("DNS2 non valido: $dns2", "Validazione", "OK", "Warning")
            return
        }
    }
    
    # Conferma
    $msg = if ($global:chkDHCP.Checked) {
        "Vuoi passare a DHCP?`n`nLa configurazione statica attuale verra' persa."
    } else {
        "Vuoi applicare questa configurazione?`n`nIP: $ip`nSubnet: $mask`nGateway: $gw`nDNS1: $dns1`nDNS2: $dns2`n`nATTENZIONE: se i parametri sono errati, potresti perdere la connessione.`nUsa RECOVERY per ripristinare."
    }
    $resp = [System.Windows.Forms.MessageBox]::Show($msg, "Conferma modifica", "YesNo", "Question")
    if ($resp -ne "Yes") { return }
    
    Apply-Changes $adapter.IfIndex $global:chkDHCP.Checked $ip $mask $gw $dns1 $dns2
})

$btnResetDHCP.Add_Click({
    $adapter = $global:adapters | Where-Object Name -eq $global:cmbAdapters.SelectedItem
    if ($adapter -and [System.Windows.Forms.MessageBox]::Show("Resettare a DHCP?", "Conferma", "YesNo", "Question") -eq "Yes") {
        Apply-Changes $adapter.IfIndex $true $null $null $null $null $null
    }
})

$btnFlushDNS.Add_Click({
    ipconfig /flushdns | Out-Null
    Write-Log "Flush DNS eseguito" "OK"
    [System.Windows.Forms.MessageBox]::Show("Cache DNS svuotata.", "Successo", "OK", "Information")
})

$btnNetbios.Add_Click({
    nbtstat -R | Out-Null
    Write-Log "Reload NetBIOS eseguito" "OK"
    [System.Windows.Forms.MessageBox]::Show("Cache NetBIOS ricaricata.", "Successo", "OK", "Information")
})

$btnRecovery.Add_Click({
    if (-not $script:lastConfig) {
        [System.Windows.Forms.MessageBox]::Show("Nessuna configurazione da ripristinare.", "Recovery", "OK", "Information")
        return
    }
    $resp = [System.Windows.Forms.MessageBox]::Show(
        "Ripristinare l'ultima configurazione?`n`n" +
        "IP: $($script:lastConfig.IP)`n" +
        "Subnet: $(ConvertFrom-CIDR $script:lastConfig.Subnet)`n" +
        "Gateway: $($script:lastConfig.Gateway)`n" +
        "DHCP: $($script:lastConfig.IsDHCP)",
        "Recovery", "YesNo", "Question"
    )
    if ($resp -ne "Yes") { return }
    
    try {
        Apply-Changes $script:lastConfig.IfIndex $script:lastConfig.IsDHCP $script:lastConfig.IP $script:lastConfig.Subnet $script:lastConfig.Gateway $script:lastConfig.DNS1 $script:lastConfig.DNS2
        Write-Log "Recovery eseguito" "OK"
    } catch {
        Write-Log "Errore recovery: $($_.Exception.Message)" "ERROR"
        [System.Windows.Forms.MessageBox]::Show("Errore recovery: $($_.Exception.Message)", "Errore", "OK", "Error")
    }
})

$btnSave.Add_Click({
    if ($global:chkDHCP.Checked) {
        [System.Windows.Forms.MessageBox]::Show("Disabilita DHCP per salvare un profilo statico.", "Info", "OK", "Information")
        return
    }
    $name = [Microsoft.VisualBasic.Interaction]::InputBox("Nome profilo:", "Salva Profilo")
    if ($name) {
        Save-Profile $name $controls.txtIndirizzoIP.Text $controls.txtSubnetMask.Text $controls.txtGateway.Text $controls.txtDNSPrimario.Text $controls.txtDNSSecondario.Text
    }
})

$btnLoad.Add_Click({
    $name = $global:cmbProfiles.SelectedItem
    if ($name) {
        $p = Load-Profile $name
        if ($p) {
            $global:chkDHCP.Checked = $false
            $controls.txtIndirizzoIP.Text = $p.IPAddress
            $controls.txtSubnetMask.Text = $p.SubnetMask
            $controls.txtGateway.Text = $p.Gateway
            $controls.txtDNSPrimario.Text = $p.DNS1
            $controls.txtDNSSecondario.Text = $p.DNS2
            Write-Log "Profilo caricato: $name" "OK"
            [System.Windows.Forms.MessageBox]::Show("Profilo caricato.", "Successo", "OK", "Information")
        }
    }
})

$btnDelete.Add_Click({
    $name = $global:cmbProfiles.SelectedItem
    if ($name -and [System.Windows.Forms.MessageBox]::Show("Eliminare '$name'?", "Conferma", "YesNo", "Question") -eq "Yes") {
        Delete-Profile $name
    }
})

# ========================= AVVIO =========================
$form.Add_Load({
    $global:btnRefresh.PerformClick()
    Update-ProfileCombo
    Write-Log "NetAdapter Manager avviato" "INFO"
})
[void]$form.ShowDialog()
