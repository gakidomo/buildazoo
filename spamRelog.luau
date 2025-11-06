local TeleportService = game:GetService("TeleportService")
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer
local character = player.Character or player.CharacterAdded:Wait()
local root = character:WaitForChild("HumanoidRootPart")

local inactive = true  -- anggap pemain tidak aktif
local startPos = root.Position

local waitTime = 5 --detik
local xTime = waitTime * 10

-- Jika pemain memberikan input, tandai sebagai aktif
UserInputService.InputBegan:Connect(function()
	inactive = false
end)

-- Cek pergerakan setiap 0.1 detik
task.spawn(function()
	for i = 1, xTime do
		task.wait(0.1)

		-- jika pemain bergerak
		if (root.Position - startPos).Magnitude > 0.5 then
			inactive = false
			break
		end
	end

	-- setelah 5 detik, kalau tetap tidak aktif → teleport
	if inactive then
		TeleportService:Teleport(game.PlaceId, player)
	end
end)
