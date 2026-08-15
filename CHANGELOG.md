# Changelog

## 0.1.0 — Initial scaffold

- **Hub/Psykhanium caching** (`preload/hub.lua`) — ported from InstantHub's package-retention approach: Mourningstar and Psykhanium level/theme/UI/HUD/game-mode/breed resources stay resident across mission transitions via an independently-held `Managers.package` reference. Three checkboxes: Mourningstar Caching, Preload Hub at Character Select, Preload Psykhanium / Meat Grinder.
- **Memory tier system** (`core/memory_probe.lua`) — reads Darktide's native graphics-memory budget once per session and maps it to conservative/balanced/aggressive, with a Balanced fallback. Manual override via the "Preload Budget" dropdown.
- **Extension API** (`core/preload_registry.lua`) — `mod:register_asset_preloader(owning_mod, definition)`, gated by the memory tier, pcall-isolated per registration.
- **Squad loadout preloading** (`preload/squad_loadouts.lua`) — first extension built on the registry, and the actual expansion beyond InstantHub: preloads every human squadmate's equipped weapon/cosmetic packages, not just the local player's. Gated at `balanced` tier.
- **Selected mission warmup** (`preload/mission_warmup.lua`) — starts from backend-confirmed mission votes for standard, Havoc, and Expedition selections, with an authoritative mechanism fallback for Quickplay. Balanced warms level/theme/item dependencies; aggressive also warms the global non-hub breed dependency set. References are released on rejection, cancellation, loading completion, tier drop, disable, and unload.
- Removed external PowerShell/WMIC memory probes that could fail startup or flash console windows.
- Smoke-tested in-game for startup, Mourningstar/Psykhanium transitions, a regular mission, squad loadouts, tier changes, disable/re-enable, and shutdown cleanup.
