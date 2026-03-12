-- RAM OP-Z
-- OP-Z-mapped generative sequencer for norns
-- K2 start/stop | K3 regen track
-- E2 select track | E3 density
-- PARAMS: choose your WIDI midi port, root, scale, tempo

local musicutil = require "musicutil"

local function clamp(x,a,b) return math.max(a, math.min(b, x)) end

local m = nil
local selected_track = 1
local sequencer_clock = nil
local screen_dirty = true

local state = {
  running = false,
  step = 1,
  steps = 16,
  root = 48, -- C3
  scale = 1,
  bpm = 118,
}

local midi_device_names = {}
local scale_names = {}
local tracks = {}

local function build_midi_device_names()
  midi_device_names = {}
  for i = 1, 4 do
    local dev = midi.vports[i]
    if dev and dev.name then
      midi_device_names[i] = dev.name
    else
      midi_device_names[i] = "port " .. i
    end
  end
end

local function build_scale_names()
  scale_names = {}
  for i, s in ipairs(musicutil.SCALES) do
    scale_names[i] = s.name
  end
end

local function connect_midi(port)
  m = midi.connect(port)
end

local function note_on(ch, note, vel)
  if m then m:note_on(note, vel, ch) end
end

local function note_off(ch, note)
  if m then m:note_off(note, 0, ch) end
end

local function cc(ch, num, val)
  if m then m:cc(num, val, ch) end
end

local function all_notes_off()
  if not m then return end
  for ch = 1, 16 do
    m:cc(123, 0, ch) -- all notes off
  end
end

local function euclid(steps, pulses, rot)
  local pattern = {}
  for i = 1, steps do pattern[i] = false end
  if pulses <= 0 then return pattern end
  if pulses >= steps then
    for i = 1, steps do pattern[i] = true end
    return pattern
  end
  local bucket = 0
  for i = 1, steps do
    bucket = bucket + pulses
    if bucket >= steps then
      bucket = bucket - steps
      pattern[i] = true
    end
  end
  if rot and rot ~= 0 then
    local rotated = {}
    for i = 1, steps do
      local j = ((i - 1 - rot) % steps) + 1
      rotated[i] = pattern[j]
    end
    return rotated
  end
  return pattern
end

local function make_track(id, name, kind, channel)
  return {
    id = id,
    name = name,
    kind = kind,
    ch = channel,
    enabled = true,
    density = 0.5,
    vel = 95,
    pattern = {},
    notes = {},
    lane_phase = math.random() * 6.28318,
    cutoff_depth = 0.0,
    send_depth = 0.0,
    oct = 0,
  }
end

local function init_tracks()
  tracks = {
    make_track(1, "kick",   "drum", 1),
    make_track(2, "snare",  "drum", 2),
    make_track(3, "hats",   "drum", 3),
    make_track(4, "perc",   "drum", 4),
    make_track(5, "bass",   "bass", 5),
    make_track(6, "chord",  "chord", 6),
    make_track(7, "arp",    "arp",  7),
    make_track(8, "lead",   "lead", 8),
  }

  for i = 9, 16 do
    local t = make_track(i, "ctl"..i, "off", i)
    t.enabled = false
    tracks[i] = t
  end

  tracks[1].density = 0.50
  tracks[2].density = 0.28
  tracks[3].density = 0.72
  tracks[4].density = 0.35
  tracks[5].density = 0.45
  tracks[6].density = 0.30
  tracks[7].density = 0.50
  tracks[8].density = 0.32

  tracks[1].vel = 110
  tracks[2].vel = 95
  tracks[3].vel = 78
  tracks[4].vel = 82
  tracks[5].vel = 98
  tracks[6].vel = 88
  tracks[7].vel = 82
  tracks[8].vel = 94

  tracks[5].oct = -12
  tracks[6].oct = 0
  tracks[7].oct = 12
  tracks[8].oct = 12

  tracks[5].cutoff_depth = 0.15
  tracks[6].cutoff_depth = 0.25
  tracks[7].cutoff_depth = 0.30
  tracks[8].cutoff_depth = 0.22

  tracks[6].send_depth = 0.15
  tracks[7].send_depth = 0.12
  tracks[8].send_depth = 0.18
end

local function set_drum_pattern(t)
  local p = {}
  if t.id == 1 then
    p = euclid(state.steps, math.floor(2 + t.density * 4), 0)
    p[1] = true
    p[9] = true
  elseif t.id == 2 then
    for i = 1, state.steps do p[i] = false end
    p[5] = true
    p[13] = true
    if t.density > 0.35 and math.random() < 0.5 then p[12] = true end
    if t.density > 0.50 and math.random() < 0.4 then p[16] = true end
  elseif t.id == 3 then
    p = euclid(state.steps, math.floor(6 + t.density * 8), 1)
    if math.random() < 0.5 then p[3] = true end
    if math.random() < 0.5 then p[11] = true end
  elseif t.id == 4 then
    p = euclid(state.steps, math.floor(2 + t.density * 6), math.random(0, 5))
  end

  for i = 1, state.steps do
    t.pattern[i] = p[i] or false
    t.notes[i] = 60
  end
end

local function get_scale()
  return musicutil.generate_scale(state.root, musicutil.SCALES[state.scale].name, 4)
end

local function choose_from_scale(lo, hi)
  local scale = get_scale()
  local filtered = {}
  for _, note in ipairs(scale) do
    if note >= lo and note <= hi then
      table.insert(filtered, note)
    end
  end
  if #filtered == 0 then
    return state.root
  end
  return filtered[math.random(1, #filtered)]
end

local function set_bass_pattern(t)
  for i = 1, state.steps do
    local on = false
    if i == 1 or i == 9 then
      on = true
    elseif i == 7 or i == 11 or i == 15 then
      on = math.random() < (0.15 + t.density * 0.5)
    else
      on = math.random() < (0.05 + t.density * 0.25)
    end
    t.pattern[i] = on
    if on then
      local n = choose_from_scale(36, 55)
      if math.random() < 0.6 then n = n - 12 end
      t.notes[i] = clamp(n, 24, 60)
    else
      t.notes[i] = nil
    end
  end
end

local function set_chord_pattern(t)
  for i = 1, state.steps do
    t.pattern[i] = false
    t.notes[i] = nil
  end
  t.pattern[1] = true
  t.pattern[9] = (t.density > 0.45)
end

local function set_arp_pattern(t)
  for i = 1, state.steps do
    t.pattern[i] = math.random() < (0.15 + t.density * 0.7)
    if t.pattern[i] then
      t.notes[i] = choose_from_scale(60, 84)
    else
      t.notes[i] = nil
    end
  end
end

local function set_lead_pattern(t)
  for i = 1, state.steps do
    t.pattern[i] = false
    t.notes[i] = nil
  end
  local slots = {1, 4, 7, 9, 12, 15}
  for _, s in ipairs(slots) do
    if math.random() < (0.15 + t.density * 0.75) then
      t.pattern[s] = true
      t.notes[s] = choose_from_scale(67, 91)
    end
  end
end

local function regen_track(t)
  if t.kind == "drum" then
    set_drum_pattern(t)
  elseif t.kind == "bass" then
    set_bass_pattern(t)
  elseif t.kind == "chord" then
    set_chord_pattern(t)
  elseif t.kind == "arp" then
    set_arp_pattern(t)
  elseif t.kind == "lead" then
    set_lead_pattern(t)
  else
    for i = 1, state.steps do
      t.pattern[i] = false
      t.notes[i] = nil
    end
  end
end

local function regen_all()
  for i = 1, 16 do regen_track(tracks[i]) end
end

local function play_chord(ch, root_note, vel)
  -- build chord from scale degrees (root, 3rd, 5th, optional 7th)
  local scale = get_scale()
  -- find root index in scale
  local root_idx = nil
  for i, n in ipairs(scale) do
    if n == root_note then root_idx = i; break end
  end
  local notes = {}
  if root_idx and root_idx + 4 <= #scale then
    table.insert(notes, scale[root_idx])       -- root
    table.insert(notes, scale[root_idx + 2])   -- 3rd degree
    table.insert(notes, scale[root_idx + 4])   -- 5th degree
    if root_idx + 6 <= #scale and math.random() < 0.4 then
      table.insert(notes, scale[root_idx + 6]) -- 7th degree
    end
  else
    -- fallback: just play the root
    notes = { root_note }
  end
  for _, n in ipairs(notes) do
    note_on(ch, clamp(n, 0, 127), vel)
  end
  clock.run(function()
    clock.sleep(0.45)
    for _, n in ipairs(notes) do
      note_off(ch, clamp(n, 0, 127))
    end
  end)
end

local function animate_track_cc(t)
  if not t.enabled or t.kind == "drum" or t.kind == "off" then return end
  t.lane_phase = t.lane_phase + 0.08

  local cutoff = 64 + math.floor(math.sin(t.lane_phase) * (t.cutoff_depth * 127))
  local send = 20 + math.floor((0.5 + 0.5 * math.sin(t.lane_phase * 0.6 + 0.8)) * (t.send_depth * 127))

  cutoff = clamp(cutoff, 0, 127)
  send = clamp(send, 0, 127)

  cc(t.ch, 3, cutoff)   -- OP-Z cutoff
  cc(t.ch, 13, send)    -- OP-Z fx1 send
end

local function play_step()
  for i = 1, 16 do
    local t = tracks[i]
    if t.enabled and t.pattern[state.step] then
      if t.kind == "drum" then
        note_on(t.ch, 60, t.vel)
        clock.run(function()
          clock.sleep(0.12)
          note_off(t.ch, 60)
        end)
      elseif t.kind == "bass" or t.kind == "arp" or t.kind == "lead" then
        local note = t.notes[state.step] or choose_from_scale(48, 84)
        note = clamp(note + t.oct, 0, 127)
        note_on(t.ch, note, t.vel)
        clock.run(function()
          clock.sleep(0.20)
          note_off(t.ch, note)
        end)
      elseif t.kind == "chord" then
        local root_note = choose_from_scale(52, 72)
        root_note = clamp(root_note + t.oct, 0, 127)
        play_chord(t.ch, root_note, t.vel)
      end
    end
    animate_track_cc(t)
  end

  state.step = state.step + 1
  if state.step > state.steps then state.step = 1 end
  screen_dirty = true
end

local function sequencer()
  while true do
    clock.sync(1/4)
    if state.running then play_step() end
    if screen_dirty then
      redraw()
      screen_dirty = false
    end
  end
end

function redraw()
  screen.clear()
  local t = tracks[selected_track]

  screen.level(15)
  screen.move(2, 10)
  screen.text("RAM OP-Z MAP")

  screen.level(10)
  screen.move(2, 21)
  screen.text("RUN " .. (state.running and "ON" or "OFF"))
  screen.move(72, 21)
  screen.text("STP " .. state.step)

  screen.move(2, 33)
  screen.text(string.format("T%02d %s CH%d", selected_track, t.name, t.ch))

  screen.move(2, 45)
  screen.text("ON " .. (t.enabled and "YES" or "NO"))
  screen.move(66, 45)
  screen.text(string.format("DEN %.2f", t.density))

  for i = 1, state.steps do
    local x = 4 + ((i - 1) * 7)
    local y = 55
    if i == state.step and state.running then
      screen.level(15)
    elseif t.pattern[i] then
      screen.level(8)
    else
      screen.level(2)
    end
    screen.rect(x, y, 4, 6)
    if t.pattern[i] then screen.fill() else screen.stroke() end
  end

  screen.update()
end

function enc(n, d)
  if n == 2 then
    selected_track = clamp(selected_track + d, 1, 16)
  elseif n == 3 then
    local t = tracks[selected_track]
    t.density = clamp(t.density + d / 100, 0, 1)
    regen_track(t)
  end
  screen_dirty = true
end

function key(n, z)
  if z == 0 then return end

  if n == 2 then
    state.running = not state.running
    if not state.running then all_notes_off() end
  elseif n == 3 then
    regen_track(tracks[selected_track])
  end
  screen_dirty = true
end

function init()
  math.randomseed(os.time())
  build_midi_device_names()
  build_scale_names()
  init_tracks()
  regen_all()

  params:add_group("ram_opz", 4)

  params:add_option("midi_out", "midi out", midi_device_names, 1)
  params:set_action("midi_out", function(v) connect_midi(v) end)

  params:add_number("root_note", "root note", 24, 84, state.root)
  params:set_action("root_note", function(v)
    state.root = v
    regen_all()
  end)

  params:add_option("scale_type", "scale", scale_names, state.scale)
  params:set_action("scale_type", function(v)
    state.scale = v
    regen_all()
  end)

  params:add_number("tempo", "tempo", 60, 180, state.bpm)
  params:set_action("tempo", function(v)
    state.bpm = v
    clock.set_tempo(v)
  end)

  params:bang()
  clock.set_tempo(state.bpm)
  sequencer_clock = clock.run(sequencer)
end

function cleanup()
  state.running = false
  all_notes_off()
end
