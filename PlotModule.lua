--!strict
-- Scripted by @Freeze667Corleone on Roblox AKA @AzizD3v
 
--[[
TL;DR: Manages a player’s plot lifecycle:
seed placement → incubation → creature spawn → passive earnings → optional capture/steal.
 
Flow:
- PlaceSeedInPlot (net): validates backpack/tool, saves to PlotSeeds, spawns Incubator.
- Incubator: shows growth; VIP hatches at 1/5 time; hatch prompt rolls a creature.
- Creature: spawns, billboard (name/rarity/earnings), moves on surfaces, pays Cash every second.
- Capture/Steal: owner reclaims instantly; others trigger devproduct to steal.
 
Persistence (DataHandler):
- PlotSeeds[id] = { SeedName, CFrameComponents, StartTime }
- PlotCreatures[id] = { SeedName, CreatureName, SizeMult }
- CreatureBackpack[CreatureName] = count; SeedBackpack[SeedName] = count; Cash += earnings/sec.
 
Assets & Settings:
- Assets.DNAPacks, Assets.Incubators, Assets.CreatureTool (with Handle).
- Plot model needs: PrimaryPart, PlacementSurface, Creatures, Incubators, NameSign, Owner.
- GameSettings.CreaturesSpeed; Passes.VIP; SamplesInfo[seed].Pack[creature].Earnings.
 
API: Plot.new(model, owner) → OnPlotLoaded → HandlePlot → LoadData; Destroy(); CreateCreatureTool.
]]
 
--// Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
 
--// Packages & Modules
local Packages = ReplicatedStorage.Packages
local AzizUtils = require(Packages.AzizUtils)
local TableUtil = require(Packages.TableUtil)
 
local DataHandler = require(script.Parent.Parent.DataHandler)
local ModuleLoader = require(ReplicatedStorage.ModuleLoader)
local GameSettings = require(ReplicatedStorage.GameSettings)
local SamplesInfo = require(ReplicatedStorage.Modules.DNASamplesInfo)
 
local Shared = ModuleLoader.Shared
local Network = Shared.Network
local NetRefs = Network.Refs
 
--// Assets
local Assets = ReplicatedStorage.Assets
 
--// Class Definition
local Plot = {}
Plot.__index = Plot
 
--// Types
export type Plot = {
	PlotModel: typeof(Assets.PlotTemplate),
	Owner: Player,
	OwnerData: any,
	OnPlotLoaded: (self: Plot) -> (),
	Destroy: (self: Plot) -> (),
}
 
--// ===== Local helpers (kept tiny; reduce repetition) =====
 
-- Bias high values to be rarer (keeps gameplay variance without frequent extremes).
local function biasedMultiplier(minVal: number, maxVal: number, power: number?): number
	local p = power or 2
	local t = math.random()
	t = t ^ p
	return minVal + (maxVal - minVal) * t
end
 
local function withPlayerObj(player: Player)
	-- Defensive wrapper to guard against nil profiles in background loops.
	local obj = DataHandler.GetPlayerObj(player)
	if not obj or not obj.profile then return nil end
	return obj
end
 
local function chooseSurface(plotModel: Model): BasePart?
	if not plotModel or not plotModel:FindFirstChild("PlacementSurface") then return nil end
	local children = plotModel.PlacementSurface:GetChildren()
	if #children == 0 then return nil end
	-- Original code only used first 2; keep behavior but handle size < 2.
	local idx = math.clamp(math.random(1, math.max(2, #children)), 1, #children)
	return children[idx] :: BasePart
end
 
local function modelHalfHeight(model: Model): number
	return AzizUtils.GetModelSize(model).Y / 2
end
 
local function ensureToolHandle(tool: Tool): BasePart
	local handle = tool:FindFirstChild("Handle", true)
	if not handle then error("Tool must have a Handle part!") end
	return handle :: BasePart
end
 
local function ownsVIP(player: Player): boolean
	return AzizUtils.PlayerOwnsGamepass(player, GameSettings.Passes.VIP)
end
 
--// ===== Constructor =====
function Plot.new(plotModel: Model, owner: Player): Plot
	local self: Plot = setmetatable({}, Plot)
 
	self.PlotModel = plotModel
	self.Owner = owner
 
	plotModel.Owner.Value = owner
 
	-- Load in background to avoid blocking spawns/spawns on join.
	task.spawn(function()
		self.OwnerData = DataHandler.WaitForData(owner)
		self:OnPlotLoaded()
		self:HandlePlot()
		self:LoadData()
	end)
 
	return self
end
 
--// ===== Public API =====
 
function Plot:RemoveCreature(id: string, creatureSeed: string, creatureName: string, owner: Player, targetPlayer: Player)
	if self.Owner ~= owner then
		error("Plot owner mismatch; refusing to mutate someone else's state")
	end
 
	local ownerObj = withPlayerObj(self.Owner)
	local targetObj = withPlayerObj(targetPlayer)
	if not ownerObj or not targetObj then return end
 
	-- Give creature back to target's backpack (why: keep inventory in sync when reclaiming/stealing).
	targetObj:Update("CreatureBackpack", function(backpack: { [string]: number })
		local count = (backpack[creatureName] or 0) + 1
		backpack[creatureName] = count
		return backpack
	end)
 
	-- Ensure/create appropriate tool representing this creature.
	local seedTool: Tool? = AzizUtils.GetPlayerToolWithProperty(targetPlayer, function(tool)
		return tool:GetAttribute("CreatureName") == creatureName
	end)
 
	if seedTool == nil then
		seedTool = Plot.CreateCreatureTool(targetPlayer, creatureSeed, creatureName)
	else
		seedTool:SetAttribute("NumCreatures", (seedTool:GetAttribute("NumCreatures") or 0) + 1)
	end
 
	-- Remove creature from plot save.
	ownerObj:Update("PlotCreatures", function(plotInfo: {})
		plotInfo[id] = nil
		return plotInfo
	end)
 
	-- Remove creature model instance.
	local creature: Model? = self.PlotModel.Creatures:FindFirstChild(id) :: Model?
	if creature then
		creature:Destroy()
	end
end
 
function Plot:HandleMovingCreature(creature: Model)
	local plotModel: Model = self.PlotModel
 
	-- Movement loop: advances creature to random surface positions at speed.
	task.spawn(function()
		while creature and creature.Parent and plotModel and plotModel.Parent and plotModel:FindFirstChild("PlacementSurface") do
			local surface = chooseSurface(plotModel)
			if not surface then break end
 
			local startCFrame = creature.WorldPivot
			local endPosition = AzizUtils.RandomSurfacePos(surface) + Vector3.new(0, modelHalfHeight(creature), 0)
			local direction = (endPosition - startCFrame.Position).Unit
			local lookAtCFrame = CFrame.new(endPosition, endPosition + direction)
 
			creature:SetAttribute("NextCFrame", lookAtCFrame)
 
			local travelDistance = (startCFrame.Position - endPosition).Magnitude
			local travelTime = travelDistance / GameSettings.CreaturesSpeed
			task.wait(travelTime)
 
			-- Snap to the computed pose (why: server-authoritative motion).
			creature:PivotTo(lookAtCFrame)
 
			task.wait(AzizUtils.GetRandomNum(1.5, 3, 2))
		end
	end)
end
 
Plot.StolenCreature = {}
 
function Plot:SpawnCreature(seedName: string, creatureName: string, id: string, spawnLocation: CFrame?)
	local plotModel: Model = self.PlotModel
	local owner = self.Owner
 
	-- Clone creature model.
	local creature: Model = (ReplicatedStorage.Assets.DNAPacks[seedName][creatureName] :: Model):Clone()
	if creature.AddTag then
		-- Preserved behavior; project may use a custom tagging helper.
		creature:AddTag("Creature")
	end
 
	-- Attach catch prompt; trigger either returns to owner or initiates steal flow.
	local proximityPrompt = script.CatchProximity:Clone()
	proximityPrompt.Parent = creature:FindFirstChildWhichIsA("BasePart", true)
 
	proximityPrompt.Triggered:Connect(function(player: Player)
		if player == owner then
			self:RemoveCreature(id, seedName, creatureName, owner, owner)
		else
			Plot.StolenCreature[player] = { id, seedName, creatureName, owner, player }
			AzizUtils.PromptPurchase(player, GameSettings.DevProducts.StealCreature, false)
		end
	end)
 
	local creatureInfo = SamplesInfo[seedName].Pack[creatureName]
	creature.Name = id
 
	-- Compute spawn pose.
	if not spawnLocation then
		local surface = chooseSurface(plotModel)
		if not surface then return end
		spawnLocation = CFrame.new(AzizUtils.RandomSurfacePos(surface))
	end
	spawnLocation = spawnLocation * CFrame.new(0, modelHalfHeight(creature), 0)
	creature:PivotTo(spawnLocation)
 
	-- Parent under plot.
	creature.Parent = plotModel.Creatures
 
	-- Play first found sound on spawn (feedback).
	local creatureSound = creature:FindFirstChildWhichIsA("Sound", true)
	if creatureSound then
		creatureSound:Play()
	end
 
	-- Billboard (why: UI/rarity feedback).
	task.spawn(function()
		local billboard = script.CreatureBillboard:Clone()
		local earningsText = billboard.Earnings
		local titleText = billboard.Title
 
		local rarityGradient = script.RarityGradients[creatureInfo.Rarity]:Clone()
		rarityGradient.Parent = titleText
 
		titleText.Text = creatureName
		earningsText.Text = `{creatureInfo.Earnings}/sec`
 
		billboard.Parent = creature:FindFirstChildWhichIsA("BasePart") or creature
	end)
 
	-- Earnings loop (server-authoritative; 1/sec).
	task.spawn(function()
		local ownerObj = withPlayerObj(owner)
		while creature and creature.Parent and ownerObj and ownerObj.profile do
			ownerObj:Update("Cash", function(cash: number)
				return cash + creatureInfo.Earnings
			end)
			task.wait(1)
			ownerObj = withPlayerObj(owner) -- refresh reference if profile changed
		end
	end)
 
	self:HandleMovingCreature(creature)
end
 
function Plot:AddCreature(seedName: string, creatureName: string, spawnLocation: CFrame?)
	local ownerObj = withPlayerObj(self.Owner)
	if not ownerObj then return end
 
	local id = HttpService:GenerateGUID(false)
	local sizeMult = biasedMultiplier(1, 3, 3) -- keep distribution
 
	ownerObj:Update("PlotCreatures", function(plotInfo: {})
		plotInfo[id] = {
			SizeMult = sizeMult,
			SeedName = seedName,
			CreatureName = creatureName,
		}
		return plotInfo
	end)
 
	self:SpawnCreature(seedName, creatureName, id, spawnLocation)
end
 
function Plot:RemoveSeedPlacement(id: string)
	local ownerObj = withPlayerObj(self.Owner)
	if not ownerObj then return end
 
	ownerObj:Update("PlotSeeds", function(plotInfo: {})
		plotInfo[id] = nil
		return plotInfo
	end)
 
	local incubator: Model? = self.PlotModel.Incubators:FindFirstChild(id) :: Model?
	if incubator then
		incubator:Destroy()
	end
end
 
function Plot:SpawnSeed(seedName: string, CFrameOffset: CFrame, startTime: number, id: string)
	local plotModel: Model = self.PlotModel
	local owner = self.Owner
 
	local seedInfo: typeof(SamplesInfo.Baddies) = SamplesInfo[seedName]
	local incubator: Model = (ReplicatedStorage.Assets.Incubators[seedName] :: Model):Clone()
	incubator.Name = id
	incubator.Parent = plotModel.Incubators
	incubator:PivotTo(plotModel.PrimaryPart.CFrame * CFrameOffset)
 
	local titleText: TextLabel = incubator:FindFirstChild("Title", true)
	local growthText: TextLabel = incubator:FindFirstChild("Growth", true)
	titleText.Text = `{seedInfo.DisplayName or seedName} DNA`
 
	local hatchTime = seedInfo.HatchTime
 
	-- Growth loop (why: client sees deterministic percentage; VIP accelerates wall-clock completion).
	task.spawn(function()
		while (tick() - startTime) < ((ownsVIP(owner) and (hatchTime / 5)) or hatchTime) do
			growthText.Text = AzizUtils.FormatRatioToPercentage((tick() - startTime) / hatchTime)
			task.wait(0.1)
		end
 
		growthText.Text = "READY!"
 
		local proximityPrompt = script.HatchProximity:Clone()
		proximityPrompt.Parent = incubator:FindFirstChildWhichIsA("BasePart", true)
 
		proximityPrompt.Triggered:Connect(function()
			local creaturePack = ReplicatedStorage.Assets.DNAPacks[seedName]:GetChildren()
			local rolled: Model = creaturePack[math.random(#creaturePack)] :: Model
 
			local spawnLocation = incubator.WorldPivot - (Vector3.yAxis * modelHalfHeight(incubator))
			self:AddCreature(seedName, rolled.Name, spawnLocation)
			self:RemoveSeedPlacement(id)
		end)
	end)
end
 
function Plot:AddSeedPlacement(seedName: string, worldCFrame: CFrame)
	local plotModel: Model = self.PlotModel
	local ownerObj = withPlayerObj(self.Owner)
	if not ownerObj then return end
 
	local id = HttpService:GenerateGUID(false)
	local CFrameOffset = plotModel.PrimaryPart.CFrame:Inverse() * worldCFrame
	local startTime = tick()
 
	ownerObj:Update("PlotSeeds", function(plotInfo: {})
		plotInfo[id] = {
			SeedName = seedName,
			CFrameComponents = { CFrameOffset:GetComponents() },
			StartTime = startTime,
		}
		return plotInfo
	end)
 
	self:SpawnSeed(seedName, CFrameOffset, startTime, id)
end
 
function Plot:HandlePlot()
	Network.Connect("PlaceSeedInPlot", function(player: Player, seedName: string, worldCFrame: CFrame)
		if player ~= self.Owner then return end
		local playerObj = withPlayerObj(player)
		if not playerObj then return end
 
		local backpack = playerObj:Get("SeedBackpack")
		if not backpack[seedName] or backpack[seedName] < 1 then
			return warn("You do not own this seed.")
		end
 
		playerObj:Update("SeedBackpack", function(b: {})
			b[seedName] -= 1
			return b
		end)
 
		local seedTool: Tool? = AzizUtils.GetPlayerToolWithProperty(player, function(tool)
			return tool:GetAttribute("SampleName") == seedName
		end)
		if seedTool then
			seedTool:SetAttribute("NumSamples", (seedTool:GetAttribute("NumSamples") or 0) - 1)
		end
 
		self:AddSeedPlacement(seedName, worldCFrame)
	end)
end
 
function Plot.CreateCreatureTool(player: Player, creatureSeed: string, creatureName: string, numCreatures: number?)
	local count = numCreatures or 1
 
	local creatureTool = ReplicatedStorage.Assets.CreatureTool:Clone()
	creatureTool:SetAttribute("CreatureSeed", creatureSeed)
	creatureTool:SetAttribute("CreatureName", creatureName)
	creatureTool:SetAttribute("NumCreatures", count)
 
	local creatureModel: Model = (Assets.DNAPacks[creatureSeed][creatureName] :: Model):Clone()
	local handle = ensureToolHandle(creatureTool)
 
	-- Anchor to weld consistently on server.
	handle.Anchored = true
 
	-- Place creature at handle; offset is adjustable per game art.
	local creatureOffset = CFrame.new(0, 0, 0)
	creatureModel:PivotTo(handle.CFrame * creatureOffset)
 
	-- Unanchor & nocollide creature parts for tool physics.
	for _, part in creatureModel:GetDescendants() do
		if part:IsA("BasePart") then
			part.Anchored = false
			part.CanCollide = false
		end
	end
 
	AzizUtils.WeldTo(creatureModel, handle)
	creatureModel.Parent = creatureTool
 
	-- Finalize weld setup.
	handle.Anchored = false
 
	local function refreshName()
		local n = creatureTool:GetAttribute("NumCreatures") or 0
		creatureTool.Name = `{creatureName} {n == 1 and "" or `[{n}]`}`
		if n < 1 then
			-- Auto-cleanup when emptied (why: avoid stale tools).
			creatureTool:Destroy()
		end
	end
 
	refreshName()
	creatureTool:GetAttributeChangedSignal("NumCreatures"):Connect(refreshName)
 
	-- Delay to ensure Backpack exists after respawn.
	task.delay(0.2, function()
		if player and player.Parent then
			creatureTool.Parent = player:FindFirstChild("Backpack") or player
		end
	end)
 
	return creatureTool
end
 
function Plot:LoadData()
	local ownerObj = withPlayerObj(self.Owner)
	if not ownerObj then return end
 
	-- Seeds (incubators)
	for seedId, seedInfo in ownerObj:Get("PlotSeeds") do
		self:SpawnSeed(seedInfo.SeedName, CFrame.new(table.unpack(seedInfo.CFrameComponents)), seedInfo.StartTime, seedId)
	end
 
	-- Creatures
	for creatureId, creatureInfo in ownerObj:Get("PlotCreatures") do
		self:SpawnCreature(creatureInfo.SeedName, creatureInfo.CreatureName, creatureId)
	end
 
	-- Creature tools on join.
	local function loadCreatureTools()
		local obj = withPlayerObj(self.Owner)
		if not obj then return end
		for creatureName, numCreatures in obj:Get("CreatureBackpack") do
			local source = ReplicatedStorage.Assets.DNAPacks:FindFirstChild(creatureName, true)
			if source and source.Parent then
				local creatureSeed = source.Parent.Name
				Plot.CreateCreatureTool(self.Owner, creatureSeed, creatureName, numCreatures)
			end
		end
	end
	loadCreatureTools()
	self.Owner.CharacterAdded:Connect(loadCreatureTools)
end
 
--// Initializes the plot after construction
function Plot:OnPlotLoaded()
	local plotModel = self.PlotModel
	local owner = self.Owner
	if not plotModel or not owner then return end
 
	plotModel.Owner.Value = owner
 
	-- Update plot sign display.
	local sign = plotModel:FindFirstChild("NameSign", true)
	if sign then
		local label = sign:FindFirstChildWhichIsA("TextLabel", true)
		if label then
			label.Text = `{owner.DisplayName}'s Plot`
		end
	end
end
 
--// Replaces and resets the plot when destroyed
function Plot:Destroy()
	local oldPlot = self.PlotModel
	if not oldPlot then return end
 
	local newPlot = Assets.PlotTemplate:Clone()
	newPlot.Name = oldPlot.Name
	newPlot.Parent = oldPlot.Parent
 
	if oldPlot.PrimaryPart then
		newPlot:PivotTo(oldPlot.PrimaryPart.CFrame)
	end
 
	oldPlot:Destroy()
end
 
return Plot
