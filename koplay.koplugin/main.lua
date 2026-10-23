--[[--
KoPlay: shows what Spotify is playing, with big album art, lets you control playback
(also from gestures while reading) and browse your library.

@module koplugin.KoPlay
--]]

local ButtonDialog = require("ui/widget/buttondialog")
local Device = require("device")
local Dispatcher = require("dispatcher")
local ImageWidget = require("ui/widget/imagewidget")
local InfoMessage = require("ui/widget/infomessage")
local NetworkMgr = require("ui/network/manager")
local Notification = require("ui/widget/notification")
local PluginShare = require("pluginshare")
local RenderImage = require("ui/renderimage")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local socket = require("socket")
local T = require("ffi/util").template
local _ = require("koplayl10n")

local KoPlayApi = require("koplayapi")
local KoPlayLibrary = require("koplaylibrary")
local KoPlayView = require("koplayview")

local IDLE_INTERVAL = 30 -- seconds between polls when paused / nothing playing
local ERROR_INTERVAL = 20
local SETTLE_DELAY = 1.2 -- Spotify needs a moment before a command shows up in the playback state

local ERRORS = {
    no_auth = { "Spotify account not connected", "Copy koplay.json into koreader/settings" },
    auth_revoked = { "Spotify login is no longer valid", "Run koplay_auth.py on your computer again" },
    network = { "No connection", "Check Wi-Fi, will retry" },
    rate_limited = { "Spotify asked us to slow down", "Will retry shortly" },
    forbidden = { "Spotify refused this", "Premium may be required, or the content isn't available" },
    no_device = { "No active Spotify device", "Open Spotify on your phone or computer" },
}

local KoPlay = WidgetContainer:extend{
    name = "koplay",
    is_doc_only = false,
}

function KoPlay:onDispatcherRegisterActions()
    Dispatcher:registerAction("koplay_now_playing", {
        category = "none", event = "KoPlayNowPlaying", title = _("KoPlay: now playing"), general = true,
    })
    Dispatcher:registerAction("koplay_library", {
        category = "none", event = "KoPlayLibrary", title = _("KoPlay: library"), general = true,
    })
    -- For use while reading: assign them to gestures, no need to open anything
    Dispatcher:registerAction("koplay_toggle", {
        category = "none", event = "KoPlayToggle", title = _("KoPlay: play/pause"), general = true,
    })
    Dispatcher:registerAction("koplay_next", {
        category = "none", event = "KoPlayNext", title = _("KoPlay: next track"), general = true,
    })
    Dispatcher:registerAction("koplay_previous", {
        category = "none", event = "KoPlayPrevious", title = _("KoPlay: previous track"), general = true,
    })
    Dispatcher:registerAction("koplay_show_track", {
        category = "none", event = "KoPlayShowTrack", title = _("KoPlay: show current track"), general = true,
    })
end

function KoPlay:init()
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
end

function KoPlay:getInterval()
    return G_reader_settings:readSetting("koplay_poll_interval", 10)
end

function KoPlay:addToMainMenu(menu_items)
    local function intervalItem(sec)
        return {
            text = T(_("%1 seconds"), sec),
            checked_func = function() return self:getInterval() == sec end,
            callback = function() G_reader_settings:saveSetting("koplay_poll_interval", sec) end,
        }
    end
    local settings = {
        {
            text = _("Refresh interval"),
            sub_item_table = { intervalItem(5), intervalItem(10), intervalItem(15), intervalItem(30) },
        },
        {
            text = _("Keep screen awake while open"),
            checked_func = function() return G_reader_settings:nilOrTrue("koplay_keep_awake") end,
            callback = function() G_reader_settings:flipNilOrTrue("koplay_keep_awake") end,
        },
    }
    local function libraryItem(text, open)
        return { text = text, callback = function() self:openLibrary(open) end }
    end
    local function controlItem(action, text_func, separator)
        return {
            text_func = text_func,
            keep_menu_open = true,
            separator = separator,
            callback = function(touchmenu_instance)
                local s = self.menu_state
                if action == "toggle" and s and not s.idle then
                    -- flip the label right away, the real state follows
                    s.is_playing = not s.is_playing
                    touchmenu_instance:updateItems()
                end
                self:control(action)
                UIManager:scheduleIn(SETTLE_DELAY + 0.3, function()
                    self:refreshMenuState(true)
                    touchmenu_instance:updateItems()
                end)
            end,
        }
    end
    menu_items.koplay = {
        text = "KoPlay",
        sorting_hint = "tools",
        -- built on every opening, so the first line shows what's playing right now
        sub_item_table_func = function()
            self:refreshMenuState()
            return {
                {
                    text_func = function()
                        local s = self.menu_state
                        if s and not s.idle then
                            local track = s.artist ~= "" and (s.title .. " — " .. s.artist) or s.title
                            return T(_("Now playing: %1"), track)
                        end
                        return _("Now playing")
                    end,
                    callback = function() self:onKoPlayNowPlaying() end,
                },
                controlItem("previous", function() return _("Previous") end),
                controlItem("toggle", function()
                    local s = self.menu_state
                    return (s and not s.idle and s.is_playing) and _("Pause") or _("Resume")
                end),
                controlItem("next", function() return _("Next") end, true),
                libraryItem(_("Playlists"), "openPlaylists"),
                libraryItem(_("Liked Songs"), "openLiked"),
                libraryItem(_("Search"), "openSearch"),
                libraryItem(_("Recently played"), "openRecent"),
                {
                    text = _("Queue"),
                    callback = function() self:openLibrary("openQueue") end,
                    separator = true,
                },
                { text = _("Settings"), sub_item_table = settings },
            }
        end,
    }
end

--- Keeps the playback state shown in the KoPlay menu fresh, without hammering the API
-- (the menu may build its items more than once, e.g. for menu search).
function KoPlay:refreshMenuState(force)
    if not force and self.menu_state_at and os.time() - self.menu_state_at < 5 then return end
    if not KoPlayApi:hasAuth() or not NetworkMgr:isOnline() then return end
    self.menu_state = KoPlayApi:getPlayback(0) or self.menu_state
    self.menu_state_at = os.time()
end

--- Opens the library straight at one of its lists. open: a KoPlayLibrary method name.
function KoPlay:openLibrary(open)
    self:onKoPlayLibrary(function(library) library[open](library) end)
end

function KoPlay:errorLines(err)
    local e = ERRORS[err]
    if e then return _(e[1]), _(e[2]) end
    return _("Couldn't reach Spotify"), tostring(err)
end

function KoPlay:errorText(err)
    local title, hint = self:errorLines(err)
    return title .. "\n\n" .. hint
end

-- Mirrors the KeepAlive plugin, so the device doesn't sleep while the view is open.
function KoPlay:setKeepAwake(on)
    if on then
        if not G_reader_settings:nilOrTrue("koplay_keep_awake") or self.kept_awake then return end
        if PluginShare.keepalive or PluginShare.pause_auto_suspend then return end -- someone else handles it
        self.kept_awake = true
        PluginShare.pause_auto_suspend = true
        if Device:isKindle() then
            PluginShare.keepalive = true
            os.execute("lipc-set-prop com.lab126.powerd preventScreenSaver 1")
        end
    elseif self.kept_awake then
        self.kept_awake = nil
        PluginShare.pause_auto_suspend = false
        if Device:isKindle() then
            PluginShare.keepalive = false
            os.execute("lipc-set-prop com.lab126.powerd preventScreenSaver 0")
        end
    end
end

function KoPlay:checkAuth()
    if KoPlayApi:hasAuth() then return true end
    UIManager:show(InfoMessage:new{
        text = _("Spotify account not connected.\n\nRun tools/koplay_auth.py on your computer and copy the resulting koplay.json into koreader/settings/ on this device."),
    })
    return false
end

function KoPlay:onKoPlayNowPlaying()
    if self.view then return true end
    if not self:checkAuth() then return true end
    self.view = KoPlayView:new{
        on_control = function(action) self:control(action) end,
        on_close = function() self:onViewClosed() end,
        on_library = function() self:onKoPlayLibrary() end,
    }
    self.view:update{ message = _("Connecting…"), hint = "" }
    UIManager:show(self.view, "full")
    self:setKeepAwake(true)
    self.poll_task = function() self:poll() end
    NetworkMgr:runWhenOnline(self.poll_task)
    return true
end

--- then_open: optional function(library), run once the library is showing.
function KoPlay:onKoPlayLibrary(then_open)
    if not self:checkAuth() then return true end
    if not self.library then
        self.library = KoPlayLibrary:new{
            plugin = self,
            on_close = function()
                -- catch up on whatever was started from the library
                if self.view then self:schedule(0.5) end
            end,
        }
    end
    NetworkMgr:runWhenOnline(function()
        self.library:show()
        if type(then_open) == "function" then then_open(self.library) end
    end)
    return true
end

--- Gesture actions, meant for use while reading: they only show a short toast.
function KoPlay:runGestureAction(action)
    if not self:checkAuth() then return true end
    NetworkMgr:runWhenOnline(function() self:control(action, true) end)
    return true
end

function KoPlay:onKoPlayToggle() return self:runGestureAction("toggle") end
function KoPlay:onKoPlayNext() return self:runGestureAction("next") end
function KoPlay:onKoPlayPrevious() return self:runGestureAction("previous") end

function KoPlay:onKoPlayShowTrack()
    if not self:checkAuth() then return true end
    NetworkMgr:runWhenOnline(function() self:toastCurrentTrack() end)
    return true
end

function KoPlay:toast(text)
    Notification:notify(text, Notification.SOURCE_ALWAYS_SHOW)
end

function KoPlay:toastCurrentTrack()
    local state, err = KoPlayApi:getPlayback(0)
    if not state then
        return self:toast((self:errorLines(err)))
    end
    if state.idle then
        return self:toast(_("Nothing playing right now"))
    end
    local text = "♪ " .. state.title
    if state.artist ~= "" then text = text .. " — " .. state.artist end
    if not state.is_playing then text = _("Paused") .. ": " .. text end
    self:toast(text)
end

function KoPlay:onViewClosed()
    if self.poll_task then UIManager:unschedule(self.poll_task) end
    self.poll_task = nil
    self.view = nil
    self.state = nil
    self.cover_url = nil
    self:setKeepAwake(false)
end

function KoPlay:schedule(delay)
    if not self.poll_task then return end
    UIManager:unschedule(self.poll_task)
    UIManager:scheduleIn(delay, self.poll_task)
end

function KoPlay:loadCover(url)
    if url == self.cover_url then return false end
    self.cover_url = url
    local size = self.view:getCoverSize()
    local image
    if url and size > 0 then
        local data = KoPlayApi:download(url)
        local bb = data and RenderImage:renderImageData(data, #data, false, size, size)
        if bb then
            image = ImageWidget:new{ image = bb, width = size, height = size, image_disposable = true }
        end
    end
    self.view:setCover(image)
    return true
end

function KoPlay:showError(err)
    local title, hint = self:errorLines(err)
    self.view:update{ state = self.state, message = title, hint = hint }
    self.view:refresh(false)
end

function KoPlay:poll()
    if not self.view then return end
    if self.library and self.library.menu then
        -- the library covers the view: don't spend network or refreshes on it
        return self:schedule(IDLE_INTERVAL)
    end
    local state, err = KoPlayApi:getPlayback(self.view:getCoverSize())
    if not self.view then return end -- closed while we were blocked on the network
    if not state then
        logger.warn("KoPlay: poll failed", err)
        self:showError(err)
        if err == "no_auth" or err == "auth_revoked" then return end
        self:schedule(err == "rate_limited" and math.max(5, KoPlayApi.retry_after - os.time()) or ERROR_INTERVAL)
        return
    end

    local track_changed = not self.state or self.state.id ~= state.id or (self.state.idle ~= state.idle)
    local cover_changed = self:loadCover(not state.idle and state.cover_url or nil)
    self.state = state
    self.menu_state, self.menu_state_at = state, os.time()
    self.view:update{ state = state }
    -- A full (flashing) refresh only when the picture changes, to clear e-ink ghosting
    self.view:refresh(track_changed or cover_changed)

    local delay = IDLE_INTERVAL
    if state.is_playing then
        delay = self:getInterval()
        -- poll right after the track ends so the next one shows up promptly
        local remaining = (state.duration_ms - state.progress_ms) / 1000
        if remaining > 0 and remaining + 1 < delay then
            delay = remaining + 1
        end
    end
    self:schedule(math.max(2, delay))
end

--- Runs a playback command. If no Spotify device is active, offers the available ones
-- and retries there. fn(device_id) -> ok, err; on_success() runs after it worked.
-- open_view: show the now playing view afterwards if it isn't open.
function KoPlay:startPlayback(fn, on_success, open_view)
    local function done()
        if on_success then on_success() end
        if self.view then
            self:schedule(SETTLE_DELAY)
        elseif open_view then
            self:onKoPlayNowPlaying()
        end
    end
    local function fail(err)
        UIManager:show(InfoMessage:new{ text = self:errorText(err), timeout = 4 })
    end

    local ok, err = fn(nil)
    if ok then return done() end
    if err ~= "no_device" then return fail(err) end

    local devices = KoPlayApi:getDevices()
    if not devices or #devices == 0 then return fail("no_device") end
    local function tryOn(device)
        local ok2, err2 = fn(device.id)
        if ok2 then return done() end
        fail(err2)
    end
    if #devices == 1 then return tryOn(devices[1]) end

    local dialog
    local buttons = {}
    for _i, device in ipairs(devices) do
        table.insert(buttons, {{
            text = device.name,
            callback = function()
                UIManager:close(dialog)
                tryOn(device)
            end,
        }})
    end
    dialog = ButtonDialog:new{ title = _("Where should it play?"), buttons = buttons }
    UIManager:show(dialog)
end

--- action: "toggle", "play", "pause", "next", "previous".
-- from_gesture: no view involved, report what happened with a toast.
function KoPlay:control(action, from_gesture)
    local s = self.state
    if action == "toggle" then
        if not self.view then
            -- no polled state to go by: ask Spotify
            s = KoPlayApi:getPlayback(0)
        end
        action = (s and not s.idle and s.is_playing) and "pause" or "play"
    end
    local function report()
        if from_gesture and not self.view then
            UIManager:scheduleIn(SETTLE_DELAY, function() self:toastCurrentTrack() end)
        end
    end
    if action == "play" then
        -- resuming may need picking a device, like starting something new
        return self:startPlayback(function(device_id)
            if device_id then return KoPlayApi:play(nil, device_id) end
            return KoPlayApi:control("play")
        end, function()
            self:setPlayingLocally(true)
            report()
        end)
    end
    local ok, err = KoPlayApi:control(action)
    if not ok then
        if from_gesture then
            self:toast((self:errorLines(err)))
        else
            UIManager:show(InfoMessage:new{ text = self:errorText(err), timeout = 3 })
        end
        return
    end
    if action == "pause" then
        self:setPlayingLocally(false)
        if from_gesture and not self.view then self:toast(_("Paused")) end
    else
        report()
    end
    self:schedule(SETTLE_DELAY)
end

-- Optimistic update for play/pause so the button flips immediately
function KoPlay:setPlayingLocally(playing)
    local s = self.state
    if not self.view or not s or s.idle then return end
    if s.is_playing then
        s.progress_ms = s.progress_ms + (socket.gettime() - s.fetched_at) * 1000
    end
    s.fetched_at = socket.gettime()
    s.is_playing = playing
    self.view:update{ state = s }
    self.view:refresh(false)
end

return KoPlay
