# Prove di IsoLR sui computer degli altri

Su quali computer proviamo IsoLR, perché, e cosa si può provare sulle macchine di GitHub e cosa solo a mano.
Aggiornato il 4 novembre 2026. Le prove a mano, da fare con parenti e amici, sono in [PROVE-A-MANO.md](PROVE-A-MANO.md).

## 1. Quali computer usa la gente (dati)

> **Attenzione:** da questa sessione `gs.statcounter.com` non era raggiungibile, perché la rete la blocca.
> I numeri di StatCounter qui sotto vengono dalle copie delle pagine nei motori di ricerca, di **giugno–settembre 2026**.
> Sono ordini di grandezza, non valori da citare.
> Il mese di **ottobre 2026 non è stato letto**. Per rifare la tabella con i CSV veri si deve permettere `gs.statcounter.com` nelle impostazioni di rete dell'ambiente.

| Cosa | Italia | Europa | Fonte e mese |
|---|---|---|---|
| Windows sul totale dei computer | circa 79% (set.); tra il 60 e il 68% in estate | — | gs.statcounter.com/os-market-share/desktop/italy, giu.–set. 2026 |
| Mac sul totale dei computer | circa 15–25% | — | stessa fonte |
| Windows 11 tra i PC Windows | circa 71% | circa 73% | gs.statcounter.com/windows-version-market-share/desktop/{italy,europe}, lug. 2026 |
| Windows 10 tra i PC Windows | circa 27% | circa 26% | stessa fonte |
| Mac Apple Silicon tra i Mac | circa 82–86% (dato mondiale) | — | Steam Hardware Survey, dic. 2025 e apr./mag. 2026 |
| Mac Intel tra i Mac | circa 14–18% (dato mondiale) | — | stessa fonte |
| macOS 26 tra i Mac | la versione più usata (circa 47% per la 26.4, ad aprile) | — | TelemetryDeck, apr. 2026 |
| macOS 15 tra i Mac | la seconda versione più usata | — | stessa fonte |
| Schermo 1920×1080 | circa 20–30% | circa 23–28% | gs.statcounter.com/screen-resolution-stats, giu.–lug. 2026 |
| Schermo 1536×864 (cioè 1920×1080 al 125%) | circa 12% | circa 10% | stessa fonte |
| Schermo 1366×768 | circa 8% | — | stessa fonte |
| Schermo 2560×1440 | — | circa 4% | stessa fonte |

**Cosa vuol dire per le prove:**
- Windows 11 su PC Intel o AMD è il caso più comune. Subito dopo viene Windows 10, che è ancora su circa un PC su quattro.
- Sui portatili lo schermo più comune è 1920×1080 al 125%, che dà 1536×864 punti. Poi viene 1366×768.
- I Mac Intel sono pochi, circa uno su sei, ma sono quelli più lenti e con più problemi (vedi il caso della cognata).
- StatCounter non distingue le versioni di macOS: Safari e Chrome dichiarano sempre «10.15». Per i Mac valgono TelemetryDeck e Steam.

## 2. Le macchine di GitHub (controllate il 4 novembre 2026 su actions/runner-images)

| Etichetta | Cosa è | Limiti |
|---|---|---|
| `macos-15` | Apple Silicon, macOS 15 (virtuale) | Niente Neural Engine né scheda grafica vera. Massima e Studio funzionano ma lente |
| `macos-26` / `macos-latest` | Apple Silicon, macOS 26 (virtuale) | come sopra |
| `xcode-27` | Apple Silicon, macOS 27.0.1 (anteprima pubblica) | è un'anteprima e può cambiare |
| `macos-15-intel`, `macos-26-intel` | Mac Intel (virtuale) | senza Metal: l'interfaccia SwiftUI non si apre. Solo motori, test senza interfaccia e controllo con `lipo`. Spesso in coda per ore |
| ~~`macos-14`~~ | — | **ritirato da GitHub il 2 novembre 2026.** macOS 14, il minimo dichiarato da IsoLR, **non si può più provare su GitHub**: va provato a mano |
| `windows-2025`, `windows-2022` | Windows Server, non Windows 10/11 Home | nessuna scheda grafica (DirectML gira sul processore); Visual C++ sempre installato; schermo piccolo |
| `windows-11-arm` | Windows 11 su ARM | IsoLR x64 gira in emulazione; DirectML non c'è |

## 3. Le combinazioni

Esiti:
- ✅ provato, con prova allegata;
- ⏳ prova scritta, risultato in arrivo;
- 🖐 da provare a mano;
- ❌ non si può provare (motivo scritto).

### Windows: l'interfaccia agli schermi veri (Chromium, lo stesso motore di WebView2)

Script: `windows/ui/test/dispositivi.js`. La finestra si calcola così: risoluzione ÷ scala, meno la barra delle applicazioni (48 punti su Windows 11, 40 su Windows 10) e la barra del titolo (32 punti).

| Schermo | Punti effettivi | Spazio utile | Finestra di partenza (prima) | Con la correzione | Interfaccia dentro la finestra |
|---|---|---|---|---|---|
| 1920×1080 al 100% | 1920×1080 | 1920×1032 | ✅ ci sta | ✅ | ✅ |
| 1920×1080 al 125% | 1536×864 | 1536×816 | ❌ esce di 36 punti | ✅ 1280×784 | ✅ |
| 1920×1080 al 150% | 1280×720 | 1280×672 | ❌ esce di 180 punti | ✅ 1280×640 | ✅ |
| 1366×768 al 100% (Win 11) | 1366×768 | 1366×720 | ❌ esce di 132 punti | ✅ 1280×688 | ✅ |
| 1366×768 al 100% (Win 10) | 1366×768 | 1366×728 | ❌ esce di 124 punti | ✅ 1280×696 | ✅ |
| 2560×1440 al 100% | 2560×1440 | 2560×1392 | ✅ | ✅ | ✅ |
| 2560×1440 al 125% | 2048×1152 | 2048×1104 | ✅ | ✅ | ✅ |
| 2560×1440 al 150% | 1706×960 | 1706×912 | ✅ | ✅ | ✅ |
| 2560×1440 al 175% | 1462×822 | 1462×774 | ❌ esce di 78 punti | ✅ 1280×742 | ✅ |
| 2560×1440 al 200% | 1280×720 | 1280×672 | ❌ esce di 180 punti | ✅ 1280×640 | ✅ |
| Due schermi con scala diversa | — | — | — | ✅ la finestra si risistema al cambio di scala (codice + test di unità) | 🖐 da provare a mano |

### Windows: installazione e avvio veri

| Macchina | Cosa si prova | Esito |
|---|---|---|
| `windows-latest` (Server 2025) | installa, apre, la finestra resta 20 s, clic destro «Separa con IsoLR», **la finestra sta dentro lo schermo** | ⏳ nel workflow Windows |
| `windows-latest` senza Visual C++ | il motore di Massima e Studio si carica, oppure dice cosa manca; **mai bloccato** | ⏳ nel workflow Windows |
| Windows 10 / 11 Home veri | tutto | 🖐 (GitHub non li ha) |
| Windows 11 Home in modalità S | l'installer non parte | 🖐; il sito deve dirlo prima del download (da fare) |
| Windows 11 su ARM (Snapdragon) | x64 in emulazione | ⏳ nel workflow dispositivi (`windows-11-arm`), 🖐 per la velocità vera |
| Scheda video vera (Intel, AMD, NVIDIA) | DirectML | ❌ su GitHub; 🖐 a mano |

### Mac

| Macchina | Cosa si prova | Esito |
|---|---|---|
| macOS 15 Apple Silicon (`macos-15`) | compila, test, avvio | ⏳ nel workflow dispositivi |
| macOS 26 Apple Silicon (`macos-26`) | compila, test, schermate, avvio | ⏳ (Compila e Schermate macOS 26) |
| macOS 27 (`xcode-27`, anteprima) | avvio | ⏳ nel workflow dispositivi |
| macOS 14 | minimo dichiarato | ❌ su GitHub (immagine ritirata), 🖐 a mano |
| Mac Intel (`macos-15-intel`) | `lipo` (ogni eseguibile ha anche la parte Intel), gara del motore, tempi di Massima | ⏳ (in coda su GitHub) |
| Mac Intel con interfaccia | tutto | 🖐 (il Mac della cognata) |
| 8 GB di RAM | memoria e tempi | 🖐 |

## 4. Quello che GitHub non può simulare

- **Schede video vere:** sia DirectML su Windows sia la grafica dei Mac Intel.
- **Windows 10/11 Home, modalità S, Smart App Control.**
- **Utente con accenti nel nome:** le cartelle di Windows (AppData, Musica) seguono l'utente vero e non si possono spostare con le variabili d'ambiente. Su GitHub si provano i file e le cartelle con accenti e spazi, non il nome utente.
- **OneDrive e iCloud con file solo nella nuvola.**
- **Antivirus di terze parti.**
- **Due schermi.**

Per questi c'è [PROVE-A-MANO.md](PROVE-A-MANO.md). Se servono macchine a pagamento, va chiesto prima, con il costo. Per esempio Windows 11 Home su Azure oppure un Mac Intel a noleggio: il costo lo verifico e te lo scrivo prima.
