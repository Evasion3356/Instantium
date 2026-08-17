# GOAL.md — Instantium

Design goals, open questions, and planned work. See AGENTS.md for the current architecture.

## Premise

Take InstantHub's core trick (retain packages across transitions instead of letting them unload/reload) and generalize it: (1) into a public extension API other mods can add preload targets to, and (2) scale how much of that extended preloading runs to the host machine's available RAM/VRAM, so the mod helps on high-end machines without being a liability on low-end ones.

### Known limitation: package retention ≠ VRAM-resident textures

Raised by InstantHub's author (2026-07-25, `message.txt`), confirmed against the decompiled source: holding a `Managers.package` reference keeps asset *data* available (no re-fetch/decompress/dependency-walk on next use — this is real and is where the load-time win comes from), but it does **not** force Darktide's texture streamer to keep high-resolution mips resident in VRAM. The streamer manages mip residency independently, based on its own internal heuristics (distance/screen-size/budget), and can still downgrade or evict mips for a package Instantium is holding open. There is no Lua-exposed API to pin or prioritize mip streaming — checked `scripts/foundation/utilities/parameters/default_dev_parameters.lua` and found only a debug-only `perfhud feedback_texture_streamer` visualization toggle, nothing that lets a mod influence streamer behavior.

**Implication**: don't oversell "eliminates pop-in" for texture detail specifically — package retention reliably eliminates *load-time* pop-in (the stutter/black-texture window while data is fetched), but full-mip-resolution pop-in as the streamer catches up is a separate problem this mod cannot directly solve from script. Keep README/AGENTS.md language honest about this distinction; don't quietly walk it back later.

## v0.1 scope (this scaffold)

- [x] Ported InstantHub's hub/Psykhanium package retention as the base layer (`preload/hub.lua`).
- [x] `core/memory_probe.lua` — native graphics-memory-budget detection, 3-tier system, manual override.
- [x] `core/preload_registry.lua` — `mod:register_asset_preloader` extension point.
- [x] `preload/squad_loadouts.lua` — first real extension: preload every human squad member's equipped-loadout packages (weapon skins, cosmetics), not just your own like InstantHub does. Gated at `balanced` tier.
- [x] Multi-developer source-reference convention (`.source-path.local`, gitignored).
- [x] `preload/mission_manifest.lua` + `preload/mission_warmup.lua` — source-backed assigned-mission package manifest and bounded pre-loading scheduler, including mission support and mutators without instantiating game loaders, worlds, UI, units, or gameplay.
- [x] `preload/unit_stream_warmup.lua` — default-on bounded native texture/mesh requests for prioritized approaching character units, with VRAM/package-pressure gates and lifecycle-safe diagnostics.

The expanded Balanced scheduler was runtime-tested on fixed mission `fm_armoury`: its 546-package manifest completed before transition, respected `MAX_SUBMISSIONS_PER_FRAME = 4` and `MAX_IN_FLIGHT = 8`, stopped submissions at `event_loading_started`, and released all 546 Instantium references after `event_loading_finished`. The current log contained no Instantium errors or warnings. InstantHub was disabled.

## Open questions for the next session

1. **Expanded mission warmup runtime coverage** — fixed-mission Balanced scheduling, bounds, loading-start handoff, loading-finished release, and clean logging are now observed. Quickplay assignment, full Havoc data, Expedition pre-handoff layout availability, Aggressive breeds, reject/timeout, re-enable during matchmaking, tier changes before/during handoff, and shutdown remain unobserved for this expansion. Earlier smoke tests covered some of those lifecycle paths only in the smaller predecessor implementation.

2. **Runtime texture/mesh warmup coverage** — source tracing, static validation, Psykanium, and a regular client mission are complete. The final build completed native requests for one Psykanium elite and, after the Psykanium baseline, 24 regular-mission specials/elites with two-unit peak concurrency, valid sub-40% VRAM telemetry, no texture timeouts, no native failures, no Instantium errors, and no circuit-breaker trip. Eighteen of those 24 regular-mission mesh requests reached the two-second timeout. Remote squad roots were already inside the 15-metre safety boundary, so player attachment coverage remains unobserved. Disable/re-enable during active requests, unload, dedicated-server exclusion, and paired A/B visual/frame-time benefit remain untested.

3. **Store/inspection preview preloading** — separate, smaller idea, still open: Store/Armoury preview models (Brunt's, Melk's, Commissary) and inventory inspection/weapon marks previews. Needs its own engine-API research (does the store view resolve preview item packages via `ItemPackage.compile_item_dependencies`, or something store-specific?) — don't guess at the data shape, check `.source-path.local` first per AGENTS.md.
4. **`on_squad_ready` cadence** — currently fires every frame in `StateGameplay` and relies on each registered callback to self-throttle. Reasonable for one registrant; revisit if this mod (or a third party) adds enough registrations that the per-frame registry iteration itself becomes measurable.
5. **VRAM tier thresholds** (6/10 GB cutoffs in `memory_probe.lua`) are a first guess, not measured against real preload memory costs. Once `squad_loadouts.lua` has run in real sessions, revisit against observed package sizes.
6. **InstantHub relationship** — right now these are two separate mods with a "don't run both" warning. Longer-term, consider whether InstantHub should be deprecated in favor of Instantium, or whether Instantium should stay a separate opt-in "extended" layer that explicitly detects and defers to InstantHub if both are present (e.g. skip `preload/hub.lua`'s own retention if `get_mod("InstantHub")` exists and is enabled). Worth a decision before either mod's userbase grows.
7. **Console/Xbox-specific tuning was dropped** in the `preload/hub.lua` port (InstantHub's `sub_platform`/Anaconda/Lockhart view-preload-policy branching). Not needed for PC-only tier scaling; revisit only if a console user reports regressed behavior versus InstantHub.

## Explicitly out of scope for now

- Any data/backend caching (store offers, contracts, wallet, Havoc rank, etc.) — InstantHub 2.0's own changelog documents in detail why that caused stale-data bugs. Instantium should stay a pure resource-retention mod, never touching backend API responses.
- Claims of full physical RAM or VRAM residency, resident package loading, texture-mip pinning, speculative VO/shader/cinematic/briefing packages, independent Expedition layout generation, or Expedition lookahead without a reliable public section lifecycle.
