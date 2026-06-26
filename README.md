# Motor6D Movement System

A Roblox character movement system that animates limbs **procedurally through
their `Motor6D` joints** instead of playing `Animation` assets. There are no
animation files anywhere in this project — every walk, run, idle and jump pose
is computed in code each frame and applied as a `Motor6D.C0` rotation.

## How it works

Roblox rigs are held together by `Motor6D` joints (shoulders, hips, the root,
etc.). Each joint exposes a `C0` CFrame that offsets its child part. By rotating
those `C0`s every frame we can swing the arms and legs directly, no timeline or
keyframes required.

The default Roblox character ships with an **`Animate`** `LocalScript` that
plays the stock walk/run/idle/jump animations. Those would fight our joint
writes, so the controller **destroys it** on spawn (and stops any tracks it
already started). The rig is then ours to pose.

### Pieces

| File | Location in game | Role |
| --- | --- | --- |
| `src/shared/ProceduralAnimator.lua` | `ReplicatedStorage.Motor6DMovement` | The reusable animator. Caches each limb's rest pose and eases its `C0` toward a computed target every frame. |
| `src/client/MovementController.client.lua` | `StarterPlayer.StarterCharacterScripts` | Per-character client script. Removes the default `Animate` script, then runs the animator on `RenderStepped`. |

### What it animates

- **Walk / run** — every limb keeps the **same** fore/aft swing (the gait),
  arms opposite the same-side leg. To move in a direction, the hips and
  shoulders **yaw** (turn) so the limbs point the way the character is
  travelling — the legs themselves never change their swing or position, the
  joints just rotate. Steering comes from the strafe component only, so moving
  forward turns nothing, strafing turns fully, and moving backward doesn't spin
  the legs around. Amplitude **and** cadence scale with the character's actual
  horizontal speed, so walking and sprinting differ automatically.
- **Torso** — a vertical bob synced to the stride (two dips per cycle), a
  **turn** toward the direction of travel, and a lean *into* that direction
  (forward when moving forward, back when reversing, left/right when strafing,
  diagonal blends in between) — all scaled by speed.
- **Reversing** — when mostly walking backward, the sideways sway/turn is
  **mirrored**, so a back+left walk sways like a forward+right one (and
  back+right like forward+left).
- **Idle** — a subtle breathing bob lifts the torso, arms and head up and down,
  while the legs stay planted on the floor.
- **In air** (jump / freefall) — arms sweep up, legs part slightly.

All poses are eased toward (frame-rate-independent smoothing), so transitions
between states never snap.

### Rig support

Works with both **R6** and **R15**. The four major limbs (two arms, two legs)
are driven the same way on either rig — a fore/aft gait swing plus a steering
yaw — so a single code path covers both. The rig is detected from
`Humanoid.RigType` and the correct joint names are looked up from a small table
in `ProceduralAnimator.lua`.

## Installing / running

This project is laid out for [Rojo](https://rojo.space).

1. Install Rojo (`rojo` CLI or the Studio plugin).
2. From the project root, start the server:
   ```sh
   rojo serve
   ```
3. In Roblox Studio, connect via the Rojo plugin. This places:
   - `ReplicatedStorage.Motor6DMovement.ProceduralAnimator`
   - `StarterPlayer.StarterCharacterScripts.MovementController`
4. Play. Walk, run, jump — all movement is now Motor6D-driven.

> No `build` step or animation uploads are needed. If you don't use Rojo, just
> copy the two scripts into the matching services manually (keep the folder name
> `Motor6DMovement` in `ReplicatedStorage`).

## Tuning

Open `ProceduralAnimator.lua` and adjust the `CONFIG` table:

| Field | Effect |
| --- | --- |
| `ReferenceSpeed` | WalkSpeed that maps to a full-amplitude stride. |
| `Cadence` | How fast the stride cycles relative to speed. |
| `MaxSwing` | Peak arm/leg fore/aft swing angle (the gait). |
| `LimbSteerYaw` | How far hips/shoulders turn the limbs toward the travel direction. |
| `TorsoSteerYaw` | How far the torso turns toward the travel direction. |
| `BobAmplitude` / `MaxLean` | Torso bob height and max directional lean angle. |
| `IdleBobAmplitude` / `IdleSpeed` | Idle breathing depth and rate. |
| `AirArmAngle` / `AirLegAngle` | In-air pose. |
| `Responsiveness` | Easing snappiness between poses. |

## Notes

- Animation is cosmetic and runs on the client for smoothness. Motor6D `C0`
  changes still replicate, so other players see the moving limbs.
- The animator restores the rig to its rest pose on death/despawn via
  `animator:reset()`.
