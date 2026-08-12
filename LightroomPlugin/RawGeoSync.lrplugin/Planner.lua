local Geo = require "Geo"

local Planner = {}

local function increment(counts, status)
    counts[status] = (counts[status] or 0) + 1
end

local function priorPluginMetadata(photo, pluginId, fields)
    local result = {}
    for _, field in ipairs(fields) do
        result[field] = photo:getPropertyForPlugin(pluginId, field)
    end
    return result
end

local function metadataFor(resolved, photo, pluginId, fields)
    if resolved.pluginMetadata then return resolved.pluginMetadata end
    return priorPluginMetadata(photo, pluginId, fields)
end

function Planner.build(manifest, adapter, options)
    options = options or {}
    local pluginId = assert(options.pluginId, "pluginId is required")
    local fields = assert(options.metadataFields, "metadataFields is required")
    local plan = {
        manifestID = manifest.header.manifestID,
        activityID = manifest.header.activityID,
        revision = manifest.header.revision,
        items = {},
        writable = {},
        counts = {},
    }
    local seenResolvedPaths = {}

    for _, record in ipairs(manifest.assets) do
        local item = { record = record }
        local resolved, resolveError = adapter.resolveExact(record)
        if not resolved then
            item.status = "notInCatalog"
            item.reason = resolveError or "照片不在当前 Lightroom 目录中"
        elseif options.includePhotoSet and not options.includePhotoSet[resolved.photo] then
            item.status = "notSelected"
            item.photo = resolved.photo
            item.path = resolved.path
            item.reason = "不在 Lightroom 当前选择中"
        elseif seenResolvedPaths[resolved.path] then
            item.status = "duplicateResolvedPath"
            item.photo = resolved.photo
            item.path = resolved.path
            item.reason = "多个清单路径解析到同一照片，已拒绝重复处理"
        elseif resolved.available == false then
            seenResolvedPaths[resolved.path] = true
            item.status = "offline"
            item.photo = resolved.photo
            item.path = resolved.path
            item.reason = "原始文件离线；为避免把智能预览误作原文件，已跳过"
        elseif resolved.byteCount ~= record.fileIdentity.byteCount then
            seenResolvedPaths[resolved.path] = true
            item.status = "identityMismatch"
            item.photo = resolved.photo
            item.path = resolved.path
            item.reason = "文件字节数与清单不一致"
        else
            seenResolvedPaths[resolved.path] = true
            item.photo = resolved.photo
            item.path = resolved.path
            item.uuid = resolved.uuid or (resolved.rawMetadata and resolved.rawMetadata.uuid)
            if resolved.rawMetadata then
                item.beforeAltitude = resolved.rawMetadata.gpsAltitude
                item.before = Geo.fromRaw(resolved.rawMetadata.gps, item.beforeAltitude)
            else
                item.before = Geo.read(resolved.photo)
                item.beforeAltitude = Geo.readAltitude(resolved.photo)
            end
            item.desired = Geo.withEffectiveAltitude(record.location, item.beforeAltitude)
            item.beforePluginMetadata = metadataFor(resolved, resolved.photo, pluginId, fields)
            if Geo.same(item.before, item.desired) then
                item.status = "alreadySame"
                item.reason = "目录中的 GPS 已与清单一致"
            elseif item.before ~= nil and not options.overwriteDifferentGps then
                item.status = "conflict"
                item.reason = "照片已有不同 GPS；默认保留"
            else
                item.status = "ready"
                item.sourceToken = assert(options.makeSourceToken(record), "source token is required")
                plan.writable[#plan.writable + 1] = item
            end
        end
        plan.items[#plan.items + 1] = item
        increment(plan.counts, item.status)
    end
    return plan
end

return Planner
