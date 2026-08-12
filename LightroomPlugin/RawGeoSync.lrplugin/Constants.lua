local Constants = {}

Constants.PLUGIN_ID = "com.sssimplec.rawgeosync.lightroom"
Constants.RECEIPT_DIRECTORY = "RawGeoSync/LightroomBridge/Receipts"
Constants.CATALOG_TOKEN_FIELD = "catalogToken"
Constants.METADATA_FIELDS = {
    "sourceToken",
    "manifestID",
    "activityID",
    "revision",
    "recordID",
    "source",
    "quality",
    "verification",
    "granularity",
    "appliedAtUTC",
}

return Constants
