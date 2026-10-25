-- pfm-vehicleshop: player_vehicles plus the finance columns. Safe to run more than once and on a
-- database where pfm-garages/player_vehicles.sql already created the table with these columns.
CREATE TABLE IF NOT EXISTS `player_vehicles` (
    `id` int(11) NOT NULL AUTO_INCREMENT,
    `license` varchar(50) DEFAULT NULL,
    `citizenid` varchar(50) DEFAULT NULL,
    `vehicle` varchar(50) DEFAULT NULL,
    `hash` varchar(50) DEFAULT NULL,
    `mods` text CHARACTER SET utf8mb4 COLLATE utf8mb4_bin DEFAULT NULL,
    `plate` varchar(15) NOT NULL,
    `fakeplate` varchar(50) DEFAULT NULL,
    `garage` varchar(50) DEFAULT 'pillboxgarage',
    `fuel` int(11) DEFAULT 100,
    `engine` float DEFAULT 1000,
    `body` float DEFAULT 1000,
    `state` int(11) DEFAULT 1,
    `depotprice` int(11) NOT NULL DEFAULT 0,
    `drivingdistance` int(50) DEFAULT NULL,
    `status` text DEFAULT NULL,
    PRIMARY KEY (`id`),
    KEY `plate` (`plate`),
    KEY `citizenid` (`citizenid`),
    KEY `license` (`license`)
) ENGINE=InnoDB AUTO_INCREMENT=1;

ALTER TABLE `player_vehicles`
ADD UNIQUE INDEX IF NOT EXISTS UK_playervehicles_plate (plate);

ALTER TABLE `player_vehicles`
ADD CONSTRAINT FK_playervehicles_players FOREIGN KEY IF NOT EXISTS (citizenid)
REFERENCES `players` (citizenid) ON DELETE CASCADE ON UPDATE CASCADE;

ALTER TABLE `player_vehicles`
ADD COLUMN IF NOT EXISTS `balance` int(11) NOT NULL DEFAULT 0;
ALTER TABLE `player_vehicles`
ADD COLUMN IF NOT EXISTS `paymentamount` int(11) NOT NULL DEFAULT 0;
ALTER TABLE `player_vehicles`
ADD COLUMN IF NOT EXISTS `paymentsleft` int(11) NOT NULL DEFAULT 0;
ALTER TABLE `player_vehicles`
ADD COLUMN IF NOT EXISTS `financetime` int(11) NOT NULL DEFAULT 0;
