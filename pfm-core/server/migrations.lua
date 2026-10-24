-- Versioned database migrations shared by every PF resource.
--
-- Each resource passes an ordered list of { version = <int>, name = <string>, up = <list of SQL | function> }.
-- Applied versions are recorded per resource in pf_schema_migrations, so a migration runs once on
-- each installation. Steps must themselves be safe to re-run (CREATE TABLE IF NOT EXISTS, guarded
-- ALTERs via the helpers below): MySQL commits DDL immediately, so a migration interrupted halfway
-- is retried from its first step on the next start.

local MIGRATIONS_TABLE = [[
CREATE TABLE IF NOT EXISTS `pf_schema_migrations` (
  `resource` VARCHAR(64) NOT NULL,
  `version` INT NOT NULL,
  `name` VARCHAR(128) NOT NULL,
  `applied_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`resource`, `version`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
]]

local running = {}

--- True when the column exists in the current database.
function MigrationColumnExists(tableName, columnName)
    local count = MySQL.scalar.await([[
        SELECT COUNT(*) FROM information_schema.COLUMNS
        WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ? AND COLUMN_NAME = ?
    ]], { tableName, columnName })
    return (tonumber(count) or 0) > 0
end

--- True when the index exists on the table in the current database.
function MigrationIndexExists(tableName, indexName)
    local count = MySQL.scalar.await([[
        SELECT COUNT(*) FROM information_schema.STATISTICS
        WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ? AND INDEX_NAME = ?
    ]], { tableName, indexName })
    return (tonumber(count) or 0) > 0
end

--- Runs a resource's pending migrations in version order.
--- @param resource string
--- @param migrations table
--- @return boolean ok, string|nil err
function RunMigrations(resource, migrations)
    if type(resource) ~= 'string' or resource == '' or type(migrations) ~= 'table' then
        return false, 'invalid arguments'
    end
    if running[resource] then return false, 'migrations already running for ' .. resource end
    running[resource] = true

    local ok, err = pcall(function()
        MySQL.query.await(MIGRATIONS_TABLE)
        local rows = MySQL.query.await('SELECT version FROM pf_schema_migrations WHERE resource = ?', { resource }) or {}
        local applied = {}
        for _, row in ipairs(rows) do applied[tonumber(row.version)] = true end

        local ordered = {}
        for _, m in ipairs(migrations) do ordered[#ordered + 1] = m end
        table.sort(ordered, function(a, b) return a.version < b.version end)

        for _, m in ipairs(ordered) do
            if not applied[m.version] then
                if type(m.up) == 'function' then
                    m.up()
                else
                    for _, sql in ipairs(m.up or {}) do MySQL.query.await(sql) end
                end
                MySQL.insert.await('INSERT INTO pf_schema_migrations (resource, version, name) VALUES (?, ?, ?)', { resource, m.version, m.name or '' })
                print(('^2[pf-migrations]^7 %s v%d applied: %s'):format(resource, m.version, m.name or ''))
            end
        end
    end)

    running[resource] = nil
    if not ok then
        print(('^1[pf-migrations]^7 %s failed: %s'):format(resource, tostring(err)))
        return false, tostring(err)
    end
    return true
end

exports('RunMigrations', RunMigrations)
exports('MigrationColumnExists', MigrationColumnExists)
exports('MigrationIndexExists', MigrationIndexExists)
