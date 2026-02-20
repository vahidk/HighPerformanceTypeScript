# High-Performance TypeScript: A Hands-On Tutorial

## 1. Typed Arrays vs Regular Arrays

A regular JavaScript array is a general-purpose container — V8 picks a storage representation based on what you put in it, and re-picks it as the contents change. A typed array (`Float64Array`, `Uint32Array`, etc.) is a pre-declared block of raw bytes, like a C array. No element-kind decisions, no per-slot indirection.

```typescript
// regular-vs-typed.ts
// Run with: node --experimental-strip-types regular-vs-typed.ts
const N = 10_000_000;

function fillRegular() {
  const a = new Array<number>(N);
  for (let i = 0; i < N; i++) a[i] = i * 1.1;
  return a;
}
function sumRegular(a: number[]) {
  let s = 0;
  for (let i = 0; i < N; i++) s += a[i];
  return s;
}
function fillTyped() {
  const a = new Float64Array(N);
  for (let i = 0; i < N; i++) a[i] = i * 1.1;
  return a;
}
function sumTyped(a: Float64Array) {
  let s = 0;
  for (let i = 0; i < N; i++) s += a[i];
  return s;
}

function time(f: () => unknown) {
  const t0 = performance.now();
  f();
  return performance.now() - t0;
}
function median(xs: number[]) {
  const s = [...xs].sort((a, b) => a - b);
  return s[Math.floor(s.length / 2)];
}
function report(label: string, f: () => unknown) {
  const cold = time(f);
  for (let i = 0; i < 2; i++) f(); // warmup
  const warm = median([0, 1, 2, 3, 4].map(() => time(f)));
  console.log(`${label.padEnd(20)} cold=${cold.toFixed(1)}ms  warm=${warm.toFixed(1)}ms`);
}

let reg: number[] | null = null;
let typ: Float64Array | null = null;
report("regular array fill", () => { reg = fillRegular(); });
report("regular array sum",  () => sumRegular(reg!));
report("typed array fill",   () => { typ = fillTyped(); });
report("typed array sum",    () => sumTyped(typ!));
```

Output:

```
regular array fill   cold=20.4ms  warm=17.2ms
regular array sum    cold= 6.3ms  warm= 5.8ms
typed array fill     cold=10.4ms  warm= 5.3ms   ← 3.2x faster (warm)
typed array sum      cold= 6.2ms  warm= 5.5ms   ← dead-heat
```

The win is in the **fill**, not the sum. A regular-array store goes through V8's general-purpose path until the JIT specializes the loop; a `Float64Array` store is a single aligned 8-byte write to a pre-typed buffer from the first iteration. Once V8 has specialized the read path, sequential reads are essentially identical.

### When to use what

| Use case | Choice |
|---|---|
| Numeric buffers, aggregation accumulators | `Float64Array`, `Uint32Array`, `Int32Array` |
| Sparse data, mixed types, push/pop/shift | Regular `Array` |
| Fixed-size lookup tables (millions of entries) | `Int32Array`, `Uint32Array` |
| Data you'll `postMessage` to a worker | Typed array (so you can transfer, see Section 3) |

---

## 2. Struct-of-Arrays — Structs Without Objects

JavaScript objects carry hidden-class metadata and a per-object header (~16–24 bytes on V8). For millions of records, a separate typed array per field — the classic "Struct-of-Arrays" (SoA) layout — uses less memory, has no per-slot overhead, and is directly transferable to workers.

### Objects vs Struct-of-Arrays

```typescript
// struct-of-arrays.ts
const NUM_GROUPS = 260_000;
const NUM_ITERS = 20_000_000;

function runObjects() {
  const objects: { count: number; sum: number; min: number; max: number }[] = [];
  for (let i = 0; i < NUM_GROUPS; i++) {
    objects.push({ count: 0, sum: 0, min: Infinity, max: -Infinity });
  }
  for (let i = 0; i < NUM_ITERS; i++) {
    const g = i % NUM_GROUPS;
    const val = i * 0.001;
    objects[g].count++;
    objects[g].sum += val;
    if (val < objects[g].min) objects[g].min = val;
    if (val > objects[g].max) objects[g].max = val;
  }
  return objects[0].count;
}

function runSoA() {
  const counts = new Float64Array(NUM_GROUPS);
  const sums   = new Float64Array(NUM_GROUPS);
  const mins   = new Float64Array(NUM_GROUPS).fill(Infinity);
  const maxs   = new Float64Array(NUM_GROUPS).fill(-Infinity);
  for (let i = 0; i < NUM_ITERS; i++) {
    const g = i % NUM_GROUPS;
    const val = i * 0.001;
    counts[g]++;
    sums[g] += val;
    if (val < mins[g]) mins[g] = val;
    if (val > maxs[g]) maxs[g] = val;
  }
  return counts[0];
}

// Report cold (first run) and warm (median of 5).
function report(label: string, f: () => unknown) {
  const t0 = performance.now(); f(); const cold = performance.now() - t0;
  for (let i = 0; i < 2; i++) f();
  const runs: number[] = [];
  for (let i = 0; i < 5; i++) {
    const s = performance.now(); f(); runs.push(performance.now() - s);
  }
  runs.sort((a, b) => a - b);
  console.log(`${label.padEnd(18)} cold=${cold.toFixed(1)}ms  warm=${runs[2].toFixed(1)}ms`);
}

report("objects", runObjects);
report("struct-of-arrays", runSoA);
```

Output:

```
objects            cold=91.7ms  warm=39.2ms
struct-of-arrays   cold=38.3ms  warm=35.0ms
```

### What the numbers mean

- **Cold:** SoA is 2.4x faster. Most of this is V8 warming up — the object-version's polymorphic property accesses need inline-cache feedback before TurboFan can specialize them.
- **Warm (steady-state):** SoA is ~12% faster. Once V8 has stabilized the hidden class and inlined the property offsets, the object version is *almost* as fast as raw typed-array writes — just an extra pointer indirection per access.

**Takeaway:** don't reach for SoA purely chasing steady-state cycles on a hot loop like this — V8 is remarkably good at objects with stable shapes. Reach for SoA for the reasons below.

### Why SoA still wins in practice

1. **Memory footprint.** A million 4-field objects carries ~16 MB of V8 object headers on top of the data. An equivalent 4× `Float64Array` is pure payload (~32 MB) and has zero per-record overhead.
2. **Transferable to workers.** `postMessage(buf, [buf.buffer])` moves a typed array zero-copy (Section 3). An object graph has to be structured-cloned.
3. **GC pressure.** A million small objects = a million allocations that the GC has to walk. Typed arrays are a handful of allocations regardless of N.
4. **Faster cold path.** Startup time often matters. If your loop runs once per request, you're living in the cold-column numbers.
5. **When you read *subsets* of fields.** The hot loop above touches all 4 fields per iteration, so objects pack efficiently into cache lines either way. But if a different loop only reads `counts`, SoA fits 8 consecutive counts per 64-byte cache line while array-of-objects reads 1 count + 3 unused doubles per line — that's where the cache-line argument actually kicks in.

### When you need a single buffer

Sometimes you need all fields packed into one buffer — for example, to transfer results from a worker via `postMessage(buf, [buf.buffer])`. Use named helper functions; V8's TurboFan inlines them, so there's no overhead:

```typescript
const FIELDS = 4;
const buf = new Float64Array(NUM_GROUPS * FIELDS);

const COUNT = 0, SUM = 1, MIN = 2, MAX = 3;

function get(g: number, field: number): number {
  return buf[g * FIELDS + field];
}
function inc(g: number, field: number): void {
  buf[g * FIELDS + field]++;
}

// Reads like named fields, runs like raw index math
inc(g, COUNT);
if (val < get(g, MIN)) { /* ... */ }
```

---

## 3. Transfer Semantics — Move, Don't Copy

By default, `postMessage` deep-clones data — O(n) for large buffers. When a worker produces a result, you can **move** ownership instead of copying, the same way Rust hands ownership across a function boundary.

### Copy vs Transfer

`postMessage` sends data in two ways:

1. **Copy** (default) — deep clone via structured clone. Both sides get independent data. Simple but O(n).
2. **Transfer** (move) — zero-copy ownership transfer. The sender's buffer is detached (length becomes 0).

You can mix both in a single call — transfer the big buffers, copy the small values:

```typescript
// Copy — sender keeps its data
parentPort!.postMessage(buf);

// Transfer — sender loses access (buf.length → 0)
parentPort!.postMessage(buf, [buf.buffer]);

// Mix — transfer big buffers, copy the rest
parentPort!.postMessage(
  { big: transferred, small: copied, label: "results" },
  [transferred.buffer]  // only this one moves; small and label are cloned
);
```

The second argument is the **transfer list** — an array of `ArrayBuffer`s to move. Note that `buf` is a typed array view while `buf.buffer` is the underlying `ArrayBuffer`. Transferring the `ArrayBuffer` detaches all views pointing at it.

### Example: transferring results from a worker

```typescript
// transfer-main.ts
import { Worker } from "node:worker_threads";

const w = new Worker("./transfer-worker.ts");

w.on("message", (buf: Float64Array) => {
  console.log(`Received ${buf.length} elements`);
  console.log(`First 5: ${Array.from(buf.slice(0, 5)).map((n) => n.toFixed(2))}`);
  w.terminate();
});
```

```typescript
// transfer-worker.ts
import { parentPort } from "node:worker_threads";

// Build an 8MB buffer
const buf = new Float64Array(1_000_000);
for (let i = 0; i < buf.length; i++) buf[i] = Math.sqrt(i);

console.log(`Before transfer: buf.length = ${buf.length}`);

// Transfer (zero-copy move), NOT clone
parentPort!.postMessage(buf, [buf.buffer]);

// buf is now detached
console.log(`After transfer:  buf.length = ${buf.length}`);  // 0!
```

Output:

```
Before transfer: buf.length = 1000000
After transfer:  buf.length = 0          ← moved!
Received 1000000 elements
First 5: 0.00,1.00,1.41,1.73,2.00
```

---

## 4. SharedArrayBuffer — Zero-Copy Shared Memory

When multiple workers need to **read** the same large dataset, copying it to each worker wastes memory. `SharedArrayBuffer` lets all threads access the same physical memory — no copy, no transfer.

### Demo: workers reading shared data

```typescript
// shared-main.ts
import { Worker } from "node:worker_threads";

const N = 1_000_000;

// Create shared memory and fill it
const sab = new SharedArrayBuffer(N * 4);
const data = new Uint32Array(sab);
for (let i = 0; i < N; i++) data[i] = i;

// Spawn 4 workers — each sums a quarter of the array
const chunkSize = N / 4;
const promises: Promise<number>[] = [];

for (let t = 0; t < 4; t++) {
  promises.push(
    new Promise((resolve) => {
      const w = new Worker("./shared-worker.ts", {
        workerData: { sab, start: t * chunkSize, end: (t + 1) * chunkSize },
      });
      w.on("message", (sum: number) => {
        resolve(sum);
        w.terminate();
      });
    })
  );
}

const results = await Promise.all(promises);
const total = results.reduce((a, b) => a + b, 0);
console.log(`Sum of 0..${N - 1} = ${total}`);
console.log(`Expected:          ${(N * (N - 1)) / 2}`);
```

```typescript
// shared-worker.ts
import { parentPort, workerData } from "node:worker_threads";

const { sab, start, end } = workerData as {
  sab: SharedArrayBuffer;
  start: number;
  end: number;
};

// Create a VIEW over the shared memory — no copy
const data = new Uint32Array(sab);

let sum = 0;
for (let i = start; i < end; i++) sum += data[i];

parentPort!.postMessage(sum);
```

Run it:

```bash
node --experimental-strip-types shared-main.ts
```

Output:

```
Sum of 0..999999 = 499999500000
Expected:          499999500000
```

Key point: the `Uint32Array(sab)` in each worker is a **view** over the same physical memory. The buffer is 4 MB; all four workers see the same 4 MB. With copies you'd pay 16 MB.

> **When to use which:** Prefer Transfer (Section 3) when a worker produces a result and sends it back — it's simpler and avoids concurrent access bugs. Use `SharedArrayBuffer` when multiple workers need to **read the same input data simultaneously**, like the example above.

---

## 5. Long-Lived Worker Pool

Spawning a worker creates a new V8 isolate, loads the script, and pays initial JIT cost — single-digit ms per worker on a warm box, but multiplied by every spawn. If you have several parallel phases, reuse the same workers instead.

### Slow: spawn new workers per phase

```typescript
// spawn-main.ts
import { Worker } from "node:worker_threads";

const TASKS_PER_PHASE = 4;

console.time("respawn workers (2 phases)");
for (let phase = 0; phase < 2; phase++) {
  const promises: Promise<number>[] = [];
  for (let t = 0; t < TASKS_PER_PHASE; t++) {
    promises.push(
      new Promise((resolve) => {
        const w = new Worker("./spawn-worker.ts", {
          workerData: { value: phase * 100 + t },
        });
        w.on("message", (r: number) => { resolve(r); w.terminate(); });
      })
    );
  }
  await Promise.all(promises);
}
console.timeEnd("respawn workers (2 phases)");
```

```typescript
// spawn-worker.ts
import { parentPort, workerData } from "node:worker_threads";

const { value } = workerData as { value: number };
let sum = 0;
for (let i = 0; i < 100_000; i++) sum += Math.sqrt(i + value);
parentPort!.postMessage(sum);
```

### Fast: reuse workers across phases

```typescript
// pool-main.ts
import { Worker } from "node:worker_threads";

const NUM_WORKERS = 4;
const workers: Worker[] = [];
for (let i = 0; i < NUM_WORKERS; i++) {
  workers.push(new Worker("./pool-worker.ts"));
}

function dispatch(tasks: number[]): Promise<number[]> {
  return Promise.all(
    workers.map(
      (w, i) =>
        new Promise<number>((resolve) => {
          w.once("message", resolve);
          w.postMessage(tasks[i]);
        })
    )
  );
}

console.time("reuse workers (2 phases)");
await dispatch([10, 20, 30, 40]);  // phase 1
await dispatch([50, 60, 70, 80]);  // phase 2
console.timeEnd("reuse workers (2 phases)");

for (const w of workers) w.terminate();
```

```typescript
// pool-worker.ts
import { parentPort } from "node:worker_threads";

parentPort!.on("message", (value: number) => {
  let sum = 0;
  for (let i = 0; i < 100_000; i++) sum += Math.sqrt(i + value);
  parentPort!.postMessage(sum);
});
```

Output (median of 5 runs each):

```
respawn workers (2 phases): 52.9ms
reuse workers (2 phases):   25.7ms   ← 2.1x faster
```

The per-task work is trivial here — the gap is pure spawn cost. With heavier work the ratio shrinks, but the absolute savings compound in multi-phase pipelines: every phase you add pays the spawn tax again in the naive version, while the pool version pays it once.

---

## 6. Array as queue

`Array.shift()` is O(n) because it moves every remaining element forward. For BFS over a well-connected graph, this is catastrophic.

```typescript
// bfs-queue.ts
// Build a random graph where BFS wavefront gets large (wide, not linear)
const N = 200_000;
const EDGES_PER_NODE = 20;

// Math.imul: correct 32-bit multiply (regular * loses precision beyond 2^53)
function hash(n: number): number {
  n = Math.imul(n, 0x9e3779b9);
  n = (n ^ (n >>> 16)) >>> 0;
  return n;
}

const adj: number[][] = Array.from({ length: N }, () => []);
for (let i = 0; i < N; i++) {
  for (let e = 0; e < EDGES_PER_NODE; e++) {
    const target = hash(i * EDGES_PER_NODE + e) % N;
    if (target !== i) adj[i].push(target);
  }
}

// ── Slow: shift() — O(n) per dequeue ─────────────────────────────
console.time("BFS with shift()");
{
  const dist = new Int32Array(N).fill(-1);
  const queue: number[] = [0];
  dist[0] = 0;
  while (queue.length > 0) {
    const node = queue.shift()!; // O(n) — moves all elements
    for (const nbr of adj[node]) {
      if (dist[nbr] === -1) {
        dist[nbr] = dist[node] + 1;
        queue.push(nbr);
      }
    }
  }
}
console.timeEnd("BFS with shift()");

// ── Fast: head pointer — O(1) per dequeue ─────────────────────────
console.time("BFS with head pointer");
{
  const dist = new Int32Array(N).fill(-1);
  const queue: number[] = [0];
  let head = 0; // just advance an index
  dist[0] = 0;
  while (head < queue.length) {
    const node = queue[head++]; // O(1)
    for (const nbr of adj[node]) {
      if (dist[nbr] === -1) {
        dist[nbr] = dist[node] + 1;
        queue.push(nbr);
      }
    }
  }
}
console.timeEnd("BFS with head pointer");
```

Output:

```
BFS with shift():       2085.0ms
BFS with head pointer:    47.9ms   ← 43x faster
```

The random graph with 20 edges per node means the BFS wavefront grows to ~200K nodes in the queue. Each `shift()` has to move them all — O(n²) total. The head pointer just increments an integer — O(n) total.

The trade-off: the "consumed" elements linger in memory until the array is GC'd. For a 200K BFS, that's ~1.6 MB of dead entries — negligible compared to a 43x speedup.

---

## Putting It All Together

This example combines techniques #1–#5: a long-lived worker pool (#5) generates input in parallel using all cores, each worker aggregates into Struct-of-Arrays typed arrays (#1, #2), and transfers results back zero-copy (#3). On the second dispatch, workers reuse cached input — no regeneration.

```typescript
// capstone-main.ts
import { Worker } from "node:worker_threads";
import { cpus } from "node:os";
import { performance } from "node:perf_hooks";

const NUM_RECORDS = 50_000_000;
const NUM_BUCKETS = 1000;
const numCPUs = cpus().length;
const chunkSize = Math.ceil(NUM_RECORDS / numCPUs);

const totalStart = performance.now();

// Worker Pool: spawn once, reuse across phases
const workers: Worker[] = [];
for (let i = 0; i < numCPUs; i++) {
  workers.push(new Worker("./capstone-worker.ts"));
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

// Phase 2: workers re-aggregate from cached input (pool reuse)
const results2 = await dispatch();

// Struct-of-Arrays: merge with separate typed arrays
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

for (const w of workers) w.terminate();
const totalMs = performance.now() - totalStart;
console.log(`Total: ${totalMs.toFixed(0)}ms  Cores: ${numCPUs}`);
```

```typescript
// capstone-worker.ts
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
```

### Results (Apple M5 Max, 18 cores, 50M records)

How TypeScript compares to the same workload ported to C++, Rust, and Python:

| | C++ | Rust | TS (Bun) | TS (Node.js) | Python |
|---|---|---|---|---|---|
| **avg** | **25ms** | **25ms** | **55ms** | **91ms** | **1263ms** |
| **best** | **25ms** | **24ms** | **55ms** | **90ms** | **1248ms** |
| **vs C++** | 1.0x | 1.0x | 2.2x | 3.6x | 50.5x |

With the techniques in this tutorial applied, TypeScript lands within ~2x of native code on Bun and ~4x on Node — close enough that for most data-heavy workloads, the choice of algorithm and memory layout matters more than the choice of language.

Run `./benchmark.sh` to reproduce.

---

## Summary Cheat Sheet

All numbers measured on Apple M5 Max / Node 22.19. "Warm" = median of 5 steady-state runs; "cold" = first run (includes JIT).

| # | Technique | Slow | Fast | Measured Speedup |
|---|---|---|---|---|
| 1 | Typed arrays | `number[]` | `Float64Array` | **3.2x on writes (warm)**, reads dead-heat |
| 2 | Struct-of-Arrays | Array of objects | Separate typed arrays per field | **2.4x cold / ~1.1x warm** — real wins are memory, transferability, GC |
| 3 | Transfer semantics | Structured clone | `postMessage(buf, [buf.buffer])` | zero copy |
| 4 | SharedArrayBuffer | Duplicate data per worker | Shared memory views | zero copy |
| 5 | Worker pool | Spawn per task | Long-lived + dispatch | **2.1x** on overhead |
| 6 | Array as queue | `Array.shift()` | `queue[head++]` | **43x** |
