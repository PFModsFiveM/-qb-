-- PF copy of the owner's progressbar (resource name kept). Patched for sv_stateBagStrictMode:
-- a bar holds pfm-inventory's 'progressbar' action lock instead of writing inv_busy itself.
fx_version 'cerulean'
lua54 'yes'
game 'gta5'

author 'qbcore-framework'
description 'Dependency for creating progressbars in QB-Core.'
version '1.0.0'

ui_page 'html/index.html'

client_script 'client.lua'

files {
    'html/index.html',
    'html/style.css',
    'html/script.js'
}
