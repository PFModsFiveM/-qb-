-- ONE-TIME UPGRADE, not part of a fresh install.
-- Copies saved items from the old qb-inventory tables (gloveboxitems, stashitems, trunkitems) into
-- `inventories`. Run it only on a database that still has those three tables, after qb-inventory.sql.
-- On a fresh database it fails with "Table ... doesn't exist", which is expected.
-- INSERT IGNORE: an inventory that already exists in `inventories` is kept as it is, so running this
-- again never overwrites newer items with old ones.
INSERT IGNORE INTO inventories (identifier, items)
SELECT
  CONCAT('glovebox-', plate),
  items
FROM
  gloveboxitems

UNION ALL

SELECT
  stash,
  items
FROM
  stashitems

UNION ALL

SELECT
  CONCAT('trunk-', plate),
  items
FROM
  trunkitems;
