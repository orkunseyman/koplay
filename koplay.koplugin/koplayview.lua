--[[--
Full-screen "now playing" view: big album art, title / artist / album, a progress bar
with times, and the transport buttons.

Everything is painted with Blitbuffer primitives in a single pass, so a refresh is one
static frame: no animation, which is what e-ink wants.
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local _ = require("koplayl10n")
local Screen = Device.screen

local floor = math.floor
local max = math.max
local min = math.min

local C = Blitbuffer

local KoPlayView = InputContainer:extend{
    name = "KoPlayNowPlaying",
    covers_fullscreen = true,
    state = nil,       -- normalized playback state from KoPlayApi:getPlayback()
    message = nil,     -- replaces the title when set (errors, setup hints)
    hint = nil,        -- replaces the artist line when set
    cover = nil,       -- ImageWidget, owned by us
    on_control = nil,  -- function(action)
    on_close = nil,    -- function()
    on_library = nil,  -- function()
}

-- Font:getFace() scales sizes by DPI; we lay out in device pixels, so undo that.
local function face(name, px)
    local scale = Screen:scaleBySize(1000) / 1000
    return Font:getFace(name, max(6, floor(px / scale + 0.5)))
end

local function formatTime(ms)
    local s = floor((ms or 0) / 1000)
    return string.format("%d:%02d", floor(s / 60), s % 60)
end

--- Draws text and returns its size. align: "left" (x is left edge), "center" (x is center), "right" (x is right edge)
local function drawText(bb, text, fface, x, y, opts)
    opts = opts or {}
    local tw = TextWidget:new{
        text = text,
        face = fface,
        bold = opts.bold,
        fgcolor = opts.color or C.COLOR_BLACK,
        max_width = opts.max_width,
        padding = 0,
    }
    local size = tw:getSize()
    if opts.align == "center" then
        x = x - floor(size.w / 2)
    elseif opts.align == "right" then
        x = x - size.w
    end
    tw:paintTo(bb, floor(x), floor(y))
    tw:free()
    return size
end

local function fillCircle(bb, cx, cy, r, color)
    r = floor(r)
    if r <= 0 then return end
    bb:paintCircle(floor(cx), floor(cy), r, color)
end

local function ring(bb, cx, cy, r, width, color)
    bb:paintCircle(floor(cx), floor(cy), floor(r), color, width)
end

--- Isosceles triangle in box (x, y, w, h), pointing "left" or "right".
local function fillTriangle(bb, x, y, w, h, dir, color)
    for i = 0, h - 1 do
        local t = (i + 0.5) / h
        local rw = floor(w * (1 - math.abs(2 * t - 1)) + 0.5)
        if rw > 0 then
            local rx = dir == "left" and (x + w - rw) or x
            bb:paintRect(rx, y + i, rw, 1, color)
        end
    end
end

function KoPlayView:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.hit = {}
    if Device:isTouchDevice() then
        self.ges_events = {
            Tap = { GestureRange:new{ ges = "tap", range = self.dimen } },
            Swipe = { GestureRange:new{ ges = "swipe", range = self.dimen } },
        }
    end
    if Device:hasKeys() then
        self.key_events = {
            Close = { { Device.input.group.Back } },
        }
    end
    self:computeLayout()
end

function KoPlayView:computeLayout()
    local W, H = self.dimen.w, self.dimen.h
    local L = {}
    L.pad = floor(W * 0.06)
    L.header_h = floor(H * 0.05)
    L.title_px = floor(H * 0.03)
    L.artist_px = floor(H * 0.021)
    L.album_px = floor(H * 0.019)
    L.text_h = floor((L.title_px + L.artist_px + L.album_px) * 1.4)
    L.ctrl_r = floor(W * 0.065)
    L.ctrl_h = 2 * L.ctrl_r
    local min_gap = floor(H * 0.012)
    L.bar_h = max(6, floor(H * 0.006))
    L.time_px = floor(H * 0.016)
    L.progress_h = L.bar_h + floor(L.time_px * 1.8)
    local others = L.header_h + L.text_h + L.progress_h + L.ctrl_h
    L.cover = max(0, min(W - 2 * L.pad, H - others - 6 * min_gap))
    -- spread what's left evenly between the blocks
    local gap = floor((H - others - L.cover) / 6)
    L.cover_x = floor((W - L.cover) / 2)
    L.cover_y = L.header_h + gap
    L.text_y = L.cover_y + L.cover + gap
    L.progress_y = L.text_y + L.text_h + gap
    L.ctrl_cy = L.progress_y + L.progress_h + gap + L.ctrl_r
    self.L = L
end

--- Pixel size the cover art is drawn at, so the caller can render it at that size.
function KoPlayView:getCoverSize()
    return self.L.cover
end

function KoPlayView:setCover(image_widget)
    if self.cover then self.cover:free() end
    self.cover = image_widget
end

function KoPlayView:update(fields)
    self.state = fields.state
    self.message = fields.message
    self.hint = fields.hint
end

function KoPlayView:refresh(full)
    UIManager:setDirty(self, full and "full" or "ui", self.dimen, full and self.cover ~= nil)
end

function KoPlayView:currentProgress()
    local s = self.state
    if not s or s.idle or not s.duration_ms or s.duration_ms <= 0 then
        return 0, 0
    end
    local pos = s.progress_ms
    if s.is_playing and s.fetched_at then
        pos = pos + (require("socket").gettime() - s.fetched_at) * 1000
    end
    pos = min(max(pos, 0), s.duration_ms)
    return pos, s.duration_ms
end

function KoPlayView:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    local W, H = self.dimen.w, self.dimen.h
    local L = self.L
    bb:paintRect(x, y, W, H, C.COLOR_WHITE)

    self:paintHeader(bb, x, y, W)
    -- the text and the progress bar line up with the cover's edges
    self:paintCover(bb, x + L.cover_x, y + L.cover_y, L.cover)
    self:paintTitle(bb, x + L.cover_x, y + L.text_y, L.cover)
    local pos, dur = self:currentProgress()
    self:paintProgress(bb, x + L.cover_x, y + L.progress_y, L.cover, dur > 0 and pos / dur or 0, pos, dur)
    self:paintControls(bb, x, y + L.ctrl_cy, W)
end

function KoPlayView:paintProgress(bb, x, y, w, p, pos, dur)
    local L = self.L
    local h = L.bar_h
    bb:paintRect(x, y, w, h, C.COLOR_GRAY_D)
    local fw = floor(w * p)
    if fw > 0 then
        bb:paintRect(x, y, fw, h, C.COLOR_BLACK)
    end
    fillCircle(bb, x + fw, y + h / 2, h * 1.3, C.COLOR_BLACK)
    local s = self.state
    local has_time = s and not s.idle and dur > 0
    local ty = y + h + floor(L.time_px * 0.5)
    drawText(bb, has_time and formatTime(pos) or "--:--", face("smallinfofont", L.time_px), x, ty,
        { color = C.COLOR_GRAY_3 })
    drawText(bb, has_time and formatTime(dur) or "--:--", face("smallinfofont", L.time_px), x + w, ty,
        { align = "right", color = C.COLOR_GRAY_3 })
end

function KoPlayView:paintHeader(bb, x, y, W)
    local L = self.L
    local px = floor(L.header_h * 0.42)
    local ty = y + floor((L.header_h - px * 1.4) / 2)
    local lib = drawText(bb, _("☰ Library"), face("smallinfofontbold", px), x + L.pad, ty, { bold = true })
    self.hit.library = Geom:new{ x = x, y = y, w = lib.w + 2 * L.pad, h = L.header_h }

    -- Spotify attribution + where it's playing
    local s = self.state
    local status = "Spotify"
    if s and s.device then status = status .. " · " .. s.device end
    drawText(bb, status, face("smallinfofont", px), x + W / 2, ty,
        { align = "center", color = C.COLOR_GRAY_4, max_width = floor(W * 0.4) })

    local close = drawText(bb, _("Close ×"), face("smallinfofont", px), x + W - L.pad, ty, { align = "right" })
    self.hit.close = Geom:new{ x = x + W - L.pad - close.w - L.pad, y = y, w = close.w + 2 * L.pad, h = L.header_h }
    bb:paintRect(x + L.pad, y + L.header_h - 2, W - 2 * L.pad, 2, C.COLOR_BLACK)
end

function KoPlayView:paintCover(bb, x, y, size)
    if size <= 0 then return end
    if self.cover then
        self.cover:paintTo(bb, x, y)
        bb:paintBorder(x, y, size, size, 2, C.COLOR_BLACK)
        return
    end
    -- No artwork (yet): a vinyl record placeholder
    bb:paintRect(x, y, size, size, C.COLOR_GRAY_E)
    bb:paintBorder(x, y, size, size, 2, C.COLOR_BLACK)
    local cx, cy, r = x + size / 2, y + size / 2, size * 0.42
    fillCircle(bb, cx, cy, r, C.COLOR_GRAY_2)
    for i = 1, 4 do
        ring(bb, cx, cy, r * (0.55 + i * 0.1), 1, C.COLOR_GRAY_5)
    end
    fillCircle(bb, cx, cy, r * 0.33, C.COLOR_WHITE)
    fillCircle(bb, cx, cy, r * 0.05, C.COLOR_GRAY_2)
end

--- Title, artist and album, left-aligned in a block of width w starting at x.
function KoPlayView:paintTitle(bb, x, y, w)
    local L = self.L
    local s = self.state
    local title, artist
    if self.message then
        title, artist = self.message, self.hint or ""
    elseif s and not s.idle then
        title, artist = s.title, s.artist
    else
        title, artist = _("Nothing playing right now"), _("Start something on Spotify")
    end
    drawText(bb, title, face("cfont", L.title_px), x, y, { bold = true, max_width = w })
    drawText(bb, artist, face("cfont", L.artist_px), x, y + floor(L.title_px * 1.4),
        { max_width = w, color = C.COLOR_GRAY_3 })
    if s and not s.idle and not self.message and s.album and s.album ~= "" then
        local album = s.album
        if s.year then album = album .. " · " .. s.year end
        drawText(bb, album, face("cfont", L.album_px), x, y + floor((L.title_px + L.artist_px) * 1.4),
            { max_width = w, color = C.COLOR_GRAY_6 })
    end
end

function KoPlayView:paintControls(bb, x, cy, W)
    local L = self.L
    local r_big, r_small = L.ctrl_r, floor(L.ctrl_r * 0.75)
    local cx_prev, cx_play, cx_next = x + W * 0.25, x + W * 0.5, x + W * 0.75
    local stroke = max(2, floor(r_small * 0.06))

    -- Previous: |◀
    ring(bb, cx_prev, cy, r_small, stroke, C.COLOR_BLACK)
    local ih = floor(r_small * 0.8)
    local iw = floor(ih * 0.8)
    local bar = max(3, floor(ih * 0.14))
    local ix = floor(cx_prev - (iw + bar) / 2)
    bb:paintRect(ix, floor(cy - ih / 2), bar, ih, C.COLOR_BLACK)
    fillTriangle(bb, ix + bar, floor(cy - ih / 2), iw, ih, "left", C.COLOR_BLACK)

    -- Next: ▶|
    ring(bb, cx_next, cy, r_small, stroke, C.COLOR_BLACK)
    ix = floor(cx_next - (iw + bar) / 2)
    fillTriangle(bb, ix, floor(cy - ih / 2), iw, ih, "right", C.COLOR_BLACK)
    bb:paintRect(ix + iw, floor(cy - ih / 2), bar, ih, C.COLOR_BLACK)

    -- Play / pause, filled
    fillCircle(bb, cx_play, cy, r_big, C.COLOR_BLACK)
    local s = self.state
    local playing = s and not s.idle and s.is_playing
    ih = floor(r_big * 0.8)
    if playing then
        local pw = floor(ih * 0.28)
        local gapw = floor(ih * 0.22)
        bb:paintRect(floor(cx_play - gapw / 2 - pw), floor(cy - ih / 2), pw, ih, C.COLOR_WHITE)
        bb:paintRect(floor(cx_play + gapw / 2), floor(cy - ih / 2), pw, ih, C.COLOR_WHITE)
    else
        iw = floor(ih * 0.85)
        -- optical centering: shift right a bit
        fillTriangle(bb, floor(cx_play - iw / 2 + iw * 0.1), floor(cy - ih / 2), iw, ih, "right", C.COLOR_WHITE)
    end

    local function box(cx, r)
        local m = floor(r * 0.4)
        return Geom:new{ x = floor(cx - r - m), y = floor(cy - r - m), w = 2 * (r + m), h = 2 * (r + m) }
    end
    self.hit.previous = box(cx_prev, r_small)
    self.hit.toggle = box(cx_play, r_big)
    self.hit.next = box(cx_next, r_small)
end

function KoPlayView:onTap(_arg, ges)
    local pos = ges.pos
    if self.hit.close and self.hit.close:contains(pos) then
        return self:onClose()
    end
    if self.hit.library and self.hit.library:contains(pos) then
        if self.on_library then self.on_library() end
        return true
    end
    for _i, action in ipairs{ "previous", "toggle", "next" } do
        if self.hit[action] and self.hit[action]:contains(pos) then
            if self.on_control then self.on_control(action) end
            return true
        end
    end
    return true
end

function KoPlayView:onSwipe(_arg, ges)
    if ges.direction == "south" then
        return self:onClose()
    end
    return true
end

function KoPlayView:onClose()
    UIManager:close(self)
    return true
end

function KoPlayView:onCloseWidget()
    self:setCover(nil)
    if self.on_close then self.on_close() end
    UIManager:setDirty(nil, "full")
end

return KoPlayView
