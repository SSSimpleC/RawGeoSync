local LrView = import "LrView"

return {
    sectionsForTopOfDialog = function(_, propertyTable)
        local factory = LrView.osFactory()
        return {
            {
                title = "RawGeoSync Lightroom Bridge",
                synopsis = "0.3.0（构建 1）",
                factory:row {
                    spacing = factory:control_spacing(),
                    factory:static_text {
                        title = "从 RawGeoSync.locations.jsonl 批量导入 GPS，并提供安全撤销。",
                        fill_horizontal = 1,
                    },
                },
            },
        }
    end,
}
