# Reset State Keeper

Reset State Keeper is a BeamNG.drive UI app that preserves selected vehicle state after the standard vehicle reset (`Insert`). Version 0.8.1 starts the HUD collapsed so it stays out of the way until you open it.

## Features

- Preserve supported fuel storage levels, engine oil and coolant temperatures, other exposed temperature values, headlight mode, and hazard-light state after a reset.
- Keep separate cached state for recognized player-spawned vehicles. Switching between existing vehicles preserves each vehicle's cached state.
- When a vehicle is replaced and its previous object is removed, discard its cached state and apply defaults to the replacement: fill available tanks, reset exposed temperatures, and turn off headlights and hazard lights.
- Exclude AI traffic from state tracking and restoration.
- Clear cached states with F10 or the HUD Reset button. The next reset uses the game's normal behavior.
- Set fuel manually in liters, fill the tank, or use 25%, 50%, 75%, and 100% presets.
- Adjust the fuel-consumption multiplier live, with quick presets from ×1 to ×20 and manual input up to ×100.
- Collapse the HUD to a fuel icon. The app starts collapsed when created or reinitialized.
- Save fuel-consumption settings to `settings/resetStateKeeper.json`.

## Installation

1. Download [Reset State Keeper v0.8.1](releases/Reset_State_Keeper_BeamNG_v0.8.1_EN.zip).
2. Place the ZIP in your BeamNG.drive user folder's `mods/` directory. Do not extract it.
3. Start the game, open **Esc → UI Apps → Add App**, and add **Reset State Keeper — Fuel Control**.
4. Remove older Reset State Keeper ZIPs, including the Russian build and v0.8.0, to avoid duplicate apps or overlapping files.

## Compatibility

The latest game version documented by this project is BeamNG.drive 0.39.4.0. Compatibility with newer versions has not been confirmed.

Fuel capacity display and adjustment depend on the data exposed by each vehicle. Custom vehicles can use different storage and temperature parameters. The mod does not repair mechanical damage or restore an engine disabled by damage. Vehicle state is cached for the current game session and is not saved across game restarts.

## Repository contents

The `lua/`, `scripts/`, `settings/`, and `ui/` directories contain the mod in BeamNG.drive's package layout. See [CHANGELOG.md](CHANGELOG.md) for release history.
