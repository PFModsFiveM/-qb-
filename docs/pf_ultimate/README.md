# PF Ultimate: police, EMS, medical, justice and corrections overhaul

Planning documents for the overhaul of police, EMS, the medical engine, hospitals, evidence, the MDTs, booking/jail,
prison/corrections, community service, courts/probation/parole and department management. Written 2026-11-03.

| File | Read it for |
|---|---|
| `PF_ULTIMATE_SYSTEM_PLAN.md` | Vision, scope, principles, the lead's batch procedure, and **batches 15-22 with every work unit** (owned files, interfaces, acceptance tests, dependencies) |
| `PF_ARCHITECTURE.md` | **Who owns which state**, module layout, every new export/event/callback contract, state machines, security, sync, performance, compatibility (legacy names), honest limits, clinical models |
| `PF_DATABASE_MIGRATIONS.md` | Every new table with keys and indexes, migration keys and version numbers per resource, legacy tables, data migration order, verification queries |
| `PF_INTEGRATION_MATRIX.md` | How each domain uses government, the ledger, inventory, jobs, restaurants, supplies, mechanics, vehicles, housing, business, phone, devices, doorlock and dispatch |
| `PF_IMPLEMENTATION_PROGRESS.md` | Status of every feature and the **development journal** (start a new session there) |
| `PF_TEST_REPORT.md` | How testing works here, the baseline, per-batch results, the live-server checklist |
| `PF_REMAINING_WORK.md` | Blockers, **open decisions for the owner**, concerns, unscheduled work, next steps |

An implementing agent needs: the lead's `AGENT_CONTEXT.md` (repo rules, test harness, ledger rules; kept in the
lead's session scratchpad, and summarised in plan section 4), its unit section in the plan, `PF_ARCHITECTURE.md`,
and its tables in `PF_DATABASE_MIGRATIONS.md`.

Related docs one level up: `MASTER_IMPLEMENTATION_CHECKLIST.md`, `IMPLEMENTATION_REPORT.md`, `JOB_LINKS.md`,
`DEVICES_AND_SERVICES.md`, `FINAL_TEST_PLAN.md`.
