local LrApplication = import "LrApplication"
local LrDialogs = import "LrDialogs"

local Constants = require "Constants"
local Runtime = require "Runtime"

local Support = {}

function Support.catalog()
    return LrApplication.activeCatalog()
end

function Support.getOrCreateCatalogToken(catalog)
    local token = catalog:getPropertyForPlugin(_PLUGIN, Constants.CATALOG_TOKEN_FIELD)
    if token then return token end
    token = Runtime.uniqueId("catalog")
    local executed = false
    catalog:withPrivateWriteAccessDo(function()
        executed = true
        local current = catalog:getPropertyForPlugin(_PLUGIN, Constants.CATALOG_TOKEN_FIELD)
        if current then token = current
        else catalog:setPropertyForPlugin(_PLUGIN, Constants.CATALOG_TOKEN_FIELD, token) end
    end, { timeout = 30 })
    if not executed then error("等待 Lightroom 私有目录写锁超时", 0) end
    return token
end

function Support.showError(title, value)
    LrDialogs.message(title, tostring(value), "critical")
end

function Support.summaryCounts(counts)
    return table.concat({
        string.format("新增写入：%d", counts.ready or 0),
        string.format("已有相同坐标：%d", counts.alreadySame or 0),
        string.format("已有不同坐标：%d", counts.conflict or 0),
        string.format("不在当前目录：%d", counts.notInCatalog or 0),
        string.format("原文件离线：%d", counts.offline or 0),
        string.format("文件身份不一致：%d", counts.identityMismatch or 0),
        string.format("路径解析重复：%d", counts.duplicateResolvedPath or 0),
        string.format("因“仅当前选择”跳过：%d", counts.notSelected or 0),
    }, "\n")
end

return Support
