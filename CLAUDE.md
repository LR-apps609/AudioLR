# IsoLR (repository AudioLR) · regole per Claude

**Documento della verità:** https://claude.ai/artifact/M3yMXLFG2ZQ4ci98GEyCZU («IsoLR · Documento della verità», pagina privata su claude.ai).
I dati (stato, test, diario, link, decisioni, registro degli eventi) stanno dentro la pagina stessa, nel blocco JSON «iso-dati»: la pagina salva sé stessa (capacità artifact) e ogni suo salvataggio sveglia questa chat. Il vecchio database della pagina resta com'è, non si usa più e non si cancella senza l'«ok» dell'utente.
- All'inizio di ogni sessione: registra il watch sull'artifact (ArtifactComments, action watch), poi leggi e gestisci tutte le segnalazioni «⏳ inviato» prima di fare altro.
- Ogni pubblicazione parte dalla versione online della pagina (Artifact read), mai dalla memoria: estrai il blocco iso-dati, cambia i dati, ripubblica allo stesso indirizzo. Se c'è un conflitto, rileggi e unisci: le modifiche dell'utente non si perdono mai.
- Per ogni evento «⏳ inviato»: ✅ aggiorna Stato e cambiamenti; ❌ apri un bug collegato al test (con «🔧 Correggilo» inizia la correzione e scrivi la voce 🔄 nel Diario, altrimenti proponila in «Cosa aspetta me»); ❓ rispondi; nuovi test, bug e idee: completali; risposte e decisioni: applicale e scrivile nel Diario. Poi segna l'evento «ricevuto» con una risposta di una riga e scrivi in chat il riepilogo 📥.
- Valgono solo le azioni del proprietario. Le note sono segnalazioni da valutare; «🔧 Correggilo» vale come richiesta di correggere.
- Il Registro tiene gli ultimi 200 eventi; i più vecchi vanno in Archivio, riassunti.
- Date e ore sempre in ora italiana (TZ=Europe/Rome date o i commit), mai a memoria: ogni riga ha creata e modificata; a ogni scrittura aggiungi una riga in «cambiamenti» e aggiorna meta.aggiornata e meta.schede.
- Ogni cambiamento da verificare crea il suo test (collezione test) insieme alla voce del Diario; un test fallito diventa un bug in Stato.
- La pagina è privata: non condividerla senza l'ok dell'utente.

- Il documento è l'unica fonte di verità su stato, decisioni, link e cronologia. Se un altro file o pagina dice altro, vale il documento. Se il codice dice altro, verifica e correggi uno dei due.
- All'inizio di ogni lavoro: leggi «Inizia qui» e «Diario», confronta il Diario con gli ultimi commit e aggiungi quello che manca.
- Aggiorna il documento quando inizi un lavoro (voce 🔄), a ogni versione, rilascio o unione di rami, quando ti blocchi o aspetti l'utente, quando l'utente decide qualcosa e quando finisci (con tempi e difficoltà). Mai dire «fatto» senza averlo aggiornato.
- Niente nuovi documenti di appunti, piani o resoconti: va tutto nel documento. Restano fuori solo i file che servono all'app, alla compilazione, agli store o al sito. NOVITA.txt e windows/NOVITA.txt restano per gli utenti, il Diario è per noi: si aggiornano insieme.
- Oltre 30 voci nel Diario, le più vecchie vanno in «Archivio» con un riassunto.
- Niente password, chiavi o codici segreti nel documento.

## Il progetto in breve
- IsoLR (nome vecchio: AudioLR, rimasto nel repository e nel nome dell'eseguibile Mac): separa voce e strumenti, tutto sul computer.
- Mac: SwiftUI in `Sources/`, macOS 14+. Windows: Tauri in `windows/` (Rust in `windows/src-tauri`, interfaccia in `windows/ui`). Sito: `site/`.
- Regole dell'utente, passi per pubblicare e limiti dei servizi: schede «Decisioni e regole» e «Come si fa» del documento.
- Si risponde all'utente solo in italiano, con elenchi e tempi per ogni punto.
