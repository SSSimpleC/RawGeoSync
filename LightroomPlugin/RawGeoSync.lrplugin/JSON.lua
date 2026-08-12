local Json = {}

local ARRAY_MT = { __rawgeosync_json_array = true }
local NULL = setmetatable({}, { __tostring = function() return "null" end })

Json.null = NULL

function Json.array(values)
    return setmetatable(values or {}, ARRAY_MT)
end

local function fail(position, message)
    error(string.format("JSON 字节 %d：%s", position, message), 0)
end

local function utf8(codepoint)
    if codepoint <= 0x7F then
        return string.char(codepoint)
    elseif codepoint <= 0x7FF then
        return string.char(
            0xC0 + math.floor(codepoint / 0x40),
            0x80 + (codepoint % 0x40)
        )
    elseif codepoint <= 0xFFFF then
        return string.char(
            0xE0 + math.floor(codepoint / 0x1000),
            0x80 + (math.floor(codepoint / 0x40) % 0x40),
            0x80 + (codepoint % 0x40)
        )
    end
    return string.char(
        0xF0 + math.floor(codepoint / 0x40000),
        0x80 + (math.floor(codepoint / 0x1000) % 0x40),
        0x80 + (math.floor(codepoint / 0x40) % 0x40),
        0x80 + (codepoint % 0x40)
    )
end

function Json.decode(source, options)
    options = options or {}
    if type(source) ~= "string" then
        error("JSON 输入必须是字符串", 0)
    end
    if source:sub(1, 3) == "\239\187\191" then
        error("JSON 不允许 UTF-8 BOM", 0)
    end

    local length = #source
    local position = 1
    local maxDepth = options.maxDepth or 64
    local canonical = options.canonical == true

    local function skipWhitespace()
        local start = position
        while position <= length do
            local byte = source:byte(position)
            if byte == 0x20 or byte == 0x09 or byte == 0x0A or byte == 0x0D then
                position = position + 1
            else
                break
            end
        end
        if canonical and position ~= start then
            fail(start, "规范 JSON 不允许结构性空白")
        end
    end

    local function parseString()
        local start = position
        position = position + 1
        local chunks = {}
        local chunkStart = position

        while position <= length do
            local byte = source:byte(position)
            if byte == 0x22 then
                chunks[#chunks + 1] = source:sub(chunkStart, position - 1)
                position = position + 1
                return table.concat(chunks)
            elseif byte == 0x5C then
                chunks[#chunks + 1] = source:sub(chunkStart, position - 1)
                position = position + 1
                if position > length then fail(position, "字符串转义未结束") end
                local escape = source:sub(position, position)
                local replacements = {
                    ['"'] = '"', ['\\'] = '\\', ['/'] = '/',
                    b = '\b', f = '\f', n = '\n', r = '\r', t = '\t'
                }
                if replacements[escape] then
                    chunks[#chunks + 1] = replacements[escape]
                    position = position + 1
                elseif escape == "u" then
                    local hex = source:sub(position + 1, position + 4)
                    if #hex ~= 4 or not hex:match("^[0-9a-fA-F]+$") then
                        fail(position, "无效的 Unicode 转义")
                    end
                    local codepoint = tonumber(hex, 16)
                    position = position + 5
                    if codepoint >= 0xD800 and codepoint <= 0xDBFF then
                        if source:sub(position, position + 1) ~= "\\u" then
                            fail(position, "高代理项缺少低代理项")
                        end
                        local lowHex = source:sub(position + 2, position + 5)
                        if #lowHex ~= 4 or not lowHex:match("^[0-9a-fA-F]+$") then
                            fail(position, "无效的低代理项")
                        end
                        local low = tonumber(lowHex, 16)
                        if low < 0xDC00 or low > 0xDFFF then
                            fail(position, "无效的低代理项")
                        end
                        codepoint = 0x10000 + (codepoint - 0xD800) * 0x400 + (low - 0xDC00)
                        position = position + 6
                    elseif codepoint >= 0xDC00 and codepoint <= 0xDFFF then
                        fail(position, "孤立的低代理项")
                    end
                    chunks[#chunks + 1] = utf8(codepoint)
                else
                    fail(position, "未知的字符串转义")
                end
                chunkStart = position
            elseif byte < 0x20 then
                fail(position, "字符串包含控制字符")
            else
                position = position + 1
            end
        end
        fail(start, "字符串未结束")
    end

    local parseValue

    local function parseNumber()
        local start = position
        if source:sub(position, position) == "-" then position = position + 1 end
        if source:sub(position, position) == "0" then
            position = position + 1
            if source:sub(position, position):match("%d") then
                fail(position, "数字不允许前导零")
            end
        else
            if not source:sub(position, position):match("[1-9]") then
                fail(position, "无效数字")
            end
            repeat
                position = position + 1
            until not source:sub(position, position):match("%d")
        end
        if source:sub(position, position) == "." then
            position = position + 1
            if not source:sub(position, position):match("%d") then
                fail(position, "小数点后必须有数字")
            end
            repeat
                position = position + 1
            until not source:sub(position, position):match("%d")
        end
        local exponent = source:sub(position, position)
        if exponent == "e" or exponent == "E" then
            position = position + 1
            local sign = source:sub(position, position)
            if sign == "+" or sign == "-" then position = position + 1 end
            if not source:sub(position, position):match("%d") then
                fail(position, "指数部分必须有数字")
            end
            repeat
                position = position + 1
            until not source:sub(position, position):match("%d")
        end
        local value = tonumber(source:sub(start, position - 1))
        if value == nil or value ~= value or value == math.huge or value == -math.huge then
            fail(start, "数字超出可表示范围")
        end
        return value
    end

    local function parseArray(depth)
        position = position + 1
        local result = Json.array()
        skipWhitespace()
        if source:sub(position, position) == "]" then
            position = position + 1
            return result
        end
        while true do
            result[#result + 1] = parseValue(depth + 1)
            skipWhitespace()
            local separator = source:sub(position, position)
            if separator == "]" then
                position = position + 1
                return result
            elseif separator ~= "," then
                fail(position, "数组元素之间缺少逗号")
            end
            position = position + 1
            skipWhitespace()
        end
    end

    local function parseObject(depth)
        position = position + 1
        local result = {}
        local previousKey = nil
        skipWhitespace()
        if source:sub(position, position) == "}" then
            position = position + 1
            return result
        end
        while true do
            if source:sub(position, position) ~= '"' then
                fail(position, "对象键必须是字符串")
            end
            local key = parseString()
            if result[key] ~= nil then
                fail(position, "对象包含重复键：" .. key)
            end
            if canonical and previousKey ~= nil and key <= previousKey then
                fail(position, "对象键未按升序排列")
            end
            previousKey = key
            skipWhitespace()
            if source:sub(position, position) ~= ":" then
                fail(position, "对象键后缺少冒号")
            end
            position = position + 1
            skipWhitespace()
            result[key] = parseValue(depth + 1)
            skipWhitespace()
            local separator = source:sub(position, position)
            if separator == "}" then
                position = position + 1
                return result
            elseif separator ~= "," then
                fail(position, "对象成员之间缺少逗号")
            end
            position = position + 1
            skipWhitespace()
        end
    end

    parseValue = function(depth)
        if depth > maxDepth then fail(position, "嵌套层级过深") end
        skipWhitespace()
        local marker = source:sub(position, position)
        if marker == '"' then
            return parseString()
        elseif marker == "{" then
            return parseObject(depth)
        elseif marker == "[" then
            return parseArray(depth)
        elseif marker == "-" or marker:match("%d") then
            return parseNumber()
        elseif source:sub(position, position + 3) == "true" then
            position = position + 4
            return true
        elseif source:sub(position, position + 4) == "false" then
            position = position + 5
            return false
        elseif source:sub(position, position + 3) == "null" then
            position = position + 4
            return NULL
        end
        fail(position, "无法识别的值")
    end

    local value = parseValue(0)
    skipWhitespace()
    if position <= length then fail(position, "根值之后还有内容") end
    return value
end

local function encodeString(value)
    local result = { '"' }
    for index = 1, #value do
        local byte = value:byte(index)
        if byte == 0x22 then result[#result + 1] = '\\"'
        elseif byte == 0x5C then result[#result + 1] = '\\\\'
        elseif byte == 0x08 then result[#result + 1] = '\\b'
        elseif byte == 0x0C then result[#result + 1] = '\\f'
        elseif byte == 0x0A then result[#result + 1] = '\\n'
        elseif byte == 0x0D then result[#result + 1] = '\\r'
        elseif byte == 0x09 then result[#result + 1] = '\\t'
        elseif byte < 0x20 then result[#result + 1] = string.format("\\u%04x", byte)
        else result[#result + 1] = string.char(byte) end
    end
    result[#result + 1] = '"'
    return table.concat(result)
end

local encodeValue

local function isArray(value)
    return getmetatable(value) == ARRAY_MT
end

encodeValue = function(value, stack)
    local valueType = type(value)
    if value == NULL then return "null" end
    if valueType == "string" then return encodeString(value) end
    if valueType == "boolean" then return value and "true" or "false" end
    if valueType == "number" then
        if value ~= value or value == math.huge or value == -math.huge then
            error("JSON 不支持非有限数字", 0)
        end
        if value == 0 then return "0" end
        return string.format("%.17g", value)
    end
    if valueType ~= "table" then
        error("JSON 不支持类型：" .. valueType, 0)
    end
    if stack[value] then error("JSON 不支持循环引用", 0) end
    stack[value] = true
    local output = {}
    if isArray(value) then
        for index = 1, #value do output[index] = encodeValue(value[index], stack) end
        stack[value] = nil
        return "[" .. table.concat(output, ",") .. "]"
    end
    local keys = {}
    for key in pairs(value) do
        if type(key) ~= "string" then error("JSON 对象键必须是字符串", 0) end
        keys[#keys + 1] = key
    end
    table.sort(keys)
    for index, key in ipairs(keys) do
        output[index] = encodeString(key) .. ":" .. encodeValue(value[key], stack)
    end
    stack[value] = nil
    return "{" .. table.concat(output, ",") .. "}"
end

function Json.encode(value)
    return encodeValue(value, {})
end

return Json
