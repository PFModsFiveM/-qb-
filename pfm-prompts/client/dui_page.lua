-- Copyright (c) 2026 Whippy, from WHIP, LGPL-3.0; modified for PF.
-- (WHIP whip_core/client/dui_page.lua, renamed: DuiPage -> PromptDui.)
--
-- ============================================
-- DUI PAGES: the prompts' screens in the world, each one browser
-- ============================================
--
-- A DUI is a whole browser: a page under html/, loaded from this resource (never the internet),
-- drawing into a texture the game can sample. The world renderer lays pieces of that texture in the
-- world with PromptQuad, so they depth-test and never lag the camera. The rules:
--
--   1. ONE BROWSER PER ATLAS, never one per prompt. Each prompt on screen is a quad drawn from its
--      cell's UVs, so the browser count does not grow with what is on screen.
--   2. A CHANGE IS A UV SWAP OR A MESSAGE, never a new browser, and a message goes only on a change.
--   3. MADE ON FIRST USE, GIVEN BACK WHEN IDLE (`idleMs`) or when the resource stops.
--
--   local page = PromptDui.new({
--       name = 'badge', url = 'badge.html', width = 4096, height = 512,
--       txd = 'pfm_prompts_badge_txd', tex = 'badge',
--       idleMs = 60000,                        -- optional
--       setup  = function() return {...} end,  -- optional: sent first once it is up
--       again  = { 500, 1500 },                -- optional: setup sent again this long after it is up
--       without = 'prompts will not draw',     -- the refusal print's words; quiet = true prints nothing
--   })
--
--   page:ensure()       made now if it is not; false, why: the game refused it (asked once only)
--   page:used()         drawn from this frame
--   page:up()           made, and the page is listening
--   page:send(msg, key) a table (sent as JSON) or a JSON string; queued until up (same key replaces)
--   page:exists()       a browser is held
--   page:release()      given back now

PromptDui = {}

local Page = {}
Page.__index = Page

-- A page that never says it is available counts as up after this long.
local UP_WAIT_MS = 10000
local UP_POLL_MS = 50

--- [page] = true while it holds a browser: the resource's stop gives every one back.
local live = {}

local function asked(v)
    if type(v) == 'function' then return v() end
    return v
end

local function urlOf(u)
    u = asked(u)
    if u:find('://', 1, true) then return u end
    return ('nui://%s/html/%s'):format(GetCurrentResourceName(), u)
end

local function sendNow(p, msg)
    if msg == nil or not p.dui then return end
    SendDuiMessage(p.dui, type(msg) == 'string' and msg or json.encode(msg))
end

--- Run one of the owner's hooks; a broken one is printed, never left to stop the page.
local function hook(p, fn, ...)
    if not fn then return nil end
    local ok, res = pcall(fn, ...)
    if not ok then
        print(('[pfm-prompts:%s] %s'):format(p.name, tostring(res)))
        return nil
    end
    return res
end

local function idleOf(p)
    local ms = asked(p.opts.idleMs)
    return (type(ms) == 'number' and ms > 0) and ms or nil
end

--- The idle check: one timer per browser, run again until it has been unused for idleMs.
local function armIdle(p)
    if not p.dui or p.idleGen == p.gen then return end
    local ms = idleOf(p)
    if not ms then return end
    local gen = p.gen
    p.idleGen = gen
    local function check()
        if p.idleGen ~= gen then return end
        local idle = idleOf(p)
        if not idle then p.idleGen = nil return end
        local left = p.lastUsed + idle - GetGameTimer()
        if left <= 0 then p:release() else SetTimeout(left, check) end
    end
    SetTimeout(ms, check)
end

--- Waits for the browser to be available, then sends the setup and whatever waited.
local function waitUp(p, gen)
    CreateThread(function()
        local deadline = GetGameTimer() + UP_WAIT_MS
        while p.gen == gen and not IsDuiAvailable(p.dui) and GetGameTimer() < deadline do Wait(UP_POLL_MS) end
        if p.gen ~= gen then return end
        p.isUp = true
        local o = p.opts
        if o.setup then sendNow(p, hook(p, o.setup)) end
        local waiting = p.queue
        p.queue = {}
        for i = 1, #waiting do sendNow(p, waiting[i].msg) end
        for _, ms in ipairs(o.again or {}) do
            SetTimeout(ms, function()
                if p.gen ~= gen then return end
                if o.setup then sendNow(p, hook(p, o.setup)) end
            end)
        end
    end)
end

---@param opts table  see the header
function PromptDui.new(opts)
    return setmetatable({
        opts = opts, name = opts.name or 'dui', txd = opts.txd, tex = opts.tex,
        dui = nil, isUp = false, gen = 0, queue = {}, lastUsed = 0, idleGen = nil, failed = nil,
    }, Page)
end

---@return boolean made, string|nil why
function Page:ensure()
    self.lastUsed = GetGameTimer()
    if self.dui then
        if self.idleGen ~= self.gen then armIdle(self) end
        return true
    end
    if self.failed then return false, self.failed end
    local o = self.opts
    -- A browser bigger than the game allows throws ("Invalid Width [1, 8192]"): said to the owner.
    local made, handle = pcall(CreateDui, urlOf(o.url), asked(o.width), asked(o.height))
    if not made or not handle or handle == 0 then
        self.failed = tostring(made and 'no browser' or handle)
        if not o.quiet then
            print(('[pfm-prompts:%s] the game refused the browser, so %s: %s'):format(self.name,
                o.without or 'it will not draw', self.failed))
        end
        return false, self.failed
    end
    self.dui = handle
    self.gen = self.gen + 1
    self.isUp = false
    live[self] = true
    -- Registering the same dictionary and texture name again after a browser was given back is fine.
    CreateRuntimeTextureFromDuiHandle(CreateRuntimeTxd(self.txd), self.tex, GetDuiHandle(handle))
    waitUp(self, self.gen)
    armIdle(self)
    return true
end

function Page:used()
    self.lastUsed = GetGameTimer()
    if self.dui and self.idleGen ~= self.gen then armIdle(self) end
end

function Page:up() return self.isUp end

function Page:exists() return self.dui ~= nil end

---@param msg table|string
---@param key any|nil
function Page:send(msg, key)
    if not self.dui or msg == nil then return end
    if self.isUp then sendNow(self, msg) return end
    local waiting = self.queue
    if key ~= nil then
        for i = 1, #waiting do
            if waiting[i].key == key then waiting[i].msg = msg return end
        end
    end
    waiting[#waiting + 1] = { key = key, msg = msg }
end

function Page:release()
    if not self.dui then return end
    local handle = self.dui
    self.dui, self.isUp, self.queue, self.idleGen = nil, false, {}, nil
    self.gen = self.gen + 1
    live[self] = nil
    pcall(DestroyDui, handle)
end

--- Every browser back (the resource is stopping).
function PromptDui.releaseAll()
    for p in pairs(live) do p:release() end
end
