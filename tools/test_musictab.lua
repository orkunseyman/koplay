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
assert(track_row.item_text[1] == "Song · Artist" and button_row.toggle[2] == "Pause")
plugin.menu_state = { idle = true }
track_row.show_func()
assert(track_row.item_text[1] == "Open Spotify on your phone" and button_row.toggle[2] == "Resume")
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

-- Turning it off removes it and moves the bottom menu off the missing tab
settings.koplay_music_tab = false
plugin.ui.config.last_panel_index = 3
MusicTab.apply(plugin)
assert(#cre == 1 and #kopt == 2 and plugin.ui.config.last_panel_index == 2)

print("ok")
