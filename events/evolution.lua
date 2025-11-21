--[[
<?xml version='1.0' encoding='utf8'?>
<event name="Evolution Handler">
 <location>load</location>
 <chance>100</chance>
 <unique />
</event>
--]]
--[[
   Evolution Event (v3.2 - Analytics)

   This event runs constantly in the background and manages evolution of ship genomes.

   Changes:
   * Restored 'enumerate_codons' for detailed genetic breakdown.
   * Added Scientist summary (Total Codons / Suppressor count).
   * Restored console debug print in display_info.
--]]
local fmt           = require "format"
local vn            = require "vn"
local spark         = require "luaspfx.spark"
-- NOTE: 'tk' is global, do not require it.

local dna_mod       = require "dna_modifier.dna_modifier"
-- luacheck: globals enter load EVO_CHECK_SYSTEM EVO_DISCUSS_RESEARCH EVO_MECHANIC EVO_SHIP_DEALER EVOLVE SCORE_ATTACKED EVO_MINER_LANDED EVO_TRADER_JUMPED hailed

-- Configuration
local MAX_GENOMES          = 6
local CATACLYSM_CHANCE     = 0.5
local ARENA_RADIUS         = 6000
local FAC_BLUE             = "Scientific Research Conglomerate"
local FAC_RED              = "Guild of Free Traders"
local SIZE_CUTOFF          = 3.0 -- Size threshold for Small vs Big ships

-- Persistent runtime storage
local GENOMES = {}
local SHIP_DEALER_STOCK = {}

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
        local scrapped_ship = table.remove(topScorers)
        if math.random(25) == 1 and #SHIP_DEALER_STOCK < 6 then
            table.insert(SHIP_DEALER_STOCK, scrapped_ship)
        end
    end

    -- Cataclysm
    if math.random(100) < CATACLYSM_CHANCE and #topScorers >= 4 then
        print(fmt.f("CATACLYSM for {f}! Keeping top 3.", {f = f_id}))
        topScorers = { topScorers[1], topScorers[2], topScorers[3] }
        table.insert(SHIP_DEALER_STOCK, topScorers[4]) -- dealer gets the runner up
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
            local pool_genome = genomes[i].genome
            if pool_genome ~= nil then
                table.insert(candidates, dna_mod.mutate_random(pool_genome, mut_rate))
            end
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

function spawn_trader( fac, hull )
    -- Auto-pick hull if missing
    if not hull or not ship.get(hull) then
        local pool = {
            "Koala", "Quicksilver", "Rhino", "Pirate Rhino",
            "Goddard Merchantman", "Llama", "Gawain", "Hyena",
            "Plowshare", "Mule", "Zebra"
        }
        hull = pool[math.random(#pool)]
    end
    local trader = pilot.add(hull, fac, spob.get( faction.get(fac) ), fmt.f(_("Trader {h}"), { h = hull }), { ai = "trader" }) 
    trader:changeAI("trader")
    trader:setFaction(fac)
    local pmem = trader:memory()
    pmem.shield_run = 40
    pmem.armour_run = 90

    local genomes = GENOMES[fac]
    -- give it a random genome
    if genomes and #genomes >= 1 then
        pmem.genome = genomes[math.random(#genomes)].genome
        dna_mod.apply_dna_to_pilot(trader, pmem.genome)
        -- hook it on jumping (success for a trader)
        if not pmem.jhook then
            pmem.jhook = hook.pilot(trader, "jump", "EVO_TRADER_JUMPED")
        end
    end

    return trader
end

function spawn_miner( fac, hull )
    -- Auto-pick hull if missing
    if not hull or not ship.get(hull) then
        local pool = {
            "Koala", "Quicksilver", "Rhino", "Pirate Rhino",
            "Goddard Merchantman", "Llama", "Gawain", "Hyena",
            "Plowshare", "Mule", "Zebra"
        }
        hull = pool[math.random(#pool)]
    end

    local miner = pilot.add(hull, "Miner", spob.get( faction.get(fac) ), nil, { ai = "miner" }) 
    miner:setFaction(fac)
    miner:changeAI("miner")
    local pmem = miner:memory()

    local genomes = GENOMES[fac]
    -- give it a random genome
    if genomes and #genomes >= 1 then
        pmem.genome = genomes[math.random(#genomes)].genome
        dna_mod.apply_dna_to_pilot(miner, pmem.genome)
        -- hook it on landing (success for a miner)
        if not pmem.lhook then
            pmem.lhook = hook.pilot(miner, "land", "EVO_MINER_LANDED")
            -- allow running if actually attacked
            hook.pilot(miner, "attacked", "EVO_MINER_ATTACKED")
        end
    end

    -- can't start with cargo, remove it all
    for _i, v in ipairs(miner:cargoList()) do
        miner:cargoRm(v.c, v.q)
    end

    -- don't be a wimp
    pmem.norun = true
    pmem.shield_run = -1
    pmem.armour_run = 40
    pmem.wimp = true -- for lack of better variable name

    return miner
end

function spawn_warrior(fac, hull, size_class, genome)
    -- Auto-pick hull if missing
    if not hull or not ship.get(hull) then
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
    if math.random(3) == 1 then smem.norun = true end
    if genome ~= nil then
        smem.genome = genome
    else
        smem.genome = get_genome(fac, determine_genome_size(fac))
    end

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
    if #genomes > 3 and math.random(#genomes) == 1 then
        -- spawn runner-up
        top = genomes[2]
    end
    local hull = top.hull
    local champ = spawn_warrior(fac, hull, "big", top.genome)
    hook.pilot(champ, "attacked", "CHAMP_ATTACKED")
    champ:rename(fmt.f("{hull} M-{no}/{fac}", {hull = top.hull, no = top.genome:len(), fac = fac:gsub("[^A-Z]", "")} ))
    champ:broadcast(fmt.f("The {fac} is not to be messed with!", {fac=fac}))
end

function EVO_MINER_ATTACKED(receiver, attacker, amount)
    if receiver:health() < 50 or receiver:health(true) < 10 * amount then
        local rmem = receiver:memory()
        if rmem.norun then
            rmem.norun = false
            spawn_warrior(receiver:faction():nameRaw())
            receiver:broadcast("Will somebody please help me??")
        end
        -- took a big hit and survived
        local rmem = receiver:memory()
        if rmem.score ~= nil then
            rmem.score = rmem.score + amount
        else
            rmem.score = amount
        end
    end
end

-- miners are only scored if they manage to jump
function EVO_TRADER_JUMPED( trader, _destination )
    -- calculate cargo worth
    local total_value = 0
    for _i, v in ipairs(trader:cargoList()) do
        total_value = total_value + v.q * math.max(325, v.c:price())
    end
    local pmem = trader:memory()
    if not pmem.score then pmem.score = 0 end
    local final_score = math.floor((total_value * 0.0247 / trader:ship():size()) + pmem.score)

    local f_id = trader:faction():nameRaw()
    if final_score > 330 and #GENOMES[f_id] < MAX_GENOMES + 3 then
        local hull = trader:ship():nameRaw()
        local genome = pmem.genome
        -- contribute to the genome
        table.insert(GENOMES[f_id], { genome = genome, score  = final_score, hull = hull })

        trader:comm(fmt.f("I escaped with cargo worth {t}! (final score {s})", { t = total_value, s = final_score } ))
    end
    print(fmt.f("{f} {h} jumped with cargo worth {t}! (final score {s})", { t = total_value, s = final_score, h = trader:ship():nameRaw(), f = f_id } ))
end

-- miners are only scored if they manage to land
function EVO_MINER_LANDED(miner, location)
    -- calculate cargo worth
    local total_value = 0
    for _i, v in ipairs(miner:cargoList()) do
        total_value = total_value + v.q * math.max(325, v.c:price())
    end
    local pmem = miner:memory()
    if not pmem.score then pmem.score = 0 end
    local final_score = math.floor((total_value * 0.0247 / miner:ship():size()) + pmem.score)
    -- didn't run? Extra points!
    if miner:cargoFree() == 0 then
        final_score = final_score * 5 / miner:ship():size()
    end

    local f_id = miner:faction():nameRaw()
    -- give the miner a better chance to incorporate the genome
    _ignored = pick_top_genome(f_id) -- prunes & sorts genome table
    if final_score > 300 and #GENOMES[f_id] < MAX_GENOMES + 2 then
        local hull = miner:ship():nameRaw()
        local genome = pmem.genome
        -- contribute to the genome
        table.insert(GENOMES[f_id], { genome = genome, score  = final_score, hull = hull })

        miner:comm(fmt.f("I landed with cargo worth {t}! (final score {s})", { t = total_value, s = final_score } ))
    end
    print(fmt.f("{f} {h} landed with cargo worth {t}! (final score {s})", { t = total_value, s = final_score, h = miner:ship():nameRaw(), f = f_id } ))
end

function EVOLVE(dead_pilot, killer)
    if killer ~= nil and killer:mothership() ~= nil then killer = killer:mothership() end
    local dmem = dead_pilot:memory()
    local score = dmem.score or 0
    local f_id = dead_pilot:faction():nameRaw()
    local genome = dmem.genome
    local hull = dead_pilot:ship():nameRaw()
    local final_score = math.floor(score)

--  dead_pilot:broadcast(fmt.f("I died with a score of {v}", {v = final_score}))

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
        if kmem.score > 1000 then
            killer:broadcast(fmt.f("I have {v} points now!", {v=kmem.score}))
        end

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

local function purchase_sequence ( genome, g_info, price )
    if not mem.genome_bank then
        mem.genome_bank = {}
    end
    if player.credits() >= price then
        player.pay(-price)
        mem.genome_bank[genome] = g_info
        naev.cache().genome_bank = mem.genome_bank -- for cross-plugin integration
        evt.save()
        return true
    end
    return false
end

local function purchase_hull ( hull, genome, price )
    -- got the cash?
    if player.credits() < price then
        return false
    end
    local a_spob, a_sys = spob.cur()
    local strict_name = "Modified " .. hull
    local result_name = player.shipAdd(hull, strict_name, fmt.f("Acquired from a shady dealer at {sp}", { sp = a_spob }), true)
    player.shipvarPush("genome", genome, result_name)

    -- lucky player, finds the ship schematics in the glove box!
    if not mem.genome_bank then
        mem.genome_bank = {}
    end
    mem.genome_bank[genome] = g_info
    naev.cache().genome_bank = mem.genome_bank -- for cross-plugin integration
    evt.save()
    return true
end

local function make_label ( g_data )
    return fmt.f(
        "{g}-{c}/{l} ({s}/{h})",
        {
            g = string.sub(g_data.genome, 1, 4),
            c = string.sub(dna_mod.get_complement(g_data.genome), 1, 4),
            l = g_data.genome:len(),
            h = g_data.hull,
            s = g_data.score
        }
    )
end

-- analyze a genomic sequence as if it was a design schematic
local function analyze_sequence ( entry )
        -- Analytics
        local breakdown_list = dna_mod.enumerate_codons(entry.genome)
        local suppressor_count = 0
        local breakdown_str = ""
        for _, item in ipairs(breakdown_list) do
            if string.find(item, "suppress") then
                suppressor_count = suppressor_count + 1
            end
            breakdown_str = breakdown_str .. "\n - " .. item
        end

        local msg = fmt.f("Hull: {h}\nScore: {s}\nLabel: {g}...", {h=entry.hull, s=entry.score, g=make_label(entry)})

        -- The requested summary:
        msg = msg .. fmt.f("\n\nThe schematics detail {c} distinct modifications, {s} of which include advanced technology.", {c=#breakdown_list, s=suppressor_count})

        msg = msg .. "\n\n[Net Attributes]"
        local mods = dna_mod.decode_dna(entry.genome)
        for k, v in pairs(mods) do msg = msg .. "\n" .. k .. ": " .. v end

        msg = msg .. "\n\n[Codon Breakdown]" .. breakdown_str

        return msg
end

function EVO_SHIP_DEALER( npc_id )
    -- pick a random genome from the local database
    local loc = spob.cur()
    local fac = loc:faction():nameRaw()
    local stolen_hulls = SHIP_DEALER_STOCK
    local g_ind = math.random(#stolen_hulls)
    local g_info = stolen_hulls[g_ind]
    table.remove(SHIP_DEALER_STOCK, g_ind)
    if not g_info then
        g_info = { genome = dna_mod.generate_junk_dna(64), hull = "Quicksilver", score = 117 }
    end
    local _oprice, price = ship.get(g_info.hull):price()
    price = price + g_info.score * g_info.genome:len()

    -- enumerate techs
    local breakdown_list = dna_mod.enumerate_codons(g_info.genome)
    local num_mods = 0
    local num_tech = 0
    for _i, item in ipairs(breakdown_list) do
        if string.find(item, "suppress") then
            num_tech = num_tech + 1
        else 
            num_mods = num_mods + 1
        end
        print(item)
    end

    local extra = ""
    if math.random(2) == 1 and num_tech > 1 then
        extra = fmt.f(_("It comes with at least {num} high-tech upgrades!"), { num = math.random(2, num_tech) })
    end

    local msg_bye = _("You're attracting too much attention.")
    vn.reset()
    vn.scene()
    local dealer = vn.newCharacter(_("Shady Ship Dealer"), {image = "scavenger1.png"})
    vn.transition()
    vn.label("start")
    dealer(fmt.f(_("Interested in a {hull} with {num} modifications? {extra}"), { hull = g_info.hull, num = num_mods, extra = extra }))
    vn.menu({
        {_("Tell me more!"), "ship_detail"},
        {_("No thanks."), "sayonara"},
    })
    vn.label("ship_detail")
    if math.random(2) == 1 then
        if num_tech > 1 then
            extra = fmt.f(_("Did I mention that it comes with {num} high-tech upgrades?"), { num = num_tech })
        else
            extra = ""
        end
    else
        local amt = math.ceil(g_info.score * g_info.genome:len() * math.random(2,8))
        extra = fmt.f(_("The schematics alone are worth at least {amount}"), { amount = fmt.credits(amt) })
    end
    dealer(fmt.f(_("I only want a measly {amount} for it, what do you say? {extra}"), { amount = fmt.credits(price), extra = extra }))
    vn.menu({
        {_("I'll take it!"), "purchase_hull"},
        {_("No thanks."), "sayonara"}
    })
    vn.label("purchase_hull")
    vn.func(function()
        if purchase_hull( g_info.hull, g_info.genome, price ) then
            vn.sfxMoney()
            msg_bye = _("Pleasure doing business with you.")
        else
            msg_bye = _("Don't waste my time, kid.")
        end
    end)
    -- intentional fallthrough
    vn.label("sayonara")
    dealer(function() return msg_bye end)
    vn.done()
    vn.run()
    evt.npcRm( npc_id )
end

function EVO_MECHANIC()
    vn.reset()
    vn.scene()
    local mechanic = vn.newCharacter("Shipyard Mechanic", {image = "old_man.png"})
    vn.transition()

    local msg_bye = "Catch you later."
    vn.label("start")
    local ps = player.pilot():ship()
    local price = ps:size() * 75000 - 25000
    mechanic(fmt.f(_("Welcome to the shipyard, we'll take good care of your {stype} for the low price of just {price}. Did you bring the schematics?"), { stype = ps:name(), price = fmt.credits(price)}))
    local choices  = {}
    local bank_key = nil
    for g_key, g_info in pairs(mem.genome_bank) do
        local label = make_label(g_info)
        table.insert(choices, { label, label })
        vn.label(label)
        vn.func(function()
            bank_key = g_key
            vn.jump("mechanic_ready")
        end)
    end

    if player.shipvarPeek("genome") then
        table.insert(choices, { _("Remove Modifications"), "remove" })
    end
    table.insert(choices, { _("Nevermind"), "end" })

    vn.label("mechanic_ready")
    vn.menu(choices)
    -- what to do with the selected schematic
    vn.func(function()
        local ng = mem.genome_bank[bank_key].genome
        if player.credits() >= price and ng then
            player.pilot():intrinsicReset()
            player.shipvarPush("genome", ng)
            -- NOTE: The mechanic isn't perfect
            local error_rate = 0.001 * ps:size()
            dna_mod.apply_dna_to_pilot(player.pilot(), dna_mod.mutate_random(ng, error_rate))
            msg_bye = _("Alright, that should do it. Why don't you take her for a spin?")
            player.pay(-price)
            vn.sfxMoney()
        elseif not ng then
            msg_bye = _("My time isn't free, you know!")
            vn.sfxEerie()
        end
    end)
    vn.jump("end")

    vn.label("remove")
    vn.func(function()
        player.shipvarPop("genome")
        player.pilot():intrinsicReset()
        msg_bye = _("No problem. She's exactly like a stock model, you won't be able to tell the difference!")
    end)
    vn.label("end")
    mechanic(function () return msg_bye end)
    vn.done()
    vn.run()
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
    scientist("How can I assist with our ongoing research project?")

    local choices = {
        {"Browse Blueprints", "view_genomes"},
        {"Access Terminal", "manage_bank"},
        {"Manage Ships", "manage_ships"},
        {"Scrap Research", "reset_research"},
        {"Leave", "end"}
    }
    local bye_msg = "Farewell."
    vn.menu(choices)

    vn.label("reset_research")
    vn.func(function()
        for i = #fac_genomes, 1, -1 do
            table.remove(fac_genomes, i)
        end
        -- insert a new genome
        table.insert(fac_genomes, { genome = dna_mod.generate_junk_dna(determine_genome_size(fac)), score=1, hull="Llama"})
    end)
    scientist(_("Well, okay then. Sometimes it's better to start from zero."))
    vn.jump("end")

    vn.label("manage_bank")
    vn.move(scientist, "farleft")
    local terminal = vn.newCharacter("Computer Terminal", {image = "minerva_terminal.png"})
    terminal("Please select a schematic.")
    local bank_choices  = {}
    local bank_key = nil
    for g_key, g_info in pairs(mem.genome_bank) do
        local label = make_label(g_info)
        table.insert(bank_choices, { label, label })
        vn.label(label)
        vn.func(function()
            bank_key = g_key
            vn.jump("terminal_open")
        end)
    end

    local poff = { _("Power off"), "terminal_end" }
    table.insert(bank_choices, poff)

    vn.label("terminal_open")
    vn.menu(bank_choices)
    -- what to do with the selected schematic
    local bank_opts = {
        { _("Overview"), "detail" },
        { _("Examine Schematic"), "examine_genome" },
        { _("Print copy"), "print_schematic" },
        { _("Delete schematic"), "delete_bank" },
        { _("Back to list"), "terminal_open" },
        poff
    }
    vn.label("bkey_select_done")
    vn.func(function()
        msg = "The data seems corrupted."
        if mem.genome_bank[bank_key] ~= nil then
            msg = "You have selected schematic " .. make_label(mem.genome_bank[bank_key])
        end
    end)
    terminal(function () return msg end)
    vn.label("bank_opts")
    vn.menu(bank_opts)
    vn.label("detail")
    terminal( function()
        local genome = mem.genome_bank[bank_key].genome
        if not genome then
            msg = "Error!"
            return
        end
        msg = ""
        local expected = dna_mod.decode_dna(genome)
        for attribute, xpctd in pairs(expected) do
            msg = msg .. (fmt.f("\n{attr}: {x}", { attr = attribute, x = xpctd } ))
        end
        return(msg)
    end )

    vn.jump("bank_opts")
    vn.label("print_schematic")
    local printed_schematic -- can be used by splice later TODO
    vn.func(function()
        msg = "The printer doesn't seem to be working."
        printed_schematic = mem.genome_bank[bank_key].genome
        if printed_schematic ~= nil then
            msg = fmt.f("The {s} schematics have been sent to the printer.", { s = make_label(mem.genome_bank[bank_key]) })
        end
    end)
    terminal(function () return msg end)
    vn.move(terminal, "farright")
    vn.move(scientist)


    vn.jump("start")

    vn.label("examine_genome")
    terminal(function()
        local entry = mem.genome_bank[bank_key]
        return analyze_sequence(entry)
    end)
    vn.jump("bank_opts")

    vn.label("delete_bank")
    terminal(function () return fmt.f("Are you sure you want to permanently delete the {g} schematics?", { g = make_label(mem.genome_bank[bank_key]) })
    end)
    vn.menu({
        { _("Yes, I'm sure!"), "confirm_delete_bank" },
        { _("Nevermind"), "terminal_open" },
    })
    vn.label("confirm_delete_bank")

    vn.func(function()
        mem.genome_bank[bank_key] = nil
    end)

    vn.label("terminal_end")
    vn.disappear(terminal)
    vn.move(scientist)
    bye_msg = _("Let me know if you need anything else.")
    vn.jump("end")

    -- === GENOME SECTION ===
    vn.label("view_genomes")
    local g_choices = {}
    for i, entry in ipairs(fac_genomes) do
        if entry.genome then
            local label = fmt.f("({s}) {g}/{l} ({hull})", { s=entry.score, g=string.sub(entry.genome,1,8), l=entry.genome:len(), hull=entry.hull })
            table.insert(g_choices, { label, "set_g_idx_"..i })
       end
    end
    table.insert(g_choices, {"Back", "start"})

    scientist(fmt.f("We have {n} blueprints available.", {n=#fac_genomes}))
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
        if not entry then return "Error: Schematic lost." end
        return analyze_sequence(entry)
    end)

    vn.menu({
        {"Purchase Sequence", "g_buy"},
        {"Prototype new hull", "g_hull"},
        {"Simplify", "g_rad"},
        {"Improve", "g_splice"},
        {"Forget", "g_del"},
        {"Back", "view_genomes"}
    })

    vn.label("g_buy")
    local price = 0
    local entry
    vn.func(function()
        entry = fac_genomes[selected_genome_idx]
        price = math.ceil(entry.score * entry.genome:len() * 0.1)
    end)
    scientist(function() return fmt.f("That'll cost you {v}, still want it?", {v=fmt.credits(price)}) end)
    vn.menu({
        {"Yes", "confirm_buy"},
        {"No thanks", "end"}
    })
    vn.label("confirm_buy")
    vn.sfxMoney()
    msg = "Alright then, here you go."
    vn.func(function()
        if entry then
            purchase_sequence(entry.genome, entry, price)
        else
            msg = "Something went wrong, sorry, but the information is unusable."
        end
    end)
    scientist(function() return msg end)
    vn.jump("end")

    vn.label("g_hull")
    vn.func(function()
        local entry = fac_genomes[selected_genome_idx]
        if entry then
            local ships_data = mem.evolution[fac].ships
            local size_class = "small"
            if math.random(6) == 1 then size_class = "big" end
            -- hidden logic: top-listed genome more likely to receive funding
            if selected_genome_idx == 1 and math.random(10) > 1 then
                size_class = "big"
            end
            entry.hull = ships_data[size_class][math.random(#ships_data[size_class])]
        end
    end)
    scientist(function() return fmt.f("We'll experiment on the {hull}.", {hull = fac_genomes[selected_genome_idx].hull}) end)
    vn.jump("end")

    vn.label("g_rad")
    scientist("The available areas to target are:\nterminator, defense, propulsion, weaponry, utility\nNote that the purpose of blueprint simplification is to change or remove an existing feature. Removing a 'terminator' can often result in substantial changes. All changes have a chance of having a cascading effect due to tight system integration.")
    vn.func(function()
        local entry = fac_genomes[selected_genome_idx]
        if entry then
            local target = tk.input("Schematic Simplification", 4, 16, "target area")
            if target then
                -- remove the old one (consumed by research)
                table.remove(fac_genomes, selected_genome_idx)
                local res = dna_mod.research_irradiate(entry.genome, target)
                table.insert(fac_genomes, { genome=dna_mod.mutate_random(res, 0.006), score=entry.score, hull=entry.hull })
            end
        end
    end)
    scientist("We'll replace the old schematics in this blueprint with the new suggestions.")
    vn.jump("end")

    vn.label("g_splice")
    vn.func(function() 
        -- if there's no printed schematic, generate a random doodle that happens to be lying around
        if not printed_schematic then
            printed_schematic = dna_mod.generate_junk_dna(42)
        end
        msg = "Let's see if we can draw some inspiration from the schematics I have lying around:"
        local breakdown_list = dna_mod.enumerate_codons(printed_schematic)
        for _, item in ipairs(breakdown_list) do
            msg = msg .. "\n - " .. item
        end
    end)
    scientist(function () return msg end)
    -- logical separation in case of donor logic changes
    vn.func(function()
        local entry = fac_genomes[selected_genome_idx]
        if entry then
            local target = tk.input("Blueprint Research", 4, 16, "target codon")
            local donor = printed_schematic
            if target and donor then
                local outcome = dna_mod.research_splice(entry.genome, donor, target)
                msg = outcome.log
                -- remove the old one (consumed by research)
                if outcome.dna then
                    table.remove(fac_genomes, selected_genome_idx)
                    table.insert(fac_genomes, { genome=outcome.dna, score=entry.score, hull=entry.hull })
                end
            end
        end
    end)
    vn.na(function() return msg end)
    vn.jump("end")

    vn.label("g_del")
    vn.func(function()
        local scrapped_ship = table.remove(fac_genomes, selected_genome_idx)
        msg = "We'll throw out those blueprints. I don't think we really needed them anyway."
        if math.random(2) == 1 then
            table.insert(SHIP_DEALER_STOCK, scrapped_ship)
            msg = _("We'll get rid of the prototype and focus our research elsewhere.")
        end
    end)
    scientist(function() return msg end)
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
            if not ok then print("Ship Add Error: "..res) end
        end
    end)
    vn.jump("manage_ships")

    vn.label("s_remove")
    vn.func(function()
        local input = tk.input("Ship Hull", 3, 30, "Hull Name")
        if input then remove_ship_from_pool(fac, input) end
    end)
    vn.jump("manage_ships")

    -- === END ===
    vn.label("end")
    scientist(function() return bye_msg end)
    vn.done()
    vn.run()
end

local function createNpcs()
    local _id = evt.npcAdd("EVO_DISCUSS_RESEARCH", _("Ship Researcher"), "zalek3.webp", _("You see the station's Ship Researcher, who is in charge of all the research and schematics around here."), 6)
    _id = evt.npcAdd("EVO_MECHANIC", _("Shipyard Engineer"), "old_man.png", "The Shipyard Engineer has so much experience in tinkering with spaceships that he can adapt your ship to any blueprint schematics you provide him with. You can't help but wonder if such an old man could really pull off complicated jobs without making mistakes.", 7)
    _id = evt.npcAdd("EVO_SHIP_DEALER", _("Shady Dealer"), "pirate/pirate_militia2.webp", _("A shady figure signals you to come over. It's obvious by the hand signals that you're about to score some kind of black market deal."), 7)
end

function hailed(receiver)
    local rmem = receiver:memory()
    if not rmem.score then rmem.score = 0 end

    -- Analytics for hail
    local breakdown_list = dna_mod.enumerate_codons(rmem.genome)
    local suppressor_count = 0
    for _, item in ipairs(breakdown_list) do
        if string.find(item, "suppress") then suppressor_count = suppressor_count + 1 end
    end

    local msg = fmt.f("Genome ({g})... Score: {s}", {g = string.sub(rmem.genome, 1, 8), s=rmem.score})
    msg = msg .. fmt.f("\nSummary: {c} active codons ({s} suppressors)", {c=#breakdown_list, s=suppressor_count})

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

-- Restored debug display for devs
function display_info()
    print("++GENOMES++")
    for fac, genomes in pairs(GENOMES) do
        local s_pool = mem.evolution[fac] and mem.evolution[fac].ships.small or {}
        local b_pool = mem.evolution[fac] and mem.evolution[fac].ships.big or {}
        print(fmt.f("Faction {f} :: Small: {s}, Big: {b}", {f=fac, s=#s_pool, b=#b_pool}))

        for i, entry in ipairs(genomes) do
            local msg = ""
            -- Use the enumerate functionality here too
            local codons = dna_mod.enumerate_codons(entry.genome)
            for _, codon in ipairs(codons) do msg = msg .. ", " .. tostring(codon) end
            print(fmt.f("({f}) {v}: {m}", {m=msg,v=entry.score,f=fac}))
        end
    end
    print("--GENOMES--")
end

function load()
--  local diffname = "evo_ngc2601_connection"
--  if not diff.isApplied(diffname) then
--      diff.apply(diffname)
--  end
    if not mem.evolution then mem.evolution = {} end
    init_ship_tables(FAC_BLUE)
    init_ship_tables(FAC_RED)

    for f_id, evo_table in pairs(mem.evolution) do
        if evo_table.genomes then GENOMES[f_id] = evo_table.genomes else GENOMES[f_id] = {} end
        init_ship_tables(f_id)
    end

    -- for cross-plugin integration
    naev.cache().genome_bank = mem.genome_bank

    player.infoButtonRegister(_("Evolution"), display_info, 3)
    land()
end

function enter()
    local genome = player.shipvarPeek("genome")
    if genome then dna_mod.apply_dna_to_pilot(player.pilot(), genome) end

    local cur = system.cur()
    if cur:nameRaw() ~= "Evolution Sandbox" then return end

    -- spawn champions first!
    spawn_champion(FAC_BLUE)
    spawn_champion(FAC_RED)
    hook.timer(3, "EVO_CHECK_SYSTEM")

    if not mem.evolution_data then mem.evolution_data = {} end
    if not mem.evolution_data.lhook then mem.evolution_data.lhook = hook.land("land") end
end

local function calc_power ( group )
    local pow = 0
    for _, p in ipairs(group) do
        local pmem = p:memory()
        if pmem.genome ~= nil then
            if pmem.score and pmem.score > 100 then
                pow = pow + p:ship():size()
            elseif pmem.wimp then
                pow = pow + 0.5
            else
                pow = pow + 0.2 * p:ship():size()
            end
        end
    end
    return pow
end

local MINERS = {}
local TRADERS = {}
-- Arena Loop
function EVO_CHECK_SYSTEM()
    local cur = system.cur()
    if cur:nameRaw() ~= "Evolution Sandbox" then return end

    local aps = pilot.get()
    -- Boundary Check
    for _, sp in ipairs(aps) do
        -- reduce population
        local pop = #aps
        if pop > 20 then
            sp:damage(pop * sp:ship():size(), 0, 10, "explosion_splash")
        end
        local dist = sp:pos():dist()
        if dist > ARENA_RADIUS then
            local spmem = sp:memory()
            if spmem.genome then
                sp:damage(dist * 0.00016, 0, 10, "explosion_splash") -- gentle nudge damage
                spark(sp:pos(), sp:vel()*-1, 50)
                spmem.aggressive = true
            end
        end
    end
    
--[[ spawn civs here --]]
    local roll = math.random(10)
    if roll == 1 then
        local mp = MINERS[FAC_BLUE]
        if not mp or not mp:exists() then
            MINERS[FAC_BLUE] = spawn_miner(FAC_BLUE)
        end
    elseif roll == 2 then
        local mp = MINERS[FAC_RED]
        if not mp or not mp:exists() then
            MINERS[FAC_RED] = spawn_miner(FAC_RED)
        end
    elseif roll == 3 then
        local tp = TRADERS[FAC_BLUE]
        if not tp or not tp:exists() then
            TRADERS[FAC_BLUE] = spawn_trader(FAC_BLUE)
        end
    elseif roll == 4 then
        local tp = TRADERS[FAC_RED]
        if not tp or not tp:exists() then
            TRADERS[FAC_RED] = spawn_trader(FAC_RED)
        end
    end
    --]]

    local blues = pilot.get(faction.get(FAC_BLUE))
    local reds = pilot.get(faction.get(FAC_RED))

    -- blind spots
    if not blues and not reds and math.random(5) > 1 then
        hook.timer(math.random(12), "EVO_CHECK_SYSTEM")
    end

    -- periodic pause
    if blues and reds and math.random(2) == 1 then
        hook.timer(10 + math.random(5), "EVO_CHECK_SYSTEM")
        return
    end
    local b_pow, r_pow = calc_power(blues), calc_power(reds)

    -- Blue Logic
    if not blues or #blues == 0 or (math.random(4)==1 and b_pow < 5) then
        if math.random(10) == 1 then spawn_champion(FAC_BLUE)
        elseif r_pow > 8 then spawn_warrior(FAC_BLUE, nil, "big")
        else spawn_warrior(FAC_BLUE, nil, "small") end
    end

    -- Red Logic
    if not reds or #reds == 0 or (math.random(4)==1 and r_pow < 5) then
        if math.random(10) == 1 then spawn_champion(FAC_RED)
        elseif b_pow > 8 then spawn_warrior(FAC_RED, nil, "big")
        else spawn_warrior(FAC_RED, nil, "small") end
    end


    hook.timer(3 + math.random(5), "EVO_CHECK_SYSTEM")
end
