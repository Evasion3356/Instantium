# Instantium

> Requisition it before you need it.

Instantium keeps things you're about to need loaded in RAM/VRAM instead of letting the game unload and reload them: the Mourningstar, the Psykhanium, and — new versus similar mods — your squadmates' equipped weapon skins and cosmetics, so their gear doesn't pop in either. How much of the extended preloading it does scales automatically to your system's RAM/VRAM.

## ⚠️ Don't run this alongside InstantHub

Instantium's hub/Psykhanium caching uses the same retention approach as InstantHub, targeting the same resources. Running both means two mods independently holding the same packages open — redundant at best. Pick one.

## What it does

| Feature | Default | Notes |
|---|---|---|
| Mourningstar Caching | ON | Keeps hub resources in memory after a mission. |
| Preload Hub at Character Select | ON | Gets a head start before your first hub visit. |
| Preload Psykhanium / Meat Grinder | ON | Same treatment for the training room. |
| Squad loadout preloading | Auto (Balanced+) | Preloads teammates' equipped weapon/cosmetic packages so their gear renders in full detail immediately, not just your own. |
| Show Notifications | ON | Brief on-screen confirmation when something finishes preloading. |

**Preload Budget** (Mod Options): Auto (recommended), Conservative, Balanced, or Aggressive. Auto detects your system RAM and (best-effort) GPU VRAM once per session and picks a tier. This only affects the extended/optional preloading (like squad loadouts) — the three checkboxes above always do what they say regardless of tier.

## Requirements

- [Darktide Mod Framework (DMF)](https://www.nexusmods.com/warhammer40kdarktide/mods/12)
- [Darktide Mod Loader](https://www.nexusmods.com/warhammer40kdarktide/mods/19)

## Installation

1. Copy the `Instantium` folder into your Darktide `mods/` folder.
2. Add `Instantium` to `mod_load_order.txt`.
3. Launch the game.

## For mod developers — extending Instantium

Instantium exposes a small API so other mods can register their own things to keep warm, without editing this mod:

```lua
get_mod("Instantium"):register_asset_preloader(mod, {
    name = "my_mod_something",
    min_tier = "balanced", -- "conservative" | "balanced" | "aggressive"
    on_hub_ready = function() ... end,
    on_squad_ready = function() ... end,
    on_release = function() ... end,
})
```

See [AGENTS.md](AGENTS.md) for the full contract (throttling expectations, pcall isolation, tier semantics).

## Files

```
Instantium/
├── Instantium.mod
├── README.md
└── scripts/mods/Instantium/
    ├── Instantium.lua
    ├── Instantium_data.lua
    ├── Instantium_localization.lua
    ├── core/
    │   ├── memory_probe.lua
    │   └── preload_registry.lua
    └── preload/
        ├── hub.lua
        └── squad_loadouts.lua
```

## Changelog

See [CHANGELOG.md](CHANGELOG.md).
