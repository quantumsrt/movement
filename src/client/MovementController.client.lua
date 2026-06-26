--!strict
--[[
	MovementController (client)

	Lives in StarterPlayer.StarterCharacterScripts, so it runs once per
	character spawn on the owning client.

	Responsibilities:
		1. Completely remove Roblox's default, animation-based movement by
		   killing the "Animate" script that Roblox inserts into the rig and
		   stopping any animation tracks it already started.
		2. Run the ProceduralAnimator every render frame so all movement comes
		   from Motor6D joints instead.

	Procedural animation is purely cosmetic, so it runs on the client via
	RenderStepped for the smoothest result. The Motor6D writes still replicate,
	so other players see the moving limbs.
]]

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ProceduralAnimator = require(
	ReplicatedStorage:WaitForChild("Motor6DMovement"):WaitForChild("ProceduralAnimator")
)

local character = script.Parent :: Model
local humanoid = character:WaitForChild("Humanoid") :: Humanoid

-- 1. Strip out Roblox's default animation system --------------------------

-- Stop any animation tracks the default "Animate" script may have started
-- before we got to disable it.
local function stopDefaultTracks()
	local animator = humanoid:FindFirstChildOfClass("Animator")
	if animator then
		for _, track in animator:GetPlayingAnimationTracks() do
			track:Stop(0)
		end
	end
end

-- The "Animate" LocalScript is what plays the stock walk/run/idle/jump
-- animations. Destroying it stops those animations from ever (re)playing,
-- leaving the rig free for our Motor6D-driven poses.
local function removeDefaultAnimate(instance: Instance?)
	if instance and instance.Name == "Animate" and instance:IsA("LuaSourceContainer") then
		instance:Destroy()
		stopDefaultTracks()
	end
end

-- Handle whichever order things load in: the Animate script may already be
-- present, or it may be inserted a moment after the character spawns.
removeDefaultAnimate(character:FindFirstChild("Animate"))
character.ChildAdded:Connect(removeDefaultAnimate)
stopDefaultTracks()

-- 2. Drive the rig procedurally -------------------------------------------

local animator = ProceduralAnimator.new(character)

local connection: RBXScriptConnection
connection = RunService.RenderStepped:Connect(function(dt)
	-- Bail out cleanly once this character is gone or dead.
	if not character.Parent or humanoid.Health <= 0 then
		animator:reset()
		connection:Disconnect()
		return
	end
	animator:update(dt)
end)

humanoid.Died:Connect(function()
	if connection.Connected then
		connection:Disconnect()
	end
end)
