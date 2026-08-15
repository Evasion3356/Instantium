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
- [x] `preload/mission_warmup.lua` — implemented and runtime-validated for fixed missions, Quickplay, Expedition, cancellation, tier scope, loading-finished release, and shutdown. Remaining contexts are tracked below.

The current develop integration was smoke-tested for startup, hub/Psykhanium transitions, a regular mission, tier changes, disable/re-enable, package cleanup, and shutdown. InstantHub must remain disabled during every Instantium runtime test.

## Open questions for the next session

1. **Remaining mission warmup runtime coverage** — backend vote updates provide `mission.map`, circumstance, category, and Havoc flags; Quickplay intentionally waits for confirmed mechanism assignment. Havoc, an explicit rejected/timeout vote, re-enable during active matchmaking, and an isolated pre-loading tier drop remain unobserved. Their source paths and cleanup behavior are verified; do not claim runtime coverage until each context is observed.

2. **Store/inspection preview preloading** — separate, smaller idea, still open: Store/Armoury preview models (Brunt's, Melk's, Commissary) and inventory inspection/weapon marks previews. Needs its own engine-API research (does the store view resolve preview item packages via `ItemPackage.compile_item_dependencies`, or something store-specific?) — don't guess at the data shape, check `.source-path.local` first per AGENTS.md.
3. **`on_squad_ready` cadence** — currently fires every frame in `StateGameplay` and relies on each registered callback to self-throttle. Reasonable for one registrant; revisit if this mod (or a third party) adds enough registrations that the per-frame registry iteration itself becomes measurable.
4. **VRAM tier thresholds** (6/10 GB cutoffs in `memory_probe.lua`) are a first guess, not measured against real preload memory costs. Once `squad_loadouts.lua` has run in real sessions, revisit against observed package sizes.
5. **InstantHub relationship** — right now these are two separate mods with a "don't run both" warning. Longer-term, consider whether InstantHub should be deprecated in favor of Instantium, or whether Instantium should stay a separate opt-in "extended" layer that explicitly detects and defers to InstantHub if both are present (e.g. skip `preload/hub.lua`'s own retention if `get_mod("InstantHub")` exists and is enabled). Worth a decision before either mod's userbase grows.
6. **Console/Xbox-specific tuning was dropped** in the `preload/hub.lua` port (InstantHub's `sub_platform`/Anaconda/Lockhart view-preload-policy branching). Not needed for PC-only tier scaling; revisit only if a console user reports regressed behavior versus InstantHub.

## Explicitly out of scope for now

- Any data/backend caching (store offers, contracts, wallet, Havoc rank, etc.) — InstantHub 2.0's own changelog documents in detail why that caused stale-data bugs. Instantium should stay a pure resource-retention mod, never touching backend API responses.
