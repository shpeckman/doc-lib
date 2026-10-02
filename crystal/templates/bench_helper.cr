# bench/bench_helper.cr
require "benchmark"
require "../src/my_project"

# Benchmark
# =========
# 
# Benchmarking utilities for Crystal code, reporting time and memory per task. 
# 
# > Always benchmark with `--release`. `bm` and `ips` warn otherwise, since non-release results are meaningless.
# 
# Iterations per second
# ---------------------
# 
# `Benchmark.ips` reports iterations/second, mean time per iteration, relative standard deviation, bytes/op, and a comparison against the fastest task:
# 
#     ```crystal
#     Benchmark.ips do |x|
#       x.report("short sleep") { sleep 10.milliseconds }
#       x.report("shorter sleep") { sleep 1.millisecond }
#     end
#     ```
# 
#     ```text
#       short sleep   88.7  ( 11.27ms) (± 3.33%)  8.90× slower
#     shorter sleep  789.7  (  1.27ms) (± 3.02%)       fastest
#     ```
# 
# A warmup stage (default 2s) finds how many cycles run each block for ~100ms; the calculation stage (default 5s) runs those sets to compute the statistics. 
# Both durations are configurable:
# 
#     ```crystal
#     Benchmark.ips(warmup: 4.seconds, calculation: 10.seconds) do |x|
#       x.report("sleep") { sleep 10.milliseconds }
#     end
#     ```
# 
# Sequential experiments
# ----------------------
# 
# `Benchmark.bm` runs experiments in sequence, printing a labeled column report of user/system/total/real time:
# 
#     ```crystal
#     Benchmark.bm do |x|
#       x.report("times:") { n.times { a = "1" } }
#       x.report("upto:")  { 1.upto(n) { a = "1" } }
#     end
#     ```
# 
#     ```text
#                user     system      total        real
#     times:   0.010000   0.000000   0.010000 (  0.008976)
#     upto:    0.010000   0.000000   0.010000 (  0.010466)
#     ```
# 
# One-off measurements
# --------------------
# 
#     ```crystal
#     Benchmark.measure { "a" * 1_000_000_000 } # => BM::Tms (user/system/total/real, in seconds)
#     Benchmark.realtime { "a" * 100_000 }      # => 00:00:00.0005840
#     Benchmark.memory { Array(Int32).new }     # => 32  (bytes)
#     ```
# 
# Module methods:
#   `bm(&block) : BM::Job`
#   Yields a `BM::Job`; report units, then executes and returns it.
#   
#   `ips(calculation = 5.seconds, warmup = 2.seconds, interactive = STDOUT.tty?, &block) : IPS::Job`
#   Yields an `IPS::Job`; reports each block, executes, prints, and returns it. `interactive` updates results live.
#   
#   `measure(label = "", &block) : BM::Tms`
#   CPU and real time used by the block.
#   
#   `realtime(&block) : Time::Span`
#   Elapsed real time used by the block.
#   
#   `memory(&block)`
#   Bytes allocated by the block.
# 
# `IPS::Job`
# ----------
# 
# Yielded by `ips`.
# 
#   `items : Array(Entry)`
#   all entries; populated with statistics after `execute`.
#   
#   `report(label = "", &action : ->) : IPS::Entry`
#   adds a block to benchmark.
#   
#   `execute : Nil`
#   runs the warmup, calculation, and comparison stages.
#   
#   `report : Nil`
#   prints the results table.
# 
# `IPS::Entry`
# ------------
# 
# One benchmarked block. 
# `label` and `action` are set at creation; the rest are `property!` and populated by `execute` (reading them earlier raises).
# 
#   `label : String`                          Benchmark label.
#   `action : ->`                             Code being benchmarked.
#   `cycles : Int32`                          Cycles to run `action` for ~100ms.
#   `size : Int32`                            Number of 100ms runs.
#   `mean` / `variance` / `stddev : Float64`  Calculation-stage statistics.
#   `relative_stddev : Float64`               Relative standard deviation (%).
#   `slower : Float64`                        Multiple slower than the fastest entry.
#   `bytes_per_op : UInt64`                   Bytes allocated per operation.
# 
# Methods: 
#   `ran? : Bool`
#   `call`
#   `call_for_100ms`
#   `set_cycles(duration, iterations)`
#   `calculate_stats(samples)`
#   and the display helpers: 
#     `human_mean`
#     `human_iteration_time`
#     `human_compare`
# 
# `BM::Job`
# ---------
# 
# Yielded by `bm`.
# 
#   `report(label = " ", &block : ->) : Nil`
#   registers a benchmark unit.
# 
# `BM::Tms`
# ---------
# 
# Times for one measurement. 
# Returned by `measure`.
# 
#   `utime : Float64`   User CPU time.
#   `stime : Float64`   System CPU time.
#   `cutime : Float64`  User CPU time of children.
#   `cstime : Float64`  System CPU time of children.
#   `real : Float64`    Elapsed real time.
#   `label : String`    Measure label.
# 
# Methods: 
#   `total : Float64` (`utime + stime + cutime + cstime`)
#   `to_s(io : IO)` (prints user/system/total/real)