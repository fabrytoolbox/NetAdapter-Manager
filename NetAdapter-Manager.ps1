# NetAdapter-Manager.ps1
# Gestore avanzato delle schede di rete con GUI Matrix
# Mostra solo schede Ethernet e Wi-Fi reali (incluse USB Ethernet)
# Feature: toggle Attiva/Disattiva scheda + anti-lockout
# Requisiti: PowerShell 7.2+, Windows
# Version: 1.2 (Matrix Edition)

#Requires -Version 7.2
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ============================================================
# AUTO-ELEVAZIONE ADMIN
# ============================================================
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    [System.Windows.Forms.MessageBox]::Show(
        "Richiesta autorizzazione al Nucleo...`n`nRilancio come Amministratore per consentire modifiche di rete.",
        "MATRIX - PRIVILEGI",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information
    ) | Out-Null

    $pwshPath = Join-Path $PSHOME "pwsh.exe"
    if (-not (Test-Path $pwshPath)) { $pwshPath = "pwsh.exe" }
    Start-Process $pwshPath -ArgumentList "-NoProfile -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

# ============================================================
# CARTELLA PROFILI E LOG
# ============================================================
$scriptPath     = Split-Path -Parent $MyInvocation.MyCommand.Definition
$profilesFolder = Join-Path $scriptPath "NetworkProfiles"
if (-not (Test-Path $profilesFolder)) {
    New-Item -ItemType Directory -Path $profilesFolder -Force | Out-Null
}

$script:logFile    = $null
$script:lastConfig = $null

function Start-Log {
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $script:logFile = Join-Path $scriptPath "matrix_netadapter_manager_$timestamp.log"
    @(
        "============================================================",
        " MATRIX NETADAPTER MANAGER v1.2 - LOG",
        "============================================================",
        "Data inizio: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')",
        "PowerShell : $($PSVersionTable.PSVersion)",
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

# ============================================================
# HELPER: CIDR / VALIDAZIONE
# ============================================================
function ConvertFrom-CIDR ([int]$Cidr) {
    if ($Cidr -lt 0 -or $Cidr -gt 32) { return "Invalid" }
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
    $octets = $IP.Trim() -split '\.'
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
    $reconstructed = ConvertFrom-CIDR $cidr
    return ($reconstructed -eq $Mask)
}

# ============================================================
# PROFILI
# ============================================================
function Get-ProfileNames {
    (Get-ChildItem $profilesFolder -Filter "*.json" -File -ErrorAction SilentlyContinue).BaseName | Sort-Object
}

function Save-Profile ($name, $ip, $mask, $gw, $dns1, $dns2) {
    $clean = $name -replace '[^a-zA-Z0-9_.-]', ''
    if (-not $clean) {
        [System.Windows.Forms.MessageBox]::Show("Nome profilo non valido.", "MATRIX - ERRORE", "OK", "Error") | Out-Null
        return
    }
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
        [System.Windows.Forms.MessageBox]::Show("Profilo '$name' salvato.", "MATRIX - OK", "OK", "Information") | Out-Null
        Update-ProfileCombo
    } catch {
        Write-Log "Errore salvataggio profilo: $($_.Exception.Message)" "ERROR"
        [System.Windows.Forms.MessageBox]::Show("Errore salvataggio: $($_.Exception.Message)", "MATRIX - ERRORE", "OK", "Error") | Out-Null
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
        [System.Windows.Forms.MessageBox]::Show("Profilo '$name' eliminato.", "MATRIX - OK", "OK", "Information") | Out-Null
        Update-ProfileCombo
    }
}

function Update-ProfileCombo {
    $global:cmbProfiles.Items.Clear()
    foreach ($n in Get-ProfileNames) { $global:cmbProfiles.Items.Add($n) }
    if ($global:cmbProfiles.Items.Count -gt 0) { $global:cmbProfiles.SelectedIndex = 0 }
}
# ============================================================
# RILEVAMENTO SCHEDE (solo Ethernet e Wi-Fi reali)
# ============================================================
function Get-NetworkAdapters {
    $adapters = @()

    # Esclusioni esplicite: virtuali, Bluetooth, tunnel, loopback, WAN Miniport
    $excludePattern = 'Virtual|VMware|VirtualBox|Hyper-V|TAP-|TAP |Loopback|Tunnel|Pseudo|WAN Miniport|Bluetooth|Microsoft Wi-Fi Direct|Kernel Debug'

    # Whitelist: PhysicalMediaType 802.3 (Ethernet) o Native 802.11 (Wi-Fi)
    # Fallback su InterfaceDescription se PhysicalMediaType non popolato
    $all = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object {
        $_.InterfaceDescription -notmatch $excludePattern -and
        (
            $_.PhysicalMediaType -in @('802.3', 'Native 802.11') -or
            $_.InterfaceDescription -match 'Ethernet|Wi-Fi|Wireless|WLAN|802\.11'
        )
    }

    foreach ($adapter in $all) {
        $ip = "N/A"; $subnet = "N/A"; $gateway = "N/A"; $dhcpServer = "N/A"
        $dns1 = "N/A"; $dns2 = "N/A"; $isDhcp = "No"

        # Se la scheda è Disabled o Not Present, non provare a leggere la configurazione IP
        # (evita l'errore CIM "MSFT_NetIPInterface" quando la scheda è spenta)
        if ($adapter.Status -in @('Disabled', 'Not Present')) {
            $ip = "N/A"; $subnet = "N/A"; $gateway = "N/A"; $dhcpServer = "N/A"
            $dns1 = "N/A"; $dns2 = "N/A"; $isDhcp = "No"
        } else {
            try {
                $cfg = Get-NetIPConfiguration -InterfaceIndex $adapter.IfIndex -ErrorAction Stop
                if ($cfg.IPv4Address) {
                    $ip       = $cfg.IPv4Address.IPAddress
                    $subnet   = $cfg.IPv4Address.PrefixLength
                    $gateway  = $cfg.IPv4DefaultGateway.NextHop ?? "N/A"
                    $isDhcp   = if ($cfg.IPv4Address.Source -eq "Dhcp") { "Sì" } else { "No" }
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
                # Fallback WMI (raro su PS7 ma utile per driver esotici)
                $wmi = Get-CimInstance Win32_NetworkAdapterConfiguration -Filter "Index = '$($adapter.IfIndex)'" -ErrorAction SilentlyContinue
                if ($wmi -and $wmi.IPEnabled) {
                    if ($wmi.IPAddress)        { $ip      = ($wmi.IPAddress | Where-Object { $_ -match '^\d+\.' } | Select-Object -First 1) }
                    if ($wmi.IPSubnet)         { $subnet  = ConvertTo-CIDR ($wmi.IPSubnet | Where-Object { $_ -match '^\d+\.' } | Select-Object -First 1) }
                    if ($wmi.DefaultIPGateway) { $gateway = $wmi.DefaultIPGateway[0] }
                    $isDhcp = if ($wmi.DHCPEnabled) { "Sì" } else { "No" }
                    if ($wmi.DNSServerSearchOrder) {
                        $dns1 = $wmi.DNSServerSearchOrder[0]
                        $dns2 = if ($wmi.DNSServerSearchOrder.Count -gt 1) { $wmi.DNSServerSearchOrder[1] } else { "N/A" }
                    }
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

# ============================================================
# ANTI-LOCKOUT: la scheda è l'unica attiva con gateway?
# ============================================================
function Test-IsOnlyActiveAdapter {
    param([int]$IfIndex)

    $upWithGw = @()
    foreach ($a in (Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' })) {
        try {
            $cfg = Get-NetIPConfiguration -InterfaceIndex $a.IfIndex -ErrorAction Stop
            if ($cfg.IPv4DefaultGateway -and $cfg.IPv4DefaultGateway.NextHop) {
                $upWithGw += $a.IfIndex
            }
        } catch { }
    }
    return ($upWithGw.Count -le 1 -and $upWithGw -contains $IfIndex)
}

# ============================================================
# TOGGLE SCHEDA (Attiva / Disattiva)
# ============================================================
function Toggle-NetAdapter {
    param([int]$IfIndex, [string]$AdapterName, [string]$CurrentStatus)

    $isUp      = ($CurrentStatus -eq 'Up')
    $isPresent = ($CurrentStatus -ne 'Not Present')

    if (-not $isPresent) {
        [System.Windows.Forms.MessageBox]::Show(
            "La scheda '$AdapterName' risulta 'Not Present' e non puo' essere attivata.",
            "MATRIX - NON DISPONIBILE", "OK", "Warning"
        ) | Out-Null
        Write-Log "Toggle rifiutato: scheda Not Present ($AdapterName)" "WARN"
        return
    }

    # --- Conferma con avviso anti-lockout ---
    if ($isUp) {
        $warning = ""
        if (Test-IsOnlyActiveAdapter -IfIndex $IfIndex) {
            $warning = "`n`nATTENZIONE: sembra essere l'UNICA scheda connessa a Internet.`nSe la disattivi, potresti perdere la rete!"
        }
        $msg = "Disattivare la scheda di rete?`n`nNome: $AdapterName`nStato: $CurrentStatus$warning"
        $icon = if ($warning) { [System.Windows.Forms.MessageBoxIcon]::Warning } else { [System.Windows.Forms.MessageBoxIcon]::Question }
    } else {
        $msg  = "Attivare la scheda di rete?`n`nNome: $AdapterName`nStato: $CurrentStatus"
        $icon = [System.Windows.Forms.MessageBoxIcon]::Question
    }

    $resp = [System.Windows.Forms.MessageBox]::Show(
        $msg, "MATRIX - CONFERMA",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        $icon
    )
    if ($resp -ne "Yes") {
        Write-Log "Toggle annullato dall'utente ($AdapterName)" "INFO"
        return
    }

    # --- Esecuzione ---
    $action = if ($isUp) { 'Disable' } else { 'Enable' }
    $verbIt = if ($isUp) { 'Disattivazione' } else { 'Attivazione' }

    try {
        if ($isUp) {
            Disable-NetAdapter -Name $AdapterName -Confirm:$false -ErrorAction Stop
        } else {
            Enable-NetAdapter  -Name $AdapterName -Confirm:$false -ErrorAction Stop
        }
        Write-Log "$verbIt scheda riuscita: $AdapterName" "OK"
        Write-ScreenLog "[$action] $AdapterName - OK" "Lime"

        # Attesa che Windows aggiorni lo stato (2s)
        Start-Sleep -Seconds 2

        [System.Windows.Forms.MessageBox]::Show(
            "$verbIt completata con successo.`n`nScheda: $AdapterName",
            "MATRIX - OK", "OK", "Information"
        ) | Out-Null
    } catch {
        $err = $_.Exception.Message
        Write-Log "ERRORE $action su $AdapterName : $err" "ERROR"
        Write-ScreenLog "[$action] $AdapterName - ERRORE: $err" "Red"

        $hint = ""
        if ($err -match 'access|denied|negato') {
            $hint = "`n`nSuggerimento: verifica privilegi amministratore e che l'antivirus non blocchi il comando."
        } elseif ($err -match 'in use|utilizzat|driver') {
            $hint = "`n`nSuggerimento: il driver potrebbe essere in uso da un'altra applicazione. Riavvia il sistema se persiste."
        }

        [System.Windows.Forms.MessageBox]::Show(
            "Impossibile completare l'operazione.`n`nErrore: $err$hint",
            "MATRIX - ERRORE CRITICO", "OK", "Error"
        ) | Out-Null
    }
    finally {
        # Refresh lista + etichetta pulsante
        if ($global:btnRefresh) { $global:btnRefresh.PerformClick() }
    }
}

# ============================================================
# APPLICA MODIFICHE IP/DNS (invariata rispetto a v1.1)
# ============================================================
function Apply-Changes ($index, $dhcp, $ip, $mask, $gw, $dns1, $dns2) {
    try {
        $currentAdapter = $global:adapters | Where-Object IfIndex -eq $index
        if ($currentAdapter) {
            $script:lastConfig = @{
                IfIndex = $index
                IP      = $currentAdapter.IPAddress
                Subnet  = $currentAdapter.SubnetMask
                Gateway = $currentAdapter.Gateway
                DNS1    = $currentAdapter.DNS1
                DNS2    = $currentAdapter.DNS2
                IsDHCP  = ($currentAdapter.IsDHCP -eq "Sì")
            }
            Write-Log "Configurazione salvata per ripristino (IfIndex=$index)" "INFO"
        }

        Set-DnsClientServerAddress -InterfaceIndex $index -ResetServerAddresses -ErrorAction SilentlyContinue

        if ($dhcp) {
            Set-NetIPInterface -InterfaceIndex $index -Dhcp Enabled -ErrorAction Stop
            Get-NetIPAddress -InterfaceIndex $index -AddressFamily IPv4 |
                Where-Object PrefixOrigin -eq "Manual" |
                Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
            Write-Log "DHCP abilitato su IfIndex=$index" "OK"
            Write-ScreenLog "DHCP abilitato su IfIndex=$index" "Lime"
        } else {
            $cidr = ConvertTo-CIDR $mask
            if ($cidr -eq 0) { throw "Subnet Mask non valida" }

            Write-Log "Rimozione IP esistenti..." "INFO"
            Get-NetIPAddress -InterfaceIndex $index -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue

            Start-Sleep -Milliseconds 500
            New-NetIPAddress -InterfaceIndex $index -IPAddress $ip -PrefixLength $cidr -ErrorAction Stop | Out-Null
            Write-Log "IP statico impostato: $ip/$cidr" "OK"

            if ($gw -and $gw -ne "N/A" -and $gw -ne "") {
                Remove-NetRoute -InterfaceIndex $index -AddressFamily IPv4 -DestinationPrefix "0.0.0.0/0" -Confirm:$false -ErrorAction SilentlyContinue
                New-NetRoute   -InterfaceIndex $index -AddressFamily IPv4 -DestinationPrefix "0.0.0.0/0" -NextHop $gw -ErrorAction SilentlyContinue | Out-Null
                Write-Log "Gateway impostato: $gw" "OK"
            }

            $dns = @()
            if ($dns1 -and $dns1 -ne "N/A" -and $dns1 -ne "") { $dns += $dns1 }
            if ($dns2 -and $dns2 -ne "N/A" -and $dns2 -ne "") { $dns += $dns2 }
            if ($dns.Count -gt 0) {
                Set-DnsClientServerAddress -InterfaceIndex $index -ServerAddresses $dns
                Write-Log "DNS impostati: $($dns -join ', ')" "OK"
            }
        }

        [System.Windows.Forms.MessageBox]::Show(
            "Modifiche applicate con successo.`n`nSe hai perso la connessione, usa RECOVERY per ripristinare.",
            "MATRIX - OK", "OK", "Information"
        ) | Out-Null
        if ($global:btnRefresh) { $global:btnRefresh.PerformClick() }
    } catch {
        Write-Log "Errore applicazione modifiche: $($_.Exception.Message)" "ERROR"
        Write-ScreenLog "ERRORE apply: $($_.Exception.Message)" "Red"
        [System.Windows.Forms.MessageBox]::Show(
            "Errore: $($_.Exception.Message)", "MATRIX - ERRORE", "OK", "Error"
        ) | Out-Null
    }
}
# ============================================================
# INTERFACCIA GRAFICA - MATRIX EDITION
# ============================================================
$form = New-Object System.Windows.Forms.Form
$form.Text            = "MATRIX NETADAPTER MANAGER v1.2"
$form.Size            = New-Object System.Drawing.Size(720, 980)
$form.StartPosition   = "CenterScreen"
$form.FormBorderStyle = "FixedSingle"
$form.MaximizeBox     = $false
$form.BackColor       = [System.Drawing.Color]::Black
$form.ForeColor       = [System.Drawing.Color]::Lime
$form.Font            = New-Object System.Drawing.Font("Consolas", 10)

# --- HEADER ---
$lblTitle = New-Object System.Windows.Forms.Label
$lblTitle.Text      = "MATRIX NETADAPTER MANAGER v1.2"
$lblTitle.ForeColor = [System.Drawing.Color]::Lime
$lblTitle.Font      = New-Object System.Drawing.Font("Consolas", 14, [System.Drawing.FontStyle]::Bold)
$lblTitle.Location  = New-Object System.Drawing.Point(20, 12)
$lblTitle.Size      = New-Object System.Drawing.Size(680, 30)
$form.Controls.Add($lblTitle)

$lblSubtitle = New-Object System.Windows.Forms.Label
$lblSubtitle.Text      = ":: GESTIONE SCHEDE ETHERNET / WI-FI : MATRIX EDITION ::"
$lblSubtitle.ForeColor = [System.Drawing.Color]::FromArgb(0, 180, 0)
$lblSubtitle.Font      = New-Object System.Drawing.Font("Consolas", 9)
$lblSubtitle.Location  = New-Object System.Drawing.Point(20, 42)
$lblSubtitle.Size      = New-Object System.Drawing.Size(680, 18)
$form.Controls.Add($lblSubtitle)

# --- SELEZIONE SCHEDA ---
$lblAdapter = New-Object System.Windows.Forms.Label
$lblAdapter.Text      = "SCHEDA:"
$lblAdapter.ForeColor = [System.Drawing.Color]::Lime
$lblAdapter.Location  = New-Object System.Drawing.Point(20, 72)
$lblAdapter.Size      = New-Object System.Drawing.Size(80, 20)
$form.Controls.Add($lblAdapter)

$global:cmbAdapters = New-Object System.Windows.Forms.ComboBox
$global:cmbAdapters.Location      = New-Object System.Drawing.Point(105, 69)
$global:cmbAdapters.Size          = New-Object System.Drawing.Size(575, 28)
$global:cmbAdapters.DropDownStyle = "DropDownList"
$global:cmbAdapters.Font          = New-Object System.Drawing.Font("Consolas", 10)
$global:cmbAdapters.BackColor     = [System.Drawing.Color]::Black
$global:cmbAdapters.ForeColor     = [System.Drawing.Color]::Lime
$form.Controls.Add($global:cmbAdapters)

# --- PULSANTE TOGGLE (feature principale) ---
$global:btnToggle = New-Object System.Windows.Forms.Button
$global:btnToggle.Text      = "ATTIVA / DISATTIVA"
$global:btnToggle.Location  = New-Object System.Drawing.Point(20, 105)
$global:btnToggle.Size      = New-Object System.Drawing.Size(660, 42)
$global:btnToggle.FlatStyle = "Flat"
$global:btnToggle.Font      = New-Object System.Drawing.Font("Consolas", 12, [System.Drawing.FontStyle]::Bold)
$global:btnToggle.BackColor = [System.Drawing.Color]::Black
$global:btnToggle.ForeColor = [System.Drawing.Color]::Lime
$global:btnToggle.FlatAppearance.BorderColor = [System.Drawing.Color]::Lime
$global:btnToggle.FlatAppearance.BorderSize  = 2
$form.Controls.Add($global:btnToggle)

# --- DETTAGLI E CONFIGURAZIONE ---
$gbDetails = New-Object System.Windows.Forms.GroupBox
$gbDetails.Text      = "[ DETTAGLI E CONFIGURAZIONE ]"
$gbDetails.ForeColor = [System.Drawing.Color]::Lime
$gbDetails.Font      = New-Object System.Drawing.Font("Consolas", 10, [System.Drawing.FontStyle]::Bold)
$gbDetails.Location  = New-Object System.Drawing.Point(20, 158)
$gbDetails.Size      = New-Object System.Drawing.Size(660, 460)
$form.Controls.Add($gbDetails)

$y = 30
$controls = @{}

# Campi sola lettura in alto
@("Descrizione", "Stato", "MACAddress", "VelocitàLink", "ServerDHCP") | ForEach-Object {
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text      = "${_}:"
    $lbl.ForeColor = [System.Drawing.Color]::Lime
    $lbl.Location  = New-Object System.Drawing.Point(20, $y)
    $lbl.AutoSize  = $true
    $gbDetails.Controls.Add($lbl)

    $txt = New-Object System.Windows.Forms.TextBox
    $txt.Location  = New-Object System.Drawing.Point(160, ($y - 3))
    $txt.Size      = New-Object System.Drawing.Size(480, 26)
    $txt.ReadOnly  = $true
    $txt.BackColor = [System.Drawing.Color]::FromArgb(10, 10, 10)
    $txt.ForeColor = [System.Drawing.Color]::Lime
    $txt.BorderStyle = "FixedSingle"
    $gbDetails.Controls.Add($txt)
    $controls["txt$_"] = $txt
    $y += 40
}

# Checkbox DHCP
$global:chkDHCP = New-Object System.Windows.Forms.CheckBox
$global:chkDHCP.Text      = "DHCP (Automatico)"
$global:chkDHCP.ForeColor = [System.Drawing.Color]::Lime
$global:chkDHCP.BackColor = [System.Drawing.Color]::Black
$global:chkDHCP.Location  = New-Object System.Drawing.Point(160, $y)
$global:chkDHCP.AutoSize  = $true
$gbDetails.Controls.Add($global:chkDHCP)
$controls["chkDHCP"] = $global:chkDHCP
$y += 40

# Campi IP / Subnet / GW / DNS
@("IndirizzoIP", "SubnetMask", "Gateway", "DNSPrimario", "DNSSecondario") | ForEach-Object {
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text      = "${_}:"
    $lbl.ForeColor = [System.Drawing.Color]::Lime
    $lbl.Location  = New-Object System.Drawing.Point(20, $y)
    $lbl.AutoSize  = $true
    $gbDetails.Controls.Add($lbl)

    $txt = New-Object System.Windows.Forms.TextBox
    $txt.Location    = New-Object System.Drawing.Point(160, ($y - 3))
    $txt.Size        = New-Object System.Drawing.Size(480, 26)
    $txt.BackColor   = [System.Drawing.Color]::Black
    $txt.ForeColor   = [System.Drawing.Color]::Lime
    $txt.BorderStyle = "FixedSingle"
    $gbDetails.Controls.Add($txt)
    $controls["txt$_"] = $txt
    $y += 40
}

# --- PULSANTI AZIONE (riga 1) ---
$yPos = 628
$global:btnRefresh = New-Object System.Windows.Forms.Button
$global:btnRefresh.Text      = "AGGIORNA"
$global:btnRefresh.Location  = New-Object System.Drawing.Point(20, $yPos)
$global:btnRefresh.Size      = New-Object System.Drawing.Size(150, 40)
$global:btnRefresh.FlatStyle = "Flat"
$global:btnRefresh.BackColor = [System.Drawing.Color]::Black
$global:btnRefresh.ForeColor = [System.Drawing.Color]::Lime
$global:btnRefresh.FlatAppearance.BorderColor = [System.Drawing.Color]::Lime
$global:btnRefresh.Font      = New-Object System.Drawing.Font("Consolas", 10, [System.Drawing.FontStyle]::Bold)
$form.Controls.Add($global:btnRefresh)

$btnApply = New-Object System.Windows.Forms.Button
$btnApply.Text      = "APPLICA"
$btnApply.Location  = New-Object System.Drawing.Point(180, $yPos)
$btnApply.Size      = New-Object System.Drawing.Size(150, 40)
$btnApply.FlatStyle = "Flat"
$btnApply.BackColor = [System.Drawing.Color]::Black
$btnApply.ForeColor = [System.Drawing.Color]::Lime
$btnApply.FlatAppearance.BorderColor = [System.Drawing.Color]::Lime
$btnApply.Font      = New-Object System.Drawing.Font("Consolas", 10, [System.Drawing.FontStyle]::Bold)
$form.Controls.Add($btnApply)

$btnResetDHCP = New-Object System.Windows.Forms.Button
$btnResetDHCP.Text      = "RESET DHCP"
$btnResetDHCP.Location  = New-Object System.Drawing.Point(340, $yPos)
$btnResetDHCP.Size      = New-Object System.Drawing.Size(150, 40)
$btnResetDHCP.FlatStyle = "Flat"
$btnResetDHCP.BackColor = [System.Drawing.Color]::Black
$btnResetDHCP.ForeColor = [System.Drawing.Color]::Yellow
$btnResetDHCP.FlatAppearance.BorderColor = [System.Drawing.Color]::Yellow
$btnResetDHCP.Font      = New-Object System.Drawing.Font("Consolas", 10, [System.Drawing.FontStyle]::Bold)
$form.Controls.Add($btnResetDHCP)

$btnFlushDNS = New-Object System.Windows.Forms.Button
$btnFlushDNS.Text      = "FLUSH DNS"
$btnFlushDNS.Location  = New-Object System.Drawing.Point(500, $yPos)
$btnFlushDNS.Size      = New-Object System.Drawing.Size(180, 40)
$btnFlushDNS.FlatStyle = "Flat"
$btnFlushDNS.BackColor = [System.Drawing.Color]::Black
$btnFlushDNS.ForeColor = [System.Drawing.Color]::Lime
$btnFlushDNS.FlatAppearance.BorderColor = [System.Drawing.Color]::Lime
$btnFlushDNS.Font      = New-Object System.Drawing.Font("Consolas", 10, [System.Drawing.FontStyle]::Bold)
$form.Controls.Add($btnFlushDNS)

# --- Riga 2: NetBIOS + Recovery ---
$btnNetbios = New-Object System.Windows.Forms.Button
$btnNetbios.Text      = "RELOAD NETBIOS"
$btnNetbios.Location  = New-Object System.Drawing.Point(20, 676)
$btnNetbios.Size      = New-Object System.Drawing.Size(200, 35)
$btnNetbios.FlatStyle = "Flat"
$btnNetbios.BackColor = [System.Drawing.Color]::Black
$btnNetbios.ForeColor = [System.Drawing.Color]::Lime
$btnNetbios.FlatAppearance.BorderColor = [System.Drawing.Color]::Lime
$form.Controls.Add($btnNetbios)

$btnRecovery = New-Object System.Windows.Forms.Button
$btnRecovery.Text      = "RECOVERY (ripristina ultima config)"
$btnRecovery.Location  = New-Object System.Drawing.Point(230, 676)
$btnRecovery.Size      = New-Object System.Drawing.Size(450, 35)
$btnRecovery.FlatStyle = "Flat"
$btnRecovery.BackColor = [System.Drawing.Color]::Black
$btnRecovery.ForeColor = [System.Drawing.Color]::Orange
$btnRecovery.FlatAppearance.BorderColor = [System.Drawing.Color]::Orange
$btnRecovery.Font      = New-Object System.Drawing.Font("Consolas", 10, [System.Drawing.FontStyle]::Bold)
$form.Controls.Add($btnRecovery)

# --- PROFILI ---
$gbProfiles = New-Object System.Windows.Forms.GroupBox
$gbProfiles.Text      = "[ PROFILI DI RETE ]"
$gbProfiles.ForeColor = [System.Drawing.Color]::Lime
$gbProfiles.Font      = New-Object System.Drawing.Font("Consolas", 10, [System.Drawing.FontStyle]::Bold)
$gbProfiles.Location  = New-Object System.Drawing.Point(20, 720)
$gbProfiles.Size      = New-Object System.Drawing.Size(660, 90)
$form.Controls.Add($gbProfiles)

$global:cmbProfiles = New-Object System.Windows.Forms.ComboBox
$global:cmbProfiles.Location      = New-Object System.Drawing.Point(15, 32)
$global:cmbProfiles.Size          = New-Object System.Drawing.Size(300, 28)
$global:cmbProfiles.DropDownStyle = "DropDownList"
$global:cmbProfiles.BackColor     = [System.Drawing.Color]::Black
$global:cmbProfiles.ForeColor     = [System.Drawing.Color]::Lime
$gbProfiles.Controls.Add($global:cmbProfiles)

$btnLoad = New-Object System.Windows.Forms.Button
$btnLoad.Text      = "CARICA"
$btnLoad.Location  = New-Object System.Drawing.Point(325, 30)
$btnLoad.Size      = New-Object System.Drawing.Size(100, 32)
$btnLoad.FlatStyle = "Flat"
$btnLoad.BackColor = [System.Drawing.Color]::Black
$btnLoad.ForeColor = [System.Drawing.Color]::Lime
$btnLoad.FlatAppearance.BorderColor = [System.Drawing.Color]::Lime
$gbProfiles.Controls.Add($btnLoad)

$btnSave = New-Object System.Windows.Forms.Button
$btnSave.Text      = "SALVA"
$btnSave.Location  = New-Object System.Drawing.Point(435, 30)
$btnSave.Size      = New-Object System.Drawing.Size(100, 32)
$btnSave.FlatStyle = "Flat"
$btnSave.BackColor = [System.Drawing.Color]::Black
$btnSave.ForeColor = [System.Drawing.Color]::Lime
$btnSave.FlatAppearance.BorderColor = [System.Drawing.Color]::Lime
$gbProfiles.Controls.Add($btnSave)

$btnDelete = New-Object System.Windows.Forms.Button
$btnDelete.Text      = "ELIMINA"
$btnDelete.Location  = New-Object System.Drawing.Point(545, 30)
$btnDelete.Size      = New-Object System.Drawing.Size(100, 32)
$btnDelete.FlatStyle = "Flat"
$btnDelete.BackColor = [System.Drawing.Color]::Black
$btnDelete.ForeColor = [System.Drawing.Color]::Red
$btnDelete.FlatAppearance.BorderColor = [System.Drawing.Color]::Red
$gbProfiles.Controls.Add($btnDelete)

# --- LOG A SCHERMO ---
$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Multiline  = $true
$txtLog.ScrollBars = "Vertical"
$txtLog.ReadOnly   = $true
$txtLog.BackColor  = [System.Drawing.Color]::FromArgb(10, 10, 10)
$txtLog.ForeColor  = [System.Drawing.Color]::Lime
$txtLog.Font       = New-Object System.Drawing.Font("Consolas", 9)
$txtLog.Location   = New-Object System.Drawing.Point(20, 818)
$txtLog.Size       = New-Object System.Drawing.Size(660, 90)
$txtLog.BorderStyle = "FixedSingle"
$form.Controls.Add($txtLog)

function Write-ScreenLog {
    param([string]$Message, [string]$Color = "Lime")
    $timestamp = Get-Date -Format "HH:mm:ss"
    $txtLog.AppendText("[$timestamp] $Message`r`n")
    $txtLog.SelectionStart = $txtLog.Text.Length
    $txtLog.ScrollToCaret()
    Write-Log $Message "INFO"
}

# --- BOTTONE EXIT ---
$btnExit = New-Object System.Windows.Forms.Button
$btnExit.Text      = "EXIT"
$btnExit.Location  = New-Object System.Drawing.Point(560, 912)
$btnExit.Size      = New-Object System.Drawing.Size(120, 30)
$btnExit.FlatStyle = "Flat"
$btnExit.BackColor = [System.Drawing.Color]::Black
$btnExit.ForeColor = [System.Drawing.Color]::Red
$btnExit.FlatAppearance.BorderColor = [System.Drawing.Color]::Red
$btnExit.Font      = New-Object System.Drawing.Font("Consolas", 10, [System.Drawing.FontStyle]::Bold)
$btnExit.Add_Click({ $form.Close() })
$form.Controls.Add($btnExit)

# --- STATUS BAR ---
$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Text      = "> Inizializzazione..."
$lblStatus.ForeColor = [System.Drawing.Color]::FromArgb(0, 200, 0)
$lblStatus.Font      = New-Object System.Drawing.Font("Consolas", 9)
$lblStatus.Location  = New-Object System.Drawing.Point(20, 916)
$lblStatus.Size      = New-Object System.Drawing.Size(530, 20)
$form.Controls.Add($lblStatus)

function Update-StatusBar {
    param([string]$Text)
    $lblStatus.Text = "> $Text"
    $form.Refresh()
}
# ============================================================
# EVENTI - CAMBIO SCHEDA SELEZIONATA
# ============================================================
$global:cmbAdapters.Add_SelectedIndexChanged({
    $adapter = $global:adapters | Where-Object Name -eq $global:cmbAdapters.SelectedItem
    if (-not $adapter) { return }

    # Popola dettagli
    $controls.txtDescrizione.Text  = $adapter.Description
    $controls.txtStato.Text        = $adapter.Status
    $controls.txtMACAddress.Text   = $adapter.MacAddress
    $controls.txtVelocitàLink.Text = $adapter.LinkSpeed
    $controls.txtServerDHCP.Text   = $adapter.DHCPServer
    $global:chkDHCP.Checked        = ($adapter.IsDHCP -eq "Sì")

    $controls.txtIndirizzoIP.Text  = $adapter.IPAddress
    $controls.txtSubnetMask.Text   = if ($adapter.SubnetMask -ne "N/A") { ConvertFrom-CIDR $adapter.SubnetMask } else { "N/A" }
    $controls.txtGateway.Text      = $adapter.Gateway
    $controls.txtDNSPrimario.Text  = $adapter.DNS1
    $controls.txtDNSSecondario.Text= $adapter.DNS2

    # ReadOnly in base a DHCP
    $controls.txtIndirizzoIP.ReadOnly = $global:chkDHCP.Checked
    $controls.txtSubnetMask.ReadOnly  = $global:chkDHCP.Checked
    $controls.txtGateway.ReadOnly     = $global:chkDHCP.Checked

    # ============================================================
    # TOGGLE DINAMICO (feature principale)
    # ============================================================
    $status = $adapter.Status
    switch ($status) {
        'Up' {
            $global:btnToggle.Text      = "⏻  DISATTIVA SCHEDA"
            $global:btnToggle.ForeColor = [System.Drawing.Color]::Red
            $global:btnToggle.FlatAppearance.BorderColor = [System.Drawing.Color]::Red
            $global:btnToggle.Enabled   = $true
        }
        { $_ -in @('Disabled', 'Down', 'Disconnected') } {
            $global:btnToggle.Text      = "⏻  ATTIVA SCHEDA"
            $global:btnToggle.ForeColor = [System.Drawing.Color]::Lime
            $global:btnToggle.FlatAppearance.BorderColor = [System.Drawing.Color]::Lime
            $global:btnToggle.Enabled   = $true
        }
        default {
            # Not Present / Unknown
            $global:btnToggle.Text      = "⏻  NON DISPONIBILE"
            $global:btnToggle.ForeColor = [System.Drawing.Color]::Gray
            $global:btnToggle.FlatAppearance.BorderColor = [System.Drawing.Color]::Gray
            $global:btnToggle.Enabled   = $false
        }
    }

    Update-StatusBar "Scheda: $($adapter.Name) | Stato: $status | IfIndex: $($adapter.IfIndex)"
})

# ============================================================
# EVENTI - CHECKBOX DHCP
# ============================================================
$global:chkDHCP.Add_CheckedChanged({
    $controls.txtIndirizzoIP.ReadOnly = $global:chkDHCP.Checked
    $controls.txtSubnetMask.ReadOnly  = $global:chkDHCP.Checked
    $controls.txtGateway.ReadOnly     = $global:chkDHCP.Checked
})

# ============================================================
# EVENTI - REFRESH
# ============================================================
$global:btnRefresh.Add_Click({
    $global:adapters = Get-NetworkAdapters
    $global:cmbAdapters.Items.Clear()
    foreach ($a in $global:adapters) { $global:cmbAdapters.Items.Add($a.Name) }
    if ($global:cmbAdapters.Items.Count -gt 0) {
        $global:cmbAdapters.SelectedIndex = 0
    } else {
        Update-StatusBar "Nessuna scheda Ethernet/Wi-Fi rilevata."
    }
    Update-ProfileCombo
    Write-Log "Adattatori aggiornati ($($global:adapters.Count) schede)" "INFO"
    Write-ScreenLog "Refresh: $($global:adapters.Count) schede rilevate" "Lime"
    Update-StatusBar "$($global:adapters.Count) schede rilevate. Log: $(Split-Path $script:logFile -Leaf)"
})

# ============================================================
# EVENTI - PULSANTE TOGGLE (Attiva/Disattiva)
# ============================================================
$global:btnToggle.Add_Click({
    $adapter = $global:adapters | Where-Object Name -eq $global:cmbAdapters.SelectedItem
    if (-not $adapter) { return }
    Toggle-NetAdapter -IfIndex $adapter.IfIndex -AdapterName $adapter.Name -CurrentStatus $adapter.Status
})

# ============================================================
# EVENTI - APPLICA
# ============================================================
$btnApply.Add_Click({
    $adapter = $global:adapters | Where-Object Name -eq $global:cmbAdapters.SelectedItem
    if (-not $adapter) { return }

    $ip   = $controls.txtIndirizzoIP.Text
    $mask = $controls.txtSubnetMask.Text
    $gw   = $controls.txtGateway.Text
    $dns1 = $controls.txtDNSPrimario.Text
    $dns2 = $controls.txtDNSSecondario.Text

    # Validazione (se non DHCP)
    if (-not $global:chkDHCP.Checked) {
        if (-not (Test-ValidIP $ip)) {
            [System.Windows.Forms.MessageBox]::Show("IP non valido: $ip", "MATRIX - VALIDAZIONE", "OK", "Warning") | Out-Null
            Write-ScreenLog "Validazione fallita: IP '$ip'" "Red"; return
        }
        if (-not (Test-ValidSubnet $mask)) {
            [System.Windows.Forms.MessageBox]::Show("Subnet non valida: $mask", "MATRIX - VALIDAZIONE", "OK", "Warning") | Out-Null
            Write-ScreenLog "Validazione fallita: Subnet '$mask'" "Red"; return
        }
        if ($gw -and $gw -ne "N/A" -and -not (Test-ValidIP $gw)) {
            [System.Windows.Forms.MessageBox]::Show("Gateway non valido: $gw", "MATRIX - VALIDAZIONE", "OK", "Warning") | Out-Null
            Write-ScreenLog "Validazione fallita: Gateway '$gw'" "Red"; return
        }
        if ($dns1 -and $dns1 -ne "N/A" -and -not (Test-ValidIP $dns1)) {
            [System.Windows.Forms.MessageBox]::Show("DNS1 non valido: $dns1", "MATRIX - VALIDAZIONE", "OK", "Warning") | Out-Null
            Write-ScreenLog "Validazione fallita: DNS1 '$dns1'" "Red"; return
        }
        if ($dns2 -and $dns2 -ne "N/A" -and -not (Test-ValidIP $dns2)) {
            [System.Windows.Forms.MessageBox]::Show("DNS2 non valido: $dns2", "MATRIX - VALIDAZIONE", "OK", "Warning") | Out-Null
            Write-ScreenLog "Validazione fallita: DNS2 '$dns2'" "Red"; return
        }
    }

    # Conferma
    $msg = if ($global:chkDHCP.Checked) {
        "Vuoi passare a DHCP?`n`nLa configurazione statica attuale verra' persa."
    } else {
        "Vuoi applicare questa configurazione?`n`nIP: $ip`nSubnet: $mask`nGateway: $gw`nDNS1: $dns1`nDNS2: $dns2`n`nATTENZIONE: se i parametri sono errati, potresti perdere la connessione.`nUsa RECOVERY per ripristinare."
    }
    $resp = [System.Windows.Forms.MessageBox]::Show($msg, "MATRIX - CONFERMA MODIFICA", "YesNo", "Question")
    if ($resp -ne "Yes") { return }

    Apply-Changes $adapter.IfIndex $global:chkDHCP.Checked $ip $mask $gw $dns1 $dns2
})

# ============================================================
# EVENTI - RESET DHCP
# ============================================================
$btnResetDHCP.Add_Click({
    $adapter = $global:adapters | Where-Object Name -eq $global:cmbAdapters.SelectedItem
    if ($adapter -and [System.Windows.Forms.MessageBox]::Show(
        "Resettare a DHCP?`n`nScheda: $($adapter.Name)",
        "MATRIX - CONFERMA", "YesNo", "Question") -eq "Yes") {
        Apply-Changes $adapter.IfIndex $true $null $null $null $null $null
    }
})

# ============================================================
# EVENTI - FLUSH DNS
# ============================================================
$btnFlushDNS.Add_Click({
    ipconfig /flushdns | Out-Null
    Write-Log "Flush DNS eseguito" "OK"
    Write-ScreenLog "Flush DNS eseguito" "Lime"
    [System.Windows.Forms.MessageBox]::Show("Cache DNS svuotata.", "MATRIX - OK", "OK", "Information") | Out-Null
})

# ============================================================
# EVENTI - RELOAD NETBIOS
# ============================================================
$btnNetbios.Add_Click({
    nbtstat -R | Out-Null
    Write-Log "Reload NetBIOS eseguito" "OK"
    Write-ScreenLog "Reload NetBIOS eseguito" "Lime"
    [System.Windows.Forms.MessageBox]::Show("Cache NetBIOS ricaricata.", "MATRIX - OK", "OK", "Information") | Out-Null
})

# ============================================================
# EVENTI - RECOVERY
# ============================================================
$btnRecovery.Add_Click({
    if (-not $script:lastConfig) {
        [System.Windows.Forms.MessageBox]::Show("Nessuna configurazione da ripristinare.", "MATRIX - RECOVERY", "OK", "Information") | Out-Null
        Write-ScreenLog "Recovery: nessuna config salvata" "Yellow"
        return
    }
    $resp = [System.Windows.Forms.MessageBox]::Show(
        "Ripristinare l'ultima configurazione?`n`n" +
        "IP: $($script:lastConfig.IP)`n" +
        "Subnet: $(ConvertFrom-CIDR $script:lastConfig.Subnet)`n" +
        "Gateway: $($script:lastConfig.Gateway)`n" +
        "DHCP: $($script:lastConfig.IsDHCP)",
        "MATRIX - RECOVERY", "YesNo", "Question"
    )
    if ($resp -ne "Yes") { return }

    try {
        Apply-Changes $script:lastConfig.IfIndex $script:lastConfig.IsDHCP $script:lastConfig.IP $script:lastConfig.Subnet $script:lastConfig.Gateway $script:lastConfig.DNS1 $script:lastConfig.DNS2
        Write-Log "Recovery eseguito" "OK"
        Write-ScreenLog "Recovery completato" "Lime"
    } catch {
        Write-Log "Errore recovery: $($_.Exception.Message)" "ERROR"
        [System.Windows.Forms.MessageBox]::Show("Errore recovery: $($_.Exception.Message)", "MATRIX - ERRORE", "OK", "Error") | Out-Null
    }
})

# ============================================================
# EVENTI - SALVA PROFILO
# ============================================================
$btnSave.Add_Click({
    if ($global:chkDHCP.Checked) {
        [System.Windows.Forms.MessageBox]::Show("Disabilita DHCP per salvare un profilo statico.", "MATRIX - INFO", "OK", "Information") | Out-Null
        return
    }
    $name = [Microsoft.VisualBasic.Interaction]::InputBox("Nome profilo:", "MATRIX - SALVA PROFILO")
    if ($name) {
        Save-Profile $name $controls.txtIndirizzoIP.Text $controls.txtSubnetMask.Text $controls.txtGateway.Text $controls.txtDNSPrimario.Text $controls.txtDNSSecondario.Text
        Write-ScreenLog "Profilo salvato: $name" "Lime"
    }
})

# ============================================================
# EVENTI - CARICA PROFILO
# ============================================================
$btnLoad.Add_Click({
    $name = $global:cmbProfiles.SelectedItem
    if ($name) {
        $p = Load-Profile $name
        if ($p) {
            $global:chkDHCP.Checked        = $false
            $controls.txtIndirizzoIP.Text  = $p.IPAddress
            $controls.txtSubnetMask.Text   = $p.SubnetMask
            $controls.txtGateway.Text      = $p.Gateway
            $controls.txtDNSPrimario.Text  = $p.DNS1
            $controls.txtDNSSecondario.Text= $p.DNS2
            Write-Log "Profilo caricato: $name" "OK"
            Write-ScreenLog "Profilo caricato: $name" "Lime"
            [System.Windows.Forms.MessageBox]::Show("Profilo caricato.", "MATRIX - OK", "OK", "Information") | Out-Null
        }
    }
})

# ============================================================
# EVENTI - ELIMINA PROFILO
# ============================================================
$btnDelete.Add_Click({
    $name = $global:cmbProfiles.SelectedItem
    if ($name -and [System.Windows.Forms.MessageBox]::Show(
        "Eliminare il profilo '$name'?",
        "MATRIX - CONFERMA", "YesNo", "Question") -eq "Yes") {
        Delete-Profile $name
        Write-ScreenLog "Profilo eliminato: $name" "Red"
    }
})

# ============================================================
# AVVIO FORM
# ============================================================
$form.Add_Load({
    Write-ScreenLog "MATRIX NETADAPTER MANAGER v1.2 avviato" "Lime"
    Write-ScreenLog "Log: $(Split-Path $script:logFile -Leaf)" "Cyan"
    Write-ScreenLog "PS: $($PSVersionTable.PSVersion)" "Cyan"
    Update-StatusBar "Inizializzazione..."
    $global:btnRefresh.PerformClick()
    Update-ProfileCombo
    Write-Log "NetAdapter Manager avviato" "INFO"
})

[void]$form.ShowDialog()
