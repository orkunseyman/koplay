--[[--
Library browser: playlists, liked songs, search, recently played, queue.

One full-screen Menu; going into a list pushes onto menu.paths, so the Menu's own
return arrow walks back up.
--]]

local ButtonDialog = require("ui/widget/buttondialog")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local Menu = require("ui/widget/menu")
local UIManager = require("ui/uimanager")
local T = require("ffi/util").template
local _ = require("koplayl10n")

local KoPlayApi = require("koplayapi")

local KoPlayLibrary = {}

function KoPlayLibrary:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    return o
end

local function formatTime(ms)
    local s = math.floor((ms or 0) / 1000)
    return string.format("%d:%02d", math.floor(s / 60), s % 60)
end

--- Runs fn while showing a "loading" message (network calls block the UI).
local function busy(fn)
    local msg = InfoMessage:new{ text = _("Loading…") }
    UIManager:show(msg)
    UIManager:forceRePaint()
    local a, b = fn()
    UIManager:close(msg)
    return a, b
end

function KoPlayLibrary:show()
    if self.menu then return end
    self.menu = Menu:new{
        title = "KoPlay",
        item_table = self:rootItems(),
        covers_fullscreen = true,
        is_borderless = true,
        is_popout = false,
        onReturn = function() self:back() end,
        onMenuHold = function(_menu, item)
            if item.hold_callback then item.hold_callback() end
            return true
        end,
    }
    local menu = self.menu
    local onCloseWidget = menu.onCloseWidget
    menu.onCloseWidget = function(m)
        self.menu = nil
        if self.on_close then self.on_close() end
        return onCloseWidget(m)
    end
    UIManager:show(menu)
end

function KoPlayLibrary:close()
    if self.menu then UIManager:close(self.menu) end
end

function KoPlayLibrary:push(title, items)
    local menu = self.menu
    if not menu then return end
    table.insert(menu.paths, { title = menu.title, items = menu.item_table, page = menu.page })
    menu.title = title
    menu:switchItemTable(title, items)
end

function KoPlayLibrary:back()
    local menu = self.menu
    local prev = menu and table.remove(menu.paths)
    if not prev then return end
    menu.title = prev.title
    menu:switchItemTable(prev.title, prev.items, (prev.page - 1) * menu.perpage + 1)
end

function KoPlayLibrary:showError(err)
    UIManager:show(InfoMessage:new{ text = self.plugin:errorText(err) })
end

function KoPlayLibrary:rootItems()
    return {
        { text = _("Playlists"), callback = function() self:openPlaylists() end },
        { text = _("Liked Songs"), callback = function() self:openLiked() end },
        { text = _("Search"), callback = function() self:openSearch() end },
        { text = _("Recently played"), callback = function() self:openRecent() end },
        { text = _("Queue"), callback = function() self:openQueue() end },
    }
end

--- Plays something, then closes the library and shows the now playing view.
function KoPlayLibrary:play(what)
    self.plugin:startPlayback(function(device_id)
        return KoPlayApi:play(what, device_id)
    end, function() self:close() end, true)
end

function KoPlayLibrary:queue(track)
    self.plugin:startPlayback(function(device_id)
        return KoPlayApi:addToQueue(track.uri, device_id)
    end, function()
        UIManager:show(InfoMessage:new{ text = T(_("Added to queue: %1"), track.title), timeout = 2 })
    end)
end

--- Menu item for a track. play_what() returns the play request for a tap.
function KoPlayLibrary:trackItem(track, play_what)
    return {
        text = track.artist ~= "" and (track.title .. " — " .. track.artist) or track.title,
        mandatory = track.duration_ms > 0 and formatTime(track.duration_ms) or nil,
        callback = function() self:play(play_what()) end,
        hold_callback = function()
            local dialog
            dialog = ButtonDialog:new{
                title = track.title,
                buttons = {{
                    { text = _("Play"), callback = function() UIManager:close(dialog); self:play(play_what()) end },
                    { text = _("Add to queue"), callback = function() UIManager:close(dialog); self:queue(track) end },
                }},
            }
            UIManager:show(dialog)
        end,
    }
end

--- Plays the tapped track followed by the rest of the loaded list (up to 50).
local function uriWindow(tracks, index)
    local uris = {}
    for i = index, math.min(#tracks, index + 49) do
        table.insert(uris, tracks[i].uri)
    end
    return { uris = uris }
end

--- Opens a paged list. loader(offset) -> { items, next_offset } | nil, err
-- make_item(entry, all_entries, index) -> menu item. head: items shown above the list.
function KoPlayLibrary:openPaged(title, loader, make_item, head, on_error)
    local res, err = busy(function() return loader(0) end)
    if not res then
        if on_error then return on_error(err) end
        return self:showError(err)
    end
    local entries, items = {}, {}
    for _i, h in ipairs(head or {}) do table.insert(items, h) end
    if #res.items == 0 and not res.next_offset then
        table.insert(items, { text = _("(empty)"), select_enabled = false })
    end
    local function append(page)
        for _i, entry in ipairs(page.items) do
            table.insert(entries, entry)
            table.insert(items, make_item(entry, entries, #entries))
        end
        if page.next_offset then
            local more
            more = {
                text = _("Load more…"),
                callback = function()
                    local next_page, next_err = busy(function() return loader(page.next_offset) end)
                    if not next_page then return self:showError(next_err) end
                    table.remove(items) -- the "more" item itself
                    local first_new = #items + 1
                    append(next_page)
                    self.menu:switchItemTable(nil, items, first_new)
                end,
            }
            table.insert(items, more)
        end
    end
    append(res)
    self:push(title, items)
end

function KoPlayLibrary:openPlaylists()
    self:openPaged(_("Playlists"), function(offset)
        return KoPlayApi:getPlaylists(offset)
    end, function(pl)
        return {
            text = pl.name,
            mandatory = pl.total and tostring(pl.total) or nil,
            callback = function() self:openPlaylist(pl) end,
        }
    end)
end

function KoPlayLibrary:openPlaylist(pl)
    local play_all = { text = _("▶ Play all"), callback = function() self:play({ context_uri = pl.uri }) end }
    self:openPaged(pl.name, function(offset)
        return KoPlayApi:getPlaylistTracks(pl.id, offset)
    end, function(track)
        return self:trackItem(track, function()
            return { context_uri = pl.uri, offset = { uri = track.uri } }
        end)
    end, { play_all }, function(err)
        if err ~= "forbidden" then return self:showError(err) end
        -- Since Feb 2026 Spotify only lists tracks of playlists you own or collaborate on
        self:push(pl.name, {
            play_all,
            { text = _("(Someone else's playlist: tracks can't be listed)"), select_enabled = false },
        })
    end)
end

function KoPlayLibrary:openAlbum(album)
    self:openPaged(album.name, function(offset)
        return KoPlayApi:getAlbumTracks(album.id, offset)
    end, function(track)
        return self:trackItem(track, function()
            return { context_uri = album.uri, offset = { uri = track.uri } }
        end)
    end, {
        { text = _("▶ Play album"), callback = function() self:play({ context_uri = album.uri }) end },
    })
end

function KoPlayLibrary:openLiked()
    self:openPaged(_("Liked Songs"), function(offset)
        return KoPlayApi:getLikedTracks(offset)
    end, function(track, all, index)
        return self:trackItem(track, function() return uriWindow(all, index) end)
    end)
end

function KoPlayLibrary:openRecent()
    self:openPaged(_("Recently played"), function()
        return KoPlayApi:getRecentlyPlayed()
    end, function(track, all, index)
        return self:trackItem(track, function() return uriWindow(all, index) end)
    end)
end

function KoPlayLibrary:openQueue()
    local q, err = busy(function() return KoPlayApi:getQueue() end)
    if not q then return self:showError(err) end
    local items = {}
    if q.current then
        table.insert(items, { text = "▶ " .. q.current.title .. " — " .. q.current.artist, select_enabled = false })
    end
    for _i, track in ipairs(q.items) do
        table.insert(items, {
            text = track.artist ~= "" and (track.title .. " — " .. track.artist) or track.title,
            mandatory = formatTime(track.duration_ms),
            select_enabled = false,
        })
    end
    if #items == 0 then
        table.insert(items, { text = _("Nothing in the queue"), select_enabled = false })
    end
    self:push(_("Queue"), items)
end

function KoPlayLibrary:openSearch()
    local dialog
    dialog = InputDialog:new{
        title = _("Search Spotify"),
        input = self.last_query or "",
        input_hint = _("Song, album, playlist"),
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            {
                text = _("Search"),
                is_enter_default = true,
                callback = function()
                    local query = dialog:getInputText()
                    UIManager:close(dialog)
                    if query and query:match("%S") then
                        self.last_query = query
                        self:showSearchResults(query)
                    end
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function KoPlayLibrary:showSearchResults(query)
    local res, err = busy(function() return KoPlayApi:search(query) end)
    if not res then return self:showError(err) end
    local items = {}
    for _i, track in ipairs(res.tracks) do
        table.insert(items, self:trackItem(track, function() return { uris = { track.uri } } end))
    end
    for _i, album in ipairs(res.albums) do
        table.insert(items, {
            text = T(_("Album: %1"), album.name .. (album.artist ~= "" and (" — " .. album.artist) or "")),
            callback = function() self:openAlbum(album) end,
        })
    end
    for _i, pl in ipairs(res.playlists) do
        table.insert(items, {
            text = T(_("Playlist: %1"), pl.name),
            callback = function() self:openPlaylist(pl) end,
        })
    end
    if #items == 0 then
        table.insert(items, { text = _("No results"), select_enabled = false })
    end
    self:push(T("“%1”", query), items)
end

return KoPlayLibrary
