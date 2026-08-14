local mod = get_mod("Instantium")

-- Darktide's sandboxed Lua has no native "how much RAM/VRAM does this machine
-- have" API (confirmed against the decompiled engine source -- see AGENTS.md).
-- scoreboard-ii already proved the workaround for this class of problem
-- (directory listing via io.popen, see its history_storage.lua): escape the
-- DMF sandbox to the real io library and shell out to the OS instead.
local mods = rawget(_G, "Mods")
local lua_libraries = mods and mods.lua
local _io = lua_libraries and lua_libraries.io

local TIER_RANK = {
	conservative = 1,
	balanced = 2,
	aggressive = 3,
}

mod.MEMORY_TIER_RANK = TIER_RANK

local probe_cache = mod:persistent_table("memory_probe_cache")

local function run_command(command)
	local popen = _io and _io.popen

	if not popen then
		return nil
	end

	local ok, handle = pcall(popen, command)

	if not ok or not handle then
		return nil
	end

	local lines = {}
	local read_ok = pcall(function()
		for line in handle:lines() do
			lines[#lines + 1] = line
		end
	end)

	pcall(handle.close, handle)

	if not read_ok or #lines == 0 then
		return nil
	end

	return lines
end

local function first_number(lines)
	for i = 1, #lines do
		local number = string.match(lines[i], "(%d+)")

		if number then
			return tonumber(number)
		end
	end

	return nil
end

-- Total system RAM, in MB. Tries PowerShell CIM first (wmic is deprecated/
-- absent on newer Windows builds), then wmic, then /proc/meminfo for Proton.
local function detect_total_ram_mb()
	local sources = {
		{ command = 'powershell -NoProfile -Command "(Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory"', bytes_per_unit = 1 },
		{ command = "wmic ComputerSystem get TotalPhysicalMemory /Value", bytes_per_unit = 1 },
		{ command = "grep MemTotal /proc/meminfo", bytes_per_unit = 1024 },
	}

	for i = 1, #sources do
		local source = sources[i]
		local lines = run_command(source.command)
		local value = lines and first_number(lines)

		if value and value > 0 then
			return math.floor((value * source.bytes_per_unit) / (1024 * 1024))
		end
	end

	return nil
end

-- Total VRAM, in MB, best-effort only. Win32_VideoController.AdapterRAM is a
-- 32-bit WMI field -- drivers on GPUs with more than 4 GB VRAM commonly
-- overflow it (reporting ~4294967295, or wrapping to a small garbage value).
-- Anything at or near that ceiling, or implausibly small, is treated as
-- undetectable rather than trusted. There is no reliable vendor-neutral CLI
-- for this, so a wrong answer here must fail closed to "unknown", not "0".
local function detect_total_vram_mb()
	local sources = {
		'powershell -NoProfile -Command "(Get-CimInstance Win32_VideoController | Measure-Object -Property AdapterRAM -Maximum).Maximum"',
		"wmic path win32_VideoController get AdapterRAM /Value",
	}

	for i = 1, #sources do
		local lines = run_command(sources[i])
		local value = lines and first_number(lines)

		if value and value > 512 * 1024 * 1024 and value < 4200000000 then
			return math.floor(value / (1024 * 1024))
		end
	end

	return nil
end

local function ram_tier(ram_mb)
	if not ram_mb then
		return "balanced"
	elseif ram_mb <= 12 * 1024 then
		return "conservative"
	elseif ram_mb <= 24 * 1024 then
		return "balanced"
	else
		return "aggressive"
	end
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

local function weaker_tier(a, b)
	if not a then
		return b
	elseif not b then
		return a
	elseif TIER_RANK[a] <= TIER_RANK[b] then
		return a
	else
		return b
	end
end

-- Runs the (relatively slow, process-spawning) detection once per game
-- session and caches the result in a persistent table, so it survives
-- Ctrl+Shift+R reloads without re-shelling out every time.
local function detect()
	if probe_cache.detected then
		return probe_cache
	end

	local ram_mb = detect_total_ram_mb()
	local vram_mb = detect_total_vram_mb()
	local tier = weaker_tier(ram_tier(ram_mb), vram_tier(vram_mb)) or "balanced"

	probe_cache.detected = true
	probe_cache.ram_mb = ram_mb
	probe_cache.vram_mb = vram_mb
	probe_cache.tier = tier

	return probe_cache
end

--- Diagnostic accessor: (ram_mb_or_nil, vram_mb_or_nil, auto_detected_tier).
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
