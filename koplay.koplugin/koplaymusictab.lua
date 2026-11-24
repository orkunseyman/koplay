--[[--
"Music" tab in KOReader's bottom menu (swipe up inside a book): the current track on one line,
and previous / play-pause / next buttons.

The track is fetched when the tab is shown, right after a button press, and every refresh interval
while the tab stays on screen. Nothing runs once the bottom menu is closed or on another tab.
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

-- FontAwesome step-backward / play / pause / step-forward (U+F048, F04B, F04C, F051), drawn from
-- nerdfonts/symbols.ttf, which KOReader uses as a fallback for all UI text
local PREV, PLAY, PAUSE, NEXT = "\239\129\136", "\239\129\139", "\239\129\140", "\239\129\145"

local track_row = {
    name = "koplay_track",
    item_text = { "" },
    item_align_center = 1.0, -- no name column: the track line gets the full width
    item_font_size = 20,
    values = {}, -- so a long-press can't store anything either
    args = { "open" }, -- a tap opens the now playing screen, with the cover art
    event = "KoPlayMusicTab",
}
local button_row = {
    name = "koplay_buttons",
    toggle = { PREV, PLAY, NEXT },
    item_align_center = 1.0,
    item_font_size = 22,
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
    button_row.toggle[2] = (s and not s.idle and s.is_playing) and PAUSE or PLAY
end

local function recheck() KoPlayMusicTab.fetchSoon(true) end

--- After the panel has been painted with the cached text: fetch, and redraw if anything changed.
-- While the tab stays on screen, it checks again every refresh interval (songs changed on the phone).
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
        -- one timer at most; once the menu is closed or on another tab, the check above ends the chain
        UIManager:unschedule(recheck)
        UIManager:scheduleIn(plugin:getInterval(), recheck)
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

--- A button was tapped. action: "previous", "toggle", "next", or "open" (the track line).
function KoPlayMusicTab.onButton(plugin, action)
    if action == "open" then
        -- next tick: the bottom menu is still finishing this tap
        UIManager:nextTick(function()
            plugin.ui.config:onCloseConfigMenu()
            plugin:onKoPlayNowPlaying()
        end)
        return true
    end
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
