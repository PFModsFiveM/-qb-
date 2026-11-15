-- Copyright (c) 2026 Whippy, from WHIP, LGPL-3.0; modified for PF.
-- (WHIP whip_core/client/world_quad.lua, renamed: WorldQuad -> PromptQuad.)
--
-- ============================================
-- PROMPT QUAD: one textured rectangle in 3D space
-- ============================================
--
-- The primitive the world renderer is built from. A rectangle placed by a CENTRE and two BASIS
-- VECTORS, so the caller decides which way it faces:
--
--   right / up from the camera   -> a billboard that turns to face the player (prompts)
--   right / up from a heading    -> a sign fixed to a surface
--
-- WHY POLYGONS RATHER THAN NUI. These depth-test: a quad behind a wall is hidden by the wall, and the
-- position comes from the same frame as the camera that renders it.
--
-- NO STATE, NO ALLOCATION, NO NATIVE CALLS BUT THE TWO DRAWS. It runs once per quad per frame.

PromptQuad = {}

--- One textured quad, as two triangles.
---
--- The winding below is the REVERSED order, which is the one that renders (found in game: the other
--- way round, backface culling makes the quad invisible from the side you stand on). The third
--- texture coordinate is 0: it is undocumented for a flat 2D texture and 0 is what works.
---@param txd string  runtime texture dictionary name
---@param tex string  texture name within it
---@param cx number @param cy number @param cz number  centre, world space
---@param rx number @param ry number @param rz number  RIGHT basis vector, unit length
---@param ux number @param uy number @param uz number  UP basis vector, unit length
---@param w number  width in metres, along `right`
---@param h number  height in metres, along `up`
---@param u0 number @param v0 number @param u1 number @param v1 number  UV rect (atlas cell)
---@param a number   alpha 0-255
---@param tr number @param tg number @param tb number  tint, multiplied into the texture
function PromptQuad.draw(txd, tex, cx, cy, cz, rx, ry, rz, ux, uy, uz, w, h, u0, v0, u1, v1, a, tr, tg, tb)
    local hw, hh = w * 0.5, h * 0.5
    local hx, hy, hz = rx * hw, ry * hw, rz * hw
    local gx, gy, gz = ux * hh, uy * hh, uz * hh

    local tlx, tly, tlz = cx + gx - hx, cy + gy - hy, cz + gz - hz
    local trx, try_, trz = cx + gx + hx, cy + gy + hy, cz + gz + hz
    local blx, bly, blz = cx - gx - hx, cy - gy - hy, cz - gz - hz
    local brx, bry, brz = cx - gx + hx, cy - gy + hy, cz - gz + hz

    DrawTexturedPoly(
        tlx, tly, tlz,  blx, bly, blz,  trx, try_, trz,
        tr, tg, tb, a, txd, tex,
        u0, v0, 0.0,  u0, v1, 0.0,  u1, v0, 0.0
    )
    DrawTexturedPoly(
        trx, try_, trz,  blx, bly, blz,  brx, bry, brz,
        tr, tg, tb, a, txd, tex,
        u1, v0, 0.0,  u0, v1, 0.0,  u1, v1, 0.0
    )
end

--- Camera forward direction as a unit vector (three numbers, no vector allocated).
---@return number fx, number fy, number fz
function PromptCameraForward()
    local rot = GetFinalRenderedCamRot(2)
    local rX = math.rad(rot.x)
    local rZ = math.rad(rot.z)
    local cosX = math.abs(math.cos(rX))
    return -math.sin(rZ) * cosX, math.cos(rZ) * cosX, math.sin(rX)
end

--- The basis for a BILLBOARD: parallel to the screen, never rolling.
---
--- It faces the camera's PLANE, not its position: aiming each quad at the camera tilted the ones near
--- the screen edges. Right is taken against world-up, so it stays level; up follows from right and
--- forward, so the quad pitches as you look up or down but never leans with the camera. Compute it
--- once per frame and share it between every quad drawn that frame.
---@param fx number|nil @param fy number|nil @param fz number|nil  the camera's forward, if read already
---@return number rx, number ry, number rz, number ux, number uy, number uz
function PromptQuad.billboardBasis(fx, fy, fz)
    if not fx then fx, fy, fz = PromptCameraForward() end

    -- right = forward x world-up
    local rx, ry, rz = fy, -fx, 0.0
    local len = math.sqrt(rx * rx + ry * ry)
    if len < 0.001 then
        -- Looking straight up or down: no horizontal right exists, so use the camera's yaw.
        local h = math.rad(GetFinalRenderedCamRot(2).z)
        rx, ry = math.cos(h), math.sin(h)
    else
        rx, ry = rx / len, ry / len
    end

    -- up = right x forward
    local ux, uy, uz = ry * fz - rz * fy, rz * fx - rx * fz, rx * fy - ry * fx
    local ulen = math.sqrt(ux * ux + uy * uy + uz * uz)
    if ulen < 0.00001 then return rx, ry, rz, 0.0, 0.0, 0.0 end
    return rx, ry, rz, ux / ulen, uy / ulen, uz / ulen
end
