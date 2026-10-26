// Registrati sopra la base (Recorder.swift sul Mac): il microfono registra mentre il mixer suona, poi la
// registrazione si mette «a tempo» con la canzone: si toglie il ritardo di microfono e altoparlanti e, se si
// suonava più piano o in un altro tono, la si riporta a velocità e tono originali (Signalsmith Stretch fuori
// tempo reale). Il file finale parte dall'inizio della canzone, con silenzio prima.
/* global Bridge, Prefs, Encode, SignalsmithStretch */
(function () {
  "use strict";
  const RATE = 44100;
  // Il raccoglitore dentro il motore audio: copia i pezzi del microfono con l'istante (in campioni) del primo
  const WORKLET = `class Raccogli extends AudioWorkletProcessor {
    constructor() { super(); this.on = true; this.port.onmessage = (e) => { if (e.data === "stop") this.on = false; }; }
    process(inputs) {
      const i = inputs[0];
      if (i && i.length) {
        const l = i[0].slice(), r = (i[1] || i[0]).slice();
        let m = 0; for (let k = 0; k < l.length; k++) m = Math.max(m, Math.abs(l[k]), Math.abs(r[k]));
        this.port.postMessage({ frame: currentFrame, l, r, peak: m }, [l.buffer, r.buffer]);
      }
      return this.on;
    }
  }
  registerProcessor("isolr-raccogli", Raccogli);`;

  const Recorder = {
    recording: false, level: 0,
    async start(player, entry, done, fail, changed) {
      if (this.recording) return;
      let stream;
      try {
        stream = await navigator.mediaDevices.getUserMedia({ audio: { echoCancellation: false, noiseSuppression: false, autoGainControl: false, channelCount: 2 } });
      } catch {
        fail("IsoLR non può usare il microfono. Aprilo in Impostazioni di Windows › Privacy e sicurezza › Microfono, oppure collegane uno.");
        return;
      }
      await player.ensureCtx();
      const ctx = player.ctx;
      if (!this.loaded) { await ctx.audioWorklet.addModule(URL.createObjectURL(new Blob([WORKLET], { type: "text/javascript" }))); this.loaded = true; }
      const src = ctx.createMediaStreamSource(stream);
      const node = new AudioWorkletNode(ctx, "isolr-raccogli", { numberOfInputs: 1, numberOfOutputs: 0, channelCount: 2, channelCountMode: "explicit" });
      const chunks = [];
      let first = null;
      node.port.onmessage = (e) => {
        if (first == null) first = e.data.frame;
        chunks.push(e.data);
        this.level = Math.max(this.level * 0.85, e.data.peak);
      };
      src.connect(node);
      const track = stream.getAudioTracks()[0];
      const inputLatency = (track.getSettings && track.getSettings().latency) || 0;
      let clock = null;
      player.recording = true; player.applyGains();
      player.onPlay = (c) => { clock = c; };
      const finish = async () => {
        if (!this.recording) return;
        this.recording = false; this.level = 0;
        node.port.postMessage("stop"); src.disconnect(); stream.getTracks().forEach((t) => t.stop());
        if (player.playing) player.pause();
        player.recording = false; player.onPlay = null; player.onStopped = null; player.applyGains();
        changed();
        try {
          if (!clock || first == null || chunks.length < 20) throw new Error("La registrazione è troppo corta.");
          // Il primo campione registrato: quale secondo della canzone si sentiva in quel momento
          const host = first / ctx.sampleRate - inputLatency;
          const start = clock.at - clock.lead + (host - clock.outputLatency - clock.startCtx) * clock.rate + Prefs.get("recordOffsetMs", 0) / 1000;
          const n = chunks.reduce((s, c) => s + c.l.length, 0);
          const raw = [new Float32Array(n), new Float32Array(n)];
          let o = 0;
          for (const c of chunks) { raw[0].set(c.l, o); raw[1].set(c.r, o); o += c.l.length; }
          const audio = await normalize(raw, ctx.sampleRate, clock.rate, clock.semitones);
          const out = place(audio, start, player.duration);
          const dir = entry.folder + "/Registrazioni";
          const existing = await Bridge.listFiles(dir, "wav");
          let k = 1; while (existing.some((p) => p.replace(/\\/g, "/").endsWith(`/Registrazione ${k}.wav`))) k++;
          const path = `${dir}/Registrazione ${k}.wav`;
          await Bridge.writeFile(path, Encode.wav(out, 24));
          done(path);
        } catch (e) { fail(e.message || String(e)); }
      };
      this.stop = finish;
      player.onStopped = finish;
      this.recording = true;
      changed();
      // Da A se c'è un passaggio, altrimenti da dove si è; sempre con una battuta di conteggio
      player.play(player.loopA ?? player.position, { counting: true, forceCount: true });
    },
    stop() {},
  };

  /** Alla velocità e nel tono della canzone (se si suonava diverso), a 44,1 kHz stereo. */
  async function normalize(raw, rate, speed, semitones) {
    const same = Math.abs(speed - 1) < 0.001 && semitones === 0;
    const seconds = raw[0].length / rate, outLen = Math.ceil(seconds * speed * RATE);
    if (same && rate === RATE) return raw;
    const off = new OfflineAudioContext(2, outLen + RATE, RATE);
    if (same) {
      const b = off.createBuffer(2, raw[0].length, rate); b.copyToChannel(raw[0], 0); b.copyToChannel(raw[1], 1);
      const s = off.createBufferSource(); s.buffer = b; s.connect(off.destination); s.start();
    } else {
      const node = await SignalsmithStretch(off);
      node.connect(off.destination);
      // Signalsmith lavora alla frequenza del contesto: la registrazione si porta prima a 44,1 kHz
      const res = rate === RATE ? raw : await resample(raw, rate);
      await node.addBuffers(res);
      node.schedule({ active: true, input: 0, output: 0, rate: 1 / speed, semitones: -semitones });
    }
    const r = await off.startRendering();
    // Signalsmith compensa da solo il suo ritardo; si tiene la lunghezza giusta
    return [r.getChannelData(0).slice(0, outLen), r.getChannelData(1).slice(0, outLen)];
  }
  async function resample(raw, rate) {
    const n = Math.ceil((raw[0].length / rate) * RATE), off = new OfflineAudioContext(2, n, RATE);
    const b = off.createBuffer(2, raw[0].length, rate); b.copyToChannel(raw[0], 0); b.copyToChannel(raw[1], 1);
    const s = off.createBufferSource(); s.buffer = b; s.connect(off.destination); s.start();
    const r = await off.startRendering();
    return [r.getChannelData(0), r.getChannelData(1)];
  }
  /** La registrazione dal secondo `start` della canzone, con silenzio prima, lunga quanto la canzone. */
  function place(audio, start, length) {
    const total = Math.round(length * RATE), shift = Math.round(start * RATE);
    const out = [new Float32Array(total), new Float32Array(total)];
    for (let c = 0; c < 2; c++) for (let i = 0; i < audio[c].length; i++) { const j = i + shift; if (j >= 0 && j < total) out[c][j] = audio[c][i]; }
    return out;
  }

  Recorder.place = place;
  window.Recorder = Recorder;
})();
