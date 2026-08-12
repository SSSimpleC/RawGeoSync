local script = arg[0]
local testDirectory = script:match("^(.*)/[^/]+$") or "."
local pluginDirectory = testDirectory .. "/../RawGeoSync.lrplugin"
package.path = pluginDirectory .. "/?.lua;" .. package.path

local Json = require "JSON"
local Manifest = require "Manifest"
local PathPolicy = require "PathPolicy"
local Planner = require "Planner"
local Receipt = require "Receipt"
local CatalogWriter = require "CatalogWriter"
local UndoWriter = require "UndoWriter"
local SHA256 = require "SHA256"

local metadataDefinition = dofile(pluginDirectory .. "/MetadataDefinition.lua")

local tests = {}
local passed = 0

local function test(name, body)
    tests[#tests + 1] = { name = name, body = body }
end

local function equal(actual, expected, message)
    if actual ~= expected then
        error(string.format("%s：期望 %s，实际 %s", message or "值不相等", tostring(expected), tostring(actual)), 0)
    end
end

local function truthy(value, message)
    if not value then error(message or "期望真值", 0) end
end

local function fails(body, pattern)
    local ok, failure = pcall(body)
    if ok then error("期望失败，实际成功", 0) end
    if pattern and not tostring(failure):find(pattern, 1, true) then
        error("失败信息不包含预期文本：" .. tostring(failure), 0)
    end
end

local function fakeSha(contents)
    local accumulator = 2166136261
    for index = 1, #contents do
        accumulator = (accumulator + contents:byte(index) * (index + 17)) % 4294967296
    end
    return string.format("%08x", accumulator):rep(8)
end

local function fakeShaNew()
    local accumulator = 2166136261
    local position = 0
    return {
        update = function(_, contents)
            for index = 1, #contents do
                accumulator = (accumulator + contents:byte(index) * (position + index + 17)) % 4294967296
            end
            position = position + #contents
        end,
        finish = function() return string.format("%08x", accumulator):rep(8) end,
    }
end

local function memoryLineAdapter(contents)
    return {
        read = function() error("流式路径不应整体读取文件", 0) end,
        parent = function() return "root" end,
        openLines = function()
            local position = 1
            return {
                byteCount = #contents,
                hasTrailingLF = contents:sub(-1) == "\n",
                nextLine = function()
                    if position > #contents then return nil end
                    local newline = contents:find("\n", position, true)
                    local line = contents:sub(position, newline - 1)
                    position = newline + 1
                    return line
                end,
                close = function() return true end,
            }
        end,
    }
end

local function uuid(number)
    return string.format("00000000-0000-4000-8000-%012d", number)
end

local function baseAsset(number, path, altitude)
    local location = {
        latitude = 10 + (number % 1000) / 10000,
        longitude = 20 + (number % 1000) / 10000,
    }
    if altitude ~= nil then location.altitude = altitude end
    return {
        type = "asset",
        recordID = uuid(number),
        relativePath = path,
        fileIdentity = {
            byteCount = 1000 + number,
            exifDateTimeOriginal = "2026:08:08 10:00:00",
        },
        correctedCaptureTimeUTC = "2026-08-08T02:00:00Z",
        location = location,
        decision = {
            confidence = "reliable",
            method = "nearestTrackPoint",
            granularity = "trackPoint",
            verification = "automatic",
            ruleVersion = "1.0",
        },
    }
end

local function manifestText(assetValues)
    local lines = {}
    local header = {
        type = "header",
        format = Manifest.FORMAT,
        schemaVersion = { major = 1, minor = 0 },
        manifestID = uuid(900001),
        activityID = uuid(900002),
        revision = 1,
        createdAtUTC = "2026-08-08T03:00:00Z",
        appVersion = "0.3.0",
        algorithmVersion = "2.0",
        recordCount = #assetValues,
        rootDisplayName = "activity",
    }
    lines[1] = Json.encode(header)
    for _, asset in ipairs(assetValues) do
        local unsigned = Json.encode(asset)
        asset.recordDigestSHA256 = fakeSha(unsigned)
        lines[#lines + 1] = Json.encode(asset)
    end
    local payload = table.concat(lines, "\n") .. "\n"
    lines[#lines + 1] = Json.encode {
        type = "trailer",
        recordCount = #assetValues,
        payloadSHA256 = fakeSha(payload),
    }
    return table.concat(lines, "\n") .. "\n"
end

local function parsedManifest(assetValues)
    return Manifest.parse(manifestText(assetValues), fakeSha)
end

test("JSON 拒绝重复键与非规范空白", function()
    fails(function() Json.decode('{"a":1,"a":2}') end, "重复键")
    fails(function() Json.decode('{"a": 1}', { canonical = true }) end, "结构性空白")
    equal(Json.decode('{"a":"\\ud83d\\ude00"}').a, "😀", "代理项解码")
end)

test("JSON 规范编码按键排序", function()
    equal(Json.encode { z = 1, a = true }, '{"a":true,"z":1}', "键排序")
    equal(Json.encode(Json.array()), "[]", "空数组")
end)

test("纯 Lua SHA-256 通过标准向量", function()
    equal(SHA256.digest(""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", "空字符串")
    equal(SHA256.digest("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "abc")
end)

test("Lightroom metadata provider 注册全部私有字段", function()
    equal(metadataDefinition.schemaVersion, 1, "schemaVersion")
    truthy(type(metadataDefinition.metadataFieldsForPhotos) == "table", "必须使用官方 metadataFieldsForPhotos 键")
    equal(#metadataDefinition.metadataFieldsForPhotos, 10, "私有字段数量")
    equal(metadataDefinition.metadataFieldsForPhotos[1].id, "sourceToken", "来源字段")
    equal(metadataDefinition.metadataFieldsForPhotos[1].title, nil, "字段保持私有")
end)

test("路径策略拒绝逃逸、反斜杠、空段和控制字符", function()
    for _, path in ipairs({
        "/absolute.nef", "../escape.nef", "a//b.nef", "a\\b.nef",
        "a/./b.nef", "a\nb.nef", "Cafe\204\129/A.nef",
    }) do
        local segments = PathPolicy.validateRelative(path)
        equal(segments, nil, "应拒绝路径 " .. path)
    end
    local resolved = PathPolicy.resolve("root", "camera/A.nef", {
        child = function(parent, child) return parent .. "/" .. child end,
        standardize = function(path) return path end,
    })
    equal(resolved, "root/camera/A.nef", "精确路径解析")
end)

test("清单校验 header、asset、trailer 与双层摘要", function()
    local parsed = parsedManifest { baseAsset(1, "Z50/A.NEF") }
    equal(#parsed.assets, 1, "记录数量")
    equal(parsed.assets[1].relativePath, "Z50/A.NEF", "相对路径")

    local damaged = manifestText { baseAsset(2, "Z50/B.NEF") }
    damaged = damaged:gsub('"latitude":10%.0002', '"latitude":10.0003', 1)
    fails(function() Manifest.parse(damaged, fakeSha) end, "recordDigestSHA256")
end)

test("Manifest.read 逐行验证且不整体读取文件", function()
    local contents = manifestText { baseAsset(1, "Z50/A.NEF"), baseAsset(2, "Z50/B.NEF") }
    local parsed = Manifest.read("root/RawGeoSync.locations.jsonl", memoryLineAdapter(contents), {
        digest = fakeSha,
        new = fakeShaNew,
    })
    equal(#parsed.assets, 2, "流式记录数")
    equal(parsed.root, "root", "清单根目录")
end)

test("Swift 与 Lua 共享规范 golden 清单", function()
    local goldenPath = testDirectory .. "/../../MetadataInfrastructure/Tests/Fixtures/RawGeoSync.locations.jsonl"
    local file = assert(io.open(goldenPath, "rb"))
    local contents = file:read("*a")
    file:close()
    local parsed = Manifest.parse(contents, SHA256.digest)
    equal(#parsed.assets, 1, "golden 记录数")
    equal(parsed.assets[1].relativePath, "Z50/SYNTHETIC.NEF", "golden 相对路径")
    equal(parsed.trailer.payloadSHA256, "e0bb190c8dcf30f186b91028fe6e823f4adac4d98a1c0eb8f175922cc3df1b54", "golden payload")
end)

test("清单拒绝重复路径和 CRLF", function()
    fails(function()
        Manifest.parse(manifestText {
            baseAsset(1, "Z50/A.NEF"),
            baseAsset(2, "Z50/A.NEF"),
        }, fakeSha)
    end, "relativePath 重复")
    fails(function()
        Manifest.parse(manifestText { baseAsset(1, "Z50/A.NEF") }:gsub("\n", "\r\n"), fakeSha)
    end, "只允许 LF")
end)

test("清单拒绝非法 UUID 与不可能日期", function()
    local invalidUuid = manifestText { baseAsset(1, "Z50/A.NEF") }
    invalidUuid = invalidUuid:gsub(
        uuid(900001):gsub("%-", "%%-"),
        "0000000-00000-4000-8000-000000900001",
        1
    )
    fails(function() Manifest.parse(invalidUuid, fakeSha) end, "UUID")

    local invalidDate = manifestText { baseAsset(1, "Z50/A.NEF") }
    invalidDate = invalidDate:gsub("2026%-08%-08T03:00:00Z", "2026-02-30T03:00:00Z", 1)
    fails(function() Manifest.parse(invalidDate, fakeSha) end, "有效的 UTC")
end)

local Photo = {}
Photo.__index = Photo

function Photo.new(identifier, gps, altitude)
    return setmetatable({
        raw = { uuid = identifier, gps = gps, gpsAltitude = altitude },
        properties = {},
    }, Photo)
end

function Photo:getRawMetadata(field) return self.raw[field] end

function Photo:setRawMetadata(field, value)
    if self.failNextWrite then
        self.failNextWrite = false
        error("injected photo write failure", 0)
    end
    if type(value) == "table" then
        self.raw[field] = { latitude = value.latitude, longitude = value.longitude }
    else
        self.raw[field] = value
    end
end

function Photo:getPropertyForPlugin(_, field) return self.properties[field] end
function Photo:setPropertyForPlugin(_, field, value) self.properties[field] = value end

local metadataFields = {
    "sourceToken", "manifestID", "activityID", "revision", "recordID",
    "source", "quality", "verification", "granularity", "appliedAtUTC",
}

local function planFor(assets, photos, overwrite)
    local manifest = parsedManifest(assets)
    return Planner.build(manifest, {
        resolveExact = function(record)
            local photo = photos[record.relativePath]
            if not photo then return nil end
            return {
                photo = photo,
                path = "root/" .. record.relativePath,
                available = photo.available ~= false,
                byteCount = photo.byteCount or record.fileIdentity.byteCount,
                uuid = photo.raw.uuid,
            }
        end,
    }, {
        pluginId = "plugin",
        metadataFields = metadataFields,
        overwriteDifferentGps = overwrite,
        makeSourceToken = function(record) return "tx:" .. record.recordID end,
    })
end

test("预检精确分类离线、身份不一致、冲突和缺失", function()
    local assets = {
        baseAsset(1, "offline.nef"), baseAsset(2, "changed.nef"),
        baseAsset(3, "conflict.nef"), baseAsset(4, "missing.nef"),
    }
    local offline = Photo.new("offline", nil, nil); offline.available = false
    local changed = Photo.new("changed", nil, nil); changed.byteCount = 999
    local conflict = Photo.new("conflict", { latitude = 1, longitude = 2 }, nil)
    local plan = planFor(assets, {
        ["offline.nef"] = offline,
        ["changed.nef"] = changed,
        ["conflict.nef"] = conflict,
    }, false)
    equal(plan.counts.offline, 1, "离线")
    equal(plan.counts.identityMismatch, 1, "身份不一致")
    equal(plan.counts.conflict, 1, "坐标冲突")
    equal(plan.counts.notInCatalog, 1, "目录缺失")
    equal(#plan.writable, 0, "默认不覆盖")
end)

test("不同清单路径解析到同一目录路径时拒绝重复处理", function()
    local assets = { baseAsset(1, "A.nef"), baseAsset(2, "a.nef") }
    local first = Photo.new("same-photo", nil, nil)
    local manifest = parsedManifest(assets)
    local plan = Planner.build(manifest, {
        resolveExact = function(record)
            return {
                photo = first,
                path = "root/A.nef",
                available = true,
                byteCount = record.fileIdentity.byteCount,
                uuid = "same-photo",
            }
        end,
    }, {
        pluginId = "plugin",
        metadataFields = metadataFields,
        overwriteDifferentGps = false,
        makeSourceToken = function(record) return "tx:" .. record.recordID end,
    })
    equal(#plan.writable, 1, "仅处理一次")
    equal(plan.counts.duplicateResolvedPath, 1, "检测解析重复")
end)

test("目录元数据按 500 张分批预取而非逐字段读取", function()
    local previousImport = _G.import
    _G.import = function(name)
        if name == "LrFileUtils" then return {} end
        if name == "LrPathUtils" then return {} end
        error("unexpected import: " .. name)
    end
    package.loaded.CatalogAdapter = nil
    local CatalogAdapter = require "CatalogAdapter"
    _G.import = previousImport

    local adapter = { resolvedByRecord = {}, resolvedByPhoto = {} }
    adapter.resolveExact = function(record)
        local cached = adapter.resolvedByRecord[record]
        if cached then return cached.result end
        local resolved = { photo = record.photo, available = true, path = record.path }
        adapter.resolvedByRecord[record] = { result = resolved }
        adapter.resolvedByPhoto[record.photo] = { resolved }
        return resolved
    end
    local records = {}
    for index = 1, 1201 do
        records[index] = { photo = Photo.new("photo-" .. index), path = "root/" .. index }
    end
    local rawCalls, propertyCalls = 0, 0
    local catalog = {
        batchGetRawMetadata = function(_, photos)
            rawCalls = rawCalls + 1
            local result = {}
            for _, photo in ipairs(photos) do
                result[photo] = { uuid = photo.raw.uuid }
            end
            return result
        end,
        batchGetPropertyForPlugin = function(_, photos)
            propertyCalls = propertyCalls + 1
            local result = {}
            for _, photo in ipairs(photos) do result[photo] = {} end
            return result
        end,
    }
    CatalogAdapter.prefetch(adapter, catalog, records, "plugin", metadataFields, 500)
    equal(rawCalls, 3, "原始元数据批次数")
    equal(propertyCalls, 3, "插件元数据批次数")
    equal(adapter.resolvedByRecord[records[1201]].result.uuid, "photo-1201", "批量 UUID")
end)

test("清单无海拔时保留照片现有海拔", function()
    local asset = baseAsset(1, "A.nef")
    local photo = Photo.new("photo-a", { latitude = 1, longitude = 2 }, 123.5)
    local plan = planFor({ asset }, { ["A.nef"] = photo }, true)
    equal(plan.writable[1].desired.altitude, 123.5, "有效海拔")
end)

local function clone(value, seen)
    if type(value) ~= "table" then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local copy = {}
    seen[value] = copy
    for key, child in pairs(value) do copy[clone(key, seen)] = clone(child, seen) end
    return copy
end

local function fakeCatalog(photos)
    return {
        photos = photos,
        withWriteAccessDo = function(self, _, body)
            local snapshots = {}
            for _, photo in pairs(self.photos) do
                snapshots[photo] = { raw = clone(photo.raw), properties = clone(photo.properties) }
            end
            local ok, failure = pcall(body)
            if not ok then
                for photo, snapshot in pairs(snapshots) do
                    photo.raw = snapshot.raw
                    photo.properties = snapshot.properties
                end
                error(failure, 0)
            end
        end,
        findPhotoByUuid = function(self, identifier)
            for _, photo in pairs(self.photos) do
                if photo.raw.uuid == identifier then return photo end
            end
            return nil
        end,
        batchGetRawMetadata = function(_, batch, fields)
            local result = {}
            for _, photo in ipairs(batch) do
                result[photo] = {}
                for _, field in ipairs(fields) do result[photo][field] = photo.raw[field] end
            end
            return result
        end,
        batchGetPropertyForPlugin = function(_, batch, _, fields)
            local result = {}
            for _, photo in ipairs(batch) do
                result[photo] = {}
                for _, field in ipairs(fields) do result[photo][field] = photo.properties[field] end
            end
            return result
        end,
    }
end

local function memoryReceiptAdapter()
    local storage = {}
    return {
        storage = storage,
        append = function(path, contents)
            storage[path] = (storage[path] or "") .. contents
            return true
        end,
    }
end

local function progress(cancelAt)
    return {
        calls = 0,
        isCanceled = function(self)
            self.calls = self.calls + 1
            return cancelAt ~= nil and self.calls >= cancelAt
        end,
        setPortionComplete = function() end,
    }
end

local function writerOptions(catalog, receiptAdapter, progressValue)
    return {
        catalog = catalog,
        pluginId = "plugin",
        metadataFields = metadataFields,
        receiptPath = "receipt.jsonl",
        receiptAdapter = receiptAdapter,
        transactionID = "transaction-1",
        catalogToken = "catalog-1",
        appliedAtUTC = "2026-08-08T03:00:00Z",
        progress = progressValue or progress(),
        batchSize = 2,
    }
end

test("批量写入会写 GPS、来源令牌并复读验证", function()
    local asset = baseAsset(1, "A.nef")
    local photo = Photo.new("photo-a", nil, 88)
    local plan = planFor({ asset }, { ["A.nef"] = photo }, false)
    local receipts = memoryReceiptAdapter()
    local result = CatalogWriter.apply(plan, writerOptions(fakeCatalog({ photo }), receipts, progress()))
    equal(result.applied, 1, "写入数量")
    equal(result.verified, 1, "验证数量")
    equal(photo.raw.gpsAltitude, 88, "保留海拔")
    truthy(photo.properties.sourceToken, "来源令牌")
    truthy(receipts.storage["receipt.jsonl"]:find("batchCommitted", 1, true), "提交收据")
end)

test("Lightroom 写入使用可让出保护调用并显式等待目录写锁", function()
    local asset = baseAsset(1, "A.nef")
    local photo = Photo.new("photo-a", nil, nil)
    local plan = planFor({ asset }, { ["A.nef"] = photo }, false)
    local catalog = fakeCatalog({ photo })
    local baseWrite = catalog.withWriteAccessDo
    local timeoutSeen = nil
    catalog.withWriteAccessDo = function(self, actionName, body, timeoutParameters)
        timeoutSeen = timeoutParameters and timeoutParameters.timeout or nil
        return baseWrite(self, actionName, body)
    end
    local protectedCalls = 0
    local options = writerOptions(catalog, memoryReceiptAdapter(), progress())
    options.protectedCall = function(body, ...)
        protectedCalls = protectedCalls + 1
        return pcall(body, ...)
    end
    local result = CatalogWriter.apply(plan, options)
    equal(result.verified, 1, "验证数量")
    equal(timeoutSeen, 30, "写锁等待秒数")
    truthy(protectedCalls >= 2, "写入和复读都使用可让出保护调用")
end)

test("正常写入复读每批只调用两次 batch API", function()
    local assets, photos, map = {}, {}, {}
    for index = 1, 3 do
        local path = string.format("%d.nef", index)
        assets[index] = baseAsset(index, path)
        photos[index] = Photo.new("photo-" .. index, nil, nil)
        map[path] = photos[index]
    end
    local catalog = fakeCatalog(photos)
    local rawCalls, propertyCalls = 0, 0
    local raw = catalog.batchGetRawMetadata
    local properties = catalog.batchGetPropertyForPlugin
    catalog.batchGetRawMetadata = function(...)
        rawCalls = rawCalls + 1
        return raw(...)
    end
    catalog.batchGetPropertyForPlugin = function(...)
        propertyCalls = propertyCalls + 1
        return properties(...)
    end
    local result = CatalogWriter.apply(
        planFor(assets, map, false),
        writerOptions(catalog, memoryReceiptAdapter(), progress())
    )
    equal(result.verified, 3, "验证数量")
    equal(rawCalls, 2, "每个写入批次一次 raw batch")
    equal(propertyCalls, 2, "每个写入批次一次 property batch")
end)

test("后续批次失败会自动恢复此前成功批次", function()
    local assets, photos = {}, {}
    for index = 1, 3 do
        assets[index] = baseAsset(index, string.format("%d.nef", index))
        photos[index] = Photo.new("photo-" .. index, nil, 50 + index)
    end
    local map = { ["1.nef"] = photos[1], ["2.nef"] = photos[2], ["3.nef"] = photos[3] }
    local plan = planFor(assets, map, false)
    photos[3].failNextWrite = true
    local result = CatalogWriter.apply(plan, writerOptions(fakeCatalog(photos), memoryReceiptAdapter(), progress()))
    equal(result.committed, 2, "此前提交")
    equal(result.rolledBack, 2, "自动恢复")
    equal(result.applied, 0, "最终零写入")
    equal(photos[1].raw.gps, nil, "第一张恢复 GPS")
    equal(photos[1].raw.gpsAltitude, 51, "第一张恢复海拔")
    equal(photos[1].properties.sourceToken, nil, "第一张恢复来源")
end)

test("用户取消会自动恢复此前成功批次", function()
    local assets, photos, map = {}, {}, {}
    for index = 1, 3 do
        local path = string.format("%d.nef", index)
        assets[index] = baseAsset(index, path)
        photos[index] = Photo.new("photo-" .. index, nil, nil)
        map[path] = photos[index]
    end
    local plan = planFor(assets, map, false)
    local result = CatalogWriter.apply(plan, writerOptions(fakeCatalog(photos), memoryReceiptAdapter(), progress(5)))
    truthy(result.canceled, "应识别取消")
    equal(result.applied, 0, "取消后无残留写入")
    equal(result.rolledBack, 2, "恢复第一批")
end)

test("复读 API 失败会自动恢复当前与此前成功批次", function()
    local asset = baseAsset(1, "A.nef")
    local photo = Photo.new("photo-a", nil, 66)
    local plan = planFor({ asset }, { ["A.nef"] = photo }, false)
    local catalog = fakeCatalog({ photo })
    catalog.batchGetRawMetadata = function() error("injected batch read failure", 0) end
    local result = CatalogWriter.apply(plan, writerOptions(catalog, memoryReceiptAdapter(), progress()))
    equal(result.applied, 0, "复读失败后零残留")
    equal(result.rolledBack, 1, "恢复已提交照片")
    equal(photo.raw.gps, nil, "恢复 GPS")
    equal(photo.raw.gpsAltitude, 66, "恢复海拔")
end)

test("崩溃遗留的不完整收据尾行会被忽略", function()
    local adapter = memoryReceiptAdapter()
    Receipt.append("r", {
        kind = "transactionPrepared",
        transactionID = "tx",
        catalogToken = "catalog",
        manifestID = "manifest",
    }, adapter)
    adapter.storage.r = adapter.storage.r .. '{"kind":"batchPrepared"'
    local events = Receipt.parse(adapter.storage.r)
    equal(#events, 1, "仅采用完整物理行")
end)

test("撤销仅恢复来源令牌与 after GPS 都未改变的照片", function()
    local asset = baseAsset(1, "A.nef")
    local photo = Photo.new("photo-a", nil, 75)
    local plan = planFor({ asset }, { ["A.nef"] = photo }, false)
    local receipts = memoryReceiptAdapter()
    CatalogWriter.apply(plan, writerOptions(fakeCatalog({ photo }), receipts, progress()))
    local state = Receipt.undoState(Receipt.parse(receipts.storage["receipt.jsonl"]))
    local catalog = fakeCatalog({ photo })
    local preflight = UndoWriter.preflight(state, { catalog = catalog, pluginId = "plugin" })
    equal(#preflight.eligible, 1, "可撤销")
    local result = UndoWriter.apply(state, preflight, {
        catalog = catalog,
        pluginId = "plugin",
        metadataFields = metadataFields,
        receiptPath = "receipt.jsonl",
        receiptAdapter = receipts,
        undoID = "undo-1",
        progress = progress(),
        batchSize = 200,
    })
    equal(result.restored, 1, "恢复数量")
    equal(photo.raw.gps, nil, "恢复空 GPS")
    equal(photo.raw.gpsAltitude, 75, "恢复旧海拔")
    equal(photo.properties.sourceToken, nil, "清除来源令牌")

    local changed = Photo.new("photo-a", { latitude = 1, longitude = 2 }, nil)
    changed.properties.sourceToken = "different"
    local unsafe = UndoWriter.preflight({ items = { state.items[1] } }, {
        catalog = fakeCatalog({ changed }), pluginId = "plugin",
    })
    equal(#unsafe.eligible, 0, "外部修改不可撤销")
    equal(unsafe.skippedChanged, 1, "安全跳过")
end)

for _, entry in ipairs(tests) do
    local ok, failure = xpcall(entry.body, debug.traceback)
    if ok then
        passed = passed + 1
        io.write("PASS  ", entry.name, "\n")
    else
        io.stderr:write("FAIL  ", entry.name, "\n", tostring(failure), "\n")
    end
end

io.write(string.format("\n%d/%d tests passed\n", passed, #tests))
if passed ~= #tests then os.exit(1) end

if arg[1] == "--benchmark" then
    local recordCount = tonumber(arg[2]) or 10000
    local assets = {}
    for index = 1, recordCount do
        assets[index] = baseAsset(index, string.format("Z50/%06d.NEF", index))
    end
    local contents = manifestText(assets)
    assets = nil
    collectgarbage("collect")
    local beforeKiB = collectgarbage("count")
    local started = os.clock()
    local parsed = Manifest.read("root/RawGeoSync.locations.jsonl", memoryLineAdapter(contents), {
        digest = fakeSha,
        new = fakeShaNew,
    })
    local elapsed = os.clock() - started
    collectgarbage("collect")
    local afterKiB = collectgarbage("count")
    io.write(string.format(
        "BENCH records=%d bytes=%d luaKiBBefore=%.0f luaKiBAfter=%.0f retainedDeltaKiB=%.0f seconds=%.3f parsed=%d\n",
        recordCount,
        #contents,
        beforeKiB,
        afterKiB,
        afterKiB - beforeKiB,
        elapsed,
        #parsed.assets
    ))
end
