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
// The batch size is NOT a constant here any more: it is a latency knob, set by
// FRAME_SAMPLES in .env and delivered through /config.json. Smaller shortens the tail
// of an utterance but multiplies the frame rate — measured, 160 samples made latency
// roughly 15x worse. 1600 is the default and the value everything was tuned against.
const DEFAULT_FRAME_SAMPLES = 1600; // 100 ms at 16 kHz
const HOLD_QUANTA = 3;      // ~8 ms at 48 kHz — below this it is a click, not a word
const RELEASE_RATIO = 0.6;  // hysteresis: fall this far before the gate can re-arm
const MAX_UTTERANCE_MS = 30000; // nobody talks this long; past it, close the turn anyway

class PCMProcessor extends AudioWorkletProcessor {
  constructor(options) {
    super();
    this.ratio = sampleRate / 16000; // sampleRate = the context's native rate (e.g. 48000)
    this._frac = 0;
    const opts = (options && options.processorOptions) || {};
    this._frameSamples = opts.frameSamples || DEFAULT_FRAME_SAMPLES;
    // Manual turn mode: this gate decides when your sentence ended, in place of the
    // provider's server VAD. Measured worth 833 ms on xAI. The budget is the SAME
    // silence the server used, so the trade is only about who is watching, not how long.
    this._silenceQuanta = Math.round(((opts.silenceMs || 400) * sampleRate) / 128 / 1000);
    // No server-side safety net exists in manual mode — idle_timeout_ms lives inside the
    // turn_detection this mode turns off. If the gate never closes, the turn never ends
    // and she waits forever. This is that net.
    this._maxQuanta = Math.round((MAX_UTTERANCE_MS * sampleRate) / 128 / 1000);
    this._below = 0;   // consecutive quanta under the release level
    this._openFor = 0; // quanta this utterance has been open
    this._buf = new Int16Array(this._frameSamples);
    this._scratch = new Float32Array(128); // one render quantum, decimation only shrinks
    this._len = 0;
    this._above = 0;                 // consecutive quanta over the gate
    this._open = false;              // true once this utterance has already been reported
    this._bargeRms = opts.bargeRms || 0.02;
  }
  process(inputs) {
    const input = inputs[0];
    if (!input || !input[0]) return true;
    const ch = input[0];

    // naive linear decimation to 16k, into a preallocated scratch buffer.
    // process() runs ~375 times a second on the realtime audio thread; a fresh array and
    // its push() growth every quantum is garbage the collector has to take back there,
    // of all places. _scratch is sized once — a 128-sample quantum can never decimate to
    // more than 128 samples, whatever the context rate.
    const out = this._scratch;
    let n = 0;
    let idx = this._frac;
    while (idx < ch.length) {
      out[n++] = ch[Math.floor(idx)];
      idx += this.ratio;
    }
    this._frac = idx - ch.length;

    // One pass, not three: clamp, accumulate the RMS, and write the sample out.
    let sum = 0;
    for (let i = 0; i < n; i++) {
      const s = Math.max(-1, Math.min(1, out[i]));
      sum += s * s;
      this._buf[this._len++] = s < 0 ? s * 0x8000 : s * 0x7fff;
      if (this._len === this._frameSamples) this._flush();
    }
    const rms = n ? Math.sqrt(sum / n) : 0;

    if (rms >= this._bargeRms) {
      this._above++;
      this._below = 0;
      if (this._above === HOLD_QUANTA && !this._open) {
        this._open = true;
        this._openFor = 0;
        this.port.postMessage({ barge: true, rms });              // once per utterance
      }
    } else if (rms < this._bargeRms * RELEASE_RATIO) {
      this._above = 0;
      // The falling edge, and the only place a turn can end. It fires ONCE per utterance
      // — _open is cleared with it — so a long pause cannot commit the same turn twice.
      if (this._open && ++this._below >= this._silenceQuanta) this._endTurn();
    }

    if (this._open && ++this._openFor >= this._maxQuanta) this._endTurn();
    return true;
  }
  _endTurn() {
    this._open = false;
    this._below = 0;
    this._openFor = 0;
    this._flush();                          // whatever is buffered belongs to this turn
    this.port.postMessage({ endOfSpeech: true });
  }
  _flush() {
    if (!this._len) return;                 // _endTurn can land on an empty buffer
    const frame = this._buf.slice(0, this._len);   // copy: _buf is reused across batches
    // No rms here any more. It used to carry the batch PEAK, which crossed the gate far
    // more readily than an instantaneous reading and made barge-in fire on room noise.
    this.port.postMessage({ pcm: frame.buffer }, [frame.buffer]);
    this._len = 0;
  }
}
registerProcessor("pcm-processor", PCMProcessor);
