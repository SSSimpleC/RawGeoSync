local Geo = require "Geo"
local Json = require "JSON"
local Receipt = require "Receipt"

local CatalogWriter = {}

local function nullableLocation(location)
    if location == nil then return Json.null end
    return {
        latitude = location.latitude,
        longitude = location.longitude,
        altitude = Receipt.nullable(location.altitude),
    }
end

local function snapshotProperties(properties, fields)
    local result = {}
    for _, field in ipairs(fields) do result[field] = Receipt.nullable(properties[field]) end
    return result
end

local function desiredProperties(plan, item, options)
    return {
        sourceToken = item.sourceToken,
        manifestID = plan.manifestID,
        activityID = plan.activityID,
        revision = tostring(plan.revision),
        recordID = item.record.recordID,
        source = item.record.decision.method,
        quality = item.record.decision.confidence,
        verification = item.record.decision.verification,
        granularity = item.record.decision.granularity,
        appliedAtUTC = options.appliedAtUTC,
    }
end

local function receiptItem(plan, item, properties, fields)
    return {
        uuid = item.uuid,
        recordID = item.record.recordID,
        sourceToken = item.sourceToken,
        before = {
            location = nullableLocation(item.before),
            altitude = Receipt.nullable(item.beforeAltitude),
            properties = snapshotProperties(item.beforePluginMetadata, fields),
        },
        after = {
            location = nullableLocation(item.desired),
            altitude = Receipt.nullable(item.desired.altitude),
            properties = properties,
        },
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

local function verifyBatch(catalog, items, startIndex, endIndex, pluginId)
    local photos = {}
    for index = startIndex, endIndex do photos[#photos + 1] = items[index].photo end
    local rawByPhoto = catalog:batchGetRawMetadata(photos, { "gps", "gpsAltitude" })
    local propertiesByPhoto = catalog:batchGetPropertyForPlugin(photos, pluginId, { "sourceToken" })
    local errors = {}
    for index = startIndex, endIndex do
        local item = items[index]
        local raw = rawByPhoto[item.photo] or {}
        local properties = propertiesByPhoto[item.photo] or {}
        if not Geo.same(Geo.fromRaw(raw.gps, raw.gpsAltitude), item.desired) then
            errors[item] = "GPS 复读结果与写入值不一致"
        elseif properties.sourceToken ~= item.sourceToken then
            errors[item] = "来源令牌复读失败"
        end
    end
    return errors
end

function CatalogWriter.apply(plan, options)
    local catalog = assert(options.catalog)
    local pluginId = assert(options.pluginId)
    local receiptPath = assert(options.receiptPath)
    local receiptAdapter = assert(options.receiptAdapter)
    local fields = assert(options.metadataFields)
    local progress = assert(options.progress)
    local batchSize = options.batchSize or 200
    local transactionID = assert(options.transactionID)
    local protectedCall = options.protectedCall or pcall
    local result = {
        applied = 0,
        committed = 0,
        verified = 0,
        failed = 0,
        rolledBack = 0,
        canceled = false,
    }
    local committedItems = {}

    local function automaticRollback()
        if #committedItems == 0 then return true end
        local rollbackStart = 1
        local rollbackBatch = 0
        while rollbackStart <= #committedItems do
            rollbackBatch = rollbackBatch + 1
            local rollbackEnd = math.min(rollbackStart + batchSize - 1, #committedItems)
            local rollbackBatchID = string.format("auto-rollback-%s-%06d", transactionID, rollbackBatch)
            local restoredThisBatch = 0
            local ok, rollbackError = protectedCall(function()
                local executed = false
                catalog:withWriteAccessDo("RawGeoSync：自动恢复导入前状态", function()
                    executed = true
                    for index = rollbackStart, rollbackEnd do
                        local item = committedItems[index]
                        if item.photo:getPropertyForPlugin(pluginId, "sourceToken") == item.sourceToken
                            and Geo.same(Geo.read(item.photo), item.desired) then
                            setLocation(item.photo, item.before, item.beforeAltitude)
                            for _, field in ipairs(fields) do
                                item.photo:setPropertyForPlugin(
                                    pluginId,
                                    field,
                                    item.beforePluginMetadata[field]
                                )
                            end
                            restoredThisBatch = restoredThisBatch + 1
                        end
                    end
                end, { timeout = options.writeAccessTimeoutSeconds or 30 })
                if not executed then error("等待 Lightroom 自动恢复写锁超时", 0) end
            end)
            if not ok then
                result.rollbackError = tostring(rollbackError)
                return nil, rollbackError
            end
            result.rolledBack = result.rolledBack + restoredThisBatch
            Receipt.append(receiptPath, {
                kind = "automaticRollbackBatchCommitted",
                transactionID = transactionID,
                batchID = rollbackBatchID,
                restored = restoredThisBatch,
            }, receiptAdapter)
            rollbackStart = rollbackEnd + 1
        end
        result.applied = result.committed - result.rolledBack
        if result.applied == 0 then result.verified = 0 end
        return result.applied == 0
    end

    Receipt.append(receiptPath, {
        kind = "transactionPrepared",
        transactionID = transactionID,
        catalogToken = options.catalogToken,
        manifestID = plan.manifestID,
        activityID = plan.activityID,
        revision = plan.revision,
        createdAtUTC = options.appliedAtUTC,
    }, receiptAdapter)
    if options.onReceiptPrepared then options.onReceiptPrepared(receiptPath) end

    local startIndex = 1
    local batchNumber = 0
    while startIndex <= #plan.writable do
        if progress:isCanceled() then result.canceled = true break end
        batchNumber = batchNumber + 1
        local endIndex = math.min(startIndex + batchSize - 1, #plan.writable)
        local batchID = string.format("%s-%06d", transactionID, batchNumber)
        local preparedItems = Json.array()
        local desiredByItem = {}
        for index = startIndex, endIndex do
            local item = plan.writable[index]
            local properties = desiredProperties(plan, item, options)
            desiredByItem[item] = properties
            preparedItems[#preparedItems + 1] = receiptItem(plan, item, properties, fields)
        end
        Receipt.append(receiptPath, {
            kind = "batchPrepared",
            transactionID = transactionID,
            batchID = batchID,
            items = preparedItems,
        }, receiptAdapter)

        local ok, writeError = protectedCall(function()
            local executed = false
            catalog:withWriteAccessDo(options.actionName or "RawGeoSync：写入 GPS", function()
                executed = true
                for index = startIndex, endIndex do
                    if progress:isCanceled() then error("__RAWGEOSYNC_CANCEL__", 0) end
                    local item = plan.writable[index]
                    setLocation(item.photo, item.desired, item.desired.altitude)
                    for _, field in ipairs(fields) do
                        item.photo:setPropertyForPlugin(pluginId, field, desiredByItem[item][field])
                    end
                end
            end, { timeout = options.writeAccessTimeoutSeconds or 30 })
            if not executed then error("等待 Lightroom 目录写锁超时", 0) end
        end)
        if not ok then
            Receipt.append(receiptPath, {
                kind = "batchAborted",
                transactionID = transactionID,
                batchID = batchID,
                reason = tostring(writeError),
            }, receiptAdapter)
            if tostring(writeError):find("__RAWGEOSYNC_CANCEL__", 1, true) then
                result.canceled = true
            else
                result.failed = endIndex - startIndex + 1
                result.error = tostring(writeError)
            end
            break
        end

        result.committed = result.committed + (endIndex - startIndex + 1)
        result.applied = result.committed
        for index = startIndex, endIndex do
            committedItems[#committedItems + 1] = plan.writable[index]
        end
        Receipt.append(receiptPath, {
            kind = "batchCommitted",
            transactionID = transactionID,
            batchID = batchID,
        }, receiptAdapter)

        local verificationOk, verificationErrors = protectedCall(
            verifyBatch,
            catalog,
            plan.writable,
            startIndex,
            endIndex,
            pluginId
        )
        if not verificationOk then
            result.failed = result.failed + (endIndex - startIndex + 1)
            result.error = "批量复读失败：" .. tostring(verificationErrors)
        else
            for index = startIndex, endIndex do
                local verifyError = verificationErrors[plan.writable[index]]
                if not verifyError then
                    result.verified = result.verified + 1
                else
                    result.failed = result.failed + 1
                    if not result.error then result.error = verifyError end
                end
            end
        end
        for index = startIndex, endIndex do
            progress:setPortionComplete(index, #plan.writable)
        end
        if progress:isCanceled() then result.canceled = true end
        if result.failed > 0 then break end
        if result.canceled then break end
        startIndex = endIndex + 1
        if options.yield then options.yield() end
    end

    if result.canceled or result.failed > 0 then
        local rolledBack = automaticRollback()
        if not rolledBack and not result.rollbackError then
            result.rollbackError = "部分照片已在外部修改，无法自动恢复；可使用持久事务收据安全撤销"
        end
    end

    Receipt.append(receiptPath, {
        kind = "transactionFinished",
        transactionID = transactionID,
        applied = result.applied,
        committed = result.committed,
        verified = result.verified,
        failed = result.failed,
        rolledBack = result.rolledBack,
        rollbackError = Receipt.nullable(result.rollbackError),
        canceled = result.canceled,
    }, receiptAdapter)
    return result
end

return CatalogWriter
