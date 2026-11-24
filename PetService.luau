-- Connected Discord-GitHub
--!strict
local ServerStorage = game:GetService("ServerStorage")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

-- Formation
local PET_SPACING = 4
local BEHIND_DISTANCE = 4
local CURVE_DEPTH = 1.5
local HEIGHT_OFFSET = 1

-- Movement
local FOLLOW_SMOOTHING = 5
local BOB_FREQUENCY = 2
local BOB_AMPLITUDE = 0.5
local TELEPORT_DISTANCE = 50
local MIN_MOVE_DISTANCE = 0.01

-- Attack
local TRIGGER_INTERVAL = 1
local MIN_DIRECTION_LENGTH = 0.001
local ATTACK_DISTANCE = 5
local ATTACK_RANGE_TOLERANCE = 0.2
local DAMAGE_INTERVAL = 0.5
local ATTACK_DAMAGE = 1

local MAX_EQUIPPED_PETS = 3

local PetModels = ServerStorage.PetModels
local Breakables = workspace.Breakables
local DetectArea = workspace.DetectArea

local PetService = {}
local Pet = {}

-- Tells Pet to look in the Pet table when an instance cannot find a key.
-- When a Pet instance cannot find a method in its own table,
-- it will look through its Metatable for the missing key so it can execute the method.
-- This allows all instances to share the same methods while only storing their own pet data.
Pet.__index = Pet

export type PetData = {
	Name: string,
	Weight: number,
	Multiplier: number,
	Rarity: string,
	ImageId: string,
}
type PetState = "Following" | "Attacking"

-- Defines the type of a Pet instance by combining its properties with the Pet Metatable.
-- Uses :: to tell the type checker that the empty table has the specified properties and types.
-- Uses typeof() to retrieve the type of the value returned by setmetatable(),
-- making the Pet type match the instance created by Pet.new.
export type Pet = typeof(setmetatable(
	{} :: {
		petId: number,
		petData: PetData,
		petModel: Model,
		currentCFrame: CFrame,
		petState: PetState,
		target: Model?,
		owner: Player,
		damageTimer: number,
	},
	Pet
))

type PetsById = { [number]: Pet }
type PlayerPets = { [Player]: PetsById }

local equippedPets: PlayerPets = {}
local ActivePets: Folder = Instance.new("Folder")
ActivePets.Parent = workspace
local triggerTimer: number = 0

function Pet.new(petId: number, petData: PetData, petModel: Model, currentCFrame: CFrame, owner: Player): Pet
	local self = {
		petId = petId,
		petData = petData,
		petModel = petModel,
		currentCFrame = currentCFrame,
		petState = "Following" :: PetState,
		target = nil :: Model?,
		owner = owner,
		damageTimer = 0,
	}
	
	-- Sets a Metatable on this instance so it can access the methods.
	-- setmetatable returns the same table with the Metatable attached,
	-- so we can directly return the result of setmetatable.
	return setmetatable(self, Pet)
end

function Pet.Destroy(self: Pet): ()
	self.petModel:Destroy()
end

-- This function first uses the offset's Magnitude to calculate the distance between the pet and the target position,
-- then checks whether the pet should be teleported.
-- If the pet does not need to be teleported, Lerp uses alpha to calculate its position and rotation for this frame.
-- When calculating the rotation, checking whether the pet's movement distance is greater than MIN_MOVE_DISTANCE
-- prevents CFrame.lookAt from looking at the same position it is starting from when the pet is stationary,
-- which would cause the resulting rotation to contain NaN values.
function Pet.Update(self: Pet, targetCFrame: CFrame, alpha: number): ()
	local newPosition: Vector3
	local newRotation: CFrame
	local currentCFrame: CFrame = self.currentCFrame
	local offsetToTarget: Vector3 = targetCFrame.Position - currentCFrame.Position
	if offsetToTarget.Magnitude > TELEPORT_DISTANCE then
		newPosition = targetCFrame.Position
		newRotation = currentCFrame.Rotation
	else
		newPosition = currentCFrame.Position:Lerp(targetCFrame.Position, alpha)
		local movement: Vector3 = newPosition - currentCFrame.Position
		movement = Vector3.new(movement.X, 0, movement.Z)
		if movement.Magnitude > MIN_MOVE_DISTANCE then
			local targetRotation: CFrame = CFrame.lookAt(currentCFrame.Position, currentCFrame.Position + movement).Rotation
			newRotation = currentCFrame.Rotation:Lerp(targetRotation, alpha) 
		else
			newRotation = currentCFrame.Rotation
		end
	end
	local goalCFrame: CFrame = CFrame.new(newPosition) * newRotation
	self.petModel:PivotTo(goalCFrame)
	self.currentCFrame = goalCFrame
end

function Pet.StartAttack(self: Pet, target: Model): ()
	self.petState = "Attacking"
	self.target = target
end

function Pet.StopAttack(self: Pet): ()
	self.petState = "Following"
	self.target = nil
end

-- This function first checks whether the pet is within attacking range.
-- ATTACK_RANGE_TOLERANCE is added because the distance between the pet and the breakable
-- may not exactly match ATTACK_DISTANCE, allowing a small margin when checking the attacking range.
-- delta represents the time elapsed between the previous frame and the current frame.
-- damageTimer accumulates delta and checks whether the attack cooldown has elapsed,
-- preventing the pet from attacking too frequently.
function Pet.TryDamage(self: Pet, delta: number): ()
	if self.petState ~= "Attacking" then return end
	if self.target == nil or self.target.Parent == nil then return end
	local offset: Vector3 = self.target:GetPivot().Position - self.currentCFrame.Position
	if offset.Magnitude > ATTACK_DISTANCE + ATTACK_RANGE_TOLERANCE then return end
	self.damageTimer += delta
	if self.damageTimer > DAMAGE_INTERVAL then
		self.damageTimer -= DAMAGE_INTERVAL
		local takeDamage: Instance? = self.target:FindFirstChild("TakeDamage")
		if takeDamage == nil or not takeDamage:IsA("BindableEvent") then return end
		takeDamage:Fire(self.owner, ATTACK_DAMAGE)
	end
end

local function getRoot(player: Player): BasePart?
	if player.Character == nil then return nil end
	local root: Instance? = player.Character:FindFirstChild("HumanoidRootPart")
	if root == nil or not root:IsA("BasePart") then return nil end
	return root
end

local function isPlayerInZone(player: Player): boolean
	local root = getRoot(player)
	if root == nil then return false end

	-- Converts the player's position into DetectArea's local coordinate space,
	-- then compares each axis' distance with half of the corresponding area size.
	-- If all three axes X, Y, and Z are within their respective ranges, the player is considered to be inside the area.
	local playerLocalPoint: Vector3 = DetectArea.CFrame:PointToObjectSpace(root.Position)
	local playerX: number = math.abs(playerLocalPoint.X)
	local playerY: number = math.abs(playerLocalPoint.Y)
	local playerZ: number = math.abs(playerLocalPoint.Z)
	local halfSize: Vector3 = DetectArea.Size / 2
	if playerX < halfSize.X and playerY < halfSize.Y and playerZ < halfSize.Z then
		return true
	end
	return false
end

local function findTarget(): Model?
	local breakables: {Instance} = Breakables:GetChildren()
	if #breakables == 0 then return nil end
	local randNum: number = math.random(1, #breakables)
	local randBreakable: Instance = breakables[randNum]
	if not randBreakable:IsA("Model") then return nil end
	return randBreakable
end

local function getFormationOffset(index: number, totalPets: number): CFrame
	local midIndex: number = (totalPets + 1) / 2
	local x: number = (midIndex - index) * PET_SPACING
	local z: number = BEHIND_DISTANCE - CURVE_DEPTH * math.abs(index - midIndex)
	return CFrame.new(x, HEIGHT_OFFSET, z)
end

local function getAttackCFrame(pet: Pet): CFrame?
	if pet.target == nil or pet.target.Parent == nil then return nil end
	local targetPosition: Vector3 = pet.target:GetPivot().Position
	local offset: Vector3 = pet.currentCFrame.Position - targetPosition
	local attackPosition: Vector3 = Vector3.xAxis
	
	-- When the pet overlaps with the breakable, the offset's magnitude becomes close to 0,
	-- making it impossible to obtain a valid unit vector.
	-- Therefore, we check the magnitude first to prevent NaN values.
	if offset.Magnitude >= MIN_DIRECTION_LENGTH then
		attackPosition = offset.Unit
	end
	local attackCFrame: CFrame = CFrame.new(targetPosition + attackPosition * ATTACK_DISTANCE)
	return attackCFrame
end

local function updateAttackTriggers(): ()
	for player in pairs(equippedPets) do
		if not isPlayerInZone(player) then continue end
		for _, pet in pairs(equippedPets[player]) do
			if pet.petState ~= "Following" then continue end
			local newTarget: Model? = findTarget()
			if newTarget == nil then continue end
			pet:StartAttack(newTarget)
		end
	end
end

local function updatePlayerPets(player: Player, delta: number): ()
	local root: BasePart? = getRoot(player)
	if root == nil then return end
	if equippedPets[player] == nil then return end
	
	-- Sorts the keys of equippedPets[player] to ensure each pet keeps the same position in every frame.
	local petIds: { number } = {}
	for petId in pairs(equippedPets[player]) do
		table.insert(petIds, petId)
	end
	table.sort(petIds)
	
	local totalPets: number = #petIds
	
	-- Calculates the smoothing factor based on FOLLOW_SMOOTHING and delta,
	-- so the pets' movement is less affected by the time between frame updates.
	local alpha: number = 1 - math.exp(-FOLLOW_SMOOTHING * delta)
	
	for index, petId in ipairs(petIds) do
		local targetCFrame: CFrame? = nil
		local pet: Pet = equippedPets[player][petId]
		if pet.petState == "Following" then
			local formationOffset: CFrame = getFormationOffset(index, totalPets)
			
			-- Uses os.clock() to make math.sin() continuously oscillate between -1 and 1, creating the pet bobbing effect.
			-- BOB_FREQUENCY represents the bobbing speed.
			-- index offsets the phase of each pet's bobbing motion.
			-- BOB_AMPLITUDE represents the bobbing amplitude.
			local bobOffset: number = math.sin(os.clock() * BOB_FREQUENCY + index) * BOB_AMPLITUDE
			
			targetCFrame = root.CFrame * formationOffset * CFrame.new(0, bobOffset, 0)
		elseif pet.petState == "Attacking" then
			local attackCFrame: CFrame? = getAttackCFrame(pet)
			if attackCFrame ~= nil then
				targetCFrame = attackCFrame
			else
				pet:StopAttack()
			end
		end
		if targetCFrame == nil then continue end
		pet:Update(targetCFrame, alpha)
		pet:TryDamage(delta)
	end
end

function PetService.Equip(player: Player, petId: number, petData: PetData): boolean
	if equippedPets[player] ~= nil then
		local petCount: number = 0
		for _, pet in pairs(equippedPets[player]) do
			if pet.petId == petId then return false end
			petCount += 1
		end
		if petCount >= MAX_EQUIPPED_PETS then return false end
	end

	local petModel = PetModels:FindFirstChild(petData.Name)
	if petModel == nil or not petModel:IsA("Model") then return false end
	local root = getRoot(player)
	if root == nil then return false end

	local petModelCloned: Model = petModel:Clone()
	if equippedPets[player] == nil then
		equippedPets[player] = {}
	end
	equippedPets[player][petId] = Pet.new(petId, petData, petModelCloned, root.CFrame, player)
	petModelCloned.Parent = ActivePets

	return true
end

function PetService.Unequip(player: Player, petId: number): boolean
	if equippedPets[player] == nil then return false end
	local pet: Pet? = equippedPets[player][petId]
	if pet == nil then return false end
	pet:Destroy()
	equippedPets[player][petId] = nil
	return true
end

function PetService.Clear(player: Player): ()
	if equippedPets[player] == nil then return end
	for _, pet in pairs(equippedPets[player]) do
		pet:Destroy()
	end
	equippedPets[player] = nil
end

Players.PlayerRemoving:Connect(function(player): ()
	PetService.Clear(player)
end)

-- Uses Heartbeat to update the attack trigger timer and all equipped pets every frame.
-- delta represents the time elapsed between the previous frame and the current frame,
-- allowing the timers and pet movement to be updated based on the actual frame time.
RunService.Heartbeat:Connect(function(delta): ()
	triggerTimer += delta
	if triggerTimer > TRIGGER_INTERVAL then
		triggerTimer -= TRIGGER_INTERVAL
		updateAttackTriggers()
	end
	for player in pairs(equippedPets) do
		updatePlayerPets(player, delta)
	end
end)

return PetService