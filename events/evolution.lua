--[[
<?xml version='1.0' encoding='utf8'?>
<event name="Evolution Handler">
 <location>load</location>
 <chance>100</chance>
 <unique />
</event>
--]]
--[[
   Evolution Event

   This event runs constantly in the background and manages evolution of ship genomes
   through combat performance. Ships fight in an arena, die, get scored, and their
   genomes are bred/mutated for the next generation.

   Key improvements in this version:
   * Efficient flat genome structure: GENOMES[f_id] = array[{genome=str, score=num, hull=str}]
   * Automatic sorting/pruning to top 8 in pick_top_genome() (called every spawn)
   * Duplicate detection: same genome+hull updates score if better
   * Breeding from top pool only
   * Random cataclysms (2% chance per spawn) keep only top 2 genomes
   * Arena marker for visibility
   * Champion scaffolding (TODO: implement spawning logic)
   * Fixed VN dialogue for new structure (including "Forget")
   * Robust save/restore
   * Integrated score devaluing, broadcasts, hailed VN
--]]
local fmt           = require "format"
local vn            = require "vn"
local spark         = require "luaspfx.spark"

local dna_mod       = require "dna_modifier.dna_modifier"
-- luacheck: globals enter load EVO_CHECK_SYSTEM EVO_DISCUSS_RESEARCH EVOLVE SCORE_ATTACKED hailed

-- Configuration
local MAX_GENOMES          = 8  -- Max genomes kept per faction (pruned/sorted desc score)
local CATACLYSM_CHANCE     = 2  -- % chance per spawn to wipe to top 2 (approx every 50 spawns)
local ARENA_RADIUS         = 5000
local FAC_BLUE             = "Scientific Research Conglomerate"
local FAC_RED              = "Guild of Free Traders"

-- Persistent runtime storage: f_id -> [{genome=str, score=num, hull=str}] (sorted desc)
local GENOMES = {}

-- Spawns
local SPAWN_SHIPS = {
    "Llama", "Quicksilver", "Shark", "Hyena", "Pirate Hyena", "Ancestor", "Gawain",
    "Phalanx", "Admonisher", "Vigilance", "Gawain", "Pirate Shark", "Empire Shark",
    "Bedivere", "Tristan", "Goddard Merchantman", "Hawking", "Rhino", "Mule",
    "Zebra", "Plowshare"
}

local SMALL_SPAWN_SHIPS = {
    "Llama", "Quicksilver", "Shark", "Hyena", "Pirate Hyena", "Ancestor", "Gawain",
    "Gawain", "Empire Shark", "Pirate Shark", "Tristan"
}

local BIG_SPAWN_SHIPS = {
    "Phalanx", "Admonisher", "Vigilance", "Hawking", "Goddard Merchantman",
    "Dvaered Phalanx", "Pirate Phalanx", "Kestrel"
}

local SPAWN_SHIP = "Llama"

function create()
    hook.load("load")
    hook.enter("enter")
end

-- Picks the top genome, prunes/sorts to top MAX_GENOMES, saves to mem
-- Called every spawn -> frequent pruning without overkill
function pick_top_genome(f_id, fallback_size)
    if not fallback_size then fallback_size = 100 end
    if not GENOMES[f_id] then GENOMES[f_id] = {} end

    local list = GENOMES[f_id]
    local topGenome, topScore = nil, -1
    local f_min_score = 0

    -- Devalue all scores slightly (favor recent performance)
    for _, entry in ipairs(list) do
        entry.score = math.floor(entry.score * 0.99)
    end

    -- Find absolute top genome
    for _, entry in ipairs(list) do
        if entry.score > topScore then
            topScore = entry.score
            topGenome = entry.genome
        end
    end

    if not topGenome then
        return dna_mod.generate_junk_dna(fallback_size)
    end

    -- Build sorted top list (copy + sort desc)
    local topScorers = {}
    for _, entry in ipairs(list) do
        -- Include high performers (original logic adapted)
        if entry.score > topScore or entry.score * 3 > topScore then
            table.insert(topScorers, {
                genome = entry.genome,
                score  = entry.score,
                hull   = entry.hull
            })
        end
    end
    table.sort(topScorers, function(a, b) return a.score > b.score end)

    -- Trim to MAX_GENOMES
    while #topScorers > MAX_GENOMES do
        table.remove(topScorers)
    end

    -- Cataclysm: random wipe to top 2 (shake up evolution, prevent stagnation)
    if math.random(100) < CATACLYSM_CHANCE then
        print(fmt.f("CATACLYSM for {f}! Keeping top 2 genomes.", {f = f_id}))
        topScorers = { topScorers[1], topScorers[2] }
    end

    -- Update runtime
    GENOMES[f_id] = topScorers

    -- Save to mem
    if not mem.evolution then mem.evolution = {} end
    mem.evolution[f_id] = mem.evolution[f_id] or {}
    mem.evolution[f_id].genomes = topScorers
    evt.save(true)

    print(fmt.f("saving {num} genomes for {fac} (high score: {score})", {score = topScore, num = #topScorers, fac = f_id}))

    return topGenome
end

-- Gets a new genome by mutating/breeding from top pool
function get_genome(fac, default_size)
    if not default_size then default_size = 100 end
    local genome = pick_top_genome(fac, default_size)  -- Prunes as side effect
    local candidates = {}
    local mut_rate = math.random(6) * 0.01 + 0.005
    local genomes = GENOMES[fac] or {}

    local pool_size = math.min(8, #genomes)
    if pool_size > 2 then
        -- Mutate top pool
        for i = 1, pool_size do
            table.insert(candidates, dna_mod.mutate_random(genomes[i].genome, mut_rate))
        end
    else
        -- Fallback mutations
        table.insert(candidates, dna_mod.mutate_random(genome, 0.06))
        table.insert(candidates, dna_mod.mutate_random(genome, 0.22))
    end

    -- Breed and add
    local bred_genome = dna_mod.breed(candidates, 0.05)
    table.insert(candidates, bred_genome)

    return candidates[math.random(#candidates)]
end

-- Scores damage: defender loses score, attacker gains
function SCORE_ATTACKED(receiver, attacker, amount)
    local pmem = receiver:memory()
    local amem = attacker:memory()
    if not pmem.score then pmem.score = amount end
    if not amem.score then amem.score = amount * 10 end
    pmem.score = math.floor(math.max(pmem.score, amount + pmem.score * 0.1))
    local asz = attacker:ship():size()
    amem.score = math.floor((amem.score * 0.99) + (amount * (4.75 - asz) / asz))
    local sz_diff = receiver:ship():size() - attacker:ship():size()
    -- underdog bonus
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

-- Spawns a basic warrior
function spawn_warrior(fac, hull)
    if not hull then hull = SPAWN_SHIP end
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
        spark( champ:pos(),
            vec2.new(math.random(-1, 1), math.random(-1, 1)),
            champ:ship():size() * 5,
            nil,
            { silent=true }
        )
    end
    local amem = attacker:memory()
    if amem.score then
        amem.score = amem.score + amount
    end
end

-- TODO: Scaffolding for champion spawns (call from EVO_CHECK_SYSTEM when ready)
local function spawn_champion(fac)
    -- Get top genome
    local genomes = GENOMES[fac]
    if not genomes or #genomes == 0 then return end
    local top = genomes[1]

    -- TODO: Decide hull based on score/threshold
    -- local hull = (top.score > 5000) and "Ancestor" or "Phalanx"
    -- spawn_warrior(fac, hull, true)  -- champion=true for special AI?

    local hull = top.hull

    local champ = spawn_warrior(fac, hull)
    hook.pilot(champ, "attacked", "CHAMP_ATTACKED")

    print(fmt.f("Champion ready for {f}: {score} on {g} in {h}", {
        f = fac, score = top.score, g = string.sub(top.genome, 1, 8), h = hull
    }))
    champ:broadcast("Watch out, here I come!")
end

-- Evolution trigger: on death, record genome performance
function EVOLVE(dead_pilot, killer)
    local dmem = dead_pilot:memory()
    local score = dmem.score or 0
    local f_id = dead_pilot:faction():nameRaw()
    local genome = dmem.genome
    local hull = dead_pilot:ship():nameRaw()
    local final_score = math.floor(score)

    dead_pilot:broadcast(fmt.f("I died with a score of {v}", {v = final_score}))

    if not GENOMES[f_id] then GENOMES[f_id] = {} end

    -- Dedupe: update existing if same genome+hull and better score
    local updated = false
    for _, entry in ipairs(GENOMES[f_id]) do
        if entry.genome == genome and entry.hull == hull then
            if final_score > entry.score then
                print(fmt.f("Updated {f} {g}: {old} -> {new}", {
                    f = f_id, g = string.sub(genome, 1, 8),
                    old = entry.score, new = final_score
                }))
                entry.score = final_score
            end
            updated = true
            break
        end
    end

    -- Insert new
    if not updated then
        table.insert(GENOMES[f_id], {
            genome = genome,
            score  = final_score,
            hull   = hull
        })
--      print(fmt.f("New genome for {f}: {s} on {h} ({g})", {
--          f = f_id, s = final_score, h = hull,
--          g = string.sub(genome, 1, 8)
--      }))
    end

    -- Reward killer
    if killer and type(killer) ~= "string" then
        killer:addHealth(20, 50)
        killer:effectClear(false, false, false)
        local kmem = killer:memory()
        if not kmem.score then kmem.score = score * 0.3 end
        local kill_bonus = 75 * dead_pilot:ship():size()
        kmem.score = math.floor(kmem.score + kill_bonus + final_score * 0.3)
        killer:broadcast(fmt.f("I have {v} points now!", {v=kmem.score}))

        -- Save killer genome too (with dedupe)
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
                table.insert(GENOMES[k_f_id], {
                    genome = kmem.genome,
                    score  = kmem.score,
                    hull   = killer:ship():nameRaw()
                })
            end
        end
    end

    -- Rare hull upgrade
    if math.random(5) == 1 then
        SPAWN_SHIP = SPAWN_SHIPS[math.random(#SPAWN_SHIPS)]
        if ship.get(SPAWN_SHIP):size() > 3 and math.random(5) > 1 then
            SPAWN_SHIP = SMALL_SPAWN_SHIPS[math.random(#SMALL_SPAWN_SHIPS)]
        end
    end
end

-- Debug display (info button)
function display_info()
    local cur = system.cur()
    if cur:nameRaw() ~= "Evolution Sandbox" then
        player.teleport("Evolution Sandbox")
    else
        print("Already in Evolution Sandbox")
    end

    print("++GENOMES++")
    for fac, genomes in pairs(GENOMES) do
        for i, entry in ipairs(genomes) do
            local msg = ""
            local codons = dna_mod.enumerate_codons(entry.genome)
            for _, codon in ipairs(codons) do
                msg = msg .. ", " .. tostring(codon)
            end
            local mods = dna_mod.decode_dna(entry.genome)
            for attribute, value in pairs(mods) do
                msg = msg .. tostring(fmt.f("\n{attr}: {val}", {attr = attribute, val = value} ))
            end
            print(fmt.f("({f}) {v}: {m}", {m=msg,v=entry,fac=fac}))
        end
    end
    print("--GENOMES--")
end

-- Load/restore genomes from mem
function load()
    if not mem.evolution then
        print("mem.evolution not initialized")
        mem.evolution = {}
    else
        for f_id, evo_table in pairs(mem.evolution) do
            local genomes = evo_table.genomes
            if genomes and #genomes > 0 then
                GENOMES[f_id] = genomes
                print(fmt.f("restored {d} genomes for {f}", {f = f_id, d = #genomes}))
            else
                print("No genomes restored for " .. tostring(f_id))
                GENOMES[f_id] = {}
            end
        end
    end

    if not mem.evolution_purchases then
        mem.evolution_purchases = {}
    end

    evobtn = player.infoButtonRegister(_("Evolution"), display_info, 3)
    land()  -- Setup NPCs if landed in sandbox
end

function npc_success( p )
    -- TODO: figure out how to score p based on cargo value or something
end

local function spawn_npc ()
    -- TODO: Spawn a ship, use the miner AI, score it based on how much cargo it brought back
    -- ai/core/idle/miner.lua
end

-- Arena control loop
function EVO_CHECK_SYSTEM()
    local cur = system.cur()
    if cur:nameRaw() ~= "Evolution Sandbox" then return end

    -- Enforce boundary (user requested: keep damage-only)
    for _, sp in ipairs(pilot.get()) do
        local excess = sp:pos():dist() - ARENA_RADIUS
        if excess > 0 then
            spark( sp:pos(), sp:vel()*-0.5, sp:ship():size() * 6, nil, {} )
            if sp:memory().genome ~= nil then
                sp:damage(excess * 0.1, 0, 10, "explosion_splash")
                local smem = sp:memory()
                smem.norun = true
                smem.aggressive = true
            end
        end
    end

    -- Balance factions by ship power
    local blues = pilot.get(faction.get(FAC_BLUE))
    local reds = pilot.get(faction.get(FAC_RED))
    local blue_power, red_power = 0, 0
    for _, bp in ipairs(blues) do blue_power = blue_power + bp:ship():size() end
    for _, rp in ipairs(reds) do red_power = red_power + rp:ship():size() end

    -- Spawn replacements
    if not blues or #blues == 0 or (math.random(4) == 1 and blue_power < 5) then
        if math.random(8) == 4 then
            spawn_champion(FAC_BLUE)
        elseif red_power > 3 then
            spawn_warrior(FAC_BLUE, BIG_SPAWN_SHIPS[math.random(#BIG_SPAWN_SHIPS)])
        else
            spawn_warrior(FAC_BLUE)
        end
    end
    if not reds or #reds == 0 or (math.random(4) == 1 and red_power < 5) then
        if math.random(8) == 4 then
            spawn_champion(FAC_RED)
        elseif blue_power > 3 then
            spawn_warrior(FAC_RED, BIG_SPAWN_SHIPS[math.random(#BIG_SPAWN_SHIPS)])
        else
            spawn_warrior(FAC_RED)
        end
    end

    hook.timer(3, "EVO_CHECK_SYSTEM")
end

function SOLD_EVO_SHIP ( stype, sname, ref )
    if sname == sref or mem.evolution_purchases[sname] ~= nil then
        mem.evolution_purchases[ref] = nil
    end
end

local function purchase_hull ( hull, genome )
    local a_spob, a_sys = spob.cur()
    local new_ship = player.shipAdd(
        hull,
        "Modified " .. hull,
        fmt.f("Acquired via Genetics research at {sp} in the {sy} system", { sp = a_spob, sy = a_sys }),
        false -- force name
    )
    mem.evolution_purchases[new_ship] = genome
    hook.ship_sell( "SOLD_EVO_SHIP", new_ship )
end

-- NPC: Genome research discussion
function EVO_DISCUSS_RESEARCH()
    local loc = spob.cur()
    local fac = loc:faction():nameRaw()
    local fac_genomes = GENOMES[fac] or {}

    local choices = {}
    for index, entry in ipairs(fac_genomes) do
        local label = fmt.f("({score}) {strep} ({hull})", {
            score = entry.score,
            hull  = entry.hull,
            strep = string.sub(entry.genome, 1, 8)
        })
        table.insert(choices, {label, tostring(index)})
    end
    table.insert(choices, { "Nevermind", "end" })

    local msg = nil
    local choice_id = nil
    vn.reset()
    vn.scene()
    local scientist = vn.newCharacter("Station Scientist", {image = "zalek3.webp"})
    vn.transition()
    scientist(fmt.f("We are currently keeping track of {num} genomes. Want to inspect them?", {num = #fac_genomes}))
    vn.menu(choices)

    for _, choice in ipairs(choices) do
        local gindex = choice[2]
        if tonumber(gindex) then
            vn.label(gindex)
            vn.func(function()
                choice_id = tonumber(gindex)
                local entry = fac_genomes[choice_id]
                if not entry then return end

                local genome = entry.genome
                msg = fmt.f("{g} ({gl}) scored {s} on {h}", {
                    g = string.sub(genome, 1, 16),
                    gl = genome:len(),
                    s = entry.score,
                    h = entry.hull
                })
                local codons = dna_mod.enumerate_codons(genome)
                for _, codon in ipairs(codons) do
                    msg = msg .. ", " .. tostring(codon)
                end
                local mods = dna_mod.decode_dna(genome)
                for attribute, value in pairs(mods) do
                    msg = msg .. fmt.f("\n{attr}: {val}", {attr = attribute, val = value})
                end
            end)
            vn.jump("speak_msg")
        end
    end

    vn.label("speak_msg")
    scientist(function() return msg end)
    local affect_choices = {
        { "Purchase", "purchase" }, -- TODO: set price
        { "Irradiate", "irradiate" },
        { "Forget", "delete" },
        { "Cancel", "end" }
    }
    vn.menu(affect_choices)
    vn.label("purchase")
    vn.func(function()
        local entry = fac_genomes[choice_id]
        if not entry then return end
        -- TODO: Payment and confirmation
        purchase_hull(entry.hull, entry.genome)
    end)
    vn.jump("end")
    vn.label("irradiate")
    scientist("The available mutagens to target are:\nterminator, defense, propulsion, weaponry, utility\nNote that the purpose of radiation research is to neutralize the target mutagen.")
    vn.func(function()
        local entry = fac_genomes[choice_id]
        if not entry then return end
        local target_mutagen = tk.input("Radiation Target", 4, 16, "mutagen type")
        local researched_genome = dna_mod.research_irradiate(entry.genome, target_mutagen)
        table.insert(fac_genomes, {
            genome = dna_mod.mutate_random(researched_genome, 0.01),
            score  = entry.score,
            hull   = entry.hull
        })
    end)
    -- intentional fallthrough to remove original
    vn.label("delete")
    vn.func(function()
        table.remove(fac_genomes, choice_id)
    end)
    vn.label("end")
    scientist("Alright, see you later.")
    vn.done()
    vn.run()
end

local function createNpcs()
    local id = evt.npcAdd(
        "EVO_DISCUSS_RESEARCH",
        _("Station Scientist"),
        "zalek3.webp",
        "Talk to this scientist to interact with the evolution plugin.",
        3
    )
    print("Created NPC ID " .. tostring(id))
end

-- Hail response: show mods and score in VN
function hailed(receiver)
    local rmem = receiver:memory()
    local msg = fmt.f("My genome ({g}/{l}) provides the following modifications:", {g = string.sub(rmem.genome, 1, 8), l = rmem.genome:len()})
    local mods = dna_mod.decode_dna(rmem.genome)
    for attribute, value in pairs(mods) do
        msg = msg .. fmt.f("\n{attr}: {val}", {attr=attribute, val=value})
    end
    msg = msg .. "\nMy current score is " .. tostring(rmem.score)

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
        -- Cleanup hooks/markers
        if mem.evolution_data and mem.evolution_data.lhook then
            hook.rm(mem.evolution_data.lhook)
            mem.evolution_data.lhook = nil
        end
        if mem.evolution_data and mem.evolution_data.marker then
            system.markerRm(mem.evolution_data.marker)
            mem.evolution_data.marker = nil
        end
        return
    end
    createNpcs()
end

function enter()
    --  print purchased custom ships
--  for k,v in pairs(mem.evolution_purchases) do
--      print(fmt.f("{k}: {v}", {k=k, v=string.sub(v, 1, 8)}))
--  end
    -- apply any purchased ship effects
    local genome = mem.evolution_purchases[player.ship()]
    if genome ~= nil then
        print(fmt.f("Applying {g} to {s}", { g = genome, s = player.ship() }))
        dna_mod.apply_dna_to_pilot(player.pilot(), genome)
    end
    local cur = system.cur()
    if cur:nameRaw() ~= "Evolution Sandbox" then return end

    print("ENTER: Evolution Sandbox activated")
    spawn_warrior(FAC_BLUE)
    spawn_warrior(FAC_RED)
    hook.timer(3, "EVO_CHECK_SYSTEM")

    if not mem.evolution_data then mem.evolution_data = {} end
    if not mem.evolution_data.lhook then
        mem.evolution_data.lhook = hook.land("land")
    end
end
