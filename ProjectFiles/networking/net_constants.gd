class_name NetConstants
extends RefCounted

## Network configuration constants.

const DEFAULT_PORT := 7777
const MAX_PLAYERS := 40
const SERVER_TICK_RATE := 240

## Game version — must match between server and client to connect.
## Bump this whenever you make changes that break compatibility.
const GAME_VERSION := "0.2.0"
