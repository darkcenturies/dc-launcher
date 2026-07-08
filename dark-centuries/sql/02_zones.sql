-- World of Warcraft: Dark Centuries — full Azeroth zone seed
-- Every zone starts contested (50) except faction home territory,
-- which is locked to its owner (progress 0 = Alliance, 100 = Horde).
-- INSERT IGNORE preserves existing capture progress on reinstall.

INSERT IGNORE INTO `dc_zone_control` (`zone_id`, `zone_name`, `capture_progress`, `controlling_faction`) VALUES
-- Eastern Kingdoms — Alliance home turf
(1,    'Dun Morogh',           0,  1),
(12,   'Elwynn Forest',        0,  1),
(1519, 'Stormwind City',       0,  1),
(1537, 'Ironforge',            0,  1),
-- Eastern Kingdoms — Horde home turf
(85,   'Tirisfal Glades',      100, 2),
(1497, 'Undercity',            100, 2),
(3430, 'Eversong Woods',       100, 2),
(3433, 'Ghostlands',           100, 2),
(3487, 'Silvermoon City',      100, 2),
-- Eastern Kingdoms — contested
(3,    'Badlands',             50, 0),
(4,    'Blasted Lands',        50, 0),
(8,    'Swamp of Sorrows',     50, 0),
(10,   'Duskwood',             50, 0),
(11,   'Wetlands',             50, 0),
(28,   'Western Plaguelands',  50, 0),
(33,   'Stranglethorn Vale',   50, 0),
(36,   'Alterac Mountains',    50, 0),
(38,   'Loch Modan',           50, 0),
(40,   'Westfall',             50, 0),
(41,   'Deadwind Pass',        50, 0),
(44,   'Redridge Mountains',   50, 0),
(45,   'Arathi Highlands',     50, 0),
(46,   'Burning Steppes',      50, 0),
(47,   'The Hinterlands',      50, 0),
(51,   'Searing Gorge',        50, 0),
(130,  'Silverpine Forest',    50, 0),
(139,  'Eastern Plaguelands',  50, 0),
(267,  'Hillsbrad Foothills',  50, 0),
-- Kalimdor — Alliance home turf
(141,  'Teldrassil',           0,  1),
(1657, 'Darnassus',            0,  1),
(3524, 'Azuremyst Isle',       0,  1),
(3525, 'Bloodmyst Isle',       0,  1),
(3557, 'The Exodar',           0,  1),
-- Kalimdor — Horde home turf
(14,   'Durotar',              100, 2),
(215,  'Mulgore',              100, 2),
(1637, 'Orgrimmar',            100, 2),
(1638, 'Thunder Bluff',        100, 2),
-- Kalimdor — contested
(15,   'Dustwallow Marsh',     50, 0),
(16,   'Azshara',              50, 0),
(17,   'The Barrens',          50, 0),
(148,  'Darkshore',            50, 0),
(331,  'Ashenvale',            50, 0),
(357,  'Feralas',              50, 0),
(361,  'Felwood',              50, 0),
(400,  'Thousand Needles',     50, 0),
(405,  'Desolace',             50, 0),
(406,  'Stonetalon Mountains', 50, 0),
(440,  'Tanaris',              50, 0),
(490,  'Un''Goro Crater',      50, 0),
(493,  'Moonglade',            50, 0),
(618,  'Winterspring',         50, 0),
(1377, 'Silithus',             50, 0);
