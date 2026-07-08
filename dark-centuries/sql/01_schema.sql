-- Dark Centuries: Zone Control
-- Run once against your AzerothCore world database

CREATE TABLE IF NOT EXISTS `dc_zone_control` (
  `zone_id`              SMALLINT UNSIGNED  NOT NULL,
  `zone_name`            VARCHAR(64)        NOT NULL,
  `capture_progress`     TINYINT UNSIGNED   NOT NULL DEFAULT 50,  -- 0=full Alliance, 100=full Horde, 50=neutral
  `controlling_faction`  TINYINT UNSIGNED   NOT NULL DEFAULT 0,   -- 0=neutral 1=Alliance 2=Horde
  `last_flip`            TIMESTAMP          NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `flip_count`           SMALLINT UNSIGNED  NOT NULL DEFAULT 0,
  PRIMARY KEY (`zone_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
