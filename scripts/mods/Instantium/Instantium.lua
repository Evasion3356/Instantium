local mod = get_mod("Instantium")

-- DMF only ever looks at one function per named lifecycle slot (mod.update,
-- mod.on_enabled, ...), so those slots are centralized here and dispatch out
-- to the per-concern modules loaded below -- each of which is free to define
-- its own ordinary `mod.*` methods and independent `mod:hook(...)` calls.
-- See AGENTS.md "Bootstrap load order" for why the order below is fixed.
local function load(path)
	return mod:io_dofile("Instantium/scripts/mods/Instantium/" .. path)
end

load("core/memory_probe")
load("core/preload_registry")
load("preload/hub")
load("preload/squad_loadouts")

local registered_event_manager = nil

local function register_events()
	local event_manager = Managers.event

	if registered_event_manager == event_manager then
		return
	end

	if registered_event_manager then
		registered_event_manager:unregister(mod, "event_loading_finished")
		registered_event_manager = nil
	end

	if event_manager then
		event_manager:register(mod, "event_loading_finished", "event_loading_finished")
		registered_event_manager = event_manager
	end
end

local function unregister_events()
	if registered_event_manager then
		registered_event_manager:unregister(mod, "event_loading_finished")
		registered_event_manager = nil
	end
end

mod.event_loading_finished = function()
	if not mod:is_enabled() then
		return
	end

	mod:hub_handle_loading_finished()
end

mod.update = function()
	if not mod:is_enabled() then
		return
	end

	register_events()
	mod:hub_handle_update()

	local state_name = Managers.presence and Managers.presence._current_game_state_name

	if state_name == "StateGameplay" then
		mod:run_asset_preloaders("on_squad_ready")
	end
end

mod.on_setting_changed = function(setting_id)
	if not mod:is_enabled() then
		return
	end

	mod:hub_handle_setting_changed(setting_id)

	if setting_id == "memory_tier_override" then
		-- A tighter tier may now exclude a preloader that was previously
		-- running; let each one decide what to release, then let the next
		-- eligible refresh pick back up anything still allowed.
		mod:run_asset_preloaders("on_release")
	end
end

mod.on_enabled = function()
	register_events()
	mod:hub_handle_enabled()
end

mod.on_disabled = function()
	unregister_events()
	mod:run_asset_preloaders("on_release")
	mod:hub_handle_disabled()
end

mod.on_game_state_changed = function(status, state_name)
	if not mod:is_enabled() or status ~= "enter" then
		return
	end

	mod:hub_handle_game_state_changed(status, state_name)

	if state_name == "StateTitle" then
		mod:run_asset_preloaders("on_release")
	end
end

mod.on_unload = function()
	unregister_events()
	mod:run_asset_preloaders("on_release")
	mod:hub_handle_disabled()
end

return mod
