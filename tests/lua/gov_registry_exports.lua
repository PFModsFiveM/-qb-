-- Serves pf-government's real registry exports (server/registry_views.lua) to a spec that does
-- not load all of pf-government. Load it after the spec has set Mock.exportsByResource['pf-government'].
-- On a real database it also adds the columns pf-government adds at start (EnsureBusinessSchema).
local saved = Mock.exportsByResource['__self']
Mock.exportsByResource['__self'] = {}
load_resource('[pfscripts]/pf-government/server/registry_views.lua')
Mock.exportsByResource['__self'] = saved
Mock.exportsByResource['pf-government'] = Mock.exportsByResource['pf-government'] or {}
for _, name in ipairs({ 'GetBusiness', 'GetBusinessesOwnedBy', 'ListBusinesses' }) do
    Mock.exportsByResource['pf-government'][name] = function(_, ...) return PFGovRegistry[name](...) end
end
if RealDB then
    pcall(MySQL.query.await, 'ALTER TABLE pf_gov_businesses ADD COLUMN IF NOT EXISTS account_ref VARCHAR(96) NULL DEFAULT NULL')
    pcall(MySQL.query.await, "ALTER TABLE pf_gov_businesses ADD COLUMN IF NOT EXISTS business_status ENUM('active', 'closed') NOT NULL DEFAULT 'active'")
end
