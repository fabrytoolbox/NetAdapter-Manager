# 🖧 NetAdapter Manager

Gestione avanzata delle schede di rete su Windows con GUI: IP, subnet, gateway, DNS, DHCP e profili.

## ✨ Feature

- ✅ **Visualizzazione** dettagliata delle schede di rete
- ✅ **Passaggio DHCP ↔ IP statico**
- ✅ **Modifica IP, subnet, gateway, DNS** con validazione
- ✅ **Conferma** prima di applicare (evita di perdere la connessione per errori)
- ✅ **RECOVERY**: ripristina l'ultima configurazione applicata
- ✅ **Profili di rete** salvabili (JSON)
- ✅ **Flush DNS** e **Reload NetBIOS**
- ✅ **Log su file** con dettagli
- ✅ **Auto-elevazione admin** (UAC)

## 📋 Requisiti

- **Windows 10 / 11**
- **PowerShell 7+** (scarica da https://aka.ms/powershell)
- **Permessi di amministratore** (per modificare le schede di rete)

## 🚀 Quick start

```powershell
git clone https://github.com/fabrytoolbox/NetAdapter-Manager.git
cd NetAdapter-Manager
Unblock-File .\NetAdapter-Manager.ps1
.\NetAdapter-Manager.ps1

Oppure doppio click su avvia.bat.

🎯 Casi d'uso
Configurare IP statico su una scheda di rete (server, NAS, stampanti)

Tornare a DHCP dopo configurazione statica

Salvare profili per reti diverse (casa, ufficio, VPN)

Diagnosticare problemi di rete (gateway, DNS)

Ripristinare la configurazione in caso di errore

🛡️ Sicurezza
Validazione di IP, subnet e gateway prima di applicare

Conferma prima di ogni modifica (evita errori irreversibili)

RECOVERY per ripristinare la configurazione precedente

Log di ogni operazione

Auto-elevazione admin (UAC)

⚠️ Attenzione
Questo tool modifica la configurazione di rete del sistema. Se applichi un IP o un gateway errato, potresti perdere la connessione.

Usa RECOVERY per ripristinare l'ultima configurazione

In caso di problemi, riavvia il PC o usa la GUI di Windows per riconnetterti

Fai un backup dei profili esistenti prima di modifiche importanti

🐛 Problemi comuni
"Il gateway esiste già"
Risolto nella v1.1: ora IP e gateway vengono applicati separatamente.

"Ho perso la connessione dopo aver applicato"
Usa RECOVERY (pulsante arancione) per ripristinare l'ultima configurazione.

"PowerShell 7 non trovato"
Installa PowerShell 7 da https://aka.ms/powershell

📜 Licenza
MIT (vedi LICENSE).

🙏 Crediti
Ispirato al tema Matrix (colori)

PowerShell 7 + WinForms

Fabry Toolbox