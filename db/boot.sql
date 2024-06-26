/*
 * Use this script when inne has been down for a long time (over a day) so
 * that the dates are updated correctly.
 *
 * Usage (for Linux): mysql -uroot -proot inne < db/boot.sql
 * Date format: 2020-02-18 21:00:00 +0100
 *
 * My (Eddy) old .sqliterc file (SQLite booting file):
 * .header on
 * .mode column
 * .timer on
 * .width 2 20 25
 * .open inne.db
 */

UPDATE global_properties
SET `value` = '2020-11-03 22:00:00 +0200'
WHERE `key` = 'next_score_update';

UPDATE global_properties
SET `value` = '2020-11-03 22:00:00 +0200'
WHERE `key` = 'next_level_update';

UPDATE global_properties
SET `value` = '2020-11-03 22:00:00 +0200'
WHERE `key` = 'next_episode_update';

UPDATE global_properties
SET `value` = '2020-11-03 22:00:00 +0200'
WHERE `key` = 'next_story_update';

UPDATE global_properties
SET `value` = '2020-11-03 22:00:00 +0200'
WHERE `key` = 'next_demo_update';

UPDATE global_properties
SET `value` = '2020-11-03 22:00:00 +0200'
WHERE `key` = 'next_report_update';

UPDATE global_properties
SET `value` = '2020-11-03 22:00:00 +0200'
WHERE `key` = 'next_userlevel_score_update';

UPDATE global_properties
SET `value` = '2020-11-03 22:00:00 +0200'
WHERE `key` = 'next_userlevel_report_update';

UPDATE global_properties
SET `value` = '2020-11-03 22:00:00 +0200'
WHERE `key` = 'next_history_update';

UPDATE global_properties
SET `value` = '2020-11-03 22:00:00 +0200'
WHERE `key` = 'next_userlevel_history_update';

UPDATE global_properties
SET `value` = '2020-11-03 22:00:00 +0200'
WHERE `key` = 'next_userlevel_tab_update';