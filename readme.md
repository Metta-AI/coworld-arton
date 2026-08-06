# Arton — Design Doc

Arton is a real-time strategy game built for AIs to play. Matches are normally a full set of AI scripts competing against each other, though the game can also be played by a single human player or by one script alone.

The AI players are written by programming agents in nimmy, a custom scripting language. Scripts must be submitted before a match starts so they are running when the game begins.

## Simulation

- The simulation is fully deterministic.
- All math uses 32-bit integers only.
- No lossy hashtables or anything that can break determinism.
- Each match runs from a simulation seed, so all randomness (like starting ship counts) is reproducible.
- Tick speed is configurable: 1x is human time, but AI matches can run at 2x, 4x, 16x, or as fast as possible.

## Map and planets

A map contains multiple planets of varying sizes.

- Every planet starts neutral, with a random number of ships irrespective of size.
- Some planets are assigned to players at start. Player planets are tinted with the owning player's color.
- Player planets produce ships over time, at a rate based on planet size.

## Ships and combat

Players send ships between planets:

1. Select your planets. Clicking always selects, it never sends:
  * click one of your planets to select just it
  * shift click adds it to the selection
  * drag from empty space or from any planet you don't own for a box select, shift box select adds
  * double click selects all of your planets
  * clicking empty space or a planet you don't own clears the selection
2. Send ships by dragging, the only way to send:
  * press on one of your planets and drag toward any planet, own planets included, then release to send there
  * the targeting line snaps to the planet you would send to and that planet gets a highlight circle
  * the snap range is three times the planet's radius, nearest planet first; out of range there is no line and releasing sends nothing
  * the drag sends from the whole selection when it starts on a selected planet, otherwise just from the planet the drag started on

The number of ships sent is governed by the player's offense factor, which ranges from 10% to 100%. It is set with the number keys: 1 = 10% up through 0 = 100%. It is a per-player setting, hidden from the other players.

Ship behavior:

- Ships depart in rings around the rim of their planet.
  * A ring holds as many ships as fit around the planet's circumference, so bigger planets launch ships faster.
  * When fewer ships remain than fill a ring, they leave as an arc centered on the direction they are going.
  * Rings launch every third of a second until the wave is done.
- Ships always move forward along their heading at the uniform ship speed, and the heading slowly rotates toward the target. Rings launch heading away from the planet, so ships from the back side arc around and line up on the target over time.
- Ships in transit push each other apart, sphere verlet simulation style — but only ships of the same player interact. Enemy ships pass through each other (enemy ships don't interact under normal rules).
- Colliding ships also average their headings a little, boids style. When two friendly streams meet head-on they shear around each other, some ships going up and some down, instead of grinding straight through.
- Ships collide with planets. A ship pressed against a planet turns along the tangent that leads toward its target, so it slides around and never gets stuck.
- Ships can't be redirected mid-flight: once they leave their planet they fly to their destination and that's it. Pushes can knock them well off course though, so they navigate back toward their target.

When ships arrive at their target planet, the ship is annihilated and:

- At a friendly planet, it adds 1 to the planet's ship count.
- At an enemy or neutral planet, it subtracts 1 from the planet's ship count. When the count would drop below zero, the planet flips to the attacker.

## Winning

A player wins by taking every planet in single player, or every non-neutral planet in multiplayer. If time runs out first, the match is a draw.

## AI interface

Scripts have full information: they can read the state of every planet (including ownership and ship count) and see every ship in transit. The only hidden state is the other players' offense factors.

Their actions mirror the human controls:

- Select planets (any amount)
- Send to planet (only one at a time)
- Change their offense factor

## Art direction

The game reads as a sumi-e ink-wash painting in motion: traditional ink and watercolor media for the simulation itself, with a thin neon-glow digital layer on top for player intent. Abstract, high contrast, no literal space imagery.

### Surface and ink

- The background is a white textured plaster/gesso surface — like heavy watercolor paper or a painted wall, with visible cracks and trowel marks. Everything sits on it like physical media, not a rendered digital scene.
- Behind everything is a large ink-style shader: marks pasted onto it slowly diffuse across the map.
- Planets emit a small amount of black ink as they spin.
- When a ship annihilates against an enemy planet, it releases a burst of ink that seeps out and splatters around that planet. Arriving at a friendly planet releases no ink.
- Each player's territory accumulates a soft watercolor stain of their color. Where factions fight, black ink blooms and splatter pile up — the contested parts of the map become the darkest, messiest parts of the painting, a readable signal of where the battle is.

### Planets

- Planets are polygonal spinning 3D-mesh orbs. Some polygons are black, others are colored with the player's color, so the interior reads as marbled ink — the player's color swirled with black. Neutral planets read almost entirely black.
- A small gray circle 10% larger than the planet diameter establishes that it's a planet, since the low-poly mesh can be quite rough and not spherical.
- Around each planet: loose concentric dry-brush rings, like coffee-stain rings or scratchy hand-drawn orbits, plus a soft halo of the owner's color bleeding into the background.
- Planets show their ship count as a number in Scout font, white with black outlines.

### Ships

- Ships are small open V shapes drawn as unfilled strokes in the player's color, at varying opacity, blended onto the background. (This is the one change from the mockup, which drew them as outlined triangles.)
- En masse they behave like murmurations: dense flocking swarms that read as gradient-colored fields from a distance, with individual ships only resolving up close.
- Ships leave a little trail of their own color as they move; faded low-opacity marks linger behind them like ghosts of ships that passed.

### UI layer

- The interface deliberately breaks the analog look: crisp neon glow over the ink.
- Selected planets get a large glowing outline in the player's color.
- Hovering over a target planet draws straight glowing lines from each selected planet to it, in the player's color.

## Tech

Written in Nim:
 * windy (for window handling)
 * silky (for UI)
 * shady (for ink shader)
 * nimmy (for AI scripts)
 * raw opengl (for planet meshes, ink shader, ships, glowing outlines, lines, etc..)

It's compiled both native and to WASM, and must run in the browser.


# Implementation Phases

## Phase 1: Basic simulation

Deterministic core with dev graphics — simple shapes on a white background, playable by a single human.

- [x] Deterministic sim core
  - Fixed timestep tick loop; tick speed configurable from 1x (human time) up to as fast as possible
  - Simulation seed drives all randomness
  - 32-bit integer math only; no lossy hashtables or anything else that can break determinism
  - Map generation: planets of varying sizes, all neutral with random ship counts, some assigned to players
  - Player planets produce ships over time at a rate based on planet size

- [x] Ship movement
  - Rim departure: ships spawn in an arc around the planet facing their target, new spawns push earlier ships outward
  - Uniform ship speed; no mid-flight redirection
  - Same-player ships push each other apart (sphere verlet style); enemy ships pass through
  - Ships steer around planets, boids style, and navigate back on course after being pushed off it
  - Arrival: ship annihilates; +1 at a friendly planet, −1 at enemy/neutral, planet flips to the attacker when the count would drop below zero

- [x] Dev graphics
  - Open window with windy
  - use raw opengl context
  - Use silky for UI
  - Planets as flat circles with owner color and ship count text
  - Ships as simple dots or triangles
  - White background, no shaders

- [ ] Human controls
  - Single click, shift click, box select, shift box select, double click (select all own planets)
  - Click a non-selected planet to send ships
  - Offense factor set with keys 1–0 (10%–100%)

- [ ] Win and draw detection
  - Single player: capture all planets
  - Multiplayer: capture all non-neutral planets
  - Draw when time runs out



## Phase 2: Browser build

- [ ] Emscripten WASM compilation
  - windy window + OpenGL context working in the browser
  - Native and WASM builds produce identical simulations (verify with a seeded replay hash)
  - Runs at interactive framerate

## Phase 3: Nimmy AI scripts

- [ ] Script API: read state
  - All planets: position, size, owner, ship count
  - All ships in transit
  - Own offense factor (others' are hidden)
- [ ] Script API: actions
  - Select planets (any amount)
  - Send to a planet (one at a time)
  - Change offense factor
- [ ] Match harness
  - Scripts submitted before the match starts, run every tick
  - Headless AI-only matches at 16x / max speed
  - A couple of baseline bots (e.g. do-nothing, nearest-planet grabber) for testing

## Phase 4: Planet graphics

- [ ] Spinning low-poly 3D mesh orbs, polygons mixed black and owner color (marbled ink look)
- [ ] Gray silhouette circle 10% larger than the planet diameter
- [ ] Dry-brush concentric rings and a soft halo of the owner's color
- [ ] Ship count numbers in Scout font, white with black outlines
- [ ] Selection glow outline in the player color
- [ ] Hover targeting lines from each selected planet to the hovered planet

## Phase 5: Ink shader

- [ ] Plaster/gesso textured white background surface
- [ ] Ink marks slowly diffuse across the map
- [ ] Planets emit black ink as they spin
- [ ] Ink burst when a ship annihilates against an enemy planet (none at friendly planets)
- [ ] Player-color watercolor stains accumulate over each player's territory
- [ ] Black ink blooms pile up where factions fight

## Phase 6: Ship graphics

- [ ] Ships as small open V shapes, unfilled strokes in the player color at varying opacity
- [ ] Color trails behind moving ships, fading like ghosts
- [ ] Swarms read as murmurations / gradient fields at a distance
