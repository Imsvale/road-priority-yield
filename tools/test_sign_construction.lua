-- Console utility (changes the save): place one yield sign construction beside a road approach,
-- or list / remove yield sign constructions. A test of placing signs as free-standing
-- constructions (2026-10-18): position, side, facing, and whether the game accepts it so close
-- to the road (the model's collider is NONE).
-- Paste into the in-game console (it has no dofile). Output goes to the game log (stdout.txt).
--
-- Placement: on SEGMENT, BACK metres out from NODE along the road, on the right-hand side of the
-- traffic coming in towards NODE (right-hand traffic), EDGE_OFFSET outside the road's edge,
-- facing that traffic (the model's face points along its -Y).
--
-- The construction's name is looked up in api.res.constructionRep (getAll(true)) rather than
-- spelled out: "imsvale_road_priority_yield::/construction/imsvale_yield_sign.con" gave the
-- game's stand-in box (a placeholder in a hole), so that wasn't the registered name (2026-10-18).
--
-- "list" also shows every construction within NEAR metres of NODE with its file name;
-- "remove" removes our signs and the stand-in boxes (file names in REMOVE_ALSO) near NODE.

local SEGMENT = 8726    -- the approach (10982: the entry at roundabout node 11032)
local NODE = 8563       -- the junction it leads into (one of SEGMENT's two nodes)
local BACK = 10         -- metres from the node along the road
local CURB_INSET = 0.5  -- metres from the curb onto the sidewalk (roads with sidewalks)
local EDGE_OFFSET = 1.0 -- metres outside the road's edge (roads without sidewalks)
-- The curb: sidewalks are the lane configs with a raised height (0.15 in the street templates),
-- driving lanes are at 0, so the curb sits half the driving lanes' width from the centre line.
-- (The first collision on the sidewalk came from the game's stand-in box, not the sign; the
-- proper construction builds there without any, 2026-10-18.)
local MODE = "list"     -- "add", "list" or "remove"
local NEAR = 60         -- metres around NODE for "list" / "remove"
local REMOVE_ALSO = { "placeholder" } -- file name parts of stand-ins to clear near NODE

local CT = api.type.ComponentType
local function out(fmt, ...)
	local args = { ... }
	for i = 1, select("#", ...) do args[i] = tostring(args[i]) end
	print("[yield-test] " .. string.format(fmt, (table.unpack or unpack)(args)))
end

local function conName()
	for id, name in pairs(api.res.constructionRep.getAll(true)) do
		if tostring(name):find("imsvale_yield_sign", 1, true) then return name, id end
	end
end

-- Constructions near NODE: { entity, fileName, distance }.
local function near()
	local np = api.engine.getComponent(NODE, CT.BASE_NODE).position
	local list = {}
	local stats = { visited = 0, withCon = 0, positioned = 0, samples = {}, lastErr = nil }
	local function visit(entity)
		stats.visited = stats.visited + 1
		local ok, err = pcall(function()
			local con = api.engine.getComponent(entity, CT.CONSTRUCTION)
			if not con then return end
			stats.withCon = stats.withCon + 1
			if #stats.samples < 3 then stats.samples[#stats.samples + 1] = tostring(con.fileName) end
			local p = con.transf:getTransl() -- Mat4f
			stats.positioned = stats.positioned + 1
			local dist = math.sqrt((p.x - np.x) ^ 2 + (p.y - np.y) ^ 2)
			if tostring(con.fileName):find("imsvale_yield_sign", 1, true) then
				out("  a yield sign: %s at (%.1f, %.1f), %.0f m from the node", entity, p.x, p.y, dist)
			end
			if dist <= NEAR then list[#list + 1] = { entity = entity, fileName = tostring(con.fileName), dist = dist } end
		end)
		if not ok then stats.lastErr = tostring(err) end
	end
	api.engine.forEachEntityWithComponent(visit, CT.CONSTRUCTION)
	if stats.visited == 0 then
		-- Fallback: the list form.
		local okList, ents = pcall(function() return api.engine.getEntitiesWithComponent(CT.CONSTRUCTION) end)
		out("forEachEntityWithComponent visited nothing; getEntitiesWithComponent: %s", okList and #ents or tostring(ents))
		if okList then for _, ent in ipairs(ents) do visit(ent) end end
	end
	out("constructions visited %s, with component %s, positioned %s, e.g. %s%s", stats.visited, stats.withCon,
		stats.positioned, table.concat(stats.samples, " | "), stats.lastErr and (" | last error: " .. stats.lastErr) or "")
	return list
end

local function isOurs(fileName)
	if fileName:find("imsvale_yield_sign", 1, true) then return true end
	for _, part in ipairs(REMOVE_ALSO) do
		if fileName:find(part, 1, true) then return true end
	end
	return false
end

print("[yield-test][start] Sign construction, mode " .. MODE)
local ok, err = pcall(function()
	local name, id = conName()
	out("registered sign construction: %s (id %s)", name, id)
	local around = near()
	out("%s constructions within %s m of node %s:", #around, NEAR, NODE)
	for _, c in ipairs(around) do out("  %s at %s m: %s", c.entity, math.floor(c.dist), c.fileName) end
	if MODE == "list" then return end

	local proposal = api.type.SimpleProposal.new()
	if MODE == "remove" then
		local list = {}
		for _, c in ipairs(around) do if isOurs(c.fileName) then list[#list + 1] = c.entity end end
		out("removing %s", #list)
		proposal.constructionsToRemove = list
	else
		if not name then out("sign construction not registered") return end
		local e = api.engine.getComponent(SEGMENT, CT.BASE_EDGE)
		if not e then out("segment %s not found", SEGMENT) return end
		if e.node0 ~= NODE and e.node1 ~= NODE then out("node %s is not an end of segment %s", NODE, SEGMENT) return end
		local at0 = e.node0 == NODE
		local p = at0 and e.position0 or e.position1
		local t = at0 and e.tangent0 or e.tangent1
		local s = at0 and 1 or -1
		local l = math.sqrt(t.x * t.x + t.y * t.y)
		local d = { x = s * t.x / l, y = s * t.y / l }   -- out along the road, away from the node
		local right = { x = -d.y, y = d.x }                -- right of the traffic coming in (travelling -d)
		local width, carriageway, sidewalk = 0, 0, false
		for _, lc in ipairs(e.laneConfigs) do
			width = width + lc.width
			if (lc.height or 0) > 0.05 then sidewalk = true else carriageway = carriageway + lc.width end
		end
		local lateral = sidewalk and (carriageway / 2 + CURB_INSET) or (width / 2 + EDGE_OFFSET)
		out("carriageway %s m of %s m, sidewalk %s", carriageway, width, tostring(sidewalk))
		local x = p.x + d.x * BACK + right.x * lateral
		local y = p.y + d.y * BACK + right.y * lateral
		local angle = math.atan2 and math.atan2(d.x, -d.y) or math.atan(d.x, -d.y) -- model -Y onto d
		out("road %s m wide; sign at (%.1f, %.1f, %.1f), angle %.1f deg", width, x, y, p.z, math.deg(angle))
		local ce = api.type.SimpleProposal.ConstructionEntity.new()
		ce.fileName = name
		ce.transf = api.type.Mat4f.rotZTransl(angle, api.type.Vec3f.new(x, y, p.z))
		ce.params = { seed = 0 }
		ce.name = "Yield sign"
		ce.playerEntity = api.engine.util.getPlayer()
		proposal.constructionsToAdd = { ce }
	end
	-- First as the player would build it; if refused, log what it collided with and send it
	-- again with ignoreErrors (the 3rd argument; the game's mission code builds its
	-- constructions that way).
	local function send(ignoreErrors)
		api.cmd.sendCommand(api.cmd.makeWorldBuildProposalCmd(proposal, nil, ignoreErrors, true), function(res, success, resultEntities)
			-- What the build made: the entities it reports back, with their component types (the
			-- built sign wasn't among the constructions, 2026-10-18).
			pcall(function()
				for _, r in ipairs(resultEntities or {}) do
					local ent = type(r) == "table" and r[1] or r
					local kinds = {}
					for _, k in ipairs({ "CONSTRUCTION", "SUBCONSTRUCTION", "ASSET_GROUP", "MODEL_INSTANCE_LIST", "BOUNDING_VOLUME", "PLAYER_OWNED", "NAME" }) do
						if CT[k] and api.engine.getComponent(ent, CT[k]) then kinds[#kinds + 1] = k end
					end
					out("built entity %s: %s", ent, table.concat(kinds, ","))
				end
				out("%s result entities", #(resultEntities or {}))
			end)
			local msgs, hits = {}, {}
			pcall(function()
				for _, m in ipairs(res.resultProposalData.errorState.messages) do msgs[#msgs + 1] = tostring(m) end
			end)
			pcall(function()
				for _, c in ipairs(res.resultProposalData.collisionInfo.collisionEntities) do
					local ent = c.entity
					local kinds = {}
					for _, k in ipairs({ "BASE_EDGE", "BASE_NODE", "CONSTRUCTION", "MODEL_INSTANCE_LIST", "ASSET_GROUP", "TOWN_BUILDING" }) do
						if CT[k] and api.engine.getComponent(ent, CT[k]) then kinds[#kinds + 1] = k end
					end
					hits[#hits + 1] = tostring(ent) .. "[" .. table.concat(kinds, ",") .. "]"
				end
			end)
			out("%s%s: %s %s | collides with: %s", MODE, ignoreErrors and " (ignoreErrors)" or "",
				success and "ok" or "REFUSED", table.concat(msgs, "; "), #hits > 0 and table.concat(hits, " ") or "-")
			if not success and not ignoreErrors and MODE == "add" then send(true) end
		end)
	end
	send(false)
end)
if not ok then out("failed: %s", err) end
print("[yield-test][end]")
