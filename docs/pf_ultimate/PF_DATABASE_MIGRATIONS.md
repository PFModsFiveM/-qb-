# PF Ultimate: database migrations

Every new table, grouped by owning resource, with its migration key and version. Read with
`PF_ARCHITECTURE.md` (owners) and `PF_ULTIMATE_SYSTEM_PLAN.md` (which unit writes which version).

## 1. Rules

- Tables are created only by `exports['pfm-core']:RunMigrations(key, list)` (or the included
  `@pfm-core/server/migrations.lua` global where a resource already uses it: pf-ambulancejob, pf-government).
  Applied versions are stored per **key** in `pf_schema_migrations (resource, version)`.
- **One schema file per resource owns its key.** The runner refuses a second concurrent run of the same key
  (`'migrations already running for <key>'`), so two files of one resource must never call it with the same key.
  Existing migration lists move into the new schema file **unchanged** (same version numbers and names), so an
  installed server does not re-apply them. Other modules of the resource wait for `<Schema>.Ready()` before
  querying.
- New versions continue the existing numbers (table in section 2). One version per batch per resource; the batch's
  schema owner (see the plan) writes it with all tables of that batch.
- Every step is rerun-safe: `CREATE TABLE IF NOT EXISTS`, `ALTER TABLE ... ADD COLUMN IF NOT EXISTS`,
  `CREATE INDEX IF NOT EXISTS` (MariaDB), `INSERT IGNORE` seeds; function steps check before they write. DDL
  auto-commits, so an interrupted version restarts from its first step.
- `ENGINE=InnoDB DEFAULT CHARSET=utf8mb4`. Logic clocks are `BIGINT` unix seconds (`*_at`); display times
  `TIMESTAMP DEFAULT CURRENT_TIMESTAMP`. JSON is `LONGTEXT` (validated in Lua; MariaDB JSON is an alias anyway).
- No foreign keys across resources (resources start and stop independently); references across resources are plain
  ids with an index. Inside one resource, foreign keys only where a delete must cascade.
- Every table with per-citizen rows has an index on `citizenid` and is handled in the resource's
  `pfm-core:server:characterDeleted` handler.
- Idempotency columns: `idem_key VARCHAR(128) NULL` with `UNIQUE KEY` (NULLs do not collide).
- Real-DB spec per version: fresh DB, DB with the previous versions applied, and a second run that applies nothing.

## 2. Version map

| Resource | Key | Existing versions (where today) | New versions |
|---|---|---|---|
| pf-ambulancejob | `pf-ambulancejob` | v1 `injury records, treatment log, health snapshots` (`server/injury_database.lua`) | v2 medical core, v3 medical events (15A); v4 legacy import (16B); v5 clinical + hospital core (17C); v6 custody care (19G); v7 hospital services, morgue, supplies (20A) |
| pf-emsmdt | `pf-emsmdt` (resource name) | v1 `roster reset backups` (`server/roster.lua`) | v2 tables created ad hoc today (15G); v3 PCR, handover, units (20D) |
| pfm-policejob | `pfm-policejob` (resource name) | v1 `/fine` records (`server/fines.lua`) | v2 evidence core (15D); v3 traffic, impound, telemetry, lab (18B) |
| pf-policemdt-DEV | `pf-policemdt-DEV` (resource name; `GetCurrentResourceName()`) | v1-v6 (`server/sentencing.lua`): active jails, sentences, licence actions, charge audit, roster backups, `released_why` | v7 SQL-file tables (15F); v8 cases, BOLOs, record audit, warrant columns (18E); v9 personnel, UoF, pursuits, IA (20F) |
| pf-justice | `pf-justice` | none (new resource) | v1 core (15B); v2 legacy import (15B step, 15C code); v3 courts, v4 supervision, v5 community service (19A) |
| pfm-prison | `pfm-prison` | none (metadata only today) | v1 inmates and events (16C); v2 facility, v3 economy, v4 security (19D) |
| pf-government | `pf-government` | v1-v4 (`server/schema.lua`): zones/requests/districts/notes, recurring bills, late fees, bill payment attempts | v5 work orders, v6 department core (15E); v7 department management (20E) |
| pf-jobgarages | `pf-jobgarages` | none (SQL file `sql/pf_jobgarages.sql`) | v1 tables from the SQL file + fleet service columns (15H) |
| pfm-phone | (no key) | column checks in `EnsureInvoiceColumns` (`server/main.lua`) | `ref` column + unique index through the same check (15H) |

Note on pf-policemdt-DEV: its key is the folder name. If an operator renames the folder (e.g. to `pf-policemdt`),
every version re-applies; all steps are rerun-safe, so this is harmless but noisy. Do not change the key.

---------------------------------------------------------------------------------------------------------------------

## 3. pf-ambulancejob (key `pf-ambulancejob`)

### v1 (existing, moved unchanged to `server/medical/schema.lua`)
`player_injuries`, `player_treatment_log`, `player_health_snapshot` (table names come from `Config.Database`).

### v2 medical core (15A)
```sql
CREATE TABLE IF NOT EXISTS `pf_med_patients` (
  `citizenid` VARCHAR(64) NOT NULL,
  `consciousness` VARCHAR(16) NOT NULL DEFAULT 'alert',   -- alert|altered|unconscious|arrest|dead
  `stage` VARCHAR(16) NOT NULL DEFAULT 'healthy',          -- worst open injury stage
  `blood_ml` INT NOT NULL DEFAULT 5000,
  `hgb_factor` DECIMAL(4,3) NOT NULL DEFAULT 1.000,
  `airway` VARCHAR(16) NOT NULL DEFAULT 'clear',
  `breathing` DECIMAL(4,3) NOT NULL DEFAULT 1.000,
  `pain` DECIMAL(4,2) NOT NULL DEFAULT 0,
  `temp_c` DECIMAL(4,1) NOT NULL DEFAULT 37.0,
  `toxins` LONGTEXT NULL,                                  -- { name = level }
  `drugs` LONGTEXT NULL,                                   -- { name = { mg, at } }
  `arrest_since` BIGINT NULL,
  `down_since` BIGINT NULL,
  `dead_at` BIGINT NULL,
  `can_respawn_at` BIGINT NULL,
  `last_tick_at` BIGINT NULL,
  `updated_at` BIGINT NOT NULL,
  PRIMARY KEY (`citizenid`),
  KEY `idx_med_pat_cons` (`consciousness`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `pf_med_injuries` (
  `id` INT NOT NULL AUTO_INCREMENT,
  `citizenid` VARCHAR(64) NOT NULL,
  `type` VARCHAR(32) NOT NULL,
  `subtype` VARCHAR(32) NULL,
  `region` VARCHAR(32) NULL,
  `structure` VARCHAR(32) NULL,
  `severity` TINYINT NOT NULL,                             -- 1..5
  `stage` VARCHAR(16) NOT NULL DEFAULT 'injured',          -- injured|stabilized|treated|recovering|recovered|complicated
  `bleed_ml_min` DECIMAL(7,2) NOT NULL DEFAULT 0,
  `pain` DECIMAL(4,2) NOT NULL DEFAULT 0,
  `mechanism` VARCHAR(32) NOT NULL,                        -- firearm|edged|blunt|fall|vehicle|burn|electrical|...
  `attrs` LONGTEXT NULL,                                   -- weapon hash, caliber, retained projectile, tbsa, ...
  `treatments` LONGTEXT NULL,                              -- active modifiers: tourniquet_at, splinted, ...
  `source_attacker_cid` VARCHAR(64) NULL,
  `idem_key` VARCHAR(128) NULL,
  `legacy_id` INT NULL,                                    -- player_injuries.id (16B import)
  `created_at` BIGINT NOT NULL,
  `stabilized_at` BIGINT NULL,
  `treated_at` BIGINT NULL,
  `recover_at` BIGINT NULL,
  `recovered_at` BIGINT NULL,
  PRIMARY KEY (`id`),
  UNIQUE KEY `uq_med_inj_key` (`idem_key`),
  UNIQUE KEY `uq_med_inj_legacy` (`legacy_id`),
  KEY `idx_med_inj_open` (`citizenid`, `stage`),
  KEY `idx_med_inj_recover` (`stage`, `recover_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
```
Bound: at most `Config.Medical.MaxOpenInjuries` (default 40) open rows per citizen; recovered rows older than
`HistoryDays` (default 60) are swept.

### v3 medical events (15A)
```sql
CREATE TABLE IF NOT EXISTS `pf_med_events` (
  `id` BIGINT NOT NULL AUTO_INCREMENT,
  `citizenid` VARCHAR(64) NOT NULL,
  `action` VARCHAR(32) NOT NULL,       -- injury|state|treatment|exam|record_read|anomaly|revive|respawn|admin
  `actor_cid` VARCHAR(64) NULL,
  `actor_src` INT NULL,
  `actor_job` VARCHAR(32) NULL,
  `detail` LONGTEXT NULL,              -- <= 4 KB
  `at` BIGINT NOT NULL,
  PRIMARY KEY (`id`),
  KEY `idx_med_ev_cid` (`citizenid`, `at`),
  KEY `idx_med_ev_action` (`action`, `at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
```

### v4 legacy import (16B): function step
Copies `player_injuries` rows with `deleted_at IS NULL` into `pf_med_injuries` (`legacy_id` = old id; zone ->
region: head->head, torso->chest_l, left_arm->upper_arm_l, ...; type map: gunshot_wound->gunshot, laceration->laceration,
blunt_trauma->bruising, burn->burn, fracture->fracture/closed, respiratory->respiratory, electrical_burn->electrical,
blast_injury->burn + bruising; severity minor/moderate/severe/critical -> 1/2/4/5; stage `injured`;
`mechanism = 'legacy'`). `INSERT IGNORE` on `legacy_id` makes it run once.

### v5 clinical and hospital core (17C, tables of 17A/17B/17C/17E)
```sql
CREATE TABLE IF NOT EXISTS `pf_med_findings` (
  `id` BIGINT NOT NULL AUTO_INCREMENT, `citizenid` VARCHAR(64) NOT NULL, `injury_id` INT NULL,
  `modality` VARCHAR(24) NOT NULL, `region` VARCHAR(32) NULL, `structure` VARCHAR(32) NULL,
  `sign` VARCHAR(48) NOT NULL, `certainty` VARCHAR(12) NOT NULL,      -- observed|suspected|confirmed
  `value` VARCHAR(64) NULL, `by_cid` VARCHAR(64) NULL, `by_tier` TINYINT NULL, `at` BIGINT NOT NULL,
  PRIMARY KEY (`id`), KEY `idx_med_find_cid` (`citizenid`, `at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `pf_med_diagnoses` (
  `id` INT NOT NULL AUTO_INCREMENT, `citizenid` VARCHAR(64) NOT NULL, `injury_id` INT NULL,
  `structure` VARCHAR(32) NULL, `injury_type` VARCHAR(32) NOT NULL,
  `status` VARCHAR(12) NOT NULL,                                       -- suspected|confirmed|ruled_out
  `source` VARCHAR(16) NOT NULL,                                       -- provider|imaging|lab|surgery
  `by_cid` VARCHAR(64) NULL, `note` VARCHAR(255) NULL, `at` BIGINT NOT NULL,
  PRIMARY KEY (`id`), KEY `idx_med_dx_cid` (`citizenid`, `status`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `pf_med_treatments` (
  `id` BIGINT NOT NULL AUTO_INCREMENT, `citizenid` VARCHAR(64) NOT NULL, `injury_id` INT NULL,
  `action` VARCHAR(32) NOT NULL, `params` LONGTEXT NULL, `items` LONGTEXT NULL,
  `by_cid` VARCHAR(64) NULL, `by_job` VARCHAR(32) NULL, `location` VARCHAR(16) NOT NULL,   -- field|rig|hospital|or
  `admission_id` INT NULL, `call_ref` VARCHAR(64) NULL, `req` VARCHAR(64) NULL, `result` VARCHAR(16) NOT NULL,
  `at` BIGINT NOT NULL,
  PRIMARY KEY (`id`), KEY `idx_med_tx_cid` (`citizenid`, `at`), KEY `idx_med_tx_adm` (`admission_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `pf_med_restrictions` (
  `id` INT NOT NULL AUTO_INCREMENT, `citizenid` VARCHAR(64) NOT NULL, `kind` VARCHAR(32) NOT NULL,
  `reason` VARCHAR(128) NULL, `injury_id` INT NULL, `from_at` BIGINT NOT NULL, `until_at` BIGINT NULL,
  `ended_at` BIGINT NULL, `by_cid` VARCHAR(64) NULL,
  PRIMARY KEY (`id`), KEY `idx_med_rs_cid` (`citizenid`, `ended_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `pf_hosp_admissions` (
  `id` INT NOT NULL AUTO_INCREMENT, `citizenid` VARCHAR(64) NOT NULL, `hospital_id` VARCHAR(32) NOT NULL,
  `state` VARCHAR(16) NOT NULL,          -- arrived|checked_in|triaged|waiting|in_treatment|admitted|discharged|transferred|left_ama|deceased
  `mode` VARCHAR(8) NOT NULL DEFAULT 'staff',                         -- staff|ai
  `triage` VARCHAR(8) NULL, `dept` VARCHAR(16) NULL, `bed_id` VARCHAR(32) NULL,
  `reason` VARCHAR(255) NULL, `arrived_at` BIGINT NOT NULL, `triaged_at` BIGINT NULL, `admitted_at` BIGINT NULL,
  `discharged_at` BIGINT NULL, `discharge_orders` LONGTEXT NULL, `idem_key` VARCHAR(128) NULL,
  PRIMARY KEY (`id`), UNIQUE KEY `uq_hosp_adm_key` (`idem_key`),
  KEY `idx_hosp_adm_cid` (`citizenid`, `state`), KEY `idx_hosp_adm_hosp` (`hospital_id`, `state`),
  KEY `idx_hosp_adm_bed` (`hospital_id`, `bed_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
```
Bed occupancy is decided in memory under a per-bed lock and rebuilt at start from admissions whose state holds a bed
(a unique key cannot express "one open row per bed" because NULLs never collide).
```sql
CREATE TABLE IF NOT EXISTS `pf_hosp_bills` (
  `id` INT NOT NULL AUTO_INCREMENT, `citizenid` VARCHAR(64) NOT NULL, `admission_id` INT NULL,
  `hospital_id` VARCHAR(32) NOT NULL, `total` INT NOT NULL, `discount` INT NOT NULL DEFAULT 0,
  `state` VARCHAR(16) NOT NULL,          -- open|charging|payment_pending|paid|invoiced|waived
  `attempt` INT NOT NULL DEFAULT 0, `pay_key` VARCHAR(128) NULL, `invoice_id` INT NULL,
  `created_at` BIGINT NOT NULL, `settled_at` BIGINT NULL, `next_check_at` BIGINT NULL,
  PRIMARY KEY (`id`), KEY `idx_hosp_bill_cid` (`citizenid`), KEY `idx_hosp_bill_state` (`state`, `next_check_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `pf_hosp_bill_lines` (
  `id` BIGINT NOT NULL AUTO_INCREMENT, `bill_id` INT NOT NULL, `kind` VARCHAR(16) NOT NULL,  -- treatment|bed|procedure|drug|supply|ai_care
  `ref_id` BIGINT NULL, `label` VARCHAR(96) NOT NULL, `qty` INT NOT NULL DEFAULT 1, `unit_price` INT NOT NULL,
  PRIMARY KEY (`id`), KEY `idx_hosp_bl_bill` (`bill_id`),
  CONSTRAINT `fk_hosp_bl_bill` FOREIGN KEY (`bill_id`) REFERENCES `pf_hosp_bills` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
```

### v6 custody care (19G)
```sql
ALTER TABLE `pf_hosp_admissions` ADD COLUMN IF NOT EXISTS `custody_ref` VARCHAR(64) NULL;
ALTER TABLE `pf_hosp_admissions` ADD COLUMN IF NOT EXISTS `escort_cid` VARCHAR(64) NULL;
CREATE TABLE IF NOT EXISTS `pf_med_screenings` (
  `id` INT NOT NULL AUTO_INCREMENT, `citizenid` VARCHAR(64) NOT NULL, `context` VARCHAR(16) NOT NULL,  -- booking|prison_intake|infirmary
  `custody_ref` VARCHAR(64) NULL, `result` VARCHAR(16) NOT NULL,       -- fit|fit_restricted|hospital_required
  `restrictions` LONGTEXT NULL, `by_cid` VARCHAR(64) NULL, `at` BIGINT NOT NULL,
  PRIMARY KEY (`id`), KEY `idx_med_scr_cid` (`citizenid`, `at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
```

### v7 hospital services, morgue, supplies (20A, tables of 20A/20B/20C)
```sql
CREATE TABLE IF NOT EXISTS `pf_hosp_prescriptions` (
  `id` INT NOT NULL AUTO_INCREMENT, `citizenid` VARCHAR(64) NOT NULL, `drug` VARCHAR(32) NOT NULL,
  `dose` VARCHAR(32) NOT NULL, `qty` INT NOT NULL, `refills` INT NOT NULL DEFAULT 0, `controlled` TINYINT(1) NOT NULL DEFAULT 0,
  `prescriber_cid` VARCHAR(64) NOT NULL, `state` VARCHAR(12) NOT NULL,  -- active|filled|expired|cancelled
  `created_at` BIGINT NOT NULL, `expires_at` BIGINT NOT NULL,
  PRIMARY KEY (`id`), KEY `idx_rx_cid` (`citizenid`, `state`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
CREATE TABLE IF NOT EXISTS `pf_hosp_dispense_log` (
  `id` BIGINT NOT NULL AUTO_INCREMENT, `prescription_id` INT NULL, `citizenid` VARCHAR(64) NOT NULL,
  `drug` VARCHAR(32) NOT NULL, `qty` INT NOT NULL, `by_cid` VARCHAR(64) NOT NULL, `stash` VARCHAR(64) NOT NULL, `at` BIGINT NOT NULL,
  PRIMARY KEY (`id`), KEY `idx_disp_drug` (`drug`, `at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
CREATE TABLE IF NOT EXISTS `pf_hosp_orders` (                      -- lab + imaging + procedure orders
  `id` INT NOT NULL AUTO_INCREMENT, `citizenid` VARCHAR(64) NOT NULL, `admission_id` INT NULL,
  `kind` VARCHAR(12) NOT NULL,           -- lab|imaging|procedure
  `test` VARCHAR(24) NOT NULL,           -- blood_type|cbc|tox|bac|xray|ct|surgery_<x>|...
  `state` VARCHAR(12) NOT NULL,          -- ordered|in_progress|resulted|cancelled
  `ordered_by` VARCHAR(64) NOT NULL, `done_by` VARCHAR(64) NULL, `result` LONGTEXT NULL,
  `ordered_at` BIGINT NOT NULL, `ready_at` BIGINT NULL, `resulted_at` BIGINT NULL,
  PRIMARY KEY (`id`), KEY `idx_hord_cid` (`citizenid`), KEY `idx_hord_state` (`state`, `ready_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
CREATE TABLE IF NOT EXISTS `pf_med_death_records` (
  `id` INT NOT NULL AUTO_INCREMENT, `citizenid` VARCHAR(64) NOT NULL, `cause` VARCHAR(128) NOT NULL,
  `manner` VARCHAR(16) NOT NULL,         -- natural|accident|homicide|suicide|undetermined|pending
  `tod_from` BIGINT NULL, `tod_to` BIGINT NULL, `examiner_cid` VARCHAR(64) NULL, `findings` LONGTEXT NULL,
  `case_ref` VARCHAR(64) NULL, `state` VARCHAR(12) NOT NULL,            -- intake|examined|released
  `created_at` BIGINT NOT NULL, `released_at` BIGINT NULL,
  PRIMARY KEY (`id`), KEY `idx_death_cid` (`citizenid`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
CREATE TABLE IF NOT EXISTS `pf_hosp_supply_usage` (
  `id` BIGINT NOT NULL AUTO_INCREMENT, `facility` VARCHAR(48) NOT NULL, `item` VARCHAR(48) NOT NULL,
  `qty` INT NOT NULL, `reason` VARCHAR(32) NOT NULL, `ref_id` BIGINT NULL, `at` BIGINT NOT NULL,
  PRIMARY KEY (`id`), KEY `idx_supply_fac` (`facility`, `at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
```

---------------------------------------------------------------------------------------------------------------------

## 4. pf-emsmdt (key `pf-emsmdt`)

- v1 (existing, moved from `server/roster.lua`): `pf_emsmdt_roster_backup`.
- v2 (15G): the tables created ad hoc today, with their current columns (copy each `CREATE TABLE IF NOT EXISTS`
  verbatim from the file and line): `pf_emsmdt_patient_notes` (`server/main.lua` ~109), `pf_emsmdt_user_profiles`
  (~845), `pf_emsmdt_bulletins` (~986), the roster table named by config (`server/roster.lua` ~139, a function step
  reading `Config`), `pf_emsmdt_sops` (`server/sop.lua` ~68), `pf_emsmdt_staff_mgmt_profiles`,
  `pf_emsmdt_staff_discipline`, `pf_emsmdt_staff_audit` (`server/officers.lua` ~185-229), plus every
  `ALTER TABLE ... ADD COLUMN` those files run today, as `ADD COLUMN IF NOT EXISTS`.
- v3 (20D):
```sql
CREATE TABLE IF NOT EXISTS `pf_emsmdt_pcr` (
  `id` INT NOT NULL AUTO_INCREMENT, `citizenid` VARCHAR(64) NOT NULL, `call_ref` VARCHAR(64) NULL,
  `unit` VARCHAR(16) NULL, `lead_cid` VARCHAR(64) NOT NULL, `state` VARCHAR(12) NOT NULL,   -- open|handed_over|closed
  `narrative` LONGTEXT NULL, `dispatch_at` BIGINT NULL, `arrive_at` BIGINT NULL, `depart_at` BIGINT NULL,
  `handover_at` BIGINT NULL, `hospital_id` VARCHAR(32) NULL, `admission_id` INT NULL,
  `created_at` BIGINT NOT NULL, `updated_at` BIGINT NOT NULL,
  PRIMARY KEY (`id`), KEY `idx_pcr_cid` (`citizenid`), KEY `idx_pcr_call` (`call_ref`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
CREATE TABLE IF NOT EXISTS `pf_emsmdt_pcr_entries` (     -- auto-charted lines (AJ treatment/vitals ids)
  `id` BIGINT NOT NULL AUTO_INCREMENT, `pcr_id` INT NOT NULL, `kind` VARCHAR(12) NOT NULL,  -- treatment|vitals|note|exam
  `ref_id` BIGINT NULL, `summary` VARCHAR(255) NOT NULL, `at` BIGINT NOT NULL,
  PRIMARY KEY (`id`), KEY `idx_pcre_pcr` (`pcr_id`, `at`),
  CONSTRAINT `fk_pcre_pcr` FOREIGN KEY (`pcr_id`) REFERENCES `pf_emsmdt_pcr` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
CREATE TABLE IF NOT EXISTS `pf_emsmdt_units` (
  `unit` VARCHAR(16) NOT NULL, `status` VARCHAR(16) NOT NULL, `crew` LONGTEXT NULL, `rig_plate` VARCHAR(16) NULL,
  `call_ref` VARCHAR(64) NULL, `updated_at` BIGINT NOT NULL, PRIMARY KEY (`unit`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
```

---------------------------------------------------------------------------------------------------------------------

## 5. pfm-policejob (key `pfm-policejob`)

- v1 (existing, moved unchanged from `server/fines.lua` to `server/schema.lua`): `pfm_police_fines`.
- v2 evidence core (15D):
```sql
CREATE TABLE IF NOT EXISTS `pf_evidence_items` (
  `id` INT NOT NULL AUTO_INCREMENT,
  `tag` VARCHAR(20) NOT NULL,                     -- EV-<year>-<seq>
  `kind` VARCHAR(16) NOT NULL,
  `label` VARCHAR(64) NOT NULL,
  `attrs` LONGTEXT NULL,
  `state` VARCHAR(16) NOT NULL,                   -- collected|sealed|in_transit|stored|at_lab|analysed|in_court|released|destroyed
  `sealed` TINYINT(1) NOT NULL DEFAULT 1,
  `quality` TINYINT NOT NULL DEFAULT 100,
  `integrity` TINYINT NOT NULL DEFAULT 100,
  `flags` VARCHAR(64) NULL,                       -- seal_broken,gap,contaminated,missing
  `holder_kind` VARCHAR(12) NULL,                 -- officer|inventory|locker|lab|court|released
  `holder_ref` VARCHAR(64) NULL,
  `scene_coords` VARCHAR(64) NULL, `scene_label` VARCHAR(96) NULL, `scene_id` VARCHAR(32) NULL,
  `collected_by` VARCHAR(64) NULL, `collected_at` BIGINT NOT NULL, `method` VARCHAR(16) NULL,
  `case_refs` LONGTEXT NULL,                      -- [{type,id}]
  `origin_type` VARCHAR(16) NULL, `origin_id` VARCHAR(64) NULL,
  `idem_key` VARCHAR(128) NULL,
  PRIMARY KEY (`id`), UNIQUE KEY `uq_ev_tag` (`tag`), UNIQUE KEY `uq_ev_key` (`idem_key`),
  KEY `idx_ev_state` (`state`), KEY `idx_ev_holder` (`holder_kind`, `holder_ref`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
CREATE TABLE IF NOT EXISTS `pf_evidence_custody` (
  `id` BIGINT NOT NULL AUTO_INCREMENT, `evidence_id` INT NOT NULL,
  `event` VARCHAR(20) NOT NULL,                   -- collected|sealed|moved|handed_over|stored|checked_out|checked_in|submitted_lab|analysed|seal_broken|presented_court|released|destroyed|flagged_missing
  `from_ref` VARCHAR(64) NULL, `to_ref` VARCHAR(64) NULL,
  `actor_cid` VARCHAR(64) NULL, `actor_src` INT NULL, `actor_job` VARCHAR(32) NULL,
  `pos` VARCHAR(64) NULL, `note` VARCHAR(255) NULL, `at` BIGINT NOT NULL,
  PRIMARY KEY (`id`), KEY `idx_evc_ev` (`evidence_id`, `at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
CREATE TABLE IF NOT EXISTS `pf_evidence_scene_drops` (
  `id` BIGINT NOT NULL AUTO_INCREMENT, `kind` VARCHAR(12) NOT NULL,   -- blood|casing|fingerprint
  `x` DECIMAL(9,2) NOT NULL, `y` DECIMAL(9,2) NOT NULL, `z` DECIMAL(9,2) NOT NULL, `cell` VARCHAR(16) NOT NULL,
  `attrs` LONGTEXT NULL,                          -- sample id, bloodtype, caliber, weapon hash, serial, print id
  `source_cid` VARCHAR(64) NULL,                  -- who left it (server-known); never sent to clients
  `state` VARCHAR(14) NOT NULL DEFAULT 'present', -- present|collected|unrecoverable|cleared
  `created_at` BIGINT NOT NULL, `decay_at` BIGINT NOT NULL, `collected_evidence_id` INT NULL,
  PRIMARY KEY (`id`), KEY `idx_drop_cell` (`cell`, `state`), KEY `idx_drop_decay` (`state`, `decay_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
CREATE TABLE IF NOT EXISTS `pf_evidence_lockers` (
  `id` INT NOT NULL AUTO_INCREMENT, `station` VARCHAR(32) NOT NULL, `label` VARCHAR(64) NOT NULL,
  `stash_id` VARCHAR(64) NOT NULL, `case_ref` VARCHAR(64) NULL, `created_at` BIGINT NOT NULL,
  PRIMARY KEY (`id`), UNIQUE KEY `uq_locker_stash` (`stash_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
```
- v3 traffic, impound, telemetry, lab (18B, tables of 18B/18C/18D):
```sql
CREATE TABLE IF NOT EXISTS `pf_police_alpr_reads` (
  `id` BIGINT NOT NULL AUTO_INCREMENT, `plate` VARCHAR(16) NOT NULL, `reader` VARCHAR(32) NOT NULL,  -- unit plate or camera id
  `x` DECIMAL(9,2) NOT NULL, `y` DECIMAL(9,2) NOT NULL, `speed_kmh` SMALLINT NULL, `hit` VARCHAR(32) NULL, `at` BIGINT NOT NULL,
  PRIMARY KEY (`id`), KEY `idx_alpr_plate` (`plate`, `at`), KEY `idx_alpr_at` (`at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
CREATE TABLE IF NOT EXISTS `pf_police_speed_events` (
  `id` BIGINT NOT NULL AUTO_INCREMENT, `plate` VARCHAR(16) NOT NULL, `source` VARCHAR(16) NOT NULL,  -- radar|camera
  `officer_cid` VARCHAR(64) NULL, `speed_kmh` SMALLINT NOT NULL, `limit_kmh` SMALLINT NOT NULL,
  `x` DECIMAL(9,2) NOT NULL, `y` DECIMAL(9,2) NOT NULL, `citation_order_id` INT NULL, `at` BIGINT NOT NULL,
  PRIMARY KEY (`id`), KEY `idx_speed_plate` (`plate`, `at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
CREATE TABLE IF NOT EXISTS `pf_police_breath_tests` (
  `id` BIGINT NOT NULL AUTO_INCREMENT, `citizenid` VARCHAR(64) NOT NULL, `officer_cid` VARCHAR(64) NOT NULL,
  `bac` DECIMAL(4,3) NOT NULL, `device` VARCHAR(16) NOT NULL, `at` BIGINT NOT NULL,
  PRIMARY KEY (`id`), KEY `idx_breath_cid` (`citizenid`, `at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
CREATE TABLE IF NOT EXISTS `pf_police_impounds` (
  `id` INT NOT NULL AUTO_INCREMENT, `plate` VARCHAR(16) NOT NULL, `owner_cid` VARCHAR(64) NULL,
  `kind` VARCHAR(8) NOT NULL,                     -- depot|seizure
  `reason` VARCHAR(255) NOT NULL, `officer_cid` VARCHAR(64) NOT NULL, `lot` VARCHAR(32) NULL,
  `fee` INT NOT NULL DEFAULT 0, `hold_until` BIGINT NULL, `case_ref` VARCHAR(64) NULL, `tow_request_id` INT NULL,
  `state` VARCHAR(12) NOT NULL,                   -- ordered|impounded|released
  `released_by` VARCHAR(64) NULL, `created_at` BIGINT NOT NULL, `released_at` BIGINT NULL,
  PRIMARY KEY (`id`), KEY `idx_imp_plate` (`plate`, `state`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
CREATE TABLE IF NOT EXISTS `pf_police_traffic_incidents` (
  `id` INT NOT NULL AUTO_INCREMENT, `kind` VARCHAR(16) NOT NULL,      -- collision|stop|pursuit_end|hazard
  `x` DECIMAL(9,2) NOT NULL, `y` DECIMAL(9,2) NOT NULL, `plates` LONGTEXT NULL, `people` LONGTEXT NULL,
  `officer_cid` VARCHAR(64) NOT NULL, `summary` VARCHAR(500) NULL, `mdt_incident_id` VARCHAR(32) NULL, `at` BIGINT NOT NULL,
  PRIMARY KEY (`id`), KEY `idx_ti_at` (`at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
CREATE TABLE IF NOT EXISTS `pf_police_telemetry` (
  `id` BIGINT NOT NULL AUTO_INCREMENT, `citizenid` VARCHAR(64) NOT NULL, `device` VARCHAR(8) NOT NULL,  -- body|dash
  `kind` VARCHAR(16) NOT NULL,          -- pos|weapon_out|weapon_in|shot_hit|shot_reported|cuff|search|frisk|taser|vehicle_in|vehicle_out|radio|note|anomaly
  `x` DECIMAL(9,2) NULL, `y` DECIMAL(9,2) NULL, `z` DECIMAL(9,2) NULL, `data` VARCHAR(500) NULL,
  `client_reported` TINYINT(1) NOT NULL DEFAULT 0, `at` BIGINT NOT NULL,
  PRIMARY KEY (`id`), KEY `idx_tel_cid` (`citizenid`, `at`), KEY `idx_tel_at` (`at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
CREATE TABLE IF NOT EXISTS `pf_evidence_reference_samples` (
  `id` INT NOT NULL AUTO_INCREMENT, `citizenid` VARCHAR(64) NOT NULL, `kind` VARCHAR(8) NOT NULL,   -- dna|prints
  `sample_ref` VARCHAR(64) NOT NULL, `source_type` VARCHAR(12) NOT NULL, `source_id` VARCHAR(64) NOT NULL, `at` BIGINT NOT NULL,
  PRIMARY KEY (`id`), UNIQUE KEY `uq_ref_sample` (`kind`, `sample_ref`), KEY `idx_ref_cid` (`citizenid`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
CREATE TABLE IF NOT EXISTS `pf_evidence_test_fires` (
  `id` INT NOT NULL AUTO_INCREMENT, `weapon_serial` VARCHAR(32) NOT NULL, `weapon_hash` BIGINT NOT NULL,
  `evidence_id` INT NULL, `by_cid` VARCHAR(64) NOT NULL, `at` BIGINT NOT NULL,
  PRIMARY KEY (`id`), UNIQUE KEY `uq_tf_serial` (`weapon_serial`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
CREATE TABLE IF NOT EXISTS `pf_evidence_lab_jobs` (
  `id` INT NOT NULL AUTO_INCREMENT, `evidence_id` INT NOT NULL, `test` VARCHAR(12) NOT NULL,
  `state` VARCHAR(12) NOT NULL,         -- queued|processing|ready|released|failed
  `requested_by` VARCHAR(64) NOT NULL, `tech_cid` VARCHAR(64) NULL, `result` LONGTEXT NULL,
  `requested_at` BIGINT NOT NULL, `ready_at` BIGINT NOT NULL, `released_at` BIGINT NULL, `idem_key` VARCHAR(128) NULL,
  PRIMARY KEY (`id`), UNIQUE KEY `uq_lab_key` (`idem_key`), KEY `idx_lab_state` (`state`, `ready_at`), KEY `idx_lab_ev` (`evidence_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
```
Retention: `pf_police_alpr_reads` 14 days, `pf_police_telemetry` 30 days (`Config.Telemetry.RetentionDays`). A
telemetry window attached to a case (through PMDT `AttachExternalRecord`) is kept by a hold row `(cid, from, to)`:
```sql
CREATE TABLE IF NOT EXISTS `pf_police_telemetry_holds` (
  `id` INT NOT NULL AUTO_INCREMENT, `citizenid` VARCHAR(64) NOT NULL, `from_at` BIGINT NOT NULL, `to_at` BIGINT NOT NULL,
  `case_ref` VARCHAR(64) NOT NULL, `at` BIGINT NOT NULL, PRIMARY KEY (`id`), KEY `idx_hold_cid` (`citizenid`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
```
The retention sweep skips rows covered by a hold.

---------------------------------------------------------------------------------------------------------------------

## 6. pf-policemdt-DEV (key = resource name)

- v1-v6 (existing, moved unchanged from `server/sentencing.lua` to `server/schema.lua`).
- v7 SQL-file tables (15F): port every `CREATE TABLE` of `sql/pf-policemdt-qb.sql` (and `sql/pf-policemdt-templates.sql`)
  as `CREATE TABLE IF NOT EXISTS`, skipping any `DROP TABLE`, with seeds as `INSERT IGNORE`: `pf_mdt_warrants`,
  `pf_mdt_incidents`, `pf_mdt_reports`, `pf_mdt_roster`, `pf_mdt_sops`, `pf_mdt_fto_reports`, `pf_mdt_fto_report_audit`,
  `pf_mdt_bulletins`, `pf_mdt_citizen_notes`, `pf_mdt_citizen_flags`, `pf_mdt_citizen_profiles`,
  `pf_mdt_officer_mgmt_profiles`, `pf_mdt_officer_discipline`, `pf_mdt_officer_audit`, `pf_mdt_officer_profiles`,
  `pf_mdt_weapons_registry`, `pf_mdt_vehicle_notes`, `pf_mdt_vehicle_flags`, `pf_mdt_vehicle_strikes`,
  `pf_mdt_vehicle_activity`, `pf_mdt_vehicle_profiles`, `pf_mdt_charges`, `pf_mdt_pending_sentences`,
  `pf_mdt_incident_evidence`, `pf_mdt_evidence`, `pf_mdt_manual_citizens`, `pf_mdt_manual_vehicles`,
  `pf_mdt_cctv_cameras` (+ seed rows), `pf_mdt_chat`, `pf_mdt_templates`; plus the ALTER loops in
  `server/officers.lua` and the `procedure -> procedure_text` rename in `server/sop.lua` as guarded steps
  (`MigrationColumnExists`). `pf_mdt_fto_reports_legacy` is not created; the code that reads it checks the table
  exists first (15F).
- v8 cases, BOLOs, record audit, warrant columns (18E, tables of 18E/18F):
```sql
CREATE TABLE IF NOT EXISTS `pf_mdt_cases` (
  `id` INT NOT NULL AUTO_INCREMENT, `case_no` VARCHAR(20) NOT NULL, `title` VARCHAR(128) NOT NULL,
  `status` VARCHAR(16) NOT NULL,        -- open|active|suspended|ready_for_court|submitted|closed
  `priority` TINYINT NOT NULL DEFAULT 2, `lead_cid` VARCHAR(64) NULL, `summary` LONGTEXT NULL,
  `court_case_id` INT NULL, `created_by` VARCHAR(64) NOT NULL, `created_at` BIGINT NOT NULL, `updated_at` BIGINT NOT NULL,
  PRIMARY KEY (`id`), UNIQUE KEY `uq_case_no` (`case_no`), KEY `idx_case_status` (`status`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
CREATE TABLE IF NOT EXISTS `pf_mdt_case_links` (
  `id` INT NOT NULL AUTO_INCREMENT, `case_id` INT NOT NULL, `ref_type` VARCHAR(16) NOT NULL,  -- incident|report|evidence|warrant|custody|order|death_record|citation|telemetry|bolo
  `ref_id` VARCHAR(64) NOT NULL, `note` VARCHAR(255) NULL, `by_cid` VARCHAR(64) NOT NULL, `at` BIGINT NOT NULL,
  PRIMARY KEY (`id`), UNIQUE KEY `uq_case_link` (`case_id`, `ref_type`, `ref_id`), KEY `idx_link_ref` (`ref_type`, `ref_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
CREATE TABLE IF NOT EXISTS `pf_mdt_case_people` (
  `id` INT NOT NULL AUTO_INCREMENT, `case_id` INT NOT NULL, `role` VARCHAR(12) NOT NULL,     -- suspect|witness|victim|person_of_interest
  `citizenid` VARCHAR(64) NULL, `manual_id` INT NULL, `name` VARCHAR(128) NOT NULL, `note` VARCHAR(255) NULL,
  PRIMARY KEY (`id`), KEY `idx_cp_case` (`case_id`), KEY `idx_cp_cid` (`citizenid`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
CREATE TABLE IF NOT EXISTS `pf_mdt_case_entries` (     -- statements, leads, interviews, surveillance logs, notes
  `id` INT NOT NULL AUTO_INCREMENT, `case_id` INT NOT NULL,
  `kind` VARCHAR(12) NOT NULL,          -- statement|lead|interview|surveillance|note|assignment
  `person_id` INT NULL, `assignee_cid` VARCHAR(64) NULL, `status` VARCHAR(12) NULL, `body` LONGTEXT NULL,
  `by_cid` VARCHAR(64) NOT NULL, `at` BIGINT NOT NULL,
  PRIMARY KEY (`id`), KEY `idx_ce_case` (`case_id`, `kind`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
CREATE TABLE IF NOT EXISTS `pf_mdt_bolos` (
  `id` INT NOT NULL AUTO_INCREMENT, `kind` VARCHAR(8) NOT NULL,   -- person|vehicle
  `citizenid` VARCHAR(64) NULL, `plate` VARCHAR(16) NULL, `description` VARCHAR(500) NOT NULL,
  `last_seen` VARCHAR(255) NULL, `danger` TINYINT(1) NOT NULL DEFAULT 0, `status` VARCHAR(10) NOT NULL, -- active|cleared|expired
  `case_id` INT NULL, `by_cid` VARCHAR(64) NOT NULL, `created_at` BIGINT NOT NULL, `expires_at` BIGINT NOT NULL,
  PRIMARY KEY (`id`), KEY `idx_bolo_plate` (`plate`, `status`), KEY `idx_bolo_cid` (`citizenid`, `status`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
CREATE TABLE IF NOT EXISTS `pf_mdt_record_audit` (
  `id` BIGINT NOT NULL AUTO_INCREMENT, `entity` VARCHAR(16) NOT NULL, `entity_id` VARCHAR(64) NOT NULL,
  `action` VARCHAR(12) NOT NULL,        -- read|create|update|delete|status
  `by_cid` VARCHAR(64) NOT NULL, `by_job` VARCHAR(32) NULL, `detail` LONGTEXT NULL, `at` BIGINT NOT NULL,
  PRIMARY KEY (`id`), KEY `idx_ra_entity` (`entity`, `entity_id`), KEY `idx_ra_by` (`by_cid`, `at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
ALTER TABLE `pf_mdt_warrants` ADD COLUMN IF NOT EXISTS `warrant_type` VARCHAR(8) NOT NULL DEFAULT 'arrest';
ALTER TABLE `pf_mdt_warrants` ADD COLUMN IF NOT EXISTS `approval_state` VARCHAR(16) NOT NULL DEFAULT 'legacy';  -- legacy|pending_approval|approved|denied|needs_info
ALTER TABLE `pf_mdt_warrants` ADD COLUMN IF NOT EXISTS `approved_by` VARCHAR(64) NULL;
ALTER TABLE `pf_mdt_warrants` ADD COLUMN IF NOT EXISTS `review_id` INT NULL;
ALTER TABLE `pf_mdt_warrants` ADD COLUMN IF NOT EXISTS `served_custody_id` INT NULL;
ALTER TABLE `pf_mdt_warrants` ADD COLUMN IF NOT EXISTS `address` VARCHAR(128) NULL;
CREATE INDEX IF NOT EXISTS `idx_warrant_suspect_cid` ON `pf_mdt_warrants` (`suspectCitizenId`);
ALTER TABLE `pf_mdt_incidents` ADD COLUMN IF NOT EXISTS `deleted_at` BIGINT NULL;     -- soft delete for expungement
ALTER TABLE `pf_mdt_sentences` ADD COLUMN IF NOT EXISTS `justice_order_ids` VARCHAR(64) NULL;
ALTER TABLE `pf_mdt_sentences` ADD COLUMN IF NOT EXISTS `deleted_at` BIGINT NULL;
```
  Existing warrants keep `approval_state = 'legacy'` (they were valid when issued).
- v9 personnel, UoF, pursuits, IA (20F):
```sql
CREATE TABLE IF NOT EXISTS `pf_mdt_force_reports` (
  `id` INT NOT NULL AUTO_INCREMENT, `kind` VARCHAR(10) NOT NULL,   -- uof|pursuit|ois
  `officer_cid` VARCHAR(64) NOT NULL, `subject_cid` VARCHAR(64) NULL, `custody_id` INT NULL,
  `force_level` TINYINT NULL, `telemetry_from` BIGINT NULL, `telemetry_to` BIGINT NULL, `auto_summary` LONGTEXT NULL,
  `narrative` LONGTEXT NULL, `state` VARCHAR(12) NOT NULL,          -- draft|submitted|reviewed|returned|closed
  `reviewer_cid` VARCHAR(64) NULL, `created_at` BIGINT NOT NULL, `updated_at` BIGINT NOT NULL,
  PRIMARY KEY (`id`), KEY `idx_fr_officer` (`officer_cid`, `state`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
CREATE TABLE IF NOT EXISTS `pf_mdt_ia_complaints` (
  `id` INT NOT NULL AUTO_INCREMENT, `complainant_cid` VARCHAR(64) NULL, `officer_cid` VARCHAR(64) NULL,
  `summary` LONGTEXT NOT NULL, `state` VARCHAR(12) NOT NULL,       -- received|investigating|sustained|not_sustained|closed
  `investigator_cid` VARCHAR(64) NULL, `outcome` VARCHAR(255) NULL, `created_at` BIGINT NOT NULL, `updated_at` BIGINT NOT NULL,
  PRIMARY KEY (`id`), KEY `idx_ia_officer` (`officer_cid`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
CREATE TABLE IF NOT EXISTS `pf_mdt_reviews` (
  `id` INT NOT NULL AUTO_INCREMENT, `officer_cid` VARCHAR(64) NOT NULL, `reviewer_cid` VARCHAR(64) NOT NULL,
  `period` VARCHAR(16) NOT NULL, `scores` LONGTEXT NULL, `notes` LONGTEXT NULL, `at` BIGINT NOT NULL,
  PRIMARY KEY (`id`), KEY `idx_rev_officer` (`officer_cid`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
```

---------------------------------------------------------------------------------------------------------------------

## 7. pf-justice (key `pf-justice`)

### v1 core (15B; tables used by 15B and 15C)
```sql
CREATE TABLE IF NOT EXISTS `pf_justice_orders` (
  `id` INT NOT NULL AUTO_INCREMENT,
  `citizenid` VARCHAR(64) NOT NULL,
  `kind` VARCHAR(20) NOT NULL,          -- jail|prison|fine|citation|restitution|community_service|probation|parole|remand
  `state` VARCHAR(16) NOT NULL,         -- pending|active|suspended|completed|vacated|revoked|issued|payment_pending|invoiced|paid|overdue|referred|waived|contested|assigned|in_progress
  `facility` VARCHAR(32) NULL,
  `clock` VARCHAR(8) NULL,              -- online|hybrid|realtime
  `required_seconds` INT NULL, `served_seconds` INT NOT NULL DEFAULT 0,
  `credit_seconds` INT NOT NULL DEFAULT 0, `forfeit_seconds` INT NOT NULL DEFAULT 0,
  `last_tick_at` BIGINT NULL, `release_at` BIGINT NULL,
  `amount` INT NULL, `paid_amount` INT NOT NULL DEFAULT 0, `pay_attempt` INT NOT NULL DEFAULT 0, `pay_key` VARCHAR(128) NULL,
  `invoice_id` INT NULL, `victim_cid` VARCHAR(64) NULL,
  `units` INT NULL, `units_done` INT NOT NULL DEFAULT 0,
  `days` INT NULL, `conditions` LONGTEXT NULL,
  `charges` LONGTEXT NULL,
  `source_type` VARCHAR(16) NULL, `source_id` VARCHAR(64) NULL,
  `custody_id` INT NULL, `parent_order_id` INT NULL,
  `starts_at` BIGINT NULL, `due_at` BIGINT NULL, `ends_at` BIGINT NULL,
  `idem_key` VARCHAR(128) NULL, `legacy_ref` VARCHAR(64) NULL,
  `created_by` VARCHAR(64) NULL, `created_at` BIGINT NOT NULL, `updated_at` BIGINT NOT NULL,
  PRIMARY KEY (`id`),
  UNIQUE KEY `uq_jo_key` (`idem_key`), UNIQUE KEY `uq_jo_legacy` (`legacy_ref`),
  KEY `idx_jo_cid` (`citizenid`, `kind`, `state`), KEY `idx_jo_state` (`kind`, `state`), KEY `idx_jo_source` (`source_type`, `source_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `pf_justice_order_events` (
  `id` BIGINT NOT NULL AUTO_INCREMENT, `order_id` INT NOT NULL, `action` VARCHAR(20) NOT NULL,
  `detail` LONGTEXT NULL, `actor_cid` VARCHAR(64) NULL, `actor_kind` VARCHAR(8) NULL, `actor_resource` VARCHAR(48) NULL, `at` BIGINT NOT NULL,
  PRIMARY KEY (`id`), KEY `idx_joe_order` (`order_id`, `at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `pf_justice_citations` (
  `id` INT NOT NULL AUTO_INCREMENT, `order_id` INT NOT NULL, `uid` VARCHAR(32) NOT NULL,
  `violation` VARCHAR(48) NOT NULL, `plate` VARCHAR(16) NULL, `speed_kmh` SMALLINT NULL, `limit_kmh` SMALLINT NULL,
  `x` DECIMAL(9,2) NULL, `y` DECIMAL(9,2) NULL, `officer_cid` VARCHAR(64) NOT NULL, `contest_until` BIGINT NULL,
  `at` BIGINT NOT NULL,
  PRIMARY KEY (`id`), UNIQUE KEY `uq_cit_uid` (`uid`), KEY `idx_cit_order` (`order_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `pf_justice_records` (
  `id` INT NOT NULL AUTO_INCREMENT, `citizenid` VARCHAR(64) NOT NULL,
  `kind` VARCHAR(12) NOT NULL,          -- conviction|arrest|citation|note|legacy_flag
  `ref_type` VARCHAR(16) NULL, `ref_id` VARCHAR(64) NULL, `summary` VARCHAR(500) NOT NULL,
  `expunged_at` BIGINT NULL, `expunged_by` VARCHAR(64) NULL, `expunge_ref` VARCHAR(64) NULL,
  `at` BIGINT NOT NULL,
  PRIMARY KEY (`id`), KEY `idx_jr_cid` (`citizenid`, `expunged_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `pf_justice_custody` (
  `id` INT NOT NULL AUTO_INCREMENT, `citizenid` VARCHAR(64) NOT NULL,
  `state` VARCHAR(16) NOT NULL,         -- detained|arrested|in_transport|booking|booked|held|remanded|hospital|transferred|released
  `prev_state` VARCHAR(16) NULL,        -- the state to return to after a hospital transfer
  `facility` VARCHAR(32) NULL, `cell_id` VARCHAR(32) NULL, `officer_cid` VARCHAR(64) NULL,
  `reason` VARCHAR(255) NULL, `charges` LONGTEXT NULL, `incident_id` VARCHAR(32) NULL,
  `booking_no` VARCHAR(24) NULL, `hold_until` BIGINT NULL, `release_reason` VARCHAR(24) NULL,
  `opened_at` BIGINT NOT NULL, `updated_at` BIGINT NOT NULL, `closed_at` BIGINT NULL, `idem_key` VARCHAR(128) NULL,
  PRIMARY KEY (`id`), UNIQUE KEY `uq_jc_key` (`idem_key`),
  KEY `idx_jc_cid` (`citizenid`, `closed_at`), KEY `idx_jc_state` (`state`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `pf_justice_custody_log` (
  `id` BIGINT NOT NULL AUTO_INCREMENT, `custody_id` INT NOT NULL, `kind` VARCHAR(20) NOT NULL,
  `data` LONGTEXT NULL, `actor_cid` VARCHAR(64) NULL, `at` BIGINT NOT NULL,
  PRIMARY KEY (`id`), KEY `idx_jcl_custody` (`custody_id`, `at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `pf_justice_bookings` (
  `id` INT NOT NULL AUTO_INCREMENT, `custody_id` INT NOT NULL, `booking_no` VARCHAR(24) NOT NULL,
  `citizenid` VARCHAR(64) NOT NULL, `fingerprint` VARCHAR(64) NULL, `bloodtype` VARCHAR(4) NULL,
  `dna_sample_ref` VARCHAR(64) NULL,    -- random token; identity only through the lab (PJ reference samples)
  `mugshot_url` VARCHAR(512) NULL, `client_supplied` TINYINT(1) NOT NULL DEFAULT 1,
  `height_cm` SMALLINT NULL, `marks` VARCHAR(255) NULL, `screening` VARCHAR(24) NULL, `notes` VARCHAR(500) NULL,
  `booked_by` VARCHAR(64) NOT NULL, `at` BIGINT NOT NULL,
  PRIMARY KEY (`id`), UNIQUE KEY `uq_jb_no` (`booking_no`), UNIQUE KEY `uq_jb_custody` (`custody_id`), KEY `idx_jb_cid` (`citizenid`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `pf_justice_property` (
  `id` INT NOT NULL AUTO_INCREMENT, `citizenid` VARCHAR(64) NOT NULL, `custody_id` INT NULL, `order_id` INT NULL,
  `stash_id` VARCHAR(64) NOT NULL,
  `state` VARCHAR(12) NOT NULL,         -- held|returning|returned|partially_returned|forfeited
  `reason` VARCHAR(128) NULL, `seized_by` VARCHAR(64) NULL, `seized_at` BIGINT NOT NULL, `returned_at` BIGINT NULL,
  `idem_key` VARCHAR(128) NULL, `legacy_ref` VARCHAR(64) NULL,
  PRIMARY KEY (`id`), UNIQUE KEY `uq_jp_stash` (`stash_id`), UNIQUE KEY `uq_jp_key` (`idem_key`), UNIQUE KEY `uq_jp_legacy` (`legacy_ref`),
  KEY `idx_jp_cid` (`citizenid`, `state`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `pf_justice_property_items` (    -- the receipt (what was taken, as recorded at seizure)
  `id` BIGINT NOT NULL AUTO_INCREMENT, `property_id` INT NOT NULL, `item` VARCHAR(64) NOT NULL, `amount` INT NOT NULL,
  `info` LONGTEXT NULL, `state` VARCHAR(10) NOT NULL DEFAULT 'held',  -- held|returned|forfeited
  `evidence_id` INT NULL,
  PRIMARY KEY (`id`), KEY `idx_jpi_prop` (`property_id`),
  CONSTRAINT `fk_jpi_prop` FOREIGN KEY (`property_id`) REFERENCES `pf_justice_property` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `pf_justice_bail` (
  `id` INT NOT NULL AUTO_INCREMENT, `citizenid` VARCHAR(64) NOT NULL, `custody_id` INT NULL, `order_id` INT NULL,
  `amount` INT NOT NULL, `conditions` LONGTEXT NULL,
  `state` VARCHAR(16) NOT NULL,         -- offered|accepted|payment_pending|posted|declined|expired|exonerated|refunded|forfeited
  `payer_cid` VARCHAR(64) NULL, `payer_name` VARCHAR(128) NULL, `pay_attempt` INT NOT NULL DEFAULT 0, `pay_key` VARCHAR(128) NULL,
  `offered_by` VARCHAR(64) NULL, `offered_at` BIGINT NOT NULL, `expires_at` BIGINT NOT NULL, `posted_at` BIGINT NULL,
  `closed_at` BIGINT NULL, `legacy_ref` VARCHAR(64) NULL,
  PRIMARY KEY (`id`), UNIQUE KEY `uq_jbl_legacy` (`legacy_ref`), KEY `idx_jbl_cid` (`citizenid`, `state`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
```

### v2 legacy import (15B step, code in 15C `server/legacy_import.lua`): function step
1. If `pf_mdt_active_jails` exists: each row -> `pf_justice_orders` (`kind = 'jail'`, `facility = 'bolingbroke'`,
   `required_seconds = total_seconds`, `served_seconds = total_seconds - remaining_seconds`, `clock = 'online'`,
   `source_type = 'mdt_sentence'`, `source_id = sentence_id`, `legacy_ref = 'mdt_jail:<id>'`, state `active`, or
   `completed` when `released_why` is set); `items` JSON -> `pf_justice_property` (`stash_id = pf_justice_property_<id>`,
   items moved into that stash with `pfm-inventory` once the resource is started, `legacy_ref = 'mdt_jail_items:<id>'`);
   open bail (`bail_amount > 0` and no `bail_key`) -> `pf_justice_bail` `offered`; a held `bail_key` ->
   `payment_pending` with that key (settled by the bail sweep through `GetTransaction`).
2. Offline players with `JSON_EXTRACT(metadata, '$.injail') > 0` -> `kind = 'prison'`, `required_seconds = injail * 60`,
   `clock = 'online'`, `legacy_ref = 'meta_injail:<cid>:<jailid or none>'`; non-empty `$.jailitems` -> property row
   (items written into the stash when the stash is first opened at release, from the stored JSON).
3. `$.criminalrecord.hasRecord = true` -> `pf_justice_records` `kind = 'legacy_flag'` once per citizen.
4. Online players are handled at `QBCore:Server:PlayerLoaded` by the same functions (same `legacy_ref`).
`INSERT IGNORE` on `legacy_ref` makes every step run once. The import never deletes or edits the legacy rows.

### v3 courts (19A)
```sql
CREATE TABLE IF NOT EXISTS `pf_justice_cases` (
  `id` INT NOT NULL AUTO_INCREMENT, `case_no` VARCHAR(20) NOT NULL, `citizenid` VARCHAR(64) NOT NULL,
  `state` VARCHAR(24) NOT NULL, `kind` VARCHAR(12) NOT NULL DEFAULT 'criminal',  -- criminal|violation|citation_contest|appeal
  `charges` LONGTEXT NULL, `custody_id` INT NULL, `mdt_case_id` INT NULL, `prosecutor_cid` VARCHAR(64) NULL,
  `defender_cid` VARCHAR(64) NULL, `judge_cid` VARCHAR(64) NULL, `filed_by` VARCHAR(64) NOT NULL,
  `filed_at` BIGINT NOT NULL, `closed_at` BIGINT NULL, `idem_key` VARCHAR(128) NULL,
  PRIMARY KEY (`id`), UNIQUE KEY `uq_jcase_no` (`case_no`), UNIQUE KEY `uq_jcase_key` (`idem_key`), KEY `idx_jcase_cid` (`citizenid`, `state`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
CREATE TABLE IF NOT EXISTS `pf_justice_case_refs` (
  `id` INT NOT NULL AUTO_INCREMENT, `case_id` INT NOT NULL, `ref_type` VARCHAR(16) NOT NULL, `ref_id` VARCHAR(64) NOT NULL,
  PRIMARY KEY (`id`), UNIQUE KEY `uq_jcr` (`case_id`, `ref_type`, `ref_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
CREATE TABLE IF NOT EXISTS `pf_justice_hearings` (
  `id` INT NOT NULL AUTO_INCREMENT, `case_id` INT NOT NULL, `kind` VARCHAR(12) NOT NULL,
  `courtroom` VARCHAR(24) NULL, `at` BIGINT NOT NULL, `judge_cid` VARCHAR(64) NULL,
  `state` VARCHAR(12) NOT NULL,         -- scheduled|held|adjourned|cancelled|auto
  `notes` LONGTEXT NULL, PRIMARY KEY (`id`), KEY `idx_jh_case` (`case_id`), KEY `idx_jh_at` (`state`, `at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
CREATE TABLE IF NOT EXISTS `pf_justice_decisions` (
  `id` INT NOT NULL AUTO_INCREMENT, `case_id` INT NOT NULL, `hearing_id` INT NULL, `kind` VARCHAR(16) NOT NULL,
  `body` LONGTEXT NOT NULL, `decided_by` VARCHAR(64) NOT NULL,   -- citizenid or 'schedule'
  `order_ids` VARCHAR(255) NULL, `at` BIGINT NOT NULL,
  PRIMARY KEY (`id`), KEY `idx_jd_case` (`case_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
CREATE TABLE IF NOT EXISTS `pf_justice_warrant_reviews` (
  `id` INT NOT NULL AUTO_INCREMENT, `warrant_id` VARCHAR(32) NOT NULL, `type` VARCHAR(8) NOT NULL,
  `target_cid` VARCHAR(64) NULL, `address` VARCHAR(128) NULL, `affidavit` LONGTEXT NOT NULL,
  `requested_by` VARCHAR(64) NOT NULL, `state` VARCHAR(12) NOT NULL,   -- requested|approved|denied|needs_info
  `judge_cid` VARCHAR(64) NULL, `note` VARCHAR(500) NULL, `requested_at` BIGINT NOT NULL, `decided_at` BIGINT NULL,
  PRIMARY KEY (`id`), KEY `idx_jwr_state` (`state`), KEY `idx_jwr_warrant` (`warrant_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
CREATE TABLE IF NOT EXISTS `pf_justice_court_orders` (    -- release orders, record subpoenas, search orders
  `id` INT NOT NULL AUTO_INCREMENT, `ref` VARCHAR(24) NOT NULL, `kind` VARCHAR(16) NOT NULL,  -- release|medical_records|telemetry|search|property
  `citizenid` VARCHAR(64) NULL, `case_id` INT NULL, `body` LONGTEXT NULL, `judge_cid` VARCHAR(64) NOT NULL,
  `valid_until` BIGINT NULL, `revoked_at` BIGINT NULL, `at` BIGINT NOT NULL,
  PRIMARY KEY (`id`), UNIQUE KEY `uq_jco_ref` (`ref`), KEY `idx_jco_cid` (`citizenid`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
```

### v4 supervision (19A for 19B)
```sql
CREATE TABLE IF NOT EXISTS `pf_justice_supervision` (
  `id` INT NOT NULL AUTO_INCREMENT, `order_id` INT NOT NULL, `citizenid` VARCHAR(64) NOT NULL,
  `officer_cid` VARCHAR(64) NULL, `state` VARCHAR(12) NOT NULL,   -- active|suspended|completed|revoked
  `monitor` LONGTEXT NULL, `next_checkin_at` BIGINT NULL, `created_at` BIGINT NOT NULL, `ended_at` BIGINT NULL,
  PRIMARY KEY (`id`), UNIQUE KEY `uq_js_order` (`order_id`), KEY `idx_js_cid` (`citizenid`, `state`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
CREATE TABLE IF NOT EXISTS `pf_justice_supervision_events` (   -- appointments, check-ins, violations
  `id` INT NOT NULL AUTO_INCREMENT, `supervision_id` INT NOT NULL, `kind` VARCHAR(12) NOT NULL,  -- appointment|checkin|violation|note
  `due_at` BIGINT NULL, `done_at` BIGINT NULL, `state` VARCHAR(12) NULL, `detail` LONGTEXT NULL, `by_cid` VARCHAR(64) NULL,
  `at` BIGINT NOT NULL,
  PRIMARY KEY (`id`), KEY `idx_jse_sup` (`supervision_id`, `kind`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
```

### v5 community service (19A for 19C)
```sql
CREATE TABLE IF NOT EXISTS `pf_justice_cs_shifts` (
  `id` INT NOT NULL AUTO_INCREMENT, `order_id` INT NOT NULL, `citizenid` VARCHAR(64) NOT NULL,
  `site` VARCHAR(32) NULL, `supervisor_cid` VARCHAR(64) NULL, `started_at` BIGINT NOT NULL, `ended_at` BIGINT NULL,
  `units` DECIMAL(6,2) NOT NULL DEFAULT 0,
  PRIMARY KEY (`id`), KEY `idx_jcs_order` (`order_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
CREATE TABLE IF NOT EXISTS `pf_justice_cs_tasks` (
  `id` INT NOT NULL AUTO_INCREMENT, `shift_id` INT NOT NULL, `order_id` INT NOT NULL,
  `work_order_id` INT NOT NULL, `claim_id` INT NOT NULL, `kind` VARCHAR(16) NOT NULL,
  `steps_done` TINYINT NOT NULL DEFAULT 0, `steps_needed` TINYINT NOT NULL,
  `state` VARCHAR(10) NOT NULL,         -- active|done|released|expired|rejected
  `started_at` BIGINT NOT NULL, `done_at` BIGINT NULL, `reject_reason` VARCHAR(64) NULL,
  PRIMARY KEY (`id`), KEY `idx_jct_shift` (`shift_id`), KEY `idx_jct_claim` (`claim_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
```

---------------------------------------------------------------------------------------------------------------------

## 8. pfm-prison (key `pfm-prison`)

`fxmanifest.lua` gains `'@oxmysql/lib/MySQL.lua'` (16C).

### v1 inmates and events (16C)
```sql
CREATE TABLE IF NOT EXISTS `pf_prison_inmates` (
  `citizenid` VARCHAR(64) NOT NULL, `order_id` INT NOT NULL, `facility` VARCHAR(32) NOT NULL,
  `status` VARCHAR(12) NOT NULL,        -- intake|in_cell|yard|work|meal|infirmary|visitation|solitary|transfer|escaped
  `cell_id` VARCHAR(16) NULL, `classification` VARCHAR(8) NOT NULL DEFAULT 'medium',
  `admitted_at` BIGINT NOT NULL, `status_at` BIGINT NOT NULL, `job_ticket` INT NULL,
  PRIMARY KEY (`citizenid`), KEY `idx_pi_order` (`order_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
CREATE TABLE IF NOT EXISTS `pf_prison_events` (
  `id` BIGINT NOT NULL AUTO_INCREMENT, `citizenid` VARCHAR(64) NULL, `facility` VARCHAR(32) NOT NULL,
  `kind` VARCHAR(16) NOT NULL,          -- intake|release|work|credit|escape|recapture|sendback|anomaly|lockdown|count|search
  `detail` LONGTEXT NULL, `actor_cid` VARCHAR(64) NULL, `at` BIGINT NOT NULL,
  PRIMARY KEY (`id`), KEY `idx_pe_cid` (`citizenid`, `at`), KEY `idx_pe_kind` (`facility`, `kind`, `at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
```

### v2 facility (19D)
```sql
CREATE TABLE IF NOT EXISTS `pf_prison_cells` (           -- seeded from config_facility.lua (INSERT IGNORE)
  `facility` VARCHAR(32) NOT NULL, `cell_id` VARCHAR(16) NOT NULL, `block` VARCHAR(8) NOT NULL,
  `classification` VARCHAR(8) NOT NULL, `capacity` TINYINT NOT NULL DEFAULT 2, `out_of_service` TINYINT(1) NOT NULL DEFAULT 0,
  PRIMARY KEY (`facility`, `cell_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
CREATE TABLE IF NOT EXISTS `pf_prison_counts` (
  `id` INT NOT NULL AUTO_INCREMENT, `facility` VARCHAR(32) NOT NULL, `due_at` BIGINT NOT NULL, `closed_at` BIGINT NULL,
  `expected` SMALLINT NOT NULL, `present` SMALLINT NOT NULL DEFAULT 0, `missing` LONGTEXT NULL, `by_cid` VARCHAR(64) NULL,
  PRIMARY KEY (`id`), KEY `idx_pc_fac` (`facility`, `due_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
CREATE TABLE IF NOT EXISTS `pf_prison_infractions` (
  `id` INT NOT NULL AUTO_INCREMENT, `citizenid` VARCHAR(64) NOT NULL, `order_id` INT NULL, `code` VARCHAR(16) NOT NULL,
  `severity` TINYINT NOT NULL, `state` VARCHAR(16) NOT NULL,      -- reported|hearing_scheduled|heard|sanctioned|dismissed
  `evidence_ids` VARCHAR(255) NULL, `hearing_at` BIGINT NULL, `heard_by` VARCHAR(64) NULL, `sanction` LONGTEXT NULL,
  `reported_by` VARCHAR(64) NULL, `at` BIGINT NOT NULL,
  PRIMARY KEY (`id`), KEY `idx_pinf_cid` (`citizenid`, `state`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
CREATE TABLE IF NOT EXISTS `pf_prison_visits` (
  `id` INT NOT NULL AUTO_INCREMENT, `inmate_cid` VARCHAR(64) NOT NULL, `visitor_cid` VARCHAR(64) NOT NULL,
  `slot_at` BIGINT NOT NULL, `state` VARCHAR(12) NOT NULL,        -- booked|checked_in|in_progress|done|cancelled|no_show|denied
  `kind` VARCHAR(10) NOT NULL DEFAULT 'social',                   -- social|attorney
  `searched` TINYINT(1) NOT NULL DEFAULT 0, `notes` VARCHAR(255) NULL, `created_at` BIGINT NOT NULL,
  PRIMARY KEY (`id`), KEY `idx_pv_inmate` (`inmate_cid`, `slot_at`), KEY `idx_pv_visitor` (`visitor_cid`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
CREATE TABLE IF NOT EXISTS `pf_prison_privileges` (
  `id` INT NOT NULL AUTO_INCREMENT, `citizenid` VARCHAR(64) NOT NULL, `kind` VARCHAR(16) NOT NULL,  -- commissary|yard|visits|phone|work
  `until_at` BIGINT NOT NULL, `infraction_id` INT NULL,
  PRIMARY KEY (`id`), KEY `idx_ppr_cid` (`citizenid`, `until_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
```

### v3 economy (19D for 19E)
```sql
CREATE TABLE IF NOT EXISTS `pf_prison_account_tx` (       -- the inmate trust ledger (each row backed by a keyed ledger transfer or an internal move)
  `id` BIGINT NOT NULL AUTO_INCREMENT, `citizenid` VARCHAR(64) NOT NULL,
  `kind` VARCHAR(16) NOT NULL,          -- deposit|earning|purchase|restitution|withdrawal|release_payout|adjustment
  `amount` INT NOT NULL,                -- signed: + into the trust, - out of it
  `ledger_key` VARCHAR(128) NULL, `ledger_state` VARCHAR(16) NULL, `ref` VARCHAR(64) NULL, `at` BIGINT NOT NULL,
  PRIMARY KEY (`id`), UNIQUE KEY `uq_pat_key` (`ledger_key`), KEY `idx_pat_cid` (`citizenid`, `at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
CREATE TABLE IF NOT EXISTS `pf_prison_work_log` (
  `id` BIGINT NOT NULL AUTO_INCREMENT, `citizenid` VARCHAR(64) NOT NULL, `order_id` INT NOT NULL, `job` VARCHAR(16) NOT NULL,
  `ticket` INT NOT NULL, `output` LONGTEXT NULL, `credit_seconds` INT NOT NULL DEFAULT 0, `wage` INT NOT NULL DEFAULT 0,
  `at` BIGINT NOT NULL,
  PRIMARY KEY (`id`), UNIQUE KEY `uq_pwl_ticket` (`order_id`, `ticket`), KEY `idx_pwl_cid` (`citizenid`, `at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
```
Balance of an inmate = `SUM(amount)` over rows whose `ledger_state` is `completed` (or internal rows with
`ledger_state = 'internal'`). Deposits/withdrawals across the trust boundary are `Transfer`s with the row's key.

### v4 security (19D for 19F)
```sql
CREATE TABLE IF NOT EXISTS `pf_prison_searches` (
  `id` INT NOT NULL AUTO_INCREMENT, `facility` VARCHAR(32) NOT NULL, `kind` VARCHAR(8) NOT NULL,   -- cell|pat|visitor|vehicle
  `target` VARCHAR(64) NOT NULL, `by_cid` VARCHAR(64) NOT NULL, `found` LONGTEXT NULL, `evidence_ids` VARCHAR(255) NULL, `at` BIGINT NOT NULL,
  PRIMARY KEY (`id`), KEY `idx_ps_target` (`target`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
CREATE TABLE IF NOT EXISTS `pf_prison_escapes` (
  `id` INT NOT NULL AUTO_INCREMENT, `citizenid` VARCHAR(64) NOT NULL, `order_id` INT NOT NULL, `method` VARCHAR(16) NOT NULL,
  `gate` VARCHAR(8) NULL, `warrant_id` VARCHAR(32) NULL, `escaped_at` BIGINT NOT NULL, `recaptured_at` BIGINT NULL,
  PRIMARY KEY (`id`), KEY `idx_pesc_cid` (`citizenid`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
```

---------------------------------------------------------------------------------------------------------------------

## 9. pf-government (key `pf-government`)

### v5 work orders (15E)
```sql
CREATE TABLE IF NOT EXISTS `pf_gov_work_orders` (
  `id` INT NOT NULL AUTO_INCREMENT, `kind` VARCHAR(16) NOT NULL, `district` VARCHAR(60) NOT NULL,
  `x` DECIMAL(9,2) NOT NULL, `y` DECIMAL(9,2) NOT NULL, `z` DECIMAL(9,2) NOT NULL, `radius` DECIMAL(6,2) NOT NULL,
  `units` TINYINT NOT NULL, `units_done` TINYINT NOT NULL DEFAULT 0,
  `effect_field` VARCHAR(32) NOT NULL, `effect_delta` DECIMAL(10,2) NOT NULL,
  `cs_eligible` TINYINT(1) NOT NULL DEFAULT 1, `pay_amount` INT NOT NULL DEFAULT 0, `pay_dept` VARCHAR(32) NULL,
  `source_type` VARCHAR(16) NOT NULL, `source_id` VARCHAR(64) NULL,
  `status` VARCHAR(12) NOT NULL,        -- open|in_progress|completed|expired|cancelled
  `created_at` BIGINT NOT NULL, `expires_at` BIGINT NOT NULL, `completed_at` BIGINT NULL, `idem_key` VARCHAR(128) NULL,
  PRIMARY KEY (`id`), UNIQUE KEY `uq_wo_key` (`idem_key`),
  KEY `idx_wo_open` (`status`, `district`), KEY `idx_wo_exp` (`status`, `expires_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
CREATE TABLE IF NOT EXISTS `pf_gov_work_claims` (
  `id` INT NOT NULL AUTO_INCREMENT, `work_order_id` INT NOT NULL, `claimant_kind` VARCHAR(8) NOT NULL,  -- cs|staff|job
  `citizenid` VARCHAR(64) NOT NULL, `ref` VARCHAR(64) NULL,
  `state` VARCHAR(10) NOT NULL,         -- claimed|done|released|expired
  `claimed_at` BIGINT NOT NULL, `expires_at` BIGINT NOT NULL, `done_at` BIGINT NULL, `proof_key` VARCHAR(128) NULL,
  `paid_key` VARCHAR(128) NULL,
  PRIMARY KEY (`id`), UNIQUE KEY `uq_wc_proof` (`proof_key`), KEY `idx_wc_wo` (`work_order_id`, `state`), KEY `idx_wc_cid` (`citizenid`, `state`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
```

### v6 department core (15E for 15I)
```sql
CREATE TABLE IF NOT EXISTS `pf_gov_dept_qualifications` (
  `id` INT NOT NULL AUTO_INCREMENT, `citizenid` VARCHAR(64) NOT NULL, `qual` VARCHAR(32) NOT NULL,
  `state` VARCHAR(8) NOT NULL,          -- granted|revoked
  `granted_by` VARCHAR(64) NULL, `source` VARCHAR(16) NOT NULL DEFAULT 'manual',  -- manual|training|import
  `expires_at` BIGINT NULL, `at` BIGINT NOT NULL, `idem_key` VARCHAR(128) NULL,
  PRIMARY KEY (`id`), UNIQUE KEY `uq_dq_cid_qual` (`citizenid`, `qual`), UNIQUE KEY `uq_dq_key` (`idem_key`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
CREATE TABLE IF NOT EXISTS `pf_gov_dept_shifts` (
  `id` INT NOT NULL AUTO_INCREMENT, `citizenid` VARCHAR(64) NOT NULL, `dept` VARCHAR(16) NOT NULL, `job` VARCHAR(32) NOT NULL,
  `grade` TINYINT NOT NULL, `started_at` BIGINT NOT NULL, `ended_at` BIGINT NULL, `end_reason` VARCHAR(16) NULL,  -- duty_off|dropped|job_change|incarcerated|restart
  PRIMARY KEY (`id`), KEY `idx_ds_cid` (`citizenid`, `started_at`), KEY `idx_ds_open` (`dept`, `ended_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
CREATE TABLE IF NOT EXISTS `pf_gov_dept_audit` (
  `id` BIGINT NOT NULL AUTO_INCREMENT, `dept` VARCHAR(16) NOT NULL, `action` VARCHAR(32) NOT NULL,
  `actor_cid` VARCHAR(64) NULL, `actor_resource` VARCHAR(48) NULL, `target` VARCHAR(64) NULL, `detail` LONGTEXT NULL, `at` BIGINT NOT NULL,
  PRIMARY KEY (`id`), KEY `idx_da_dept` (`dept`, `at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
-- pf_gov_budget_transactions is created ad hoc in server/budgets.lua (~line 214); copy that CREATE TABLE IF NOT
-- EXISTS here first, so the ALTER cannot run before the table exists
ALTER TABLE `pf_gov_budget_transactions` ADD COLUMN IF NOT EXISTS `idem_key` VARCHAR(128) NULL;
CREATE UNIQUE INDEX IF NOT EXISTS `uq_gov_budget_tx_key` ON `pf_gov_budget_transactions` (`idem_key`);
```
Open shifts at start-up are closed with `end_reason = 'restart'`. A keyed budget move inserts its audit row with the
key first (`INSERT ... idem_key`); a duplicate key means the move already happened, so no money moves again.

### v7 department management (20E)
```sql
CREATE TABLE IF NOT EXISTS `pf_gov_dept_training` (
  `id` INT NOT NULL AUTO_INCREMENT, `citizenid` VARCHAR(64) NOT NULL, `dept` VARCHAR(16) NOT NULL, `course` VARCHAR(32) NOT NULL,
  `result` VARCHAR(8) NOT NULL,         -- pass|fail|in_progress
  `instructor_cid` VARCHAR(64) NULL, `grants_qual` VARCHAR(32) NULL, `at` BIGINT NOT NULL,
  PRIMARY KEY (`id`), KEY `idx_dt_cid` (`citizenid`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
CREATE TABLE IF NOT EXISTS `pf_gov_dept_assets` (
  `id` INT NOT NULL AUTO_INCREMENT, `dept` VARCHAR(16) NOT NULL, `kind` VARCHAR(24) NOT NULL, `serial` VARCHAR(32) NOT NULL,
  `item` VARCHAR(48) NULL, `state` VARCHAR(12) NOT NULL,          -- in_stock|issued|maintenance|lost|retired
  `holder_cid` VARCHAR(64) NULL, `location` VARCHAR(48) NULL, `cost` INT NOT NULL DEFAULT 0, `acquired_at` BIGINT NOT NULL,
  PRIMARY KEY (`id`), UNIQUE KEY `uq_da_serial` (`dept`, `serial`), KEY `idx_da_holder` (`holder_cid`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
CREATE TABLE IF NOT EXISTS `pf_gov_dept_asset_events` (
  `id` BIGINT NOT NULL AUTO_INCREMENT, `asset_id` INT NOT NULL, `event` VARCHAR(12) NOT NULL,  -- issue|return|repair|lost|retire
  `actor_cid` VARCHAR(64) NULL, `holder_cid` VARCHAR(64) NULL, `note` VARCHAR(255) NULL, `at` BIGINT NOT NULL,
  PRIMARY KEY (`id`), KEY `idx_dae_asset` (`asset_id`, `at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
CREATE TABLE IF NOT EXISTS `pf_gov_dept_procurements` (
  `id` INT NOT NULL AUTO_INCREMENT, `dept` VARCHAR(16) NOT NULL, `buyer_id` VARCHAR(48) NOT NULL, `store_order_id` INT NULL,
  `total` INT NOT NULL, `state` VARCHAR(12) NOT NULL, `by_cid` VARCHAR(64) NOT NULL, `at` BIGINT NOT NULL,
  PRIMARY KEY (`id`), KEY `idx_dp_dept` (`dept`, `at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
```

---------------------------------------------------------------------------------------------------------------------

## 10. Small resources

- **pf-jobgarages** (key `pf-jobgarages`, 15H) v1: the three `CREATE TABLE IF NOT EXISTS` from
  `sql/pf_jobgarages.sql` (`job_garage_vehicles`, `job_garage_permissions`, `job_garage_logs`; not its
  `player_vehicles` stub, which pfm-core owns), then
  ```sql
  ALTER TABLE `job_garage_vehicles` ADD COLUMN IF NOT EXISTS `service_state` VARCHAR(16) NOT NULL DEFAULT 'ok';  -- ok|due|in_service|out_of_service
  ALTER TABLE `job_garage_vehicles` ADD COLUMN IF NOT EXISTS `last_service_at` DATETIME NULL;
  ALTER TABLE `job_garage_vehicles` ADD COLUMN IF NOT EXISTS `service_due_at` DATETIME NULL;
  ALTER TABLE `job_garage_vehicles` ADD COLUMN IF NOT EXISTS `last_body` SMALLINT NULL;
  ALTER TABLE `job_garage_vehicles` ADD COLUMN IF NOT EXISTS `last_engine` SMALLINT NULL;
  ```
- **pfm-phone** (15H): through `EnsureInvoiceColumns` (the file's existing pattern; it also reads the columns back):
  `ALTER TABLE phone_invoices ADD COLUMN ref VARCHAR(128) NULL` and `CREATE UNIQUE INDEX uq_phone_invoices_ref ON phone_invoices (ref)`;
  the same column in `qb-phone.sql`.

---------------------------------------------------------------------------------------------------------------------

## 11. Existing tables: kept, frozen, retired

| Table | Owner | Fate |
|---|---|---|
| `player_injuries`, `player_treatment_log` | AJ | **Frozen** after the 16B import (read only for history); legacy CRUD functions remain for third-party callers. Never dropped automatically |
| `player_health_snapshot` | AJ | Created by v1, never written; **retired** (left in place) |
| `patient_care_reports`, `vital_signs_log`, `medication_administration`, `doa_records`, `mci_incidents`, `mci_patients` | AJ SQL file only | Never created by code; **superseded** by `pf_emsmdt_pcr*`, `pf_med_*`, `pf_med_death_records`; the SQL file marks them unused (15A) |
| `pf_mdt_active_jails` | PMDT | **Frozen** after the JU import (15C/16D); the MDT stops writing it in 16D |
| `pf_mdt_sentences` | PMDT | **Kept**: the legal sentence record; gains `justice_order_ids`, `deleted_at` (v8) |
| `pf_mdt_pending_sentences` | PMDT | Kept for the rcore path only |
| `pf_mdt_evidence`, `pf_mdt_incident_evidence` | PMDT | **Kept** as photo records; linked to PJ evidence by `AttachExternalRecord` (case links); optional import into PJ as `photo` evidence is a later decision |
| `pfm_police_fines` | PJ | **Kept**; new fines are JU orders from 16D; the PJ sweep drains open rows |
| `pf_gov_bills` | GOV | Kept; city fines stay GOV bills (JU fines are orders) |
| `pf_mdt_vehicle_activity` | PMDT | Read but never written today; written by PJ ALPR hits through a PMDT export (18F) or dropped from the UI |
| Player metadata `injail`, `criminalrecord` | (was PR/PJ) | **Mirrors** written by JU only (16C/16D) |
| Player metadata `jailitems` | (was PR) | **Retired** after the import moves items into JU property |

## 12. Data migration order (per install)

1. Batch 15 deploy: PMDT v7 and EMDT v2 create the missing tables (no data change on installs that imported the SQL
   files by hand). JU v1 tables and v2 import run: legacy MDT jails, offline `injail` sentences and criminal-record
   flags become JU rows. **The old runtimes still run in batch 15**, so the import's `legacy_ref` makes a second
   import pass at batch 16 deploy pick up anything sentenced in between (run the v2 functions again on 16D start:
   they are idempotent).
2. Batch 16 deploy: AJ v4 import of `player_injuries`; PMDT stops using `pf_mdt_active_jails`; PR v1 tables; at each
   player load JU imports any remaining `injail`/`jailitems` and PR admits from JU.
3. Later batches only add tables/columns.

## 13. Verification queries (run on a copy of live after each deploy)

```sql
SELECT resource, version, name, applied_at FROM pf_schema_migrations
 WHERE resource IN ('pf-ambulancejob','pf-emsmdt','pfm-policejob','pf-policemdt-DEV','pf-justice','pfm-prison','pf-government','pf-jobgarages')
 ORDER BY resource, version;
-- every legacy MDT jail imported once
SELECT COUNT(*) FROM pf_mdt_active_jails j LEFT JOIN pf_justice_orders o ON o.legacy_ref = CONCAT('mdt_jail:', j.id) WHERE o.id IS NULL;
-- nobody holds two active incarcerations
SELECT citizenid, COUNT(*) n FROM pf_justice_orders WHERE kind IN ('jail','prison','remand') AND state = 'active' GROUP BY citizenid HAVING n > 1;
-- every open legacy injury imported
SELECT COUNT(*) FROM player_injuries p LEFT JOIN pf_med_injuries m ON m.legacy_id = p.id WHERE p.deleted_at IS NULL AND m.id IS NULL;
-- every evidence bag item has a row (run from the server console helper in 15D, inventories are JSON)
```
