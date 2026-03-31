# SPDX-License-Identifier: MIT
# Copyright (c) 2026 McMarius11
## Named constants for physics collision layers.
## Use via class_name: CollisionLayers.WORLD, CollisionLayers.PLAYER, etc.
## Combine with bitwise OR: CollisionLayers.WORLD | CollisionLayers.ENEMY
class_name CollisionLayers

const WORLD: int = 1         # Layer 1 — level geometry, static bodies
const PLAYER: int = 2        # Layer 2 — player character
const ENEMY: int = 4         # Layer 3 — monsters / enemies
const PROJECTILE: int = 8    # Layer 4 — projectiles (nails, rockets, etc.)
const PICKUP: int = 16       # Layer 5 — pickup items (health, ammo, weapons)
const INTERACTABLE: int = 32 # Layer 6 — doors, buttons, triggers
const WATER: int = 64        # Layer 7 — liquid volumes (water, slime, lava)
