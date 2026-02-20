use rayon::prelude::*;
use std::time::Instant;

const NUM_BUCKETS: usize = 1000;

#[inline]
fn hash_u32(n: u32) -> u32 {
    n.wrapping_mul(0x9E3779B9) >> 16
}

fn main() {
    let num_records: usize = std::env::args()
        .nth(1)
        .and_then(|v| v.parse().ok())
        .unwrap_or(50_000_000);
    let num_threads = rayon::current_num_threads();
    let total_start = Instant::now();

    // Generate input in parallel — all cores used
    let input: Vec<f64> = (0..num_records)
        .into_par_iter()
        .map(|i| (i as f64 * 0.001).sin() * (i as f64 * 0.0007).cos())
        .collect();
    let gen_ms = total_start.elapsed().as_secs_f64() * 1000.0;

    // Run aggregation twice (rayon's pool is always warm)
    let phase_start = Instant::now();
    let chunk_size = num_records / num_threads;

    let mut all_results = Vec::new();
    for _ in 0..2 {
        let phase_results: Vec<(Vec<f64>, Vec<f64>)> = (0..num_threads)
            .into_par_iter()
            .map(|t| {
                let start = t * chunk_size;
                let end = if t == num_threads - 1 { num_records } else { start + chunk_size };

                let mut counts = vec![0.0f64; NUM_BUCKETS];
                let mut sums = vec![0.0f64; NUM_BUCKETS];

                for i in start..end {
                    let h = hash_u32(i as u32);
                    let bucket = (h as usize) % NUM_BUCKETS;
                    counts[bucket] += 1.0;
                    sums[bucket] += input[i]; // shared read — no copy
                }

                (counts, sums)
            })
            .collect();
        all_results.push(phase_results);
    }
    let phase_ms = phase_start.elapsed().as_secs_f64() * 1000.0;

    // Merge
    let merge_start = Instant::now();
    let mut counts = vec![0.0f64; NUM_BUCKETS];
    let mut sums = vec![0.0f64; NUM_BUCKETS];
    for phase_results in &all_results {
        for (c, s) in phase_results {
            for b in 0..NUM_BUCKETS {
                counts[b] += c[b];
                sums[b] += s[b];
            }
        }
    }
    let merge_ms = merge_start.elapsed().as_secs_f64() * 1000.0;

    let total_ms = total_start.elapsed().as_secs_f64() * 1000.0;

    eprintln!("Generate (par):    {:.0}ms", gen_ms);
    eprintln!("2 phases (pool):   {:.0}ms", phase_ms);
    eprintln!("Merge (SoA):       {:.0}ms", merge_ms);
    eprintln!("Total:             {:.0}ms", total_ms);
    eprintln!("Cores:             {}", num_threads);
    eprintln!("TOTAL_MS:{:.0}", total_ms);
}
