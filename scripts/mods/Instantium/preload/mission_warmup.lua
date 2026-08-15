local mod = get_mod("Instantium")

local BreedResourceDependencies = require("scripts/utilities/breed_resource_dependencies")
local Breeds = require("scripts/settings/breed/breeds")
local CircumstanceTemplates = require("scripts/settings/circumstance/circumstance_templates")
local Havoc = require("scripts/utilities/havoc")
local ItemPackage = require("scripts/foundation/managers/package/utilities/item_package")
local MasterItems = require("scripts/backend/master_items")
local Missions = require("scripts/settings/mission/mission_templates")
local ThemePackage = require("scripts/foundation/managers/package/utilities/theme_package")

local CORE_REFERENCE = "Instantium:MissionWarmup:Core"
local BREED_REFERENCE = "Instantium:MissionWarmup:Breeds"
local VOTE_TEMPLATE = "mission_vote_matchmaking_immaterium"

local state = mod:persistent_table("mission_warmup_state")
state.generation = state.generation or 0
state.package_ids = state.package_ids or {}

local breed_cache_version = nil
local breed_cache_packages = nil

local function release_packages()
	state.generation = state.generation + 1

	local package_ids = state.package_ids
	local package_manager = Managers.package

	state.package_ids = {}
	state.core_started = false
	state.level_loaded = false
	state.core_dependencies_started = false
	state.breeds_started = false
	state.unavailable_warning_emitted = false

	if package_manager then
		for _, entry in pairs(package_ids) do
			package_manager:release(entry.id)
		end
	end
end

local function clear_target()
	release_packages()
	state.target = nil
	state.waiting_for_assignment = false
	state.matchmaking_started = false
	state.vote_observed = false
	state.vote_committed = false
end

-- A module-only development reload can otherwise inherit IDs owned by the old
-- callbacks. Full DMF reloads already release through mod.on_unload.
clear_target()
state.backend_mission_id = nil

local function package_available(package_manager, package_name)
	if package_manager:package_is_known(package_name) then
		return true
	end

	local application = rawget(_G, "Application")
	local can_get_resource = application and application.can_get_resource

	return type(can_get_resource) == "function" and can_get_resource("package", package_name)
end

local function load_package(package_name, reference_name, loaded_callback)
	if type(package_name) ~= "string" or state.package_ids[package_name] then
		return
	end

	local package_manager = Managers.package

	if not package_manager or not package_available(package_manager, package_name) then
		if not state.unavailable_warning_emitted then
			state.unavailable_warning_emitted = true
			mod:warning("Mission warmup skipped unavailable package: %s", tostring(package_name))
		end

		return
	end

	local generation = state.generation
	local function on_loaded(id)
		if generation ~= state.generation then
			return
		end

		local entry = state.package_ids[package_name]

		if not entry or entry.id ~= id then
			return
		end

		entry.loaded = true

		if loaded_callback then
			loaded_callback()
		end
	end

	local id = package_manager:load(package_name, reference_name, on_loaded)

	state.package_ids[package_name] = {
		id = id,
		loaded = false,
		reference_name = reference_name,
	}

	return id
end

local function theme_tag(circumstance_name, havoc_data, is_havoc, theme_override)
	if theme_override then
		return theme_override
	end

	if havoc_data then
		local ok, parsed_data = pcall(Havoc.parse_data, havoc_data)

		if ok and parsed_data then
			return parsed_data.theme
		end
	elseif is_havoc then
		return nil
	end

	local circumstance = circumstance_name and CircumstanceTemplates[circumstance_name]

	return circumstance and circumstance.theme_tag or "default"
end

local function target_key(target)
	return table.concat({
		target.mission_name,
		target.theme_tag or "deferred",
		target.skip_theme and "no-theme" or "theme",
	}, "\0")
end

local function load_core_dependencies(target)
	local item_definitions = MasterItems.get_cached()

	if not item_definitions then
		return false
	end

	local item_packages = ItemPackage.level_resource_dependency_packages(item_definitions, target.level_name)

	for package_name, _ in pairs(item_packages) do
		load_package(package_name, CORE_REFERENCE)
	end

	if target.theme_tag and not target.skip_theme then
		local theme_packages = ThemePackage.level_resource_dependency_packages(target.level_name, target.theme_tag)

		for _, package_name in pairs(theme_packages) do
			load_package(package_name, CORE_REFERENCE)
		end
	end

	return true
end

local function breed_packages()
	local item_definitions = MasterItems.get_cached()

	if not item_definitions then
		return nil
	end

	local version = MasterItems.get_cached_version()

	if breed_cache_version ~= version then
		breed_cache_packages = BreedResourceDependencies.generate(Breeds, item_definitions)
		breed_cache_version = version
	end

	return breed_cache_packages
end

local function ensure_target_loaded()
	local target = state.target

	if not target then
		return
	end

	local tier = mod:get_preload_tier()

	if tier == "conservative" then
		return
	end

	if not state.core_started then
		local id = load_package(target.level_name, CORE_REFERENCE, function()
			state.level_loaded = true
			ensure_target_loaded()
		end)

		state.core_started = id ~= nil
	end

	if state.level_loaded and not state.core_dependencies_started then
		state.core_dependencies_started = load_core_dependencies(target)
	end

	if tier == "aggressive" and not state.breeds_started then
		local packages = breed_packages()

		if packages then
			state.breeds_started = true

			for package_name, _ in pairs(packages) do
				load_package(package_name, BREED_REFERENCE)
			end
		end
	end
end

local function set_target(mission_name, circumstance_name, havoc_data, is_havoc, theme_override, skip_theme)
	local mission = mission_name and Missions[mission_name]

	if not mission or mission.is_hub or mission_name == "hub_ship" or mission_name == "tg_shooting_range" then
		return false
	end

	local level_name = mission.level

	if type(level_name) ~= "string" then
		return false
	end

	local target = {
		mission_name = mission_name,
		level_name = level_name,
		circumstance_name = circumstance_name,
		theme_tag = theme_tag(circumstance_name, havoc_data, is_havoc, theme_override),
		skip_theme = skip_theme or mission.expedition_template ~= nil,
	}
	target.key = target_key(target)

	if state.target and state.target.key == target.key then
		state.waiting_for_assignment = false
		ensure_target_loaded()

		return true
	end

	release_packages()
	state.target = target
	state.waiting_for_assignment = false
	ensure_target_loaded()

	return true
end

local function flag_value(flags, prefix)
	if type(flags) ~= "table" then
		return nil
	end

	for flag, _ in pairs(flags) do
		if type(flag) == "string" and string.sub(flag, 1, #prefix) == prefix then
			return string.sub(flag, #prefix + 1)
		end
	end

	return nil
end

local function decode_mission_data(value)
	local json = rawget(_G, "cjson")
	local decode = json and json.decode

	if type(value) ~= "string" or type(decode) ~= "function" then
		return nil
	end

	local ok, data = pcall(decode, value)

	return ok and data and data.mission or nil
end

mod.mission_warmup_handle_vote_event = function(self, event)
	local params = event and event.params
	local is_target_vote = params and (params.template_name == VOTE_TEMPLATE or state.backend_mission_id ~= nil and state.backend_mission_id == params.backend_mission_id)

	if not is_target_vote then
		return
	end

	local vote_state = event.state

	if vote_state == "ONGOING" then
		state.backend_mission_id = params.backend_mission_id
		state.matchmaking_started = false
		state.vote_observed = true
		state.vote_committed = false

		if params.qp == "true" then
			release_packages()
			state.target = nil
			state.waiting_for_assignment = true

			return
		end

		local mission_data = decode_mission_data(params.mission_data)
		local havoc_theme = mission_data and flag_value(mission_data.flags, "havoc-theme-")
		local is_havoc = havoc_theme ~= nil or string.find(params.mission_data or "", "havoc-rank", 1, true) ~= nil
		local is_expedition = mission_data and mission_data.category == "expedition"

		if mission_data and set_target(mission_data.map, mission_data.circumstance, nil, is_havoc, havoc_theme, is_expedition) then
			return
		end

		release_packages()
		state.target = nil
		state.waiting_for_assignment = true
	elseif vote_state == "COMPLETED_APPROVED" then
		state.matchmaking_started = true
		state.vote_observed = false
		state.vote_committed = true
	else
		clear_target()
		state.backend_mission_id = nil
	end
end

mod.mission_warmup_handle_game_state = function(self, game_state)
	local status = game_state and game_state.status

	if status == "MATCHMAKING_IN_PROGRESS" then
		state.matchmaking_started = true
	elseif status == "GAME_SESSION_IN_PROGRESS" then
		state.matchmaking_started = false
	elseif status == "" and state.matchmaking_started then
		clear_target()
		state.backend_mission_id = nil
	end
end

mod.mission_warmup_handle_transition = function(self, context)
	if type(context) ~= "table" or type(context.mission_name) ~= "string" then
		return
	end

	if not state.waiting_for_assignment and not state.target and not context.backend_mission_id then
		return
	end

	if set_target(context.mission_name, context.circumstance_name, context.havoc_data, context.havoc_data ~= nil) then
		state.backend_mission_id = context.backend_mission_id or state.backend_mission_id
	end
end

mod.mission_warmup_handle_update = function(self)
	if state.vote_observed and not state.vote_committed then
		local party_manager = Managers.party_immaterium
		local vote_state = party_manager and party_manager:party_vote_state()

		if not vote_state or vote_state.state ~= "ONGOING" then
			clear_target()
			state.backend_mission_id = nil

			return
		end
	end

	if state.target then
		ensure_target_loaded()
	end
end

mod.mission_warmup_handle_enabled = function(self)
	local party_manager = Managers.party_immaterium
	local game_state = party_manager and party_manager:party_game_state()

	if party_manager and game_state.status ~= "GAME_SESSION_IN_PROGRESS" then
		self:mission_warmup_handle_vote_event(party_manager:party_vote_state())
		self:mission_warmup_handle_game_state(game_state)
	end

	local mechanism_manager = Managers.mechanism

	if mechanism_manager and game_state and game_state.status ~= "GAME_SESSION_IN_PROGRESS" then
		local ok, mechanism_data = pcall(mechanism_manager.mechanism_data, mechanism_manager)

		if ok then
			self:mission_warmup_handle_transition(mechanism_data)
		end
	end
end

mod.mission_warmup_handle_loading_finished = function(self)
	clear_target()
	state.backend_mission_id = nil
end

mod.mission_warmup_handle_setting_changed = function(self)
	release_packages()
	ensure_target_loaded()
end

mod.mission_warmup_clear = function(self)
	clear_target()
	state.backend_mission_id = nil
end

mod:register_asset_preloader(mod, {
	name = "instantium_mission_warmup",
	min_tier = "balanced",
	on_release = release_packages,
})

mod:hook("PartyImmateriumManager", "_handle_party_vote_update_event", function(func, self, event)
	local result = func(self, event)

	if mod:is_enabled() then
		mod:mission_warmup_handle_vote_event(event)
	end

	return result
end)

mod:hook("PartyImmateriumManager", "_handle_party_game_state_update_event", function(func, self, event)
	local result = func(self, event)

	if mod:is_enabled() then
		mod:mission_warmup_handle_game_state(self:party_game_state())
	end

	return result
end)

return mod
