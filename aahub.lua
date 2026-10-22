--!strict
--[[
    Anime Adventures Hub  v0.1  (core framework)
    Target executor: Real  (MCP-connected)

    Design notes baked in on purpose:
      * firesignal / Connection:Fire are SILENT NO-OPS in Real. Every "click"
        goes through Util.click, which calls the handler function behind the
        button (getconnections -> .Function) and only falls back to native
        input if there is no handler.
      * Nothing here assumes static GUI children in LevelSelectGui/MapSelectGui:
        both are built at runtime from ReplicatedStorage.src.Data.Levels.
      * Every action verifies its own result and returns ok, reason - so the
        scheduler can retry instead of assuming a click landed.
]]

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")

-- The autoexec copy is re-run by the executor on every DataModel load (including
-- the teleport into an event run), and at that moment LocalPlayer is still nil -
-- index it once and every teleport silently kills the hub.
local LP = Players.LocalPlayer
while not LP do
    task.wait(0.2)
    LP = Players.LocalPlayer
end
local PGUI = LP:WaitForChild("PlayerGui")

-- ============================================================================
-- Config
-- ============================================================================

local Config = {
    debug = true,
    notifyOnScreen = true,

    -- In-game loop -----------------------------------------------------------
    inGame = {
        autoStart = false,
        autoReplay = false,        -- off by default: enable once the flows are verified
        autoSkip = false,          -- off by default (text match is too loose to trust yet)
        autoLeaveAtWave = 0,      -- 0 = off, else return to lobby at this wave
        autoSellAtWave = 0,       -- 0 = off, else sell all placed units at this wave
        autoAbilities = false,    -- low priority per your friend's note
        startTimeout = 25,
        lobbyTimeout = 40,
    },

    -- Lobby ------------------------------------------------------------------
    lobby = {
        -- which mode the auto-joiner should cycle
        mode = "story",           -- "story" | "challenge" | "legend" | "event" | "portal" | "raid"
        stageId = "",             -- level id from ReplicatedStorage.src.Data.Levels
        difficulty = "Normal",    -- Normal | Hard | ... as the stage allows
        eventName = "",           -- April Fools / Assassin / ...
        matchmake = false,        -- cross-server matchmaking (captcha gate)
        retryDelay = 3,
        maxRetries = 6,
    },

    -- April Fools event (verified live 2026-10-22) ---------------------------
    -- Flow: request_join_lobby(event lobby) -> teleport to the event lobby ->
    -- VoteStart.Yes -> the run starts. No captcha on this path; the captcha
    -- watcher still covers the queue-based path (request_matchmaking).
    event = {
        enabled = false,           -- master switch for the auto loop
        lobby = "_lobbytemplate_event3",
        level = "april2_event",
        difficulty = "Hard",
        voteStart = true,          -- press VoteStart.Yes when it shows up
        autoPlace = true,          -- place the 6 equipped units along the path
        autoPick = true,           -- pick the roguelike card when the run asks
        placeDelay = 0.7,          -- seconds between placements (server rate limit)
        leaveAtWave = 0,           -- 0 = never; else teleport back to lobby at this wave
        leaveAfterMatch = true,    -- leave when _DATA.GameFinished flips true
        rejoinDelay = 5,           -- seconds between loop actions inside the match
        joinDelay = 8,             -- seconds between join attempts in the hub
        places = { 14229762361, 14918509670 },  -- event lobby / event run place ids
    },

    -- Macro ------------------------------------------------------------------
    macro = {
        path = "AAHub/macros",
        autoPlayOnReplay = false,
    },
}

-- ============================================================================
-- Util
-- ============================================================================

local Util = {}
local Log = {}

function Util.log(fmt, ...)
    local msg = select("#", ...) > 0 and string.format(fmt, ...) or fmt
    table.insert(Log, msg)
    if Config.debug then
        print("[AAHub] " .. msg)
    end
end

function Util.warn(msg)
    Log[#Log + 1] = "WARN " .. msg
    warn("[AAHub] " .. msg)
end

-- Resolve "QuestsUI/Main/Main/Main/QuestGroups/Buttons/story" without exploding.
function Util.find(path: string, root: Instance?): Instance?
    local node: Instance? = root or PGUI
    for part in string.gmatch(path, "[^/]+") do
        node = node and node:FindFirstChild(part)
        if not node then return nil end
    end
    return node
end

function Util.waitFor(path: string, timeout: number?, root: Instance?): Instance?
    local deadline = os.clock() + (timeout or 10)
    repeat
        local found = Util.find(path, root)
        if found then return found end
        task.wait(0.1)
    until os.clock() > deadline
    return nil
end

-- The only click primitive that actually works in Real.
-- Returns ok, detail.
function Util.click(btn: GuiButton?, root: Instance?): (boolean, string)
    if not btn then return false, "button is nil" end
    if not btn:IsA("GuiButton") then return false, "not a GuiButton" end

    local calls, errors = 0, 0
    for _, signalName in ipairs({ "Activated", "MouseButton1Click" }) do
        local sig = (btn :: any)[signalName]
        if sig then
            local okConns, conns = pcall(getconnections, sig)
            if okConns and conns then
                for _, conn in ipairs(conns) do
                    local fn = (conn :: any).Function
                    if typeof(fn) == "function" and fn ~= nil then
                        local ok, err = pcall(fn)
                        if ok then calls += 1 else errors += 1; Util.warn("handler error on " .. btn:GetFullName() .. ": " .. tostring(err)) end
                    end
                end
            end
        end
    end

    if calls == 0 then
        -- No Lua handler we can reach: fall back to native input at the button's
        -- screen position. Requires the Roblox window to be focused.
        return Util.nativeClick(btn)
    end
    return true, string.format("%d handler(s) called, %d error(s)", calls, errors)
end

function Util.isActive(): boolean
    local ok, active = pcall(function() return isrbxactive() end)
    return ok and active == true
end

function Util.nativeClick(btn: GuiButton?): (boolean, string)
    if not btn then return false, "no button" end
    if not Util.isActive() then return false, "window not focused (native input is a no-op)" end
    local pos = btn.AbsolutePosition
    local size = btn.AbsoluteSize
    local x = math.floor(pos.X + size.X / 2)
    local y = math.floor(pos.Y + size.Y / 2)
    local ok = pcall(function() (mousemoveabs :: any)(x, y) end)
    if not ok then return false, "mousemoveabs unavailable" end
    task.wait(0.05)
    local clicked = pcall(function() (mouse1click :: any)() end)
    return clicked, clicked and ("native click at " .. x .. "," .. y) or "mouse1click failed"
end

-- Wait until predicate is true. Returns ok, elapsed.
function Util.waitUntil(predicate: () -> boolean, timeout: number?, label: string?): (boolean, number)
    local t0 = os.clock()
    local limit = timeout or 10
    while os.clock() - t0 < limit do
        local ok, res = pcall(predicate)
        if ok and res then return true, os.clock() - t0 end
        task.wait(0.1)
    end
    Util.warn(string.format("timeout waiting for %s (%.1fs)", label or "condition", limit))
    return false, os.clock() - t0
end

function Util.isVisible(inst: Instance?): boolean
    if not inst then return false end
    local gui = inst :: GuiObject
    local ok, vis = pcall(function() return gui.Visible end)
    return ok and vis == true
end

-- Visible all the way up to (but not including) the ScreenGui, whose Enabled is
-- checked separately. Needed because halves of a panel keep Visible = true.
function Util.isShown(inst: Instance?): boolean
    if not inst then return false end
    local node: Instance? = inst
    while node and not node:IsA("ScreenGui") do
        if node:IsA("GuiObject") and not (node :: GuiObject).Visible then return false end
        node = node.Parent
    end
    if node and node:IsA("ScreenGui") and not (node :: ScreenGui).Enabled then return false end
    return true
end

function Util.firstVisible(parent: Instance?, names: { string }): GuiButton?
    if not parent then return nil end
    for _, name in ipairs(names) do
        local child = parent:FindFirstChild(name, true)
        if child and child:IsA("GuiButton") and Util.isVisible(child) then
            return child
        end
    end
    return nil
end

-- Every visible GuiButton under a GUI whose Text/Name matches one of the words.
function Util.findByText(root: Instance?, words: { string }): GuiButton?
    if not root then return nil end
    local lower = {}
    for _, w in ipairs(words) do lower[w] = string.lower(w) end
    for _, d in ipairs(root:GetDescendants()) do
        if d:IsA("GuiButton") and Util.isVisible(d) then
            local hay = string.lower(d.Name)
            local text = ""
            if d:IsA("TextButton") then text = string.lower(d.Text) end
            for _, w in ipairs(words) do
                local lw = string.lower(w)
                if string.find(hay, lw, 1, true) or string.find(text, lw, 1, true) then
                    return d
                end
            end
        end
    end
    return nil
end

-- ============================================================================
-- UI  (built-in Rayfield-style window - no external dependency)
-- ============================================================================
-- Left rail tabs, dark panel, toggles/steppers wired straight into Config.
-- RightShift shows/hides. Everything is created from scratch so it works with
-- no HTTP, no loadstring, and no external library.

local UI = {}
local statusLabel: TextLabel? = nil
local rootGui: ScreenGui? = nil
local window: Frame? = nil

local THEME = {
    bg = Color3.fromRGB(24, 24, 30),
    rail = Color3.fromRGB(17, 17, 22),
    panel = Color3.fromRGB(31, 31, 39),
    stroke = Color3.fromRGB(52, 52, 64),
    accent = Color3.fromRGB(123, 92, 255),
    text = Color3.fromRGB(236, 236, 245),
    sub = Color3.fromRGB(148, 148, 164),
    good = Color3.fromRGB(88, 214, 141),
    bad = Color3.fromRGB(238, 96, 96),
}

local function uiParent(): Instance
    local ok, hui = pcall(function() return (gethui :: any)() end)
    if ok and hui then return hui end
    return PGUI
end

local function hub(): any
    return (getgenv() :: any).AAHub
end

local function round(parent: Instance, r: number): UICorner
    local c = Instance.new("UICorner")
    c.CornerRadius = UDim.new(0, r)
    c.Parent = parent
    return c
end

local function outline(parent: Instance, color: Color3?): UIStroke
    local s = Instance.new("UIStroke")
    s.Color = color or THEME.stroke
    s.Thickness = 1
    s.Parent = parent
    return s
end

function UI.init()
    if not Config.notifyOnScreen then return end
    local parent = uiParent()
    local old = parent:FindFirstChild("AAHubUI")
    if old then old:Destroy() end
    local oldBar = parent:FindFirstChild("AAHubStatus")
    if oldBar then oldBar:Destroy() end

    local gui = Instance.new("ScreenGui")
    gui.Name = "AAHubUI"
    gui.ResetOnSpawn = false
    gui.IgnoreGuiInset = true
    gui.DisplayOrder = 998
    gui.Parent = parent
    rootGui = gui

    -- ------------------------------------------------------------------ window
    local win = Instance.new("Frame")
    win.Name = "Window"
    win.Size = UDim2.fromOffset(560, 428)
    win.Position = UDim2.new(0.5, -280, 0.5, -214)
    win.BackgroundColor3 = THEME.bg
    win.BorderSizePixel = 0
    win.Active = true
    win.Parent = gui
    round(win, 10)
    outline(win)
    window = win

    local top = Instance.new("Frame")
    top.Name = "TopBar"
    top.Size = UDim2.new(1, 0, 0, 38)
    top.BackgroundColor3 = THEME.rail
    top.BorderSizePixel = 0
    top.Parent = win
    round(top, 10)

    local topFix = Instance.new("Frame")           -- square off the bottom corners
    topFix.Size = UDim2.new(1, 0, 0, 12)
    topFix.Position = UDim2.new(0, 0, 1, -12)
    topFix.BackgroundColor3 = THEME.rail
    topFix.BorderSizePixel = 0
    topFix.Parent = win

    local title = Instance.new("TextLabel")
    title.Size = UDim2.new(1, -90, 1, 0)
    title.Position = UDim2.fromOffset(14, 0)
    title.BackgroundTransparency = 1
    title.Font = Enum.Font.GothamBold
    title.TextSize = 14
    title.TextColor3 = THEME.text
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.Text = "AAHub  Â·  Anime Adventures"
    title.Parent = top

    local ver = Instance.new("TextLabel")
    ver.Size = UDim2.fromOffset(120, 38)
    ver.Position = UDim2.new(1, -140, 0, 0)
    ver.BackgroundTransparency = 1
    ver.Font = Enum.Font.Gotham
    ver.TextSize = 11
    ver.TextColor3 = THEME.sub
    ver.TextXAlignment = Enum.TextXAlignment.Right
    ver.Text = "RightShift to hide"
    ver.Parent = top

    local close = Instance.new("TextButton")
    close.Size = UDim2.fromOffset(26, 26)
    close.Position = UDim2.new(1, -34, 0, 6)
    close.BackgroundColor3 = THEME.panel
    close.BorderSizePixel = 0
    close.Font = Enum.Font.GothamBold
    close.TextSize = 14
    close.TextColor3 = THEME.bad
    close.Text = "Ã—"
    close.Parent = top
    round(close, 6)
    close.MouseButton1Click:Connect(function() gui.Enabled = false end)

    -- drag
    local dragging, dragStart, startPos = false, nil, nil
    top.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            dragStart = input.Position
            startPos = win.Position
        end
    end)
    top.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = false
        end
    end)
    task.spawn(function()
        local uis = game:GetService("UserInputService")
        uis.InputChanged:Connect(function(input)
            if dragging and dragStart and startPos then
                if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
                    local delta = input.Position - dragStart
                    win.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X,
                        startPos.Y.Scale, startPos.Y.Offset + delta.Y)
                end
            end
        end)
        uis.InputBegan:Connect(function(input, gp)
            if gp then return end
            if input.KeyCode == Enum.KeyCode.RightShift then
                gui.Enabled = not gui.Enabled
            end
        end)
    end)

    -- -------------------------------------------------------------------- rail
    local rail = Instance.new("Frame")
    rail.Size = UDim2.new(0, 138, 1, -38)
    rail.Position = UDim2.fromOffset(0, 38)
    rail.BackgroundColor3 = THEME.rail
    rail.BorderSizePixel = 0
    rail.Parent = win

    local body = Instance.new("Frame")
    body.Size = UDim2.new(1, -142, 1, -76)
    body.Position = UDim2.fromOffset(140, 38)
    body.BackgroundTransparency = 1
    body.Parent = win

    local statusBar = Instance.new("Frame")
    statusBar.Size = UDim2.new(1, 0, 0, 34)
    statusBar.Position = UDim2.new(0, 0, 1, -34)
    statusBar.BackgroundColor3 = THEME.rail
    statusBar.BorderSizePixel = 0
    statusBar.Parent = win
    round(statusBar, 10)

    local statusFix = Instance.new("Frame")
    statusFix.Size = UDim2.new(1, 0, 0, 10)
    statusFix.Position = UDim2.new(0, 0, 1, -10)
    statusFix.BackgroundColor3 = THEME.rail
    statusFix.BorderSizePixel = 0
    statusFix.Parent = statusBar

    local dot = Instance.new("Frame")
    dot.Size = UDim2.fromOffset(8, 8)
    dot.Position = UDim2.new(0, 12, 0.5, -4)
    dot.BackgroundColor3 = THEME.good
    dot.BorderSizePixel = 0
    dot.Parent = statusBar
    round(dot, 8)
    UI.dot = dot

    local lbl = Instance.new("TextLabel")
    lbl.Size = UDim2.new(1, -30, 1, 0)
    lbl.Position = UDim2.fromOffset(28, 0)
    lbl.BackgroundTransparency = 1
    lbl.Font = Enum.Font.GothamMedium
    lbl.TextSize = 12
    lbl.TextColor3 = THEME.text
    lbl.TextXAlignment = Enum.TextXAlignment.Left
    lbl.Text = "idle"
    lbl.Parent = statusBar
    statusLabel = lbl

    -- ------------------------------------------------------------- components
    local function page(): ScrollingFrame
        local s = Instance.new("ScrollingFrame")
        s.Size = UDim2.fromScale(1, 1)
        s.BackgroundTransparency = 1
        s.BorderSizePixel = 0
        s.ScrollBarThickness = 3
        s.ScrollBarImageColor3 = THEME.stroke
        s.CanvasSize = UDim2.new()
        s.AutomaticCanvasSize = Enum.AutomaticSize.Y
        s.Visible = false
        s.Parent = body
        local p = Instance.new("UIPadding")
        p.PaddingLeft = UDim.new(0, 14)
        p.PaddingRight = UDim.new(0, 10)
        p.PaddingTop = UDim.new(0, 12)
        p.Parent = s
        local l = Instance.new("UIListLayout")
        l.Padding = UDim.new(0, 6)
        l.SortOrder = Enum.SortOrder.LayoutOrder
        l.Parent = s
        return s
    end

    local function heading(parent: Instance, text: string)
        local h = Instance.new("TextLabel")
        h.Size = UDim2.new(1, 0, 0, 22)
        h.BackgroundTransparency = 1
        h.Font = Enum.Font.GothamBold
        h.TextSize = 11
        h.TextColor3 = THEME.sub
        h.TextXAlignment = Enum.TextXAlignment.Left
        h.Text = string.upper(text)
        h.Parent = parent
        return h
    end

    local function row(parent: Instance): Frame
        local f = Instance.new("Frame")
        f.Size = UDim2.new(1, 0, 0, 32)
        f.BackgroundColor3 = THEME.panel
        f.BorderSizePixel = 0
        f.Parent = parent
        round(f, 6)
        return f
    end

    local function rowLabel(parent: Instance, text: string): TextLabel
        local t = Instance.new("TextLabel")
        t.Size = UDim2.new(1, -70, 1, 0)
        t.Position = UDim2.fromOffset(10, 0)
        t.BackgroundTransparency = 1
        t.Font = Enum.Font.GothamMedium
        t.TextSize = 12
        t.TextColor3 = THEME.text
        t.TextXAlignment = Enum.TextXAlignment.Left
        t.Text = text
        t.Parent = parent
        return t
    end

    local function toggle(parent: Instance, text: string, getter: () -> boolean, setter: (boolean) -> ())
        local r = row(parent)
        rowLabel(r, text)
        local pill = Instance.new("Frame")
        pill.Size = UDim2.fromOffset(40, 20)
        pill.Position = UDim2.new(1, -50, 0.5, -10)
        pill.BackgroundColor3 = getter() and THEME.accent or THEME.stroke
        pill.BorderSizePixel = 0
        pill.Parent = r
        round(pill, 10)

        local knob = Instance.new("Frame")
        knob.Size = UDim2.fromOffset(14, 14)
        knob.Position = UDim2.new(0, getter() and 23 or 3, 0.5, -7)
        knob.BackgroundColor3 = THEME.text
        knob.BorderSizePixel = 0
        knob.Parent = pill
        round(knob, 10)

        local btn = Instance.new("TextButton")
        btn.Size = UDim2.fromScale(1, 1)
        btn.BackgroundTransparency = 1
        btn.Text = ""
        btn.Parent = r
        btn.MouseButton1Click:Connect(function()
            local now = not getter()
            setter(now)
            pill.BackgroundColor3 = now and THEME.accent or THEME.stroke
            knob.Position = UDim2.new(0, now and 23 or 3, 0.5, -7)
        end)

        -- keep the visual honest when something else flips the flag
        task.spawn(function()
            while pill.Parent do
                local on = getter()
                pill.BackgroundColor3 = on and THEME.accent or THEME.stroke
                knob.Position = UDim2.new(0, on and 23 or 3, 0.5, -7)
                task.wait(1)
            end
        end)
        return r
    end

    local function stepper(parent: Instance, text: string, minV: number, maxV: number, step: number,
        getter: () -> number, setter: (number) -> ())
        local r = row(parent)
        local lbl2 = rowLabel(r, text)
        lbl2.Size = UDim2.new(1, -130, 1, 0)

        local value = Instance.new("TextLabel")
        value.Size = UDim2.fromOffset(52, 22)
        value.Position = UDim2.new(1, -124, 0.5, -11)
        value.BackgroundColor3 = THEME.bg
        value.BorderSizePixel = 0
        value.Font = Enum.Font.GothamBold
        value.TextSize = 12
        value.TextColor3 = THEME.text
        value.Text = tostring(getter())
        value.Parent = r
        round(value, 5)

        local function bump(dir: number)
            local v = math.clamp(getter() + dir * step, minV, maxV)
            setter(v)
            value.Text = tostring(v)
        end

        for _, spec in ipairs({ { "-", -66, -1 }, { "+", -12, 1 } }) do
            local b = Instance.new("TextButton")
            b.Size = UDim2.fromOffset(22, 22)
            b.Position = UDim2.new(1, spec[2], 0.5, -11)
            b.BackgroundColor3 = THEME.panel
            b.BorderSizePixel = 0
            b.Font = Enum.Font.GothamBold
            b.TextSize = 13
            b.TextColor3 = THEME.text
            b.Text = spec[1]
            b.Parent = r
            round(b, 5)
            b.MouseButton1Click:Connect(function() bump(spec[3]) end)
        end

        task.spawn(function()
            while value.Parent do
                value.Text = tostring(getter())
                task.wait(1)
            end
        end)
        return r
    end

    local function button(parent: Instance, text: string, color: Color3, onClick: () -> ())
        local b = Instance.new("TextButton")
        b.Size = UDim2.new(1, 0, 0, 30)
        b.BackgroundColor3 = color
        b.BorderSizePixel = 0
        b.Font = Enum.Font.GothamBold
        b.TextSize = 12
        b.TextColor3 = THEME.text
        b.Text = text
        b.Parent = parent
        round(b, 6)
        b.MouseButton1Click:Connect(onClick)
        return b
    end

    local function info(parent: Instance, text: string): TextLabel
        local t = Instance.new("TextLabel")
        t.Size = UDim2.new(1, 0, 0, 44)
        t.BackgroundColor3 = THEME.panel
        t.BorderSizePixel = 0
        t.Font = Enum.Font.Code
        t.TextSize = 11
        t.TextColor3 = THEME.sub
        t.TextWrapped = true
        t.TextXAlignment = Enum.TextXAlignment.Left
        t.TextYAlignment = Enum.TextYAlignment.Top
        t.Text = text
        t.Parent = parent
        round(t, 6)
        local p = Instance.new("UIPadding")
        p.PaddingLeft = UDim.new(0, 8)
        p.PaddingTop = UDim.new(0, 6)
        p.Parent = t
        return t
    end

    -- -------------------------------------------------------------------- pages
    local pages = {}
    local tabs = { { "Main", "main" }, { "Event", "event" }, { "Macro", "macro" }, { "Log", "log" } }
    local tabButtons = {}

    local function show(key: string)
        for k, p in pairs(pages) do p.Visible = (k == key) end
        for k, b in pairs(tabButtons) do
            b.BackgroundColor3 = (k == key) and THEME.accent or THEME.rail
            b.TextColor3 = (k == key) and THEME.text or THEME.sub
        end
    end

    local y = 10
    for _, t in ipairs(tabs) do
        local b = Instance.new("TextButton")
        b.Size = UDim2.new(1, -16, 0, 34)
        b.Position = UDim2.fromOffset(8, y)
        b.BackgroundColor3 = THEME.rail
        b.BorderSizePixel = 0
        b.Font = Enum.Font.GothamBold
        b.TextSize = 12
        b.TextColor3 = THEME.sub
        b.TextXAlignment = Enum.TextXAlignment.Left
        b.Text = "   " .. t[1]
        b.Parent = rail
        round(b, 6)
        b.MouseButton1Click:Connect(function() show(t[2]) end)
        tabButtons[t[2]] = b
        pages[t[2]] = page()
        y += 38
    end

    -- main page
    local main = pages.main
    heading(main, "Automation")
    toggle(main, "Auto event (join + vote + place)", function()
        return Config.event.enabled
    end, function(v)
        local h = hub(); if not h then return end
        if v then h.EventLoop.start() else h.EventLoop.stop() end
    end)
    toggle(main, "Auto place units", function()
        return Config.event.autoPlace
    end, function(v)
        Config.event.autoPlace = v
    end)
    toggle(main, "Leave when the run finishes", function()
        return Config.event.leaveAfterMatch
    end, function(v)
        Config.event.leaveAfterMatch = v
    end)
    toggle(main, "Vote start automatically", function()
        return Config.event.voteStart
    end, function(v)
        Config.event.voteStart = v
    end)

    heading(main, "Actions")
    button(main, "Join event lobby now", THEME.accent, function()
        local h = hub(); if h then h.Event.joinLobby() end
    end)
    button(main, "Place units now", THEME.panel, function()
        local h = hub(); if h then h.AutoPlace.reset(); h.AutoPlace.tick() end
    end)
    button(main, "Leave to lobby", THEME.panel, function()
        local h = hub(); if h then h.Event.leave() end
    end)

    -- event page
    local ev = pages.event
    heading(ev, "Event loop")
    toggle(ev, "Auto pick cards", function()
        return Config.event.autoPick
    end, function(v)
        Config.event.autoPick = v
    end)
    stepper(ev, "Leave at wave (0 = never)", 0, 60, 1, function()
        return Config.event.leaveAtWave
    end, function(v)
        Config.event.leaveAtWave = v
    end)
    stepper(ev, "Rejoin delay (s)", 2, 30, 1, function()
        return Config.event.rejoinDelay
    end, function(v)
        Config.event.rejoinDelay = v
    end)
    stepper(ev, "Place delay (ms x100)", 1, 30, 1, function()
        return math.floor(Config.event.placeDelay * 10)
    end, function(v)
        Config.event.placeDelay = v / 10
    end)
    heading(ev, "Live")
    local evInfo = info(ev, "...")
    task.spawn(function()
        while true do
            local h = hub()
            if h then evInfo.Text = h.Event.status() end
            task.wait(1)
        end
    end)

    -- macro page
    local mc = pages.macro
    heading(mc, "Record / play")
    toggle(mc, "Auto replay after a run", function()
        return Config.inGame.autoReplay
    end, function(v)
        Config.inGame.autoReplay = v
    end)
    toggle(mc, "Auto skip prompts", function()
        return Config.inGame.autoSkip
    end, function(v)
        Config.inGame.autoSkip = v
    end)
    button(mc, "Start recording", THEME.accent, function()
        local h = hub(); if h then h.Macro.record() end
    end)
    button(mc, "Stop recording", THEME.panel, function()
        local h = hub(); if h then h.Macro.stop() end
    end)
    button(mc, "Play last macro", THEME.panel, function()
        local h = hub(); if h then h.Macro.play() end
    end)

    -- log page
    local lg = pages.log
    heading(lg, "Console")
    local logBox = info(lg, "")
    logBox.Size = UDim2.new(1, 0, 0, 210)
    task.spawn(function()
        while true do
            local h = hub()
            if h and h.log then
                local lines = {}
                for i = math.max(1, #h.log - 13), #h.log do
                    lines[#lines + 1] = h.log[i]
                end
                logBox.Text = table.concat(lines, "\n")
            end
            task.wait(1)
        end
    end)

    show("main")
end

function UI.status(text: string)
    if UI.lastStatus == text then return end
    UI.lastStatus = text
    if statusLabel then
        statusLabel.Text = text
    end
    if UI.dot then
        local running = Config.event.enabled
        UI.dot.BackgroundColor3 = running and THEME.good or THEME.bad
    end
    Util.log("status: %s", text)
end

-- ============================================================================
-- InGame
-- ============================================================================

local InGame = {}

-- Status of the run. The server keeps `_wave_num` in Workspace for every live
-- run, so this reads the same value the HUD reads instead of guessing from text.
function InGame.getWave(): number?
    local w = workspace:FindFirstChild("_wave_num")
    if w and w:IsA("ValueBase") then
        return (w :: any).Value
    end
    return nil
end

function InGame.isInGame(): boolean
    local data = workspace:FindFirstChild("_DATA")
    local started = data and data:FindFirstChild("GameStarted")
    if started and started:IsA("BoolValue") and started.Value then
        return true
    end
    return workspace:FindFirstChild("_map") ~= nil and InGame.getWave() ~= nil
end

function InGame.isFinished(): boolean
    local data = workspace:FindFirstChild("_DATA")
    local done = data and data:FindFirstChild("GameFinished")
    return done ~= nil and done:IsA("BoolValue") and done.Value == true
end

-- Event challenges end on a results panel with a Next button; story runs have
-- Replay. Both are handled here so the auto loop does not care which mode it is.
function InGame.resultsButton(): GuiButton?
    local r = PGUI:FindFirstChild("ResultsUI")
    if not r then return nil end
    local next = r:FindFirstChild("Next", true)
    if next and next:IsA("GuiButton") and Util.isVisible(next) then return next end
    local replay = Util.findByText(r, { "replay", "next" })
    return replay
end

function InGame.start(): (boolean, string)
    local btn = Util.find("LevelSelectGui/Buttons/Start")
    if Util.isVisible(btn) then
        local ok, detail = Util.click(btn)
        UI.status("start -> " .. detail)
        return ok, detail
    end
    btn = Util.find("MapSelectGui/Buttons/Start")
    if Util.isVisible(btn) then
        local ok, detail = Util.click(btn)
        UI.status("start(map) -> " .. detail)
        return ok, detail
    end
    return false, "start button not visible"
end

function InGame.replay(): (boolean, string)
    -- Replay lives on the post-run results panel; find it by text so we do not
    -- depend on a path that changes per game mode.
    local btn = Util.findByText(PGUI, { "replay" })
    if not btn then return false, "replay button not found" end
    local ok, detail = Util.click(btn)
    UI.status("replay -> " .. detail)
    return ok, detail
end

function InGame.returnToLobby(): (boolean, string)
    local btn = Util.findByText(PGUI, { "return to lobby", "lobby", "leave" })
    if not btn then return false, "lobby button not found" end
    local ok, detail = Util.click(btn)
    UI.status("lobby -> " .. detail)
    return ok, detail
end

function InGame.autoSkip(): (boolean, string)
    local btn = Util.findByText(PGUI, { "skip" })
    if not btn then return false, "no skip prompt" end
    local ok, detail = Util.click(btn)
    UI.status("skip -> " .. detail)
    return ok, detail
end

function InGame.sellAll(): (boolean, string)
    -- Prefer the remote: it is stable across GUI layout changes.
    local rs = game:GetService("ReplicatedStorage")
    for _, name in ipairs({ "sell_units", "sell_all_units", "autosell_units" }) do
        local remote = rs:FindFirstChild(name, true)
        if remote and remote:IsA("RemoteEvent") then
            local ok, err = pcall(function() remote:FireServer() end)
            UI.status("sell via " .. name .. (ok and " ok" or (" err " .. tostring(err))))
            return ok, tostring(err or name)
        end
    end
    return false, "no sell remote found"
end

function InGame.guardWaves()
    local wave = InGame.getWave()
    if not wave then return end

    local sellAt = Config.inGame.autoSellAtWave
    if sellAt > 0 and wave >= sellAt then
        InGame.sellAll()
        Config.inGame.autoSellAtWave = 0
    end

    local leaveAt = Config.inGame.autoLeaveAtWave
    if leaveAt > 0 and wave >= leaveAt then
        InGame.returnToLobby()
        Config.inGame.autoLeaveAtWave = 0
    end

    if Config.inGame.autoSkip then
        InGame.autoSkip()
    end
end

function InGame.tick()
    if Config.inGame.autoReplay then
        local replayBtn = Util.findByText(PGUI, { "replay" })
        if replayBtn then
            InGame.replay()
            task.wait(1)
            return
        end
    end
    InGame.guardWaves()
end

-- ============================================================================
-- Lobby
-- ============================================================================

local Lobby = {}

-- v0.1: prove we can open the quest board (story/event tabs) from the lobby.
-- Stage/map/difficulty selection is added once the dynamic lists are mapped.
function Lobby.openQuests(): (boolean, string)
    local btn = Util.find("QuestsUI/Main/Main/Main/QuestGroups/Buttons/story")
    if not btn then return false, "story tab missing" end
    local ok, detail = Util.click(btn)
    UI.status("quests -> " .. detail)
    return ok, detail
end

function Lobby.openTab(kind: string): (boolean, string)
    local btn = Util.find("QuestsUI/Main/Main/Main/QuestGroups/Buttons/" .. kind)
    if not btn then return false, kind .. " tab missing" end
    local ok, detail = Util.click(btn)
    UI.status(kind .. " -> " .. detail)
    return ok, detail
end

function Lobby.tick()
    -- placeholder: auto-join sequence lands here
end

-- ============================================================================
-- Macro  (record / play)
-- ============================================================================

local Macro = {}

local recording = false
local recorded: { any } = {}
local recordStart = 0
local conns: { RBXScriptConnection } = {}

function Macro.record()
    if recording then return end
    recorded = {}
    recordStart = os.clock()
    recording = true
    UI.status("recording macro...")

    table.insert(conns, UserInputService.InputBegan:Connect(function(input, processed)
        if processed then return end
        table.insert(recorded, {
            t = os.clock() - recordStart,
            kind = "down",
            inputType = input.UserInputType.Name,
            keyCode = input.KeyCode.Name,
            pos = input.Position,
        })
    end))
    table.insert(conns, UserInputService.InputEnded:Connect(function(input, processed)
        if processed then return end
        table.insert(recorded, {
            t = os.clock() - recordStart,
            kind = "up",
            inputType = input.UserInputType.Name,
            keyCode = input.KeyCode.Name,
            pos = input.Position,
        })
    end))
end

function Macro.stop()
    if not recording then return end
    recording = false
    for _, c in ipairs(conns) do c:Disconnect() end
    conns = {}
    UI.status(string.format("macro recorded: %d events", #recorded))
    return recorded
end

function Macro.play(events: { any }?)
    local seq = events or recorded
    if #seq == 0 then return false, "nothing recorded" end
    if not Util.isActive() then return false, "focus the Roblox window to play a macro" end

    task.spawn(function()
        local t0 = os.clock()
        for _, e in ipairs(seq) do
            local wait = e.t - (os.clock() - t0)
            if wait > 0 then task.wait(wait) end
            pcall(function()
                if e.inputType == "MouseButton1" then
                    if e.kind == "down" then (mouse1press :: any)() else (mouse1release :: any)() end
                elseif e.inputType == "MouseButton2" then
                    if e.kind == "down" then (mouse2press :: any)() else (mouse2release :: any)() end
                elseif e.inputType == "Keyboard" then
                    local vk = (Enum.KeyCode[e.keyCode] :: any).Value
                    if e.kind == "down" then (keypress :: any)(vk) else (keyrelease :: any)(vk) end
                end
            end)
        end
    end)
    return true, string.format("playing %d events", #seq)
end

-- ============================================================================
-- Matchmaking  (April Fools event, verified live on 2026-10-22)
-- ============================================================================
-- The captcha is a plain TextLabel ("Captcha") inside
-- NotificationWindows.Popups.CaptchaWindow - no OCR needed. Fill TypeBox, press
-- ButtonHolder.Yes. The window is a live clone; Popups.PopupTemplate.CaptchaWindow
-- is only the template and must be ignored.

local Matchmaking = {}

Matchmaking.eventLobby = "_lobbytemplate_event3"
Matchmaking.eventLevel = "april2_event"
Matchmaking.solved = 0

function Matchmaking.captchaWindow(): GuiObject?
    local nw = PGUI:FindFirstChild("NotificationWindows")
    local popups = nw and nw:FindFirstChild("Popups")
    local win = popups and popups:FindFirstChild("CaptchaWindow")
    if win and win:IsA("GuiObject") and win.Visible then
        return win
    end
    return nil
end

function Matchmaking.solveCaptcha(): (boolean, string)
    local win = Matchmaking.captchaWindow()
    if not win then return false, "no captcha on screen" end

    local label = win:FindFirstChild("Captcha")
    local box = win:FindFirstChild("TypeBox", true)
    local holder = win:FindFirstChild("ButtonHolder")
    local submit = holder and holder:FindFirstChild("Yes")
    if not (label and box and submit) then
        return false, "captcha window structure changed"
    end

    local code = (label :: TextLabel).Text
    ;(box :: TextBox).Text = code
    task.wait(0.15)
    local ok, detail = Util.click(submit)
    Matchmaking.solved += 1
    UI.status("captcha " .. code .. (ok and " submitted" or (" failed: " .. detail)))
    return ok, code
end

-- Watches for the captcha for as long as the script runs. Cheap: one child lookup
-- per tick, and only does work when a captcha is actually up.
function Matchmaking.watchCaptchas(interval: number?)
    -- one watcher only: re-running the hub must not stack a second solver
    local prev = (getgenv() :: any).AAHubCaptchaThread
    if type(prev) == "thread" then
        pcall(task.cancel, prev)
    end
    (getgenv() :: any).AAHubCaptchaThread = task.spawn(function()
        while true do
            if Matchmaking.captchaWindow() then
                Matchmaking.solveCaptcha()
                task.wait(1.2)
            else
                task.wait(interval or 0.35)
            end
        end
    end)
end

function Matchmaking.isQueued(): boolean
    local mm = PGUI:FindFirstChild("MatchmakingUI")
    return mm ~= nil and (mm :: ScreenGui).Enabled == true
end

function Matchmaking.status(): string
    local mm = PGUI:FindFirstChild("MatchmakingUI")
    if not mm then return "no matchmaking ui" end
    local s = mm:FindFirstChild("Status")
    local e = mm:FindFirstChild("ElapsedTime")
    return string.format("%s %s", s and (s :: TextLabel).Text or "?",
        e and (e :: TextLabel).Text or "")
end

-- The event card in ContractsUI. This is the same button a human presses: it opens
-- the matchmaking popup, and the popup's own handler invokes request_matchmaking.
function Matchmaking.eventContractButton(): GuiButton?
    local c = PGUI:FindFirstChild("ContractsUI")
    if not c then return nil end
    for _, d in ipairs(c:GetDescendants()) do
        if d:IsA("GuiButton") and d.Name == "Matchmaking" and Util.isVisible(d) then
            return d
        end
    end
    return nil
end

function Matchmaking.joinEvent(): (boolean, string)
    local btn = Matchmaking.eventContractButton()
    if not btn then return false, "event contract Matchmaking button not visible" end
    local ok, detail = Util.click(btn)
    UI.status("event matchmaking -> " .. detail)
    return ok, detail
end

-- Raw fallback: the exact remotes the client uses itself.
function Matchmaking.invoke(kind: string, ...): (boolean, any)
    local rs = game:GetService("ReplicatedStorage")
    local c2s = rs:FindFirstChild("endpoints") and rs.endpoints:FindFirstChild("client_to_server")
    local remote = c2s and c2s:FindFirstChild(kind)
    if not remote then return false, "remote " .. kind .. " missing" end
    local args = table.pack(...)
    local ok, res = pcall(function()
        return (remote :: any):InvokeServer(table.unpack(args, 1, args.n))
    end)
    return ok, res
end


-- ============================================================================
-- AutoPick  (roguelike "Choose a card!" prompt)
-- ============================================================================
-- The run stalls until a card is picked: RoguelikeSelect.Main.Main.Items holds
-- OptionFrame{Button, Confirm} per card. Select one, then Confirm.

local AutoPick = {
    lastAction = 0,
    picks = 0,
    prefer = "AprilCoins",     -- pick the card with the best AprilCoins bonus
}

function AutoPick.prompt(): Instance?
    local rs = PGUI:FindFirstChild("RoguelikeSelect")
    if not rs then return nil end
    if rs:IsA("ScreenGui") and not (rs :: ScreenGui).Enabled then return nil end
    return rs
end

local function onScreen(g: GuiObject): boolean
    local p = g.AbsolutePosition
    local s = g.AbsoluteSize
    local vp = workspace.CurrentCamera and workspace.CurrentCamera.ViewportSize or Vector2.new(1920, 1080)
    return p.X >= 0 and p.Y >= 0 and (p.X + s.X) <= vp.X and (p.Y + s.Y) <= vp.Y
end

local function bestOption(root: Instance): GuiButton?
    local best, bestScore = nil, -math.huge
    for _, frame in ipairs(root:GetDescendants()) do
        if frame:IsA("GuiObject") and frame.Name == "OptionFrame" then
            local btn = frame:FindFirstChild("Button")
            if btn and btn:IsA("GuiButton") and Util.isShown(btn) and onScreen(btn) then
                local score = 0
                for _, d in ipairs(frame:GetDescendants()) do
                    if d:IsA("TextLabel") and string.find(d.Text, AutoPick.prefer, 1, true) then
                        local n = string.match(d.Text, "(%d+)%%")
                        score = n and tonumber(n) or 1
                    end
                end
                if score > bestScore then best, bestScore = btn, score end
            end
        end
    end
    return best
end

function AutoPick.tick()
    if not Config.event.autoPick then return end
    local root = AutoPick.prompt()
    if not root then return end
    local now = os.clock()
    if now - AutoPick.lastAction < 0.6 then return end

    -- a card is already selected -> confirm it
    for _, d in ipairs(root:GetDescendants()) do
        if d:IsA("GuiButton") and d.Name == "Confirm" and Util.isShown(d) and onScreen(d) then
            AutoPick.lastAction = now
            Util.click(d)
            AutoPick.picks += 1
            UI.status("card confirmed (" .. AutoPick.picks .. ")")
            return
        end
    end

    local opt = bestOption(root)
    if opt then
        AutoPick.lastAction = now
        Util.click(opt)
        UI.status("card picked")
    end
end


-- ============================================================================
-- AutoPlace  (verified live 2026-10-22)
-- ============================================================================
-- The 6 unit slots are spawn_units.Lives.Frame.Units.1..6 and each button carries
-- the equipped unit's uuid in its `_equipped_frame_unit_uuid` attribute. The game
-- itself places with spawn_unit(uuid, CFrame) - a Vector3 is rejected server side
-- ("LookVector is not a valid member of Vector3"), so always pass a CFrame.

local AutoPlace = {
    placed = {},        -- button name -> true, only after the unit is on the map
    tries = {},         -- button name -> attempt count
    skipped = {},       -- button name -> true after giving up for this run
    fails = 0,
    lastPlace = 0,
    lastCashWarn = 0,
    done = false,
}

function AutoPlace.buttons(): { GuiButton }
    local frame = Util.find("spawn_units/Lives/Frame/Units")
    if not frame then return {} end
    local out = {}
    for _, c in ipairs(frame:GetChildren()) do
        if c:IsA("GuiButton") then
            table.insert(out, c)
        end
    end
    table.sort(out, function(a, b)
        return (tonumber(a.Name) or 99) < (tonumber(b.Name) or 99)
    end)
    return out
end

function AutoPlace.uuidOf(btn: GuiButton): any
    for k, v in pairs(btn:GetAttributes()) do
        if k == "_equipped_frame_unit_uuid" then return v end
    end
    return nil
end

-- The exact ground beside the path, where the game actually accepts a unit.
-- Verified live 2026-10-22:
--   * spawn_unit(uuid, CFrame) IS the placement call, and it is accepted when
--     the CFrame sits on the ground *beside* the route (cash drops by the price).
--   * the server silently drops a spot over the path itself, a spot floating
--     above the ground (+1 stud already fails) or a spot far from the map.
-- So: walk perpendicular from the road centre, raycast straight down and keep
-- the exact hit position. Several radii per side give the retry loop somewhere
-- else to try when a neighbour already occupies a spot.
-- One shared RaycastParams, created with the rest of the module: creating an
-- Instance from inside the scheduler thread intermittently fails with
-- "cannot access 'Instance' (lacking capability Plugin)" and silently kills a
-- placement tick.
local RayParams = RaycastParams.new()
RayParams.FilterType = Enum.RaycastFilterType.Exclude

function AutoPlace.candidates(index: number, total: number): { CFrame }
    local road = workspace:FindFirstChild("_road")
    if not road then return {} end
    local parts = {}
    for _, p in ipairs(road:GetChildren()) do
        if p:IsA("BasePart") then table.insert(parts, p) end
    end
    if #parts == 0 then return {} end
    table.sort(parts, function(a, b) return a.Position.Z < b.Position.Z end)

    local exclude = {}
    local units = workspace:FindFirstChild("_UNITS")
    if units then table.insert(exclude, units) end
    if LP.Character then table.insert(exclude, LP.Character) end
    RayParams.FilterDescendantsInstances = exclude

    local out = {}
    local seen = {}
    local function push(cf: CFrame)
        local key = string.format("%.0f:%.0f:%.0f", cf.X, cf.Y, cf.Z)
        if not seen[key] then
            seen[key] = true
            table.insert(out, cf)
        end
    end

    -- the slot's own stretch of the route first, then the whole route: a slot whose
    -- neighbourhood is already crowded still finds ground, and the map itself
    -- changes between runs (bridges, upper decks) so every stretch is a candidate.
    local baseIdx = math.clamp(math.floor(((index - 0.5) / math.max(1, total)) * #parts) + 1, 1, #parts)
    local order = {}
    for step = 0, #parts - 1 do
        order[#order + 1] = ((baseIdx - 1 + step) % #parts) + 1
    end
    local limit = math.min(#order, 8)

    -- positions already taken by any unit, so a candidate never lands on a neighbour
    local taken = {}
    if units then
        for _, unit in ipairs(units:GetChildren()) do
            local root = unit:FindFirstChild("HumanoidRootPart") or unit:FindFirstChild("Torso")
            if root then table.insert(taken, root.Position) end
        end
    end

    local sides = (index % 2 == 0) and { 1, -1 } or { -1, 1 }
    for k = 1, limit do
        local idx = order[k]
        local part = parts[idx]
        local a = parts[math.max(1, idx - 1)]
        local b = parts[math.min(#parts, idx + 1)]
        local dir = b.Position - a.Position
        dir = Vector3.new(dir.X, 0, dir.Z)
        if dir.Magnitude < 0.01 then dir = Vector3.new(0, 0, 1) end
        dir = dir.Unit
        local perp = Vector3.new(-dir.Z, 0, dir.X)

        for _, side in ipairs(sides) do
            for _, radius in ipairs({ 12, 15, 18, 21, 25, 9 }) do
                local target = part.Position + perp * (radius * side)
                local ok, hit = pcall(function()
                    return workspace:Raycast(
                        Vector3.new(target.X, target.Y + 80, target.Z),
                        Vector3.new(0, -260, 0),
                        RayParams
                    )
                end)
                if ok and hit then
                    local ground = hit.Position
                    -- same level as the road (skips bridges / decks above the route)
                    local level = math.abs(ground.Y - part.Position.Y)
                    local free = true
                    for _, p in ipairs(taken) do
                        if (Vector3.new(p.X, ground.Y, p.Z) - ground).Magnitude < 10 then
                            free = false
                            break
                        end
                    end
                    if level <= 8 and free then push(CFrame.new(ground)) end
                end
            end
        end
    end
    return out
end

function AutoPlace.reset()
    AutoPlace.placed = {}
    AutoPlace.tries = {}
    AutoPlace.skipped = {}
    AutoPlace.lastPlace = 0
    AutoPlace.lastCashWarn = 0
    AutoPlace.fails = 0
    AutoPlace.done = false
end

-- The unit's model name lives inside the slot's viewport, and the price in
-- Cost.text. Both are what the game itself shows, so no guessing.
function AutoPlace.nameOf(btn: GuiButton): string?
    local wm = btn:FindFirstChild("WorldModel", true)
    if not wm then return nil end
    local model = wm:GetChildren()[1]
    return model and model.Name or nil
end

function AutoPlace.costOf(btn: GuiButton): number?
    local cost = btn:FindFirstChild("Cost", true)
    if not cost then return nil end
    local best: number? = nil
    for _, d in ipairs(cost:GetDescendants()) do
        if d:IsA("TextLabel") then
            local n = tonumber((d.Text:gsub("[^%d]", "")))
            if n and n > 0 and n < 9999 then best = n end
        end
    end
    return best
end

-- Placed units are real models in workspace._UNITS carrying a _stats folder:
--   _stats.id     -> the real unit id (saber_evolved, not the card label "saber")
--   _stats.player -> the owner's username, so our own units are countable
-- spawn_unit returns nil whether the server takes the call or drops it, so the
-- count (and the cash label) is the only honest success signal.
function AutoPlace.myUnits(): number
    local units = workspace:FindFirstChild("_UNITS")
    if not units then return 0 end
    local me = LP.Name
    local n = 0
    for _, c in ipairs(units:GetChildren()) do
        local stats = c:FindFirstChild("_stats")
        local owner = stats and stats:FindFirstChild("player")
        -- the owner value has been seen as both a StringValue and a plain
        -- string depending on how the server replicated the model, so compare
        -- the value, not the class
        if owner and tostring(owner.Value) == me then
            n += 1
        end
    end
    return n
end

-- Cash lives in spawn_units as the big yellow number just above the unit bar.
-- Reading it lets the scheduler wait instead of firing a placement it cannot pay
-- for (the server drops those without a word).
function AutoPlace.cash(): number?
    local su = PGUI:FindFirstChild("spawn_units")
    if not su then return nil end
    local best: number? = nil
    for _, d in ipairs(su:GetDescendants()) do
        if d:IsA("TextLabel") and d.Visible and d.Text ~= "" and d.Text:sub(1, 1) ~= "+" then
            local n = tonumber((d.Text:gsub("[^%d]", "")))
            if n then
                local pos = d.AbsolutePosition
                if pos.X > 330 and pos.X < 385 and pos.Y > 440 and pos.Y < 465 then
                    if best == nil or n > best then best = n end
                end
            end
        end
    end
    return best
end

-- Places exactly one unit per call so the scheduler never blocks for long, and
-- only marks it placed once the game shows it landed (unit count or cash).
function AutoPlace.tick()
    if not Config.event.autoPlace then return end
    local wave = InGame.getWave()
    if not wave or wave < 1 then return end
    local now = os.clock()
    if now - AutoPlace.lastPlace < math.max(1.2, Config.event.placeDelay) then return end

    local btns = AutoPlace.buttons()
    if #btns == 0 then return end

    -- cheapest first: a level 100 team is expensive and cash only trickles in.
    -- Empty slots render as "unselected_unit" - there is nothing to place there,
    -- so they must not count towards "all units placed".
    local queue = {}
    local placeable = 0
    for i, btn in ipairs(btns) do
        local uuid = AutoPlace.uuidOf(btn)
        local name = AutoPlace.nameOf(btn) or btn.Name
        if uuid and name ~= "unselected_unit" then
            placeable += 1
            local attempts = AutoPlace.tries[btn.Name] or 0
            if attempts >= 20 then
                -- one stubborn slot (stale uuid, unplaceable unit) must never
                -- starve the rest of the team for the whole run
                if not AutoPlace.skipped[btn.Name] then
                    AutoPlace.skipped[btn.Name] = true
                    Util.log("giving up on %s after %d attempts", name, attempts)
                end
            elseif not AutoPlace.placed[btn.Name] then
                queue[#queue + 1] = {
                    i = i,
                    btn = btn,
                    name = name,
                    cost = AutoPlace.costOf(btn) or 0,
                }
            end
        end
    end
    if placeable == 0 then return end
    if #queue == 0 then
        if not AutoPlace.done then
            AutoPlace.done = true
            UI.status(string.format("placement done (%d on map)", AutoPlace.count()))
            Util.log("placement done (%d on map, %d slots)", AutoPlace.count(), placeable)
        end
        return
    end
    table.sort(queue, function(a, b)
        local al = (AutoPlace.tries[a.btn.Name] or 0) >= 12
        local bl = (AutoPlace.tries[b.btn.Name] or 0) >= 12
        if al ~= bl then return not al end
        return a.cost < b.cost
    end)

    local pick = queue[1]
    local cash = AutoPlace.cash()
    if cash and pick.cost > 0 and cash < pick.cost then
        if now - (AutoPlace.lastCashWarn or 0) > 6 then
            AutoPlace.lastCashWarn = now
            UI.status(string.format("waiting for cash: %s %d, have %d", pick.name, pick.cost, cash))
        end
        return
    end

    local cands = AutoPlace.candidates(pick.i, #btns)
    if #cands == 0 then return end
    local tries = AutoPlace.tries[pick.btn.Name] or 0
    AutoPlace.tries[pick.btn.Name] = tries + 1
    local spot = cands[(tries % #cands) + 1]

    local beforeUnits = AutoPlace.myUnits()
    AutoPlace.lastPlace = now
    local ok = Matchmaking.invoke("spawn_unit", AutoPlace.uuidOf(pick.btn), spot)
    task.wait(0.85)

    local afterUnits = AutoPlace.myUnits()
    local afterCash = AutoPlace.cash()
    local spent = 0
    if cash and afterCash then spent = cash - afterCash end
    local landed = afterUnits > beforeUnits or spent >= math.max(100, math.floor(pick.cost * 0.5))

    if ok and landed then
        AutoPlace.placed[pick.btn.Name] = true
        AutoPlace.fails = 0
        UI.status(string.format("placed %s (%d on map)", pick.name, AutoPlace.count()))
        Util.log("placed slot %s (%s) at wave %s", pick.btn.Name, pick.name, tostring(wave))
    else
        AutoPlace.fails += 1
        if AutoPlace.fails % 5 == 1 then
            Util.log("place %s rejected (try %d, units %d->%d, cash %s->%s, ok=%s)",
                pick.name, tries + 1, beforeUnits, afterUnits,
                tostring(cash), tostring(afterCash), tostring(ok))
        end
    end
end

function AutoPlace.count(): number
    local n = 0
    for _ in pairs(AutoPlace.placed) do n += 1 end
    return n
end


-- ============================================================================
-- Event  (April Fools auto-join, verified live on 2026-10-22)
-- ============================================================================
-- Two ways into the event:
--   queue  : request_lock_level + request_matchmaking (captcha gate)
--   lobby  : request_join_lobby("_lobbytemplate_event3") teleports you into the
--            event lobby, VoteStart.Yes starts the run. No captcha, no queue.
-- The lobby path is what the loop below uses: it is the one that was proven end
-- to end on a live client.

local Event = {}

function Event.inMatch(): boolean
    if InGame.isInGame() then return true end
    local data = workspace:FindFirstChild("_DATA")
    local started = data and data:FindFirstChild("GameStarted")
    return started ~= nil and started:IsA("BoolValue") and started.Value == true
end

function Event.matchEnded(): boolean
    return InGame.isFinished()
end

-- The event lobby is the only place with a VoteStart prompt.
function Event.inEventLobby(): boolean
    local vs = PGUI:FindFirstChild("VoteStart")
    return vs ~= nil and vs:IsA("ScreenGui") and vs.Enabled == true
end

-- Place ids the April Fools event teleports between. Used to tell "waiting for
-- the run to start" apart from "sitting in the main hub".
function Event.inEventPlace(): boolean
    local id = game.PlaceId
    for _, v in ipairs(Config.event.places) do
        if v == id then return true end
    end
    return false
end

function Event.voteButton(): GuiButton?
    local vs = PGUI:FindFirstChild("VoteStart")
    if not vs then return nil end
    local yes = vs:FindFirstChild("Yes", true)
    if yes and yes:IsA("GuiButton") then return yes end
    return nil
end

function Event.joinLobby(): (boolean, string)
    local ok, res = Matchmaking.invoke("request_join_lobby", Config.event.lobby)
    if not ok then return false, "remote error: " .. tostring(res) end
    return res == true, tostring(res)
end

function Event.voteStart(): (boolean, string)
    local yes = Event.voteButton()
    if not yes then return false, "VoteStart.Yes not on screen" end
    local ok, detail = Util.click(yes)
    UI.status("event vote -> " .. detail)
    return ok, detail
end

function Event.leave(): (boolean, string)
    local ok, res = Matchmaking.invoke("teleport_back_to_lobby")
    UI.status("event leave -> " .. tostring(res))
    return ok, tostring(res)
end

-- One press does the whole thing: enter the lobby if needed, then vote.
function Event.start(): (boolean, string)
    if Event.inEventLobby() then
        return Event.voteStart()
    end
    local joined, detail = Event.joinLobby()
    if not joined then return false, "join_lobby -> " .. detail end
    local appeared = Util.waitUntil(Event.inEventLobby, 25, "event lobby")
    if not appeared then return false, "joined (" .. detail .. ") but VoteStart never appeared" end
    if not Config.event.voteStart then return true, "in event lobby, vote disabled" end
    return Event.voteStart()
end

function Event.status(): string
    if Event.inMatch() then
        return string.format("in event run, wave %s%s",
            tostring(InGame.getWave() or "?"),
            Event.matchEnded() and " (finished)" or "")
    end
    if Event.inEventLobby() then return "event lobby, ready to vote" end
    return "hub"
end

-- The loop. Exactly one action per tick, no waits, no blocking calls.
local EventLoop = {
    running = false,
    matches = 0,
    lastAction = 0,
    votes = 0,
    inRun = false,
}

function EventLoop.tick()
    if not Config.event.enabled then return end
    local now = os.clock()

    -- ---- in a run ----------------------------------------------------------
    if Event.inMatch() then
        if not EventLoop.inRun then
            EventLoop.inRun = true
            AutoPlace.reset()            -- a fresh run gets a fresh set of placements
        end

        local wave = InGame.getWave()
        UI.status(Event.status())

        AutoPick.tick()
        AutoPlace.tick()

        local leaveAt = Config.event.leaveAtWave
        if leaveAt > 0 and wave and wave >= leaveAt then
            Config.event.leaveAtWave = 0          -- fire once
            EventLoop.lastAction = now
            Event.leave()
            return
        end

        if Config.event.leaveAfterMatch and Event.matchEnded() then
            if now - EventLoop.lastAction < Config.event.rejoinDelay then return end
            EventLoop.lastAction = now
            EventLoop.matches += 1
            EventLoop.inRun = false
            Util.log("event run %d finished at wave %s", EventLoop.matches, tostring(wave))
            Event.leave()
        end
        return
    end

    EventLoop.inRun = false

    -- ---- in the event lobby: vote ------------------------------------------
    if Event.inEventLobby() then
        if now - EventLoop.lastAction < 4 then return end
        EventLoop.lastAction = now
        if not Config.event.voteStart then return end
        if EventLoop.votes >= 3 then return end   -- never hammer the vote button
        EventLoop.votes += 1
        Event.voteStart()
        return
    end

    -- ---- inside an event place but the run has not started ------------------
    -- The match only flips _DATA.GameStarted once players load in, and during
    -- that window every tick used to fire request_join_lobby while in the run
    -- place, where that remote does not exist ("remote missing" every 8s).
    -- Wait for the run, and if it never starts, leave instead of idling forever.
    if Event.inEventPlace() then
        EventLoop.placeSince = EventLoop.placeSince or now
        if now - EventLoop.placeSince > 120 and now - EventLoop.lastAction > 10 then
            EventLoop.lastAction = now
            EventLoop.placeSince = now
            Util.log("no run started in event place %s, leaving", tostring(game.PlaceId))
            Event.leave()
        end
        return
    end
    EventLoop.placeSince = nil

    -- ---- in the hub: enter the event lobby ----------------------------------
    if now - EventLoop.lastAction < Config.event.joinDelay then return end
    -- the endpoints folder only exists once the lobby has replicated; firing
    -- earlier just logs "remote missing" noise
    local rs = game:GetService("ReplicatedStorage")
    if not (rs:FindFirstChild("endpoints") and rs.endpoints:FindFirstChild("client_to_server")) then return end
    EventLoop.lastAction = now
    local ok, detail = Event.joinLobby()
    Util.log("event join -> %s", detail)
    if ok then
        -- the teleport takes a few seconds; without this the next tick fires
        -- request_join_lobby again and logs a confusing "-> false"
        EventLoop.lastAction = now + 12
    else
        UI.status("event join failed: " .. detail)
    end
end

function EventLoop.start()
    Config.event.enabled = true
    EventLoop.running = true
    EventLoop.votes = 0
    UI.status("auto event ON")
    Util.log("auto event loop enabled (lobby %s)", Config.event.lobby)
end

function EventLoop.stop()
    Config.event.enabled = false
    EventLoop.running = false
    UI.status("auto event OFF")
    Util.log("auto event loop disabled")
end


-- ============================================================================
-- Scheduler
-- ============================================================================

local Hub = {}

function Hub.step()
    if recording then return end
    local ok, err = pcall(function()
        if Config.event.enabled then
            EventLoop.tick()
        elseif InGame.isInGame() then
            InGame.tick()
        else
            Lobby.tick()
        end
    end)
    if not ok then
        local text = tostring(err)
        -- Running the game's own GUI handlers from the scheduler thread can trip
        -- Roblox's capability sandbox ("cannot access 'Instance' (lacking
        -- capability Plugin)"). The handler's remote call has already gone out by
        -- then - the card pick and placement still land - so it is noise, not a
        -- failed action. Report it once and keep the log readable.
        if text:find("lacking capability", 1, true) then
            if not Hub.capWarned then
                Hub.capWarned = true
                Util.log("note: a game GUI handler hit the capability sandbox (harmless)")
            end
        else
            Util.warn("step error: " .. text)
        end
    end
end

function Hub.start()
    UI.init()
    UI.status("loaded")

    -- one scheduler only: re-running the hub must not stack a second loop
    local prev = (getgenv() :: any).AAHubThread
    if type(prev) == "thread" then
        pcall(task.cancel, prev)
    end
    (getgenv() :: any).AAHubThread = task.spawn(function()
        while true do
            Hub.step()
            task.wait(0.5)
        end
    end)

    getgenv().AAHub = {
        Config = Config,
        Util = Util,
        UI = UI,
        InGame = InGame,
        Lobby = Lobby,
        Macro = Macro,
        Matchmaking = Matchmaking,
        AutoPick = AutoPick,
        AutoPlace = AutoPlace,
        Event = Event,
        EventLoop = EventLoop,
        Hub = Hub,
        log = Log,
    }
    Matchmaking.watchCaptchas()
    Util.log("AAHub ready. getgenv().AAHub for the API.")
end

Hub.start()
return Hub
