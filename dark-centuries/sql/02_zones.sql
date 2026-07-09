-- World of Warcraft: Dark Centuries — lore-based world seed
-- Alliance/Horde territory is locked (cannot be fought for); contested
-- warfronts start at 50. Truly neutral zones (Moonglade, Stranglethorn
-- Vale, Tanaris, Winterspring, Un'Goro, Silithus, Deadwind Pass) take
-- no part in the war and have no rows.
-- INSERT IGNORE preserves existing capture progress on reinstall.

-- Remove truly neutral zones from any earlier install
DELETE FROM `dc_zone_control` WHERE `zone_id` IN (493, 33, 440, 618, 490, 1377, 41);

INSERT IGNORE INTO `dc_zone_control` (`zone_id`, `zone_name`, `capture_progress`, `controlling_faction`) VALUES
-- Eastern Kingdoms — Alliance territory (locked)
(1,    'Dun Morogh',           0,  1),
(10,   'Duskwood',             0,  1),
(11,   'Wetlands',             0,  1),
(12,   'Elwynn Forest',        0,  1),
(38,   'Loch Modan',           0,  1),
(40,   'Westfall',             0,  1),
(44,   'Redridge Mountains',   0,  1),
(1519, 'Stormwind City',       0,  1),
(1537, 'Ironforge',            0,  1),
-- Eastern Kingdoms — Horde territory (locked)
(85,   'Tirisfal Glades',      100, 2),
(130,  'Silverpine Forest',    100, 2),
(1497, 'Undercity',            100, 2),
(3430, 'Eversong Woods',       100, 2),
(3433, 'Ghostlands',           100, 2),
(3487, 'Silvermoon City',      100, 2),
-- Eastern Kingdoms — contested warfronts
(3,    'Badlands',             50, 0),
(4,    'Blasted Lands',        50, 0),
(8,    'Swamp of Sorrows',     50, 0),
(28,   'Western Plaguelands',  50, 0),
(36,   'Alterac Mountains',    50, 0),
(45,   'Arathi Highlands',     50, 0),
(46,   'Burning Steppes',      50, 0),
(47,   'The Hinterlands',      50, 0),
(51,   'Searing Gorge',        50, 0),
(139,  'Eastern Plaguelands',  50, 0),
(267,  'Hillsbrad Foothills',  50, 0),
-- Kalimdor — Alliance territory (locked)
(141,  'Teldrassil',           0,  1),
(148,  'Darkshore',            0,  1),
(1657, 'Darnassus',            0,  1),
(3524, 'Azuremyst Isle',       0,  1),
(3525, 'Bloodmyst Isle',       0,  1),
(3557, 'The Exodar',           0,  1),
-- Kalimdor — Horde territory (locked)
(14,   'Durotar',              100, 2),
(17,   'The Barrens',          100, 2),
(215,  'Mulgore',              100, 2),
(1637, 'Orgrimmar',            100, 2),
(1638, 'Thunder Bluff',        100, 2),
-- Kalimdor — contested warfronts
(15,   'Dustwallow Marsh',     50, 0),
(16,   'Azshara',              50, 0),
(331,  'Ashenvale',            50, 0),
(357,  'Feralas',              50, 0),
(361,  'Felwood',              50, 0),
(400,  'Thousand Needles',     50, 0),
(405,  'Desolace',             50, 0),
(406,  'Stonetalon Mountains', 50, 0);
