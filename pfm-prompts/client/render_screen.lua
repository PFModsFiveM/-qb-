-- pfm-prompts: the fallback renderer. 2D text and a key box at each prompt's projected point
-- (SetDrawOrigin), used when the game refuses the DUI textures or Config.Renderer / the convar
-- pfm_prompts_renderer says 'screen'. Not depth-tested (a wall does not hide it).
--
-- On a pad the key is drawn as GTA's own token ("~INPUT_PICKUP~"), which the game renders as the
-- right button for the layout in use; on a keyboard as the key's letter in a box.
--
-- Same input as the world renderer (the registry's `visible`), and the same rule in the draw path:
-- no table or string is made per frame (the words were made on the score frame).

local R = { name = 'screen' }

local alpha = {}         -- [vkey] = 0..1, eased toward the state's opacity
local tokens = {}        -- [control] = '~INPUT_X~' or false
local DOT = 'dot'

local function tokenFor(control)
    local t = tokens[control]
    if t == nil then
        t = PromptKeys.inputToken(control) or false
        tokens[control] = t
    end
    return t
end

local function text(str, x, y, scale, r, g, b, a, centre, font)
    SetTextFont(font)
    SetTextScale(scale, scale)
    SetTextColour(r, g, b, a)
    SetTextOutline()
    SetTextCentre(centre)
    BeginTextCommandDisplayText('STRING')
    AddTextComponentSubstringPlayerName(str)
    EndTextCommandDisplayText(x, y)
end

function R.attach() return true end
function R.detach() alpha = {} end
function R.clear() alpha = {} end
function R.busy() return false end

---@param visible table  [vkey] = entry
---@param isScoreFrame boolean
---@param now number
function R.frame(visible, isScoreFrame, now)
    local cfg = Config.Screen or {}
    local st = PromptStyle.get()
    local font = cfg.font or 4
    local ts, ss = cfg.textScale or 0.36, cfg.sublabelScale or 0.30
    local kw, kh = (cfg.keyBox or {}).w or 0.018, (cfg.keyBox or {}).h or 0.03
    local dot = cfg.dotSize or 0.006
    local dt = GetFrameTime()
    if dt <= 0.0 then dt = 1.0 / 60.0 end
    local pad = PromptKeys.padActive(now)

    if isScoreFrame then
        for vkey in pairs(alpha) do
            if not visible[vkey] then alpha[vkey] = nil end
        end
    end

    for vkey, e in pairs(visible) do
        local target = PromptStyle.alpha(st, e.focused, e.active)
        local cur = alpha[vkey] or 0.0
        local step = st.fade > 0 and dt / st.fade or 1.0
        if step >= 1.0 then cur = target else cur = cur + (target - cur) * step end
        alpha[vkey] = cur
        local a = math.floor(cur * 255 + 0.5)

        if a > 0 then
            SetDrawOrigin(e.x, e.y, e.z, 0)
            if e.focused then
                local token = pad and tokenFor(e.control) or false
                if token then
                    text(token, 0.0, -0.014, ts, 255, 255, 255, a, true, font)
                else
                    DrawRect(0.0, 0.0, kw, kh, 255, 255, 255, a)
                    text(e.glyph, 0.0, -0.013, ts, 15, 17, 21, a, true, font)
                end
                if e.holdP then
                    DrawRect(0.0, kh * 0.5 + 0.004, kw, 0.004, 0, 0, 0, math.floor(a * 0.6))
                    DrawRect(-kw * 0.5 + kw * e.holdP * 0.5, kh * 0.5 + 0.004, kw * e.holdP, 0.004,
                        st.holdR, st.holdG, st.holdB, a)
                end
            elseif e.active and not e.actionable then
                DrawRect(0.0, 0.0, dot * 1.6, dot * 2.8, 27, 31, 38, a)
            elseif e.active then
                DrawRect(0.0, 0.0, dot * 1.4, dot * 2.5, 255, 255, 255, a)
            else
                DrawRect(0.0, 0.0, dot, dot * 1.8, 255, 255, 255, a)
            end

            if e.wantLabel then
                local x = kw * 0.5 + 0.006
                if e.label ~= '' then
                    SetTextJustification(1)
                    text(e.label, x, -0.016, ts, 255, 255, 255, a, false, font)
                    if e.sublabel ~= '' then
                        text(e.sublabel, x, 0.004, ss, 180, 186, 198, a, false, font)
                    end
                elseif e.sublabel ~= '' then
                    text(e.sublabel, x - kw * 0.5, -0.013, ts, 180, 186, 198, a, false, font)
                end
                -- The other options, dimmed, above and below in their order.
                if e.focused and (e.availN or 1) > 1 then
                    local labels = e.optLabels
                    for k = 1, e.availN do
                        if k ~= e.sel and labels[k] and labels[k] ~= '' then
                            text(labels[k], x, -0.016 + (k - e.sel) * 0.026, ts * 0.9, 255, 255, 255,
                                math.floor(a * st.stackAlpha), false, font)
                        end
                    end
                end
            end
            ClearDrawOrigin()
        end
    end
end

PromptRenderers.screen = R
