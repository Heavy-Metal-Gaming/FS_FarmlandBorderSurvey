---
--- BorderRendererMesh.lua
--- Renders property borders as depth-tested vertical ribbon walls from the
--- terrain surface up to a configurable height, with a glowing cap at the top.
---
--- Approach:  A flat quad is created programmatically via
--- createPlaneShapeFrom2DContour(), then the additive_colorScale material
--- from the game's glowShader is applied so we get colour-controllable
--- glow.  Long border segments are subdivided into short (~4 m) sub-
--- segments so each piece individually samples terrain height and follows
--- uneven ground, creating a continuous ribbon effect.
---
--- Because these are real 3D shapes they participate in the normal depth
--- pipeline — objects between the camera and the border occlude them.
---

BorderRendererMesh = {}

--- Height of the glow-cap strip at the top of the ribbon (meters).
BorderRendererMesh.GLOW_CAP_HEIGHT = 0.06

--- Maximum length of a single wall sub-segment (meters).
--- Shorter = smoother terrain following but more draw calls.
BorderRendererMesh.MAX_SUB_SEGMENT_LENGTH = 4.0

---------------------------------------------------------------------------
-- Initialisation
---------------------------------------------------------------------------

--- Create the template wall quad programmatically and borrow the glowShader
--- material from a known-working game shape.
---@param modDir string  Mod directory path (with trailing slash)
---@return boolean success
function BorderRendererMesh.init(modDir)
    BorderRendererMesh.templateNode     = nil
    BorderRendererMesh.materialLoaded   = false
    BorderRendererMesh.rootNode         = nil
    BorderRendererMesh.farmlandNodes    = {}   -- farmlandId -> transformGroup
    BorderRendererMesh.sharedLoadReqId  = nil

    -- Step 1 -----------------------------------------------------------
    -- Load a known-good glowShader shape from game data to borrow its
    -- material.  The chainsawRingSelector uses glowShader.xml with the
    -- additive_colorScale variation — exactly what we need.
    local csRoot, csLoadId = g_i3DManager:loadSharedI3DFile(
        "$data/handTools/shared/treeCutters/chainsawRingSelector.i3d",
        false, false)

    if csRoot == nil or csRoot == 0 then
        Logging.warning("PropertyBorders: failed to load chainsawRingSelector.i3d for material")
        return false
    end

    local csShape = getChildAt(csRoot, 0)
    if csShape == nil or csShape == 0 then
        Logging.warning("PropertyBorders: chainsawRingSelector has no child shape")
        delete(csRoot)
        if csLoadId then g_i3DManager:releaseSharedI3DFile(csLoadId) end
        return false
    end

    -- Get the additive_colorScale glowShader material
    local glowMat = getMaterial(csShape, 0)
    Logging.info("PropertyBorders: glowMat=%s from chainsawRingSelector", tostring(glowMat))

    if glowMat == nil or glowMat == 0 then
        Logging.warning("PropertyBorders: failed to get material from chainsawRingSelector")
        delete(csRoot)
        if csLoadId then g_i3DManager:releaseSharedI3DFile(csLoadId) end
        return false
    end

    -- Step 2 -----------------------------------------------------------
    -- Create a unit quad in the XZ plane using the engine's contour API.
    -- Four corners of a 1×1 square centred at the origin.
    local quadNode = createPlaneShapeFrom2DContour(
        "borderQuad",
        {-0.5, -0.5,  0.5, -0.5,  0.5, 0.5,  -0.5, 0.5},
        false)

    if quadNode == nil or quadNode == 0 then
        Logging.warning("PropertyBorders: createPlaneShapeFrom2DContour failed")
        delete(csRoot)
        if csLoadId then g_i3DManager:releaseSharedI3DFile(csLoadId) end
        return false
    end

    Logging.info("PropertyBorders: created contour quad=%s", tostring(quadNode))

    -- Step 3 -----------------------------------------------------------
    -- Apply the glowShader material to our quad so it gets the
    -- additive_colorScale variation with colorScale & lightControl params.
    setMaterial(quadNode, glowMat, 0)

    -- Verify shader params are now available
    local hasCS = getHasShaderParameter(quadNode, "colorScale")
    local hasLC = getHasShaderParameter(quadNode, "lightControl")
    Logging.info("PropertyBorders: quad hasColorScale=%s, hasLightControl=%s",
        tostring(hasCS), tostring(hasLC))

    -- Done with the reference shape
    delete(csRoot)
    BorderRendererMesh.csLoadId = csLoadId  -- keep for cleanup

    if not hasCS then
        Logging.warning("PropertyBorders: quad has no colorScale after setMaterial — "
            .. "falling back to debug mode")
        delete(quadNode)
        if csLoadId then g_i3DManager:releaseSharedI3DFile(csLoadId) end
        return false
    end

    -- The quad is XZ-flat ⇒ we must rotate 90° around X to stand it up.
    BorderRendererMesh.needsXRotation = true

    -- Set some sane defaults
    setVisibility(quadNode, false)
    setShaderParameter(quadNode, "lightControl", 1.0, 0, 0, 0, false)
    setShaderParameter(quadNode, "colorScale",   1, 1, 1, 0, false)

    BorderRendererMesh.templateNode   = quadNode
    BorderRendererMesh.materialLoaded = true

    -- Root transform group that holds all border clones
    BorderRendererMesh.rootNode = createTransformGroup("propertyBordersRoot")
    link(getRootNode(), BorderRendererMesh.rootNode)

    -- Park the template under that root (keeps it alive)
    link(BorderRendererMesh.rootNode, BorderRendererMesh.templateNode)

    Logging.info("PropertyBorders: Mesh renderer init SUCCESS, templateNode=%s, rootNode=%s",
        tostring(BorderRendererMesh.templateNode), tostring(BorderRendererMesh.rootNode))

    return true
end

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

--- Clone the template quad, set its colour via shader parameter, and link
--- it under *parentNode*.
local function cloneQuad(parentNode, r, g, b, glowIntensity)
    local tmpl = BorderRendererMesh.templateNode
    if tmpl == nil then return nil end

    local c = clone(tmpl, false)
    if c == nil or c == 0 then return nil end

    setVisibility(c, true)
    link(parentNode, c)

    if getHasShaderParameter(c, "colorScale") then
        setShaderParameter(c, "colorScale", r, g, b, 0, false)
    end
    if getHasShaderParameter(c, "lightControl") then
        setShaderParameter(c, "lightControl", glowIntensity, 0, 0, 0, false)
    end

    return c
end

--- Position / rotate / scale a wall clone so it forms a vertical wall
--- between two world-space XZ points, from yBottom to yTop.
local function placeWall(node, x1, z1, x2, z2, yBottom, yTop)
    local dx = x2 - x1
    local dz = z2 - z1
    local segLen = math.sqrt(dx * dx + dz * dz)
    local wallH  = yTop - yBottom

    if segLen < 0.001 or wallH < 0.001 then
        setVisibility(node, false)
        return
    end

    local mx = (x1 + x2) * 0.5
    local mz = (z1 + z2) * 0.5
    local midY = (yBottom + yTop) * 0.5
    local ry = math.atan2(dx, dz)

    -- Centre the wall vertically between yBottom and yTop.
    setTranslation(node, mx, midY, mz)

    if BorderRendererMesh.needsXRotation then
        -- XZ-flat quad: rotate 90° around X to stand up, then Y for heading.
        -- Scale X = segment length, Z = wall height (Z becomes Y after rotation).
        setRotation(node, math.rad(90), ry, 0)
        setScale(node, segLen, 1, wallH)
    else
        -- Already vertical (XY plane): just rotate around Y.
        setRotation(node, 0, ry, 0)
        setScale(node, segLen, wallH, 1)
    end
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------

--- Build ribbon meshes for one farmland.
--- Long segments are subdivided so each piece follows terrain individually.
function BorderRendererMesh.createForFarmland(farmlandId, polylines, color, stripWidth)
    if not BorderRendererMesh.materialLoaded or BorderRendererMesh.rootNode == nil then
        return
    end

    local totalClones = 0
    local loggedFirst = false

    -- Remove previous meshes for this farmland
    BorderRendererMesh.removeForFarmland(farmlandId)

    local farmTG = createTransformGroup("borderFarmland_" .. farmlandId)
    link(BorderRendererMesh.rootNode, farmTG)
    BorderRendererMesh.farmlandNodes[farmlandId] = farmTG

    local r, g, b = color[1], color[2], color[3]
    local bodyR, bodyG, bodyB = r * 0.6, g * 0.6, b * 0.6
    local bodyGlow = 1.5
    local capR = math.min(1, r * 1.5 + 0.15)
    local capG = math.min(1, g * 1.5 + 0.15)
    local capB = math.min(1, b * 1.5 + 0.15)
    local capGlow = 4.0
    local capH = BorderRendererMesh.GLOW_CAP_HEIGHT

    local terrainNode = g_currentMission.terrainRootNode
    local heightOffset = PropertyBorders.settings.height
    local maxSubLen = BorderRendererMesh.MAX_SUB_SEGMENT_LENGTH

    for _, polyline in ipairs(polylines) do
        for i = 1, #polyline - 1 do
            local p1 = polyline[i]
            local p2 = polyline[i + 1]

            local dx = p2.x - p1.x
            local dz = p2.z - p1.z
            local fullLen = math.sqrt(dx * dx + dz * dz)
            if fullLen >= 0.01 then

            -- Number of sub-segments for this edge
            local numSubs = math.max(1, math.ceil(fullLen / maxSubLen))

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
                local avgGround = math.min(ground1, ground2)
                local avgTop = math.max(ground1, ground2) + heightOffset

                -- Body wall
                local bodyNode = cloneQuad(farmTG, bodyR, bodyG, bodyB, bodyGlow)
                if bodyNode then
                    placeWall(bodyNode, sx1, sz1, sx2, sz2, avgGround, avgTop)
                    totalClones = totalClones + 1
                    if not loggedFirst then
                        loggedFirst = true
                        Logging.info("PropertyBorders: first sub-seg (%.1f,%.1f)-(%.1f,%.1f) ground=%.1f top=%.1f node=%s needsXRot=%s",
                            sx1, sz1, sx2, sz2, avgGround, avgTop, tostring(bodyNode), tostring(BorderRendererMesh.needsXRotation))
                    end
                end

                -- Glow cap
                local capNode = cloneQuad(farmTG, capR, capG, capB, capGlow)
                if capNode then
                    placeWall(capNode, sx1, sz1, sx2, sz2, avgTop - capH, avgTop + capH)
                    totalClones = totalClones + 1
                end
            end

            end -- fullLen >= 0.01
        end
    end

    Logging.info("PropertyBorders: createForFarmland(%s) done - %d clones, %d polylines",
        tostring(farmlandId), totalClones, #polylines)
end

--- Remove all border meshes for one farmland.
function BorderRendererMesh.removeForFarmland(farmlandId)
    if BorderRendererMesh.farmlandNodes == nil then return end
    local node = BorderRendererMesh.farmlandNodes[farmlandId]
    if node ~= nil and entityExists(node) then
        delete(node)
    end
    BorderRendererMesh.farmlandNodes[farmlandId] = nil
end

--- Remove meshes for every farmland.
function BorderRendererMesh.removeAll()
    if BorderRendererMesh.farmlandNodes == nil then return end
    for fid, _ in pairs(BorderRendererMesh.farmlandNodes) do
        BorderRendererMesh.removeForFarmland(fid)
    end
    BorderRendererMesh.farmlandNodes = {}
end

--- Toggle visibility of all border meshes.
function BorderRendererMesh.setVisible(visible)
    if BorderRendererMesh.rootNode ~= nil and entityExists(BorderRendererMesh.rootNode) then
        setVisibility(BorderRendererMesh.rootNode, visible)
    end
end

--- Update colour for every existing border mesh clone.
function BorderRendererMesh.updateColor(color)
    if BorderRendererMesh.rootNode == nil then return end
    if BorderRendererMesh.farmlandNodes == nil then return end

    local r, g, b = color[1], color[2], color[3]

    for _, farmTG in pairs(BorderRendererMesh.farmlandNodes) do
        if farmTG ~= nil and entityExists(farmTG) then
            local n = getNumOfChildren(farmTG)
            for ci = 0, n - 1 do
                local child = getChildAt(farmTG, ci)
                if child ~= nil then
                    if getHasShaderParameter(child, "colorScale") then
                        setShaderParameter(child, "colorScale", r, g, b, 0, false)
                    end
                end
            end
        end
    end
end

--- Release every resource the mesh renderer owns.
function BorderRendererMesh.destroy()
    BorderRendererMesh.removeAll()

    if BorderRendererMesh.rootNode ~= nil and entityExists(BorderRendererMesh.rootNode) then
        delete(BorderRendererMesh.rootNode)
    end
    BorderRendererMesh.rootNode    = nil
    BorderRendererMesh.templateNode = nil

    if BorderRendererMesh.sharedLoadReqId ~= nil then
        g_i3DManager:releaseSharedI3DFile(BorderRendererMesh.sharedLoadReqId)
        BorderRendererMesh.sharedLoadReqId = nil
    end

    if BorderRendererMesh.csLoadId ~= nil then
        g_i3DManager:releaseSharedI3DFile(BorderRendererMesh.csLoadId)
        BorderRendererMesh.csLoadId = nil
    end

    BorderRendererMesh.materialLoaded = false
end
