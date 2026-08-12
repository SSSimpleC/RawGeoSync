local VERSION = {}
VERSION.major = 0
VERSION.minor = 3
VERSION.revision = 0
VERSION.build = 1

return {
    LrSdkVersion = 6.0,
    LrSdkMinimumVersion = 6.0,
    LrToolkitIdentifier = "com.sssimplec.rawgeosync.lightroom",
    LrPluginName = "RawGeoSync Lightroom Bridge",
    LrPluginInfoUrl = "https://github.com/sssimplec/RawGeoSync",
    LrPluginInfoProvider = "PluginInfoProvider.lua",
    LrMetadataProvider = "MetadataDefinition.lua",
    VERSION = VERSION,
    LrLibraryMenuItems = {
        {
            title = "RawGeoSync：导入位置清单…",
            file = "ImportLocations.lua",
        },
        {
            title = "RawGeoSync：撤销最近一次导入…",
            file = "UndoImport.lua",
        },
        {
            title = "RawGeoSync：打开撤销收据文件夹…",
            file = "RevealReceipts.lua",
        },
    },
}
