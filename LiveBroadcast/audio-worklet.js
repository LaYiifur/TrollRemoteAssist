'use strict';

class LivetestPCMProcessor extends AudioWorkletProcessor {
  constructor() {
    super();
    this.capacity = Math.max(4096, Math.round(sampleRate * 0.25));
    this.target = Math.max(1024, Math.round(sampleRate * 0.06));
    this.left = new Float32Array(this.capacity);
    this.right = new Float32Array(this.capacity);
    this.read = 0;
    this.write = 0;
    this.available = 0;
    this.primed = false;
    this.underrun = 0;
    this.overflow = 0;
    this.cycles = 0;
    this.port.onmessage = event => {
      const message = event.data || {};
      if (message.type === 'clear') this.clear();
      else if (message.type === 'pcm' && message.pcm) this.push(message.pcm);
    };
  }

  clear() {
    this.read = this.write = this.available = 0;
    this.primed = false;
    this.underrun = this.overflow = 0;
  }

  push(pcm) {
    let frames = pcm.length >> 1;
    let start = 0;
    if (frames > this.capacity) {
      start = (frames - this.capacity) * 2;
      frames = this.capacity;
    }
    const excess = Math.max(0, this.available + frames - this.capacity);
    if (excess) {
      this.read = (this.read + excess) % this.capacity;
      this.available -= excess;
      this.overflow += excess;
    }
    for (let index = 0; index < frames; index++) {
      this.left[this.write] = pcm[start + index * 2];
      this.right[this.write] = pcm[start + index * 2 + 1];
      this.write = (this.write + 1) % this.capacity;
    }
    this.available += frames;
    if (!this.primed && this.available >= this.target) this.primed = true;
  }

  process(inputs, outputs) {
    const output = outputs[0];
    if (!output || !output.length) return true;
    const left = output[0];
    const right = output[1] || output[0];
    left.fill(0);
    if (right !== left) right.fill(0);
    if (this.primed) {
      const count = Math.min(left.length, this.available);
      for (let index = 0; index < count; index++) {
        left[index] = this.left[this.read];
        right[index] = this.right[this.read];
        this.read = (this.read + 1) % this.capacity;
      }
      this.available -= count;
      if (count < left.length) {
        this.underrun++;
        this.primed = false;
      }
    }
    if (++this.cycles % 100 === 0)
      this.port.postMessage({underrun:this.underrun, overflow:this.overflow, buffered:this.available});
    return true;
  }
}

registerProcessor('livetest-pcm', LivetestPCMProcessor);
