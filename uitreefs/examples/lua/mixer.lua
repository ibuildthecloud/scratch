-- mixer.lua: a color mixer in Lua. Three sliders mix a color, a hex
-- field takes one typed in, Random rolls one, and Save keeps it in a
-- palette of swatches you can click to bring back.
--
--	uitreefs -t Mixer --dir ALPINE:#L lua5.4 mixer.lua
--
-- Lua is a Linux program here, from an Alpine tree run by h9's Linux ABI,
-- and it reaches the tree at $ui with nothing but io.open. Every event
-- line starts name key path, so gmatch("%S+") is the whole parser, and
-- every update is one write of set lines to the window's ctl, which apply
-- together in one frame.
--
-- Shows: a standard-library-only Lua client, sliders whose change events
-- carry value=, a tag on a container inherited by the three sliders, echoes
-- (via=ctl) told apart from the user's own changes, style rewritten with
-- set PATH : words, swatches made with new and routed by tag.   Needs: M3

local ui = os.getenv("ui") or "/mnt/ui"

-- put: one open, one write, one close. A ctl applies its lines at close.
local function put(path, s)
	local f = assert(io.open(ui .. "/" .. path, "w"))
	f:write(s)
	f:close()
end
local function get(path)
	local f = assert(io.open(ui .. "/" .. path))
	local s = f:read("a")
	f:close()
	return s
end
local function ctl(lines) put("win/main/ctl", table.concat(lines, "\n") .. "\n") end
-- Plan 9 quoting, for values with blanks in them.
local function q(s)
	if s ~= "" and not s:find("[%s'=]") then return s end
	return "'" .. s:gsub("'", "''") .. "'"
end

-- A few named colors, to say what the mix is close to.
local names = {
	{"black", 0, 0, 0}, {"white", 255, 255, 255}, {"red", 230, 57, 70},
	{"tomato", 255, 99, 71}, {"orange", 245, 158, 11}, {"gold", 250, 204, 21},
	{"olive", 128, 128, 0}, {"lime", 132, 204, 22}, {"green", 34, 197, 94},
	{"teal", 20, 184, 166}, {"cyan", 6, 182, 212}, {"sky", 14, 165, 233},
	{"blue", 59, 130, 246}, {"indigo", 99, 102, 241}, {"violet", 139, 92, 246},
	{"purple", 168, 85, 247}, {"pink", 236, 72, 153}, {"rose", 244, 63, 94},
	{"brown", 120, 72, 40}, {"slate", 100, 116, 139}, {"gray", 128, 128, 128},
}
local function nearest(r, g, b)
	local best, d = "", math.huge
	for _, c in ipairs(names) do
		local e = (r - c[2]) ^ 2 + (g - c[3]) ^ 2 + (b - c[4]) ^ 2
		if e < d then best, d = c[1], e end
	end
	return best
end

local rgb = {r = 59, g = 130, b = 246}
local function hex() return string.format("#%02x%02x%02x", rgb.r, rgb.g, rgb.b) end
local swatch = "size=132 rounded_xl border_1 border_color=border shadow_md bg="

put("win/main/ctl", "set . title=Mixer size=560,520 min=480,460 pos=center")
put("win/main/tree", [[
div root  : v_flex size_full p=24 gap=18 bg=background
  div top  : h_flex gap=20 items_center
    div swatch  : ]] .. swatch .. hex() .. "\n" .. [[
    div info  : v_flex gap=6 flex_1
      text hex  text=#3b82f6  : text_3xl font_bold font_family=monospace
      text rgb  text='rgb(59, 130, 246)'  : text_sm text_color=muted_foreground font_family=monospace
      text name  text='close to blue'  : text_sm text_color=muted_foreground
  div sliders  tag=rgb  : v_flex gap=10
    div r  : h_flex gap=12 items_center
      text l  text=R  : w=16 font_semibold text_color=danger
      slider s  min=0  max=255  step=1  value=59  : flex_1
      text v  text=59  : w=36 text_right font_family=monospace
    div g  : h_flex gap=12 items_center
      text l  text=G  : w=16 font_semibold text_color=success
      slider s  min=0  max=255  step=1  value=130  : flex_1
      text v  text=130  : w=36 text_right font_family=monospace
    div b  : h_flex gap=12 items_center
      text l  text=B  : w=16 font_semibold text_color=info
      slider s  min=0  max=255  step=1  value=246  : flex_1
      text v  text=246  : w=36 text_right font_family=monospace
  div row  : h_flex gap=8 items_center
    input hex  placeholder=#rrggbb  tag=hex  : w=150 font_family=monospace
    button save  label='Save swatch'  icon=plus  tag=save  : outline sm
    button random  label=Random  icon=shuffle  tag=random  : ghost sm
  text ph  text=Palette  : text_sm font_semibold
  div palette  : h_flex flex_wrap gap=8
    text none  text='Saved colors appear here.'  : text_sm text_color=muted_foreground
]])
put("keys", "cmd-s save\ncmd-r random\n")

-- show: everything that follows from rgb, as one ctl write. With
-- sliders=true the sliders are moved too (for a typed or random color).
local function show(sliders)
	local h = hex()
	local lines = {
		"set swatch : " .. swatch .. h,
		"set info/hex text=" .. h,
		"set info/rgb text=" .. q(string.format("rgb(%d, %d, %d)", rgb.r, rgb.g, rgb.b)),
		"set info/name text=" .. q("close to " .. nearest(rgb.r, rgb.g, rgb.b)),
	}
	for _, c in ipairs({"r", "g", "b"}) do
		lines[#lines + 1] = "set sliders/" .. c .. "/v text=" .. rgb[c]
		if sliders then lines[#lines + 1] = "set sliders/" .. c .. "/s value=" .. rgb[c] end
	end
	ctl(lines)
end

local saved = 0
math.randomseed(os.time())
for line in io.lines(ui .. "/events") do
	local w = {}
	for x in line:gmatch("%S+") do w[#w + 1] = x end
	local name, key, path = w[1], w[2], w[3]
	local a = {}
	for i = 4, #w do
		local k, v = w[i]:match("^([^=]+)=(.*)$")
		if k then a[k] = v end
	end
	if name == "change" and key == "rgb" and a.via ~= "ctl" then
		-- path is sliders/r/s: the second part names the channel
		local c = path:match("^sliders/(%a)/s$")
		local v = tonumber(a.value)
		if c and v then
			rgb[c] = math.floor(v + 0.5)
			show(false)
		end
	elseif name == "submit" and key == "hex" then
		local s = get("win/main/row/hex/value"):gsub("%s", ""):gsub("^#", "")
		if s:match("^%x%x%x%x%x%x$") then
			rgb.r, rgb.g, rgb.b = tonumber(s:sub(1, 2), 16), tonumber(s:sub(3, 4), 16), tonumber(s:sub(5, 6), 16)
			ctl({"set row/hex value="})
			show(true)
		end
	elseif (name == "click" or name == "action") and key == "random" then
		rgb.r, rgb.g, rgb.b = math.random(0, 255), math.random(0, 255), math.random(0, 255)
		show(true)
	elseif (name == "click" or name == "action") and key == "save" then
		saved = saved + 1
		local h = hex()
		local lines = {}
		if saved == 1 then lines[1] = "delete palette/none" end
		lines[#lines + 1] = "new div palette/s" .. saved .. " tag=pick:" .. h:sub(2) .. " on=click tooltip=" .. h ..
			" : size=40 rounded_md border_1 border_color=border cursor_pointer hover:border_color=ring bg=" .. h
		ctl(lines)
	elseif name == "click" and key:match("^pick:") then
		local s = key:sub(6)
		rgb.r, rgb.g, rgb.b = tonumber(s:sub(1, 2), 16), tonumber(s:sub(3, 4), 16), tonumber(s:sub(5, 6), 16)
		show(true)
	end
end
