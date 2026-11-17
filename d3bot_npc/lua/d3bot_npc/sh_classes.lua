AddCSLuaFile()

-- Modular Zombie Class Configuration System for D3bot NPC
-- Pulls canonical stats from JetBoom Zombie Survival's GAMEMODE.ZombieClasses and SWEP definitions
-- while allowing clean per-class overrides, animations, and custom ability hooks.

local lib = D3botNPC

lib.ClassOverrides = lib.ClassOverrides or {}
lib.ClassConfigs = lib.ClassConfigs or {}

function lib.RegisterClassConfig(className, cfg)
	if not isstring(className) or not istable(cfg) then return end
	cfg.Name = cfg.Name or className
	lib.ClassOverrides[className] = cfg
	if lib.ClassesBuilt then
		lib.RebuildClassConfigs()
	end
end

-- Class-specific behavioral profiles mapped directly from JetBoom ZS zombieclasses/*.lua & zombie SWEPs
lib.RegisterClassConfig("Zombie", {
	FallbackModel = "models/player/zombie_classic.mdl",
	CanJump = true,
	CanClimb = false,
	CanPounce = false,
	DetectionRange = 1600,
	Weight = 5,
	Animations = {
		Idle = ACT_HL2MP_IDLE_ZOMBIE,
		Walk = ACT_HL2MP_WALK_ZOMBIE_01,
		Run = ACT_HL2MP_RUN_ZOMBIE,
		CrouchIdle = ACT_HL2MP_IDLE_CROUCH_ZOMBIE,
		CrouchWalk = ACT_HL2MP_WALK_CROUCH_ZOMBIE_01,
		Jump = ACT_HL2MP_JUMP_ZOMBIE,
		AttackGesture = ACT_GMOD_GESTURE_RANGE_ZOMBIE
	}
})

lib.RegisterClassConfig("Fresh Dead", {
	FallbackModel = "models/player/group01/male_02.mdl",
	CanJump = true,
	CanClimb = false,
	CanPounce = false,
	DetectionRange = 1600,
	Weight = 2,
	Animations = {
		Idle = ACT_HL2MP_IDLE_ZOMBIE,
		Walk = ACT_HL2MP_WALK_ZOMBIE_01,
		Run = ACT_HL2MP_RUN_ZOMBIE,
		CrouchIdle = ACT_HL2MP_IDLE_CROUCH_ZOMBIE,
		CrouchWalk = ACT_HL2MP_WALK_CROUCH_ZOMBIE_01,
		Jump = ACT_HL2MP_JUMP_ZOMBIE,
		AttackGesture = ACT_GMOD_GESTURE_RANGE_ZOMBIE
	}
})

lib.RegisterClassConfig("Classic Zombie", {
	FallbackModel = "models/player/zombie_classic.mdl",
	CanJump = true,
	CanClimb = true,
	ClimbSpeed = 165,
	CanPounce = false,
	DetectionRange = 1600,
	Weight = 2,
	Animations = {
		Idle = ACT_HL2MP_IDLE_ZOMBIE,
		Walk = ACT_HL2MP_WALK_ZOMBIE_01,
		Run = ACT_HL2MP_RUN_ZOMBIE,
		CrouchIdle = ACT_HL2MP_IDLE_CROUCH_ZOMBIE,
		CrouchWalk = ACT_HL2MP_WALK_CROUCH_ZOMBIE_01,
		Jump = ACT_HL2MP_JUMP_ZOMBIE,
		Climb = ACT_ZOMBIE_CLIMB_UP,
		AttackGesture = ACT_GMOD_GESTURE_RANGE_ZOMBIE
	}
})

lib.RegisterClassConfig("Ghoul", {
	FallbackModel = "models/player/corpse1.mdl",
	CanJump = true,
	CanClimb = false,
	CanPounce = false,
	DetectionRange = 1700,
	Weight = 1,
	RangedAttack = {
		Projectile = "projectile_ghoulflesh",
		Speed = 660,
		Windup = 0.65,
		Cooldown = 4.5,
		MinRange = 180,
		MaxRange = 750,
		Spread = { {0, 0}, {-1, 0}, {1, 0}, {-0.5, 0}, {0.5, 0} },
		SpreadScale = 5,
		CastSound = "npc/fast_zombie/leap1.wav"
	},
	OnMeleeHitHuman = function(npc, victim, dmg, trace, cfg)
		if SERVER and IsValid(victim) and victim:IsPlayer() and victim:Team() == TEAM_HUMAN then
			local durMul = 10 / math.max(cfg.Damage or 23, 1)
			local gt = victim.GiveStatus and victim:GiveStatus("enfeeble", dmg * durMul)
			if IsValid(gt) then
				gt.Applier = npc
			end
		end
	end,
	UsePoisonDamage = true,
	Animations = {
		Idle = ACT_HL2MP_IDLE_ZOMBIE,
		Walk = ACT_HL2MP_WALK_ZOMBIE_01,
		Run = ACT_HL2MP_RUN_ZOMBIE,
		CrouchIdle = ACT_HL2MP_IDLE_CROUCH_ZOMBIE,
		CrouchWalk = ACT_HL2MP_WALK_CROUCH_ZOMBIE_01,
		Jump = ACT_HL2MP_JUMP_ZOMBIE,
		AttackGesture = ACT_GMOD_GESTURE_RANGE_ZOMBIE
	}
})

lib.RegisterClassConfig("Wraith", {
	FallbackModel = "models/player/soldier_stripped.mdl",
	CanJump = true,
	CanClimb = false,
	CanPounce = false,
	DetectionRange = 1900,
	RenderMode = RENDERMODE_TRANSALPHA,
	Alpha = 55,
	AttackAlpha = 140,
	Weight = 3,
	Sounds = {
		Hit = { "ambient/machines/slicer1.wav", "ambient/machines/slicer2.wav", "ambient/machines/slicer3.wav", "ambient/machines/slicer4.wav" },
		Miss = { "npc/zombie/claw_miss1.wav", "npc/zombie/claw_miss2.wav" },
		Attack = { "npc/antlion/distract1.wav" },
		Alert = { "npc/stalker/go_alert2a.wav" }
	},
	Animations = {
		Idle = ACT_HL2MP_IDLE_KNIFE,
		Walk = ACT_HL2MP_WALK_KNIFE,
		Run = ACT_HL2MP_RUN_KNIFE,
		CrouchIdle = ACT_HL2MP_IDLE_CROUCH_FIST,
		CrouchWalk = ACT_HL2MP_WALK_CROUCH_KNIFE,
		Jump = ACT_HL2MP_JUMP_KNIFE,
		AttackGesture = ACT_GMOD_GESTURE_RANGE_ZOMBIE_SPECIAL
	}
})

lib.RegisterClassConfig("Bloated Zombie", {
	FallbackModel = "models/player/zombie_classic.mdl",
	CanJump = true,
	CanClimb = false,
	CanPounce = false,
	DetectionRange = 1500,
	Weight = 3,
	Sounds = {
		Attack = { "npc/ichthyosaur/attack_growl1.wav", "npc/ichthyosaur/attack_growl2.wav", "npc/ichthyosaur/attack_growl3.wav" },
		Idle = { "npc/barnacle/barnacle_tongue_pull1.wav", "npc/barnacle/barnacle_tongue_pull2.wav", "npc/barnacle/barnacle_tongue_pull3.wav" }
	},
	Animations = {
		Idle = ACT_HL2MP_IDLE_ZOMBIE,
		Walk = ACT_HL2MP_WALK_ZOMBIE_01,
		Run = ACT_HL2MP_RUN_ZOMBIE,
		CrouchIdle = ACT_HL2MP_IDLE_CROUCH_ZOMBIE,
		CrouchWalk = ACT_HL2MP_WALK_CROUCH_ZOMBIE_01,
		Jump = ACT_HL2MP_JUMP_ZOMBIE,
		AttackGesture = ACT_GMOD_GESTURE_RANGE_ZOMBIE
	}
})

lib.RegisterClassConfig("Fast Zombie", {
	FallbackModel = "models/player/zombie_fast.mdl",
	CanJump = true,
	CanClimb = true,
	ClimbSpeed = 240,
	CanPounce = true,
	PounceVelocity = 700,
	PounceStartDelay = 0.5,
	PounceDelay = 1.25,
	PounceDamage = 20,
	PounceDamageVsPlayerMul = 0.2,
	PounceReach = 26,
	PounceSize = 12,
	DetectionRange = 2000,
	Weight = 4,
	Sounds = {
		Hit = { "NPC_FastZombie.AttackHit" },
		Miss = { "NPC_FastZombie.AttackMiss" },
		Attack = { "npc/fast_zombie/leap1.wav" },
		PounceStart = { "npc/fast_zombie/leap1.wav" },
		Pounce = { "NPC_FastZombie.Scream" },
		Alert = { "NPC_FastZombie.Frenzy" },
		Idle = { "NPC_FastZombie.AlertFar" }
	},
	Animations = {
		Idle = ACT_HL2MP_IDLE_ZOMBIE,
		Walk = ACT_HL2MP_RUN_ZOMBIE_FAST,
		Run = ACT_HL2MP_RUN_ZOMBIE_FAST,
		CrouchIdle = ACT_HL2MP_IDLE_CROUCH_ZOMBIE,
		CrouchWalk = ACT_HL2MP_WALK_CROUCH_ZOMBIE_01,
		Jump = ACT_HL2MP_JUMP_ZOMBIE,
		Climb = ACT_ZOMBIE_CLIMB_UP,
		LeapStart = ACT_ZOMBIE_LEAP_START,
		Leaping = ACT_ZOMBIE_LEAPING,
		AttackGesture = ACT_GMOD_GESTURE_RANGE_FRENZY
	}
})

lib.RegisterClassConfig("Lacerator", {
	FallbackModel = "models/player/zombie_fast.mdl",
	CanJump = true,
	CanClimb = true,
	ClimbSpeed = 250,
	CanPounce = true,
	PounceVelocity = 700,
	PounceStartDelay = 0.5,
	PounceDelay = 1.25,
	PounceDamage = 24,
	PounceDamageVsPlayerMul = 0.25,
	PounceReach = 26,
	PounceSize = 12,
	DetectionRange = 2100,
	Weight = 2,
	Sounds = {
		Hit = { "NPC_FastZombie.AttackHit" },
		Miss = { "NPC_FastZombie.AttackMiss" },
		Attack = { "npc/fast_zombie/leap1.wav" },
		PounceStart = { "npc/fast_zombie/leap1.wav" },
		Pounce = { "NPC_FastZombie.Scream" }
	},
	Animations = {
		Idle = ACT_HL2MP_IDLE_ZOMBIE,
		Walk = ACT_HL2MP_RUN_ZOMBIE_FAST,
		Run = ACT_HL2MP_RUN_ZOMBIE_FAST,
		CrouchIdle = ACT_HL2MP_IDLE_CROUCH_ZOMBIE,
		CrouchWalk = ACT_HL2MP_WALK_CROUCH_ZOMBIE_01,
		Jump = ACT_HL2MP_JUMP_ZOMBIE,
		Climb = ACT_ZOMBIE_CLIMB_UP,
		LeapStart = ACT_ZOMBIE_LEAP_START,
		Leaping = ACT_ZOMBIE_LEAPING,
		AttackGesture = ACT_GMOD_GESTURE_RANGE_FRENZY
	}
})

lib.RegisterClassConfig("Poison Zombie", {
	FallbackModel = "models/Zombie/Poison.mdl",
	IsHL2NPCModel = true,
	CanJump = true,
	CanClimb = false,
	CanPounce = false,
	DetectionRange = 1700,
	Weight = 3,
	RangedAttack = {
		Projectile = "projectile_poisonflesh",
		Speed = 380,
		Windup = 0.9,
		Cooldown = 5.0,
		MinRange = 160,
		MaxRange = 650,
		Spread = { {-1, 0}, {-0.66, 0}, {-0.33, 0}, {0, 0}, {0, 1}, {0, -1}, {0.33, 0}, {0.66, 0}, {1, 0} },
		SpreadScaleX = 12.5,
		SpreadScaleY = 5,
		CastSound = "NPC_PoisonZombie.Throw"
	},
	Sounds = {
		Hit = { "npc/zombie/claw_strike1.wav", "npc/zombie/claw_strike2.wav", "npc/zombie/claw_strike3.wav" },
		Miss = { "npc/zombie/claw_miss1.wav", "npc/zombie/claw_miss2.wav" },
		Attack = { "npc/zombie_poison/pz_warn1.wav", "npc/zombie_poison/pz_warn2.wav" }
	},
	Animations = {
		Idle = ACT_IDLE,
		Walk = ACT_WALK,
		Run = ACT_WALK,
		CrouchIdle = ACT_IDLE,
		CrouchWalk = ACT_WALK,
		Jump = ACT_IDLE,
		AttackGesture = ACT_MELEE_ATTACK1,
		RangedGesture = ACT_RANGE_ATTACK2
	}
})

lib.RegisterClassConfig("Headcrab", {
	FallbackModel = "models/headcrabclassic.mdl",
	IsHL2NPCModel = true,
	IsCrab = true,
	CanJump = true,
	CanClimb = false,
	CanPounce = true,
	PounceVelocity = 450,
	PounceStartDelay = 0.05,
	PounceDelay = 1.1,
	PounceDamage = 8,
	PounceDamageVsPlayerMul = 1.0,
	PounceReach = 18,
	PounceSize = 12,
	CantDuck = true,
	DetectionRange = 1500,
	Weight = 2,
	Sounds = {
		Attack = { "NPC_HeadCrab.Attack" },
		Hit = { "NPC_HeadCrab.Bite" },
		Idle = { "NPC_HeadCrab.Idle" }
	},
	Animations = {
		Idle = ACT_IDLE,
		Walk = ACT_RUN,
		Run = ACT_RUN,
		CrouchIdle = ACT_IDLE,
		CrouchWalk = ACT_RUN,
		Jump = ACT_RANGE_ATTACK1,
		Leaping = ACT_RANGE_ATTACK1,
		AttackGesture = ACT_RANGE_ATTACK1
	}
})

lib.RegisterClassConfig("Fast Headcrab", {
	FallbackModel = "models/headcrab.mdl",
	IsHL2NPCModel = true,
	IsCrab = true,
	CanJump = true,
	CanClimb = false,
	CanPounce = true,
	PounceVelocity = 520,
	PounceStartDelay = 0.05,
	PounceDelay = 0.85,
	PounceDamage = 7,
	PounceDamageVsPlayerMul = 1.0,
	PounceReach = 18,
	PounceSize = 12,
	CantDuck = true,
	DetectionRange = 1600,
	Weight = 1,
	Sounds = {
		Attack = { "NPC_HeadCrab.Attack" },
		Hit = { "NPC_HeadCrab.Bite" }
	},
	Animations = {
		Idle = ACT_IDLE,
		Walk = ACT_RUN,
		Run = ACT_RUN,
		CrouchIdle = ACT_IDLE,
		CrouchWalk = ACT_RUN,
		Jump = ACT_RANGE_ATTACK1,
		Leaping = ACT_RANGE_ATTACK1,
		AttackGesture = ACT_RANGE_ATTACK1
	}
})

lib.RegisterClassConfig("Skeletal Walker", {
	FallbackModel = "models/player/skeleton.mdl",
	CanJump = true,
	CanClimb = false,
	CanPounce = false,
	DetectionRange = 1600,
	Weight = 1,
	Animations = {
		Idle = ACT_HL2MP_IDLE_ZOMBIE,
		Walk = ACT_HL2MP_WALK_ZOMBIE_01,
		Run = ACT_HL2MP_RUN_ZOMBIE,
		CrouchIdle = ACT_HL2MP_IDLE_CROUCH_ZOMBIE,
		CrouchWalk = ACT_HL2MP_WALK_CROUCH_ZOMBIE_01,
		Jump = ACT_HL2MP_JUMP_ZOMBIE,
		AttackGesture = ACT_GMOD_GESTURE_RANGE_ZOMBIE
	}
})

lib.RegisterClassConfig("Zombine", {
	FallbackModel = "models/zombie/zombie_soldier.mdl",
	CanJump = true,
	CanClimb = false,
	CanPounce = false,
	DetectionRange = 1750,
	Weight = 4,
	Animations = {
		Idle = ACT_HL2MP_IDLE_ZOMBIE,
		Walk = ACT_HL2MP_WALK_ZOMBIE_01,
		Run = ACT_HL2MP_RUN_ZOMBIE,
		CrouchIdle = ACT_HL2MP_IDLE_CROUCH_ZOMBIE,
		CrouchWalk = ACT_HL2MP_WALK_CROUCH_ZOMBIE_01,
		Jump = ACT_HL2MP_JUMP_ZOMBIE,
		AttackGesture = ACT_GMOD_GESTURE_RANGE_ZOMBIE
	}
})

-- Intermission Crow representation (ported from ZS zombieclasses/crow.lua & D3bot undead_crow.lua)
lib.RegisterClassConfig("Crow", {
	FallbackModel = "models/crow.mdl",
	IsHL2NPCModel = true,
	IsCrow = true,
	Hidden = true,
	NoHeadbox = true,
	NoFallDamage = true,
	NoFallSlowdown = true,
	NoTurretTarget = true,
	CantDuck = true,
	CanJump = true,
	CanClimb = false,
	CanPounce = false,
	Health = 5,
	Speed = 95,
	WalkSpeed = 95,
	RunSpeed = 160,
	FlyingSpeed = 350,
	JumpPower = 230,
	Damage = 0,
	AttackRange = 36,
	AttackCooldown = 0.6,
	AttackDelay = 0.12,
	Points = 0,
	Weight = 0,
	Hull = { Vector(-4, -4, 0), Vector(4, 4, 9) },
	HullDuck = { Vector(-4, -4, 0), Vector(4, 4, 9) },
	ViewOffset = Vector(0, 0, 7),
	ViewOffsetDucked = Vector(0, 0, 7),
	DetectionRange = 2200,
	Sounds = {
		Idle = { "npc/crow/idle1.wav", "npc/crow/idle2.wav", "npc/crow/idle3.wav", "npc/crow/idle4.wav" },
		Pain = { "npc/crow/pain1.wav", "npc/crow/pain2.wav" },
		Death = { "npc/crow/die1.wav", "npc/crow/die2.wav" },
		Attack = { "npc/crow/alert2.wav", "npc/crow/alert3.wav" },
		Hit = { "npc/crow/alert1.wav" },
		Miss = { "npc/crow/flap2.wav" }
	},
	Animations = {
		Idle = ACT_IDLE,
		Walk = ACT_RUN,
		Run = ACT_RUN,
		Jump = ACT_FLY,
		Fly = ACT_FLY,
		CrouchIdle = ACT_IDLE,
		CrouchWalk = ACT_RUN,
		AttackGesture = ACT_MELEE_ATTACK1,
		SeqIdle = "Idle01",
		SeqWalk = "Walk",
		SeqRun = "Run",
		SeqFly = "Fly01"
	}
})

-- JetBoom ZS Boss Zombie Profiles
lib.RegisterClassConfig("Nightmare", {
	FallbackModel = "models/player/charple.mdl",
	Boss = true,
	CanJump = true,
	CanClimb = false,
	CanPounce = false,
	DetectionRange = 2400,
	AttackRange = 56,
	Damage = 48,
	AttackCooldown = 1.0,
	Weight = 0,
	Animations = {
		Idle = ACT_HL2MP_IDLE_ZOMBIE,
		Walk = ACT_HL2MP_WALK_ZOMBIE_01,
		Run = ACT_HL2MP_RUN_ZOMBIE,
		CrouchIdle = ACT_HL2MP_IDLE_CROUCH_ZOMBIE,
		CrouchWalk = ACT_HL2MP_WALK_CROUCH_ZOMBIE_01,
		Jump = ACT_HL2MP_JUMP_ZOMBIE,
		AttackGesture = ACT_GMOD_GESTURE_RANGE_ZOMBIE
	}
})

lib.RegisterClassConfig("Bonemesh", {
	FallbackModel = "models/player/zombie_fast.mdl",
	Boss = true,
	CanJump = true,
	CanClimb = true,
	ClimbSpeed = 210,
	CanPounce = false,
	DetectionRange = 2200,
	AttackRange = 52,
	Damage = 40,
	Weight = 0,
	RangedAttack = {
		Projectile = "projectile_bonemesh",
		Speed = 620,
		Windup = 0.7,
		Cooldown = 4.2,
		MinRange = 170,
		MaxRange = 800,
		Spread = { {0, 0}, {-1, 0}, {1, 0} },
		SpreadScale = 5,
		CastSound = "npc/fast_zombie/leap1.wav"
	},
	Animations = {
		Idle = ACT_HL2MP_IDLE_ZOMBIE,
		Walk = ACT_HL2MP_RUN_ZOMBIE_FAST,
		Run = ACT_HL2MP_RUN_ZOMBIE_FAST,
		CrouchIdle = ACT_HL2MP_IDLE_CROUCH_ZOMBIE,
		CrouchWalk = ACT_HL2MP_WALK_CROUCH_ZOMBIE_01,
		Jump = ACT_HL2MP_JUMP_ZOMBIE,
		Climb = ACT_ZOMBIE_CLIMB_UP,
		AttackGesture = ACT_GMOD_GESTURE_RANGE_FRENZY
	}
})

lib.RegisterClassConfig("The Butcher", {
	FallbackModel = "models/player/corpse1.mdl",
	Boss = true,
	CanJump = true,
	CanClimb = false,
	CanPounce = false,
	DetectionRange = 2200,
	AttackRange = 64,
	Damage = 55,
	AttackCooldown = 1.05,
	Weight = 0,
	Animations = {
		Idle = ACT_HL2MP_IDLE_MELEE,
		Walk = ACT_HL2MP_WALK_MELEE,
		Run = ACT_HL2MP_RUN_MELEE,
		CrouchIdle = ACT_HL2MP_IDLE_CROUCH_MELEE,
		CrouchWalk = ACT_HL2MP_WALK_CROUCH_MELEE,
		Jump = ACT_HL2MP_JUMP_MELEE,
		AttackGesture = ACT_HL2MP_GESTURE_RANGE_ATTACK_MELEE
	}
})

lib.RegisterClassConfig("Puke Pus", {
	FallbackModel = "models/Zombie/Poison.mdl",
	IsHL2NPCModel = true,
	Boss = true,
	CanJump = true,
	CanClimb = false,
	CanPounce = false,
	DetectionRange = 2200,
	AttackRange = 54,
	Damage = 42,
	Weight = 0,
	RangedAttack = {
		Projectile = "projectile_poisonpuke",
		Speed = 420,
		Windup = 0.85,
		Cooldown = 4.0,
		MinRange = 140,
		MaxRange = 680,
		Spread = { {-1, 0}, {-0.5, 0}, {0, 0}, {0.5, 0}, {1, 0}, {0, 0.5} },
		SpreadScaleX = 11,
		SpreadScaleY = 5,
		CastSound = "NPC_PoisonZombie.Throw"
	},
	Animations = {
		Idle = ACT_IDLE,
		Walk = ACT_WALK,
		Run = ACT_WALK,
		CrouchIdle = ACT_IDLE,
		CrouchWalk = ACT_WALK,
		Jump = ACT_IDLE,
		AttackGesture = ACT_MELEE_ATTACK1,
		RangedGesture = ACT_RANGE_ATTACK2
	}
})

lib.RegisterClassConfig("The Tickle Monster", {
	FallbackModel = "models/player/zombie_fast.mdl",
	Boss = true,
	CanJump = true,
	CanClimb = true,
	ClimbSpeed = 200,
	CanPounce = false,
	DetectionRange = 2200,
	AttackRange = 92,
	Damage = 42,
	AttackCooldown = 1.15,
	Weight = 0,
	Animations = {
		Idle = ACT_HL2MP_IDLE_ZOMBIE,
		Walk = ACT_HL2MP_WALK_ZOMBIE_01,
		Run = ACT_HL2MP_RUN_ZOMBIE,
		CrouchIdle = ACT_HL2MP_IDLE_CROUCH_ZOMBIE,
		CrouchWalk = ACT_HL2MP_WALK_CROUCH_ZOMBIE_01,
		Jump = ACT_HL2MP_JUMP_ZOMBIE,
		AttackGesture = ACT_GMOD_GESTURE_RANGE_ZOMBIE
	}
})

lib.RegisterClassConfig("Giga Gore Child", {
	FallbackModel = "models/player/zombie_classic.mdl",
	Boss = true,
	CanJump = true,
	CanClimb = false,
	CanPounce = false,
	DetectionRange = 2200,
	AttackRange = 64,
	Damage = 45,
	Weight = 0,
	Animations = {
		Idle = ACT_HL2MP_IDLE_ZOMBIE,
		Walk = ACT_HL2MP_WALK_ZOMBIE_01,
		Run = ACT_HL2MP_RUN_ZOMBIE,
		CrouchIdle = ACT_HL2MP_IDLE_CROUCH_ZOMBIE,
		CrouchWalk = ACT_HL2MP_WALK_CROUCH_ZOMBIE_01,
		Jump = ACT_HL2MP_JUMP_ZOMBIE,
		AttackGesture = ACT_GMOD_GESTURE_RANGE_ZOMBIE
	}
})

lib.RegisterClassConfig("Shade", {
	FallbackModel = "models/player/soldier_stripped.mdl",
	Boss = true,
	CanJump = true,
	CanClimb = false,
	CanPounce = false,
	RenderMode = RENDERMODE_TRANSALPHA,
	Alpha = 110,
	AttackAlpha = 210,
	DetectionRange = 2200,
	AttackRange = 54,
	Damage = 35,
	Weight = 0,
	Animations = {
		Idle = ACT_HL2MP_IDLE_MAGIC,
		Walk = ACT_HL2MP_WALK_MAGIC,
		Run = ACT_HL2MP_RUN_MAGIC,
		CrouchIdle = ACT_HL2MP_IDLE_CROUCH_MAGIC,
		CrouchWalk = ACT_HL2MP_WALK_CROUCH_MAGIC,
		Jump = ACT_HL2MP_JUMP_MAGIC,
		AttackGesture = ACT_GMOD_GESTURE_RANGE_ZOMBIE_SPECIAL
	}
})

local defaultHull = { Vector(-16, -16, 0), Vector(16, 16, 72) }
local defaultHullDuck = { Vector(-16, -16, 0), Vector(16, 16, 36) }
local defaultViewOffset = Vector(0, 0, 64)
local defaultViewOffsetDucked = Vector(0, 0, 28)

local defaultSounds = {
	Pain = { "npc/zombie/zombie_pain1.wav", "npc/zombie/zombie_pain2.wav", "npc/zombie/zombie_pain3.wav", "npc/zombie/zombie_pain4.wav", "npc/zombie/zombie_pain5.wav", "npc/zombie/zombie_pain6.wav" },
	Death = { "npc/zombie/zombie_die1.wav", "npc/zombie/zombie_die2.wav", "npc/zombie/zombie_die3.wav" },
	Attack = { "npc/zombie/zo_attack1.wav", "npc/zombie/zo_attack2.wav" },
	Hit = { "npc/zombie/claw_strike1.wav", "npc/zombie/claw_strike2.wav", "npc/zombie/claw_strike3.wav" },
	Miss = { "npc/zombie/claw_miss1.wav", "npc/zombie/claw_miss2.wav" },
	Idle = { "npc/zombie/zombie_voice_idle1.wav", "npc/zombie/zombie_voice_idle2.wav", "npc/zombie/zombie_voice_idle3.wav" }
}

local function mergeSounds(baseSounds, customSounds)
	local out = table.Copy(baseSounds)
	if istable(customSounds) then
		for k, v in pairs(customSounds) do
			out[k] = v
		end
	end
	return out
end

function lib.RebuildClassConfigs()
	local configs = {}
	local zsClasses = GAMEMODE and GAMEMODE.ZombieClasses or {}

	for k, zsClass in pairs(zsClasses) do
		if istable(zsClass) and isstring(zsClass.Name) then
			local ovr = lib.ClassOverrides[zsClass.Name] or {}
			local swep = zsClass.SWEP and weapons.GetStored(zsClass.SWEP) or nil
			local baseSwep = swep and swep.Base and weapons.GetStored(swep.Base) or nil

			local function swepVal(key, fallback)
				if swep and swep[key] ~= nil then return swep[key] end
				if baseSwep and baseSwep[key] ~= nil then return baseSwep[key] end
				return fallback
			end

			local primaryDelay = (swep and swep.Primary and swep.Primary.Delay)
				or (baseSwep and baseSwep.Primary and baseSwep.Primary.Delay)
				or 1.2

			local baseSpeed = ovr.Speed or zsClass.Speed or 175
			local mdl = ovr.Model or zsClass.Model or ovr.FallbackModel or "models/player/zombie_classic.mdl"
			local hull = ovr.Hull or zsClass.Hull or defaultHull
			local hullDuck = ovr.HullDuck or zsClass.HullDuck or defaultHullDuck

			local sounds = mergeSounds(defaultSounds, ovr.Sounds)
			if zsClass.PainSounds then sounds.Pain = zsClass.PainSounds end
			if zsClass.DeathSounds then sounds.Death = zsClass.DeathSounds end

			local pounceVel = ovr.PounceVelocity or swepVal("PounceVelocity", nil)
			local canPounce = ovr.CanPounce
			if canPounce == nil then
				canPounce = (pounceVel ~= nil) or (zsClass.IsHeadcrab == true)
			end

			local cfg = {
				Name = zsClass.Name,
				ZSClassIndex = zsClass.Index or k,
				SWEP = zsClass.SWEP,
				Model = mdl,
				FallbackModel = ovr.FallbackModel or "models/player/zombie_classic.mdl",
				ModelScale = ovr.ModelScale or zsClass.ModelScale or 1,
				IsHL2NPCModel = ovr.IsHL2NPCModel or false,
				IsCrow = ovr.IsCrow or (zsClass.Name == "Crow") or false,
				Health = ovr.Health or zsClass.Health or 225,
				Speed = baseSpeed,
				WalkSpeed = ovr.WalkSpeed or math.max(85, baseSpeed * 0.6),
				RunSpeed = ovr.RunSpeed or baseSpeed,
				FlyingSpeed = ovr.FlyingSpeed or zsClass.FlyingSpeed or (baseSpeed * 2.5),
				CrouchedWalkSpeed = ovr.CrouchedWalkSpeed or zsClass.CrouchedWalkSpeed or 0.55,
				Damage = (ovr.Damage ~= nil) and ovr.Damage or swepVal("MeleeDamage", 35),
				DamageType = ovr.DamageType or swepVal("MeleeDamageType", DMG_SLASH),
				MeleeForceScale = ovr.MeleeForceScale or swepVal("MeleeForceScale", 1),
				AttackRange = ovr.AttackRange or swepVal("MeleeReach", 48),
				MeleeSize = ovr.MeleeSize or swepVal("MeleeSize", 4.5),
				AttackDelay = ovr.AttackDelay or swepVal("MeleeDelay", 0.5),
				AttackCooldown = ovr.AttackCooldown or primaryDelay,
				DetectionRange = ovr.DetectionRange or 1600,
				Hull = hull,
				HullDuck = hullDuck,
				ViewOffset = ovr.ViewOffset or zsClass.ViewOffset or defaultViewOffset,
				ViewOffsetDucked = ovr.ViewOffsetDucked or zsClass.ViewOffsetDucked or defaultViewOffsetDucked,
				JumpPower = ovr.JumpPower or zsClass.JumpPower or DEFAULT_JUMP_POWER or 200,
				StepSize = ovr.StepSize or zsClass.StepSize or 18,
				Mass = ovr.Mass or zsClass.Mass or 85,
				Points = ovr.Points or zsClass.Points or 3,
				Wave = zsClass.Wave or 0,
				Infliction = zsClass.Infliction,
				Unlocked = zsClass.Unlocked,
				Locked = zsClass.Locked,
				Hidden = ovr.Hidden ~= nil and ovr.Hidden or zsClass.Hidden,
				Boss = ovr.Boss ~= nil and ovr.Boss or zsClass.Boss,
				NoTurretTarget = ovr.NoTurretTarget or zsClass.NoTurretTarget,
				NoHeadbox = ovr.NoHeadbox or zsClass.NoHeadbox or zsClass.NoHead,
				CantDuck = ovr.CantDuck or zsClass.CantDuck or false,
				NoFallDamage = ovr.NoFallDamage or zsClass.NoFallDamage,
				NoFallSlowdown = ovr.NoFallSlowdown or zsClass.NoFallSlowdown,
				CanJump = ovr.CanJump ~= false,
				CanClimb = ovr.CanClimb or (zsClass.Name == "Fast Zombie" or zsClass.Name == "Lacerator" or zsClass.Name == "Classic Zombie" or zsClass.Name == "Bonemesh"),
				ClimbSpeed = ovr.ClimbSpeed or 220,
				CanPounce = canPounce,
				IsCrab = ovr.IsCrab or zsClass.IsHeadcrab or false,
				PounceVelocity = pounceVel or (zsClass.IsHeadcrab and 450 or nil),
				PounceStartDelay = ovr.PounceStartDelay or swepVal("PounceStartDelay", 0.5),
				PounceDelay = ovr.PounceDelay or swepVal("PounceDelay", 1.25),
				PounceDamage = ovr.PounceDamage or swepVal("PounceDamage", 15),
				PounceDamageVsPlayerMul = ovr.PounceDamageVsPlayerMul or swepVal("PounceDamageVsPlayerMul", 1),
				PounceReach = ovr.PounceReach or swepVal("PounceReach", 26),
				PounceSize = ovr.PounceSize or swepVal("PounceSize", 12),
				RangedAttack = ovr.RangedAttack,
				OnMeleeHitHuman = ovr.OnMeleeHitHuman,
				UsePoisonDamage = ovr.UsePoisonDamage or false,
				Sounds = sounds,
				VoicePitch = zsClass.VoicePitch or 0.7,
				Animations = ovr.Animations or lib.ClassOverrides["Zombie"].Animations,
				RenderMode = ovr.RenderMode or zsClass.RenderMode or RENDERMODE_NORMAL,
				Alpha = ovr.Alpha or 255,
				AttackAlpha = ovr.AttackAlpha or 255,
				BloodColor = ovr.BloodColor or zsClass.BloodColor or BLOOD_COLOR_RED,
				Weight = ovr.Weight ~= nil and ovr.Weight or (lib.DefaultClassWeights and lib.DefaultClassWeights[zsClass.Name]) or 0
			}

			configs[zsClass.Name] = cfg
			if zsClass.Index then
				configs[zsClass.Index] = cfg
			end
		end
	end

	-- Ensure a guaranteed fallback Zombie config exists even before GAMEMODE finishes loading
	if not configs["Zombie"] then
		local ovr = lib.ClassOverrides["Zombie"]
		configs["Zombie"] = {
			Name = "Zombie",
			ZSClassIndex = 1,
			Model = ovr.FallbackModel,
			FallbackModel = ovr.FallbackModel,
			ModelScale = 1,
			Health = 225,
			Speed = 175,
			WalkSpeed = 105,
			RunSpeed = 175,
			CrouchedWalkSpeed = 0.55,
			Damage = 35,
			DamageType = DMG_SLASH,
			MeleeForceScale = 1,
			AttackRange = 48,
			MeleeSize = 4.5,
			AttackDelay = 0.74,
			AttackCooldown = 1.2,
			DetectionRange = 1600,
			Hull = defaultHull,
			HullDuck = defaultHullDuck,
			ViewOffset = defaultViewOffset,
			ViewOffsetDucked = defaultViewOffsetDucked,
			JumpPower = 200,
			StepSize = 18,
			Mass = 85,
			Points = 3,
			Wave = 0,
			Unlocked = true,
			CanJump = true,
			CanClimb = false,
			CanPounce = false,
			Sounds = defaultSounds,
			VoicePitch = 0.65,
			Animations = ovr.Animations,
			RenderMode = RENDERMODE_NORMAL,
			Alpha = 255,
			AttackAlpha = 255,
			BloodColor = BLOOD_COLOR_RED,
			Weight = 5
		}
	end

	lib.ClassConfigs = configs
	lib.ClassesBuilt = true
	return configs
end

function lib.GetClassConfig(nameOrIndex)
	if not lib.ClassesBuilt then
		lib.RebuildClassConfigs()
	end
	if nameOrIndex and lib.ClassConfigs[nameOrIndex] then
		return lib.ClassConfigs[nameOrIndex]
	end
	return lib.ClassConfigs["Zombie"]
end

function lib.ResolveClassName(query)
	if not lib.ClassesBuilt then
		lib.RebuildClassConfigs()
	end
	if not query or query == "" then return "Zombie" end
	if lib.ClassConfigs[query] then return lib.ClassConfigs[query].Name end

	local lower = string.lower(tostring(query))
	-- Exact case-insensitive match first
	for k, cfg in pairs(lib.ClassConfigs) do
		if isstring(k) and string.lower(k) == lower then
			return cfg.Name
		end
	end
	-- Partial prefix/substring match
	for k, cfg in pairs(lib.ClassConfigs) do
		if isstring(k) and string.find(string.lower(k), lower, 1, true) then
			return cfg.Name
		end
	end
	return nil
end

function lib.IsNPCClassUnlocked(className)
	local cfg = lib.GetClassConfig(className)
	if not cfg then return false end
	if GAMEMODE and GAMEMODE.IsClassUnlocked then
		if GAMEMODE:IsClassUnlocked(cfg.Name) then return true end
	end
	local wave = lib.GetCurrentWave()
	if cfg.Locked then return false end
	if cfg.Unlocked then return true end
	if cfg.Wave and wave >= cfg.Wave then return true end
	return false
end

hook.Add("InitPostEntity", lib.HookId .. ".RebuildClasses", function()
	lib.RebuildClassConfigs()
end)
