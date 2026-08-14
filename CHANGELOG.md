# Changelog

## 0.1.0 — Initial scaffold

- **Hub/Psykhanium caching** (`preload/hub.lua`) — ported from InstantHub's package-retention approach: Mourningstar and Psykhanium level/theme/UI/HUD/game-mode/breed resources stay resident across mission transitions via an independently-held `Managers.package` reference. Three checkboxes: Mourningstar Caching, Preload Hub at Character Select, Preload Psykhanium / Meat Grinder.
- **Memory tier system** (`core/memory_probe.lua`) — auto-detects total system RAM (reliable) and GPU VRAM (best-effort, falls back to undetected on the known 32-bit `AdapterRAM` overflow for >4 GB cards) once per session, mapping to conservative/balanced/aggressive. Manual override via the "Preload Budget" dropdown.
- **Extension API** (`core/preload_registry.lua`) — `mod:register_asset_preloader(owning_mod, definition)`, gated by the memory tier, pcall-isolated per registration.
- **Squad loadout preloading** (`preload/squad_loadouts.lua`) — first extension built on the registry, and the actual expansion beyond InstantHub: preloads every human squadmate's equipped weapon/cosmetic packages, not just the local player's. Gated at `balanced` tier.
- Fixed startup failing when the memory probe tried to access the nonexistent `Elmodedo` global instead of DMF's `Mods.lua.io` bridge.
- Smoke-tested in-game for startup and a smooth Mourningstar → Psykhanium → Mourningstar round trip; regular missions, squad loadouts, tier changes, and shutdown cleanup remain untested.
