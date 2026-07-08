-- Dark Centuries: Contested zone seed data
-- All zones start neutral (progress=50, faction=0)

INSERT INTO `dc_zone_control` (`zone_id`, `zone_name`) VALUES
(267,  'Hillsbrad Foothills'),
(45,   'Arathi Highlands'),
(33,   'Stranglethorn Vale'),
(36,   'Alterac Mountains'),
(139,  'Eastern Plaguelands'),
(28,   'Western Plaguelands'),
(1377, 'Silithus'),
(3,    'Badlands'),
(46,   'Burning Steppes')
ON DUPLICATE KEY UPDATE zone_name = VALUES(zone_name);
