# Tests

Local test suite for Fap Hero Journey, using **GdUnit4**. Chosen because the
highest-value targets (GameState, ScoreService) are Godot-typed C#, which can't
be tested by plain xUnit without a Godot runtime — GdUnit4 runs inside Godot and
supports native GDScript *and* C# test suites under one runner.

## Setup (one-time)

Install GdUnit4 into `addons/gdUnit4/`:

- **Asset Library:** search "gdUnit4", download, install.
- **or GitHub:** https://github.com/MikeSchulze/gdUnit4 → copy `addons/gdUnit4`.

Then enable it in **Project → Project Settings → Plugins** (gdUnit4 → Enabled).

## Running

- **In-editor:** open the **GdUnit4** bottom panel, or right-click the `tests/`
  folder in the FileSystem dock → **Run Tests**.
- **Headless / CI:** from the project root —
  ```
  addons/gdUnit4/runtest.cmd -a res://tests      # Windows
  addons/gdUnit4/runtest.sh  -a res://tests      # Linux/macOS
  ```
  Exits non-zero on any failure, so it drops into CI as-is.

A suite is a script `extends GdUnitTestSuite` with `test_*()` methods using the
`assert_*` matchers (`assert_bool`, `assert_int`, `assert_float`, `assert_str`,
…). Use `auto_free(node)` for any Node created in a test.

## CI

`.github/workflows/tests.yml` runs the suite on every push / PR to `main` via the
`godot-gdunit-labs/gdUnit4-action` (Godot 4.6 .NET, gdUnit4 v6.1.3, `res://tests`).
gdUnit4 isn't committed, so the action installs it. Likely first-run friction, in
order: the `godot-version` string must match a downloadable release; the
EIRTeam.FFmpeg GDExtension must load on the Linux runner (tests don't use it, but
Godot loads it at startup); and the C# build must succeed under `net8.0`.

---

## Roadmap

Ordered by value × ease. ✅ = written, ▢ = planned.

### Tier 1 — pure logic, no setup (DONE — bootstraps the harness)

- ✅ **Catalog integrity** (`catalog_test.gd`) — intensity triple present on
  adjustable sensory effects (absent on binary), `idef` normalized 0–1, audio
  kinds ⊆ catalog, names unique across curse/sensory/blessing, kind+name present.
- ✅ **SensoryFX intensity** (`sensory_fx_test.gd`) — `_ival` normal + inverted
  ranges + clamping + missing-field fallback; `intensity_for` override/default/clamp.
- ✅ **ScoreService** (`score_service_test.gd`) — bucket thresholds (1/3/5 pts),
  multiplier rounding (≥1), `PenalizeScore` clamp-at-0 + `ScoreChanged` signal,
  `TotalScore = Σrounds + current`, `StartRound`/`EndRound` transitions,
  `LastRoundScore`, `CaptureSaveData`↔`LoadFromSave`.
  - *Harness note:* written in **GDScript driving the `ScoreService` autoload**
    rather than a native C# suite — that avoids adding the `gdUnit4.api` NuGet
    package to the `.csproj`. Trade-off: it exercises the shared singleton, so each
    test resets via `before_test`. If we later want isolated C# suites (fresh
    `new()` per test, fixtures), that's a separate NuGet setup. Requires the C#
    assembly built (it always is, to run the game).
- ▢ **Boss-modifier arrays parallel** (`BuilderSidePanel.BOSS_MODIFIER_KINDS` /
  `_LABELS` same length) — left out of the first batch only to keep it dependency-free.

### Tier 2 — journey serialize ↔ scan round-trip (the content-corruption guard)

- ✅ **Step 1 — scanner parse round-trip** (`journey_scan_test.gd`): writes a
  full-coverage journey.json (cursed + boss rounds, shop, storyboard, conditional
  fork with a nested fork) to a temp `user://` dir and runs the real
  `parse_journey`, asserting every authored field on both the top-level and
  fork-path round sites, plus the `ShowReveal` default and the empty-on-missing
  case. No media files: rounds carry cached `ActionCount`/`LengthMs`, hitting the
  scanner's fast path. Guards scanner-side field drops; doubles as the schema.
- ✅ **Step 2 — builder↔scanner round-trip** (`journey_build_roundtrip_test.gd`):
  the authored-field serialization was extracted from the builder's two save sites
  into one shared pure function, `JourneyData.round_to_json(item)` (the save loop
  now just merges in the media/slug fields it computes). The test runs an item
  through the real `round_to_json` → real `parse_journey` and asserts equality,
  catching a *builder*-side key drop/typo (which step 1 can't, since it hand-authors
  the JSON). Also unit-tests `round_to_json`'s shape directly and the default values.
  This collapsed the duplicated authored-field write block to one site.
  - *Remaining:* shops / storyboards / fork-resolution serialization still live
    inline in the builder save — same extraction could fold them into
    `round_to_json`-style helpers if/when they grow. Not urgent.
  - *VideoPath round-trip:* both round-trip suites now also assert the explicit
    `VideoPath` survives save → scan (resolved to absolute), with a no-`VideoPath`
    case asserting the folder-scan fallback (`JourneyData._round_video`).
- ✅ **Shared media pool** (`media_pool_test.gd`): the save-time dedup that stores
  each video / funscript source once under `media/m_<fingerprint>.<ext>`. Unit-tests
  the pure planner `JourneyData.plan_media_pool` (first-copy vs skip-on-reuse, 5
  references → 3 writes), `pooled_media_rel` shape, and `media_fingerprint`
  stability (same bytes → same fp; different size/path → different fp). The actual
  transcode/copy + skip wiring in the builder save is manual/integration.

### Tier 3 — GameState fork splicing (C#, highest risk)

Key finding: `ResolveFork(pathIndex)` takes the path index as a parameter — the
*decision* (which path) lives in GameLoop/ForkScreen, not GameState. So the
splicing engine is fully deterministic; **no RNG seam needed for the core.**

- ✅ **3a — GameState sequence/splice** (`gamestate_fork_test.gd`): `BuildSequence`
  ordering, `ResolveFork` splicing (interleave + `fork_end` sentinel + index lands
  on first path item), path selection + index clamping, `RoundNumber`/`TotalRounds`
  before/after, `IsLastRound`/`IsSequenceDone` ignoring sentinels, **nested-fork
  depth**, `CaptureSaveData`↔`LoadFromSave`, and the Current* accessors. Driven
  through the GameState autoload; deterministic, no production change.
- ✅ **3b — fork decision logic** (`fork_resolver_test.gd`). The path-picking was
  extracted from GameLoop / ForkScreen into a pure `ForkResolver` (all static,
  external state passed in). GameLoop's `_weighted_random_path` / `_conditional_path`
  and ForkScreen's `_can_afford` are now thin glue over it.
  - **Random** — `weighted_pick(weights, r)`: cumulative bracket, zero-weight skip,
    single/empty. The only non-deterministic line left is `randi() % total` in
    GameLoop (the RNG seam reduced to that).
  - **Conditional** — `conditional_path(...)`: highest met threshold (score/coins),
    item ownership top-down, default on no-match, default clamping, empty paths.
  - **Sacrifice** — `path_affordable(...)`: coin cost (incl. exact) + required-item
    gates, free path. (Consumption — `SpendCoins`/`ConsumeItem` on pick — and the
    "≥1 free path" builder rule stay in ForkScreen/validation, untested here.)
  - **Player Choice** — pass-through to `ResolveFork(index)`, covered by 3a.

### Out of scope (manual / integration only)

FunscriptPlayer dispatch, device output (Buttplug / serial), video playback,
transitions, and UI — these need the real engine/hardware, not unit tests.
