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
| `Tools/convert_demucs.py` | Converte Demucs in Core ML e controlla che app e modello diano lo stesso risultato di Demucs |

## Compilazione

- **Ogni modifica** → workflow «Compila AudioLR» sul Mac di GitHub: compila (Apple Silicon e Intel), esegue i test, pubblica la release `vX.Y.Z` con lo `.zip`.
- **Modello** → workflow «Modello Demucs» (parte da solo quando cambia `Tools/convert_demucs.py`, o a mano da Actions): converte, prova, carica `HTDemucs.mlpackage.zip` nella release `modelli-1`.
- **Installare**: scarica lo `.zip` dalla release, aprilo, doppio clic su «Costruisci e installa.command» (la prima volta: tasto destro → Apri).

## Percorso

1. **Motore** (0.1): separazione in 4 tracce + base karaoke ← *siamo qui*
2. **Mixer**: le tracce in parallelo, volume/muto/solo per ognuna, esporta il mix
3. **Rifiniture**: modello più preciso (htdemucs_ft) o a 6 tracce (chitarra, pianoforte), aggiornamenti con doppio clic (`.audiolr`)
4. **Ponte con OrbitLR**: «Apri in AudioLR» da OrbitLR

Va meglio sui Mac con chip Apple (M1 e successivi); sugli Intel funziona, più lentamente.
