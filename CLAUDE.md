# IsoLR (repository AudioLR) · regole per Claude

**Documento della verità:** https://claude.ai/artifact/M3yMXLFG2ZQ4ci98GEyCZU («IsoLR · Documento della verità», pagina privata su claude.ai).
I dati (stato, test, diario, link, decisioni) stanno nel database della pagina: si aggiornano con lo strumento ArtifactData (collezioni meta, attese, test, link, stato, diario, decisioni, comefare, archivio, cambiamenti). La pagina si ripubblica solo quando cambia l'aspetto.
- Prima di ogni aggiornamento rileggi i dati dal database, non dalla memoria. Se una scrittura non riesce, dillo.
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
