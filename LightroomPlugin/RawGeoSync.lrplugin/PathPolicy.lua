local PathPolicy = {}

local function decodeCodepoints(value)
    local index = 1
    local length = #value
    local codepoints = {}
    while index <= length do
        local first = value:byte(index)
        local count, codepoint
        if first <= 0x7F then
            count, codepoint = 1, first
        elseif first >= 0xC2 and first <= 0xDF then
            count, codepoint = 2, first - 0xC0
        elseif first >= 0xE0 and first <= 0xEF then
            count, codepoint = 3, first - 0xE0
        elseif first >= 0xF0 and first <= 0xF4 then
            count, codepoint = 4, first - 0xF0
        else
            return nil, "路径不是有效 UTF-8"
        end
        if index + count - 1 > length then return nil, "路径 UTF-8 序列不完整" end
        for offset = 2, count do
            local continuation = value:byte(index + offset - 1)
            if continuation < 0x80 or continuation > 0xBF then
                return nil, "路径不是有效 UTF-8"
            end
            codepoint = codepoint * 0x40 + (continuation - 0x80)
        end
        if (count == 3 and codepoint < 0x800)
            or (count == 4 and codepoint < 0x10000)
            or codepoint > 0x10FFFF
            or (codepoint >= 0xD800 and codepoint <= 0xDFFF) then
            return nil, "路径包含无效 Unicode 码位"
        end
        codepoints[#codepoints + 1] = codepoint
        index = index + count
    end
    return codepoints
end

function PathPolicy.validateRelative(relativePath)
    if type(relativePath) ~= "string" or relativePath == "" then
        return nil, "relativePath 必须是非空字符串"
    end
    if relativePath:sub(1, 1) == "/" or relativePath:match("^%a:") then
        return nil, "relativePath 不得是绝对路径"
    end
    if relativePath:find("\\", 1, true) then
        return nil, "relativePath 只能使用正斜杠"
    end
    if relativePath:sub(-1) == "/" or relativePath:find("//", 1, true) then
        return nil, "relativePath 包含空路径段"
    end

    local codepoints, unicodeError = decodeCodepoints(relativePath)
    if not codepoints then return nil, unicodeError end
    for _, codepoint in ipairs(codepoints) do
        if codepoint <= 0x1F or (codepoint >= 0x7F and codepoint <= 0x9F) then
            return nil, "relativePath 包含控制字符"
        end
        if (codepoint >= 0x0300 and codepoint <= 0x036F)
            or (codepoint >= 0x1AB0 and codepoint <= 0x1AFF)
            or (codepoint >= 0x1DC0 and codepoint <= 0x1DFF)
            or (codepoint >= 0x20D0 and codepoint <= 0x20FF)
            or (codepoint >= 0xFE20 and codepoint <= 0xFE2F) then
            return nil, "relativePath 必须使用 NFC；不接受分解组合字符"
        end
    end

    local segments = {}
    for segment in relativePath:gmatch("[^/]+") do
        if segment == "." or segment == ".." then
            return nil, "relativePath 不得包含 . 或 .."
        end
        segments[#segments + 1] = segment
    end
    if #segments == 0 then return nil, "relativePath 没有有效路径段" end
    return segments
end

function PathPolicy.resolve(root, relativePath, pathAdapter)
    if type(root) ~= "string" or root == "" then return nil, "清单根目录无效" end
    local segments, pathError = PathPolicy.validateRelative(relativePath)
    if not segments then return nil, pathError end
    local candidate = root
    for _, segment in ipairs(segments) do candidate = pathAdapter.child(candidate, segment) end
    local standardizedRoot = pathAdapter.standardize(root)
    local standardizedCandidate = pathAdapter.standardize(candidate)
    local prefix = standardizedRoot
    if prefix:sub(-1) ~= "/" then prefix = prefix .. "/" end
    if standardizedCandidate:sub(1, #prefix) ~= prefix then
        return nil, "路径解析结果越出清单目录"
    end
    return standardizedCandidate
end

return PathPolicy
