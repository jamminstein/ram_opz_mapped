-- RAM OP-Z
-- OP-Z-mapped generative sequencer for norns
-- K2 start/stop | K3 regen track
-- E2 select track | E3 density
-- PARAMS: choose your WIDI midi port, root, scale, tempo
--
-- v1.2: Redesigned screen with status strip, live zone with activity meters,
--       step component indicator, context bar, and transient parameter popup

engine.name = "PolyPerc"

local musicutil = require "musicutil"

local function clamp(x,a,b) return math.max(a, math.min(b, x)) end

local function midi_to_hz(note)
  return 440 * 2^((note - 69) / 12)
end

local m = nil
local selected_track = 1

-- OP-XY MIDI
local opxy_out = nil
local function opxy_note_on(note, vel) if opxy_out then opxy_out:note_on(note, vel, params:get("opxy_channel")) end end
local function opxy_note_off(note) if opxy_out then opxy_out:note_off(note, 0, params:get("opxy_channel")) end end
local sequencer_clock = nil
local screen_refresh_id = nil
local k2_hold_clock_id = nil
local screen_dirty = true
local pattern_locked = false     -- K2 long-hold to lock patterns
local k2_down_time = 0

local state = {
  running = false,
  step = 1,
  steps = 16,
  root = 48, -- C3
  scale = 1,
  bpm = 118,
  beat_phase = 0,
}

-- SPIRITS: named moods that shape the whole sequencer
local spirits = {
  {name="MIDNIGHT",   root=36, scale=7,  bpm=85,  dens={0.7,0.3,0.2,0.5, 0.4,0.6,0.3,0.2}},
  {name="SUNRISE",    root=48, scale=1,  bpm=110, dens={0.5,0.6,0.7,0.4, 0.8,0.5,0.3,0.6}},
  {name="HEAT",       root=41, scale=29, bpm=128, dens={0.9,0.8,0.5,0.7, 0.6,0.9,0.4,0.8}},
  {name="DRIFT",      root=45, scale=5,  bpm=92,  dens={0.3,0.2,0.6,0.3, 0.5,0.4,0.7,0.2}},
  {name="FUNK",       root=43, scale=2,  bpm=105, dens={0.8,0.7,0.4,0.6, 0.5,0.8,0.6,0.7}},
  {name="CRYSTAL",    root=48, scale=11, bpm=72,  dens={0.2,0.4,0.8,0.3, 0.6,0.3,0.9,0.1}},
  {name="PRESSURE",   root=38, scale=8,  bpm=140, dens={0.9,0.9,0.3,0.8, 0.7,0.5,0.6,0.9}},
  {name="GHOST",      root=40, scale=3,  bpm=98,  dens={0.4,0.5,0.3,0.2, 0.3,0.7,0.5,0.4}},
}
local current_spirit = 1

local midi_device_names = {}
local scale_names = {}
local tracks = {}

-- Track activity indicators (flash on note trigger)
local track_activity = { 0, 0, 0, 0, 0, 0, 0, 0 }
local ACTIVITY_DECAY = 0.5

-- Transient parameter popup state
local popup_param = nil
local popup_val = nil
local popup_time = 0
local POPUP_DURATION = 0.8

-- Scene snapshots (8 scenes)
local scenes = {}
local current_scene = 1

-- Track label abbreviations
local track_labels = { "KK", "SN", "PR", "SM", "BS", "LD", "AR", "CH" }

-- OP-Z step component CC mapping per track
-- Each track has 8 step components (CC 1-8)
local step_component_cc = {
  { cc_base = 1, enabled = true },   -- Track 1
  { cc_base = 9, enabled = true },   -- Track 2
  { cc_base = 17, enabled = true },  -- Track 3
  { cc_base = 25, enabled = true },  -- Track 4
  { cc_base = 33, enabled = true },  -- Track 5
  { cc_base = 41, enabled = true },  -- Track 6
  { cc_base = 49, enabled = true },  -- Track 7
  { cc_base = 57, enabled = true },  -- Track 8
}

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
  opxy_note_on(note, vel)
  track_activity[ch] = 1.0
  screen_dirty = true
end

local function note_off(ch, note)
  if m then m:note_off(note, 0, ch) end
  opxy_note_off(note)
end

local function cc(ch, num, val)
  if m then m:cc(num, val, ch) end
end

local function send_step_component_cc(track_id, component, value)
  if not step_component_cc[track_id].enabled then return end
  local cc_num = step_component_cc[track_id].cc_base + component - 1
  cc(tracks[track_id].ch, cc_num, math.floor(value))
end

local function all_notes_off()
  if not m then return end
  for ch = 1, 16 do
    m:cc(123, 0, ch) -- all notes off
  end
end

-- Draw euclidean pattern as circle of dots
local function draw_euclid_circle(x, y, radius, pattern)
  if not pattern or #pattern == 0 then return end
  local steps = #pattern
  for i = 1, steps do
    local angle = (i - 1) / steps * 2 * math.pi
    local px = x + math.cos(angle) * radius
    local py = y + math.sin(angle) * radius
    screen.level(pattern[i] and 12 or 3)
    screen.circle(px, py, 1)
    screen.fill()
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

-- Scene save/load functions
local function save_scene(slot)
  local scene_data = {}
  for i = 1, 16 do
    scene_data[i] = {
      density = tracks[i].density,
      vel = tracks[i].vel,
      oct = tracks[i].oct,
      pattern = {},
      notes = {},
    }
    for j = 1, state.steps do
      scene_data[i].pattern[j] = tracks[i].pattern[j]
      scene_data[i].notes[j] = tracks[i].notes[j]
    end
  end
  scenes[slot] = scene_data
  local path = _path.data .. "ram_opz_mapped/scene_" .. slot .. ".lua"
  os.execute("mkdir -p " .. _path.data .. "ram_opz_mapped/")
  tab.save(scene_data, path)
  print("ram_opz: scene " .. slot .. " saved")
end

local function load_scene(slot)
  if not scenes[slot] then return end
  local scene_data = scenes[slot]
  for i = 1, 16 do
    if scene_data[i] then
      tracks[i].density = scene_data[i].density or 0.5
      tracks[i].vel = scene_data[i].vel or 95
      tracks[i].oct = scene_data[i].oct or 0
      tracks[i].pattern = scene_data[i].pattern or {}
      tracks[i].notes = scene_data[i].notes or {}
    end
  end
  current_scene = slot
  print("ram_opz: scene " .. slot .. " loaded")
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
  local scale = get_scale()
  local root_idx = nil
  for i, n in ipairs(scale) do
    if n == root_note then root_idx = i; break end
  end
  local notes = {}
  if root_idx and root_idx + 4 <= #scale then
    table.insert(notes, scale[root_idx])
    table.insert(notes, scale[root_idx + 2])
    table.insert(notes, scale[root_idx + 4])
    if root_idx + 6 <= #scale and math.random() < 0.4 then
      table.insert(notes, scale[root_idx + 6])
    end
  else
    notes = { root_note }
  end
  for _, n in ipairs(notes) do
    note_on(ch, clamp(n, 0, 127), vel)
    -- Engine output
    local freq = midi_to_hz(n)
    engine.hz(freq)
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
  
  -- Send step component CCs
  send_step_component_cc(t.id, 1, cutoff)
  send_step_component_cc(t.id, 2, send)
end

local function play_step()
  for i = 1, 16 do
    local t = tracks[i]
    if t.enabled and t.pattern[state.step] then
      if t.kind == "drum" then
        note_on(t.ch, 60, t.vel)
        engine.hz(midi_to_hz(60))
        clock.run(function()
          clock.sleep(0.12)
          note_off(t.ch, 60)
          
        end)
      elseif t.kind == "bass" or t.kind == "arp" or t.kind == "lead" then
        local note = t.notes[state.step] or choose_from_scale(48, 84)
        note = clamp(note + t.oct, 0, 127)
        note_on(t.ch, note, t.vel)
        local freq = midi_to_hz(note)
        engine.hz(freq)
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
  state.beat_phase = (state.beat_phase + 1) % 4
  screen_dirty = true
end

local function sequencer()
  while true do
    clock.sync(1/4)
    if state.running then play_step() end
    
    -- Decay activity indicators
    for i = 1, 8 do
      track_activity[i] = math.max(0, track_activity[i] - (ACTIVITY_DECAY / 12))
    end
    
    if screen_dirty then
      redraw()
      screen_dirty = false
    end
  end
end

function redraw()
  screen.clear()
  
  -- ==============================================
  -- STATUS STRIP (y 0-8)
  -- ==============================================
  screen.level(4)
  screen.move(2, 7)
  screen.text("RAM>OPZ")

  -- BPM display (prominent)
  screen.level(8)
  screen.font_size(7)
  screen.move(64, 7)
  screen.text_center(state.bpm .. " BPM")
  screen.font_size(8)

  -- Scene indicator
  screen.level(6)
  screen.move(120, 7)
  screen.text_right("S" .. current_scene)
  
  -- Beat pulse dot at x=124
  if state.beat_phase == 0 and state.running then
    screen.level(15)
  else
    screen.level(3)
  end
  screen.rect(122, 2, 3, 3)
  screen.fill()
  
  -- ==============================================
  -- LIVE ZONE (y 9-52): 8-channel sequencer
  -- ==============================================
  -- Each track row is ~5px tall
  for ch = 1, 8 do
    local y = 9 + (ch - 1) * 5
    local t = tracks[ch]
    
    -- Track label at level 5 (or 12 if selected)
    if ch == selected_track then
      screen.level(12)
    else
      screen.level(5)
    end
    screen.move(2, y + 4)
    screen.text(track_labels[ch])
    
    -- Subtle highlight bar behind selected track
    if ch == selected_track then
      screen.level(2)
      screen.rect(0, y, 128, 5)
      screen.fill()
      screen.level(12)
    end
    
    -- Activity meter: horizontal bar
    local activity_brightness = math.floor(track_activity[ch] * 13) + 2
    if track_activity[ch] > 0 then
      screen.level(activity_brightness)
    else
      screen.level(2)
    end
    local meter_width = math.floor(track_activity[ch] * 40)
    if meter_width > 0 then
      screen.rect(24, y + 1, meter_width, 3)
      screen.fill()
    else
      screen.rect(24, y + 1, 40, 3)
      screen.stroke()
    end
    
    -- Step component indicator (STP) if active
    if step_component_cc[ch].enabled then
      screen.level(6)
      screen.move(70, y + 4)
      screen.text("STP")
    end

    -- Euclidean pattern circle (small, right side)
    if t.enabled and t.pattern then
      draw_euclid_circle(105, y + 2, 4, t.pattern)
    end
  end
  
  -- ==============================================
  -- CONTEXT BAR (y 53-58)
  -- ==============================================
  screen.level(6)
  screen.move(2, 60)
  screen.text(scale_names[state.scale] or "Unknown")
  
  screen.level(4)
  screen.move(50, 60)
  screen.text(midi_device_names[params:get("midi_out")] or "MIDI")
  
  -- Active track count
  local active_count = 0
  for i = 1, 8 do
    if tracks[i].enabled then active_count = active_count + 1 end
  end
  screen.level(5)
  screen.move(120, 60)
  screen.text_right(active_count .. "/8")

  screen.update()
end

local k1_held = false

function enc(n, d)
  if n == 1 then
    -- E1: cycle spirits
    current_spirit = clamp(current_spirit + d, 1, #spirits)
    local sp = spirits[current_spirit]
    state.root = sp.root
    state.scale = sp.scale
    state.bpm = sp.bpm
    params:set("clock_tempo", sp.bpm)
    for i = 1, math.min(8, #sp.dens) do
      if tracks[i] then
        tracks[i].density = sp.dens[i]
        tracks[i].enabled = sp.dens[i] > 0.15
      end
    end
    regen_all()
    popup_param = "SPIRIT"
    popup_val = sp.name
    popup_time = 15
  elseif n == 2 then
    if k1_held then
      -- K1+E2: velocity
      local t = tracks[selected_track]
      t.vel = clamp(t.vel + d, 20, 127)
      popup_param = "VEL"
      popup_val = t.vel
      popup_time = 10
    else
      -- E2: select track
      selected_track = clamp(selected_track + d, 1, 16)
      local t = tracks[selected_track]
      popup_param = "TRACK " .. selected_track
      popup_val = t.kind
      popup_time = 10
    end
  elseif n == 3 then
    if k1_held then
      -- K1+E3: octave shift
      local t = tracks[selected_track]
      t.oct = clamp(t.oct + d, -24, 24)
      popup_param = "OCTAVE"
      popup_val = t.oct
      popup_time = 10
    else
      -- E3: density
      local t = tracks[selected_track]
      t.density = clamp(t.density + d / 100, 0, 1)
      if not pattern_locked then
        regen_track(t)
      end
      popup_param = "DENSITY"
      popup_val = string.format("%.0f%%", t.density * 100)
      popup_time = 10
    end
  end
  screen_dirty = true
end

function key(n, z)
  if n == 1 then
    k1_held = (z == 1)
    return
  end
  if n == 2 then
    if z == 1 then
      k2_down_time = 0
    else
      if k1_held then
        -- K1+K2: toggle current track enabled
        local t = tracks[selected_track]
        t.enabled = not t.enabled
        popup_param = "TRACK " .. selected_track
        popup_val = t.enabled and "ON" or "OFF"
        popup_time = 10
      elseif k2_down_time > 0.5 then
        pattern_locked = not pattern_locked
        popup_param = "PATTERN"
        popup_val = pattern_locked and "LOCKED" or "FREE"
        popup_time = 10
      else
        state.running = not state.running
        if not state.running then all_notes_off() end
        popup_param = state.running and "PLAY" or "STOP"
        popup_val = ""
        popup_time = 10
      end
      k2_down_time = 0
    end
  elseif n == 3 and z == 1 then
    if k1_held then
      -- K1+K3: regenerate ALL tracks
      regen_all()
      popup_param = "REGEN ALL"
      popup_val = ""
      popup_time = 10
    else
      -- K3: VIBE SHIFT — new scale, new root, shuffle densities, regen all
      local roots = {36, 38, 40, 41, 43, 45, 47, 48}
      state.root = roots[math.random(#roots)]
      local good_scales = {1, 2, 3, 5, 7, 8, 11, 12, 29}
      state.scale = good_scales[math.random(#good_scales)]
      -- shuffle densities across tracks
      for i = 1, 16 do
        local t = tracks[i]
        if t then
          t.density = clamp(t.density + (math.random() - 0.5) * 0.3, 0.05, 0.95)
          -- occasionally flip a track on/off
          if math.random() < 0.15 then t.enabled = not t.enabled end
        end
      end
      regen_all()
      local root_name = musicutil.note_num_to_name(state.root, true)
      local scale_name = musicutil.SCALES[state.scale].name
      popup_param = root_name .. " " .. scale_name:sub(1, 8)
      popup_val = "VIBE SHIFT"
      popup_time = 15
    end
  end
  screen_dirty = true
end

function init()
  math.randomseed(os.time())

  -- PolyPerc defaults
  engine.amp(0.7)
  engine.release(0.3)
  engine.cutoff(2500)
  engine.pw(0.4)

  build_midi_device_names()
  build_scale_names()
  init_tracks()
  regen_all()

  -- auto-start
  state.running = true

  params:add_group("ram_opz", 4)

  params:add_option("midi_out", "midi out", midi_device_names, 1)
  params:set_action("midi_out", function(v) connect_midi(v) end)

  params:add_separator("OP-XY MIDI")
  params:add{type="number", id="opxy_device", name="OP-XY Device", min=1, max=16, default=2, action=function(v) opxy_out = midi.connect(v) end}
  params:add{type="number", id="opxy_channel", name="OP-XY Channel", min=1, max=16, default=1}
  opxy_out = midi.connect(params:get("opxy_device"))

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
    params:set("clock_tempo", v)
  end)

  params:bang()
  params:set("clock_tempo", state.bpm)

  -- Timer for K2 hold detection
  k2_hold_clock_id = clock.run(function()
    while true do
      clock.sleep(0.01)
      if k2_down_time >= 0 and k2_down_time < 10 then
        k2_down_time = k2_down_time + 0.01
      end
    end
  end)

  -- Screen refresh at ~12fps for animation
  screen_refresh_id = clock.run(function()
    while true do
      clock.sleep(1/12)
      screen_dirty = true
    end
  end)
  
  sequencer_clock = clock.run(sequencer)
end

function cleanup()
  state.running = false
  all_notes_off()
  if opxy_out then for ch=1,16 do opxy_out:cc(123,0,ch) end end
  -- PolySub: noteOff per-voice (all_notes_off already handles MIDI CC 123)
  for n=0,127 do pcall(function()  end) end
  if screen_refresh_id then clock.cancel(screen_refresh_id) end
  if sequencer_clock then clock.cancel(sequencer_clock) end
  if k2_hold_clock_id then clock.cancel(k2_hold_clock_id) end
  -- Save current scene
  save_scene(current_scene)
end
