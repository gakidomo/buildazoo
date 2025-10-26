-- AutoEgg UNC-Integrated (Ronix) — v1.0
-- Fokus: Filesystem (persist), rconsole (observabilitas), event-driven, overlay (Drawing), guardrail+backoff.
-- Catatan: Tidak memakai WebSocket. Jalur utama tetap RPC FireServer("BuyEgg", uid).

-- =======================[ KONFIGURASI AWAL (DEFAULT) ]=======================

local ISLAND_PARENT_NAME = "Art"
local DESIRED_MUTATIONS = { Golden = false, Dino = false, Snow = true, Halloween = true } -- default sama seperti skripmu
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

-- Overlay
local OVERLAY_AUTOSHOW = true   -- otomatis on saat start (sesuai permintaan)
local OVERLAY_MARGIN = 10       -- padding tepi layar
local OVERLAY_PADDING = 10
local OVERLAY_LINE_SPACING = 16 -- spasi antar baris teks
local OVERLAY_FONT = 2          -- Drawing.Fonts.UI (umum)
local OVERLAY_TEXT_SIZE = 16
local OVERLAY_BG_ALPHA = 0.4

-- Logs
local LOG_ROTATE_BYTES = 1 * 1024 * 1024 -- 1MB

-- Backoff
local BACKOFF_FAIL_COUNT = 3
local BACKOFF_DURATION = 2.0

-- ===========================[ SERVICE & UTILITAS ]===========================

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")
local TextChatService = game:GetService("TextChatService")
local UserInputService = game:GetService("UserInputService")
local HttpService = game:GetService("HttpService")

local localPlayer = Players.LocalPlayer
local character = localPlayer.Character or localPlayer.CharacterAdded:Wait()
local root = character:WaitForChild("HumanoidRootPart")

-- UNC Filesystem (pastikan tersedia di Ronix-mu)
local isfile = isfile or function() return false end
local isfolder = isfolder or function() return false end
local writefile = writefile or function() end
local readfile = readfile or function() return nil end
local appendfile = appendfile or function() end
local makefolder = makefolder or function() end
local delfile = delfile or function() end
local delfolder = delfolder or function() end
local listfiles = listfiles -- opsional (tidak wajib)

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

-- ===============================[ PERSISTENSI ]==============================

local DIR = ".autoegg"
local PATH_CONFIG = DIR.."/config.json"
local PATH_STATE  = DIR.."/state.json"
local PATH_LOG    = DIR.."/logs.txt"

local function ensureDir()
	if not isfolder(DIR) then
		makefolder(DIR)
	end
end

local function jsonEncode(tbl)
	return HttpService:JSONEncode(tbl)
end
local function jsonDecode(s)
	return HttpService:JSONDecode(s)
end

local function safeWrite(path, content)
	-- tulis ke tmp lalu ganti (rename emulasi: hapus lama -> tulis baru)
	local tmp = path..".tmp"
	writefile(tmp, content)
	if isfile(path) then
		delfile(path)
	end
	writefile(path, content)
	if isfile(tmp) then
		delfile(tmp)
	end
end

local function readJson(path, fallback)
	if not isfile(path) then return fallback end
	local ok, data = pcall(readfile, path)
	if not ok or not data or #data == 0 then return fallback end
	local ok2, obj = pcall(jsonDecode, data)
	if not ok2 then return fallback end
	return obj
end

local function writeJson(path, obj)
	local ok, data = pcall(jsonEncode, obj)
	if ok then
		safeWrite(path, data)
	end
end

local function rotateLogIfNeeded()
	if not isfile(PATH_LOG) then return end
	local ok, data = pcall(readfile, PATH_LOG)
	if not ok or not data then return end
	if #data >= LOG_ROTATE_BYTES then
		local stamp = os.date("!%Y%m%d-%H%M%S")
		local rotated = string.format("%s/logs-%s.txt", DIR, stamp)
		-- pindahkan konten lama ke file baru, kosongkan logs.txt
		writefile(rotated, data)
		delfile(PATH_LOG)
		writefile(PATH_LOG, "")
		rlog("WARN", "Log dirotasi ke "..rotated)
	end
end

local function logLine(msg)
	ensureDir()
	rotateLogIfNeeded()
	appendfile(PATH_LOG, string.format("%s %s\n", os.date("!%Y-%m-%dT%H:%M:%SZ"), msg))
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

-- =============================[ OVERLAY (Drawing) ]==========================

local overlay = {
	enabled = OVERLAY_AUTOSHOW,
	objects = {},
	bounds = {x=0,y=0,w=0,h=0},
	closeBtn = {x=0,y=0,w=20,h=20}, -- area tombol [X]
}

local function destroyOverlay()
	for _,o in pairs(overlay.objects) do
		pcall(function() o.Visible = false; o:Remove() end)
	end
	overlay.objects = {}
end

local function drawRect(x,y,w,h, alpha)
	local r = Drawing.new("Square")
	r.Filled = true
	r.Color = Color3.new(0,0,0)
	r.Transparency = alpha or OVERLAY_BG_ALPHA
	r.Size = Vector2.new(w, h)
	r.Position = Vector2.new(x, y)
	r.Visible = true
	return r
end

local function drawText(x,y,txt,size)
	local t = Drawing.new("Text")
	t.Text = txt
	t.Size = size or OVERLAY_TEXT_SIZE
	t.Font = OVERLAY_FONT
	t.Color = Color3.new(1,1,1)
	t.Position = Vector2.new(x, y)
	t.Visible = true
	return t
end

local function within(px,py, r)
	return px >= r.x and px <= r.x + r.w and py >= r.y and py <= r.y + r.h
end

local function renderOverlay()
	if not overlay.enabled then destroyOverlay(); return end
	destroyOverlay()

	-- Kumpulkan info status ringkas
	local modeExec = "RPC"
	local modeDetect = (activeBelt and "#evt" or "polling") -- kita pasang event saat belt siap
	local mutList = {}
	for k,v in pairs(DESIRED_MUTATIONS) do if v then mutList[#mutList+1]=k end end
	table.sort(mutList)
	local mutStr = (#mutList>0) and table.concat(mutList,", ") or "(none)"

	local allowTypes = {}
	for k,v in pairs(TYPE_ALLOW) do if v then allowTypes[#allowTypes+1]=k end end
	table.sort(allowTypes)
	local typeStr = (#allowTypes>0) and table.concat(allowTypes,", ") or "(all)"

	local lines = {
		"AutoEgg UNC Status",
		string.format("Mode Exec : %s", modeExec),
		string.format("Detection : %s + polling", (activeBelt and "event-driven" or "no-events")),
		string.format("Island    : %s", activeIsland and activeIsland.Name or "-"),
		string.format("Conveyor  : %s", activeConveyor and activeConveyor.Name or "-"),
		string.format("Buys/min  : %d / %d", #buysWindow, MAX_BUYS_PER_MIN),
		string.format("TTL(UID)  : %0.1fs", LAST_BOUGHT_TTL_SEC),
		string.format("Mutations : %s", mutStr),
		string.format("Types     : %s", typeStr),
		"[X] close overlay",
	}

	-- Hitung ukuran sederhana
	local maxw = 0
	for _,txt in ipairs(lines) do
		maxw = math.max(maxw, #txt)
	end
	local w = math.max(240, maxw*8 + 30)
	local h = OVERLAY_MARGIN*2 + (#lines)*OVERLAY_LINE_SPACING + 10
	local x = OVERLAY_MARGIN
	local y = OVERLAY_MARGIN

	overlay.bounds = {x=x,y=y,w=w,h=h}
	overlay.closeBtn = {x = x + w - 26, y = y + 6, w = 20, h = 20}

	-- Background
	overlay.objects.bg = drawRect(x, y, w, h, OVERLAY_BG_ALPHA)

	-- Teks
	local ty = y + 10
	for i,txt in ipairs(lines) do
		local t = drawText(x+10, ty, txt, OVERLAY_TEXT_SIZE)
		overlay.objects["t"..i] = t
		ty = ty + OVERLAY_LINE_SPACING
	end

	-- Kotak tombol [X]
	overlay.objects.btn = drawRect(overlay.closeBtn.x, overlay.closeBtn.y, overlay.closeBtn.w, overlay.closeBtn.h, 0.25)
	overlay.objects.btnBorder = Drawing.new("Square")
	overlay.objects.btnBorder.Filled = false
	overlay.objects.btnBorder.Color = Color3.new(1,1,1)
	overlay.objects.btnBorder.Size = Vector2.new(overlay.closeBtn.w, overlay.closeBtn.h)
	overlay.objects.btnBorder.Position = Vector2.new(overlay.closeBtn.x, overlay.closeBtn.y)
	overlay.objects.btnBorder.Visible = true

	local tx = drawText(overlay.closeBtn.x+5, overlay.closeBtn.y+2, "X", OVERLAY_TEXT_SIZE)
	overlay.objects.btnText = tx
end

-- Tutup overlay saat klik mouse di area tombol
UserInputService.InputBegan:Connect(function(input, gpe)
	if gpe then return end
	if input.UserInputType == Enum.UserInputType.MouseButton1 and overlay.enabled then
		local pos = UserInputService:GetMouseLocation()
		if within(pos.X, pos.Y, overlay.closeBtn) then
			overlay.enabled = false
			destroyOverlay()
			sys("Overlay ditutup. Ketik !buyegg overlay untuk menampilkan kembali.")
		end
	end
end)

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
		logLine(("BUY OK uid=%s"):format(uid))
		if ENABLE_LOG then
			print(("[AutoEgg] BUY uid=%s"):format(uid))
		end
		task.wait(BUY_COOLDOWN_SEC)
		return true
	else
		consecutiveFail += 1
		logLine(("BUY FAIL uid=%s err=%s"):format(uid, tostring(err)))
		rlog("WARN", "FireServer gagal: "..tostring(err))
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
	logLine(("RESCAN %s %s %s cnt=%d"):format(reason, island.Name, conveyor.Name, #belt:GetChildren()))

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

	renderOverlay()
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
		renderOverlay()
	end
	sys("Loop berhenti.")
end

-- ===============================[ BOOTSTRAP ]================================

ensureDir()

-- Load CONFIG & STATE
do
	-- Config
	local cfg = readJson(PATH_CONFIG, nil)
	if cfg then
		-- override nilai default jika ada
		if cfg.ISLAND_PARENT_NAME then ISLAND_PARENT_NAME = cfg.ISLAND_PARENT_NAME end
		if cfg.DESIRED_MUTATIONS then DESIRED_MUTATIONS = cfg.DESIRED_MUTATIONS end
		if cfg.CONVEYOR_LEVEL_OVERRIDE ~= nil then CONVEYOR_LEVEL_OVERRIDE = cfg.CONVEYOR_LEVEL_OVERRIDE end
		if cfg.BUY_COOLDOWN_SEC then BUY_COOLDOWN_SEC = cfg.BUY_COOLDOWN_SEC end
		if cfg.RESCAN_INTERVAL_SEC then RESCAN_INTERVAL_SEC = cfg.RESCAN_INTERVAL_SEC end
		if cfg.MAX_BUYS_PER_MIN then MAX_BUYS_PER_MIN = cfg.MAX_BUYS_PER_MIN end
		if cfg.LAST_BOUGHT_TTL_SEC then LAST_BOUGHT_TTL_SEC = cfg.LAST_BOUGHT_TTL_SEC end
		if cfg.ENABLE_LOG ~= nil then ENABLE_LOG = cfg.ENABLE_LOG end
		if cfg.ENABLE_TYPE_FILTER ~= nil then ENABLE_TYPE_FILTER = cfg.ENABLE_TYPE_FILTER end
		if cfg.TYPE_ALLOW then TYPE_ALLOW = cfg.TYPE_ALLOW end
	end

	-- State
	local st = readJson(PATH_STATE, nil)
	if st then
		if st.lastBoughtAt then lastBoughtAt = st.lastBoughtAt end
	end
end

-- Tulis default config jika belum ada
if not isfile(PATH_CONFIG) then
	writeJson(PATH_CONFIG, {
		ISLAND_PARENT_NAME = ISLAND_PARENT_NAME,
		DESIRED_MUTATIONS = DESIRED_MUTATIONS,
		CONVEYOR_LEVEL_OVERRIDE = CONVEYOR_LEVEL_OVERRIDE,
		BUY_COOLDOWN_SEC = BUY_COOLDOWN_SEC,
		RESCAN_INTERVAL_SEC = RESCAN_INTERVAL_SEC,
		MAX_BUYS_PER_MIN = MAX_BUYS_PER_MIN,
		LAST_BOUGHT_TTL_SEC = LAST_BOUGHT_TTL_SEC,
		ENABLE_LOG = ENABLE_LOG,
		ENABLE_TYPE_FILTER = ENABLE_TYPE_FILTER,
		TYPE_ALLOW = TYPE_ALLOW,
	})
end

-- Rescan awal
task.defer(function()
	rescanAll("initial")
end)

-- Overlay awal
if OVERLAY_AUTOSHOW then
	renderOverlay()
end

-- ===============================[ CHAT COMMAND ]=============================

local PREFIX, BASE = "!", "buyegg"

local function listActiveMutations()
	local t = {}
	for k,v in pairs(DESIRED_MUTATIONS) do if v then t[#t+1]=k end end
	table.sort(t); return #t>0 and table.concat(t,", ") or "(kosong)"
end

local function persistConfig()
	writeJson(PATH_CONFIG, {
		ISLAND_PARENT_NAME = ISLAND_PARENT_NAME,
		DESIRED_MUTATIONS = DESIRED_MUTATIONS,
		CONVEYOR_LEVEL_OVERRIDE = CONVEYOR_LEVEL_OVERRIDE,
		BUY_COOLDOWN_SEC = BUY_COOLDOWN_SEC,
		RESCAN_INTERVAL_SEC = RESCAN_INTERVAL_SEC,
		MAX_BUYS_PER_MIN = MAX_BUYS_PER_MIN,
		LAST_BOUGHT_TTL_SEC = LAST_BOUGHT_TTL_SEC,
		ENABLE_LOG = ENABLE_LOG,
		ENABLE_TYPE_FILTER = ENABLE_TYPE_FILTER,
		TYPE_ALLOW = TYPE_ALLOW,
	})
end

local function persistState()
	writeJson(PATH_STATE, {
		lastBoughtAt = lastBoughtAt,
		island = activeIsland and activeIsland.Name or nil,
		conveyor = activeConveyor and activeConveyor.Name or nil,
		beltCount = (activeBelt and #activeBelt:GetChildren() or 0),
	})
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

	elseif sub == "overlay" then
		-- toggle overlay
		overlay.enabled = not overlay.enabled
		if overlay.enabled then renderOverlay() else destroyOverlay() end
		sys("Overlay: "..(overlay.enabled and "ON" or "off"))

	elseif sub == "rescan" then
		local ok = rescanAll("manual")
		if not ok then
			sys("Rescan gagal. Pastikan kamu berada di dekat island & conveyor yang benar.")
		else
			persistState()
		end

	elseif sub == "types" then
		if not activeIsland or not activeBelt then
			sys("Belt belum aktif. Gunakan !buyegg rescan dulu.")
		else
			local counts = {}
			for e in iterValidEggs(activeIsland, activeBelt) do
				local et = getEggType(e.data, e.item)
				if et then
					local key = _norm(et)
					if not counts[key] then counts[key] = {name = et, n = 0} end
					counts[key].n += 1
				end
			end
			local total = 0
			for _, v in pairs(counts) do total += v.n end
			if total == 0 then
				sys("Tidak ada egg type terdeteksi di belt saat ini.")
			else
				sys(("Egg types di belt (total %d):"):format(total))
				for _, v in pairs(counts) do
					local flag = TYPE_ALLOW[_norm(v.name)] and "ON" or "off"
					sys(("- %s  (count=%d, filter=%s)"):format(v.name, v.n, flag))
					task.wait(0.02)
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
			persistConfig()
			sys(("Filter type %s: %s"):format(name, onoff == "on" and "ON" or "off"))
			renderOverlay()
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
			persistConfig()
			sys("Filter types di-set eksklusif. Cek dengan !buyegg types")
			renderOverlay()
		end

	elseif sub == "cleartypes" then
		for k,_ in pairs(TYPE_ALLOW) do TYPE_ALLOW[k] = nil end
		persistConfig()
		sys("Filter types dikosongkan (semua tipe diizinkan).")
		renderOverlay()

	elseif sub == "status" then
		sys(("Status: %s | Mutasi aktif: %s | Level: %s | Window buys: %d/min | Overlay: %s")
			:format(running and "BERJALAN" or "BERHENTI",
				listActiveMutations(),
				CONVEYOR_LEVEL_OVERRIDE and tostring(CONVEYOR_LEVEL_OVERRIDE) or "auto",
				#buysWindow,
				overlay.enabled and "ON" or "off"))

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
			persistConfig()
			sys("Conveyor level: AUTO")
		else
			local n = tonumber(p)
			if n then
				CONVEYOR_LEVEL_OVERRIDE = n
				persistConfig()
				sys("Conveyor level di-set ke: "..n)
			else
				sys("Pakai: !buyegg setlevel <n|auto>")
			end
		end
		renderOverlay()

	elseif sub == "setmut" then
		local name = parts[3]; local onoff = parts[4] and parts[4]:lower()
		if not name or (onoff ~= "on" and onoff ~= "off") then
			sys("Pakai: !buyegg setmut <Nama> on|off (contoh: !buyegg setmut Golden on)")
			return
		end
		DESIRED_MUTATIONS[name] = (onoff == "on")
		persistConfig()
		sys("Mutasi aktif sekarang: "..listActiveMutations())
		renderOverlay()

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
		sys("Perintah: !buyegg start | stop | status | eggs | setmut <Nama> on|off | setlevel <n|auto> | rescan | types | settype <Type> on|off | onlytype <A,B,...> | cleartypes | test | buy <uid> | collect | overlay")
	end

	-- Persist state ringan di akhir command
	persistState()
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

sys("Perintah: !buyegg start | stop | status | eggs | setmut <Nama> on|off | setlevel <n|auto> | rescan | types | settype <Type> on|off | onlytype <A,B,...> | cleartypes | test | buy <uid> | collect | overlay")
