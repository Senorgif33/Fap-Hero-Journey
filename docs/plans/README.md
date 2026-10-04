# Plans index

Executable Cursor plans (with todos) live in [`.cursor/plans/`](../../.cursor/plans/).  
Open or run them in chat with `@.cursor/plans/<filename>.plan.md` — relative markdown links inside `.plan.md` files do not navigate in the Plans UI.

## Stim stack roadmap (execution order)

1. ~~**[Strip Restim backend](../../.cursor/plans/strip-restim.plan.md)**~~ — **cancelled**
2. ~~**[Upstream merge](../../.cursor/plans/upstream-merge.plan.md)**~~ — **done**
3. ~~**[Vector 1A integration](../../.cursor/plans/vector-live.plan.md)**~~ — **done**
4. **Journey events** (split; Vector implementation planned in restim-vector-live)
   - [journey-events-schema.stub.md](../../.cursor/plans/journey-events-schema.stub.md) — Fap-Hero storage (`Events` in journey.json)
   - [vector-trigger-contract.stub.md](../../.cursor/plans/vector-trigger-contract.stub.md) — wire contract (**Vector EVT done**; Fap-Hero runtime A **done**)
   - [journey-events-converter.plan.md](../../.cursor/plans/journey-events-converter.plan.md) — **B** converter (**new separate repo**, not this game)
   - [journey-events-builder.plan.md](../../.cursor/plans/journey-events-builder.plan.md) — **C** Builder UI
   - Runtime (**A**) — [journey-events-runtime.plan.md](../../.cursor/plans/journey-events-runtime.plan.md) — early `EVT` from journey Events (**done**)
5. ~~[release-windows.plan.md](../../.cursor/plans/release-windows.plan.md)~~ — release time bands + Events overlay Release lane (**done**)

## Active / current work

- [inferno-c01-rebuild.plan.md](inferno-c01-rebuild.plan.md) — Inferno Canto I rebuild (release windows; EPX; no 6.5/010) — **decisions locked**
- [erosphere-stim-effects.plan.md](../../.cursor/plans/erosphere-stim-effects.plan.md) — Feign / Blinding / Time Control → automated L0 (Soft Touch untouched)
- [journey-events-converter.plan.md](../../.cursor/plans/journey-events-converter.plan.md) — **B** new separate repo
- [journey-events-builder.plan.md](../../.cursor/plans/journey-events-builder.plan.md) — **C** Builder UI (**Phase 2 overlay done**)
- [release-windows.plan.md](../../.cursor/plans/release-windows.plan.md) — **done** (engine + Builder Release lane)

## Completed / cancelled

- [journey-events-runtime.plan.md](../../.cursor/plans/journey-events-runtime.plan.md) — done (Fap-Hero → Vector EVT)
- [vector-live.plan.md](../../.cursor/plans/vector-live.plan.md) — done
- [strip-restim.plan.md](../../.cursor/plans/strip-restim.plan.md) — cancelled
- [upstream-merge.plan.md](../../.cursor/plans/upstream-merge.plan.md) — done

## Superseded

- [restim-integration.plan.md](../../.cursor/plans/restim-integration.plan.md) → vector-live
- [round-effects-restim.plan.md](../../.cursor/plans/round-effects-restim.plan.md)

## Release & Erosphere

- [inferno-c01-rebuild.plan.md](inferno-c01-rebuild.plan.md) — Canto I rebuild (active)
- [erosphere-stim-effects.plan.md](../../.cursor/plans/erosphere-stim-effects.plan.md) — skill stim redesign (project `.cursor/plans/` only; not global Cursor plans)
- [release-feature.plan.md](../../.cursor/plans/release-feature.plan.md)
- [erosphere-engine-data.plan.md](../../.cursor/plans/erosphere-engine-data.plan.md)
- [erosphere-journey-structure.plan.md](../../.cursor/plans/erosphere-journey-structure.plan.md)
- [canto-ii-scaffold.plan.md](../../.cursor/plans/canto-ii-scaffold.plan.md)
- [ep7-freeplay-hubs.plan.md](../../.cursor/plans/ep7-freeplay-hubs.plan.md)
- [inferno-award-item-unlocks.plan.md](../../.cursor/plans/inferno-award-item-unlocks.plan.md)

## Builder / engine

- [test-builds.plan.md](../../.cursor/plans/test-builds.plan.md)
- [mid-round-purchases.plan.md](../../.cursor/plans/mid-round-purchases.plan.md)
- [cooldown-cutscene-nodes.plan.md](../../.cursor/plans/cooldown-cutscene-nodes.plan.md)
- [cutscene-editor-parity.plan.md](../../.cursor/plans/cutscene-editor-parity.plan.md)
- [upstream_v0.7.6_sync.plan.md](../../.cursor/plans/upstream_v0.7.6_sync.plan.md) — historical

## Notes (not executable plans)

- [inferno-copy-review.md](../../.cursor/plans/inferno-copy-review.md)
- [fork_feature_report_checklist.md](../../.cursor/plans/fork_feature_report_checklist.md)
