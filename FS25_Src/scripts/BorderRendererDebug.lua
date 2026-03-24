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

--- Maximum sub-segment length for terrain following (meters).
BorderRendererDebug.MAX_SUB_SEGMENT_LENGTH = 4.0

--- Draw all cached border ribbons for owned farmlands.
--- Called every frame from PropertyBorders:draw() when renderMode == "debug".
--- Long segments are subdivided so the lines closely follow terrain undulations.
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
    local maxSubLen = BorderRendererDebug.MAX_SUB_SEGMENT_LENGTH
    local heightOffset = mod.settings.height

    local terrainNode = g_currentMission.terrainRootNode

    for farmlandId, polylines in pairs(mod.borderCache) do
        for _, polyline in ipairs(polylines) do
            for i = 1, #polyline - 1 do
                local p1 = polyline[i]
                local p2 = polyline[i + 1]

                -- Subdivide long segments for better terrain following
                local dx = p2.x - p1.x
                local dz = p2.z - p1.z
                local segLen = math.sqrt(dx * dx + dz * dz)
                local numSubs = math.max(1, math.ceil(segLen / maxSubLen))

                for s = 0, numSubs - 1 do
                    local t0 = s / numSubs
                    local t1 = (s + 1) / numSubs

                    local sx1 = p1.x + dx * t0
                    local sz1 = p1.z + dz * t0
                    local sx2 = p1.x + dx * t1
                    local sz2 = p1.z + dz * t1

                    -- Sample terrain at each sub-segment endpoint
                    local ground1 = getTerrainHeightAtWorldPos(terrainNode, sx1, 0, sz1)
                    local ground2 = getTerrainHeightAtWorldPos(terrainNode, sx2, 0, sz2)
                    local top1 = ground1 + heightOffset
                    local top2 = ground2 + heightOffset

                    -- Draw ribbon body: horizontal lines from ground to top
                    for f = 0, fillLines do
                        local ft = f / fillLines
                        local y1 = ground1 + (top1 - ground1) * ft
                        local y2 = ground2 + (top2 - ground2) * ft

                        -- Fade color: dimmer at ground, brighter at top
                        local fade = 0.3 + 0.7 * ft
                        local lr = bodyR * fade
                        local lg = bodyG * fade
                        local lb = bodyB * fade

                        drawDebugLine(
                            sx1, y1, sz1,  lr, lg, lb,
                            sx2, y2, sz2,  lr, lg, lb
                        )
                    end

                    -- Draw vertical edges at start of sub-segment
                    drawDebugLine(
                        sx1, ground1, sz1,  bodyR * 0.3, bodyG * 0.3, bodyB * 0.3,
                        sx1, top1, sz1,     bodyR, bodyG, bodyB
                    )

                    -- Draw top glow line (thicker = multiple offset lines)
                    for gl = 0, glowLines - 1 do
                        local yOff = gl * glowSpacing
                        drawDebugLine(
                            sx1, top1 + yOff, sz1,  glowR, glowG, glowB,
                            sx2, top2 + yOff, sz2,  glowR, glowG, glowB
                        )
                    end
                end
            end
        end
    end
end
