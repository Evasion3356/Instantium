return {
	mod_name = {
		en = "Instantium",
	},
	mod_description = {
		en = "Preloads Mourningstar, Psykhanium, mission, and squad resources before they are needed, scaling extended warmup to Darktide's graphics-memory budget.",
	},
	runtime_stream_warmup = {
		en = "Runtime Texture / Mesh Warmup",
	},
	runtime_stream_warmup_description = {
		en = "Requests texture and mesh streaming before nearby squad members, monsters, specials, and elites are first seen. Enabled by default, but bounded and paused near the renderer's VRAM budget. This cannot permanently pin texture mips in VRAM.",
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
		en = "How aggressively Instantium's extended preloaders use spare memory. Auto reads Darktide's native graphics-memory budget once per session and falls back to Balanced when unavailable. This does not affect Mourningstar/Psykhanium caching above, which is controlled by its own checkboxes.",
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
