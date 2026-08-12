local Geo = require "Geo"
local Json = require "JSON"
local Receipt = require "Receipt"

local UndoWriter = {}

local function fromNullable(value)
    if value == Json.null then return nil end
    return value
end

local function locationFromReceipt(value)
    if value == Json.null then return nil end
    return {
        latitude = value.latitude,
        longitude = value.longitude,
        altitude = fromNullable(value.altitude),
    }
end

local function setLocation(photo, location, altitude)
    if location == nil then
        photo:setRawMetadata("gps", nil)
    else
        photo:setRawMetadata("gps", {
            latitude = location.latitude,
            longitude = location.longitude,
        })
    end
    photo:setRawMetadata("gpsAltitude", altitude)
end

function UndoWriter.preflight(state, options)
    local result = { eligible = {}, skippedMissing = 0, skippedChanged = 0 }
    local candidates = {}
    for _, receiptItem in ipairs(state.items) do
        local photo = options.catalog:findPhotoByUuid(receiptItem.uuid)
        if not photo then
            result.skippedMissing = result.skippedMissing + 1
        else
            candidates[#candidates + 1] = { photo = photo, receipt = receiptItem }
        end
    end
    local batchSize = options.batchSize or 500
    for startIndex = 1, #candidates, batchSize do
        local endIndex = math.min(startIndex + batchSize - 1, #candidates)
        local photos = {}
        for index = startIndex, endIndex do photos[#photos + 1] = candidates[index].photo end
        local rawByPhoto = options.catalog:batchGetRawMetadata(photos, { "gps", "gpsAltitude" })
        local propertiesByPhoto = options.catalog:batchGetPropertyForPlugin(
            photos,
            options.pluginId,
            { "sourceToken" }
        )
        for index = startIndex, endIndex do
            local candidate = candidates[index]
            local raw = rawByPhoto[candidate.photo] or {}
            local properties = propertiesByPhoto[candidate.photo] or {}
            local afterLocation = locationFromReceipt(candidate.receipt.after.location)
            if properties.sourceToken ~= candidate.receipt.sourceToken
                or not Geo.same(Geo.fromRaw(raw.gps, raw.gpsAltitude), afterLocation) then
                result.skippedChanged = result.skippedChanged + 1
            else
                result.eligible[#result.eligible + 1] = candidate
            end
        end
    end
    return result
end

function UndoWriter.apply(state, preflight, options)
    local result = { restored = 0, skippedChanged = preflight.skippedChanged, skippedMissing = preflight.skippedMissing, canceled = false }
    local batchSize = options.batchSize or 200
    local startIndex = 1
    local batchNumber = 0
    local protectedCall = options.protectedCall or pcall
    while startIndex <= #preflight.eligible do
        if options.progress:isCanceled() then result.canceled = true break end
        batchNumber = batchNumber + 1
        local endIndex = math.min(startIndex + batchSize - 1, #preflight.eligible)
        local batchID = string.format("undo-%s-%06d", options.undoID, batchNumber)
        Receipt.append(options.receiptPath, {
            kind = "undoBatchPrepared",
            transactionID = state.transactionID,
            undoID = options.undoID,
            batchID = batchID,
        }, options.receiptAdapter)

        local restoredThisBatch = 0
        local ok, writeError = protectedCall(function()
            local executed = false
            options.catalog:withWriteAccessDo(options.actionName or "RawGeoSync：撤销 GPS 导入", function()
                executed = true
                for index = startIndex, endIndex do
                    if options.progress:isCanceled() then error("__RAWGEOSYNC_CANCEL__", 0) end
                    local candidate = preflight.eligible[index]
                    local receiptItem = candidate.receipt
                    local currentToken = candidate.photo:getPropertyForPlugin(options.pluginId, "sourceToken")
                    local afterLocation = locationFromReceipt(receiptItem.after.location)
                    if currentToken == receiptItem.sourceToken and Geo.same(Geo.read(candidate.photo), afterLocation) then
                        setLocation(
                            candidate.photo,
                            locationFromReceipt(receiptItem.before.location),
                            fromNullable(receiptItem.before.altitude)
                        )
                        for _, field in ipairs(options.metadataFields) do
                            candidate.photo:setPropertyForPlugin(
                                options.pluginId,
                                field,
                                fromNullable(receiptItem.before.properties[field])
                            )
                        end
                        restoredThisBatch = restoredThisBatch + 1
                    else
                        result.skippedChanged = result.skippedChanged + 1
                    end
                end
            end, { timeout = options.writeAccessTimeoutSeconds or 30 })
            if not executed then error("等待 Lightroom 撤销写锁超时", 0) end
        end)
        if not ok then
            Receipt.append(options.receiptPath, {
                kind = "undoBatchAborted",
                transactionID = state.transactionID,
                undoID = options.undoID,
                batchID = batchID,
                reason = tostring(writeError),
            }, options.receiptAdapter)
            if tostring(writeError):find("__RAWGEOSYNC_CANCEL__", 1, true) then result.canceled = true
            else result.error = tostring(writeError) end
            break
        end
        result.restored = result.restored + restoredThisBatch
        Receipt.append(options.receiptPath, {
            kind = "undoBatchCommitted",
            transactionID = state.transactionID,
            undoID = options.undoID,
            batchID = batchID,
            restored = restoredThisBatch,
        }, options.receiptAdapter)
        for index = startIndex, endIndex do
            options.progress:setPortionComplete(index, #preflight.eligible)
        end
        startIndex = endIndex + 1
        if options.yield then options.yield() end
    end
    Receipt.append(options.receiptPath, {
        kind = "undoFinished",
        transactionID = state.transactionID,
        undoID = options.undoID,
        restored = result.restored,
        skippedChanged = result.skippedChanged,
        skippedMissing = result.skippedMissing,
        canceled = result.canceled,
    }, options.receiptAdapter)
    return result
end

return UndoWriter
