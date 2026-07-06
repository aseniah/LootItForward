local _, LIF = ...

-- Primary stat, weapon/off-hand usability, and dual-wield now live per-spec in
-- LIF.SPEC_TABLE below (character-centric truth tables). The former
-- SPEC_PRIMARY_STAT, SPEC_DUAL_WIELD, and Hunter weapon-gate tables were folded
-- into it and removed. Verify SPEC_TABLE entries in-game via
-- GetSpecializationInfoByID(specID); re-verify after major patches.

-- ============================================================
-- CLASS_SPECS[classToken] = { specID, ... }
-- Spec IDs grouped by class. Used by the pre-inspect prefilter (specID nil):
-- "can ANY spec of this class use subID X" = union across these specs. An
-- unrecognized/future specID simply isn't listed, so it has no SPEC_TABLE
-- entry and fails closed with no special-casing (F2).
-- ============================================================
LIF.CLASS_SPECS = {
  WARRIOR     = { 71, 72, 73 },
  PALADIN     = { 65, 66, 70 },
  HUNTER      = { 253, 254, 255 },
  ROGUE       = { 259, 260, 261 },
  PRIEST      = { 256, 257, 258 },
  DEATHKNIGHT = { 250, 251, 252 },
  SHAMAN      = { 262, 263, 264 },
  MAGE        = { 62, 63, 64 },
  WARLOCK     = { 265, 266, 267 },
  MONK        = { 268, 269, 270 },
  DRUID       = { 102, 103, 104, 105 },
  DEMONHUNTER = { 577, 581, 1480 },
  EVOKER      = { 1467, 1468, 1473 },
}

-- ============================================================
-- SPEC_TABLE[specID] = per-spec usability truth table (positive facts only).
--   primaryStat   = "STR" | "AGI" | "INT"
--   mainHand      = { [weaponSubID]=true }  -- classID 2, slot 16
--   offHandWeapon = { [weaponSubID]=true }  -- classID 2, slot 17 (dual-wield)
--   offHandItem   = { [itemSubID]=true }    -- classID 4, slot 17 (shield 6 / holdable 0)
-- Inclusion = usable, omission = not. No inheritance, no baseline+override.
--
-- Weapon subIDs: 0 1HAxe · 1 2HAxe · 2 Bow · 3 Gun · 4 1HMace · 5 2HMace ·
--   6 Polearm · 7 1HSword · 8 2HSword · 9 Warglaive · 10 Staff · 13 Fist ·
--   15 Dagger · 18 Crossbow · 19 Wand.  Off-hand item subIDs: 0 Holdable · 6 Shield.
--
-- PROVENANCE / VALIDATION STATUS: validated spec-by-spec against authoritative
-- sources for the Midnight expansion (12.0.x) — warcraft.wiki.gg weapon
-- proficiency matrix plus current spec mechanics — in the 2026-07-04
-- data-validation pass. Each set is a positive fact about what the spec can
-- actually use in live play (functional capability, not raw equippability or
-- stat-weight preference). Notable Midnight-specific facts baked in below:
--   * 2H-only melee specs (Arms, Ret, Blood, Unholy, Feral, Guardian) omit all
--     1H forms and carry no off-hand item — no free off-hand slot.
--   * Fury lost Single-Minded Fury → Titan's Grip 2H both hands, no off-hand item.
--   * Shamans cannot use swords or 2H axes/maces; Ele/Resto add daggers + staff.
--   * Mages / Warlocks gained the 1H sword; Demon Hunters gained 1H sword + 1H axe
--     and dropped the holdable (all specs dual-wield). Devourer (1480, INT caster)
--     additionally gained the dagger skill in Midnight — INT daggers, both hands;
--     Havoc/Vengeance stay dagger-incompatible (physical abilities need glaives/swords).
--   * Rogues: Assassination & Subtlety are dagger-locked in BOTH hands; Outlaw's
--     main-hand excludes daggers but its off-hand accepts any 1H. (Outlaw's
--     main-hand dagger exclusion is a mechanical restriction — its strikes scale
--     off slow weapon damage — not a stat-weight preference; hence it belongs in
--     the truth table. An either-hand dagger drop still qualifies Outlaw via the
--     off-hand slot; see SpecWeaponHands in loot.lua.)
-- Re-verify after major patches via GetSpecializationInfoByID(specID).
-- ============================================================
LIF.SPEC_TABLE = {
  -- Warrior (STR). Arms/Ret-style 2H specs carry no off-hand item.
  [71]  = { primaryStat = "STR", mainHand = {[1]=true,[5]=true,[6]=true,[8]=true}, offHandWeapon = {}, offHandItem = {} }, -- Arms (2H only)
  [72]  = { primaryStat = "STR", mainHand = {[1]=true,[5]=true,[6]=true,[8]=true}, offHandWeapon = {[1]=true,[5]=true,[6]=true,[8]=true}, offHandItem = {} }, -- Fury (Titan's Grip: 2H both hands)
  [73]  = { primaryStat = "STR", mainHand = {[0]=true,[4]=true,[7]=true,[13]=true}, offHandWeapon = {}, offHandItem = {[6]=true} }, -- Protection (1H + shield)

  -- Paladin. 1H specs (Holy/Prot) + shield; Prot has no holdable. Ret is 2H.
  [65]  = { primaryStat = "INT", mainHand = {[0]=true,[4]=true,[7]=true}, offHandWeapon = {}, offHandItem = {[0]=true,[6]=true} }, -- Holy (1H + holdable/shield)
  [66]  = { primaryStat = "STR", mainHand = {[0]=true,[4]=true,[7]=true}, offHandWeapon = {}, offHandItem = {[6]=true} }, -- Protection (1H + shield)
  [70]  = { primaryStat = "STR", mainHand = {[1]=true,[5]=true,[6]=true,[8]=true}, offHandWeapon = {}, offHandItem = {} }, -- Retribution (2H only)

  -- Hunter (AGI). BM/MM: ranged only. Survival: melee (no Fist); off-hand is 1H only.
  [253] = { primaryStat = "AGI", mainHand = {[2]=true,[3]=true,[18]=true}, offHandWeapon = {}, offHandItem = {} }, -- Beast Mastery
  [254] = { primaryStat = "AGI", mainHand = {[2]=true,[3]=true,[18]=true}, offHandWeapon = {}, offHandItem = {} }, -- Marksmanship
  [255] = { primaryStat = "AGI", mainHand = {[0]=true,[1]=true,[6]=true,[7]=true,[8]=true,[10]=true,[15]=true}, offHandWeapon = {[0]=true,[7]=true,[15]=true}, offHandItem = {} }, -- Survival

  -- Rogue (AGI). Assa/Sub dagger-locked both hands; Outlaw MH no dagger, OH any 1H.
  [259] = { primaryStat = "AGI", mainHand = {[15]=true}, offHandWeapon = {[15]=true}, offHandItem = {} }, -- Assassination
  [260] = { primaryStat = "AGI", mainHand = {[0]=true,[4]=true,[7]=true,[13]=true}, offHandWeapon = {[0]=true,[4]=true,[7]=true,[13]=true,[15]=true}, offHandItem = {} }, -- Outlaw
  [261] = { primaryStat = "AGI", mainHand = {[15]=true}, offHandWeapon = {[15]=true}, offHandItem = {} }, -- Subtlety

  -- Priest (INT). mainHand: 4,10,15,19. offHandItem: holdable(0).
  [256] = { primaryStat = "INT", mainHand = {[4]=true,[10]=true,[15]=true,[19]=true}, offHandWeapon = {}, offHandItem = {[0]=true} }, -- Discipline
  [257] = { primaryStat = "INT", mainHand = {[4]=true,[10]=true,[15]=true,[19]=true}, offHandWeapon = {}, offHandItem = {[0]=true} }, -- Holy
  [258] = { primaryStat = "INT", mainHand = {[4]=true,[10]=true,[15]=true,[19]=true}, offHandWeapon = {}, offHandItem = {[0]=true} }, -- Shadow

  -- Death Knight (STR). Blood/Unholy 2H only; Frost dual-wields 1H. No off-hand item.
  [250] = { primaryStat = "STR", mainHand = {[1]=true,[5]=true,[6]=true,[8]=true}, offHandWeapon = {}, offHandItem = {} }, -- Blood (2H only)
  [251] = { primaryStat = "STR", mainHand = {[0]=true,[1]=true,[4]=true,[5]=true,[6]=true,[7]=true,[8]=true}, offHandWeapon = {[0]=true,[4]=true,[7]=true}, offHandItem = {} }, -- Frost (2H or dual 1H)
  [252] = { primaryStat = "STR", mainHand = {[1]=true,[5]=true,[6]=true,[8]=true}, offHandWeapon = {}, offHandItem = {} }, -- Unholy (2H only)

  -- Shaman. No swords / no 2H axe-mace. Ele/Resto: 1H+staff+dagger, shield/holdable.
  -- Enhancement dual-wields 1H (no staff), no off-hand item.
  [262] = { primaryStat = "INT", mainHand = {[0]=true,[4]=true,[10]=true,[13]=true,[15]=true}, offHandWeapon = {}, offHandItem = {[0]=true,[6]=true} }, -- Elemental
  [263] = { primaryStat = "AGI", mainHand = {[0]=true,[4]=true,[13]=true,[15]=true}, offHandWeapon = {[0]=true,[4]=true,[13]=true,[15]=true}, offHandItem = {} }, -- Enhancement
  [264] = { primaryStat = "INT", mainHand = {[0]=true,[4]=true,[10]=true,[13]=true,[15]=true}, offHandWeapon = {}, offHandItem = {[0]=true,[6]=true} }, -- Restoration

  -- Mage (INT). mainHand: 1H-sword(7),staff,dagger,wand. offHandItem: holdable(0).
  [62]  = { primaryStat = "INT", mainHand = {[7]=true,[10]=true,[15]=true,[19]=true}, offHandWeapon = {}, offHandItem = {[0]=true} }, -- Arcane
  [63]  = { primaryStat = "INT", mainHand = {[7]=true,[10]=true,[15]=true,[19]=true}, offHandWeapon = {}, offHandItem = {[0]=true} }, -- Fire
  [64]  = { primaryStat = "INT", mainHand = {[7]=true,[10]=true,[15]=true,[19]=true}, offHandWeapon = {}, offHandItem = {[0]=true} }, -- Frost

  -- Warlock (INT). mainHand: 1H-sword(7),staff,dagger,wand. offHandItem: holdable(0).
  [265] = { primaryStat = "INT", mainHand = {[7]=true,[10]=true,[15]=true,[19]=true}, offHandWeapon = {}, offHandItem = {[0]=true} }, -- Affliction
  [266] = { primaryStat = "INT", mainHand = {[7]=true,[10]=true,[15]=true,[19]=true}, offHandWeapon = {}, offHandItem = {[0]=true} }, -- Demonology
  [267] = { primaryStat = "INT", mainHand = {[7]=true,[10]=true,[15]=true,[19]=true}, offHandWeapon = {}, offHandItem = {[0]=true} }, -- Destruction

  -- Monk. mainHand: 0,4,6,7,10,13. Brew/WW dual-wield 1H (off-hand 1H only, no
  -- off-hand item). Mistweaver: 1H + holdable, or 2H staff.
  [268] = { primaryStat = "AGI", mainHand = {[0]=true,[4]=true,[6]=true,[7]=true,[10]=true,[13]=true}, offHandWeapon = {[0]=true,[4]=true,[7]=true,[13]=true}, offHandItem = {} }, -- Brewmaster
  [269] = { primaryStat = "AGI", mainHand = {[0]=true,[4]=true,[6]=true,[7]=true,[10]=true,[13]=true}, offHandWeapon = {[0]=true,[4]=true,[7]=true,[13]=true}, offHandItem = {} }, -- Windwalker
  [270] = { primaryStat = "INT", mainHand = {[0]=true,[4]=true,[6]=true,[7]=true,[10]=true,[13]=true}, offHandWeapon = {}, offHandItem = {[0]=true} }, -- Mistweaver

  -- Druid. Balance/Resto: caster 1H/2H + holdable. Feral/Guardian: 2H only.
  [102] = { primaryStat = "INT", mainHand = {[4]=true,[5]=true,[6]=true,[10]=true,[13]=true,[15]=true}, offHandWeapon = {}, offHandItem = {[0]=true} }, -- Balance
  [103] = { primaryStat = "AGI", mainHand = {[5]=true,[6]=true,[10]=true}, offHandWeapon = {}, offHandItem = {} }, -- Feral (2H only)
  [104] = { primaryStat = "AGI", mainHand = {[5]=true,[6]=true,[10]=true}, offHandWeapon = {}, offHandItem = {} }, -- Guardian (2H only)
  [105] = { primaryStat = "INT", mainHand = {[4]=true,[5]=true,[6]=true,[10]=true,[13]=true,[15]=true}, offHandWeapon = {}, offHandItem = {[0]=true} }, -- Restoration

  -- Demon Hunter. mainHand: 1H-axe(0),1H-sword(7),warglaive(9),fist(13). All
  -- dual-wield; no off-hand item.
  [577] = { primaryStat = "AGI", mainHand = {[0]=true,[7]=true,[9]=true,[13]=true}, offHandWeapon = {[0]=true,[7]=true,[9]=true,[13]=true}, offHandItem = {} }, -- Havoc
  [581] = { primaryStat = "AGI", mainHand = {[0]=true,[7]=true,[9]=true,[13]=true}, offHandWeapon = {[0]=true,[7]=true,[9]=true,[13]=true}, offHandItem = {} }, -- Vengeance
  [1480] = { primaryStat = "INT", mainHand = {[0]=true,[7]=true,[9]=true,[13]=true,[15]=true}, offHandWeapon = {[0]=true,[7]=true,[9]=true,[13]=true,[15]=true}, offHandItem = {} }, -- Devourer (Midnight: +INT daggers)

  -- Evoker (INT). mainHand: 0,1,4,5,7,8,10,13,15. offHandItem: holdable(0).
  [1467] = { primaryStat = "INT", mainHand = {[0]=true,[1]=true,[4]=true,[5]=true,[7]=true,[8]=true,[10]=true,[13]=true,[15]=true}, offHandWeapon = {}, offHandItem = {[0]=true} }, -- Devastation
  [1468] = { primaryStat = "INT", mainHand = {[0]=true,[1]=true,[4]=true,[5]=true,[7]=true,[8]=true,[10]=true,[13]=true,[15]=true}, offHandWeapon = {}, offHandItem = {[0]=true} }, -- Preservation
  [1473] = { primaryStat = "INT", mainHand = {[0]=true,[1]=true,[4]=true,[5]=true,[7]=true,[8]=true,[10]=true,[13]=true,[15]=true}, offHandWeapon = {}, offHandItem = {[0]=true} }, -- Augmentation
}

-- Spec ID → "Spec/Class" abbreviation for display (debug window)
LIF.SPEC_LABEL = {
  -- Warrior
  [71]   = "Arms/War",
  [72]   = "Fury/War",
  [73]   = "Prot/War",
  -- Paladin
  [65]   = "Holy/Pal",
  [66]   = "Prot/Pal",
  [70]   = "Ret/Pal",
  -- Hunter
  [253]  = "BM/Hunt",
  [254]  = "MM/Hunt",
  [255]  = "Surv/Hunt",
  -- Rogue
  [259]  = "Assa/Rog",
  [260]  = "Outl/Rog",
  [261]  = "Sub/Rog",
  -- Priest
  [256]  = "Disc/Pri",
  [257]  = "Holy/Pri",
  [258]  = "Shad/Pri",
  -- Death Knight
  [250]  = "Blood/DK",
  [251]  = "Frost/DK",
  [252]  = "Unho/DK",
  -- Shaman
  [262]  = "Elem/Sham",
  [263]  = "Enh/Sham",
  [264]  = "Resto/Sham",
  -- Mage
  [62]   = "Arc/Mage",
  [63]   = "Fire/Mage",
  [64]   = "Frost/Mage",
  -- Warlock
  [265]  = "Affl/Lock",
  [266]  = "Demo/Lock",
  [267]  = "Dest/Lock",
  -- Monk
  [268]  = "Brew/Monk",
  [269]  = "WW/Monk",
  [270]  = "MW/Monk",
  -- Druid
  [102]  = "Bal/Dru",
  [103]  = "Feral/Dru",
  [104]  = "Guard/Dru",
  [105]  = "Resto/Dru",
  -- Demon Hunter
  [577]  = "Havoc/DH",
  [581]  = "Veng/DH",
  [1480] = "Devr/DH",
  -- Evoker
  [1467] = "Dvst/Evok",
  [1468] = "Pres/Evok",
  [1473] = "Aug/Evok",
}

-- Class token → short display name for chat notifications and UI.
LIF.CLASS_SHORT = {
  WARRIOR     = "Warrior", PALADIN     = "Paladin", HUNTER  = "Hunter",
  ROGUE       = "Rogue",   PRIEST      = "Priest",  SHAMAN  = "Shaman",
  MAGE        = "Mage",    WARLOCK     = "Warlock", DRUID   = "Druid",
  MONK        = "Monk",    EVOKER      = "Evoker",
  DEATHKNIGHT = "DK",      DEMONHUNTER = "DH",
}
