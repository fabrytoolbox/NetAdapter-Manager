# Changelog

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
