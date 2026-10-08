-- discord: bottlenecks roblox: Xx_MoonshadeVoidwalk
-- Connected Discord-GitHub
--!strict
--!native

-- mechspider is one (server-side) script that singlehandedly builds, animates n runs a six legged hunter mech
-- only outside assets are 3 meshes w/ 3 textures, if they dont load it falls back to plain parts
-- order: config, helpers, spider class (sense > navigate > steer > pose > legs > attack), audio listeners, spawning and main loop
-- here we go!!

local players = game:GetService("Players")
local runservice = game:GetService("RunService")
local pathfindingservice = game:GetService("PathfindingService")
local collectionservice = game:GetService("CollectionService")
local tweenservice = game:GetService("TweenService")
local assetservice = game:GetService("AssetService")
local workspace = game:GetService("Workspace")

-- frozen so nothing can overwrite a value mid game
local config = table.freeze({
	spawntag = "mechspider", -- tag a part with this n a spider spawns on it
	upperlength = 4.3, -- hip to knee, measured off the mesh
	lowerlength = 12.7, -- knee to foot tip
	bodyheight = 7.3, -- body center above the average foot
	walkspeed = 9,
	huntspeed = 18,
	acceleration = 4,
	turnrate = 3.5, -- slow enough that the legs keep up on a full turn
	stepdistance = 4.5, -- how far a foot drifts from its rest spot before it lifts
	steptime = 0.22,
	stepheight = 3.5,
	anticipation = 0.25, -- seconds of velocity feet aim ahead by
	probe = 14, -- half length of ground raycasts
	sightrange = 90,
	fovcos = math.cos(math.rad(70)), -- cos so i can compare dot products instead of doing acos every frame
	losetime = 15,
	wanderradius = 60,
	waypointreach = 4,
	repathtime = 0.75,
	attackrange = 16,
	attackcooldown = 4,
	strikedelay = 0.6, -- lines up with the foot landing
	strikeradius = 6,
	damage = 25,
	knockback = 45,
	launchtime = 0.25,
	slide = PhysicalProperties.new(0.7, 0.05, 0.2), -- low friction so a ragdoll actually slides you
	launchforce = 100000,
	ragdolltime = 1.8,
	grace = 1.2, -- time after getting up before u can be hit again
	maxspiders = 1,
	lungespeed = 10,
	standoff = 0.7, -- stops at this fraction of attack range so it swings at u instead of standing on u
	spacing = 26,
	swingtime = 1.1,
	swingheight = 9,
	bodyradius = 2.5,
	lookahead = 1.5,
	detour = 1, -- seconds it trusts the navmesh after bumping a wall
})

-- extent undoes whatever unit scaling the fbx import did, fallback is the part size if the mesh fails
local meshes = table.freeze({
	body = {
		mesh = 109332668108188,
		texture = 71308697227007,
		extent = Vector3.new(8.16, 7.66, 11.8),
		fallback = Vector3.new(4.9, 2, 6),
	},
	upper = {
		mesh = 90557837242320,
		texture = 90879539856058,
		extent = Vector3.new(1.63, 1.87, 5.95),
		fallback = Vector3.new(0.7, 0.7, 4.3),
	},
	lower = {
		mesh = 136484331153150,
		texture = 114841189184226,
		extent = Vector3.new(3.01, 1.11, 13.1),
		fallback = Vector3.new(0.45, 0.45, 12.7),
	},
})

-- right side legs front to back in body space, left side is the same mirrored on x
local layout = table.freeze({
	{ hip = Vector3.new(1.27, 1.09, -3.47), rest = Vector3.new(9.5, -config.bodyheight, -10) },
	{ hip = Vector3.new(3, 1.09, 0), rest = Vector3.new(12.5, -config.bodyheight, 0) },
	{ hip = Vector3.new(1.27, 1.09, 3.47), rest = Vector3.new(9.5, -config.bodyheight, 9.5) },
})

local flatmask = Vector3.new(1, 0, 1) -- zeroes y
local hullflip = CFrame.Angles(0, math.pi, 0) -- hull mesh faces +z, the rig walks down -z
local eyeoffset = CFrame.new(1.46, -1.58, 5.82)
local beaconoffset = CFrame.new(0, 4.5, -1.5) -- antenna tip (added after on the model, i cba to make it in the actual model)
local legcolor = Color3.fromRGB(70, 72, 78)
local idlecolor = Color3.fromRGB(80, 255, 120)
local huntcolor = Color3.fromRGB(255, 60, 60)
local flashinfo = TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local rng = Random.new()

-- one RaycastParams reused for every ground check
local groundparams = RaycastParams.new()
groundparams.RespectCanCollide = true -- dont step on cancollide false decor
groundparams.IgnoreWater = true

-- CanQuery false on every spider part means my raycasts never hit the spider, no exclude list needed
local function configure(part: BasePart, name: string)
	part.Name = name
	part.Anchored = true -- moved by cframe every frame, physics never touches it
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
end

local function makepart(name: string, size: Vector3, color: Color3): Part
	local part = Instance.new("Part")
	part.Size = size
	part.Color = color
	part.Material = Enum.Material.Metal
	configure(part, name)
	return part
end

type meshinfo = { mesh: number, texture: number, extent: Vector3, fallback: Vector3 }

-- MeshId is read only so CreateMeshPartAsync is how u build one from an id, pcall cause a bad id throws
local function maketemplate(name: string, info: meshinfo): BasePart
	local options = { CollisionFidelity = Enum.CollisionFidelity.Box }
	local ok, part = pcall(assetservice.CreateMeshPartAsync, assetservice, Content.fromAssetId(info.mesh), options)
	if not ok then
		return makepart(name, info.fallback, legcolor)
	end
	part.TextureID = "rbxassetid://" .. info.texture
	part.Color = Color3.new(1, 1, 1) -- white so the texture isnt tinted
	part.Material = Enum.Material.SmoothPlastic
	part.Size = part.Size * (info.extent.Z / part.Size.Z) -- uniform rescale, keeps proportions
	configure(part, name)
	return part
end

local function clone(template: BasePart, parent: Instance): BasePart
	local part = template:Clone()
	part.Parent = parent
	return part
end

-- new audio api: AudioPlayer > Wire > AudioEmitter, the emitter plays it from the body
local function makeaudio(asset: string, volume: number, emitter: AudioEmitter): AudioPlayer
	local audio = Instance.new("AudioPlayer")
	audio.Asset = asset
	audio.Volume = volume
	audio.Parent = emitter.Parent
	local wire = Instance.new("Wire")
	wire.SourceInstance = audio
	wire.TargetInstance = emitter
	wire.Parent = audio
	return audio
end

-- Play() resumes from TimePosition so we have to reset it or a finished clip stays silent
local function oneshot(audio: AudioPlayer, speed: number)
	audio.PlaybackSpeed = speed -- random pitch so footsteps dont sound like the exact same every single time and drive me mad
	audio.TimePosition = 0
	audio:Play()
end

-- root + humanoid if the character is alive, nil otherwise. one check for every caller instead of nesting a bazilinion times
local function living(character: Model?): (BasePart?, Humanoid?)
	if not character then
		return nil, nil
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local root = character.PrimaryPart
	if not humanoid or not root or humanoid.Health <= 0 then
		return nil, nil
	end
	return root, humanoid
end

-- puts a bone between two points, hint is the bend plane normal so its never parallel to the bone. that would look weird
local function placebone(part: BasePart, from: Vector3, to: Vector3, hint: Vector3)
	part.CFrame = CFrame.lookAlong(from:Lerp(to, 0.5), to - from, hint)
end

local function groundunder(point: Vector3, up: Vector3): Vector3
	local hit = workspace:Raycast(point + up * config.probe, -up * config.probe * 2, groundparams)
	return if hit then hit.Position else point
end

-- eases in n out, no snapping at either end
local function smoothstep(t: number): number
	t = math.clamp(t, 0, 1)
	return t * t * (3 - 2 * t)
end

-- frame rate independent lerp factor, a flat lerp(0.1) would move faster on higher fps
local function smoothing(dt: number, rate: number): number
	return 1 - math.exp(-dt * rate)
end

-- loaded once, every spider clones these
local templates = {
	body = maketemplate("body", meshes.body),
	upper = maketemplate("upper", meshes.upper),
	lower = maketemplate("lower", meshes.lower),
}

type leg = {
	hip: Vector3,
	rest: Vector3,
	group: number, -- tripod group, 0 or 1
	foot: Vector3, -- worldspace
	from: Vector3,
	to: Vector3,
	progress: number, -- 0..1 through a step, 1 = planted
	upper: BasePart,
	lower: BasePart,
}

type fields = {
	model: Model,
	body: BasePart,
	eye: Part,
	beacon: Part,
	light: PointLight,
	highlight: Highlight,
	legs: { leg },
	lastgroup: number,
	origin: Vector3,
	position: Vector3,
	ground: Vector3,
	velocity: Vector3,
	forward: Vector3,
	up: Vector3,
	cframe: CFrame,
	state: string,
	target: Model?,
	visible: boolean,
	lastseen: number,
	lastknown: Vector3,
	path: Path,
	waypoints: { PathWaypoint },
	waypointindex: number,
	pathing: boolean, -- a ComputeAsync is running so we dont stack another
	nextpath: number,
	lastattack: number,
	blockedat: number,
	attackleg: leg?,
	attackstart: number,
	stepaudio: AudioPlayer,
	lungeaudio: AudioPlayer,
	hitaudio: AudioPlayer,
}

-- metatable class, typeof(setmetatable()) gives strict mode the instance type
local spider = {}
spider.__index = spider
type spider = typeof(setmetatable({} :: fields, spider))

local spiders: { spider } = {}

function spider.new(origin: Vector3): spider
	local model = Instance.new("Model")
	model.Name = "mechspider"
	local body = clone(templates.body, model)
	local eye = makepart("eye", Vector3.new(0.7, 0.7, 0.7), idlecolor)
	eye.Shape = Enum.PartType.Ball
	eye.Material = Enum.Material.Neon
	eye.Parent = model
	local beacon = makepart("beacon", Vector3.new(1.1, 1.1, 1.1), idlecolor)
	beacon.Shape = Enum.PartType.Ball
	beacon.Material = Enum.Material.Neon
	beacon.Parent = model
	local light = Instance.new("PointLight") -- neon alone doesnt light anything around it because roblox doesn't know what neon is apparently
	light.Color = idlecolor
	light.Brightness = 0.7
	light.Range = 18
	light.Parent = beacon
	model.PrimaryPart = body

	local highlight = Instance.new("Highlight")
	highlight.FillColor = huntcolor
	highlight.FillTransparency = 1 -- hidden until an attack flashes it
	highlight.OutlineTransparency = 1
	highlight.DepthMode = Enum.HighlightDepthMode.Occluded -- no flash thru walls
	highlight.Parent = model

	local emitter = Instance.new("AudioEmitter")
	emitter.DistanceAttenuationMode = Enum.DistanceAttenuationMode.InverseTapered
	emitter.DistanceAttenuationBounds = NumberRange.new(8, 160)
	emitter.Parent = body
	local stepaudio = makeaudio("rbxasset://sounds/action_footsteps_plastic.mp3", 0.6, emitter)
	stepaudio.PlaybackRegion = NumberRange.new(0, 0.28) -- just one footfall out of the clip

	-- feet spawn raised so the first frame steps them down onto the floor
	local legs: { leg } = {}
	for sideindex, side in { -1, 1 } do
		local mirror = Vector3.new(side, 1, 1)
		for index, slot in layout do
			local rest = slot.rest * mirror
			local start = origin + rest + Vector3.yAxis * config.stepdistance
			table.insert(legs, {
				hip = slot.hip * mirror,
				rest = rest,
				group = (index + sideindex) % 2, -- alternating groups = tripod gait and everyone is happy
				foot = start,
				from = start,
				to = start,
				progress = 1,
				upper = clone(templates.upper, model),
				lower = clone(templates.lower, model),
			})
		end
	end

	-- agent sized to the hull, a wider one got NoPath on ramps
	local path = pathfindingservice:CreatePath({ AgentRadius = 4, AgentHeight = 12, AgentCanJump = false, WaypointSpacing = 6 })

	local self = setmetatable({
		model = model,
		body = body,
		eye = eye,
		beacon = beacon,
		light = light,
		highlight = highlight,
		legs = legs,
		lastgroup = 1,
		origin = origin,
		position = origin,
		ground = origin - Vector3.yAxis * config.bodyheight,
		velocity = Vector3.zero,
		forward = -Vector3.zAxis,
		up = Vector3.yAxis,
		cframe = CFrame.new(origin),
		state = "wander",
		target = nil,
		visible = false,
		lastseen = 0,
		lastknown = origin,
		path = path,
		waypoints = {},
		waypointindex = 1,
		pathing = false,
		nextpath = 0,
		lastattack = 0,
		blockedat = 0,
		attackleg = nil,
		attackstart = 0,
		stepaudio = stepaudio,
		lungeaudio = makeaudio("rbxasset://sounds/action_jump.mp3", 0.8, emitter),
		hitaudio = makeaudio("rbxasset://sounds/impact_explosion_03.mp3", 0.5, emitter),
	} :: fields, spider)

	model:SetAttribute("state", "wander") -- shows in properties so u can watch the ai
	model.Parent = workspace
	return self
end

-- switches between wander n hunt, everything that depends on the state gets updated in this one spot
function spider.setstate(self: spider, state: string)
	if self.state == state then
		return
	end
	self.state = state
	self.model:SetAttribute("state", state)
	local color = if state == "hunt" then huntcolor else idlecolor
	self.eye.Color = color
	self.beacon.Color = color
	self.light.Color = color
	table.clear(self.waypoints) -- old path was for the old state, clear keeps the same table so nothing new gets allocated
end

-- spider parts are CanQuery false so the ray only stops on walls or the target
function spider.cansee(self: spider, root: BasePart): boolean
	local from = self.eye.Position
	local hit = workspace:Raycast(from, root.Position - from)
	return hit ~= nil and hit.Instance:IsDescendantOf(root.Parent :: Instance)
end

-- closest visible player, vision cone while wandering, 360 once hunting. this spider is megabuffed since in a normal game it would be imo miniboss level ATLEAST
function spider.sense(self: spider, now: number)
	local best: Model? = nil
	local bestroot: BasePart? = nil
	local bestdistance = config.sightrange
	for _, player in players:GetPlayers() do
		local root = living(player.Character)
		if not root then
			continue
		end
		local offset = root.Position - self.position
		local distance = offset.Magnitude
		if distance > bestdistance then
			continue -- skips the raycast
		end
		if self.state == "wander" and self.forward:Dot(offset.Unit) < config.fovcos then
			continue
		end
		if not self:cansee(root) then
			continue
		end
		best, bestroot, bestdistance = player.Character, root, distance
	end

	if self.visible and not bestroot then
		self.nextpath = 0 -- just lost sight, path right away
	end
	self.visible = bestroot ~= nil
	if best and bestroot then
		self.target = best
		self.lastseen = now
		self.lastknown = bestroot.Position
		self:setstate("hunt")
		return
	end
	if self.state == "hunt" and now - self.lastseen > config.losetime then
		self.target = nil
		self:setstate("wander")
	end
end

-- ComputeAsync yields so it gets its own thread
function spider.requestpath(self: spider, goal: Vector3)
	self.pathing = true
	task.spawn(function()
		local ok = pcall(self.path.ComputeAsync, self.path, self.ground, goal)
		local found = ok and self.path.Status == Enum.PathStatus.Success
		self.waypoints = if found then self.path:GetWaypoints() else {}
		self.waypointindex = 2 -- 1 is where it already stands
		self.pathing = false
	end)
end

function spider.nextwaypoint(self: spider): Vector3?
	while true do
		local waypoint = self.waypoints[self.waypointindex]
		if not waypoint then
			return nil
		end
		local flat = (waypoint.Position - self.ground) * flatmask
		if flat.Magnitude > config.waypointreach then
			return waypoint.Position
		end
		self.waypointindex += 1
	end
end

-- straight at u when it can see u, navmesh when it cant, random roaming otherwise
function spider.navigate(self: spider, now: number): Vector3?
	if self.state == "hunt" then
		local root = living(self.target)
		if root and self.visible and now - self.blockedat > config.detour then
			table.clear(self.waypoints)
			return root.Position
		end
		local goal = if root then root.Position else self.lastknown
		if not self.pathing and now >= self.nextpath then
			self.nextpath = now + config.repathtime
			self:requestpath(goal)
		end
		return self:nextwaypoint() or goal -- no path = head straight, the wall cast slides it
	end

	local point = self:nextwaypoint()
	if point or self.pathing or now < self.nextpath then
		return point
	end
	local spread = rng:NextUnitVector() * flatmask
	self.nextpath = now + rng:NextNumber(1.5, 4) -- little pause between roams
	self:requestpath(self.origin + spread * rng:NextNumber(10, config.wanderradius))
	return nil
end

function spider.steer(self: spider, goal: Vector3?, dt: number, now: number)
	local hunting = self.state == "hunt"
	local speed = if hunting then config.huntspeed else config.walkspeed
	local wish = Vector3.zero
	if goal then
		local flat = (goal - self.position) * flatmask
		-- standoff only when chasing u directly, on waypoints it would count every one as reached n freeze
		local chasing = hunting and self.visible and #self.waypoints == 0
		local stop = if chasing then config.attackrange * config.standoff else 1
		wish = if flat.Magnitude > stop then flat.Unit * speed else wish
	end
	for _, other in spiders do
		local gap = (self.position - other.position) * flatmask
		local distance = gap.Magnitude
		if rawequal(other, self) or distance >= config.spacing or distance < 0.01 then
			continue
		end
		wish += gap.Unit * speed * (1 - distance / config.spacing) -- pushes harder the closer they are
	end
	self.velocity = self.velocity:Lerp(wish, smoothing(dt, config.acceleration))

	-- body is anchored so nothing stops it, this sphere cast is the wall check. upward normals are floors n ramps
	local moving = self.velocity.Magnitude
	if moving > 0.05 then
		local sweep = self.velocity * (dt + config.lookahead / moving)
		local wall = workspace:Spherecast(self.position, config.bodyradius, sweep, groundparams)
		if wall and wall.Normal.Y < 0.5 then
			local normal = (wall.Normal * flatmask).Unit
			self.velocity -= normal * math.min(self.velocity:Dot(normal), 0) -- cut the part going into the wall, keep the slide
			self.blockedat = now
		end
	end

	local ahead = self.position + self.velocity * dt
	local hit = workspace:Raycast(ahead + Vector3.yAxis * config.probe, -Vector3.yAxis * config.probe * 2, groundparams)
	if not hit then
		self.velocity = Vector3.zero -- edge, dont walk off
		return
	end
	self.position = ahead
	self.ground = hit.Position

	local pace = self.velocity.Magnitude
	if pace > 1 then
		self.forward = self.forward:Lerp(self.velocity / pace, smoothing(dt, config.turnrate)).Unit
	end
end

-- height from the average foot, tilt from the plane the feet make
function spider.pose(self: spider, dt: number)
	local legs = self.legs
	local sum = Vector3.zero
	for _, leg in legs do
		sum += leg.foot
	end
	local center = sum / #legs

	-- legs go left front/mid/back then right front/mid/back
	local across = legs[5].foot - legs[2].foot
	local along = (legs[3].foot + legs[6].foot) - (legs[1].foot + legs[4].foot)
	local normal = along:Cross(across).Unit
	normal = if normal:Dot(self.up) < 0 then -normal else normal -- mid turn it can flip, put it back
	local targetup = (normal + Vector3.yAxis).Unit -- biased to world up so it tilts but never flips
	self.up = self.up:Lerp(targetup, smoothing(dt, 5)).Unit

	local height = math.lerp(self.position.Y, center.Y + config.bodyheight, smoothing(dt, 6))
	self.position = Vector3.new(self.position.X, height, self.position.Z)

	local forward = (self.forward - self.up * self.forward:Dot(self.up)).Unit -- keeps look n up perpendicular
	self.cframe = CFrame.lookAlong(self.position, forward, self.up)
	self.body.CFrame = self.cframe * hullflip
	self.eye.CFrame = self.cframe * eyeoffset
	self.beacon.CFrame = self.cframe * beaconoffset
end

-- tripod gait, two groups of three take turns so it always stands on three feet
function spider.steplegs(self: spider, dt: number)
	local busy = { false, false }
	local wants = { false, false }
	local landed = false
	local steptime = config.steptime / math.max(1, self.velocity.Magnitude / config.walkspeed) -- faster body, faster steps
	local lead = self.velocity * config.anticipation
	lead = if lead.Magnitude > config.stepdistance then lead.Unit * config.stepdistance else lead

	for _, leg in self.legs do
		if leg == self.attackleg then
			continue
		end
		if leg.progress < 1 then
			busy[leg.group + 1] = true
			leg.progress = math.min(leg.progress + dt / steptime, 1)
			local arc = math.sin(leg.progress * math.pi) * config.stepheight -- 0 at both ends, peak mid step
			leg.foot = leg.from:Lerp(leg.to, leg.progress) + self.up * arc
			landed = landed or leg.progress == 1
			continue
		end
		local anchor = self.cframe * leg.rest + lead
		leg.to = groundunder(anchor, self.up)
		wants[leg.group + 1] = wants[leg.group + 1] or (leg.to - leg.foot).Magnitude >= config.stepdistance
	end

	-- whichever group didnt step last goes first, otherwise group 0 wins every tie n group 1 drags, and the spider would be limp and stupid
	for offset = 1, 2 do
		local group = (self.lastgroup + offset) % 2
		if not wants[group + 1] or busy[1] or busy[2] then
			continue
		end
		for _, leg in self.legs do
			if leg.group == group and leg ~= self.attackleg then
				leg.from, leg.progress = leg.foot, 0
			end
		end
		busy[group + 1] = true
		self.lastgroup = group
	end

	if landed then
		oneshot(self.stepaudio, rng:NextNumber(0.55, 0.75)) -- pitched down so it sounds heavy
	end
end

-- two bone ik, law of cosines gives the hip angle, rotate toward the pole to get the knee
function spider.solvelegs(self: spider)
	local upper, lower = config.upperlength, config.lowerlength
	for _, leg in self.legs do
		local hip = self.cframe * leg.hip
		local reach = leg.foot - hip
		local direction = reach.Unit
		local distance = math.clamp(reach.Magnitude, 0.1, upper + lower - 0.05) -- past full stretch acos gives nan
		local foot = hip + direction * distance
		local cosine = (upper * upper + distance * distance - lower * lower) / (2 * upper * distance)
		local hipangle = math.acos(math.clamp(cosine, -1, 1))
		local pole = (self.up * 2 + (hip - self.position)).Unit -- knees bend up n out
		local axis = direction:Cross(pole).Unit
		local knee = hip + CFrame.fromAxisAngle(axis, hipangle) * direction * upper
		placebone(leg.upper, hip, knee, axis)
		placebone(leg.lower, knee, foot, axis)
	end
end

-- attack leg: wind up, slam, hold, pull back. ik turns the foot path into the leg motion
function spider.swing(self: spider, now: number)
	local leg = self.attackleg
	if not leg then
		return
	end
	local phase = (now - self.attackstart) / config.swingtime
	if phase >= 1 then
		self.attackleg = nil -- back to the gait
		return
	end
	local hip = self.cframe * leg.hip
	local root = living(self.target)
	local impact = if root then root.Position else self.position + self.forward * config.attackrange * config.standoff
	local raised = hip + self.up * config.swingheight + self.forward * 3
	if phase < 0.42 then
		leg.foot = leg.from:Lerp(raised, smoothstep(phase / 0.42))
	elseif phase < 0.55 then
		local t = (phase - 0.42) / 0.13
		leg.foot = raised:Lerp(impact, t * t) -- speeds up into the hit
	elseif phase < 0.7 then
		leg.foot = impact
	else
		local home = groundunder(self.cframe * leg.rest, self.up)
		leg.foot = impact:Lerp(home, smoothstep((phase - 0.7) / 0.3))
	end
end

-- ragdoll from the server. the player owns their physics so ChangeState gets overruled,
-- EvaluateStateMachine replicates tho. new rigs use AnimationConstraints with ball sockets already in, old Motor6D rigs get sockets built
local function ragdoll(character: Model, humanoid: Humanoid, root: BasePart)
	if character:GetAttribute("ragdolled") then
		return
	end
	character:SetAttribute("ragdolled", true)
	humanoid.RequiresNeck = false -- otherwise a disabled neck kills u
	local animated: { AnimationConstraint } = {}
	local motors: { Motor6D } = {}
	local extras: { Instance } = {}
	local limbs: { BasePart } = {}
	for _, joint in character:GetDescendants() do
		-- root joint stays on, cutting it sends the root n the camera off without the body
		if joint:IsA("AnimationConstraint") then
			local a0, a1 = joint.Attachment0, joint.Attachment1
			if not a0 or not a1 or a0.Parent == root or a1.Parent == root then
				continue
			end
			joint.Enabled = false
			table.insert(animated, joint)
		elseif joint:IsA("Motor6D") and joint.Part0 and joint.Part1 then
			if joint.Part0 == root or joint.Part1 == root then
				continue
			end
			local a0 = Instance.new("Attachment")
			a0.CFrame = joint.C0
			a0.Parent = joint.Part0
			local a1 = Instance.new("Attachment")
			a1.CFrame = joint.C1
			a1.Parent = joint.Part1
			local socket = Instance.new("BallSocketConstraint")
			socket.Attachment0 = a0
			socket.Attachment1 = a1
			socket.LimitsEnabled = true
			socket.TwistLimitsEnabled = true
			socket.Parent = joint.Part0
			joint.Enabled = false
			table.insert(motors, joint)
			table.insert(extras, a0)
			table.insert(extras, a1)
			table.insert(extras, socket)
		end
	end
	local slick: { BasePart } = {}
	for _, part in character:GetChildren() do
		if not part:IsA("BasePart") then
			continue
		end
		if part ~= root and not part.CanCollide then
			part.CanCollide = true -- or it sinks thru the floor
			table.insert(limbs, part)
		end
		if not part.CustomPhysicalProperties then
			part.CustomPhysicalProperties = config.slide
			table.insert(slick, part)
		end
	end
	humanoid.EvaluateStateMachine = false
	task.delay(config.ragdolltime, function()
		for _, inst in extras do
			inst:Destroy()
		end
		for _, joint in animated do
			joint.Enabled = true
		end
		for _, joint in motors do
			joint.Enabled = true
		end
		for _, part in limbs do
			part.CanCollide = false
		end
		for _, part in slick do
			part.CustomPhysicalProperties = nil :: any -- nil = back to default, the type defs just dont allow it
		end
		humanoid.RequiresNeck = true
		humanoid.EvaluateStateMachine = true
		-- snap upright, otherwise the humanoid takes forever to get up
		local pivot = character:GetPivot()
		local heading = pivot.LookVector * flatmask
		local facing = if heading.Magnitude > 0.01 then heading.Unit else -Vector3.zAxis
		character:PivotTo(CFrame.lookAlong(pivot.Position + Vector3.yAxis * 2, facing))
	end)
	task.delay(config.ragdolltime + config.grace, function()
		character:SetAttribute("ragdolled", nil)
	end)
end

function spider.strike(self: spider)
	local leg = self.attackleg
	local center = if leg then leg.foot else self.position + self.forward * config.strikeradius -- hits where the foot lands
	local landed = false
	for _, player in players:GetPlayers() do
		local root, humanoid = living(player.Character)
		if not root or not humanoid or (root.Position - center).Magnitude > config.strikeradius then
			continue
		end
		if (root.Position - self.position).Magnitude > config.attackrange * 1.25 then
			continue -- already ran out of reach
		end
		humanoid:TakeDamage(config.damage) -- respects forcefields
		landed = true
		if humanoid.Health <= 0 then
			continue -- let the death play out, a ragdoll would stop it from registering
		end
		ragdoll(player.Character :: Model, humanoid, root)
		-- ApplyImpulse from the server gets ignored on players n a velocity write dies to friction,
		-- a LinearVelocity replicates n holds for launchtime
		local away = ((root.Position - self.position) * flatmask).Unit
		local anchor = Instance.new("Attachment")
		anchor.Parent = root
		local launcher = Instance.new("LinearVelocity")
		launcher.Attachment0 = anchor
		launcher.RelativeTo = Enum.ActuatorRelativeTo.World
		launcher.VectorVelocity = away * config.knockback + Vector3.yAxis * config.knockback * 0.5
		launcher.MaxForce = config.launchforce
		launcher.Parent = root
		task.delay(config.launchtime, function()
			launcher:Destroy()
			anchor:Destroy()
		end)
	end
	if landed then
		oneshot(self.hitaudio, rng:NextNumber(0.9, 1.1))
	end
end

function spider.tryattack(self: spider, now: number)
	if self.state ~= "hunt" or now - self.lastattack < config.attackcooldown then
		return
	end
	local root = living(self.target)
	local target = self.target
	if not root or not target or (root.Position - self.position).Magnitude > config.attackrange then
		return
	end
	if target:GetAttribute("ragdolled") then
		return -- no combos
	end
	self.lastattack = now
	local aim = ((root.Position - self.position) * flatmask).Unit
	self.velocity += aim * config.lungespeed
	-- the leg pointing most at the target swings
	local best = self.legs[1]
	local bestdot = -math.huge
	for _, leg in self.legs do
		local dot = ((self.cframe * leg.rest - self.position) * flatmask).Unit:Dot(aim)
		if dot > bestdot then
			best, bestdot = leg, dot
		end
	end
	best.from, best.progress = best.foot, 1
	self.attackleg = best
	self.attackstart = now
	self.highlight.FillTransparency = 0.6
	tweenservice:Create(self.highlight, flashinfo, { FillTransparency = 1 }):Play()
	oneshot(self.lungeaudio, 0.5)
	task.delay(config.strikedelay, self.strike, self) -- extra args get passed thru, no closure needed
end

function spider.update(self: spider, dt: number, now: number)
	self:sense(now)
	self:steer(self:navigate(now), dt, now)
	self:pose(dt)
	self:swing(now)
	self:steplegs(dt)
	self:solvelegs()
	self:tryattack(now)
end

-- new audio api needs a listener wired to a device output per player, roblox only makes one when voice chat is on
local function listen(player: Player)
	local output = Instance.new("AudioDeviceOutput")
	output.Player = player
	output.Parent = player -- goes away when they leave

	local function oncharacter(character: Model)
		local listener = Instance.new("AudioListener")
		listener.Parent = character
		local wire = Instance.new("Wire")
		wire.SourceInstance = listener
		wire.TargetInstance = output
		wire.Parent = listener -- dies with the character, rebuilt on respawn
	end
	player.CharacterAdded:Connect(oncharacter)
	if player.Character then
		oncharacter(player.Character)
	end
end
players.PlayerAdded:Connect(listen)
for _, player in players:GetPlayers() do
	listen(player)
end

local function add(origin: Vector3)
	local hunter = spider.new(origin)
	table.insert(spiders, hunter)
	hunter.model.Destroying:Once(function()
		local index = table.find(spiders, hunter)
		if index then
			table.remove(spiders, index)
		end
	end)
end

local function spawnon(instance: Instance)
	if instance:IsA("BasePart") and #spiders < config.maxspiders then
		add(instance.Position + Vector3.yAxis * config.bodyheight)
	end
end

for _, part in collectionservice:GetTagged(config.spawntag) do
	spawnon(part)
end
collectionservice:GetInstanceAddedSignal(config.spawntag):Connect(spawnon)
if #spiders == 0 then
	add(Vector3.new(0, config.bodyheight, 0)) -- no tags, still spawn one
end

-- one loop drives every spider, PostSimulation so it reads where players ended up this frame
runservice.PostSimulation:Connect(function(dt: number)
	local now = os.clock()
	for _, hunter in spiders do
		hunter:update(dt, now)
	end
end)

-- ok bai