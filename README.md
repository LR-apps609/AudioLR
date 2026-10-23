# AudioLR

Separa una canzone in voce, batteria, basso e altri strumenti, **tutto sul Mac**: niente server, niente abbonamento, niente limiti.
Il motore è Demucs v4 (HTDemucs, licenza MIT) convertito in Core ML; spettrogramma e ricucitura dei pezzi li fa l'app in Swift.

## Come è fatto

| File | Cosa fa |
|---|---|
| `Sources/Spectrogram.swift` | STFT / iSTFT identiche a Demucs (Accelerate) |
| `Sources/Separator.swift` | Divide la canzone in pezzi, li passa al modello, li ricuce; lettura dei risultati Core ML |
| `Sources/ModelStore.swift` | Scarica il modello la prima volta (release `modelli-1`) e lo prepara |
| `Sources/AudioIO.swift` | Legge MP3/M4A/WAV/AIFF/FLAC → stereo 44,1 kHz; scrive WAV 24 bit |
| `Sources/SeparationJob.swift` | Il lavoro su una canzone, con avanzamento e tempo stimato |
| `Sources/ContentView.swift` | La finestra |
| `Sources/Studio.swift` | Marchio animato, forme d'onda, sfondo da studio |
| `Sources/Updater.swift` | Aggiornamenti: controllo giornaliero, doppio clic sul `.audiolr`, novità |
| `Tools/convert_demucs.py` | Converte Demucs in Core ML e controlla che app e modello diano lo stesso risultato di Demucs |

## Installare e aggiornare

**Prima installazione** (una volta sola): apri il Terminale, incolla questa riga e premi Invio.

```
curl -fsSL https://raw.githubusercontent.com/LR-apps609/AudioLR/main/installa.sh | zsh
```

Scarica l'ultima versione già pronta, la mette in Applicazioni e la apre. Scaricata così, macOS non la blocca come «sviluppatore non identificato».

**Aggiornamenti**: niente da fare. AudioLR controlla da sola una volta al giorno e chiede «Scarica e installa»; oppure doppio clic su un file `.audiolr` delle Release. Si chiude e si riapre aggiornata in pochi secondi; se qualcosa va storto, la versione di prima resta al suo posto.

## Compilazione e prove

- **Ogni modifica** → workflow «Compila AudioLR» sul Mac di GitHub: compila (Apple Silicon e Intel), esegue i test, pubblica la release `vX.Y.Z` con il `.audiolr`.
- **Modello** → workflow «Modello Demucs» (quando cambia `Tools/convert_demucs.py`, o a mano): converte, confronta con Demucs, carica `HTDemucs.mlpackage.zip` nella release `modelli-1`.
- **Prova di fedeltà** → workflow «Prova di fedelta»: Demucs originale separa una canzone di prova; il test `EndToEndTests` la separa con l'app e il modello vero e controlla che il risultato coincida. Fedeltà e velocità si leggono nella pagina della compilazione.
- **Icona** → `Tools/make_icon.py` la ridisegna (Pillow).

## Percorso

1. **Motore** (0.1): separazione in 4 tracce + base karaoke
   **Studio** (0.2): nuova grafica, forme d'onda, aggiornamenti con doppio clic ← *siamo qui*
2. **Mixer**: le tracce in parallelo, volume/muto/solo per ognuna, esporta il mix
3. **Rifiniture**: modello più preciso (htdemucs_ft) o a 6 tracce (chitarra, pianoforte), sito di presentazione
4. **Ponte con OrbitLR**: «Apri in AudioLR» da OrbitLR

Va meglio sui Mac con chip Apple (M1 e successivi); sugli Intel funziona, più lentamente.
