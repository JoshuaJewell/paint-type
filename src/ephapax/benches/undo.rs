// SPDX-License-Identifier: PMPL-1.0-or-later
//
// Bench harness for the UndoGraph module.
//
// We deliberately avoid pulling in `criterion`: this is a baseline-only
// measurement at v0.1 with no threshold. A hand-rolled timer using
// `std::time::Instant` is plenty for grep-able TSV output.
//
// Output schema (tab-separated, one row per measurement):
//
//   bench<TAB>op<TAB>iterations<TAB>total_ns<TAB>ns_per_op
//
// Run with:  cargo bench --bench undo

use std::hint::black_box;
use std::time::Instant;

use ephapax::undo::{RevId, UndoGraph};

fn bench_commit(n: usize) {
    let mut g: UndoGraph<u64> = UndoGraph::new(0);
    let mut prev = RevId::ROOT;

    let t0 = Instant::now();
    for i in 1..=n as u64 {
        prev = g.commit(black_box(prev), black_box(i));
    }
    let elapsed = t0.elapsed();
    black_box(&g);

    let total_ns = elapsed.as_nanos() as u64;
    let per_op = if n == 0 { 0 } else { total_ns / (n as u64) };
    println!("undo_bench\tcommit\t{}\t{}\t{}", n, total_ns, per_op);
}

fn bench_checkout(graph_size: usize, n_lookups: usize) {
    // Pre-build a graph of `graph_size` revisions.
    let mut g: UndoGraph<u64> = UndoGraph::new(0);
    let mut prev = RevId::ROOT;
    for i in 1..=graph_size as u64 {
        prev = g.commit(prev, i);
    }

    // Simple LCG to keep the bench self-contained (no `rand` dep).
    let mut state: u64 = 0xDEAD_BEEF_CAFE_F00D;
    let modulus = graph_size as u64 + 1; // include root

    let t0 = Instant::now();
    let mut sink: u64 = 0;
    for _ in 0..n_lookups {
        // LCG: Numerical Recipes constants.
        state = state.wrapping_mul(1664525).wrapping_add(1013904223);
        let rev = RevId((state % modulus) as u32);
        if let Some(v) = g.checkout(black_box(rev)) {
            sink = sink.wrapping_add(*v);
        }
    }
    let elapsed = t0.elapsed();
    black_box(sink);

    let total_ns = elapsed.as_nanos() as u64;
    let per_op = if n_lookups == 0 {
        0
    } else {
        total_ns / (n_lookups as u64)
    };
    println!(
        "undo_bench\tcheckout\t{}\t{}\t{}",
        n_lookups, total_ns, per_op
    );
}

fn main() {
    // Header (tab-separated, grep-friendly).
    println!("bench\top\titerations\ttotal_ns\tns_per_op");

    // Warm-up: avoid cold-cache artifacts in the first real measurement.
    bench_commit(1_000);
    bench_checkout(1_000, 1_000);

    // Real measurements.
    bench_commit(10_000);
    bench_checkout(10_000, 1_000);
}
