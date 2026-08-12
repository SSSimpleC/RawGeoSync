local LrFileUtils = import "LrFileUtils"
local LrPathUtils = import "LrPathUtils"

local SHA256 = require "SHA256"

local function normalizeDigest(digest)
    if type(digest) ~= "string" then return nil end
    if #digest == 64 and digest:match("^[0-9a-fA-F]+$") then
        return string.lower(digest)
    elseif #digest == 32 then
        return (digest:gsub(".", function(byte) return string.format("%02x", byte:byte()) end))
    end
    return nil
end

local nativeSHA256 = nil
local nativeSHA256Init = nil
local nativeOk, LrDigest = pcall(import, "LrDigest")
if nativeOk and LrDigest and LrDigest.SHA256 and type(LrDigest.SHA256.digest) == "function" then
    local candidate = LrDigest.SHA256.digest
    local digestOk, emptyDigest = pcall(candidate, "")
    if digestOk
        and normalizeDigest(emptyDigest) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" then
        nativeSHA256 = candidate
    end
    if type(LrDigest.SHA256.init) == "function" then
        local initOk, context = pcall(LrDigest.SHA256.init)
        if initOk and context and type(context.update) == "function" and type(context.digest) == "function" then
            local checkOk, checkDigest = pcall(function()
                context:update("")
                return context:digest()
            end)
            if checkOk
                and normalizeDigest(checkDigest) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" then
                nativeSHA256Init = LrDigest.SHA256.init
            end
        end
    end
end

local Runtime = {}

Runtime.path = {
    child = function(parent, child) return LrPathUtils.child(parent, child) end,
    parent = function(path) return LrPathUtils.parent(path) end,
    standardize = function(path) return LrPathUtils.standardizePath(path) end,
}

Runtime.files = {
    read = function(path)
        local ok, value = pcall(LrFileUtils.readFile, path)
        if ok then return value end
        return nil, value
    end,
    parent = function(path) return LrPathUtils.parent(path) end,
    exists = function(path) return LrFileUtils.exists(path) == "file" end,
    byteCount = function(path)
        local attributes = LrFileUtils.fileAttributes(path)
        return attributes and attributes.fileSize or nil
    end,
    openLines = function(path)
        local file, openError = io.open(path, "rb")
        if not file then return nil, openError end
        local byteCount = file:seek("end")
        local hasTrailingLF = false
        if byteCount and byteCount > 0 then
            file:seek("set", byteCount - 1)
            hasTrailingLF = file:read(1) == "\n"
        end
        file:seek("set", 0)
        return {
            byteCount = byteCount or 0,
            hasTrailingLF = hasTrailingLF,
            nextLine = function() return file:read("*l") end,
            close = function() return file:close() end,
        }
    end,
}

Runtime.receipts = {
    append = function(path, contents)
        local parent = LrPathUtils.parent(path)
        local ok, directoryError = pcall(LrFileUtils.createAllDirectories, parent)
        if not ok then return nil, directoryError end
        local file, openError = io.open(path, "ab")
        if not file then return nil, openError end
        local wrote, writeError = file:write(contents)
        if wrote then wrote, writeError = file:flush() end
        local closed, closeError = file:close()
        if not wrote then return nil, writeError end
        if not closed then return nil, closeError end
        return true
    end,
    read = function(path)
        local ok, value = pcall(LrFileUtils.readFile, path)
        if ok then return value end
        return nil, value
    end,
}

function Runtime.sha256(contents)
    if nativeSHA256 then
        local ok, digest = pcall(nativeSHA256, contents)
        if ok and normalizeDigest(digest) then return normalizeDigest(digest) end
        nativeSHA256 = nil
    end
    return SHA256.digest(contents)
end

function Runtime.sha256New()
    if nativeSHA256Init then
        local nativeContext = nativeSHA256Init()
        return {
            update = function(_, contents)
                nativeContext:update(contents)
            end,
            finish = function()
                local digest = normalizeDigest(nativeContext:digest())
                if not digest then error("Lightroom SHA-256 返回了无效摘要", 0) end
                return digest
            end,
        }
    end
    return SHA256.new()
end

function Runtime.nowUtc()
    return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

function Runtime.uniqueId(seed)
    local value = table.concat({
        tostring(seed or ""),
        Runtime.nowUtc(),
        tostring(os.clock()),
        tostring({}),
    }, ":")
    return Runtime.sha256(value):sub(1, 32)
end

function Runtime.receiptPath(transactionID)
    local appData = LrPathUtils.getStandardFilePath("appData")
    local directory = appData
    for segment in ("RawGeoSync/LightroomBridge/Receipts"):gmatch("[^/]+") do
        directory = LrPathUtils.child(directory, segment)
    end
    return LrPathUtils.child(directory, transactionID .. ".jsonl")
end

function Runtime.receiptDirectory()
    local appData = LrPathUtils.getStandardFilePath("appData")
    local directory = appData
    for segment in ("RawGeoSync/LightroomBridge/Receipts"):gmatch("[^/]+") do
        directory = LrPathUtils.child(directory, segment)
    end
    return LrPathUtils.standardizePath(directory)
end

function Runtime.isSafeReceiptPath(path)
    if type(path) ~= "string" or path == "" then return false end
    local standardized = LrPathUtils.standardizePath(path)
    local prefix = Runtime.receiptDirectory()
    if prefix:sub(-1) ~= "/" then prefix = prefix .. "/" end
    return standardized:sub(1, #prefix) == prefix
end

return Runtime
