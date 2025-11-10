-- genome_logic.lua
-- Single file for all genome-related functions: decoding, mutation, application to ships.

local COMPLEMENT = {A = "T", T = "A", C = "G", G = "C"}
local BASES = {"A", "C", "G", "T"}

-- Codon table: Maps 3-base strings to operations.
-- Format: codon = {op = "add_hull", delta = 0.1, debuff = {mass = 0.05, energy_regen = -0.01}, ...}
-- Full table based on previous assignments (abbreviated here for scaffolding).
local CODON_TABLE = {
    ["ATG"] = {op = "add_hull", delta = 0.1, debuff = {mass = 0.05, energy_regen = -0.01}},
    ["ATC"] = {op = "add_hull", delta = 0.1, debuff = {mass = 0.05, energy_regen = -0.01}},
    -- ... add all from summary (e.g., 4 for add_hull, etc.)
    ["TAA"] = {op = "stop"},
    -- Suppressors, subtracts, etc.
    -- Unmatched = junk (skip)
}

-- Max stacks per op type for diminishing returns.
local MAX_STACKS = {
    add_hull = 15,
    -- ... for each op
}

-- Function to generate initial random junk DNA pair (variable length 100-200).
function generate_initial_dna(min_len, max_len)
    local len = math.random(min_len or 100, max_len or 200)
    local forward = ""
    for i = 1, len do
        forward = forward .. BASES[math.random(1, 4)]
    end
    local reverse = reverse_complement(forward)
    return forward, reverse
end

-- Compute reverse complement.
function reverse_complement(strand)
    local comp = ""
    for i = #strand, 1, -1 do
        comp = comp .. COMPLEMENT[strand:sub(i, i)]
    end
    return comp
end

-- Mismatch rate calculation.
function mismatch_rate(fwd, rev)
    if #fwd ~= #rev then return 1.0 end  -- Full penalty if lengths differ
    local mismatches = 0
    for i = 1, #fwd do
        if COMPLEMENT[fwd:sub(i, i)] ~= rev:sub(i, i) then
            mismatches = mismatches + 1
        end
    end
    return mismatches / #fwd
end

-- Decode a single strand: Returns mod table {hull = 1.2, ...} (multipliers).
function decode_strand(strand)
    local mods = {}  -- Init to 1.0 for each attr
    local op_counts = {}  -- Track stacks per op
    local i = 1
    while i <= #strand - 2 do
        local codon = strand:sub(i, i+2)
        local entry = CODON_TABLE[codon]
        if entry then
            if entry.op == "stop" then break end
            op_counts[entry.op] = (op_counts[entry.op] or 0) + 1
            local n = op_counts[entry.op]
            local dim = math.sqrt(n) / math.sqrt(MAX_STACKS[entry.op] or 10)
            -- Apply delta * dim to mod[attr]
            -- e.g., mods.hull = (mods.hull or 1) + entry.delta * dim
            -- Apply debuffs linearly: mods[debuff_attr] = (mods[debuff_attr] or 1) + entry.debuff[debuff_attr] * n
            i = i + 3  -- Step by 3
        else
            i = i + 1  -- Shift frame for junk
        end
    end
    -- Apply suppressors last (reduce debuff mods)
    return mods
end

-- Full decode: Average fwd + rev mods, apply mismatch penalty.
function decode_genome(fwd, rev)
    local fwd_mods = decode_strand(fwd)
    local rev_mods = decode_strand(rev)
    local avg_mods = {}
    -- Average each attr
    -- Global penalty: mismatch = mismatch_rate(fwd, rev)
    -- for attr, val in pairs(avg_mods) do val = val * (1 - mismatch * 0.02) end
    return avg_mods
end

-- Mutate a strand (point, indel, duplication).
function mutate_strand(strand, rate)
    -- Point: for each base, random() < rate -> flip to random other
    -- Indel: small chance insert/delete 1-3 bases
    -- Duplication: rare, duplicate 3-9 base chunk
    return mutated_strand
end

-- Mutate pair: Independently mutate fwd/rev for divergence.
function mutate_genome(fwd, rev, rate)
    fwd = mutate_strand(fwd, rate)
    rev = mutate_strand(rev, rate)
    return fwd, rev
end

-- Apply mods to existing ship: Create variant or modify pilot.
function apply_genome_to_ship(base_ship_name, mods)
    -- Get base ship obj: local base_ship = ship.get(base_ship_name)
    -- Create new variant name: e.g., base_ship_name .. "_evo_" .. hash(mods)
    -- local variant = Ship.new(variant_name, base_ship:desc(), ...) -- Copy props
    -- Apply % mods: variant:set("hull", base_ship:hull() * mods.hull)
    -- variant:set("armour", ...) etc.
    -- For non-settable, add outfits post-spawn
    return variant_name
end

-- GA functions: crossover, etc.
function crossover_genome(fwd1, rev1, fwd2, rev2)
    -- Pick points, swap segments for fwd/rev independently
    return new_fwd, new_rev
end
