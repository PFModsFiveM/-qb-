-- The one migration list of pfm-policejob (key = resource name, as server/fines.lua used before).
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
