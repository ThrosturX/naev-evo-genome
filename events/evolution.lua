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

   This event runs constantly in the background and manages evolution (maybe)
--]]
local fmt           = require "format"
local vn            = require "vn"
local dna_mod = require "dna_modifier.dna_modifier"
-- luacheck: globals enter load EVO_CHECK_SYSTEM, EVO_DISCUSS_RESEARCH (Hook functions passed by name)

-- TODO:
-- * Add a bar NPC to get info from
-- * Trigger research

function create ()
  hook.load("load")
  hook.enter("enter")
end

local evobtn

local GENOMES = {}

local MAX_GENOMES = 16
function pick_top_genome ( f_id, fallback_size )
    if not fallback_size then
        fallback_size = 100
    end
    local topGenome = nil
    local topScore = -1
    local topScorers = {}
    if not GENOMES[f_id] then
        GENOMES[f_id] = {}
    end

    local f_min_score = 0

    for _i, t in ipairs(GENOMES[f_id]) do
        for k, v in pairs(t) do
            -- devalue all scores
            v.score = math.floor(v.score * 0.99)
            if v.score > topScore then
                topScore = v.score
                topGenome = k
                local te = {}
                te[topGenome] = { score = topScore, hull = v.hull }
                table.insert(topScorers, te)
            elseif v.score * 3 > topScore then
                local te = {}
                te[topGenome] = { score = math.floor(v.score), hull = v.hull }
                table.insert(topScorers, te)
            end
        end
    end
    -- clean the genomes table while we're here
    table.sort(topScorers, function(a,b)
        for _genomeA, dataA in pairs(a) do
            for _genomeB, dataB in pairs(b) do
                return dataA.score > dataB.score
            end
        end
    end)
    if #topScorers > MAX_GENOMES then
        for i = MAX_GENOMES + 1, #topScorers do
            topScorers[i] = nil
        end
        local trimmed = {}
        for i = 1, MAX_GENOMES do
            trimmed[i] = topScorers[i]
        end
        topScorers = trimmed
    end
    GENOMES[f_id] = topScorers
    if not mem.evolution[f_id] then 
        mem.evolution[f_id] = {}
    end
    -- save our top genomes into the memory
    if #topScorers > 3 then
        print(fmt.f("saving {num} genomes for {fac} (high score: {score})", {score = topScore, num = #topScorers, fac = f_id}))
        local me = mem.evolution[f_id]
        me.genomes = topScorers
        mem.evolution[f_id] = me
        evt.save()
    end
    return topGenome or dna_mod.generate_junk_dna(fallback_size)
end

local function get_genome( fac, default_size )
    if not default_size then
        default_size = 100
    end
    local genome = pick_top_genome( fac, default_size )
    local genome_candidates = {}
    local mut_rate = math.random(6) * 0.01 + 0.005
    if #GENOMES[fac] > 2 then
        for _i, te in ipairs(GENOMES[fac]) do
            for genome, _score in pairs(te) do
                table.insert(genome_candidates, dna_mod.mutate_random(genome, mut_rate))
            end
        end
    else
        table.insert(genome_candidates, dna_mod.mutate_random(genome, 0.06))
        table.insert(genome_candidates, dna_mod.mutate_random(genome, 0.22))
    end
    local bred_genome = dna_mod.breed(genome_candidates, 0.05)
    table.insert(genome_candidates, bred_genome)

    return genome_candidates[math.random(#genome_candidates)]
end

function SCORE_ATTACKED ( receiver, attacker, amount )
   local pmem = receiver:memory() 
   local amem = attacker:memory()
   if not pmem.score then
        pmem.score = amount
   end
   if not amem.score then
       -- initial score based on alpha strike
       amem.score = amount * 10 
   end
    pmem.score = math.floor(math.max(pmem.score, amount + pmem.score * 0.1))
    amem.score = math.floor((amem.score * 0.95) + (amount * 3.75))
end

local SPAWN_SHIPS = {
    "Llama", "Quicksilver", "Shark", "Hyena", "Pirate Hyena", "Ancestor", "Gawain",
    "Phalanx", "Admonisher", "Vigilance", "Gawain", "Pirate Shark", "Empire Shark",
    "Bedivere", "Tristan",
    "Goddard Merchantman", "Hawking"
}

local SPAWN_SHIP = "Hyena"

local function determine_genome_size( fac )
    local val = 128
    if fac:find("Research") then
        val = 256
    elseif fac:find("Guild") then
        val = 128
    end
    
    return val
end

local function spawn_warrior ( fac, hull )
    if not hull then
        hull = SPAWN_SHIP
    end
    local sp = pilot.add(hull, fac, nil)
    local smem = sp:memory()
    smem.genome = get_genome( fac, determine_genome_size( fac ) )
    if math.random(3) == 1 then
        -- stubborn warrior
        smem.norun = true
    end
    
    dna_mod.apply_dna_to_pilot(sp, smem.genome)

    hook.pilot(sp, "death", "EVOLVE")
    hook.pilot(sp, "attacked", "SCORE_ATTACKED")
    hook.pilot(sp, "hail", "hailed")

    -- special stuff
    sp:setNoDisable(true)
    sp:setNoLand(true)
    sp:setNoJump(true)
end

-- TODO: Make the pilot broadcast a message with his score
function EVOLVE ( dead_pilot, killer, _last_genome )
    local dmem = dead_pilot:memory()
    local score = dmem.score or 0
    local f_id = dead_pilot:faction():nameRaw()
    last_genome = dmem.genome

    if GENOMES[f_id] == nil then
        GENOMES[f_id] = {}
    end

    local table_entry = {}
    local final_score = math.floor(score / dead_pilot:ship():size())
    dead_pilot:broadcast(fmt.f("I died with a score of {v}", {v = final_score} ))
    table_entry[last_genome] = { score = final_score, hull = dead_pilot:ship():nameRaw() }
    table.insert(GENOMES[f_id], table_entry)
--  print(fmt.f("Genome for {fac} scored at {score}", {fac=f_id, score=score}))
    -- reset or reward killer here
    if killer ~= nil and type(killer) ~= "string" then
        killer:addHealth(20, 50)
        killer:effectClear(false, false, false)
        local kmem = killer:memory()
        if kmem.score == nil then
            kmem.score = score * 0.3 -- inherit some of victim's score
        end
        local kill_bonus = 200 * dead_pilot:ship():size()
        kmem.score = math.floor(kmem.score + kill_bonus + final_score * 0.3) -- score bonus for final blow
--      print(fmt.f("Attacker ({fac}) has a score of {score}", {score=kmem.score, fac=killer:faction()}))
        killer:broadcast(fmt.f("I have {v} points now!", {v=kmem.score}))
        -- save killer genome too
        if kmem.genome ~= nil then
            local winner_entry = {}
            winner_entry[kmem.genome] = { score = kmem.score, hull = killer:ship():nameRaw() }
            table.insert(GENOMES[killer:faction():nameRaw()], winner_entry)
        end
    end

    -- spawn replacement pilot
--  spawn_warrior( f_id )

    -- change the next spawn ship?
    if math.random(5) == 1 then
        SPAWN_SHIP = SPAWN_SHIPS[math.random(#SPAWN_SHIPS)]
    end
end

local function get_codon_infostr ( genome )
    local msg = "Winner codons:"
    local codons = dna_mod.enumerate_codons(genome)
    for _, codon in ipairs(codons) do
        msg = msg .. "\n" .. tostring(codon)
    end
    local mods = dna_mod.decode_dna(genome)
    for attribute, value in pairs(mods) do
        msg = msg .. tostring(fmt.f("\n{attr}: {val}", {attr = attribute, val = value} ))
    end
    return msg
end

local FAC_BLUE = "Scientific Research Conglomerate"
local FAC_RED = "Guild of Free Traders"


function display_info ()
    local cur = system.cur()

    if cur:nameRaw() ~= "Evolution Sandbox" then
        player.teleport("Evolution Sandbox")
    else
        print("Already in Evolution Sandbox")
    end

    print("++GENOMES++")
    for fac, sb in pairs(GENOMES) do
        for _i, te in pairs(sb) do
            for genome, v in pairs(te) do
                local msg = ""
                local codons = dna_mod.enumerate_codons(genome)
                for _, codon in ipairs(codons) do
                    msg = msg .. ", " .. tostring(codon)
                end
                local mods = dna_mod.decode_dna(genome)
                for attribute, value in pairs(mods) do
                    msg = msg .. tostring(fmt.f("\n{attr}: {val}", {attr = attribute, val = value} ))
                end
                print(fmt.f("({f}) {v}: {m}", {m=msg,v=v,f=fac}))
            end
        end
    end
    print("--GENOMES--")
end

-- NOTE: Don't use this!
function TEST_RELOAD()
    for i = 0, 1000, 1 do
        local suc = hook.rm(i)
        print(tostring(i) .. " " .. tostring(suc))
    end
end

function load ()
    -- initial setup and restoration
    if not mem.evolution then
        print("mem.evolution not initialized")
        mem.evolution = {}
    else
        for f_id, evo_table in pairs(mem.evolution) do
            if evo_table.genomes ~= nil and #evo_table.genomes > 0 then
                GENOMES[f_id] = evo_table.genomes
                print(fmt.f("restored {d} genomes for {f}", {f=f_id, d=#evo_table.genomes}))
            else
                print("Didn't restore any genomes for " .. tostring(f_id))
                GENOMES[f_id] = {}
            end
        end
    end

    evobtn = player.infoButtonRegister( _("Evolution"), display_info, 3 )
    -- we always load while landed, run the handler
    land()
end

function npc_success( p )
    -- TODO: figure out how to score p based on cargo value or something
end

local function spawn_npc ()
    -- TODO: Spawn a ship, use the miner AI, score it based on how much cargo it brought back
    -- ai/core/idle/miner.lua
end

-- timer helper that checks if the player is still simulating
function EVO_CHECK_SYSTEM()
    local cur = system.cur()
    if cur:nameRaw() ~= "Evolution Sandbox" then
        -- not in the evo system
        return
    end

    -- enforce a boundary
    for _i, sp in pairs(pilot.get()) do
        local excess = sp:pos():dist() - 5000
        if excess > 0 then
            sp:damage(excess * 0.1, 0, 10, "explosion_splash")
            local smem = sp:memory()
            smem.norun = true
            smem.aggressive = true
        end
    end
    
    -- check if each faction has pilots
    local blues = pilot.get(faction.get(FAC_BLUE))
    local reds = pilot.get(faction.get(FAC_RED))
    --
    -- calculate the power
    local blue_power = 0
    local red_power = 0

    for _, bp in pairs(blues) do
        blue_power = blue_power + bp:ship():size()
    end
    for _, rp in pairs(reds) do
        red_power = red_power + rp:ship():size()
    end

    -- replace lost pilots and randomly spawn more
    if not blues or #blues == 0 or math.random(4) == 1 and blue_power < 5 then
        spawn_warrior(FAC_BLUE)
    end

    if not reds or #reds == 0 or math.random(4) == 1 and red_power < 5 then
        spawn_warrior(FAC_RED)
    end

    -- reschedule the control loop
    hook.timer(3, "EVO_CHECK_SYSTEM")
end

function EVO_DISCUSS_RESEARCH ()
    -- first, we figure out where we are
    local spob, _ = spob.cur()
    local fac = spob:faction():nameRaw()
    -- now we will get information about this faction's genome
    local fac_genomes = GENOMES[fac]
--  print(fmt.f("Probing {fac} for genomes...", {fac=fac}))
--  print(fmt.f("found {d} genomes for {f}", {d=#fac_genomes, f=fac}))
    local choices = {}
    for index, g_info in pairs(fac_genomes) do
        for genome, info in pairs(g_info) do
--          print(fmt.f("Genome {i}: {g}", {i=index, g=genome}))
--          for k,v in pairs(info) do
--              print(fmt.f("{k}: {v}",{k=k,v=v}))
--          end
            local label = fmt.f(
                "({score}) {strep} ({hull})",
                {score = info.score, hull = info.hull, strep = string.sub(genome, 1, 8)}
            )
            table.insert(choices, { label, tostring(index) })
        end
    end

    table.insert(choices, { "Nevermind", "end" } )

    local msg = nil
    local choice_id = nil
    vn.reset()
    vn.scene()
    local scientist = vn.newCharacter("Station Scientist", {image = "zalek3.webp"})
    vn.transition()
    scientist(fmt.f("We are currently keeping track of {num} genomes. Want to inspect them?", {num=#fac_genomes}))
    vn.menu( choices )
    for _i, choice in pairs(choices) do
        local gindex = tostring(choice[2])
        if tonumber(gindex) ~= nil then
            vn.label(gindex)
            vn.func( function()
--              print("YOU HAVE SELECTED GENOME NUMBER " .. tostring(gindex))
                local choice_id = gindex
                -- do something with genome
                local g_entry = fac_genomes[tonumber(gindex)]
                local genome = ""
                local g_info = nil
                for gnm, v in pairs(g_entry) do 
                    genome = gnm
                    g_info = v
                end
--              print(genome)
                msg = fmt.f("{g} scored {s} on {h}", {g=string.sub(genome, 1, 16), s=g_info.score, h=g_info.hull})
                local codons = dna_mod.enumerate_codons(genome)
                for _, codon in ipairs(codons) do
                    msg = msg .. ", " .. tostring(codon)
                end
                local mods = dna_mod.decode_dna(genome)
                for attribute, value in pairs(mods) do
                    msg = msg .. tostring(fmt.f("\n{attr}: {val}", {attr = attribute, val = value} ))
                end
--              print(msg)
            end )
            vn.jump("speak_msg")
        end
    end

    vn.label("speak_msg")
    scientist( function() return msg end )
    local affect_choices = {
        { "Forget", "delete" },
        { "Cancel", "end" }
    }
    vn.menu(affect_choices)
    -- affect this genome?
    vn.label("delete")
    vn.func( function ()
        table.remove(fac_genomes, choice_id)
    end )
    vn.label("end")
    scientist( "Alright, see you later." )
    vn.done()
    vn.run()

--  for fac, sb in pairs(GENOMES) do
--      for _i, te in pairs(sb) do
--          for genome, v in pairs(te) do
--              local msg = ""
--              local codons = dna_mod.enumerate_codons(genome)
--              for _, codon in ipairs(codons) do
--                  msg = msg .. ", " .. tostring(codon)
--              end
--              local mods = dna_mod.decode_dna(genome)
--              for attribute, value in pairs(mods) do
--                  msg = msg .. tostring(fmt.f("\n{attr}: {val}", {attr = attribute, val = value} ))
--              end
--              print(fmt.f("({f}) {v}: {m}", {m=msg,v=v,f=fac}))
--          end
--      end
--  end
--  print("--GENOMES--")
end

local function createNpcs()
    local id = evt.npcAdd(
        "EVO_DISCUSS_RESEARCH",
        _("Station Scientist"),
        "zalek3.webp",
        "Talk to this scientist to interact with the evolution plugin.",
        3,
        nil
    )
    print("created an NPC with ID "..tostring(id))
end

function hailed( receiver )
    local rmem = receiver:memory()
    local msg = "My genome provides the following modifications:"
    mods = dna_mod.decode_dna(rmem.genome)
    for attribute, value in pairs(mods) do
        msg = msg .. fmt.f("\n{attr}: {val}", {attr=attribute, val=value})
    end
    msg = msg .. "\nMy current score is " .. tostring(rmem.score)

    -- build the message TODO
    vn.clear()
    vn.scene()
    vn.transition()
    vn.na(msg)
    vn.run()
    -- close the comm
    player.commClose()
end

function land()
    -- check if we are in the right place or if we need to nuke this hook
    local cur = system.cur()
    if cur:nameRaw() ~= "Evolution Sandbox" then
        if mem.evolution_data.lhook ~= nil then
            hook.rm(mem.evolution.lhook)
            mem.evolution.lhook = nil
        end
        return
    end
    -- we're in the right place, make the NPC
    createNpcs()
end

function enter ()
    -- Check if we're in the right system
    local cur = system.cur()
    if cur:nameRaw() ~= "Evolution Sandbox" then
        -- not in the evo system
        return
    end
    -- for each station in the system:
    --   pick a mission at random -> spawn a ship for scoring
    --   use pilot.add( "shipname", "stringfaction", "spob", "pilotname", {params} )
    -- for now: just start the fighting
--    spawn_enemies()
    spawn_warrior(FAC_BLUE)
    spawn_warrior(FAC_RED)

    hook.timer(3, "EVO_CHECK_SYSTEM")
    if not mem.evolution_data then
        mem.evolution_data = {}
    end
    if not mem.evolution_data.lhook then
        mem.evolution_data.lhook = hook.land("land")
    end
end
