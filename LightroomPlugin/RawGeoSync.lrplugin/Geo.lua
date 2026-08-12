local Geo = {}

local function finite(value)
    return type(value) == "number"
        and value == value
        and value ~= math.huge
        and value ~= -math.huge
end

function Geo.validate(location)
    if type(location) ~= "table" then return nil, "location 必须是对象" end
    if not finite(location.latitude) or location.latitude < -90 or location.latitude > 90 then
        return nil, "latitude 必须位于 -90 至 90"
    end
    if not finite(location.longitude) or location.longitude < -180 or location.longitude > 180 then
        return nil, "longitude 必须位于 -180 至 180"
    end
    if location.altitude ~= nil and not finite(location.altitude) then
        return nil, "altitude 必须是有限数字"
    end
    return {
        latitude = location.latitude,
        longitude = location.longitude,
        altitude = location.altitude,
    }
end

function Geo.fromRaw(rawGps, altitude)
    if type(rawGps) ~= "table"
        or not finite(rawGps.latitude)
        or not finite(rawGps.longitude) then
        return nil
    end
    return {
        latitude = rawGps.latitude,
        longitude = rawGps.longitude,
        altitude = finite(altitude) and altitude or nil,
    }
end

function Geo.read(photo)
    return Geo.fromRaw(photo:getRawMetadata("gps"), Geo.readAltitude(photo))
end

function Geo.readAltitude(photo)
    local altitude = photo:getRawMetadata("gpsAltitude")
    return finite(altitude) and altitude or nil
end

function Geo.withEffectiveAltitude(location, existingAltitude)
    return {
        latitude = location.latitude,
        longitude = location.longitude,
        altitude = location.altitude ~= nil and location.altitude or existingAltitude,
    }
end

function Geo.same(left, right, coordinateEpsilon, altitudeEpsilon)
    if left == nil or right == nil then return left == nil and right == nil end
    coordinateEpsilon = coordinateEpsilon or 0.0000001
    altitudeEpsilon = altitudeEpsilon or 0.01
    if math.abs(left.latitude - right.latitude) > coordinateEpsilon
        or math.abs(left.longitude - right.longitude) > coordinateEpsilon then
        return false
    end
    if left.altitude == nil or right.altitude == nil then
        return left.altitude == nil and right.altitude == nil
    end
    return math.abs(left.altitude - right.altitude) <= altitudeEpsilon
end

return Geo
