-- Egg Counter + Mini Toast (Custom UI) v3
-- Menampilkan rekap jumlah egg per Type (T) & Mutation (M)
-- dalam panel kecil (toast) yang auto-hilang dan bisa menampung banyak baris.

-- ===== KONFIGURASI =====
local DURATION = 20           -- detik toast tampil
local WIDTH    = 380          -- px
local HEIGHT   = 260          -- px
local POSITION = "bottom_right" 
-- pilihan: "top_right", "top_left", "bottom_right", "bottom_left"
local COUNT_PLANTED_ONLY   = false  -- hanya yang ada child "DI"
local COUNT_UNPLANTED_ONLY = true  -- hanya yang TIDAK punya child "DI"
-- jika keduanya false -> hitung semua

-- ===== SERVICE =====
local Players = game:GetService("Players")
local LP = Players.LocalPlayer
local PlayerGui = LP:WaitForChild("PlayerGui")

-- ===== HELPER UI =====
local function getAnchorAndPos(posKey)
    if posKey == "top_right" then
        return Vector2.new(1,0), UDim2.fromScale(0.99, 0.06)
    elseif posKey == "top_left" then
        return Vector2.new(0,0), UDim2.fromScale(0.01, 0.06)
    elseif posKey == "bottom_left" then
        return Vector2.new(0,1), UDim2.fromScale(0.01, 0.99)
    else -- bottom_right (default)
        return Vector2.new(1,1), UDim2.fromScale(0.99, 0.99)
    end
end

local function createMiniToast(titleText: string, lines: {string}, duration: number?)
    local sg = Instance.new("ScreenGui")
    sg.Name = "EggMiniToast_v3"
    sg.ResetOnSpawn = false
    sg.Parent = PlayerGui

    local anchor, pos = getAnchorAndPos(POSITION)

    local frame = Instance.new("Frame")
    frame.AnchorPoint = anchor
    frame.Position = pos
    frame.Size = UDim2.fromOffset(WIDTH, HEIGHT)
    frame.BackgroundColor3 = Color3.fromRGB(22,22,22)
    frame.BackgroundTransparency = 0.1
    frame.BorderSizePixel = 0
    frame.Parent = sg

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 10)
    corner.Parent = frame

    local stroke = Instance.new("UIStroke")
    stroke.Thickness = 1
    stroke.Color = Color3.fromRGB(80, 200, 120)
    stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
    stroke.Parent = frame

    -- title bar
    local title = Instance.new("TextLabel")
    title.Size = UDim2.new(1, -40, 0, 26)
    title.Position = UDim2.fromOffset(12, 10)
    title.BackgroundTransparency = 1
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.Text = titleText
    title.Font = Enum.Font.GothamMedium
    title.TextSize = 14
    title.TextColor3 = Color3.fromRGB(235,255,240)
    title.Parent = frame

    -- close button
    local closeBtn = Instance.new("TextButton")
    closeBtn.Size = UDim2.fromOffset(24, 24)
    closeBtn.Position = UDim2.new(1, -30, 0, 8)
    closeBtn.BackgroundTransparency = 1
    closeBtn.Text = "✕"
    closeBtn.Font = Enum.Font.GothamBold
    closeBtn.TextSize = 16
    closeBtn.TextColor3 = Color3.fromRGB(220, 220, 220)
    closeBtn.Parent = frame
    closeBtn.MouseButton1Click:Connect(function()
        sg:Destroy()
    end)

    -- list container
    local sf = Instance.new("ScrollingFrame")
    sf.Size = UDim2.new(1, -20, 1, -48)
    sf.Position = UDim2.fromOffset(10, 38)
    sf.AutomaticCanvasSize = Enum.AutomaticSize.Y
    sf.CanvasSize = UDim2.new()
    sf.ScrollBarThickness = 6
    sf.BackgroundTransparency = 1
    sf.Parent = frame

    local list = Instance.new("UIListLayout")
    list.Padding = UDim.new(0, 6)
    list.Parent = sf

    -- fill lines
    local function addLine(txt: string, bold: boolean?)
        local lbl = Instance.new("TextLabel")
        lbl.Size = UDim2.new(1, -6, 0, 16)
        lbl.BackgroundTransparency = 1
        lbl.TextXAlignment = Enum.TextXAlignment.Left
        lbl.Font = bold and Enum.Font.GothamMedium or Enum.Font.Code
        lbl.TextSize = bold and 14 or 13
        lbl.TextColor3 = Color3.fromRGB(220,240,225)
        lbl.Text = txt
        lbl.Parent = sf
    end

    for _, line in ipairs(lines) do
        if line == "__hr__" then
            local sep = Instance.new("Frame")
            sep.Size = UDim2.new(1, -6, 0, 1)
            sep.BackgroundColor3 = Color3.fromRGB(70, 90, 80)
            sep.BackgroundTransparency = 0.35
            sep.BorderSizePixel = 0
            sep.Parent = sf
        elseif line == "__sp__" then
            local spacer = Instance.new("Frame")
            spacer.Size = UDim2.new(1, -6, 0, 2)
            spacer.BackgroundTransparency = 1
            spacer.Parent = sf
        else
            addLine(line, false)
        end
    end

    task.delay(duration or DURATION, function()
        if sg and sg.Parent then
            sg:Destroy()
        end
    end)
end

-- ===== LOGIKA HITUNG =====
local function isPlanted(node: Instance): boolean
    return node:FindFirstChild("DI") ~= nil
end

local function eligible(node: Instance): boolean
    if COUNT_PLANTED_ONLY and not isPlanted(node) then return false end
    if COUNT_UNPLANTED_ONLY and isPlanted(node) then return false end
    return true
end

local function countEggs(root: Instance)
    local byType, byPair = {}, {}
    local total, matched = 0, 0

    for _, inst in ipairs(root:GetDescendants()) do
        local okT, T = pcall(function() return inst:GetAttribute("T") end)
        if okT and T ~= nil then
            if eligible(inst) then
                matched += 1
                local M = inst:GetAttribute("M") or "None"
                byType[T] = (byType[T] or 0) + 1
                local key = tostring(T) .. "|" .. tostring(M)
                byPair[key] = (byPair[key] or 0) + 1
                total += 1
            end
        end
    end
    return byType, byPair, total, matched
end

local function formatLines(byType, byPair, total, matched)
    local lines = {}

    -- judul seksi 1
    table.insert(lines, "Per T (M):")
    table.insert(lines, "__sp__")

    local keys = {}
    for k in pairs(byPair) do table.insert(keys, k) end
    table.sort(keys)

    for _, key in ipairs(keys) do
        local T, M = string.match(key, "^(.-)|(.+)$")
        local cnt = byPair[key]
        table.insert(lines, string.format("%s (%s): %d", T or "?", M or "?", cnt))
    end

    table.insert(lines, "__sp__")
    table.insert(lines, "__hr__")
    table.insert(lines, "__sp__")

    -- judul seksi 2
    table.insert(lines, "Ringkas per Jenis:")
    table.insert(lines, "__sp__")

    local tkeys = {}
    for t in pairs(byType) do table.insert(tkeys, t) end
    table.sort(tkeys)
    for _, t in ipairs(tkeys) do
        table.insert(lines, string.format("%s: %d", t, byType[t]))
    end

    table.insert(lines, "__sp__")
    table.insert(lines, "__hr__")
    table.insert(lines, "__sp__")

    table.insert(lines, string.format("TOTAL: %d   (match T=%d)", total, matched))

    return lines
end

-- ===== EKSEKUSI =====
local dataFolder = PlayerGui:WaitForChild("Data", 10)
local eggRoot = dataFolder and dataFolder:WaitForChild("Egg", 10)
if not eggRoot then
    warn("[EggMiniToast] Tidak menemukan PlayerGui.Data.Egg")
    return
end

local byType, byPair, total, matched = countEggs(eggRoot)
local lines = formatLines(byType, byPair, total, matched)
createMiniToast("Egg Counter", lines, DURATION)

-- (opsional) hidupkan auto-update saat inventory berubah:
-- eggRoot.DescendantAdded:Connect(function()
--     task.wait(0.1)
--     local bt, bp, tot, m = countEggs(eggRoot)
--     createMiniToast("Egg Counter (Updated +)", formatLines(bt, bp, tot, m), DURATION)
-- end)
-- eggRoot.DescendantRemoving:Connect(function()
--     task.wait(0.1)
--     local bt, bp, tot, m = countEggs(eggRoot)
--     createMiniToast("Egg Counter (Updated -)", formatLines(bt, bp, tot, m), DURATION)
-- end)
