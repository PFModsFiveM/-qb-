fx_version 'cerulean'
game 'gta5'
lua54 'yes'
author 'Kakarot'
description 'Various minigames that can be used for players to complete'
version '1.0.0'

client_scripts {
    'client/*.lua'
}

-- challenges the server issues and checks (API note at the top of the file)
server_script 'server/challenge.lua'

ui_page 'html/index.html'

files {
    'html/index.html',
    'html/css/*.css',
    'html/js/*.js',
    'html/sounds/*.ogg',
    'html/images/*.png',
}
