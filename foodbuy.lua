
-------------------------
-- ========== KONFIGURASI ==========
-------------------------
local USE_BLACKLIST = true
local BLACKLIST = { -- set true untuk item yang TIDAK mau dibeli
    --Pear = true,
	--Pineapple = true,
	--DragonFruit = true,
	--GoldMango = true,
	--BloodstoneCycad = true,
	--ColossalPinecone = true,
	--VoltGinkgo = true,
	--DeepseaPearlFruit = true,
    --Durian = true,
	--CandyCorn = true,
	--Pumpkin = true,
	--FrankenKiwi = true,
	--Acorn = true,
	--Cranberry = true,
}

local LOOP_ENABLED = true              -- true = jalan terus
local LOOP_INTERVAL = 145              -- detik
local DELAY_PER_BUY = 0.25             -- jeda antar FireServer
local MAX_PER_ITEM = 500               -- safe guard
local DRY_RUN = false                  -- true = simulasi aja (tidak FireServer)
local TOAST_DURATION = 5              -- detik

-------------------------
-- ========== SERVICE & PATH ==========
-------------------------
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local LocalPlayer = Players.LocalPlayer

local function waitForPath()
    local pg = LocalPlayer:WaitForChild("PlayerGui")
    local data = pg:WaitForChild("Data")
    local foodStore = data:WaitForChild("FoodStore")
    local lst = foodStore:WaitForChild("LST")
    local remote = ReplicatedStorage:WaitForChild("Remote"):WaitForChild("FoodStoreRE")
    return lst, remote
end

-------------------------
-- ========== MINI TOAST ==========
-------------------------
local function ensureToastGui()
    local gui = Instance.new("ScreenGui")
    gui.Name = "MiniToast_FoodStore"
    gui.ResetOnSpawn = false
    gui.IgnoreGuiInset = true
    gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    gui.Parent = LocalPlayer:WaitForChild("PlayerGui")

    local holder = Instance.new("Frame")
    holder.Name = "Holder"
    holder.AnchorPoint = Vector2.new(1, 0)
    holder.Position = UDim2.new(1, -16, 0, 16)
    holder.Size = UDim2.new(0, 360, 0, 0)
    holder.BackgroundTransparency = 1
    holder.Parent = gui

    return gui, holder
end

local ToastGUI, ToastHolder = ensureToastGui()

local function showToast(linesText, duration)
    duration = duration or TOAST_DURATION

    local frame = Instance.new("Frame")
    frame.AutomaticSize = Enum.AutomaticSize.Y
    frame.Size = UDim2.fromOffset(360, 0)
    frame.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
    frame.BackgroundTransparency = 0.15
    frame.BorderSizePixel = 0
    frame.Position = UDim2.fromOffset(0, 0)
    frame.Parent = ToastHolder
    frame.ClipsDescendants = true

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 12)
    corner.Parent = frame

    local padding = Instance.new("UIPadding")
    padding.PaddingTop = UDim.new(0, 12)
    padding.PaddingBottom = UDim.new(0, 12)
    padding.PaddingLeft = UDim.new(0, 12)
    padding.PaddingRight = UDim.new(0, 12)
    padding.Parent = frame

    local label = Instance.new("TextLabel")
    label.Name = "Text"
    label.AutomaticSize = Enum.AutomaticSize.Y
    label.Size = UDim2.new(1, 0, 0, 0)
    label.BackgroundTransparency = 1
    label.TextWrapped = true
    label.TextXAlignment = Enum.TextXAlignment.Left
    label.TextYAlignment = Enum.TextYAlignment.Top
    label.Font = Enum.Font.Gotham
    label.TextSize = 14
    label.TextColor3 = Color3.fromRGB(235, 235, 235)
    label.RichText = false
    label.Text = linesText
    label.Parent = frame

    -- animasi masuk/keluar sederhana
    frame.Position = UDim2.fromOffset(400, 0)
    frame.Visible = true
    frame:TweenPosition(UDim2.fromOffset(0, 0), Enum.EasingDirection.Out, Enum.EasingStyle.Quad, 0.25, true)

    task.delay(duration, function()
        if frame and frame.Parent then
            frame:TweenPosition(UDim2.fromOffset(400, 0), Enum.EasingDirection.In, Enum.EasingStyle.Quad, 0.25, true)
            task.wait(0.3)
            frame:Destroy()
        end
    end)
end

-------------------------
-- ========== INTI PEMBELIAN ==========
-------------------------
local function clamp(n, lo, hi)
    if n < lo then return lo end
    if n > hi then return hi end
    return n
end

local function buildTargetsFromAttributes(lstInstance)
    local attrs = lstInstance:GetAttributes()
    local targets = {}
    for name, qty in pairs(attrs) do
        local isNumber = (typeof(qty) == "number")
        if isNumber and qty > 0 then
            if (not USE_BLACKLIST) or (BLACKLIST[name] ~= true) then
                targets[name] = clamp(qty, 1, MAX_PER_ITEM)
            end
        end
    end
    return targets
end

local function buyOnce()
    local lst, remote = waitForPath()

    local summary = {
        startedAt = os.time(),
        totalCalls = 0,
        ok = {},
        fail = {},
        skipped = {},
    }

    local targets = buildTargetsFromAttributes(lst)
    -- catat item yang diskip karena blacklist/qty 0
    do
        local attrs = lst:GetAttributes()
        for name, qty in pairs(attrs) do
            if (typeof(qty) == "number") and qty > 0 then
                if USE_BLACKLIST and BLACKLIST[name] == true then
                    summary.skipped[name] = qty
                end
            end
        end
    end

    for itemName, qty in pairs(targets) do
        for i = 1, qty do
            summary.totalCalls += 1
            if DRY_RUN then
                summary.ok[itemName] = (summary.ok[itemName] or 0) + 1
            else
                local ok, err = pcall(function()
                    remote:FireServer(itemName)
                end)
                if ok then
                    summary.ok[itemName] = (summary.ok[itemName] or 0) + 1
                else
                    summary.fail[itemName] = (summary.fail[itemName] or 0) + 1
                    warn("[FoodStore AutoBuy] Gagal beli", itemName, "err:", err)
                end
            end
            task.wait(DELAY_PER_BUY)
        end
    end

    -- Buat ringkasan
    local function joinKV(t)
        local parts = {}
        for k, v in pairs(t) do
            table.insert(parts, string.format("%s x%d", k, v))
        end
        table.sort(parts)
        return (#parts > 0) and table.concat(parts, ", ") or "-"
    end

    local text = string.format(
        "FoodStore Auto-Buy\nOK: %s\nFAIL: %s\nSKIP: %s\nTotal Calls: %d",
        joinKV(summary.ok),
        joinKV(summary.fail),
        joinKV(summary.skipped),
        summary.totalCalls
    )

    print("[FoodStore AutoBuy] " .. text:gsub("\n", " | "))
    showToast(text, TOAST_DURATION)
end

-------------------------
-- ========== EKSEKUSI ==========
-------------------------
task.spawn(function()
    if LOOP_ENABLED then
        while true do
            buyOnce()
            task.wait(LOOP_INTERVAL)
        end
    else
        buyOnce()
    end
end)
