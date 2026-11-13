// Nel lavoratore audio (AudioWorklet), prima del motore di velocità e tono: il suo process() risponde sempre
// «continua», quindi un motore tolto restava vivo per sempre con tutte le tracce dentro (dal tester t15: 81 motori
// dopo 80 cambi di canzone). Qui il processore si ferma davvero quando gli si manda schedule({ fine: true }),
// e il browser lo può liberare. Il suono non cambia: process() è quello del motore.
const register = globalThis.registerProcessor;
globalThis.registerProcessor = (name, Processor) => register(name, class extends Processor {
  process(inputs, outputs, parameters) {
    if (this.timeMap && this.timeMap.some((s) => s.fine)) return false;
    return super.process(inputs, outputs, parameters);
  }
});
