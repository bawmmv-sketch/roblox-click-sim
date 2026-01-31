--!strict

--[[
	Click System Backend
	this script contains:
	OOP with metatables
	Delta time based generators
	DataStore retry logic
	MarketplaceService usage
	Server click handling
	Roblox API usage
	Memory save player session management
]]

local Players = game:GetService("Players")
local DataStoreService = game:GetService("DataStoreService")
local MarketplaceService = game:GetService("MarketplaceService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local AddClick: RemoteEvent = ReplicatedStorage:WaitForChild("AddClick")
local ClickStore = DataStoreService:GetDataStore("AdvancedClickData_V1")
local DATA_RETRY_COUNT = 5
local DATA_RETRY_DELAY = 2
local GAMEPASS_AUTO = 1586277217
local GAMEPASS_2X = 1585719373
local GAMEPASS_4X = 1584858573
local GAMEPASS_8X = 1584134109
local BuyUpgrade: RemoteEvent = ReplicatedStorage:WaitForChild("BuyUpgrade")

-- Session Class

type PlayerSession = {
	Player: Player,
	Clicks: IntValue,
	Multiplier: NumberValue,
	LastSave: number,
	OwnedPasses: {[number]: boolean},
	Accumulator: number,
	UpgradeLevel: IntValue,
}

local Session = {}
Session.__index = Session

-- Datastore

local function safeGetAsync(userId: number)
	for attempt = 1, DATA_RETRY_COUNT do
		local success, result = pcall(function()
			return ClickStore:GetAsync(userId)
		end)

		if success then
			return result
		end

		task.wait(DATA_RETRY_DELAY)
	end

	warn("DataStore GetAsync failed for", userId)
	return nil
end

local function safeSetAsync(userId: number, data: any)
	for attempt = 1, DATA_RETRY_COUNT do
		local success = pcall(function()
			ClickStore:SetAsync(userId, data)
		end)

		if success then
			return true
		end

		task.wait(DATA_RETRY_DELAY)
	end

	warn("DataStore SetAsync failed for", userId)
	return false
end

-- Check Marketplace

local function ownsPass(player: Player, passId: number): boolean
	local success, result = pcall(function()
		return MarketplaceService:UserOwnsGamePassAsync(player.UserId, passId)
	end)

	return success and result
end

-- Session Methods

function Session.new(player: Player): PlayerSession
	local self = setmetatable({}, Session)

	self.Player = player
	self.LastSave = os.clock()
	self.Accumulator = 0
	self.OwnedPasses = {}

	local upgrade = Instance.new("IntValue")
	upgrade.Name = "UpgradeLevel"
	upgrade.Value = 1
	upgrade.Parent = player
	self.UpgradeLevel = upgrade

	-- Leaderstats creation
	local leaderstats = Instance.new("Folder")
	leaderstats.Name = "leaderstats"
	leaderstats.Parent = player

	local clicks = Instance.new("IntValue")
	clicks.Name = "Clicks"
	clicks.Parent = leaderstats
	self.Clicks = clicks

	local multiplier = Instance.new("NumberValue")
	multiplier.Name = "Multiplier"
	multiplier.Value = 1
	multiplier.Parent = player
	self.Multiplier = multiplier

	return self
end

function Session:loadData()
	local data = safeGetAsync(self.Player.UserId)

	if data then
		self.Clicks.Value = data.Clicks or 0
		self.UpgradeLevel.Value = data.UpgradeLevel or 1

		local lastTime = data.LastTime or os.time()
		local offlineSeconds = os.time() - lastTime

		if ownsPass(self.Player, GAMEPASS_AUTO) then
			self.Clicks.Value += offlineSeconds * 10
		end
	end
end

function Session:saveData()
	local payload = {
		Clicks = self.Clicks.Value,
		LastTime = os.time(),
		UpgradeLevel = self.UpgradeLevel.Value,
	}

	safeSetAsync(self.Player.UserId, payload)
	self.LastSave = os.clock()
end

function Session:refreshPasses()
	self.OwnedPasses[GAMEPASS_2X] = ownsPass(self.Player, GAMEPASS_2X)
	self.OwnedPasses[GAMEPASS_4X] = ownsPass(self.Player, GAMEPASS_4X)
	self.OwnedPasses[GAMEPASS_8X] = ownsPass(self.Player, GAMEPASS_8X)
	self.OwnedPasses[GAMEPASS_AUTO] = ownsPass(self.Player, GAMEPASS_AUTO)

	-- Apply highest multiplier
	if self.OwnedPasses[GAMEPASS_8X] then
		self.Multiplier.Value = 8
	elseif self.OwnedPasses[GAMEPASS_4X] then
		self.Multiplier.Value = 4
	elseif self.OwnedPasses[GAMEPASS_2X] then
		self.Multiplier.Value = 2
	else
		self.Multiplier.Value = 1
	end
end

function Session:addClick(amount: number)
	local power = amount * self.Multiplier.Value * self.UpgradeLevel.Value
	self.Clicks.Value += power
end

end

-- Session Manager

local Sessions: {[Player]: PlayerSession} = {}

-- Heartbeat Generator

RunService.Heartbeat:Connect(function(dt)
	for player, session in pairs(Sessions) do
		if not player.Parent then
			continue
		end

		-- Accumulate delta time for accurate timing
		session.Accumulator += dt

		-- Use CFrame math timing discipline (consistent tick every 1s)
		local steps = math.floor(session.Accumulator)
		if steps >= 1 then
			session.Accumulator -= steps

			if session.OwnedPasses[GAMEPASS_AUTO] then
				session:addClick(10 * steps)
			end
		end

		-- Autosave every 60 seconds using time comparison
		if os.clock() - session.LastSave > 60 then
			session:saveData()
		end
	end
end)

-- Player Lifecycle

Players.PlayerAdded:Connect(function(player)
	local session = Session.new(player)
	Sessions[player] = session

	session:loadData()
	session:refreshPasses()
end)

Players.PlayerRemoving:Connect(function(player)
	local session = Sessions[player]
	if session then
		session:saveData()
		Sessions[player] = nil
	end
end)

-- Gamepass Purchase

MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player, passId, purchased)
	if not purchased then
		return
	end

	local session = Sessions[player]
	if not session then
		return
	end

	session:refreshPasses()
end)

-- Remote Click

AddClick.OnServerEvent:Connect(function(player)
	local session = Sessions[player]
	if not session then
		return
	end

	-- Server authoritative validation
	session:addClick(1)
end)

-- Buy Upgrade 

BuyUpgrade.OnServerEvent:Connect(function(player)
	local session = Sessions[player]
	if not session then
		return
	end

	local cost = session.UpgradeLevel.Value * 100

	if session.Clicks.Value < cost then
		return
	end

	session.Clicks.Value -= cost
	session.UpgradeLevel.Value += 1
end)


-- Shuttdown save

game:BindToClose(function()
	for player, session in pairs(Sessions) do
		session:saveData()
	end
end)
