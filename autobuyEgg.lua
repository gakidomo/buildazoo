-- AutoEgg UNC-Integrated (Ronix) — v2.0
-- Fokus: In-memory state, rconsole (observabilitas), event-driven, overlay (Drawing), guardrail+backoff.
-- Catatan: Tidak memakai WebSocket atau file I/O. Jalur utama tetap RPC FireServer("BuyEgg", uid).

-- =======================[ KONFIGURASI AWAL (DEFAULT) ]=======================

local ISLAND_PARENT_NAME = "Art"
local DESIRED_MUTATIONS = { Golden = false, Dino = false, Snow = false, Halloween = false, Thanksgiving = true } -- default sama seperti skripmu
local CONVEYOR_LEVEL_OVERRIDE = nil

local BUY_COOLDOWN_SEC = 0.35
local RESCAN_INTERVAL_SEC = 1.5               -- tetap; kita tambahkan event-driven agar lebih responsif
local MAX_BUYS_PER_MIN = 120
local LAST_BOUGHT_TTL_SEC = 4
local ENABLE_LOG = true

-- Auto-Collect
local COLLECT_SLEEP_PER_PET = 0.05
local COLLECT_MAX_PETS = nil

-- Type Filter (case-insensitive)
local ENABLE_TYPE_FILTER = true
local TYPE_ALLOW = {}

-- Simple Display
local DISPLAY_ENABLED = true
local DISPLAY_FONT = 2
local DISPLAY_TEXT_SIZE = 14
local DISPLAY_POSITION = Vector2.new(10, 10)

-- Backoff
local BACKOFF_FAIL_COUNT = 3
local BACKOFF_DURATION = 2.0

-- ===========================[ SERVICE & UTILITAS ]===========================

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")
local TextChatService = game:GetService("TextChatService")
local HttpService = game:GetService("HttpService")

local localPlayer = Players.LocalPlayer
local character = localPlayer.Character or localPlayer.CharacterAdded:Wait()
local root = character:WaitForChild("HumanoidRootPart")

-- rconsole (pakai keluarga rconsole* bila tersedia)
local HAS_RCONSOLE = (typeof(rconsoleprint) == "function") or (typeof(rconsolewarn) == "function")
local function rlog(level, msg)
	if not HAS_RCONSOLE then return end
	local prefix = "[AutoEgg] "
	if level == "ERROR" and rconsoleerr then rconsoleerr(prefix .. msg .. "\n")
	elseif level == "WARN" and rconsolewarn then rconsolewarn(prefix .. msg .. "\n")
	elseif rconsoleprint then rconsoleprint(prefix .. msg .. "\n")
	end
end
pcall(function()
	if HAS_RCONSOLE and rconsolename then
		rconsolename("AutoEgg UNC")
	end
end)

local function sys(t)
	pcall(function() StarterGui:SetCore("ChatMakeSystemMessage",{Text="[AutoEgg] "..t}) end)
	if ENABLE_LOG then print("[AutoEgg]", t) end
	rlog("INFO", t)
end

-- ===============================[ STATE RUNTIME ]============================

local running = false
local activeIsland  -- Instance | nil
local activeConveyor -- Instance | nil
local activeBelt    -- Instance | nil

local buysWindow = {}
local lastBoughtAt = {} -- uid -> time
local consecutiveFail = 0
local backoffUntil = 0

-- Event-driven connections
local connections = {} -- { RBXScriptConnection, ... }
local function addConn(conn) connections[#connections+1] = conn end
local function clearConns()
	for i = #connections, 1, -1 do
		local c = connections[i]
		pcall(function() c:Disconnect() end)
		table.remove(connections, i)
	end
end

-- =============================[ SIMPLE DISPLAY ]============================

local displayText = nil

local function destroyDisplay()
	if displayText then
		pcall(function() displayText.Visible = false; displayText:Remove() end)
		displayText = nil
	end
end

local function updateDisplay()
	if not DISPLAY_ENABLED then
		destroyDisplay()
		return
	end
	
	-- Kumpulkan mutations aktif
	local mutList = {}
	for k,v in pairs(DESIRED_MUTATIONS) do
		if v then mutList[#mutList+1]=k end
	end
	table.sort(mutList)
	local mutStr = (#mutList>0) and table.concat(mutList,", ") or "(none)"
	
	-- Kumpulkan types aktif
	local allowTypes = {}
	for k,v in pairs(TYPE_ALLOW) do
		if v then allowTypes[#allowTypes+1]=k end
	end
	table.sort(allowTypes)
	local typeStr = (#allowTypes>0) and table.concat(allowTypes,", ") or "(all)"
	
	-- Buat text sederhana
	local displayStr = string.format("[AutoEgg] Mutations: %s | Types: %s", mutStr, typeStr)
	
	if not displayText then
		displayText = Drawing.new("Text")
		displayText.Size = DISPLAY_TEXT_SIZE
		displayText.Font = DISPLAY_FONT
		displayText.Color = Color3.new(1, 1, 1)
		displayText.Position = DISPLAY_POSITION
		displayText.Visible = true
		displayText.Outline = true
		displayText.OutlineColor = Color3.new(0, 0, 0)
	end
	
	displayText.Text = displayStr
end

-- =============================[ LOGIKA GAME ]================================

local function beltAlive()
	return activeBelt and activeBelt.Parent and activeBelt:IsDescendantOf(game)
end

local function findActiveIsland()
	local parent = Workspace:FindFirstChild(ISLAND_PARENT_NAME) or Workspace
	local best, bestDist = nil, math.huge
	for _, m in ipairs(parent:GetChildren()) do
		if m.Name:match("^Island_%d+$") then
			local p = m.PrimaryPart or m:FindFirstChildWhichIsA("BasePart", true)
			if p then
				local d = (p.Position - root.Position).Magnitude
				if d < bestDist then best, bestDist = m, d end
			end
		end
	end
	return best
end

local function findConveyor(island, levelOverride)
	if not island then return nil end
	if levelOverride then
		local target = "Conveyor"..tostring(levelOverride)
		for _, d in ipairs(island:GetDescendants()) do
			if d:IsA("Model") and d.Name == target then return d end
		end
	end
	-- auto: cari Conveyor%d+ yang punya Belt; ambil level terbesar
	local best, bestNum = nil, -1
	for _, d in ipairs(island:GetDescendants()) do
		if d:IsA("Model") then
			local n = d.Name:match("^Conveyor(%d+)$")
			if n and d:FindFirstChild("Belt") then
				n = tonumber(n)
				if n > bestNum then best, bestNum = d, n end
			end
		end
	end
	return best
end

local function getIslandEggFolder(islandModel)
	local eggs = ReplicatedStorage:FindFirstChild("Eggs"); if not eggs then return nil end
	return eggs:FindFirstChild(islandModel.Name)
end

local function iterValidEggs(islandModel, belt)
	local folder = getIslandEggFolder(islandModel)
	if not folder then return function() return nil end end
	local list = {}
	for _, item in ipairs(belt:GetChildren()) do
		local uid = item.Name
		local data = folder:FindFirstChild(uid)
		if data then
			table.insert(list, {uid=uid, data=data, item=item})
		end
	end
	local i = 0
	return function() i += 1; return list[i] end
end

-- Normalisasi
local function _norm(s) if s == nil then return nil end return tostring(s):lower() end

local function getEggType(eggData, beltItem)
	if eggData then
		local t = eggData:GetAttribute("T")
		if t ~= nil then return tostring(t) end
	end
	if beltItem then
		local t2 = beltItem:GetAttribute("Type")
		if t2 ~= nil then return tostring(t2) end
	end
	return nil
end

local function isTypeAllowed(etype)
	if not ENABLE_TYPE_FILTER then return true end
	if next(TYPE_ALLOW) == nil then return true end
	if not etype then return false end
	return TYPE_ALLOW[_norm(etype)] == true
end

local function isMutationMatch(data)
	if not data then return false end
	local m = data:GetAttribute("M")
	return m and DESIRED_MUTATIONS[tostring(m)] == true
end

local function isMatch(eggData, beltItem)
	if not isMutationMatch(eggData) then return false end
	local etype = getEggType(eggData, beltItem)
	return isTypeAllowed(etype)
end

local function getBuyRemote()
	local remoteFolder = ReplicatedStorage:FindFirstChild("Remote")
	if not remoteFolder then return nil end
	return remoteFolder:FindFirstChild("CharacterRE")
end

local function canBuyNow()
	local now = os.clock()
	for i = #buysWindow, 1, -1 do
		if now - buysWindow[i] > 60 then table.remove(buysWindow, i) end
	end
	return #buysWindow < MAX_BUYS_PER_MIN and now >= backoffUntil
end

local function recordBuy(uid)
	local t = os.clock()
	buysWindow[#buysWindow+1] = t
	lastBoughtAt[uid] = t
end

local function recentlyBought(uid)
	local t = lastBoughtAt[uid]
	return t and (os.clock() - t) < LAST_BOUGHT_TTL_SEC
end

local function fireBuy(uid)
	local re = getBuyRemote()
	if not re or not re:IsA("RemoteEvent") then
		sys("❌ RemoteEvent ReplicatedStorage.Remote.CharacterRE tidak ditemukan.")
		return false
	end
	if not canBuyNow() then
		return false
	end

	local ok, err = pcall(function()
		re:FireServer("BuyEgg", uid)
	end)
	if ok then
		recordBuy(uid)
		consecutiveFail = 0
		if ENABLE_LOG then
			print(("[AutoEgg] BUY uid=%s"):format(uid))
		end
		rlog("INFO", ("BUY OK uid=%s"):format(uid))
		task.wait(BUY_COOLDOWN_SEC)
		return true
	else
		consecutiveFail += 1
		rlog("WARN", ("BUY FAIL uid=%s err=%s"):format(uid, tostring(err)))
		if consecutiveFail >= BACKOFF_FAIL_COUNT then
			backoffUntil = os.clock() + BACKOFF_DURATION
			rlog("WARN", ("Backoff aktif %0.1fs"):format(BACKOFF_DURATION))
		end
		return false
	end
end

-- ============================[ RESCAN & EVENT-DRIVEN ]=======================

local function rescanAll(reason)
	reason = reason or "manual"
	activeIsland, activeConveyor, activeBelt = nil, nil, nil
	clearConns()

	local island = findActiveIsland()
	if not island then
		sys(("Rescan (%s): ❌ Island tidak ketemu."):format(reason))
		return false
	end

	local conveyor = findConveyor(island, CONVEYOR_LEVEL_OVERRIDE)
	if not conveyor then
		sys(("Rescan (%s): ❌ Conveyor tidak ketemu di %s."):format(reason, island.Name))
		return false
	end

	local belt = conveyor:FindFirstChild("Belt")
	if not belt then
		sys(("Rescan (%s): ❌ Belt tidak ada di %s."):format(reason, conveyor.Name))
		return false
	end

	activeIsland, activeConveyor, activeBelt = island, conveyor, belt
	sys(("Rescan (%s): ✅ %s → %s (Belt children: %d)"):format(reason, island.Name, conveyor.Name, #belt:GetChildren()))
	rlog("INFO", ("RESCAN %s %s %s cnt=%d"):format(reason, island.Name, conveyor.Name, #belt:GetChildren()))

	-- Pasang Event-Driven listener pada Belt
	local c1 = belt.ChildAdded:Connect(function(child)
		if not running then return end
		-- targeted validate
		local folder = getIslandEggFolder(activeIsland)
		if not folder then return end
		local uid = child.Name
		if recentlyBought(uid) then return end
		local data = folder:FindFirstChild(uid)
		if not data then return end
		if isMatch(data, child) and canBuyNow() then
			fireBuy(uid)
		end
	end)
	addConn(c1)

	local c2 = belt.ChildRemoved:Connect(function(_)
		-- tidak wajib lakukan apa-apa; tetap untuk keseimbangan
	end)
	addConn(c2)

	updateDisplay()
	return true
end

-- ===============================[ ONE-SHOT COLLECT ]=========================

local collecting = false
local function oneShotCollectPets()
	if collecting then
		sys("Collect lagi berjalan. Tunggu selesai ya.")
		return
	end
	collecting = true
	task.spawn(function()
		local ok, err = pcall(function()
			local petsFolder = Workspace:FindFirstChild("Pets") or Workspace:WaitForChild("Pets", 3)
			if not petsFolder then
				sys("❌ Folder Workspace.Pets tidak ditemukan.")
				return
			end
			local processed, success, total = 0, 0, #petsFolder:GetChildren()
			sys(("Mulai collect dari %d pets…"):format(total))
			for _, pet in ipairs(petsFolder:GetChildren()) do
				if COLLECT_MAX_PETS and processed >= COLLECT_MAX_PETS then break end
				local rootPart = pet:FindFirstChild("RootPart")
				if rootPart then
					local remote = rootPart:FindFirstChild("RE")
					if remote and remote:IsA("RemoteEvent") then
						local okFire, errFire = pcall(function()
							remote:FireServer("Claim")
						end)
						processed += 1
						if okFire then success += 1 else
							if ENABLE_LOG then warn("[AutoEgg] Collect gagal:", errFire) end
						end
						if COLLECT_SLEEP_PER_PET and COLLECT_SLEEP_PER_PET > 0 then
							task.wait(COLLECT_SLEEP_PER_PET)
						end
					end
				end
			end
			sys(("Collect selesai. Diproses: %d | Berhasil: %d"):format(processed, success))
		end)
		if not ok then
			sys("❌ Collect error: "..tostring(err))
		end
		collecting = false
	end)
end

-- ===============================[ MAIN LOOP ]================================

local function mainLoop()
	sys("Loop mulai. Event-driven aktif + polling fallback. Ketik !buyegg rescan jika berpindah island/bertukar conveyor.")
	while running do
		if not beltAlive() then
			sys("Belt tidak tersedia. Gunakan !buyegg rescan.")
			task.wait(RESCAN_INTERVAL_SEC)
			continue
		end
		-- Polling (fallback): iterasi cache island+belt, biarkan event-driven menangkap yang baru muncul.
		for e in iterValidEggs(activeIsland, activeBelt) do
			if not running then break end
			if isMatch(e.data, e.item) then
				local uid = e.uid
				if not recentlyBought(uid) and canBuyNow() then
					fireBuy(uid)
				end
			end
		end
		task.wait(RESCAN_INTERVAL_SEC)
		updateDisplay()
	end
	sys("Loop berhenti.")
end

-- ===============================[ BOOTSTRAP ]================================

-- Rescan awal
task.defer(function()
	rescanAll("initial")
end)

-- Display awal
if DISPLAY_ENABLED then
	updateDisplay()
end

-- ===============================[ CHAT COMMAND ]=============================

local PREFIX, BASE = "!", "buyegg"

local function listActiveMutations()
	local t = {}
	for k,v in pairs(DESIRED_MUTATIONS) do if v then t[#t+1]=k end end
	table.sort(t); return #t>0 and table.concat(t,", ") or "(kosong)"
end

local function tryParseCommand(msg)
	if not msg or msg:sub(1,#PREFIX) ~= PREFIX then return end
	local parts = string.split(msg:sub(#PREFIX+1), " ")
	if #parts==0 then return end
	parts[1] = parts[1]:lower()
	if parts[1] ~= BASE then return end

	local sub = (parts[2] or "help"):lower()

	if sub == "start" then
		if running then sys("Sudah berjalan.") else running = true; task.spawn(mainLoop); sys("Dimulai.") end

	elseif sub == "collect" then
		oneShotCollectPets()

	elseif sub == "stop" then
		if running then running = false; sys("Dihentikan.") else sys("Sudah berhenti.") end

	elseif sub == "display" then
		-- toggle display
		DISPLAY_ENABLED = not DISPLAY_ENABLED
		if DISPLAY_ENABLED then updateDisplay() else destroyDisplay() end
		sys("Display: "..(DISPLAY_ENABLED and "ON" or "off"))

	elseif sub == "rescan" then
		local ok = rescanAll("manual")
		if not ok then
			sys("Rescan gagal. Pastikan kamu berada di dekat island & conveyor yang benar.")
		end

	elseif sub == "unload" then
    	running = false
    	clearConns()
    	DISPLAY_ENABLED = false
    	destroyDisplay()
    	sys("AutoEgg dihentikan dan semua event listener dilepas.")
    return

	elseif sub == "types" then
    if not activeIsland or not activeBelt then
        sys("Belt belum aktif. Gunakan !buyegg rescan dulu.")
    else
        local counts = {} -- counts[typeKey] = { name = typeName, n = 0, muts = { mutKey = { name = mutName, n = 0 } } }
        local total = 0

        for e in iterValidEggs(activeIsland, activeBelt) do
            local et = getEggType(e.data, e.item) or "(unknown)"
            local mk = tostring(e.data:GetAttribute("M") or "(none)")
            local tkey = _norm(et)
            local mkey = _norm(mk)

            if not counts[tkey] then
                counts[tkey] = { name = et, n = 0, muts = {} }
            end
            counts[tkey].n = counts[tkey].n + 1
            total = total + 1

            if not counts[tkey].muts[mkey] then
                counts[tkey].muts[mkey] = { name = mk, n = 0 }
            end
            counts[tkey].muts[mkey].n = counts[tkey].muts[mkey].n + 1
        end

        if total == 0 then
            sys("Tidak ada egg type terdeteksi di belt saat ini.")
        else
            sys(("Egg types di belt (total %d):"):format(total))
            -- urut berdasarkan nama tipe untuk konsistensi
            local keys = {}
            for k,_ in pairs(counts) do keys[#keys+1] = k end
            table.sort(keys)

            for _, k in ipairs(keys) do
                local v = counts[k]
                local flag = TYPE_ALLOW[_norm(v.name)] and "ON" or "off"
                sys(("- %s  (count=%d, filter=%s)"):format(v.name, v.n, flag))
                task.wait(0.01)
                -- tampilkan mutasi untuk tipe ini (urut)
                local mkeys = {}
                for mk,_ in pairs(v.muts) do mkeys[#mkeys+1] = mk end
                table.sort(mkeys)
                for _, mk in ipairs(mkeys) do
                    local mv = v.muts[mk]
                    sys(("    * %s (count=%d)"):format(mv.name, mv.n))
                    task.wait(0.01)
                end
            end
        end
    end

	elseif sub == "settype" then
		-- !buyegg settype <TypeName> on|off
		local name = parts[3]
		local onoff = parts[4] and parts[4]:lower()
		if not name or (onoff ~= "on" and onoff ~= "off") then
			sys("Pakai: !buyegg settype <TypeName> on|off   (contoh: !buyegg settype BowserEgg on)")
		else
			TYPE_ALLOW[_norm(name)] = (onoff == "on")
			sys(("Filter type %s: %s"):format(name, onoff == "on" and "ON" or "off"))
			updateDisplay()
		end

	elseif sub == "onlytype" then
		-- !buyegg onlytype <Type1,Type2,...>
		local list = parts[3]
		if not list or #list == 0 then
			sys("Pakai: !buyegg onlytype <Type1,Type2,...>")
		else
			for k,_ in pairs(TYPE_ALLOW) do TYPE_ALLOW[k] = nil end
			for token in string.gmatch(list, "([^,]+)") do
				TYPE_ALLOW[_norm((token:gsub("^%s*(.-)%s*$","%1")))] = true
			end
			sys("Filter types di-set eksklusif. Cek dengan !buyegg types")
			updateDisplay()
		end

	elseif sub == "cleartypes" then
		for k,_ in pairs(TYPE_ALLOW) do TYPE_ALLOW[k] = nil end
		sys("Filter types dikosongkan (semua tipe diizinkan).")
		updateDisplay()

	elseif sub == "status" then
		sys(("Status: %s | Mutasi aktif: %s | Level: %s | Window buys: %d/min | Display: %s")
			:format(running and "BERJALAN" or "BERHENTI",
				listActiveMutations(),
				CONVEYOR_LEVEL_OVERRIDE and tostring(CONVEYOR_LEVEL_OVERRIDE) or "auto",
				#buysWindow,
				DISPLAY_ENABLED and "ON" or "off"))

	elseif sub == "eggs" then
		local island = findActiveIsland(); if not island then sys("Island?"); return end
		local conveyor = findConveyor(island, CONVEYOR_LEVEL_OVERRIDE); if not conveyor then sys("Conveyor?"); return end
		local belt = conveyor:FindFirstChild("Belt"); if not belt then sys("Belt?"); return end
		local shown = 0
		for e in iterValidEggs(island, belt) do
			local m = e.data:GetAttribute("M")
			sys(("[%02d] uid=%s | M=%s | match=%s"):format(shown+1, e.uid, tostring(m), tostring(isMutationMatch(e.data))))
			shown += 1; if shown >= 15 then break end
		end
		if shown == 0 then sys("Tidak ada egg valid terdeteksi di Belt.") end

	elseif sub == "setlevel" then
		local p = parts[3]
		if p == nil or p == "auto" then
			CONVEYOR_LEVEL_OVERRIDE = nil
			sys("Conveyor level: AUTO")
		else
			local n = tonumber(p)
			if n then
				CONVEYOR_LEVEL_OVERRIDE = n
				sys("Conveyor level di-set ke: "..n)
			else
				sys("Pakai: !buyegg setlevel <n|auto>")
			end
		end
		updateDisplay()

	elseif sub == "setmut" then
		local name = parts[3]; local onoff = parts[4] and parts[4]:lower()
		if not name or (onoff ~= "on" and onoff ~= "off") then
			sys("Pakai: !buyegg setmut <Nama> on|off (contoh: !buyegg setmut Golden on)")
			return
		end
		DESIRED_MUTATIONS[name] = (onoff == "on")
		sys("Mutasi aktif sekarang: "..listActiveMutations())
		updateDisplay()

	elseif sub == "test" then
		local island = findActiveIsland(); if not island then sys("Island?"); return end
		local conveyor = findConveyor(island, CONVEYOR_LEVEL_OVERRIDE); if not conveyor then sys("Conveyor?"); return end
		local belt = conveyor:FindFirstChild("Belt"); if not belt then sys("Belt?"); return end
		for e in iterValidEggs(island, belt) do
			if isMatch(e.data, e.item) then
				sys("Test beli uid="..e.uid)
				fireBuy(e.uid); return
			end
		end
		sys("Tidak ada egg yang match mutasi aktif.")

	elseif sub == "buy" then
		local uid = parts[3]
		if not uid then sys("Pakai: !buyegg buy <uid>"); return end
		fireBuy(uid)

	else
		sys("Perintah: !buyegg start | stop | status | eggs | setmut <Nama> on|off | setlevel <n|auto> | rescan | types | settype <Type> on|off | onlytype <A,B,...> | cleartypes | test | buy <uid> | collect | display | unload")
	end
end

if TextChatService and TextChatService.ChatVersion == Enum.ChatVersion.TextChatService then
	if TextChatService.SendingMessage then
		TextChatService.SendingMessage:Connect(function(props)
			if props and props.Text and props.Text:sub(1,#PREFIX)==PREFIX then
				tryParseCommand(props.Text); props.Text=""
			end
		end)
	end
else
	localPlayer.Chatted:Connect(tryParseCommand)
end

sys("Perintah: !buyegg start | stop | status | eggs | setmut <Nama> on|off | setlevel <n|auto> | rescan | types | settype <Type> on|off | onlytype <A,B,...> | cleartypes | test | buy <uid> | collect | display")
