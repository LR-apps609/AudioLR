# Licenze dei modelli di IsoLR

Controllo del 1° novembre 2026. Il **codice** che fa girare i modelli (Demucs, BS-RoFormer, Mel-Band RoFormer,
MDX23C) è MIT; qui si parla dei **pesi**, cioè dei file addestrati che IsoLR scarica e usa.

| Modello in IsoLR | A cosa serve | Pesi di | Licenza dei pesi | Uso a pagamento |
|---|---|---|---|---|
| HTDemucs, HTDemucsFT-0/1/2 | Rapida, riserve | Meta (Demucs v4) | MIT | ✅ |
| Basic Pitch | Note MIDI | Spotify | Apache 2.0 | ✅ |
| — (nessun modello) | Pulisci la voce · rumore | calcolo di IsoLR (Tools/denoise_ref.py) | nostra | ✅ |
| — (nessun modello) | Pulisci la voce · riverbero | calcolo di IsoLR (Tools/dereverb_ref.py) | nostra | ✅ |
| StrumentiSW (BS-RoFormer SW) | Massima, Studio | jarredou e altri | non dichiarata («unknown» sulla pagina dell'autore; un terzo dice MIT) | ⚠️ da chiedere |
| VoceRevive (BS-RoFormer Revive V3e) | Studio, voce | unwa | non trovata | ⚠️ da chiedere |
| VoceRoFormer9 (Mel-Band RoFormer) | riserva della voce | Kimberley Jensen | «unknown» sulla pagina dei pesi; un terzo dice MIT | ⚠️ da chiedere |
| VoceCori3 (Mel-Band RoFormer karaoke) | Voce e cori | aufr33, viperx | non trovata | ⚠️ da chiedere |
| VoceDuetto (BS-RoFormer Chorus Male-Female) | Voce maschile e femminile | Sucial | non trovata | ⚠️ da chiedere |
| BatteriaDrumSep (MDX23C DrumSep) | Dividi la batteria | aufr33, jarredou | non trovata | ⚠️ da chiedere |

## Togli rumore: perché non DeepFilterNet
DeepFilterNet3 (Hendrik Schröter, MIT o Apache 2.0) ha una licenza perfetta ed è stato convertito e provato
(Tools/convert_deepfilter.py, workflow «Modello pulizia»: uguale all'originale, 5 → 12 dB sul parlato). Ma è fatto per
il parlato: sulle voci cantate di 5 canzoni di MUSDB18-HQ (Tools/prova_canto.py) toglie anche pezzi di voce (in media
−2,5 dB su una voce già pulita, −5,6 dB su un brano rock) e con un rumore a 10 dB il risultato peggiora in media
(9,1 → 6,5 dB); limitarlo non basta. Per questo «Rumore» è un calcolo nostro, un «noise gate» spettrale: profilo del
rumore dai momenti più silenziosi della traccia, abbassa solo quello che non supera il profilo; se la traccia non ha un
rumore di fondo riconoscibile non tocca niente.

## Togli riverbero: perché senza modello
Controllo del 2 novembre 2026: i modelli di dereverbero per la musica oggi disponibili hanno pesi con licenze che non
permettono la vendita o che obbligherebbero a pubblicare il codice dell'app: anvuew (Mel-Band e BS-RoFormer dereverb,
dereverb_room) **GPL-3.0**, Sucial (Dereverb-Echo Mel-Band RoFormer) **CC BY-NC-SA 4.0**, FoxJoy (UVR DeEcho-DeReverb)
licenza non dichiarata. Per questo «Riverbero» è un calcolo nostro (porta sul decadimento della coda tardiva, sulla linea di
Lebart e altri, 2001): toglie bene la coda tra una nota e l'altra (10–15 dB nelle prove), meno il riverbero che suona
insieme a una nota tenuta. Se un autore desse il permesso, un modello si potrebbe aggiungere come opzione.

## Cosa vuol dire
- **Uso gratuito e personale:** è come lo usa oggi chiunque con UVR o MVSep; i pesi sono pubblici e citati per nome.
- **Vendita:** senza una licenza scritta, i pesi «non dichiarati» non si possono considerare liberi per un prodotto a
  pagamento. Prima di vendere servono, per ognuno, un permesso scritto dell'autore (una mail o un messaggio pubblico
  sulla pagina del modello basta) oppure un modello sostitutivo con licenza chiara.

## Strada consigliata
1. Scrivere agli autori (unwa, jarredou, Kimberley Jensen, aufr33, viperx, Sucial) chiedendo il permesso per l'uso in
   un'app a pagamento, con il nome e il link a IsoLR nei crediti (che ci sono già in Impostazioni › Informazioni).
2. Nel frattempo, per una versione a pagamento «sicura»: Rapida e Massima con i soli modelli MIT (Demucs), e Studio
   come funzione gratuita o a donazione, finché i permessi non arrivano.
3. Tenere qui le risposte degli autori.
