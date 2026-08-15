local mod = get_mod("Instantium")

-- Core backbone, adapted from InstantHub (github.com/.../InstantHub, this
-- machine's ../InstantHub) with its author's permission to reuse as the
-- foundation for this mod. Same retention mechanism: `Managers.package:load`
-- is called independently of the game's own loaders, so the package
-- manager's refcount never drops to zero across a hub<->mission transition,
-- even though the game's own loader still runs its normal cleanup on its own
-- reference. No cleanup functions are hooked; nothing here can leave a
-- loader in a half-cleaned state.
--
-- IMPORTANT: do not run this alongside InstantHub itself -- both mods retain
-- the same hub/Psykhanium packages independently, which is redundant at
-- best. Pick one. See README.md.

local hub_mission_name = "hub_ship"
local psychanium_mission_name = "tg_shooting_range"

local function setting(key)
	return mod:get(key)
end

local function new_preload(reference_name, done_message)
	return {
		state = "idle",
		generation = 0,
		packages = {},
		pending_ids = {},
		scheduling = 0,
		unavailable_packages = {},
		warned_packages = {},
		item_dependencies_scheduled = {},
		theme_dependencies_scheduled = {},
		base_scheduled = false,
		master_items_version = nil,
		active_theme_tag = nil,
		notified = false,
		silent = false,
		reference_name = reference_name,
		done_message = done_message,
	}
end

local hub_preload = new_preload("Instantium:Mourningstar", "Instantium: Mourningstar preloaded")
local hub_theme_preload = new_preload("Instantium:MourningstarTheme", "Instantium: Mourningstar theme preloaded")
local psychanium_preload = new_preload("Instantium:Psychanium", "Instantium: Psychanium / Meat Grinder preloaded")

local hub_ready = false
local hub_setup_pending = false
local hub_ready_once = false
local hub_cache_active = false

local function game_mode_name()
	local game_mode = Managers.state and Managers.state.game_mode

	return game_mode and game_mode:game_mode_name()
end

local function is_in_hub()
	return game_mode_name() == "hub"
end

local function release_preload(preload)
	if preload.state == "released" then
		return
	end

	preload.generation = preload.generation + 1
	preload.state = "released"

	local packages = preload.packages

	preload.packages = {}
	preload.pending_ids = {}
	preload.scheduling = 0
	preload.unavailable_packages = {}
	preload.warned_packages = {}
	preload.item_dependencies_scheduled = {}
	preload.theme_dependencies_scheduled = {}
	preload.base_scheduled = false
	preload.master_items_version = nil
	preload.active_theme_tag = nil
	preload.notified = false
	preload.silent = false

	local package_manager = Managers.package

	if package_manager then
		for _, entry in pairs(packages) do
			package_manager:release(entry.id)
		end
	end
end

local function reset_preload(preload)
	if preload.state ~= "released" then
		release_preload(preload)
	end

	preload.state = "idle"
end

local function mark_preload_done(preload)
	if preload.state ~= "loading" or preload.scheduling > 0 or next(preload.pending_ids) then
		return
	end

	preload.state = "done"

	if not preload.notified and not preload.silent and not next(preload.unavailable_packages) then
		preload.notified = true

		if setting("show_notifications") then
			mod:notify(preload.done_message)
		end
	end
end

local function preload_pkg(preload, name, loaded_callback, prioritize, warn_unavailable)
	if type(name) ~= "string" or preload.state ~= "loading" then
		return
	end

	local existing_entry = preload.packages[name]

	if existing_entry then
		if loaded_callback then
			if existing_entry.loaded then
				loaded_callback()
			else
				existing_entry.callbacks[#existing_entry.callbacks + 1] = loaded_callback
			end
		end

		return existing_entry.id
	end

	local unavailable_entry = preload.unavailable_packages[name]

	if unavailable_entry then
		unavailable_entry.prioritize = unavailable_entry.prioritize or prioritize

		if loaded_callback then
			unavailable_entry.callbacks[#unavailable_entry.callbacks + 1] = loaded_callback
		end

		return
	end

	local package_manager = Managers.package

	if not package_manager then
		return
	end

	local package_is_known = package_manager:package_is_known(name)

	if not package_is_known and (not Application or not Application.can_get_resource("package", name)) then
		preload.unavailable_packages[name] = {
			callbacks = loaded_callback and { loaded_callback } or {},
			prioritize = prioritize,
		}

		if warn_unavailable and not preload.warned_packages[name] then
			preload.warned_packages[name] = true
			mod:warning("Package still unavailable after target load [%s]: %s", preload.reference_name, name)
		end

		return
	end

	local generation = preload.generation

	local function package_loaded(id)
		if preload.generation ~= generation or preload.state == "released" then
			return
		end

		local entry = preload.packages[name]

		if not entry or entry.id ~= id then
			return
		end

		entry.loaded = true
		preload.pending_ids[id] = nil

		local callbacks = entry.callbacks

		entry.callbacks = {}

		for i = 1, #callbacks do
			if preload.generation ~= generation or preload.state == "released" then
				return
			end

			callbacks[i]()
		end

		mark_preload_done(preload)
	end

	local id = package_manager:load(name, preload.reference_name, package_loaded, prioritize)

	preload.packages[name] = {
		id = id,
		loaded = false,
		callbacks = loaded_callback and { loaded_callback } or {},
	}
	preload.pending_ids[id] = true

	return id
end

local function retry_unavailable_packages(preload, warn_unavailable)
	local unavailable_packages = preload.unavailable_packages

	if not next(unavailable_packages) then
		return
	end

	preload.unavailable_packages = {}

	for name, entry in pairs(unavailable_packages) do
		if #entry.callbacks == 0 then
			preload_pkg(preload, name, nil, entry.prioritize, warn_unavailable)
		else
			for i = 1, #entry.callbacks do
				preload_pkg(preload, name, entry.callbacks[i], entry.prioritize, warn_unavailable)
			end
		end
	end
end

local function schedule_preload(preload, silent, schedule, warn_unavailable)
	if preload.state == "released" then
		reset_preload(preload)
	end

	if preload.state == "idle" then
		preload.notified = false
		preload.silent = silent
	elseif not silent then
		preload.silent = false
	end

	preload.state = "loading"
	preload.scheduling = preload.scheduling + 1

	retry_unavailable_packages(preload, warn_unavailable)
	schedule()

	preload.scheduling = preload.scheduling - 1
	mark_preload_done(preload)
end

local function preload_level_items(preload, level_name, item_definitions, item_package, master_items_version)
	if preload.item_dependencies_scheduled[level_name] then
		return
	end

	preload.item_dependencies_scheduled[level_name] = true

	preload_pkg(preload, level_name, function()
		local current_master_items_version = require("scripts/backend/master_items").get_cached_version()

		if preload.master_items_version ~= master_items_version or current_master_items_version ~= master_items_version then
			return
		end

		local item_packages = item_package.level_resource_dependency_packages(item_definitions, level_name)

		if item_packages then
			for package_name, _ in pairs(item_packages) do
				preload_pkg(preload, package_name)
			end
		end
	end)
end

local function preload_level_theme(preload, level_name, theme_tag, theme_package, prioritize)
	local dependency_key = level_name .. "\0" .. theme_tag
	local dependency_data = preload.theme_dependencies_scheduled[dependency_key]

	if dependency_data then
		dependency_data.prioritize = dependency_data.prioritize or prioritize

		return
	end

	dependency_data = {
		prioritize = prioritize or false,
	}
	preload.theme_dependencies_scheduled[dependency_key] = dependency_data

	preload_pkg(preload, level_name, function()
		local theme_packages = theme_package.level_resource_dependency_packages(level_name, theme_tag)

		if theme_packages then
			for _, package_name in pairs(theme_packages) do
				preload_pkg(preload, package_name, nil, dependency_data.prioritize)
			end
		end
	end, dependency_data.prioritize)
end

local function view_preload_policies()
	local disable_preload = GameParameters.disable_view_preload

	return {
		always_even_with_debug = true,
		always = not disable_preload,
		not_ps5 = not disable_preload and not IS_PLAYSTATION,
	}
end

local function preload_views(preload, policy_key, mission_name, item_definitions, item_package, master_items_version)
	local Views = require("scripts/ui/views/views")
	local policies = view_preload_policies()

	for view_name, view_settings in pairs(Views) do
		local policy = view_settings[policy_key]

		if policy and policies[policy] then
			local package_setting = view_settings.package

			if type(package_setting) == "table" then
				for i = 1, #package_setting do
					preload_pkg(preload, package_setting[i])
				end
			else
				preload_pkg(preload, package_setting)
			end

			if view_settings.levels then
				for _, level_name in ipairs(view_settings.levels) do
					preload_level_items(preload, level_name, item_definitions, item_package, master_items_version)
				end
			end

			if view_name == "mission_intro_view" then
				local MissionIntroView = require("scripts/ui/views/mission_intro_view/mission_intro_view")
				local _, dynamic_level_package = MissionIntroView.select_target_intro_level(mission_name)

				if dynamic_level_package and dynamic_level_package.is_level_package then
					preload_level_items(preload, dynamic_level_package.name, item_definitions, item_package, master_items_version)
				elseif dynamic_level_package then
					preload_pkg(preload, dynamic_level_package.name)
				end
			end
		end
	end
end

local function preload_hud(preload, mission_settings)
	if not mission_settings.hud_elements then
		return
	end

	local hud_elements = require(mission_settings.hud_elements)

	if hud_elements then
		for _, element in ipairs(hud_elements) do
			preload_pkg(preload, element.package)
		end
	end
end

local function preload_game_mode(preload, mission_settings)
	local GameModeSettings = require("scripts/settings/game_mode/game_mode_settings")
	local game_mode_settings = GameModeSettings[mission_settings.game_mode_name]
	local packages = game_mode_settings and game_mode_settings.packages

	if packages then
		for i = 1, #packages do
			preload_pkg(preload, packages[i])
		end
	end
end

local function preload_hub_breeds(preload, item_definitions)
	local BreedQueries = require("scripts/utilities/breed_queries")
	local BreedResourceDependencies = require("scripts/utilities/breed_resource_dependencies")
	local chosen_breeds = {}

	for breed_name, breed in pairs(BreedQueries.player_breeds_by_name()) do
		chosen_breeds[breed_name] = breed
	end

	for breed_name, breed in pairs(BreedQueries.minion_companion_breeds_by_name()) do
		chosen_breeds[breed_name] = breed
	end

	local breeds_to_load = BreedResourceDependencies.generate(chosen_breeds, item_definitions)

	if breeds_to_load then
		for package_name, _ in pairs(breeds_to_load) do
			preload_pkg(preload, package_name)
		end
	end
end

local function preload_mission_breeds(preload, item_definitions)
	local BreedResourceDependencies = require("scripts/utilities/breed_resource_dependencies")
	local Breeds = require("scripts/settings/breed/breeds")
	local breeds_to_load = BreedResourceDependencies.generate(Breeds, item_definitions)

	if breeds_to_load then
		for package_name, _ in pairs(breeds_to_load) do
			preload_pkg(preload, package_name)
		end
	end
end

mod.start_hub_preload = function(self, silent, warn_unavailable)
	if hub_preload.state == "released" then
		reset_preload(hub_preload)
	end

	local MasterItems = require("scripts/backend/master_items")
	local Missions = require("scripts/settings/mission/mission_templates")
	local item_definitions = MasterItems.get_cached()
	local master_items_version = MasterItems.get_cached_version()
	local hub_settings = Missions[hub_mission_name]

	if not item_definitions or not hub_settings then
		return false
	end

	local initial_base = not hub_preload.base_scheduled
	local version_changed = hub_preload.base_scheduled and hub_preload.master_items_version ~= master_items_version

	if version_changed then
		hub_preload.item_dependencies_scheduled = {}
		hub_preload.unavailable_packages = {}
		hub_preload.base_scheduled = false
	end

	local needs_base = not hub_preload.base_scheduled
	local has_unavailable_packages = next(hub_preload.unavailable_packages) ~= nil

	if not needs_base and not has_unavailable_packages then
		return true
	end

	if initial_base and setting("show_notifications") and not silent then
		self:notify("Instantium: Preloading Mourningstar...")
	end

	local ItemPackage = require("scripts/foundation/managers/package/utilities/item_package")
	local level_name = hub_settings.level

	schedule_preload(hub_preload, silent, function()
		if needs_base then
			hub_preload.base_scheduled = true
			hub_preload.master_items_version = master_items_version
			preload_level_items(hub_preload, level_name, item_definitions, ItemPackage, master_items_version)
			preload_views(hub_preload, "preload_in_hub", hub_mission_name, item_definitions, ItemPackage, master_items_version)
			preload_hud(hub_preload, hub_settings)
			preload_game_mode(hub_preload, hub_settings)
			preload_hub_breeds(hub_preload, item_definitions)
		end
	end, warn_unavailable)

	return true
end

mod.start_hub_theme_preload = function(self, theme_tag, prioritize, warn_unavailable)
	if hub_theme_preload.state == "released" then
		reset_preload(hub_theme_preload)
	end

	if hub_theme_preload.active_theme_tag and hub_theme_preload.active_theme_tag ~= theme_tag then
		release_preload(hub_theme_preload)
		reset_preload(hub_theme_preload)
	end

	local needs_theme = hub_theme_preload.active_theme_tag ~= theme_tag

	if prioritize then
		for _, entry in pairs(hub_theme_preload.unavailable_packages) do
			entry.prioritize = true
		end
	end

	local has_unavailable_packages = next(hub_theme_preload.unavailable_packages) ~= nil
	local Missions = require("scripts/settings/mission/mission_templates")
	local hub_settings = Missions[hub_mission_name]

	if not hub_settings then
		return
	end

	local ThemePackage = require("scripts/foundation/managers/package/utilities/theme_package")

	if not needs_theme and prioritize then
		preload_level_theme(hub_theme_preload, hub_settings.level, theme_tag, ThemePackage, true)
	end

	if not needs_theme and not has_unavailable_packages then
		return
	end

	schedule_preload(hub_theme_preload, true, function()
		if needs_theme then
			hub_theme_preload.active_theme_tag = theme_tag
			preload_level_theme(hub_theme_preload, hub_settings.level, theme_tag, ThemePackage, prioritize)
		end
	end, warn_unavailable)
end

mod.start_psychanium_preload = function(self, warn_unavailable)
	if not setting("preload_psychanium") then
		return
	end

	if psychanium_preload.state == "released" then
		reset_preload(psychanium_preload)
	end

	local MasterItems = require("scripts/backend/master_items")
	local Missions = require("scripts/settings/mission/mission_templates")
	local item_definitions = MasterItems.get_cached()
	local master_items_version = MasterItems.get_cached_version()
	local mission_settings = Missions[psychanium_mission_name]

	if not item_definitions or not mission_settings then
		return
	end

	local initial_base = not psychanium_preload.base_scheduled
	local version_changed = psychanium_preload.base_scheduled and psychanium_preload.master_items_version ~= master_items_version

	if version_changed then
		psychanium_preload.item_dependencies_scheduled = {}
		psychanium_preload.theme_dependencies_scheduled = {}
		psychanium_preload.unavailable_packages = {}
		psychanium_preload.base_scheduled = false
	end

	local needs_base = not psychanium_preload.base_scheduled
	local has_unavailable_packages = next(psychanium_preload.unavailable_packages) ~= nil

	if not needs_base and not has_unavailable_packages then
		return
	end

	if initial_base and setting("show_notifications") then
		self:notify("Instantium: Preloading Psychanium / Meat Grinder...")
	end

	local ItemPackage = require("scripts/foundation/managers/package/utilities/item_package")
	local ThemePackage = require("scripts/foundation/managers/package/utilities/theme_package")

	schedule_preload(psychanium_preload, false, function()
		if needs_base then
			psychanium_preload.base_scheduled = true
			psychanium_preload.master_items_version = master_items_version
			psychanium_preload.active_theme_tag = "default"
			preload_level_items(psychanium_preload, mission_settings.level, item_definitions, ItemPackage, master_items_version)
			preload_level_theme(psychanium_preload, mission_settings.level, "default", ThemePackage)
			preload_views(psychanium_preload, "preload_in_mission", psychanium_mission_name, item_definitions, ItemPackage, master_items_version)
			preload_hud(psychanium_preload, mission_settings)
			preload_game_mode(psychanium_preload, mission_settings)
			preload_mission_breeds(psychanium_preload, item_definitions)
		end
	end, warn_unavailable)
end

local function hub_theme_tag(circumstance_name)
	local CircumstanceTemplates = require("scripts/settings/circumstance/circumstance_templates")
	local circumstance_template = circumstance_name and CircumstanceTemplates[circumstance_name]

	return circumstance_template and circumstance_template.theme_tag or "default"
end

local function current_hub_theme_tag()
	local mechanism_manager = Managers.mechanism
	local mechanism_data = mechanism_manager and mechanism_manager:mechanism_data()

	return hub_theme_tag(mechanism_data and mechanism_data.circumstance_name)
end

local function should_keep_hub_preload()
	local early_preload_active = not hub_ready_once and setting("preload_hub")

	return early_preload_active or hub_cache_active
end

mod.release_hub_preloads = function(self)
	release_preload(hub_preload)
	release_preload(hub_theme_preload)
	release_preload(psychanium_preload)
end

local function prepare_hub_caches()
	hub_setup_pending = false
	hub_ready_once = true

	if setting("hub_caching") then
		hub_cache_active = true
		mod:start_hub_preload(true, true)
		mod:start_hub_theme_preload(current_hub_theme_tag(), false, true)
	else
		hub_cache_active = false
		release_preload(hub_preload)
		release_preload(hub_theme_preload)
	end

	mod:start_psychanium_preload()
	mod:run_asset_preloaders("on_hub_ready")
end

mod:hook("MechanismManager", "wanted_transition", function(func, self, ...)
	local next_state, context = func(self, ...)

	if context and context.mission_name == hub_mission_name then
		if should_keep_hub_preload() then
			mod:start_hub_preload(true)
		end

		if setting("preload_hub") or setting("hub_caching") then
			mod:start_hub_theme_preload(hub_theme_tag(context.circumstance_name), true)
		end
	elseif context and context.mission_name == psychanium_mission_name then
		mod:start_psychanium_preload()
	end

	local mission_warmup_handler = mod.mission_warmup_handle_transition

	if mission_warmup_handler then
		mission_warmup_handler(mod, context)
	end

	return next_state, context
end)

mod:hook("StateTitle", "update", function(func, self, ...)
	local next_state, params = func(self, ...)

	if not hub_ready_once and self._backend_data_synced and setting("preload_hub") then
		mod:start_hub_preload(false)
	end

	return next_state, params
end)

--- Called from the bootstrap's `mod.event_loading_finished`.
mod.hub_handle_loading_finished = function(self)
	local mode_name = game_mode_name()

	if mode_name == "hub" then
		hub_ready = true
		hub_setup_pending = true

		if setting("show_notifications") then
			self:notify("Instantium: Mourningstar ready")
		end
	else
		if mode_name == "shooting_range" then
			self:start_psychanium_preload(true)

			if setting("show_notifications") then
				self:notify("Instantium: Psychanium / Meat Grinder ready")
			end
		end

		if hub_cache_active and setting("hub_caching") then
			self:start_hub_preload(true)
		end
	end
end

--- Called every frame from the bootstrap's `mod.update`.
mod.hub_handle_update = function(self)
	local state_name = Managers.presence and Managers.presence._current_game_state_name

	if state_name == "StateMainMenu" and setting("preload_hub") and not hub_ready_once then
		self:start_hub_preload(false)
	end

	if hub_setup_pending and hub_ready and is_in_hub() then
		prepare_hub_caches()
	end
end

--- Called from the bootstrap's `mod.on_setting_changed`.
mod.hub_handle_setting_changed = function(self, setting_id)
	if setting_id == "hub_caching" then
		if setting("hub_caching") then
			local state_name = Managers.presence and Managers.presence._current_game_state_name

			if hub_ready or hub_ready_once or state_name == "StateGameplay" then
				hub_cache_active = true
				self:start_hub_preload(true)

				if is_in_hub() then
					self:start_hub_theme_preload(current_hub_theme_tag())
				end
			end
		else
			hub_cache_active = false

			if not should_keep_hub_preload() then
				release_preload(hub_preload)
				release_preload(hub_theme_preload)
			end
		end
	elseif setting_id == "preload_hub" then
		if setting("preload_hub") then
			local state_name = Managers.presence and Managers.presence._current_game_state_name

			if not hub_ready_once and state_name == "StateMainMenu" then
				self:start_hub_preload(false)
			end
		elseif not should_keep_hub_preload() then
			release_preload(hub_preload)
			release_preload(hub_theme_preload)
		end
	elseif setting_id == "preload_psychanium" then
		if setting("preload_psychanium") then
			local state_name = Managers.presence and Managers.presence._current_game_state_name

			if (hub_ready and is_in_hub()) or state_name == "StateGameplay" then
				self:start_psychanium_preload()
			end
		else
			release_preload(psychanium_preload)
		end
	end
end

--- Called from the bootstrap's `mod.on_enabled`.
mod.hub_handle_enabled = function(self)
	if hub_preload.state == "released" then
		reset_preload(hub_preload)
	end

	if hub_theme_preload.state == "released" then
		reset_preload(hub_theme_preload)
	end

	if psychanium_preload.state == "released" then
		reset_preload(psychanium_preload)
	end

	local state_name = Managers.presence and Managers.presence._current_game_state_name

	if state_name == "StateGameplay" then
		if is_in_hub() then
			hub_ready = true
			hub_setup_pending = true
		elseif setting("hub_caching") then
			hub_cache_active = true
			self:start_hub_preload(true)
		end

		if not is_in_hub() and setting("preload_psychanium") then
			self:start_psychanium_preload()
		end
	end
end

--- Called from the bootstrap's `mod.on_disabled`.
mod.hub_handle_disabled = function(self)
	self:release_hub_preloads()

	hub_ready = false
	hub_setup_pending = false
	hub_ready_once = false
	hub_cache_active = false
end

--- Called from the bootstrap's `mod.on_game_state_changed`.
mod.hub_handle_game_state_changed = function(self, status, state_name)
	if status ~= "enter" then
		return
	end

	if state_name == "StateLoading" or state_name == "StateMainMenu" or state_name == "StateTitle" then
		hub_ready = false
		hub_setup_pending = false
	end

	if state_name == "StateTitle" then
		self:release_hub_preloads()

		hub_ready_once = false
		hub_cache_active = false
	end
end

return mod
