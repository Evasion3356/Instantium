# Instantium

> Requisition it before you need it.

Instantium keeps things you're about to need loaded instead of letting the game unload and reload them: the Mourningstar, the Psykhanium, the next selected mission, and your squadmates' equipped weapon skins and cosmetics. How much extended preloading it does scales to Darktide's graphics-memory budget.

## ⚠️ Don't run this alongside InstantHub

Instantium's hub/Psykhanium caching uses the same retention approach as InstantHub, targeting the same resources. Running both means two mods independently holding the same packages open — redundant at best. Pick one.

## What it does

| Feature | Default | Notes |
|---|---|---|
| Mourningstar Caching | ON | Keeps hub resources in memory after a mission. |
| Preload Hub at Character Select | ON | Gets a head start before your first hub visit. |
| Preload Psykhanium / Meat Grinder | ON | Same treatment for the training room. |
| Squad loadout preloading | Auto (Balanced+) | Balanced preloads your party in the hub and your human mission squad. Aggressive expands the hub scope to every visible human player. |
| Selected mission warmup | Auto (Balanced+) | Balanced warms the assigned level, theme, and item dependencies. Aggressive also warms the global non-hub breed dependencies. Quickplay starts only after matchmaking assigns a map. |
| Show Notifications | ON | Brief on-screen confirmation when something finishes preloading. |

**Preload Budget** (Mod Options): Auto (recommended), Conservative, Balanced, or Aggressive. Auto reads Darktide's native graphics-memory budget once per session and picks a tier, falling back to Balanced if unavailable. This only affects extended/optional preloading such as squad loadouts and selected missions; the three checkboxes above always do what they say regardless of tier.

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

See [AGENTS.md](AGENTS.md) for the full contract (throttling expectations, pcall isolation, tier semantics) and [CONTRIBUTING.md](CONTRIBUTING.md) for the branch, review, and release workflow.

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
        ├── squad_loadouts.lua
        └── mission_warmup.lua
```

## Changelog

See [CHANGELOG.md](CHANGELOG.md).
