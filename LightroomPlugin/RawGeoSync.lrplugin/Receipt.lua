local Json = require "JSON"

local Receipt = {}

Receipt.FORMAT = "com.sssimplec.rawgeosync.lightroom-receipt"
Receipt.VERSION = 1

function Receipt.nullable(value)
    if value == nil then return Json.null end
    return value
end

function Receipt.append(path, event, fileAdapter)
    event.receiptFormat = Receipt.FORMAT
    event.receiptVersion = Receipt.VERSION
    local line = Json.encode(event) .. "\n"
    local ok, appendError = fileAdapter.append(path, line)
    if not ok then error("无法持久化事务收据：" .. tostring(appendError), 0) end
end

function Receipt.parse(contents)
    if type(contents) ~= "string" or contents == "" then error("事务收据为空", 0) end
    if contents:find("\r", 1, true) then error("事务收据包含无效换行", 0) end
    local events = {}
    for line in contents:gmatch("([^\n]*)\n") do
        if line == "" then error("事务收据包含空行", 0) end
        local event = Json.decode(line, { canonical = true, maxDepth = 32 })
        if type(event) ~= "table"
            or event.receiptFormat ~= Receipt.FORMAT
            or event.receiptVersion ~= Receipt.VERSION then
            error("事务收据格式不受支持", 0)
        end
        events[#events + 1] = event
    end
    if #events == 0 or events[1].kind ~= "transactionPrepared" then
        error("事务收据缺少 transactionPrepared", 0)
    end
    return events
end

function Receipt.undoState(events)
    local header = events[1]
    local prepared = {}
    local order = {}
    local aborted = {}
    for _, event in ipairs(events) do
        if event.transactionID ~= header.transactionID then
            error("事务收据混入其他 transactionID", 0)
        end
        if event.kind == "batchPrepared" then
            if prepared[event.batchID] then error("事务收据 batchID 重复", 0) end
            prepared[event.batchID] = event
            order[#order + 1] = event.batchID
        elseif event.kind == "batchAborted" then
            aborted[event.batchID] = true
        end
    end
    local items = {}
    for _, batchID in ipairs(order) do
        if not aborted[batchID] then
            local event = prepared[batchID]
            if type(event.items) ~= "table" then error("batchPrepared 缺少 items", 0) end
            for _, item in ipairs(event.items) do items[#items + 1] = item end
        end
    end
    return {
        transactionID = header.transactionID,
        catalogToken = header.catalogToken,
        manifestID = header.manifestID,
        items = items,
    }
end

return Receipt
