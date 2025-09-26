-- test_ramcar_client.lua
-- Client-side visuals for the rammer test: marker above rammer and draw LOS lines to debug what the rammer "sees".

local LOS_HEIGHT = 0.6 -- lower height so ray originates nearer the vehicle center
local RAY_LENGTH = 30
local SIDE_OFFSET = 2.2
local SCAN_FREQ = 1.5 -- rotations per second (full 360 sweep every ~0.66 seconds)

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
            -- compute start and end using resource helper getMatrixOffsets so axes match server code
            local sxw, syw, szw = getMatrixOffsets(mx, 0, 0, LOS_HEIGHT)
            local txw, tyw, tzw = getMatrixOffsets(mx, 0, RAY_LENGTH, LOS_HEIGHT)
            local sscreenX, sscreenY = getScreenFromWorldPosition(sxw, syw, szw)
            local tscreenX, tscreenY = getScreenFromWorldPosition(txw, tyw, tzw)
            if sscreenX and sscreenY and tscreenX and tscreenY then
                dxDrawLine(sscreenX, sscreenY, tscreenX, tscreenY, tocolor(255, 255, 0, 200), 2)
            end

            -- side rays (frustum) computed with lateral offset and shorter forward length
            local leftxw, leftyw, leftzw = getMatrixOffsets(mx, -SIDE_OFFSET, RAY_LENGTH * 0.7, LOS_HEIGHT)
            local rightxw, rightyw, rightzw = getMatrixOffsets(mx, SIDE_OFFSET, RAY_LENGTH * 0.7, LOS_HEIGHT)
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
            local ticks = getTickCount() / 1000
            local angleDeg = (ticks * 360 * SCAN_FREQ) % 360
            local angleRad = math.rad(angleDeg)
            -- forward and right vectors from matrix
            -- In this matrix layout, row 2 is the forward axis and row 1 is right/side axis
            local rx = mx[1][1]
            local ry = mx[1][2]
            local rz = mx[1][3]
            local fx = mx[2][1]
            local fy = mx[2][2]
            local fz = mx[2][3]
            -- rotated direction = forward * cos(a) + right * sin(a)
            local dirx = fx * math.cos(angleRad) + rx * math.sin(angleRad)
            local diry = fy * math.cos(angleRad) + ry * math.sin(angleRad)
            local dirz = fz * math.cos(angleRad) + rz * math.sin(angleRad)
            local scanXw, scanYw, scanZw = getMatrixOffsets(mx, 0, 0, LOS_HEIGHT)
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
