local Players = game:GetService("Players")
local LocalPlayer = Players.LocalPlayer
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Remote Events yang dibutuhkan
local characterRE = ReplicatedStorage:WaitForChild("Remote"):WaitForChild("CharacterRE")
local tradeRE = ReplicatedStorage:WaitForChild("Remote"):WaitForChild("TradeRE") -- Remote Event untuk Trade

-- Durasi jeda loop (90 detik)
local LOOP_DELAY = 95

-- Variabel global
local targetPetUID = nil
local foundTradePart = nil
local myUserId = LocalPlayer.UserId 
local artContainer = Workspace:WaitForChild("Art") 
local petsContainer = LocalPlayer.PlayerGui.Data.Pets

-- Fungsi untuk mendapatkan Karakter dan komponen utamanya (untuk Teleportasi)
local function getCharacterComponents()
    local Character = LocalPlayer.Character or LocalPlayer.CharacterAdded:Wait()
    local HumanoidRootPart = Character:WaitForChild("HumanoidRootPart")
    return Character, HumanoidRootPart
end

-- ==========================================================
-- FUNGSI INTI: MENEMUKAN PET
-- ==========================================================
local function findAndFocusPet()
    targetPetUID = nil -- Reset UID setiap loop
    
    -- 1. Cari Pet UID yang valid (di Inventory)
    for _, petInstance in ipairs(petsContainer:GetChildren()) do
        if #petInstance:GetChildren() == 0 then
            targetPetUID = petInstance.Name 
            break 
        end
    end

    -- 2. Eksekusi Focus TANPA SYARAT
    if targetPetUID then
        local args = {
            "Focus",
            targetPetUID
        }
        characterRE:FireServer(unpack(args))
        print("✅ Pet Focus: Dijalankan tanpa syarat.")
        return true
    else
        warn("❌ Peringatan: Tidak ditemukan pet yang tersedia di inventory.")
        return false
    end
end

-- ==========================================================
-- FUNGSI INTI: TELEPORTASI
-- ==========================================================
local function doTeleport(humanoidRootPart)
    foundTradePart = nil -- Reset target setiap loop
    
    for _, island in ipairs(artContainer:GetChildren()) do
        if island:IsA("Model") and string.match(island.Name, "^Island_") then
            
            local ownerId = island:GetAttribute("OccupyingPlayerId")

            if ownerId == myUserId then
                -- Menemukan TradePart menggunakan jalur eksplisit
                local tradeZoneContainer = island:FindFirstChild("ENV")
                if tradeZoneContainer and tradeZoneContainer:FindFirstChild("TradeZone") then
                    
                    -- Penelusuran jalur tetap: ENV.TradeZone.Zone.TradeZone5.TradePart
                    foundTradePart = tradeZoneContainer.TradeZone
                                     :FindFirstChild("Zone")
                                     :FindFirstChild("TradeZone5")
                                     :FindFirstChild("TradePart")
                end
                
                if foundTradePart and foundTradePart:IsA("BasePart") then
                    break 
                end
            end
        end
    end

    if foundTradePart then
        local targetPosition = foundTradePart.Position
        -- Pindahkan HumanoidRootPart
        humanoidRootPart.CFrame = CFrame.new(targetPosition) * CFrame.new(0, 5, 0)
        print("✅ Teleportasi berhasil.")
        return true
    else
        warn("❌ Gagal Teleportasi: Tidak dapat menemukan TradePart di pulau milik Anda.")
        return false
    end
end


-- ==========================================================
-- LOOP UTAMA SKRIP
-- ==========================================================

while true do
    local Character, HumanoidRootPart = getCharacterComponents() -- Dapatkan komponen karakter yang terbaru

    -- 1. FASE 1: Fokus Pet
    if not findAndFocusPet() then
        wait(LOOP_DELAY)
        continue -- Lanjut ke loop berikutnya jika tidak ada pet
    end
    
    -- 2. FASE 1: Teleportasi
    if not doTeleport(HumanoidRootPart) then
        wait(LOOP_DELAY)
        continue -- Lanjut ke loop berikutnya jika gagal teleport
    end

    -- Tunggu sejenak setelah teleport untuk loading
    wait(1) 
    
    -- 3. FASE 2: Request Trade
    tradeRE:FireServer({
        event = "reqtrade"
    })
    print("➡️ Request Trade dikirim.")

    -- Jeda singkat untuk memproses Trade Request (misalnya 0.5 detik)
    wait(0.5) 
    
    -- 4. FASE 2: Decline Trade
    tradeRE:FireServer({
        event = "decline"
    })
    print("⬅️ Trade di-decline.")
    
    -- 5. Jeda Loop (90 detik)
    print("⏳ Menunggu siklus berikutnya dalam "..LOOP_DELAY.." detik...")
    wait(LOOP_DELAY) 
end
