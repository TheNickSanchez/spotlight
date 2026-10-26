--[[--
Pace learning, pacing and auto-adjust for Spotlight.

Pure Lua, no KOReader dependencies, so it runs under plain LuaJIT on a desktop.

Every tunable number lives in Pace.config below.

  M2  judging and keeping sentence timings from Manual reading.
  M3  the pacer: how long each sentence stays lit in Auto mode, pausing
      and resuming it.
  M4  the pace model (fit from your timings), the learning phase, and
      auto-adjust.

A pace is a table { wpm, pause_ms }: a sentence stays lit for
pause_ms + words × 60000 / wpm. "wpm" is the speed shown everywhere (popup,
indicator, speed panel); the short fixed pause per sentence comes on top.

A timing sample is a table:
    words       words in the sentence
    ms          how long the sentence was lit before moving on
    reread      the sentence had been lit before (you went back to it)
    after_turn  a page turn happened while it was lit, or right before
    at          when it was taken (os.time())

@module spotlight.pace
--]]

local Pace = {}

Pace.config = {
    -- Reading text around a page (main.lua). A sentence that started on the
    -- previous page is found by walking back at most this many words, and a
    -- sentence that runs onto the next page by walking at most this many
    -- words past the page end.
    max_words_back = 200,
    max_words_past_page = 200,

    -- Taps: the left part of the screen that means "back", as a share of
    -- the screen width.
    back_zone_ratio = 0.25,

    -- A timing counts for learning only if it took between these per word,
    -- and under max_sentence_ms in total.
    min_ms_per_word = 120,
    max_ms_per_word = 1500,
    max_sentence_ms = 60000,

    -- How many valid timings to keep (oldest dropped first).
    max_samples = 400,

    -- Auto mode speed, in words per minute: the starting value, the range
    -- the speed panel allows, and its step (also the Faster/Slower step).
    default_wpm = 200,
    min_wpm = 80,
    max_wpm = 400,
    wpm_step = 5,

    -- Before your pace is learned: the pause per sentence.
    sentence_pause_ms = 400,

    -- Learning: Auto is ready after at least this many valid timings and
    -- this much reading time in them.
    learn_min_sentences = 40,
    learn_min_ms = 3 * 60 * 1000,

    -- The pace model: time = pause + words × time per word, fit by least
    -- squares on your most recent valid timings. The pause is kept within
    -- pause_min_ms..pause_max_ms. When the fit is unstable (too few
    -- timings, sentences all about the same length, or an implausible
    -- result), the fallback is your median words per minute with a
    -- fallback_pause_ms pause.
    fit_max_samples = 150,
    fit_min_samples = 10,
    fit_min_word_sd = 2,       -- sentence lengths must vary at least this much (words)
    fit_max_abs_pause_ms = 4000, -- a fitted pause beyond ±this is not believable
    pause_min_ms = 200,
    pause_max_ms = 1500,
    fallback_pause_ms = 400,

    -- Auto-adjust: look at windows of this many Auto sentences. Holds and
    -- backs are stops; skip-aheads mean too slow. At most one change per
    -- window.
    adjust_window = 15,
    adjust_stops_to_slow = 3,  -- this many stops or more: slow down
    adjust_slower = 0.95,      -- by 5 %
    adjust_faster = 1.05,      -- no stops, some skips: 5 % faster
    adjust_quiet = 1.02,       -- no stops, no skips, two windows in a row: 2 % faster
    adjust_quiet_windows = 2,

    -- Extra time after letting go of a hold, after an automatic page turn
    -- (for the first sentence on the new page), and after a menu or dialog
    -- that covered the page closes.
    hold_resume_grace_ms = 500,
    page_turn_grace_ms = 800,
    dialog_resume_grace_ms = 1000,

    -- If the light moved on less than this long before a finger landed, the
    -- finger was aimed at the sentence before: go back to it.
    touch_race_ms = 250,

    -- While a menu or dialog covers the page, check again this often.
    blocked_poll_s = 1,

    -- Kindle only: while Auto runs without any touch, tell the Kindle's
    -- power manager this often that the reader is in use (its own sleep
    -- timer is 10 minutes).
    keep_awake_every_s = 300,

    -- Session stats (stats.lua): a gap longer than this between two moves
    -- of the light is not counted as reading time; after the Kindle sleeps
    -- longer than session_break_s with the book open, a new session starts.
    active_gap_ms = 90 * 1000,
    session_break_s = 30 * 60,
}

local cfg = Pace.config

--- Does a timing count for learning? Returns ok, reason.
function Pace.isValidSample(sample)
    if sample.reread then return false, "reread" end
    if sample.after_turn then return false, "after_turn" end
    if not sample.words or sample.words < 1 then return false, "no_words" end
    if sample.ms >= cfg.max_sentence_ms then return false, "too_long" end
    local per_word = sample.ms / sample.words
    if per_word < cfg.min_ms_per_word then return false, "too_fast" end
    if per_word > cfg.max_ms_per_word then return false, "too_slow" end
    return true
end

--- Add a sample to a list of valid samples, keeping at most max_samples.
-- Returns true if it was kept.
function Pace.addSample(samples, sample)
    if not Pace.isValidSample(sample) then return false end
    samples[#samples + 1] = {
        words = sample.words,
        ms = math.floor(sample.ms + 0.5),
        at = sample.at,
    }
    while #samples > cfg.max_samples do
        table.remove(samples, 1)
    end
    return true
end

--- Keep a speed in range, rounded to `step` (whole words a minute if nil).
function Pace.clampWpm(wpm, step)
    step = step or 1
    wpm = math.floor(wpm / step + 0.5) * step
    return math.max(cfg.min_wpm, math.min(cfg.max_wpm, wpm))
end

--- The pace before anything is learned.
function Pace.defaultPace(wpm)
    return { wpm = wpm or cfg.default_wpm, pause_ms = cfg.sentence_pause_ms }
end

--[[--
How long a sentence (or the part of it on one page) stays lit in Auto mode.

@param words number of words to read
@param pace { wpm, pause_ms }
@param with_pause include the per-sentence pause (false for the second part
       of a sentence split by a page break: the pause was in the first)
@return milliseconds
]]
function Pace.sentenceMs(words, pace, with_pause)
    local ms = words * 60000 / pace.wpm
    if with_pause ~= false then ms = ms + pace.pause_ms end
    return ms
end

---------------------------------------------------------------------------
-- The pace model
---------------------------------------------------------------------------

local function median(list)
    local t = {}
    for i, v in ipairs(list) do t[i] = v end
    table.sort(t)
    local n = #t
    if n == 0 then return nil end
    if n % 2 == 1 then return t[(n + 1) / 2] end
    return (t[n / 2] + t[n / 2 + 1]) / 2
end

local function fallbackModel(samples)
    local wpms = {}
    for i, s in ipairs(samples) do wpms[i] = s.words * 60000 / s.ms end
    local wpm = median(wpms)
    if not wpm then return nil end
    return { wpm = wpm, pause_ms = cfg.fallback_pause_ms, fallback = true, n = #samples }
end

--[[--
Fit the pace model to valid timings: time = pause + words × time per word,
by least squares on the most recent `fit_max_samples`.

@return { wpm, pause_ms, n, fallback } or nil when there are no samples.
`fallback` is true when the fit was unstable and the median speed was used.
]]
function Pace.fit(all_samples)
    local first = math.max(1, #all_samples - cfg.fit_max_samples + 1)
    local samples = {}
    for i = first, #all_samples do samples[#samples + 1] = all_samples[i] end
    local n = #samples
    if n == 0 then return nil end
    if n < cfg.fit_min_samples then return fallbackModel(samples) end

    local sx, sy = 0, 0
    for _i, s in ipairs(samples) do sx, sy = sx + s.words, sy + s.ms end
    local mx, my = sx / n, sy / n
    local sxx, sxy = 0, 0
    for _i, s in ipairs(samples) do
        sxx = sxx + (s.words - mx) ^ 2
        sxy = sxy + (s.words - mx) * (s.ms - my)
    end
    if math.sqrt(sxx / n) < cfg.fit_min_word_sd then
        return fallbackModel(samples) -- sentences too alike in length to separate pause from speed
    end
    local per_word = sxy / sxx
    local pause = my - per_word * mx
    if math.abs(pause) > cfg.fit_max_abs_pause_ms then
        return fallbackModel(samples)
    end
    if pause < cfg.pause_min_ms or pause > cfg.pause_max_ms then
        -- Keep the pause in range and refit the time per word around it.
        pause = math.max(cfg.pause_min_ms, math.min(cfg.pause_max_ms, pause))
        local num, den = 0, 0
        for _i, s in ipairs(samples) do
            num = num + s.words * (s.ms - pause)
            den = den + s.words * s.words
        end
        per_word = num / den
    end
    if per_word < cfg.min_ms_per_word or per_word > cfg.max_ms_per_word then
        return fallbackModel(samples)
    end
    return { wpm = 60000 / per_word, pause_ms = pause, n = n, fallback = false }
end

--- Learning progress: how many valid timings, how much reading time, ready?
function Pace.learningProgress(samples)
    local ms = 0
    for _i, s in ipairs(samples) do ms = ms + s.ms end
    local ready = #samples >= cfg.learn_min_sentences and ms >= cfg.learn_min_ms
    return #samples, ms, ready
end

---------------------------------------------------------------------------
-- Auto-adjust
---------------------------------------------------------------------------

--[[--
Watches Auto sentences in windows of `adjust_window`. Tell it what happens:

    adjuster:note("sentence")   the light moved on by itself
    adjuster:note("skip")       a skip-ahead (counts as a sentence too)
    adjuster:note("hold")       a hold (a stop)
    adjuster:note("back")       a back (a stop)

At the end of each window `note` returns the change to apply (a factor for
the speed, e.g. 0.95) and why, or nil when the speed should stay.
]]
local Adjuster = {}
Adjuster.__index = Adjuster

function Pace.newAdjuster()
    return setmetatable({ count = 0, stops = 0, skips = 0, quiet = 0 }, Adjuster)
end

function Adjuster:note(kind)
    if kind == "hold" or kind == "back" then
        self.stops = self.stops + 1
        return nil
    end
    if kind == "skip" then self.skips = self.skips + 1 end
    if kind == "sentence" or kind == "skip" then
        self.count = self.count + 1
        if self.count >= cfg.adjust_window then
            return self:closeWindow()
        end
    end
    return nil
end

function Adjuster:closeWindow()
    local stops, skips = self.stops, self.skips
    self.count, self.stops, self.skips = 0, 0, 0
    if stops >= cfg.adjust_stops_to_slow then
        self.quiet = 0
        return cfg.adjust_slower, "stops"
    end
    if stops == 0 and skips > 0 then
        self.quiet = 0
        return cfg.adjust_faster, "skips"
    end
    if stops == 0 and skips == 0 then
        self.quiet = self.quiet + 1
        if self.quiet >= cfg.adjust_quiet_windows then
            self.quiet = 0
            return cfg.adjust_quiet, "quiet"
        end
        return nil
    end
    self.quiet = 0 -- a few stops: about right
    return nil
end

--- Apply an auto-adjust factor: at least one word a minute, kept in range.
function Pace.adjustedWpm(wpm, factor)
    local new = wpm * factor
    if factor > 1 then new = math.max(new, wpm + 1) else new = math.min(new, wpm - 1) end
    return Pace.clampWpm(new)
end

--[[--
The pacer's clock for the lit sentence. Times are in milliseconds, from any
clock the caller likes (main.lua uses KOReader's monotonic clock).

    states: "idle", "running" (counting down to `deadline`), "paused"
            (holding `remaining`)
]]
local Pacer = {}
Pacer.__index = Pacer

function Pace.newPacer()
    return setmetatable({ state = "idle" }, Pacer)
end

--- Start the countdown for a newly lit sentence. Returns ms until it is due.
function Pacer:start(now, ms)
    self.state = "running"
    self.deadline = now + ms
    self.remaining = nil
    return ms
end

--- Freeze the countdown (finger down, sleep, a dialog...).
function Pacer:pause(now)
    if self.state == "running" then
        self.remaining = math.max(0, self.deadline - now)
        self.state = "paused"
    end
end

--- Continue with the time that was left, plus `grace`. Returns ms until due.
function Pacer:resume(now, grace)
    if self.state ~= "paused" then return nil end
    self.state = "running"
    self.deadline = now + self.remaining + (grace or 0)
    self.remaining = nil
    return self.deadline - now
end

function Pacer:stop()
    self.state = "idle"
    self.deadline, self.remaining = nil, nil
end

function Pacer:isRunning() return self.state == "running" end
function Pacer:isPaused() return self.state == "paused" end

--- ms until the lit sentence is due (0 when due), nil when not running.
function Pacer:untilDue(now)
    if self.state ~= "running" then return nil end
    return math.max(0, self.deadline - now)
end

--- Speed changed from old_wpm to new_wpm: stretch what is left of the
-- current sentence accordingly, so the change is felt at once.
function Pacer:rescale(now, old_wpm, new_wpm)
    local factor = old_wpm / new_wpm
    if self.state == "running" then
        self.deadline = now + (self.deadline - now) * factor
    elseif self.state == "paused" then
        self.remaining = self.remaining * factor
    end
end

return Pace
