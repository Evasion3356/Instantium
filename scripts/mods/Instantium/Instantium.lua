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
load("preload/mission_warmup")
load("preload/unit_stream_warmup")

local function call_mission_warmup(method_name, ...)
	local handler = mod[method_name]

	if handler then
		return handler(mod, ...)
	end
end

local registered_event_manager = nil

local function register_events()
	local event_manager = Managers.event

	if registered_event_manager == event_manager then
		return
	end

	if registered_event_manager then
		registered_event_manager:unregister(mod, "unit_registered")
		registered_event_manager:unregister(mod, "event_loading_started")
		registered_event_manager:unregister(mod, "event_loading_finished")
		registered_event_manager = nil
	end

	if event_manager then
		event_manager:register(mod, "unit_registered", "event_unit_registered")
		event_manager:register(mod, "event_loading_started", "event_loading_started")
		event_manager:register(mod, "event_loading_finished", "event_loading_finished")
		registered_event_manager = event_manager
	end
end

local function unregister_events()
	if registered_event_manager then
		registered_event_manager:unregister(mod, "unit_registered")
		registered_event_manager:unregister(mod, "event_loading_started")
		registered_event_manager:unregister(mod, "event_loading_finished")
		registered_event_manager = nil
	end
end

mod.event_loading_finished = function()
	if not mod:is_enabled() then
		return
	end

	mod:hub_handle_loading_finished()
	call_mission_warmup("mission_warmup_handle_loading_finished")
	mod:unit_stream_handle_loading_finished()
end

mod.event_unit_registered = function(self, unit)
	if mod:is_enabled() then
		mod:unit_stream_handle_registered(unit)
	end
end

mod.update = function(dt)
	if not mod:is_enabled() then
		return
	end

	register_events()
	mod:hub_handle_update()
	call_mission_warmup("mission_warmup_handle_update")
	mod:unit_stream_handle_update(dt)

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
	mod:unit_stream_handle_setting_changed(setting_id)

	if setting_id == "memory_tier_override" then
		-- A tighter tier may now exclude a preloader that was previously
		-- running; let each one decide what to release, then let the next
		-- eligible refresh pick back up anything still allowed.
		mod:run_asset_preloaders("on_release")
		call_mission_warmup("mission_warmup_handle_setting_changed")
	end
end

mod.on_enabled = function()
	register_events()
	mod:hub_handle_enabled()
	call_mission_warmup("mission_warmup_handle_enabled")
	mod:unit_stream_handle_enabled()
end

mod.event_loading_started = function()
	if not mod:is_enabled() then
		return
	end

	call_mission_warmup("mission_warmup_handle_loading_started")
	mod:unit_stream_handle_loading_started()
end

mod.on_disabled = function()
	unregister_events()
	mod:run_asset_preloaders("on_release")
	call_mission_warmup("mission_warmup_clear")
	mod:unit_stream_clear()
	mod:hub_handle_disabled()
end

mod.on_game_state_changed = function(status, state_name)
	if status == "exit" and state_name == "StateGame" then
		mod:unit_stream_clear()
		unregister_events()
		return
	end

	if not mod:is_enabled() or status ~= "enter" then
		return
	end

	mod:hub_handle_game_state_changed(status, state_name)

	if state_name == "StateTitle" then
		mod:run_asset_preloaders("on_release")
		call_mission_warmup("mission_warmup_clear")
		mod:unit_stream_clear()
	end
end

mod.on_unload = function(exit_game)
	if exit_game then
		-- EventManager is destroyed before ModManager triggers DMF's exit unload event.
		registered_event_manager = nil
	else
		unregister_events()
	end

	mod:run_asset_preloaders("on_release")
	call_mission_warmup("mission_warmup_clear")
	mod:unit_stream_clear()
	mod:hub_handle_disabled()
end

return mod
