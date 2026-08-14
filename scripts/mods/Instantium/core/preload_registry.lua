local mod = get_mod("Instantium")

-- Extension point for other mods -- mirrors scoreboard-ii's
-- `register_scoreboard_row` pattern: a small owning-mod-tagged registry that
-- Instantium itself also uses for its own built-in preloaders
-- (preload/squad_loadouts.lua), so first-party and third-party preloaders
-- are handled identically.
local preloaders = mod:persistent_table("asset_preloaders")

--- Public API. Call from another mod's `on_all_mods_loaded` (or any point
--- after Instantium is guaranteed loaded):
---
---   get_mod("Instantium"):register_asset_preloader(mod, {
---       name = "my_mod_weapon_previews",
---       min_tier = "balanced", -- "conservative" | "balanced" | "aggressive"
---       on_hub_ready = function() ... end,   -- hub finished its own preload
---       on_squad_ready = function() ... end, -- squad roster is known
---       on_release = function() ... end,     -- caches should be dropped
---   })
---
--- `min_tier` gates the preloader against Instantium's detected/overridden
--- memory tier (core/memory_probe.lua) -- it never runs below the tier it
--- declares. Callbacks are optional; only the ones you provide are called.
--- Registering under a `name` that's already taken replaces the previous
--- registration (supports the `mod:io_dofile()` dev reload workflow).
mod.register_asset_preloader = function(self, owning_mod, definition)
	if type(definition) ~= "table" or type(definition.name) ~= "string" then
		self:warning("register_asset_preloader: definition.name (string) is required")

		return false
	end

	preloaders[definition.name] = {
		owning_mod_name = owning_mod and owning_mod.get_name and owning_mod:get_name() or "unknown",
		min_tier = definition.min_tier or "conservative",
		on_hub_ready = definition.on_hub_ready,
		on_squad_ready = definition.on_squad_ready,
		on_release = definition.on_release,
	}

	return true
end

mod.unregister_asset_preloader = function(self, name)
	preloaders[name] = nil
end

local RANK = mod.MEMORY_TIER_RANK

--- Invokes every registered preloader's `event_name` callback whose
--- `min_tier` is at or below the currently active tier. `on_release` always
--- runs so a tier drop cannot strand resources loaded at the previous tier.
--- Failures are pcall-isolated and logged per-preloader so a bug in one
--- registration cannot break another's or Instantium's own flow.
mod.run_asset_preloaders = function(self, event_name)
	local active_tier = self:get_preload_tier()
	local active_rank = RANK[active_tier] or RANK.conservative
	local is_release = event_name == "on_release"

	for name, entry in pairs(preloaders) do
		local required_rank = RANK[entry.min_tier] or RANK.conservative
		local callback = entry[event_name]

		if callback and (is_release or active_rank >= required_rank) then
			local ok, err = pcall(callback)

			if not ok then
				self:warning("Asset preloader '%s' (%s) failed during %s: %s", name, entry.owning_mod_name, event_name, tostring(err))
			end
		end
	end
end

return mod
