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
-- luacheck: globals enter load (Hook functions passed by name)

-- TODO:
-- * Add a bar NPC to get info from
-- * Trigger research
-- * Implement genome logic

function create ()
--  mem.multiplayer = {
--      servers = {}
--  }
  hook.load("load")
  hook.enter("enter")
end

local evobtn

local function science ()
    player.allowSave ( false )  -- no saving in experimental mode
    player.teleport("Evolution Sandbox")
end

function load ()
    evobtn = player.infoButtonRegister( _("Evolution"), science, 3 )
end

function npc_success( p )
    -- TODO: figure out how to score p based on crgo value or something
end

local function spawn_npc ()
    -- TODO: Spawn a ship, use the miner AI, score it based on how much cargo it brought back
    -- ai/core/idle/miner.lua
end

function enter ()
    -- Check if we're in the right system
    local cur = system.cur()
    if cur:nameRaw() ~= "Evolution Sandbox" then
        -- not in the evo system
        return
    end
    if not mem.evolution then
        mem.evolution = {
            data = {} -- TODO
        }
    end
    -- for each station in the system:
    --   pick a mission at random -> spawn a ship for scoring
    --   use pilot.add( "shipname", "stringfaction", "spob", "pilotname", {params} )
end
