-- ================================================
-- BUILD A ZOO AUTO BUYER
-- Auto Egg + Auto Food (Full Implementasi + Full Flag Support)
-- ================================================

local Rayfield = loadstring(game:HttpGet("https://sirius.menu/rayfield"))()

local Window = Rayfield:CreateWindow({
    Name = "Build A Zoo Auto Buyer",
    LoadingTitle = "Auto Egg + Auto Food",
    LoadingSubtitle = "Auto Save and Load Config",
    ConfigurationSaving = {
        Enabled = true,
        FolderName = "GakiSC",
        FileName = "AutoBuyer_Config"
    }
})

-- ================================================
-- SERVICES & STATE
-- ================================================
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LocalPlayer = Players.LocalPlayer
local rootPart = nil

local eggRunning = false
local foodRunning = false

-- Egg System
local activeIsland = nil
local activeBelt = nil
local ALL_MUTATIONS = {}
local ALL_EGGS = {}
local SELECTED_MUTATIONS = {}
local SELECTED_EGGS = {}
local BUY_ANY_DETECTED = false
local EGG_COOLDOWN = 0.35

-- Food System
local FOOD_LOOP_INTERVAL = 145
local FOOD_DELAY_PER_BUY = 0.25
local FOOD_MAX_PER_ITEM = 500

local function sys(msg)
    print("[AutoBuyer]", msg)
end

-- Character Handler
local function updateRoot()
    local char = LocalPlayer.Character or LocalPlayer.CharacterAdded:Wait()
    rootPart = char:WaitForChild("HumanoidRootPart", 5)
end
LocalPlayer.CharacterAdded:Connect(updateRoot)
if LocalPlayer.Character then updateRoot() end

-- ================================================
-- LOAD STATIC DATA
-- ================================================
local function loadStaticData()
    -- Mutations
    local config = ReplicatedStorage:FindFirstChild("Config")
    local resMutate = config and config:FindFirstChild("ResMutate")
    if resMutate then
        local mutTable = require(resMutate)
        ALL_MUTATIONS = mutTable["__index"] or {}
    end

    -- Egg Pools (tanpa _W)
    local eggPools = ReplicatedStorage:FindFirstChild("EggPools")
    if eggPools then
        local temp = {}
        for _, v in ipairs(eggPools:GetChildren()) do
            local name = v.Name
            if not name:find("_W$") then
                temp[name] = true
            end
        end
        ALL_EGGS = {}
        for name in pairs(temp) do table.insert(ALL_EGGS, name) end
        table.sort(ALL_EGGS)
    end
end

-- ================================================
-- EGG RESCAN
-- ================================================
local function rescanEgg()
    activeIsland = nil
    activeBelt = nil

    local parent = Workspace:FindFirstChild("Art") or Workspace
    local best, bestDist = nil, math.huge

    for _, island in ipairs(parent:GetChildren()) do
        if island.Name:match("^Island_%d+$") then
            local p = island.PrimaryPart or island:FindFirstChildWhichIsA("BasePart", true)
            if p and rootPart then
                local dist = (p.Position - rootPart.Position).Magnitude
                if dist < bestDist then 
                    best, bestDist = island, dist 
                end
            end
        end
    end

    if not best then return false end
    activeIsland = best

    local conveyor = nil
    local bestLevel = -1
    for _, v in ipairs(best:GetDescendants()) do
        if v:IsA("Model") then
            local lvl = v.Name:match("^Conveyor(%d+)$")
            if lvl and v:FindFirstChild("Belt") then
                lvl = tonumber(lvl)
                if lvl > bestLevel then 
                    conveyor = v
                    bestLevel = lvl 
                end
            end
        end
    end

    if not conveyor then return false end
    activeBelt = conveyor:FindFirstChild("Belt")
    return activeBelt ~= nil
end

-- ================================================
-- GUI WITH FLAGS
-- ================================================
local BuyEggTab = Window:CreateTab("Buy Egg", 4483362458)
local BuyFoodTab = Window:CreateTab("Buy Food", 4483362458)
local MiscTab = Window:CreateTab("Misc", 4483362458)

-- ================== BUY EGG TAB ==================
BuyEggTab:CreateToggle({
    Name = "Auto Buy Egg",
    CurrentValue = false,
    Flag = "AutoEgg_Running",           -- ← Flag ditambahkan
    Callback = function(state)
        eggRunning = state
        if state then
            sys("Auto Egg Running → ON")
            task.spawn(function()
                while eggRunning do
                    if activeBelt then
                        local eggFolder = ReplicatedStorage:FindFirstChild("Eggs") and ReplicatedStorage.Eggs:FindFirstChild(activeIsland and activeIsland.Name)
                        if eggFolder then
                            for _, item in ipairs(activeBelt:GetChildren()) do
                                local data = eggFolder:FindFirstChild(item.Name)
                                if data then
                                    local mut = data:GetAttribute("M")
                                    local eggType = data:GetAttribute("T")
                                    local eggSelected = SELECTED_EGGS[eggType] == true
                                    local mutSelected = BUY_ANY_DETECTED or (SELECTED_MUTATIONS[mut] == true)

                                    if eggSelected and mutSelected then
                                        local re = ReplicatedStorage:FindFirstChild("Remote") and ReplicatedStorage.Remote:FindFirstChild("CharacterRE")
                                        if re then
                                            pcall(function() re:FireServer("BuyEgg", item.Name) end)
                                            task.wait(EGG_COOLDOWN)
                                        end
                                    end
                                end
                            end
                        end
                    end
                    task.wait(1)
                end
            end)
            rescanEgg()
        else
            sys("Auto Egg Running → OFF")
        end
    end
})


local Section1 = BuyEggTab:CreateSection("Egg")

local eggDropdown = BuyEggTab:CreateDropdown({
    Name = "Selected Eggs",
    Options = ALL_EGGS,
    CurrentOption = {},
    MultipleOptions = true,
    Flag = "Selected_Eggs",             -- ← Flag
    Callback = function(selected)
        SELECTED_EGGS = {}
        for _, v in ipairs(selected) do 
            SELECTED_EGGS[v] = true 
        end
    end
})

local Section2 = BuyEggTab:CreateSection("Mutation")

BuyEggTab:CreateToggle({
    Name = "Buy Any Detected Mutation",
    CurrentValue = false,
    Flag = "BuyAny_Mutation",           -- ← Flag
    Callback = function(state)
        BUY_ANY_DETECTED = state
    end
})

local mutationDropdown = BuyEggTab:CreateDropdown({
    Name = "Selected Mutations",
    Options = ALL_MUTATIONS,
    CurrentOption = {},
    MultipleOptions = true,
    Flag = "Selected_Mutations",        -- ← Flag (Dropdown multiple)
    Callback = function(selected)
        SELECTED_MUTATIONS = {}
        for _, v in ipairs(selected) do 
            SELECTED_MUTATIONS[v] = true 
        end
    end
})

local Section2 = BuyEggTab:CreateSection("Misc")

BuyEggTab:CreateButton({
    Name = "🔄 Refresh Lists",
    Callback = function()
        loadStaticData()
        mutationDropdown:Refresh(ALL_MUTATIONS)
        eggDropdown:Refresh(ALL_EGGS)
        sys("Lists di-refresh")
    end
})


MiscTab:CreateButton({
    Name = "🗑️ Unload/Close Script",
    Callback = function()
        eggRunning = false
        foodRunning = false
        pcall(function() Rayfield:Destroy() end)
        sys("Script berhasil di-unload.")
    end
})

-- ================== BUY FOOD TAB ==================
BuyFoodTab:CreateToggle({
    Name = "Auto Food Running",
    CurrentValue = false,
    Flag = "AutoFood_Running",          -- ← Flag
    Callback = function(state)
        foodRunning = state
        if state then
            sys("Auto Food Running → ON")
            task.spawn(function()
                while foodRunning do
                    local pg = LocalPlayer:WaitForChild("PlayerGui")
                    local data = pg:WaitForChild("Data")
                    local foodStore = data:WaitForChild("FoodStore")
                    local lst = foodStore:WaitForChild("LST")
                    local remote = ReplicatedStorage:FindFirstChild("Remote") and ReplicatedStorage.Remote:FindFirstChild("FoodStoreRE")

                    if lst and remote then
                        local attrs = lst:GetAttributes()
                        for itemName, qty in pairs(attrs) do
                            if typeof(qty) == "number" and qty > 0 then
                                local buyAmount = math.min(qty, FOOD_MAX_PER_ITEM)
                                for i = 1, buyAmount do
                                    pcall(function() remote:FireServer(itemName) end)
                                    task.wait(FOOD_DELAY_PER_BUY)
                                end
                            end
                        end
                        sys("Food buying cycle selesai")
                    end
                    task.wait(FOOD_LOOP_INTERVAL)
                end
            end)
        else
            sys("Auto Food Running → OFF")
            Rayfield:Notify({
                Title = "Auto buy food",
                Content = "sedang berjalan",
                Duration = 8
            })
        end
    end
})

BuyFoodTab:CreateSlider({
    Name = "Food Loop Interval (detik)",
    Range = {60, 300},
    Increment = 5,
    CurrentValue = FOOD_LOOP_INTERVAL,
    Flag = "Food_LoopInterval",         -- ← Flag
    Callback = function(v) 
        FOOD_LOOP_INTERVAL = v 
    end
})

BuyFoodTab:CreateSlider({
    Name = "Delay Per Buy (detik)",
    Range = {0.1, 1},
    Increment = 0.05,
    CurrentValue = FOOD_DELAY_PER_BUY,
    Flag = "Food_DelayPerBuy",          -- ← Flag
    Callback = function(v) 
        FOOD_DELAY_PER_BUY = v 
    end
})

BuyFoodTab:CreateSlider({
    Name = "Max Per Item",
    Range = {100, 1000},
    Increment = 50,
    CurrentValue = FOOD_MAX_PER_ITEM,
    Flag = "Food_MaxPerItem",           -- ← Flag
    Callback = function(v) 
        FOOD_MAX_PER_ITEM = v 
    end
})

-- MiscTab:CreateButton({
--     Name = "Auto Collect Money",
--     Callback = function()
--         -- ================== ONE SHOT COLLECT PETS ==================
--         local collecting = false

--         local function oneShotCollectPets()
--             if collecting then
--                 sys("Collect sedang berjalan. Tunggu selesai.")
--                 Rayfield:Notify({
--                     Title = "Auto Collect sedang berjalan",
--                     Content = "Tunggu selesai",
--                     Duration = 8
--                 })
--                 return
--             end

--             -- ================== VARIABLE DI DALAM FUNGSI ==================
--             local COLLECT_MAX_PETS = nil        -- nil = collect semua
--             local COLLECT_SLEEP_PER_PET = 0.05  -- jeda antar collect (detik)
--             local ENABLE_LOG = false             -- untuk logging error

--             collecting = true

--             task.spawn(function()
--                 local ok, err = pcall(function()
--                     local petsFolder = Workspace:FindFirstChild("Pets") or Workspace:WaitForChild("Pets", 3)
--                     if not petsFolder then
--                         sys("❌ Folder Workspace.Pets tidak ditemukan.")
--                         Rayfield:Notify({
--                             Title = "Auto Collect Warning",
--                             Content = "Folder Workspace.Pets tidak ditemukan",
--                             Duration = 8
--                         })
--                         return
--                     end

--                     local processed = 0
--                     local success = 0
--                     local total = #petsFolder:GetChildren()

--                     sys(("Mulai collect dari %d pets..."):format(total))

--                     for _, pet in ipairs(petsFolder:GetChildren()) do
--                         -- Cek batas maksimal jika diatur
--                         if COLLECT_MAX_PETS and processed >= COLLECT_MAX_PETS then 
--                             break 
--                         end

--                         local rootPart = pet:FindFirstChild("RootPart")
--                         if rootPart then
--                             local remote = rootPart:FindFirstChild("RE")
--                             if remote and remote:IsA("RemoteEvent") then
--                                 local okFire = pcall(function()
--                                     remote:FireServer("Claim")
--                                 end)

--                                 processed += 1
--                                 if okFire then 
--                                     success += 1 
--                                 else
--                                     if ENABLE_LOG then 
--                                         warn("[Collect] Gagal claim pet:", pet.Name) 
--                                         Rayfield:Notify({
--                                             Title = "Gagal Claim pet: " + pet.Name,
--                                             Content = "Tunggu selesai",
--                                             Duration = 8
--                                         })
--                                     end
--                                 end

--                                 -- Jeda antar collect
--                                 if COLLECT_SLEEP_PER_PET and COLLECT_SLEEP_PER_PET > 0 then
--                                     task.wait(COLLECT_SLEEP_PER_PET)
--                                 end
--                             end
--                         end
--                     end

--                     sys(("Collect selesai → Diproses: %d | Berhasil: %d"):format(processed, success))
--                     Rayfield:Notify({
--                         Title = "Auto Collect Berhasil",
--                         Content = "done collect all bang",
--                         Duration = 8
--                     })
--                 end)

--                 if not ok then
--                     sys("❌ Error saat collect: " .. tostring(err))
--                     Rayfield:Notify({
--                         Title = "Auto Collect Error",
--                         Content = "ada yang error, auto collect gagal",
--                         Duration = 8
--                     })
--                 end

--                 collecting = false
--             end)
--         end

--         -- Jalankan fungsi collect
--         oneShotCollectPets()
--     end
-- })

-- ================================================
-- INIT
-- ================================================
loadStaticData()

Rayfield:Notify({
    Title = "GakiSC",
    Content = "Script loaded",
    Duration = 8
})

sys("Build A Zoo Auto Buyer v3.3 Final berhasil dimuat!")

Rayfield:LoadConfiguration()
