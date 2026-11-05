-- pfm-prison tables (pf_schema_migrations key 'pfm-prison'; PF_DATABASE_MIGRATIONS.md section 8).
-- This is the only file of the resource that runs migrations (the runner refuses a second
-- concurrent run of the same key). Other files wait for PFPrisonSchema.Ready().
--
--   v1 inmates and events (batch 16C):
--     pf_prison_inmates  one row per citizen pfm-prison holds for a pf-justice order: the order, the
--                        status (intake, in_cell, escaped, releasing), the property receipts it seized
--                        at intake, and how many work tickets were credited. A row means "this
--                        citizen is physically ours": a login with a row and no open order is let out.
--     pf_prison_events   the audit trail (architecture 3.8): intake, release, credit, escape,
--                        recapture, sendback, anomaly, lockdown. Swept after EventRetentionDays.
--
-- Every step is rerun-safe (CREATE ... IF NOT EXISTS); DDL auto-commits, so an interrupted version
-- restarts from its first step.

PFPrisonSchema = PFPrisonSchema or {}
local Schema = PFPrisonSchema

Schema.KEY = 'pfm-prison'

Schema.V1 = {
    [[CREATE TABLE IF NOT EXISTS `pf_prison_inmates` (
      `citizenid` VARCHAR(64) NOT NULL,
      `order_id` INT NOT NULL,
      `facility` VARCHAR(32) NOT NULL,
      `status` VARCHAR(12) NOT NULL,
      `cell_id` VARCHAR(16) NULL,
      `classification` VARCHAR(8) NOT NULL DEFAULT 'medium',
      `admitted_at` BIGINT NOT NULL,
      `status_at` BIGINT NOT NULL,
      `job_ticket` INT NULL,
      `receipt_ids` VARCHAR(255) NULL,
      PRIMARY KEY (`citizenid`),
      KEY `idx_pi_order` (`order_id`),
      KEY `idx_pi_status` (`facility`, `status`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]],
    [[CREATE TABLE IF NOT EXISTS `pf_prison_events` (
      `id` BIGINT NOT NULL AUTO_INCREMENT,
      `citizenid` VARCHAR(64) NULL,
      `facility` VARCHAR(32) NOT NULL,
      `kind` VARCHAR(16) NOT NULL,
      `detail` LONGTEXT NULL,
      `actor_cid` VARCHAR(64) NULL,
      `at` BIGINT NOT NULL,
      PRIMARY KEY (`id`),
      KEY `idx_pe_cid` (`citizenid`, `at`),
      KEY `idx_pe_kind` (`facility`, `kind`, `at`),
      KEY `idx_pe_at` (`at`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]],
}

Schema.Migrations = {
    { version = 1, name = 'prison inmates and events', up = Schema.V1 },
}

Schema.ready = false
Schema.lastError = nil

--- Applies the migrations once. True when the tables are usable.
function Schema.Run()
    if Schema.ready then return true end
    local ok, applied, err = pcall(function()
        return exports['pfm-core']:RunMigrations(Schema.KEY, Schema.Migrations)
    end)
    if ok and applied == true then
        Schema.ready, Schema.lastError = true, nil
        return true
    end
    Schema.lastError = ok and tostring(err or 'migrations failed') or tostring(applied)
    return false
end

function Schema.Ready() return Schema.ready == true end
