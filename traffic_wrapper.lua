_createVehicle = createVehicle
function createVehicle ( ... )
        -- Store our vehicle
        local veh = _createVehicle ( ... )
        TRAFFIC_VEHICLES[veh] = true
        return veh
end

addEventHandler("onElementDestroy", root,
        function ()
                if getElementType(source) == "vehicle" and TRAFFIC_VEHICLES[source] then
                        TRAFFIC_VEHICLES[source] = nil
                end
        end
)