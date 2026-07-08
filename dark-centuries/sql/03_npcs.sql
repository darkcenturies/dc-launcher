-- Dark Centuries: Patrol guard NPC templates
-- Entry 900001 = Alliance Guardian   (faction 1802 = Alliance Generic PvP)
-- Entry 900002 = Horde Guardian      (faction 1801 = Horde Generic PvP)
-- Level 78, aggressive toward enemy faction, patrols randomly

DELETE FROM `creature_template` WHERE `entry` IN (900001, 900002);

INSERT INTO `creature_template`
  (`entry`, `name`, `subname`, `minlevel`, `maxlevel`, `faction`, `npcflag`,
   `unit_class`, `family`, `type`, `type_flags`,
   `BaseAttackTime`, `RangeAttackTime`, `BaseVariance`, `CombatVariance`,
   `HealthModifier`, `ManaModifier`, `ArmorModifier`, `DamageModifier`,
   `SpeedWalk`, `SpeedRun`,
   `MovementType`, `InhabitType`,
   `AIName`, `ScriptName`,
   `mechanic_immune_mask`, `flags_extra`,
   `BoundingRadius`, `CombatReach`,
   `scale`)
VALUES
-- Alliance Guardian
(900001, 'Dark Centuries Alliance Guardian', 'Territorial Forces', 78, 78, 1802, 0,
  1, 0, 7, 0,
  2000, 2000, 1.0, 1.0,
  6.0, 1.0, 1.0, 1.0,
  1.0, 1.14286,
  1, 3,
  'SmartAI', '',
  0, 0,
  0.35, 1.5, 1.0),
-- Horde Guardian
(900002, 'Dark Centuries Horde Guardian', 'Territorial Forces', 78, 78, 1801, 0,
  1, 0, 7, 0,
  2000, 2000, 1.0, 1.0,
  6.0, 1.0, 1.0, 1.0,
  1.0, 1.14286,
  1, 3,
  'SmartAI', '',
  0, 0,
  0.35, 1.5, 1.0);

-- Smart AI: attack enemy faction on sight, wander within 10yd of spawn
DELETE FROM `smart_scripts` WHERE `entryorguid` IN (900001, 900002) AND `source_type` = 0;

INSERT INTO `smart_scripts` (`entryorguid`, `source_type`, `id`, `link`, `event_type`, `event_phase_mask`,
  `event_chance`, `event_flags`, `event_param1`, `event_param2`, `event_param3`, `event_param4`,
  `action_type`, `action_param1`, `action_param2`, `action_param3`, `action_param4`, `action_param5`, `action_param6`,
  `target_type`, `target_param1`, `target_param2`, `target_param3`, `target_x`, `target_y`, `target_z`, `target_o`, `comment`)
VALUES
-- Alliance Guardian: attack Horde players on sight
(900001, 0, 0, 0, 54, 0, 100, 0, 0, 0, 0, 0,  1, 0, 0, 0, 0, 0, 0,  19, 2, 30, 0, 0, 0, 0, 0, 'DC Alliance Guard - Attack Horde on sight'),
-- Horde Guardian: attack Alliance players on sight
(900002, 0, 0, 0, 54, 0, 100, 0, 0, 0, 0, 0,  1, 0, 0, 0, 0, 0, 0,  19, 1, 30, 0, 0, 0, 0, 0, 'DC Horde Guard - Attack Alliance on sight');
