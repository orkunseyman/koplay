-- Tests for koplaymusictab.lua without KOReader. Run from the repo root: luajit tools/test_musictab.lua
package.path = "koplay.koplugin/?.lua;" .. package.path

local settings = {}
G_reader_settings = {
    nilOrTrue = function(_self, k) return settings[k] ~= false end,
}
local cre, kopt = { prefix = "copt", { icon = "a" } }, { prefix = "kopt", { icon = "a" }, { icon = "b" } }
local ticks, online = {}, true
local stubs = {
    ["ui/data/creoptions"] = cre,
    ["ui/data/koptoptions"] = kopt,
    ["ui/network/manager"] = { runWhenOnline = function(_self, fn) if online then fn() end end },
    ["ui/uimanager"] = {
        tickAfterNext = function(_self, fn) table.insert(ticks, fn) end,
        scheduleIn = function(_self, _s, fn) table.insert(ticks, fn) end,
        nextTick = function(_self, fn) table.insert(ticks, fn) end,
        unschedule = function(_self, fn) for i = #ticks, 1, -1 do if ticks[i] == fn then table.remove(ticks, i) end end end,
        setDirty = function() end,
    },
    util = { arrayContains = function(t, v) for i, x in ipairs(t) do if x == v then return i end end return false end },
    gettext = { current_lang = "C" },
}
for name, m in pairs(stubs) do package.preload[name] = function() return m end end

local MusicTab = require("koplaymusictab")
local commands = {}
local plugin = {
    ui = { config = { options = kopt, last_panel_index = 1 } },
    menu_state = { title = "Song", artist = "Artist", is_playing = true },
    control = function(_self, action) table.insert(commands, action) end,
    refreshMenuState = function() end,
    getInterval = function() return 10 end,
    errorLines = function(_self, err) return "error " .. err, "hint" end,
}

-- Added once, at the end of both option tables
MusicTab.install(plugin)
MusicTab.install(plugin)
assert(#cre == 2 and #kopt == 3 and cre[2] == kopt[3], "tab not added exactly once at the end")
local tab = cre[2]
local track_row, button_row = tab.options[1], tab.options[2]
assert(track_row.name and button_row.name and button_row.values and #button_row.values == 0,
    "rows need a name and empty values, or KOReader crashes / saves them")

-- Labels
assert(track_row.show_func() == true)
assert(track_row.item_text[1] == "Song · Artist" and button_row.toggle[2] == "\239\129\140")
plugin.menu_state = { idle = true }
track_row.show_func()
assert(track_row.item_text[1] == "Open Spotify on your phone" and button_row.toggle[2] == "\239\129\139")
plugin.menu_state = { idle = true, device = "Phone" }
track_row.show_func()
assert(track_row.item_text[1] == "Nothing playing")
plugin.menu_error = "network"
track_row.show_func()
assert(track_row.item_text[1] == "error network", "error message not reused")
plugin.menu_error = nil

-- Buttons: play/pause flips the label at once, then runs KoPlay's control()
plugin.menu_state = { title = "Song", artist = "", is_playing = true }
assert(MusicTab.onButton(plugin, "toggle") == true)
assert(plugin.menu_state.is_playing == false and commands[1] == "toggle")
MusicTab.onButton(plugin, "next")
assert(commands[2] == "next")

-- Tapping the track line closes the bottom menu, then opens the now playing screen
local steps = {}
plugin.ui.config.onCloseConfigMenu = function() table.insert(steps, "close menu") end
plugin.onKoPlayNowPlaying = function() table.insert(steps, "now playing") end
ticks = {}
assert(track_row.event == "KoPlayMusicTab" and track_row.args[1] == "open")
assert(MusicTab.onButton(plugin, "open") == true and #steps == 0, "must wait for the menu to finish the tap")
ticks[1]()
assert(steps[1] == "close menu" and steps[2] == "now playing" and #commands == 2)

-- While the tab is on screen it keeps checking, with one timer only; closing the menu ends it
local fetches = 0
plugin.refreshMenuState = function() fetches = fetches + 1 end
plugin.ui.config.config_dialog = { config_options = cre, panel_index = 2, update = function() end, dialog_frame = {} }
ticks = {}
MusicTab.fetchSoon()
ticks[1]()                      -- the fetch itself
assert(fetches == 1 and #ticks == 2, "should schedule exactly one recheck")
local recheck = ticks[2]
MusicTab.fetchSoon()
ticks[3]()                      -- a second fetch replaces the pending recheck, never adds one
assert(fetches == 2 and #ticks == 3 and ticks[3] == recheck, "rechecks are stacking")
plugin.ui.config.config_dialog = nil -- menu closed
ticks = {}
recheck()
ticks[1]()
assert(fetches == 2 and #ticks == 1, "kept checking after the menu closed")

-- Turning it off removes it and moves the bottom menu off the missing tab
settings.koplay_music_tab = false
plugin.ui.config.last_panel_index = 3
MusicTab.apply(plugin)
assert(#cre == 1 and #kopt == 2 and plugin.ui.config.last_panel_index == 2)

print("ok")
