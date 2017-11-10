local utils = require "mp.utils"
local options = require "mp.options"
local msg = require 'mp.msg'

local cut_timestamp = nil
local action_to_confirm = nil
local delay_error = 5
local delay_info = 2
local delay_confirm = 99999
local delay_pause = 0.1 -- 100ms to wait before printing an osd message after a pause

--
-- LOG()
--
function osd(msg, level, delay)
    local prefix = "[cutoff]"
    if level then
      prefix = prefix .. "[" .. level .. "]"
    end
    mp.osd_message(prefix .. ' ' .. msg, delay)
end
function osd_err(msg)
  osd(msg, 'error', delay_error)
end
function osd_confirm(msg)
  osd(msg, nil, delay_confirm)
end
function osd_info(msg)
  osd(msg, 'info', delay_info)
end
function osd_clear()
  mp.osd_message('')
end

--
-- APPEND_TABLE()
--
function append_table(lhs, rhs)
    for i = 1,#rhs do
        lhs[#lhs+1] = rhs[i]
    end
    return lhs
end

--
-- FILE_EXISTS()
--
function file_exists(name)
    local f = io.open(name, "r")
    if f ~= nil then
        io.close(f)
        return true
    else
        return false
    end
end

--
-- SECONDS_TO_TIME_STRING
--
function seconds_to_time_string(seconds, full)
    local ret = string.format("%02d:%02d.%03d"
        , math.floor(seconds / 60) % 60
        , math.floor(seconds) % 60
        , seconds * 1000 % 1000
    )
    if full or seconds > 3600 then
        ret = string.format("%d:%s", math.floor(seconds / 3600), ret)
    end
    return ret
end

--
-- RUN FFMPEG
--
function run_ffmpeg(input, output, force, from, to, ffmpeg_args)
  local args = {
    "ffmpeg",
    "-loglevel", "panic", "-hide_banner", --stfu ffmpeg
  }
  if force then
    args = append_table(args, {"-y"})
  end
  if from > 0 then
    args = append_table(args, {"-ss", seconds_to_time_string(from, false)})
  end
  args = append_table(args, {"-i", input, "-c", "copy"})
  if to > 0 then
    if from > 0 then
      to = to - from
    end
    args = append_table(args, {"-to", seconds_to_time_string(to, false)})
  end
  for token in string.gmatch(ffmpeg_args, "[^%s]+") do
    args[#args + 1] = token
  end
  args[#args + 1] = output

  msg.info("Run " .. utils.to_string(args))
--  return true
  local res = utils.subprocess({ args = args, max_size = 1024, cancellable = false })
  msg.info("FFMPEG return: " .. utils.to_string(res.stdout))
  if res.status == 0 then
    return true
  else
    return false, "Failed to encode, check the log"
  end
end

--
-- GET_PATH()
--
function get_path()
  local path = mp.get_property("path")
  if not path then
    osd_err("No file currently playing")
    return false
  end
  if not file_exists(path) then
    osd_err("File does not exist on disk")
    return false
  end

  local ext = path:lower():match('%.(%w+)$')
  if ext ~= "mp4" and ext ~= "mov" then
    osd_err("I can only work with MP4 files, sorry (" .. ext .. ")")
    return false
  end

  return path
end

--
-- CUT()
--
function cut()
  local path = get_path()
  if not path then return end
 
  local timestamp = mp.get_property_number("time-pos")
  if cut_timestamp == nil then
      cut_timestamp = timestamp
      mp.set_property("pause", "yes")
      mp.add_timeout(delay_pause, function() 
        osd_info("[CUT] set starting position to current frame: " .. seconds_to_time_string(timestamp, false))
      end)
  else
    if timestamp < cut_timestamp then -- exchange times
      local tmp = timestamp
      timestamp = cut_timestamp
      cut_timestamp = tmp
    end

    local _, filename = utils.split_path(path)
    local name, ext = filename:match('^(.+)%.(%w%w%w)$')
    filename = name .. ".cut$n." .. ext
    local dir = mp.get_property("screenshot-directory", "string")
    local out = utils.join_path(dir, filename)

    local i = 1
    while true do
      local potential_name = string.gsub(out, "$n", tostring(i))
      if not file_exists(potential_name) then
        out = potential_name
        break
      end
      i = i + 1
    end

    local from = cut_timestamp
    cut_timestamp = nil

    ask_confirmation("[CUT] Ready to cut from " .. seconds_to_time_string(from, false) .. " to " .. seconds_to_time_string(timestamp, false) .. " to " .. out .. ": confirm ? (Y)", function()
      local ret, msg = run_ffmpeg(path, out, false, from, timestamp, "")
      if not ret then
        os.remove(out)
        osd_err("Error while trimming: " .. msg)
        return
      else
        ask_confirmation("Do you want to load the new file (" .. out .. ")? (Y)", function()
          mp.commandv("loadfile", out, "replace", "start=0")
          mp.set_property("pause", "no")
        end)
      end
    end)
  end
end

function clear_cut()
  cut_timestamp = nil
  osd_info("cut position has been cleared")
end

--
-- TRIM()
--
function trim(before, after)
  local path = get_path()
  if not path then return end
 
  local timestamp = mp.get_property_number("time-pos")
--  local fps = mp.get_property_number("container-fps")
--  timestamp = timestamp + 1 / fps / 2

  if before and timestamp <= 0.1 then
    osd_err("Can't trim before start (0)")
    return
  end

  local remain = mp.get_property_number("time-remaining")
  if after and remain <= 1.0 then
    osd_err("Can't trim after end (" .. remain .. ")")
    return
  end

  local output = path:gsub('%.mp4$', ".trim.mp4")

  local from = -1
  local to = -1
  if before then
    from = timestamp
  end
  if after then
    to = timestamp
  end


  local way = "-"
  if before then way = "before" end
  if after then way = "after" end
  local osd_msg = "Are you sure to cut " .. way .. " the current position. This will alter the current file ? (Y)"
  ask_confirmation(osd_msg, function()
    ask_confirmation("These will replace the original file, are you really sure ? (Y)", function()
      mp.command('stop')

      local ret, err = run_ffmpeg(path, output, true, from, to, "")
      if not ret then
        os.remove(output)
        osd_err("Error while trimming: " .. err)
        return
      else
        msg.info("renaming " .. output .. " to " .. path)
        os.remove(path)
        os.rename(output, path)
      end
      mp.commandv("loadfile", path, "replace", "start=0")
      osd_clear()
    end)
  end)
end

--
-- ASK_CONFIRMATION
--
function ask_confirmation(msg, action)
  action_to_confirm = action
  local check_pause = function(name, value)
    if not value then -- remove action and clean osd if trimming has been canceled
      osd_clear()
      action_to_confirm = nil
      cut_timestamp = nil
      mp.unobserve_property(check_pause)
    end
  end
  mp.set_property("pause", "yes")
  mp.add_timeout(delay_pause, function() 
    osd_confirm(msg)
    mp.observe_property("pause", "bool", check_pause)
  end)
end

--
-- TRIM_BEFORE()
--
function trim_before()
  trim(true, false)
end

--
-- TRIM_AFTER()
--
function trim_after()
  trim(false, true)
end

--
-- CONFIRM()
--
function confirm()
  if action_to_confirm then
    local action = action_to_confirm
    action_to_confirm = nil
    action()
  else
    osd_info("No action to confirm")
  end
end

--
-- KEY BINDING
--
mp.add_key_binding("c", "cut", cut)
mp.add_key_binding("Ctrl+c", "clear-cut", clear_cut)
mp.add_key_binding("b", "trim-before", trim_before)
mp.add_key_binding("a", "trim-after", trim_after)
mp.add_key_binding("y", "confirm", confirm)
