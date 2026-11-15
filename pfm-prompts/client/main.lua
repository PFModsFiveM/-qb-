-- pfm-prompts: the loop, the renderer choice and the exports.
-- Copyright (c) 2026 Whippy, from WHIP, LGPL-3.0; modified for PF.
-- (The pass loop and per-resource cleanup follow WHIP whip_core/client/interact.lua.)

local M = PfmPrompts

--- Which renderer: the convar, else Config.Renderer. 'world' falls back to 'screen' if the game
--- refuses its textures.
local function chooseRenderer()
    local want = GetConvar('pfm_prompts_renderer', '')
    if want ~= 'world' and want ~= 'screen' then want = Config.Renderer end
    if want ~= 'screen' then want = 'world' end
    local R = PromptRenderers[want]
    if want == 'world' and not R.attach() then
        R = PromptRenderers.screen
    end
    R.attach()
    return R
end

local function setRenderer(name)
    if M.renderer then
        if M.renderer.clear then M.renderer.clear() end
        if M.renderer.detach then M.renderer.detach() end
    end
    local R = PromptRenderers[name]
    if not R or not R.attach() then R = PromptRenderers.screen; R.attach() end
    M.renderer = R
    M.scoreSoon()
    return R.name
end

CreateThread(function()
    M.renderer = chooseRenderer()
    -- Each pass under pcall, so one bad value from another resource cannot end the loop.
    local failures = 0
    while true do
        local ok, res = pcall(M.tick, GetGameTimer())
        if ok then
            Wait(res or 0)
        else
            failures = failures + 1
            if failures <= 3 then print(('[pfm-prompts] error in the prompt loop (it keeps running): %s'):format(tostring(res))) end
            Wait(500)
        end
    end
end)

-- /pfmprompts_renderer world|screen: switch live to compare.
RegisterCommand('pfmprompts_renderer', function(_, args)
    local name = args and args[1]
    if name ~= 'world' and name ~= 'screen' then
        print(('[pfm-prompts] renderer: %s (use world or screen)'):format(M.renderer and M.renderer.name or 'none'))
        return
    end
    print(('[pfm-prompts] renderer now: %s'):format(setRenderer(name)))
end, false)

-- Cleanup: a stopping resource's prompts go with it; this resource's stop gives the browsers back.
AddEventHandler('onResourceStop', function(res)
    if res == GetCurrentResourceName() then
        M.clear()
        if M.renderer and M.renderer.detach then M.renderer.detach() end
        PromptDui.releaseAll()
        return
    end
    M.removeAllFor(res)
end)

-- Exports. A function passed in (canInteract, onPress) arrives as a funcref and is called as one.
exports('Add', function(id, def) return M.add(id, def) end)
exports('Update', function(id, patch) return M.update(id, patch) end)
exports('Remove', function(id) return M.remove(id) end)
exports('RemoveAllFor', function(resource)
    return M.removeAllFor(resource or GetInvokingResource() or GetCurrentResourceName())
end)
exports('Exists', function(id) return M.exists(id) end)
exports('Flash', function(id, r, g, b) return M.flash(id, r, g, b) end)
exports('GetFocused', function() return M.getFocused() end)
exports('GetRenderer', function() return M.renderer and M.renderer.name or nil end)
