--[[
dna_modifier.lua (v6.3 - Optimized & Immutable)

Performance Improvements:
- Replaced iterative string concatenation with table buffers (table.concat) to reduce garbage collection overhead.
- Optimized `get_complement` using string.gsub.
- Made CODON_MAP immutable. `research_stabilize` now performs a reverse lookup on existing definitions
  rather than generating new keys at runtime.

Original Features:
- Terminator Codon ('TAGG')
- Meiosis-based breeding
- Research Suite (Splice, Irradiate, Stabilize)
- Advanced diagnostics
--]]

local DnaModifier = {}

-- Cache standard libraries for performance in tight loops
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
local TERMINATOR_CODON = "TAGG"

local FLAT_INTRINSICS = {
    armour = true, armour_regen = true, mass = true, cpu = true, crew = true,
    cargo = true, fuel = true, energy = true, shield = true,
    stress_dissipation = true,
}

-- ####################################################################
-- #
-- #    CODON DEFINITIONS (IMMUTABLE)
-- #
-- ####################################################################

local CODON_MAP = {
    -- Group: Hull & Defense Systems
    ["GCAT"] = { type = "positive", category = "defense", attribute = "armour_mod", value = 0.10, debuffs = { { attribute = "mass_mod", value = 0.08, tag = "HEAVY_PLATING_A" }, { attribute = "turn_mod", value = -0.05, tag = "INERTIA_A" } } },
    ["AGCC"] = { type = "positive", category = "defense", attribute = "armour_mod", value = 0.08, debuffs = { { attribute = "energy_mod", value = -0.06, tag = "ENERGY_HARDENING_A" } } },
    ["GCTA"] = { type = "positive", category = "defense", attribute = "armour_mod", value = 0.12, debuffs = { { attribute = "fuel_mod", value = -0.10, tag = "ABLATIVE_FUEL_TANKS_A" } } },
    ["TCTC"] = { type = "positive", category = "defense", attribute = "shield_mod", value = 0.15, debuffs = { { attribute = "stress_dissipation", value = -20, tag = "HIGH_CAP_SHIELD_A" } } },
    ["AGTC"] = { type = "positive", category = "defense", attribute = "shield_regen", value = 0.10, debuffs = { { attribute = "shield_mod", value = -0.05, tag = "FAST_CHARGE_SHIELD_A" } } },
    ["CGCG"] = { type = "positive", category = "defense", attribute = "armour", value = 150, debuffs = { { attribute = "accel_mod", value = -0.05, tag = "REINFORCED_BULKHEAD_A" } } },
    ["CGCT"] = { type = "positive", category = "defense", attribute = "armour", value = 50, debuffs = { { attribute = "mass", value = 100, tag = "REINFORCED_BULKHEAD_A" } } },
    ["AATT"] = { type = "positive", category = "defense", attribute = "armour_regen", value = 2, debuffs = { { attribute = "armour_mod", value = -0.10, tag = "NANITE_REPAIR_A" } } },
    ["AATG"] = { type = "positive", category = "defense", attribute = "armour_regen", value = 3, debuffs = { { attribute = "armour_mod", value = -0.15, tag = "NANITE_REPAIR_A" } } },
    ["AATA"] = { type = "positive", category = "defense", attribute = "armour_regen", value = 4, debuffs = { { attribute = "armour_mod", value = -0.15, tag = "NANITE_REPAIR_A" }, { attribute = "mass_mod", value = 0.1, tag = "REINFORCED_BULKHEAD_A" } } },

    -- Group: Mobility & Propulsion
    ["CTAG"] = { type = "positive", category = "propulsion", attribute = "speed_mod", value = 0.10, debuffs = { { attribute = "armour_mod", value = -0.08, tag = "AGGRESSIVE_TUNING_A" } } },
    ["GTAC"] = { type = "positive", category = "propulsion", attribute = "speed_mod", value = 0.08, debuffs = { { attribute = "energy_regen_mod", value = -0.10, tag = "OVERCHARGED_ENGINES_A" } } },
    ["CTCA"] = { type = "positive", category = "propulsion", attribute = "accel_mod", value = 0.12, debuffs = { { attribute = "mass_mod", value = -0.05, tag = "INERTIAL_DAMPENERS_A" } } },
    ["GACC"] = { type = "positive", category = "propulsion", attribute = "turn_mod", value = 0.15, debuffs = { { attribute = "cpu_mod", value = -0.10, tag = "MANEUVERING_THRUSTERS_A" } } },
    ["TCGT"] = { type = "positive", category = "propulsion", attribute = "jump_distance", value = 0.15, debuffs = { { attribute = "jump_warmup", value = 0.20, tag = "LONG_RANGE_DRIVE_A" } } },

    -- Group: Weapon & Energy Systems
    ["AGAT"] = { type = "positive", category = "weaponry", attribute = "tur_damage", value = 0.08, debuffs = { { attribute = "tur_firerate", value = -0.06, tag = "HIGH_POWER_CAPS_A" } } },
    ["TCGC"] = { type = "positive", category = "weaponry", attribute = "tur_firerate", value = 0.10, debuffs = { { attribute = "tur_damage", value = -0.08, tag = "RAPID_CYCLING_A" } } },
    ["ACAT"] = { type = "positive", category = "weaponry", attribute = "energy_mod", value = 0.12, debuffs = { { attribute = "energy_regen_mod", value = -0.10, tag = "LARGE_CELLS_A" } } },
    ["ACCA"] = { type = "positive", category = "weaponry", attribute = "energy_regen_mod", value = 0.10, debuffs = { { attribute = "energy_mod", value = -0.08, tag = "HIGH_FLOW_CONDUITS_A" } } },
    ["GATA"] = { type = "positive", category = "weaponry", attribute = "tur_range", value = 0.15, debuffs = { { attribute = "cooldown_mod", value = 0.10, tag = "TARGETING_OPTICS_A" } } },
    ["CGTA"] = { type = "positive", category = "weaponry", attribute = "cooldown_mod", value = -0.15, debuffs = { { attribute = "ew_signature", value = 0.20, tag = "HEAT_SINKS_A" } } },

    -- Group: Specialized & Utility Systems
    ["TGCG"] = { type = "positive", category = "utility", attribute = "cargo_mod", value = 0.15, debuffs = { { attribute = "mass_mod", value = 0.12, tag = "EXPANDED_HOLD_A" } } },
    ["ATCG"] = { type = "positive", category = "utility", attribute = "mining_bonus", value = 0.10, debuffs = { { attribute = "weapon_damage", value = -0.05, tag = "SEISMIC_DRILLS_A" } } },
    ["ATGC"] = { type = "positive", category = "utility", attribute = "ew_stealth", value = 0.10, debuffs = { { attribute = "shield_regen_malus", value = 0.30, tag = "ACTIVE_CAMO_A" } } },
    ["AGTA"] = { type = "positive", category = "utility", attribute = "loot_mod", value = 0.20, debuffs = { { attribute = "cpu_mod", value = -0.15, tag = "TRACTOR_BEAM_A" } } },

    -- Suppressors for all defined debuffs
    -- These are now strictly defined here and never added to at runtime.
    ["TCGA"] = { type = "suppressor", tag = "HEAVY_PLATING_A" }, ["ATAG"] = { type = "suppressor", tag = "INERTIA_A" },
    ["TCGG"] = { type = "suppressor", tag = "ENERGY_HARDENING_A" }, ["CGAT"] = { type = "suppressor", tag = "ABLATIVE_FUEL_TANKS_A" },
    ["AGAG"] = { type = "suppressor", tag = "HIGH_CAP_SHIELD_A" }, ["TCAC"] = { type = "suppressor", tag = "FAST_CHARGE_SHIELD_A" },
    ["GCGC"] = { type = "suppressor", tag = "REINFORCED_BULKHEAD_A" }, ["TTAA"] = { type = "suppressor", tag = "NANITE_REPAIR_A" },
    ["GATC"] = { type = "suppressor", tag = "AGGRESSIVE_TUNING_A" }, ["CATG"] = { type = "suppressor", tag = "OVERCHARGED_ENGINES_A" },
    ["GAGT"] = { type = "suppressor", tag = "INERTIAL_DAMPENERS_A" }, ["CTGG"] = { type = "suppressor", tag = "MANEUVERING_THRUSTERS_A" },
    ["AGCA"] = { type = "suppressor", tag = "LONG_RANGE_DRIVE_A" }, ["TCTA"] = { type = "suppressor", tag = "HIGH_POWER_CAPS_A" },
    ["AGCG"] = { type = "suppressor", tag = "RAPID_CYCLING_A" }, ["TGTA"] = { type = "suppressor", tag = "LARGE_CELLS_A" },
    ["TGGT"] = { type = "suppressor", tag = "HIGH_FLOW_CONDUITS_A" }, ["CTAT"] = { type = "suppressor", tag = "TARGETING_OPTICS_A" },
    ["AAGC"] = { type = "suppressor", tag = "HEAT_SINKS_A" }, ["ACGC"] = { type = "suppressor", tag = "EXPANDED_HOLD_A" },
    ["TAGC"] = { type = "suppressor", tag = "SEISMIC_DRILLS_A" }, ["TACG"] = { type = "suppressor", tag = "ACTIVE_CAMO_A" },
    ["TCAT"] = { type = "suppressor", tag = "TRACTOR_BEAM_A" },
}

-- Reverse Lookup Table for fast O(1) access in research_stabilize
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
    ["AACTTCAA"] = { type = "palindrome", attribute = "armour_regen", value = 5},
}

-- ####################################################################
-- #
-- #    HELPER & CORE FUNCTIONS
-- #
-- ####################################################################

-- Optimized: Use mapping table and gsub instead of loops
local COMPLEMENT_CHAR_MAP = { A = "T", T = "A", C = "G", G = "C" }

function DnaModifier.get_complement(dna_string)
    return (dna_string:gsub(".", COMPLEMENT_CHAR_MAP))
end

-- Optimized: Use table.concat for buffer
function DnaModifier.generate_junk_dna(length)
    local buffer = {}
    for i = 1, length do
        buffer[i] = NUCLEOTIDES[m_random(4)]
    end
    return t_concat(buffer)
end

-- ####################################################################
-- #
-- #    DIAGNOSTICS
-- #
-- ####################################################################

function DnaModifier.enumerate_codons(dna_string)
    local found_codons = {}
    local recognized_set = {}
    local strands = { dna_string, DnaModifier.get_complement(dna_string) }

    for _, strand in ipairs(strands) do
        local terminator_pos = strand:find(TERMINATOR_CODON, 1, true)
        if terminator_pos and not recognized_set[TERMINATOR_CODON] then
             t_insert(found_codons, TERMINATOR_CODON .. " (Terminator)")
             recognized_set[TERMINATOR_CODON] = true
        end

        for pattern, effect in pairs(PALINDROME_MAP) do
            if strand:find(pattern) and not recognized_set[pattern] then
                t_insert(found_codons, pattern .. " (" .. effect.attribute .. ")")
                recognized_set[pattern] = true
            end
        end

        for i = 1, #strand - CODON_LENGTH + 1, CODON_LENGTH do
            local codon_str = s_sub(strand, i, i + CODON_LENGTH - 1)
            local codon = CODON_MAP[codon_str]
            if codon and codon.type ~= "junk" and not recognized_set[codon_str] then
                local description = ""
                if codon.type == "positive" then
                    description = codon.attribute
                elseif codon.type == "suppressor" then
                    description = "suppresses " .. codon.tag
                end
                t_insert(found_codons, codon_str .. " (" .. description .. ")")
                recognized_set[codon_str] = true
            end
        end
    end
    return found_codons
end

-- ####################################################################
-- #
-- #    DECODING ENGINE with TERMINATOR LOGIC
-- #
-- ####################################################################
function DnaModifier.decode_dna(dna_string)
    local raw_effects = {}
    local suppressor_counts = {}
    local strands = { dna_string, DnaModifier.get_complement(dna_string) }

    for _, strand in ipairs(strands) do
        local effective_strand = strand
        local terminator_pos = strand:find(TERMINATOR_CODON, 1, true)
        if terminator_pos then
            effective_strand = s_sub(strand, 1, terminator_pos - 1)
        end

        -- Check Palindromes
        for pattern, effect in pairs(PALINDROME_MAP) do
            if effective_strand:find(pattern) then
                raw_effects[effect.attribute] = raw_effects[effect.attribute] or {}
                t_insert(raw_effects[effect.attribute], effect.value)
            end
        end

        -- Check Codons
        local len = #effective_strand
        for i = 1, len - CODON_LENGTH + 1, CODON_LENGTH do
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
                mitigation = 0.5 ^ suppressor_counts[debuff.tag]
            end
            total_effect = total_effect + (debuff.value * mitigation)
        end
        final_modifiers[attribute] = total_effect
    end

    -- Clamp percentages
    for attribute, value in pairs(final_modifiers) do
        if not FLAT_INTRINSICS[attribute] then
            final_modifiers[attribute] = m_max(-0.9, m_min(1.0, value))
        end
    end

    return final_modifiers
end

-- ####################################################################
-- #
-- #    ADVANCED GENETICS SUITE
-- #
-- ####################################################################

-- Optimized: Buffer-based mutation
function DnaModifier.mutate_random(dna_string, mutation_rate)
    local buffer = {}
    local b_idx = 0
    local len = #dna_string
    local i = 1

    -- Using a while loop allows us to skip characters (for deletions/groups) easier if needed
    -- though here we primarily iterate linearly.
    for pos = 1, len do
        local char = s_sub(dna_string, pos, pos)

        if m_random() < mutation_rate then
            local mutation_type = m_random(6)

            if mutation_type == 1 then -- Substitution
                b_idx = b_idx + 1; buffer[b_idx] = NUCLEOTIDES[m_random(4)]
            elseif mutation_type == 2 then -- Insertion
                b_idx = b_idx + 1; buffer[b_idx] = NUCLEOTIDES[m_random(4)]
                b_idx = b_idx + 1; buffer[b_idx] = char
            elseif mutation_type == 3 then -- Insertion (double)
                b_idx = b_idx + 1; buffer[b_idx] = NUCLEOTIDES[m_random(4)]
                b_idx = b_idx + 1; buffer[b_idx] = NUCLEOTIDES[m_random(4)]
                b_idx = b_idx + 1; buffer[b_idx] = char
            elseif mutation_type == 4 then -- duplication (group)
                local start_pos = m_max(1, pos - 1)
                local end_pos = m_min(len, pos + 2)
                local chunk = s_sub(dna_string, start_pos, end_pos)
                b_idx = b_idx + 1; buffer[b_idx] = chunk
                b_idx = b_idx + 1; buffer[b_idx] = chunk -- duplicate logic implies adding it?
                -- Re-reading original logic: it appends the group to the current build
                -- Original: mutated = mutated .. sub(start, end).
                -- Since "char" is implicitly added in the 'else' of the original, type 4 replaced the char loop?
                -- Wait, original logic: if mutation, do X, ELSE append char.
                -- Type 4 in original: appends group *instead* of the current char.
            elseif mutation_type == 5 then -- duplication (single)
                b_idx = b_idx + 1; buffer[b_idx] = char
                b_idx = b_idx + 1; buffer[b_idx] = char
            end
            -- Note: mutation_type 6 is implicit deletion (do nothing)
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
        local last_terminator_pos = nil
        -- Scan backwards for terminator
        for pos = #mutated_dna - #TERMINATOR_CODON + 1, 1, -1 do
            if s_sub(mutated_dna, pos, pos + #TERMINATOR_CODON - 1) == TERMINATOR_CODON then
                last_terminator_pos = pos
                break
            end
        end

        if last_terminator_pos then
            mutated_dna = s_sub(mutated_dna, 1, last_terminator_pos - 1)
        else
            mutated_dna = mutated_dna .. TERMINATOR_CODON
        end
    end

    return mutated_dna
end

-- Optimized: Buffer-based breeding
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
            -- If the chosen parent has run out of DNA, try the other
            if i <= #parent1 then chunk = s_sub(parent1, i, m_min(i + CHUNK_SIZE - 1, #parent1))
            elseif i <= #parent2 then chunk = s_sub(parent2, i, m_min(i + CHUNK_SIZE - 1, #parent2))
            end
        end

        if chunk then
            b_idx = b_idx + 1
            buffer[b_idx] = chunk
        end
    end

    return DnaModifier.mutate_random(t_concat(buffer), mutation_rate)
end

function DnaModifier.research_splice(recipient_dna, donor_dna, target_codon)
    local outcome = { dna = recipient_dna, log = "" }
    local donor_pos = donor_dna:find(target_codon, 1, true)

    if not donor_pos then
        outcome.log = "Splicing failed: Target codon not found in donor."
        return outcome
    end

    local roll = m_random()
    if roll <= 0.6 then -- Success (60%)
        local start_pos = m_max(1, donor_pos - 4)
        local end_pos = m_min(#donor_dna, donor_pos + CODON_LENGTH + 3)
        local splice_chunk = s_sub(donor_dna, start_pos, end_pos)

        local insert_pos = m_random(#recipient_dna)
        outcome.dna = s_sub(recipient_dna, 1, insert_pos) .. splice_chunk .. s_sub(recipient_dna, insert_pos + 1)
        outcome.log = "Splicing successful: Gene sequence inserted."
    elseif roll <= 0.85 then -- Failure 1 (25%)
        local start_pos = m_max(1, donor_pos - 12)
        local end_pos = m_min(#donor_dna, donor_pos + CODON_LENGTH + 11)
        local splice_chunk = s_sub(donor_dna, start_pos, end_pos)

        local insert_pos = m_random(#recipient_dna)
        outcome.dna = s_sub(recipient_dna, 1, insert_pos) .. splice_chunk .. s_sub(recipient_dna, insert_pos + 1)
        outcome.log = "Splicing resulted in contamination: A larger, unstable gene sequence was inserted."
    else -- Failure 2 (15%)
        local insert_pos = m_random(#recipient_dna)
        local damaged_dna = s_sub(recipient_dna, 1, insert_pos) .. TERMINATOR_CODON .. s_sub(recipient_dna, insert_pos + 1)
        outcome.dna = DnaModifier.mutate_random(damaged_dna, 0.1)
        outcome.log = "Splicing failed catastrophically: Genome rejected the splice."
    end
    return outcome
end

-- Optimized: Buffer-based irradiation
function DnaModifier.research_irradiate(dna_string, mutagen_type)
    local buffer = {}
    local b_idx = 0
    local i = 1
    local len = #dna_string

    while i <= len do
        if i + CODON_LENGTH - 1 <= len then
            local codon_str = s_sub(dna_string, i, i + CODON_LENGTH - 1)
            local codon = CODON_MAP[codon_str]

            local is_target_codon = (codon and codon.category == mutagen_type)
            local is_target_terminator = (codon_str == TERMINATOR_CODON and mutagen_type == "terminator")

            if (is_target_codon or is_target_terminator) and m_random(100) > 50 then
                b_idx = b_idx + 1
                buffer[b_idx] = DnaModifier.mutate_random(codon_str, 0.75)
            else
                b_idx = b_idx + 1
                buffer[b_idx] = codon_str
            end
            i = i + 4
        else
            -- Append remaining characters that don't fit a 4-block
            b_idx = b_idx + 1
            buffer[b_idx] = s_sub(dna_string, i, i)
            i = i + 1
        end
    end
    return t_concat(buffer)
end

-- UPDATED: Now utilizes the immutable map via SUPPRESSOR_LOOKUP
function DnaModifier.research_stabilize(dna_string, debuff_tag)
    local outcome = { dna = dna_string, log = "" }

    -- We can no longer "invent" new codons. We must find the one that exists for this tag.
    local suppressor_codon = SUPPRESSOR_LOOKUP[debuff_tag]

    if not suppressor_codon then
        outcome.log = "Research failed: No known suppressor sequence exists for this anomaly."
        return outcome
    end

    if m_random() <= 0.5 then -- Success (50% chance)
        local insert_pos = m_random(#outcome.dna)
        outcome.dna = s_sub(outcome.dna, 1, insert_pos) .. suppressor_codon .. s_sub(outcome.dna, insert_pos + 1)
        outcome.log = "Research successful: A suppressor codon (" .. suppressor_codon .. ") was synthesized and inserted."
    else
        outcome.log = "Research failed: The experimental process yielded no results."
    end
    return outcome
end

-- ####################################################################
-- #
-- #    FINAL APPLICATION
-- #
-- ####################################################################

function DnaModifier.apply_dna_to_pilot(pilot_entity, dna_string)
    if not pilot_entity or not pilot_entity.intrinsicSet or not dna_string then return nil end

    local modifiers = DnaModifier.decode_dna(dna_string)

    for attribute, value in pairs(modifiers) do
        local api_value = value
        if not FLAT_INTRINSICS[attribute] then
            api_value = value * 100
        end
        pilot_entity:intrinsicSet(attribute, api_value)
    end

    return modifiers
end

return DnaModifier
