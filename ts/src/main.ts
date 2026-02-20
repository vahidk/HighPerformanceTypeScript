import { Worker } from "node:worker_threads";
import { cpus } from "node:os";
import { performance } from "node:perf_hooks";

const NUM_RECORDS = parseInt(process.argv[2] || "50000000");
const NUM_BUCKETS = 1000;
const numCPUs = cpus().length;
const chunkSize = Math.ceil(NUM_RECORDS / numCPUs);

const totalStart = performance.now();

// Worker Pool: spawn once, reuse across phases
// Workers generate their own input chunk (parallel), then aggregate
const workers: Worker[] = [];
for (let i = 0; i < numCPUs; i++) {
  workers.push(new Worker(new URL("./worker.js", import.meta.url)));
}

interface Result { counts: Float64Array; sums: Float64Array }

function dispatch(): Promise<Result[]> {
  return Promise.all(
    workers.map((w, t) => new Promise<Result>((resolve) => {
      w.once("message", resolve);
      const start = t * chunkSize;
      const end = Math.min(start + chunkSize, NUM_RECORDS);
      w.postMessage({ start, end, numBuckets: NUM_BUCKETS });
    }))
  );
}

// Phase 1: workers generate input + aggregate (all cores used)
const results1 = await dispatch();
const genAndPhase1Ms = performance.now() - totalStart;

// Phase 2: workers re-aggregate from cached input (pool reuse)
const phase2Start = performance.now();
const results2 = await dispatch();
const phase2Ms = performance.now() - phase2Start;

// Struct-of-Arrays: merge with separate typed arrays
const mergeStart = performance.now();
const counts = new Float64Array(NUM_BUCKETS);
const sums = new Float64Array(NUM_BUCKETS);
for (const results of [results1, results2]) {
  for (const wr of results) {
    for (let b = 0; b < NUM_BUCKETS; b++) {
      counts[b] += wr.counts[b];
      sums[b] += wr.sums[b];
    }
  }
}
const mergeMs = performance.now() - mergeStart;

for (const w of workers) w.terminate();

const totalMs = performance.now() - totalStart;

console.error(`Gen + phase 1:     ${genAndPhase1Ms.toFixed(0)}ms`);
console.error(`Phase 2 (warm):    ${phase2Ms.toFixed(0)}ms`);
console.error(`Merge (SoA):       ${mergeMs.toFixed(0)}ms`);
console.error(`Total:             ${totalMs.toFixed(0)}ms`);
console.error(`Cores:             ${numCPUs}`);
console.error(`TOTAL_MS:${totalMs.toFixed(0)}`);
