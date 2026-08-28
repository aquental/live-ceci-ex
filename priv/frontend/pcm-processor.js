// AudioWorklet: resample the mic from the context rate down to 16 kHz mono PCM,
// and emit an RMS level for client-side barge-in. Runs off the main thread.
//
// PCM crosses to the main thread in ~100 ms batches. One message per 128-sample render
// quantum meant 375 WebSocket frames/sec of ~85 bytes, where framing and TLS overhead
// dwarfed the audio itself — and each one cost a GenServer call on the server.
//
// Barge-in cannot wait for that batch: a quantum whose level crosses the gate posts an
// RMS-only message immediately, so cutting her off stays as responsive as it was.
const FRAME_SAMPLES = 1600; // 100 ms at 16 kHz

class PCMProcessor extends AudioWorkletProcessor {
  constructor(options) {
    super();
    this.ratio = sampleRate / 16000; // sampleRate = the context's native rate (e.g. 48000)
    this._frac = 0;
    this._buf = new Int16Array(FRAME_SAMPLES);
    this._len = 0;
    this._peak = 0;                  // loudest quantum in the batch, not an average of averages
    this._bargeRms = (options && options.processorOptions && options.processorOptions.bargeRms) || 0.02;
  }
  process(inputs) {
    const input = inputs[0];
    if (!input || !input[0]) return true;
    const ch = input[0];

    // naive linear decimation to 16k
    const out = [];
    let idx = this._frac;
    while (idx < ch.length) {
      out.push(ch[Math.floor(idx)]);
      idx += this.ratio;
    }
    this._frac = idx - ch.length;

    let sum = 0;
    for (let i = 0; i < out.length; i++) {
      const s = Math.max(-1, Math.min(1, out[i]));
      out[i] = s;
      sum += s * s;
    }
    const rms = out.length ? Math.sqrt(sum / out.length) : 0;
    if (rms > this._peak) this._peak = rms;

    for (let i = 0; i < out.length; i++) {
      this._buf[this._len++] = out[i] < 0 ? out[i] * 0x8000 : out[i] * 0x7fff;
      if (this._len === FRAME_SAMPLES) this._flush();
    }

    if (rms >= this._bargeRms) this.port.postMessage({ rms });   // barge-in fast path
    return true;
  }
  _flush() {
    const frame = this._buf.slice(0, this._len);   // copy: _buf is reused across batches
    this.port.postMessage({ pcm: frame.buffer, rms: this._peak }, [frame.buffer]);
    this._len = 0;
    this._peak = 0;
  }
}
registerProcessor("pcm-processor", PCMProcessor);
