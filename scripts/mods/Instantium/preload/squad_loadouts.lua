local mod = get_mod("Instantium")
local PlayerCompositions = require("scripts/utilities/players/player_compositions")

-- First built-in consumer of core/preload_registry.lua, and the actual
-- expansion beyond InstantHub's scope: InstantHub only ever preloads *your
-- own* equipped profile. This resolves and retains equipped-loadout
-- packages (weapon skins/materials, cosmetics -- whatever
-- `resolve_profile_packages` says a profile depends on) for every
-- party member in the hub and every human squad member in a mission, so
-- teammates' weapons/gear don't pop in either. The aggressive tier expands
-- the hub scope to every visible human player.
--
-- Gated at "balanced" tier: balanced keeps the hub scope to the actual party,
-- while aggressive accepts the cost of every visible hub player's packages.
-- Both tiers include every human squad member in missions.

local REFRESH_INTERVAL = 5 -- seconds between resolve passes; cheap no-op in between.

local preloads = {}
local party_players = {}
local next_refresh_time = 0

local function players_to_preload(player_manager)
	local game_mode = Managers.state and Managers.state.game_mode

	if game_mode and game_mode:game_mode_name() == "hub" and mod:get_preload_tier() ~= "aggressive" then
		return PlayerCompositions.players("party", party_players)
	end

	return player_manager:human_players()
end

local function local_profile_package_resolver()
	local package_synchronization_manager = Managers.package_synchronization
	local synchronizer_client = package_synchronization_manager and package_synchronization_manager:synchronizer_client()

	if synchronizer_client and synchronizer_client:item_definitions_initialized() then
		return synchronizer_client
	end

	local item_definitions = require("scripts/backend/master_items").get_cached()

	if not item_definitions then
		return
	end

	local PackageSynchronizerClient = require("scripts/loading/package_synchronizer_client")

	return setmetatable({
		_item_definitions = item_definitions,
		_mission_name = "hub_ship",
	}, {
		__index = PackageSynchronizerClient,
	})
end

local function release_player_preload(unique_id)
	local entry = preloads[unique_id]

	if not entry then
		return
	end

	local package_manager = Managers.package

	if package_manager then
		for _, id in pairs(entry.packages) do
			package_manager:release(id)
		end
	end

	preloads[unique_id] = nil
end

local function refresh_player_preload(unique_id, profile, resolver, package_manager)
	local entry = preloads[unique_id]
	local mission_name = resolver._mission_name

	if entry and entry.character_id == profile.character_id and entry.profile == profile and entry.mission_name == mission_name then
		return
	end

	local ok, profile_packages = pcall(resolver.resolve_profile_packages, resolver, profile)

	if not ok or not profile_packages then
		return
	end

	local desired = {}

	for _, package_data in pairs(profile_packages) do
		for package_name, _ in pairs(package_data.dependencies) do
			desired[package_name] = true
		end
	end

	if not entry or entry.character_id ~= profile.character_id then
		if entry then
			release_player_preload(unique_id)
		end

		entry = { character_id = profile.character_id, packages = {} }
		preloads[unique_id] = entry
	end

	entry.profile = profile
	entry.mission_name = mission_name

	for package_name, id in pairs(entry.packages) do
		if not desired[package_name] then
			package_manager:release(id)
			entry.packages[package_name] = nil
		end
	end

	for package_name, _ in pairs(desired) do
		if not entry.packages[package_name] then
			entry.packages[package_name] = package_manager:load(package_name, "Instantium:SquadLoadouts")
		end
	end
end

--- Registered under both "on_hub_ready" and "on_squad_ready" -- see
--- Instantium.lua. Internally throttled, so it's safe for the bootstrap to
--- invoke the registry every update tick.
local function refresh_all(dt_ignored)
	local now = os.clock()

	if now < next_refresh_time then
		return
	end

	next_refresh_time = now + REFRESH_INTERVAL

	local player_manager = Managers.player
	local package_manager = Managers.package

	if not player_manager or not package_manager then
		return
	end

	local resolver = local_profile_package_resolver()

	if not resolver then
		return
	end

	local seen = {}

	for _, player in pairs(players_to_preload(player_manager)) do
		local unique_id = player:unique_id()
		local profile = player:profile()

		if unique_id and profile and profile.character_id then
			seen[unique_id] = true
			refresh_player_preload(unique_id, profile, resolver, package_manager)
		end
	end

	for unique_id, _ in pairs(preloads) do
		if not seen[unique_id] then
			release_player_preload(unique_id)
		end
	end
end

mod.squad_loadouts_release_all = function(self)
	for unique_id, _ in pairs(preloads) do
		release_player_preload(unique_id)
	end

	next_refresh_time = 0
end

mod:register_asset_preloader(mod, {
	name = "instantium_squad_loadouts",
	min_tier = "balanced",
	on_hub_ready = refresh_all,
	on_squad_ready = refresh_all,
	on_release = mod.squad_loadouts_release_all,
})

return mod
