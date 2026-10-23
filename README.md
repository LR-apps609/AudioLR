# AudioLR

Separa una canzone in voce, batteria, basso e altri strumenti, **tutto sul Mac**: niente server, niente abbonamento, niente limiti.
Il motore è Demucs v4 (HTDemucs, licenza MIT) convertito in Core ML; spettrogramma e ricucitura dei pezzi li fa l'app in Swift.

## Come è fatto

| File | Cosa fa |
|---|---|
| `Sources/Spectrogram.swift` | STFT / iSTFT identiche a Demucs (Accelerate) |
| `Sources/Separator.swift` | Demucs: divide la canzone in pezzi, li passa al modello, li ricuce; controllo di coerenza |
| `Sources/VoiceRoFormer.swift` | Voce con Mel-Band RoFormer: STFT come torch, bande mel, maschere, ricucitura |
| `Sources/Engine.swift` | Qualità (Veloce, Massima) e scelta automatica tra Neural Engine e grafica |
| `Sources/ModelStore.swift` | Scarica i modelli la prima volta (release `modelli-1`) e li prepara |
| `Sources/AudioIO.swift` | Legge MP3/M4A/WAV/AIFF/FLAC → stereo 44,1 kHz; scrive WAV, FLAC, Apple Lossless |
| `Sources/SeparationJob.swift` | Il lavoro su una canzone: coda, avanzamento, salvataggio, cronologia |
| `Sources/Mixer.swift` | Mixer: tracce sincronizzate, muto/solo/volume, esportazione del mix |
| `Sources/ContentView.swift`, `Studio.swift`, `Theme.swift` | La finestra e la grafica |
| `Sources/SettingsView.swift`, `Preferences.swift`, `History.swift` | Impostazioni, formati, cartella, recenti |
| `Sources/Updater.swift` | Aggiornamenti: controllo giornaliero, doppio clic sul `.audiolr`, novità |
| `Tools/convert_demucs.py`, `Tools/convert_roformer.py` | Conversione dei modelli in Core ML, con confronto con gli originali |
| `Tools/benchmark.py` | Banco di prova: SDR sulle 50 canzoni di prova di MUSDB18, per ogni metodo |
| `site/index.html` | Bozza del sito |

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
- **Modelli Massima qualità** → workflow «Modelli Massima qualita» (htdemucs_ft, 4 modelli) e «Modello voce RoFormer».
- **Banco di prova** → workflow «Banco di prova»: SDR di ogni metodo su MUSDB18, risultati nella release `banco-di-prova` (con le canzoni per il confronto con Fadr).
- **Prova di fedeltà** → workflow «Prova di fedelta»: Demucs originale separa una canzone di prova; il test `EndToEndTests` la separa con l'app e il modello vero e controlla che il risultato coincida. Fedeltà e velocità si leggono nella pagina della compilazione.
- **Icona** → `Tools/make_icon.py` la ridisegna (Pillow).

## Percorso

La roadmap aggiornata è nella pagina di progetto (artifact «AudioLR»). In breve:

1. Motore (0.1) · 2. Studio (0.2) · 3. Qualità e professionalità (0.3–0.4) — fatti
4. **Voce pulita come i migliori** (0.5): voce con RoFormer, banco di prova, confronto con Fadr — in corso
5. Mixer (anticipato in 0.5) · 6. Ponte con OrbitLR · 7. Sito e prova nel browser · poi analisi, studio per musicisti, più tracce, MIDI, video

Va meglio sui Mac con chip Apple (M1 e successivi); sugli Intel funziona, più lentamente.
