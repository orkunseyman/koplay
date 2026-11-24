--[[--
"Music" tab in KOReader's bottom menu (swipe up inside a book): the current track on one line,
and previous / play-pause / next buttons.

No polling: the track is fetched only when the tab is shown and right after a button press.
The buttons work like KOReader's own font size decrease / increase buttons (font_fine_tune in
creoptions.lua): `values = {}` stores nothing in the book's settings, so no button stays selected.
--]]

local CreOptions = require("ui/data/creoptions")
local KoptOptions = require("ui/data/koptoptions")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local util = require("util")
local _ = require("koplayl10n")

local KoPlayMusicTab = {
    plugin = nil, -- the KoPlay object of the open book
}

local track_row = {
    name = "koplay_track",
    item_text = { "" },
    item_align_center = 1.0, -- no name column: the track line gets the full width
    item_font_size = 20,
    values = {}, -- so a long-press can't store anything either
}
local button_row = {
    name = "koplay_buttons",
    toggle = { "", "", "" },
    item_align_center = 1.0,
    height = 40, -- the default 30 is a small target on a 167 ppi screen
    values = {},
    args = { "previous", "toggle", "next" },
    event = "KoPlayMusicTab",
}
local tab = { icon = "music", options = { track_row, button_row } }

local function trackText(plugin)
    local s = plugin.menu_state
    if plugin.menu_error then return (plugin:errorLines(plugin.menu_error)) end
    if not s then return _("Loading…") end
    if s.idle then return s.device and _("Nothing playing") or _("Open Spotify on your phone") end
    return s.artist ~= "" and (s.title .. " · " .. s.artist) or s.title
end

local function refreshLabels(plugin)
    local s = plugin.menu_state
    track_row.item_text[1] = trackText(plugin)
    button_row.toggle[1], button_row.toggle[3] = _("Previous"), _("Next")
    button_row.toggle[2] = (s and not s.idle and s.is_playing) and _("Pause") or _("Resume")
end

--- After the panel has been painted with the cached text: fetch, and redraw if anything changed.
function KoPlayMusicTab.fetchSoon(force)
    UIManager:tickAfterNext(function()
        local plugin = KoPlayMusicTab.plugin
        local dialog = plugin and plugin.ui.config and plugin.ui.config.config_dialog
        if not dialog or dialog.config_options[dialog.panel_index] ~= tab then return end -- closed, or another tab
        local shown = track_row.item_text[1] .. button_row.toggle[2]
        plugin:refreshMenuState(force) -- at most once per 5 s unless forced, so the redraw below can't loop
        refreshLabels(plugin)
        if track_row.item_text[1] .. button_row.toggle[2] ~= shown then
            dialog:update()
            UIManager:setDirty(dialog, function() return "ui", dialog.dialog_frame.dimen end)
        end
    end)
end

-- show_func runs each time the panel is built, before its rows: the place to set their labels.
function track_row.show_func()
    local plugin = KoPlayMusicTab.plugin
    if not plugin then return false end
    refreshLabels(plugin)
    KoPlayMusicTab.fetchSoon()
    return true
end

--- A button was tapped. action: "previous", "toggle" or "next".
function KoPlayMusicTab.onButton(plugin, action)
    local s = plugin.menu_state
    if action == "toggle" and s and not s.idle then
        s.is_playing = not s.is_playing -- flip the label right away, the real state follows
    end
    plugin.menu_state_at = os.time() -- skip the fetch on the panel rebuild: Spotify isn't updated yet
    NetworkMgr:runWhenOnline(function()
        plugin:control(action)
        -- same wait as the KoPlay menu: Spotify needs a moment before the change shows up
        UIManager:scheduleIn(1.5, function() KoPlayMusicTab.fetchSoon(true) end)
    end)
    return true
end

--- Adds or removes the tab to match the setting. Safe to call any number of times.
function KoPlayMusicTab.apply(plugin)
    local on = G_reader_settings:nilOrTrue("koplay_music_tab")
    for _i, options in ipairs{ CreOptions, KoptOptions } do
        local index = util.arrayContains(options, tab)
        if on and not index then
            table.insert(options, tab) -- last, so the tab numbers books remember stay right
        elseif not on and index then
            table.remove(options, index)
        end
    end
    local config = plugin.ui.config
    if config then -- don't reopen the bottom menu on a tab that's gone
        config.last_panel_index = math.min(config.last_panel_index, #config.options)
    end
end

function KoPlayMusicTab.install(plugin)
    if plugin.ui.config then KoPlayMusicTab.plugin = plugin end -- only books have a bottom menu
    KoPlayMusicTab.apply(plugin)
end

return KoPlayMusicTab
