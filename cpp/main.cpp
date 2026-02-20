#include <cmath>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <thread>
#include <vector>

static constexpr int NUM_BUCKETS = 1000;

inline uint32_t hash_u32(uint32_t n) {
    n *= 0x9E3779B9u;
    return n >> 16;
}

struct WorkerResult {
    std::vector<double> counts;
    std::vector<double> sums;
};

void worker(int start, int end, const double* input, WorkerResult& result) {
    result.counts.assign(NUM_BUCKETS, 0.0);
    result.sums.assign(NUM_BUCKETS, 0.0);

    for (int i = start; i < end; i++) {
        uint32_t h = hash_u32(static_cast<uint32_t>(i));
        int bucket = h % NUM_BUCKETS;
        result.counts[bucket] += 1.0;
        result.sums[bucket] += input[i - start];
    }
}

int main(int argc, char* argv[]) {
    int num_records = (argc > 1) ? std::atoi(argv[1]) : 50'000'000;
    int num_threads = static_cast<int>(std::thread::hardware_concurrency());
    int chunk_size = (num_records + num_threads - 1) / num_threads;

    auto total_start = std::chrono::high_resolution_clock::now();

    // Generate input in parallel — each thread generates its own chunk
    std::vector<std::vector<double>> inputs(num_threads);
    {
        std::vector<std::thread> threads;
        for (int t = 0; t < num_threads; t++) {
            int start = t * chunk_size;
            int end = std::min(start + chunk_size, num_records);
            threads.emplace_back([&inputs, t, start, end]() {
                int len = end - start;
                inputs[t].resize(len);
                for (int i = 0; i < len; i++) {
                    int idx = start + i;
                    inputs[t][i] = std::sin(idx * 0.001) * std::cos(idx * 0.0007);
                }
            });
        }
        for (auto& th : threads) th.join();
    }

    auto gen_end = std::chrono::high_resolution_clock::now();
    double gen_ms = std::chrono::duration<double, std::milli>(gen_end - total_start).count();

    // Run aggregation twice — reuse threads like a pool
    auto phase_start = std::chrono::high_resolution_clock::now();

    std::vector<std::vector<WorkerResult>> all_results(2, std::vector<WorkerResult>(num_threads));

    for (int phase = 0; phase < 2; phase++) {
        std::vector<std::thread> threads;
        for (int t = 0; t < num_threads; t++) {
            int start = t * chunk_size;
            int end = std::min(start + chunk_size, num_records);
            threads.emplace_back(worker, start, end, inputs[t].data(), std::ref(all_results[phase][t]));
        }
        for (auto& th : threads) th.join();
    }

    auto phase_end = std::chrono::high_resolution_clock::now();
    double phase_ms = std::chrono::duration<double, std::milli>(phase_end - phase_start).count();

    // Merge
    auto merge_start = std::chrono::high_resolution_clock::now();
    std::vector<double> counts(NUM_BUCKETS, 0.0);
    std::vector<double> sums(NUM_BUCKETS, 0.0);
    for (auto& phase_results : all_results) {
        for (auto& wr : phase_results) {
            for (int b = 0; b < NUM_BUCKETS; b++) {
                counts[b] += wr.counts[b];
                sums[b] += wr.sums[b];
            }
        }
    }
    auto merge_end = std::chrono::high_resolution_clock::now();
    double merge_ms = std::chrono::duration<double, std::milli>(merge_end - merge_start).count();

    auto total_end = std::chrono::high_resolution_clock::now();
    double total_ms = std::chrono::duration<double, std::milli>(total_end - total_start).count();

    std::fprintf(stderr, "Generate (par):    %.0fms\n", gen_ms);
    std::fprintf(stderr, "2 phases (pool):   %.0fms\n", phase_ms);
    std::fprintf(stderr, "Merge (SoA):       %.0fms\n", merge_ms);
    std::fprintf(stderr, "Total:             %.0fms\n", total_ms);
    std::fprintf(stderr, "Cores:             %d\n", num_threads);
    std::fprintf(stderr, "TOTAL_MS:%.0f\n", total_ms);

    return 0;
}
