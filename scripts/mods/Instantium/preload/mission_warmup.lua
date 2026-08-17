local mod = get_mod("Instantium")

local CircumstanceTemplates = require("scripts/settings/circumstance/circumstance_templates")
local Havoc = require("scripts/utilities/havoc")
local Missions = require("scripts/settings/mission/mission_templates")
local MissionManifest = mod:io_dofile("Instantium/scripts/mods/Instantium/preload/mission_manifest")

local MAX_SUBMISSIONS_PER_FRAME = 4
local MAX_IN_FLIGHT = 8
local EXPEDITION_SNAPSHOT_INTERVAL = 0.25
local REFERENCE = "Instantium:MissionWarmup"
local VOTE_TEMPLATE = "mission_vote_matchmaking_immaterium"

local state = mod:persistent_table("mission_warmup_state")
state.generation = state.generation or 0
state.stats = state.stats or {}

local function increment(name, amount)
    local stats = state.stats

    stats[name] = (stats[name] or 0) + (amount or 1)
end

local function reset_work()
    state.manifest = nil
    state.entries = {}
    state.ids = {}
    state.loaded_levels = {}
    state.category_index = 1
    state.category_cursors = {}
    state.expanded = false
    state.in_flight = 0
    state.peak_in_flight = 0
    state.submitted_frames = 0
    state.deferred_busy_frames = 0
    state.dynamic_additions = 0
    state.next_expedition_snapshot_time = 0
end

local function release_packages(reason)
    state.generation = state.generation + 1

    local ids = state.ids or {}
    local legacy_package_ids = state.package_ids or {}
    local package_manager = Managers.package
    local owner_package_manager = state.package_manager

    state.ids = {}
    state.package_ids = nil
    state.package_manager = nil
    state.in_flight = 0

    if package_manager and package_manager == owner_package_manager then
        for id, _ in pairs(ids) do
            package_manager:release(id)
            increment("releases")
        end
    end

    if package_manager then
        for _, entry in pairs(legacy_package_ids) do
            if entry.id then
                package_manager:release(entry.id)
                increment("releases")
            end
        end
    end

    if reason == "cancel" then
        increment("cancellations")
    end

    reset_work()
end

local function clear_target(reason)
    release_packages(reason)
    state.target = nil
    state.tier = nil
    state.handoff = false
    state.waiting_for_assignment = false
    state.matchmaking_started = false
    state.vote_observed = false
    state.vote_committed = false
end

-- A module-only development reload can inherit IDs owned by old callbacks.
clear_target()
state.backend_mission_id = nil

local function package_available(package_manager, package_name)
    if package_manager:package_is_known(package_name) then
        return true
    end

    local application = rawget(_G, "Application")
    local can_get_resource = application and application.can_get_resource

    if type(can_get_resource) ~= "function" then
        return false
    end

    local ok, available = pcall(can_get_resource, "package", package_name)

    return ok and available == true
end

local function copy_expedition_snapshot()
    local mechanism_manager = Managers.mechanism

    if not mechanism_manager or mechanism_manager:mechanism_name() ~= "expedition" then
        return nil, nil
    end

    local mechanism = mechanism_manager:current_mechanism()
    local levels_spawner = mechanism and mechanism.levels_spawner and mechanism:levels_spawner()
    local expedition = levels_spawner and levels_spawner:expedition()
    local current_index = mechanism and mechanism.current_location_index and mechanism:current_location_index()
    local mechanism_data = mechanism and mechanism.mechanism_data and mechanism:mechanism_data()

    if type(expedition) ~= "table" or type(current_index) ~= "number" then
        return nil, {
            section = current_index,
            layout_seed = mechanism_data and mechanism_data.layout_seed,
            layout_config_name = mechanism_data and mechanism_data.layout_config_name,
            node_id = mechanism_data and mechanism_data.node_id,
            settings_version = mechanism_data and mechanism_data.settings_version,
            package_signature = "",
        }
    end

    local levels = {}
    local current = expedition[current_index]

    if type(current) ~= "table" or type(current.levels_data) ~= "table" then
        return nil, {
            section = current_index,
            layout_seed = mechanism_data and mechanism_data.layout_seed,
            layout_config_name = mechanism_data and mechanism_data.layout_config_name,
            node_id = mechanism_data and mechanism_data.node_id,
            settings_version = mechanism_data and mechanism_data.settings_version,
            package_signature = "",
        }
    end

    for section_index = math.max(1, current_index - 1), current_index do
        local section = expedition[section_index]
        local is_prior_section = section_index ~= current_index

        for i = 1, #(section and section.levels_data or {}) do
            local level_data = section.levels_data[i]

            if type(level_data.level_name) == "string" and (not is_prior_section or level_data.delayed_despawn) then
                levels[#levels + 1] = {
                    level_name = level_data.level_name,
                    theme_tag = section.theme_tag,
                    load_theme = level_data.is_location == true or level_data.is_safe_zone == true,
                    delayed_despawn = is_prior_section,
                }
            end
        end
    end

    table.sort(levels, function(a, b)
        return a.level_name < b.level_name
    end)
    local signature = {
        tostring(current_index),
    }

    for i = 1, #levels do
        signature[#signature + 1] = levels[i].level_name
        signature[#signature + 1] = levels[i].theme_tag or ""
        signature[#signature + 1] = levels[i].load_theme and "theme" or "no-theme"
        signature[#signature + 1] = levels[i].delayed_despawn and "delayed" or "current"
    end

    return levels, {
        section = current_index,
        layout_seed = mechanism_data and mechanism_data.layout_seed,
        layout_config_name = mechanism_data and mechanism_data.layout_config_name,
        node_id = mechanism_data and mechanism_data.node_id,
        settings_version = mechanism_data and mechanism_data.settings_version,
        package_signature = table.concat(signature, "|"),
    }
end

local function stable_value(value)
    local value_type = type(value)

    if value_type == "string" or value_type == "number" or value_type == "boolean" then
        return tostring(value)
    end

    return ""
end

local function target_key(target)
    return table.concat({
        target.mission_name,
        target.circumstance_name or "",
        table.concat(target.circumstances or {}, ","),
        target.havoc_data or "",
        target.theme_tag or "",
        target.is_expedition and "expedition" or "mission",
        stable_value(target.expedition_identity and target.expedition_identity.section),
        stable_value(target.expedition_identity and target.expedition_identity.layout_seed),
        stable_value(target.expedition_identity and target.expedition_identity.layout_config_name),
        stable_value(target.expedition_identity and target.expedition_identity.node_id),
        stable_value(target.expedition_identity and target.expedition_identity.settings_version),
        stable_value(target.expedition_identity and target.expedition_identity.package_signature),
        stable_value(target.backend_mission_id),
        stable_value(target.side_mission),
    }, "\0")
end

local function parsed_havoc(havoc_data)
    if type(havoc_data) ~= "string" then
        return nil
    end

    local ok, parsed = pcall(Havoc.parse_data, havoc_data)

    return ok and parsed or nil
end

local function build_target(mission_name, context)
    local mission = mission_name and Missions[mission_name]

    if not mission or mission.is_hub or mission_name == "hub_ship" or mission_name == "tg_shooting_range" or type(mission.level) ~= "string" then
        return nil
    end

    context = context or {}

    local parsed = parsed_havoc(context.havoc_data)
    local circumstance_name = context.circumstance_name
    local circumstances = {}
    local seen_circumstances = {}

    local function add_circumstance(name)
        if type(name) == "string" and CircumstanceTemplates[name] and not seen_circumstances[name] then
            seen_circumstances[name] = true
            circumstances[#circumstances + 1] = name
        end
    end

    if parsed and parsed.circumstances then
        for i = 1, #parsed.circumstances do
            add_circumstance(parsed.circumstances[i])
        end
    elseif context.circumstances and #context.circumstances > 0 then
        for i = 1, #context.circumstances do
            add_circumstance(context.circumstances[i])
        end
    else
        add_circumstance(circumstance_name)
    end

    table.sort(circumstances)

    local circumstance = circumstance_name and CircumstanceTemplates[circumstance_name]
    local is_expedition = context.is_expedition or mission.expedition_template ~= nil
    local expedition_levels, expedition_identity

    if is_expedition then
        expedition_levels, expedition_identity = copy_expedition_snapshot()
    end

    local target = {
        mission_name = mission_name,
        level_name = mission.level,
        circumstance_name = circumstance_name,
        circumstances = circumstances,
        havoc_data = context.havoc_data,
        theme_tag = context.theme_override or parsed and parsed.theme or circumstance and circumstance.theme_tag,
        is_expedition = is_expedition,
        expedition_levels = expedition_levels,
        expedition_identity = expedition_identity,
        backend_mission_id = context.backend_mission_id,
        side_mission = context.side_mission,
    }
    target.key = target_key(target)

    return target
end

local function install_manifest(manifest, dynamic)
    if not manifest then
        return false
    end

    local old_entries = state.entries
    local entries = {}

    for i = 1, #MissionManifest.categories do
        local category = MissionManifest.categories[i]
        local category_entries = manifest[category]

        for j = 1, #category_entries do
            local resolved = category_entries[j]
            local existing = old_entries[resolved.name]

            if existing then
                entries[resolved.name] = existing
            else
                entries[resolved.name] = {
                    category = category,
                    name = resolved.name,
                    reason = resolved.reason,
                    status = "queued",
                }

                if dynamic then
                    increment("dynamic_additions")
                end
            end
        end
    end

    state.manifest = manifest
    state.entries = entries

    return true
end

local function start_target(target)
    local tier = mod:get_preload_tier()

    release_packages("replace")
    state.target = target
    state.tier = tier
    state.handoff = false
    state.waiting_for_assignment = false
    increment("target_changes")

    if tier ~= "conservative" then
        install_manifest(MissionManifest.resolve(target, tier), false)
    end
end

local function set_target(mission_name, context)
    local target = build_target(mission_name, context)

    if not target then
        return false
    end

    if state.target and state.target.key == target.key then
        state.waiting_for_assignment = false

        return true
    end

    start_target(target)

    return true
end

local function category_done(category)
    local manifest = state.manifest

    if not manifest then
        return false
    end

    local category_entries = manifest[category]

    local cursor = state.category_cursors[category] or 1

    for i = cursor, #category_entries do
        local status = state.entries[category_entries[i].name].status

        if status == "queued" or status == "submitted" then
            state.category_cursors[category] = i

            return false
        end
    end

    state.category_cursors[category] = #category_entries + 1

    return true
end

local function expand_manifest()
    if state.expanded then
        return true
    end

    local manifest = MissionManifest.resolve(state.target, state.tier, state.loaded_levels)

    if not manifest then
        return false
    end

    state.expanded = true
    install_manifest(manifest, true)

    return true
end

local function advance_category()
    while state.category_index <= #MissionManifest.categories do
        local category = MissionManifest.categories[state.category_index]

        if not category_done(category) then
            return category
        end

        if category == "level" and not expand_manifest() then
            return nil
        end

        state.category_index = state.category_index + 1
    end

    return nil
end

local function submit_entry(entry, package_manager)
    if not package_available(package_manager, entry.name) then
        entry.status = "unavailable"
        increment("unavailable")

        return false
    end

    local generation = state.generation
    local function on_loaded(id)
        if generation ~= state.generation then
            return
        end

        local current = state.entries[entry.name]

        if not current or current.id ~= id or current.status ~= "submitted" then
            return
        end

        current.status = "loaded"
        state.in_flight = math.max(state.in_flight - 1, 0)
        increment("loaded")

        if current.category == "level" then
            state.loaded_levels[current.name] = true
        end
    end

    local id = package_manager:load(entry.name, REFERENCE, on_loaded, false, false)

    if id == nil then
        entry.status = "failed"
        increment("failed")

        return false
    end

    entry.id = id
    entry.status = "submitted"
    state.ids[id] = true
    state.package_manager = package_manager
    state.in_flight = state.in_flight + 1
    state.peak_in_flight = math.max(state.peak_in_flight, state.in_flight)
    increment("submitted")

    return true
end

local function schedule_manifest()
    if state.handoff or state.tier == "conservative" or not state.target or not state.manifest then
        return
    end

    local category = advance_category()

    if not category or state.in_flight >= MAX_IN_FLIGHT then
        return
    end

    local package_manager = Managers.package

    if not package_manager or package_manager:is_anything_loading_now() then
        state.deferred_busy_frames = state.deferred_busy_frames + 1

        return
    end

    local submissions = 0
    local attempts = 0
    local entries = state.manifest[category]

    local cursor = state.category_cursors[category] or 1

    for i = cursor, #entries do
        local entry = state.entries[entries[i].name]

        if entry.status == "queued" then
            attempts = attempts + 1

            if submit_entry(entry, package_manager) then
                submissions = submissions + 1
            end

            if attempts >= MAX_SUBMISSIONS_PER_FRAME or state.in_flight >= MAX_IN_FLIGHT then
                break
            end
        end
    end

    if submissions > 0 then
        state.submitted_frames = state.submitted_frames + 1
    end
end

local function flag_value(flags, prefix)
    for flag, _ in pairs(type(flags) == "table" and flags or {}) do
        if type(flag) == "string" and string.sub(flag, 1, #prefix) == prefix then
            return string.sub(flag, #prefix + 1)
        end
    end
end

local function flag_values(flags, prefix)
    local values = {}

    for flag, _ in pairs(type(flags) == "table" and flags or {}) do
        if type(flag) == "string" and string.sub(flag, 1, #prefix) == prefix then
            values[#values + 1] = string.sub(flag, #prefix + 1)
        end
    end

    table.sort(values)

    return values
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

local function handle_vote_assignment(params)
    state.backend_mission_id = params.backend_mission_id

    if params.qp == "true" then
        release_packages("replace")
        state.target = nil
        state.waiting_for_assignment = true

        return
    end

    local mission_data = decode_mission_data(params.mission_data)
    local havoc_theme = mission_data and flag_value(mission_data.flags, "havoc-theme-")
    local havoc_circumstances = mission_data and flag_values(mission_data.flags, "havoc-circ-")
    local context = {
        circumstance_name = mission_data and mission_data.circumstance,
        circumstances = havoc_circumstances,
        theme_override = havoc_theme,
        is_expedition = mission_data and mission_data.category == "expedition",
        backend_mission_id = params.backend_mission_id,
        side_mission = mission_data and mission_data.sideMission,
    }

    if mission_data and set_target(mission_data.map, context) then
        return
    end

    release_packages("replace")
    state.target = nil
    state.waiting_for_assignment = true
end

mod.mission_warmup_handle_vote_event = function(self, event)
    if state.handoff then
        return
    end

    local params = event and event.params
    local is_target_vote = params and (params.template_name == VOTE_TEMPLATE or state.backend_mission_id ~= nil and state.backend_mission_id == params.backend_mission_id)

    if not is_target_vote then
        return
    end

    if event.state == "ONGOING" then
        state.matchmaking_started = false
        state.vote_observed = true
        state.vote_committed = false
        handle_vote_assignment(params)
    elseif event.state == "COMPLETED_APPROVED" then
        if not state.target and not state.waiting_for_assignment then
            handle_vote_assignment(params)
        end

        state.matchmaking_started = true
        state.vote_observed = false
        state.vote_committed = true
    else
        clear_target("cancel")
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
        clear_target("cancel")
        state.backend_mission_id = nil
    end
end

mod.mission_warmup_handle_transition = function(self, context)
    if state.handoff or type(context) ~= "table" or type(context.mission_name) ~= "string" then
        return
    end

    if not state.waiting_for_assignment and not state.target and not context.backend_mission_id then
        return
    end

    local target_context = {
        circumstance_name = context.circumstance_name,
        havoc_data = context.havoc_data,
        backend_mission_id = context.backend_mission_id or state.backend_mission_id,
        side_mission = context.side_mission,
    }

    if set_target(context.mission_name, target_context) then
        state.backend_mission_id = context.backend_mission_id or state.backend_mission_id
    end
end

mod.mission_warmup_handle_update = function(self)
    if state.vote_observed and not state.vote_committed then
        local party_manager = Managers.party_immaterium
        local vote_state = party_manager and party_manager:party_vote_state()

        if not vote_state or vote_state.state ~= "ONGOING" then
            clear_target("cancel")
            state.backend_mission_id = nil

            return
        end
    end

    local target = state.target
    local expedition_identity = target and target.expedition_identity

    local now = os.clock()

    if target and target.is_expedition and not state.handoff and now >= state.next_expedition_snapshot_time and (not expedition_identity or expedition_identity.package_signature == "") then
        state.next_expedition_snapshot_time = now + EXPEDITION_SNAPSHOT_INTERVAL

        set_target(target.mission_name, {
            circumstance_name = target.circumstance_name,
            circumstances = target.circumstances,
            havoc_data = target.havoc_data,
            theme_override = target.theme_tag,
            is_expedition = true,
            backend_mission_id = target.backend_mission_id,
            side_mission = target.side_mission,
        })
    end

    schedule_manifest()
end

mod.mission_warmup_handle_enabled = function(self)
    local party_manager = Managers.party_immaterium
    local game_state = party_manager and party_manager:party_game_state()

    if party_manager and game_state and game_state.status ~= "GAME_SESSION_IN_PROGRESS" then
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

mod.mission_warmup_handle_loading_started = function(self)
    if state.target and not state.handoff then
        state.handoff = true
        increment("handoffs")
    end
end

mod.mission_warmup_handle_loading_finished = function(self)
    clear_target()
    state.backend_mission_id = nil
end

mod.mission_warmup_handle_setting_changed = function(self)
    local tier = mod:get_preload_tier()

    if not state.target or tier == state.tier then
        return
    end

    release_packages("tier")
    state.tier = tier

    if state.handoff or tier == "conservative" then
        return
    end

    install_manifest(MissionManifest.resolve(state.target, tier), false)
end

mod.mission_warmup_clear = function(self)
    clear_target()
    state.backend_mission_id = nil
end

mod.mission_warmup_info = function()
    local totals = {}
    local counts = {
        queued = 0,
        submitted = 0,
        loaded = 0,
        unavailable = 0,
        failed = 0,
    }

    for i = 1, #MissionManifest.categories do
        local category = MissionManifest.categories[i]

        totals[category] = state.manifest and #state.manifest[category] or 0
    end

    for _, entry in pairs(state.entries or {}) do
        counts[entry.status] = (counts[entry.status] or 0) + 1
    end

    return {
        target = state.target and state.target.mission_name,
        key = state.target and state.target.key,
        generation = state.generation,
        tier = state.tier or mod:get_preload_tier(),
        handoff = state.handoff == true,
        manifest = totals,
        queued = counts.queued,
        submitted = counts.submitted,
        in_flight = state.in_flight or 0,
        loaded = counts.loaded,
        unavailable = counts.unavailable,
        failed = counts.failed,
        peak_in_flight = state.peak_in_flight or 0,
        submitted_frames = state.submitted_frames or 0,
        deferred_busy_frames = state.deferred_busy_frames or 0,
        dynamic_additions = state.dynamic_additions or 0,
        releases = state.stats.releases or 0,
        cancellations = state.stats.cancellations or 0,
        target_changes = state.stats.target_changes or 0,
        handoffs = state.stats.handoffs or 0,
    }
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
