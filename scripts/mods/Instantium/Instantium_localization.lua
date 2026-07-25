return {
	mod_name = {
		en = "Instantium",
	},
	mod_description = {
		en = "Requisitions Mourningstar, Psykhanium, and squad loadout resources ahead of when you need them, scaling how much it keeps warm to your system's RAM/VRAM so nothing pops in.",
	},
	hub_caching = {
		en = "Mourningstar Caching",
	},
	hub_caching_description = {
		en = "Keeps Mourningstar level, theme, UI, HUD, and game-mode resources in memory after leaving the hub. Speeds up returns but adds roughly 500 MB-1 GB of memory use. Disable if missions stutter or crash.",
	},
	preload_hub = {
		en = "Preload Hub at Character Select",
	},
	preload_hub_description = {
		en = "Preloads Mourningstar resources after backend sync, moving that work ahead of your first hub transition. Uses roughly 500 MB-1 GB of memory.",
	},
	preload_psychanium = {
		en = "Preload Psykhanium / Meat Grinder",
	},
	preload_psychanium_description = {
		en = "Preloads Meat Grinder level, theme, UI, HUD, and game-mode resources. Uses additional memory.",
	},
	memory_tier_override = {
		en = "Preload Budget",
	},
	memory_tier_override_description = {
		en = "How aggressively Instantium's extended preloaders (squad loadout textures, and anything other mods register) use spare memory. Auto detects your system RAM/VRAM once per session. This does not affect Mourningstar/Psykhanium caching above, which are always controlled by their own checkboxes.",
	},
	memory_tier_auto = {
		en = "Auto (Recommended)",
	},
	memory_tier_conservative = {
		en = "Conservative",
	},
	memory_tier_balanced = {
		en = "Balanced",
	},
	memory_tier_aggressive = {
		en = "Aggressive",
	},
	show_notifications = {
		en = "Show Notifications",
	},
	show_notifications_description = {
		en = "Shows brief messages when preloading starts or finishes and when a destination is ready. Does not affect loading behavior.",
	},
}
