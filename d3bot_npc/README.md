# D3bot NPC — Slotless AI Zombies for Original JetBoom Zombie Survival (v3.1.0)

`d3bot_npc` adapts **AzBot / D3bot**'s custom navigation graph, A\* pathfinding, class behaviors, username pools, and Zombie Survival automation onto **slotless `base_nextbot` entities** (`d3bot_npc_zombie`). It lets you play solo or co-op on **original JetBoom Zombie Survival (`zombiesurvival`)** against configurable zombie hordes, bosses, and intermission Crows **without consuming any server player slots** (`maxplayers` stays 100% free).

---

## What's New in v3.1.0 — Faithful D3bot Port onto Slotless NextBots

### 1. Direct Source Port of Original D3bot AI & Handler Architecture
- **Ported Core Modules (`sv_extend_npc.lua`, `sh_extend_entity.lua`)**: Ported original `sv_extend_player.lua` (`D3bot_GetAttackPosOrNil`, `D3bot_GetAttackPosOrNilFuture`, `D3bot_GetAttackPosOrNilFuturePlatforms`, `D3bot_CanPounceToPos`, `D3bot_CanSeeTargetCached`, `D3bot_CanSeeTarget`, `D3bot_AngsRotateTo`, `D3bot_UpdateAngsOffshoot`, `D3bot_FindBarricadeEntity`, `D3bot_RerollClass`, `D3bot_UpdatePath`, `D3bot_UpdatePathProgress`, `D3bot_StorePos`, `D3bot_CheckStuck`) and `sh_extend_entity.lua` (`Entity:D3bot_IsBarricade()`) onto `d3bot_npc_zombie` entities, paired with `d3bot_npc`'s fast binary-heap A\* solver and bad-sigil-node main-component snapping.
- **Ported Handler Modules (`sv_bot_handler/`)**:
  - `basics.lua`: Ported `D3botNPC.Basics.SuicideOrRetarget`, `Walk`, `WalkAttackAuto`, and `PounceAuto` verbatim (velocity-lead aiming, crouch-to-attack low humans, barricade pursuit, `MaxHeight`/`Duck`/`Jump`/`Ladder`/`Climbing` node & link parameters, `AntiStuckTime`, and pounce trajectory selection).
  - `handlers/undead_fallback.lua`, `undead_headcrab.lua`, `undead_crow.lua`: Ported original D3bot handler selectors, `UpdateBotCmdFunction`, `ThinkFunction` (`<=500u` close-human checks, fixation distance `250u`, path lethality costs), `OnTakeDamageFunction`, `OnDoDamageFunction` (barricade caching), `OnDeathFunction` (`BotClasses` weighted class rerolls), `CanBeTgt`, and `RerollTarget`.
  - `handle.lua` & `supervisor.lua`: Ported original `FindHandler` dispatch, per-frame `Think`/`UpdateBotCmd` execution, `D3bot_StorePos` cadence, damage/death hooks, and `DoNodeTrigger` BotMod updates cleanly onto the slotless `sh_roster.lua` / `sv_population.lua` manager.
- **Slotless `base_nextbot` Compatibility Layer (`shared.lua` & `init.lua`)**: Added virtual `GetActiveWeapon()` SWEP proxy (`MeleeReach`, `PounceVelocity`, `PounceStartDelay`, `HitRecovery`, `GetClimbing`, `GetClimbSurface`, fire cooldowns), `OldAlive()`, `Kill()`, and `RunBehaviour()` translating D3bot `CUserCmd` movement/buttons (`ViewAngles`, `ForwardMove`, `SideMove`, `IN_JUMP`, `IN_DUCK`, `IN_ATTACK`, `IN_ATTACK2`, `IN_USE`) directly into `CLuaLocomotion`.

### 2. Authentic Zero-Collision Zombie Crowd Physics (`sv_zs_compat.lua`, `shared.lua`)
- **Zero Mutual Pushing or Slowdown**: Zombies pass cleanly through one another and undead players (`d3bot_npc_nocollide_zombies 1`) without separation shoving or proximity slowdown; corridor spread stays in A\* congestion weights.
- **Spawn Hull Parity**: Added `spawnNonZombieFilter` to `isHullClear()` in `sv_zs_compat.lua` so zombies spawning at the same spawn point never block each other.

### 3. Harmless Crow Pre-Round & Intermission Lifecycle (`sv_zs_compat.lua`, `sv_population.lua`, `sh_classes.lua`, `undead_crow.lua`)
- **Wave 0 & Intermission Crows**: `d3bot_npc_wave_zero_spawn "1"` spawns Wave 0 bots as Crows (preserving `DeathClass` / `m_NonCrowClass`) and transitions together when Wave 1 starts, during wave intermissions, and on round restarts (`PreRestartRound`).
- **Strictly Harmless Crows**: Enforced Crow `Damage = 0`, stripped `IN_USE`/`IN_ATTACK`/`IN_ATTACK2` in `undead_crow.lua`, and blocked Crow damage across `init.lua`, `EntityTakeDamage`, and `PlayerShouldTakeDamage`.

### 4. Fixed Runtime Lua Errors & JetBoom ZS Pipeline (`sv_extend_npc.lua`, `undead_fallback.lua`, `sv_zs_compat.lua`, `init.lua`)
- **Fixed `attempt to call method 'MaxHealth' (a number value)`**: Guarded non-player JetBoom ZS SENTs (`prop_obj_sigil`, `prop_arsenalcrate`, turrets) in `CanBeTgt()` using `GetSigilHealth()`, `GetObjectHealth()`, and `isfunction`/`isnumber` checks rather than calling `:MaxHealth()` or falsely rejecting `Entity:Health() == 0`.
- **Real ZS Sigil Damage & Zero Engine `AddMultiDamage` Warnings**: Preserved `ZS.ApplySigilDamage()`, `prop_obj_sigil.OnTakeDamage` wrapping (`SetSigilCorrupted(true)` + `SigilCorrupted`), `NearestPoint` melee hit fallback, and `computeNonZeroDamageForce()` across all melee, pounce, Bloated poison splash, `NodeDamageTick`, and `Kill()` damage calls.
- **Engine Safety Guards**: Preserved `D3botNPC.IsZombieSurvivalReady()`, `D3botNPC.GetInternalVar()`, `d3bot_npc_zombies_per_minute` (`ZPM` vs `ZPPM`), `xpcall` isolation around spawn/lifecycle transitions, and `+15000/+12000/+9000` off-mesh sigil node penalties.

---

## Core Capabilities Preserved (100% Slotless)

- **Zero Player Slots Consumed**: Every zombie spawns via `ents.Create("d3bot_npc_zombie")` (`base_nextbot`) — zero `player.CreateNextBot()`, zero `CreateFakeClient()`, zero server player slots used.
- **Automatic Navmesh Audit (`sv_navmesh_audit.lua`)**: Keeps mall escalators/ramps walkable, bridges nearby stranded components (`<175u`), marks sheer drops `OneWay`, inspects sigil node connectivity, and flags dead ends and low-ceiling crouch nodes.
- **JetBoom Zombie Survival Parity**: Solo/low-player `MinPlayersBridge`, boss wave spawns (`Wave 2+`), infliction/wave class scaling, intermission Crow lifecycle, nailed barricade destruction, ranged projectiles, killfeed, TargetID, and TAB scoreboard injection.

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

- **Core Population**: `d3bot_npc_enabled`, `d3bot_npc_auto_spawn`, `d3bot_npc_respawn`, `d3bot_npc_desired_zombies`, `d3bot_npc_max_population`, `d3bot_npc_zombies_per_human`, `d3bot_npc_zombies_per_wave`, `d3bot_npc_zombies_per_human_wave`, `d3bot_npc_zombies_per_minute`, `d3bot_npc_zombies_max_per_human`, `d3bot_npc_spawn_interval`, `d3bot_npc_respawn_delay`, `d3bot_npc_wave_zero_spawn`, `d3bot_npc_intermission_cleanup`, `d3bot_npc_intermission_crows`, `d3bot_npc_bosses`, `d3bot_npc_min_players_bridge`, `d3bot_npc_solo_wave_zero_seconds`
- **Physics, Identity & ZS Integration**: `d3bot_npc_nocollide_zombies`, `d3bot_npc_ragdoll_lifetime`, `d3bot_npc_name_list`, `d3bot_npc_name_prefix`, `d3bot_npc_show_enemy_targetid`, `d3bot_npc_node_damage`, `d3bot_npc_suppress_d3bot_spawns`, `d3bot_npc_contribute_infliction`, `d3bot_npc_debug`
- **Navigation & Route Spread**: `d3bot_npc_path_budget`, `d3bot_npc_crowd_avoidance`, `d3bot_npc_crowd_congestion_weight`, `d3bot_npc_whisker_avoidance`, `d3bot_npc_stuck_recovery`, `d3bot_npc_link_fail_penalty`, `d3bot_npc_path_recalc_interval`, `d3bot_npc_auto_audit_mesh`, `d3bot_npc_allow_last_resort_tp`, `d3bot_npc_use_source_nav`, `d3bot_npc_source_nav_override`, `d3bot_npc_no_nav_fallback`
  - *(Removed in v3.1.0: `d3bot_npc_separation_force` — zombies now naturally pass through each other with zero separation force or mutual slowdown.)*
- **Console Commands**: `d3bot_npc_spawn [count] [class]` · `d3bot_npc_add [count] [class]` *(up to 200)* · `d3bot_npc_spawn_here [class] [count]` · `d3bot_npc_remove [target]` · `d3bot_npc_remove_all` · `d3bot_npc_population [count]` · `d3bot_npc_botmod [mod]` · `d3bot_npc_setclass <target|all> <class>` · `d3bot_npc_forceclass <class|auto>` · `d3bot_npc_setname <target> <name>` · `d3bot_npc_spawnboss [class]` · `d3bot_npc_list` · `d3bot_npc_status` · `d3bot_npc_startwave` · `d3bot_npc_resetpaths` · `d3bot_npc_autospawn [0/1]` · `d3bot_npc_reloadmesh` · `d3bot_npc_list_classes` · `d3bot_npc_debug_toggle` · `d3bot_npc_audit_mesh` · `d3bot_npc_repair_mesh [save]` · `d3bot_npc_inspect_node [id]` · `d3bot_npc_debug_npc [target|stuck|all]` · `d3bot_npc_nav_stats`
- **ULX Category (`D3bot NPC`)**: `!d3botnpc_add`, `!d3botnpc_spawn`, `!d3botnpc_spawnclass`, `!d3botnpc_spawnhere`, `!d3botnpc_spawnboss`, `!d3botnpc_remove`, `!d3botnpc_removeall`, `!d3botnpc_respawn`, `!d3botnpc_count`, `!d3botnpc_botmod`, `!d3botnpc_zombiesperplayer`, `!d3botnpc_maxpopulation`, `!d3botnpc_autospawn`, `!d3botnpc_enabled`, `!d3botnpc_setclass`, `!d3botnpc_forceclass`, `!d3botnpc_setname`, `!d3botnpc_setteam`, `!d3botnpc_list`, `!d3botnpc_status`, `!d3botnpc_startwave`, `!d3botnpc_intermissioncrows`, `!d3botnpc_reloadmesh`, `!d3botnpc_resetpaths`, `!d3botnpc_debug`, `!d3botnpc_auditmesh`, `!d3botnpc_repairmesh`, `!d3botnpc_inspectnode`, `!d3botnpc_debugnpc`, `!d3botnpc_navstats`

---

## Verification Scope (Container-Honest)

- **Executed in Workspace**:
  - Comprehensive Python static Lua syntax, ConVar parity, API safety, and invariant audit across all `.lua` files in `d3bot_npc`.
  - Pure TypeScript simulation & unit test suite (`src/sim/npcRestore.test.ts`) verifying human/sigil targeting, zero zombie separation/slowdown, harmless Crow lifecycle transitions, `GetInternalVariable` 0-return safety, and `IsZombieSurvivalReady()` guards.
  - Packaged addon integrity test (`python3 -m zipfile -t public/d3bot_npc.zip`).
- **Requires Live Garry's Mod + JetBoom Zombie Survival (`zs_abandoned_mall_v6b`)**:
  - `status` confirms 0 player slots consumed while `87–100+` `d3bot_npc_zombie` entities are active.
  - Zero runtime Lua errors during map load, Wave 0 spawn, Wave 1 start, intermission Crow transitions, Boss spawns, and `PreRestartRound`.
  - Visual verification of Crows dealing 0 damage, zombies passing through each other without shoving/slowdown, persistent pursuit of humans & uncorrupted sigils, and clean recovery/recycling.
