local SHA256 = {}

local MOD = 4294967296
local XOR = {}
local AND = {}

for left = 0, 15 do
    for right = 0, 15 do
        local xorValue = 0
        local andValue = 0
        local place = 1
        local a = left
        local b = right
        for _ = 1, 4 do
            local aBit = a % 2
            local bBit = b % 2
            if aBit ~= bBit then xorValue = xorValue + place end
            if aBit == 1 and bBit == 1 then andValue = andValue + place end
            a = math.floor(a / 2)
            b = math.floor(b / 2)
            place = place * 2
        end
        XOR[left * 16 + right] = xorValue
        AND[left * 16 + right] = andValue
    end
end

local function bitop(left, right, lookup)
    local result = 0
    local place = 1
    for _ = 1, 8 do
        local a = left % 16
        local b = right % 16
        result = result + lookup[a * 16 + b] * place
        left = math.floor(left / 16)
        right = math.floor(right / 16)
        place = place * 16
    end
    return result
end

local function bxor(left, right) return bitop(left, right, XOR) end
local function band(left, right) return bitop(left, right, AND) end
local function bnot(value) return 4294967295 - value end
local function rshift(value, count) return math.floor(value / (2 ^ count)) end
local function lshift(value, count)
    return (value % (2 ^ (32 - count))) * (2 ^ count)
end
local function ror(value, count)
    return (rshift(value, count) + lshift(value, 32 - count)) % MOD
end
local function bxor3(a, b, c) return bxor(bxor(a, b), c) end
local function add(...)
    local result = 0
    for index = 1, select("#", ...) do result = (result + select(index, ...)) % MOD end
    return result
end

local CONSTANTS = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
    0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
    0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
    0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
    0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
    0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
    0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
    0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
    0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}

local function wordBytes(value)
    return string.char(
        rshift(value, 24) % 256,
        rshift(value, 16) % 256,
        rshift(value, 8) % 256,
        value % 256
    )
end

local function processBlock(h, block)
    local words = {}
    for index = 1, 16 do
        local offset = (index - 1) * 4 + 1
        local a, b, c, d = block:byte(offset, offset + 3)
        words[index] = ((a * 256 + b) * 256 + c) * 256 + d
    end
    for index = 17, 64 do
        local previous = words[index - 15]
        local sigma0 = bxor3(ror(previous, 7), ror(previous, 18), rshift(previous, 3))
        previous = words[index - 2]
        local sigma1 = bxor3(ror(previous, 17), ror(previous, 19), rshift(previous, 10))
        words[index] = add(words[index - 16], sigma0, words[index - 7], sigma1)
    end

    local a, b, c, d = h[1], h[2], h[3], h[4]
    local e, f, g, hh = h[5], h[6], h[7], h[8]
    for index = 1, 64 do
        local sum1 = bxor3(ror(e, 6), ror(e, 11), ror(e, 25))
        local choice = bxor(band(e, f), band(bnot(e), g))
        local temp1 = add(hh, sum1, choice, CONSTANTS[index], words[index])
        local sum0 = bxor3(ror(a, 2), ror(a, 13), ror(a, 22))
        local majority = bxor3(band(a, b), band(a, c), band(b, c))
        local temp2 = add(sum0, majority)
        hh, g, f, e, d, c, b, a = g, f, e, add(d, temp1), c, b, a, add(temp1, temp2)
    end
    h[1], h[2], h[3], h[4] = add(h[1], a), add(h[2], b), add(h[3], c), add(h[4], d)
    h[5], h[6], h[7], h[8] = add(h[5], e), add(h[6], f), add(h[7], g), add(h[8], hh)
end

function SHA256.new()
    local context = {
        h = {
            0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
            0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
        },
        buffer = "",
        byteCount = 0,
        finished = false,
    }

    function context:update(contents)
        if self.finished then error("SHA256 上下文已经结束", 0) end
        if type(contents) ~= "string" then error("SHA256 输入必须是字符串", 0) end
        self.byteCount = self.byteCount + #contents
        local pending = self.buffer .. contents
        local position = 1
        while #pending - position + 1 >= 64 do
            processBlock(self.h, pending:sub(position, position + 63))
            position = position + 64
        end
        self.buffer = pending:sub(position)
        return self
    end

    function context:finish()
        if self.finished then error("SHA256 上下文已经结束", 0) end
        self.finished = true
        local bitLength = self.byteCount * 8
        local zeroCount = (56 - ((#self.buffer + 1) % 64)) % 64
        local padded = self.buffer
            .. string.char(0x80)
            .. string.rep("\0", zeroCount)
            .. wordBytes(math.floor(bitLength / MOD))
            .. wordBytes(bitLength % MOD)
        for position = 1, #padded, 64 do
            processBlock(self.h, padded:sub(position, position + 63))
        end
        return string.format(
            "%08x%08x%08x%08x%08x%08x%08x%08x",
            self.h[1], self.h[2], self.h[3], self.h[4],
            self.h[5], self.h[6], self.h[7], self.h[8]
        )
    end
    return context
end

function SHA256.digest(contents)
    return SHA256.new():update(contents):finish()
end

return SHA256
