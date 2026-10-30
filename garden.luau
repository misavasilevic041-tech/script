-- AutoFarm v4.8.1: v4.8 + TEMPORARY cycle diagnostics (stat line: cycle / grow / eff). Farm logic untouched.
--
-- AutoFarm v4.8 as a hub farm (garden.luau, hub v2): ON/OFF + MODE + X (unload)
-- hub v2: Core log / saved settings / language / copy-log / Core.guard (autopause, restart after death, watchdog).
-- Farm logic untouched.
--
-- v4.8 (farm logic untouched): the stall watchdog no longer counts time while a planted soil is still growing
-- (RT.nextRipe known), so long-growing crops do not trigger a false warning or auto-stop; session time is now
-- measured with the real clock; the GUI is refreshed after a watchdog stop.
-- v4.7 (farm logic untouched, additions only): session summary on OFF / unload / every 10 min, a stall watchdog
-- (AF.stallWarn = 300 s without any plant or harvest -> warning; AF.stallStop = 1200 s -> farm switches itself OFF;
-- set AF.stallStop = 0 to never auto-stop) and a startup check of the remotes and the crop config.
--
-- MODES
--   AUTO     the script looks for the most profitable way by itself:
--              * crop    = best profit/s for the current soil count, coins and level (re-checked every 15 s),
--                          using MEASURED sale value and MEASURED growth time once it has seen a full cycle
--              * rate    = starts at 30/s, climbs while the server keeps up (up to 40/s, the measured server limit),
--                          backs off on retries and remembers the rate that failed (ceiling) for 4 minutes
--   SLOW     looks like manual play: ~4 actions/s with random timing, random "thinking" pauses,
--            short breaks, nearest soil first, small buy chunks
--   MEDIUM   balance of speed and reliability (20/s, adaptive up to 28/s)
--   FAST     maximum speed WITHOUT losing efficiency: up to the measured server limit (40/s), adaptive,
--            backs off at the first sign of dropped requests
--   FASTEST! experimental: everything pushed to the limit (bursts, 0.05 s scan, rate up to 80/s,
--            short cooldowns). Expect retries and temporary bans of soils; the adaptive loop fights it.
--   CUSTOM   the menu values are used; a row set to "auto" falls back to the MEDIUM value.
-- AUTO also LEARNS (file afarm_learn.json): crops differ only in sale price and growth speed, so two factors
-- (k = real price per unit / config price, y = units per harvested soil) describe them all. A fresh install
-- watches the first clean sales of the crop it farms: if the server pays exactly the config price (it does:
-- k = 1.00, 1 unit per soil) the config is trusted at once and nothing is probed. Only if the payout differs
-- from the config it probes one crop per growth tier. Later runs load k and y and verify them on the first sales. AFARM.crops() prints the crop table of the game config.
-- AFARM.relearn() forgets it and probes again.
-- X stops everything, destroys the GUI and removes the globals.
-- AFARM.setMode("fast") / AFARM.dump() are available from the console.
--
-- Pass: harvest every ripe soil -> (the soils are empty: seen locally, no waiting for the crops) -> replant and
-- water at once with the seeds that were bought in advance -> only then sell (in the background when the model is
-- confirmed) -> buy the seeds of the next wave while the crops grow. Planting and watering hand the turn back to the
-- harvest as soon as a soil ripens, so ripe plants never wait behind a long planting loop.
-- Facts used (measured): server accepts 40 req/s, Buy Amount up to 100 per request, FarmAction modes are
-- ignored by the server, selling does not touch the seeds, a Wet soil stays Wet.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local HttpService = game:GetService("HttpService")

local Core = getgenv().HubCore
if not Core then
    warn("Core not found: start hub.luau first")
    return
end
local T = Core.t
local function join(...)
    local a = table.pack(...)
    for i = 1, a.n do
        a[i] = tostring(a[i])
    end
    return table.concat(a, " ", 1, a.n)
end
-- everything the script prints goes to the shared log (copy-log button)
local function warn(...)
    Core.log("AFARM", "%s", join(...))
end
local function print(...)
    Core.log("AFARM", "%s", join(...))
end

local Net = require(ReplicatedStorage.Signals.Net)
local FarmConfig = require(ReplicatedStorage.Config.FarmConfig)
local PlayerDataHelper = require(ReplicatedStorage.Helper.PlayerDataHelper)
local getCurrentSeedAmount = require(ReplicatedStorage.Features.Farm.getCurrentSeedAmount)

local lp = Players.LocalPlayer
local PlayerSystem = require(lp:WaitForChild("PlayerScripts").ClientSystems.PlayerSystem)
local G = getgenv()
local clock = os.clock
local rand = Random.new()

-- stop the previous run completely: threads, connections and the old GUI
for _, t in ipairs(G._AFARM_THREADS or {}) do
    pcall(task.cancel, t)
end
for _, c in ipairs(G._AFARM_CONNS or {}) do
    pcall(function()
        c:Disconnect()
    end)
end
local threads, conns = {}, {}
G._AFARM_THREADS, G._AFARM_CONNS = threads, conns
local oldGui = lp:WaitForChild("PlayerGui"):FindFirstChild("AFarmGUI")
if oldGui then
    oldGui:Destroy()
end

local unload -- assigned below
local MYSCOPE = rawget(_G, "STATE") or getgenv().STATE
pcall(function()
    local ST = rawget(_G, "STATE") or getgenv().STATE
    if ST then
        ST.onCleanup(function()
            if unload then
                unload()
            end
        end)
    end
end)

-- ========== configuration ==========
local MODES = { "auto", "slow", "medium", "fast", "fastest", "custom" }
local MODE_LABEL = { auto = "AUTO", slow = "SLOW", medium = "MEDIUM", fast = "FAST", fastest = "FASTEST!", custom = "CUSTOM" }

local AF = G.AFARM or {}
G.AFARM = AF
AF.enabled = false
-- saved settings (AutoFarmHub/settings.json): mode and every menu row; enabled is never saved
local SAVEKEYS = {
    "mode", "seed", "targetSeeds", "buyChunkMax", "coinReserve", "rate", "maxRate", "burst", "tick", "adapt",
    "doPlant", "doWater", "doHarvest", "doSell", "landWait", "sellEvery", "jitter", "humanPause", "breakEvery",
    "breakLen", "sortByDistance", "coolPlant", "coolWater", "coolHarvest", "failLimit", "banTime", "grace",
    "idleTick", "buyTries", "buyWait", "noBuyPause", "chunkMemory", "trace",
}
do
    local raw = Core.getRaw("garden")
    for _, k in ipairs(SAVEKEYS) do
        local v = raw[k]
        local tv = type(v)
        if AF[k] == nil and (tv == "number" or tv == "string" or tv == "boolean") then
            AF[k] = v
        end
    end
end
local function saveSettings()
    local o = {}
    for _, k in ipairs(SAVEKEYS) do
        if AF[k] ~= nil then
            o[k] = AF[k]
        end
    end
    Core.setFarm("garden", o)
end
if not table.find(MODES, AF.mode) then
    AF.mode = "auto"
end
if AF.trace == nil then
    AF.trace = true
end
if AF.stallWarn == nil then
    AF.stallWarn = 300
end
if AF.stallStop == nil then
    AF.stallStop = 1200 -- 0 = never stop by itself
end

-- defaults shared by every mode
local BASE = {
    -- crop / shop
    targetSeeds = 0, -- 0 = as many as there are empty soils
    buyChunkMax = 100,
    coinReserve = 0,
    buyTries = 12, -- max buy attempts per pass
    buyWait = 1.2, -- seconds to wait for a buy to land
    noBuyPause = 5, -- pause buying after a refusal
    chunkMemory = 30, -- how long a halved buy chunk is remembered
    -- actions
    doPlant = true,
    doWater = true,
    doHarvest = true,
    doSell = true,
    landWait = 2, -- max wait for harvested crops to appear in the inventory before selling
    sellEvery = 15, -- fallback sale interval, 0 = off
    -- speed
    rate = 20,
    maxRate = 40,
    minRate = 6,
    adapt = true,
    tuneWindow = 10, -- seconds per adaptation step
    ceilTime = 90, -- how long a failing rate stays a ceiling
    preBuy = false, -- buy the seeds of the next wave while the crops are still growing
    rateUp = 1.15,
    rateDown = 0.75,
    upRatio = 0.02, -- retries/actions below this: go faster
    downRatio = 0.08, -- retries/actions above this: slow down
    burst = 1, -- requests that may go out back to back
    tick = 0.25,
    idleTick = 0.5,
    -- human behaviour
    jitter = 0, -- random +-fraction on every delay
    humanPause = 0, -- chance per action of a short "thinking" pause
    breakEvery = 0, -- seconds between short breaks, 0 = none
    breakLen = 0,
    sortByDistance = false, -- nearest soil first
    -- failure handling
    coolPlant = 1.5,
    coolWater = 3,
    coolHarvest = 1.5,
    failLimit = 3, -- attempts without effect before a soil is banned
    banTime = 60,
    grace = 0.8, -- seconds before an unanswered action is judged as failed
}

local PROFILES = {
    auto = {
        rate = 30, maxRate = 40, minRate = 10, tick = 0.1, burst = 2,
        tuneWindow = 6, rateUp = 1.12, rateDown = 0.85, upRatio = 0.02, downRatio = 0.06, ceilTime = 60, banTime = 15, preBuy = true,
        coolPlant = 1, coolWater = 2, coolHarvest = 1, grace = 0.6, landWait = 1.5, buyWait = 1.0,
    },
    slow = {
        rate = 4, maxRate = 6, adapt = false, tick = 0.8, burst = 1,
        jitter = 0.45, humanPause = 0.04, breakEvery = 150, breakLen = 5, sortByDistance = true,
        coolPlant = 2.5, coolWater = 5, coolHarvest = 2.5, grace = 1.5,
        buyChunkMax = 50, buyWait = 1.6, landWait = 2.5, sellEvery = 30,
    },
    medium = {
        rate = 20, maxRate = 28, tick = 0.25, burst = 2,
    },
    fast = {
        rate = 32, maxRate = 40, minRate = 12, tick = 0.1, burst = 3,
        tuneWindow = 8, upRatio = 0.015, downRatio = 0.05,
        coolPlant = 1, coolWater = 2, coolHarvest = 1, grace = 0.6, landWait = 1.5, buyWait = 1.0,
    },
    fastest = {
        rate = 40, maxRate = 80, minRate = 15, tick = 0.05, burst = 8,
        tuneWindow = 5, rateUp = 1.25, rateDown = 0.6, upRatio = 0.04, downRatio = 0.12,
        coolPlant = 0.5, coolWater = 1, coolHarvest = 0.5, grace = 0.4,
        failLimit = 6, banTime = 20, landWait = 1, buyWait = 0.8, noBuyPause = 2,
    },
}
local MERGED = {}
for name, o in pairs(PROFILES) do
    MERGED[name] = setmetatable(o, { __index = BASE })
end

-- effective value: CUSTOM row if set, otherwise the value of the active mode (CUSTOM falls back to MEDIUM)
local function eff(k)
    if AF.mode == "custom" then
        local v = AF[k]
        if v ~= nil and v ~= "auto" then
            return v
        end
        return MERGED.medium[k]
    end
    return MERGED[AF.mode][k]
end

local COOLKEY = { plant = "coolPlant", water = "coolWater", harvest = "coolHarvest" }

-- runtime state (adapted and learned while running)
local RT = {
    rate = 20,
    seed = nil,
    ceiling = nil, ceilUntil = 0, -- a rate that failed recently: do not climb above it for a while
    good = nil, -- last rate that had a clean window
    stallUntil = 0, -- the server stalled (failures at a rate that was clean before): no bans, patient retries
    nextRipe = nil,
    value = {}, -- crop -> measured coins per harvested soil
    grow = { {}, {} }, -- [1] watered / [2] dry: crop -> measured growth time / harvestTimeSec
    blocked = {}, -- crop -> time until which the server refused it
    lat = 0.3, -- measured delay between a request and its visible result (EMA)
    chunk = {}, -- crop -> { n, untilT }: remembered buy chunk after a real refusal
    refused = {}, -- crop -> refusals in a row although the coins were enough
    okAt = {}, -- crop -> when a buy of it last worked (such a crop is never called "above level")
    glog = {},
}

local S = {
    planted = 0, empty = 0, ripe = 0, soils = 0, harvested = 0, plantedTotal = 0,
    actionsTotal = 0, retriesTotal = 0, active = 0, coins0 = 0,
}
AF.stats, AF.runtime = S, RT
-- diagnostics printed with every `stat` line: where the soils lose time
local D = { rn = 0, rs = 0, en = 0, es = 0, shop = 0, cs = 0, cn = 0, gs = 0 }
AF.diag = D
local hLast = setmetatable({}, { __mode = "k" }) -- diag: soil -> time of its previous harvest request

local function log(...)
    if AF.trace then
        print(...)
    end
end

-- an action is judged as failed only after the server had time to show it (3x the measured delay)
local function graceEff()
    local g = math.min(math.max(eff("grace"), RT.lat * 3), 4)
    if clock() < RT.stallUntil then
        g = math.min(g * 2, 4) -- answers are late, not lost: do not double the load with early retries
    end
    return g
end

local function curRate()
    if AF.mode == "custom" and type(AF.rate) == "number" then
        return AF.rate
    end
    return RT.rate
end

-- ========== rate limiter (shared by every remote) ==========
local win = { actions = 0, retries = 0, t = clock() }
local nextSlot = 0
local function pace()
    local now = clock()
    local interval = 1 / math.max(curRate(), 1)
    local floor = now - (math.max(eff("burst"), 1) - 1) * interval -- unused credit allows a burst
    if nextSlot < floor then
        nextSlot = floor
    end
    local wait = nextSlot - now
    local j = eff("jitter")
    local step = interval
    if j > 0 then
        step = interval * (1 + (rand:NextNumber() * 2 - 1) * j)
    end
    nextSlot = nextSlot + step
    local hp = eff("humanPause")
    if hp > 0 and rand:NextNumber() < hp then
        local extra = 0.3 + rand:NextNumber() * 1.2
        wait = math.max(wait, 0) + extra
        nextSlot = nextSlot + extra
    end
    win.actions = win.actions + 1
    S.actionsTotal = S.actionsTotal + 1
    if wait > 0.001 then
        task.wait(wait)
    end
end

-- faster while retries stay rare, slower when they pile up; a failing rate becomes a temporary ceiling
local function tuneRate(now)
    local fixed = AF.mode == "custom" and type(AF.rate) == "number"
    if fixed or not eff("adapt") then
        win.actions, win.retries, win.t = 0, 0, now
        return
    end
    if now - win.t < eff("tuneWindow") then
        return
    end
    if win.actions >= 25 then
        local ratio = win.retries / win.actions
        local tag
        if ratio > eff("downRatio") then
            local good = RT.good or eff("rate")
            if RT.rate > good * 1.05 then
                -- we climbed above the last clean rate and it failed: that rate is the ceiling (briefly)
                RT.ceiling, RT.ceilUntil = good, now + eff("ceilTime")
                RT.rate = math.max(eff("minRate"), good)
                tag = "ceil"
            else
                -- failures at a rate that was clean a moment ago: the server stalled and our rate is not the
                -- cause (lowering it did not help in the logs). Back off a little, never below 75% of the clean
                -- rate, and do not remember a ceiling.
                RT.stallUntil = now + 15
                RT.rate = math.max(eff("minRate"), RT.rate * 0.92, good * 0.75)
                tag = "stall"
            end
        elseif ratio < eff("upRatio") then
            RT.good = RT.rate
            local limit = eff("maxRate")
            if RT.ceiling and now < RT.ceilUntil then
                limit = math.min(limit, RT.ceiling)
            end
            RT.rate = math.min(limit, RT.rate * eff("rateUp"))
        end
        RT.rate = math.min(RT.rate, eff("maxRate"))
        if tag then
            log("rate", math.floor(RT.rate), "retries", win.retries, "/", win.actions, tag)
        else
            log("rate", math.floor(RT.rate), "retries", win.retries, "/", win.actions)
        end
    end
    win.actions, win.retries, win.t = 0, 0, now
end

local function resetRate()
    RT.rate = eff("rate")
    RT.ceiling, RT.ceilUntil = nil, 0
    RT.good, RT.stallUntil = nil, 0
    win.actions, win.retries, win.t = 0, 0, clock()
end

local function setMode(m)
    if not table.find(MODES, m) then
        return
    end
    AF.mode = m
    resetRate()
    saveSettings()
end
AF.setMode = setMode
resetRate()

-- ========== helpers ==========
local function getPlayerData()
    return PlayerSystem:GetPlayerData()
end

local function coins()
    local d = getPlayerData()
    return d and d.Coins or 0
end

local function seedId()
    if AF.mode == "custom" and AF.seed ~= nil and AF.seed ~= "auto" then
        return AF.seed
    end
    return RT.seed
end

local function isAutoSeed()
    return AF.mode ~= "custom" or AF.seed == nil or AF.seed == "auto"
end

local function seedStock(d)
    d = d or getPlayerData()
    local sid = seedId()
    return sid and d and d.Inventory and getCurrentSeedAmount(d.Inventory, sid) or 0
end

local function cropUnits() -- all harvested crops in the inventory
    local d = getPlayerData()
    local inv = d and d.Inventory
    if not inv then
        return 0
    end
    local total = 0
    for name in pairs(FarmConfig.Crops) do
        total = total + (PlayerDataHelper.GetMaterialAmount(inv, name) or 0)
    end
    return total
end

-- wait until getter() leaves `base` and stays unchanged for `quiet` seconds; returns the last value
local function waitStable(getter, base, timeout, quiet)
    local t0, last, lastChange = clock(), base, nil
    while clock() - t0 < timeout do
        task.wait(0.05)
        local v = getter()
        if v ~= last then
            last, lastChange = v, clock()
        end
        if lastChange and clock() - lastChange > quiet then
            break
        end
    end
    return last
end

local lastEquip = 0
local function equipTool()
    local char = lp.Character
    if not char or char:FindFirstChild("Watering Can") or clock() - lastEquip < 1 then
        return
    end
    lastEquip = clock()
    local backpack = lp:FindFirstChildOfClass("Backpack")
    local tool = backpack and backpack:FindFirstChild("Watering Can")
    local hum = char:FindFirstChildOfClass("Humanoid")
    if tool and hum then
        hum:EquipTool(tool)
        task.wait(0.4)
    end
end

-- cached soil list
local soils = {}
for _, s in ipairs(CollectionService:GetTagged("FarmSoil")) do
    soils[s] = true
end
conns[#conns + 1] = CollectionService:GetInstanceAddedSignal("FarmSoil"):Connect(function(s)
    soils[s] = true
end)
conns[#conns + 1] = CollectionService:GetInstanceRemovedSignal("FarmSoil"):Connect(function(s)
    soils[s] = nil
end)

local soilPos = setmetatable({}, { __mode = "k" })
local soilCrop = setmetatable({}, { __mode = "k" }) -- soil -> crop currently on it
local waterSent = setmetatable({}, { __mode = "k" }) -- soil -> water requests sent since it was planted
local emptyAt = setmetatable({}, { __mode = "k" }) -- soil -> when the scan first saw it empty
local plantedAt = setmetatable({}, { __mode = "k" }) -- soil -> { t = server time it was first seen planted, crop }
local seenEmpty = setmetatable({}, { __mode = "k" }) -- soil was seen empty, so its next planting is timed from the start

local function posOf(soil)
    local p = soilPos[soil]
    if p == nil then
        local ok, cf = pcall(soil.GetPivot, soil)
        p = ok and cf.Position or false
        soilPos[soil] = p
    end
    return p
end

-- SLOW: nearest soil first with a little noise, like walking along the rows
local function orderList(list)
    if #list < 2 or not eff("sortByDistance") then
        return list
    end
    local char = lp.Character
    local hrp = char and char:FindFirstChild("HumanoidRootPart")
    if not hrp then
        return list
    end
    local origin, keyed = hrp.Position, {}
    for i, s in ipairs(list) do
        local p = posOf(s)
        keyed[i] = { s = s, d = (p and (p - origin).Magnitude or 1e9) * (0.85 + rand:NextNumber() * 0.3) }
    end
    table.sort(keyed, function(a, b)
        return a.d < b.d
    end)
    for i, k in ipairs(keyed) do
        list[i] = k.s
    end
    return list
end

-- ========== crop model + memory between runs ==========
-- Known fact: crops differ ONLY in sale price and growth speed. So two numbers describe every crop:
--   k = coins really received per unit / config price     (price realisation)
--   y = crop units that one harvested soil gives          (yield)
-- A sale is measured only when ONE kind of crop was in the inventory (coins / units = its price, coins of another
-- crop cannot leak in). Until k and y are understood the script PROBES: one wave per growth tier (best crop of the
-- tier first); it stops as soon as two crops of different tiers agree. A confirmed model is saved to a file; the
-- next run loads it, plants normally and only VERIFIES it on the first sales.
local MODEL_FILE = "afarm_learn.json"
local PROBE_N = 2 -- clean sales per probed crop
local PROBE_MAX = 4 -- crops probed per series
local CONSIST = 1.35 -- two crops agree if their k (and y) differ by less than this factor
local M = {
    state = "watch", k = nil, y = nil, kRef = nil, yRef = nil,
    cur = nil, curN = 0, curSkip = 0, curT = 0, curMax = 0, done = {}, probes = 0, fresh = 0, nextTry = 0,
}
RT.model, RT.vs, RT.pool, RT.runs = M, {}, {}, 1 -- vs: crop -> last sales, pool: last sales of every crop

local NTIER = 0 -- number of different growth times in the config
do
    local seen = {}
    for _, c in pairs(FarmConfig.Crops) do
        if type(c) == "table" and c.harvestTimeSec and not seen[c.harvestTimeSec] then
            seen[c.harvestTimeSec], NTIER = true, NTIER + 1
        end
    end
end

local canFile = type(writefile) == "function" and type(readfile) == "function" and type(isfile) == "function"

local function cropSig() -- changes when the game changes prices or times
    local names = {}
    for name, c in pairs(FarmConfig.Crops) do
        if type(c) == "table" then
            names[#names + 1] = name
        end
    end
    table.sort(names)
    local h = 0
    for _, name in ipairs(names) do
        local c = FarmConfig.Crops[name]
        h = (h * 31 + (c.cropPrice or 0) * 7 + (c.seedPrice or 0) * 3 + (c.harvestTimeSec or 0)) % 2147483647
    end
    return h
end
local SIG = cropSig()

local function fmt(x)
    return x and string.format("%.2f", x) or "?"
end

local lastSave = 0
local function saveLearn(force)
    if not canFile then
        return
    end
    local t = clock()
    if not force and t - lastSave < 20 then
        return
    end
    lastSave = t
    local ok = M.state == "confirmed" and M.k ~= nil
    pcall(function()
        writefile(MODEL_FILE, HttpService:JSONEncode({
            v = 2, place = game.PlaceId, sig = SIG, runs = RT.runs, saved = os.time(),
            confirmed = ok, k = ok and M.k or nil, y = ok and M.y or nil, wet = RT.grow[1], dry = RT.grow[2],
        }))
    end)
end

local function loadLearn()
    if not canFile then
        return
    end
    local ok, data = pcall(function()
        if not isfile(MODEL_FILE) then
            return nil
        end
        return HttpService:JSONDecode(readfile(MODEL_FILE))
    end)
    if not ok or type(data) ~= "table" then
        return
    end
    if data.v ~= 2 or data.place ~= game.PlaceId or data.sig ~= SIG then
        log("saved model belongs to another game / config / script version: ignored")
        return
    end
    RT.runs = (tonumber(data.runs) or 0) + 1
    for i, key in ipairs({ "wet", "dry" }) do
        if type(data[key]) == "table" then
            for name, f in pairs(data[key]) do
                if type(f) == "number" then
                    RT.grow[i][name] = f
                end
            end
        end
    end
    if data.confirmed and type(data.k) == "number" and data.k > 0 then
        M.state, M.k, M.kRef = "verify", data.k, data.k
        if type(data.y) == "number" and data.y > 0 then
            M.y, M.yRef = data.y, data.y
        end
        log("previous run loaded: k", fmt(M.k), "yield", fmt(M.y), "-> verifying on the first sales")
    else
        log("previous run found, but its model was not confirmed")
    end
end

local function resetModel()
    M.state, M.k, M.y, M.kRef, M.yRef = "probe", nil, nil, nil, nil
    M.cur, M.curN, M.curSkip, M.done, M.probes, M.fresh, M.nextTry = nil, 0, 0, {}, 0, 0, 0
    RT.vs, RT.pool, RT.value = {}, {}, {}
end

-- price realisation: coins received / coins the config promises, over sales [from..#list]
local function priceK(list, from)
    local d, w = 0, 0
    for i = from or 1, #list do
        d, w = d + list[i].d, w + list[i].w
    end
    return w > 0 and d / w or nil
end

-- yield: crop units per harvested soil (only sales where the harvested soils are known)
local function yieldY(list, from)
    -- units that landed in a sale can come from soils of an earlier pass (units > soils), never the other way
    -- round, so the smallest units/soils ratio of several sales is the closest to the truth
    local best, n = nil, 0
    for i = from or 1, #list do
        local x = list[i]
        if x.h >= 5 then
            n = n + 1
            best = best and math.min(best, x.u / x.h) or x.u / x.h
        end
    end
    return n >= 3 and best or nil
end

local function drifted(a, ref, lim)
    return a ~= nil and ref ~= nil and (a / ref > lim or a / ref < 1 / lim)
end

local function modelUpdate()
    if M.state == "verify" then
        if M.fresh >= 5 then
            local kn, yn = priceK(RT.pool), yieldY(RT.pool)
            if kn and not drifted(kn, M.k, 1.43) then
                M.k = (M.k + kn) / 2
                M.y = (M.y and yn) and (M.y + yn) / 2 or M.y or yn
                M.kRef, M.yRef, M.state = M.k, M.y, "confirmed"
                log("model confirmed by the previous run: k", fmt(M.k), "yield", fmt(M.y))
                saveLearn(true)
            else
                log("previous run does not match (k", fmt(kn), "vs", fmt(M.k), "yield", fmt(yn), "vs", fmt(M.y), ") -> probing")
                resetModel()
            end
        end
    elseif M.state == "confirmed" then
        local n = #RT.pool
        if n >= 8 then
            local k8, y8 = priceK(RT.pool, n - 7), yieldY(RT.pool, n - 7)
            if drifted(k8, M.kRef, 1.6) then
                log("payout changed (k", fmt(k8), "yield", fmt(y8), ") -> probing again")
                resetModel()
                return
            end
            M.k = priceK(RT.pool) or M.k
            M.y = yieldY(RT.pool) or M.y
        end
        saveLearn(false)
    elseif M.state == "watch" then
        -- passive: the crop that is being farmed already shows whether the server pays the config prices
        local best
        for name, list in pairs(RT.vs) do
            if not best or #list > #RT.vs[best] then
                best = name
            end
        end
        local list = best and RT.vs[best]
        local r = list and (#list >= 2 or list[#list].u >= 20) and priceK(list)
        if r and r > 0.97 and r < 1.03 then
            M.k, M.y = priceK(RT.pool) or r, yieldY(RT.pool)
            M.kRef, M.yRef, M.state = M.k, M.y, "confirmed"
            log("model confirmed: the server pays exactly the config price. k", fmt(M.k), "yield", fmt(M.y), "crop", best)
            saveLearn(true)
        elseif r and #list >= 4 then
            log("the server does not pay the config price (k", fmt(r), ") -> probing the other tiers")
            M.state = "probe"
        end
    else -- probe / open: do crops of different tiers agree on k and y?
        local cnt, kLo, kHi, yLo, yHi, tiers = 0, nil, nil, nil, nil, {}
        for name, list in pairs(RT.vs) do
            local r = #list >= PROBE_N and priceK(list)
            if r then
                cnt, kLo, kHi = cnt + 1, kLo and math.min(kLo, r) or r, kHi and math.max(kHi, r) or r
                local y = yieldY(list)
                if y then
                    yLo, yHi = yLo and math.min(yLo, y) or y, yHi and math.max(yHi, y) or y
                end
                local c = FarmConfig.Crops[name]
                if c then
                    tiers[c.harvestTimeSec] = true
                end
            end
        end
        local nt = 0
        for _ in pairs(tiers) do
            nt = nt + 1
        end
        if cnt >= 2 and nt >= math.min(2, NTIER) and kHi / kLo <= CONSIST then
            M.k, M.y = priceK(RT.pool), yieldY(RT.pool)
            M.kRef, M.yRef, M.state, M.cur = M.k, M.y, "confirmed", nil
            log("model confirmed: crops differ only in price and speed. k", fmt(M.k), "yield", fmt(M.y), "crops", cnt, "tiers", nt)
            saveLearn(true)
        end
    end
end

-- units per soil snapped to steps of 0.5: late coins make the measured value wobble (1.0 shows as 1.1)
local function yieldR()
    local y = M.y or yieldY(RT.pool)
    local r = y and math.floor(y * 2 + 0.5) / 2 or 1
    return r > 0 and r or 1
end

local function valueOf(name, c) -- what one harvested soil of this crop is worth
    if M.k and (M.state == "confirmed" or M.state == "verify") then
        return c.cropPrice * M.k * yieldR()
    end
    local list = RT.vs[name]
    local k = list and #list >= 2 and priceK(list)
    return c.cropPrice * (k or 1) * yieldR()
end

loadLearn()

-- ========== learning (used by the crop choice) ==========
local lastWLog = 0
local function learnGrow(name, real, waters)
    local c = FarmConfig.Crops[name]
    if not (c and c.harvestTimeSec) or real < 0.2 or real > c.harvestTimeSec * 1.5 then
        return
    end
    if waters and waters > 1 then
        -- watered more than once (a retry landed twice): logged for diagnosis, kept out of the growth model
        if clock() - lastWLog > 1 then
            lastWLog = clock()
            log("grow", name, string.format("%.1fs", real), "waters", waters)
        end
        return
    end
    local t = RT.grow[eff("doWater") and 1 or 2]
    local f = math.clamp(real / c.harvestTimeSec, 0.02, 1.5)
    t[name] = t[name] and (t[name] * 0.6 + f * 0.4) or f
    t["*"] = t["*"] and (t["*"] * 0.7 + f * 0.3) or f
    if not RT.glog[name] or math.abs(RT.glog[name] - real) > 0.5 then
        RT.glog[name] = real
        log("grow", name, string.format("%.1fs", real))
    end
    saveLearn(false)
end

local function growTime(name, c)
    local wet = eff("doWater")
    local t = RT.grow[wet and 1 or 2]
    return c.harvestTimeSec * (t[name] or t["*"] or (wet and 0.1 or 1))
end

-- one clean sale: `units` crop units of ONE kind gave `delta` coins; `harvests` soils gave them (0 = unknown)
local function learnValue(name, delta, units, harvests)
    local c = FarmConfig.Crops[name]
    if not (c and c.cropPrice) or units < 1 or delta <= 0 then
        return
    end
    local per = delta / units
    if per < c.cropPrice * 0.2 or per > c.cropPrice * 5 then
        return
    end
    if name == M.cur and M.curSkip > 0 then
        M.curSkip = M.curSkip - 1 -- the first sale of a probe: the coins of the previous crop still land
        return
    end
    -- late coins move between neighbouring sales, so everything is summed over the last sales, not averaged
    local smp = { d = delta, u = units, w = units * c.cropPrice, h = harvests or 0 }
    local list = RT.vs[name] or {}
    RT.vs[name] = list
    list[#list + 1] = smp
    if #list > 8 then
        table.remove(list, 1)
    end
    local d, h = 0, 0
    for _, x in ipairs(list) do
        if x.h > 0 then
            d, h = d + x.d, h + x.h
        end
    end
    if h >= 3 then
        RT.value[name] = d / h -- coins per harvested soil
    end
    RT.pool[#RT.pool + 1] = smp
    if #RT.pool > 24 then
        table.remove(RT.pool, 1)
    end
    M.fresh = M.fresh + 1
    if name == M.cur then
        M.curN = M.curN + 1
    end
    log("sale", name, "units", units, "soils", harvests or 0, "coins", math.floor(delta), "per unit", string.format("%.1f", per))
    modelUpdate()
end

-- ========== per-soil attempt tracking (outcome based) ==========
-- record: an action was fired. outcome: judged by the soil's attribute `grace` seconds later.
-- An action without effect `failLimit` times in a row bans that soil for `banTime` seconds.
-- Failures also feed the adaptive rate (retries).
local track = { plant = {}, water = {}, harvest = {} }
for _, t in pairs(track) do
    setmetatable(t, { __mode = "k" })
end

local function banned(action, soil, now)
    local r = track[action][soil]
    return r ~= nil and now < r.ban
end

local function canFire(action, soil, now)
    local r = track[action][soil]
    return r == nil or (now >= r.ban and now - r.t >= math.max(eff(COOLKEY[action]), graceEff() + 0.1))
end

local function record(action, soil, now)
    local r = track[action][soil]
    if not r then
        track[action][soil] = { t = now, fails = 0, ban = 0, judged = false }
    else
        r.t, r.judged = now, false
    end
end

local function outcome(action, soil, now, succeeded)
    local r = track[action][soil]
    if not r then
        return
    end
    if succeeded then
        if (action == "plant" or action == "water") and not r.judged then
            local dt = now - r.t
            if dt > 0 and dt < 5 then
                RT.lat = RT.lat * 0.9 + dt * 0.1
            end
        end
        track[action][soil] = nil
    elseif not r.judged and now - r.t >= graceEff() then
        r.judged = true
        win.retries = win.retries + 1
        S.retriesTotal = S.retriesTotal + 1
        if now < RT.stallUntil then
            return -- server stall: the soil is not at fault, do not count towards a ban
        end
        r.fails = r.fails + 1
        if r.fails >= eff("failLimit") then
            r.fails, r.ban = 0, now + eff("banTime")
            log("ban", action, soil:GetFullName())
        end
    end
end

-- classify every soil: ripe (harvest), empty (plant), dry (water); judge pending actions on the way
local function scan()
    local now, serverNow = clock(), workspace:GetServerTimeNow()
    local ripe, empty, dry = {}, {}, {}
    local planted, emptyN, total, nextRipe = 0, 0, 0, nil
    for soil in pairs(soils) do
        total = total + 1
        local pid = soil:GetAttribute("PlantId")
        if pid == nil then
            seenEmpty[soil] = true
            emptyAt[soil] = emptyAt[soil] or now
            if not track.plant[soil] then
                plantedAt[soil] = nil
            end
            outcome("harvest", soil, now, true)
            outcome("plant", soil, now, false)
            track.water[soil] = nil
            if not banned("plant", soil, now) then
                emptyN = emptyN + 1
                if canFire("plant", soil, now) then
                    empty[#empty + 1] = soil
                end
            end
        else
            planted = planted + 1
            emptyAt[soil] = nil
            soilCrop[soil] = pid
            outcome("plant", soil, now, true)
            local pa = plantedAt[soil]
            if not pa or pa.crop ~= pid then
                pa = { t = serverNow, crop = pid, skip = not seenEmpty[soil] }
                plantedAt[soil], seenEmpty[soil] = pa, nil
            end
            local gend = soil:GetAttribute("GrowthEndTime") or 0
            if gend > 0 and serverNow >= gend then
                if not pa.done then
                    pa.done = true
                    if not pa.skip then
                        learnGrow(pid, gend - pa.t, waterSent[soil])
                    end
                end
                track.water[soil] = nil
                outcome("harvest", soil, now, false)
                if canFire("harvest", soil, now) then
                    ripe[#ripe + 1] = soil
                end
            else
                if gend > 0 and (not nextRipe or gend - serverNow < nextRipe) then
                    nextRipe = gend - serverNow
                end
                outcome("harvest", soil, now, true)
                local wet = soil:GetAttribute("SoilState") == "Wet"
                outcome("water", soil, now, wet)
                if not wet and canFire("water", soil, now) then
                    dry[#dry + 1] = soil
                end
            end
        end
    end
    S.planted, S.empty, S.ripe, S.soils = planted, emptyN, #ripe, total
    RT.nextRipe = nextRipe
    return ripe, empty, dry, emptyN
end

-- ========== AUTO crop choice ==========
local picked, lastPick = nil, 0

local function isBlocked(name, now)
    local u = RT.blocked[name]
    return u ~= nil and now < u
end

local lastLevel
local function playerLevel() -- any numeric field called "level" (top level or one table deeper), then leaderstats / attributes
    local found
    local d = getPlayerData()
    if d then
        for k, v in pairs(d) do
            if type(v) == "number" and tostring(k):lower() == "level" then
                found = v
                break
            elseif type(v) == "table" and k ~= "Inventory" then
                for k2, v2 in pairs(v) do
                    if type(v2) == "number" and tostring(k2):lower() == "level" then
                        found = v2
                        break
                    end
                end
                if found then
                    break
                end
            end
        end
    end
    if found == nil then
        pcall(function()
            local lp = game:GetService("Players").LocalPlayer
            local ls = lp:FindFirstChild("leaderstats")
            local lv = ls and (ls:FindFirstChild("Level") or ls:FindFirstChild("level"))
            if lv and type(lv.Value) == "number" then
                found = lv.Value
            else
                local a = lp:GetAttribute("Level") or lp:GetAttribute("level")
                if type(a) == "number" then
                    found = a
                end
            end
        end)
    end
    if found ~= lastLevel then
        lastLevel = found
        log("level", found == nil and "unknown (blocked crops are learned from refused buys)" or found)
    end
    return found
end

-- level used for choosing crops: the real one if the game shows it, else the ceiling learned from refused buys
local function effLevel(now)
    local l = playerLevel()
    if l ~= nil then
        return l
    end
    if RT.lvlLimit and now < RT.lvlUntil then
        return RT.lvlLimit
    end
    return nil
end

-- a crop was refused although the coins were enough: our level is below its level, so every crop at that
-- level or above is out as well (until the limit expires and is tested again)
local function learnLevelLimit(sid)
    local c = FarmConfig.Crops[sid]
    local L = c and c.requiredLevel or 0
    if L > 0 then
        RT.lvlLimit = math.min(RT.lvlLimit or math.huge, L - 1)
        RT.lvlUntil = clock() + 240
        log("level limit", "below " .. L, "-> only crops up to level", RT.lvlLimit)
    end
end

-- ---- probing: which crop to test next ----
-- best crop (by config profit/s) of a growth tier that has not been measured yet, then the best of the rest
local function pickProbe(now)
    if M.probes >= PROBE_MAX then
        return nil
    end
    local n = math.max(S.soils, 1)
    local money, level = coins() - eff("coinReserve"), effLevel(now)
    local rate = math.max(curRate(), 1)
    local seen = {}
    for name in pairs(M.done) do
        local c = FarmConfig.Crops[name]
        if c then
            seen[c.harvestTimeSec] = true
        end
    end
    local bestU, scoreU, bestA, scoreA
    for name, c in pairs(FarmConfig.Crops) do
        if type(c) == "table" and c.seedPrice and c.cropPrice and c.harvestTimeSec and not M.done[name] and not isBlocked(name, now)
            and (level == nil or (c.requiredLevel or 0) <= level) then
            local afford = math.min(n, math.floor(money / math.max(c.seedPrice, 1)))
            if afford >= math.min(3, n) then
                local cycle = math.max(growTime(name, c) + 1 + eff("tick"), 3 * afford / rate + 1)
                local score = (c.cropPrice - c.seedPrice) * afford / cycle
                if score > 0 then
                    if not seen[c.harvestTimeSec] and (not scoreU or score > scoreU) then
                        bestU, scoreU = name, score
                    end
                    if not scoreA or score > scoreA then
                        bestA, scoreA = name, score
                    end
                end
            end
        end
    end
    return bestU or bestA
end

-- returns the crop that must be planted for the probe right now (or nil when nothing is being probed)
local function probeStep(now)
    if AF.mode ~= "auto" then
        return nil
    end
    if M.state == "open" and now > M.nextTry then
        M.state, M.probes, M.done = "probe", 0, {}
        log("probing the crops that are still unmeasured")
    end
    if M.state ~= "probe" then
        return nil
    end
    if M.cur then
        if M.curN < PROBE_N and not isBlocked(M.cur, now) and now - M.curT < M.curMax then
            return M.cur
        end
        M.done[M.cur], M.cur = true, nil
    end
    local nxt = pickProbe(now)
    if not nxt then
        if M.probes > 0 then
            M.state, M.nextTry = "open", now + 600
            log("probing finished without a common k: using per-crop measurements")
        end
        return nil
    end
    local c = FarmConfig.Crops[nxt]
    M.cur, M.curN, M.curSkip, M.curT, M.probes = nxt, 0, 0, now, M.probes + 1
    M.curMax = growTime(nxt, c) * 3 + 25
    log("probe", M.probes .. "/" .. PROBE_MAX, nxt, "tier", c.harvestTimeSec)
    return nxt
end

local wasForced = false
-- score = profit per second of the whole farm.
-- one soil cycle can't be shorter than its growth (+ our reaction time), and the whole farm can't cycle
-- faster than the limiter can send 3 requests per soil (harvest, plant, water).
local function chooseSeed(now)
    local forced = probeStep(now)
    if forced then
        wasForced = true
        if picked ~= forced then
            picked, RT.seed, lastPick = forced, forced, now
            log("crop ->", forced, "(probe)")
        end
        return
    elseif wasForced then
        wasForced, lastPick = false, 0 -- the probe is over: choose normally at once
    end
    local reeval = AF.mode == "auto" and 15 or 30
    if picked and not isBlocked(picked, now) and now - lastPick < reeval then
        return
    end
    lastPick = now
    local n = math.max(S.soils, 1)
    local money, level = coins() - eff("coinReserve"), effLevel(now)
    local rate, latency = math.max(curRate(), 1), 1 + eff("tick")
    local best, bestScore, curScore, cheapest = nil, nil, 0, nil
    for name, c in pairs(FarmConfig.Crops) do
        if type(c) == "table" and c.seedPrice and c.cropPrice and c.harvestTimeSec and not isBlocked(name, now) then
            if level == nil or (c.requiredLevel or 0) <= level then
                if not cheapest or c.seedPrice < FarmConfig.Crops[cheapest].seedPrice then
                    cheapest = name
                end
                local afford = math.min(n, math.floor(money / math.max(c.seedPrice, 1)))
                if afford > 0 then
                    local cycle = math.max(growTime(name, c) + latency, 3 * afford / rate + 1)
                    local value = valueOf(name, c)
                    local score = (value - c.seedPrice) * afford / cycle
                    if name == picked then
                        curScore = score
                    end
                    if not bestScore or score > bestScore then
                        best, bestScore = name, score
                    end
                end
            end
        end
    end
    best = best or cheapest
    if not best then
        -- everything is blocked (false refusals?): forget the blocks and try again instead of standing still
        if next(RT.blocked) or RT.lvlLimit then
            RT.blocked, RT.lvlLimit = {}, nil
            log("no crop left: block list cleared")
        end
        return
    end
    if best and best ~= picked and (not picked or isBlocked(picked, now) or (bestScore or 0) > curScore * 1.15) then
        picked, RT.seed = best, best
        log("crop ->", best, "score", math.floor(bestScore or 0))
    end
end

-- ========== shop ==========
-- wait for a buy to show up: the seed count rises, or the coins drop (then the seeds are on their way)
local function waitBuy(stock0, coins0, timeout, price)
    local t0, lastChange = clock(), nil
    local s, cn = stock0, coins0
    while true do
        task.wait(0.05)
        local s2, c2 = seedStock(), coins()
        if s2 ~= s or c2 ~= cn then
            s, cn, lastChange = s2, c2, clock()
        end
        local el = clock() - t0
        local full = s > stock0 and (price <= 0 or (s - stock0) >= (coins0 - cn) / price * 0.9 or el > timeout + 1.5)
        if lastChange and clock() - lastChange > 0.3 and (full or el > timeout) then
            break
        end
        if el > timeout + (cn < coins0 and 2.5 or 0) then
            break
        end
    end
    return s, coins0 - cn
end

-- One request for everything that is missing, never more than the coins allow (coins are re-read after every
-- buy). A refusal only counts when the coins were enough and nothing changed: then the chunk is halved
-- (remembered per crop); a crop is blocked only after two such refusals at chunk 1.
local noBuyUntil = 0
local sellBusy, lastSellAt = false, 0 -- a background sale is running / when the last sale was sent
local seedsUsed = 0 -- seeds spent on planting (the shop thread compensates for them when it counts what arrived)
local function ensureSeedsInner(want)
    local sid = seedId()
    local c = FarmConfig.Crops[sid]
    local price = c and c.seedPrice or 0
    local stock = seedStock()
    if isAutoSeed() and isBlocked(sid, clock()) then
        chooseSeed(clock()) -- the crop in use was blocked: switch before buying anything
        return stock
    end
    if clock() < noBuyUntil then
        return stock
    end
    if stock < want and price > 0 and (sellBusy or clock() - lastSellAt < 2.5)
        and coins() - eff("coinReserve") < (want - stock) * price then
        waitStable(coins, coins(), 1.5, 0.3) -- the coins of the sale in flight pay for these seeds
    end
    local reserve = eff("coinReserve")
    local tries = 0
    local deadline = clock() + 3.5 -- ripe plants never wait longer than this behind the shop
    while AF.enabled and tries < eff("buyTries") and clock() < deadline do
        local afford = price > 0 and math.floor((coins() - reserve) / price) or math.huge
        local need = math.min(want, stock + math.max(afford, 0)) - stock
        if need <= 0 then
            if stock < want and afford <= 0 then
                noBuyUntil = clock() + 1 -- no coins: wait for the next sale
            end
            break
        end
        tries = tries + 1
        local ch = RT.chunk[sid]
        if ch and clock() > ch.untilT then
            ch, RT.chunk[sid] = nil, nil
        end
        local n = math.min(ch and ch.n or math.huge, eff("buyChunkMax"), need)
        local coins0, used0 = coins(), seedsUsed
        pace()
        Net.FarmShopRequest:FireServer({ RequestType = "Buy", Amount = n, Category = "Material", ItemName = sid })
        local got, spent = waitBuy(stock, coins0, math.max(eff("buyWait"), RT.lat * 4), price)
        got = got + (seedsUsed - used0) -- planting ate some of the new seeds already
        if got <= stock and spent < price * n * 0.5 then
            -- coins of a sale that lands at the same moment hide the payment and the seeds may simply be late:
            -- look again before calling it a refusal
            local t1 = clock()
            while AF.enabled and clock() - t1 < 1.5 and got <= stock do
                task.wait(0.1)
                got = math.max(got, seedStock() + (seedsUsed - used0))
            end
        end
        log("buy", sid, n, "->", got, "spent", math.floor(spent))
        if got > stock then
            stock, RT.refused[sid], RT.okAt[sid] = seedStock(), nil, clock()
            local cc = RT.chunk[sid]
            if cc then -- the server took it: grow the remembered chunk back
                cc.n = cc.n * 2
                cc.untilT = clock() + eff("chunkMemory")
                if cc.n >= eff("buyChunkMax") then
                    RT.chunk[sid] = nil
                end
            end
        elseif price > 0 and spent >= price * n * 0.5 then
            RT.refused[sid] = nil -- paid, the seeds are just late: do not buy again now
            stock = seedStock()
            break
        elseif afford < n then
            noBuyUntil = clock() + 1
            break
        elseif clock() < RT.stallUntil then
            noBuyUntil = clock() + 1.5 -- server stall: the seeds are late, not refused; do not shrink the chunk
            break
        elseif RT.okAt[sid] and clock() - RT.okAt[sid] < 300 then
            noBuyUntil = clock() + 1.5 -- this crop was bought a moment ago: a late answer, not a refusal
            break
        elseif n <= 1 then
            RT.refused[sid] = (RT.refused[sid] or 0) + 1
            if RT.refused[sid] >= 2 and isAutoSeed() then
                RT.blocked[sid], picked, RT.refused[sid] = clock() + 90, nil, nil
                log("crop blocked", sid)
                learnLevelLimit(sid)
                chooseSeed(clock())
            else
                noBuyUntil = clock() + eff("noBuyPause")
            end
            break
        elseif isAutoSeed() and (RT.refused[sid] or 0) >= 1 then
            -- the coins were enough and the server gave nothing twice (crop above our level): drop it, take the next best
            RT.blocked[sid], picked, RT.refused[sid] = clock() + 90, nil, nil
            log("crop blocked", sid, "(refused, probably above level)")
            learnLevelLimit(sid)
            chooseSeed(clock())
            break
        else
            RT.refused[sid] = (RT.refused[sid] or 0) + 1
            RT.chunk[sid] = { n = math.max(5, math.floor(n / 2)), untilT = clock() + eff("chunkMemory") }
        end
    end
    return stock
end

local function ensureSeeds(want)
    local t0 = clock()
    local r = ensureSeedsInner(want)
    D.shop = D.shop + (clock() - t0)
    return r
end

-- buying runs in its own thread: the farm pass never waits for the shop (ripe plants and empty soils come first)
local buyBusy, buyWant = false, 0
local function buyAsync(want)
    buyWant = math.max(buyWant, want)
    if buyBusy then
        return
    end
    buyBusy = true
    threads[#threads + 1] = task.spawn(function()
        pcall(function()
            while buyWant > 0 and AF.enabled do
                local w = buyWant
                buyWant = 0
                ensureSeeds(w)
            end
        end)
        buyBusy = false
    end)
end

local lastSell = 0
-- returns: number of crop kinds sold, number of units, the last kind sold
local function sellAll()
    local d = getPlayerData()
    if not (d and d.Inventory) then
        return 0, 0
    end
    local sent, units, last = 0, 0, nil
    for cropName in pairs(FarmConfig.Crops) do
        if not AF.enabled then
            return sent, units, last
        end
        local amt = PlayerDataHelper.GetMaterialAmount(d.Inventory, cropName) or 0
        if amt > 0 then
            pace()
            Net.FarmShopRequest:FireServer({ RequestType = "Sell", Category = "Material", ItemName = cropName, Amount = amt })
            sent, units, last = sent + 1, units + amt, cropName
        end
    end
    lastSell = clock()
    lastSellAt = lastSell
    return sent, units, last
end

-- sell and measure what the crop really pays. Only a sale of exactly ONE crop kind is a clean sample.
local function sellNow(crop, harvests)
    local c0 = coins()
    local sent, units, only = sellAll()
    if sent == 0 then
        return
    end
    local delta = waitStable(coins, c0, 1.2, 0.25) - c0
    if delta <= 0 and sent == 1 and M.state ~= "confirmed" and AF.enabled then
        delta = waitStable(coins, c0, 2.5, 0.25) - c0 -- slow server: the coins of this sale land late
    end
    if delta > 0 and sent == 1 and only and units >= 3 then
        learnValue(only, delta, units, (crop == only and harvests >= 3) and harvests or 0)
    elseif M.state ~= "confirmed" then
        log("sale not measured:", sent > 1 and "several crop kinds in one sale" or units < 3 and "too few units" or "coins did not arrive in time", "units", units, "coins", math.floor(delta))
    end
end

-- Selling in the background: the pass does not wait for the crops to land and for the coins to arrive, it goes on
-- planting at once (the ripe plants of the next wave are not left standing). Used only when the model is
-- confirmed and the bank covers a full replant; once a minute a normal measured sale still checks the prices.
local lastMeasure = 0
local sellAgain, sellBase = false, 0
local function sellSoon(base)
    sellAgain, sellBase = true, base
    if sellBusy then
        return
    end
    sellBusy = true
    threads[#threads + 1] = task.spawn(function()
        pcall(function()
            while sellAgain and AF.enabled do
                sellAgain = false
                waitStable(cropUnits, sellBase, eff("landWait"), 0.25)
                if AF.enabled then
                    sellAll()
                end
            end
        end)
        sellBusy = false
    end)
end

-- ========== farm actions ==========
local function waterBatch(list)
    local sent = 0
    for i, soil in ipairs(list) do
        if not AF.enabled then
            break
        end
        pace()
        Net.SoilEvent:FireServer(soil, { Action = "WateringComplete" })
        record("water", soil, clock())
        waterSent[soil] = (waterSent[soil] or 0) + 1
        sent = sent + 1
        if i % 8 == 0 and i < #list and eff("doHarvest") and #(scan()) > 0 then
            break -- something ripened meanwhile: the harvest goes first, the rest is watered on the next pass
        end
    end
    return sent
end

-- buy what is missing, then plant every empty soil and water each one right after planting
local function plantBatch(list, emptyN)
    local want = emptyN
    if eff("targetSeeds") > 0 then
        want = math.min(eff("targetSeeds"), emptyN)
    end
    local stock = seedStock()
    if stock < want or stock < S.soils then
        buyAsync(math.max(want, S.soils))
    end
    local n = math.min(#list, stock)
    local sid, water, sent = seedId(), eff("doWater"), 0
    for i = 1, n do
        if not AF.enabled then
            break
        end
        local soil = list[i]
        pace()
        local ea = emptyAt[soil]
        if ea and not track.plant[soil] and clock() - ea < 60 then
            D.en, D.es = D.en + 1, D.es + (clock() - ea)
        end
        Net.SoilEvent:FireServer(soil, { Action = "Plant", PlantId = sid })
        record("plant", soil, clock())
        seedsUsed = seedsUsed + 1
        waterSent[soil] = 0
        plantedAt[soil] = { t = workspace:GetServerTimeNow(), crop = sid, skip = false }
        S.plantedTotal = S.plantedTotal + 1
        sent = sent + 1
        if water then
            pace()
            Net.SoilEvent:FireServer(soil, { Action = "WateringComplete" })
            record("water", soil, clock())
            waterSent[soil] = waterSent[soil] + 1
            sent = sent + 1
        end
        if i % 6 == 0 and i < n and eff("doHarvest") and #(scan()) > 0 then
            break -- something ripened meanwhile: the harvest goes first, the rest is planted on the next pass
        end
    end
    return sent
end

-- local read only: the harvested soils lose their PlantId
local function waitEmpty(list, timeout)
    local t0 = clock()
    while AF.enabled and clock() - t0 < timeout do
        local left = false
        for _, soil in ipairs(list) do
            if soil:GetAttribute("PlantId") ~= nil then
                left = true
                break
            end
        end
        if not left then
            return true
        end
        task.wait(0.05)
    end
    return false
end

-- returns the number of requests fired (0 = nothing to do, the loop may sleep)
-- Order keeps the farm full: harvest -> replant + water at once (the seeds are already in stock) -> only then sell.
-- Nothing the soils wait for is behind a sale or a buy.
local function farmPass()
    equipTool()
    local ripe, empty, dry, emptyN = scan()
    local now = clock()
    if isAutoSeed() then
        chooseSeed(now)
    end
    tuneRate(now)
    if not seedId() then
        return 0
    end
    local acted = 0
    local pending -- the harvest whose crops are still to be sold: { u0, ok, single }

    -- 1) harvest every ripe soil, then see locally when the soils are empty
    if eff("doHarvest") and #ripe > 0 then
        local u0 = cropUnits()
        local fired, single = {}, nil
        for _, soil in ipairs(orderList(ripe)) do
            if not AF.enabled then
                return acted
            end
            pace()
            if not track.harvest[soil] then
                local ge = soil:GetAttribute("GrowthEndTime") or 0
                local lag = workspace:GetServerTimeNow() - ge
                if ge > 0 and lag >= 0 and lag < 60 then
                    D.rn, D.rs = D.rn + 1, D.rs + lag
                end
                -- diag: real time between two harvests of this soil vs the growth time of its crop
                local hn, hc = clock(), FarmConfig.Crops[soilCrop[soil] or ""]
                if hLast[soil] and hn - hLast[soil] < 600 and hc then
                    D.cs, D.cn, D.gs = D.cs + (hn - hLast[soil]), D.cn + 1, D.gs + growTime(soilCrop[soil], hc)
                end
                hLast[soil] = hn
            end
            Net.SoilEvent:FireServer(soil, { Action = "Harvest" })
            record("harvest", soil, clock())
            fired[#fired + 1] = soil
            S.harvested = S.harvested + 1
            local crop = soilCrop[soil]
            if single == nil then
                single = crop
            elseif single ~= crop then
                single = false
            end
        end
        acted = acted + #fired
        waitEmpty(fired, 1.2)
        if eff("doSell") and AF.enabled then
            local ok = 0
            for _, soil in ipairs(fired) do
                if soil:GetAttribute("PlantId") == nil then
                    ok = ok + 1
                end
            end
            pending = { u0 = u0, ok = ok, single = single or nil }
        end
        ripe, empty, dry, emptyN = scan() -- fresh view: the harvested soils are empty now
    end

    -- 2) replant (and water) at once; only if seeds AND coins are both short does the sale go first
    if eff("doPlant") and #empty > 0 and AF.enabled then
        if pending then
            local cs = FarmConfig.Crops[seedId()]
            local short = math.min(#empty, emptyN) - seedStock()
            if short > 0 and cs and coins() < short * (cs.seedPrice or 0) then
                lastMeasure = clock()
                waitStable(cropUnits, pending.u0, eff("landWait"), 0.25)
                sellNow(pending.single, pending.ok)
                pending = nil
            end
        end
        acted = acted + plantBatch(orderList(empty), emptyN)
    end

    -- 3) water the dry ones that are still growing
    if eff("doWater") and #dry > 0 and AF.enabled then
        acted = acted + waterBatch(orderList(dry))
    end

    -- 4) sale, off the critical path: in the background when the model is confirmed (a measured one once a minute)
    if pending and AF.enabled then
        local cs = FarmConfig.Crops[seedId() or ""]
        local bank = coins() >= ((cs and cs.seedPrice) or 10) * math.max(S.soils, 1)
        if M.state == "confirmed" and AF.mode ~= "slow" and bank and clock() - lastMeasure < 60 then
            sellSoon(pending.u0)
        else
            lastMeasure = clock()
            waitStable(cropUnits, pending.u0, eff("landWait"), 0.25)
            sellNow(pending.single, pending.ok)
        end
    end

    -- 5) fallback sale (leftovers, crops that landed late)
    local every = eff("sellEvery")
    if eff("doSell") and AF.enabled and every > 0 and clock() - lastSell > every then
        if M.state == "confirmed" and AF.mode ~= "slow" then
            sellAll()
        else
            sellNow(nil, 0)
        end
        lastSell = clock()
    end

    -- 6) idle: buy the seeds of the next wave while the crops grow, so the next pass plants without the shop wait
    -- v4.6: one bigger purchase instead of many small top-ups: buy when the shortfall is at least half of the
    -- soils, or when the next wave ripens soon (so the full stock is ready), or when the ripening time is unknown
    if eff("preBuy") and eff("doPlant") and AF.enabled and acted == 0 and S.soils > 0 and S.planted > 0 then
        local deficit = S.soils - seedStock()
        if deficit > 0 and (deficit >= math.ceil(S.soils / 2) or RT.nextRipe == nil or RT.nextRipe < 10) then
            buyAsync(S.soils)
        end
    end
    return acted
end

-- ========== GUI ==========
local cropNames = {}
for k in pairs(FarmConfig.Crops) do
    table.insert(cropNames, k)
end
table.sort(cropNames)

Core.addStrings({
    ru = {
        ["g.CROP"] = "КУЛЬТУРА",
        ["g.seed"] = "семена",
        ["g.seeds in stock"] = "семян в запасе",
        ["g.buy chunk max"] = "макс. пачка покупки",
        ["g.coin reserve"] = "резерв монет",
        ["g.SPEED"] = "СКОРОСТЬ",
        ["g.rate /s"] = "запросов/с",
        ["g.auto max rate"] = "авто макс. скорость",
        ["g.burst"] = "пачка запросов",
        ["g.scan interval"] = "интервал скана",
        ["g.adaptive rate"] = "адаптивная скорость",
        ["g.ACTIONS"] = "ДЕЙСТВИЯ",
        ["g.plant"] = "посадка",
        ["g.water"] = "полив",
        ["g.harvest"] = "сбор",
        ["g.sell"] = "продажа",
        ["g.SELLING"] = "ПРОДАЖА",
        ["g.landing wait (s)"] = "ждать урожай (с)",
        ["g.sell every (s)"] = "продавать каждые (с)",
        ["g.HUMAN"] = "ЧЕЛОВЕЧНОСТЬ",
        ["g.timing jitter"] = "разброс задержек",
        ["g.random pauses"] = "случайные паузы",
        ["g.break every (s)"] = "перерыв каждые (с)",
        ["g.break length (s)"] = "длина перерыва (с)",
        ["g.nearest soil first"] = "сначала ближние грядки",
        ["g.TIMING"] = "ТАЙМИНГИ",
        ["g.plant cooldown"] = "пауза посадки",
        ["g.water cooldown"] = "пауза полива",
        ["g.harvest cooldown"] = "пауза сбора",
        ["g.fails before ban"] = "неудач до бана",
        ["g.ban time"] = "время бана",
        ["g.judge delay (grace)"] = "задержка оценки",
        ["g.idle interval"] = "интервал простоя",
        ["g.BUYING"] = "ПОКУПКА",
        ["g.buy attempts"] = "попыток покупки",
        ["g.buy wait"] = "ожидание покупки",
        ["g.pause after refusal"] = "пауза после отказа",
        ["g.chunk memory"] = "память пачки",
        ["g.OTHER"] = "ПРОЧЕЕ",
        ["g.console log"] = "лог в консоль",
        ["g_on"] = "ВКЛ",
        ["g_off"] = "ВЫКЛ",
        ["g_pause"] = "ПАУЗА",
        ["g_toast_unload"] = "Огород выгружен",
    },
    en = {
        ["g.CROP"] = "CROP",
        ["g.seed"] = "seed",
        ["g.seeds in stock"] = "seeds in stock",
        ["g.buy chunk max"] = "buy chunk max",
        ["g.coin reserve"] = "coin reserve",
        ["g.SPEED"] = "SPEED",
        ["g.rate /s"] = "rate /s",
        ["g.auto max rate"] = "auto max rate",
        ["g.burst"] = "burst",
        ["g.scan interval"] = "scan interval",
        ["g.adaptive rate"] = "adaptive rate",
        ["g.ACTIONS"] = "ACTIONS",
        ["g.plant"] = "plant",
        ["g.water"] = "water",
        ["g.harvest"] = "harvest",
        ["g.sell"] = "sell",
        ["g.SELLING"] = "SELLING",
        ["g.landing wait (s)"] = "landing wait (s)",
        ["g.sell every (s)"] = "sell every (s)",
        ["g.HUMAN"] = "HUMAN",
        ["g.timing jitter"] = "timing jitter",
        ["g.random pauses"] = "random pauses",
        ["g.break every (s)"] = "break every (s)",
        ["g.break length (s)"] = "break length (s)",
        ["g.nearest soil first"] = "nearest soil first",
        ["g.TIMING"] = "TIMING",
        ["g.plant cooldown"] = "plant cooldown",
        ["g.water cooldown"] = "water cooldown",
        ["g.harvest cooldown"] = "harvest cooldown",
        ["g.fails before ban"] = "fails before ban",
        ["g.ban time"] = "ban time",
        ["g.judge delay (grace)"] = "judge delay (grace)",
        ["g.idle interval"] = "idle interval",
        ["g.BUYING"] = "BUYING",
        ["g.buy attempts"] = "buy attempts",
        ["g.buy wait"] = "buy wait",
        ["g.pause after refusal"] = "pause after refusal",
        ["g.chunk memory"] = "chunk memory",
        ["g.OTHER"] = "OTHER",
        ["g.console log"] = "console log",
        ["g_on"] = "ON",
        ["g_off"] = "OFF",
        ["g_pause"] = "PAUSE",
        ["g_toast_unload"] = "Garden unloaded",
    },
})
local function GT(text)
    return T("g." .. text)
end
local langRefresh = {} -- functions that re-draw translated texts

local function new(class, props, parent)
    local o = Instance.new(class)
    for k, v in pairs(props) do
        o[k] = v
    end
    o.Parent = parent
    return o
end

local WHITE, GRAY, BTN, BG = Color3.fromRGB(235, 235, 240), Color3.fromRGB(140, 140, 150), Color3.fromRGB(48, 48, 58), Color3.fromRGB(26, 26, 32)
local GREEN, RED = Color3.fromRGB(46, 160, 67), Color3.fromRGB(170, 50, 50)
local ACTIVE, HOT = Color3.fromRGB(40, 110, 200), Color3.fromRGB(215, 110, 30)

local gui = new("ScreenGui", { Name = "AFarmGUI", ResetOnSpawn = false }, lp:WaitForChild("PlayerGui"))
local root = new("Frame", {
    Size = UDim2.fromOffset(200, 166), Position = UDim2.new(0, 20, 0.5, -83),
    BackgroundColor3 = BG, BorderSizePixel = 0, Active = true, Draggable = true,
}, gui)
new("UICorner", { CornerRadius = UDim.new(0, 8) }, root)

local function button(parent, props)
    props.BorderSizePixel, props.TextColor3 = 0, WHITE
    props.Font = props.Font or Enum.Font.GothamBold
    local b = new("TextButton", props, parent)
    new("UICorner", { CornerRadius = UDim.new(0, 6) }, b)
    return b
end

local toggle = button(root, {
    Position = UDim2.fromOffset(6, 6), Size = UDim2.new(1, -12, 0, 72), TextSize = 18,
    AutoButtonColor = false, RichText = true, Text = T("g_off"), BackgroundColor3 = RED,
})
local closeBtn = button(root, {
    Position = UDim2.new(1, -26, 0, 8), Size = UDim2.fromOffset(18, 18), TextSize = 12, Text = "X",
    BackgroundColor3 = Color3.fromRGB(120, 36, 36), ZIndex = 5,
})

-- mode buttons: 3 x 2 grid
local modeBtns = {}
for i, m in ipairs(MODES) do
    local col, row = (i - 1) % 3, math.floor((i - 1) / 3)
    modeBtns[m] = button(root, {
        Position = UDim2.fromOffset(6 + col * 63, 84 + row * 26), Size = UDim2.fromOffset(59, 22),
        TextSize = 10, Text = MODE_LABEL[m], BackgroundColor3 = BTN,
    })
end

local langBtn = button(root, {
    Position = UDim2.fromOffset(6, 138), Size = UDim2.fromOffset(92, 22), TextSize = 10, BackgroundColor3 = BTN,
})
local logBtn = button(root, {
    Position = UDim2.fromOffset(102, 138), Size = UDim2.fromOffset(92, 22), TextSize = 10, BackgroundColor3 = BTN,
})
Core.bindText(logBtn, "log_copy")
logBtn.Activated:Connect(Core.copyLog)
langBtn.Activated:Connect(Core.nextLang)
langRefresh[#langRefresh + 1] = function()
    langBtn.Text = T("lang_label") .. ": " .. Core.getLang():upper()
end
langRefresh[1]()

-- CUSTOM menu (opens under the window): many parameters, grouped
local menu = new("ScrollingFrame", {
    Position = UDim2.new(0, 0, 1, 6), Size = UDim2.new(1, 0, 0, 320), BackgroundColor3 = BG,
    BorderSizePixel = 0, ScrollBarThickness = 3, AutomaticCanvasSize = Enum.AutomaticSize.Y,
    CanvasSize = UDim2.new(), Visible = false,
}, root)
new("UICorner", { CornerRadius = UDim.new(0, 8) }, menu)
new("UIListLayout", { Padding = UDim.new(0, 3), SortOrder = Enum.SortOrder.LayoutOrder }, menu)
new("UIPadding", {
    PaddingTop = UDim.new(0, 6), PaddingBottom = UDim.new(0, 6),
    PaddingLeft = UDim.new(0, 5), PaddingRight = UDim.new(0, 5),
}, menu)

local order, updaters = 0, {}
local function addHeader(text)
    order = order + 1
    local h = new("TextLabel", {
        Size = UDim2.new(1, -8, 0, 18), LayoutOrder = order, BackgroundTransparency = 1, Text = GT(text),
        TextColor3 = GRAY, Font = Enum.Font.GothamBold, TextSize = 11, TextXAlignment = Enum.TextXAlignment.Left,
    }, menu)
    langRefresh[#langRefresh + 1] = function()
        h.Text = GT(text)
    end
end

local function show(key, v)
    if v == true then
        return T("v_on")
    elseif v == false then
        return T("v_off")
    elseif key == "targetSeeds" and v == 0 then
        return "auto"
    end
    return tostring(v)
end

-- a row cycles through its options on click; unset rows show the MEDIUM value
local function addRow(text, key, opts)
    order = order + 1
    local b = button(menu, {
        Size = UDim2.new(1, -8, 0, 24), LayoutOrder = order, BackgroundColor3 = BTN, TextSize = 12, Font = Enum.Font.Gotham,
    })
    local function get()
        local v = AF[key]
        if v == nil then
            v = (key == "seed" or key == "rate") and "auto" or MERGED.medium[key]
        end
        return v
    end
    local function upd()
        b.Text = GT(text) .. ": " .. show(key, get())
    end
    b.Activated:Connect(function()
        AF[key] = opts[(table.find(opts, get()) or 0) % #opts + 1]
        if key == "rate" then
            resetRate()
        end
        saveSettings()
        upd()
    end)
    upd()
    updaters[#updaters + 1] = upd
    langRefresh[#langRefresh + 1] = upd
end

local seedOpts = { "auto" }
for _, n in ipairs(cropNames) do
    seedOpts[#seedOpts + 1] = n
end
local BOOL = { true, false }
local MENU = {
    { "CROP" },
    { "seed", "seed", seedOpts },
    { "seeds in stock", "targetSeeds", { 0, 10, 24, 48, 72, 100, 200 } },
    { "buy chunk max", "buyChunkMax", { 25, 50, 100, 200, 500 } },
    { "coin reserve", "coinReserve", { 0, 100, 500, 2000, 10000 } },
    { "SPEED" },
    { "rate /s", "rate", { "auto", 4, 8, 12, 16, 24, 32, 40, 60, 80 } },
    { "auto max rate", "maxRate", { 24, 32, 40, 48, 60, 80 } },
    { "burst", "burst", { 1, 2, 3, 5, 8 } },
    { "scan interval", "tick", { 0.05, 0.1, 0.25, 0.5, 1 } },
    { "adaptive rate", "adapt", BOOL },
    { "ACTIONS" },
    { "plant", "doPlant", BOOL },
    { "water", "doWater", BOOL },
    { "harvest", "doHarvest", BOOL },
    { "sell", "doSell", BOOL },
    { "SELLING" },
    { "landing wait (s)", "landWait", { 0.5, 1, 2, 3 } },
    { "sell every (s)", "sellEvery", { 0, 15, 30, 60 } },
    { "HUMAN" },
    { "timing jitter", "jitter", { 0, 0.2, 0.45 } },
    { "random pauses", "humanPause", { 0, 0.02, 0.04, 0.1 } },
    { "break every (s)", "breakEvery", { 0, 60, 150, 300 } },
    { "break length (s)", "breakLen", { 2, 5, 10 } },
    { "nearest soil first", "sortByDistance", BOOL },
    { "TIMING" },
    { "plant cooldown", "coolPlant", { 0.5, 1.5, 3 } },
    { "water cooldown", "coolWater", { 1, 3, 6 } },
    { "harvest cooldown", "coolHarvest", { 0.5, 1.5, 3 } },
    { "fails before ban", "failLimit", { 2, 3, 5, 8 } },
    { "ban time", "banTime", { 15, 60, 180 } },
    { "judge delay (grace)", "grace", { 0.4, 0.8, 1.5, 3 } },
    { "idle interval", "idleTick", { 0.25, 0.5, 1, 2 } },
    { "BUYING" },
    { "buy attempts", "buyTries", { 4, 8, 12, 20 } },
    { "buy wait", "buyWait", { 0.6, 1.2, 2, 3 } },
    { "pause after refusal", "noBuyPause", { 2, 5, 15, 30 } },
    { "chunk memory", "chunkMemory", { 30, 120, 300 } },
    { "OTHER" },
    { "console log", "trace", BOOL },
}
for _, r in ipairs(MENU) do
    if #r == 1 then
        addHeader(r[1])
    else
        addRow(r[1], r[2], r[3])
    end
end

local function refresh()
    for m, b in pairs(modeBtns) do
        b.BackgroundColor3 = (m == AF.mode) and (m == "fastest" and HOT or ACTIVE) or BTN
    end
    menu.Visible = AF.mode == "custom"
    toggle.BackgroundColor3 = AF.enabled and GREEN or RED
    if not AF.enabled then
        toggle.Text = T("g_off")
    end
    for _, f in ipairs(updaters) do
        f()
    end
end

local langOff = Core.onLang(function()
    for _, f in ipairs(langRefresh) do
        pcall(f)
    end
    pcall(refresh)
end)

-- session summary: what the farm did since it was switched ON
local SES = { h0 = 0, p0 = 0 }
local function sessionSummary(tag)
    local mins = S.active / 60
    local gain = coins() - S.coins0
    log("summary", tag, "min", string.format("%.1f", mins), "coins", math.floor(gain),
        "per min", mins > 0.1 and math.floor(gain / mins) or 0,
        "harvested", S.harvested - SES.h0, "planted", S.plantedTotal - SES.p0,
        "retries", S.actionsTotal > 0 and string.format("%.1f%%", S.retriesTotal / S.actionsTotal * 100) or "0%")
end

local function statusLine()
    local d = getPlayerData()
    local sid = seedId()
    local c = sid and FarmConfig.Crops[sid]
    local perMin = S.active > 5 and (coins() - S.coins0) / S.active * 60 or 0
    local effPct = S.actionsTotal > 0 and (1 - S.retriesTotal / S.actionsTotal) * 100 or 100
    return string.format(
        "%s | %d/%d/%d | %d/s\nseeds %d | coins %d\n%+d/min | eff %d%%%s",
        c and c.displayName or tostring(sid),
        S.planted,
        S.empty,
        S.ripe,
        math.floor(curRate()),
        seedStock(d),
        math.floor(d and d.Coins or 0),
        math.floor(perMin),
        math.floor(effPct),
        AF.mode == "auto" and (" | " .. ({ watch = "watch", probe = "PROBE", verify = "check", confirmed = "k ok", open = "open" })[M.state]) or ""
    )
end

local function onClick(btn, fn)
    conns[#conns + 1] = btn.Activated:Connect(function()
        fn()
        refresh()
    end)
end
onClick(toggle, function()
    Core.guard.cancel("garden")
    AF.enabled = not AF.enabled
    if AF.enabled then
        S.coins0, S.active, S.actionsTotal, S.retriesTotal = coins(), 0, 0, 0
        SES.h0, SES.p0 = S.harvested, S.plantedTotal
        resetRate()
    else
        pcall(sessionSummary, "stop")
    end
    toggle.Text = AF.enabled and (T("g_on") .. '\n<font size="11">' .. statusLine() .. "</font>") or T("g_off")
end)
for m, b in pairs(modeBtns) do
    onClick(b, function()
        setMode(m)
    end)
end

unload = function()
    if AF.enabled then
        pcall(sessionSummary, "unload")
    end
    pcall(saveLearn, true)
    AF.enabled = false
    for _, t in ipairs(threads) do
        pcall(task.cancel, t)
    end
    for _, c in ipairs(conns) do
        pcall(function()
            c:Disconnect()
        end)
    end
    pcall(function()
        gui:Destroy()
    end)
    pcall(langOff)
    pcall(saveSettings)
    pcall(Core.guard.unregister, "garden")
    G.AFARM, G._AFARM_THREADS, G._AFARM_CONNS = nil, nil, nil
    log("unloaded")
    Core.toast(T("g_toast_unload"), "info", 2)
    Core.afterFarm(MYSCOPE) -- nothing else needs the shared module once the only farm is gone
end
AF.unload = unload
closeBtn.Activated:Connect(unload)
refresh()

-- hub guard: autopause while dead, restart after death, anti-freeze watchdog
Core.guard.register("garden", {
    isEnabled = function()
        return AF.enabled
    end,
    setEnabled = function(v, reason)
        AF.enabled = v
        pcall(refresh)
        if not v and reason == "autopause" then
            toggle.Text = T("g_pause")
        end
    end,
    progress = function()
        return S.harvested + S.plantedTotal
    end,
    idleOk = function() -- something is still growing: waiting, not stuck
        return RT.nextRipe ~= nil
    end,
    stallSec = 240,
    restart = function(reason)
        log("guard restart:", reason)
        resetRate()
    end,
})

-- ========== threads ==========
-- status line (2 Hz); when the farm is off it refreshes the soil counters itself
threads[#threads + 1] = task.spawn(function()
    local statT, statC = clock(), coins()
    local sumT, wdProg, wdT, wdWarned = clock(), -1, clock(), false
    local actT = clock()
    while gui.Parent do
        if not AF.enabled then
            pcall(scan)
            statT, statC = clock(), coins()
            sumT, wdProg, wdT, wdWarned = clock(), -1, clock(), false
            actT = clock()
        else
            -- watchdog: no plant and no harvest for a long time = the farm is stuck
            local now = clock()
            local prog = S.harvested + S.plantedTotal
            if prog ~= wdProg then
                wdProg, wdT, wdWarned = prog, now, false
            else
                if RT.nextRipe ~= nil then
                    wdT = now -- something is still growing: not stuck
                end
                local idle = now - wdT
                if not wdWarned and AF.stallWarn > 0 and idle >= AF.stallWarn then
                    wdWarned = true
                    warn("no plant or harvest for " .. math.floor(idle) .. " s: the farm looks stuck")
                end
                if AF.stallStop > 0 and idle >= AF.stallStop then
                    warn("stuck for " .. math.floor(idle) .. " s: switching the farm OFF")
                    pcall(sessionSummary, "watchdog")
                    AF.enabled = false
                    toggle.Text = T("g_off")
                    wdT = now
                    pcall(refresh)
                end
            end
            if AF.enabled and now - sumT >= 600 then
                sumT = now
                pcall(sessionSummary, "10min")
            end
            if clock() - statT >= 30 then -- net income of the last 30 s (sales minus seeds)
                local c = coins()
                log("stat", "coins/min", math.floor((c - statC) / (clock() - statT) * 60), "soils", S.planted .. "/" .. S.soils,
                    "rate", math.floor(curRate()), "retries", S.actionsTotal > 0 and math.floor(S.retriesTotal / S.actionsTotal * 100) .. "%" or "0%", "model", M.state,
                    "lag ripe", D.rn > 0 and string.format("%.1fs", D.rs / D.rn) or "-",
                    "empty", D.en > 0 and string.format("%.1fs", D.es / D.en) or "-",
                    "shop", string.format("%.0fs", D.shop),
                    "cycle", D.cn > 0 and string.format("%.2fs", D.cs / D.cn) or "-",
                    "grow", D.cn > 0 and string.format("%.2fs", D.gs / D.cn) or "-",
                    "eff", D.cn > 0 and D.cs > 0 and string.format("%.1f%%", D.gs / D.cs * 100) or "-")
                D.rn, D.rs, D.en, D.es, D.shop, D.cs, D.cn, D.gs = 0, 0, 0, 0, 0, 0, 0, 0
                statT, statC = clock(), c
            end
            S.active = S.active + (clock() - actT)
            actT = clock()
            toggle.Text = T("g_on") .. '\n<font size="11">' .. statusLine() .. "</font>"
        end
        task.wait(0.5)
    end
end)

-- farm: an error in a pass never kills the loop. After a pass that did work the next one starts at once;
-- an idle loop sleeps until the next soil ripens (but never longer than `tick`).
threads[#threads + 1] = task.spawn(function()
    local lastErr, nextBreak = 0, 0
    while true do
        if AF.enabled then
            local ok, res = pcall(farmPass)
            if not ok and clock() - lastErr > 5 then
                lastErr = clock()
                warn("error: " .. tostring(res))
            end
            local acted = ok and res or 0

            local be = eff("breakEvery")
            if be > 0 and AF.enabled then
                local t = clock()
                if nextBreak == 0 then
                    nextBreak = t + be * (0.7 + rand:NextNumber() * 0.6)
                elseif t >= nextBreak then
                    nextBreak = t + be * (0.7 + rand:NextNumber() * 0.6)
                    task.wait(eff("breakLen") * (0.6 + rand:NextNumber() * 0.8))
                end
            end

            local wake = eff("tick")
            if acted > 0 then
                wake = 0.03
            elseif RT.nextRipe then
                wake = math.clamp(RT.nextRipe + 0.03, 0.03, wake)
            end
            local j = eff("jitter")
            if j > 0 then
                wake = wake * (1 + rand:NextNumber() * j)
            end
            task.wait(wake)
        else
            nextBreak = 0
            task.wait(eff("idleTick"))
        end
    end
end)

AF.model = M
AF.crops = function() -- the crop table of the game config, cheapest sale first
    local list = {}
    for name, c in pairs(FarmConfig.Crops) do
        if type(c) == "table" then
            list[#list + 1] = { name = name, c = c }
        end
    end
    table.sort(list, function(a, b)
        local pa, pb = a.c.cropPrice or 0, b.c.cropPrice or 0
        if pa ~= pb then
            return pa < pb
        end
        return a.name < b.name
    end)
    for _, x in ipairs(list) do
        print("cfg", x.name, "seed", x.c.seedPrice, "sale", x.c.cropPrice, "time", x.c.harvestTimeSec, "lvl", x.c.requiredLevel or 0)
    end
end
AF.forget = function() -- clear everything learned (model, growth times) and the saved file
    resetModel()
    RT.grow = { {}, {} }
    saveLearn(true)
    print("learned data cleared")
end
AF.relearn = function() -- forget what was learned: the next waves probe again
    resetModel()
    print("model reset: probing again")
end

-- diagnostic: attributes of a soil and of its parents
AF.dump = function()
    print("model:", M.state, "k", M.k, "yield", M.y, "run", RT.runs)
    local soil = next(soils)
    if not soil then
        print("no FarmSoil found")
        return
    end
    print("soils:", S.soils)
    local o = soil
    while o and o ~= game do
        print(o:GetFullName())
        for k, v in pairs(o:GetAttributes()) do
            print("   ", k, "=", v)
        end
        o = o.Parent
    end
end

-- startup check: the remotes and the crop config the farm depends on (a game update may change them)
do
    local missing = {}
    for _, n in ipairs({ "FarmShopRequest", "SoilEvent" }) do
        local ok, r = pcall(function()
            return Net[n]
        end)
        if not ok or r == nil then
            missing[#missing + 1] = n
        end
    end
    if type(FarmConfig.Crops) ~= "table" then
        missing[#missing + 1] = "FarmConfig.Crops"
    end
    if #missing > 0 then
        warn("startup check: missing " .. table.concat(missing, ", ") .. " (the game may have been updated)")
    end
end

if AF.trace then
    pcall(AF.crops)
end
print("loaded. mode=" .. AF.mode)
