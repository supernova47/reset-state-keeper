# Reset State Keeper — Changelog

## 0.8.3 — 2026-10-20

- Reworked the collapsed HUD into a small square icon that can be dragged anywhere inside the screen and remembers its position.
- Expands the panel toward the available screen space around the icon.
- Enabled independent width and height resizing in the HUD editor, with a compact minimum size.
- Preserved the HUD editor's own move and resize behavior while the app is collapsed.

## 0.8.2 — 2026-10-20

- Fixed hazard-light restoration passing numeric `0` as a truthy Lua value; the mod now passes an explicit boolean to the vehicle electrics API.
- Refresh the input-action and binding caches after the mod loads, so the clear-states key is registered even when BeamNG cached actions before mounting user mods.

## 0.8.1 — 2026-10-19

- Changed: the HUD app now starts collapsed when it is created or reinitialized. Click the fuel icon to expand it.
- No vehicle-state, reset, fuel-control, or configuration behavior was changed.
