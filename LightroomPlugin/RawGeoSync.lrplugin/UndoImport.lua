local LrDialogs = import "LrDialogs"
local LrFunctionContext = import "LrFunctionContext"
local LrPrefs = import "LrPrefs"
local LrProgressScope = import "LrProgressScope"
local LrTasks = import "LrTasks"

local Constants = require "Constants"
local Receipt = require "Receipt"
local Runtime = require "Runtime"
local Support = require "ControllerSupport"
local UndoWriter = require "UndoWriter"

local function readState(path)
    if not Runtime.isSafeReceiptPath(path) then error("事务收据路径不安全或已失效", 0) end
    local contents, readError = Runtime.receipts.read(path)
    if not contents then error("无法读取事务收据：" .. tostring(readError), 0) end
    return Receipt.undoState(Receipt.parse(contents))
end

local function run()
    local prefs = LrPrefs.prefsForPlugin()
    local receiptPath = prefs.latestReceiptPath
    if not receiptPath then
        LrDialogs.message("RawGeoSync", "没有可撤销的 RawGeoSync 导入事务。", "info")
        return
    end
    local state = readState(receiptPath)
    if #state.items == 0 and prefs.previousReceiptPath then
        receiptPath = prefs.previousReceiptPath
        state = readState(receiptPath)
    end

    local catalog = Support.catalog()
    local catalogToken = catalog:getPropertyForPlugin(_PLUGIN, Constants.CATALOG_TOKEN_FIELD)
    if type(state.catalogToken) ~= "string" or state.catalogToken ~= catalogToken then
        error("事务收据不属于当前 Lightroom 目录，已拒绝撤销", 0)
    end
    local preflight = UndoWriter.preflight(state, {
        catalog = catalog,
        pluginId = _PLUGIN,
    })
    if #preflight.eligible == 0 then
        LrDialogs.message(
            "RawGeoSync",
            string.format(
                "没有可安全撤销的照片。\n找不到：%d 张\n导入后已改变：%d 张",
                preflight.skippedMissing,
                preflight.skippedChanged
            ),
            "warning"
        )
        return
    end
    local answer = LrDialogs.confirm(
        "撤销最近一次 RawGeoSync 导入？",
        string.format(
            "将恢复 %d 张照片导入前的 GPS。另有 %d 张已被外部修改，将安全跳过。",
            #preflight.eligible,
            preflight.skippedChanged
        ),
        "撤销",
        "取消"
    )
    if answer ~= "ok" then return end

    local progress = LrProgressScope {
        title = string.format("正在恢复 %d 张照片", #preflight.eligible),
    }
    progress:setCancelable(true)
    local result = UndoWriter.apply(state, preflight, {
        catalog = catalog,
        pluginId = _PLUGIN,
        metadataFields = Constants.METADATA_FIELDS,
        receiptPath = receiptPath,
        receiptAdapter = Runtime.receipts,
        undoID = Runtime.uniqueId("undo"),
        progress = progress,
        batchSize = 200,
        yield = LrTasks.yield,
        protectedCall = LrTasks.pcall,
    })
    progress:done()
    LrDialogs.message(
        "RawGeoSync 撤销结果",
        string.format(
            "已恢复：%d 张\n已被修改而跳过：%d 张\n找不到而跳过：%d 张%s",
            result.restored,
            result.skippedChanged,
            result.skippedMissing,
            result.canceled and "\n状态：用户取消" or ""
        ),
        result.error and "warning" or "info"
    )
end

LrTasks.startAsyncTask(function()
    LrFunctionContext.callWithContext("RawGeoSyncUndo", run)
end)
