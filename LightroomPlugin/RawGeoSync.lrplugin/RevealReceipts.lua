local LrDialogs = import "LrDialogs"
local LrFileUtils = import "LrFileUtils"
local LrShell = import "LrShell"
local LrTasks = import "LrTasks"

local Runtime = require "Runtime"

LrTasks.startAsyncTask(function()
    local directory = Runtime.receiptDirectory()
    LrFileUtils.createAllDirectories(directory)
    LrShell.revealInShell(directory)
    LrDialogs.message(
        "RawGeoSync 撤销收据",
        "已在 Finder 中打开撤销收据文件夹。收据可能包含原 GPS 与拍摄身份信息；只应在确认不再需要跨重启撤销后手工删除。",
        "info"
    )
end)
