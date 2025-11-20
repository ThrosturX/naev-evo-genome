--[[
dna_modifier.lua (v7.0 - Grid-Locked Terminators)

Changes v7.0:
- TERMINATORS are now strictly grid-aligned (must start at 1, 5, 9...).
- Added secondary terminator "TGAA" to CODON_MAP.
- Removed string.find(TERMINATOR) logic; decoders now scan the grid.
- `mutate_random` pads output to ensure 4-char alignment for safety terminators.
--]]

local DnaModifier = {}

-- Cache standard libraries for performance
local m_random = math.random
local m_floor = math.floor
local m_max = math.max
local m_min = math.min
local s_sub = string.sub
local t_insert = table.insert
local t_concat = table.concat

-- Basic DNA configuration
local NUCLEOTIDES = { "A", "T", "C", "G" }
local CODON_LENGTH = 4
local TERMINATOR_CODON = "TAGG" -- Default for appending

local FLAT_INTRINSICS = {
    armour = true, armour_regen = true, mass = true, cpu = true, crew = true,
    cargo = true, fuel = true, energy = true, shield = true,
    stress_dissipation = true,
}

-- ####################################################################
-- #    CODON DEFINITIONS (IMMUTABLE)
-- ####################################################################

local CODON_MAP = {
    -- Terminators (Grid-Locked)
    ["TAGG"] = { type = "terminator", category = "terminator" },
    ["TGAA"] = { type = "terminator", category = "terminator" }, -- Secondary terminator
    ["TAAA"] = { type = "terminator", category = "terminator" }, -- Tertiary terminator

    -- Group: Hull & Defense Systems
    ["GCAT"] = { type = "positive", category = "defense", attribute = "armour_mod", value = 0.10, debuffs = { { attribute = "mass_mod", value = 0.08, tag = "HEAVY_MASS" }, { attribute = "turn_mod", value = -0.05, tag = "INERTIA" } } },
    ["AGCC"] = { type = "positive", category = "defense", attribute = "armour_mod", value = 0.08, debuffs = { { attribute = "energy_mod", value = -0.06, tag = "ENERGY_DRAIN" } } },
    ["GCTA"] = { type = "positive", category = "defense", attribute = "armour_mod", value = 0.12, debuffs = { { attribute = "fuel_mod", value = -0.10, tag = "ENERGY_DRAIN" } } },
    ["TCTC"] = { type = "positive", category = "defense", attribute = "shield_mod", value = 0.15, debuffs = { { attribute = "stress_dissipation", value = -20, tag = "SHIELD_OVERLOAD" } } },
    ["AGTC"] = { type = "positive", category = "defense", attribute = "shield_regen", value = 0.10, debuffs = { { attribute = "shield_mod", value = -0.05, tag = "SHIELD_OVERLOAD" } } },
    ["CGCG"] = { type = "positive", category = "defense", attribute = "armour", value = 125, debuffs = { { attribute = "accel_mod", value = -0.05, tag = "INERTIA" } } },
    ["CGCT"] = { type = "positive", category = "defense", attribute = "armour", value = 50, debuffs = { { attribute = "mass", value = 50, tag = "HEAVY_MASS" } } },
    ["AATT"] = { type = "positive", category = "defense", attribute = "armour_regen", value = 1, debuffs = { { attribute = "armour_mod", value = -0.10, tag = "ARMOR_WEAK" } } },
    ["AATG"] = { type = "positive", category = "defense", attribute = "armour_regen", value = 2, debuffs = { { attribute = "armour_mod", value = -0.15, tag = "ARMOR_WEAK" } } },
    ["AATA"] = { type = "positive", category = "defense", attribute = "armour_regen", value = 3, debuffs = { { attribute = "armour_mod", value = -0.15, tag = "ARMOR_WEAK" }, { attribute = "mass_mod", value = 0.1, tag = "HEAVY_MASS" } } },
    ["ATTA"] = { type = "positive", category = "defense", attribute = "shield_regen_mod", value = 0.12, debuffs = { { attribute = "shield_mod", value = -0.08, tag = "SHIELD_OVERLOAD" } } },
    ["ATTG"] = { type = "positive", category = "defense", attribute = "shield_regen_mod", value = 0.20, debuffs = { { attribute = "shield_mod", value = -0.15, tag = "SHIELD_OVERLOAD" }, { attribute = "energy_regen_mod", value = -0.10, tag = "ENERGY_DRAIN" } } },
    ["ATTT"] = { type = "positive", category = "defense", attribute = "shield_regen_mod", value = 0.28, debuffs = { { attribute = "shield_mod", value = -0.20, tag = "SHIELD_OVERLOAD" }, { attribute = "energy_regen_mod", value = -0.15, tag = "ENERGY_DRAIN" }, { attribute = "stress_dissipation", value = -10, tag = "SHIELD_OVERLOAD" } } },
    ["CATC"] = { type = "positive", category = "defense", attribute = "stress_dissipation", value = 3, debuffs = { { attribute = "shield_mod", value = -0.10, tag = "SHIELD_OVERLOAD" } } },
    ["CATA"] = { type = "positive", category = "defense", attribute = "stress_dissipation", value = 5, debuffs = { { attribute = "shield_mod", value = -0.15, tag = "SHIELD_OVERLOAD" }, { attribute = "energy_mod", value = -0.05, tag = "ENERGY_DRAIN" } } },
    ["ACTA"] = { type = "positive", category = "defense", attribute = "shielddown_mod", value = -0.10, debuffs = { { attribute = "shield_mod", value = -0.15, tag = "SHIELD_OVERLOAD" } } },
    ["ACTG"] = { type = "positive", category = "defense", attribute = "shielddown_mod", value = -0.20, debuffs = { { attribute = "shield_mod", value = -0.25, tag = "SHIELD_OVERLOAD" }, { attribute = "energy_mod", value = -0.10, tag = "ENERGY_DRAIN" } } },
    ["ACTC"] = { type = "positive", category = "defense", attribute = "shielddown_mod", value = -0.30, debuffs = { { attribute = "shield_mod", value = -0.35, tag = "SHIELD_OVERLOAD" }, { attribute = "energy_mod", value = -0.15, tag = "ENERGY_DRAIN" }, { attribute = "ew_signature", value = 0.10, tag = "SENSOR_STRAIN" } } },

    -- Group: Mobility & Propulsion
    ["CTAG"] = { type = "positive", category = "propulsion", attribute = "speed_mod", value = 0.10, debuffs = { { attribute = "armour_mod", value = -0.08, tag = "ARMOR_WEAK" } } },
    ["GTAC"] = { type = "positive", category = "propulsion", attribute = "speed_mod", value = 0.08, debuffs = { { attribute = "energy_regen_mod", value = -0.10, tag = "ENERGY_DRAIN" } } },
    ["CTCA"] = { type = "positive", category = "propulsion", attribute = "accel_mod", value = 0.12, debuffs = { { attribute = "mass_mod", value = -0.05, tag = "FRAGILE_HULL" } } },
    ["GACC"] = { type = "positive", category = "propulsion", attribute = "turn_mod", value = 0.15, debuffs = { { attribute = "cpu_mod", value = -0.10, tag = "UTILITY_COST" } } },
    ["TCGT"] = { type = "positive", category = "propulsion", attribute = "jump_distance", value = 0.15, debuffs = { { attribute = "jump_warmup", value = 0.20, tag = "SENSOR_STRAIN" } } },
    ["CCCC"] = { type = "positive", category = "propulsion", attribute = "mass_mod", value = -0.10 },
    ["CCCT"] = { type = "positive", category = "propulsion", attribute = "mass_mod", value = -0.18, debuffs = { { attribute = "armour_mod", value = -0.10, tag = "FRAGILE_HULL" } } },
    ["CCCA"] = { type = "positive", category = "propulsion", attribute = "mass_mod", value = -0.25, debuffs = { { attribute = "armour_mod", value = -0.18, tag = "FRAGILE_HULL" }, { attribute = "turn_mod", value = -0.05, tag = "INERTIA" } } },

    -- Group: Weapon & Energy Systems
    ["AGAT"] = { type = "positive", category = "weaponry", attribute = "tur_damage", value = 0.08, debuffs = { { attribute = "tur_firerate", value = -0.06, tag = "WEAPON_OVERHEAT" } } },
    ["TCGC"] = { type = "positive", category = "weaponry", attribute = "tur_firerate", value = 0.10, debuffs = { { attribute = "tur_damage", value = -0.08, tag = "WEAPON_OVERHEAT" } } },
    ["ACAT"] = { type = "positive", category = "weaponry", attribute = "energy_mod", value = 0.12, debuffs = { { attribute = "energy_regen_mod", value = -0.10, tag = "ENERGY_DRAIN" } } },
    ["ACCA"] = { type = "positive", category = "weaponry", attribute = "energy_regen_mod", value = 0.10, debuffs = { { attribute = "energy_mod", value = -0.08, tag = "ENERGY_DRAIN" } } },
    ["GATA"] = { type = "positive", category = "weaponry", attribute = "tur_range", value = 0.15, debuffs = { { attribute = "cooldown_mod", value = 0.10, tag = "SENSOR_STRAIN" } } },
    ["CGTA"] = { type = "positive", category = "weaponry", attribute = "cooldown_mod", value = -0.15, debuffs = { { attribute = "ew_signature", value = 0.20, tag = "SENSOR_STRAIN" } } },
    ["CCGG"] = { type = "positive", category = "weaponry", attribute = "tur_tracking", value = 0.15, debuffs = { { attribute = "tur_firerate", value = -0.10, tag = "WEAPON_OVERHEAT" } } },
    ["CCGC"] = { type = "positive", category = "weaponry", attribute = "tur_tracking", value = 0.25, debuffs = { { attribute = "tur_damage", value = -0.12, tag = "WEAPON_OVERHEAT" }, { attribute = "tur_range", value = -0.10, tag = "SENSOR_STRAIN" } } },
    ["TTGG"] = { type = "positive", category = "weaponry", attribute = "launch_damage", value = 0.20, debuffs = { { attribute = "launch_energy", value = 0.25, tag = "FIGHTER_OVERCHARGE" } } },
    ["TTGC"] = { type = "positive", category = "weaponry", attribute = "fbay_rate", value = 0.20, debuffs = { { attribute = "fbay_reload", value = 0.15, tag = "FIGHTER_OVERCHARGE" } } },
    ["TTGT"] = { type = "positive", category = "weaponry", attribute = "launch_range", value = 0.15, debuffs = { { attribute = "launch_turn", value = -0.10, tag = "FIGHTER_OVERCHARGE" } } },
    ["ACGG"] = { type = "positive", category = "weaponry", attribute = "weapon_damage", value = 0.08, debuffs = { { attribute = "weapon_energy", value = 0.10, tag = "WEAPON_OVERHEAT" } } },
    ["ACGT"] = { type = "positive", category = "weaponry", attribute = "weapon_firerate", value = 0.10, debuffs = { { attribute = "weapon_damage", value = -0.05, tag = "WEAPON_OVERHEAT" } } },

    -- Group: Specialized & Utility Systems
    ["TGCG"] = { type = "positive", category = "utility", attribute = "cargo_mod", value = 0.15, debuffs = { { attribute = "mass_mod", value = 0.12, tag = "HEAVY_MASS" } } },
    ["ATCG"] = { type = "positive", category = "utility", attribute = "mining_bonus", value = 0.10, debuffs = { { attribute = "weapon_damage", value = -0.05, tag = "UTILITY_COST" } } },
    ["ATGC"] = { type = "positive", category = "utility", attribute = "ew_stealth", value = 0.10, debuffs = { { attribute = "shield_regen_malus", value = 0.30, tag = "EW_COST" } } },
    ["AGTA"] = { type = "positive", category = "utility", attribute = "loot_mod", value = 0.20, debuffs = { { attribute = "cpu_mod", value = -0.15, tag = "UTILITY_COST" } } },
    ["GGCC"] = { type = "positive", category = "utility", attribute = "cpu", value = 30 },
    ["GGCT"] = { type = "positive", category = "utility", attribute = "cpu", value = 60, debuffs = { { attribute = "mass", value = 200, tag = "HEAVY_MASS" } } },
    ["GGCA"] = { type = "positive", category = "utility", attribute = "cpu", value = 100, debuffs = { { attribute = "mass", value = 400, tag = "HEAVY_MASS" }, { attribute = "energy_mod", value = -0.10, tag = "ENERGY_DRAIN" } } },
    ["TTTT"] = { type = "positive", category = "utility", attribute = "crew", value = 3 },
    ["TTTG"] = { type = "positive", category = "utility", attribute = "crew", value = 6, debuffs = { { attribute = "cpu", value = -20, tag = "UTILITY_COST" } } },
    ["TTTA"] = { type = "positive", category = "utility", attribute = "crew", value = 10, debuffs = { { attribute = "cpu", value = -50, tag = "UTILITY_COST" }, { attribute = "mass", value = 100, tag = "HEAVY_MASS" } } },
    ["GGGG"] = { type = "positive", category = "utility", attribute = "fuel", value = 50 },
    ["GGGT"] = { type = "positive", category = "utility", attribute = "fuel", value = 200, debuffs = { { attribute = "mass", value = 200, tag = "HEAVY_MASS" } } },
    ["GGGA"] = { type = "positive", category = "utility", attribute = "fuel", value = 600, debuffs = { { attribute = "mass", value = 500, tag = "HEAVY_MASS" }, { attribute = "accel_mod", value = -0.05, tag = "INERTIA" } } },
    ["GTGT"] = { type = "positive", category = "utility", attribute = "ew_signature", value = -0.15, debuffs = { { attribute = "speed_mod", value = -0.05, tag = "INERTIA" } } },
    ["GTGA"] = { type = "positive", category = "utility", attribute = "ew_detect", value = 0.20, debuffs = { { attribute = "ew_signature", value = 0.10, tag = "SENSOR_STRAIN" } } },

    -- Suppressors
    ["TCGA"] = { type = "suppressor", tag = "HEAVY_MASS" },
    ["ATAG"] = { type = "suppressor", tag = "INERTIA" },
    ["TCGG"] = { type = "suppressor", tag = "ENERGY_DRAIN" },
    ["AGAG"] = { type = "suppressor", tag = "SHIELD_OVERLOAD" },
    ["TTAA"] = { type = "suppressor", tag = "ARMOR_WEAK" },
    ["TCTA"] = { type = "suppressor", tag = "WEAPON_OVERHEAT" },
    ["CTAT"] = { type = "suppressor", tag = "SENSOR_STRAIN" },
    ["TAGC"] = { type = "suppressor", tag = "UTILITY_COST" },
    ["TACG"] = { type = "suppressor", tag = "EW_COST" },
    ["CTTG"] = { type = "suppressor", tag = "FRAGILE_HULL" },
    ["TTGA"] = { type = "suppressor", tag = "FIGHTER_OVERCHARGE" },
}

-- Reverse Lookup Table
local SUPPRESSOR_LOOKUP = {}
for codon, data in pairs(CODON_MAP) do
    if data.type == "suppressor" and data.tag then
        SUPPRESSOR_LOOKUP[data.tag] = codon
    end
end

local PALINDROME_MAP = {
    ["GATTACCA"] = { type = "palindrome", attribute = "cooldown_mod", value = -0.25 },
    ["CTAGGCAT"] = { type = "palindrome", attribute = "cpu", value = 50 },
    ["TCAGCTGA"] = { type = "palindrome", attribute = "shield_regen", value = 0.25 },
    ["AGCTAGCT"] = { type = "palindrome", attribute = "weapon_firerate", value = 0.25 },
    ["AATTACCA"] = { type = "palindrome", attribute = "armour_regen", value = 10},
}

-- ####################################################################
-- #    HELPER & CORE FUNCTIONS
-- ####################################################################

local COMPLEMENT_CHAR_MAP = { A = "T", T = "A", C = "G", G = "C" }

function DnaModifier.get_complement(dna_string)
    return (dna_string:gsub(".", COMPLEMENT_CHAR_MAP))
end

function DnaModifier.generate_junk_dna(length)
    local buffer = {}
    for i = 1, length do buffer[i] = NUCLEOTIDES[m_random(4)] end
    return t_concat(buffer)
end

-- ####################################################################
-- #    DIAGNOSTICS (Context-Aware & Grid-Locked)
-- ####################################################################

function DnaModifier.enumerate_codons(dna_string)
    local found_codons = {}
    local recognized_set = {}
    local strands = { dna_string, DnaModifier.get_complement(dna_string) }

    for _, strand in ipairs(strands) do
        -- 1. Determine Active Zone (Grid Scan)
        local active_len = #strand
        local terminator_found = false

        for i = 1, #strand - CODON_LENGTH + 1, CODON_LENGTH do
            local codon_str = s_sub(strand, i, i + CODON_LENGTH - 1)
            local codon = CODON_MAP[codon_str]
            if codon and codon.type == "terminator" then
                active_len = i - 1 -- End active zone before this codon starts
                terminator_found = true
                break
            end
        end

        -- 2. Pre-scan Active Zone for Debuff Tags
        local active_debuffs = {}
        for i = 1, active_len - CODON_LENGTH + 1, CODON_LENGTH do
            local codon_str = s_sub(strand, i, i + CODON_LENGTH - 1)
            local codon = CODON_MAP[codon_str]
            if codon and codon.type == "positive" and codon.debuffs then
                for _, debuff in ipairs(codon.debuffs) do
                    if debuff.tag then active_debuffs[debuff.tag] = true end
                end
            end
        end

        -- 3. Enumerate
        -- Check Palindromes (Global scan, context aware)
        for pattern, effect in pairs(PALINDROME_MAP) do
            local p_pos = strand:find(pattern, 1, true)
            if p_pos and not recognized_set[pattern] then
                local status = (p_pos > active_len) and ", inactive" or ""
                t_insert(found_codons, pattern .. " (" .. effect.attribute .. status .. ")")
                recognized_set[pattern] = true
            end
        end

        -- Check Codons (Grid Scan)
        for i = 1, #strand - CODON_LENGTH + 1, CODON_LENGTH do
            local codon_str = s_sub(strand, i, i + CODON_LENGTH - 1)
            local codon = CODON_MAP[codon_str]

            if codon and not recognized_set[codon_str] then
                local description = ""
                local is_inactive = (i > active_len)

                if codon.type == "terminator" then
                    if i == active_len + 1 then
                        description = "Terminator" -- The active terminator
                    else
                        description = "Terminator, inactive" -- Terminators after the terminator
                    end
                elseif codon.type == "positive" then
                    description = codon.attribute
                    if is_inactive then description = description .. ", inactive" end
                elseif codon.type == "suppressor" then
                    description = "suppresses " .. codon.tag
                    if is_inactive then
                        description = description .. ", inactive"
                    elseif not active_debuffs[codon.tag] then
                        description = description .. ", inactive (no target)"
                    end
                end

                t_insert(found_codons, codon_str .. " (" .. description .. ")")
                recognized_set[codon_str] = true
            end
        end
    end
    return found_codons
end

-- ####################################################################
-- #    DECODING ENGINE (Grid-Locked)
-- ####################################################################
function DnaModifier.decode_dna(dna_string)
    local raw_effects = {}
    local suppressor_counts = {}
    local strands = { dna_string, DnaModifier.get_complement(dna_string) }

    for _, strand in ipairs(strands) do
        -- 1. Determine Active Length via Grid Scan
        local active_len = #strand
        for i = 1, #strand - CODON_LENGTH + 1, CODON_LENGTH do
            local codon_str = s_sub(strand, i, i + CODON_LENGTH - 1)
            local codon = CODON_MAP[codon_str]
            if codon and codon.type == "terminator" then
                active_len = i - 1
                break
            end
        end

        local effective_strand = s_sub(strand, 1, active_len)

        -- Check Palindromes (Global on effective strand)
        for pattern, effect in pairs(PALINDROME_MAP) do
            if effective_strand:find(pattern) then
                raw_effects[effect.attribute] = raw_effects[effect.attribute] or {}
                t_insert(raw_effects[effect.attribute], effect.value)
            end
        end

        -- Check Codons (Grid on effective strand)
        for i = 1, active_len - CODON_LENGTH + 1, CODON_LENGTH do
            local codon_str = s_sub(effective_strand, i, i + CODON_LENGTH - 1)
            local codon = CODON_MAP[codon_str]
            if codon then
                if codon.type == "positive" then
                    raw_effects[codon.attribute] = raw_effects[codon.attribute] or {}
                    t_insert(raw_effects[codon.attribute], codon.value)
                    if codon.debuffs then
                        for _, debuff in ipairs(codon.debuffs) do
                            raw_effects[debuff.attribute] = raw_effects[debuff.attribute] or {}
                            t_insert(raw_effects[debuff.attribute], { value = debuff.value, tag = debuff.tag })
                        end
                    end
                elseif codon.type == "suppressor" then
                    suppressor_counts[codon.tag] = (suppressor_counts[codon.tag] or 0) + 1
                end
            end
        end
    end

    local final_modifiers = {}
    for attribute, values in pairs(raw_effects) do
        local total_effect = 0
        local simple_values = {}
        local tagged_debuffs = {}

        for _, v in ipairs(values) do
            if type(v) == "table" then t_insert(tagged_debuffs, v) else t_insert(simple_values, v) end
        end

        if #simple_values > 0 then
            if simple_values[1] > 0 and not FLAT_INTRINSICS[attribute] then
                local remaining = 1.0
                for _, bonus in ipairs(simple_values) do remaining = remaining * (1.0 - bonus) end
                total_effect = total_effect + (1.0 - remaining)
            else
                for _, bonus in ipairs(simple_values) do total_effect = total_effect + bonus end
            end
        end

        for _, debuff in ipairs(tagged_debuffs) do
            local mitigation = 1.0
            if debuff.tag and suppressor_counts[debuff.tag] then
                mitigation = 0.75 ^ suppressor_counts[debuff.tag]
            end
            total_effect = total_effect + (debuff.value * mitigation)
        end
        final_modifiers[attribute] = total_effect
    end

    for attribute, value in pairs(final_modifiers) do
        if not FLAT_INTRINSICS[attribute] then
            final_modifiers[attribute] = m_max(-0.9, m_min(1.0, value))
        end
    end

    return final_modifiers
end

-- ####################################################################
-- #    ADVANCED GENETICS SUITE
-- ####################################################################

-- BIAS: "grow" (default), "neutral", "shrink"
function DnaModifier.mutate_random(dna_string, mutation_rate, bias)
    bias = bias or "neutral"
    local buffer = {}
    local b_idx = 0
    local len = #dna_string

    for pos = 1, len do
        local char = s_sub(dna_string, pos, pos)

        if m_random() < mutation_rate then
            local roll = m_random(100)
            local m_type = 1

            if bias == "shrink" then
                if roll <= 40 then m_type = 6 elseif roll <= 80 then m_type = 1 else m_type = m_random(2, 5) end
            elseif bias == "neutral" then
                if roll <= 35 then m_type = 6 elseif roll <= 65 then m_type = 1 else m_type = m_random(2, 5) end
            else -- "grow"
                if roll <= 10 then m_type = 6 elseif roll <= 30 then m_type = 1 else m_type = m_random(2, 5) end
            end

            if m_type == 1 then -- Substitution
                b_idx = b_idx + 1; buffer[b_idx] = NUCLEOTIDES[m_random(4)]
            elseif m_type == 2 then -- Insertion
                b_idx = b_idx + 1; buffer[b_idx] = NUCLEOTIDES[m_random(4)]
                b_idx = b_idx + 1; buffer[b_idx] = char
            elseif m_type == 3 then -- Insertion (double)
                b_idx = b_idx + 1; buffer[b_idx] = NUCLEOTIDES[m_random(4)]
                b_idx = b_idx + 1; buffer[b_idx] = NUCLEOTIDES[m_random(4)]
                b_idx = b_idx + 1; buffer[b_idx] = char
            elseif m_type == 4 then -- duplication (group)
                local start_pos = m_max(1, pos - 1)
                local end_pos = m_min(len, pos + 2)
                local chunk = s_sub(dna_string, start_pos, end_pos)
                b_idx = b_idx + 1; buffer[b_idx] = chunk
                b_idx = b_idx + 1; buffer[b_idx] = chunk
            elseif m_type == 5 then -- duplication (single)
                b_idx = b_idx + 1; buffer[b_idx] = char
                b_idx = b_idx + 1; buffer[b_idx] = char
            end
            -- m_type 6 is deletion (do nothing)
        else
            b_idx = b_idx + 1; buffer[b_idx] = char
        end
    end

    local mutated_dna = t_concat(buffer)

    local MAX_LENGTH = 1024
    local EXTREME_LENGTH = 2 * MAX_LENGTH

    if #mutated_dna > EXTREME_LENGTH then
        mutated_dna = s_sub(mutated_dna, 1, m_floor(#mutated_dna / 2))
    end

    if #mutated_dna > MAX_LENGTH then
        -- Safety Trim + Alignment Pad
        -- Find grid-aligned cutoff
        local safe_len = m_floor(MAX_LENGTH / 4) * 4
        mutated_dna = s_sub(mutated_dna, 1, safe_len - 4) -- Make room for terminator
        mutated_dna = mutated_dna .. TERMINATOR_CODON
    else
        -- If we aren't trimming, we still want to check alignment for clean appends?
        -- No, random mutations are naturally messy.
        -- However, if the user wants robustness, we can ensure alignment.
        -- But standard evolution logic allows messy alignment to exist (junk DNA).
    end

    return mutated_dna
end

function DnaModifier.breed(parent_pool, mutation_rate)
    if not parent_pool or #parent_pool < 2 then return parent_pool and parent_pool[1] or "" end

    local p1_idx = m_random(#parent_pool)
    local p2_idx = m_random(#parent_pool)
    while p1_idx == p2_idx do p2_idx = m_random(#parent_pool) end

    local parent1, parent2 = parent_pool[p1_idx], parent_pool[p2_idx]

    local CHUNK_SIZE = 20
    local buffer = {}
    local b_idx = 0
    local max_len = m_max(#parent1, #parent2)

    for i = 1, max_len, CHUNK_SIZE do
        local parent_choice = m_random(2)
        local chunk
        if parent_choice == 1 and i <= #parent1 then
            chunk = s_sub(parent1, i, m_min(i + CHUNK_SIZE - 1, #parent1))
        elseif i <= #parent2 then
            chunk = s_sub(parent2, i, m_min(i + CHUNK_SIZE - 1, #parent2))
        else
            if i <= #parent1 then chunk = s_sub(parent1, i, m_min(i + CHUNK_SIZE - 1, #parent1))
            elseif i <= #parent2 then chunk = s_sub(parent2, i, m_min(i + CHUNK_SIZE - 1, #parent2))
            end
        end

        if chunk then
            b_idx = b_idx + 1
            buffer[b_idx] = chunk
        end
    end

    local child_dna = t_concat(buffer)

    local c_len = #child_dna
    local bias = "grow"
    if c_len > 600 then bias = "neutral" end
    if c_len > 900 then bias = "shrink" end

    return DnaModifier.mutate_random(child_dna, mutation_rate, bias)
end

function DnaModifier.research_splice(recipient_dna, donor_dna, target_codon)
    local outcome = { dna = recipient_dna, log = "" }
    local donor_pos = donor_dna:find(target_codon, 1, true)

    if not donor_pos then
        outcome.log = "Splicing failed: Target codon not found in donor."
        return outcome
    end

    local roll = m_random()
    if roll <= 0.6 then
        local start_pos = m_max(1, donor_pos - 4)
        local end_pos = m_min(#donor_dna, donor_pos + CODON_LENGTH + 3)
        local splice_chunk = s_sub(donor_dna, start_pos, end_pos)

        local insert_pos = m_random(#recipient_dna)
        outcome.dna = s_sub(recipient_dna, 1, insert_pos) .. splice_chunk .. s_sub(recipient_dna, insert_pos + 1)
        outcome.log = "Splicing successful: Gene sequence inserted."
    elseif roll <= 0.85 then
        local start_pos = m_max(1, donor_pos - 12)
        local end_pos = m_min(#donor_dna, donor_pos + CODON_LENGTH + 11)
        local splice_chunk = s_sub(donor_dna, start_pos, end_pos)

        local insert_pos = m_random(#recipient_dna)
        outcome.dna = s_sub(recipient_dna, 1, insert_pos) .. splice_chunk .. s_sub(recipient_dna, insert_pos + 1)
        outcome.log = "Splicing resulted in contamination: A larger, unstable gene sequence was inserted."
    else
        local insert_pos = m_random(#recipient_dna)
        local damaged_dna = s_sub(recipient_dna, 1, insert_pos) .. TERMINATOR_CODON .. s_sub(recipient_dna, insert_pos + 1)
        outcome.dna = DnaModifier.mutate_random(damaged_dna, 0.1)
        outcome.log = "Splicing failed catastrophically: Genome rejected the splice."
    end
    return outcome
end

function DnaModifier.research_irradiate(dna_string, mutagen_type)
    local buffer = {}
    local b_idx = 0
    local i = 1
    local len = #dna_string

    local bias = "neutral"
    if len < 100 then bias = "grow" elseif len > 1000 then bias = "shrink" end

    while i <= len do
        if i + CODON_LENGTH - 1 <= len then
            local codon_str = s_sub(dna_string, i, i + CODON_LENGTH - 1)
            local codon = CODON_MAP[codon_str]

            -- Check if codon category matches mutagen type
            -- This now works for Terminators too because they are in CODON_MAP
            local is_target = (codon and codon.category == mutagen_type)

            if is_target and m_random(100) > 50 then
                b_idx = b_idx + 1
                buffer[b_idx] = DnaModifier.mutate_random(codon_str, 0.25, bias)
            else
                b_idx = b_idx + 1
                buffer[b_idx] = codon_str
            end
            i = i + 4
        else
            b_idx = b_idx + 1
            buffer[b_idx] = s_sub(dna_string, i, i)
            i = i + 1
        end
    end
    return t_concat(buffer)
end

function DnaModifier.research_stabilize(dna_string, debuff_tag)
    local outcome = { dna = dna_string, log = "" }
    local suppressor_codon = SUPPRESSOR_LOOKUP[debuff_tag]

    if not suppressor_codon then
        outcome.log = "Research failed: No known suppressor sequence exists for this anomaly."
        return outcome
    end

    if m_random() <= 0.5 then
        local insert_pos = m_random(#outcome.dna)
        outcome.dna = s_sub(outcome.dna, 1, insert_pos) .. suppressor_codon .. s_sub(outcome.dna, insert_pos + 1)
        outcome.log = "Research successful: A suppressor codon (" .. suppressor_codon .. ") was synthesized and inserted."
    else
        outcome.log = "Research failed: The experimental process yielded no results."
    end
    return outcome
end

function DnaModifier._apply_dna_to_pilot(pilot_entity, dna_string)
    if not pilot_entity or not pilot_entity.intrinsicSet or not dna_string then return nil end
    local smem = pilot_entity:shipMemory()
    local modifiers = DnaModifier.decode_dna(dna_string)
    if smem.dna_applied ~= nil then
        if dna_string == smem.dna_applied then
            return modifiers
        else
            -- reverse previous modifications
            local omods = DnaModifier.decode_dna(smem.dna_applied)
            for attr, val in pairs(omods) do
                local nval = -val
                if not FLAT_INTRINSICS[attr] then nval = nval * 100 end
                pilot_entity:intrinsicSet(attr, nval)
            end
        end
    end
    -- apply dna effects
    for attribute, value in pairs(modifiers) do
        local api_value = value
        if not FLAT_INTRINSICS[attribute] then api_value = value * 100 end
        pilot_entity:intrinsicSet(attribute, api_value)
    end
    smem.dna_applied = dna_string
    pilot_entity:shipvarPop("genome") -- necessary?
    pilot_entity:shipvarPush("genome", dna_string)
    return modifiers
end

function DnaModifier.apply_dna_to_pilot(pilot_entity, dna_string)
    -- check pilot argument
    if not pilot_entity or not pilot_entity.intrinsicSet then return nil end

    -- check optional genome argument
    if not dna_string then
        dna_string = pilot_entity:shipvarPop("genome")
        if not dna_string then
            return nil  -- no genome exists for this ship yet!
        end
    end

    -- we got all we need, the genome now governs intrinsic stats
    local smem = pilot_entity:shipMemory()
    local modifiers = DnaModifier.decode_dna(dna_string)
    pilot_entity:intrinsicReset()
    for attr, val in pairs(modifiers) do
        local aval = val
        if not FLAT_INTRINSICS[attr] then aval = val * 100 end
        pilot_entity:intrinsicSet(attr, aval, true)
    end
    -- in case we want to check if the applied DNA is the same as the genome shipvar
    smem.dna_applied = dna_string
    pilot_entity:shipvarPush("genome", dna_string)
end

return DnaModifier
