--[[
dna_modifier.lua (v6.2 - Fixed)

This module implements an advanced DNA system for modifying ship attributes in Naev.
It supports complex mechanics inspired by real biology, including gene expression control,
meiosis-based breeding, and multiple paths for targeted genetic research.

- Terminator Codon ('TAGG'): Halts the reading of a DNA strand.
  * UPDATED v6.2: Changed from TAG to TAGG to match CODON_LENGTH (4) and prevent
  accidental truncation of valid codons like CTAG (Speed Mod).
- Breeding: A new `breed()` function simulates meiosis by shuffling chunks of DNA from two parents.
- Research Suite: Three new functions (`research_splice`, `research_irradiate`, `research_stabilize`)
  provide distinct, strategic paths for genome modification.
- Random Mutation: The original `mutate` function is now `mutate_random` for simulating low-level errors.
- enumerate_codons: Now provides descriptive output for diagnostics.
--]]

local DnaModifier = {}

-- Basic DNA configuration
local NUCLEOTIDES = { "A", "T", "C", "G" }
local CODON_LENGTH = 4
local TERMINATOR_CODON = "TAGG" -- Updated to 4 chars to align with grid and avoid collisions

-- A set of intrinsic attributes that take flat values instead of percentages.
local FLAT_INTRINSICS = {
    armour = true, armour_regen = true, mass = true, cpu = true, crew = true,
    cargo = true, fuel = true, energy = true, shield = true,
    stress_dissipation = true,
}

-- ####################################################################
-- #
-- #    CODON DEFINITIONS w/ CATEGORIES
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
    ["AATG"] = { type = "positive", category = "defense", attribute = "armour_regen", value = 5, debuffs = { { attribute = "armour_mod", value = -0.15, tag = "NANITE_REPAIR_A" }, { attribute = "mass_mod", value = 0.1, tag = "REINFORCED_BULKHEAD_A" } } },

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

-- ## PALINDROMIC "OP" MODIFIERS ##
local PALINDROME_MAP = {
    ["GATTACCA"] = { type = "palindrome", attribute = "cooldown_mod", value = -0.25 },
    ["CTAGGCAT"] = { type = "palindrome", attribute = "cpu", value = 50 },
    ["TCAGCTGA"] = { type = "palindrome", attribute = "shield_regen", value = 0.25 },
    ["AGCTAGCT"] = { type = "palindrome", attribute = "weapon_firerate", value = 0.25 },
    ["AATTACCA"] = { type = "palindrome", attribute = "armour_regen", value = 10},
}

-- ####################################################################
-- #
-- #    HELPER & CORE FUNCTIONS
-- #
-- ####################################################################
local COMPLEMENT_MAP = { A = "T", T = "A", C = "G", G = "C" }

function DnaModifier.get_complement(dna_string)
    local complement = ""
    for i = 1, #dna_string do
        local char = dna_string:sub(i, i)
        complement = complement .. (COMPLEMENT_MAP[char] or "")
    end
    return complement
end

function DnaModifier.generate_junk_dna(length)
    local dna = ""
    for _ = 1, length do
        dna = dna .. NUCLEOTIDES[math.random(#NUCLEOTIDES)]
    end
    return dna
end

-- ####################################################################
-- #
-- #    DIAGNOSTICS
-- #
-- ####################################################################

--- Parses a DNA string and its complement to find all recognized codons, with descriptions.
-- @param dna_string The DNA string to enumerate.
-- @return A table (list) of all non-junk codon strings found with descriptions.
function DnaModifier.enumerate_codons(dna_string)
    local found_codons = {}
    local recognized_set = {} -- Use a set to prevent duplicates
    local strands = { dna_string, DnaModifier.get_complement(dna_string) }

    for _, strand in ipairs(strands) do
        -- Check for terminator first
        local terminator_pos = strand:find(TERMINATOR_CODON, 1, true)
        if terminator_pos and not recognized_set[TERMINATOR_CODON] then
             table.insert(found_codons, TERMINATOR_CODON .. " (Terminator)")
             recognized_set[TERMINATOR_CODON] = true
        end

        -- Check for palindromes
        for pattern, effect in pairs(PALINDROME_MAP) do
            if strand:find(pattern) and not recognized_set[pattern] then
                table.insert(found_codons, pattern .. " (" .. effect.attribute .. ")")
                recognized_set[pattern] = true
            end
        end
        -- Check for regular codons
        for i = 1, #strand - CODON_LENGTH + 1, CODON_LENGTH do
            local codon_str = strand:sub(i, i + CODON_LENGTH - 1)
            local codon = CODON_MAP[codon_str]
            if codon and codon.type ~= "junk" and not recognized_set[codon_str] then
                local description = ""
                if codon.type == "positive" then
                    description = codon.attribute
                elseif codon.type == "suppressor" then
                    description = "suppresses " .. codon.tag
                end
                table.insert(found_codons, codon_str .. " (" .. description .. ")")
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
        local terminator_pos = strand:find(TERMINATOR_CODON, 1, true)
        local effective_strand = strand
        if terminator_pos then
            effective_strand = strand:sub(1, terminator_pos - 1)
        end

        for pattern, effect in pairs(PALINDROME_MAP) do
            if effective_strand:find(pattern) then
                raw_effects[effect.attribute] = raw_effects[effect.attribute] or {}
                table.insert(raw_effects[effect.attribute], effect.value)
            end
        end

        for i = 1, #effective_strand - CODON_LENGTH + 1, CODON_LENGTH do
            local codon_str = effective_strand:sub(i, i + CODON_LENGTH - 1)
            local codon = CODON_MAP[codon_str]
            if codon then
                if codon.type == "positive" then
                    raw_effects[codon.attribute] = raw_effects[codon.attribute] or {}
                    table.insert(raw_effects[codon.attribute], codon.value)
                    if codon.debuffs then
                        for _, debuff in ipairs(codon.debuffs) do
                            raw_effects[debuff.attribute] = raw_effects[debuff.attribute] or {}
                            table.insert(raw_effects[debuff.attribute], { value = debuff.value, tag = debuff.tag })
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
            if type(v) == "table" then table.insert(tagged_debuffs, v) else table.insert(simple_values, v) end
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

    for attribute, value in pairs(final_modifiers) do
        if not FLAT_INTRINSICS[attribute] then
            final_modifiers[attribute] = math.max(-0.9, math.min(1.0, value))
        end
    end

    return final_modifiers
end

-- ####################################################################
-- #
-- #    ADVANCED GENETICS SUITE
-- #
-- ####################################################################

function DnaModifier.mutate_random(dna_string, mutation_rate)
    local mutated_dna = ""
    for i = 1, #dna_string do
        if math.random() < mutation_rate then
            local mutation_type = math.random(6)
            -- if 3: deletion
            if mutation_type == 1 then -- Substitution
                mutated_dna = mutated_dna .. NUCLEOTIDES[math.random(#NUCLEOTIDES)]
            elseif mutation_type == 2 then -- Insertion
                mutated_dna = mutated_dna .. NUCLEOTIDES[math.random(#NUCLEOTIDES)] .. dna_string:sub(i, i)
            elseif mutation_type == 3 then -- Insertion (double)
                mutated_dna = mutated_dna .. NUCLEOTIDES[math.random(#NUCLEOTIDES)] .. NUCLEOTIDES[math.random(#NUCLEOTIDES)] .. dna_string:sub(i, i)
            elseif mutation_type == 4 then -- duplication (group)
                local start_pos = math.max(1, i - 1)
                local end_pos = math.min(#dna_string, i + 2)
                mutated_dna = mutated_dna .. dna_string:sub(start_pos, end_pos)
            elseif mutation_type == 5 then -- duplication (single)
                mutated_dna = mutated_dna .. dna_string:sub(i, i) .. dna_string:sub(i, i)
            end
        else
            mutated_dna = mutated_dna .. dna_string:sub(i, i)
        end
    end

    local MAX_LENGTH = 1024
    local EXTREME_LENGTH = 2 * MAX_LENGTH

    -- Handle extreme cases first
    if #mutated_dna > EXTREME_LENGTH then
        -- Lose half the genome (hard truncate to half)
        mutated_dna = mutated_dna:sub(1, math.floor(#mutated_dna / 2))
    end

    -- Now handle normal capping if over MAX_LENGTH
    if #mutated_dna > MAX_LENGTH then
        -- Search for the last terminator codon
        local last_terminator_pos = nil
        for pos = #mutated_dna - #TERMINATOR_CODON + 1, 1, -1 do
            if mutated_dna:sub(pos, pos + #TERMINATOR_CODON - 1) == TERMINATOR_CODON then
                last_terminator_pos = pos
                break
            end
        end

        if last_terminator_pos then
            -- Cut at the start of the last terminator (excluding it and everything after)
            mutated_dna = mutated_dna:sub(1, last_terminator_pos - 1)
        else
            -- No terminator found; append one at the end
            mutated_dna = mutated_dna .. TERMINATOR_CODON
        end
    end

    return mutated_dna
end

function DnaModifier.breed(parent_pool, mutation_rate)
    if not parent_pool or #parent_pool < 2 then return parent_pool and parent_pool[1] or "" end

    local p1_idx = math.random(#parent_pool)
    local p2_idx = math.random(#parent_pool)
    while p1_idx == p2_idx do p2_idx = math.random(#parent_pool) end

    local parent1, parent2 = parent_pool[p1_idx], parent_pool[p2_idx]

    local CHUNK_SIZE = 20
    local child_dna = ""
    local max_len = math.max(#parent1, #parent2)

    for i = 1, max_len, CHUNK_SIZE do
        local parent_choice = math.random(2)
        local chunk = ""
        if parent_choice == 1 and i <= #parent1 then
            chunk = parent1:sub(i, math.min(i + CHUNK_SIZE - 1, #parent1))
        elseif i <= #parent2 then
            chunk = parent2:sub(i, math.min(i + CHUNK_SIZE - 1, #parent2))
        end
        child_dna = child_dna .. chunk
    end

    return DnaModifier.mutate_random(child_dna, mutation_rate)
end

function DnaModifier.research_splice(recipient_dna, donor_dna, target_codon)
    local outcome = { dna = recipient_dna, log = "" }
    local donor_pos = donor_dna:find(target_codon, 1, true)

    if not donor_pos then
        outcome.log = "Splicing failed: Target codon not found in donor."
        return outcome
    end

    local roll = math.random()
    if roll <= 0.6 then -- Success (60% chance)
        local start_pos = math.max(1, donor_pos - 4)
        local end_pos = math.min(#donor_dna, donor_pos + CODON_LENGTH + 3)
        local splice_chunk = donor_dna:sub(start_pos, end_pos)

        local insert_pos = math.random(#recipient_dna)
        outcome.dna = recipient_dna:sub(1, insert_pos) .. splice_chunk .. recipient_dna:sub(insert_pos + 1)
        outcome.log = "Splicing successful: Gene sequence inserted."
    elseif roll <= 0.85 then -- Failure 1: Sloppy Extraction (25% chance)
        local start_pos = math.max(1, donor_pos - 12)
        local end_pos = math.min(#donor_dna, donor_pos + CODON_LENGTH + 11)
        local splice_chunk = donor_dna:sub(start_pos, end_pos)

        local insert_pos = math.random(#recipient_dna)
        outcome.dna = recipient_dna:sub(1, insert_pos) .. splice_chunk .. recipient_dna:sub(insert_pos + 1)
        outcome.log = "Splicing resulted in contamination: A larger, unstable gene sequence was inserted."
    else -- Failure 2: Immune Response (15% chance)
        local insert_pos = math.random(#recipient_dna)
        local damaged_dna = recipient_dna:sub(1, insert_pos) .. TERMINATOR_CODON .. recipient_dna:sub(insert_pos + 1)
        outcome.dna = DnaModifier.mutate_random(damaged_dna, 0.1)
        outcome.log = "Splicing failed catastrophically: Genome rejected the splice, causing widespread corruption and termination."
    end
    return outcome
end

function DnaModifier.research_irradiate(dna_string, mutagen_type)
    local mutated_dna = ""
    local i = 1
    while i <= #dna_string do
        if i + CODON_LENGTH - 1 <= #dna_string then
            local codon_str = dna_string:sub(i, i + CODON_LENGTH - 1)
            local codon = CODON_MAP[codon_str]

            -- Check if it's a standard codon matching the type, or the terminator matching "terminator"
            local is_target_codon = (codon and codon.category == mutagen_type)
            local is_target_terminator = (codon_str == TERMINATOR_CODON and mutagen_type == "terminator")

            if (is_target_codon or is_target_terminator) and math.random(100) > 50 then
                mutated_dna = mutated_dna .. DnaModifier.mutate_random(codon_str, 0.75)
            else
                mutated_dna = mutated_dna .. dna_string:sub(i, i)
            end
        else
            mutated_dna = mutated_dna .. dna_string:sub(i, i)
        end
        i = i + 4
    end
    return mutated_dna
end

function DnaModifier.research_stabilize(dna_string, debuff_tag)
    local outcome = { dna = dna_string, log = "" }

    if math.random() <= 0.5 then -- Success (50% chance)
        local new_suppressor_str
        for _ = 1, 100 do
            local random_codon = DnaModifier.generate_junk_dna(CODON_LENGTH)
            -- Ensure generated junk is not the terminator and not a known codon
            if not CODON_MAP[random_codon] and random_codon ~= TERMINATOR_CODON then
                new_suppressor_str = random_codon;
                break;
            end
        end

        if new_suppressor_str then
            CODON_MAP[new_suppressor_str] = { type = "suppressor", tag = debuff_tag }
            local insert_pos = math.random(#outcome.dna)
            outcome.dna = outcome.dna:sub(1, insert_pos) .. new_suppressor_str .. outcome.dna:sub(insert_pos + 1)
            outcome.log = "Research successful: A new suppressor codon (" .. new_suppressor_str .. ") was synthesized and inserted."
        else
            outcome.log = "Research failed: Could not synthesize a stable suppressor sequence."
        end
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
