local LrFileUtils = import "LrFileUtils"
local LrPathUtils = import "LrPathUtils"

local PathPolicy = require "PathPolicy"

local CatalogAdapter = {}

function CatalogAdapter.new(catalog, root)
    local pathAdapter = {
        child = function(parent, child) return LrPathUtils.child(parent, child) end,
        standardize = function(path) return LrPathUtils.standardizePath(path) end,
    }
    local adapter
    adapter = {
        resolvedByRecord = {},
        resolvedByPhoto = {},
        resolveExact = function(record)
            local cached = adapter.resolvedByRecord[record]
            if cached then return cached.result, cached.error end
            local absolutePath, pathError = PathPolicy.resolve(root, record.relativePath, pathAdapter)
            if not absolutePath then
                adapter.resolvedByRecord[record] = { error = pathError }
                return nil, pathError
            end
            local photo = catalog:findPhotoByPath(absolutePath)
            if not photo then
                local missingError = "精确路径不在当前 Lightroom 目录中"
                adapter.resolvedByRecord[record] = { error = missingError }
                return nil, missingError
            end
            if LrFileUtils.exists(absolutePath) ~= "file" then
                local offline = {
                    photo = photo,
                    path = absolutePath,
                    available = false,
                }
                adapter.resolvedByRecord[record] = { result = offline }
                adapter.resolvedByPhoto[photo] = adapter.resolvedByPhoto[photo] or {}
                adapter.resolvedByPhoto[photo][#adapter.resolvedByPhoto[photo] + 1] = offline
                return offline
            end
            local attributes = LrFileUtils.fileAttributes(absolutePath)
            local result = {
                photo = photo,
                path = absolutePath,
                available = true,
                byteCount = attributes and attributes.fileSize or nil,
            }
            adapter.resolvedByRecord[record] = { result = result }
            adapter.resolvedByPhoto[photo] = adapter.resolvedByPhoto[photo] or {}
            adapter.resolvedByPhoto[photo][#adapter.resolvedByPhoto[photo] + 1] = result
            return result
        end,
    }
    return adapter
end

function CatalogAdapter.prefetch(adapter, catalog, records, plugin, metadataFields, batchSize)
    batchSize = batchSize or 500
    local photos = {}
    local seen = {}
    for _, record in ipairs(records) do
        local resolved = adapter.resolveExact(record)
        if resolved and resolved.available ~= false and not seen[resolved.photo] then
            seen[resolved.photo] = true
            photos[#photos + 1] = resolved.photo
        end
    end

    for startIndex = 1, #photos, batchSize do
        local batch = {}
        local endIndex = math.min(startIndex + batchSize - 1, #photos)
        for index = startIndex, endIndex do batch[#batch + 1] = photos[index] end
        local rawByPhoto = catalog:batchGetRawMetadata(batch, { "gps", "gpsAltitude", "uuid" })
        local propertiesByPhoto = catalog:batchGetPropertyForPlugin(batch, plugin, metadataFields)
        for _, photo in ipairs(batch) do
            local resolvedRaw = rawByPhoto[photo]
            if resolvedRaw then
                for _, resolved in ipairs(adapter.resolvedByPhoto[photo] or {}) do
                    resolved.rawMetadata = resolvedRaw
                    resolved.uuid = resolvedRaw.uuid
                    resolved.pluginMetadata = propertiesByPhoto[photo] or {}
                end
            end
        end
    end
end

return CatalogAdapter
