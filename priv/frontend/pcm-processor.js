// AudioWorklet: resample the mic from the context rate down to 16 kHz mono PCM,
// and emit an RMS level for client-side barge-in. Runs off the main thread.
//
// PCM crosses to the main thread in ~100 ms batches. One message per 128-sample render
// quantum meant 375 WebSocket frames/sec of ~85 bytes, where framing and TLS overhead
// dwarfed the audio itself — and each one cost a GenServer call on the server.
//
// Barge-in cannot wait for that batch, so it posts its own message the moment speech
// starts. It fires on the RISING EDGE only: while the level stays up, the utterance is
// already known to be in progress and repeating the message just kills the voice frames
// that arrived since. HOLD_QUANTA rejects single-sample spikes, and releasing at a lower
// level than it triggers stops it chattering around the threshold.
const FRAME_SAMPLES = 1600; // 100 ms at 16 kHz
const HOLD_QUANTA = 3;      // ~8 ms at 48 kHz — below this it is a click, not a word
const RELEASE_RATIO = 0.6;  // hysteresis: fall this far before the gate can re-arm

class PCMProcessor extends AudioWorkletProcessor {
  constructor(options) {
    super();
    this.ratio = sampleRate / 16000; // sampleRate = the context's native rate (e.g. 48000)
    this._frac = 0;
    this._buf = new Int16Array(FRAME_SAMPLES);
    this._len = 0;
    this._above = 0;                 // consecutive quanta over the gate
    this._open = false;              // true once this utterance has already been reported
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

    for (let i = 0; i < out.length; i++) {
      this._buf[this._len++] = out[i] < 0 ? out[i] * 0x8000 : out[i] * 0x7fff;
      if (this._len === FRAME_SAMPLES) this._flush();
    }

    if (rms >= this._bargeRms) {
      this._above++;
      if (this._above === HOLD_QUANTA && !this._open) {
        this._open = true;
        this.port.postMessage({ barge: true, rms });              // once per utterance
      }
    } else if (rms < this._bargeRms * RELEASE_RATIO) {
      this._above = 0;
      this._open = false;
    }
    return true;
  }
  _flush() {
    const frame = this._buf.slice(0, this._len);   // copy: _buf is reused across batches
    // No rms here any more. It used to carry the batch PEAK, which crossed the gate far
    // more readily than an instantaneous reading and made barge-in fire on room noise.
    this.port.postMessage({ pcm: frame.buffer }, [frame.buffer]);
    this._len = 0;
  }
}
registerProcessor("pcm-processor", PCMProcessor);
