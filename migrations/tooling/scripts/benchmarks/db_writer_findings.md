# IntermediateDB writer — throughput & parallelism findings

Notes from investigating two things:

1. Does the run-level `DbWriter` slow down writes? (It started as an always-queued
   single writer thread.)
2. How should IntermediateDB writes scale once we run steps in parallel?

The PR that ships from this (`mt/run-level-db-writer`) keeps it simple: a **direct
inline** run-level writer, because today there is only ever one in-process producer.
Everything below is the reasoning and the numbers behind that, plus the groundwork for
the future step-parallelism work.

Benchmarks live next to this file and run from the core gem:

```
cd migrations/core
bundle exec ruby ../tooling/scripts/benchmarks/db_writer.rb        # queue vs inline
bundle exec ruby ../tooling/scripts/benchmarks/fork_pipe_writer.rb # single vs multi vs hybrid
```

Numbers are from a 20-core box, Ruby 3.4.9, extralite 2.14, btrfs disk. They are
relative, not absolute — re-run on the target hardware before trusting magnitudes.
**Write DBs to real disk, never tmpfs** (`/tmp` is RAM here; the multi-writer arms
filled RAM and OOM'd until I pointed them at `/var/tmp`).

## 1. The per-row queue handoff is the regression

Funnelling every `insert` through a `SizedQueue` to one writer thread, one row per
item, is much slower than writing inline — for cheap rows:

| | rows/s |
|---|---|
| inline (`Connection#insert`) | ~1.3M |
| queue → 1 writer thread | ~0.17M (**~8x slower**) |

For realistic wide rows the gap shrinks (the per-row build/format/insert work
dominates), but it is never free. Since steps run sequentially and each has a single
producer (main thread for serial, one collector thread for parallel), the queue buys
nothing today — hence the direct writer.

## 2. Root cause is the GVL, not the queue

The queue itself is fast (~5.7M rows/s of pure handoff). The slowdown is a live
in-process producer thread sharing the GVL with a SQLite-busy consumer thread: every
`execute` releases the GVL, every `pop` wakes the producer → a context switch per row.

| | rows/s |
|---|---|
| A: inline, single thread | ~1.2M |
| B: queue + live producer thread | ~0.17M |
| C: queue, pre-filled (no live rival) | ~1.15M (≈ inline) |

extralite's `gvl_release_threshold = 0` (hold the GVL per statement) recovers B to
~inline **for cheap rows**, but **hurts realistic wide rows** (it starves the decoder
threads, ~-19%). So it is a per-workload knob, not a default. We did not ship it.

## 3. Wire format matters more than the serializer gem

Decode is the bottleneck on the parent side. On the post-`format_*` payload (all
primitives), decode throughput (YJIT):

| serializer | decode rows/s | bytes/row |
|---|---|---|
| json gem | ~1.9M | 240 |
| msgpack | ~1.5M | 178 |
| Oj `:strict` | ~1.0M | 240 |
| Oj `:object` (today's Worker) | ~0.9M | 422 |
| Marshal | ~0.43M | 246 |
| schema-aware pure Ruby | ~0.31M | 265 |

Takeaways:
- **json gem decodes fastest** here; Oj `:object` is the slowest path and is
  unnecessary on the output wire (it carries primitives, not objects).
- **Factor out the SQL** — it is identical for every row in a step. Sending it once
  per batch roughly halves the payload (msgpack 368→178, json 432→240 bytes/row).
- **Pure-Ruby-with-YJIT does not beat C** for byte parsing (~5x slower). The win is
  doing less work (factor SQL, drop type tags), not the language.
- This does **not** contradict PR #40827 ("keep Oj"): that measured the current
  `Worker` with Oj streaming + a one-item-in-flight handshake, where the in-flight
  window dwarfs the codec. These numbers are the batched/no-handshake regime, where
  the codec is exposed. Both agree the levers are *primitives + wider window*.

## 4. Single vs multi vs hybrid writer (the future scaling question)

End-to-end, 2M wide rows, json + factored SQL, **real disk**:

| forks | serial | single writer | multi-writer + merge | hybrid + merge |
|---|---|---|---|---|
| 4 | 83K | **284K** | 278K | 277K (2w) |
| 8 | 83K | 229K | 366K | 377K (4w) |
| 16 | 83K | 243K | 433K | **470K** (8w) |

- **Single writer** (N producers → 1 parent writer → 1 DB) is best and simplest at
  low parallelism, then **plateaus ~230–245K**: the parent's single GVL (decoding all
  the incoming streams) saturates, so extra forks stop helping.
- **Multi-writer** (each fork writes its own DB) and **hybrid** (a few writer
  processes, each fed by several forks) **scale with cores** — at 16 forks they reach
  ~1.8–1.9x the single writer. Separate processes = separate GVLs.
- The **merge is cheap**: 2M rows via `ATTACH` + `INSERT … SELECT` = ~0.78s
  (2.56M rows/s). Easily paid back by the parallel production gain.
- **Hybrid is fastest at high core counts** (fewer DBs to merge than full
  multi-writer, still many separate-GVL writers).

Crossover is ~4–5 forks. So: single writer for ≤4 effective producers (simplest,
one canonical DB); multi-writer or hybrid + merge when saturating many cores for the
big migrations.

## 5. Recommendations for the future step-parallelism PRs

- Run steps in parallel as **separate processes**, each with a single producer →
  the run-level writer stays a simple direct inline writer (no in-process concurrent
  writers, no queue).
- For throughput at scale, prototype **hybrid**: a handful of writer processes, each
  owning a shard DB, then one cheap `ATTACH`/`INSERT … SELECT` merge.
- On the worker IPC wire: move to a **primitive** format, **factor out the SQL**, and
  benchmark **json** vs Oj `:strict` on the target Ruby — but coordinate with
  PR #40827's conclusion (the in-flight window is the bigger lever there).
- `gvl_release_threshold` is a per-step knob only — helpful for cheap write-bound
  steps, harmful for wide-row producer-bound steps. Don't set it globally.
- Always write IntermediateDB shards to **real disk**, and **bound** any in-flight
  queue (rows = queue_depth × batch_size) to avoid the OOM we hit.

## Reference code on this branch

This branch also carries the exploratory `DbWriter` (the "Option 2" direct + dormant
`concurrent { }` queued mode) and the `Connection(gvl_release_threshold:)` knob, kept
as a starting point for the parallelism work. The PR ships the simpler direct-only
version.
