--[[
<?xml version='1.0' encoding='utf8'?>
<event name="DNA Testing">
 <location>load</location>
 <chance>100</chance>
</event>
--]]
-- luacheck globals HANDLE_INPUT (Hook functions passed by name)

-- enable this event by increasing the chance in the header

local fmt = require "format"
local vn = require "vn"
local dna_mod = require "dna_modifier.dna_modifier"

local genome = ""

local function vnDNA ()
    genome = player.pilot():shipvarPeek("genome")
    if not genome then genome = "" end
    mem.genome_bank = naev.cache().genome_bank
    if not mem.genome_bank then mem.genome_bank = {} end
    local restart = false
    local complement = dna_mod.get_complement(genome)
    local msg = fmt.f("The current genome is {g}\nThe complement is {c}", {g = genome, c = complement})
    local codons = dna_mod.enumerate_codons(genome)
    for _, codon in ipairs(codons) do
        msg = msg .. "\n" .. tostring(codon)
    end
    local mods = dna_mod.decode_dna(genome)
    for attribute, value in pairs(mods) do
        msg = msg .. tostring(fmt.f("\n{attr}: {val}", {attr = attribute, val = value} ))
    end
    local choices = {
        { _("Add DNA"), "add" },
        { _("Set DNA"), "set" },
        { _("Mutate DNA"), "mutate" },
        { _("Irradiate DNA"), "irradiate" },
        { _("Stabilize DNA"), "stabilize" },
        { _("Splice DNA"), "splice" },
        { _("Details"), "detail" },
        { _("Done"), "end" },
    }
    vn.clear()
    vn.scene()
    vn.transition()
    vn.na(msg)
    vn.menu(choices)
    local pp = player:pilot()
    vn.label("add")
    vn.func( function() 
        local addno = tonumber(tk.input( "New Genome", 1, 4, "Length"))
        if addno ~= nil then
            genome = dna_mod.generate_junk_dna(addno)
            mods = dna_mod.apply_dna_to_pilot(pp, genome)
            msg = fmt.f("The genome is now {g}", {g = genome})
            restart = true
        end
    end )
    vn.jump("end")
    vn.label("set")
    vn.func( function()
        genome = tk.input( "New Genome", 4, 256, "Nucleotide sequence")
        mods = dna_mod.apply_dna_to_pilot(pp, genome)
        msg = fmt.f("The genome is now {g}", {g = genome})
        restart = true
    end)
    vn.jump("end")
    vn.label("mutate")
    vn.func( function() 
        local mrate = tonumber(tk.input( "Mutation", 1, 5, "mutation chance (0-1)"))
        genome = dna_mod.mutate_random(genome, mrate)
        mods = dna_mod.apply_dna_to_pilot(pp, genome)
        msg = fmt.f("The genome is now {g}", {g = genome})
        restart = true
    end )
    vn.jump("end")
    vn.label("irradiate")
    vn.na("The available mutagens to target are:\nterminator, defense, propulsion, weaponry, utility\nNote that the purpose of radiation research is to neutralize the target mutagen.")
    vn.func( function() 
        local target = tk.input("Radiation Target", 4, 16, "mutagen type")
        if target then
            genome = dna_mod.research_irradiate(genome, target)
            mods = dna_mod.apply_dna_to_pilot(pp, genome)
            msg = fmt.f("The genome is now {g}", {g = genome})
            restart = true
        end
    end )
    vn.jump("end")
    vn.label("stabilize")
    vn.func(function()
        local target = tk.input( "Stabilize DNA", 4, 16, "target tag" )
        local outcome = dna_mod.research_stabilize(genome, target)
        genome, msg = outcome.dna, outcome.log
        mods = dna_mod.apply_dna_to_pilot(pp, genome)
    end)
    vn.na(function() return msg end)
    vn.jump("end")
    vn.label("splice")
    vn.na("Which donor DNA to use?")
    local donor_choices = { {"Synthetic junk DNA", "splice_ready"} }
    print("in bank:")
    for g, gi in pairs(mem.genome_bank) do
        print(tostring(g))
    end
    for _seq, g_data in pairs(mem.genome_bank) do
        local seq_id = fmt.f(
            "{g}-{c}/{l} ({s}/{h})",
            {
                g = string.sub(g_data.genome, 1, 4),
                c = string.sub(dna_mod.get_complement(g_data.genome), 1, 4),
                l = g_data.genome:len(),
                h = g_data.hull,
                s = g_data.score
            }
        )
        table.insert(donor_choices, { seq_id , seq_id })
        vn.label(seq_id)
        vn.func(function()
            donor = g_data.genome
        end)
    end
    vn.func(function()
        donor = dna_mod.generate_junk_dna(62)
    end)
    vn.menu(donor_choices)

    vn.label("splice_ready")
    vn.func(function()
        local target = tk.input( "Splice DNA", 4, 24, "target codon" )
        local outcome = dna_mod.research_splice(genome, donor, target)
        genome, msg = outcome.dna, outcome.log
        mods = dna_mod.apply_dna_to_pilot(pp, genome)
    end)
    vn.na(function() return msg end)
    vn.jump("end")
    vn.label("detail")
    vn.func( function()
        print("\nPRINTING DETAILS\n================")
        local all_stats = pp:intrinsicGet()
        msg = ""
--      for attribute, value in pairs(all_stats) do
--          msg = msg .. (fmt.f("\n{attr}: {val}", {attr = attribute, val = value} ))
--      end
        local expected = dna_mod.decode_dna(genome)
        for attribute, xpctd in pairs(expected) do
            local value = pp:intrinsicGet(attribute)
            msg = msg .. (fmt.f("\n{attr}: {val} (expected {x})", {attr = attribute, val = value, x = xpctd} ))
        end
        print(msg)
    end )
    vn.na(function() return msg end)
    vn.label("end")
    vn.done()
    vn.run()

    if mods ~= nil and #mods ~= 0 then
        print("Found mods!")
        for attribute, value in pairs(mods) do
            print(fmt.f("{attr}: {val}", {attr = attribute, val = value} ))
        end
    end
    print("Current Genome: ", pp:shipvarPeek("genome"))

    if restart then
        vnDNA()
    end
end

local dnabutton
function create ()
    print("Loading DNA Tester...")
    -- TODO HERE: Something
    dnabutton = player.infoButtonRegister ( _("DNA"), vnDNA, 3 )
    print("DNA Tester:  Loaded!!")
end

