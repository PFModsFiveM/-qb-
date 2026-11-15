-- pfm-ui theme: tells every PF page which theme resource the server picked.
-- Copyright (c) 2026 Whippy, from WHIP, LGPL-3.0; modified for PF (see NOTICE.md).
-- The client half of WHIP's Config.Theme, read from a replicated convar instead of a config file:
--
--     setr pf_ui_theme "my_theme"     -- server.cfg; unset or "" = the base look
--
-- html/theme.js (loaded by each page) posts to https://pfm-ui/theme and appends
-- https://cfx-nui-<name>/theme.css after the page's own styles. The name is checked again on the page.

local NAME = '^[%w_%-]+$'

local function themeName()
    local name = GetConvar('pf_ui_theme', '')
    if name == '' or #name > 64 or not name:match(NAME) then return false end
    return name
end

RegisterNUICallback('theme', function(_, cb)
    cb({ resource = themeName() })
end)

exports('GetTheme', themeName)
