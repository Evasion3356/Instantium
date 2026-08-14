local mod = get_mod("Instantium")

-- Darktide exposes the renderer's current VRAM budget in MB. Total system RAM
-- is not available through a verified native Lua API, so Auto uses this budget
-- and falls back to balanced rather than spawning external probe processes.
local PROBE_VERSION = 2

local TIER_RANK = {
	conservative = 1,
	balanced = 2,
	aggressive = 3,
}

mod.MEMORY_TIER_RANK = TIER_RANK

local probe_cache = mod:persistent_table("memory_probe_cache")

local function detect_vram_budget_mb()
	local memory = rawget(_G, "Memory")
	local vram_budget = memory and memory.vram_budget

	if type(vram_budget) ~= "function" then
		return nil
	end

	local ok, value = pcall(vram_budget)

	if not ok or type(value) ~= "number" or value <= 0 then
		return nil
	end

	return math.floor(value)
end

local function vram_tier(vram_mb)
	if not vram_mb then
		return nil
	elseif vram_mb <= 6 * 1024 then
		return "conservative"
	elseif vram_mb <= 10 * 1024 then
		return "balanced"
	else
		return "aggressive"
	end
end

-- Cache once per game session. The version invalidates values produced by an
-- older probe implementation after a development reload.
local function detect()
	if probe_cache.detected and probe_cache.version == PROBE_VERSION then
		return probe_cache
	end

	local vram_mb = detect_vram_budget_mb()
	local tier = vram_tier(vram_mb) or "balanced"

	probe_cache.detected = true
	probe_cache.version = PROBE_VERSION
	probe_cache.ram_mb = nil
	probe_cache.vram_mb = vram_mb
	probe_cache.tier = tier

	return probe_cache
end

--- Diagnostic accessor: (nil, vram_budget_mb_or_nil, auto_detected_tier).
mod.memory_probe_info = function(self)
	local result = detect()

	return result.ram_mb, result.vram_mb, result.tier
end

--- Active preload tier, honoring the "memory_tier_override" setting when it
--- isn't "auto". This is what gates registered asset preloaders (see
--- core/preload_registry.lua) -- it does not affect Instantium's own base
--- hub/psychanium caching, which stays under its own explicit checkboxes.
mod.get_preload_tier = function(self)
	local override = self:get("memory_tier_override")

	if override and override ~= "auto" then
		return override
	end

	return detect().tier
end

return mod
