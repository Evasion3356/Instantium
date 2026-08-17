local mod = get_mod("Instantium")

local Breed = require("scripts/utilities/breed")
local game_parameters = rawget(_G, "GameParameters")
local dedicated_server = rawget(_G, "DEDICATED_SERVER") == true

local MAX_QUEUE = 32
local MAX_IN_FLIGHT = 2
local MIN_DISTANCE_SQUARED = 15 * 15
local MAX_DISTANCE_SQUARED = 40 * 40
local FORCE_STREAM_TIMEOUT = game_parameters and game_parameters.force_stream_mesh_timeout or 2
local REQUEST_WATCHDOG = FORCE_STREAM_TIMEOUT + 1
local VRAM_PRESSURE_RATIO = 0.9

local PRIORITY = {
    squad = 1,
    monster = 2,
    captain = 2,
    special = 3,
    elite = 4,
}

local state = mod:persistent_table("unit_stream_warmup_state")
state.generation = state.generation or 0
state.stats = state.stats or {}
state.clock = state.clock or 0
state.faulted = false
state.last_error = nil

local function increment(name, amount)
    state.stats[name] = (state.stats[name] or 0) + (amount or 1)
end

local function reset_work()
    state.queue = {}
    state.queued_units = setmetatable({}, { __mode = "k" })
    state.seen_units = setmetatable({}, { __mode = "k" })
    state.requests = {}
    state.in_flight = 0
    state.peak_in_flight = 0
    state.next_request_id = 0
    state.last_vram_usage_mb = nil
    state.last_vram_budget_mb = nil
    state.last_vram_ratio = nil
    state.vram_pressure = true
    state.vram_probe_status = "unprobed"
    state.next_vram_check = 0
    state.blocked_until = state.clock
end

local function clear_work()
    state.generation = state.generation + 1
    reset_work()
    state.blocked_until = state.clock + REQUEST_WATCHDOG
end

-- Module-only reloads cannot cancel native requests, so invalidate callbacks
-- and drop every retained Lua unit reference immediately.
clear_work()

local function setting_enabled()
    return mod:get("runtime_stream_warmup") ~= false
end

local function gameplay_active()
    if dedicated_server or not setting_enabled() or not Managers.presence or Managers.presence._current_game_state_name ~= "StateGameplay" then
        return false
    end

    local mechanism_manager = Managers.mechanism

    return not mechanism_manager or mechanism_manager:mechanism_name() ~= "hub"
end

local function classify_unit(unit)
    local player_manager = Managers.player
    local player = player_manager and player_manager:player_by_unit(unit)

    if player then
        local local_player = player_manager:local_player(1)

        if player ~= local_player then
            return "squad", PRIORITY.squad
        end

        return nil
    end

    local breed = Breed.unit_breed_or_nil(unit)
    local enemy_type = breed and breed.tags and breed.tags.cultist_captain and "captain" or Breed.enemy_type(breed)

    return enemy_type, PRIORITY[enemy_type]
end

local function remove_queue_entry(index, mark_seen)
    local entry = state.queue[index]

    if entry then
        state.queued_units[entry.unit] = nil

        if mark_seen then
            state.seen_units[entry.unit] = true
        end

        local last_index = #state.queue

        state.queue[index] = state.queue[last_index]
        state.queue[last_index] = nil
    end

    return entry
end

local function enqueue_unit(unit)
    local mechanism_manager = Managers.mechanism

    if not setting_enabled()
        or state.faulted
        or dedicated_server
        or mechanism_manager and mechanism_manager:mechanism_name() == "hub"
        or not Unit.alive(unit)
        or state.seen_units[unit]
        or state.queued_units[unit]
    then
        return
    end

    local kind, priority = classify_unit(unit)

    if not priority then
        return
    end

    local queue = state.queue

    if #queue >= MAX_QUEUE then
        local worst_index = nil
        local worst_priority = -math.huge

        for i = 1, #queue do
            if queue[i].priority > worst_priority then
                worst_priority = queue[i].priority
                worst_index = i
            end
        end

        if priority >= worst_priority then
            increment("dropped_queue_full")

            return
        end

        remove_queue_entry(worst_index, true)
        increment("dropped_queue_full")
    end

    local entry = {
        unit = unit,
        kind = kind,
        priority = priority,
        queued_at = state.clock,
    }

    queue[#queue + 1] = entry
    state.queued_units[unit] = true
    increment("queued")
end

local function enqueue_squad_units()
    local player_manager = Managers.player
    local players = player_manager and player_manager:players()

    for _, player in pairs(players or {}) do
        if player.player_unit then
            enqueue_unit(player.player_unit)
        end
    end
end

local function memory_pressure(now)
    if now < state.next_vram_check then
        return state.vram_pressure
    end

    local memory = rawget(_G, "Memory")
    local usage_function = memory and memory.vram_usage
    local budget_function = memory and memory.vram_budget

    if type(usage_function) ~= "function" or type(budget_function) ~= "function" then
        state.last_vram_usage_mb = nil
        state.last_vram_budget_mb = nil
        state.last_vram_ratio = nil
        state.vram_pressure = true
        state.vram_probe_status = "unavailable"
        state.next_vram_check = now + 5
        increment("vram_probe_failures")

        return true
    end

    local usage_ok, usage = pcall(usage_function)
    local budget_ok, budget = pcall(budget_function)

    local valid_usage = type(usage) == "number" and usage == usage and usage >= 0 and usage < math.huge
    local valid_budget = type(budget) == "number" and budget == budget and budget > 0 and budget < math.huge

    if not usage_ok or not budget_ok or not valid_usage or not valid_budget then
        state.last_vram_usage_mb = nil
        state.last_vram_budget_mb = nil
        state.last_vram_ratio = nil
        state.vram_pressure = true
        state.vram_probe_status = "invalid"
        state.next_vram_check = now + 5
        increment("vram_probe_failures")

        return true
    end

    local ratio = usage / budget

    state.last_vram_usage_mb = usage
    state.last_vram_budget_mb = budget
    state.last_vram_ratio = ratio
    state.vram_pressure = ratio >= VRAM_PRESSURE_RATIO
    state.vram_probe_status = "valid"
    state.next_vram_check = now + 0.25

    return state.vram_pressure
end

local function finish_request_part(request_id, part, timed_out, failed)
    local request = state.requests[request_id]

    if not request or request.generation ~= state.generation or request[part .. "_done"] then
        return
    end

    request[part .. "_done"] = true

    if timed_out then
        increment(part .. "_timeouts")
    elseif failed then
        increment(part .. "_failures")
    end

    if not request.mesh_done or not request.texture_done then
        return
    end

    local elapsed = state.clock - request.started_at

    state.requests[request_id] = nil
    state.in_flight = math.max(state.in_flight - 1, 0)
    state.stats.total_callback_seconds = (state.stats.total_callback_seconds or 0) + elapsed
    state.stats.max_callback_seconds = math.max(state.stats.max_callback_seconds or 0, elapsed)
    increment("completed")
end

local function submit_unit(unit, kind)
    state.next_request_id = state.next_request_id + 1

    local request_id = state.next_request_id
    local generation = state.generation

    state.requests[request_id] = {
        generation = generation,
        kind = kind,
        started_at = state.clock,
        mesh_done = false,
        texture_done = false,
    }
    state.in_flight = state.in_flight + 1
    state.peak_in_flight = math.max(state.peak_in_flight, state.in_flight)
    increment("submitted")
    increment("submitted_" .. kind)

    local mesh_ok = pcall(Unit.force_stream_meshes, unit, function(timed_out)
        if generation == state.generation then
            finish_request_part(request_id, "mesh", not not timed_out, false)
        end
    end, true, FORCE_STREAM_TIMEOUT)

    if not mesh_ok then
        finish_request_part(request_id, "mesh", false, true)
    end

    local texture_ok = pcall(Unit.force_stream_textures, unit, function(timed_out)
        if generation == state.generation then
            finish_request_part(request_id, "texture", not not timed_out, false)
        end
    end, true, FORCE_STREAM_TIMEOUT)

    if not texture_ok then
        finish_request_part(request_id, "texture", false, true)
    end
end

local function expire_requests(now)
    local expired_ids = {}

    for request_id, request in pairs(state.requests) do
        if now - request.started_at >= REQUEST_WATCHDOG then
            expired_ids[#expired_ids + 1] = request_id
        end
    end

    for i = 1, #expired_ids do
        local request_id = expired_ids[i]
        local request = state.requests[request_id]

        if request and not request.mesh_done then
            finish_request_part(request_id, "mesh", true, false)
        end

        request = state.requests[request_id]

        if request and not request.texture_done then
            finish_request_part(request_id, "texture", true, false)
        end
    end
end

local function next_candidate(now)
    local player_manager = Managers.player
    local local_player = player_manager and player_manager:local_player(1)
    local player_unit = local_player and local_player.player_unit
    local player_position = player_unit and Unit.alive(player_unit) and Unit.world_position(player_unit, 1)

    if not player_position then
        return nil
    end

    local best_entry = nil
    local best_priority = math.huge
    local best_distance = math.huge

    for i = #state.queue, 1, -1 do
        local entry = state.queue[i]
        local unit = entry.unit
        local unit_alive = Unit.alive(unit)
        local unit_position = unit_alive and Unit.world_position(unit, 1)

        if not unit_position then
            remove_queue_entry(i, true)
            increment("dropped_stale")
        else
            local distance_squared = Vector3.distance_squared(player_position, unit_position)

            if distance_squared < MIN_DISTANCE_SQUARED then
                remove_queue_entry(i, true)
                increment("dropped_too_close")
            elseif distance_squared <= MAX_DISTANCE_SQUARED and (entry.priority < best_priority or entry.priority == best_priority and distance_squared < best_distance) then
                best_entry = entry
                best_priority = entry.priority
                best_distance = distance_squared
            end
        end
    end

    if best_entry then
        for i = 1, #state.queue do
            if state.queue[i] == best_entry then
                return i
            end
        end
    end
end

mod.unit_stream_handle_registered = function(self, unit)
    enqueue_unit(unit)
end

local function update_streaming(dt)
    if not gameplay_active() then
        return
    end

    if type(dt) == "number" and dt > 0 then
        state.clock = state.clock + dt
    end

    local now = state.clock

    if state.in_flight > 0 then
        expire_requests(now)
    end

    if state.in_flight >= MAX_IN_FLIGHT then
        return
    elseif now < state.blocked_until then
        increment("deferred_cleanup_cooldown")

        return
    end

    if #state.queue == 0 then
        return
    end

    local package_manager = Managers.package

    if package_manager and package_manager:is_anything_loading_now() then
        increment("deferred_package_loading")

        return
    elseif memory_pressure(now) then
        increment("deferred_vram_pressure")

        return
    end

    local candidate_index = next_candidate(now)

    if candidate_index then
        local entry = remove_queue_entry(candidate_index, true)

        if entry then
            submit_unit(entry.unit, entry.kind)
        end
    end
end

mod.unit_stream_handle_update = function(self, dt)
    if state.faulted then
        return
    end

    local ok, err = pcall(update_streaming, dt)

    if not ok then
        state.faulted = true
        state.last_error = tostring(err)
        clear_work()
        mod:warning("Runtime texture/mesh warmup stopped for this session: %s", state.last_error)
    end
end

mod.unit_stream_handle_loading_started = function(self)
    clear_work()
end

mod.unit_stream_handle_loading_finished = function(self)
    if setting_enabled() and not dedicated_server then
        enqueue_squad_units()
    end
end

mod.unit_stream_handle_enabled = function(self)
    if gameplay_active() then
        enqueue_squad_units()
    end
end

mod.unit_stream_handle_setting_changed = function(self, setting_id)
    if setting_id ~= "runtime_stream_warmup" then
        return
    end

    clear_work()

    if gameplay_active() then
        enqueue_squad_units()
    end
end

mod.unit_stream_clear = function(self)
    clear_work()
end

mod.streaming_warmup_info = function()
    local completed = state.stats.completed or 0

    return {
        enabled = setting_enabled(),
        active = mod:is_enabled() and gameplay_active() and not state.faulted and state.clock >= state.blocked_until,
        faulted = state.faulted == true,
        last_error = state.last_error,
        generation = state.generation,
        queued = #state.queue,
        in_flight = state.in_flight,
        peak_in_flight = state.peak_in_flight,
        submitted = state.stats.submitted or 0,
        submitted_by_kind = {
            squad = state.stats.submitted_squad or 0,
            monster = state.stats.submitted_monster or 0,
            captain = state.stats.submitted_captain or 0,
            special = state.stats.submitted_special or 0,
            elite = state.stats.submitted_elite or 0,
        },
        completed = completed,
        mesh_timeouts = state.stats.mesh_timeouts or 0,
        texture_timeouts = state.stats.texture_timeouts or 0,
        mesh_failures = state.stats.mesh_failures or 0,
        texture_failures = state.stats.texture_failures or 0,
        dropped_queue_full = state.stats.dropped_queue_full or 0,
        dropped_stale = state.stats.dropped_stale or 0,
        dropped_too_close = state.stats.dropped_too_close or 0,
        deferred_cleanup_cooldown = state.stats.deferred_cleanup_cooldown or 0,
        deferred_package_loading = state.stats.deferred_package_loading or 0,
        deferred_vram_pressure = state.stats.deferred_vram_pressure or 0,
        vram_probe_failures = state.stats.vram_probe_failures or 0,
        average_callback_seconds = completed > 0 and (state.stats.total_callback_seconds or 0) / completed or 0,
        max_callback_seconds = state.stats.max_callback_seconds or 0,
        vram_usage_mb = state.last_vram_usage_mb,
        vram_budget_mb = state.last_vram_budget_mb,
        vram_ratio = state.last_vram_ratio,
        vram_probe_status = state.vram_probe_status,
    }
end

return mod
