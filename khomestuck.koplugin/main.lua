--[[ kHomestuck: read Homestuck page by page like the website, with animated panels and
[S] animations (sound over Bluetooth through KinAMP). Sections are downloaded from the
kylep333/khomestuck-packs GitHub release into /mnt/us/homestuck/<section>/. ]]
local Blitbuffer = require("ffi/blitbuffer")
local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local Device = require("device")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local ImageWidget = require("ui/widget/imagewidget")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local InputDialog = require("ui/widget/inputdialog")
local Mupdf = require("ffi/mupdf")
local NetworkMgr = require("ui/network/manager")
local HtmlBoxWidget = require("ui/widget/htmlboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local Widget = require("ui/widget/widget")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local ffiUtil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")
local rapidjson = require("rapidjson")
local time = require("ui/time")
local util = require("util")
local zlib = require("ffi/zlib")
local ffi = require("ffi")
local C = ffi.C
require("ffi/posix_h")
local _ = require("gettext")
local T = ffiUtil.template
local Screen = Device.screen

local ROOT = "/mnt/us/homestuck"
local BOOK_NAME = "khomestuck.epub" -- the library "book" that opens Homestuck (launcher/make_book.py)
local TOTAL_PAGES = 8130 -- homestuck.com numbering runs to 8130 (with six gaps)
-- a GitHub release holding index.json and one <section>.zip per act or intermission
local PACKS_URL = "https://github.com/kylep333/khomestuck-packs/releases/download/packs"
local KINAMP = "/mnt/us/KinAMP/startkinamp_koreader.sh"
local FIFO = "/tmp/kinamp_cmd"
local STATUS = "/tmp/kinamp_status"
local PLAYLIST = "/tmp/khomestuck.m3u"
local VOLUME = 60
-- shortcut: fixed guess for Bluetooth output delay, add a setting once it's measured by ear
local BT_DELAY = 0.2
local SYNC_SECONDS = 3 -- how long to force fresh KinAMP positions after audio starts
local NO_AUDIO_WAIT = 10 -- seconds before giving up on KinAMP and playing silent
local TICK = 0.04
local MEDIA_SHARE = 0.62 -- most of the screen height panels may take; the text gets the rest

local function hsNumber(pid) return tonumber(pid) - 1900 end -- homestuck.com page numbers

-- single-quotes a value for /bin/sh (Lua's %q is Lua quoting: $(...) would still run inside it)
local function sh(s) return "'" .. (tostring(s):gsub("'", "'\\''")) .. "'" end

---------- KinAMP ----------

-- Same non-blocking FIFO write kAmbience and KinAMP's own plugin use.
local function send(cmds)
    local fd = C.open(FIFO, bit.bor(C.O_WRONLY, C.O_NONBLOCK))
    if fd < 0 then return false end
    local payload = table.concat(cmds, "\n") .. "\n"
    C.write(fd, payload, #payload)
    C.close(fd)
    return true
end

local function readStatus()
    local f = io.open(STATUS)
    if not f then return {} end
    local st = {}
    for k, v in f:read("*a"):gmatch("(%w+)=([^\n]*)") do st[k] = v end
    f:close()
    return st
end

local function keepAwake(on)
    os.execute("lipc-set-prop com.lab126.powerd preventScreenSaver " .. (on and 1 or 0))
end

---------- Frames: zlib-compressed 0/255 frames back to back, offsets in the section JSON ----------

local Frames = {}
Frames.__index = Frames

function Frames.open(path, m)
    local f = io.open(path, "rb")
    if not f then return nil end
    local self = setmetatable({ f = f, m = m, size = m.w * m.h, count = #m.offsets - 1 }, Frames)
    self.bb = Blitbuffer.new(m.w, m.h, Blitbuffer.TYPE_BB8)
    return self
end

function Frames:load(i) -- 0-based
    local o = self.m.offsets
    self.f:seek("set", o[i + 1])
    ffi.copy(self.bb.data, zlib.zlib_uncompress(self.f:read(o[i + 2] - o[i + 1]), self.size), self.size)
end

function Frames:close()
    if self.f then self.f:close(); self.f = nil end
    if self.bb then self.bb:free(); self.bb = nil end
end

---------- Full-screen [S] player ----------

local Player = InputContainer:extend{ dir = nil, m = nil, on_close = nil }

function Player:init()
    self.frames = Frames.open(self.dir .. "/" .. self.m.bin, self.m)
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.ox = math.floor((self.dimen.w - self.m.w) / 2)
    self.oy = math.floor((self.dimen.h - self.m.h) / 2)
    self.region = Geom:new{ x = self.ox, y = self.oy, w = self.m.w, h = self.m.h }
    self.frames:load(0)
    self.shown = 0
    self.ges_events = { Tap = { GestureRange:new{ ges = "tap", range = self.dimen } } }
    self.tick = function() self:onTick() end
end

function Player:paintTo(bb, x, y)
    bb:paintRect(x, y, self.dimen.w, self.dimen.h, Blitbuffer.COLOR_BLACK)
    bb:blitFrom(self.frames.bb, x + self.ox, y + self.oy, 0, 0, self.m.w, self.m.h)
end

function Player:start()
    keepAwake(true)
    self.started = time.now()
    if self.m.audio then
        local m3u = io.open(PLAYLIST, "w")
        m3u:write(self.dir, "/", self.m.audio, "\n")
        m3u:close()
        -- strategy 0 = play once (kAmbience leaves it on 1, repeat)
        local cmds = { "vol " .. VOLUME, "strategy 0", "load " .. PLAYLIST, "index 0" }
        if not send(cmds) then
            os.execute("nohup " .. sh(KINAMP) .. " --idle >/dev/null 2>&1 &")
            self.pending = cmds -- resent from onTick until the daemon's pipe exists
        end
    else
        self.anchor, self.silent = self.started, true
    end
    UIManager:scheduleIn(TICK, self.tick)
end

function Player:onTick()
    local now = time.now()
    if not self.silent then
        if self.pending and send(self.pending) then self.pending = nil end
        -- KinAMP's own 1 Hz status write samples pos at a fixed phase, so the anchor would stay
        -- up to 1 s off. Forcing fresh writes for the first seconds samples every phase.
        if not self.heard or now - self.anchor < time.s(SYNC_SECONDS) then send({ "status" }) end
        local st = readStatus()
        if st.path and st.path:find(self.dir, 1, true) and st.state == "playing" then
            -- pos is truncated to whole seconds, so now - pos is a late bound on the true
            -- start; the smallest one seen so far is the tightest.
            local cand = now - time.s(tonumber(st.pos))
            self.anchor = self.anchor and math.min(self.anchor, cand) or cand
            self.heard = true
        elseif self.heard then
            -- audio ended (it can be shorter than the frames): finish the frames on the same clock
            self.silent = true
            self.anchor = self.anchor + time.s(BT_DELAY) -- keep the frame position where it was
        elseif not self.anchor and time.to_s(now - self.started) > NO_AUDIO_WAIT then
            self.anchor, self.silent = now, true -- no audio from KinAMP: play silent
        end
    end
    if self.anchor then
        local t = time.to_s(now - self.anchor) - (self.silent and 0 or BT_DELAY)
        local i = math.floor(t * self.m.fps)
        if i >= self.frames.count then return self:onClose() end
        if i > self.shown then
            self.frames:load(i) -- skips straight to the right frame when we fall behind
            self.shown = i
            UIManager:setDirty(self, "a2", self.region)
        end
    end
    UIManager:scheduleIn(TICK, self.tick)
end

function Player:onTap() return self:onClose() end

function Player:onClose()
    if self.closed then return true end -- a tap and the clip's end can both land here
    self.closed = true
    UIManager:unschedule(self.tick)
    if not self.silent then send({ "stop" }) end
    keepAwake(false)
    UIManager:close(self, "full") -- full refresh clears A2 ghosting
    if self.on_close then self.on_close() end
    return true
end

function Player:onCloseWidget()
    UIManager:unschedule(self.tick)
    self.frames:close()
end

---------- Panel: one page media item drawn from frames (animated GIF or [S] poster) ----------

local FramePanel = Widget:extend{ dir = nil, m = nil, width = nil, height = nil, show_parent = nil }

function FramePanel:init()
    self.frames = assert(Frames.open(self.dir .. "/" .. self.m.bin, self.m), "missing " .. self.m.bin)
    self.dimen = Geom:new{ w = self.width, h = self.height }
    self.idx = self.m.kind == "clip" and self.m.poster or 0
    self.frames:load(self.idx)
    self.loops = 0
    self.tick = function() self:onTick() end
end

function FramePanel:getSize() return self.dimen end

function FramePanel:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    local src = self.frames.bb
    if self.width ~= self.m.w or self.height ~= self.m.h then
        -- Multi-panel pages shrink their panels. Scale with MuPDF (C) once per frame: bb:scale is a
        -- per-pixel Lua loop, and redoing it on every repaint froze KOReader (page 89, two GIFs).
        if self.scaled_idx ~= self.idx then
            if self.scaled then self.scaled:free() end
            self.scaled = Mupdf.scaleBlitBuffer(src, self.width, self.height)
            self.scaled_idx = self.idx
        end
        src = self.scaled
    end
    bb:blitFrom(src, x, y, 0, 0, self.width, self.height)
end

function FramePanel:play()
    if self.playing or self.m.kind ~= "anim" or self.frames.count < 2 then return end
    self.playing = true
    UIManager:scheduleIn(self:duration(), self.tick)
end

function FramePanel:stop()
    self.playing = false
    UIManager:unschedule(self.tick)
end

function FramePanel:duration()
    -- e-ink can't keep up with very short GIF delays; 60 ms is about one A2 refresh
    return math.max(60, self.m.durations[self.idx + 1] or 100) / 1000
end

function FramePanel:onTick()
    if not self.playing then return end
    self.idx = (self.idx + 1) % self.frames.count
    self.frames:load(self.idx)
    self.loops = self.loops + 1
    -- setDirty repaints whole windows, so go through the page; only our rectangle is refreshed.
    -- A2 ghosts; a cleaner refresh every 40 frames keeps the panel readable.
    UIManager:setDirty(self.show_parent, self.loops % 40 == 0 and "ui" or "a2", self.dimen)
    UIManager:scheduleIn(self:duration(), self.tick)
end

function FramePanel:free()
    self:stop()
    if self.scaled then self.scaled:free(); self.scaled = nil end
    self.frames:close()
end

---------- Page view ----------

local LOG_NAMES = { TRKSTRLOG = "Tricksterlog", SRIOUSBIZ = "Serious Business" }
local function logName(log)
    return LOG_NAMES[log] or (log:sub(1, 1) .. log:sub(2):lower())
end

local function esc(s)
    return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

local CSS = [[
body { font-family: monospace; font-weight: bold; margin: 0; }
h1 { font-size: 1.1em; text-align: center; margin: 0.2em 0 0.4em 0; }
.log { border: 1px dashed black; padding: 0.3em; margin: 0.3em 0; }
.next { font-size: 1.15em; margin-top: 0.8em; }
a { color: black; }
]]

---------- MS Paint (Windows 95) style chrome: beveled buttons, checkered scroll track ----------

local BLACK, WHITE, GRAY = Blitbuffer.COLOR_BLACK, Blitbuffer.COLOR_WHITE, Blitbuffer.COLOR_GRAY

local function inside(r, x, y)
    return r and x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h
end

local SEE_THROUGH = 0.82 -- how much white covers the background picture behind see-through boxes

-- fills r with white, or nearly white so a background picture shows faintly through
local function face(bb, r, see_through)
    if see_through then
        bb:lightenRect(r.x, r.y, r.w, r.h, SEE_THROUGH)
    else
        bb:paintRect(r.x, r.y, r.w, r.h, WHITE)
    end
end

-- white face, black outline, gray shadow on the bottom and right edges
local function bevelBox(bb, r, see_through)
    local b = math.max(1, Screen:scaleBySize(1.5))
    face(bb, r, see_through)
    bb:paintBorder(r.x, r.y, r.w, r.h, b, BLACK)
    bb:paintRect(r.x + b, r.y + r.h - 2 * b, r.w - 2 * b, b, GRAY)
    bb:paintRect(r.x + r.w - 2 * b, r.y + b, b, r.h - 2 * b, GRAY)
end

local function triangle(bb, r, up)
    local th = math.floor(r.h / 3)
    local cx, top = r.x + math.floor(r.w / 2), r.y + math.floor((r.h - th) / 2)
    for i = 0, th - 1 do
        local half = math.floor((up and i or th - 1 - i) * 0.9)
        bb:paintRect(cx - half, top + i, 2 * half + 1, 1, BLACK)
    end
end

local function closeGlyph(bb, r)
    local t = math.max(2, Screen:scaleBySize(3))
    local inset = math.floor(r.w / 4)
    local n = r.w - 2 * inset
    for i = 0, n - t do
        bb:paintRect(r.x + inset + i, r.y + inset + i, t, t, BLACK)
        bb:paintRect(r.x + inset + n - t - i, r.y + inset + i, t, t, BLACK)
    end
end

-- the scroll track's sparse dot pattern, drawn once per page layout
local function checker(w, h)
    local bb = Blitbuffer.new(w, h, Blitbuffer.TYPE_BB8)
    bb:fill(WHITE)
    for y = 0, h - 1, 2 do
        for x = (y / 2) % 2, w - 1, 2 do bb:setPixel(x, y, BLACK) end
    end
    return bb
end

-- Vertical MS Paint scroll bar over a box: arrow buttons, dotted track, beveled thumb.
local ScrollBar = {}
ScrollBar.__index = ScrollBar

function ScrollBar.new(x, y, w, h)
    local self = setmetatable({}, ScrollBar)
    self.up = Geom:new{ x = x, y = y, w = w, h = w }
    self.down = Geom:new{ x = x, y = y + h - w, w = w, h = w }
    self.track = Geom:new{ x = x, y = y + w, w = w, h = h - 2 * w }
    self.track_bb = checker(w, self.track.h)
    return self
end

function ScrollBar:thumb(page, pages)
    local t = self.track
    local hh = math.max(t.w, math.floor(t.h / pages))
    local y = t.y + math.floor((t.h - hh) * (page - 1) / math.max(1, pages - 1))
    return Geom:new{ x = t.x, y = y, w = t.w, h = hh }
end

function ScrollBar:paint(bb, page, pages)
    local t = self.track
    bb:blitFrom(self.track_bb, t.x, t.y, 0, 0, t.w, t.h)
    bb:paintBorder(t.x, t.y, t.w, t.h, 1, BLACK)
    bevelBox(bb, self:thumb(page, pages))
    bevelBox(bb, self.up); triangle(bb, self.up, true)
    bevelBox(bb, self.down); triangle(bb, self.down, false)
end

-- page step for a tap at x, y (-1 up, 1 down, 0 on the thumb), nil when outside the bar
function ScrollBar:hit(x, y, page, pages)
    if inside(self.up, x, y) then return -1 end
    if inside(self.down, x, y) then return 1 end
    if inside(self.track, x, y) then
        local th = self:thumb(page, pages)
        return y < th.y and -1 or y >= th.y + th.h and 1 or 0
    end
end

function ScrollBar:free() self.track_bb:free() end

local PageView = InputContainer:extend{ app = nil, covers_fullscreen = true }

function PageView:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = self.dimen } },
        Swipe = { GestureRange:new{ ges = "swipe", range = self.dimen } },
    }
    self.turns = 0
    self.pad = Screen:scaleBySize(10)
    self.sbw = Screen:scaleBySize(22) -- scroll bar width
    local xb = Screen:scaleBySize(36)
    self.close_rect = Geom:new{ x = self.dimen.w - xb - self.pad, y = self.pad, w = xb, h = xb }
end

function PageView:setPage(sec, pid)
    self:freePanels()
    self.sec, self.pid, self.page, self.log_open = sec, pid, sec.json.pages[pid], false
    self.app:saveProgress(sec.id, pid, self.page.title)
    self:layout()
    self.turns = self.turns + 1
    -- flash every few turns to clear ghosts from panel animations (the first show refreshes itself)
    if self.turns > 1 then UIManager:setDirty(self, self.turns % 6 == 0 and "full" or "ui") end
end

function PageView:freePanels()
    for _, p in ipairs(self.panels or {}) do
        if p.free then p:free() end
    end
    self.panels = {}
    if self.text then self.text:free(); self.text = nil end
    if self.sb then self.sb:free(); self.sb = nil end
end

-- Lays the page out by hand: panels from the very top, text below, a small footer at the
-- bottom, the close button over the top-right corner, and a scroll bar only when needed.
function PageView:layout()
    local w, h, pad = self.dimen.w, self.dimen.h, self.pad
    self.footer = TextWidget:new{
        text = T("%1  ·  %2 / %3", self.sec.json.name, hsNumber(self.pid), hsNumber(self.sec.json.last)),
        face = Font:getFace("ffont", 14),
    }
    local fh = self.footer:getSize().h
    self.footer_rect = Geom:new{ x = 0, y = h - fh - pad, w = w, h = fh + pad }

    local media = {}
    for _, m in ipairs(self.page.media) do
        if m.kind ~= "none" then media[#media + 1] = m end
    end
    local total = 0
    for _, m in ipairs(media) do total = total + m.h * math.min(1, w / m.w) end
    local scale = total > 0 and math.min(1, h * MEDIA_SHARE / total) or 1
    local y = 0
    for _, m in ipairs(media) do
        local s = scale * math.min(1, w / m.w)
        local mw, mh = math.floor(m.w * s), math.floor(m.h * s)
        local panel
        if m.kind == "img" then
            panel = ImageWidget:new{ file = self.sec.dir .. "/" .. m.src, width = mw, height = mh, scale_factor = 0 }
        else
            panel = FramePanel:new{ dir = self.sec.dir, m = m, width = mw, height = mh, show_parent = self }
            if m.kind == "anim" and self.app.settings.autoplay then panel:play() end
        end
        panel.media = m
        panel.rect = Geom:new{ x = math.floor((w - mw) / 2), y = y, w = mw, h = mh }
        table.insert(self.panels, panel)
        y = y + mh
    end

    -- text area: no close button above it when there's no picture to sit on
    local top = y > 0 and y + pad or self.close_rect.y + self.close_rect.h + pad
    local th = self.footer_rect.y - top
    self.text_rect = Geom:new{ x = pad, y = top, w = w - 2 * pad, h = th }
    self.text = self:makeHtml(self.text_rect.w)
    if self.text.page_count > 1 then
        self.text:free()
        self.text_rect.w = w - 2 * pad - self.sbw - pad
        self.text = self:makeHtml(self.text_rect.w)
        self.sb = ScrollBar.new(w - pad - self.sbw, top, self.sbw, th)
    end
end

function PageView:makeHtml(width)
    local box = HtmlBoxWidget:new{ dimen = Geom:new{ w = width, h = self.text_rect.h } }
    box:setContent(self:html(), CSS, Screen:scaleBySize(17), false, nil, self.sec.dir)
    return box
end

function PageView:paintTo(bb, x, y)
    bb:paintRect(x, y, self.dimen.w, self.dimen.h, WHITE)
    for _, p in ipairs(self.panels) do p:paintTo(bb, x + p.rect.x, y + p.rect.y) end
    self.text:paintTo(bb, x + self.text_rect.x, y + self.text_rect.y)
    if self.sb then self.sb:paint(bb, self.text.page_number, self.text.page_count) end
    local fs = self.footer:getSize()
    self.footer:paintTo(bb, math.floor((self.dimen.w - fs.w) / 2), self.footer_rect.y + math.floor(self.pad / 2))
    bevelBox(bb, self.close_rect)
    closeGlyph(bb, self.close_rect)
end

function PageView:scroll(d)
    local n = self.text.page_number + d
    if n < 1 or n > self.text.page_count then return true end
    self.text:setPageNumber(n)
    self.text:freeBb()
    UIManager:setDirty(self, "ui", Geom:new{ x = 0, y = self.text_rect.y, w = self.dimen.w, h = self.text_rect.h })
    return true
end

function PageView:html()
    local p, out = self.page, {}
    out[#out + 1] = "<h1>" .. esc(p.title) .. "</h1>"
    for i, m in ipairs(p.media) do
        if m.kind == "clip" then
            out[#out + 1] = '<p><a href="play:' .. i .. '">&gt;&gt; Play animation</a></p>'
        elseif m.kind == "none" then
            out[#out + 1] = "<p><i>" .. esc(m.note) .. "</i></p>"
        end
    end
    if p.log and p.log ~= "AUTHORLOG" then
        local name = logName(p.log)
        if self.log_open then
            out[#out + 1] = '<div class="log"><a href="log:">Hide ' .. name .. "</a><br/><br/>" .. p.text .. "</div>"
        else
            out[#out + 1] = '<p><a href="log:">Show ' .. name .. "</a></p>"
        end
    else
        out[#out + 1] = "<p>" .. p.text .. "</p>"
    end
    for _, n in ipairs(p.next or {}) do
        out[#out + 1] = '<p class="next">&gt; <a href="go:' .. n.id .. '">' .. esc(n.title) .. "</a></p>"
    end
    return table.concat(out)
end

function PageView:onLink(uri)
    local go = uri:match("go:(%d+)") or uri:match("page:(%d+)")
    if go then return self.app:openPage(go) end
    local play = uri:match("play:(%d+)")
    if play then return self:playClip(self.page.media[tonumber(play)]) end
    if uri:find("log:", 1, true) then
        self.log_open = not self.log_open
        self:freePanels()
        self:layout()
        UIManager:setDirty(self, "ui")
    end
end

function PageView:playClip(m)
    for _, p in ipairs(self.panels) do
        if p.stop then p:stop() end
    end
    local player = Player:new{
        dir = self.sec.dir, m = m,
        on_close = function()
            if self.app.settings.autoplay then
                for _, p in ipairs(self.panels) do
                    if p.play then p:play() end
                end
            end
            UIManager:setDirty(self, "full")
        end,
    }
    UIManager:show(player, "full")
    -- show() returns before the first paint; start on the next tick so frame 0 is up first
    UIManager:nextTick(function() player:start() end)
    return true
end

function PageView:onTap(_, ges)
    local x, y = ges.pos.x, ges.pos.y
    if inside(self.close_rect, x, y) then return self:onClose() end
    if inside(self.footer_rect, x, y) then return self.app:showPageMenu() end
    local step = self.sb and self.sb:hit(x, y, self.text.page_number, self.text.page_count)
    if step then return self:scroll(step) end
    for _, p in ipairs(self.panels) do
        if inside(p.rect, x, y) then
            if p.media.kind == "clip" then return self:playClip(p.media) end
            if p.media.kind == "anim" then
                if p.playing then p:stop() else p:play() end
                return true
            end
        end
    end
    local pos = self.text:getPosFromAbsPos(ges.pos)
    local link = pos and self.text:getLinkByPosition(pos)
    if link then
        self:onLink(link.uri or "")
        return true
    end
end

function PageView:onSwipe(_, ges)
    local p, dir = self.page, ges.direction
    if (dir == "north" or dir == "south") and inside(self.text_rect, ges.pos.x, ges.pos.y) then
        return self:scroll(dir == "north" and 1 or -1)
    end
    if dir == "west" and p.next and p.next[1] then return self.app:openPage(p.next[1].id) end
    if dir == "east" and p.prev then return self.app:openPage(p.prev) end
end

function PageView:onClose()
    UIManager:close(self, "full")
    return true
end

function PageView:onCloseWidget()
    self:freePanels()
    self.app.page_view = nil
    G_reader_settings:flush() -- keep the reading position even if KOReader later crashes
    self.app:refreshSections() -- the sections list underneath shows the new "continue" page
end

---------- Plugin: sections, downloads, settings ----------

local KHomestuck = WidgetContainer:extend{ name = "khomestuck", is_doc_only = false }

function KHomestuck:init()
    self.settings = G_reader_settings:readSetting("khomestuck", { server = PACKS_URL, autoplay = true })
    self.settings.progress = self.settings.progress or {} -- section id -> last page read there
    if self.settings.background == nil then self.settings.background = true end
    G_reader_settings:saveSetting("khomestuck", self.settings) -- edits mutate this table in place
    self.downloads = {}
    self.ui.menu:registerToMainMenu(self)
    -- ZenOS's App Launcher matches app names to SVGs in koreader/icons: give it our SBURB house
    local icon = DataStorage:getFullDataDir() .. "/icons/homestuck.svg"
    if not lfs.attributes(icon, "mode") then
        lfs.mkdir(DataStorage:getFullDataDir() .. "/icons")
        ffiUtil.copyFile(self.path .. "/homestuck.svg", icon)
    end
end

-- The Homestuck book (launcher/khomestuck.epub) was opened, from the library, "continue reading"
-- or the home screen tile: show Homestuck in its place, at the page you left off on.
function KHomestuck:onReaderReady()
    local file = self.ui.document and self.ui.document.file
    if not file or file:match("[^/]+$") ~= BOOK_NAME then return end
    self.book_mode = true
    UIManager:nextTick(function()
        self:showSections()
        local pid = self.settings.page
        local s = pid and self:sectionFor(pid)
        if s and self:installed(s.id) then self:openPage(pid) end
    end)
end

-- the book's progress bar in the library shows how far through Homestuck you are
function KHomestuck:onSaveSettings()
    if self.book_mode and self.settings.page and self.ui.doc_settings then
        self.ui.doc_settings:saveSetting("percent_finished", hsNumber(self.settings.page) / TOTAL_PAGES)
    end
end

-- leaving Homestuck closes the book too, back to the library
function KHomestuck:closeBook()
    if self.book_mode then
        self.book_mode = false
        UIManager:nextTick(function()
            -- Open the file browser in the same step, as KOReader's own "file browser" item does:
            -- started from the home screen tile there is none underneath, and closing the last
            -- window makes KOReader quit back to the Kindle.
            local file = self.ui.document and self.ui.document.file
            self.ui:onClose()
            self.ui:showFileManager(file)
        end)
    end
end

function KHomestuck:addToMainMenu(menu_items)
    menu_items.khomestuck = {
        text = _("Homestuck"),
        sorting_hint = "tools", -- top of the Tools tab, next to KinAMP Player
        callback = function() self:showSections() end,
    }
end

-- last page read overall (for Continue) and in each section (for opening that section)
function KHomestuck:saveProgress(sid, pid, title)
    self.settings.page, self.settings.page_title = pid, title
    self.settings.progress[sid] = pid
end

-- shell command that downloads url to out with fetch.lua (KOReader's HTTPS; busybox wget has none)
function KHomestuck:fetchCmd(url, out)
    return "cd " .. sh(lfs.currentdir()) .. " && ./luajit " .. sh(self.path .. "/fetch.lua") .. " " .. sh(url) .. " " .. sh(out)
end

function KHomestuck:installed(sid)
    return lfs.attributes(ROOT .. "/" .. sid .. "/.complete", "mode") == "file"
end

function KHomestuck:loadIndex()
    local ok, idx = pcall(rapidjson.load, ROOT .. "/index.json")
    self.index = {}
    -- the list comes from the network and its ids end up in file paths: keep only plain ids
    for _, s in ipairs(ok and idx and idx.sections or {}) do
        if type(s.id) == "string" and s.id:match("^[%w-]+$") then table.insert(self.index, s) end
    end
end

function KHomestuck:fetchIndex(done)
    NetworkMgr:runWhenOnline(function()
        lfs.mkdir(ROOT)
        local tmp = ROOT .. "/index.json.part"
        local ok = os.execute(self:fetchCmd(self.settings.server .. "/index.json", tmp)) == 0
        if ok and pcall(rapidjson.load, tmp) then
            os.rename(tmp, ROOT .. "/index.json")
        else
            os.remove(tmp)
            UIManager:show(InfoMessage:new{ text = T(_("Couldn't reach the server at %1"), self.settings.server) })
        end
        self:loadIndex()
        if done then done() end
    end)
end

function KHomestuck:sectionFor(pid)
    for _, s in ipairs(self.index or {}) do
        if pid >= s.first and pid <= s.last then return s end
    end
end

function KHomestuck:openSection(s)
    if self.sec and self.sec.id == s.id then return self.sec end
    local dir = ROOT .. "/" .. s.id
    local ok, json = pcall(rapidjson.load, dir .. "/section.json")
    if not ok or not json then
        UIManager:show(InfoMessage:new{ text = T(_("%1 looks damaged. Delete it and download it again."), s.name) })
        return
    end
    self.sec = { id = s.id, dir = dir, json = json }
    return self.sec
end

function KHomestuck:openPage(pid)
    if not self.index then self:loadIndex() end
    local s = self:sectionFor(pid)
    if not s then return UIManager:show(InfoMessage:new{ text = T(_("Page %1 isn't in any known section."), hsNumber(pid)) }) end
    if not self:installed(s.id) then
        return UIManager:show(InfoMessage:new{ text = T(_("Page %1 is in %2. Download it from the Homestuck sections list first."), hsNumber(pid), s.name) })
    end
    local sec = self:openSection(s)
    if not sec then return end
    if not sec.json.pages[pid] then -- one of Homestuck's six numbering gaps, e.g. 2399
        return UIManager:show(InfoMessage:new{ text = T(_("There's no page %1."), hsNumber(pid)) })
    end
    if not self.page_view then
        self.page_view = PageView:new{ app = self }
        self.page_view:setPage(sec, pid)
        UIManager:show(self.page_view, "full")
    else
        self.page_view:setPage(sec, pid)
    end
    return true
end

function KHomestuck:showPageMenu()
    local dialog
    dialog = ButtonDialog:new{
        buttons = {
            {{ text = self.settings.autoplay and _("GIF autoplay: on") or _("GIF autoplay: off"), callback = function()
                UIManager:close(dialog)
                self.settings.autoplay = not self.settings.autoplay
                for _, p in ipairs(self.page_view and self.page_view.panels or {}) do
                    if p.play then
                        if self.settings.autoplay then p:play() else p:stop() end
                    end
                end
            end }},
            {{ text = _("Go to page…"), callback = function()
                UIManager:close(dialog)
                self:askPage()
            end }},
            {{ text = _("Close Homestuck"), callback = function()
                UIManager:close(dialog)
                if self.page_view then self.page_view:onClose() end
                if self.home then self.home:onClose() end
            end }},
        },
    }
    UIManager:show(dialog)
end

function KHomestuck:askPage()
    local input
    input = InputDialog:new{
        title = _("Go to Homestuck page (1–8130)"),
        input_type = "number",
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(input) end },
            { text = _("Go"), is_enter_default = true, callback = function()
                local n = tonumber(input:getInputText())
                UIManager:close(input)
                if n then self:openPage(string.format("%06d", n + 1900)) end
            end },
        }},
    }
    UIManager:show(input)
    input:onShowKeyboard()
end

local function mb(bytes) return util.getFriendlySize(bytes) end

---------- Home: the sections window, drawn like an MS Paint (Windows 95) window ----------

local function mono(size) return Font:getFace("droid/DroidSansMono.ttf", size) end

local function text(str, face, max_w, color)
    return TextWidget:new{ text = str, face = face, bold = true, max_width = max_w, fgcolor = color or BLACK }
end

-- Windows 95 "sunken" field: dark top/left edge
local function sunken(bb, r)
    bb:paintRect(r.x, r.y, r.w, 1, Blitbuffer.COLOR_DARK_GRAY)
    bb:paintRect(r.x, r.y, 1, r.h, Blitbuffer.COLOR_DARK_GRAY)
    bb:paintRect(r.x, r.y + r.h - 1, r.w, 1, GRAY)
    bb:paintRect(r.x + r.w - 1, r.y, 1, r.h, GRAY)
end

-- MS Paint pixel-art icons, one string per row, '#' is a black pixel
local ICON_DOWNLOAD = {
    "....######....",
    "...#......#...",
    ".###......###.",
    "#............#",
    "#............#",
    ".############.",
    "......##......",
    "......##......",
    "...########...",
    "....######....",
    ".....####.....",
    "......##......",
}
local ICON_TRASH = {
    ".....####.....",
    "##############",
    ".#..........#.",
    ".#.#..##..#.#.",
    ".#.#..##..#.#.",
    ".#.#..##..#.#.",
    ".#.#..##..#.#.",
    ".#.#..##..#.#.",
    ".#..........#.",
    "..##########..",
}

-- draws a pixel-art icon centered in r, each pixel scaled up to a square
local function pixelIcon(bb, r, icon)
    local s = math.floor(math.min(r.w * 0.6 / #icon[1], r.h * 0.6 / #icon))
    local ox = r.x + math.floor((r.w - s * #icon[1]) / 2)
    local oy = r.y + math.floor((r.h - s * #icon) / 2)
    for row, line in ipairs(icon) do
        for col = 1, #line do
            if line:sub(col, col) == "#" then bb:paintRect(ox + (col - 1) * s, oy + (row - 1) * s, s, s, BLACK) end
        end
    end
end

local Home = InputContainer:extend{ app = nil, covers_fullscreen = true }

function Home:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = self.dimen } },
        Hold = { GestureRange:new{ ges = "hold", range = self.dimen } },
        Swipe = { GestureRange:new{ ges = "swipe", range = self.dimen } },
    }
    self.pad = Screen:scaleBySize(10)
    self.page = 1
    self:layout()
end

function Home:layout()
    if self.sb then self.sb:free(); self.sb = nil end
    local w, h, pad, S = self.dimen.w, self.dimen.h, self.pad, function(n) return Screen:scaleBySize(n) end
    local app = self.app
    self.title_h = S(48)
    local xb = self.title_h - S(12)
    self.close_rect = Geom:new{ x = w - xb - S(6), y = S(6), w = xb, h = xb }
    self.options_rect = Geom:new{ x = 0, y = self.title_h, w = S(140), h = S(40) }
    local y = self.title_h + self.options_rect.h + pad
    self.here = app.settings.page and app:sectionFor(app.settings.page)
    self.cont_rect = nil
    if self.here and app:installed(self.here.id) then
        self.cont_rect = Geom:new{ x = pad, y = y, w = w - 2 * pad, h = S(100) }
        y = y + self.cont_rect.h + pad
    end
    self.status_rect = Geom:new{ x = 0, y = h - S(44), w = w, h = S(44) }
    self.row_h = S(84)
    if self.bg then self.bg:free(); self.bg = nil end
    if app.settings.background then
        self.bg = ImageWidget:new{ file = app.path .. "/bg.png", width = w, height = h }
    end
    local list_h = self.status_rect.y - pad - y
    self.per_page = math.max(1, math.floor(list_h / self.row_h))
    local n = #(app.index or {})
    self.pages = math.max(1, math.ceil(n / self.per_page))
    self.page = math.min(self.page, self.pages)
    local list_w = w - 2 * pad
    if self.pages > 1 then
        local sbw = S(22)
        list_w = list_w - sbw - pad
        self.sb = ScrollBar.new(w - pad - sbw, y, sbw, self.per_page * self.row_h)
    end
    self.list = Geom:new{ x = pad, y = y, w = list_w, h = self.per_page * self.row_h }
end

function Home:rowRect(k) -- k-th visible row, 1-based
    local l = self.list
    return Geom:new{ x = l.x, y = l.y + (k - 1) * self.row_h, w = l.w, h = self.row_h - Screen:scaleBySize(6) }
end

function Home:visible()
    local first = (self.page - 1) * self.per_page
    local out = {}
    for k = 1, self.per_page do
        local s = (self.app.index or {})[first + k]
        if not s then break end
        out[k] = s
    end
    return out
end

-- the square toolbar-style button at the right end of a row (download or delete)
function Home:iconRect(r)
    local m = Screen:scaleBySize(8)
    local side = r.h - 2 * m
    return Geom:new{ x = r.x + r.w - side - m, y = r.y + m, w = side, h = side }
end

function Home:paintRow(bb, r, s)
    local app, pad = self.app, self.pad
    local current = self.here and self.here.id == s.id
    local fg = current and WHITE or BLACK
    local installed = app:installed(s.id)
    if current then
        bb:paintRect(r.x, r.y, r.w, r.h, BLACK) -- the act you're in, highlighted like a selection
    else
        -- downloaded sections let the picture show through; ones still in the cloud stay solid
        bevelBox(bb, r, self.bg ~= nil and installed)
    end
    local ir = self:iconRect(r)
    local right = ir.x - pad -- where the right-hand text ends

    -- left: name, and below it how far you are in this section
    local lx, lw = r.x + math.floor(pad * 1.5), math.floor(r.w * 0.55)
    local name = text(s.name, mono(19), lw, fg)
    local saved = app.settings.progress and app.settings.progress[s.id]
    local at, of = app:sectionPosition(s, saved or s.first)
    local sub = saved and T("page %1 / %2", at, of) or T("%1 pages", of)
    local line2 = text(sub, mono(14), lw, fg)
    local gap = math.floor((r.h - name:getSize().h - line2:getSize().h) / 3)
    name:paintTo(bb, lx, r.y + gap)
    line2:paintTo(bb, lx, r.y + 2 * gap + name:getSize().h)
    name:free(); line2:free()

    local dl = app.downloads[s.id]
    if dl then
        -- Windows 95 progress bar: a sunken box filled with blocks
        local pw, ph = Screen:scaleBySize(240), Screen:scaleBySize(26)
        local box = Geom:new{ x = r.x + r.w - pw - math.floor(pad * 1.5), y = r.y + math.floor((r.h - ph) / 2), w = pw, h = ph }
        bb:paintRect(box.x, box.y, box.w, box.h, WHITE)
        sunken(bb, box)
        local frac = math.min(1, (lfs.attributes(dl .. ".part", "size") or lfs.attributes(dl, "size") or 0) / s.size)
        local bw, bgap = Screen:scaleBySize(10), Screen:scaleBySize(3)
        for bx = box.x + bgap, box.x + math.floor((box.w - bgap) * frac) - bw, bw + bgap do
            bb:paintRect(bx, box.y + bgap, bw, box.h - 2 * bgap, BLACK)
        end
        return
    end

    -- right: size, then the download or delete button
    local size = text(s.size and mb(s.size) or "not built yet", mono(15), math.floor(r.w * 0.3), fg)
    size:paintTo(bb, right - size:getSize().w, r.y + math.floor((r.h - size:getSize().h) / 2))
    size:free()
    if s.size then
        bevelBox(bb, ir)
        pixelIcon(bb, ir, installed and ICON_TRASH or ICON_DOWNLOAD)
    end
end

function Home:paintTo(bb, x, y)
    local w, h, pad, app = self.dimen.w, self.dimen.h, self.pad, self.app
    bb:paintRect(0, 0, w, h, WHITE)
    if self.bg then self.bg:paintTo(bb, 0, 0) end -- John's room, behind everything

    -- title bar
    bb:paintRect(0, 0, w, self.title_h, BLACK)
    local title = text("Homestuck", mono(22), w - 3 * self.title_h, WHITE)
    title:paintTo(bb, math.floor(pad * 1.5), math.floor((self.title_h - title:getSize().h) / 2))
    title:free()
    bevelBox(bb, self.close_rect)
    closeGlyph(bb, self.close_rect)

    -- menu bar, with the access-key underline Windows menus had
    local o = self.options_rect
    face(bb, Geom:new{ x = 0, y = o.y, w = w, h = o.h }, self.bg ~= nil)
    local opt = text("Options", mono(17))
    local ox, oy = o.x + math.floor(pad * 1.5), o.y + math.floor((o.h - opt:getSize().h) / 2)
    opt:paintTo(bb, ox, oy)
    local first = text("O", mono(17))
    bb:paintRect(ox, oy + opt:getSize().h - Screen:scaleBySize(4), first:getSize().w, Screen:scaleBySize(2), BLACK)
    opt:free(); first:free()
    bb:paintRect(0, o.y + o.h - 1, w, 1, GRAY)

    -- continue card
    local c = self.cont_rect
    if c then
        bevelBox(bb, c, self.bg ~= nil)
        local l1 = text("> Continue reading", mono(21), c.w - 3 * pad)
        local at, of = app:sectionPosition(self.here, app.settings.page)
        local l2 = text(T("%1 · %2 / %3 · %4", self.here.name, at, of, app.settings.page_title or ""), mono(15), c.w - 3 * pad)
        local gap = math.floor((c.h - l1:getSize().h - l2:getSize().h) / 3)
        l1:paintTo(bb, c.x + math.floor(pad * 1.5), c.y + gap)
        l2:paintTo(bb, c.x + math.floor(pad * 1.5), c.y + 2 * gap + l1:getSize().h)
        l1:free(); l2:free()
    end

    -- sections
    local rows = self:visible()
    for k, s in pairs(rows) do self:paintRow(bb, self:rowRect(k), s) end
    if #(app.index or {}) == 0 then
        local l = self.list
        local msg = text("No section list yet.", mono(17), l.w)
        local msg2 = text("Turn on Wi-Fi, then tap", mono(15), l.w)
        local msg3 = text("Options > Refresh section list.", mono(15), l.w)
        msg:paintTo(bb, l.x, l.y); msg2:paintTo(bb, l.x, l.y + 2 * msg:getSize().h); msg3:paintTo(bb, l.x, l.y + 3 * msg:getSize().h)
        msg:free(); msg2:free(); msg3:free()
    end
    if self.sb then self.sb:paint(bb, self.page, self.pages) end

    -- status bar: two sunken fields
    local sr = self.status_rect
    face(bb, sr, self.bg ~= nil)
    bb:paintRect(sr.x, sr.y, sr.w, 1, GRAY)
    local fw = math.floor((w - 3 * pad) / 2)
    local pid = app.settings.page
    local fields = { self.app:freeText(), pid and T("Page %1 of %2", hsNumber(pid), TOTAL_PAGES) or "Not started" }
    for i, str in ipairs(fields) do
        local f = Geom:new{ x = pad + (i - 1) * (fw + pad), y = sr.y + Screen:scaleBySize(7), w = fw, h = sr.h - Screen:scaleBySize(14) }
        sunken(bb, f)
        local t = text(str, mono(13), f.w - pad)
        t:paintTo(bb, f.x + math.floor(pad / 2), f.y + math.floor((f.h - t:getSize().h) / 2))
        t:free()
    end
end

function Home:sectionAt(x, y)
    for k, s in pairs(self:visible()) do
        local r = self:rowRect(k)
        if inside(r, x, y) then return s, r end
    end
end

function Home:turn(d)
    local p = math.max(1, math.min(self.pages, self.page + d))
    if p ~= self.page then
        self.page = p
        UIManager:setDirty(self, "ui")
    end
    return true
end

function Home:onTap(_, ges)
    local x, y = ges.pos.x, ges.pos.y
    if inside(self.close_rect, x, y) then return self:onClose() end
    if inside(self.options_rect, x, y) then return self.app:showOptions() end
    if inside(self.cont_rect, x, y) then return self.app:openPage(self.app.settings.page) end
    local step = self.sb and self.sb:hit(x, y, self.page, self.pages)
    if step then return self:turn(step) end
    local s, r = self:sectionAt(x, y)
    if s then
        if s.size and inside(self:iconRect(r), x, y) and self.app:installed(s.id) then
            return self.app:holdSection(s) -- the trash button
        end
        return self.app:tapSection(s)
    end
end

function Home:onHold(_, ges)
    local s = self:sectionAt(ges.pos.x, ges.pos.y)
    if s then return self.app:holdSection(s) end
end

function Home:onSwipe(_, ges)
    if ges.direction == "north" then return self:turn(1) end
    if ges.direction == "south" then return self:turn(-1) end
end

function Home:refresh()
    self:layout()
    UIManager:setDirty(self, "ui")
end

function Home:onClose()
    UIManager:close(self, "full")
    self.app:closeBook()
    return true
end

function Home:onCloseWidget()
    if self.sb then self.sb:free(); self.sb = nil end
    if self.bg then self.bg:free(); self.bg = nil end
    self.app.home = nil
end

-- page number within a section and the section's page count ("46 / 248")
function KHomestuck:sectionPosition(s, pid)
    return tonumber(pid) - tonumber(s.first) + 1, s.pages or (tonumber(s.last) - tonumber(s.first) + 1)
end

function KHomestuck:freeText()
    local free = util.diskUsage("/mnt/us").available
    return free and T(_("%1 free"), mb(free)) or ""
end

function KHomestuck:showSections()
    self:loadIndex()
    if self.home then return end
    self.home = Home:new{ app = self }
    UIManager:show(self.home, "full")
    if #self.index == 0 then self:fetchIndex(function() self:refreshSections() end) end
end

function KHomestuck:refreshSections()
    if self.home then self.home:refresh() end
end

function KHomestuck:showOptions()
    local dialog
    dialog = ButtonDialog:new{
        title = _("Options"),
        buttons = {
            {{ text = _("Refresh section list"), callback = function()
                UIManager:close(dialog)
                self:fetchIndex(function() self:refreshSections() end)
            end }},
            {{ text = _("Download location…"), callback = function()
                UIManager:close(dialog)
                self:askServer()
            end }},
            {{ text = self.settings.autoplay and _("GIF autoplay: on") or _("GIF autoplay: off"), callback = function()
                UIManager:close(dialog)
                self.settings.autoplay = not self.settings.autoplay
            end }},
            {{ text = self.settings.background and _("Picture background: on") or _("Picture background: off"), callback = function()
                UIManager:close(dialog)
                self.settings.background = not self.settings.background
                self:refreshSections()
            end }},
        },
    }
    UIManager:show(dialog)
end

function KHomestuck:tapSection(s)
    if self.downloads[s.id] then return end
    if self:installed(s.id) then
        -- where you left off in this section (older versions only saved the overall page)
        local here = self.settings.page and self:sectionFor(self.settings.page)
        return self:openPage(self.settings.progress[s.id] or (here and here.id == s.id and self.settings.page) or s.first)
    end
    if not s.size then
        return UIManager:show(InfoMessage:new{ text = T(_("%1 hasn't been built yet."), s.name) })
    end
    local free = util.diskUsage("/mnt/us").available or 0
    if free < s.size * 2.1 then -- the zip and its unpacked copy exist together for a moment
        return UIManager:show(InfoMessage:new{ text = T(_("%1 needs about %2 free while downloading. Delete a section you've finished first."), s.name, mb(s.size * 2)) })
    end
    UIManager:show(ConfirmBox:new{
        text = T(_("Download %1 (%2)?"), s.name, mb(s.size)),
        ok_text = _("Download"),
        ok_callback = function() self:download(s) end,
    })
end

function KHomestuck:holdSection(s)
    if not self:installed(s.id) then return end
    UIManager:show(ConfirmBox:new{
        text = T(_("Delete %1? You can download it again later."), s.name),
        ok_text = _("Delete"),
        ok_callback = function()
            if self.sec and self.sec.id == s.id then self.sec = nil end
            ffiUtil.purgeDir(ROOT .. "/" .. s.id)
            self:refreshSections()
        end,
    })
end

function KHomestuck:download(s)
    NetworkMgr:runWhenOnline(function()
        local zip = ROOT .. "/" .. s.id .. ".zip"
        local dir = ROOT .. "/" .. s.id
        lfs.mkdir(ROOT)
        ffiUtil.purgeDir(dir) -- a half-unpacked earlier attempt
        -- create the .part now: the poller reads "no zip, no .part, not installed" as a failure
        local f = io.open(zip .. ".part", "w")
        if f then f:close() end
        -- runs in the background so the Kindle stays usable; .complete marks a finished unpack
        os.execute("(" .. self:fetchCmd(self.settings.server .. "/" .. s.id .. ".zip", zip)
            .. " && unzip -q -o " .. sh(zip) .. " -d " .. sh(ROOT) .. " && touch " .. sh(dir .. "/.complete")
            .. "; rm -f " .. sh(zip) .. " " .. sh(zip .. ".part") .. ") >/dev/null 2>&1 &")
        self.downloads[s.id] = zip
        self:pollDownloads()
    end)
end

function KHomestuck:pollDownloads()
    local changed = false
    for sid, zip in pairs(self.downloads) do
        if self:installed(sid) then
            self.downloads[sid] = nil
            changed = true
        elseif not lfs.attributes(zip, "mode") and not lfs.attributes(zip .. ".part", "mode") then
            -- both are removed after .complete is written, so both gone + no .complete = failed
            self.downloads[sid] = nil
            changed = true
            ffiUtil.purgeDir(ROOT .. "/" .. sid)
            UIManager:show(InfoMessage:new{ text = T(_("Download of %1 failed."), sid) })
        end
    end
    if changed then
        self:refreshSections()
    elseif self.home then
        -- only progress bars moved: no re-layout, and refresh just the list, not the whole screen
        UIManager:setDirty(self.home, "ui", self.home.list)
    end
    if next(self.downloads) then UIManager:scheduleIn(2, function() self:pollDownloads() end) end
end

function KHomestuck:askServer()
    local input
    input = InputDialog:new{
        title = _("Where sections download from"),
        input = self.settings.server,
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(input) end },
            { text = _("Save"), is_enter_default = true, callback = function()
                self.settings.server = input:getInputText():gsub("/+$", "")
                UIManager:close(input)
                self:fetchIndex(function() self:refreshSections() end)
            end },
        }},
    }
    UIManager:show(input)
    input:onShowKeyboard()
end

return KHomestuck
