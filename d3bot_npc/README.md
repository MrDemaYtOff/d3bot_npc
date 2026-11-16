# D3bot NPC — Slotless AI Zombies for Original JetBoom Zombie Survival (v3.0.0)

`d3bot_npc` adapts **AzBot / D3bot**'s custom navigation graph, A\* pathfinding, class behaviors, username pools, and Zombie Survival automation onto **slotless `base_nextbot` entities** (`d3bot_npc_zombie`). It lets you play solo or co-op on **original JetBoom Zombie Survival (`zombiesurvival`)** against configurable zombie hordes, bosses, and intermission crows **without consuming any server player slots** (`maxplayers` stays 100% free).

---

## What's New in v3.0.0 — Full Engineering Overhaul

### 1. Navmesh & A\* Navigation Fixes
- **Long Escalator & Ramp Walkability (`sv_navmesh_audit.lua`, `sv_path.lua`)**: Computed cached `CachedSlopeDeg` and `CachedDist2D` on links so gentle ramps and escalators (`slopeAngle <= 46°` and `dist2D >= 95u`) remain **bidirectional uphill**, while sheer drop-offs and steep ledges stay enforced as uphill-forbidden `RuntimeOneWay` downhill drops. Raises default A\* iteration cap from `6500` to `8000`.
- **Recoverable `RuntimeEmbedded` Soft Penalty (`sv_path.lua`)**: Changed `RuntimeEmbedded` intermediate nodes from a hard route ban to a `+1800` soft A\* penalty so zombies avoid stuck-prone spots when bypasses exist without bricking corridors where the only link touches an embedded node.
- **Floor-Continuous String-Pulling & Direct Chase (`sv_ai_core.lua`)**: `TryShortcutWaypoint` now refuses to shortcut through `RuntimeEmbedded` nodes, narrow bottleneck doorways (`RuntimeBottleneckScore >= 2`), or `RuntimeWorldBlocked` links, and verifies floor continuity with a 2-point downward trace. Tightened cross-node `CanWalkDirectlyToTarget` to `220u` with two-sample gap checks across spans `>130u`.
- **Tier-3 -> Tier-4 Anti-Loop Escalation (`sv_ai_core.lua`)**: Tracks `ConsecutiveTier3` route-blacklist reroutes and escalates cleanly to Tier-4 recovery after two consecutive stalled reroutes instead of looping infinitely.
- **Ladders, Water & Doors (`sv_ai_core.lua`, `init.lua`)**: Added water swim-up recovery (`WaterLevel() >= 2`), downward-ladder detection (`isLadderDescending`) so NPCs do not jump down ladders, fixed downward climb velocity in `ExecuteClimb` (`-40`), and cleared `BarricadeAttackEntity` when doors open or fall behind the NPC.

### 2. Garry's Mod / Zombie Survival Compatibility & Combat Fixes
- **Animated Fallbacks & Wide Barricade Melee (`entities/d3bot_npc_zombie/init.lua`)**: Expanded `SAFE_FALLBACK_ACTS` in `PlaySafeActivity` to eliminate T-posing on missing sequences; switched fallback melee hit checks to `NearestPoint(origin)` and aim-facing to `NearestPoint(myPos)` so zombies cleanly strike wide nailed barricades and angled props.
- **Bloated Zombie Death Splash (`init.lua`)**: Added LOS-checked `Bloated Zombie` poison death splash in `OnKilled`.
- **Extended ZS Player Stubs & Guarded HUD (`shared.lua`, `cl_init.lua`)**: Added compatibility shims (`IsPlaying`, `BarricadeGhosting`, `IsSkillActive`, `HasTrinket`, `Armor`, `MaxArmor`, `FlashlightIsOn`, `InVehicle`, `GetRagdollEntity`, `HasGodMode`), guarded `ShouldCollide` entity checks, and guarded client HUD/scoreboard label controls with `IsValid(...)`.
- **Immediate Population Catch-Up & Clean Cleanup (`sv_population.lua`, `sv_zs_compat.lua`, `ulx/modules/sh/d3bot_npc.lua`)**: Immediate catch-up spawns when below initial roster quota (up to 4/tick), `d3bot_npc_enabled 0` live cleanup callback, explicit `classQuery` validation on spawn commands, `PostCleanupMap` entity/cache flush, evenly distributed fallback node spawning across `MainComponentId`, and ULX cap raised to `200` (`64` per `spawnclass`).

### 3. Hot-Path Memory, O(1) Lookup & Net Optimization
- **O(1) Navmesh Normalization & Zero-Alloc Geometry (`sh_navmesh.lua`)**: Precomputed lowercase parameter lookup maps, eliminated `from(...):SelV(...)` allocations inside `ForceGetLink`, restricted `itemParamChanged` spatial re-indexing strictly to spatial keys (`Pos`/`Area`), mutated `item.Pos:SetUnpacked(...)` in place, and added scalar `GetClosestPointCoords` + scratch-table `scoredScratch` in `GetBestNodeNear`.
- **Correct BFS Falloff & Null-Safe Node Blocks (`sh_utilities.lua`)**: Rewrote `NeighbourNodeFalloff` as a depth-bounded FIFO BFS with `visited` tracking and `math.max` falloff propagation, and guarded nil positions in `computeNodeBlocked`.
- **Zero-Alloc Overlay & Trace Constants (`sv_debug.lua`, `sv_navmesh_audit.lua`)**: Hoisted all overlay `Color`/`Vector` allocations and virtual-bridge repair trace scratch vectors outside loops.
- **Lean Roster Networking & Replication (`sh_roster.lua`, `sh_config.lua`)**: Removed unused `d3bot_npc_roster_killfeed` net string, targeted `Roster.BroadcastSync(ply)` on `PlayerInitialSpawn`, expanded roster sync cap to `511` (`UInt 9`), pruned stale `ClientProxies`, and replicated `d3bot_npc_nocollide_zombies` via `FCVAR_REPLICATED` + change callback calling `CollisionRulesChanged()`.

---

## Core Capabilities Preserved (100% Slotless)

- **Zero Player Slots Consumed**: Every zombie spawns via `ents.Create("d3bot_npc_zombie")` (`base_nextbot`) — zero `player.CreateNextBot()`, zero `CreateFakeClient()`, zero ULX player slot kicks.
- **Automatic Navmesh Audit (`sv_navmesh_audit.lua`)**: Bridges stranded nearby components (`<175u`), marks sheer uphill edges downhill-only, flags dead ends and low-ceiling crouch nodes, and supports optional `.npc_patch.txt` sidecars.
- **Multi-Source Navigation**: Native D3bot `.txt` + `.params.txt` graphs (with floor-Z area containment and binary-heap A\*), Source Engine `.nav` fallback (`d3bot_npc_use_source_nav 1`), and open-field no-nav fallback (`d3bot_npc_no_nav_fallback 1`).
- **JetBoom Zombie Survival Parity**: Solo/low-player `MinPlayersBridge`, boss wave spawns (`Wave 2+`), infliction/wave class scaling, intermission Crow transformation, nailed barricade destruction, ranged projectiles, killfeed, TargetID, and TAB scoreboard injection.

---

## Installation

1. Copy the **`d3bot_npc/`** folder into:
   ```text
   garrysmod/addons/d3bot_npc/
   ```
2. *(Optional)* Place D3bot navmesh files in:
   ```text
   garrysmod/data/d3bot/navmesh/map/<mapname>.txt
   garrysmod/data/d3bot/navmesh/map/<mapname>.params.txt
   ```
3. Launch **`zombiesurvival`**. No Zombie Survival or ULX core files need modification.

---

## ConVars (`39`) & Commands (`24` Console / `30` ULX)

- **Core Population**: `d3bot_npc_enabled`, `d3bot_npc_auto_spawn`, `d3bot_npc_respawn`, `d3bot_npc_desired_zombies`, `d3bot_npc_max_population`, `d3bot_npc_zombies_per_human`, `d3bot_npc_zombies_per_wave`, `d3bot_npc_zombies_per_human_wave`, `d3bot_npc_zombies_max_per_human`, `d3bot_npc_spawn_interval`, `d3bot_npc_respawn_delay`, `d3bot_npc_wave_zero_spawn`, `d3bot_npc_intermission_cleanup`, `d3bot_npc_intermission_crows`, `d3bot_npc_bosses`, `d3bot_npc_min_players_bridge`, `d3bot_npc_solo_wave_zero_seconds`
- **Physics, Identity & ZS Integration**: `d3bot_npc_nocollide_zombies`, `d3bot_npc_ragdoll_lifetime`, `d3bot_npc_name_list`, `d3bot_npc_name_prefix`, `d3bot_npc_show_enemy_targetid`, `d3bot_npc_node_damage`, `d3bot_npc_suppress_d3bot_spawns`, `d3bot_npc_contribute_infliction`, `d3bot_npc_debug`
- **Navigation & Crowd Steering**: `d3bot_npc_path_budget`, `d3bot_npc_separation_force`, `d3bot_npc_crowd_avoidance`, `d3bot_npc_crowd_congestion_weight`, `d3bot_npc_whisker_avoidance`, `d3bot_npc_stuck_recovery`, `d3bot_npc_link_fail_penalty`, `d3bot_npc_path_recalc_interval`, `d3bot_npc_auto_audit_mesh`, `d3bot_npc_allow_last_resort_tp`, `d3bot_npc_use_source_nav`, `d3bot_npc_source_nav_override`, `d3bot_npc_no_nav_fallback`
- **Console Commands**: `d3bot_npc_spawn [count] [class]` · `d3bot_npc_add [count] [class]` *(up to 200)* · `d3bot_npc_spawn_here [class] [count]` · `d3bot_npc_remove [target]` · `d3bot_npc_remove_all` · `d3bot_npc_population [count]` · `d3bot_npc_botmod [mod]` · `d3bot_npc_setclass <target|all> <class>` · `d3bot_npc_forceclass <class|auto>` · `d3bot_npc_setname <target> <name>` · `d3bot_npc_spawnboss [class]` · `d3bot_npc_list` · `d3bot_npc_status` · `d3bot_npc_startwave` · `d3bot_npc_resetpaths` · `d3bot_npc_autospawn [0/1]` · `d3bot_npc_reloadmesh` · `d3bot_npc_list_classes` · `d3bot_npc_debug_toggle` · `d3bot_npc_audit_mesh` · `d3bot_npc_repair_mesh [save]` · `d3bot_npc_inspect_node [id]` · `d3bot_npc_debug_npc [target|stuck|all]` · `d3bot_npc_nav_stats`
- **ULX Category (`D3bot NPC`)**: `!d3botnpc_add`, `!d3botnpc_spawn`, `!d3botnpc_spawnclass`, `!d3botnpc_spawnhere`, `!d3botnpc_spawnboss`, `!d3botnpc_remove`, `!d3botnpc_removeall`, `!d3botnpc_respawn`, `!d3botnpc_count`, `!d3botnpc_botmod`, `!d3botnpc_zombiesperplayer`, `!d3botnpc_maxpopulation`, `!d3botnpc_autospawn`, `!d3botnpc_enabled`, `!d3botnpc_setclass`, `!d3botnpc_forceclass`, `!d3botnpc_setname`, `!d3botnpc_setteam`, `!d3botnpc_list`, `!d3botnpc_status`, `!d3botnpc_startwave`, `!d3botnpc_intermissioncrows`, `!d3botnpc_reloadmesh`, `!d3botnpc_resetpaths`, `!d3botnpc_debug`, `!d3botnpc_auditmesh`, `!d3botnpc_repairmesh`, `!d3botnpc_inspectnode`, `!d3botnpc_debugnpc`, `!d3botnpc_navstats`

---

## Live Garry's Mod Test Plan (25 Checks)

Run on a live **JetBoom Zombie Survival** server (`zs_abandoned_mall_v6b` + `.nav` map + no-nav map):
1. Verify `status` shows 0 bot player slots consumed when `87–100+` `d3bot_npc_zombie` entities are active.
2. Verify `d3bot_npc_status` prints `Version: 3.0.0` and zero Lua errors in server/client consoles.
3. Verify `d3bot_npc_audit_mesh` reports walkable mall escalators bidirectional while sheer drops stay `OneWay`.
4. Verify zombies walk smoothly up and down mall escalators and ramps without stalling at the base.
5. Verify zombies never try to jump vertically up 2nd-floor balcony overhangs to reach humans above.
6. Verify zombies route around crates/pillars and squeeze cleanly through narrow doorways without corner pinning.
7. Verify `d3bot_npc_nocollide_zombies 1` / `0` toggles zombie-to-zombie collisions immediately mid-match.
8. Verify humans standing near wide nailed barricades trigger zombie swings even outside center-point reach.
9. Verify breaking a barricade invalidates cached horde paths and triggers immediate swarm breakthrough.
10. Verify `Bloated Zombie` death emits a poison splash damaging nearby humans without passing through solid walls.
11. Verify crouch-only vents trigger ducking animations/hulls and `PlaySafeActivity` produces zero T-poses.
12. Verify ladder ascents/descents climb or climb down smoothly without jumping off mid-ladder.
13. Verify deep water triggers swim-up recovery instead of drowning at the pool floor.
14. Verify unlocked opened doors no longer trap zombies in infinite barricade-swing state.
15. Verify Tier-1 -> Tier-4 anti-loop stuck recovery frees caged spawns or recycles silently without death spam.
16. Verify solo Wave-0 countdown starts cleanly (`MinPlayersBridge`) and ends into Wave 1 without human teammates.
17. Verify Wave 2+ boss spawning triggers `AI.RerollTarget` and `AI.UpdatePathImmediate`.
18. Verify Wave intermission morphs survivors/NPCs to Crows and restores/cleans up for the next wave.
19. Verify `PostCleanupMap` and `PreRestartRound` flush stale kill bonuses, queues, and cached paths.
20. Verify `d3bot_npc_enabled 0` removes active NPCs and clears spawn queues without errors.
21. Verify `d3bot_npc_add 200` and invalid `classQuery` input are clamped/validated cleanly in console & ULX.
22. Verify joining late syncs full 511-slot roster (`9`-bit UInt) accurately on TAB scoreboard, killfeed, and TargetID.
23. Verify client spectator / HUD TargetID shows valid NPC class, name, health, and damage/DMG node overlays.
24. Verify Source `.nav` fallback map loads and navigates when D3bot `.txt` mesh is absent (`d3bot_npc_use_source_nav 1`).
25. Verify tick-time stability at 10 / 30 / 50 / 87 / 100+ NPCs under active horde combat and dynamic path invalidations.

---

## Verification Scope (Container-Honest)

- **Executed & Passed in Workspace**:
  - Comprehensive Python static audit across all **24 `.lua` files** (`0` syntax/block/bracket/quote errors, pooled net strings verified, `9`-bit roster write/read symmetry verified, `39` unique ConVars, `0` player-slot bot calls, valid includes/AddCSLuaFiles).
  - TypeScript algorithmic mirror & test suite (`./node_modules/.bin/tsx --test src/sim/navEngine.test.ts` — all **16 tests** passing, including `v3.0.0` escalator slope test, `RuntimeEmbedded` soft-penalty fallback test, Tier-3->4 escalation test, and `10–120` NPC benchmarks).
  - Release zip rebuild & integrity verification (`python3 -m zipfile -t public/d3bot_npc.zip`).
- **Requires Live Garry's Mod + Zombie Survival**: Actual HL2/ZS animations, Source engine `NextBot` physics (`self.loco`), BSP `util.TraceHull`/`MASK_NPCSOLID`, sound scripts, and live client scoreboard/HUD rendering (see 25-point checklist above).
