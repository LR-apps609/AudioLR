// Il mixer, come MixPlayer in Sources/Mixer.swift: tutte le tracce partono nello stesso istante; volume,
// muto e ascolto solo per traccia; scorciatoie (Tutto, Karaoke, Solo voce, Karaoke con cori, «Senza…»).
// «Esercitati»: velocità senza cambiare il tono e tono senza cambiare la velocità (Signalsmith Stretch),
// un passaggio A–B da ripetere con la rampa, il metronomo sui battiti veri e il conteggio prima di partire.
// Più la registrazione sopra la base e la sua riproduzione. Le tracce si leggono dai WAV salvati.
/* global SignalsmithStretch, Encode, Bridge */
(function () {
  "use strict";
  const RATE = 44100;
  const VOICES = ["vocals", "lead", "backing", "male", "female"];
  const SPLITS = { vocals: ["lead", "backing"], gender: ["male", "female"], drums: ["kick", "snare", "toms", "hh", "ride", "crash"] };
  const SOURCE = { vocals: "vocals", gender: "vocals", drums: "drums" };
  const INSTRUMENTS = { drums: ["drums", "kick", "snare", "toms", "hh", "ride", "crash"], bass: ["bass"], guitar: ["guitar"], piano: ["piano"] };

  /** Le tracce da mescolare: la base resta fuori (è già un mix); le tracce divise prendono il posto della loro. */
  function mixable(stems) {
    const keys = stems.map((s) => s.key);
    const replaced = Object.keys(SPLITS).filter((k) => SPLITS[k].some((p) => keys.includes(p))).map((k) => SOURCE[k]);
    return stems.filter((s) => s.key !== "instrumental" && !replaced.includes(s.key));
  }

  // Un «tic» di 40 ms: una nota che si spegne subito (MixPlayer.clickBuffer)
  function click(ctx, hz) {
    const n = Math.round(0.04 * RATE), b = ctx.createBuffer(2, n, RATE);
    for (let c = 0; c < 2; c++) {
      const d = b.getChannelData(c);
      for (let i = 0; i < n; i++) { const t = i / RATE; d[i] = 0.45 * Math.sin(2 * Math.PI * hz * t) * Math.exp(-t / 0.008) * Math.min(1, t / 0.0005); }
    }
    return b;
  }

  class Player extends EventTarget {
    constructor() {
      super();
      this.ctx = null; this.buffers = {}; this.keys = []; this.duration = 0;
      this.gains = {}; this.muted = new Set(); this.solo = new Set();
      this.playing = false; this.startPos = 0; this.startCtx = 0; this.lead = 0;
      this.rate = 1; this.semitones = 0; this.loopA = null; this.loopB = null; this.ramp = false;
      this.metronome = false; this.countIn = false; this.structure = null; this.bpm = 0;
      this.take = null; this.takeOn = true; this.takeVolume = 1; this.recording = false;
      this.nodes = []; this.clickNodes = []; this.stretch = null; this.scheduledTo = 0;
      this.onStopped = null; this.onPlay = null;
    }
    emit() { this.dispatchEvent(new Event("change")); }

    async ensureCtx() {
      if (!this.ctx) {
        this.ctx = new AudioContext({ sampleRate: RATE, latencyHint: "interactive" });
        // Limitatore in uscita: con i volumi alzati le tracce sommate non «friggono»
        this.limiter = this.ctx.createDynamicsCompressor();
        Object.assign(this.limiter, {});
        this.limiter.threshold.value = -1; this.limiter.knee.value = 0; this.limiter.ratio.value = 20;
        this.limiter.attack.value = 0.002; this.limiter.release.value = 0.08;
        this.master = this.ctx.createGain();
        this.master.connect(this.limiter).connect(this.ctx.destination);
        this.clickHigh = click(this.ctx, 1760); this.clickLow = click(this.ctx, 1175);
        this.clickGain = this.ctx.createGain(); this.clickGain.connect(this.ctx.destination);
      }
      if (this.ctx.state === "suspended") await this.ctx.resume();
    }

    /** Prepara le tracce di una canzone (cartella e descrizione). */
    async load(entry) {
      this.stop();
      const folderChanged = !this.entry || this.entry.folder !== entry.folder;
      this.entry = entry;
      await this.ensureCtx();
      const wanted = mixable(entry.meta.stems);
      this.buffers = {}; this.keys = []; this.duration = 0;
      for (const s of wanted) {
        try {
          const ch = Encode.readWav(await Bridge.readFile(entry.folder + "/" + s.file));
          const b = this.ctx.createBuffer(2, ch[0].length, RATE);
          b.copyToChannel(ch[0], 0); b.copyToChannel(ch[1], 1);
          this.buffers[s.key] = b; this.keys.push(s.key);
          this.duration = Math.max(this.duration, b.duration);
        } catch (e) { /* una traccia illeggibile resta fuori dal mixer */ }
      }
      if (folderChanged) {
        this.gains = {}; this.muted = new Set(); this.solo = new Set();
        this.resetPractice();
      }
      const a = entry.meta.analysis;
      this.structure = a && a.structure ? a.structure : null;
      this.bpm = a && a.bpm ? a.bpm : 0;
      this.startPos = 0;
      this.dropStretch();
      await this.loadTake(null);
      this.emit();
    }

    // ── Stato del mix ──
    effectiveGain(k) {
      const g = this.gains[k] ?? 1;
      if (this.solo.size) return this.solo.has(k) ? g : 0;
      return this.muted.has(k) ? 0 : g;
    }
    setGain(k, v) { this.gains[k] = v; this.applyGains(); this.emit(); }
    toggleMute(k) { this.muted.has(k) ? this.muted.delete(k) : this.muted.add(k); this.applyGains(); this.emit(); }
    toggleSolo(k) { this.solo.has(k) ? this.solo.delete(k) : this.solo.add(k); this.applyGains(); this.emit(); }
    /** Le scorciatoie: all, karaoke, voice, backing (karaoke con cori). */
    preset(p) {
      this.muted = new Set(); this.solo = new Set();
      const v = this.keys.filter((k) => VOICES.includes(k));
      if (p === "karaoke") v.forEach((k) => this.muted.add(k));
      if (p === "voice") v.forEach((k) => this.solo.add(k));
      if (p === "backing") this.muted.add("lead");
      this.applyGains(); this.emit();
    }
    get currentPreset() {
      const v = this.keys.filter((k) => VOICES.includes(k));
      const same = (a, b) => a.size === b.length && b.every((x) => a.has(x));
      if (!this.muted.size && !this.solo.size) return "all";
      if (!this.solo.size && this.muted.size === 1 && this.muted.has("lead")) return "backing";
      if (!this.solo.size && same(this.muted, v)) return "karaoke";
      if (!this.muted.size && same(this.solo, v)) return "voice";
      return null;
    }
    without(inst) { this.muted = new Set(INSTRUMENTS[inst].filter((k) => this.keys.includes(k))); this.solo = new Set(); this.applyGains(); this.emit(); }
    get withoutNow() {
      if (this.solo.size || !this.muted.size) return null;
      for (const [k, list] of Object.entries(INSTRUMENTS)) { const ks = list.filter((x) => this.keys.includes(x)); if (ks.length && ks.length === this.muted.size && ks.every((x) => this.muted.has(x))) return k; }
      return null;
    }
    applyGains() {
      for (const n of this.nodes) if (n.key) n.gain.gain.setTargetAtTime(this.effectiveGain(n.key), this.ctx.currentTime, 0.01);
      if (this.takeGain) this.takeGain.gain.setTargetAtTime(this.takeOn && !this.recording ? this.takeVolume : 0, this.ctx.currentTime, 0.01);
    }

    // ── Posizione ──
    get position() {
      if (!this.playing || !this.ctx) return this.startPos;
      let p = this.startPos + Math.max(0, this.ctx.currentTime - this.startCtx - this.lead / this.rate) * this.rate;
      // Tra un controllo e l'altro il passaggio può essere già ricominciato
      if (this.isLooping && !this.recording && p >= this.loopB) p = this.loopA + (p - this.loopB);
      return Math.min(this.duration, p);
    }
    get isLooping() { return this.loopA != null && this.loopB != null; }
    get usesStretch() { return Math.abs(this.rate - 1) > 0.001 || this.semitones !== 0; }

    toggle() { this.playing ? this.pause() : this.play(this.position >= this.duration - 0.05 ? 0 : this.position); }

    /** Suona da `from`; con il conteggio, prima una battuta di clic (non quando il passaggio ricomincia da solo). */
    async play(from, { counting = true, forceCount = false } = {}) {
      if (!this.keys.length) return;
      await this.ensureCtx();
      this.stopNodes();
      let at = Math.max(0, Math.min(from, this.duration));
      if (this.isLooping && (at < this.loopA || at >= this.loopB - 0.02)) at = this.loopA;
      const period = this.beatPeriod(at), bar = (this.structure && this.structure.beatsPerBar) || 4;
      this.lead = counting && (this.countIn || forceCount) && (this.bpm > 0 || this.structure) ? period * bar : 0;
      const when = this.ctx.currentTime + 0.08;
      this.startCtx = when; this.startPos = at; this.scheduledTo = at;
      const musicAt = when + this.lead / this.rate;
      if (this.usesStretch) await this.playStretched(at, musicAt);
      else this.playPlain(at, musicAt);
      // Conteggio: una battuta di clic prima della musica (sempre udibile, anche senza metronomo)
      if (this.lead > 0) for (let i = 0; i < bar; i++) this.clickAt(when + (i * period) / this.rate, i === 0, true);
      this.playing = true;
      if (this.onPlay) this.onPlay({ startCtx: when, at, lead: this.lead, rate: this.rate, semitones: this.semitones, outputLatency: (this.ctx.outputLatency || 0) + (this.ctx.baseLatency || 0) });
      this.scheduleClicks();
      this.emit();
    }

    playPlain(at, when) {
      for (const k of this.keys) {
        const src = this.ctx.createBufferSource(), g = this.ctx.createGain();
        src.buffer = this.buffers[k]; g.gain.value = this.effectiveGain(k);
        if (this.isLooping && !this.recording) { src.loop = true; src.loopStart = this.loopA; src.loopEnd = this.loopB; }
        src.connect(g).connect(this.master);
        src.start(when, at);
        this.nodes.push({ key: k, src, gain: g });
      }
      if (this.take && this.takeBuffer) {
        const src = this.ctx.createBufferSource();
        src.buffer = this.takeBuffer; src.connect(this.takeGain);
        if (this.isLooping && !this.recording) { src.loop = true; src.loopStart = this.loopA; src.loopEnd = this.loopB; }
        src.start(when, Math.min(at, this.takeBuffer.duration));
        this.nodes.push({ src });
      }
      this.applyGains();
    }

    // Velocità e tono: un solo nodo Signalsmith con tutte le tracce come canali, poi diviso per traccia
    async playStretched(at, when) {
      if (!this.stretch) {
        if (typeof SignalsmithStretch !== "function") throw new Error("velocità e tono non disponibili");
        const all = this.take && this.takeBuffer ? [...this.keys, "__take"] : [...this.keys];
        const C = all.length * 2;
        const node = await SignalsmithStretch(this.ctx, { numberOfInputs: 0, numberOfOutputs: 1, outputChannelCount: [C] });
        const split = this.ctx.createChannelSplitter(C);
        node.connect(split);
        const outs = all.map((k, i) => {
          const m = this.ctx.createChannelMerger(2), g = this.ctx.createGain();
          split.connect(m, 2 * i, 0); split.connect(m, 2 * i + 1, 1);
          m.connect(g).connect(k === "__take" ? this.takeGain : this.master);
          return { key: k === "__take" ? null : k, gain: g };
        });
        const chans = all.flatMap((k) => { const b = k === "__take" ? this.takeBuffer : this.buffers[k]; return [b.getChannelData(0), b.getChannelData(1)]; });
        await node.addBuffers(chans);
        this.stretch = { node, outs, split };
      }
      const s = this.stretch;
      s.outs.forEach((o) => { if (o.key) o.gain.gain.value = this.effectiveGain(o.key); });
      this.nodes.push(...s.outs.filter((o) => o.key).map((o) => ({ key: o.key, gain: o.gain })));
      const loop = this.isLooping && !this.recording ? { loopStart: this.loopA, loopEnd: this.loopB } : { loopStart: 0, loopEnd: 0 };
      s.node.schedule({ active: true, output: when, input: at, rate: this.rate, semitones: this.semitones, ...loop });
    }
    dropStretch() {
      if (!this.stretch) return;
      try { this.stretch.node.schedule({ active: false }); this.stretch.node.disconnect(); this.stretch.split.disconnect(); } catch {}
      this.stretch = null;
    }

    clickAt(t, strong, count) {
      const src = this.ctx.createBufferSource();
      src.buffer = strong ? this.clickHigh : this.clickLow;
      const g = this.ctx.createGain(); g.gain.value = count || this.metronome ? 1 : 0;
      src.connect(g).connect(this.clickGain);
      src.start(t);
      this.clickNodes.push({ src, g, count });
    }
    /** I clic del metronomo nel prossimo secondo e mezzo (si ricalcola a ogni giro del passaggio). */
    scheduleClicks() {
      if (!this.playing || !this.structure || !this.structure.beats) return;
      const s = this.structure, pos = this.position, horizon = pos + 1.5 * this.rate;
      const end = this.isLooping && !this.recording ? this.loopB : this.duration;
      for (let i = 0; i < s.beats.length; i++) {
        const t = s.beats[i];
        if (t < Math.max(this.scheduledTo, pos) - 0.001 || t >= Math.min(horizon, end)) continue;
        const k = (((i - s.firstDownbeat) % s.beatsPerBar) + s.beatsPerBar) % s.beatsPerBar;
        const ctxT = this.startCtx + this.lead / this.rate + (t - this.startPos) / this.rate;
        if (ctxT > this.ctx.currentTime) this.clickAt(ctxT, k === 0, false);
      }
      this.scheduledTo = Math.min(horizon, end);
    }
    beatPeriod(at) {
      const b = this.structure && this.structure.beats;
      if (b && b.length >= 3) {
        let i = b.findIndex((x) => x >= at); if (i < 0) i = b.length - 1;
        i = Math.min(b.length - 2, Math.max(0, i - 1));
        const lo = Math.max(0, i - 4), hi = Math.min(b.length - 1, i + 4), gaps = [];
        for (let j = lo; j < hi; j++) gaps.push(b[j + 1] - b[j]);
        gaps.sort((x, y) => x - y);
        const m = gaps[Math.floor(gaps.length / 2)];
        if (m > 0.2 && m < 2) return m;
      }
      return this.bpm > 0 ? 60 / this.bpm : 0.5;
    }

    pause() { this.startPos = this.position; this.stopNodes(); this.playing = false; this.emit(); }
    stop() { this.stopNodes(); this.playing = false; this.startPos = 0; this.emit(); }
    stopNodes() {
      for (const n of this.nodes) if (n.src) try { n.src.stop(); n.src.disconnect(); } catch {}
      for (const c of this.clickNodes) try { c.src.stop(); } catch {}
      if (this.stretch) try { this.stretch.node.schedule({ active: false }); } catch {}
      this.nodes = []; this.clickNodes = [];
    }
    seek(fraction) {
      const t = Math.max(0, Math.min(1, fraction)) * this.duration;
      if (this.playing) this.play(t, { counting: false }); else { this.startPos = t; this.emit(); }
    }

    /** Chiamato spesso dalla finestra: fine canzone, fine passaggio (rampa, registrazione), metronomo. */
    tick() {
      if (!this.playing) return;
      this.scheduleClicks();
      const raw = this.startPos + Math.max(0, this.ctx.currentTime - this.startCtx - this.lead / this.rate) * this.rate;
      if (this.isLooping && raw >= this.loopB - 0.03) {
        if (this.recording) { this.pause(); if (this.onStopped) this.onStopped(); return; }
        // Il passaggio ricomincia: con la rampa un po' più veloce (si riparte con la velocità nuova)
        if (this.ramp && this.rate < 1) {
          this.rate = Math.min(1, Math.round((this.rate + 0.05) * 100) / 100);
          this.play(this.loopA, { counting: false });
          return;
        }
        // Le tracce ripartono da sole da A: qui si rimette a posto l'orologio (e i clic del giro nuovo)
        this.startCtx = this.startCtx + this.lead / this.rate + (this.loopB - this.startPos) / this.rate;
        this.lead = 0; this.startPos = this.loopA; this.scheduledTo = this.loopA;
        this.scheduleClicks();
        return;
      }
      if (!this.isLooping && raw >= this.duration - 0.02) { this.stop(); if (this.onStopped) this.onStopped(); }
    }

    // ── Esercitati ──
    setRate(r) { const was = this.playing, at = this.position; this.rate = r; if (was) this.play(at, { counting: false }); else this.emit(); }
    setSemitones(s) { const was = this.playing, at = this.position; this.semitones = s; if (was) this.play(at, { counting: false }); else this.emit(); }
    markA() { this.loopA = this.position; if (this.loopB != null && this.loopB <= this.loopA + 0.25) this.loopB = null; this.emit(); }
    markB() {
      const p = this.position;
      if (p <= (this.loopA ?? 0) + 0.25) return;
      if (this.loopA == null) this.loopA = 0;
      this.loopB = p;
      if (this.playing) this.play(this.loopA, { counting: false }); else this.emit();
    }
    clearLoop() { this.loopA = null; this.loopB = null; if (this.playing) this.play(this.position, { counting: false }); else this.emit(); }
    practice(a, b) { if (b <= a + 0.25) return; this.loopA = Math.max(0, a); this.loopB = Math.min(this.duration, b); this.play(this.loopA); }
    setRamp(on) { this.ramp = on; if (on) this.rate = 0.7; this.lastLap = -1; this.emit(); }
    resetPractice() { this.ramp = false; this.rate = 1; this.semitones = 0; this.loopA = null; this.loopB = null; this.emit(); }
    section(t) { const s = this.structure && this.structure.sections; return s ? s.find((x) => t >= x.start && t < x.end) : null; }

    // ── La registrazione da riascoltare ──
    async loadTake(path) {
      await this.ensureCtx();
      if (!this.takeGain) { this.takeGain = this.ctx.createGain(); this.takeGain.connect(this.master); }
      this.take = path; this.takeBuffer = null;
      if (path) {
        try {
          const ch = Encode.readWav(await Bridge.readFile(path));
          const b = this.ctx.createBuffer(2, ch[0].length, RATE);
          b.copyToChannel(ch[0], 0); b.copyToChannel(ch[1], 1);
          this.takeBuffer = b;
        } catch { this.take = null; }
      }
      this.dropStretch();
      this.applyGains(); this.emit();
    }

    /** Il mix che senti (o solo il passaggio), come MixPlayer.export: alla velocità e nel tono originali. */
    mixdown(range) {
      const n = Math.round(this.duration * RATE), s0 = range ? Math.max(0, Math.floor(range[0] * RATE)) : 0, s1 = range ? Math.min(n, Math.floor(range[1] * RATE)) : n;
      const out = [new Float32Array(s1 - s0), new Float32Array(s1 - s0)];
      for (const k of this.keys) {
        const g = this.effectiveGain(k); if (!g) continue;
        for (let c = 0; c < 2; c++) { const d = this.buffers[k].getChannelData(c); for (let i = s0; i < Math.min(s1, d.length); i++) out[c][i - s0] += d[i] * g; }
      }
      let top = 0; for (const c of out) for (let i = 0; i < c.length; i++) top = Math.max(top, Math.abs(c[i]));
      return { channels: out, gain: top > 0.98 ? 0.98 / top : 1 };
    }
    exportName(title) {
      const p = this.currentPreset;
      if (p === "karaoke") return `${title} – Karaoke`;
      if (p === "voice") return `${title} – Solo voce`;
      if (p === "backing") return `${title} – Karaoke con cori`;
      const w = this.withoutNow;
      if (w) return `${title} – Senza ${{ drums: "batteria", bass: "basso", guitar: "chitarra", piano: "pianoforte" }[w]}`;
      return `${title} – Mix`;
    }
  }

  window.MixPlayer = { Player, mixable, VOICES, SPLITS, INSTRUMENTS };
})();
