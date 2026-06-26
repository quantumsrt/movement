--!strict
--[[
	ProceduralAnimator

	Drives a character's limbs purely through their Motor6D joints instead of
	playing Animation assets. Every frame it computes a target rotation for each
	limb (walk/run swing, idle settle, in-air pose) and eases the joint's `C0`
	toward it.

	The system is rig agnostic: it works for both R6 and R15 by treating the
	four major limbs (two arms, two legs) the same way -- a forward/back swing
	about the torso's lateral (X) axis, pivoted at the joint. That axis is the
	sagittal swing axis for both rig types, so a single code path covers both.

	Usage:
		local animator = ProceduralAnimator.new(character)
		RunService.RenderStepped:Connect(function(dt)
			animator:update(dt)
		end)
		-- later, on death / despawn:
		animator:reset()
]]

local ProceduralAnimator = {}
ProceduralAnimator.__index = ProceduralAnimator

-- Tunable parameters ------------------------------------------------------
local CONFIG = {
	-- WalkSpeed (studs/s) that corresponds to a full-amplitude stride.
	ReferenceSpeed = 16,
	-- How quickly the stride cycles. Phase advances by `speed * Cadence` per
	-- second, so cadence scales naturally with movement speed.
	Cadence = 0.85,
	-- Peak forward/back swing of arms & legs at reference speed.
	MaxSwing = math.rad(48),
	-- Allow a little overswing when sprinting above the reference speed.
	MaxSpeedFactor = 1.4,

	-- Vertical bob of the torso, synced to the stride (two dips per cycle).
	BobAmplitude = 0.18,
	-- Forward lean of the torso while moving, scaled by speed.
	MaxLean = math.rad(9),

	-- Subtle idle "breathing" while standing still.
	IdleBobAmplitude = 0.06,
	IdleSpeed = 1.6,

	-- In-air pose: arms swept up, legs gently parted.
	AirArmAngle = math.rad(120),
	AirLegAngle = math.rad(22),

	-- Below this horizontal speed the character is considered standing.
	MoveThreshold = 0.6,

	-- Easing responsiveness (higher = snappier). Frame-rate independent.
	Responsiveness = 13,
}

-- Per-rig joint layout. `root` bobs/leans the torso; `limbs` are swung.
-- `side` controls left/right phase, `role` makes arms swing opposite legs.
local RIGS = {
	[Enum.HumanoidRigType.R6] = {
		root = "RootJoint",
		limbs = {
			{ name = "Right Shoulder", role = "arm", side = "right" },
			{ name = "Left Shoulder", role = "arm", side = "left" },
			{ name = "Right Hip", role = "leg", side = "right" },
			{ name = "Left Hip", role = "leg", side = "left" },
		},
	},
	[Enum.HumanoidRigType.R15] = {
		root = "Root",
		limbs = {
			{ name = "RightShoulder", role = "arm", side = "right" },
			{ name = "LeftShoulder", role = "arm", side = "left" },
			{ name = "RightHip", role = "leg", side = "right" },
			{ name = "LeftHip", role = "leg", side = "left" },
		},
	},
}

-- Find a Motor6D anywhere in the character by name. Joint parents differ
-- between R6 (all in Torso) and R15 (spread across UpperTorso/LowerTorso),
-- so we search descendants rather than assume a parent.
local function findMotor(character: Instance, name: string): Motor6D?
	for _, descendant in character:GetDescendants() do
		if descendant:IsA("Motor6D") and descendant.Name == name then
			return descendant
		end
	end
	return nil
end

-- Split a CFrame into its translation and pure-rotation parts so we can
-- re-apply a swing rotation about the joint pivot without losing the base
-- orientation baked into the default C0.
local function decompose(cf: CFrame): (Vector3, CFrame)
	return cf.Position, cf.Rotation
end

function ProceduralAnimator.new(character: Model)
	local humanoid = character:WaitForChild("Humanoid") :: Humanoid
	local rootPart = character:WaitForChild("HumanoidRootPart") :: BasePart

	local rig = RIGS[humanoid.RigType]
	assert(rig, "Unsupported humanoid rig type: " .. tostring(humanoid.RigType))

	local self = setmetatable({
		character = character,
		humanoid = humanoid,
		rootPart = rootPart,
		phase = 0, -- stride phase in radians
		limbs = {},
		rootMotor = nil :: Motor6D?,
		rootBaseC0 = nil :: CFrame?,
		rootBob = 0,
		rootPitch = 0,
		rootRoll = 0,
	}, ProceduralAnimator)

	-- Cache every animated limb together with its rest pose.
	for _, def in rig.limbs do
		local motor = findMotor(character, def.name)
		if motor then
			local basePos, baseRot = decompose(motor.C0)
			table.insert(self.limbs, {
				motor = motor,
				role = def.role,
				side = def.side,
				basePos = basePos,
				baseRot = baseRot,
				current = 0, -- eased swing angle (radians)
			})
		else
			warn(`ProceduralAnimator: missing Motor6D "{def.name}"`)
		end
	end

	-- Cache the root joint for torso bob/lean.
	local rootMotor = findMotor(character, rig.root)
	if rootMotor then
		self.rootMotor = rootMotor
		self.rootBaseC0 = rootMotor.C0
	end

	return self
end

-- Frame-rate independent ease toward a target value.
local function ease(current: number, target: number, dt: number): number
	local alpha = 1 - math.exp(-CONFIG.Responsiveness * dt)
	return current + (target - current) * alpha
end

function ProceduralAnimator:update(dt: number)
	dt = math.min(dt, 1 / 20) -- guard against hitches producing huge steps

	local humanoid = self.humanoid
	local velocity = self.rootPart.AssemblyLinearVelocity
	local horizontalSpeed = Vector3.new(velocity.X, 0, velocity.Z).Magnitude

	local state = humanoid:GetState()
	local inAir = state == Enum.HumanoidStateType.Jumping
		or state == Enum.HumanoidStateType.Freefall

	local moving = horizontalSpeed > CONFIG.MoveThreshold

	-- Normalised "how fast are we going" used to scale amplitudes.
	local speedFactor = math.clamp(horizontalSpeed / CONFIG.ReferenceSpeed, 0, CONFIG.MaxSpeedFactor)
	local swingAmplitude = speedFactor * CONFIG.MaxSwing

	-- Advance the stride phase only while grounded and moving so the cycle
	-- pauses cleanly when the character stops.
	if moving and not inAir then
		self.phase += dt * horizontalSpeed * CONFIG.Cadence
	end

	-- Drive each limb toward its target swing angle.
	for _, limb in self.limbs do
		local target: number

		if inAir then
			-- Arms swing up in FRONT of the body, legs part slightly.
			if limb.role == "arm" then
				target = CONFIG.AirArmAngle
			else
				target = (limb.side == "right" and 1 or -1) * CONFIG.AirLegAngle
			end
		elseif moving then
			local sideSign = (limb.side == "right") and 1 or -1
			-- Arms swing opposite to the leg on the same side.
			local roleSign = (limb.role == "arm") and -1 or 1
			target = math.sin(self.phase) * swingAmplitude * sideSign * roleSign
		else
			-- Idle: settle limbs back to rest.
			target = 0
		end

		limb.current = ease(limb.current, target, dt)
		-- Re-apply the swing as a rotation about the joint pivot, preserving
		-- the rest orientation baked into the default C0.
		limb.motor.C0 = CFrame.new(limb.basePos)
			* CFrame.Angles(limb.current, 0, 0)
			* limb.baseRot
	end

	-- Torso bob + directional lean.
	if self.rootMotor and self.rootBaseC0 then
		local targetBob: number
		local targetPitch = 0 -- forward (+) / back (-) lean
		local targetRoll = 0 -- right (+) / left (-) lean

		if inAir then
			targetBob = 0
		elseif moving then
			-- Two vertical dips per stride cycle.
			targetBob = math.cos(self.phase * 2) * CONFIG.BobAmplitude * speedFactor

			-- Lean into the direction of travel, measured relative to the way
			-- the character is facing. Moving forward leans forward, strafing
			-- right leans right, and any blend leans diagonally.
			local localVelocity = self.rootPart.CFrame:VectorToObjectSpace(velocity)
			local forward = -localVelocity.Z -- in Roblox, -Z is the look direction
			local strafe = localVelocity.X -- +X is the character's right
			local ref = CONFIG.ReferenceSpeed
			-- Negative signs tilt the *top* of the torso toward the movement
			-- direction (Roblox's +X rotation pitches backward, +Z rolls left).
			targetPitch = -math.clamp(forward / ref, -1, 1) * CONFIG.MaxLean
			targetRoll = -math.clamp(strafe / ref, -1, 1) * CONFIG.MaxLean
		else
			-- Gentle idle breathing.
			targetBob = math.sin(os.clock() * CONFIG.IdleSpeed) * CONFIG.IdleBobAmplitude
		end

		self.rootBob = ease(self.rootBob, targetBob, dt)
		self.rootPitch = ease(self.rootPitch, targetPitch, dt)
		self.rootRoll = ease(self.rootRoll, targetRoll, dt)

		self.rootMotor.C0 = CFrame.new(0, self.rootBob, 0)
			* CFrame.Angles(self.rootPitch, 0, self.rootRoll)
			* self.rootBaseC0
	end
end

-- Restore every joint to its rest pose (e.g. before the character dies).
function ProceduralAnimator:reset()
	for _, limb in self.limbs do
		limb.current = 0
		limb.motor.C0 = CFrame.new(limb.basePos) * limb.baseRot
	end
	if self.rootMotor and self.rootBaseC0 then
		self.rootBob = 0
		self.rootPitch = 0
		self.rootRoll = 0
		self.rootMotor.C0 = self.rootBaseC0
	end
end

return ProceduralAnimator
