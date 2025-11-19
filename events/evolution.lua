--[[
<?xml version='1.0' encoding='utf8'?>
<event name="Evolution Handler">
 <location>load</location>
 <chance>100</chance>
 <unique />
</event>
--]]
--[[
   Evolution Event (v3.1 - Stable)

   This event runs constantly in the background and manages evolution of ship genomes.

   Changes:
   * Fixed 'require tk' crash.
   * Refactored VN to safe state-machine structure.
   * Implemented Ship Pool Management (Small/Big tables).
   * Persistent storage of faction-specific ship pools.
--]]
local fmt           = require "format"
local vn            = require "vn"
local spark         = require "luaspfx.spark"
-- NOTE: 'tk' is global, do not require it.

local dna_mod       = require "dna_modifier.dna_modifier"
-- luacheck: globals enter load EVO_CHECK_SYSTEM EVO_DISCUSS_RESEARCH EVOLVE SCORE_ATTACKED hailed

-- Configuration
local MAX_GENOMES          = 6
local CATACLYSM_CHANCE     = 2
local ARENA_RADIUS         = 5000
local FAC_BLUE             = "Scientific Research Conglomerate"
local FAC_RED              = "Guild of Free Traders"
local SIZE_CUTOFF          = 3.0 -- Size threshold for Small vs Big ships

-- Persistent runtime storage
local GENOMES = {}

-- Default Ship Pools (Fallback)
local DEFAULT_SMALL = {
    "Llama", "Quicksilver", "Shark", "Hyena", "Pirate Hyena", "Ancestor",
    "Gawain", "Tristan", "Plowshare", "Mule"
}

local DEFAULT_BIG = {
    "Phalanx", "Admonisher", "Vigilance", "Pacifier", "Rhino"
}

function create()
    hook.load("load")
    hook.enter("enter")
end

-- ####################################################################
-- #    GENOME MANAGEMENT
-- ####################################################################

function pick_top_genome(f_id, fallback_size)
    if not fallback_size then fallback_size = 100 end
    if not GENOMES[f_id] then GENOMES[f_id] = {} end

    local list = GENOMES[f_id]
    local topGenome, topScore = nil, -1

    -- Devalue scores
    for _, entry in ipairs(list) do
        entry.score = math.floor(entry.score * 0.99)
    end

    -- Find top
    for _, entry in ipairs(list) do
        if entry.score > topScore then
            topScore = entry.score
            topGenome = entry.genome
        end
    end

    if not topGenome then
        return dna_mod.generate_junk_dna(fallback_size)
    end

    -- Filter & Sort
    local topScorers = {}
    for _, entry in ipairs(list) do
        if entry.score > topScore or entry.score * 3 > topScore then
            table.insert(topScorers, {
                genome = entry.genome,
                score  = entry.score,
                hull   = entry.hull
            })
        end
    end
    table.sort(topScorers, function(a, b) return a.score > b.score end)

    -- Prune
    while #topScorers > MAX_GENOMES do
        table.remove(topScorers)
    end

    -- Cataclysm
    if math.random(100) < CATACLYSM_CHANCE then
        print(fmt.f("CATACLYSM for {f}! Keeping top 3.", {f = f_id}))
        topScorers = { topScorers[1], topScorers[2], topScorers[3] }
    end

    GENOMES[f_id] = topScorers

    -- Persist
    if not mem.evolution then mem.evolution = {} end
    mem.evolution[f_id] = mem.evolution[f_id] or {}
    mem.evolution[f_id].genomes = topScorers

    evt.save(true)
    return topGenome
end

function get_genome(fac, default_size)
    if not default_size then default_size = 100 end
    local genome = pick_top_genome(fac, default_size)
    local candidates = {}
    local mut_rate = math.random(6) * 0.01 + 0.005
    local genomes = GENOMES[fac] or {}

    local pool_size = math.min(8, #genomes)
    if pool_size > 2 then
        for i = 1, pool_size do
            table.insert(candidates, dna_mod.mutate_random(genomes[i].genome, mut_rate))
        end
    else
        table.insert(candidates, dna_mod.mutate_random(genome, 0.06))
        table.insert(candidates, dna_mod.mutate_random(genome, 0.22))
    end

    local bred_genome = dna_mod.breed(candidates, 0.05)
    table.insert(candidates, bred_genome)

    return candidates[math.random(#candidates)]
end

-- ####################################################################
-- #    SHIP POOL MANAGEMENT
-- ####################################################################

local function add_ship_to_pool(f_id, hull_name)
    local s = ship.get(hull_name)
    if not s then return false, "Unknown ship hull." end

    -- Initialize if missing
    if not mem.evolution[f_id].ships then mem.evolution[f_id].ships = { small={}, big={} } end
    if not mem.evolution[f_id].ships.small then mem.evolution[f_id].ships.small = {} end
    if not mem.evolution[f_id].ships.big then mem.evolution[f_id].ships.big = {} end

    -- Determine category
    local target_table = (s:size() > SIZE_CUTOFF) and mem.evolution[f_id].ships.big or mem.evolution[f_id].ships.small
    local cat_name = (s:size() > SIZE_CUTOFF) and "BIG" or "SMALL"

    -- Check duplicates
    for _, h in ipairs(target_table) do
        if h == hull_name then return false, "Ship already in " .. cat_name .. " pool." end
    end

    table.insert(target_table, hull_name)
    return true, "Added " .. hull_name .. " to " .. cat_name .. " pool."
end

local function remove_ship_from_pool(f_id, hull_name)
    local found = false
    local pools = { mem.evolution[f_id].ships.small, mem.evolution[f_id].ships.big }

    for _, pool in ipairs(pools) do
        for i, h in ipairs(pool) do
            if h == hull_name then
                table.remove(pool, i)
                found = true
                break
            end
        end
        if found then break end
    end
    return found
end

-- ####################################################################
-- #    COMBAT & SPAWNING
-- ####################################################################

function SCORE_ATTACKED(receiver, attacker, amount)
    if attacker:mothership() ~= nil then attacker = attacker:mothership() end
    local pmem = receiver:memory()
    local amem = attacker:memory()
    if not pmem.score then pmem.score = amount end
    if not amem.score then amem.score = amount * 10 end
    pmem.score = math.floor(math.max(pmem.score, amount + pmem.score * 0.1))
    local asz = attacker:ship():size()
    amem.score = math.floor((amem.score * 0.99) + (amount * (4.75 - asz) / asz))
    local sz_diff = receiver:ship():size() - attacker:ship():size()
    if sz_diff > 0 then
        amem.score = amem.score + math.floor(amount * sz_diff * attacker:ship():size() / 2)
    end
end

local function determine_genome_size(fac)
    local val = 128
    if fac:find("Research") then val = 256 end
    if fac:find("Guild") then val = 128 end
    return val
end

function spawn_warrior(fac, hull, size_class)
    -- Auto-pick hull if missing
    if not hull then
        local ships_data = mem.evolution[fac].ships
        -- Safety init
        if not ships_data then ships_data = { small={}, big={} } end

        local pool
        if size_class == "big" then
            pool = ships_data.big
        elseif size_class == "small" then
            pool = ships_data.small
        else
            -- Random selection
            pool = (math.random(100) < 20) and ships_data.big or ships_data.small
        end

        -- Fallback to defaults if empty
        if not pool or #pool == 0 then
            pool = (size_class == "big") and DEFAULT_BIG or DEFAULT_SMALL
        end

        hull = pool[math.random(#pool)]
    end

    local sp = pilot.add(hull, fac, nil)
    local smem = sp:memory()
    smem.genome = get_genome(fac, determine_genome_size(fac))
    if math.random(3) == 1 then smem.norun = true end

    dna_mod.apply_dna_to_pilot(sp, smem.genome)
    hook.pilot(sp, "death", "EVOLVE")
    hook.pilot(sp, "attacked", "SCORE_ATTACKED")
    hook.pilot(sp, "hail", "hailed")

    sp:setNoDisable(true)
    sp:setNoLand(true)
    sp:setNoJump(true)

    return sp
end

function CHAMP_ATTACKED ( champ, attacker, amount )
    for _=  1, math.random(3) do
        spark( champ:pos(), vec2.new(math.random(-1, 1), math.random(-1, 1)), champ:ship():size() * 5, nil, { silent=false })
    end
    local amem = attacker:memory()
    if amem.score then amem.score = amem.score + amount end
end

local function spawn_champion(fac)
    local genomes = GENOMES[fac]
    if not genomes or #genomes == 0 then return end
    local top = genomes[1]
    local hull = top.hull
    local champ = spawn_warrior(fac, hull)
    hook.pilot(champ, "attacked", "CHAMP_ATTACKED")
    champ:broadcast("Watch out, here I come!")
end

function EVOLVE(dead_pilot, killer)
    if killer ~= nil and killer:mothership() ~= nil then killer = killer:mothership() end
    local dmem = dead_pilot:memory()
    local score = dmem.score or 0
    local f_id = dead_pilot:faction():nameRaw()
    local genome = dmem.genome
    local hull = dead_pilot:ship():nameRaw()
    local final_score = math.floor(score)

    dead_pilot:broadcast(fmt.f("I died with a score of {v}", {v = final_score}))

    if not GENOMES[f_id] then GENOMES[f_id] = {} end

    local updated = false
    for _, entry in ipairs(GENOMES[f_id]) do
        if entry.genome == genome and entry.hull == hull then
            if final_score > entry.score then
                entry.score = final_score
            end
            updated = true
            break
        end
    end

    if not updated then
        table.insert(GENOMES[f_id], { genome = genome, score  = final_score, hull   = hull })
    end

    if killer and type(killer) ~= "string" then
        killer:addHealth(20, 50)
        killer:effectClear(false, false, false)
        local kmem = killer:memory()
        if not kmem.score then kmem.score = score * 0.3 end
        local kill_bonus = 75 * dead_pilot:ship():size()
        kmem.score = math.floor(kmem.score + kill_bonus + final_score * 0.3)
        killer:broadcast(fmt.f("I have {v} points now!", {v=kmem.score}))

        local k_f_id = killer:faction():nameRaw()
        if kmem.genome then
            if not GENOMES[k_f_id] then GENOMES[k_f_id] = {} end
            local k_updated = false
            for _, entry in ipairs(GENOMES[k_f_id]) do
                if entry.genome == kmem.genome and entry.hull == killer:ship():nameRaw() then
                    if kmem.score > entry.score then
                        entry.score = kmem.score
                    end
                    k_updated = true
                    break
                end
            end
            if not k_updated then
                table.insert(GENOMES[k_f_id], { genome = kmem.genome, score  = kmem.score, hull   = killer:ship():nameRaw() })
            end
        end
    end
end

-- ####################################################################
-- #    VN & INTERACTION
-- ####################################################################

local function purchase_hull ( hull, genome )
    local a_spob, a_sys = spob.cur()
    local strict_name = "Modified " .. hull
    player.shipAdd(hull, strict_name, fmt.f("Acquired via Genetics research at {sp}", { sp = a_spob }), true)
    player.shipvarPush("genome", genome, strict_name)
end

function EVO_DISCUSS_RESEARCH()
    local loc = spob.cur()
    local fac = loc:faction():nameRaw()
    local fac_genomes = GENOMES[fac] or {}

    -- State variables for the conversation
    local selected_genome_idx = 0

    vn.reset()
    vn.scene()
    local scientist = vn.newCharacter("Station Scientist", {image = "zalek3.webp"})
    vn.transition()

    -- === START NODE ===
    vn.label("start")
    scientist("How can I assist with our ongoing evolution project?")

    local choices = {
        {"Examine Genomes", "view_genomes"},
        {"Manage Ships", "manage_ships"},
        {"Leave", "end"}
    }
    vn.menu(choices)

    -- === GENOME SECTION ===
    vn.label("view_genomes")
    local g_choices = {}
    -- Dynamically build jump labels based on current indices
    for i, entry in ipairs(fac_genomes) do
        local label = fmt.f("({s}) {g}/{l} ({hull})", { s=entry.score, g=string.sub(entry.genome,1,8), l=entry.genome:len(), hull=entry.hull })
        table.insert(g_choices, { label, "set_g_idx_"..i })
    end
    table.insert(g_choices, {"Back", "start"})

    scientist(fmt.f("We have {n} genomes stored.", {n=#fac_genomes}))
    vn.menu(g_choices)

    -- Define selection nodes
    for i, entry in ipairs(fac_genomes) do
        vn.label("set_g_idx_"..i)
        vn.func(function() selected_genome_idx = i end)
        vn.jump("show_genome")
    end

    vn.label("show_genome")
    scientist(function()
        local entry = fac_genomes[selected_genome_idx]
        if not entry then return "Error: Genome lost." end

        local msg = fmt.f("Hull: {h}\nScore: {s}\nSeq: {g}", {h=entry.hull, s=entry.score, g=entry.genome})
        local mods = dna_mod.decode_dna(entry.genome)
        for k, v in pairs(mods) do msg = msg .. "\n" .. k .. ": " .. v end
        return msg
    end)

    vn.menu({
        {"Purchase Ship", "g_buy"},
        {"Irradiate", "g_rad"},
        {"Forget", "g_del"},
        {"Back", "view_genomes"}
    })

    vn.label("g_buy")
    vn.func(function()
        local entry = fac_genomes[selected_genome_idx]
        if entry then purchase_hull(entry.hull, entry.genome) end
    end)
    vn.jump("end")

    vn.label("g_rad")
    vn.func(function()
        local entry = fac_genomes[selected_genome_idx]
        if entry then
             local target = tk.input("Radiation Target", 4, 16, "mutagen type")
             if target then
                 local res = dna_mod.research_irradiate(entry.genome, target)
                 table.insert(fac_genomes, { genome=dna_mod.mutate_random(res, 0.01), score=entry.score, hull=entry.hull })
             end
        end
    end)
    -- Must end because list changed
    scientist("Experimental genome added to pool.")
    vn.jump("end")

    vn.label("g_del")
    vn.func(function()
        table.remove(fac_genomes, selected_genome_idx)
    end)
    scientist("Genome data purged.")
    -- Must end because list structure changed, invalidating the "view_genomes" menu graph
    vn.jump("end")

    -- === SHIPS SECTION ===
    vn.label("manage_ships")
    scientist(function()
        local s_pool = mem.evolution[fac].ships.small or {}
        local b_pool = mem.evolution[fac].ships.big or {}
        local msg = "Current Ship Pools for " .. fac .. ":\n\n[Small]\n"
        if #s_pool == 0 then msg = msg .. "(Empty)\n" end
        for _, h in ipairs(s_pool) do msg = msg .. h .. ", " end

        msg = msg .. "\n\n[Big]\n"
        if #b_pool == 0 then msg = msg .. "(Empty)\n" end
        for _, h in ipairs(b_pool) do msg = msg .. h .. ", " end
        return msg
    end)

    vn.menu({
        {"Add Ship", "s_add"},
        {"Remove Ship", "s_remove"},
        {"Back", "start"}
    })

    vn.label("s_add")
    vn.func(function()
        local input = tk.input("Ship Hull", 3, 30, "Hull Name")
        if input then
            local ok, res = add_ship_to_pool(fac, input)
            if not ok then
                -- Since we can't easily print immediate output without a node, we use spark/print or just rely on loop
                print("Ship Add Error: "..res)
            end
        end
    end)
    vn.jump("manage_ships") -- Loop back to refresh list

    vn.label("s_remove")
    vn.func(function()
        local input = tk.input("Ship Hull", 3, 30, "Hull Name")
        if input then
            remove_ship_from_pool(fac, input)
        end
    end)
    vn.jump("manage_ships")

    -- === END ===
    vn.label("end")
    scientist("Farewell.")
    vn.done()
    vn.run()
end

local function createNpcs()
    local id = evt.npcAdd("EVO_DISCUSS_RESEARCH", _("Station Scientist"), "zalek3.webp", "Evolution Research", 3)
    print("Created NPC ID " .. tostring(id))
end

function hailed(receiver)
    local rmem = receiver:memory()
    local msg = fmt.f("Genome ({g})... Score: {s}", {g = string.sub(rmem.genome, 1, 8), s=rmem.score})
    local mods = dna_mod.decode_dna(rmem.genome)
    for k, v in pairs(mods) do msg = msg .. fmt.f("\n{k}: {v}", {k=k, v=v}) end

    vn.clear()
    vn.scene()
    vn.transition()
    vn.na(msg)
    vn.run()
    player.commClose()
end

function land()
    local cur = system.cur()
    if cur:nameRaw() ~= "Evolution Sandbox" then
        if mem.evolution_data and mem.evolution_data.lhook then
            hook.rm(mem.evolution_data.lhook)
            mem.evolution_data.lhook = nil
        end
        return
    end
    createNpcs()
end

local function init_ship_tables(f_id)
    if not mem.evolution[f_id] then mem.evolution[f_id] = {} end
    local ships_data = mem.evolution[f_id].ships

    -- Migration
    if ships_data and #ships_data > 0 and not ships_data.small then
        print(fmt.f("Migrating ship data for {f}...", {f=f_id}))
        local new_struct = { small = {}, big = {} }
        for _, hull in ipairs(ships_data) do
            local s = ship.get(hull)
            if s then
                if s:size() > SIZE_CUTOFF then table.insert(new_struct.big, hull)
                else table.insert(new_struct.small, hull) end
            end
        end
        mem.evolution[f_id].ships = new_struct
    end

    -- Initialization
    if not mem.evolution[f_id].ships or not mem.evolution[f_id].ships.small then
        mem.evolution[f_id].ships = { small = {}, big = {} }
        for _, s in ipairs(DEFAULT_SMALL) do table.insert(mem.evolution[f_id].ships.small, s) end
        for _, s in ipairs(DEFAULT_BIG) do table.insert(mem.evolution[f_id].ships.big, s) end
    end
end

function load()
    if not mem.evolution then mem.evolution = {} end
    init_ship_tables(FAC_BLUE)
    init_ship_tables(FAC_RED)

    for f_id, evo_table in pairs(mem.evolution) do
        if evo_table.genomes then GENOMES[f_id] = evo_table.genomes else GENOMES[f_id] = {} end
        init_ship_tables(f_id)
    end

    player.infoButtonRegister(_("Evolution"), function()
        print("Use the Station Scientist to inspect evolution data.")
    end, 3)
    land()
end

function enter()
    local genome = player.shipvarPeek("genome")
    if genome then dna_mod.apply_dna_to_pilot(player.pilot(), genome) end

    local cur = system.cur()
    if cur:nameRaw() ~= "Evolution Sandbox" then return end

    spawn_warrior(FAC_BLUE)
    spawn_warrior(FAC_RED)
    hook.timer(3, "EVO_CHECK_SYSTEM")

    if not mem.evolution_data then mem.evolution_data = {} end
    if not mem.evolution_data.lhook then mem.evolution_data.lhook = hook.land("land") end
end

-- Arena Loop
function EVO_CHECK_SYSTEM()
    local cur = system.cur()
    if cur:nameRaw() ~= "Evolution Sandbox" then return end

    local aps = pilot.get()
    if #aps > 100 then pilot.clear(); return end

    -- Boundary Check
    for _, sp in ipairs(aps) do
        if sp:pos():dist() > ARENA_RADIUS then
            if sp:memory().genome then
                sp:damage(100, 0, 10, "explosion_splash") -- gentle nudge damage
                spark(sp:pos(), sp:vel()*-1, 50)
                local v = sp:vel()
                sp:setVel(vec2.new(-v.x, -v.y)) -- Turn around
            end
        end
    end

    local blues = pilot.get(faction.get(FAC_BLUE))
    local reds = pilot.get(faction.get(FAC_RED))
    local b_pow, r_pow = 0, 0
    for _, p in ipairs(blues) do b_pow = b_pow + p:ship():size() end
    for _, p in ipairs(reds) do r_pow = r_pow + p:ship():size() end

    -- Blue Logic
    if not blues or #blues == 0 or (math.random(4)==1 and b_pow < 8) then
        if math.random(10) == 1 then spawn_champion(FAC_BLUE)
        elseif r_pow > 8 then spawn_warrior(FAC_BLUE, nil, "big")
        else spawn_warrior(FAC_BLUE, nil, "small") end
    end

    -- Red Logic
    if not reds or #reds == 0 or (math.random(4)==1 and r_pow < 8) then
        if math.random(10) == 1 then spawn_champion(FAC_RED)
        elseif b_pow > 8 then spawn_warrior(FAC_RED, nil, "big")
        else spawn_warrior(FAC_RED, nil, "small") end
    end

    hook.timer(3, "EVO_CHECK_SYSTEM")
end
