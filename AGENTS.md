# AGENTS.md — Instantium

Context file for AI coding agents. Read this before making any changes.

## Project overview

**Instantium** is a [Darktide Mod Framework (DMF)](../dmf/) mod for Warhammer 40,000: Darktide. It's a resource-preloading framework: it keeps things you're about to need (Mourningstar, the Psykhanium, squad members' weapon/cosmetic textures) resident in RAM/VRAM instead of letting the game unload and reload them, and it auto-scales how much it keeps warm to the host machine's detected memory so it helps on a 64 GB rig without being the reason a 16 GB one starts paging.

**Origin**: the base hub/Psykhanium caching (`preload/hub.lua`) is a direct port of [InstantHub](../InstantHub/)'s package-retention approach — same mechanism (hold an independent `Managers.package:load` reference so the refcount never hits zero across a hub↔mission transition; nothing hooks cleanup). **Do not run Instantium and InstantHub together** — they'd retain the same packages redundantly. Pick one; see README.md.

**What's new versus InstantHub**: (1) an extension point (`mod:register_asset_preloader`) so this and other mods can register additional things to keep warm without touching this mod's core, and (2) a memory-tier system that gates how much of that *extended* preloading runs, based on auto-detected system RAM and (best-effort) VRAM. The base hub/Psykhanium caching intentionally stays under its own plain checkboxes, matching InstantHub's proven UX, rather than being swept into the tier system.

## This is a multi-developer project — no hardcoded paths

Unlike this author's other mods, other people will be working in this repo on their own machines. **Nothing that varies per developer belongs in a tracked file.**

### Game source code

Everyone's decompiled Darktide source lives at a different absolute path. The convention:

- Each developer creates their own `.source-path.local` at the repo root — one line, the absolute path to their `scripts` folder (see `.source-path.local.example`). It's gitignored; it will never end up in history.
- **Agents**: before referencing engine source, read `.source-path.local` in this directory if it exists and use that path. If it doesn't exist, ask the user where their decompiled source lives (or proceed without source verification and say so explicitly — don't guess at engine data shapes silently).
- Reference only; never modify anything under that path regardless of whose machine it is.

The DMF framework lives at `../dmf/` (one directory up, shared, not gitignored — same for everyone). Never modify it.

## Repo layout

```
Instantium/
├── AGENTS.md                                  ← this file
├── CLAUDE.md                                  ← points to AGENTS.md
├── GOAL.md                                    ← open design questions, planned work
├── README.md                                  ← user-facing
├── CHANGELOG.md
├── Instantium.mod                             ← DMF entry point (loaded by the game)
├── .source-path.local.example                 ← template; copy to .source-path.local (gitignored)
└── scripts/mods/Instantium/
    ├── Instantium.lua                         ← bootstrap: fixed load order, centralizes DMF's named lifecycle slots
    ├── Instantium_data.lua                    ← DMF settings widgets
    ├── Instantium_localization.lua
    ├── core/
    │   ├── memory_probe.lua                   ← RAM/VRAM detection + tiering + manual override
    │   └── preload_registry.lua               ← mod:register_asset_preloader public API
    └── preload/
        ├── hub.lua                            ← Mourningstar + Psykhanium level caching (ported from InstantHub)
        └── squad_loadouts.lua                 ← first registry consumer: squad members' equipped-loadout packages
```

## Why DMF lifecycle slots are centralized in Instantium.lua

DMF calls a handful of functions by fixed name on the shared `mod` table (`mod.update`, `mod.on_enabled`, `mod.on_disabled`, `mod.on_setting_changed`, `mod.on_game_state_changed`, `mod.on_unload`, and event-registered methods like `mod.event_loading_finished`). Only one definition of each can exist — if two files each assigned `mod.update`, the second `load(...)` call would silently clobber the first. So:

- **`Instantium.lua`** owns every one of those named slots and dispatches out to ordinary (non-reserved-name) methods defined by the other modules, e.g. `mod:hub_handle_update()`, `mod:run_asset_preloaders(event_name)`.
- Other modules are free to register their own **`mod:hook(...)`** calls directly at load time (hooks are independent per class/method, not a single named slot) — see `preload/hub.lua`'s `MechanismManager.wanted_transition` and `StateTitle.update` hooks.

If you add a new file that needs to react to a DMF lifecycle event, give it an ordinary method name (`mod:my_module_handle_x()`) and call it from the matching slot in `Instantium.lua` — don't redefine the slot itself elsewhere.

## Bootstrap load order (`Instantium.lua`)

```
core/memory_probe → core/preload_registry → preload/hub → preload/squad_loadouts
```

`preload/squad_loadouts.lua` calls `mod:register_asset_preloader` at file-load time (not inside a callback), so `core/preload_registry.lua` must already be loaded. Insert new files after their dependencies are loaded, same as scoreboard-ii's convention.

## The extension point — `mod:register_asset_preloader`

This is the part meant for other mod authors (`core/preload_registry.lua`):

```lua
get_mod("Instantium"):register_asset_preloader(mod, {
    name = "my_mod_something",        -- unique key; re-registering replaces (dev-reload friendly)
    min_tier = "balanced",            -- "conservative" | "balanced" | "aggressive"
    on_hub_ready = function() ... end,    -- fired when Instantium's own hub preload completes
    on_squad_ready = function() ... end,  -- fired every update tick while state == StateGameplay (throttle internally!)
    on_release = function() ... end,      -- fired on disable/unload/tier-drop/leaving to StateTitle
})
```

- `min_tier` gates against `mod:get_preload_tier()` — a preloader never runs below the tier it declares. It does not gate `on_release`; releasing must always be allowed to run.
- `on_squad_ready` fires on every frame while in a mission — the registry does not throttle it for you. `preload/squad_loadouts.lua`'s `refresh_all` is the reference pattern: check a `next_refresh_time` (`os.clock()`-based) and no-op until it elapses.
- All three callbacks are optional and pcall-isolated per registration — a bug in one preloader (first- or third-party) logs a warning tagged with its name and owning mod, and does not affect any other registration.

## Memory tier system (`core/memory_probe.lua`)

Darktide's sandboxed Lua has no native "how much RAM/VRAM does this machine have" API (checked against the decompiled source; nothing in `scripts/` exposes one). Detection shells out to the OS through `Mods.lua.io`, the same sandbox escape DMF and scoreboard use for filesystem access. If that library or `io.popen` is unavailable, detection fails closed to the existing RAM-unknown fallback instead of blocking mod startup:

- **RAM**: PowerShell `Get-CimInstance Win32_ComputerSystem` → `wmic ComputerSystem get TotalPhysicalMemory` (wmic is deprecated/absent on newer Windows) → `/proc/meminfo` (Proton/Linux). Reliable.
- **VRAM**: `Win32_VideoController.AdapterRAM`, best-effort only. It's a 32-bit WMI field — GPUs with more than 4 GB VRAM commonly report it wrapped or as `~4294967295`. Values at or near that ceiling, or implausibly small, are treated as **undetected**, not trusted. There is no reliable vendor-neutral alternative (no `nvidia-smi`-equivalent that works across NVIDIA/AMD/Intel); if VRAM can't be detected, tiering falls back to the RAM-only result.
- Detection runs once per game session (cached in a persistent table) and combines to the *weaker* of the RAM tier and VRAM tier.
- `memory_tier_override` (Mod Options dropdown, default `"auto"`) lets the user force a tier, bypassing detection entirely.

**Deliberate scope limit**: this gates the *extended* preloaders registered through `core/preload_registry.lua` — it does not touch `hub_caching`/`preload_hub`/`preload_psychanium`, which stay simple always-on-by-default checkboxes like InstantHub's. Don't wire the base hub cache into the tier system without discussing it first — those three settings are the proven, low-risk baseline; the tier system is for the new, heavier, optional stuff.

## DMF mod conventions

### Entry point
`Instantium.mod` calls `new_mod("Instantium", { mod_script, mod_data, mod_localization })`. Paths are relative to the `mods/` directory.

### Getting the mod handle
Every Lua file in the mod starts with:
```lua
local mod = get_mod("Instantium")
```

### Hooking game functions
```lua
mod:hook(ClassName, "method_name", function(func, self, ...)
    -- wraps the method; must call func(self, ...) to invoke original
end)
mod:hook_safe(ClassName, "method_name", function(self, ...)
    -- runs after the original; return value ignored
end)
```
Require game classes with `require("scripts/path/to/class")` (matches InstantHub's own usage) — most of this mod's engine touchpoints are read-only package/profile resolution, not hooks into gameplay classes.

### Settings
- Declared in `Instantium_data.lua` as `options.widgets` entries.
- Read at runtime: `mod:get("setting_id")` → value.
- Localization keys live in `Instantium_localization.lua`.

## Compatibility

- **InstantHub**: do not enable both. Same retention target, redundant work.
- **scoreboard-ii / SocialNotifications**: no known interaction; different subsystems entirely.

## Game logs

Darktide writes console logs to:
```
%AppData%\Fatshark\Darktide\console_logs\
```
Mod `mod:info(...)` output appears prefixed `[MOD][Instantium][INFO]`.

## Coding guidelines

- Lua 5.1 (Darktide's embedded VM). No `//` comments, no `goto`, no integer division operator.
- Paths passed to DMF APIs use forward slashes and are rooted at the `mods/` directory.
- Keep all user-visible strings in `Instantium_localization.lua`; access via `mod:localize("key")`.
- Never read or write `.source-path.local` or whatever it points to as anything other than a reference — and never commit a real path in its place.
- See GOAL.md before starting on the "weapon textures and stuff" expansion beyond squad loadouts (store previews, inspection screens) — those need their own engine-API research and aren't scaffolded yet.
