# Repository instructions

## Benchmarks

- Treat benchmark numbers as evidence, not tests. Run correctness checks first;
  if the benchmark's oracle fails, stop and report the run as invalid.
- Compare revisions on the same machine, with the same Elixir/OTP build, VM
  flags, profile, seed, scheduler count, and fixed operation count.
- Never reset or check out another revision over the user's working tree. Use a
  temporary git worktree or another Conductor workspace for the base revision.
- Compile and warm up before measuring. Run each measured scenario in a fresh
  BEAM, use at least five repetitions, and alternate base/head order when
  practical to reduce drift.
- Record telemetry events/second separately from storage observations/second.
  Keep recording, collection, and final merge timings separate.
- Run ordinary, `lcnt`, and `msacc` profiles separately. Profiler-enabled
  throughput is diagnostic and must not be compared with ordinary-emulator
  throughput.
- For `lcnt`, first verify that the lock-counting emulator is available. Capture
  all relevant non-zero `:db` locks; do not filter only by ETS table name because
  CA-tree locks may be anonymous.
- Do not gate CI on throughput, latency, or lock-collision thresholds. CI may run
  deterministic correctness and output-shape checks only.
- Do not add copied implementations of other metric reporters to the internal
  benchmark. External comparisons must run each library in a separate VM through
  its public API and only when explicitly requested.

Before making performance claims, record:

- base and head SHAs, including whether either worktree is dirty;
- the exact commands and VM flags;
- OS, architecture, CPU, Elixir, OTP, ERTS, and scheduler counts;
- workload/profile configuration and repetition count;
- correctness results and the measured values for every claim;
- important caveats, noise, and any inconclusive result.

Write findings as Markdown under `.context/benchmarks/` by default. Use a short
descriptive filename and include these sections:

```markdown
# <benchmark question>

## Revisions and environment
## Commands
## Correctness
## Results
## Findings
## Caveats
```

Keep exact commands and compact result tables in the report. Put large raw
profiler output in a sibling artifact and link it. Distinguish observed facts
from interpretation, and link the report in the final response. Only commit a
benchmark report under `bench/results/` when the user explicitly asks for it.
