local Json = require "JSON"
local Geo = require "Geo"
local PathPolicy = require "PathPolicy"

local Manifest = {}

Manifest.FORMAT = "com.sssimplec.rawgeosync.locations"
Manifest.SCHEMA_MAJOR = 1
Manifest.SCHEMA_MINOR = 0

local function manifestError(lineNumber, message)
    if lineNumber then
        error(string.format("清单第 %d 行：%s", lineNumber, message), 0)
    end
    error("清单：" .. message, 0)
end

local function requireType(value, expected, name, lineNumber)
    if type(value) ~= expected then
        manifestError(lineNumber, name .. " 类型无效")
    end
    return value
end

local function requireNonempty(value, name, lineNumber)
    requireType(value, "string", name, lineNumber)
    if value == "" then manifestError(lineNumber, name .. " 不得为空") end
    return value
end

local function requireInteger(value, name, lineNumber, minimum)
    requireType(value, "number", name, lineNumber)
    if value ~= math.floor(value) or value < (minimum or 0) then
        manifestError(lineNumber, name .. " 必须是有效整数")
    end
    if value > 9007199254740991 then
        manifestError(lineNumber, name .. " 超出 Lightroom Lua 的安全整数范围")
    end
    return value
end

local function optionalString(value, name, lineNumber)
    if value ~= nil then requireNonempty(value, name, lineNumber) end
end

local function isUuid(value)
    if type(value) ~= "string" then return false end
    local a, b, c, d, e = value:match("^(%x+)%-(%x+)%-(%x+)%-(%x+)%-(%x+)$")
    return a ~= nil and #a == 8 and #b == 4 and #c == 4 and #d == 4 and #e == 12
end

local function requireUuid(value, name, lineNumber)
    if not isUuid(value) then manifestError(lineNumber, name .. " 必须是 UUID") end
end

local function isSha256(value)
    return type(value) == "string" and #value == 64 and value:match("^[0-9a-f]+$") ~= nil
end

local function requireSha256(value, name, lineNumber)
    if not isSha256(value) then manifestError(lineNumber, name .. " 必须是 64 位小写 SHA-256") end
end

local function requireUtc(value, name, lineNumber)
    requireNonempty(value, name, lineNumber)
    local year, month, day, hour, minute, second = value:match(
        "^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)Z$"
    )
    if not year then
        year, month, day, hour, minute, second = value:match(
            "^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)%.%d+Z$"
        )
    end
    if not year then
        manifestError(lineNumber, name .. " 必须是 UTC RFC3339 时间")
    end
    year, month, day = tonumber(year), tonumber(month), tonumber(day)
    hour, minute, second = tonumber(hour), tonumber(minute), tonumber(second)
    local monthDays = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
    if year % 4 == 0 and (year % 100 ~= 0 or year % 400 == 0) then monthDays[2] = 29 end
    if month < 1 or month > 12 or day < 1 or day > monthDays[month]
        or hour > 23 or minute > 59 or second > 60 then
        manifestError(lineNumber, name .. " 不是有效的 UTC RFC3339 时间")
    end
end

local function requireFiniteOptional(value, name, lineNumber, minimum)
    if value == nil then return end
    if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge
        or (minimum ~= nil and value < minimum) then
        manifestError(lineNumber, name .. " 必须是有效数字")
    end
end

local function validateHeader(header, lineNumber)
    if header.type ~= "header" then manifestError(lineNumber, "首行 type 必须是 header") end
    if header.format ~= Manifest.FORMAT then manifestError(lineNumber, "format 不受支持") end
    requireType(header.schemaVersion, "table", "schemaVersion", lineNumber)
    local major = requireInteger(header.schemaVersion.major, "schemaVersion.major", lineNumber)
    requireInteger(header.schemaVersion.minor, "schemaVersion.minor", lineNumber)
    if major ~= Manifest.SCHEMA_MAJOR then
        manifestError(lineNumber, "schemaVersion.major 不受支持")
    end
    requireUuid(header.manifestID, "manifestID", lineNumber)
    requireUuid(header.activityID, "activityID", lineNumber)
    requireInteger(header.revision, "revision", lineNumber, 1)
    requireUtc(header.createdAtUTC, "createdAtUTC", lineNumber)
    requireNonempty(header.appVersion, "appVersion", lineNumber)
    requireNonempty(header.algorithmVersion, "algorithmVersion", lineNumber)
    requireInteger(header.recordCount, "recordCount", lineNumber)
    requireNonempty(header.rootDisplayName, "rootDisplayName", lineNumber)
    if header.priorPayloadSHA256 ~= nil then
        requireSha256(header.priorPayloadSHA256, "priorPayloadSHA256", lineNumber)
    end
end

local function validateFileIdentity(identity, lineNumber)
    requireType(identity, "table", "fileIdentity", lineNumber)
    requireInteger(identity.byteCount, "fileIdentity.byteCount", lineNumber)
    requireNonempty(identity.exifDateTimeOriginal, "fileIdentity.exifDateTimeOriginal", lineNumber)
    optionalString(identity.subsecondTimeOriginal, "fileIdentity.subsecondTimeOriginal", lineNumber)
    optionalString(identity.offsetTimeOriginal, "fileIdentity.offsetTimeOriginal", lineNumber)
    optionalString(identity.make, "fileIdentity.make", lineNumber)
    optionalString(identity.model, "fileIdentity.model", lineNumber)
    optionalString(identity.serialNumber, "fileIdentity.serialNumber", lineNumber)
    optionalString(identity.internalSerialNumber, "fileIdentity.internalSerialNumber", lineNumber)
    if identity.shutterCount ~= nil then
        requireInteger(identity.shutterCount, "fileIdentity.shutterCount", lineNumber)
    end
end

local function validateDecision(decision, lineNumber)
    requireType(decision, "table", "decision", lineNumber)
    requireNonempty(decision.confidence, "decision.confidence", lineNumber)
    requireNonempty(decision.method, "decision.method", lineNumber)
    requireNonempty(decision.granularity, "decision.granularity", lineNumber)
    local verification = requireNonempty(decision.verification, "decision.verification", lineNumber)
    if verification ~= "automatic" and verification ~= "userConfirmed" and verification ~= "manual" then
        manifestError(lineNumber, "decision.verification 不受支持")
    end
    requireNonempty(decision.ruleVersion, "decision.ruleVersion", lineNumber)
    requireFiniteOptional(decision.estimatedRadiusMeters, "decision.estimatedRadiusMeters", lineNumber, 0)
    requireFiniteOptional(decision.temporalDistanceSeconds, "decision.temporalDistanceSeconds", lineNumber, 0)
    optionalString(decision.evidenceSummary, "decision.evidenceSummary", lineNumber)
    if decision.trackFileSHA256 ~= nil then
        requireSha256(decision.trackFileSHA256, "decision.trackFileSHA256", lineNumber)
    end
end

local function unsignedRecordLine(rawLine, digest, lineNumber)
    local escapedDigest = digest:gsub("(%W)", "%%%1")
    local unsigned, replacements = rawLine:gsub(
        ',"recordDigestSHA256":"' .. escapedDigest .. '"',
        "",
        1
    )
    if replacements ~= 1 then
        manifestError(lineNumber, "无法定位规范的 recordDigestSHA256 字段")
    end
    return unsigned
end

local function validateAsset(asset, rawLine, lineNumber, sha256)
    if asset.type ~= "asset" then manifestError(lineNumber, "中间行 type 必须是 asset") end
    requireUuid(asset.recordID, "recordID", lineNumber)
    requireNonempty(asset.relativePath, "relativePath", lineNumber)
    local _, pathError = PathPolicy.validateRelative(asset.relativePath)
    if pathError then manifestError(lineNumber, pathError) end
    validateFileIdentity(asset.fileIdentity, lineNumber)
    requireUtc(asset.correctedCaptureTimeUTC, "correctedCaptureTimeUTC", lineNumber)
    local normalized, geoError = Geo.validate(asset.location)
    if not normalized then manifestError(lineNumber, geoError) end
    asset.location = normalized
    validateDecision(asset.decision, lineNumber)
    requireSha256(asset.recordDigestSHA256, "recordDigestSHA256", lineNumber)
    local unsigned = unsignedRecordLine(rawLine, asset.recordDigestSHA256, lineNumber)
    if sha256(unsigned) ~= asset.recordDigestSHA256 then
        manifestError(lineNumber, "recordDigestSHA256 校验失败")
    end
end

local function validateTrailer(trailer, lineNumber)
    if trailer.type ~= "trailer" then manifestError(lineNumber, "末行 type 必须是 trailer") end
    requireInteger(trailer.recordCount, "recordCount", lineNumber)
    requireSha256(trailer.payloadSHA256, "payloadSHA256", lineNumber)
end

function Manifest.parse(contents, sha256, limits)
    requireType(contents, "string", "contents")
    if type(sha256) ~= "function" then error("Manifest.parse 需要 SHA-256 函数", 0) end
    limits = limits or {}
    if #contents == 0 then manifestError(nil, "文件为空") end
    if #contents > (limits.maxBytes or 33554432) then manifestError(nil, "文件超过安全大小限制") end
    if contents:find("\r", 1, true) then manifestError(nil, "只允许 LF 换行") end
    if contents:sub(-1) ~= "\n" then manifestError(nil, "末行必须以 LF 结束") end

    local lines = {}
    for line in contents:gmatch("([^\n]*)\n") do
        if line == "" then manifestError(#lines + 1, "不允许空行") end
        lines[#lines + 1] = line
    end
    if #lines < 2 then manifestError(nil, "至少需要 header 与 trailer") end
    if #lines - 2 > (limits.maxRecords or 1000000) then
        manifestError(nil, "记录数超过安全限制")
    end

    local decoded = {}
    for index, line in ipairs(lines) do
        local ok, value = pcall(Json.decode, line, { canonical = true, maxDepth = 32 })
        if not ok then manifestError(index, value) end
        if type(value) ~= "table" then manifestError(index, "物理行必须是 JSON 对象") end
        decoded[index] = value
    end

    local header = decoded[1]
    local trailer = decoded[#decoded]
    validateHeader(header, 1)
    validateTrailer(trailer, #decoded)

    local assets = {}
    local seenPaths = {}
    local seenRecordIds = {}
    local payloadParts = { lines[1], "\n" }
    for index = 2, #decoded - 1 do
        local asset = decoded[index]
        validateAsset(asset, lines[index], index, sha256)
        if seenPaths[asset.relativePath] then
            manifestError(index, "relativePath 重复")
        end
        if seenRecordIds[asset.recordID] then
            manifestError(index, "recordID 重复")
        end
        seenPaths[asset.relativePath] = true
        seenRecordIds[asset.recordID] = true
        assets[#assets + 1] = asset
        payloadParts[#payloadParts + 1] = lines[index]
        payloadParts[#payloadParts + 1] = "\n"
    end
    if header.recordCount ~= #assets or trailer.recordCount ~= #assets then
        manifestError(nil, "header/trailer 的 recordCount 与 asset 行数不一致")
    end
    if sha256(table.concat(payloadParts)) ~= trailer.payloadSHA256 then
        manifestError(#decoded, "payloadSHA256 校验失败")
    end

    return {
        header = header,
        assets = assets,
        trailer = trailer,
    }
end

function Manifest.read(path, fileAdapter, sha256, limits)
    limits = limits or {}
    local digest = type(sha256) == "table" and sha256.digest or sha256
    local newDigest = type(sha256) == "table" and sha256.new or nil
    if not fileAdapter.openLines or type(newDigest) ~= "function" then
        local contents, readError = fileAdapter.read(path)
        if not contents then error("无法读取清单：" .. tostring(readError), 0) end
        local parsed = Manifest.parse(contents, digest, limits)
        parsed.path = path
        parsed.root = fileAdapter.parent(path)
        return parsed
    end

    local reader, openError = fileAdapter.openLines(path)
    if not reader then error("无法读取清单：" .. tostring(openError), 0) end
    local function closeReader() pcall(reader.close) end
    local ok, result = pcall(function()
        if reader.byteCount == 0 then manifestError(nil, "文件为空") end
        if reader.byteCount > (limits.maxBytes or 33554432) then
            manifestError(nil, "文件超过安全大小限制")
        end
        if not reader.hasTrailingLF then manifestError(nil, "末行必须以 LF 结束") end

        local lineNumber = 1
        local headerLine = reader.nextLine()
        if not headerLine or headerLine == "" then manifestError(1, "缺少 header") end
        if headerLine:find("\r", 1, true) then manifestError(1, "只允许 LF 换行") end
        if #headerLine > (limits.maxLineBytes or 1048576) then manifestError(1, "物理行过长") end
        local headerOk, header = pcall(Json.decode, headerLine, { canonical = true, maxDepth = 32 })
        if not headerOk then manifestError(1, header) end
        validateHeader(header, 1)

        local payload = newDigest()
        payload:update(headerLine .. "\n")
        local assets = {}
        local seenPaths = {}
        local seenRecordIds = {}
        local trailer = nil
        while true do
            local rawLine = reader.nextLine()
            if rawLine == nil then break end
            lineNumber = lineNumber + 1
            if rawLine == "" then manifestError(lineNumber, "不允许空行") end
            if rawLine:find("\r", 1, true) then manifestError(lineNumber, "只允许 LF 换行") end
            if #rawLine > (limits.maxLineBytes or 1048576) then
                manifestError(lineNumber, "物理行过长")
            end
            local lineOk, value = pcall(Json.decode, rawLine, { canonical = true, maxDepth = 32 })
            if not lineOk then manifestError(lineNumber, value) end
            if type(value) ~= "table" then manifestError(lineNumber, "物理行必须是 JSON 对象") end
            if value.type == "trailer" then
                trailer = value
                validateTrailer(trailer, lineNumber)
                if reader.nextLine() ~= nil then manifestError(lineNumber + 1, "trailer 后仍有内容") end
                break
            end
            validateAsset(value, rawLine, lineNumber, digest)
            if seenPaths[value.relativePath] then manifestError(lineNumber, "relativePath 重复") end
            if seenRecordIds[value.recordID] then manifestError(lineNumber, "recordID 重复") end
            seenPaths[value.relativePath] = true
            seenRecordIds[value.recordID] = true
            assets[#assets + 1] = value
            if #assets > (limits.maxRecords or 1000000) then
                manifestError(lineNumber, "记录数超过安全限制")
            end
            payload:update(rawLine .. "\n")
        end
        if not trailer then manifestError(nil, "缺少 trailer") end
        if header.recordCount ~= #assets or trailer.recordCount ~= #assets then
            manifestError(nil, "header/trailer 的 recordCount 与 asset 行数不一致")
        end
        if payload:finish() ~= trailer.payloadSHA256 then
            manifestError(lineNumber, "payloadSHA256 校验失败")
        end
        return {
            header = header,
            assets = assets,
            trailer = trailer,
            path = path,
            root = fileAdapter.parent(path),
        }
    end)
    closeReader()
    if not ok then error(result, 0) end
    return result
end

return Manifest
