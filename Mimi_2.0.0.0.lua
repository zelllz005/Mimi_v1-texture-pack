--[[
	Mimi[1.0.0.0]
	Pixel texture pack for Roblox executors. Every block in the map gets chunky pixels;
	players, NPCs and their gear are never touched.

	Open the menu with the glowing "M" orb (drag it anywhere) or press RightShift.
	Needs an executor that supports writefile + getcustomasset.
]]

local Players = game:GetService("Players")
local Lighting = game:GetService("Lighting")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local NAME = "Mimi[1.0.0.0]"
local TAG = "MimiPixel"
local SMOOTH = Enum.Material.SmoothPlastic
local RESCAN_EVERY = 10 -- seconds between automatic sweeps

local STYLES = { "Classic", "Speckle", "Grain", "Stone", "Brick", "Checker", "Mosaic", "Dither", "Dunes", "Ore" }
local styleIndex = {}
for index, name in ipairs(STYLES) do styleIndex[name] = index end

local REFLECTION_NAMES = { "Off", "Subtle", "Soft", "Glossy", "Mirror", "Chrome" }
local REFLECTION = { Off = 0, Subtle = 0.05, Soft = 0.12, Glossy = 0.25, Mirror = 0.45, Chrome = 0.7 }

local GRADE_NAMES = { "Off", "Warm", "Cool", "Vivid", "Cinema" }
local GRADES = {
	Off = false,
	Warm = { Brightness = 0.02, Contrast = 0.08, Saturation = 0.12, TintColor = Color3.fromRGB(255, 240, 220) },
	Cool = { Brightness = 0, Contrast = 0.08, Saturation = 0.05, TintColor = Color3.fromRGB(222, 238, 255) },
	Vivid = { Brightness = 0, Contrast = 0.15, Saturation = 0.35, TintColor = Color3.fromRGB(255, 255, 255) },
	Cinema = { Brightness = -0.02, Contrast = 0.22, Saturation = 0.05, TintColor = Color3.fromRGB(255, 246, 235) },
}

local env = (getgenv and getgenv()) or _G
if env.MimiStop then pcall(env.MimiStop) end
if env.PixelPackStop then pcall(env.PixelPackStop) end -- remove the first version if it is still loaded

local origLighting = {
	GlobalShadows = Lighting.GlobalShadows,
	Exposure = Lighting.ExposureCompensation,
	EnvSpec = Lighting.EnvironmentSpecularScale,
}
pcall(function() origLighting.ShadowSoftness = Lighting.ShadowSoftness end)

local CFG = {
	On = false, Flat = false, Auto = true, Shuffle = true, Blur = true,
	PixelSize = 0.5, -- studs per pixel
	Strength = 0.8,
	Style = "Classic",
	-- realism
	Reflection = "Subtle", Variation = 0, Bloom = 0, Rays = 0, Haze = 0,
	Exposure = origLighting.Exposure, EnvSpec = origLighting.EnvSpec,
	Grade = "Off", Dof = false, Shadows = false,
}
local REALISM_DEFAULTS = {}
for _, key in ipairs({ "Reflection", "Variation", "Bloom", "Rays", "Haze", "Exposure", "EnvSpec", "Grade", "Dof", "Shadows" }) do
	REALISM_DEFAULTS[key] = CFG[key]
end

------------------------------------------------------------------ PNG encoder
-- Mimi builds its own small images (pixel tiles and soft glows) so nothing is downloaded
-- and no picture ever replaces your blocks.

local crcTable = {}
for i = 0, 255 do
	local c = i
	for _ = 1, 8 do
		if bit32.band(c, 1) == 1 then
			c = bit32.bxor(0xEDB88320, bit32.rshift(c, 1))
		else
			c = bit32.rshift(c, 1)
		end
	end
	crcTable[i] = c
end

local function crc32(s)
	local c = 0xFFFFFFFF
	for i = 1, #s do
		c = bit32.bxor(crcTable[bit32.band(bit32.bxor(c, s:byte(i)), 255)], bit32.rshift(c, 8))
	end
	return bit32.bxor(c, 0xFFFFFFFF)
end

local function u32(n)
	return string.char(bit32.rshift(n, 24) % 256, bit32.rshift(n, 16) % 256, bit32.rshift(n, 8) % 256, n % 256)
end

local function pngChunk(kind, data)
	return u32(#data) .. kind .. data .. u32(crc32(kind .. data))
end

-- zlib stream made of "stored" blocks (no compression needed for tiny images)
local function zlibStore(data)
	local out, pos, total = { "\120\1" }, 1, #data
	repeat
		local size = math.min(65535, total - pos + 1)
		local last = (pos + size > total) and 1 or 0
		local nsize = 65535 - size
		out[#out + 1] = string.char(last, size % 256, math.floor(size / 256), nsize % 256, math.floor(nsize / 256))
			.. data:sub(pos, pos + size - 1)
		pos += size
	until pos > total
	local a, b = 1, 0
	for i = 1, total do
		a = (a + data:byte(i)) % 65521
		b = (b + a) % 65521
	end
	out[#out + 1] = u32(b * 65536 + a)
	return table.concat(out)
end

local function encodePNG(width, height, data) -- data: RGBA scanlines, each starting with a filter byte
	return "\137PNG\r\n\26\n"
		.. pngChunk("IHDR", u32(width) .. u32(height) .. "\8\6\0\0\0")
		.. pngChunk("IDAT", zlibStore(data))
		.. pngChunk("IEND", "")
end

------------------------------------------------------------------ pixel styles
local GRID, CELL = 16, 4 -- 16x16 pixels per tile, 4 texels per pixel keeps the edges sharp
local SIZE = GRID * CELL

local function hash(x, y, seed)
	local n = math.sin(x * 12.9898 + y * 78.233 + seed * 37.719) * 43758.5453
	return n - math.floor(n)
end

local BAYER = { 0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5 }

-- One pixel of a tile as a tone from -1 (dark) to 1 (light).
local function pixelTone(style, rng, col, row, seed)
	local noise = rng:NextNumber() * 2 - 1
	if style == "Classic" then
		return math.floor(noise * 2 + 0.5) / 2
	elseif style == "Speckle" then
		if rng:NextNumber() < 0.22 then return noise > 0 and 0.9 or -0.9 end
		return 0
	elseif style == "Grain" then -- plank lines
		if row % 4 == 0 then return -0.85 end
		return math.floor(noise * 1.5 + 0.5) / 4
	elseif style == "Stone" then -- soft blotches
		local blotch = hash(math.floor(col / 2), math.floor(row / 2), seed) * 2 - 1
		return math.floor((blotch * 0.9 + noise * 0.25) * 3 + 0.5) / 3
	elseif style == "Brick" then -- mortar lines, offset every other course
		local offset = (math.floor(row / 4) % 2) * 4
		if row % 4 == 0 or (col + offset) % 8 == 0 then return -0.9 end
		local brick = hash(math.floor((col + offset) / 8), math.floor(row / 4), seed) * 2 - 1
		return math.floor((brick * 0.5 + noise * 0.15) * 4 + 0.5) / 4
	elseif style == "Checker" then
		return ((col + row) % 2 == 0 and 0.4 or -0.4) + math.floor(noise + 0.5) / 8
	elseif style == "Mosaic" then -- 4x4 tiles with dark seams
		if col % 4 == 0 or row % 4 == 0 then return -0.5 end
		return math.floor((hash(math.floor(col / 4), math.floor(row / 4), seed) * 2 - 1) * 3 + 0.5) / 3
	elseif style == "Dither" then -- ordered dithering with varying density
		local density = hash(math.floor(col / 4), math.floor(row / 4), seed)
		return (BAYER[(row % 4) * 4 + col % 4 + 1] / 16 < density) and -0.7 or 0.15
	elseif style == "Dunes" then -- diagonal sand ripples
		local band = (col + row * 2) % 8
		if band < 2 then return -0.75 elseif band < 4 then return -0.25 end
		return math.floor(noise * 1.5 + 0.5) / 4 + 0.2
	end
	-- Ore: quiet stone with a few bright gems and dark nuggets
	local gem = hash(math.floor(col / 2), math.floor(row / 2), seed)
	if gem > 0.9 then return 1 elseif gem < 0.08 then return -1 end
	return math.floor(noise * 1.5 + 0.5) / 5
end

-- bias > 0: bright block (lean dark). bias < 0: dark block (lean light).
local function toneColor(tone, bias)
	tone = math.clamp(tone - bias * 0.3, -1, 1)
	if tone < -0.08 then return 0, 0, 0, math.floor(-tone * 150) end
	if tone > 0.08 then return 255, 255, 255, math.floor(tone * 130) end
	return 128, 128, 128, 0
end

local function buildTile(style, bias)
	local rng = Random.new(1337 + bias * 31 + styleIndex[style] * 101)
	local seed = styleIndex[style] * 7.3 + bias
	local lines = {}
	for row = 0, GRID - 1 do
		local line = { "\0" } -- PNG filter byte
		for col = 0, GRID - 1 do
			line[#line + 1] = string.rep(string.char(toneColor(pixelTone(style, rng, col, row, seed), bias)), CELL)
		end
		lines[#lines + 1] = string.rep(table.concat(line), CELL)
	end
	return encodePNG(SIZE, SIZE, table.concat(lines))
end

local function buildGlow()
	local n, rows = 64, {}
	for y = 0, n - 1 do
		local line = { "\0" }
		local dy = (y + 0.5) / n * 2 - 1
		for x = 0, n - 1 do
			local dx = (x + 0.5) / n * 2 - 1
			local fall = math.clamp(1 - math.sqrt(dx * dx + dy * dy), 0, 1)
			line[#line + 1] = string.char(255, 255, 255, math.floor(fall * fall * 255))
		end
		rows[#rows + 1] = table.concat(line)
	end
	return encodePNG(n, n, table.concat(rows))
end

local SUPPORTED = type(writefile) == "function"
	and (type(getcustomasset) == "function" or type(getsynasset) == "function")

local function makeAsset(file, builder)
	if not SUPPORTED then return nil end
	local ok, asset = pcall(function()
		writefile(file, builder())
		return (getcustomasset or getsynasset)(file)
	end)
	return ok and asset or nil
end

local tiles = {}
local function tileFor(style, bias)
	local key = style .. bias
	if tiles[key] == nil then
		local file = ("Mimi_%s_%d.png"):format(style, bias)
		tiles[key] = makeAsset(file, function() return buildTile(style, bias) end) or false
	end
	return tiles[key]
end

local GLOW = makeAsset("Mimi_glow.png", buildGlow)

------------------------------------------------------------------ realism (lighting)
local fx = {}
local function effect(class)
	local obj = fx[class]
	if not obj or not obj.Parent then
		obj = Instance.new(class)
		obj.Name = "Mimi" .. class
		obj.Parent = Lighting
		fx[class] = obj
	end
	return obj
end

local atmo, atmoOwned, atmoOrig = nil, false, nil
local function applyHaze()
	if CFG.Haze <= 0 then
		if atmo then
			if atmoOwned then
				atmo:Destroy()
			elseif atmoOrig then
				atmo.Density, atmo.Haze = atmoOrig.Density, atmoOrig.Haze
			end
		end
		atmo, atmoOwned, atmoOrig = nil, false, nil
		return
	end
	if not atmo then
		atmo = Lighting:FindFirstChildOfClass("Atmosphere")
		if atmo then
			atmoOrig = { Density = atmo.Density, Haze = atmo.Haze }
		else
			atmo = Instance.new("Atmosphere")
			atmo.Name = "MimiHaze"
			atmo.Parent = Lighting
			atmoOwned = true
		end
	end
	atmo.Density = 0.15 + CFG.Haze * 0.25
	atmo.Haze = CFG.Haze * 2
end

local function applyRealism()
	Lighting.ExposureCompensation = CFG.Exposure
	Lighting.EnvironmentSpecularScale = CFG.EnvSpec

	local bloom = effect("BloomEffect")
	bloom.Enabled = CFG.Bloom > 0
	bloom.Intensity = CFG.Bloom
	bloom.Size = 28
	bloom.Threshold = 0.85

	local rays = effect("SunRaysEffect")
	rays.Enabled = CFG.Rays > 0
	rays.Intensity = CFG.Rays
	rays.Spread = 0.8

	local grade = GRADES[CFG.Grade]
	local color = effect("ColorCorrectionEffect")
	color.Enabled = grade ~= false
	if grade then
		color.Brightness, color.Contrast = grade.Brightness, grade.Contrast
		color.Saturation, color.TintColor = grade.Saturation, grade.TintColor
	end

	local dof = effect("DepthOfFieldEffect")
	dof.Enabled = CFG.Dof
	dof.FarIntensity = 0.3
	dof.NearIntensity = 0
	dof.FocusDistance = 60
	dof.InFocusRadius = 50

	pcall(function()
		Lighting.GlobalShadows = CFG.Shadows or origLighting.GlobalShadows
		Lighting.ShadowSoftness = CFG.Shadows and 0.25 or origLighting.ShadowSoftness
	end)
	applyHaze()
end

local function restoreRealism()
	CFG.Haze = 0
	applyHaze()
	for _, obj in pairs(fx) do obj:Destroy() end
	fx = {}
	Lighting.ExposureCompensation = origLighting.Exposure
	Lighting.EnvironmentSpecularScale = origLighting.EnvSpec
	pcall(function()
		Lighting.GlobalShadows = origLighting.GlobalShadows
		Lighting.ShadowSoftness = origLighting.ShadowSoftness
	end)
end

------------------------------------------------------------------ block handling
local statusLabel
local function setStatus(message)
	if statusLabel then statusLabel.Text = message end
end

local FACES = Enum.NormalId:GetEnumItems()
local HAS_ZINDEX = pcall(function() return Instance.new("Texture").ZIndex end)

local function weakKeys() return setmetatable({}, { __mode = "k" }) end
local recs, list, count = weakKeys(), {}, 0 -- part -> record, ordered records, number of blocks
local watcher, scanToken = nil, 0

local function isCharacterOrGear(node)
	if node:IsA("Accessory") or node:IsA("Tool") or node:IsA("Camera") then return true end
	if node:FindFirstChildOfClass("Humanoid") then return true end
	return node:IsA("Model") and Players:GetPlayerFromCharacter(node) ~= nil
end

local function isBlock(part)
	if not part:IsA("BasePart") or part:IsA("Terrain") then return false end
	if part.Transparency > 0.6 or part.Size.Magnitude < 0.3 then return false end
	local node = part.Parent
	while node and node ~= workspace do
		if isCharacterOrGear(node) then return false end
		node = node.Parent
	end
	return node == workspace
end

local function biasOf(color)
	local luma = 0.299 * color.R + 0.587 * color.G + 0.114 * color.B
	if luma > 0.65 then return 1 end
	if luma < 0.3 then return -1 end
	return 0
end

-- material, reflectance and colour changes are always undoable
local function applyLook(rec)
	local part = rec.part
	if CFG.Flat then
		if not rec.mat and part.Material ~= SMOOTH then
			rec.mat = part.Material
			part.Material = SMOOTH
		end
	elseif rec.mat then
		part.Material = rec.mat
		rec.mat = nil
	end

	local level = REFLECTION[CFG.Reflection]
	if level > 0 then
		rec.refl = rec.refl or part.Reflectance
		part.Reflectance = math.max(rec.refl, level)
	elseif rec.refl then
		part.Reflectance = rec.refl
		rec.refl = nil
	end

	if CFG.Variation > 0 then
		rec.color = rec.color or part.Color
		local k = 1 + (rec.sj * 2 - 1) * CFG.Variation
		local c = rec.color
		part.Color = Color3.new(math.clamp(c.R * k, 0, 1), math.clamp(c.G * k, 0, 1), math.clamp(c.B * k, 0, 1))
	elseif rec.color then
		part.Color = rec.color
		rec.color = nil
	end
end

local function restoreLook(rec)
	if rec.mat then rec.part.Material = rec.mat end
	if rec.refl then rec.part.Reflectance = rec.refl end
	if rec.color then rec.part.Color = rec.color end
end

local function offsetFor(seed)
	if not CFG.Shuffle then return 0 end
	return math.floor(seed * GRID) * CFG.PixelSize -- random but pixel-aligned, hides tile repetition
end

local function styleTextures(rec)
	local asset = tileFor(CFG.Style, rec.bias)
	local tile = CFG.PixelSize * GRID
	for _, tex in ipairs(rec.tex) do
		if asset then tex.Texture = asset end
		tex.StudsPerTileU = tile
		tex.StudsPerTileV = tile
		tex.OffsetStudsU = offsetFor(rec.su)
		tex.OffsetStudsV = offsetFor(rec.sv)
		tex.Transparency = 1 - CFG.Strength
	end
end

local function refreshRecord(rec)
	styleTextures(rec)
	applyLook(rec)
end

local function applyPart(part, force)
	if not CFG.On then return end
	local rec = recs[part]
	if rec and not force then return end
	if not rec and not isBlock(part) then return end

	if rec then
		for _, tex in ipairs(rec.tex) do tex:Destroy() end
		rec.tex = {}
	else
		rec = {
			part = part, bias = biasOf(part.Color), tex = {},
			su = math.random(), sv = math.random(), sj = math.random(),
		}
		recs[part] = rec
		list[#list + 1] = rec
		count += 1
	end

	if not tileFor(CFG.Style, rec.bias) then return end
	for _, face in ipairs(FACES) do
		local tex = Instance.new("Texture")
		tex.Name = TAG
		tex.Face = face
		if HAS_ZINDEX then tex.ZIndex = 10 end -- draw above any decals the game already put on the face
		tex.Parent = part
		rec.tex[#rec.tex + 1] = tex
	end
	refreshRecord(rec)
end

-- runs `action` over every record without freezing the game
local function eachRecord(action)
	local snapshot = list
	task.spawn(function()
		for i = 1, #snapshot do
			action(snapshot[i])
			if i % 250 == 0 then task.wait() end
		end
	end)
end

local function restyle()
	eachRecord(refreshRecord)
end

local function scan(token)
	for i, inst in ipairs(workspace:GetDescendants()) do
		if token ~= scanToken or not CFG.On then return end
		if inst:IsA("BasePart") then
			local rec = recs[inst]
			local first = rec and rec.tex[1]
			if not rec or (first and first.Parent ~= inst) then
				applyPart(inst, rec ~= nil) -- also rebuilds blocks whose textures the game removed
			end
		end
		if i % 150 == 0 then task.wait() end
	end
	setStatus(("%d blocks pixelated"):format(count))
end

local function enable()
	if not SUPPORTED then
		setStatus("This executor can't save files (needs writefile + getcustomasset)")
		return false
	end
	if not tileFor(CFG.Style, 0) then
		setStatus("Couldn't create the pixel tile")
		return false
	end
	CFG.On = true
	scanToken += 1
	local mine = scanToken
	watcher = workspace.DescendantAdded:Connect(function(inst)
		if inst:IsA("BasePart") then task.delay(0.25, applyPart, inst) end
	end)
	setStatus("Pixelating...")
	task.spawn(function()
		scan(mine)
		while scanToken == mine do
			task.wait(RESCAN_EVERY)
			if scanToken == mine and CFG.Auto then scan(mine) end
		end
	end)
	return true
end

local function disable()
	CFG.On = false
	scanToken += 1
	if watcher then
		watcher:Disconnect()
		watcher = nil
	end
	local old = list
	recs, list, count = weakKeys(), {}, 0
	for _, rec in ipairs(old) do restoreLook(rec) end
	task.spawn(function()
		for i, rec in ipairs(old) do
			for _, tex in ipairs(rec.tex) do tex:Destroy() end
			if i % 200 == 0 then task.wait() end
		end
	end)
	setStatus("Off")
end

------------------------------------------------------------------ liquid glass theme
local C = {
	ice = Color3.fromRGB(214, 236, 255),
	sky = Color3.fromRGB(120, 200, 255),
	cyan = Color3.fromRGB(80, 225, 255),
	blue = Color3.fromRGB(50, 130, 255),
	dim = Color3.fromRGB(176, 208, 244),
	red = Color3.fromRGB(255, 110, 130),
}
local WHITE = Color3.new(1, 1, 1)
local AQUA = ColorSequence.new(C.cyan, C.blue)
local DANGER = ColorSequence.new(Color3.fromRGB(255, 150, 160), Color3.fromRGB(225, 60, 95))
local TITLE = ColorSequence.new({
	ColorSequenceKeypoint.new(0, WHITE),
	ColorSequenceKeypoint.new(0.5, C.ice),
	ColorSequenceKeypoint.new(1, C.cyan),
})
local RIM = ColorSequence.new({
	ColorSequenceKeypoint.new(0, WHITE),
	ColorSequenceKeypoint.new(0.5, C.cyan),
	ColorSequenceKeypoint.new(1, WHITE),
})
local RIM_ALPHA = NumberSequence.new({
	NumberSequenceKeypoint.new(0, 0.05),
	NumberSequenceKeypoint.new(0.3, 0.8),
	NumberSequenceKeypoint.new(0.7, 0.8),
	NumberSequenceKeypoint.new(1, 0.05),
})

local connections = {}
local function bind(signal, handler)
	connections[#connections + 1] = signal:Connect(handler)
end

local function create(class, props, parent)
	local obj = Instance.new(class)
	for key, value in pairs(props) do obj[key] = value end
	obj.Parent = parent
	return obj
end

local function corner(obj, radius)
	return create("UICorner", { CornerRadius = UDim.new(0, radius) }, obj)
end

local function tween(obj, seconds, props, style)
	local t = TweenService:Create(obj, TweenInfo.new(seconds, style or Enum.EasingStyle.Quad, Enum.EasingDirection.Out), props)
	t:Play()
	return t
end

-- a soft expanding ring when something is pressed
local function ripple(target)
	local blob = create("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(0, 0),
		BackgroundColor3 = WHITE, BackgroundTransparency = 0.5, ZIndex = 5,
	}, target)
	corner(blob, 100)
	tween(blob, 0.55, { Size = UDim2.fromOffset(170, 170), BackgroundTransparency = 1 }).Completed:Connect(function()
		blob:Destroy()
	end)
end

local function text(parent, props)
	props.BackgroundTransparency = 1
	props.TextColor3 = props.TextColor3 or WHITE
	props.Font = props.Font or Enum.Font.GothamMedium
	props.TextSize = props.TextSize or 13
	props.TextXAlignment = props.TextXAlignment or Enum.TextXAlignment.Left
	return create("TextLabel", props, parent)
end

local function glowImage(parent, color, size, transparency)
	if not GLOW then return nil end
	return create("ImageLabel", {
		Image = GLOW, BackgroundTransparency = 1, ImageColor3 = color, ImageTransparency = transparency,
		AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(size, size),
	}, parent)
end

-- frosted glass surface with a lit edge
local function glass(frame, radius, transparency)
	frame.BackgroundColor3 = WHITE
	frame.BackgroundTransparency = transparency
	corner(frame, radius)
	local edge = create("UIStroke", { Color = WHITE, Thickness = 1, Transparency = 0.3 }, frame)
	create("UIGradient", { Color = RIM, Transparency = RIM_ALPHA, Rotation = 60 }, edge)
	return frame
end

local function isPress(input)
	return input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch
end

-- drag `target` by grabbing `handle`; a press that barely moves counts as a tap
local function makeDraggable(handle, target, onTap)
	local dragging, moved, grab, startPos, startInput = false, false, nil, nil, nil
	bind(handle.InputBegan, function(input)
		if isPress(input) then
			dragging, moved, grab = true, false, input
			startPos, startInput = target.Position, input.Position
		end
	end)
	bind(UserInputService.InputChanged, function(input)
		if dragging and (input == grab or input.UserInputType == Enum.UserInputType.MouseMovement) then
			local delta = input.Position - startInput
			if delta.Magnitude > 6 then moved = true end
			if moved then
				target.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
			end
		end
	end)
	bind(UserInputService.InputEnded, function(input)
		if dragging and (input == grab or input.UserInputType == Enum.UserInputType.MouseButton1) then
			dragging = false
			if onTap and not moved then onTap() end
		end
	end)
end

local order = 0
local function card(page, height)
	order += 1
	return glass(create("Frame", { Size = UDim2.new(1, 0, 0, height), LayoutOrder = order }, page), 12, 0.86)
end

local function knobPosition(on)
	return on and UDim2.new(1, -21, 0.5, 0) or UDim2.new(0, 3, 0.5, 0)
end

local function addToggle(page, title, description, default, onChange)
	local row = card(page, 48)
	text(row, { Text = title, Position = UDim2.new(0, 12, 0, 6), Size = UDim2.new(1, -84, 0, 18), Font = Enum.Font.GothamBold })
	text(row, { Text = description, Position = UDim2.new(0, 12, 0, 25), Size = UDim2.new(1, -84, 0, 16), TextSize = 11, TextColor3 = C.dim })

	local switch = create("TextButton", {
		Text = "", AutoButtonColor = false, AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -12, 0.5, 0),
		Size = UDim2.fromOffset(46, 24), BackgroundColor3 = WHITE, ClipsDescendants = true,
		BackgroundTransparency = default and 0.05 or 0.75,
	}, row)
	corner(switch, 12)
	create("UIGradient", { Color = AQUA }, switch)
	create("UIStroke", { Color = WHITE, Thickness = 1, Transparency = 0.5 }, switch)
	local knob = create("Frame", {
		AnchorPoint = Vector2.new(0, 0.5), Size = UDim2.fromOffset(18, 18), BackgroundColor3 = WHITE,
		Position = knobPosition(default),
	}, switch)
	corner(knob, 9)
	create("UIStroke", { Color = C.sky, Thickness = 1, Transparency = 0.4 }, knob)

	local state = default
	local function render()
		tween(switch, 0.2, { BackgroundTransparency = state and 0.05 or 0.75 })
		tween(knob, 0.25, { Position = knobPosition(state) }, Enum.EasingStyle.Back)
	end
	switch.Activated:Connect(function()
		local wanted = not state
		if onChange(wanted) == false then return end -- refused (for example, unsupported executor)
		state = wanted
		ripple(switch)
		render()
	end)
	return function(value)
		state = value
		render()
	end
end

local function addSlider(page, title, min, max, step, default, format, onCommit)
	local row = card(page, 58)
	text(row, { Text = title, Position = UDim2.new(0, 12, 0, 6), Size = UDim2.new(0.5, 0, 0, 18), Font = Enum.Font.GothamBold })
	local readout = text(row, {
		Text = format(default), Position = UDim2.new(0.5, 0, 0, 6), Size = UDim2.new(0.5, -12, 0, 18),
		TextXAlignment = Enum.TextXAlignment.Right, TextColor3 = C.cyan, Font = Enum.Font.GothamBold,
	})
	local track = create("Frame", { Position = UDim2.new(0, 12, 0, 38), Size = UDim2.new(1, -24, 0, 6), BackgroundColor3 = WHITE, BackgroundTransparency = 0.78 }, row)
	corner(track, 3)
	local fill = create("Frame", { Size = UDim2.fromScale(0, 1), BackgroundColor3 = WHITE }, track)
	corner(fill, 3)
	create("UIGradient", { Color = AQUA }, fill)
	local knob = create("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5), Size = UDim2.fromOffset(18, 18), BackgroundColor3 = WHITE, ZIndex = 2,
	}, track)
	corner(knob, 9)
	create("UIStroke", { Color = C.cyan, Thickness = 2, Transparency = 0.2 }, knob)
	glowImage(knob, C.cyan, 44, 0.55)
	local hitbox = create("TextButton", {
		Text = "", BackgroundTransparency = 1, Position = UDim2.new(0, -10, 0, -14), Size = UDim2.new(1, 20, 0, 34), ZIndex = 3,
	}, track)

	local value = default
	local function setFraction(fraction)
		fraction = math.clamp(fraction, 0, 1)
		value = math.clamp(math.floor((min + (max - min) * fraction) / step + 0.5) * step, min, max)
		local shown = (value - min) / (max - min)
		fill.Size = UDim2.fromScale(shown, 1)
		knob.Position = UDim2.fromScale(shown, 0.5)
		readout.Text = format(value)
	end
	setFraction((default - min) / (max - min))

	local dragging, grab = false, nil
	local function follow(input)
		setFraction((input.Position.X - track.AbsolutePosition.X) / track.AbsoluteSize.X)
	end
	bind(hitbox.InputBegan, function(input)
		if isPress(input) then
			dragging, grab = true, input
			page.ScrollingEnabled = false -- keep the page from scrolling while the slider moves
			follow(input)
		end
	end)
	bind(UserInputService.InputChanged, function(input)
		if dragging and (input == grab or input.UserInputType == Enum.UserInputType.MouseMovement) then
			follow(input)
		end
	end)
	bind(UserInputService.InputEnded, function(input)
		if dragging and (input == grab or input.UserInputType == Enum.UserInputType.MouseButton1) then
			dragging = false
			page.ScrollingEnabled = true
			onCommit(value) -- apply once on release so big maps aren't updated every frame
		end
	end)
	return function(newValue) setFraction((newValue - min) / (max - min)) end
end

local function addChoice(page, title, options, default, onChange, perRow)
	perRow = perRow or 3
	local rows = math.ceil(#options / perRow)
	local row = card(page, 38 + rows * 32)
	text(row, { Text = title, Position = UDim2.new(0, 12, 0, 6), Size = UDim2.new(1, -24, 0, 18), Font = Enum.Font.GothamBold })
	local strip = create("Frame", {
		Position = UDim2.new(0, 12, 0, 32), Size = UDim2.new(1, -24, 0, rows * 32 - 6), BackgroundTransparency = 1,
	}, row)
	create("UIGridLayout", {
		CellPadding = UDim2.fromOffset(6, 6), SortOrder = Enum.SortOrder.LayoutOrder,
		CellSize = UDim2.new(1 / perRow, -math.ceil(6 * (perRow - 1) / perRow), 0, 26),
	}, strip)

	local chips = {}
	local function select(selected)
		for name, chip in pairs(chips) do
			tween(chip, 0.2, { BackgroundTransparency = name == selected and 0.08 or 0.78 })
		end
	end
	for index, name in ipairs(options) do
		local chip = create("TextButton", {
			Text = "", AutoButtonColor = false, LayoutOrder = index, BackgroundColor3 = WHITE, ClipsDescendants = true,
			BackgroundTransparency = name == default and 0.08 or 0.78,
		}, strip)
		corner(chip, 9)
		create("UIGradient", { Color = AQUA, Rotation = 90 }, chip)
		create("UIStroke", { Color = WHITE, Thickness = 1, Transparency = 0.6 }, chip)
		text(chip, {
			Text = name, Size = UDim2.fromScale(1, 1), TextXAlignment = Enum.TextXAlignment.Center,
			Font = Enum.Font.GothamBold, TextSize = 12,
		})
		chip.Activated:Connect(function()
			select(name)
			ripple(chip)
			onChange(name)
		end)
		chips[name] = chip
	end
	return select
end

local function addButton(page, caption, danger, onClick)
	order += 1
	local button = create("TextButton", {
		Text = "", AutoButtonColor = false, Size = UDim2.new(1, 0, 0, 38), LayoutOrder = order,
		BackgroundColor3 = WHITE, BackgroundTransparency = 0.1, ClipsDescendants = true,
	}, page)
	corner(button, 12)
	create("UIGradient", { Color = danger and DANGER or AQUA, Rotation = 90 }, button)
	create("UIStroke", { Color = WHITE, Thickness = 1, Transparency = 0.45 }, button)
	local shine = create("Frame", { Size = UDim2.new(1, -8, 0.45, 0), Position = UDim2.new(0, 4, 0, 3), BackgroundColor3 = WHITE, BackgroundTransparency = 0.78 }, button)
	corner(shine, 9)
	text(button, {
		Text = caption, Size = UDim2.fromScale(1, 1), TextXAlignment = Enum.TextXAlignment.Center,
		Font = Enum.Font.GothamBold, ZIndex = 2,
	})
	button.Activated:Connect(function()
		ripple(button)
		onClick()
	end)
end

------------------------------------------------------------------ window
local gui = create("ScreenGui", { Name = "MimiUI", ResetOnSpawn = false, IgnoreGuiInset = true, DisplayOrder = 999 })
if not pcall(function() gui.Parent = (gethui and gethui()) or game:GetService("CoreGui") end) or not gui.Parent then
	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
end

local blur = create("BlurEffect", { Name = "MimiMenuBlur", Size = 0 }, Lighting)
local isOpen = false
local function updateBlur()
	tween(blur, 0.35, { Size = (isOpen and CFG.Blur) and 14 or 0 })
end

local viewport = workspace.CurrentCamera and workspace.CurrentCamera.ViewportSize or Vector2.new(800, 400)
local WIDTH = math.clamp(viewport.X - 40, 320, 480)
local HEIGHT = math.clamp(viewport.Y - 30, 230, 300)

local shell = create("Frame", {
	Name = "Window", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5),
	Size = UDim2.fromOffset(WIDTH, HEIGHT), BackgroundColor3 = WHITE, ClipsDescendants = true, Visible = false,
}, gui)
corner(shell, 18)
create("UIGradient", {
	Rotation = 55,
	Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(150, 212, 255)),
		ColorSequenceKeypoint.new(0.5, Color3.fromRGB(62, 142, 250)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(22, 70, 190)),
	}),
	Transparency = NumberSequence.new(0.3, 0.5),
}, shell)
local rim = create("UIStroke", { Thickness = 1.5, Color = WHITE }, shell)
local rimGradient = create("UIGradient", { Color = RIM, Transparency = RIM_ALPHA }, rim)

-- slow drifting light inside the glass
local blobs = {}
local function addBlob(x, y, size, color, speed, phase)
	local img = glowImage(shell, color, size, 0.55)
	if img then
		img.Position = UDim2.fromScale(x, y)
		blobs[#blobs + 1] = { img = img, x = x, y = y, speed = speed, phase = phase }
	end
end
addBlob(0.12, 0.1, 280, C.cyan, 0.5, 0)
addBlob(0.92, 0.88, 320, C.ice, 0.35, 2)
addBlob(0.62, 0.28, 220, C.blue, 0.6, 4)

local gloss = create("Frame", { Position = UDim2.new(0, 5, 0, 4), Size = UDim2.new(1, -10, 0.36, 0), BackgroundColor3 = WHITE }, shell)
corner(gloss, 15)
create("UIGradient", { Rotation = 90, Transparency = NumberSequence.new(0.72, 1) }, gloss)

-- header
local header = create("Frame", { Size = UDim2.new(1, 0, 0, 42), BackgroundTransparency = 1, Active = true }, shell)
local title = text(header, {
	Text = NAME, Position = UDim2.new(0, 18, 0, 0), Size = UDim2.new(1, -70, 1, 0),
	Font = Enum.Font.GothamBlack, TextSize = 19,
})
local titleGradient = create("UIGradient", { Color = TITLE }, title)
local closeButton = create("TextButton", {
	Text = "", AutoButtonColor = false, AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -12, 0.5, 0),
	Size = UDim2.fromOffset(26, 26),
}, header)
glass(closeButton, 13, 0.7)
text(closeButton, { Text = "X", Size = UDim2.fromScale(1, 1), TextXAlignment = Enum.TextXAlignment.Center, Font = Enum.Font.GothamBold })

-- sidebar
local TAB_NAMES = { "Home", "Pixels", "Realism", "About" }
local TAB_STEP = 38
local side = glass(create("Frame", { Position = UDim2.new(0, 10, 0, 46), Size = UDim2.new(0, 92, 1, -56) }, shell), 14, 0.84)
local pill = create("Frame", {
	Position = UDim2.new(0, 6, 0, 8), Size = UDim2.new(1, -12, 0, 32), BackgroundColor3 = WHITE, BackgroundTransparency = 0.05,
}, side)
corner(pill, 10)
create("UIGradient", { Color = AQUA, Rotation = 20 }, pill)
create("UIStroke", { Color = WHITE, Thickness = 1, Transparency = 0.35 }, pill)
glowImage(pill, C.cyan, 90, 0.6)

-- pages
local body = create("Frame", { Position = UDim2.new(0, 112, 0, 46), Size = UDim2.new(1, -122, 1, -56), BackgroundTransparency = 1 }, shell)
local function newPage()
	local page = create("ScrollingFrame", {
		Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, BorderSizePixel = 0, Visible = false,
		ScrollBarThickness = 3, ScrollBarImageColor3 = C.cyan, CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y, ScrollingDirection = Enum.ScrollingDirection.Y,
	}, body)
	create("UIListLayout", { Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder }, page)
	create("UIPadding", { PaddingRight = UDim.new(0, 6), PaddingBottom = UDim.new(0, 6) }, page)
	return page
end
local home, pixels, realism, about = newPage(), newPage(), newPage(), newPage()

local function unload()
	disable()
	restoreRealism()
	for _, connection in ipairs(connections) do connection:Disconnect() end
	blur:Destroy()
	gui:Destroy()
	env.MimiStop = nil
end

local function percent(v) return ("%d%%"):format(math.floor(v * 100 + 0.5)) end

-- Home
addToggle(home, "Pixelate Blocks", "Turns every map block into pixels", false, function(on)
	if on then return enable() end
	disable()
end)
addToggle(home, "Flat Materials", "Hides material shine so pixels pop", false, function(on)
	CFG.Flat = on
	restyle()
end)
addToggle(home, "Auto Rescan", "Re-checks the map every few seconds", true, function(on)
	CFG.Auto = on
end)
addToggle(home, "Glass Blur", "Blurs the game behind the menu", true, function(on)
	CFG.Blur = on
	updateBlur()
end)
addButton(home, "Rescan Now", false, function()
	if CFG.On then task.spawn(scan, scanToken) end
end)
statusLabel = text(card(home, 40), {
	Text = "Off", Position = UDim2.new(0, 12, 0, 0), Size = UDim2.new(1, -24, 1, 0),
	TextWrapped = true, TextSize = 12, TextColor3 = C.dim,
})

-- Pixels
addSlider(pixels, "Pixel Size", 0.125, 3, 0.125, CFG.PixelSize, function(v)
	return ("%g studs"):format(v)
end, function(v)
	CFG.PixelSize = v
	restyle()
end)
addSlider(pixels, "Strength", 0.2, 1, 0.05, CFG.Strength, percent, function(v)
	CFG.Strength = v
	restyle()
end)
addToggle(pixels, "Break Repetition", "Shifts each block's pixel grid", true, function(on)
	CFG.Shuffle = on
	restyle()
end)
addChoice(pixels, "Style", STYLES, CFG.Style, function(name)
	CFG.Style = name
	restyle()
end)

-- Realism
local resetters = {}
resetters.Reflection = addChoice(realism, "Reflection", REFLECTION_NAMES, CFG.Reflection, function(name)
	CFG.Reflection = name
	restyle()
end)
resetters.EnvSpec = addSlider(realism, "Sky Reflection", 0, 1, 0.05, CFG.EnvSpec, percent, function(v)
	CFG.EnvSpec = v
	applyRealism()
end)
resetters.Variation = addSlider(realism, "Color Variation", 0, 0.2, 0.02, CFG.Variation, percent, function(v)
	CFG.Variation = v
	restyle()
end)
resetters.Bloom = addSlider(realism, "Bloom", 0, 1.5, 0.1, CFG.Bloom, function(v)
	return ("%.1f"):format(v)
end, function(v)
	CFG.Bloom = v
	applyRealism()
end)
resetters.Rays = addSlider(realism, "Sun Rays", 0, 0.5, 0.05, CFG.Rays, function(v)
	return ("%.2f"):format(v)
end, function(v)
	CFG.Rays = v
	applyRealism()
end)
resetters.Haze = addSlider(realism, "Depth Haze", 0, 1, 0.1, CFG.Haze, percent, function(v)
	CFG.Haze = v
	applyRealism()
end)
resetters.Exposure = addSlider(realism, "Exposure", -1, 1, 0.1, CFG.Exposure, function(v)
	return ("%+.1f"):format(v)
end, function(v)
	CFG.Exposure = v
	applyRealism()
end)
resetters.Grade = addChoice(realism, "Color Grade", GRADE_NAMES, CFG.Grade, function(name)
	CFG.Grade = name
	applyRealism()
end)
resetters.Dof = addToggle(realism, "Depth Blur", "Soft focus on distant blocks", false, function(on)
	CFG.Dof = on
	applyRealism()
end)
resetters.Shadows = addToggle(realism, "Soft Shadows", "Smoother, richer shadows", false, function(on)
	CFG.Shadows = on
	applyRealism()
end)
addButton(realism, "Reset Realism", false, function()
	for key, value in pairs(REALISM_DEFAULTS) do CFG[key] = value end
	for key, setter in pairs(resetters) do setter(CFG[key]) end
	restyle()
	applyRealism()
end)

-- About
local info = card(about, 124)
text(info, { Text = NAME, Position = UDim2.new(0, 12, 0, 8), Size = UDim2.new(1, -24, 0, 20), Font = Enum.Font.GothamBlack, TextSize = 15 })
text(info, {
	Text = "Pixel texture pack for every block.\nPlayers and NPCs are never touched.\nRoblox terrain can't hold textures.\nMenu key: RightShift",
	Position = UDim2.new(0, 12, 0, 34), Size = UDim2.new(1, -24, 0, 80), TextWrapped = true,
	TextYAlignment = Enum.TextYAlignment.Top, TextSize = 12, TextColor3 = C.dim,
})
addButton(about, "Unload Mimi", true, unload)

-- tabs
local pageOf = { Home = home, Pixels = pixels, Realism = realism, About = about }
local tabButtons, currentTab = {}, nil
local function selectTab(name)
	if name == currentTab then return end
	currentTab = name
	for tabName, page in pairs(pageOf) do page.Visible = tabName == name end
	tween(pill, 0.3, { Position = UDim2.new(0, 6, 0, 8 + (table.find(TAB_NAMES, name) - 1) * TAB_STEP) }, Enum.EasingStyle.Back)
	for tabName, button in pairs(tabButtons) do
		tween(button, 0.2, { TextColor3 = tabName == name and WHITE or C.dim })
	end
	local page = pageOf[name]
	page.Position = UDim2.fromOffset(16, 0)
	tween(page, 0.25, { Position = UDim2.new() })
end
for index, name in ipairs(TAB_NAMES) do
	local button = create("TextButton", {
		Text = name, BackgroundTransparency = 1, AutoButtonColor = false, ZIndex = 2,
		Position = UDim2.new(0, 6, 0, 8 + (index - 1) * TAB_STEP), Size = UDim2.new(1, -12, 0, 32),
		Font = Enum.Font.GothamBold, TextSize = 13, TextColor3 = C.dim,
	}, side)
	button.Activated:Connect(function() selectTab(name) end)
	tabButtons[name] = button
end
selectTab("Home")

-- open / close
local fullSize = UDim2.fromOffset(WIDTH, HEIGHT)
local smallSize = UDim2.fromOffset(WIDTH * 0.92, HEIGHT * 0.92)
local function setOpen(open)
	isOpen = open
	updateBlur()
	if open then
		shell.Visible = true
		shell.BackgroundTransparency = 1
		rim.Transparency = 1
		shell.Size = smallSize
		tween(shell, 0.35, { Size = fullSize }, Enum.EasingStyle.Back)
		tween(shell, 0.25, { BackgroundTransparency = 0 })
		tween(rim, 0.25, { Transparency = 0 })
	else
		tween(shell, 0.2, { Size = smallSize, BackgroundTransparency = 1 })
		tween(rim, 0.2, { Transparency = 1 }).Completed:Connect(function()
			if not isOpen then shell.Visible = false end
		end)
	end
end
closeButton.Activated:Connect(function() setOpen(false) end)
makeDraggable(header, shell)

-- glowing glass orb that opens the menu (movable)
local orb = create("TextButton", {
	Name = "Opener", Text = "", AutoButtonColor = false, Size = UDim2.fromOffset(50, 50),
	Position = UDim2.new(0, 14, 0.42, 0), BackgroundColor3 = WHITE, BackgroundTransparency = 0.08,
}, gui)
corner(orb, 25)
local orbGradient = create("UIGradient", { Color = AQUA, Rotation = 45 }, orb)
local orbRim = create("UIStroke", { Color = WHITE, Thickness = 2 }, orb)
local orbRimGradient = create("UIGradient", { Color = RIM, Transparency = RIM_ALPHA }, orbRim)
local orbGlow = glowImage(orb, C.cyan, 96, 0.5)
local orbShine = create("Frame", {
	Position = UDim2.fromScale(0.16, 0.07), Size = UDim2.fromScale(0.68, 0.4), BackgroundColor3 = WHITE, BackgroundTransparency = 0.6,
}, orb)
corner(orbShine, 20)
text(orb, {
	Text = "M", Size = UDim2.fromScale(1, 1), TextXAlignment = Enum.TextXAlignment.Center,
	Font = Enum.Font.GothamBlack, TextSize = 22, ZIndex = 2,
})
if orbGlow then
	TweenService:Create(
		orbGlow,
		TweenInfo.new(1.6, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
		{ ImageTransparency = 0.8 }
	):Play()
end
makeDraggable(orb, orb, function() setOpen(not isOpen) end)

bind(UserInputService.InputBegan, function(input, processed)
	if not processed and input.KeyCode == Enum.KeyCode.RightShift then setOpen(not isOpen) end
end)

-- animated glass: moving rim light, drifting glow, title shimmer
bind(RunService.Heartbeat, function()
	local now = os.clock()
	orbGradient.Rotation = 45 + math.sin(now * 1.2) * 25
	orbRimGradient.Rotation = (now * 90) % 360
	if shell.Visible then
		rimGradient.Rotation = (now * 50) % 360
		titleGradient.Offset = Vector2.new(math.sin(now * 1.6) * 0.35, 0)
		for _, blob in ipairs(blobs) do
			blob.img.Position = UDim2.new(
				blob.x, math.sin(now * blob.speed + blob.phase) * 40,
				blob.y, math.cos(now * blob.speed * 0.8 + blob.phase) * 30
			)
		end
	end
end)

env.MimiStop = unload
