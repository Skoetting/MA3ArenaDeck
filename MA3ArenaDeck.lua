-- Plugin: MA3ArenaDeck (Resolume composition grid for grandMA3)
-- Copyright (c) 2026 Simon Kotting — MIT License (see LICENSE)
-- Fetches the current Resolume composition, builds a layout grid, imports
-- clip thumbnails as Images/Appearances, and can poll connected state to
-- highlight currently running clips.
--
-- Arguments:
--   (none)/setup - setup dialog, then sync
--   sync         - full sync (no dialog; used by SYNC button)
--   monitor      - start status polling / highlight loop
--   stop         - stop status polling
--   interval     - cycle poll interval
--   trigtoggle   - enable/disable tap-to-trigger clips
--   trigger L C  - fire Resolume clip at layer/column (from clip macros)
--
-- Layout buttons (macros) under the clip grid:
--   SYNC | POLL ON | POLL OFF | POLL xs | TRIG ON/OFF
--
-- API: GET http://<host>:<port>/api/v1/composition
--      POST .../layers/{L}/clips/{C}/connect  (when trigger mode is on)

local pluginName = select(1, ...)
local componentName = select(2, ...)
local signalTable = select(3, ...)
local myHandle = select(4, ...)

-- Bump when changing runtime behavior so System Monitor proves the reload.
local PLUGIN_VERSION = "2026-08-09l"

------------------------------------------------------------------------
-- Configuration (defaults; overridden by GlobalVars / setup dialog)
------------------------------------------------------------------------
local CFG_PREFIX = "MA3ArenaDeck_"
local MONITOR_VAR = CFG_PREFIX .. "Monitor"
local MONITOR_OWNER_VAR = CFG_PREFIX .. "MonitorOwner"
local INTERVAL_VAR = CFG_PREFIX .. "PollInterval"
local TRIGGER_VAR = CFG_PREFIX .. "Trigger"
-- Clip taps queue "L,C" here; the poll loop fires Resolume (no Plugin call).
local FIRE_VAR = CFG_PREFIX .. "Fire"

local RESOLUME_HOST = "127.0.0.1"
local RESOLUME_PORT = 8080

local ONLY_WITH_THUMBNAIL = false

local LAYOUT_INDEX = 1
local LAYOUT_NAME = "MA3ArenaDeck"

local CELL_WIDTH = 160
local CELL_HEIGHT = 90
local CELL_GAP_X = 10
local CELL_GAP_Y = 10
local LABEL_WIDTH = 140
local ORIGIN_X = 0
local ORIGIN_Y = 0

local SHOW_LAYER_LABELS = true

local FETCH_THUMBNAILS = true
local IMAGE_POOL = 3
local IMAGE_START_INDEX = 200
local APPEARANCE_START_INDEX = 200
local MAX_MEDIA_SLOTS = 300
local IMAGE_NAME_PREFIX = "MAD_"
local APPEARANCE_IDLE_PREFIX = "MAD_"
local APPEARANCE_PLAY_PREFIX = "MADP_"

-- Status polling
local POLL_INTERVAL_SEC = 0.25
local POLL_INTERVAL_OPTIONS = { 0.10, 0.25, 0.50, 1.00, 2.00 }
local HIGHLIGHT_PREVIEWING = false -- also highlight "Previewing" clips
local PLAYING_BORDER_SIZE = 14
local IDLE_BORDER_SIZE = 7
local LAYER_BORDER_SIZE = 6
-- Clip frame colors (0-255): idle white, active/playing cyan
local PLAYING_BORDER_R = 0
local PLAYING_BORDER_G = 220
local PLAYING_BORDER_B = 255
local IDLE_BORDER_R = 255
local IDLE_BORDER_G = 255
local IDLE_BORDER_B = 255
local LAYER_BORDER_R = 220
local LAYER_BORDER_G = 220
local LAYER_BORDER_B = 220

-- Control macros + buttons under the grid
local MACRO_START_INDEX = 200
-- Per-clip fire macros start after the 5 control macros (200-204)
local TRIGGER_MACRO_START = MACRO_START_INDEX + 10
local BUTTON_WIDTH = 128
local BUTTON_HEIGHT = 60
local BUTTON_GAP = 12
-- Extra offset below layer-1 row so controls never sit on the clip grid
local BUTTON_ROW_OFFSET = 40

-- Control button colors (active = currently selected mode)
local CTRL_COLOR = {
    sync = { r = 70, g = 90, b = 140 },
    -- Poll enabled: POLL ON = cyan, POLL OFF = dim
    poll_on_active = { r = 0, g = 220, b = 255 },
    poll_on_idle = { r = 55, g = 55, b = 60 },
    -- Poll disabled: POLL OFF = white, POLL ON = dim
    poll_off_active = { r = 255, g = 255, b = 255 },
    poll_off_idle = { r = 55, g = 55, b = 60 },
    interval = { r = 40, g = 130, b = 200 },
    -- Trigger mode: amber when taps fire clips
    trigger_active = { r = 255, g = 170, b = 0 },
    trigger_idle = { r = 55, g = 55, b = 60 },
}

------------------------------------------------------------------------
-- Lazy module load
------------------------------------------------------------------------
local http, ltn12, json

local function ensure_deps()
    if http and ltn12 and json then
        return true
    end

    local ok_http, mod_http = pcall(require, "http")
    local ok_ltn12, mod_ltn12 = pcall(require, "ltn12")
    local ok_json, mod_json = pcall(require, "json")

    if not (ok_http and ok_ltn12 and ok_json) then
        Printf(
            "MA3ArenaDeck ERROR: missing Lua modules (http=%s, ltn12=%s, json=%s)",
            tostring(ok_http),
            tostring(ok_ltn12),
            tostring(ok_json)
        )
        return false
    end

    http = mod_http
    ltn12 = mod_ltn12
    json = mod_json
    return true
end

------------------------------------------------------------------------
-- Persisted config (GlobalVars) + setup dialog
------------------------------------------------------------------------

local function cfg_get(key, default)
    local ok, v = pcall(function()
        return GetVar(GlobalVars(), CFG_PREFIX .. key)
    end)
    if not ok or v == nil or v == "" then
        return default
    end
    return v
end

local function cfg_set(key, value)
    pcall(function()
        SetVar(GlobalVars(), CFG_PREFIX .. key, value)
    end)
end

local function cfg_get_bool(key, default)
    local v = cfg_get(key, default and "1" or "0")
    if v == true or v == 1 or v == "1" or v == "true" or v == "True" then
        return true
    end
    if v == false or v == 0 or v == "0" or v == "false" or v == "False" then
        return false
    end
    return default and true or false
end

local function nearest_poll_interval(value)
    local n = tonumber(value) or POLL_INTERVAL_SEC
    local best = POLL_INTERVAL_OPTIONS[1]
    local best_d = math.abs(best - n)
    for _, opt in ipairs(POLL_INTERVAL_OPTIONS) do
        local d = math.abs(opt - n)
        if d < best_d then
            best = opt
            best_d = d
        end
    end
    return best
end

local function get_poll_interval()
    return nearest_poll_interval(cfg_get("PollInterval", POLL_INTERVAL_SEC))
end

local function set_poll_interval(sec)
    local value = nearest_poll_interval(sec)
    POLL_INTERVAL_SEC = value
    cfg_set("PollInterval", string.format("%.2f", value))
    return value
end

local function refresh_derived_indexes()
    -- Per-clip fire macros sit after the 5 control macros, with headroom.
    TRIGGER_MACRO_START = MACRO_START_INDEX + 10
end

local function load_config()
    RESOLUME_HOST = tostring(cfg_get("Host", RESOLUME_HOST))
    RESOLUME_PORT = tonumber(cfg_get("Port", RESOLUME_PORT)) or RESOLUME_PORT
    LAYOUT_INDEX = tonumber(cfg_get("LayoutIndex", LAYOUT_INDEX)) or LAYOUT_INDEX
    LAYOUT_NAME = tostring(cfg_get("LayoutName", LAYOUT_NAME))
    IMAGE_START_INDEX = tonumber(cfg_get("ImageStart", IMAGE_START_INDEX)) or IMAGE_START_INDEX
    APPEARANCE_START_INDEX = tonumber(cfg_get("AppearanceStart", APPEARANCE_START_INDEX))
        or APPEARANCE_START_INDEX
    MACRO_START_INDEX = tonumber(cfg_get("MacroStart", MACRO_START_INDEX)) or MACRO_START_INDEX
    refresh_derived_indexes()
    ONLY_WITH_THUMBNAIL = cfg_get_bool("OnlyWithThumbnail", ONLY_WITH_THUMBNAIL)
    FETCH_THUMBNAILS = cfg_get_bool("FetchThumbnails", FETCH_THUMBNAILS)
    HIGHLIGHT_PREVIEWING = cfg_get_bool("HighlightPreviewing", HIGHLIGHT_PREVIEWING)
    POLL_INTERVAL_SEC = get_poll_interval()
end

local function save_config()
    cfg_set("Host", RESOLUME_HOST)
    cfg_set("Port", tostring(RESOLUME_PORT))
    cfg_set("LayoutIndex", tostring(LAYOUT_INDEX))
    cfg_set("LayoutName", LAYOUT_NAME)
    cfg_set("ImageStart", tostring(IMAGE_START_INDEX))
    cfg_set("AppearanceStart", tostring(APPEARANCE_START_INDEX))
    cfg_set("MacroStart", tostring(MACRO_START_INDEX))
    cfg_set("OnlyWithThumbnail", ONLY_WITH_THUMBNAIL and "1" or "0")
    cfg_set("FetchThumbnails", FETCH_THUMBNAILS and "1" or "0")
    cfg_set("HighlightPreviewing", HIGHLIGHT_PREVIEWING and "1" or "0")
    set_poll_interval(POLL_INTERVAL_SEC)
end

local function mb_input(result, name, default)
    if type(result) ~= "table" then
        return default
    end
    local inputs = result.inputs or result
    local v = inputs[name]
    if v == nil or v == "" then
        return default
    end
    return v
end

local function mb_state(result, name, default)
    if type(result) ~= "table" then
        return default
    end
    local states = result.states or result
    local v = states[name]
    if v == nil then
        return default
    end
    return v and true or false
end

--- Setup UI when launched from the plugin pool (no argument).
--- Returns: "sync" | "save" | "cancel"
local function show_setup_dialog(display_handle)
    load_config()
    Printf("MA3ArenaDeck: opening setup dialog...")

    local options = {
        title = "MA3ArenaDeck Setup",
        message = "Set Resolume host/port and MA3 pool slots, then Sync.\n\n"
            .. "Note: Resolume's default webserver port is 8080, which grandMA3 "
            .. "also uses by default. If both run on the same machine, change "
            .. "Resolume's port (e.g. 8090) and enter that port here.",
        autoCloseOnInput = false,
        commands = {
            { value = 1, name = "Sync" },
            { value = 2, name = "Save Only" },
            { value = 0, name = "Cancel" },
        },
        inputs = {
            { name = "01 Host", value = tostring(RESOLUME_HOST) },
            {
                name = "02 Port",
                value = tostring(RESOLUME_PORT),
                whiteFilter = "0123456789",
                vkPlugin = "TextInputNumOnly",
            },
            {
                name = "03 Layout Index",
                value = tostring(LAYOUT_INDEX),
                whiteFilter = "0123456789",
                vkPlugin = "TextInputNumOnly",
            },
            { name = "04 Layout Name", value = tostring(LAYOUT_NAME) },
            {
                name = "05 Image Start",
                value = tostring(IMAGE_START_INDEX),
                whiteFilter = "0123456789",
                vkPlugin = "TextInputNumOnly",
            },
            {
                name = "06 Appearance Start",
                value = tostring(APPEARANCE_START_INDEX),
                whiteFilter = "0123456789",
                vkPlugin = "TextInputNumOnly",
            },
            {
                name = "07 Macro Start",
                value = tostring(MACRO_START_INDEX),
                whiteFilter = "0123456789",
                vkPlugin = "TextInputNumOnly",
            },
            {
                name = "08 Poll Interval (s)",
                value = string.format("%.2f", get_poll_interval()),
                whiteFilter = "0123456789.",
                vkPlugin = "TextInputNumOnly",
            },
        },
        states = {
            { name = "Fetch thumbnails", state = FETCH_THUMBNAILS and true or false },
            { name = "Only clips with thumbnail", state = ONLY_WITH_THUMBNAIL and true or false },
            { name = "Highlight previewing", state = HIGHLIGHT_PREVIEWING and true or false },
        },
    }

    -- Only pass display when it looks valid; a bad handle can suppress the popup.
    if display_handle ~= nil then
        options.display = display_handle
    end

    local ok, result = pcall(MessageBox, options)
    if not ok then
        Printf("MA3ArenaDeck: MessageBox failed: %s", tostring(result))
        -- Retry with a minimal dialog (some builds dislike states/inputs combo).
        ok, result = pcall(MessageBox, {
            title = "MA3ArenaDeck Setup",
            message = string.format(
                "Host=%s  Port=%d  Layout=%d\nEdit values in code/GlobalVars if this dialog is limited.\n\nContinue with Sync?",
                RESOLUME_HOST,
                RESOLUME_PORT,
                LAYOUT_INDEX
            ),
            commands = {
                { value = 1, name = "Sync" },
                { value = 0, name = "Cancel" },
            },
        })
        if not ok or type(result) ~= "table" then
            Printf("MA3ArenaDeck: setup dialog unavailable")
            return "cancel"
        end
        local cmd = tonumber(result.result)
        if cmd == nil and type(result.result) == "string" then
            cmd = (result.result:lower() == "sync") and 1 or 0
        end
        if (cmd or 0) == 1 then
            return "sync"
        end
        return "cancel"
    end

    if type(result) ~= "table" then
        Printf("MA3ArenaDeck: MessageBox returned %s", type(result))
        return "cancel"
    end
    if result.success == false then
        Printf("MA3ArenaDeck: setup cancelled")
        return "cancel"
    end

    local cmd = tonumber(result.result)
    if cmd == nil and type(result.result) == "string" then
        local r = result.result:lower()
        if r == "sync" then
            cmd = 1
        elseif r == "save only" or r == "save" then
            cmd = 2
        else
            cmd = 0
        end
    end
    cmd = cmd or 0
    if cmd == 0 then
        Printf("MA3ArenaDeck: setup cancelled")
        return "cancel"
    end

    RESOLUME_HOST = tostring(mb_input(result, "01 Host", RESOLUME_HOST))
    RESOLUME_PORT = tonumber(mb_input(result, "02 Port", RESOLUME_PORT)) or RESOLUME_PORT
    LAYOUT_INDEX = tonumber(mb_input(result, "03 Layout Index", LAYOUT_INDEX)) or LAYOUT_INDEX
    LAYOUT_NAME = tostring(mb_input(result, "04 Layout Name", LAYOUT_NAME))
    IMAGE_START_INDEX = tonumber(mb_input(result, "05 Image Start", IMAGE_START_INDEX))
        or IMAGE_START_INDEX
    APPEARANCE_START_INDEX = tonumber(mb_input(result, "06 Appearance Start", APPEARANCE_START_INDEX))
        or APPEARANCE_START_INDEX
    MACRO_START_INDEX = tonumber(mb_input(result, "07 Macro Start", MACRO_START_INDEX))
        or MACRO_START_INDEX
    refresh_derived_indexes()
    POLL_INTERVAL_SEC = nearest_poll_interval(
        mb_input(result, "08 Poll Interval (s)", POLL_INTERVAL_SEC)
    )
    FETCH_THUMBNAILS = mb_state(result, "Fetch thumbnails", FETCH_THUMBNAILS)
    ONLY_WITH_THUMBNAIL = mb_state(result, "Only clips with thumbnail", ONLY_WITH_THUMBNAIL)
    HIGHLIGHT_PREVIEWING = mb_state(result, "Highlight previewing", HIGHLIGHT_PREVIEWING)

    save_config()
    Printf(
        "MA3ArenaDeck: config saved (%s:%d, Layout %d, poll %.2fs)",
        RESOLUME_HOST,
        RESOLUME_PORT,
        LAYOUT_INDEX,
        POLL_INTERVAL_SEC
    )

    if cmd == 2 then
        return "save"
    end
    return "sync"
end

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------

local function param_value(param, default)
    if param == nil then
        return default
    end
    if type(param) == "table" then
        if param.value ~= nil then
            return param.value
        end
        return default
    end
    return param
end

local function http_get(url, accept, timeout_sec, keep_alive)
    local previous_timeout = http.TIMEOUT
    if timeout_sec ~= nil then
        http.TIMEOUT = timeout_sec
    end

    local body = {}
    local ok, code, _headers, status = http.request({
        url = url,
        method = "GET",
        headers = {
            ["Accept"] = accept or "application/json",
            ["Connection"] = keep_alive and "keep-alive" or "close",
        },
        sink = ltn12.sink.table(body),
    })

    if previous_timeout ~= nil then
        http.TIMEOUT = previous_timeout
    end

    if not ok then
        return nil, string.format("HTTP request failed: %s", tostring(code))
    end

    local status_code = tonumber(code)
    if status_code ~= 200 then
        return nil, string.format("HTTP %s (%s)", tostring(code), tostring(status))
    end

    return table.concat(body), nil
end

local function composition_url()
    return string.format("http://%s:%d/api/v1/composition", RESOLUME_HOST, RESOLUME_PORT)
end

local function layer_url(layer_index)
    return string.format(
        "http://%s:%d/api/v1/composition/layers/%d",
        RESOLUME_HOST,
        RESOLUME_PORT,
        tonumber(layer_index) or 1
    )
end

local function clip_slot_url(layer_index, column_index)
    return string.format(
        "http://%s:%d/api/v1/composition/layers/%d/clips/%d",
        RESOLUME_HOST,
        RESOLUME_PORT,
        tonumber(layer_index) or 1,
        tonumber(column_index) or 1
    )
end

local function clip_by_id_url(clip_id)
    return string.format(
        "http://%s:%d/api/v1/composition/clips/by-id/%s",
        RESOLUME_HOST,
        RESOLUME_PORT,
        tostring(clip_id)
    )
end

local function clip_connect_url(layer_index, column_index)
    return string.format(
        "http://%s:%d/api/v1/composition/layers/%d/clips/%d/connect",
        RESOLUME_HOST,
        RESOLUME_PORT,
        tonumber(layer_index) or 1,
        tonumber(column_index) or 1
    )
end

local function clip_connect_by_id_url(clip_id)
    return string.format(
        "http://%s:%d/api/v1/composition/clips/by-id/%s/connect",
        RESOLUME_HOST,
        RESOLUME_PORT,
        tostring(clip_id)
    )
end

--- POST with optional body. Treats 2xx (incl. 204) as success.
local function http_post(url, body, timeout_sec)
    local previous_timeout = http.TIMEOUT
    if timeout_sec ~= nil then
        http.TIMEOUT = timeout_sec
    end

    body = body or ""
    local response = {}
    local ok, code, _headers, status = http.request({
        url = url,
        method = "POST",
        headers = {
            ["Content-Type"] = "application/json",
            ["Content-Length"] = tostring(#body),
            ["Connection"] = "close",
        },
        source = ltn12.source.string(body),
        sink = ltn12.sink.table(response),
    })

    if previous_timeout ~= nil then
        http.TIMEOUT = previous_timeout
    end

    if not ok then
        return nil, string.format("HTTP POST failed: %s", tostring(code))
    end

    local status_code = tonumber(code) or 0
    -- Resolume connect often returns 204 No Content.
    if status_code < 200 or status_code >= 300 then
        return nil, string.format("HTTP %s (%s)", tostring(code), tostring(status))
    end

    return true, nil
end

local function thumbnail_url(clip)
    if type(clip.thumbnail_path) == "string" and clip.thumbnail_path ~= "" then
        if clip.thumbnail_path:sub(1, 1) == "/" then
            return string.format("http://%s:%d%s", RESOLUME_HOST, RESOLUME_PORT, clip.thumbnail_path)
        end
        return clip.thumbnail_path
    end
    return string.format(
        "http://%s:%d/api/v1/composition/clips/by-id/%s/thumbnail",
        RESOLUME_HOST,
        RESOLUME_PORT,
        tostring(clip.id)
    )
end

local function clip_is_available(clip)
    if type(clip) ~= "table" then
        return false
    end

    local thumbnail = clip.thumbnail
    if type(thumbnail) == "table" and thumbnail.is_default == false then
        return true
    end

    if ONLY_WITH_THUMBNAIL then
        return false
    end

    return clip.video ~= nil or clip.audio ~= nil
end

local function clip_media_path(clip)
    local video = clip.video
    if type(video) == "table" and type(video.fileinfo) == "table" then
        return video.fileinfo.path
    end
    local audio = clip.audio
    if type(audio) == "table" and type(audio.fileinfo) == "table" then
        return audio.fileinfo.path
    end
    return nil
end

local function is_playing_state(state)
    if state == "Connected" or state == "Connected & previewing" then
        return true
    end
    if HIGHLIGHT_PREVIEWING and state == "Previewing" then
        return true
    end
    return false
end

local function collect_clips(composition)
    local clips = {}
    local layers_meta = {}
    local layers = composition.layers or {}
    local max_column = 0

    for layer_index, layer in ipairs(layers) do
        local layer_name = param_value(layer.name, string.format("Layer %d", layer_index))
        local layer_clips = layer.clips or {}
        local filled = 0

        if #layer_clips > max_column then
            max_column = #layer_clips
        end

        for column_index, clip in ipairs(layer_clips) do
            if clip_is_available(clip) then
                filled = filled + 1
                if column_index > max_column then
                    max_column = column_index
                end
                local thumbnail = clip.thumbnail or {}
                clips[#clips + 1] = {
                    layer = layer_index,
                    column = column_index,
                    layer_name = layer_name,
                    layer_id = layer.id,
                    id = clip.id,
                    name = param_value(clip.name, ""),
                    connected = param_value(clip.connected, "Disconnected"),
                    selected = param_value(clip.selected, false),
                    media_path = clip_media_path(clip),
                    thumbnail_path = thumbnail.path,
                    has_thumbnail = thumbnail.is_default == false,
                    thumbnail_update = thumbnail.last_update,
                }
            end
        end

        layers_meta[#layers_meta + 1] = {
            index = layer_index,
            id = layer.id,
            name = layer_name,
            filled = filled,
            columns = #layer_clips,
        }
    end

    local used_max = 0
    for _, clip in ipairs(clips) do
        if clip.column > used_max then
            used_max = clip.column
        end
    end
    if used_max > 0 then
        max_column = used_max
    end

    return clips, {
        layers = layers_meta,
        layer_count = #layers_meta,
        max_column = max_column,
    }
end

local function fetch_composition(timeout_sec)
    local raw, err = http_get(composition_url(), "application/json", timeout_sec)
    if not raw then
        return nil, err
    end

    local ok, composition = pcall(json.decode, raw)
    if not ok or type(composition) ~= "table" then
        return nil, "Failed to decode composition JSON"
    end
    return composition, nil, raw and #raw or 0
end

local function fetch_available_clips()
    local composition, err = fetch_composition(10)
    if not composition then
        return nil, err
    end
    local clips, grid = collect_clips(composition)
    return clips, nil, composition, grid
end

--- id(string) -> connected state string
local function collect_connected_states(composition)
    local states = {}
    for _, layer in ipairs(composition.layers or {}) do
        for _, clip in ipairs(layer.clips or {}) do
            if clip.id ~= nil then
                states[tostring(clip.id)] = param_value(clip.connected, "Disconnected")
            end
        end
    end
    return states
end

--- Lighter poll: fetch each layer instead of the full composition JSON.
--- (Still heavy: Resolume returns full clip trees per layer ~hundreds of KB.)
local function collect_connected_states_by_layers(layer_indexes, timeout_sec)
    local states = {}
    local bytes = 0
    local requests = 0
    for layer_index in pairs(layer_indexes) do
        requests = requests + 1
        local raw, err = http_get(layer_url(layer_index), "application/json", timeout_sec or 2)
        if not raw then
            return nil, err, bytes, requests
        end
        bytes = bytes + #raw
        local ok, layer = pcall(json.decode, raw)
        if not ok or type(layer) ~= "table" then
            return nil, "Failed to decode layer JSON " .. tostring(layer_index), bytes, requests
        end
        for _, clip in ipairs(layer.clips or {}) do
            if clip.id ~= nil then
                states[tostring(clip.id)] = param_value(clip.connected, "Disconnected")
            end
        end
    end
    return states, nil, bytes, requests
end

local function fetch_clip_connected_state(meta, timeout_sec)
    local raw, err
    if meta.layer and meta.layer > 0 and meta.column and meta.column > 0 then
        raw, err = http_get(
            clip_slot_url(meta.layer, meta.column),
            "application/json",
            timeout_sec or 1.5,
            true
        )
    end
    if not raw then
        raw, err = http_get(
            clip_by_id_url(meta.id),
            "application/json",
            timeout_sec or 1.5,
            true
        )
    end
    if not raw then
        return nil, err, 0
    end
    local ok, clip = pcall(json.decode, raw)
    if not ok or type(clip) ~= "table" then
        return nil, "Failed to decode clip JSON", #raw
    end
    return param_value(clip.connected, "Disconnected"), nil, #raw
end

--- Fast poll: one small request per clip slot.
--- Only one clip per Resolume layer can be Connected, so once we find it we
--- mark the rest of that layer Disconnected without more HTTP calls.
--- Previously-playing clips are checked first (usually 1 request/layer).
local function collect_connected_states_by_clips(clip_metas, timeout_sec)
    local by_layer = {}
    local no_layer = {}
    for _, meta in ipairs(clip_metas) do
        if meta.layer and meta.layer > 0 then
            by_layer[meta.layer] = by_layer[meta.layer] or {}
            local list = by_layer[meta.layer]
            list[#list + 1] = meta
        else
            no_layer[#no_layer + 1] = meta
        end
    end

    local states = {}
    local bytes = 0
    local requests = 0

    local function check_meta(meta)
        requests = requests + 1
        local state, err, n = fetch_clip_connected_state(meta, timeout_sec)
        bytes = bytes + (n or 0)
        if not state then
            return nil, err
        end
        states[tostring(meta.id)] = state
        return state, nil
    end

    for _, metas in pairs(by_layer) do
        table.sort(metas, function(a, b)
            if a.playing == b.playing then
                return (a.column or 0) < (b.column or 0)
            end
            return a.playing and not b.playing
        end)

        local connected_id = nil
        for _, meta in ipairs(metas) do
            if connected_id then
                states[tostring(meta.id)] = "Disconnected"
            else
                local state, err = check_meta(meta)
                if not state then
                    return nil, err, bytes, requests
                end
                if is_playing_state(state) then
                    connected_id = tostring(meta.id)
                end
            end
        end
    end

    for _, meta in ipairs(no_layer) do
        local state, err = check_meta(meta)
        if not state then
            return nil, err, bytes, requests
        end
    end

    return states, nil, bytes, requests
end

------------------------------------------------------------------------
-- File helpers
------------------------------------------------------------------------

local function ensure_dir(path)
    pcall(function()
        os.execute(string.format('mkdir -p "%s"', path))
    end)
end

local function write_binary_file(path, data)
    local file, err = io.open(path, "wb")
    if not file then
        return false, err or "open failed"
    end
    file:write(data)
    file:close()
    return true
end

local function write_text_file(path, text)
    local file, err = io.open(path, "w")
    if not file then
        return false, err or "open failed"
    end
    file:write(text)
    file:close()
    return true
end

local function images_library_path()
    local path = nil
    if Enums and Enums.PathType and Enums.PathType.UserImageLibrary then
        path = GetPath(Enums.PathType.UserImageLibrary, true)
    end
    if path == nil or path == "" then
        path = GetPath("gma3_library/media/images", true)
    end
    return path
end

local function path_join(a, b)
    local sep = "/"
    if GetPathSeparator then
        sep = GetPathSeparator()
    end
    if a:sub(-1) == "/" or a:sub(-1) == "\\" then
        return a .. b
    end
    return a .. sep .. b
end

------------------------------------------------------------------------
-- Image + Appearance pool management
------------------------------------------------------------------------

local function get_images_pool()
    return ShowData().MediaPools.Images
end

local function get_appearances_pool()
    return ShowData().Appearances
end

local function object_name(obj)
    if obj == nil then
        return nil
    end
    local ok, name = pcall(function()
        return obj.Name or obj.name
    end)
    if ok then
        return name
    end
    return nil
end

local function pool_object_valid(obj)
    if obj == nil then
        return false
    end
    if IsObjectValid then
        local ok, valid = pcall(IsObjectValid, obj)
        if ok then
            return valid and true or false
        end
    end
    return true
end

--- Fresh shows only initialize a small pool range. Create(index) beyond
--- Count() silently fails (nil). Resize first, then Create.
local function ensure_pool_object(pool, index)
    if pool == nil then
        return nil
    end
    index = tonumber(index)
    if index == nil or index < 1 then
        return nil
    end

    if pool_object_valid(pool[index]) then
        return pool[index]
    end

    pcall(function()
        local count = pool:Count()
        if type(count) ~= "number" or index <= count then
            return
        end
        local max_count = nil
        pcall(function()
            max_count = pool:MaxCount()
        end)
        local new_size = math.ceil(index / 1000) * 1000
        if new_size < index then
            new_size = index
        end
        if type(max_count) == "number" and max_count > 0 then
            new_size = math.min(max_count, new_size)
            if index > new_size then
                return
            end
        end
        pool:Resize(new_size)
    end)

    local created = nil
    pcall(function()
        created = pool:Create(index)
    end)
    if pool_object_valid(created) then
        return created
    end
    if pool_object_valid(pool[index]) then
        return pool[index]
    end
    return nil
end

--- Macro-specific create with Cmd("Store Macro N") fallback for empty shows.
local function ensure_macro(index)
    local macros = DataPool().Macros
    if macros == nil then
        return nil
    end
    local macro = ensure_pool_object(macros, index)
    if pool_object_valid(macro) then
        return macro
    end
    pcall(function()
        Cmd(string.format("Store Macro %d /Overwrite", index))
    end)
    if pool_object_valid(macros[index]) then
        return macros[index]
    end
    return nil
end

local function find_pool_index_by_name(pool, name, start_index, max_slots)
    for i = start_index, start_index + max_slots - 1 do
        local obj = pool[i]
        if pool_object_valid(obj) and object_name(obj) == name then
            return i
        end
    end
    return nil
end

local function find_free_pool_index(pool, start_index, max_slots)
    for i = start_index, start_index + max_slots - 1 do
        if not pool_object_valid(pool[i]) then
            return i
        end
    end
    return nil
end

local function ensure_pool_index(pool, name, start_index, max_slots)
    local existing = find_pool_index_by_name(pool, name, start_index, max_slots)
    if existing then
        return existing
    end
    local free = find_free_pool_index(pool, start_index, max_slots)
    if not free then
        return nil, "No free pool slots left in configured range"
    end
    return free
end

--- Write PNG + .png.xml library descriptor (FileName pointer).
--- This MA3 build accepts: Import Image Library "name.png.xml" At Image …
local function write_image_import_files(clip, png_data)
    local lib = images_library_path()
    if lib == nil or lib == "" then
        return nil, "Could not resolve UserImageLibrary path"
    end
    ensure_dir(lib)

    local base = IMAGE_NAME_PREFIX .. tostring(clip.id)
    local png_name = base .. ".png"
    local sidecar_name = png_name .. ".xml"
    local png_path = path_join(lib, png_name)
    local sidecar_path = path_join(lib, sidecar_name)

    local ok, err = write_binary_file(png_path, png_data)
    if not ok then
        return nil, "Failed to write PNG: " .. tostring(err)
    end

    local sidecar = string.format(
        '<?xml version="1.0" encoding="UTF-8"?>\n'
            .. '<GMA3 DataVersion="2.2.1.1">\n'
            .. '    <UserImage FileName="%s" />\n'
            .. "</GMA3>\n",
        png_name
    )
    ok, err = write_text_file(sidecar_path, sidecar)
    if not ok then
        return nil, "Failed to write PNG XML sidecar: " .. tostring(err)
    end

    return {
        base = base,
        png_name = png_name,
        sidecar_name = sidecar_name,
        lib = lib,
        png_path = png_path,
        sidecar_path = sidecar_path,
        png_bytes = #png_data,
    }
end

local function delete_image_slot(images, image_index)
    if images == nil or image_index == nil then
        return
    end
    if pool_object_valid(images[image_index]) then
        pcall(function()
            images:Delete(image_index)
        end)
    end
    if pool_object_valid(images[image_index]) then
        pcall(function()
            Cmd(string.format("Delete Image %d.%d /NoConfirmation", IMAGE_POOL, image_index))
        end)
    end
end

--- Import via the one path this build accepts without Illegal object spam:
---   Import Image Library "MAD_….png.xml" At Image 3.N
--- Do not try embedded MAD_….xml library import — that logs Illegal object.
local function try_import_image(images, image_index, files)
    delete_image_slot(images, image_index)

    local image_obj = ensure_pool_object(images, image_index)
    if image_obj == nil then
        pcall(function()
            Cmd(string.format("Store Image %d.%d /Overwrite", IMAGE_POOL, image_index))
        end)
        image_obj = images[image_index]
    end
    if image_obj == nil or not pool_object_valid(image_obj) then
        return nil, "no-slot (pool Resize/Create failed at " .. tostring(image_index) .. ")"
    end

    local ok = pcall(function()
        Cmd(string.format(
            'Import Image Library "%s" At Image %d.%d /NoConfirmation',
            files.sidecar_name,
            IMAGE_POOL,
            image_index
        ))
    end)
    image_obj = images[image_index]
    if ok and pool_object_valid(image_obj) then
        return image_obj, "cmd-import-library-sidecar"
    end

    -- Quiet fallback (no Cmd noise): object API with the same sidecar XML.
    ok = pcall(function()
        image_obj:Import(files.lib, files.sidecar_name)
    end)
    image_obj = images[image_index]
    if ok and pool_object_valid(image_obj) then
        return image_obj, "object-import-sidecar-xml"
    end

    if pool_object_valid(images[image_index]) then
        return images[image_index], "import-failed"
    end
    return nil, "import-failed (slot missing after Import)"
end

local function import_image_to_pool(clip, png_data)
    if type(png_data) ~= "string" or #png_data < 24 or png_data:sub(1, 8) ~= "\137PNG\r\n\26\n" then
        return nil, "invalid PNG payload"
    end

    local files, err = write_image_import_files(clip, png_data)
    if not files then
        return nil, err
    end

    local images = get_images_pool()
    if images == nil then
        return nil, "Images pool not found"
    end

    local image_index, index_err = ensure_pool_index(
        images,
        files.base,
        IMAGE_START_INDEX,
        MAX_MEDIA_SLOTS
    )
    if not image_index then
        return nil, index_err
    end

    local image_obj, method = try_import_image(images, image_index, files)
    if image_obj == nil then
        return nil, tostring(method or ("Image import did not create pool object " .. tostring(image_index)))
    end

    pcall(function()
        image_obj:Set("Name", files.base)
    end)
    pcall(function()
        Cmd(string.format('Label Image %d.%d "%s"', IMAGE_POOL, image_index, files.base))
    end)

    Printf(
        "MA3ArenaDeck: image import Image %d.%d via %s (%d bytes)",
        IMAGE_POOL,
        image_index,
        tostring(method),
        files.png_bytes
    )

    return {
        index = image_index,
        name = files.base,
        handle = image_obj,
    }
end

local function style_playing_appearance(appearance)
    -- Subtle cyan marker tint for playing clips. MA3 Obj.Set wants strings.
    local props = {
        { "ImageR", "180" },
        { "ImageG", "245" },
        { "ImageB", "255" },
        { "BACKR", "0" },
        { "BACKG", "40" },
        { "BACKB", "50" },
    }
    for _, p in ipairs(props) do
        pcall(function()
            appearance:Set(p[1], p[2])
        end)
    end
end

-- Remember which border-color write works on this console (avoid Cmd spam).
local border_color_method = nil -- "obj-BorderColor" | "cmd-BorderColor" | ...

--- Apply border color on a layout element.
local function set_element_border_color(element, r, g, b)
    if element == nil then
        return
    end

    local idx = nil
    pcall(function()
        idx = element:Index()
    end)
    if not idx then
        return
    end

    local color = string.format("%d,%d,%d,255", r, g, b)

    local function try_obj(prop)
        return pcall(function()
            element:Set(prop, color)
        end)
    end

    local function try_cmd(prop)
        return pcall(function()
            Cmd(string.format(
                'Set Layout %d.%d Property "%s" "%s"',
                LAYOUT_INDEX,
                idx,
                prop,
                color
            ))
        end)
    end

    if border_color_method == "obj-BorderColor" then
        try_obj("BorderColor")
        return
    elseif border_color_method == "obj-BORDERCOLOR" then
        try_obj("BORDERCOLOR")
        return
    elseif border_color_method == "cmd-BorderColor" then
        try_cmd("BorderColor")
        return
    elseif border_color_method == "cmd-BORDERCOLOR" then
        try_cmd("BORDERCOLOR")
        return
    end

    if try_obj("BorderColor") then
        border_color_method = "obj-BorderColor"
    elseif try_obj("BORDERCOLOR") then
        border_color_method = "obj-BORDERCOLOR"
    elseif try_cmd("BorderColor") then
        border_color_method = "cmd-BorderColor"
    elseif try_cmd("BORDERCOLOR") then
        border_color_method = "cmd-BORDERCOLOR"
    end
end

local function apply_playing_chrome(element, playing)
    local border = playing and PLAYING_BORDER_SIZE or IDLE_BORDER_SIZE
    pcall(function()
        element:Set("bordersize", tostring(border))
        element:Set("visibilityborder", "Visible")
    end)
    if playing then
        set_element_border_color(element, PLAYING_BORDER_R, PLAYING_BORDER_G, PLAYING_BORDER_B)
    else
        set_element_border_color(element, IDLE_BORDER_R, IDLE_BORDER_G, IDLE_BORDER_B)
    end
end

local function ensure_named_appearance(app_name, image_info, playing)
    local appearances = get_appearances_pool()
    if appearances == nil then
        return nil, "Appearances pool not found"
    end

    local app_index, err = ensure_pool_index(
        appearances,
        app_name,
        APPEARANCE_START_INDEX,
        MAX_MEDIA_SLOTS
    )
    if not app_index then
        return nil, err
    end

    if appearances[app_index] == nil then
        ensure_pool_object(appearances, app_index)
    end

    local appearance = appearances[app_index]
    if appearance == nil or not pool_object_valid(appearance) then
        return nil, "Could not create Appearance " .. tostring(app_index)
    end

    appearance:Set("Name", app_name)
    if image_info then
        Cmd(string.format(
            "Assign Image %d.%d At Appearance %d",
            IMAGE_POOL,
            image_info.index,
            app_index
        ))
    end
    if playing then
        style_playing_appearance(appearance)
    end

    return {
        index = app_index,
        name = app_name,
        handle = appearance,
    }
end

local function ensure_appearances_for_image(image_info, clip_id)
    local idle_name = APPEARANCE_IDLE_PREFIX .. tostring(clip_id)
    local play_name = APPEARANCE_PLAY_PREFIX .. tostring(clip_id)

    local idle, idle_err = ensure_named_appearance(idle_name, image_info, false)
    if not idle then
        return nil, idle_err
    end

    local play, play_err = ensure_named_appearance(play_name, image_info, true)
    if not play then
        return nil, play_err
    end

    return {
        image = image_info,
        appearance_idle = idle,
        appearance_play = play,
    }
end

local function ensure_appearances_without_image(clip_id)
    local idle_name = APPEARANCE_IDLE_PREFIX .. tostring(clip_id)
    local play_name = APPEARANCE_PLAY_PREFIX .. tostring(clip_id)

    local idle, idle_err = ensure_named_appearance(idle_name, nil, false)
    if not idle then
        return nil, idle_err
    end
    local play, play_err = ensure_named_appearance(play_name, nil, true)
    if not play then
        return nil, play_err
    end
    return {
        image = nil,
        appearance_idle = idle,
        appearance_play = play,
    }
end

local function lookup_appearances_for_clip(clip_id)
    local appearances = get_appearances_pool()
    if appearances == nil then
        return nil
    end

    local idle_name = APPEARANCE_IDLE_PREFIX .. tostring(clip_id)
    local play_name = APPEARANCE_PLAY_PREFIX .. tostring(clip_id)
    local idle_index = find_pool_index_by_name(appearances, idle_name, APPEARANCE_START_INDEX, MAX_MEDIA_SLOTS)
    local play_index = find_pool_index_by_name(appearances, play_name, APPEARANCE_START_INDEX, MAX_MEDIA_SLOTS)

    if not idle_index and not play_index then
        return nil
    end

    local result = {}
    if idle_index then
        result.appearance_idle = {
            index = idle_index,
            name = idle_name,
            handle = appearances[idle_index],
        }
    end
    if play_index then
        result.appearance_play = {
            index = play_index,
            name = play_name,
            handle = appearances[play_index],
        }
    end
    return result
end

local function sync_clip_thumbnail(clip)
    if not clip.has_thumbnail then
        return ensure_appearances_without_image(clip.id)
    end

    local png, err = http_get(thumbnail_url(clip), "image/png")
    if not png then
        return ensure_appearances_without_image(clip.id)
    end

    if png:sub(1, 8) ~= "\137PNG\r\n\26\n" then
        return ensure_appearances_without_image(clip.id)
    end

    local image_info, image_err = import_image_to_pool(clip, png)
    if not image_info then
        return nil, image_err
    end

    return ensure_appearances_for_image(image_info, clip.id)
end

local function sync_thumbnails(clips)
    local map = {}
    local ok_count = 0
    local skip_count = 0
    local fail_count = 0

    Printf("MA3ArenaDeck: importing thumbnails / appearances...")

    for _, clip in ipairs(clips) do
        local media, err
        if FETCH_THUMBNAILS then
            media, err = sync_clip_thumbnail(clip)
        else
            media, err = ensure_appearances_without_image(clip.id)
        end

        if media then
            map[tostring(clip.id)] = media
            ok_count = ok_count + 1
            if clip.has_thumbnail and media.image then
                Printf(
                    "  thumb OK  L%02d C%03d %-20s -> Image %d.%d / App %d/%d",
                    clip.layer,
                    clip.column,
                    tostring(clip.name),
                    IMAGE_POOL,
                    media.image.index,
                    media.appearance_idle.index,
                    media.appearance_play.index
                )
            else
                skip_count = skip_count + 1
            end
        else
            fail_count = fail_count + 1
            Printf(
                "  thumb FAIL L%02d C%03d %-20s (%s)",
                clip.layer,
                clip.column,
                tostring(clip.name),
                tostring(err)
            )
        end
    end

    Printf(
        "MA3ArenaDeck: media done (ok=%d no-thumb=%d fail=%d)",
        ok_count,
        skip_count,
        fail_count
    )
    return map
end

------------------------------------------------------------------------
-- Plugin address / macros / monitor flag
------------------------------------------------------------------------

local function resolve_plugin_index()
    if myHandle == nil then
        return nil
    end
    -- ComponentLua -> parent UserPlugin
    local ok, parent = pcall(function()
        return myHandle:Parent()
    end)
    if ok and parent ~= nil then
        local idx = nil
        pcall(function()
            idx = parent:Index()
        end)
        if idx then
            return idx
        end
    end
    local idx = nil
    pcall(function()
        idx = myHandle:Index()
    end)
    return idx
end

local function plugin_command(argument)
    local arg = argument or "sync"
    if type(pluginName) == "string" and pluginName ~= "" then
        return string.format('Plugin "%s" "%s"', pluginName, arg)
    end

    local index = resolve_plugin_index()
    if index then
        return string.format('Plugin %d "%s"', index, arg)
    end
    return string.format('Plugin 1 "%s"', arg)
end

local function set_monitor_flag(enabled)
    SetVar(GlobalVars(), MONITOR_VAR, enabled and 1 or 0)
end

local function get_monitor_flag()
    local v = GetVar(GlobalVars(), MONITOR_VAR)
    return tonumber(v) == 1 or v == true or v == "1"
end

local function set_trigger_flag(enabled)
    SetVar(GlobalVars(), TRIGGER_VAR, enabled and 1 or 0)
end

local function get_trigger_flag()
    local v = GetVar(GlobalVars(), TRIGGER_VAR)
    return tonumber(v) == 1 or v == true or v == "1"
end

local function write_macro_lines(macro, macro_index, lines)
    local children = macro:Children()
    for i = #children, 1, -1 do
        macro:Delete(i)
    end

    for line_index, command in ipairs(lines) do
        local line = macro:Acquire()
        if line then
            local set_ok = pcall(function()
                line:Set("Command", command)
            end)
            if not set_ok then
                pcall(function()
                    line.Command = command
                end)
            end
            local got = ""
            pcall(function()
                got = tostring(line.Command or "")
            end)
            if got == "" then
                local escaped = command:gsub('\\', '\\\\'):gsub('"', '\\"')
                pcall(function()
                    Cmd(string.format(
                        'Set Macro %d.%d Property "Command" "%s"',
                        macro_index,
                        line_index,
                        escaped
                    ))
                end)
            end
        end
    end
end

local function ensure_control_macros()
    local macros = DataPool().Macros
    if macros == nil then
        return nil, "Macros pool not found"
    end

    local defs = {
        {
            index = MACRO_START_INDEX,
            name = "MAD_Sync",
            note = "resolume-ctrl:sync",
            lines = {
                string.format('Lua "SetVar(GlobalVars(), \'%s\', 0)"', MONITOR_VAR),
                "Wait 0.5",
                plugin_command("sync"),
            },
        },
        {
            index = MACRO_START_INDEX + 1,
            name = "MAD_PollOn",
            note = "resolume-ctrl:monitor",
            lines = {
                plugin_command("monitor"),
            },
        },
        {
            index = MACRO_START_INDEX + 2,
            name = "MAD_PollOff",
            note = "resolume-ctrl:stop",
            -- Clear flag immediately (interrupts loop), then plugin stop for UI chrome.
            lines = {
                string.format('Lua "SetVar(GlobalVars(), \'%s\', 0)"', MONITOR_VAR),
                plugin_command("stop"),
            },
        },
        {
            index = MACRO_START_INDEX + 3,
            name = "MAD_Interval",
            note = "resolume-ctrl:interval",
            lines = {
                plugin_command("interval"),
            },
        },
        {
            index = MACRO_START_INDEX + 4,
            name = "MAD_TrigToggle",
            note = "resolume-ctrl:trigger",
            lines = {
                plugin_command("trigtoggle"),
            },
        },
    }

    for _, def in ipairs(defs) do
        local macro = ensure_macro(def.index)
        if macro == nil then
            Printf("MA3ArenaDeck: could not create Macro %d '%s'", def.index, def.name)
            return nil, string.format("Could not create Macro %d", def.index)
        end
        macro:Set("Name", def.name)
        write_macro_lines(macro, def.index, def.lines)

        local line_count = 0
        pcall(function()
            line_count = #macro:Children()
        end)
        Printf(
            "MA3ArenaDeck: Macro %d '%s' ready (%d lines)",
            def.index,
            def.name,
            line_count
        )
    end

    return defs
end

--- One macro per clip: queue L,C for the poll loop (Lua SetVar only).
--- Do NOT Call Plugin here — that runs Cleanup on the monitor and stops poll.
--- Returns map clip_id_string -> macro_index
local function ensure_clip_trigger_macros(clips)
    local macros = DataPool().Macros
    local map = {}
    if macros == nil or type(clips) ~= "table" then
        return map
    end

    -- Grow once for the full clip range (fresh shows need Resize before Create).
    if #clips > 0 then
        ensure_macro(TRIGGER_MACRO_START + #clips - 1)
    end

    for i, clip in ipairs(clips) do
        local macro_index = TRIGGER_MACRO_START + (i - 1)
        local macro = ensure_macro(macro_index)
        if macro == nil then
            Printf(
                "MA3ArenaDeck: could not create trigger Macro %d (clip L%d C%d)",
                macro_index,
                tonumber(clip.layer) or 1,
                tonumber(clip.column) or 1
            )
        else
            local layer = tonumber(clip.layer) or 1
            local column = tonumber(clip.column) or 1
            local name = string.format("MAD_Fire_L%dC%d", layer, column)
            macro:Set("Name", name)
            write_macro_lines(macro, macro_index, {
                string.format(
                    'Lua "SetVar(GlobalVars(), \'%s\', \'%d,%d\')"',
                    FIRE_VAR,
                    layer,
                    column
                ),
            })
            map[tostring(clip.id)] = macro_index
        end
    end

    Printf(
        "MA3ArenaDeck: clip trigger macros ready (%d, start=%d)",
        #clips,
        TRIGGER_MACRO_START
    )
    return map
end

------------------------------------------------------------------------
-- Output
------------------------------------------------------------------------

local function print_clips(clips, composition, grid)
    local comp_name = "unknown"
    if type(composition) == "table" then
        comp_name = param_value(composition.name, "unknown")
    end

    Printf("MA3ArenaDeck ----------------------------------------")
    Printf("Host: %s:%d", RESOLUME_HOST, RESOLUME_PORT)
    Printf("Composition: %s", tostring(comp_name))
    Printf("Available clips: %d", #clips)
    if grid then
        Printf("Grid: %d layers x %d columns (used)", grid.layer_count, grid.max_column)
    end
    Printf("-----------------------------------------------------------")

    for i, clip in ipairs(clips) do
        local selected = clip.selected and "*" or " "
        local thumb = clip.has_thumbnail and "T" or "-"
        Printf(
            "[%03d]%s%s L%02d C%03d | %-24s | %-16s | %s",
            i,
            selected,
            thumb,
            clip.layer,
            clip.column,
            tostring(clip.layer_name),
            tostring(clip.connected),
            tostring(clip.name)
        )
    end

    Printf("-----------------------------------------------------------")
end

------------------------------------------------------------------------
-- Layout builder
------------------------------------------------------------------------

local function get_layouts_pool()
    return DataPool().Layouts
end

local function ensure_layout()
    local layouts = get_layouts_pool()
    if layouts == nil then
        return nil, "Layouts pool not found"
    end

    if layouts[LAYOUT_INDEX] == nil then
        ensure_pool_object(layouts, LAYOUT_INDEX)
    end

    local layout = layouts[LAYOUT_INDEX]
    if layout == nil or not pool_object_valid(layout) then
        return nil, string.format("Could not create Layout %d", LAYOUT_INDEX)
    end

    layout:Set("Name", LAYOUT_NAME)
    return layout, nil
end

local function clear_layout_elements(layout)
    local children = layout:Children()
    for i = #children, 1, -1 do
        layout:Delete(i)
    end
end

local function cell_pos(column_index, layer_index, _layer_count)
    local x = ORIGIN_X + LABEL_WIDTH + ((column_index - 1) * (CELL_WIDTH + CELL_GAP_X))
    local y = ORIGIN_Y + ((layer_index - 1) * (CELL_HEIGHT + CELL_GAP_Y))
    return x, y
end

local function label_pos(layer_index, _layer_count)
    local x = ORIGIN_X
    local y = ORIGIN_Y + ((layer_index - 1) * (CELL_HEIGHT + CELL_GAP_Y))
    return x, y
end

local function assign_appearance(element, appearance_info)
    if element == nil or appearance_info == nil or appearance_info.handle == nil then
        return false
    end

    local ok = pcall(function()
        element.Appearance = appearance_info.handle:AddrNative()
    end)
    if ok then
        return true
    end

    ok = pcall(function()
        element:Set("Appearance", appearance_info.handle:AddrNative())
    end)
    if ok then
        return true
    end

    local elem_no = nil
    pcall(function()
        elem_no = element:Index()
    end)
    if elem_no == nil then
        elem_no = element.No or element.index
    end
    if elem_no then
        pcall(function()
            Cmd(string.format(
                'Set Layout %d.%d Property "Appearance" %d',
                LAYOUT_INDEX,
                elem_no,
                appearance_info.index
            ))
        end)
        pcall(function()
            Cmd(string.format(
                "Assign Appearance %d At Layout %d.%d",
                appearance_info.index,
                LAYOUT_INDEX,
                elem_no
            ))
        end)
        return true
    end

    return false
end

--- Solid fill Appearance for control buttons (no image).
local function ensure_solid_appearance(app_name, r, g, b)
    local appearances = get_appearances_pool()
    if appearances == nil then
        return nil
    end

    local app_index, err = ensure_pool_index(
        appearances,
        app_name,
        APPEARANCE_START_INDEX,
        MAX_MEDIA_SLOTS
    )
    if not app_index then
        Printf("MA3ArenaDeck: solid appearance '%s' failed: %s", app_name, tostring(err))
        return nil
    end

    if appearances[app_index] == nil then
        ensure_pool_object(appearances, app_index)
    end
    local appearance = appearances[app_index]
    if appearance == nil or not pool_object_valid(appearance) then
        return nil
    end

    appearance:Set("Name", app_name)
    local color01 = string.format("%.3f,%.3f,%.3f,1", r / 255, g / 255, b / 255)
    pcall(function()
        appearance:Set("Color", color01)
    end)
    pcall(function()
        Cmd(string.format(
            'Set Appearance %d Property "Color" "%s"',
            app_index,
            color01
        ))
    end)

    local channel_props = {
        { "ImageR", r },
        { "ImageG", g },
        { "ImageB", b },
        { "BACKR", r },
        { "BACKG", g },
        { "BACKB", b },
        { "BackR", r },
        { "BackG", g },
        { "BackB", b },
        { "ImageAlpha", 255 },
        { "BackAlpha", 255 },
    }
    for _, p in ipairs(channel_props) do
        pcall(function()
            appearance:Set(p[1], tostring(p[2]))
        end)
    end

    return {
        index = app_index,
        name = app_name,
        handle = appearance,
    }
end

local function control_appearance_for(kind, active)
    if kind == "monitor" then
        local c = active and CTRL_COLOR.poll_on_active or CTRL_COLOR.poll_on_idle
        local name = active and "MAD_Btn_PollOn_On" or "MAD_Btn_PollOn_Off"
        return ensure_solid_appearance(name, c.r, c.g, c.b)
    end
    if kind == "stop" then
        local c = active and CTRL_COLOR.poll_off_active or CTRL_COLOR.poll_off_idle
        local name = active and "MAD_Btn_PollOff_On" or "MAD_Btn_PollOff_Off"
        return ensure_solid_appearance(name, c.r, c.g, c.b)
    end
    if kind == "interval" then
        local c = CTRL_COLOR.interval
        return ensure_solid_appearance("MAD_Btn_Interval", c.r, c.g, c.b)
    end
    if kind == "trigger" then
        local c = active and CTRL_COLOR.trigger_active or CTRL_COLOR.trigger_idle
        local name = active and "MAD_Btn_Trig_On" or "MAD_Btn_Trig_Off"
        return ensure_solid_appearance(name, c.r, c.g, c.b)
    end
    if kind == "sync" then
        local c = CTRL_COLOR.sync
        return ensure_solid_appearance("MAD_Btn_Sync", c.r, c.g, c.b)
    end
    return nil
end

local function element_addr(element)
    if element == nil then
        return nil
    end
    local addr = nil
    pcall(function()
        addr = element:ToAddr()
    end)
    return addr
end

local function cleanup_stray_rcs_macro_elements(layout)
    if layout == nil then
        return 0
    end

    local removed = 0
    local children = layout:Children()
    for i = #children, 1, -1 do
        local el = children[i]
        local note = ""
        pcall(function()
            note = el.Note or el.note or ""
        end)

        local is_ctrl_button = type(note) == "string" and note:find("^resolume%-ctrl:") ~= nil
        local is_clip = type(note) == "string" and note:find("^resolume%-clip:") ~= nil
        -- Clip cells may have MAD_Fire_* macros assigned when trigger mode is on.
        if not is_ctrl_button and not is_clip then
            local obj_name = ""
            pcall(function()
                local obj = el.Object
                if obj ~= nil then
                    obj_name = tostring(obj.Name or obj.name or "")
                end
            end)
            if obj_name == "" then
                pcall(function()
                    obj_name = tostring(el.Name or "")
                end)
            end

            if obj_name:find("^MAD_") ~= nil then
                layout:Delete(i)
                removed = removed + 1
                Printf("MA3ArenaDeck: removed stray '%s' from layout", obj_name)
            end
        end
    end
    return removed
end

local function style_element(element, opts)
    element:Set("posx", tostring(opts.x))
    element:Set("posy", tostring(opts.y))
    element:Set("width", tostring(opts.width))
    element:Set("height", tostring(opts.height))
    element:Set("customtexttext", tostring(opts.text or ""))
    element:Set("customtextsize", tostring(opts.text_size or 16))
    element:Set("customtextalignmenth", "Center")
    element:Set("customtextalignmentv", opts.text_align_v or "Center")
    element:Set("visibilityborder", "Visible")
    element:Set("bordersize", tostring(opts.border or 2))
    element:Set("visibilityobjectname", "Hidden")
    if opts.note then
        element:Set("note", tostring(opts.note))
    end
end

local function interval_button_label()
    return string.format("POLL %.2fs", get_poll_interval())
end

local function trigger_button_label()
    return get_trigger_flag() and "TRIG ON" or "TRIG OFF"
end

local function parse_ctrl_note(note)
    if type(note) ~= "string" then
        return nil
    end
    return note:match("^resolume%-ctrl:([%w_]+)")
end

local function apply_control_chrome(element, kind, active)
    if element == nil or kind == nil then
        return
    end

    local color = CTRL_COLOR.sync
    local border = 5
    if kind == "monitor" then
        color = active and CTRL_COLOR.poll_on_active or CTRL_COLOR.poll_on_idle
        border = active and 10 or 4
    elseif kind == "stop" then
        color = active and CTRL_COLOR.poll_off_active or CTRL_COLOR.poll_off_idle
        border = active and 10 or 4
    elseif kind == "interval" then
        color = CTRL_COLOR.interval
        border = 6
    elseif kind == "trigger" then
        color = active and CTRL_COLOR.trigger_active or CTRL_COLOR.trigger_idle
        border = active and 10 or 4
    elseif kind == "sync" then
        color = CTRL_COLOR.sync
        border = 5
    end

    pcall(function()
        element:Set("bordersize", tostring(border))
        element:Set("visibilityborder", "Visible")
    end)
    set_element_border_color(element, color.r, color.g, color.b)

    -- Solid appearance fill (border color alone is unreliable on macro elements).
    local app = control_appearance_for(kind, active)
    if app then
        assign_appearance(element, app)
    end

    if kind == "interval" then
        pcall(function()
            element:Set("customtexttext", interval_button_label())
        end)
    elseif kind == "trigger" then
        pcall(function()
            element:Set("customtexttext", trigger_button_label())
        end)
    end
end

local function update_control_button_styles()
    local layout = DataPool().Layouts[LAYOUT_INDEX]
    if layout == nil then
        return
    end

    local monitoring = get_monitor_flag()
    local triggering = get_trigger_flag()
    for _, element in ipairs(layout:Children()) do
        local note = nil
        pcall(function()
            note = element.Note or element.note
        end)
        local kind = parse_ctrl_note(note)
        if kind then
            local active = false
            if kind == "monitor" then
                active = monitoring
            elseif kind == "stop" then
                active = not monitoring
            elseif kind == "trigger" then
                active = triggering
            elseif kind == "interval" or kind == "sync" then
                active = true
            end
            apply_control_chrome(element, kind, active)
        end
    end
end

local function set_element_action_go(element)
    if element == nil then
        return
    end
    local addr = element_addr(element)
    if addr then
        pcall(function()
            Cmd('Set ' .. addr .. ' Property "Action" "Go+"')
        end)
    end
    local child_index = nil
    pcall(function()
        child_index = element:Index()
    end)
    if child_index then
        pcall(function()
            Cmd(string.format(
                'Set Layout %d.%d Property "Action" "Go+"',
                LAYOUT_INDEX,
                child_index
            ))
        end)
    end
end

--- Place a control Macro on the layout as a new element, then style it.
--- Do not create an empty placeholder first: on this MA3 build,
--- `Assign Macro N At Layout X.Y` appends a sibling, and deleting that
--- "stray" removed the only element that actually had the Macro/Action.
local function place_control_macro(layout, macro_index, geo)
    if layout == nil or macro_index == nil then
        return false
    end

    local macro = DataPool().Macros[macro_index]
    if macro == nil then
        Printf("MA3ArenaDeck: Macro %d missing", macro_index)
        return false
    end

    local before = #layout:Children()
    local ok = pcall(function()
        Cmd(string.format(
            "Assign Macro %d At Layout %d",
            macro_index,
            LAYOUT_INDEX
        ))
    end)

    local children = layout:Children()
    local target = nil
    if #children > before then
        target = children[#children]
    else
        -- Fallback: find by assigned object / name.
        for i = #children, 1, -1 do
            local el = children[i]
            local match = false
            pcall(function()
                local obj = el.Object
                if obj and obj:Index() == macro_index then
                    match = true
                end
            end)
            if not match then
                pcall(function()
                    local name = tostring(el.Name or "")
                    if name == tostring(macro.Name) then
                        match = true
                    end
                end)
            end
            if match then
                target = el
                break
            end
        end
    end

    if target == nil then
        Printf(
            "MA3ArenaDeck: Assign Macro %d did not create a layout element",
            macro_index
        )
        return false
    end

    if geo then
        style_element(target, geo)
    end
    set_element_action_go(target)
    pcall(function()
        target:Set("visibilityobjectname", "Hidden")
    end)

    local child_index = nil
    pcall(function()
        child_index = target:Index()
    end)

    Printf(
        "MA3ArenaDeck: button Macro %d -> Layout %d.%s (%s)",
        macro_index,
        LAYOUT_INDEX,
        tostring(child_index or "?"),
        ok and "ok" or "cmd-failed"
    )
    return true
end

local function add_element(layout, opts)
    local element = layout:Acquire()
    if element == nil then
        return nil
    end
    style_element(element, opts)
    if opts.appearance then
        assign_appearance(element, opts.appearance)
    end
    if opts.playing ~= nil then
        apply_playing_chrome(element, opts.playing)
    end
    return element
end

local function clip_note(clip_id, clip_name, playing, layer, column, macro_index)
    local note = string.format(
        "resolume-clip:%s|name:%s|play:%s|L:%s|C:%s",
        tostring(clip_id),
        tostring(clip_name or ""):gsub("|", "/"),
        playing and "1" or "0",
        tostring(layer or 0),
        tostring(column or 0)
    )
    if macro_index then
        note = note .. "|M:" .. tostring(macro_index)
    end
    return note
end

local function parse_clip_note(note)
    if type(note) ~= "string" then
        return nil
    end
    local id = note:match("resolume%-clip:([%w%-]+)")
    if not id then
        return nil
    end
    local name = note:match("|name:([^|]*)") or ""
    local play = note:match("|play:(%d)") == "1"
    local layer = tonumber(note:match("|L:(%d+)"))
    local column = tonumber(note:match("|C:(%d+)"))
    local macro_index = tonumber(note:match("|M:(%d+)"))
    return {
        id = id,
        name = name,
        playing = play,
        layer = layer,
        column = column,
        macro_index = macro_index,
    }
end

local function clear_element_action(element)
    if element == nil then
        return
    end
    local idx = nil
    pcall(function()
        idx = element:Index()
    end)
    pcall(function()
        element:Set("Action", "")
    end)
    pcall(function()
        element:Set("Object", "")
    end)
    if idx then
        pcall(function()
            Cmd(string.format('Set Layout %d.%d Property "Action" ""', LAYOUT_INDEX, idx))
        end)
        pcall(function()
            Cmd(string.format('Set Layout %d.%d Property "Object" ""', LAYOUT_INDEX, idx))
        end)
    end
end

local function assign_clip_trigger_macro(element, macro_index)
    if element == nil or macro_index == nil then
        return false
    end
    local macro = DataPool().Macros[macro_index]
    if macro == nil then
        return false
    end

    -- Prefer Object property (Assign Macro At Layout X.Y often appends a sibling).
    local ok = pcall(function()
        element:Set("Object", macro)
    end)
    if not ok then
        ok = pcall(function()
            element:Set("Object", string.format("Macro %d", macro_index))
        end)
    end
    set_element_action_go(element)
    pcall(function()
        element:Set("visibilityobjectname", "Hidden")
    end)
    return true
end

local function apply_trigger_mode_to_layout(enabled)
    local layout = DataPool().Layouts[LAYOUT_INDEX]
    if layout == nil then
        return 0
    end

    local count = 0
    for _, element in ipairs(layout:Children()) do
        local note = nil
        pcall(function()
            note = element.Note or element.note
        end)
        local meta = parse_clip_note(note)
        if meta then
            if enabled and meta.macro_index then
                if assign_clip_trigger_macro(element, meta.macro_index) then
                    count = count + 1
                end
            else
                clear_element_action(element)
                count = count + 1
            end
        end
    end
    return count
end

--- Returns new enabled state (true = trigger on).
local function toggle_trigger_mode()
    local enabled = not get_trigger_flag()
    set_trigger_flag(enabled)
    local n = apply_trigger_mode_to_layout(enabled)
    update_control_button_styles()
    Printf(
        "MA3ArenaDeck: trigger mode %s (%d clip elements)",
        enabled and "ON" or "OFF",
        n
    )
    pcall(function()
        Echo(string.format("MA3ArenaDeck: TRIG %s", enabled and "ON" or "OFF"))
    end)
    return enabled
end

--- Called from the poll loop: handle clip taps queued via GlobalVars.
local function process_pending_fire()
    local v = nil
    pcall(function()
        v = GetVar(GlobalVars(), FIRE_VAR)
    end)
    if v == nil or v == "" or v == 0 or v == "0" then
        return false
    end
    pcall(function()
        SetVar(GlobalVars(), FIRE_VAR, "")
    end)

    local layer, column = tostring(v):match("^(%d+)%s*,%s*(%d+)$")
    if not layer then
        return false
    end

    local ok, err = http_post(clip_connect_url(layer, column), "", 2)
    if ok then
        Printf(
            "MA3ArenaDeck: triggered L%d C%d (from layout tap)",
            tonumber(layer) or 0,
            tonumber(column) or 0
        )
        return true
    end

    Printf("MA3ArenaDeck: trigger FAILED (%s)", tostring(err))
    return false
end

local function fire_resolume_clip(layer, column, clip_id)
    if not ensure_deps() then
        return false
    end

    local ok, err
    if layer and column then
        ok, err = http_post(clip_connect_url(layer, column), "", 2)
        if ok then
            Printf(
                "MA3ArenaDeck: triggered L%d C%d",
                tonumber(layer) or 0,
                tonumber(column) or 0
            )
            return true
        end
    end

    if clip_id then
        ok, err = http_post(clip_connect_by_id_url(clip_id), "", 2)
        if ok then
            Printf("MA3ArenaDeck: triggered clip id %s", tostring(clip_id))
            return true
        end
    end

    Printf("MA3ArenaDeck: trigger FAILED (%s)", tostring(err))
    return false
end

local function add_control_buttons(layout, layer_count)
    local macros = ensure_control_macros()
    if not macros then
        return 0
    end

    -- Below layer 1 (Y-up): negative Y, with extra offset so they never cover clips.
    local y = ORIGIN_Y - (BUTTON_HEIGHT + BUTTON_GAP + BUTTON_ROW_OFFSET)
    local x = ORIGIN_X
    local created = 0

    local buttons = {
        { label = "SYNC", macro = macros[1], note = "resolume-ctrl:sync", kind = "sync" },
        { label = "POLL ON", macro = macros[2], note = "resolume-ctrl:monitor", kind = "monitor" },
        { label = "POLL OFF", macro = macros[3], note = "resolume-ctrl:stop", kind = "stop" },
        {
            label = interval_button_label(),
            macro = macros[4],
            note = "resolume-ctrl:interval",
            kind = "interval",
        },
        {
            label = trigger_button_label(),
            macro = macros[5],
            note = "resolume-ctrl:trigger",
            kind = "trigger",
        },
    }

    for i, btn in ipairs(buttons) do
        local bx = x + ((i - 1) * (BUTTON_WIDTH + BUTTON_GAP))
        local geo = {
            x = bx,
            y = y,
            width = BUTTON_WIDTH,
            height = BUTTON_HEIGHT,
            text = btn.label,
            text_size = 16,
            border = 5,
            note = btn.note,
        }
        if place_control_macro(layout, btn.macro.index, geo) then
            created = created + 1
        else
            Printf("MA3ArenaDeck: failed to wire button '%s'", btn.label)
        end
    end

    cleanup_stray_rcs_macro_elements(layout)
    update_control_button_styles()
    return created
end

local function build_layout(clips, grid, appearance_map)
    local layout, err = ensure_layout()
    if not layout then
        return nil, err
    end

    clear_layout_elements(layout)

    local layer_count = grid.layer_count
    local created = 0
    appearance_map = appearance_map or {}

    if layer_count >= 1 and SHOW_LAYER_LABELS then
        for _, layer in ipairs(grid.layers) do
            local x, y = label_pos(layer.index, layer_count)
            local label = string.format("L%d %s", layer.index, tostring(layer.name))
            local el = add_element(layout, {
                x = x,
                y = y,
                width = LABEL_WIDTH - CELL_GAP_X,
                height = CELL_HEIGHT,
                text = label,
                text_size = 14,
                border = LAYER_BORDER_SIZE,
                note = string.format("resolume-layer:%s", tostring(layer.id or layer.index)),
            })
            if el then
                set_element_border_color(el, LAYER_BORDER_R, LAYER_BORDER_G, LAYER_BORDER_B)
                created = created + 1
            end
        end
    end

    local fire_macros = ensure_clip_trigger_macros(clips)
    local trigger_enabled = get_trigger_flag()

    for _, clip in ipairs(clips) do
        local x, y = cell_pos(clip.column, clip.layer, layer_count)
        local playing = is_playing_state(clip.connected)
        local text = tostring(clip.name)
        if playing then
            text = "> " .. text
        end

        local media = appearance_map[tostring(clip.id)]
        local appearance = nil
        if media then
            appearance = playing and media.appearance_play or media.appearance_idle
        end

        local macro_index = fire_macros[tostring(clip.id)]
        local element = add_element(layout, {
            x = x,
            y = y,
            width = CELL_WIDTH,
            height = CELL_HEIGHT,
            text = text,
            text_size = appearance and 12 or 14,
            text_align_v = appearance and "Bottom" or "Center",
            border = playing and PLAYING_BORDER_SIZE or IDLE_BORDER_SIZE,
            appearance = appearance,
            playing = playing,
            note = clip_note(
                clip.id,
                clip.name,
                playing,
                clip.layer,
                clip.column,
                macro_index
            ),
        })
        if element then
            created = created + 1
            if trigger_enabled and macro_index then
                assign_clip_trigger_macro(element, macro_index)
            end
        end
    end

    created = created + add_control_buttons(layout, layer_count)
    cleanup_stray_rcs_macro_elements(layout)

    return layout, nil, created
end

------------------------------------------------------------------------
-- Status polling / highlight updates
------------------------------------------------------------------------

local function apply_element_playing_state(element, meta, playing)
    local apps = lookup_appearances_for_clip(meta.id)
    local appearance = nil
    if apps then
        appearance = playing and apps.appearance_play or apps.appearance_idle
        if appearance == nil then
            appearance = apps.appearance_idle or apps.appearance_play
        end
    end

    if appearance then
        assign_appearance(element, appearance)
    end

    local name = meta.name
    if name == "" then
        name = tostring(meta.id)
    end
    local text = playing and ("> " .. name) or name
    pcall(function()
        element:Set("customtexttext", text)
        element:Set(
            "note",
            clip_note(meta.id, name, playing, meta.layer, meta.column, meta.macro_index)
        )
    end)
    apply_playing_chrome(element, playing)
end

--- Returns ok, err, changed, stats_table
local function update_playing_highlights()
    local layout = DataPool().Layouts[LAYOUT_INDEX]
    if layout == nil then
        return false, "Layout not found", 0, nil
    end

    local layer_indexes = {}
    local clip_elements = {}
    for _, element in ipairs(layout:Children()) do
        local note = nil
        pcall(function()
            note = element.Note or element.note
        end)
        local meta = parse_clip_note(note)
        if meta then
            clip_elements[#clip_elements + 1] = { element = element, meta = meta }
            if meta.layer and meta.layer > 0 then
                layer_indexes[meta.layer] = true
            end
        end
    end

    local t_fetch0 = Time()
    local states, err, bytes, requests
    local mode = "clips"
    local layer_count = 0
    for _ in pairs(layer_indexes) do
        layer_count = layer_count + 1
    end

    local clip_metas = {}
    for _, item in ipairs(clip_elements) do
        clip_metas[#clip_metas + 1] = item.meta
    end

    if #clip_metas > 0 then
        -- Prefer tiny per-clip requests (layer JSON was ~350KB each / ~3s).
        states, err, bytes, requests = collect_connected_states_by_clips(clip_metas, 1.5)
        if not states and layer_count > 0 then
            mode = "layers-fallback"
            states, err, bytes, requests = collect_connected_states_by_layers(layer_indexes, 2)
        end
        if not states then
            mode = "composition-fallback"
            local composition, comp_err, comp_bytes = fetch_composition(5)
            if not composition then
                return false, tostring(err or comp_err), 0, {
                    mode = mode,
                    fetch_s = Time() - t_fetch0,
                    bytes = 0,
                    requests = requests or 0,
                }
            end
            states = collect_connected_states(composition)
            bytes = comp_bytes or 0
            requests = 1
        end
    else
        mode = "composition"
        local composition, comp_err, comp_bytes = fetch_composition(5)
        if not composition then
            return false, tostring(comp_err), 0, {
                mode = mode,
                fetch_s = Time() - t_fetch0,
                bytes = 0,
                requests = 1,
            }
        end
        states = collect_connected_states(composition)
        bytes = comp_bytes or 0
        requests = 1
    end
    local fetch_s = Time() - t_fetch0

    local t_apply0 = Time()
    local changed = 0
    for _, item in ipairs(clip_elements) do
        local meta = item.meta
        local state = states[meta.id] or "Disconnected"
        local playing = is_playing_state(state)
        if playing ~= meta.playing then
            apply_element_playing_state(item.element, meta, playing)
            changed = changed + 1
        end
    end
    local apply_s = Time() - t_apply0

    return true, nil, changed, {
        mode = mode,
        fetch_s = fetch_s,
        apply_s = apply_s,
        bytes = bytes or 0,
        requests = requests or 0,
        layers = layer_count,
        clips = #clip_elements,
    }
end

local function ui_echo(msg)
    pcall(function()
        Echo(msg)
    end)
end

local function cycle_poll_interval()
    local current = get_poll_interval()
    local next_index = 1
    for i, opt in ipairs(POLL_INTERVAL_OPTIONS) do
        if math.abs(opt - current) < 0.001 then
            next_index = (i % #POLL_INTERVAL_OPTIONS) + 1
            break
        end
    end
    local value = set_poll_interval(POLL_INTERVAL_OPTIONS[next_index])
    update_control_button_styles()
    Printf("MA3ArenaDeck: poll interval -> %.2fs", value)
    ui_echo(string.format("MA3ArenaDeck: poll interval -> %.2fs", value))
end

local function run_monitor_loop()
    local interval = get_poll_interval()

    -- Always take ownership. A previous monitor may have been killed when
    -- another Plugin call ran (Cleanup), leaving a stale MONITOR flag.
    local owner = string.format("%0.4f-%d", Time(), math.random(10000, 99999))
    pcall(function()
        SetVar(GlobalVars(), MONITOR_OWNER_VAR, owner)
    end)
    set_monitor_flag(true)
    update_control_button_styles()

    Printf(
        "MA3ArenaDeck: POLL ON - monitor started (v%s)",
        PLUGIN_VERSION
    )
    Printf(
        "  interval=%.2fs  host=%s:%d  url=%s",
        interval,
        RESOLUME_HOST,
        RESOLUME_PORT,
        composition_url()
    )
    ui_echo(string.format(
        "MA3ArenaDeck: POLL ON v%s (%.2fs) %s:%d",
        PLUGIN_VERSION,
        interval,
        RESOLUME_HOST,
        RESOLUME_PORT
    ))

    local function still_owner()
        local current = nil
        pcall(function()
            current = GetVar(GlobalVars(), MONITOR_OWNER_VAR)
        end)
        return tostring(current or "") == owner
    end

    -- Plugins run as coroutines: must yield or the loop is a busy-wait that
    -- freezes / gets aborted, so highlights only refresh when POLL ON is tapped again.
    local tick = 0
    local last_tick_end = Time()
    while get_monitor_flag() and still_owner() do
        tick = tick + 1
        local tick_start = Time()
        local gap_s = tick_start - last_tick_end

        -- Layout taps queue fires here (SetVar) so Plugin/Cleanup never runs.
        process_pending_fire()

        local ok, err, changed, stats = update_playing_highlights()
        local tick_s = Time() - tick_start
        last_tick_end = Time()

        if not ok then
            Printf("MA3ArenaDeck monitor ERROR: %s", tostring(err))
            ui_echo(string.format("MA3ArenaDeck poll ERROR: %s", tostring(err)))
        else
            -- Always log the first few ticks so slow fetches are obvious.
            if tick <= 5 or (changed and changed > 0) or (tick % 20 == 0) then
                Printf(
                    "MA3ArenaDeck: poll #%d changed=%d total=%.2fs fetch=%.2fs apply=%.2fs gap=%.2fs mode=%s req=%d bytes=%d layers=%d",
                    tick,
                    changed or 0,
                    tick_s,
                    stats and stats.fetch_s or 0,
                    stats and stats.apply_s or 0,
                    gap_s,
                    stats and stats.mode or "?",
                    stats and stats.requests or 0,
                    stats and stats.bytes or 0,
                    stats and stats.layers or 0
                )
            end
            if tick == 1 then
                ui_echo(string.format(
                    "MA3ArenaDeck: first poll %.2fs (fetch %.2fs, mode=%s)",
                    tick_s,
                    stats and stats.fetch_s or 0,
                    stats and stats.mode or "?"
                ))
            end
        end

        if not get_monitor_flag() or not still_owner() then
            break
        end

        interval = get_poll_interval()
        local yield_ok = pcall(function()
            coroutine.yield(interval)
        end)
        if not yield_ok then
            local until_t = Time() + interval
            while get_monitor_flag() and still_owner() and Time() < until_t do
            end
        end
    end

    if still_owner() then
        set_monitor_flag(false)
        update_control_button_styles()
        Printf("MA3ArenaDeck: POLL OFF - monitor stopped (after %d ticks)", tick)
        ui_echo("MA3ArenaDeck: POLL OFF - monitor stopped")
    else
        Printf("MA3ArenaDeck: monitor instance replaced (after %d ticks)", tick)
    end
end

------------------------------------------------------------------------
-- Actions
------------------------------------------------------------------------

local function run_full_sync()
    -- Ensure a running monitor yields before we rebuild the layout.
    set_monitor_flag(false)

    Printf("MA3ArenaDeck: SYNC starting (v%s)", PLUGIN_VERSION)
    Printf("MA3ArenaDeck: fetching composition...")
    local clips, err, composition, grid = fetch_available_clips()
    if not clips then
        Printf("MA3ArenaDeck ERROR: %s", tostring(err))
        Printf("Check that Resolume Webserver is enabled and reachable at %s", composition_url())
        return
    end

    print_clips(clips, composition, grid)

    local appearance_map = sync_thumbnails(clips)

    Printf("MA3ArenaDeck: building Layout %d '%s'...", LAYOUT_INDEX, LAYOUT_NAME)
    local layout, layout_err, created = build_layout(clips, grid, appearance_map)
    if not layout then
        Printf("MA3ArenaDeck ERROR: %s", tostring(layout_err))
        return
    end

    ensure_control_macros()

    Printf(
        "MA3ArenaDeck: layout ready (%d elements, %d clips, %d layer rows)",
        created or 0,
        #clips,
        grid.layer_count
    )
    Printf(
        "Controls: Macro %d SYNC | %d POLL ON | %d POLL OFF | %d INTERVAL | %d TRIG",
        MACRO_START_INDEX,
        MACRO_START_INDEX + 1,
        MACRO_START_INDEX + 2,
        MACRO_START_INDEX + 3,
        MACRO_START_INDEX + 4
    )
    Printf(
        "Trigger mode: %s (tap clips %s)",
        get_trigger_flag() and "ON" or "OFF",
        get_trigger_flag() and "fire Resolume" or "monitor only"
    )
end

------------------------------------------------------------------------
-- Entry point
------------------------------------------------------------------------

function Main(display_handle, argument)
    load_config()

    -- Normalize argument. Pool taps often pass nil; macros pass "sync"/etc.
    -- Some builds pass a non-string; coerce safely.
    local arg = ""
    if argument ~= nil then
        arg = tostring(argument):lower():gsub("^%s+", ""):gsub("%s+$", "")
    end

    Printf(
        "MA3ArenaDeck: v%s starting (%s) arg='%s' (type=%s)",
        PLUGIN_VERSION,
        tostring(pluginName or "plugin"),
        arg,
        type(argument)
    )

    -- Fire a Resolume clip (from per-clip layout macros). Keep this first / cheap.
    local trig_layer, trig_col = arg:match("^trigger%s+(%d+)%s+(%d+)$")
    if trig_layer then
        fire_resolume_clip(tonumber(trig_layer), tonumber(trig_col), nil)
        return
    end
    local trig_id = arg:match("^trigger%s+id%s+([%w%-]+)$")
    if trig_id then
        fire_resolume_clip(nil, nil, trig_id)
        return
    end

    if arg == "trigtoggle" or arg == "trig" or arg == "trigger toggle" then
        toggle_trigger_mode()
        -- Calling Plugin replaces the previous monitor coroutine; always resume poll.
        if not ensure_deps() then
            return
        end
        run_monitor_loop()
        return
    end

    if arg == "stop" or arg == "polloff" or arg == "poll off" or arg == "off" then
        set_monitor_flag(false)
        update_control_button_styles()
        Printf("MA3ArenaDeck: stop requested")
        return
    end

    if arg == "interval" or arg == "pollinterval" or arg == "poll interval" then
        cycle_poll_interval()
        return
    end

    if arg == "monitor" or arg == "pollon" or arg == "poll on" or arg == "on" then
        if not ensure_deps() then
            return
        end
        run_monitor_loop()
        return
    end

    -- Layout SYNC button: sync without dialog.
    if arg == "sync" then
        if not ensure_deps() then
            return
        end
        run_full_sync()
        return
    end

    -- Plugin pool / unknown / setup: always show configuration UI first.
    local action = show_setup_dialog(display_handle)
    if action ~= "sync" then
        return
    end
    if not ensure_deps() then
        return
    end
    run_full_sync()
end

function Cleanup()
    -- Intentionally do NOT clear MONITOR_VAR here.
    -- Any other Plugin invocation (old trigger macros, interval, etc.) would
    -- stop the poll via Cleanup. Poll is stopped only by POLL OFF / SYNC.
end

return Main, Cleanup
