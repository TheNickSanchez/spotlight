--[[--
Session stats for Spotlight.

Pure Lua, no KOReader dependencies (main.lua reads and writes the JSON file).

A session is one stretch of reading in one book: from opening it to closing
it, or to a sleep longer than `session_break_s`. While it runs, main.lua
tells it what happens:

    session:activity(now_ms, mode)   the light moved (mode: "manual"/"auto")
    session:sentenceRead(words)      a sentence was read and left
    session:count("holds"|"backs"|"skip_aheads"|"auto_adjust_changes")

Reading time only counts gaps of up to `active_gap_ms` between two moves of
the light; longer gaps (you put the Kindle down) are left out.

session:record(...) turns it into a plain table with descriptive field names,
the format saved in spotlight_stats.json (see FIELDS below).

@module spotlight.stats
--]]

local Stats = {}

--- The saved session fields, in order, with what they mean.
Stats.FIELDS = {
    { "id", "unique id of the session" },
    { "date", "day the session started, YYYY-MM-DD (local time)" },
    { "started_at", "start, YYYY-MM-DDTHH:MM:SS (local time)" },
    { "ended_at", "end (last activity), same format" },
    { "book_title", "title of the book" },
    { "active_seconds", "reading time; gaps over 90 seconds are left out" },
    { "manual_seconds", "part of active_seconds in Manual mode" },
    { "auto_seconds", "part of active_seconds in Auto mode" },
    { "sentences", "sentences read" },
    { "words", "words in those sentences" },
    { "average_wpm", "words per minute of active time" },
    { "holds", "holds in Auto mode (pauses)" },
    { "backs", "times you went back a sentence" },
    { "skip_aheads", "skips ahead in Auto mode" },
    { "starting_pace_wpm", "Auto pace at the start" },
    { "ending_pace_wpm", "Auto pace at the end" },
    { "auto_adjust_changes", "speed changes made by auto-adjust" },
}

local Session = {}
Session.__index = Session

--[[--
Start a session.
@param o { book_title, started_at (os.time()), pace_wpm, cfg (Pace.config) }
]]
function Stats.newSession(o)
    return setmetatable({
        cfg = o.cfg,
        book_title = o.book_title or "",
        started_at = o.started_at,
        last_at = o.started_at,   -- wall clock of the last activity
        last_ms = nil,            -- monotonic clock of the last activity
        last_mode = nil,
        active_ms = 0, manual_ms = 0, auto_ms = 0,
        sentences = 0, words = 0,
        holds = 0, backs = 0, skip_aheads = 0, auto_adjust_changes = 0,
        starting_pace_wpm = o.pace_wpm,
        -- Unique even for two sessions started in the same second.
        id = os.date("%Y%m%d-%H%M%S", o.started_at) .. "-" .. string.format("%06x", math.random(0, 0xFFFFFF)),
    }, Session)
end

--- The light moved (or a sentence was read): count the time since the last
-- activity as reading, unless it was a long gap.
function Session:activity(now_ms, mode, wall)
    if self.last_ms then
        local d = now_ms - self.last_ms
        if d > 0 and d <= self.cfg.active_gap_ms then
            self.active_ms = self.active_ms + d
            if self.last_mode == "auto" then
                self.auto_ms = self.auto_ms + d
            else
                self.manual_ms = self.manual_ms + d
            end
        end
    end
    self.last_ms = now_ms
    self.last_mode = mode
    if wall then self.last_at = wall end
end

function Session:sentenceRead(words)
    self.sentences = self.sentences + 1
    self.words = self.words + (words or 0)
end

function Session:count(field)
    self[field] = self[field] + 1
end

--- How long ago (wall clock seconds) the last activity was.
function Session:idleSeconds(wall)
    return wall - self.last_at
end

local function round(x) return math.floor(x + 0.5) end

--- The session as saved: a plain table with the fields in Stats.FIELDS, or
-- nil when nothing was read.
function Session:record(ending_pace_wpm)
    if self.sentences == 0 then return nil end
    local active_s = round(self.active_ms / 1000)
    return {
        id = self.id,
        date = os.date("%Y-%m-%d", self.started_at),
        started_at = os.date("%Y-%m-%dT%H:%M:%S", self.started_at),
        ended_at = os.date("%Y-%m-%dT%H:%M:%S", self.last_at),
        book_title = self.book_title,
        active_seconds = active_s,
        manual_seconds = round(self.manual_ms / 1000),
        auto_seconds = round(self.auto_ms / 1000),
        sentences = self.sentences,
        words = self.words,
        average_wpm = active_s > 0 and round(self.words * 60 / active_s) or 0,
        holds = self.holds,
        backs = self.backs,
        skip_aheads = self.skip_aheads,
        starting_pace_wpm = self.starting_pace_wpm,
        ending_pace_wpm = ending_pace_wpm or self.starting_pace_wpm,
        auto_adjust_changes = self.auto_adjust_changes,
    }
end

--- Add a record to a list, or replace the one with the same id (a session
-- saved while still running is saved again when it ends).
function Stats.upsert(records, record)
    for i, r in ipairs(records) do
        if r.id == record.id then
            records[i] = record
            return
        end
    end
    records[#records + 1] = record
end

---------------------------------------------------------------------------
-- Summaries
---------------------------------------------------------------------------

--- "YYYY-MM-DD" -> a day number (consecutive days differ by 1).
function Stats.dayNumber(date)
    local y, m, d = date:match("^(%d+)-(%d+)-(%d+)")
    if not y then return nil end
    return math.floor(os.time{ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 12 } / 86400)
end

--[[--
Totals over the days first..last (day numbers, inclusive):
{ sessions, minutes, sentences, words, wpm, stops_per_100 }. `wpm` and
`stops_per_100` are nil when there is nothing to measure.
]]
function Stats.summarize(records, first, last)
    local t = { sessions = 0, seconds = 0, sentences = 0, words = 0, stops = 0 }
    for _i, r in ipairs(records) do
        local day = r.date and Stats.dayNumber(r.date)
        if day and day >= first and day <= last then
            t.sessions = t.sessions + 1
            t.seconds = t.seconds + (r.active_seconds or 0)
            t.sentences = t.sentences + (r.sentences or 0)
            t.words = t.words + (r.words or 0)
            t.stops = t.stops + (r.holds or 0) + (r.backs or 0)
        end
    end
    t.minutes = t.seconds / 60
    t.wpm = t.seconds > 0 and t.words * 60 / t.seconds or nil
    t.stops_per_100 = t.sentences > 0 and t.stops * 100 / t.sentences or nil
    return t
end

--- Today, the last 7 days and the last 30 days, each with the period
-- before it (yesterday, the 7 days before...) for the trend.
-- Returns a list of { key = "today"|"week"|"month", days, current, previous }.
function Stats.report(records, today)
    local t = Stats.dayNumber(today)
    local out = {}
    for _i, p in ipairs({ { "today", 1 }, { "week", 7 }, { "month", 30 } }) do
        local n = p[2]
        out[#out + 1] = {
            key = p[1],
            days = n,
            current = Stats.summarize(records, t - n + 1, t),
            previous = Stats.summarize(records, t - 2 * n + 1, t - n),
        }
    end
    return out
end

return Stats
