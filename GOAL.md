# GOAL.md — Instantium

Design goals, open questions, and planned work. See AGENTS.md for the current architecture.

## Premise

Take InstantHub's core trick (retain packages across transitions instead of letting them unload/reload) and generalize it: (1) into a public extension API other mods can add preload targets to, and (2) scale how much of that extended preloading runs to the host machine's available RAM/VRAM, so the mod helps on high-end machines without being a liability on low-end ones.

### Known limitation: package retention ≠ VRAM-resident textures

Raised by InstantHub's author (2026-07-25, `message.txt`), confirmed against the decompiled source: holding a `Managers.package` reference keeps asset *data* available (no re-fetch/decompress/dependency-walk on next use — this is real and is where the load-time win comes from), but it does **not** force Darktide's texture streamer to keep high-resolution mips resident in VRAM. The streamer manages mip residency independently, based on its own internal heuristics (distance/screen-size/budget), and can still downgrade or evict mips for a package Instantium is holding open. There is no Lua-exposed API to pin or prioritize mip streaming — checked `scripts/foundation/utilities/parameters/default_dev_parameters.lua` and found only a debug-only `perfhud feedback_texture_streamer` visualization toggle, nothing that lets a mod influence streamer behavior.

**Implication**: don't oversell "eliminates pop-in" for texture detail specifically — package retention reliably eliminates *load-time* pop-in (the stutter/black-texture window while data is fetched), but full-mip-resolution pop-in as the streamer catches up is a separate problem this mod cannot directly solve from script. Keep README/AGENTS.md language honest about this distinction; don't quietly walk it back later.

## v0.1 scope (this scaffold)

- [x] Ported InstantHub's hub/Psykhanium package retention as the base layer (`preload/hub.lua`).
- [x] `core/memory_probe.lua` — RAM (reliable) + VRAM (best-effort) detection, 3-tier system, manual override.
- [x] `core/preload_registry.lua` — `mod:register_asset_preloader` extension point.
- [x] `preload/squad_loadouts.lua` — first real extension: preload every human squad member's equipped-loadout packages (weapon skins, cosmetics), not just your own like InstantHub does. Gated at `balanced` tier.
- [x] Multi-developer source-reference convention (`.source-path.local`, gitignored).

Not yet tested in-game. Next session should start with a live smoke test (enable-only, watch console logs for `[MOD][Instantium]` warnings/errors, confirm no double-retention conflict if InstantHub happens to also be enabled by accident).

## Open questions for the next session

1. **Mission asset warmup** (proposed by InstantHub's author, `message.txt`) — preload the *selected* mission's level/theme/breeds as soon as the target is known, retain only that mission's scope (not the whole game), release on mission exit. Scoped below; not yet implemented.

   **Hook chain found** (earliest to latest — all confirmed against the decompiled source):
   - `mission_board_view_logic.lua:start_mission_matchmaking(party_manager, selected_mission_id)` → `MissionBoardService.start_mission` (`mission_board_service.lua:69`) → **`PartyImmateriumManager.wanted_mission_selected(self, backend_mission_id, private_session, reef)`** (`party_immaterium_manager.lua:1265`) → kicks off `Managers.voting:start_voting("mission_vote_matchmaking_immaterium", {...})` (party members can still accept/reject) → eventually `MechanismManager.wanted_transition` fires with the finalized `context.mission_name` (this is the hook `preload/hub.lua` already uses today, for `hub_ship`/`tg_shooting_range` only).
   - `PartyImmateriumManager` is a registered class (`class("PartyImmateriumManager", ...)` in `party_immaterium_manager.lua`) — same pattern as `MechanismManager`, which `preload/hub.lua` already hooks successfully. `mod:hook("PartyImmateriumManager", "wanted_mission_selected", ...)` should work the same way; **not yet verified against a live hook (no game restart done this session)**.
   - **Head-start window**: `wanted_mission_selected` fires the moment a player commits to a mission on the board, before matchmaking/queueing/the party vote — potentially tens of seconds to minutes ahead of the current `wanted_transition` hook point. This is the actual value of this feature over what `preload/hub.lua` already does.

   **Open sub-problem — resolving `backend_mission_id` to a level**: `wanted_mission_selected` only has the *backend board* mission id, not the internal `mission_name`/level `preload_level_items` needs (the same key space `Missions[mission_name]` in `preload/hub.lua` uses). The mission board's already-fetched list (`mission_board_service.lua`'s `fetch`/`format_missions_data`) should have this mapping client-side already (no extra network round-trip needed), but the exact field name wasn't pinned down this session — `format_missions_data`'s per-mission fields (`mission.duration`, `.required_level`, `.side_mission`, etc., see lines 36-54) don't obviously include a level/template key at a glance; needs one more read of that function plus wherever `missions_data.missions[i]` entries get consumed by `mission_board_view` to find the field that maps to `Missions[...]`'s keys.

   **Design per the author's constraints** (all sensible, adopt as-is):
   - Preload only level + theme + breeds for the *specific* selected mission — no view/HUD/game-mode preload sprawl like `hub.lua` does for the hub (those are hub-specific policy tables, don't reuse them here).
   - Must handle the vote being **rejected or timing out** (a teammate declines, or the player picks a different mission before voting resolves) — release/replace the warm scope, don't leak it forward into an actually-different mission.
   - Release on mission exit (existing `on_release` registry event already covers this if implemented as a registered preloader).
   - Havoc/Expedition mission selection (`havoc_play_view.lua`) is a separate UI flow from the mission board — not investigated this session; likely needs its own hook point if it doesn't route through the same `wanted_mission_selected` call.

   **Suggested shape**: a new `preload/mission_warmup.lua`, registered via `core/preload_registry.lua` like `squad_loadouts.lua` (own `min_tier`, own `on_release`), rather than folded into `hub.lua` — different trigger point, different lifecycle (single-mission scope vs. hub's persistent-while-enabled scope).

2. **Store/inspection preview preloading** — separate, smaller idea, still open: Store/Armoury preview models (Brunt's, Melk's, Commissary) and inventory inspection/weapon marks previews. Needs its own engine-API research (does the store view resolve preview item packages via `ItemPackage.compile_item_dependencies`, or something store-specific?) — don't guess at the data shape, check `.source-path.local` first per AGENTS.md.
3. **`on_squad_ready` cadence** — currently fires every frame in `StateGameplay` and relies on each registered callback to self-throttle. Reasonable for one registrant; revisit if this mod (or a third party) adds enough registrations that the per-frame registry iteration itself becomes measurable.
4. **VRAM tier thresholds** (6/10 GB cutoffs in `memory_probe.lua`) are a first guess, not measured against real preload memory costs. Once `squad_loadouts.lua` has run in real sessions, revisit against observed package sizes.
5. **InstantHub relationship** — right now these are two separate mods with a "don't run both" warning. Longer-term, consider whether InstantHub should be deprecated in favor of Instantium, or whether Instantium should stay a separate opt-in "extended" layer that explicitly detects and defers to InstantHub if both are present (e.g. skip `preload/hub.lua`'s own retention if `get_mod("InstantHub")` exists and is enabled). Worth a decision before either mod's userbase grows.
6. **Console/Xbox-specific tuning was dropped** in the `preload/hub.lua` port (InstantHub's `sub_platform`/Anaconda/Lockhart view-preload-policy branching). Not needed for PC-only tier scaling; revisit only if a console user reports regressed behavior versus InstantHub.
7. **Contributor workflow** — this is the first mod in this `mods/` folder meant for multiple developers. If more than one person ends up committing regularly, worth deciding on a branching convention (scoreboard-ii's `original_version`-tracking pattern doesn't apply here since there's no upstream to track, but a `main` + feature-branch + PR-review flow might still be worth setting up).

## Explicitly out of scope for now

- Any data/backend caching (store offers, contracts, wallet, Havoc rank, etc.) — InstantHub 2.0's own changelog documents in detail why that caused stale-data bugs. Instantium should stay a pure resource-retention mod, never touching backend API responses.
