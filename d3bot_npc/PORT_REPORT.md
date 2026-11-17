# d3bot_npc 3.2.0 – port report

Not verified in Garry's Mod. Everything below is from reading code and plain-Lua tests; no in-game run was possible.

## Runtime architecture (who controls an NPC)
1. `ENT:Initialize` -> `ApplyZombieClass` -> `D3bot_InitializeOrReset` (`sv_extend_npc.lua`, port of `sv_extend_player.lua`)
2. Every server tick, `sv_bot_handler/handle.lua` Think hook: `handler.ThinkFunction` (target acquisition, reroll, offshoot, path update every ~1s) then `handler.UpdateBotCmdFunction` (original handler code) fills `bot.D3bot_Cmd`.
3. `Basics.PounceAuto / WalkAttackAuto / Walk` (port of original `basics.lua`) produce forward/side move, buttons, aim angle.
4. `ENT:RunBehaviour` (the only place that touches the body) converts that `D3bot_Cmd` into NextBot locomotion (`loco:Approach`, `FaceTowards`, `Jump`, crouch, climb velocity, pounce velocity) and melee/ranged attacks.
5. Pathing: `D3bot_UpdatePath` -> `GetNearestNodeOrNil` (x2) -> `GetBestMeshPathOrNil` (original A*) -> `D3bot_SetPath`; `D3bot_UpdatePathProgress` advances nodes with the original `GetContains(pos, 100)`.
No second AI loop exists (checked: no other Think/timer drives movement; `sv_ai_core.lua` only forwards).

## Changed in 3.2.0 (restored to original D3bot behaviour)
- `sv_path.lua`: replaced the custom A* (heap, 0.25s shared path cache, crowd-congestion cost, audit one-way/uphill rejection, failed-link blacklist, 8000-iteration cap) with the original D3bot algorithm and cost model.
- `sh_navmesh.lua`: `GetContains` restored to original semantics (nil = pure 2D check; number = z extrusion; no +-4 padding / hidden 56/34 limits). `GetNearestNodeOrNil` restored to exact original full scan.
- `sv_extend_npc.lua`: `D3bot_UpdatePath` uses original nearest-node selection (removed GetBestNodeNear component/LOS scoring and alternate-target snapping). Unreachable target -> reroll, as in the original.
- `sh_config.lua`: constants restored to original: BotAngLerpFactor 0.125, BotAttackAngLerpFactor 0.125, BotAimAngLerpFactor 0.5, BotAimPosVelocityOffshoot 0.4, Jump/Duck antichance 25, BotNodeMinProximity 40.
- Mesh audit no longer injects "virtual bridge" links (new convar `d3bot_npc_audit_add_bridges`, default 0) and no longer runs automatically (`d3bot_npc_auto_audit_mesh` default 0; run it manually). Crowd cost convar default 0 and is no longer used by pathing.
- Entity: NextBot jump height now equals the value the pathfinder assumes (D3bot's `CalculateJumpHeight`), step height = class StepSize.
- New: `d3bot_npc_sigil_probe` prints whether sigil hits were accepted by ZS natively or only by the compat fallback, and each sigil's nearest nav node + distance.

## Directly ported (unchanged logic)
`Basics.*`, `Undead_Fallback`, `Undead_Headcrab`, `Undead_Crow` handlers, `FindHandler` dispatch, `D3bot_*` entity methods (target pos, LOS cache, pounce trajectory, barricade detect, stuck check, reroll class).

## Required NextBot adaptations
CUserCmd -> `D3bot_Cmd` table; weapon -> virtual weapon proxy (MeleeReach/PounceVelocity/climb); player velocity -> `loco:GetVelocity()`; StartCommand hook -> Think hook; PlayerDeath/Spawn -> NPC lifecycle; climbing/pounce/crow flight implemented with loco velocity.

## Issues from the handoff
- MaxHealth error: not present in this build (no `:MaxHealth()` call remains). Cause was calling `ent:MaxHealth()` on ZS props where `ENT.MaxHealth` is a number; handlers now use guarded `GetMaxHealth()`/`GetSigilHealth()`.
- Sigil damage: UNVERIFIED. ZS source was not provided. Flow is: normal `TakeDamageInfo` with non-zero damage force -> ZS `OnTakeDamage`; only if HP did not drop does the compat fallback apply damage. Use `d3bot_npc_sigil_probe` to see which path is used.
- "bad sigil node": the original just uses the nearest node; I no longer re-snap. The probe shows distance to the nearest node so you can see if a sigil has no usable node nearby (then it needs a node in the D3bot mesh editor).
- Zombie-zombie collision, crow lifecycle, population, ConVars, ULX: not modified.

## Still unverified in-game
Locomotion feel with the original path, sigil destruction, barricade attacking, wall climbing, headcrab pouncing, crow lifecycle, performance with many NPCs.
