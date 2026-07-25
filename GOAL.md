# GOAL.md — Instantium

Design goals, open questions, and planned work. See AGENTS.md for the current architecture.

## Premise

Take InstantHub's core trick (retain packages across transitions instead of letting them unload/reload) and generalize it: (1) into a public extension API other mods can add preload targets to, and (2) scale how much of that extended preloading runs to the host machine's available RAM/VRAM, so the mod helps on high-end machines without being a liability on low-end ones.

## v0.1 scope (this scaffold)

- [x] Ported InstantHub's hub/Psykhanium package retention as the base layer (`preload/hub.lua`).
- [x] `core/memory_probe.lua` — RAM (reliable) + VRAM (best-effort) detection, 3-tier system, manual override.
- [x] `core/preload_registry.lua` — `mod:register_asset_preloader` extension point.
- [x] `preload/squad_loadouts.lua` — first real extension: preload every human squad member's equipped-loadout packages (weapon skins, cosmetics), not just your own like InstantHub does. Gated at `balanced` tier.
- [x] Multi-developer source-reference convention (`.source-path.local`, gitignored).

Not yet tested in-game. Next session should start with a live smoke test (enable-only, watch console logs for `[MOD][Instantium]` warnings/errors, confirm no double-retention conflict if InstantHub happens to also be enabled by accident).

## Open questions for the next session

1. **"Weapon textures and stuff" beyond squad loadouts** — what else pops in that's worth preloading?
   - Store/Armoury preview models (Brunt's, Melk's, Commissary) — browsing a weapon skin you don't own yet still has to load its render on demand.
   - Inventory inspection / weapon marks view previews.
   - These need their own engine-API research (how does the store view resolve preview item packages? is it the same `ItemPackage.compile_item_dependencies` path, or something store-specific?) — don't guess at the data shape, check `.source-path.local` first per AGENTS.md.
2. **`on_squad_ready` cadence** — currently fires every frame in `StateGameplay` and relies on each registered callback to self-throttle. Reasonable for one registrant; revisit if this mod (or a third party) adds enough registrations that the per-frame registry iteration itself becomes measurable.
3. **VRAM tier thresholds** (6/10 GB cutoffs in `memory_probe.lua`) are a first guess, not measured against real preload memory costs. Once `squad_loadouts.lua` has run in real sessions, revisit against observed package sizes.
4. **InstantHub relationship** — right now these are two separate mods with a "don't run both" warning. Longer-term, consider whether InstantHub should be deprecated in favor of Instantium, or whether Instantium should stay a separate opt-in "extended" layer that explicitly detects and defers to InstantHub if both are present (e.g. skip `preload/hub.lua`'s own retention if `get_mod("InstantHub")` exists and is enabled). Worth a decision before either mod's userbase grows.
5. **Console/Xbox-specific tuning was dropped** in the `preload/hub.lua` port (InstantHub's `sub_platform`/Anaconda/Lockhart view-preload-policy branching). Not needed for PC-only tier scaling; revisit only if a console user reports regressed behavior versus InstantHub.
6. **Contributor workflow** — this is the first mod in this `mods/` folder meant for multiple developers. If more than one person ends up committing regularly, worth deciding on a branching convention (scoreboard-ii's `original_version`-tracking pattern doesn't apply here since there's no upstream to track, but a `main` + feature-branch + PR-review flow might still be worth setting up).

## Explicitly out of scope for now

- Any data/backend caching (store offers, contracts, wallet, Havoc rank, etc.) — InstantHub 2.0's own changelog documents in detail why that caused stale-data bugs. Instantium should stay a pure resource-retention mod, never touching backend API responses.
