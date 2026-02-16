extends Node
class_name PlayerSubsystem

## Base class for all player subsystems.
##
## Formalizes the contract that every player subsystem follows:
##   - setup(player) to store the player reference
##   - server_process(delta) for server-authoritative logic
##   - client_process(delta) for client-side visuals
##   - reset() to restore default state
##
## Subclasses override the virtual methods they need. The base implementations
## are no-ops so subsystems only implement what's relevant to them.

## The owning player. Set by setup().
var player: CharacterBody3D


func setup(p: CharacterBody3D) -> void:
	## Store the player reference. Subclasses that need extra initialization
	## should override this and call super.setup(p) first.
	player = p
