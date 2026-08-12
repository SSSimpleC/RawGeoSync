local LrBinding = import "LrBinding"
local LrDialogs = import "LrDialogs"
local LrFunctionContext = import "LrFunctionContext"
local LrPathUtils = import "LrPathUtils"
local LrPrefs = import "LrPrefs"
local LrProgressScope = import "LrProgressScope"
local LrTasks = import "LrTasks"
local LrView = import "LrView"

local CatalogAdapter = require "CatalogAdapter"
local CatalogWriter = require "CatalogWriter"
local Constants = require "Constants"
local Manifest = require "Manifest"
local Planner = require "Planner"
local Runtime = require "Runtime"
local Support = require "ControllerSupport"

local function chooseManifest()
    local paths = LrDialogs.runOpenPanel {
        title = "选择 RawGeoSync 位置清单",
        prompt = "选择清单",
        canChooseFiles = true,
        canChooseDirectories = false,
        allowsMultipleSelection = false,
        fileTypes = { "jsonl" },
    }
    return paths and paths[1] or nil
end

local function makePlan(manifest, adapter, transactionID, overwrite, includePhotoSet)
    return Planner.build(manifest, adapter, {
        pluginId = _PLUGIN,
        metadataFields = Constants.METADATA_FIELDS,
        overwriteDifferentGps = overwrite,
        includePhotoSet = includePhotoSet,
        makeSourceToken = function(record)
            return transactionID .. ":" .. record.recordID
        end,
    })
end

local function confirmPlan(context, plan, selectedCount)
    local factory = LrView.osFactory()
    local properties = LrBinding.makePropertyTable(context)
    properties.selectedOnly = false
    local view = factory:column {
        bind_to_object = properties,
        spacing = factory:control_spacing(),
        factory:static_text {
            title = Support.summaryCounts(plan.counts),
            width_in_chars = 58,
        },
        factory:checkbox {
            title = string.format("仅处理 Lightroom 当前选择（当前 %d 张）", selectedCount),
            value = LrView.bind("selectedOnly"),
            enabled = selectedCount > 0,
        },
        factory:static_text {
            title = string.format(
                "RawGeoSync 将按已确认策略覆盖 %d 张已有不同 GPS 的照片。",
                plan.counts.conflict or 0
            ),
            width_in_chars = 58,
        },
        factory:separator { fill_horizontal = 1 },
        factory:static_text {
            title = "提示：Lightroom SDK 无法可靠检测“自动将更改写入 XMP”。本操作只更新目录；如该选项已开启，Lightroom 可能随后写入旁车文件。建议导入前关闭该选项。",
            width_in_chars = 58,
            height_in_lines = 4,
        },
    }
    local answer = LrDialogs.presentModalDialog {
        title = "RawGeoSync 导入预检",
        contents = view,
        actionVerb = "开始导入",
        cancelVerb = "取消",
    }
    return answer == "ok", properties.selectedOnly
end

local function run(context)
    local manifestPath = chooseManifest()
    if not manifestPath then return end

    local parseProgress = LrProgressScope { title = "正在校验 RawGeoSync 位置清单" }
    parseProgress:setCancelable(false)
    local manifest = Manifest.read(manifestPath, Runtime.files, {
        digest = Runtime.sha256,
        new = Runtime.sha256New,
    })
    parseProgress:done()

    local catalog = Support.catalog()
    local catalogToken = Support.getOrCreateCatalogToken(catalog)
    local transactionID = Runtime.uniqueId(manifest.header.manifestID)
    local catalogAdapter = CatalogAdapter.new(catalog, manifest.root)
    CatalogAdapter.prefetch(
        catalogAdapter,
        catalog,
        manifest.assets,
        _PLUGIN,
        Constants.METADATA_FIELDS,
        500
    )
    local targetPhotos = catalog:getTargetPhotos()
    local selectedSet = {}
    for _, photo in ipairs(targetPhotos) do selectedSet[photo] = true end
    local previewPlan = makePlan(manifest, catalogAdapter, transactionID, false, nil)
    local confirmed, selectedOnly = confirmPlan(context, previewPlan, #targetPhotos)
    if not confirmed then return end
    if selectedOnly then
        local selectedPreview = makePlan(manifest, catalogAdapter, transactionID, false, selectedSet)
        local selectedConfirmation = LrDialogs.confirm(
            "复核 Lightroom 当前选择",
            Support.summaryCounts(selectedPreview.counts)
                .. string.format(
                    "\n\n将覆盖已有不同 GPS：%d 张",
                    selectedPreview.counts.conflict or 0
                ),
            "按当前选择导入",
            "取消"
        )
        if selectedConfirmation ~= "ok" then return end
    end
    local plan = makePlan(
        manifest,
        catalogAdapter,
        transactionID,
        true,
        selectedOnly and selectedSet or nil
    )
    if #plan.writable == 0 then
        LrDialogs.message("RawGeoSync", "预检后没有需要写入的照片。", "info")
        return
    end

    local receiptPath = Runtime.receiptPath(transactionID)
    local prefs = LrPrefs.prefsForPlugin()
    local previousReceiptPath = prefs.latestReceiptPath
    local progress = LrProgressScope {
        title = string.format("正在向 Lightroom 目录写入 %d 张照片的位置", #plan.writable),
    }
    progress:setCancelable(true)
    local result = CatalogWriter.apply(plan, {
        catalog = catalog,
        pluginId = _PLUGIN,
        metadataFields = Constants.METADATA_FIELDS,
        receiptPath = receiptPath,
        receiptAdapter = Runtime.receipts,
        transactionID = transactionID,
        catalogToken = catalogToken,
        appliedAtUTC = Runtime.nowUtc(),
        progress = progress,
        batchSize = 200,
        yield = LrTasks.yield,
        protectedCall = LrTasks.pcall,
        onReceiptPrepared = function(path)
            prefs.previousReceiptPath = previousReceiptPath
            prefs.latestReceiptPath = path
            prefs.latestReceiptCatalogToken = catalogToken
        end,
    })
    progress:done()

    if result.applied == 0 and result.rolledBack == result.committed then
        prefs.latestReceiptPath = previousReceiptPath
        prefs.latestReceiptCatalogToken = nil
        prefs.previousReceiptPath = nil
    end

    local messages = {
        string.format("成功写入并复读验证：%d 张", result.verified),
        string.format("最终保留本次写入：%d 张", result.applied),
        string.format("自动恢复：%d 张", result.rolledBack),
        result.canceled and "状态：用户取消" or "状态：处理完成",
    }
    if result.error then messages[#messages + 1] = "错误：" .. result.error end
    if result.rollbackError then messages[#messages + 1] = "自动恢复异常：" .. result.rollbackError end
    messages[#messages + 1] = "若 Lightroom 地图/位置面板暂未刷新，请重启 Lightroom 后复核；目录元数据复读结果才是本次校验依据。"
    local message = table.concat(messages, "\n")
    LrDialogs.message("RawGeoSync 导入结果", message, result.applied > 0 and "info" or "warning")
end

LrTasks.startAsyncTask(function()
    LrFunctionContext.callWithContext("RawGeoSyncImport", run)
end)
