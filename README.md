# Razer Battery Widget

Mini widget per Windows che mostra la batteria dei dispositivi wireless Razer, sul desktop o come icone nella barra delle applicazioni. **Non serve installare nulla**: usa PowerShell e le API HID già presenti in Windows, quindi funziona anche senza Razer Synapse.

## Funzionalità

- Percentuale di batteria e stato di ricarica per ogni dispositivo Razer collegato
- Tre modalità: widget sul desktop, icone nell'area di notifica, oppure entrambi
- Widget trascinabile, opzione "sempre in primo piano", posizione ricordata
- Aggiornamento automatico ogni minuto
- Supporta sia il protocollo dei mouse Razer (feature report) sia quello delle cuffie BlackShark HyperSpeed

## Dispositivi testati

| Dispositivo | Stato |
|---|---|
| Razer Viper V3 | ✅ funzionante |
| Razer BlackShark V3 HyperSpeed (dongle "BlackShark V2 HS 2.4") | ✅ funzionante |

Altri mouse Razer wireless dovrebbero funzionare, perché usano lo stesso protocollo. Se ne provi uno, apri una issue con l'output della diagnosi.

## Installazione

1. Scarica il repository (pulsante verde **Code → Download ZIP**) ed estrailo in una cartella.
2. Fai doppio clic su `avvia_widget.vbs`.

Per avviarlo automaticamente all'accensione, premi `Win + R`, scrivi `shell:startup` e metti nella cartella che si apre un collegamento a `avvia_widget.vbs`.

## Utilizzo

- **Trascina** il widget con il tasto sinistro per spostarlo.
- **Tasto destro** sul widget o su un'icona per aprire il menu: Aggiorna ora, Mostra come, Sempre in primo piano, Esci.
- **Doppio clic** su un'icona nella barra per aggiornare subito.

Su Windows 11 le icone nuove finiscono spesso nascoste dietro la freccia `^`. Per tenerle visibili: Impostazioni → Personalizzazione → Barra delle applicazioni → Altre icone della barra delle applicazioni → attiva "Windows PowerShell".

## Diagnosi

Se un dispositivo non viene letto, apri PowerShell nella cartella del progetto e lancia:

```powershell
powershell -ExecutionPolicy Bypass -File .\razer_battery_widget.ps1 -Scan
```

Elenca tutte le interfacce HID Razer trovate e il risultato della lettura su ciascuna.

## Come funziona

- **Mouse**: viene inviato un feature report da 90 byte con il protocollo Razer (comando `0x07 0x80` per il livello, `0x07 0x84` per la ricarica). Il transaction ID cambia tra modelli, quindi vengono provati quelli noti.
- **Cuffie**: viene inviato un output report da 64 byte (report ID `0x02`, comandi `0x21` batteria e `0x2A` ricarica) e si attende la risposta tra gli input report.

## Crediti

- Protocollo dei mouse documentato dal progetto [OpenRazer](https://github.com/openrazer/openrazer)
- Protocollo delle cuffie HyperSpeed documentato da [razer-blackshark-v2-hyperspeed-webhid](https://github.com/justik13/razer-blackshark-v2-hyperspeed-webhid)

## Avvertenza

Progetto non ufficiale, non affiliato né approvato da Razer Inc. "Razer" è un marchio dei rispettivi proprietari.

## Licenza

[MIT](LICENSE)
