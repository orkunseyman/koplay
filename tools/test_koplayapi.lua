-- Tests for koplayapi.lua without KOReader. Run from the repo root: luajit tools/test_koplayapi.lua
-- KOReader modules are stubbed; "JSON" is Lua table literals, so no JSON library is needed.
package.path = "koplay.koplugin/?.lua;" .. package.path
local dir = os.tmpname()
os.remove(dir)
assert(os.execute("mkdir " .. dir))

local function serialize(v)
    if type(v) ~= "table" then return string.format("%q", v) end
    local parts = {}
    for k, x in pairs(v) do table.insert(parts, "[" .. serialize(k) .. "]=" .. serialize(x)) end
    return "{" .. table.concat(parts, ",") .. "}"
end
local stubs = {
    datastorage = { getSettingsDir = function() return dir end },
    json = { encode = serialize, decode = function(s) return assert((loadstring or load)("return " .. s))() end },
    ["socket.http"] = {}, ltn12 = {}, socketutil = {},
    logger = { warn = function() end },
    socket = { gettime = os.time },
}
for name, m in pairs(stubs) do package.preload[name] = function() return m end end

local Api = require("koplayapi")
local responses
Api.request = function() return (unpack or table.unpack)(table.remove(responses, 1)) end
local function writeAuth(token)
    local f = io.open(Api.auth_file, "w")
    f:write(serialize({ client_id = "cid", refresh_token = token }))
    f:close()
end

-- Recently played: Spotify's `next` is a cursor, so there must be no "Load more"
writeAuth("r1")
responses = {
    { 200, '{ access_token = "a1", expires_in = 3600 }' },
    { 200, '{ next = "https://x?before=1", items = { { track = { uri = "u1", name = "A", artists = { { name = "X" } } } } } }' },
}
local recent = assert(Api:getRecentlyPlayed())
assert(recent.next_offset == nil, "recently played offers Load more")
assert(Api.label(recent.items[1]) == "A — X" and Api.label({ title = "A", artist = "" }) == "A")

-- 401 refreshes once and retries; a rotated refresh token is saved to disk
responses = {
    { 401, "" },
    { 200, '{ access_token = "a2", refresh_token = "r2" }' },
    { 200, '{ is_playing = true, item = { id = "t", name = "T", artists = {}, album = { name = "Al", images = {'
        .. '{ url = "big", width = 640 }, { url = "mid", width = 300 }, { url = "small", width = 64 } } } } }' },
}
local state = assert(Api:getPlayback(200))
assert(state.title == "T" and state.cover_url == "mid", "wrong cover size: " .. tostring(state.cover_url))
assert(io.open(Api.auth_file):read("*a"):find('"r2"'), "rotated token not saved")
assert(not io.open(Api.auth_file .. ".tmp"), "temp file left behind")

-- A revoked login is forgotten, so a newly copied koplay.json is picked up without a restart
Api.access_token = nil
responses = { { 400, "{}" } }
local _, err = Api:getPlayback(0)
assert(err == "auth_revoked" and Api.auth == nil, "revoked auth still cached")
writeAuth("r3")
assert(Api:hasAuth() and Api.auth.refresh_token == "r3")

assert(Api.formatTime(61500) == "1:01")
os.execute("rm -r " .. dir)
print("ok")
