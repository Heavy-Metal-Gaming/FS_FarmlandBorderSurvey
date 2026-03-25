---
--- BorderScanner.lua
--- Scans the farmland density map (BitVectorMap) to extract border edge segments,
--- chains them into continuous polylines, simplifies with Douglas-Peucker, and
--- converts to world coordinates with terrain height.
---
--- The farmland density map is a raster image where each pixel value is a farmland ID.
--- Borders are detected where adjacent pixels have different farmland IDs.
---

BorderScanner = {}

--- Scan the density map for border edges of a specific farmland.
--- Returns a list of edge segments in bitmap coordinate space.
--- Each edge is {x1, z1, x2, z2} representing a grid-edge between two pixels.
---@param farmlandId number The farmland ID to scan for
---@return table edges List of {x1, z1, x2, z2} edge segments in bitmap coords
function BorderScanner.scanFarmlandEdges(farmlandId)
    local fm = g_farmlandManager
    if fm == nil or fm.localMap == nil then
        return {}
    end

    local map = fm.localMap
    local mapW = fm.localMapWidth
    local mapH = fm.localMapHeight
    local bits = fm.numberOfBits

    -- Use bounding box to limit scan area
    local farmland = fm:getFarmlandById(farmlandId)
    local startX, startZ, endX, endZ = 0, 0, mapW - 1, mapH - 1

    if farmland ~= nil and farmland.boundingBox ~= nil then
        local bb = farmland.boundingBox
        local terrainSize = g_currentMission.terrainSize
        local scale = mapW / terrainSize

        -- Convert world bounding box to bitmap coords (with 2-pixel margin)
        startX = math.max(0, math.floor((bb.minX + terrainSize * 0.5) * scale) - 2)
        startZ = math.max(0, math.floor((bb.minZ + terrainSize * 0.5) * scale) - 2)
        endX = math.min(mapW - 1, math.ceil((bb.maxX + terrainSize * 0.5) * scale) + 2)
        endZ = math.min(mapH - 1, math.ceil((bb.maxZ + terrainSize * 0.5) * scale) + 2)
    end

    local edges = {}

    for x = startX, endX do
        for z = startZ, endZ do
            local val = getBitVectorMapPoint(map, x, z, 0, bits)
            if val == farmlandId then
                -- Check RIGHT neighbor: vertical edge at x+1
                if x + 1 > endX or getBitVectorMapPoint(map, x + 1, z, 0, bits) ~= farmlandId then
                    edges[#edges + 1] = {x1 = x + 1, z1 = z, x2 = x + 1, z2 = z + 1}
                end
                -- Check LEFT neighbor: vertical edge at x
                if x - 1 < startX or getBitVectorMapPoint(map, x - 1, z, 0, bits) ~= farmlandId then
                    edges[#edges + 1] = {x1 = x, z1 = z + 1, x2 = x, z2 = z}
                end
                -- Check BOTTOM neighbor: horizontal edge at z+1
                if z + 1 > endZ or getBitVectorMapPoint(map, x, z + 1, 0, bits) ~= farmlandId then
                    edges[#edges + 1] = {x1 = x + 1, z1 = z + 1, x2 = x, z2 = z + 1}
                end
                -- Check TOP neighbor: horizontal edge at z
                if z - 1 < startZ or getBitVectorMapPoint(map, x, z - 1, 0, bits) ~= farmlandId then
                    edges[#edges + 1] = {x1 = x, z1 = z, x2 = x + 1, z2 = z}
                end
            end
        end
    end

    return edges
end

--- Chain individual edge segments into continuous polylines.
--- Edges are connected by matching endpoints to form ordered vertex lists.
---@param edges table List of {x1, z1, x2, z2} edge segments
---@return table polylines List of polylines, each a list of {x, z} vertices
function BorderScanner.chainEdges(edges)
    if #edges == 0 then
        return {}
    end

    -- Build endpoint adjacency map
    local adjMap = {}
    for i, e in ipairs(edges) do
        local k1 = e.x1 .. "," .. e.z1
        local k2 = e.x2 .. "," .. e.z2
        if adjMap[k1] == nil then adjMap[k1] = {} end
        if adjMap[k2] == nil then adjMap[k2] = {} end
        adjMap[k1][#adjMap[k1] + 1] = i
        adjMap[k2][#adjMap[k2] + 1] = i
    end

    local used = {}
    local polylines = {}

    for startIdx, e in ipairs(edges) do
        if not used[startIdx] then
            used[startIdx] = true

            -- Start a new chain
            local chain = {{x = e.x1, z = e.z1}, {x = e.x2, z = e.z2}}

            -- Extend forward from the chain's last point
            local extended = true
            while extended do
                extended = false
                local lastPt = chain[#chain]
                local key = lastPt.x .. "," .. lastPt.z
                local candidates = adjMap[key]
                if candidates ~= nil then
                    for _, idx in ipairs(candidates) do
                        if not used[idx] then
                            used[idx] = true
                            local ce = edges[idx]
                            local nextPt
                            if ce.x1 == lastPt.x and ce.z1 == lastPt.z then
                                nextPt = {x = ce.x2, z = ce.z2}
                            else
                                nextPt = {x = ce.x1, z = ce.z1}
                            end
                            chain[#chain + 1] = nextPt
                            extended = true
                            break
                        end
                    end
                end
            end

            -- Extend backward from the chain's first point
            extended = true
            while extended do
                extended = false
                local firstPt = chain[1]
                local key = firstPt.x .. "," .. firstPt.z
                local candidates = adjMap[key]
                if candidates ~= nil then
                    for _, idx in ipairs(candidates) do
                        if not used[idx] then
                            used[idx] = true
                            local ce = edges[idx]
                            local prevPt
                            if ce.x2 == firstPt.x and ce.z2 == firstPt.z then
                                prevPt = {x = ce.x1, z = ce.z1}
                            else
                                prevPt = {x = ce.x2, z = ce.z2}
                            end
                            table.insert(chain, 1, prevPt)
                            extended = true
                            break
                        end
                    end
                end
            end

            polylines[#polylines + 1] = chain
        end
    end

    return polylines
end

--- Perpendicular distance from a point to a line segment (for Douglas-Peucker).
---@param px number Point X
---@param pz number Point Z
---@param ax number Line start X
---@param az number Line start Z
---@param bx number Line end X
---@param bz number Line end Z
---@return number distance Perpendicular distance
function BorderScanner.perpendicularDistance(px, pz, ax, az, bx, bz)
    local dx = bx - ax
    local dz = bz - az
    local lenSq = dx * dx + dz * dz

    if lenSq == 0 then
        -- Degenerate segment: distance to point
        local ddx = px - ax
        local ddz = pz - az
        return math.sqrt(ddx * ddx + ddz * ddz)
    end

    -- Project point onto line, clamp to segment
    local t = ((px - ax) * dx + (pz - az) * dz) / lenSq
    t = math.max(0, math.min(1, t))

    local projX = ax + t * dx
    local projZ = az + t * dz
    local ddx = px - projX
    local ddz = pz - projZ

    return math.sqrt(ddx * ddx + ddz * ddz)
end

--- Douglas-Peucker polyline simplification.
--- Reduces vertex count while preserving shape within the given tolerance.
---@param polyline table List of {x, z} vertices
---@param tolerance number Maximum allowed perpendicular distance (in bitmap units)
---@return table simplified Simplified polyline
function BorderScanner.simplifyPolyline(polyline, tolerance)
    if #polyline <= 2 then
        return polyline
    end

    -- Find the point with maximum distance from the line between first and last
    local maxDist = 0
    local maxIdx = 1
    local first = polyline[1]
    local last = polyline[#polyline]

    for i = 2, #polyline - 1 do
        local d = BorderScanner.perpendicularDistance(
            polyline[i].x, polyline[i].z,
            first.x, first.z,
            last.x, last.z
        )
        if d > maxDist then
            maxDist = d
            maxIdx = i
        end
    end

    if maxDist > tolerance then
        -- Split and recurse
        local left = {}
        for i = 1, maxIdx do
            left[#left + 1] = polyline[i]
        end
        local right = {}
        for i = maxIdx, #polyline do
            right[#right + 1] = polyline[i]
        end

        local simplifiedLeft = BorderScanner.simplifyPolyline(left, tolerance)
        local simplifiedRight = BorderScanner.simplifyPolyline(right, tolerance)

        -- Merge (skip duplicate junction point)
        local result = {}
        for i = 1, #simplifiedLeft - 1 do
            result[#result + 1] = simplifiedLeft[i]
        end
        for i = 1, #simplifiedRight do
            result[#result + 1] = simplifiedRight[i]
        end
        return result
    else
        -- All points within tolerance: keep only first and last
        return {first, last}
    end
end

--- Convert bitmap-coordinate polylines to world-coordinate polylines with terrain height.
--- Each point stores ground-level Y and top Y (ground + heightOffset) so renderers
--- can draw a ribbon/wall from the terrain surface up to the specified height.
---@param polylines table List of polylines in bitmap coords (each is list of {x, z})
---@param heightOffset number Height above terrain in meters
---@return table worldPolylines List of polylines in world coords (each is list of {x, yGround, yTop, z})
function BorderScanner.toWorldCoords(polylines, heightOffset)
    local fm = g_farmlandManager
    if fm == nil then return {} end

    local mapW = fm.localMapWidth
    local mapH = fm.localMapHeight
    local terrainSize = g_currentMission.terrainSize
    local scaleX = terrainSize / mapW
    local scaleZ = terrainSize / mapH
    local terrainNode = g_currentMission.terrainRootNode

    local worldPolylines = {}

    for i, polyline in ipairs(polylines) do
        local worldPoly = {}
        for j, pt in ipairs(polyline) do
            -- GIANTS pixel (x,z) is centered at integer coords; its cell spans
            -- (x-0.5, z-0.5) to (x+0.5, z+0.5).  Our edge detection places
            -- edges at integer bitmap coords (e.g. x+1 for the right edge of
            -- pixel x), but the true cell boundary is at x+0.5.  Subtracting
            -- 0.5 from every coordinate realigns our edges with the game's
            -- pixel-cell boundaries (confirmed via FarmlandManager source).
            local wx = (pt.x - 0.5 - mapW * 0.5) * scaleX
            local wz = (pt.z - 0.5 - mapH * 0.5) * scaleZ
            local wyGround = getTerrainHeightAtWorldPos(terrainNode, wx, 0, wz)
            local wyTop = wyGround + heightOffset

            worldPoly[#worldPoly + 1] = {x = wx, yGround = wyGround, yTop = wyTop, z = wz}
        end
        worldPolylines[#worldPolylines + 1] = worldPoly
    end

    return worldPolylines
end
