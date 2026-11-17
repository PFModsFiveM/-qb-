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
--   v2 facility (batch 19D, server/facility.lua, schedule.lua, discipline.lua, visitation.lua):
--     pf_prison_cells       cells per facility, seeded from config_facility.lua with INSERT IGNORE
--                           at every start (facility.lua), so new config cells appear without a version.
--     pf_prison_counts      headcounts: expected / present from server presence, the missing list.
--     pf_prison_infractions discipline (architecture 5.13). Adds `idem_key` (UNIQUE) beyond the doc
--                           DDL so RecordInfraction is idempotent per caller key (architecture 3.3).
--     pf_prison_visits      visitation bookings and their visit-room state.
--     pf_prison_privileges  timed privilege losses (commissary, yard, visits, phone, work) and
--                           solitary terms (kind 'solitary'); a row ends at until_at.
--   v3 economy (batch 19D for 19E, server/work.lua, economy.lua):
--     pf_prison_account_tx  the inmate trust ledger; balance = SUM(amount) of settled rows.
--     pf_prison_work_log    one row per credited work ticket (UNIQUE order_id + ticket).
--   v4 security (batch 19D for 19F, server/security.lua):
--     pf_prison_searches    cell / pat / visitor / vehicle searches and what they found.
--     pf_prison_escapes     escapes, the warrant asked for, and the recapture.
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

Schema.V2 = {
    [[CREATE TABLE IF NOT EXISTS `pf_prison_cells` (
      `facility` VARCHAR(32) NOT NULL,
      `cell_id` VARCHAR(16) NOT NULL,
      `block` VARCHAR(8) NOT NULL,
      `classification` VARCHAR(8) NOT NULL,
      `capacity` TINYINT NOT NULL DEFAULT 2,
      `out_of_service` TINYINT(1) NOT NULL DEFAULT 0,
      PRIMARY KEY (`facility`, `cell_id`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]],
    [[CREATE TABLE IF NOT EXISTS `pf_prison_counts` (
      `id` INT NOT NULL AUTO_INCREMENT,
      `facility` VARCHAR(32) NOT NULL,
      `due_at` BIGINT NOT NULL,
      `closed_at` BIGINT NULL,
      `expected` SMALLINT NOT NULL,
      `present` SMALLINT NOT NULL DEFAULT 0,
      `missing` LONGTEXT NULL,
      `by_cid` VARCHAR(64) NULL,
      PRIMARY KEY (`id`),
      KEY `idx_pc_fac` (`facility`, `due_at`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]],
    [[CREATE TABLE IF NOT EXISTS `pf_prison_infractions` (
      `id` INT NOT NULL AUTO_INCREMENT,
      `citizenid` VARCHAR(64) NOT NULL,
      `order_id` INT NULL,
      `code` VARCHAR(16) NOT NULL,
      `severity` TINYINT NOT NULL,
      `state` VARCHAR(16) NOT NULL,
      `evidence_ids` VARCHAR(255) NULL,
      `hearing_at` BIGINT NULL,
      `heard_by` VARCHAR(64) NULL,
      `sanction` LONGTEXT NULL,
      `reported_by` VARCHAR(64) NULL,
      `at` BIGINT NOT NULL,
      `idem_key` VARCHAR(128) NULL,
      PRIMARY KEY (`id`),
      UNIQUE KEY `uq_pinf_key` (`idem_key`),
      KEY `idx_pinf_cid` (`citizenid`, `state`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]],
    [[CREATE TABLE IF NOT EXISTS `pf_prison_visits` (
      `id` INT NOT NULL AUTO_INCREMENT,
      `inmate_cid` VARCHAR(64) NOT NULL,
      `visitor_cid` VARCHAR(64) NOT NULL,
      `slot_at` BIGINT NOT NULL,
      `state` VARCHAR(12) NOT NULL,
      `kind` VARCHAR(10) NOT NULL DEFAULT 'social',
      `searched` TINYINT(1) NOT NULL DEFAULT 0,
      `notes` VARCHAR(255) NULL,
      `created_at` BIGINT NOT NULL,
      PRIMARY KEY (`id`),
      KEY `idx_pv_inmate` (`inmate_cid`, `slot_at`),
      KEY `idx_pv_visitor` (`visitor_cid`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]],
    [[CREATE TABLE IF NOT EXISTS `pf_prison_privileges` (
      `id` INT NOT NULL AUTO_INCREMENT,
      `citizenid` VARCHAR(64) NOT NULL,
      `kind` VARCHAR(16) NOT NULL,
      `until_at` BIGINT NOT NULL,
      `infraction_id` INT NULL,
      PRIMARY KEY (`id`),
      KEY `idx_ppr_cid` (`citizenid`, `until_at`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]],
}

Schema.V3 = {
    [[CREATE TABLE IF NOT EXISTS `pf_prison_account_tx` (
      `id` BIGINT NOT NULL AUTO_INCREMENT,
      `citizenid` VARCHAR(64) NOT NULL,
      `kind` VARCHAR(16) NOT NULL,
      `amount` INT NOT NULL,
      `ledger_key` VARCHAR(128) NULL,
      `ledger_state` VARCHAR(16) NULL,
      `ref` VARCHAR(64) NULL,
      `at` BIGINT NOT NULL,
      PRIMARY KEY (`id`),
      UNIQUE KEY `uq_pat_key` (`ledger_key`),
      KEY `idx_pat_cid` (`citizenid`, `at`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]],
    [[CREATE TABLE IF NOT EXISTS `pf_prison_work_log` (
      `id` BIGINT NOT NULL AUTO_INCREMENT,
      `citizenid` VARCHAR(64) NOT NULL,
      `order_id` INT NOT NULL,
      `job` VARCHAR(16) NOT NULL,
      `ticket` INT NOT NULL,
      `output` LONGTEXT NULL,
      `credit_seconds` INT NOT NULL DEFAULT 0,
      `wage` INT NOT NULL DEFAULT 0,
      `at` BIGINT NOT NULL,
      PRIMARY KEY (`id`),
      UNIQUE KEY `uq_pwl_ticket` (`order_id`, `ticket`),
      KEY `idx_pwl_cid` (`citizenid`, `at`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]],
}

Schema.V4 = {
    [[CREATE TABLE IF NOT EXISTS `pf_prison_searches` (
      `id` INT NOT NULL AUTO_INCREMENT,
      `facility` VARCHAR(32) NOT NULL,
      `kind` VARCHAR(8) NOT NULL,
      `target` VARCHAR(64) NOT NULL,
      `by_cid` VARCHAR(64) NOT NULL,
      `found` LONGTEXT NULL,
      `evidence_ids` VARCHAR(255) NULL,
      `at` BIGINT NOT NULL,
      PRIMARY KEY (`id`),
      KEY `idx_ps_target` (`target`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]],
    [[CREATE TABLE IF NOT EXISTS `pf_prison_escapes` (
      `id` INT NOT NULL AUTO_INCREMENT,
      `citizenid` VARCHAR(64) NOT NULL,
      `order_id` INT NOT NULL,
      `method` VARCHAR(16) NOT NULL,
      `gate` VARCHAR(8) NULL,
      `warrant_id` VARCHAR(32) NULL,
      `escaped_at` BIGINT NOT NULL,
      `recaptured_at` BIGINT NULL,
      PRIMARY KEY (`id`),
      KEY `idx_pesc_cid` (`citizenid`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]],
}

Schema.Migrations = {
    { version = 1, name = 'prison inmates and events', up = Schema.V1 },
    { version = 2, name = 'prison facility', up = Schema.V2 },
    { version = 3, name = 'prison economy', up = Schema.V3 },
    { version = 4, name = 'prison security', up = Schema.V4 },
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
