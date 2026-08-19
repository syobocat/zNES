// The audio device's end of the queue: a ring buffer the emulator fills a
// frame at a time and the audio thread drains 128 samples at a time.
//
// The two threads do not share memory. A SharedArrayBuffer would let them,
// but it is only available to a cross-origin-isolated page, which means
// serving COOP and COEP headers -- something a plain static host may well not
// let you do. Samples are transferred by `postMessage` instead, which costs
// nothing per sample (the buffer is moved, not copied) and asks nothing of
// the server.
//
// What the emulator needs back is how full the queue is, so it can steer its
// resampling ratio (see `App.effectiveSampleRate`). That travels as a running
// total of samples consumed rather than as a fill level, because a total is
// immune to the messages arriving out of step with the writes: the main
// thread knows how much it has written, and the difference is the answer.

// How many quanta to render between reports. At 128 samples each and 44100
// samples a second, 16 quanta is about 46 ms -- a rounding error next to the
// two-second time constant of the feedback that consumes it.
const REPORT_INTERVAL = 16;

// Ring capacity, in samples: about half a second. Deep enough that a slow
// frame cannot overflow it, which would cost audio the emulator has already
// produced.
const CAPACITY = 24576;

class ZnesProcessor extends AudioWorkletProcessor {
  constructor() {
    super();
    this.ring = new Float32Array(CAPACITY);
    this.read = 0;
    this.write = 0;
    this.available = 0;
    this.consumed = 0;
    this.quanta = 0;

    this.port.onmessage = ({ data }) => {
      if (data === "clear") {
        this.read = 0;
        this.write = 0;
        this.available = 0;
        this.consumed = 0;
        this.port.postMessage(this.consumed);
        return;
      }
      this.push(data);
    };
  }

  push(samples) {
    for (let i = 0; i < samples.length; i++) {
      // A full ring drops the oldest sample rather than the newest: the
      // newest is the one the emulator is about to need.
      if (this.available === CAPACITY) {
        this.read = (this.read + 1) % CAPACITY;
        this.available--;
      }
      this.ring[this.write] = samples[i];
      this.write = (this.write + 1) % CAPACITY;
      this.available++;
    }
  }

  process(inputs, outputs) {
    const channel = outputs[0][0];
    for (let i = 0; i < channel.length; i++) {
      if (this.available === 0) {
        // Underrun. Silence is the only honest answer, and the emulator will
        // see the queue empty and speed up to refill it.
        channel[i] = 0;
        continue;
      }
      channel[i] = this.ring[this.read];
      this.read = (this.read + 1) % CAPACITY;
      this.available--;
      this.consumed++;
    }

    if (++this.quanta >= REPORT_INTERVAL) {
      this.quanta = 0;
      this.port.postMessage(this.consumed);
    }
    return true;
  }
}

registerProcessor("znes", ZnesProcessor);
