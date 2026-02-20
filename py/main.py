import math
import time
import sys
from multiprocessing import Pool, cpu_count

NUM_RECORDS = int(sys.argv[1]) if len(sys.argv) > 1 else 50_000_000
NUM_BUCKETS = 1000


def hash_u32(n):
    return ((n * 0x9E3779B9) & 0xFFFFFFFF) >> 16


# Persists across phases within each pool worker process (matches TS worker caching).
_input_cache: dict[int, list[float]] = {}


def worker(args):
    start, end, num_buckets = args

    input_arr = _input_cache.get(start)
    if input_arr is None:
        input_arr = [
            math.sin(i * 0.001) * math.cos(i * 0.0007)
            for i in range(start, end)
        ]
        _input_cache[start] = input_arr

    counts = [0.0] * num_buckets
    sums = [0.0] * num_buckets

    for i in range(len(input_arr)):
        h = hash_u32(start + i)
        bucket = h % num_buckets
        counts[bucket] += 1.0
        sums[bucket] += input_arr[i]

    return (counts, sums)


def main():
    num_cpus = cpu_count()
    chunk_size = NUM_RECORDS // num_cpus

    total_start = time.perf_counter()

    tasks = []
    for t in range(num_cpus):
        start = t * chunk_size
        end = NUM_RECORDS if t == num_cpus - 1 else start + chunk_size
        tasks.append((start, end, NUM_BUCKETS))

    # Run both phases with the same pool
    all_results = []
    with Pool(num_cpus) as pool:
        for _ in range(2):
            results = pool.map(worker, tasks)
            all_results.append(results)
    phase_ms = (time.perf_counter() - total_start) * 1000

    # Merge
    merge_start = time.perf_counter()
    counts = [0.0] * NUM_BUCKETS
    sums = [0.0] * NUM_BUCKETS
    for phase_results in all_results:
        for c, s in phase_results:
            for b in range(NUM_BUCKETS):
                counts[b] += c[b]
                sums[b] += s[b]
    merge_ms = (time.perf_counter() - merge_start) * 1000

    total_ms = (time.perf_counter() - total_start) * 1000

    print(f"2 phases (pool):   {phase_ms:.0f}ms", file=sys.stderr)
    print(f"Merge (SoA):       {merge_ms:.0f}ms", file=sys.stderr)
    print(f"Total:             {total_ms:.0f}ms", file=sys.stderr)
    print(f"Cores:             {num_cpus}", file=sys.stderr)
    print(f"TOTAL_MS:{total_ms:.0f}", file=sys.stderr)


if __name__ == "__main__":
    main()
