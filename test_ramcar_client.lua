-- test_ramcar_client.lua
-- Client-side visuals for the rammer test: marker above rammer and draw LOS lines to debug what the rammer "sees".

local LOS_HEIGHT = 0.6 -- lower height so ray originates nearer the vehicle center
local RAY_LENGTH = 75 -- increased by 150% to match extended detection radius
local SIDE_OFFSET = 2.2
local SCAN_FREQ = 1.5 -- rotations per second (full 360 sweep every ~0.66 seconds)

local function normalize(x, y, z)
    local len = math.sqrt(x * x + y * y + z * z)
    if len > 0 then
        return x / len, y / len, z / len, len
    end
    return 0, 0, 0, 0
end

local function cross(ax, ay, az, bx, by, bz)
    return ay * bz - az * by, az * bx - ax * bz, ax * by - ay * bx
end

addEventHandler("onClientRender", root, function()
    for i, veh in ipairs(getElementsByType('vehicle', getResourceRootElement(), true)) do
        if getElementData(veh, 'rammer_test') then
            -- draw a marker above the vehicle
            local x,y,z = getElementPosition(veh)
            local screenX, screenY = getScreenFromWorldPosition(x, y, z + 2)
            if screenX and screenY then
                dxDrawText('RAMMER', screenX, screenY - 20, screenX, screenY - 20, tocolor(255, 0, 0, 200), 1.3, 'default', 'center')
            end

            -- draw the LOS ray(s) the vehicle would be using
            local mx = getElementMatrix(veh)
            local pursuing = getElementData(veh, 'rammer_pursuing') == true
            local targetElement = getElementData(veh, 'rammer_target')
            if not isElement(targetElement) then
                targetElement = getLocalPlayer()
            end
            -- compute start point once so we can reuse it for all debug lines
            local sxw, syw, szw = getMatrixOffsets(mx, 0, 0, LOS_HEIGHT)
            local baseForwardX, baseForwardY, baseForwardZ = normalize(mx[2][1], mx[2][2], mx[2][3])
            local baseRightX, baseRightY, baseRightZ = normalize(mx[1][1], mx[1][2], mx[1][3])
            local baseUpX, baseUpY, baseUpZ = normalize(mx[3][1], mx[3][2], mx[3][3])

            local activeForwardX, activeForwardY, activeForwardZ = baseForwardX, baseForwardY, baseForwardZ
            if pursuing and isElement(targetElement) then
                local px, py, pz = getElementPosition(targetElement)
                local dirX = px - sxw
                local dirY = py - syw
                local dirZ = (pz + LOS_HEIGHT) - szw
                local nx, ny, nz, len = normalize(dirX, dirY, dirZ)
                if len > 0 then
                    activeForwardX, activeForwardY, activeForwardZ = nx, ny, nz
                end
            end

            local activeRightX, activeRightY, activeRightZ = cross(baseUpX, baseUpY, baseUpZ, activeForwardX, activeForwardY, activeForwardZ)
            local rx, ry, rz, rlen = normalize(activeRightX, activeRightY, activeRightZ)
            if rlen == 0 then
                rx, ry, rz = baseRightX, baseRightY, baseRightZ
            end
            activeRightX, activeRightY, activeRightZ = rx, ry, rz

            local txw = sxw + activeForwardX * RAY_LENGTH
            local tyw = syw + activeForwardY * RAY_LENGTH
            local tzw = szw + activeForwardZ * RAY_LENGTH
            local sscreenX, sscreenY = getScreenFromWorldPosition(sxw, syw, szw)
            local tscreenX, tscreenY = getScreenFromWorldPosition(txw, tyw, tzw)
            if sscreenX and sscreenY and tscreenX and tscreenY then
                dxDrawLine(sscreenX, sscreenY, tscreenX, tscreenY, tocolor(255, 255, 0, 200), 2)
            end

            -- side rays (frustum) computed with lateral offset and shorter forward length
            local forwardShort = RAY_LENGTH * 0.7
            local leftxw = sxw + activeForwardX * forwardShort - activeRightX * SIDE_OFFSET
            local leftyw = syw + activeForwardY * forwardShort - activeRightY * SIDE_OFFSET
            local leftzw = szw + activeForwardZ * forwardShort - activeRightZ * SIDE_OFFSET
            local rightxw = sxw + activeForwardX * forwardShort + activeRightX * SIDE_OFFSET
            local rightyw = syw + activeForwardY * forwardShort + activeRightY * SIDE_OFFSET
            local rightzw = szw + activeForwardZ * forwardShort + activeRightZ * SIDE_OFFSET
            local lsx, lsy = getScreenFromWorldPosition(leftxw, leftyw, leftzw)
            local rsx, rsy = getScreenFromWorldPosition(rightxw, rightyw, rightzw)
            if lsx and lsy and sscreenX and sscreenY then
                dxDrawLine(sscreenX, sscreenY, lsx, lsy, tocolor(255, 128, 0, 150), 1)
            end
            if rsx and rsy and sscreenX and sscreenY then
                dxDrawLine(sscreenX, sscreenY, rsx, rsy, tocolor(255, 128, 0, 150), 1)
            end

            -- draw hit position if published by server
            local hasHit = getElementData(veh, 'rammer_hashit')
            if hasHit then
                local hx = getElementData(veh, 'rammer_hit_x')
                local hy = getElementData(veh, 'rammer_hit_y')
                local hz = getElementData(veh, 'rammer_hit_z')
                if hx and hy and hz then
                    local hxS, hyS = getScreenFromWorldPosition(hx, hy, hz)
                    if hxS and hyS then
                        dxDrawCircle(hxS, hyS, 6, tocolor(0, 255, 0, 200))
                        dxDrawText('HIT', hxS, hyS - 12, hxS, hyS - 12, tocolor(0,255,0,220), 1)
                    end
                end
            end

            -- rotating scanner line (full 360 sweep) to simulate driver scanning
            local dirx, diry, dirz
            local scanXw, scanYw, scanZw = sxw, syw, szw
            if pursuing and isElement(targetElement) then
                dirx, diry, dirz = activeForwardX, activeForwardY, activeForwardZ
            else
                local ticks = getTickCount() / 1000
                local angleDeg = (ticks * 360 * SCAN_FREQ) % 360
                local angleRad = math.rad(angleDeg)
                local cosA = math.cos(angleRad)
                local sinA = math.sin(angleRad)
                dirx = baseForwardX * cosA + baseRightX * sinA
                diry = baseForwardY * cosA + baseRightY * sinA
                dirz = baseForwardZ * cosA + baseRightZ * sinA
            end
            local scanEndX = scanXw + dirx * RAY_LENGTH
            local scanEndY = scanYw + diry * RAY_LENGTH
            local scanEndZ = scanZw + dirz * RAY_LENGTH
            local sx2, sy2 = getScreenFromWorldPosition(scanXw, scanYw, scanZw)
            local tx2, ty2 = getScreenFromWorldPosition(scanEndX, scanEndY, scanEndZ)
            if sx2 and sy2 and tx2 and ty2 then
                dxDrawLine(sx2, sy2, tx2, ty2, tocolor(0, 200, 255, 180), 2)
            end
            -- draw a debug line to the local player so you can see player direction relative to scanner
            local localPlayer = getLocalPlayer()
            if isElement(localPlayer) then
                local px, py, pz = getElementPosition(localPlayer)
                local psx, psy = getScreenFromWorldPosition(px, py, pz + 0.5)
                local vsx, vsy = getScreenFromWorldPosition(scanXw, scanYw, scanZw)
                if psx and psy and vsx and vsy then
                    dxDrawLine(vsx, vsy, psx, psy, tocolor(0, 255, 0, 160), 1)
                end
            end

            -- Enforce server-specified control states on the rammer's driver to override the
            -- traffic AI on this client. The core traffic script writes element-data for
            -- control keys too, so we read the server-written values and apply them directly
            -- to the ped with setPedControlState each frame (onClientRender runs after
            -- the traffic client's pre-render logic).
            local driver = getVehicleOccupant(veh)
            if isElement(driver) then
                local ctlKeys = {"vehicle_left","vehicle_right","brake_reverse","accelerate","handbrake","horn"}
                for _, key in ipairs(ctlKeys) do
                    local state = getElementData(veh, key)
                    if state == nil then state = false end
                    -- apply control state to the ped driver, overriding traffic AI
                    setPedControlState(driver, key, state)
                end
            end
        end
    end
end)
