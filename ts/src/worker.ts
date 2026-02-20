import { parentPort } from "node:worker_threads";

let cachedInput: Float64Array | null = null;
let cachedStart = 0;

parentPort!.on("message", (msg: {
  start: number; end: number; numBuckets: number;
}) => {
  const { start, end, numBuckets } = msg;
  const len = end - start;

  // Generate input on first call, cache for subsequent dispatches
  if (!cachedInput || cachedStart !== start) {
    cachedInput = new Float64Array(len);
    cachedStart = start;
    for (let i = 0; i < len; i++) {
      const idx = start + i;
      cachedInput[i] = Math.sin(idx * 0.001) * Math.cos(idx * 0.0007);
    }
  }

  // Struct-of-Arrays: separate typed array per field
  const counts = new Float64Array(numBuckets);
  const sums = new Float64Array(numBuckets);

  for (let i = 0; i < len; i++) {
    const h = Math.imul(start + i, 0x9e3779b9) >>> 16;
    const bucket = h % numBuckets;
    counts[bucket]++;
    sums[bucket] += cachedInput[i];
  }

  // Transfer: zero-copy move to main thread
  parentPort!.postMessage(
    { counts, sums },
    [counts.buffer, sums.buffer]
  );
});
