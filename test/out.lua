-- fileheader (common:header)

args = args or {...}

-- if jit and jit.opt then
--     -- boost jit limits
--     jit.opt.start("maxsnap=1000","loopunroll=500","maxmcode=2048")
-- end

local __LONG_INT_CLASS__

local setmetatable = setmetatable
local assert = assert
local error = error
local bit = bit
local math = math
local bit_tobit = bit.tobit
local bit_arshift = bit.arshift
local bit_rshift = bit.rshift
local bit_lshift = bit.lshift
local bit_band = bit.band
local bit_bor = bit.bor
local bit_bxor = bit.bxor
local bit_ror = bit.ror
local bit_rol = bit.rol
local math_huge = math.huge
local math_floor = math.floor
local math_ceil = math.ceil
local math_abs = math.abs
local math_max = math.max
local math_min = math.min
local math_pow = math.pow
local math_sqrt = math.sqrt
local math_ldexp = math.ldexp
local math_frexp = math.frexp
local math_log = math.log

if jit and jit.version_num < 20100 then
    function math_frexp(dbl)
        local aDbl = math_abs(dbl)
    
        if dbl ~= 0 and (aDbl ~= math_huge) then
            local exp = math_max(-1023,math_floor(math_log(aDbl,2) + 1))
            local x = aDbl * math_pow(2,-exp)
    
            if dbl < 0 then
                x = -x
            end
    
            return x,exp
        end
    
        return dbl,0
    end
end

local function __TRUNC__(n)
    if n >= 0 then return math_floor(n) end
    return math_ceil(n)
end

local function __LONG_INT__(low,high)
    -- Note: Avoid using tail-calls on builtins
    -- This aborts a JIT trace, and can be avoided by wrapping tail calls in parentheses
    return (setmetatable({low,high},__LONG_INT_CLASS__))
end

local function __LONG_INT_N__(n) -- operates on non-normalized integers
    -- convert a double value to i64 directly
    local high = bit_tobit(math_floor(n / (2^32))) -- manually rshift by 32
    local low = bit_tobit(n % (2^32)) -- wtf? normal bit conversions are not sufficent according to tests
    return (setmetatable({low,high},__LONG_INT_CLASS__))
end

_G.__LONG_INT__ = __LONG_INT__
_G.__LONG_INT_N__ = __LONG_INT_N__

-- Modules are entirely localised and can be modified post load
local __IMPORTS__ = {}
local __GLOBALS__ = {}
local __SETJMP_STATES__ = setmetatable({},{__mode="k"})
local __FUNCS__ = {}
local __EXPORTS__ = {}
local __BINDINGS__ = {}
local __BINDER__ = {arrays = {},ptrArrays = {}}

local module = {
    imports = __IMPORTS__,
    exports = __EXPORTS__,
    globals = __GLOBALS__,
    funcs = __FUNCS__,
    bindings = __BINDINGS__,
    binder = __BINDER__,
}

function module.setImports(imp)
    __IMPORTS__ = imp
    module.imports = imp
end

local function __STACK_POP__(__STACK__)
    local v = __STACK__[#__STACK__]
    __STACK__[#__STACK__] = nil
    return v
end

local function __UNSIGNED__(value)
    if value < 0 then
        value = value + 4294967296
    end

    return value
end

-- Adapted from https://github.com/notcake/glib/blob/master/lua/glib/bitconverter.lua
-- with permission from notcake
local function UInt32ToFloat(int)
    local negative = int < 0 -- check if first bit is 0
    if negative then int = int - 0x80000000 end

    local exponent = bit_rshift(bit_band(int, 0x7F800000), 23) -- and capture lowest 9 bits
    local significand = bit_band(int, 0x007FFFFF) / (2 ^ 23) -- discard lowest 9 bits and turn into a fraction

    local float

    if exponent == 0 then
        -- special case 1
        float = significand == 0 and 0 or math_ldexp(significand,-126)
    elseif exponent == 0xFF then
        -- special case 2
        float = significand == 0 and math_huge or (math_huge - math_huge) -- inf or nan
    else
        float = math_ldexp(significand + 1,exponent - 127)
    end

    return negative and -float or float
end

local function FloatToUInt32(float)
    local int = 0

    -- wtf -0
    if (float < 0) or ((1 / float) < 0) then
        int = int + 0x80000000
        float = -float
    end

    local exponent = 0
    local significand = 0

    if float == math_huge then
        -- special case 2.1
        exponent = 0xFF
        -- significand stays 0
    elseif float ~= float then -- nan
        -- special case 2.2
        exponent = 0xFF
        significand = 1
    elseif float ~= 0 then
        significand,exponent = math_frexp(float)
        exponent = exponent + 126 -- limit to 8 bits (u get what i mean)

        if exponent <= 0 then
            -- denormal float

            significand = math_floor(significand * 2 ^ (23 + exponent) + 0.5)
            -- ^ convert to back to whole number

            exponent = 0
        else
            significand = math_floor((significand * 2 - 1) * 2 ^ 23 + 0.5)
            -- ^ convert to back to whole number
        end
    end

    int = int + bit_lshift(bit_band(exponent, 0xFF), 23) -- stuff high 8 bits with exponent (after first sign bit)
    int = int + bit_band(significand, 0x007FFFFF) -- stuff low 23 bits with significand

    return bit_tobit(int)
end

local function UInt32sToDouble(uint_low,uint_high)
    local negative = false
    -- check if first bit is 0
    if uint_high < 0 then
        uint_high = uint_high - 0x80000000
        -- set first bit to  0 ^
        negative = true
    end

    local exponent = bit_rshift(uint_high, 20) -- and capture lowest 11 bits
    local significand = (bit_band(uint_high, 0x000FFFFF) * 0x100000000 + uint_low) / (2 ^ 52) -- discard low bits and turn into a fraction

    local double = 0

    if exponent == 0 then
        -- special case 1
        double = significand == 0 and 0 or math_ldexp(significand,-1022)
    elseif exponent == 0x07FF then
        -- special case 2
        double = significand == 0 and math_huge or (math_huge - math_huge) -- inf or nan
    else
        double = math_ldexp(significand + 1,exponent - 1023)
    end

    return negative and -double or double
end

local function DoubleToUInt32s(double)
    local uint_low = 0
    local uint_high = 0

    -- wtf -0
    if (double < 0) or ((1 / double) < 0) then
        uint_high = uint_high + 0x80000000
        double = -double
    end

    local exponent = 0
    local significand = 0

    if double == math_huge then
        -- special case 2.1
        exponent = 0x07FF
        -- significand stays 0
    elseif double ~= double then -- nan
        -- special case 2.2
        exponent = 0x07FF
        significand = 1
    elseif double ~= 0 then
        significand,exponent = math_frexp(double)
        exponent = exponent + 1022 -- limit to 10 bits (u get what i mean)

        if exponent <= 0 then
            -- denormal double

            significand = math_floor(significand * 2 ^ (52 + exponent) + 0.5)
            -- ^ convert to back to whole number

            exponent = 0
        else
            significand = math_floor((significand * 2 - 1) * 2 ^ 52 + 0.5)
            -- ^ convert to back to whole number
        end
    end

    -- significand is partially in low and high uints
    uint_low = significand % 0x100000000
    uint_high = uint_high + bit_lshift(bit_band(exponent, 0x07FF), 20)
    uint_high = uint_high + bit_band(math_floor(significand / 0x100000000), 0x000FFFFF)

    return bit_tobit(uint_low), bit_tobit(uint_high)
end
-- pure lua memory lib

local function __MEMORY_GROW__(mem,pages)
    local old_pages = mem._page_count
    local new_pages = old_pages + pages

    -- check if new size exceeds the size limit
    if new_pages > mem._max_pages then
        return -1
    end

    -- 16k cells = 64kb = 1 page
    local cell_start = old_pages * 16 * 1024
    local cell_end = new_pages * 16 * 1024 - 1

    for i = cell_start, cell_end do 
        mem.data[i] = 0
    end

    mem._len = new_pages * 64 * 1024
    mem._page_count = new_pages
    return old_pages
end

--[[
    Float mapping overview:
    - mem._fp_map is a sparse map that indicates where floats and doubles are stored in memory.
    - The mapping system only works when floats are cell-aligned (the float or double's address is a multiple of 4).
    - Any memory write can update the map: writing a byte in a cell occupied by a float will force the entire cell to revert to an integer value.
    - In the interest of speed and local slot conservation, all constants have been inlined. Their values:
        - nil: Cell is occupied by integer data.
        -   1: Cell is occupied by a single-width float.
        -   2: Cell contains the low half of a double-width float. GUARANTEES that a (3) follows.
        -   3: Cell contains the high half of a double-width float. GUARANTEES that a (2) precedes.
]]

local function __MEMORY_READ_8__(mem,loc)
    assert((loc >= 0) and (loc < mem._len),"out of memory access")

    local cell_loc = bit_rshift(loc,2)
    local byte_loc = bit_band(loc,3)

    local cell_value
    local mem_t = mem._fp_map[cell_loc]
    if mem_t == nil then
        cell_value = mem.data[cell_loc]
    else
        if mem_t == 1 then
            cell_value = FloatToUInt32(mem.data[cell_loc])
        else
            local low, high = DoubleToUInt32s(mem.data[cell_loc])
            if mem_t == 2 then
                cell_value = low
            else
                cell_value = high
            end
        end
    end

    return bit_band(bit_rshift(cell_value, byte_loc * 8),255)
end

local function __MEMORY_READ_16__(mem,loc)
    assert((loc >= 0) and (loc < (mem._len - 1)),"out of memory access")
    -- 16 bit reads/writes are less common, they can be optimized later
    return bit_bor(
        __MEMORY_READ_8__(mem,loc),
        bit_lshift(__MEMORY_READ_8__(mem,loc + 1),8)
    )
end

local function __MEMORY_READ_32__(mem,loc)
    assert((loc >= 0) and (loc < (mem._len - 3)),"out of memory access")

    if bit_band(loc,3) == 0 then
        -- aligned read, fast path
        local cell_loc = bit_rshift(loc,2)

        local mem_t = mem._fp_map[cell_loc]
        if mem_t ~= nil then
            if mem_t == 1 then
                return FloatToUInt32(mem.data[cell_loc])
            else
                local low, high = DoubleToUInt32s(mem.data[cell_loc])
                if mem_t == 2 then
                    return low
                else
                    return high
                end
            end
        end

        local val = mem.data[cell_loc]
        -- It breaks in some way I don't understand if you don't normalize the value.
        return bit_tobit(val)
    else
        --print("bad alignment (read 32)",alignment)
        return bit_bor(
            __MEMORY_READ_8__(mem,loc),
            bit_lshift(__MEMORY_READ_8__(mem,loc + 1),8),
            bit_lshift(__MEMORY_READ_8__(mem,loc + 2),16),
            bit_lshift(__MEMORY_READ_8__(mem,loc + 3),24)
        )
    end
end

-- I also tried some weird shift/xor logic,
-- both had similar performance but I kept this becuase it was simpler.
local mask_table = {0xFFFF00FF,0xFF00FFFF,0x00FFFFFF}
mask_table[0] = 0xFFFFFF00
local function __MEMORY_WRITE_8__(mem,loc,val)
    assert((loc >= 0) and (loc < mem._len),"out of memory access")
    val = bit_band(val,255)

    local cell_loc = bit_rshift(loc,2)
    local byte_loc = bit_band(loc,3)

    local mem_t = mem._fp_map[cell_loc]
    local old_cell
    if mem_t == nil then
        -- fast path, the cell is already an integer
        old_cell = mem.data[cell_loc]
    else
        -- bad news, a float is stored here and we have to convert it to an integer
        mem._fp_map[cell_loc] = nil
        if mem_t == 1 then
            -- float
            old_cell = FloatToUInt32(mem.data[cell_loc])
        else
            -- double: we must also update the matching cell
            local low, high = DoubleToUInt32s(mem.data[cell_loc])
            if mem_t == 2 then
                -- this cell is the low half
                old_cell = low

                mem.data[cell_loc + 1] = high
                mem._fp_map[cell_loc + 1] = nil
            else
                -- this cell is the high half
                old_cell = high

                mem.data[cell_loc - 1] = low
                mem._fp_map[cell_loc - 1] = nil
            end
        end
    end

    old_cell = bit_band(old_cell, mask_table[byte_loc])
    local new_cell = bit_bor(old_cell, bit_lshift(val,byte_loc * 8))

    mem.data[cell_loc] = new_cell
end

local function __MEMORY_WRITE_16__(mem,loc,val)
    assert((loc >= 0) and (loc < (mem._len - 1)),"out of memory access")
    -- 16 bit reads/writes are less common, they can be optimized later
    __MEMORY_WRITE_8__(mem,loc,     val)
    __MEMORY_WRITE_8__(mem,loc + 1, bit_rshift(val,8))
end

local function __MEMORY_WRITE_32__(mem,loc,val)
    assert((loc >= 0) and (loc < (mem._len - 3)),"out of memory access")

    if bit_band(loc,3) == 0 then
        -- aligned write, fast path
        local cell_loc = bit_rshift(loc,2)
        mem._fp_map[cell_loc] = nil -- mark this cell as an integer
        mem.data[cell_loc] = val
    else
        --print("bad alignment (write 32)",alignment)
        __MEMORY_WRITE_8__(mem,loc,     val)
        __MEMORY_WRITE_8__(mem,loc + 1, bit_rshift(val,8))
        __MEMORY_WRITE_8__(mem,loc + 2, bit_rshift(val,16))
        __MEMORY_WRITE_8__(mem,loc + 3, bit_rshift(val,24))
    end
end

local function __MEMORY_READ_32F__(mem,loc)
    assert((loc >= 0) and (loc < (mem._len - 3)),"out of memory access")

    local cell_loc = bit_rshift(loc,2)
    local byte_loc = bit_band(loc,3)

    if byte_loc == 0 and mem._fp_map[cell_loc] == 1 then
        return mem.data[cell_loc]
    else
        -- Let __MEMORY_READ_32__ handle any issues.
        return UInt32ToFloat(__MEMORY_READ_32__(mem,loc))
    end
end

local function __MEMORY_READ_64F__(mem,loc)
    assert((loc >= 0) and (loc < (mem._len - 7)),"out of memory access")

    local cell_loc = bit_rshift(loc,2)
    local byte_loc = bit_band(loc,3)

    local mem_t = mem._fp_map[cell_loc]

    if byte_loc == 0 and mem_t == 2 then
        return mem.data[cell_loc]
    else
        -- Let __MEMORY_READ_32__ handle any issues.
        return UInt32sToDouble(__MEMORY_READ_32__(mem,loc),__MEMORY_READ_32__(mem,loc + 4))
    end
end

local function __MEMORY_WRITE_32F__(mem,loc,val)
    assert((loc >= 0) and (loc < (mem._len - 3)),"out of memory access")

    if bit_band(loc,3) == 0 then
        local cell_loc = bit_rshift(loc,2)
        mem._fp_map[cell_loc] = 1
        mem.data[cell_loc] = val
    else
        -- unaligned writes can't use the float map.
        __MEMORY_WRITE_32__(mem,loc,FloatToUInt32(val))
    end
end

local function __MEMORY_WRITE_64F__(mem,loc,val)
    assert((loc >= 0) and (loc < (mem._len - 7)),"out of memory access")

    if bit_band(loc,3) == 0 then
        local cell_loc = bit_rshift(loc,2)
        mem._fp_map[cell_loc] = 2
        mem.data[cell_loc] = val
        mem._fp_map[cell_loc + 1] = 3
        mem.data[cell_loc + 1] = val
    else
        -- unaligned writes can't use the float map.
        local low,high = DoubleToUInt32s(val)
        __MEMORY_WRITE_32__(mem,loc,low)
        __MEMORY_WRITE_32__(mem,loc + 4,high)
    end
end

local function __MEMORY_INIT__(mem,loc,data)
    for i = 1, #data do -- TODO RE-OPTIMIZE
        __MEMORY_WRITE_8__(mem, loc + i-1, data:byte(i))
    end
end

local function __MEMORY_ALLOC__(pages, max_pages)
    local mem = {}
    mem.data = {}
    mem._page_count = pages
    mem._len = pages * 64 * 1024
    mem._fp_map = {}
    mem._max_pages = max_pages or 1024

    local cellLength = pages * 16 * 1024 -- 16k cells = 64kb = 1 page
    for i=0,cellLength - 1 do mem.data[i] = 0 end

    mem.write8 = __MEMORY_WRITE_8__
    mem.write16 = __MEMORY_WRITE_16__
    mem.write32 = __MEMORY_WRITE_32__

    mem.read8 = __MEMORY_READ_8__
    mem.read16 = __MEMORY_READ_16__
    mem.read32 = __MEMORY_READ_32__

    __SETJMP_STATES__[mem] = {}

    return mem
end
-- fileheader (common:footer)

-- extra bit ops

local __clz_tab = {3, 2, 2, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0}
__clz_tab[0] = 4

local function __CLZ__(x)
    local n = 0
    if bit_band(x,-65536)     == 0 then n = 16;    x = bit_lshift(x,16) end
    if bit_band(x,-16777216)  == 0 then n = n + 8; x = bit_lshift(x,8) end
    if bit_band(x,-268435456) == 0 then n = n + 4; x = bit_lshift(x,4) end
    n = n + __clz_tab[bit_rshift(x,28)]
    return n
end

local __ctz_tab = {}

for i = 0,31 do
    __ctz_tab[ bit_rshift( 125613361 * bit_lshift(1,i) , 27 ) ] = i
end

local function __CTZ__(x)
    if x == 0 then return 32 end
    return __ctz_tab[ bit_rshift( bit_band(x,-x) * 125613361 , 27 ) ]
end

local __popcnt_tab = {
      1,1,2,1,2,2,3,1,2,2,3,2,3,3,4,1,2,2,3,2,3,3,4,2,3,3,4,3,4,4,5,1,2,2,3,2,3,3,4,2,3,3,4,3,4,4,5,2,3,3,4,3,4,4,5,3,4,4,5,4,5,5,6,
    1,2,2,3,2,3,3,4,2,3,3,4,3,4,4,5,2,3,3,4,3,4,4,5,3,4,4,5,4,5,5,6,2,3,3,4,3,4,4,5,3,4,4,5,4,5,5,6,3,4,4,5,4,5,5,6,4,5,5,6,5,6,6,7,
    1,2,2,3,2,3,3,4,2,3,3,4,3,4,4,5,2,3,3,4,3,4,4,5,3,4,4,5,4,5,5,6,2,3,3,4,3,4,4,5,3,4,4,5,4,5,5,6,3,4,4,5,4,5,5,6,4,5,5,6,5,6,6,7,
    2,3,3,4,3,4,4,5,3,4,4,5,4,5,5,6,3,4,4,5,4,5,5,6,4,5,5,6,5,6,6,7,3,4,4,5,4,5,5,6,4,5,5,6,5,6,6,7,4,5,5,6,5,6,6,7,5,6,6,7,6,7,7,8
}
__popcnt_tab[0] = 0

local function __POPCNT__(x)
    -- the really cool algorithm uses a multiply that can overflow, so we're stuck with a LUT
    return __popcnt_tab[bit_band(x,255)]
    + __popcnt_tab[bit_band(bit_rshift(x,8),255)]
    + __popcnt_tab[bit_band(bit_rshift(x,16),255)]
    + __popcnt_tab[bit_rshift(x,24)]
end

-- division helpers

local function __IDIV_S__(a,b)
    local res_1 = a / b
    local res_2 = math_floor(res_1)
    if res_1 ~= res_2 and res_2 < 0 then res_2 = res_2 + 1 end
    local int = bit_tobit(res_2)
    if res_2 ~= int then error("bad division") end
    return int
end

local function __IDIV_U__(a,b)
    local res = math_floor(__UNSIGNED__(a) / __UNSIGNED__(b))
    local int = bit_tobit(res)
    if res ~= int then error("bad division") end
    return int
end

local function __IMOD_S__(a,b)
    if b == 0 then error("bad modulo") end
    local res = math_abs(a) % math_abs(b)
    if a < 0 then  res = -res end
    return bit_tobit(res)
end

local function __IMOD_U__(a,b)
    if b == 0 then error("bad modulo") end
    local res = __UNSIGNED__(a) % __UNSIGNED__(b)
    return bit_tobit(res)
end

-- Multiply two 32 bit integers without busting due to precision loss on overflow
local function __IMUL__(a,b)
    local a_low = bit_band(a,65535)
    local b_low = bit_band(b,65535)

    return bit_tobit(
        a_low * b_low +
        bit_lshift(a_low * bit_rshift(b,16),16) +
        bit_lshift(b_low * bit_rshift(a,16),16)
    )
end

-- Extra math functions for floats, stored in their own table since they're not likely to be used often.
local __FLOAT__ = {
    nearest = function(x)
        if x % 1 == .5 then
            -- Must round toward even in the event of a tie.
            local y = math_floor(x)
            return y + (y % 2)
        end
        return math_floor(x + .5)
    end,
    truncate = function(x)
        return x > 0 and math_floor(x) or math_ceil(x)
    end,
    copysign = function(x,y)
        -- Does not handle signed zero, but who really cares?
        local sign = y > 0 and 1 or -1
        return x * sign
    end,
    min = function(x,y)
        if x ~= x or y ~= y then return 0 / 0 end
        return math_min(x,y)
    end,
    max = function(x,y)
        if x ~= x or y ~= y then return 0 / 0 end
        return math_max(x,y)
    end
}

-- Multiply and divide code adapted from 
    -- https://github.com/BixData/lua-long/ which is adapted from
    -- https://github.com/dcodeIO/long.js which is adapted from
    -- https://github.com/google/closure-library

-- This is the core division routine used by other division functions.
local function __LONG_INT_DIVIDE__(rem,divisor)
    assert(divisor[1] ~= 0 or divisor[2] ~= 0,"divide by zero")

    local res = __LONG_INT__(0,0)

    local d_approx = __UNSIGNED__(divisor[1]) + __UNSIGNED__(divisor[2]) * 4294967296

    while rem:_ge_u(divisor) do
        local n_approx = __UNSIGNED__(rem[1]) + __UNSIGNED__(rem[2]) * 4294967296

        -- Don't allow our approximation to be larger than an i64
        n_approx = math_min(n_approx, 18446744073709549568)

        local q_approx = math_max(1, math_floor(n_approx / d_approx))

        -- dark magic from long.js / closure lib
        local log2 = math_ceil(math_log(q_approx, 2))
        local delta = math_pow(2,math_max(0,log2 - 48))

        local res_approx = __LONG_INT_N__(q_approx)
        local rem_approx = res_approx * divisor

        -- decrease approximation until smaller than remainder and the multiply hopefully
        while rem_approx:_gt_u(rem) do
            q_approx = q_approx - delta
            res_approx = __LONG_INT_N__(q_approx)
            rem_approx = res_approx * divisor
        end

        -- res must be at least one, lib I copied the algo from had this check
        -- but I'm not sure is necessary or makes sense
        if res_approx[1] == 0 and res_approx[2] == 0 then
            error("res_approx = 0")
            res_approx[1] = 1
        end

        res = res + res_approx
        rem = rem - rem_approx
    end

    return res, rem
end

__LONG_INT_CLASS__ = {
    __tostring = function(self)
        return "__LONG_INT__(" .. self[1] .. "," .. self[2] .. ")"
    end,
    __add = function(a,b)
        local low = __UNSIGNED__(a[1]) + __UNSIGNED__(b[1])
        local high = a[2] + b[2] + (low >= 4294967296 and 1 or 0)
        return __LONG_INT__( bit_tobit(low), bit_tobit(high) )
    end,
    __sub = function(a,b)
        local low = __UNSIGNED__(a[1]) - __UNSIGNED__(b[1])
        local high = a[2] - b[2] - (low < 0 and 1 or 0)
        return __LONG_INT__( bit_tobit(low), bit_tobit(high) )
    end,
    __mul = function(a,b)
        -- I feel like this is excessive but I'm going to
        -- defer to the better wizard here.

        local a48 = bit_rshift(a[2],16)
        local a32 = bit_band(a[2],65535)
        local a16 = bit_rshift(a[1],16)
        local a00 = bit_band(a[1],65535)

        local b48 = bit_rshift(b[2],16)
        local b32 = bit_band(b[2],65535)
        local b16 = bit_rshift(b[1],16)
        local b00 = bit_band(b[1],65535)

        local c00 = a00 * b00
        local c16 = bit_rshift(c00,16)
        c00 = bit_band(c00,65535)

        c16 = c16 + a16 * b00
        local c32 = bit_rshift(c16,16)
        c16 = bit_band(c16,65535)

        c16 = c16 + a00 * b16
        c32 = c32 + bit_rshift(c16,16)
        c16 = bit_band(c16,65535)

        c32 = c32 + a32 * b00
        local c48 = bit_rshift(c32,16)
        c32 = bit_band(c32,65535)

        c32 = c32 + a16 * b16
        c48 = c48 + bit_rshift(c32,16)
        c32 = bit_band(c32,65535)

        c32 = c32 + a00 * b32
        c48 = c48 + bit_rshift(c32,16)
        c32 = bit_band(c32,65535)

        c48 = c48 + a48 * b00 + a32 * b16 + a16 * b32 + a00 * b48
        c48 = bit_band(c48,65535)

        return __LONG_INT__(
            bit_bor(c00,bit_lshift(c16,16)),
            bit_bor(c32,bit_lshift(c48,16))
        )
    end,
    __eq = function(a,b)
        return a[1] == b[1] and a[2] == b[2]
    end,
    __lt = function(a,b) -- <
        if a[2] == b[2] then return a[1] < b[1] else return a[2] < b[2] end
    end,
    __le = function(a,b) -- <=
        if a[2] == b[2] then return a[1] <= b[1] else return a[2] <= b[2] end
    end,
    __index = {
        store = function(self,mem,loc)
            assert((loc >= 0) and (loc < (mem._len - 7)),"out of memory access")

            local low = self[1]
            local high = self[2]

            __MEMORY_WRITE_32__(mem,loc,low)
            __MEMORY_WRITE_32__(mem,loc + 4,high)
        end,
        load = function(self,mem,loc)

            local low =  __MEMORY_READ_32__(mem,loc)
            local high = __MEMORY_READ_32__(mem,loc + 4)

            self[1] = low
            self[2] = high
        end,
        store32 = function(self,mem,loc)
           __MEMORY_WRITE_32__(mem,loc,self[1])
        end,
        store16 = function(self,mem,loc)
            __MEMORY_WRITE_16__(mem,loc,self[1])
        end,
        store8 = function(self,mem,loc)
            __MEMORY_WRITE_8__(mem,loc,self[1])
        end,
        _div_s = function(a,b)
            local negate_result = false
            if a[2] < 0 then
                a = __LONG_INT__(0,0) - a
                negate_result = not negate_result
            end

            if b[2] < 0 then
                b = __LONG_INT__(0,0) - b
                negate_result = not negate_result
            end

            local res, rem = __LONG_INT_DIVIDE__(a,b)
            if res[2] < 0 then
                error("division overflow")
            end
            if negate_result then
                res = __LONG_INT__(0,0) - res
            end
            return res
        end,
        _div_u = function(a,b)
            local res, rem = __LONG_INT_DIVIDE__(a,b)
            return res
        end,
        _rem_s = function(a,b)
            local negate_result = false
            if a[2] < 0 then
                a = __LONG_INT__(0,0) - a
                negate_result = not negate_result
            end

            if b[2] < 0 then
                b = __LONG_INT__(0,0) - b
            end

            local res, rem = __LONG_INT_DIVIDE__(a,b)

            if negate_result then
                rem = __LONG_INT__(0,0) - rem
            end

            return rem
        end,
        _rem_u = function(a,b)
            local res, rem = __LONG_INT_DIVIDE__(a,b)
            return rem
        end,
        _lt_u = function(a,b)
            if __UNSIGNED__(a[2]) == __UNSIGNED__(b[2]) then
                return __UNSIGNED__(a[1]) < __UNSIGNED__(b[1])
            else
                return __UNSIGNED__(a[2]) < __UNSIGNED__(b[2])
            end
        end,
        _le_u = function(a,b)
            if __UNSIGNED__(a[2]) == __UNSIGNED__(b[2]) then
                return __UNSIGNED__(a[1]) <= __UNSIGNED__(b[1])
            else
                return __UNSIGNED__(a[2]) <= __UNSIGNED__(b[2])
            end
        end,
        _gt_u = function(a,b)
            if __UNSIGNED__(a[2]) == __UNSIGNED__(b[2]) then
                return __UNSIGNED__(a[1]) > __UNSIGNED__(b[1])
            else
                return __UNSIGNED__(a[2]) > __UNSIGNED__(b[2])
            end
        end,
        _ge_u = function(a,b)
            if __UNSIGNED__(a[2]) == __UNSIGNED__(b[2]) then
                return __UNSIGNED__(a[1]) >= __UNSIGNED__(b[1])
            else
                return __UNSIGNED__(a[2]) >= __UNSIGNED__(b[2])
            end
        end,
        _shl = function(a,b)
            local shift = bit_band(b[1],63)

            local low, high
            if shift < 32 then
                high = bit_bor( bit_lshift(a[2],shift), shift == 0 and 0 or bit_rshift(a[1], 32-shift) )
                low = bit_lshift(a[1],shift)
            else
                low = 0
                high = bit_lshift(a[1],shift-32)
            end

            return __LONG_INT__(low,high)
        end,
        _shr_u = function(a,b)
            local shift = bit_band(b[1],63)

            local low, high
            if shift < 32 then
                low = bit_bor( bit_rshift(a[1],shift), shift == 0 and 0 or bit_lshift(a[2], 32-shift) )
                high = bit_rshift(a[2],shift)
            else
                low = bit_rshift(a[2],shift-32)
                high = 0
            end

            return __LONG_INT__(low,high)
        end,
        _shr_s = function(a,b)
            local shift = bit_band(b[1],63)

            local low, high
            if shift < 32 then
                low = bit_bor( bit_rshift(a[1],shift), shift == 0 and 0 or bit_lshift(a[2], 32-shift) )
                high = bit_arshift(a[2],shift)
            else
                low = bit_arshift(a[2],shift-32)
                high = bit_arshift(a[2],31)
            end

            return __LONG_INT__(low,high)
        end,
        _rotr = function(a,b)
            local shift = bit_band(b[1],63)
            local short_shift = bit_band(shift,31)

            local res1, res2
            if short_shift == 0 then
                -- Need this special case because shifts of 32 aren't valid :(
                res1 = a[1]
                res2 = a[2]
            else
                res1 = bit_bor( bit_rshift(a[1],short_shift), bit_lshift(a[2], 32-short_shift) )
                res2 = bit_bor( bit_rshift(a[2],short_shift), bit_lshift(a[1], 32-short_shift) )
            end

            if shift < 32 then
                return __LONG_INT__(res1,res2)
            else
                return __LONG_INT__(res2,res1)
            end
        end,
        _rotl = function(a,b)
            local shift = bit_band(b[1],63)
            local short_shift = bit_band(shift,31)

            local res1, res2
            if short_shift == 0 then
                -- Need this special case because shifts of 32 aren't valid :(
                res1 = a[1]
                res2 = a[2]
            else
                res1 = bit_bor( bit_lshift(a[1],short_shift), bit_rshift(a[2], 32-short_shift) )
                res2 = bit_bor( bit_lshift(a[2],short_shift), bit_rshift(a[1], 32-short_shift) )
            end

            if shift < 32 then
                return __LONG_INT__(res1,res2)
            else
                return __LONG_INT__(res2,res1)
            end
        end,
        _or = function(a,b)
            return __LONG_INT__(bit_bor(a[1],b[1]), bit_bor(a[2],b[2]))
        end,
        _and = function(a,b)
            return __LONG_INT__(bit_band(a[1],b[1]), bit_band(a[2],b[2]))
        end,
        _xor = function(a,b)
            return __LONG_INT__(bit_bxor(a[1],b[1]), bit_bxor(a[2],b[2]))
        end,
        _clz = function(a)
            local result = (a[2] ~= 0) and __CLZ__(a[2]) or 32 + __CLZ__(a[1])
            return __LONG_INT__(result,0)
        end,
        _ctz = function(a)
            local result = (a[1] ~= 0) and __CTZ__(a[1]) or 32 + __CTZ__(a[2])
            return __LONG_INT__(result,0)
        end,
        _popcnt = function(a)
            return __LONG_INT__( __POPCNT__(a[1]) + __POPCNT__(a[2]), 0)
        end,
    }
}

do
    local mem_0 = __MEMORY_ALLOC__(16);
    module.memory = mem_0
    do
        __GLOBALS__[0] = 1048576;
    end
    function __FUNCS__.dummy()
    end
    function __FUNCS__.__wasm_call_dtors()
        __FUNCS__.dummy();
        __FUNCS__.dummy();
    end
    
    function module.init()
    end
end

return module
