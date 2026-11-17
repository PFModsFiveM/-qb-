-- The one migration list of pfm-policejob (key = resource name, as server/fines.lua used before):
-- v1 fines, v2 evidence core (batch 15), v3 traffic, impound, telemetry and lab (batch 18).
-- The migration runner refuses two concurrent runs of one key, so every module waits for
-- PFPoliceSchema.WaitReady() instead of running migrations itself. v1 moved here unchanged from
-- server/fines.lua (same version, name and SQL), so an installed server does not apply it again.

PFPoliceSchema = PFPoliceSchema or {}
local S = PFPoliceSchema

S.state = S.state or 'idle' -- idle | running | ready | failed

S.Migrations = {
    {
        version = 1,
        name = 'police fine records',
        up = {
            [[CREATE TABLE IF NOT EXISTS `pfm_police_fines` (
                `id` INT UNSIGNED NOT NULL AUTO_INCREMENT,
                `citizenid` VARCHAR(50) NOT NULL,
                `society` VARCHAR(50) NOT NULL,
                `amount` INT UNSIGNED NOT NULL,
                `officer_citizenid` VARCHAR(50) NULL,
                `officer_name` VARCHAR(100) NULL,
                `reason` VARCHAR(128) NOT NULL DEFAULT 'Police fine',
                `state` VARCHAR(16) NOT NULL DEFAULT 'charging',
                `attempt` INT UNSIGNED NOT NULL DEFAULT 1,
                `checks` INT UNSIGNED NOT NULL DEFAULT 0,
                `paid_from` VARCHAR(8) NULL,
                `invoice_id` INT NULL,
                `last_error` VARCHAR(64) NULL,
                `next_at` INT UNSIGNED NOT NULL DEFAULT 0,
                `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
                `updated_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
                PRIMARY KEY (`id`),
                KEY `idx_due` (`state`, `next_at`),
                KEY `idx_citizen` (`citizenid`)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]],
        },
    },
    {
        version = 2,
        name = 'evidence core',
        up = {
            [[CREATE TABLE IF NOT EXISTS `pf_evidence_items` (
                `id` INT NOT NULL AUTO_INCREMENT,
                `tag` VARCHAR(20) NOT NULL,
                `kind` VARCHAR(16) NOT NULL,
                `label` VARCHAR(64) NOT NULL,
                `attrs` LONGTEXT NULL,
                `state` VARCHAR(16) NOT NULL,
                `sealed` TINYINT(1) NOT NULL DEFAULT 1,
                `quality` TINYINT NOT NULL DEFAULT 100,
                `integrity` TINYINT NOT NULL DEFAULT 100,
                `flags` VARCHAR(64) NULL,
                `holder_kind` VARCHAR(12) NULL,
                `holder_ref` VARCHAR(64) NULL,
                `scene_coords` VARCHAR(64) NULL, `scene_label` VARCHAR(96) NULL, `scene_id` VARCHAR(32) NULL,
                `collected_by` VARCHAR(64) NULL, `collected_at` BIGINT NOT NULL, `method` VARCHAR(16) NULL,
                `case_refs` LONGTEXT NULL,
                `origin_type` VARCHAR(16) NULL, `origin_id` VARCHAR(64) NULL,
                `idem_key` VARCHAR(128) NULL,
                PRIMARY KEY (`id`), UNIQUE KEY `uq_ev_tag` (`tag`), UNIQUE KEY `uq_ev_key` (`idem_key`),
                KEY `idx_ev_state` (`state`), KEY `idx_ev_holder` (`holder_kind`, `holder_ref`)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]],
            [[CREATE TABLE IF NOT EXISTS `pf_evidence_custody` (
                `id` BIGINT NOT NULL AUTO_INCREMENT, `evidence_id` INT NOT NULL,
                `event` VARCHAR(20) NOT NULL,
                `from_ref` VARCHAR(64) NULL, `to_ref` VARCHAR(64) NULL,
                `actor_cid` VARCHAR(64) NULL, `actor_src` INT NULL, `actor_job` VARCHAR(32) NULL,
                `pos` VARCHAR(64) NULL, `note` VARCHAR(255) NULL, `at` BIGINT NOT NULL,
                PRIMARY KEY (`id`), KEY `idx_evc_ev` (`evidence_id`, `at`)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]],
            [[CREATE TABLE IF NOT EXISTS `pf_evidence_scene_drops` (
                `id` BIGINT NOT NULL AUTO_INCREMENT, `kind` VARCHAR(12) NOT NULL,
                `x` DECIMAL(9,2) NOT NULL, `y` DECIMAL(9,2) NOT NULL, `z` DECIMAL(9,2) NOT NULL, `cell` VARCHAR(16) NOT NULL,
                `attrs` LONGTEXT NULL,
                `source_cid` VARCHAR(64) NULL,
                `state` VARCHAR(14) NOT NULL DEFAULT 'present',
                `created_at` BIGINT NOT NULL, `decay_at` BIGINT NOT NULL, `collected_evidence_id` INT NULL,
                PRIMARY KEY (`id`), KEY `idx_drop_cell` (`cell`, `state`), KEY `idx_drop_decay` (`state`, `decay_at`),
                KEY `idx_drop_src` (`source_cid`)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]],
            [[CREATE TABLE IF NOT EXISTS `pf_evidence_lockers` (
                `id` INT NOT NULL AUTO_INCREMENT, `station` VARCHAR(32) NOT NULL, `label` VARCHAR(64) NOT NULL,
                `stash_id` VARCHAR(64) NOT NULL, `case_ref` VARCHAR(64) NULL, `created_at` BIGINT NOT NULL,
                PRIMARY KEY (`id`), UNIQUE KEY `uq_locker_stash` (`stash_id`)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]],
        },
    },
    -- Batch 18 (schema owner 18B): traffic and impound (18B), telemetry (18C), lab (18D). DDL as in
    -- PF_DATABASE_MIGRATIONS.md section 5, plus pf_police_citations (18B: one row per citation uid,
    -- so a citation pf-justice could not take yet is retried with the same key) and three lookup
    -- indexes on pf_police_impounds.
    {
        version = 3,
        name = 'traffic, impound, telemetry, lab',
        up = {
            [[CREATE TABLE IF NOT EXISTS `pf_police_alpr_reads` (
                `id` BIGINT NOT NULL AUTO_INCREMENT, `plate` VARCHAR(16) NOT NULL, `reader` VARCHAR(32) NOT NULL,
                `x` DECIMAL(9,2) NOT NULL, `y` DECIMAL(9,2) NOT NULL, `speed_kmh` SMALLINT NULL, `hit` VARCHAR(32) NULL, `at` BIGINT NOT NULL,
                PRIMARY KEY (`id`), KEY `idx_alpr_plate` (`plate`, `at`), KEY `idx_alpr_at` (`at`)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]],
            [[CREATE TABLE IF NOT EXISTS `pf_police_speed_events` (
                `id` BIGINT NOT NULL AUTO_INCREMENT, `plate` VARCHAR(16) NOT NULL, `source` VARCHAR(16) NOT NULL,
                `officer_cid` VARCHAR(64) NULL, `speed_kmh` SMALLINT NOT NULL, `limit_kmh` SMALLINT NOT NULL,
                `x` DECIMAL(9,2) NOT NULL, `y` DECIMAL(9,2) NOT NULL, `citation_order_id` INT NULL, `at` BIGINT NOT NULL,
                PRIMARY KEY (`id`), KEY `idx_speed_plate` (`plate`, `at`)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]],
            [[CREATE TABLE IF NOT EXISTS `pf_police_breath_tests` (
                `id` BIGINT NOT NULL AUTO_INCREMENT, `citizenid` VARCHAR(64) NOT NULL, `officer_cid` VARCHAR(64) NOT NULL,
                `bac` DECIMAL(4,3) NOT NULL, `device` VARCHAR(16) NOT NULL, `at` BIGINT NOT NULL,
                PRIMARY KEY (`id`), KEY `idx_breath_cid` (`citizenid`, `at`)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]],
            [[CREATE TABLE IF NOT EXISTS `pf_police_impounds` (
                `id` INT NOT NULL AUTO_INCREMENT, `plate` VARCHAR(16) NOT NULL, `owner_cid` VARCHAR(64) NULL,
                `kind` VARCHAR(8) NOT NULL,
                `reason` VARCHAR(255) NOT NULL, `officer_cid` VARCHAR(64) NOT NULL, `lot` VARCHAR(32) NULL,
                `fee` INT NOT NULL DEFAULT 0, `hold_until` BIGINT NULL, `case_ref` VARCHAR(64) NULL, `tow_request_id` INT NULL,
                `state` VARCHAR(12) NOT NULL,
                `released_by` VARCHAR(64) NULL, `created_at` BIGINT NOT NULL, `released_at` BIGINT NULL,
                PRIMARY KEY (`id`), KEY `idx_imp_plate` (`plate`, `state`), KEY `idx_imp_tow` (`tow_request_id`),
                KEY `idx_imp_owner` (`owner_cid`), KEY `idx_imp_state` (`state`)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]],
            [[CREATE TABLE IF NOT EXISTS `pf_police_traffic_incidents` (
                `id` INT NOT NULL AUTO_INCREMENT, `kind` VARCHAR(16) NOT NULL,
                `x` DECIMAL(9,2) NOT NULL, `y` DECIMAL(9,2) NOT NULL, `plates` LONGTEXT NULL, `people` LONGTEXT NULL,
                `officer_cid` VARCHAR(64) NOT NULL, `summary` VARCHAR(500) NULL, `mdt_incident_id` VARCHAR(32) NULL, `at` BIGINT NOT NULL,
                PRIMARY KEY (`id`), KEY `idx_ti_at` (`at`)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]],
            [[CREATE TABLE IF NOT EXISTS `pf_police_citations` (
                `id` INT NOT NULL AUTO_INCREMENT, `uid` VARCHAR(32) NOT NULL, `citizenid` VARCHAR(64) NOT NULL,
                `officer_cid` VARCHAR(64) NULL, `code` VARCHAR(24) NOT NULL, `violation` VARCHAR(48) NOT NULL,
                `amount` INT NOT NULL, `plate` VARCHAR(16) NULL, `speed_event_id` BIGINT NULL,
                `speed_kmh` SMALLINT NULL, `limit_kmh` SMALLINT NULL, `x` DECIMAL(9,2) NULL, `y` DECIMAL(9,2) NULL,
                `state` VARCHAR(12) NOT NULL,
                `order_id` INT NULL, `citation_id` INT NULL, `error` VARCHAR(32) NULL,
                `attempts` INT NOT NULL DEFAULT 0, `next_at` BIGINT NOT NULL DEFAULT 0,
                `created_at` BIGINT NOT NULL, `updated_at` BIGINT NOT NULL,
                PRIMARY KEY (`id`), UNIQUE KEY `uq_pcit_uid` (`uid`), UNIQUE KEY `uq_pcit_speed` (`speed_event_id`),
                KEY `idx_pcit_cid` (`citizenid`), KEY `idx_pcit_due` (`state`, `next_at`)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]],
            [[CREATE TABLE IF NOT EXISTS `pf_police_telemetry` (
                `id` BIGINT NOT NULL AUTO_INCREMENT, `citizenid` VARCHAR(64) NOT NULL, `device` VARCHAR(8) NOT NULL,
                `kind` VARCHAR(16) NOT NULL,
                `x` DECIMAL(9,2) NULL, `y` DECIMAL(9,2) NULL, `z` DECIMAL(9,2) NULL, `data` VARCHAR(500) NULL,
                `client_reported` TINYINT(1) NOT NULL DEFAULT 0, `at` BIGINT NOT NULL,
                PRIMARY KEY (`id`), KEY `idx_tel_cid` (`citizenid`, `at`), KEY `idx_tel_at` (`at`)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]],
            [[CREATE TABLE IF NOT EXISTS `pf_police_telemetry_holds` (
                `id` INT NOT NULL AUTO_INCREMENT, `citizenid` VARCHAR(64) NOT NULL, `from_at` BIGINT NOT NULL, `to_at` BIGINT NOT NULL,
                `case_ref` VARCHAR(64) NOT NULL, `at` BIGINT NOT NULL, PRIMARY KEY (`id`), KEY `idx_hold_cid` (`citizenid`)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]],
            [[CREATE TABLE IF NOT EXISTS `pf_evidence_reference_samples` (
                `id` INT NOT NULL AUTO_INCREMENT, `citizenid` VARCHAR(64) NOT NULL, `kind` VARCHAR(8) NOT NULL,
                `sample_ref` VARCHAR(64) NOT NULL, `source_type` VARCHAR(12) NOT NULL, `source_id` VARCHAR(64) NOT NULL, `at` BIGINT NOT NULL,
                PRIMARY KEY (`id`), UNIQUE KEY `uq_ref_sample` (`kind`, `sample_ref`), KEY `idx_ref_cid` (`citizenid`)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]],
            [[CREATE TABLE IF NOT EXISTS `pf_evidence_test_fires` (
                `id` INT NOT NULL AUTO_INCREMENT, `weapon_serial` VARCHAR(32) NOT NULL, `weapon_hash` BIGINT NOT NULL,
                `evidence_id` INT NULL, `by_cid` VARCHAR(64) NOT NULL, `at` BIGINT NOT NULL,
                PRIMARY KEY (`id`), UNIQUE KEY `uq_tf_serial` (`weapon_serial`)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]],
            [[CREATE TABLE IF NOT EXISTS `pf_evidence_lab_jobs` (
                `id` INT NOT NULL AUTO_INCREMENT, `evidence_id` INT NOT NULL, `test` VARCHAR(12) NOT NULL,
                `state` VARCHAR(12) NOT NULL,
                `requested_by` VARCHAR(64) NOT NULL, `tech_cid` VARCHAR(64) NULL, `result` LONGTEXT NULL,
                `requested_at` BIGINT NOT NULL, `ready_at` BIGINT NOT NULL, `released_at` BIGINT NULL, `idem_key` VARCHAR(128) NULL,
                PRIMARY KEY (`id`), UNIQUE KEY `uq_lab_key` (`idem_key`), KEY `idx_lab_state` (`state`, `ready_at`), KEY `idx_lab_ev` (`evidence_id`)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]],
        },
    },
}

function S.Ready() return S.state == 'ready' end

--- Applies the pending versions once. A second caller while it runs waits for that run (at most
--- ~60 s) instead of starting its own, which the runner would refuse.
function S.Run()
    if S.state == 'ready' then return true end
    if S.state == 'running' then return S.WaitReady(60000) end
    S.state = 'running'
    local ok, res, err = pcall(function() return exports['pfm-core']:RunMigrations(GetCurrentResourceName(), S.Migrations) end)
    if ok and res ~= false and res ~= nil then
        S.state = 'ready'
        return true
    end
    S.state = 'failed'
    print(('^1[pfm-policejob]^7 migrations failed: %s'):format(tostring(ok and (err or res) or res)))
    return false
end

--- True once the schema is applied; waits up to timeoutMs (default 5 minutes) while it runs.
function S.WaitReady(timeoutMs)
    local waited, limit = 0, tonumber(timeoutMs) or 300000
    while S.state == 'idle' or S.state == 'running' do
        if waited >= limit then return false end
        Wait(250)
        waited = waited + 250
    end
    return S.state == 'ready'
end

CreateThread(function()
    if S.state == 'idle' then S.Run() end
end)
