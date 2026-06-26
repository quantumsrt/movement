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

	-- Steering: how far the hips/shoulders yaw to turn the limbs toward the
	-- direction of travel at full sideways speed. The limbs keep their normal
	-- fore/aft gait; this yaw just points them the way the character is moving.
	LimbSteerYaw = math.rad(50),
	-- How far the torso itself turns toward the direction of travel (subtler
	-- than the limbs, so the upper body leads rather than snaps around).
	TorsoSteerYaw = math.rad(14),
	-- When the backward share of travel exceeds this fraction, the sideways
	-- sway/turn is mirrored, so reversing diagonally sways like the opposite
	-- forward diagonal (back+left reads like forward+right, and vice versa).
	BackwardInvertThreshold = 0.3,

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
		rootYaw = 0,
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
				baseC0 = motor.C0, -- full rest C0 (position + rotation)
				current = CFrame.identity, -- eased local rotation offset (yaw + swing)
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

	-- Frame-rate independent smoothing factor for this frame.
	local alpha = 1 - math.exp(-CONFIG.Responsiveness * dt)

	-- Steering. The body turns/sways toward the direction of travel, driven by
	-- the lateral (strafe) component: forward turns nothing, strafing turns
	-- fully, and backward does NOT spin the legs around. When mostly reversing,
	-- the sideways sway is mirrored so a back+left walk sways like forward+right.
	local localVelocity = self.rootPart.CFrame:VectorToObjectSpace(velocity)
	local steerLateral = 0
	if moving and horizontalSpeed > 0.05 then
		local lateral = math.clamp(localVelocity.X / CONFIG.ReferenceSpeed, -1, 1)
		if localVelocity.Z / horizontalSpeed > CONFIG.BackwardInvertThreshold then
			lateral = -lateral -- moving backwards: mirror the sideways sway/turn
		end
		steerLateral = lateral
	end
	local steerYaw = -steerLateral * CONFIG.LimbSteerYaw

	-- Torso bob, turn-toward-movement, and lean. Computed before the limbs so
	-- the legs can cancel the breathing bob and stay planted (see below).
	if self.rootMotor and self.rootBaseC0 then
		local targetBob: number
		local targetPitch = 0 -- forward (+) / back (-) lean
		local targetRoll = 0 -- right (+) / left (-) lean
		local targetYaw = 0 -- turn toward the direction of travel

		if inAir then
			targetBob = 0
		elseif moving then
			-- Two vertical dips per stride cycle.
			targetBob = math.cos(self.phase * 2) * CONFIG.BobAmplitude * speedFactor

			-- Turn the torso toward the way the character is moving. This uses
			-- the mirrored sway so reversing diagonally turns the opposite way.
			targetYaw = -steerLateral * CONFIG.TorsoSteerYaw
			-- Lean into the *actual* direction of travel (never mirrored), so the
			-- body leans back-and-left when reversing left, not forward-right.
			-- Pitch leans back when reversing; roll leans toward the strafe side
			-- (moving left leans left, moving right leans right).
			targetPitch = -math.clamp(-localVelocity.Z / CONFIG.ReferenceSpeed, -1, 1) * CONFIG.MaxLean
			targetRoll = math.clamp(localVelocity.X / CONFIG.ReferenceSpeed, -1, 1) * CONFIG.MaxLean
		else
			-- Gentle idle breathing.
			targetBob = math.sin(os.clock() * CONFIG.IdleSpeed) * CONFIG.IdleBobAmplitude
		end

		self.rootBob = ease(self.rootBob, targetBob, dt)
		self.rootPitch = ease(self.rootPitch, targetPitch, dt)
		self.rootRoll = ease(self.rootRoll, targetRoll, dt)
		self.rootYaw = ease(self.rootYaw, targetYaw, dt)

		self.rootMotor.C0 = CFrame.new(0, self.rootBob, 0)
			* CFrame.Angles(self.rootPitch, self.rootYaw, self.rootRoll)
			* self.rootBaseC0
	end

	-- The breathing/bob above moves the whole torso, and the arms ride along
	-- with it, so they rise and fall too. The legs are children of the torso as
	-- well, so to keep them planted while idle we cancel that vertical bob on
	-- the hips only.
	local idle = not inAir and not moving
	local legBobCancel = idle and Vector3.new(0, -self.rootBob, 0) or Vector3.zero

	-- Drive each limb. The fore/aft swing (the gait) is identical regardless of
	-- travel direction; only the hip/shoulder yaw changes, turning the whole
	-- limb to face the way the character is moving.
	for _, limb in self.limbs do
		local targetRot: CFrame
		if inAir then
			-- Arms raise in front, legs part; a simple fore/aft rotation.
			local angle = (limb.role == "arm") and CONFIG.AirArmAngle
				or (limb.side == "right" and 1 or -1) * CONFIG.AirLegAngle
			targetRot = CFrame.Angles(angle, 0, 0)
		elseif moving then
			local sideSign = (limb.side == "right") and 1 or -1
			-- Arms swing opposite to the leg on the same side.
			local roleSign = (limb.role == "leg") and 1 or -1
			local swing = math.sin(self.phase) * sideSign * roleSign * swingAmplitude
			-- Hip/shoulder yaw first, then the constant fore/aft swing: the
			-- limb's own rotation never changes, the yaw steers it.
			targetRot = CFrame.Angles(0, steerYaw, 0) * CFrame.Angles(swing, 0, 0)
		else
			-- Idle: settle back to the rest pose.
			targetRot = CFrame.identity
		end

		limb.current = limb.current:Lerp(targetRot, alpha)

		-- Legs keep planted during idle breathing; everything else is pure
		-- rotation about the joint (no positional change).
		local pivot = (limb.role == "leg") and (limb.basePos + legBobCancel) or limb.basePos
		limb.motor.C0 = CFrame.new(pivot) * limb.current * limb.baseRot
	end
end

-- Restore every joint to its rest pose (e.g. before the character dies).
function ProceduralAnimator:reset()
	for _, limb in self.limbs do
		limb.current = CFrame.identity
		limb.motor.C0 = limb.baseC0
	end
	if self.rootMotor and self.rootBaseC0 then
		self.rootBob = 0
		self.rootPitch = 0
		self.rootRoll = 0
		self.rootYaw = 0
		self.rootMotor.C0 = self.rootBaseC0
	end
end

return ProceduralAnimator
