# Changelog

### [1.2.0] - 2026-11-01 — Matrix Edition

#### Aggiunto
- Nuova interfaccia **GUI Matrix**: sfondo nero, testo verde, font Consolas, bottoni flat con bordi colorati
- Pulsante **Toggle dinamico** per Attivare/Disattivare la scheda di rete selezionata
  - Etichetta e colore cambiano in base allo stato della scheda (`Up` → rosso "DISATTIVA"; `Disabled`/`Down`/`Disconnected` → verde "ATTIVA"; `Not Present` → grigio disabilitato)
- **Anti-lockout**: avviso di sicurezza se provi a disattivare l'unica scheda connessa a Internet
- **Log a schermo** in tempo reale con timestamp (in aggiunta al file di log)
- **Status bar** in basso con info su scheda selezionata, stato e file di log attivo
- **Filtro schede reali**: mostra solo Ethernet e Wi-Fi (incluse le USB Ethernet)
  - Escluse automaticamente le schede virtuali (VMware, VirtualBox, Hyper-V, TAP, loopback, tunnel, Bluetooth, WAN Miniport)

#### Modificato
- Titolo finestra e header aggiornati a `MATRIX NETADAPTER MANAGER v1.2`
- Gestione degli errori migliorata: messaggi differenziati per "accesso negato", "driver in uso" e "scheda non presente"
- Sostituito `Get-WmiObject` con `Get-CimInstance` (deprecato in PowerShell 7) nel fallback di lettura IP
- Rinominato il file di log da `netadapter_manager_*.log` a `matrix_netadapter_manager_*.log`

#### Corretto
- Le schede in stato `Disabled` ora compaiono nella lista e possono essere riattivate (prima erano filtrate e invisibili)
- Filtro di esclusione delle schede reso più ampio e robusto (esclude esplicitamente virtuali, Bluetooth, WAN Miniport, ecc.)

## [1.1.0] - 2025-01-26

### Fixed
- Subnet mask visualizzata correttamente (era invertita)
- Errore "default gateway esiste già" durante l'applicazione
- Connessione persa dopo l'applicazione di IP statico

### Added
- Separazione tra IP e Gateway (New-NetRoute)
- Rimozione IP vecchi prima di applicare nuovi
- Pulsante RECOVERY per ripristinare l'ultima configurazione
- Log su file con dettagli operazioni

## [1.0.0] - 2025-01-25

### Added
- GUI per gestione schede di rete
- Visualizzazione IP, subnet, gateway, DNS, DHCP
- Passaggio DHCP/statico
- Profili di rete salvabili (JSON)
- Flush DNS, Reload NetBIOS
- Auto-elevazione admin
