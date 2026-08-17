local BreedResourceDependencies = require("scripts/utilities/breed_resource_dependencies")
local Breeds = require("scripts/settings/breed/breeds")
local CircumstanceTemplates = require("scripts/settings/circumstance/circumstance_templates")
local GameModeSettings = require("scripts/settings/game_mode/game_mode_settings")
local ItemPackage = require("scripts/foundation/managers/package/utilities/item_package")
local MasterItems = require("scripts/backend/master_items")
local Missions = require("scripts/settings/mission/mission_templates")
local MissionIntroViewSettings = require("scripts/ui/views/mission_intro_view/mission_intro_view_settings")
local MutatorMinionVisualOverrideSettings = require("scripts/settings/mutator/mutator_mininion_visual_overrides_settings")
local MutatorTemplates = require("scripts/settings/mutator/mutator_templates")
local ThemePackage = require("scripts/foundation/managers/package/utilities/theme_package")
local Views = require("scripts/ui/views/views")

local MissionManifest = {}
local CATEGORIES = {
    "level",
    "level_dependencies",
    "mission_support",
    "mutators",
    "breeds",
}

local breed_cache_version = nil
local breed_cache_packages = nil

local function sorted_keys(values)
    local keys = {}

    for key, _ in pairs(values or {}) do
        if type(key) == "string" then
            keys[#keys + 1] = key
        end
    end

    table.sort(keys)

    return keys
end

local function add_entry(manifest, seen, category, name, reason)
    if type(name) ~= "string" or name == "" or seen[name] then
        return
    end

    seen[name] = true
    manifest[category][#manifest[category] + 1] = {
        category = category,
        name = name,
        reason = reason,
    }
end

local function add_map(manifest, seen, category, packages, reason)
    local names = sorted_keys(packages)

    for i = 1, #names do
        add_entry(manifest, seen, category, names[i], reason)
    end
end

local function add_array(manifest, seen, category, packages, reason)
    local names = {}

    for _, name in pairs(packages or {}) do
        if type(name) == "string" then
            names[#names + 1] = name
        end
    end

    table.sort(names)

    for i = 1, #names do
        add_entry(manifest, seen, category, names[i], reason)
    end
end

local function view_preload_policies()
    local game_parameters = rawget(_G, "GameParameters")
    local disable_preload = game_parameters and game_parameters.disable_view_preload
    local is_playstation = rawget(_G, "IS_PLAYSTATION") == true
    local xbox = rawget(_G, "Xbox")
    local sub_platform = ""

    if rawget(_G, "IS_XBS") == true and xbox and xbox.console_type then
        local console_type = xbox.console_type()

        if console_type == xbox.CONSOLE_TYPE_XBOX_SCARLETT_ANACONDA then
            sub_platform = "anaconda"
        elseif console_type == xbox.CONSOLE_TYPE_XBOX_SCARLETT_LOCKHEART then
            sub_platform = "lockhart"
        end
    end

    return {
        always_even_with_debug = true,
        always = not disable_preload,
        not_ps5 = not disable_preload and not is_playstation,
        not_ps5_nor_lockhart = not disable_preload and not is_playstation and sub_platform ~= "lockhart",
    }
end

local function intro_level_name(mission)
    local intro_level = MissionIntroViewSettings.intro_levels_by_zone_id[mission.zone_id]
        or MissionIntroViewSettings.intro_levels_by_zone_id.default

    return intro_level and intro_level.level_name
end

local function collect_level_names(manifest, seen, target, mission)
    add_entry(manifest, seen, "level", target.level_name, "selected mission level")

    local policies = view_preload_policies()
    local view_names = sorted_keys(Views)

    for i = 1, #view_names do
        local view_name = view_names[i]
        local view = Views[view_name]
        local policy = view.preload_in_mission

        if policy and policies[policy] then
            add_array(manifest, seen, "level", view.levels, "mission view associated level: " .. view_name)

            if view_name == "mission_intro_view" then
                add_entry(manifest, seen, "level", intro_level_name(mission), "mission intro level")
            end
        end
    end

    local expedition_levels = target.expedition_levels or {}

    for i = 1, #expedition_levels do
        local entry = expedition_levels[i]
        local reason = entry.delayed_despawn and "generated Expedition prior delayed-despawn level" or "generated Expedition current-section level"

        add_entry(manifest, seen, "level", entry.level_name, reason)
    end
end

local function add_level_dependencies(manifest, seen, target, loaded_levels, item_definitions)
    local levels = manifest.level

    for i = 1, #levels do
        local level_name = levels[i].name

        if loaded_levels[level_name] then
            local item_packages = ItemPackage.level_resource_dependency_packages(item_definitions, level_name)

            add_map(manifest, seen, "level_dependencies", item_packages, "level item dependency: " .. level_name)
        end
    end

    if target.theme_tag and not target.is_expedition and loaded_levels[target.level_name] then
        local theme_packages = ThemePackage.level_resource_dependency_packages(target.level_name, target.theme_tag)

        add_array(manifest, seen, "level_dependencies", theme_packages, "selected mission theme")
    end

    local expedition_levels = target.expedition_levels or {}

    for i = 1, #expedition_levels do
        local entry = expedition_levels[i]

        if entry.load_theme and entry.theme_tag and loaded_levels[entry.level_name] then
            local theme_packages = ThemePackage.level_resource_dependency_packages(entry.level_name, entry.theme_tag)

            add_array(manifest, seen, "level_dependencies", theme_packages, "generated Expedition level theme")
        end
    end
end

local function add_hud_packages(manifest, seen, mission)
    local definitions = mission.hud_elements and require(mission.hud_elements)

    if definitions then
        for i = 1, #definitions do
            add_entry(manifest, seen, "mission_support", definitions[i].package, "mission HUD: " .. tostring(definitions[i].class_name))
        end

        return
    end

    local class_names = {}
    local player = require("scripts/ui/hud/hud_elements_player")
    local spectator = require("scripts/ui/hud/hud_elements_spectator")

    for i = 1, #player do
        local definition = player[i]

        class_names[definition.class_name] = true
        add_entry(manifest, seen, "mission_support", definition.package, "default player HUD: " .. tostring(definition.class_name))
    end

    for i = 1, #(spectator or {}) do
        local definition = spectator[i]

        if not class_names[definition.class_name] then
            class_names[definition.class_name] = true
            add_entry(manifest, seen, "mission_support", definition.package, "default spectator HUD: " .. tostring(definition.class_name))
        end
    end
end

local function add_view_packages(manifest, seen)
    local policies = view_preload_policies()
    local view_names = sorted_keys(Views)

    for i = 1, #view_names do
        local view_name = view_names[i]
        local view = Views[view_name]
        local policy = view.preload_in_mission

        if policy and policies[policy] then
            if type(view.package) == "table" then
                add_array(manifest, seen, "mission_support", view.package, "mission view: " .. view_name)
            else
                add_entry(manifest, seen, "mission_support", view.package, "mission view: " .. view_name)
            end

            if view_name == "loading_view" then
                local background = view.backgrounds and view.backgrounds[1]

                add_entry(manifest, seen, "mission_support", background and view.dynamic_package_folder .. background, "loading view dynamic background")
            end
        end
    end
end

local function add_mutator_node_packages(manifest, seen, nodes, mutator_name)
    for i = 1, #(nodes or {}) do
        local template = nodes[i].template

        if template then
            add_entry(manifest, seen, "mutators", template.asset_package, "mutator spawner asset: " .. mutator_name)
            add_mutator_node_packages(manifest, seen, template.spawners, mutator_name)
        end
    end
end

local function mutator_names(target)
    local names = {}
    local seen = {}

    for i = 1, #(target.circumstances or {}) do
        local circumstance = CircumstanceTemplates[target.circumstances[i]]

        for j = 1, #(circumstance and circumstance.mutators or {}) do
            local name = circumstance.mutators[j]

            if not seen[name] then
                seen[name] = true
                names[#names + 1] = name
            end
        end
    end

    table.sort(names)

    return names
end

local function add_visual_override_packages(manifest, seen, mutator_name, mutator, item_definitions)
    if mutator.class ~= "scripts/managers/mutator/mutators/mutator_minion_visual_override" then
        return
    end

    local override = MutatorMinionVisualOverrideSettings[mutator.template_name]
    local items = {}
    local seen_items = {}

    for _, override_entry in pairs(override or {}) do
        for _, slot in pairs(override_entry.item_slot_data or {}) do
            for i = 1, #(slot.items or {}) do
                local item_name = slot.items[i]

                if not seen_items[item_name] then
                    seen_items[item_name] = true
                    items[#items + 1] = item_name
                end
            end
        end

        for _, gib_data in pairs(override_entry.has_gib_override or {}) do
            items[#items + 1] = gib_data
        end
    end

    local asset_package = {
        items = items,
    }
    local packages = BreedResourceDependencies.generate(asset_package, item_definitions)

    add_map(manifest, seen, "mutators", packages, "mutator visual override items: " .. mutator_name)
end

local function add_mutator_packages(manifest, seen, target, item_definitions)
    local names = mutator_names(target)

    for i = 1, #names do
        local name = names[i]
        local mutator = MutatorTemplates[name]

        if mutator then
            add_entry(manifest, seen, "mutators", mutator.asset_package, "mutator root asset: " .. name)
            add_mutator_node_packages(manifest, seen, mutator.spawners, name)
            add_visual_override_packages(manifest, seen, name, mutator, item_definitions)
        end
    end
end

local function add_breed_packages(manifest, seen, item_definitions)
    local version = MasterItems.get_cached_version()

    if breed_cache_version ~= version then
        breed_cache_packages = BreedResourceDependencies.generate(Breeds, item_definitions)
        breed_cache_version = version
    end

    add_map(manifest, seen, "breeds", breed_cache_packages, "global non-hub BreedLoader dependency")
end

MissionManifest.resolve = function(target, tier, loaded_levels)
    local mission = target and Missions[target.mission_name]

    if not mission then
        return nil
    end

    local manifest = {}
    local seen = {}

    for i = 1, #CATEGORIES do
        manifest[CATEGORIES[i]] = {}
    end

    collect_level_names(manifest, seen, target, mission)

    if not loaded_levels then
        return manifest
    end

    local item_definitions = MasterItems.get_cached()

    if not item_definitions then
        return nil
    end

    add_level_dependencies(manifest, seen, target, loaded_levels, item_definitions)

    local game_mode = GameModeSettings[mission.game_mode_name]

    add_array(manifest, seen, "mission_support", game_mode and game_mode.packages, "mission game mode")
    add_hud_packages(manifest, seen, mission)
    add_view_packages(manifest, seen)
    add_mutator_packages(manifest, seen, target, item_definitions)

    if tier == "aggressive" then
        add_breed_packages(manifest, seen, item_definitions)
    end

    return manifest
end

MissionManifest.categories = CATEGORIES

return MissionManifest
