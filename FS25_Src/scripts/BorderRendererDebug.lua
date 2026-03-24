---
--- BorderRendererDebug.lua
--- Renders property borders as a semi-transparent ribbon (wall) from ground
--- to the configured height, with a brighter/thicker glow line at the top.
---
--- Uses drawDebugLine (immediate-mode, per-frame).
---
--- NOTE: drawDebugLine does NOT support depth testing; debug lines always
--- render on top of geometry.  For depth-tested (occluded) borders switch
--- to renderMode = "mesh", which uses real 3D shapes.
---

BorderRendererDebug = {}

--- Number of horizontal lines to fill the ribbon body (creates vertical fill effect).
BorderRendererDebug.RIBBON_FILL_LINES = 6
--- Number of extra lines drawn for the thicker glow at the top.
BorderRendererDebug.TOP_GLOW_LINES = 3
--- Vertical offset between each glow line at the top (meters).
BorderRendererDebug.TOP_GLOW_SPACING = 0.02

--- Draw all cached border ribbons for owned farmlands.
--- Called every frame from PropertyBorders:draw() when renderMode == "debug".
---@param mod table The PropertyBorders mod instance
function BorderRendererDebug.draw(mod)
    local color = mod.settings.color
    local r, g, b, a = color[1], color[2], color[3], color[4] or 0.4
    -- Dimmed color for the ribbon body (more transparent)
    local bodyR, bodyG, bodyB = r * 0.5, g * 0.5, b * 0.5

    -- Bright color for the top glow line
    local glowR = math.min(1.0, r * 1.4 + 0.1)
    local glowG = math.min(1.0, g * 1.4 + 0.1)
    local glowB = math.min(1.0, b * 1.4 + 0.1)

    local fillLines = BorderRendererDebug.RIBBON_FILL_LINES
    local glowLines = BorderRendererDebug.TOP_GLOW_LINES
    local glowSpacing = BorderRendererDebug.TOP_GLOW_SPACING

    for farmlandId, polylines in pairs(mod.borderCache) do
        for _, polyline in ipairs(polylines) do
            for i = 1, #polyline - 1 do
                local p1 = polyline[i]
                local p2 = polyline[i + 1]

                local p1Ground = p1.yGround
                local p1Top = p1.yTop
                local p2Ground = p2.yGround
                local p2Top = p2.yTop

                -- Draw ribbon body: horizontal lines from ground to top
                for f = 0, fillLines do
                    local t = f / fillLines
                    local y1 = p1Ground + (p1Top - p1Ground) * t
                    local y2 = p2Ground + (p2Top - p2Ground) * t

                    -- Fade color: dimmer at ground, brighter at top
                    local fade = 0.3 + 0.7 * t
                    local lr = bodyR * fade
                    local lg = bodyG * fade
                    local lb = bodyB * fade

                    drawDebugLine(
                        p1.x, y1, p1.z,  lr, lg, lb,
                        p2.x, y2, p2.z,  lr, lg, lb
                    )
                end

                -- Draw vertical edges at each vertex for ribbon structure
                drawDebugLine(
                    p1.x, p1Ground, p1.z,  bodyR * 0.3, bodyG * 0.3, bodyB * 0.3,
                    p1.x, p1Top, p1.z,     bodyR, bodyG, bodyB
                )

                -- Draw top glow line (thicker = multiple offset lines)
                for g = 0, glowLines - 1 do
                    local yOff = g * glowSpacing
                    drawDebugLine(
                        p1.x, p1Top + yOff, p1.z,  glowR, glowG, glowB,
                        p2.x, p2Top + yOff, p2.z,  glowR, glowG, glowB
                    )
                end
            end
        end
    end
end
