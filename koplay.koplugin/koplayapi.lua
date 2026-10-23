--[[--
Minimal Spotify Web API client: token refresh, playback state and controls, library lists.

Credentials live in <settings dir>/koplay.json, written once by tools/koplay_auth.py:
    { "client_id": "...", "refresh_token": "..." }
Spotify may rotate the refresh token on every refresh, so we write it back each time.
--]]

local DataStorage = require("datastorage")
local JSON = require("json")
local http = require("socket.http")
local logger = require("logger")
local ltn12 = require("ltn12")
local socket = require("socket")
local socketutil = require("socketutil")

local API_BASE = "https://api.spotify.com/v1"
local TOKEN_URL = "https://accounts.spotify.com/api/token"

local KoPlayApi = {
    auth_file = DataStorage:getSettingsDir() .. "/koplay.json",
    legacy_auth_file = DataStorage:getSettingsDir() .. "/spotify.json", -- from before the rename
    auth = nil,          -- { client_id, refresh_token }
    access_token = nil,
    token_expires = 0,   -- os.time() after which access_token is stale
    retry_after = 0,     -- os.time() before which we must not call the API (HTTP 429)
}

local function urlencode(str)
    return (tostring(str):gsub("[^%w%-%._~]", function(c)
        return string.format("%%%02X", string.byte(c))
    end))
end

local function isTable(v)
    return type(v) == "table"
end

local function str(v)
    return type(v) == "string" and v or nil
end

local function readJson(path)
    local f = io.open(path, "r")
    if not f then return end
    local content = f:read("*a")
    f:close()
    local ok, data = pcall(JSON.decode, content)
    if ok and isTable(data) then return data end
end

function KoPlayApi:loadAuth()
    local data = readJson(self.auth_file)
    local migrated = false
    if not data then
        data = readJson(self.legacy_auth_file)
        migrated = data ~= nil
    end
    if data and str(data.client_id) and str(data.refresh_token) then
        self.auth = data
        if migrated then
            self:saveAuth()
            os.remove(self.legacy_auth_file)
        end
        return true
    end
    logger.warn("KoPlay: no valid auth file", self.auth_file)
    return false
end

function KoPlayApi:saveAuth()
    local f = io.open(self.auth_file, "w")
    if not f then
        logger.warn("KoPlay: cannot write", self.auth_file)
        return
    end
    f:write(JSON.encode(self.auth))
    f:close()
end

function KoPlayApi:hasAuth()
    return self.auth ~= nil or self:loadAuth()
end

--- Performs an HTTP request.
-- @treturn int|nil HTTP status code (nil on network error)
-- @treturn string response body (or error message)
-- @treturn table response headers
function KoPlayApi:request(method, url, headers, body)
    local sink = {}
    headers = headers or {}
    if body then
        headers["Content-Length"] = tostring(#body)
    elseif method ~= "GET" then
        -- Spotify answers 411 to body-less PUT/POST without it
        headers["Content-Length"] = "0"
    end
    socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
    local code, resp_headers, status = socket.skip(1, http.request{
        method = method,
        url = url,
        headers = headers,
        source = body and ltn12.source.string(body) or nil,
        sink = socketutil.table_sink(sink),
    })
    socketutil:reset_timeout()
    if resp_headers == nil then
        logger.warn("KoPlay: network error", method, url, status or code)
        return nil, tostring(status or code)
    end
    return code, table.concat(sink), resp_headers
end

function KoPlayApi:refreshAccessToken()
    if not self:hasAuth() then return false, "no_auth" end
    local body = "grant_type=refresh_token"
        .. "&refresh_token=" .. urlencode(self.auth.refresh_token)
        .. "&client_id=" .. urlencode(self.auth.client_id)
    local code, content = self:request("POST", TOKEN_URL, {
        ["Content-Type"] = "application/x-www-form-urlencoded",
    }, body)
    if code ~= 200 then
        logger.warn("KoPlay: token refresh failed", code, content)
        if code == 400 or code == 401 then
            return false, "auth_revoked"
        end
        return false, "network"
    end
    local ok, data = pcall(JSON.decode, content)
    if not ok or not isTable(data) or not str(data.access_token) then
        return false, "bad_response"
    end
    self.access_token = data.access_token
    self.token_expires = os.time() + (tonumber(data.expires_in) or 3600) - 60
    if str(data.refresh_token) and data.refresh_token ~= self.auth.refresh_token then
        self.auth.refresh_token = data.refresh_token
        self:saveAuth()
    end
    return true
end

--- Calls the Web API with a valid access token, refreshing it once on 401.
-- @param body optional table, sent as JSON
-- @treturn int|nil status code
-- @treturn string|table decoded JSON body when possible, error kind otherwise
function KoPlayApi:call(method, path, body)
    if os.time() < self.retry_after then
        return nil, "rate_limited"
    end
    local payload = body and JSON.encode(body) or nil
    for attempt = 1, 2 do
        if not self.access_token or os.time() >= self.token_expires then
            local ok, err = self:refreshAccessToken()
            if not ok then return nil, err end
        end
        local headers = { ["Authorization"] = "Bearer " .. self.access_token }
        if payload then headers["Content-Type"] = "application/json" end
        local code, content, resp_headers = self:request(method, API_BASE .. path, headers, payload)
        if code == nil then
            return nil, "network"
        elseif code == 401 and attempt == 1 then
            self.access_token = nil
        elseif code == 429 then
            local wait = tonumber(resp_headers and resp_headers["retry-after"]) or 30
            self.retry_after = os.time() + wait
            return code, "rate_limited"
        else
            if content and content:sub(1, 1) == "{" then
                local ok, data = pcall(JSON.decode, content)
                if ok then return code, data end
            end
            return code, content
        end
    end
    return nil, "auth_revoked"
end

--- GET returning decoded JSON on 200, or nil plus an error kind.
function KoPlayApi:get(path)
    local code, data = self:call("GET", path)
    if code == 200 and isTable(data) then
        return data
    end
    logger.warn("KoPlay: GET failed", path, code, data)
    if code == 403 then return nil, "forbidden" end
    return nil, type(data) == "string" and data or "http_" .. tostring(code)
end

local function pickImage(images, want)
    if not isTable(images) then return nil end
    local best
    for _, img in ipairs(images) do
        if isTable(img) and str(img.url) then
            local w = tonumber(img.width) or 0
            -- Smallest image that's still at least as big as wanted, else the biggest one
            if not best
                or (w >= want and (best.w < want or w < best.w))
                or (best.w < want and w > best.w) then
                best = { url = img.url, w = w }
            end
        end
    end
    return best and best.url
end

local function artistNames(artists)
    local names = {}
    if isTable(artists) then
        for _, a in ipairs(artists) do
            if isTable(a) and str(a.name) then table.insert(names, a.name) end
        end
    end
    return table.concat(names, ", ")
end

--- Normalizes a track or episode object into { uri, title, artist, duration_ms }.
function KoPlayApi.track(item)
    if not isTable(item) or not str(item.uri) then return nil end
    return {
        uri = item.uri,
        title = str(item.name) or "",
        artist = item.type == "episode" and isTable(item.show) and str(item.show.name) or artistNames(item.artists),
        duration_ms = tonumber(item.duration_ms) or 0,
    }
end

--- Fetches the current playback state, normalized.
-- @treturn table|nil { is_playing, progress_ms, duration_ms, id, title, artist, album, cover_url, device }
--         or { idle = true } when nothing is playing
-- @treturn string error kind
function KoPlayApi:getPlayback(cover_px)
    local code, data = self:call("GET", "/me/player?additional_types=episode")
    if code == 204 then
        return { idle = true }
    elseif code ~= 200 or not isTable(data) then
        return nil, type(data) == "string" and data or "http_" .. tostring(code)
    end
    local item = data.item
    local device = isTable(data.device) and str(data.device.name) or nil
    if not isTable(item) then
        return { idle = true, device = device }
    end
    local state = {
        is_playing = data.is_playing == true,
        progress_ms = tonumber(data.progress_ms) or 0,
        duration_ms = tonumber(item.duration_ms) or 0,
        id = item.id or item.uri or item.name,
        title = str(item.name) or "",
        device = device,
        fetched_at = socket.gettime(),
    }
    if item.type == "episode" then
        state.artist = isTable(item.show) and str(item.show.name) or ""
        state.cover_url = pickImage(item.images, cover_px) or (isTable(item.show) and pickImage(item.show.images, cover_px))
    else
        state.artist = artistNames(item.artists)
        if isTable(item.album) then
            state.album = str(item.album.name) or ""
            state.year = str(item.album.release_date) and item.album.release_date:sub(1, 4) or nil
            state.cover_url = pickImage(item.album.images, cover_px)
        end
    end
    return state
end

local function controlResult(code, data, what)
    if code and code >= 200 and code < 300 then
        return true
    end
    logger.warn("KoPlay: command failed", what, code, data)
    if code == 404 then return false, "no_device" end
    if code == 403 then return false, "forbidden" end
    return false, type(data) == "string" and data or "http_" .. tostring(code)
end

--- Playback control (requires Premium). action: "play", "pause", "next", "previous"
function KoPlayApi:control(action)
    local method = (action == "play" or action == "pause") and "PUT" or "POST"
    local code, data = self:call(method, "/me/player/" .. action)
    return controlResult(code, data, action)
end

--- Starts playback of something. what: { context_uri = ..., offset = { uri = ... } } or { uris = {...}, offset = { position = n } }
function KoPlayApi:play(what, device_id)
    local path = "/me/player/play"
    if device_id then path = path .. "?device_id=" .. urlencode(device_id) end
    local code, data = self:call("PUT", path, what)
    return controlResult(code, data, "play")
end

function KoPlayApi:addToQueue(uri, device_id)
    local path = "/me/player/queue?uri=" .. urlencode(uri)
    if device_id then path = path .. "&device_id=" .. urlencode(device_id) end
    local code, data = self:call("POST", path)
    return controlResult(code, data, "queue")
end

function KoPlayApi:getDevices()
    local data, err = self:get("/me/player/devices")
    if not data then return nil, err end
    local devices = {}
    for _, d in ipairs(isTable(data.devices) and data.devices or {}) do
        if isTable(d) and str(d.id) and not d.is_restricted then
            table.insert(devices, { id = d.id, name = str(d.name) or "?", type = str(d.type), is_active = d.is_active == true })
        end
    end
    return devices
end

--- One page of a paged list. Returns { items = {...}, next_offset = n|nil }
local function page(data, offset, convert)
    local items = {}
    for _, entry in ipairs(isTable(data.items) and data.items or {}) do
        local item = convert(entry)
        if item then table.insert(items, item) end
    end
    local next_offset
    if str(data.next) then
        next_offset = offset + #(isTable(data.items) and data.items or {})
    end
    return { items = items, next_offset = next_offset }
end

function KoPlayApi:getPlaylists(offset)
    offset = offset or 0
    local data, err = self:get("/me/playlists?limit=50&offset=" .. offset)
    if not data then return nil, err end
    return page(data, offset, function(p)
        if not isTable(p) or not str(p.uri) then return nil end
        -- Feb 2026 API renamed playlist.tracks to playlist.items
        local count = isTable(p.items) and p.items.total or isTable(p.tracks) and p.tracks.total
        return { id = p.id, uri = p.uri, name = str(p.name) or "", total = tonumber(count) }
    end)
end

function KoPlayApi:getPlaylistTracks(playlist_id, offset)
    offset = offset or 0
    local data, err = self:get("/playlists/" .. urlencode(playlist_id) .. "/items?limit=50&offset=" .. offset)
    if not data then return nil, err end
    return page(data, offset, function(e)
        return isTable(e) and KoPlayApi.track(e.item or e.track)
    end)
end

function KoPlayApi:getAlbumTracks(album_id, offset)
    offset = offset or 0
    local data, err = self:get("/albums/" .. urlencode(album_id) .. "/tracks?limit=50&offset=" .. offset)
    if not data then return nil, err end
    return page(data, offset, KoPlayApi.track)
end

function KoPlayApi:getLikedTracks(offset)
    offset = offset or 0
    local data, err = self:get("/me/tracks?limit=50&offset=" .. offset)
    if not data then return nil, err end
    return page(data, offset, function(e)
        return isTable(e) and KoPlayApi.track(e.track)
    end)
end

function KoPlayApi:getRecentlyPlayed()
    local data, err = self:get("/me/player/recently-played?limit=50")
    if not data then return nil, err end
    return page(data, 0, function(e)
        return isTable(e) and KoPlayApi.track(e.track)
    end)
end

--- Returns { current = track|nil, items = {track...} }
function KoPlayApi:getQueue()
    local data, err = self:get("/me/player/queue")
    if not data then return nil, err end
    local items = {}
    for _, t in ipairs(isTable(data.queue) and data.queue or {}) do
        local track = KoPlayApi.track(t)
        if track then table.insert(items, track) end
    end
    return { current = KoPlayApi.track(data.currently_playing), items = items }
end

--- Search tracks, albums and playlists (Spotify caps each type at 10 results).
function KoPlayApi:search(query)
    local data, err = self:get("/search?type=track,album,playlist&limit=10&q=" .. urlencode(query))
    if not data then return nil, err end
    local result = { tracks = {}, albums = {}, playlists = {} }
    for _, t in ipairs(isTable(data.tracks) and isTable(data.tracks.items) and data.tracks.items or {}) do
        local track = KoPlayApi.track(t)
        if track then table.insert(result.tracks, track) end
    end
    for _, a in ipairs(isTable(data.albums) and isTable(data.albums.items) and data.albums.items or {}) do
        if isTable(a) and str(a.id) then
            table.insert(result.albums, { id = a.id, uri = a.uri, name = str(a.name) or "", artist = artistNames(a.artists) })
        end
    end
    -- playlist results can contain nulls
    for _, p in ipairs(isTable(data.playlists) and isTable(data.playlists.items) and data.playlists.items or {}) do
        if isTable(p) and str(p.uri) then
            table.insert(result.playlists, { id = p.id, uri = p.uri, name = str(p.name) or "" })
        end
    end
    return result
end

function KoPlayApi:download(url)
    local code, content = self:request("GET", url)
    if code == 200 and content and #content > 0 then
        return content
    end
    logger.warn("KoPlay: image download failed", url, code)
end

return KoPlayApi
