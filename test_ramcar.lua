-- test_ramcar.lua
-- Adds a /ramcar command to spawn a traffic vehicle that will pathfollow and try to ram the player

local RAMMERS = {}
local RAMMER_BY_OWNER = {}

-- NOTE: If Bobcat model ID differs for your server, change BOBcat_MODEL below.
local BOBCAT_MODEL = 422 -- Bobcat model ID

local DEFAULT_RAM_DISTANCE = 500 -- start trying to ram when closer than this (increased)
local LOS_CHECK_HEIGHT = 1.2
local LOS_EXTRA_HEIGHTS = {0.8, 1.5} -- additional heights for fallback LOS checks to better handle hills
local UPDATE_INTERVAL = 200 -- ms
local PURSUE_KEEP_TIME = 15000 -- ms to keep pursuing after last seen (used to enter pursue mode)
local PURSUE_EXIT_DISTANCE = 2000 -- if player farther than this, stop pursuing
local STUCK_SPEED_THRESHOLD = 0.08 -- below this velocity we consider the rammer stuck
local STUCK_TIME_MS = 2000 -- must remain under the threshold for this long to trigger recovery
local STUCK_RECOVERY_MS = 1100 -- duration of the reverse manoeuvre when freeing the vehicle

local function cleanupRammer(veh)
    if not veh then return end
    local info = RAMMERS[veh]
    if info and info.timer then
        killTimer(info.timer)
    end
    if info and info.avoidTimer then
        killTimer(info.avoidTimer)
    end
    if info and info.owner and RAMMER_BY_OWNER[info.owner] == veh then
        RAMMER_BY_OWNER[info.owner] = nil
    end
    RAMMERS[veh] = nil
end

addEventHandler("onElementDestroy", root, function()
    if getElementType(source) == "vehicle" and RAMMERS[source] then
        cleanupRammer(source)
    end
end)

addEventHandler("onVehicleExplode", root, function()
    if RAMMERS[source] then
        cleanupRammer(source)
    end
end)

addEventHandler("onPlayerQuit", root, function()
    local veh = RAMMER_BY_OWNER[source]
    if veh then
        if isElement(veh) then
            destroyElement(veh)
        end
        cleanupRammer(veh)
    end
end)

addCommandHandler("ramcar", function(player, cmd, arg)
    -- arg can be a distance override
    local ramDist = tonumber(arg) or DEFAULT_RAM_DISTANCE

    local existing = RAMMER_BY_OWNER[player]
    if existing then
        if isElement(existing) then
            destroyElement(existing)
        end
        cleanupRammer(existing)
        outputChatBox("Your ramcar has been removed.", player)
        return
    end

    local px, py, pz = getElementPosition(player)
    local node = pathsNodeFindClosest(px, py, pz, {allowParking = false})
    if not node then
        outputChatBox("No nearby node found.", player)
        return
    end
    local next = pathsFindNextNode(node.id, nil, {allowParking = false})
    if not next then
        outputChatBox("No next node found.", player)
        return
    end

    -- Use similar spawn logic as traffic_server.createVehicleOnNodes so the vehicle integrates with the system
    local rotz = (360 - math.deg(math.atan2((next.x - node.x), (next.y - node.y)))) % 360
    local ox, oy = calcNodeLaneOffset(next, rotz, node)
    local sx, sy = node.x + ox, node.y + oy
    local rotx = math.deg(math.atan2(next.z - node.z, getDistanceBetweenPoints2D(next.x, next.y, sx, sy)))

    local veh
    if node.type == TYPE_DEFAULT then
        -- spawn a Bobcat for the ram test so it can push/ram reliably
        veh = createVehicle(BOBCAT_MODEL, sx, sy, node.z + 1, rotx, 0, rotz)
    elseif node.type == TYPE_BOAT then
        veh = createVehicle(BOAT_TYPES[math.random(1,#BOAT_TYPES)], sx, sy, node.z, 0, 0, rotz)
    end

    if not veh then
        outputChatBox("Failed to create vehicle.", player)
        return
    end

    -- mark this vehicle so clients can show debug visuals
    setElementData(veh, "rammer_test", true)

    setVehicleColor(veh, 255, 255, 0) -- fuschia for visibility

    -- create ped and attach
    local ped = createPed(math.random(9,264), node.x, node.y, node.z, 0, false)
    if not ped then
        destroyElement(veh)
        outputChatBox("Failed to create ped.", player)
        return
    end
    setElementData(ped, "BotTeam", getTeamFromName("Citizens"))
    warpPedIntoVehicle(ped, veh)
    setElementParent(ped, veh)
    setElementData(veh, "type", "traffic")
    setElementData(veh, "next", next.id)
    -- Disable the core traffic AI for this vehicle so the rammer script can fully control it.
    -- This flag is checked by the traffic client/server (small patch applied to core files).
    setElementData(veh, "traffic_enabled", false)

    -- Notify clients the same way the traffic spawner does so the client-side pathfollowing initializes
    -- Keep the same call style used in the resource so handlers pick it up
    triggerClientEvent(VEH_CREATED, ped, node.id, next.id)

    -- Track this rammer and start update timer
    RAMMERS[veh] = { owner = player, target = player, ramDist = ramDist, lastKnown = nil, avoiding = false, uTurning = false, pursuing = false, routingToLast = false, stuckSince = nil, lastStuckTurnLeft = nil, lastAvoidTurnLeft = false }
    RAMMER_BY_OWNER[player] = veh

    RAMMERS[veh].timer = setTimer(function()
        if not isElement(veh) or not isElement(player) or getElementType(veh) ~= "vehicle" then
            cleanupRammer(veh)
            return
        end

        local info = RAMMERS[veh]
        if not info then
            cleanupRammer(veh)
            return
        end

    local vx, vy, vz = getElementPosition(veh)
        local px2, py2, pz2 = getElementPosition(player)
        local dist = getDistanceBetweenPoints3D(vx, vy, vz, px2, py2, pz2)

    -- line-of-sight test to player; wrap in pcall to avoid runtime errors if underlying API returns unexpected values
    local ok, hit, hx, hy, hz, helem = pcall(processLineOfSight, vx, vy, vz + LOS_CHECK_HEIGHT, px2, py2, pz2 + LOS_CHECK_HEIGHT, true, true, true, true, true, true, true, true, veh)
        if not ok then
            hit = nil
            hx, hy, hz, helem = nil, nil, nil, nil
        end
    -- treat nil/false as no blocking element -> has LOS
    local hasLOS = (hit == nil or hit == false)
        if not hasLOS and ok then
            for _, extra in ipairs(LOS_EXTRA_HEIGHTS) do
                local ok2, hit2 = pcall(processLineOfSight, vx, vy, vz + LOS_CHECK_HEIGHT + extra, px2, py2, pz2 + LOS_CHECK_HEIGHT + extra, true, true, true, true, true, true, true, true, veh)
                if ok2 and (hit2 == nil or hit2 == false) then
                    hasLOS = true
                    break
                end
            end
        end
        -- if we have LOS, update last known player position and timestamp
        if hasLOS then
            info.lastKnown = { x = px2, y = py2, z = pz2 }
            info.lastSeen = getTickCount()
            info.routingToLast = false
        end

        -- publish hit position for client debug visuals (will be nil when nothing hit)
        if hx and hy and hz then
            setElementData(veh, "rammer_hit_x", hx)
            setElementData(veh, "rammer_hit_y", hy)
            setElementData(veh, "rammer_hit_z", hz)
            setElementData(veh, "rammer_hashit", true)
        else
            setElementData(veh, "rammer_hit_x", false)
            setElementData(veh, "rammer_hit_y", false)
            setElementData(veh, "rammer_hit_z", false)
            setElementData(veh, "rammer_hashit", false)
        end

        -- publish some state flags so clients can show debug info
        setElementData(veh, "rammer_pursuing", info.pursuing == true)
        setElementData(veh, "rammer_routing", info.routingToLast == true)

        local controls = {
            vehicle_left = false,
            vehicle_right = false,
            brake_reverse = false,
            accelerate = false,
            handbrake = false,
            horn = false
        }

        local targetX, targetY, targetZ
        -- determine pursuit mode (latch into pursuit once entered; only exit when player is far away)
        local now = getTickCount()
        local enterPursue = info.lastSeen and (now - info.lastSeen) <= PURSUE_KEEP_TIME
        -- if already pursuing, keep pursuing unless the player is extremely far away
        if info.pursuing then
            if dist > PURSUE_EXIT_DISTANCE then
                info.pursuing = false
            end
        else
            if enterPursue then
                info.pursuing = true
            end
        end

        local pursuing = info.pursuing

        -- during active pursuit we increase detection distance
        local effectiveDist = info.ramDist
        if pursuing then
            effectiveDist = effectiveDist * 2
        end

        if hasLOS and dist <= effectiveDist then
            targetX, targetY, targetZ = px2, py2, pz2
        elseif info.lastKnown then
            -- head to last known location when player is not in LOS
            targetX, targetY, targetZ = info.lastKnown.x, info.lastKnown.y, info.lastKnown.z
        end

        if targetX and targetY and targetZ then
            -- steer towards target (player or last known location)
            local desired = (360 - math.deg(math.atan2((targetX - vx), (targetY - vy)))) % 360
            local _, _, vrot = getElementRotation(veh)
            vrot = vrot or 0
            local trot = (desired - vrot) % 360
            -- reduce accuracy to be more aggressive at steering toward the target
            local accuracy = 6
            if trot > -accuracy and trot < accuracy then
                controls.vehicle_left = false
                controls.vehicle_right = false
            else
                -- prefer the turn (left or right) that will route the vehicle closer to the target
                local function simForwardDist(angleOffset)
                    local simAngle = (vrot + angleOffset) % 360
                    local simDist = 6
                    local sx = vx + math.cos(math.rad(simAngle)) * simDist
                    local sy = vy + math.sin(math.rad(simAngle)) * simDist
                    return getDistanceBetweenPoints2D(sx, sy, targetX, targetY)
                end
                local leftDist = simForwardDist(-20)
                local rightDist = simForwardDist(20)
                if leftDist < rightDist then
                    controls.vehicle_left = true
                    controls.vehicle_right = false
                else
                    controls.vehicle_left = false
                    controls.vehicle_right = true
                end
            end
            -- if we have LOS but are heading strongly away from the target, do a quick U-turn maneuver
            -- compute signed angle (-180..180)
            local signed = ((trot + 180) % 360) - 180
            if hasLOS and math.abs(signed) > 140 and not info.uTurning then
                info.uTurning = true
                -- choose direction that will point faster toward target
                local leftDist = (function() local simAngle = (vrot - 60) % 360; local sx = vx + math.cos(math.rad(simAngle)) * 3; local sy = vy + math.sin(math.rad(simAngle)) * 3; return getDistanceBetweenPoints2D(sx, sy, targetX, targetY) end)()
                local rightDist = (function() local simAngle = (vrot + 60) % 360; local sx = vx + math.cos(math.rad(simAngle)) * 3; local sy = vy + math.sin(math.rad(simAngle)) * 3; return getDistanceBetweenPoints2D(sx, sy, targetX, targetY) end)()
                local turnLeft = leftDist < rightDist
                -- short reverse+turn to start a U-turn
                controls.brake_reverse = true
                controls.accelerate = false
                controls.handbrake = false
                controls.vehicle_left = turnLeft
                controls.vehicle_right = not turnLeft
                -- end u-turn after a short burst and then resume aggressive pursuit
                setTimer(function()
                    if RAMMERS[veh] then
                        RAMMERS[veh].uTurning = false
                    end
                end, 700, 1)
            end
            controls.accelerate = true
            controls.brake_reverse = false
            controls.handbrake = false
            controls.horn = true

            -- aggressive pursuit: if we've lost LOS previously and are routing to last known, ensure the client re-forms path toward that last-known node
            if (not hasLOS) and info.lastKnown and not info.routingToLast then
                local lk = info.lastKnown
                local nodeNear = pathsNodeFindClosest(lk.x, lk.y, lk.z, {allowParking = false})
                if nodeNear then
                    local nextNode = pathsFindNextNode(nodeNear.id, nil, {allowParking = false})
                    if nextNode then
                        setElementData(veh, "next", nextNode.id)
                        -- trigger client to initialize path following toward this node
                        triggerClientEvent(VEH_CREATED, ped, nodeNear.id, nextNode.id)
                        info.routingToLast = true
                    end
                end
            end

            -- if extremely close, full-on ram (no braking, keep accelerating)
            if dist < 6 then
                controls.accelerate = true
                controls.brake_reverse = false
                controls.handbrake = false
            end
        else
            -- default: follow path nodes (leave to normal traffic AI), but give it a small forward nudge
            controls.accelerate = false
            controls.brake_reverse = false
            controls.handbrake = false
            controls.vehicle_left = false
            controls.vehicle_right = false
            controls.horn = false
        end

        -- Simple obstacle detection/avoidance in front of the vehicle
        -- If a non-player vehicle blocks the path, attempt a short reverse+turn maneuver
        if not info.avoiding and not info.uTurning then
            local matrix = getElementMatrix(veh)
            local sx, sy, sz = getMatrixOffsets(matrix, 0, 1.5, 0)
            local ex, ey, ez = getMatrixOffsets(matrix, 0, 4.5, 0)
            local okf, hit, hitX, hitY, hitZ, hitElement = pcall(processLineOfSight, sx, sy, sz + 0.5, ex, ey, ez + 0.5, true, true, true, true, true, true, true, true, veh)
            if not okf then
                hit = false
                hitElement = nil
                hitX, hitY, hitZ = nil, nil, nil
            end
            if hit and hitElement and isElement(hitElement) then
                local htype = getElementType(hitElement)
                -- ignore players and peds (they may be the target). If it's a vehicle, check that it's not the player's vehicle
                local isPlayerVehicle = false
                if htype == "vehicle" then
                    local controller = getVehicleController(hitElement)
                    if controller == player then
                        isPlayerVehicle = true
                    end
                end
                if htype == "vehicle" and hitElement ~= veh and not isPlayerVehicle then
                    -- only avoid if it's not the target vehicle and it's close
                    if not hitX or not hitY or not hitZ then
                        hitX, hitY, hitZ = getElementPosition(hitElement)
                    end
                    local toHitX, toHitY, toHitZ = hitX - vx, hitY - vy, hitZ - vz
                    -- project onto the vehicle's forward axis to ensure the obstacle is in front of us
                    local forwardDot = toHitX * matrix[2][1] + toHitY * matrix[2][2] + toHitZ * matrix[2][3]
                    if forwardDot > 0.2 then
                        -- decide turn direction using the right vector so we turn away from the obstacle in vehicle space
                        local sideDot = toHitX * matrix[1][1] + toHitY * matrix[1][2] + toHitZ * matrix[1][3]
                        local turnLeft
                        if math.abs(sideDot) < 0.05 then
                            -- Obstacle is centered; alternate direction to avoid oscillation
                            turnLeft = not info.lastAvoidTurnLeft
                        else
                            -- Positive sideDot => obstacle sits on the vehicle's right, so steer left to pivot away
                            turnLeft = sideDot > 0
                        end
                        info.lastAvoidTurnLeft = turnLeft
                        info.avoiding = true
                        -- set reverse and turning for a short burst
                        controls.brake_reverse = true
                        controls.accelerate = false
                        controls.handbrake = false
                        controls.vehicle_left = turnLeft
                        controls.vehicle_right = not turnLeft
                        -- schedule end of avoidance state
                        if info.avoidTimer and isTimer(info.avoidTimer) then killTimer(info.avoidTimer) end
                        info.avoidTimer = setTimer(function()
                            if RAMMERS[veh] then RAMMERS[veh].avoiding = false end
                        end, 700, 1)
                    end
                end
            end
        end

        -- Stuck detection: if the rammer tries to pursue but barely moves, trigger a reverse manoeuvre
        if targetX and not info.avoiding and not info.uTurning then
            local velx, vely, velz = getElementVelocity(veh)
            velx, vely, velz = velx or 0, vely or 0, velz or 0
            local planarSpeed = math.sqrt(velx * velx + vely * vely)
            if planarSpeed < STUCK_SPEED_THRESHOLD then
                if not info.stuckSince then
                    info.stuckSince = now
                elseif now - info.stuckSince >= STUCK_TIME_MS then
                    info.stuckSince = now
                    local turnLeft = info.lastStuckTurnLeft
                    if turnLeft == nil then
                        turnLeft = math.random() < 0.5
                    else
                        turnLeft = not turnLeft
                    end
                    info.lastStuckTurnLeft = turnLeft
                    info.avoiding = true
                    controls.brake_reverse = true
                    controls.accelerate = false
                    controls.handbrake = false
                    controls.vehicle_left = turnLeft
                    controls.vehicle_right = not turnLeft
                    if info.avoidTimer and isTimer(info.avoidTimer) then
                        killTimer(info.avoidTimer)
                    end
                    info.avoidTimer = setTimer(function()
                        local data = RAMMERS[veh]
                        if data then
                            data.avoiding = false
                            data.stuckSince = nil
                        end
                    end, STUCK_RECOVERY_MS, 1)
                end
            else
                info.stuckSince = nil
            end
        else
            info.stuckSince = nil
        end

        for k, v in pairs(controls) do
            setElementData(veh, k, v)
        end

        -- also publish the control states in a compact form for debugging
        -- (clients already read individual keys above, but having the boolean pursuing/routing
        -- helps to diagnose why traffic might re-take control)

        -- cleanup if far away from owner player for too long AND not actively pursuing
        if not info.pursuing and dist > PURSUE_EXIT_DISTANCE then
            destroyElement(veh)
            cleanupRammer(veh)
        end
    end, UPDATE_INTERVAL, 0)

    outputChatBox("Rammer spawned. It will try to reach and ram you if within "..tostring(ramDist).." units and line-of-sight.", player)
end)

-- Helper: resume traffic AI for a vehicle in a safe way by choosing the node
-- that best matches the vehicle's current heading so the core AI doesn't pick
-- an outdated distant node when re-enabled.
local function resumeTrafficAI(veh)
    if not isElement(veh) or getElementType(veh) ~= "vehicle" then return false end
    local driver = getVehicleOccupant(veh)
    if not isElement(driver) then return false end
    local vx, vy, vz = getElementPosition(veh)
    local matrix = getElementMatrix(veh)
    local fx, fy, fz = getMatrixOffsets(matrix, 0, 1, 0)
    local forwardVec = { x = fx - vx, y = fy - vy }
    local node = pathsNodeFindClosest(vx, vy, vz)
    if not node then return false end
    local neighbours = pathsNodeGetNeighbours(node.id)
    if not neighbours or #neighbours == 0 then
        return false
    end
    local bestId, bestAng = nil, 1e9
    for _, nid in ipairs(neighbours) do
        local nnode = getNode(nid)
        if nnode then
            local nx, ny = nnode.x - node.x, nnode.y - node.y
            local dot = (forwardVec.x * nx + forwardVec.y * ny)
            local magA = math.sqrt(forwardVec.x * forwardVec.x + forwardVec.y * forwardVec.y)
            local magB = math.sqrt(nx * nx + ny * ny)
            if magA > 0 and magB > 0 then
                local cos = dot / (magA * magB)
                local ang = math.acos(math.max(-1, math.min(1, cos)))
                if ang < bestAng then
                    bestAng = ang
                    bestId = nid
                end
            end
        end
    end
    if not bestId then
        bestId = neighbours[1]
    end
    local chosen = getNode(bestId)
    if chosen then
        setElementData(veh, "next", chosen.id)
        -- re-trigger client initialization for pathfollowing
        triggerClientEvent(VEH_CREATED, driver, node.id, chosen.id)
        return true
    end
    return false
end

-- Command to toggle traffic behavior on the nearest rammer vehicle
addCommandHandler("ramtoggle", function(player, cmd, arg)
    local px, py, pz = getElementPosition(player)
    local best, bestDist
    for _, v in ipairs(getElementsByType("vehicle")) do
        if getElementData(v, "rammer_test") then
            local vx, vy, vz = getElementPosition(v)
            local d = getDistanceBetweenPoints3D(px, py, pz, vx, vy, vz)
            if not bestDist or d < bestDist then bestDist = d best = v end
        end
    end
    if not best then
        outputChatBox("No rammer nearby.", player)
        return
    end
    local cur = getElementData(best, "traffic_enabled")
    local new = not (cur == true)
    setElementData(best, "traffic_enabled", new)
    outputChatBox("Rammer traffic_enabled set to "..tostring(new), player)
    if new then
        -- resume traffic AI in a safe way
        if resumeTrafficAI(best) then
            outputChatBox("Resumed traffic AI for rammer.", player)
        else
            outputChatBox("Couldn't find a suitable node to resume traffic; leave it disabled.", player)
        end
    end
end)
