# D3bot NPC — Slotless AI Zombies for Original JetBoom Zombie Survival (v2.2.0)

`d3bot_npc` adapts **AzBot / D3bot**'s custom navigation graph, A\* pathfinding, class behaviors, username pools, and Zombie Survival automation onto **slotless `base_nextbot` entities** (`d3bot_npc_zombie`). It lets you play solo or co-op on **original JetBoom Zombie Survival** against configurable zombie hordes, bosses, and intermission crows **without consuming any server player slots** (`maxplayers` stays 100% free).

---

## What's New in v2.2.0 — Performance, Navigation & Stability Overhaul

### 1. Server Hot-Path Performance & 100+ NPC Scalability
- **Zero-Allocation AI & NextBot Hot Loops** (`sv_ai_core.lua`, `d3bot_npc_zombie/init.lua`): Preallocated reusable trace structs, scratch vectors (`Vector:SetUnpacked`), static trace filter functions, cached hull bounds (`m_CachedHullMin`/`m_CachedHullMax`, `HalfHullWidth`), and per-NPC reusable `StepIntent` tables eliminate thousands of temporary tables, vectors, and Lua closures per second.
- **Reusable Binary Min-Heap & O(K) Path Reconstruction** (`sv_path.lua`): Replaced per-solve heap closure/table creation with module-level array reuse (`heapReset`) and swapped O(K²) `table.insert(path, 1, ...)` for O(K) forward reconstruction. Integer-packed ability keys replace multi-string cache keys.
- **Packed-Integer Spatial Grids** (`sh_navmesh.lua`, `sv_ai_core.lua`): Replaced `"cx:cy"` string concatenation keys in both the navmesh grid and NPC crowd grid with packed integer keys, eliminating ~60k+ string allocations/sec at 100 NPCs.
- **Shared Horde Caches & O(1) Parameter Indexes**:
  - Added pre-indexed `DamageNodes`, `BotModNodes`, and `CachedNodeCount` (`sh_navmesh.lua`) so `NodeDamageTick` (`sv_zs_compat.lua`) and `GetNodeBotMod()` (`sv_population.lua`) no longer iterate all 2,883+ nodes on every trigger.
  - Shared TTL caches for living humans (`0.20s`), deployable targets (`0.65s`), attacker dispersion load (`0.25s`), and target navmesh nodes (`0.25s`, distance-invalidated at `>48u`) eliminate 100x duplicate A\* start/end lookups when hordes chase 1–4 humans.
  - Fast early exit in `IsNavMeshNodeBlocked` (`sh_utilities.lua`) when a node/link has zero blocking parameters, plus cached class configs (`GetClassConfig`, `cl_init.lua`) and single-pass `SelectWeightedSequence` (`PlaySafeActivity`).
  - Throttled per-NPC barricade probing (`0.18s`), distance-adaptive whisker cadence (`0.11s` near / `0.19s` beyond `1400u`), 0-human net broadcast suppression (`sh_roster.lua`), and batched population catch-up spawning (up to 3 NPCs/interval, admin spawn cap raised to `200`).

### 2. Verified Bug Fixes
- **Zombie-vs-Zombie Pass-Through Collision Fix (`shared.lua`)**: `init.lua` enabled `SetCustomCollisionCheck(true)` and `shared.lua` defined `ENT:ShouldNotCollide(ent)`, which Source NextBots never invoke automatically. Registered `hook.Add("ShouldCollide", "D3botNPC.ZombieCollisionCheck", ...)` so `d3bot_npc_nocollide_zombies 1` actually lets hordes stream cleanly without solid self-blocking!
- **Round Reset Cleanup (`sv_zs_compat.lua`)**: Reset `GAMEMODE.D3botNPC_Kills = 0` and flushed shared path caches in `PreRestartRound` so stale kill bonuses and prior-round cached paths never leak across map waves.
- **Silent Tier-4 Stuck Recycling (`init.lua`, `sv_ai_core.lua`)**: Tagged Tier-4 stuck recycles with `npc.m_SilentRecycle = true` so trapped spawns recycle cleanly without fake death sounds, scoreboard death inflation, or ragdolls.
- **Live `D3bot.MapNavMesh` Fallback Binding (`sv_navmesh.lua`)**: Applied sidecar patch loading, `RebuildParamIndexes()`, and `RebuildSpatialGrid()` consistently to live D3bot mesh reuse.
- **Debounced Entity Invalidation (`sv_ai_core.lua`)**: Coalesced same-cell `EntityRemoved` invalidations (`0.15s` cooldown) and ignored `<14u` un-nailed prop debris/gibs so shattering wooden crates never trigger redundant swarm-wide A\* flushes.

### 3. Navigation & Combat Flow Enhancements
- **Waypoint String-Pulling / Shortcutting (`AI.TryShortcutWaypoint`)**: At ~4Hz, checks waist-hull clearance and midpoint floor continuity to skip redundant intermediate zig-zag nodes on dense meshes like `zs_abandoned_mall_v6b`, while respecting ladders, jumps, drops, and crouch vents.
- **Melee Swarm Ring Surrounding**: Crowd separation remains active down to `28u` around targets (`28u` ring spacing when `dist <= 75`), preventing zombie packs from collapsing onto one exact coordinate in melee range.
- **Whisker Wall-Slide Projection**: Projects `trCenter.HitNormal` tangentially onto perpendicular axes when scraping angled walls/railings, paired with wider ±60° corner probing.

---

## Inherited v2.1.0 & Core Capabilities (100% Preserved)

- **Zero Player Slots Consumed**: Every zombie spawns via `ents.Create("d3bot_npc_zombie")`—zero `player.CreateNextBot()`, zero fake clients, zero ULX slot disconnects.
- **Automatic Navmesh Topology & Geometry Audit (`sv_navmesh_audit.lua`)**: Fixes isolated/stranded islands (`<175u` unobstructed bridges), restricts impossible uphill edges (`OneWay`), flags dead-end sinks and low-ceiling crouch nodes, and saves optional `.npc_patch.txt` sidecars.
- **Dual Navmesh Support**: Native D3bot `.txt` + `.params.txt` graphs (with floor-Z area containment and binary-heap A\*) plus Source `.nav` fallback (`d3bot_npc_use_source_nav 1`) and no-nav fallback (`d3bot_npc_no_nav_fallback 1`).
- **JetBoom Zombie Survival Parity**: Solo/low-player `MinPlayersBridge`, boss wave spawns (`Wave 2+`), infliction/wave class progression, intermission Crow morph/restore, nailed barricade damage, ranged projectiles, killfeeds, TargetID, and TAB scoreboard injection.

---

## Installation

1. Copy the `d3bot_npc/` folder into:
   ```
   garrysmod/addons/d3bot_npc/
   ```
2. *(Optional)* Place D3bot navmesh files in:
   ```
   garrysmod/data/d3bot/navmesh/map/<mapname>.txt
   garrysmod/data/d3bot/navmesh/map/<mapname>.params.txt
   ```
3. Run gamemode **`zombiesurvival`**. No ZS or ULX core files need modification.

---

## Console & ULX Commands

`d3bot_npc_spawn [count] [class]` · `d3bot_npc_add [count] [class]` *(up to 200 per call)* · `d3bot_npc_spawn_here [class] [count]` · `d3bot_npc_remove [target]` · `d3bot_npc_remove_all` · `d3bot_npc_population [count]` · `d3bot_npc_botmod [mod]` · `d3bot_npc_setclass <target|all> <class>` · `d3bot_npc_forceclass <class|auto>` · `d3bot_npc_setname <target> <name>` · `d3bot_npc_spawnboss [class]` · `d3bot_npc_list` · `d3bot_npc_status` · `d3bot_npc_startwave` · `d3bot_npc_resetpaths` · `d3bot_npc_autospawn [0/1]` · `d3bot_npc_reloadmesh` · `d3bot_npc_list_classes` · `d3bot_npc_debug_toggle` · `d3bot_npc_audit_mesh` · `d3bot_npc_repair_mesh [save]` · `d3bot_npc_inspect_node [id]` · `d3bot_npc_debug_npc [target|stuck|all]` · `d3bot_npc_nav_stats`

*(All ULX commands live under the **"D3bot NPC"** category with `!d3botnpc_*`.)*

---

## Verification Scope

- **Static Audit**: All 24 `.lua` files verified for balanced Lua syntax/blocks/brackets/strings, zero `player.CreateNextBot`/`CreateFakeClient` calls, ConVar consistency, clean includes, and 30 ULX commands.
- **Standalone Algorithmic Simulation (`node:test`)**: Verifies A\*, floor-Z containment, mesh auditing, string-pulling shortcutting, melee ring spread, barricade breaching & debounced invalidation, 4-tier anti-loop recovery, and 10/30/50/87/120-NPC scalability benchmarks.
- **Requires Live Garry's Mod Server**: Source engine `NextBot` locomotion (`self.loco`), BSP `util.TraceHull`/`MASK_NPCSOLID`, HL2/ZS animations, and `ShouldCollide` hook execution against live entities.
