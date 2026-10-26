local Pace = require("pace")
local test, eq, ok = T.test, T.eq, T.ok

local function sample(words, ms, extra)
    local s = { words = words, ms = ms, at = 0 }
    for k, v in pairs(extra or {}) do s[k] = v end
    return s
end

test("a normal timing counts", function()
    ok(Pace.isValidSample(sample(10, 3000))) -- 300 ms per word, 200 wpm
end)

test("rereads and sentences right after a page turn do not count", function()
    eq(select(2, Pace.isValidSample(sample(10, 3000, { reread = true }))), "reread")
    eq(select(2, Pace.isValidSample(sample(10, 3000, { after_turn = true }))), "after_turn")
end)

test("per-word time must be between 120 and 1500 ms", function()
    ok(Pace.isValidSample(sample(10, 1200)))
    eq(select(2, Pace.isValidSample(sample(10, 1199))), "too_fast")
    ok(Pace.isValidSample(sample(10, 15000)))
    eq(select(2, Pace.isValidSample(sample(10, 15001))), "too_slow")
end)

test("a sentence must take under 60 seconds", function()
    eq(select(2, Pace.isValidSample(sample(50, 60000))), "too_long")
    ok(Pace.isValidSample(sample(50, 59999)))
end)

test("sentences without words do not count", function()
    eq(select(2, Pace.isValidSample(sample(0, 2000))), "no_words")
end)

test("addSample keeps valid samples and drops the oldest past the limit", function()
    local list = {}
    ok(Pace.addSample(list, sample(10, 3000)))
    ok(not Pace.addSample(list, sample(10, 100)))
    eq(#list, 1)
    local max = Pace.config.max_samples
    for i = 1, max + 5 do Pace.addSample(list, sample(10, 3000 + i)) end
    eq(#list, max)
    eq(list[#list].ms, 3000 + max + 5)
end)

-- Pacer (M3) ----------------------------------------------------------------

local cfg = Pace.config

test("speeds are kept in range, rounded to whole words or to a step", function()
    eq(Pace.clampWpm(203.4), 203)
    eq(Pace.clampWpm(203, 5), 205)
    eq(Pace.clampWpm(202, 5), 200)
    eq(Pace.clampWpm(20), cfg.min_wpm)
    eq(Pace.clampWpm(999), cfg.max_wpm)
end)

test("sentence time: the pace's pause plus the words at its speed", function()
    local pace = { wpm = 200, pause_ms = 500 }
    eq(Pace.sentenceMs(10, pace), 500 + 3000)
    eq(Pace.sentenceMs(10, pace, false), 3000) -- second half of a split sentence
    eq(Pace.defaultPace().pause_ms, cfg.sentence_pause_ms)
end)

test("a sentence comes due after its time", function()
    local p = Pace.newPacer()
    eq(p:start(1000, 3000), 3000)
    eq(p:untilDue(2000), 2000)
    eq(p:untilDue(5000), 0)
end)

test("hold: pause on finger down, continue with what was left plus the grace", function()
    local p = Pace.newPacer()
    p:start(0, 3000)
    p:pause(1000)                 -- finger down after 1 s: 2 s left
    ok(p:isPaused())
    eq(p:untilDue(9000), nil)     -- the clock is frozen while holding
    eq(p:resume(9000, cfg.hold_resume_grace_ms), 2000 + cfg.hold_resume_grace_ms)
    ok(p:isRunning())
end)

test("pausing twice or resuming when not paused changes nothing", function()
    local p = Pace.newPacer()
    p:start(0, 3000)
    p:pause(1000)
    p:pause(2000)
    eq(p:resume(3000, 0), 2000)
    eq(p:resume(3000, 0), nil)
end)

test("a speed change stretches the time left", function()
    local p = Pace.newPacer()
    p:start(0, 4000)
    p:rescale(1000, 200, 300)     -- 3 s left at 200 wpm -> 2 s at 300 wpm
    eq(p:untilDue(1000), 2000)
    p:pause(1000)
    p:rescale(1000, 300, 150)
    eq(p:resume(1000, 0), 4000)
end)

test("stop clears everything", function()
    local p = Pace.newPacer()
    p:start(0, 1000)
    p:stop()
    ok(not p:isRunning() and not p:isPaused())
    eq(p:untilDue(0), nil)
end)

-- Learning and the pace model (M4) ----------------------------------------------

-- A reader with a known pace taps through sentences of varied length.
-- Deterministic "noise" so the tests are repeatable.
local function reader(pause_ms, ms_per_word, opts)
    opts = opts or {}
    local seed = opts.seed or 7
    local function rand()
        seed = (seed * 1103515245 + 12345) % 2147483648
        return seed / 2147483648
    end
    local samples = {}
    for i = 1, opts.n or 60 do
        local words = opts.words or (4 + math.floor(rand() * 30)) -- 4..33 words
        local noise = 1 + (rand() - 0.5) * (opts.noise or 0.2)    -- ±10 %
        samples[i] = { words = words, ms = (pause_ms + words * ms_per_word) * noise, at = i }
    end
    return samples
end

test("fit: recovers the pause and the speed of a steady reader", function()
    local m = Pace.fit(reader(600, 300)) -- 600 ms pause, 200 wpm
    ok(not m.fallback)
    ok(math.abs(m.wpm - 200) < 12, "wpm " .. m.wpm)
    ok(math.abs(m.pause_ms - 600) < 250, "pause " .. m.pause_ms)
end)

test("fit: the pause is kept between 0.2 and 1.5 s", function()
    local m = Pace.fit(reader(0, 300, { noise = 0.02 }))
    eq(m.pause_ms, cfg.pause_min_ms)
    ok(math.abs(m.wpm - 200) < 15, "speed refit around the clamped pause: " .. m.wpm)
    m = Pace.fit(reader(2500, 300, { noise = 0.02 }))
    eq(m.pause_ms, cfg.pause_max_ms)
end)

test("fit: sentences all the same length fall back to the median speed", function()
    local m = Pace.fit(reader(400, 300, { words = 12, noise = 0.1 }))
    ok(m.fallback)
    eq(m.pause_ms, cfg.fallback_pause_ms)
    ok(math.abs(m.wpm - 12 * 60000 / (400 + 12 * 300)) < 10)
end)

test("fit: too few timings fall back too; none give nothing", function()
    ok(Pace.fit(reader(400, 300, { n = 5 })).fallback)
    eq(Pace.fit({}), nil)
end)

test("fit: uses the most recent timings, so the pace stays current", function()
    local old = reader(400, 400, { n = 200, seed = 1 })  -- used to read at 150 wpm
    local new = reader(400, 250, { n = 150, seed = 2 })  -- now at 240 wpm
    for _i, s in ipairs(new) do old[#old + 1] = s end
    local m = Pace.fit(old)
    ok(math.abs(m.wpm - 240) < 15, "wpm " .. m.wpm)
end)

test("learning: ready after 40 valid sentences and 3 minutes of reading", function()
    local samples = reader(400, 300, { n = 39, words = 20 })   -- ~6.4 s each
    local n, ms, ready = Pace.learningProgress(samples)
    eq(n, 39)
    ok(ms > cfg.learn_min_ms and not ready, "39 sentences are not enough")
    samples[#samples + 1] = { words = 20, ms = 6400 }
    ok(select(3, Pace.learningProgress(samples)))
    -- 40 short sentences in under 3 minutes are not enough either.
    local quick = reader(300, 200, { n = 45, words = 6 })      -- ~1.5 s each
    ok(not select(3, Pace.learningProgress(quick)))
end)

-- Auto-adjust: simulated Auto sessions ---------------------------------------

-- Play a session: "." the light moves on, "s" skip ahead, "h" hold, "b" back.
-- Returns the speed after each change.
local function play(script, wpm)
    local adj = Pace.newAdjuster()
    local changes = {}
    for c in script:gmatch(".") do
        local kind = ({ ["."] = "sentence", s = "skip", h = "hold", b = "back" })[c]
        local factor, why = adj:note(kind)
        if factor then
            wpm = Pace.adjustedWpm(wpm, factor)
            changes[#changes + 1] = why .. " " .. wpm
        end
    end
    return changes, wpm
end

test("3 or more stops in 15 sentences: 5 % slower", function()
    eq((play("..h....b......h...", 200)), { "stops 190" }) -- 15 sentences, 3 stops
end)

test("no stops and a skip-ahead: 5 % faster", function()
    eq((play("......s........", 200)), { "skips 210" })
end)

test("no stops and no skips for two windows in a row: 2 % faster", function()
    eq((play(string.rep(".", 15), 200)), {})
    eq((play(string.rep(".", 30), 200)), { "quiet 204" })
    eq((play(string.rep(".", 60), 200)), { "quiet 204", "quiet 208" })
end)

test("one or two stops: the speed stays, and the quiet streak starts over", function()
    eq((play("..h............" .. string.rep(".", 15), 200)), {})
end)

test("at most one change per window", function()
    -- Many stops and skips in one window: one change only.
    eq((play("hhhhbbss.......ss.....", 200)), { "stops 190" })
end)

test("speed stays between 80 and 400", function()
    local _c, wpm = play(string.rep("..h.h.h........", 40), 100)
    eq(wpm, cfg.min_wpm)
    _c, wpm = play(string.rep("s", 15 * 40), 390)
    eq(wpm, cfg.max_wpm)
end)

test("small speeds still change by at least one word a minute", function()
    eq(Pace.adjustedWpm(90, 1.02), 92)
    eq(Pace.adjustedWpm(81, 0.995), 80)
end)
