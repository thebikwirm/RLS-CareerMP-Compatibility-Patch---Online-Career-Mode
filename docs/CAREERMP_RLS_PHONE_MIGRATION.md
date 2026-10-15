# CareerMP UI migration into the RLS phone (experimental)

Base: `beamng-0.39.4-careermp`. Branch: `feature/careermp-rls-phone`.

## Verified integration points

The upstream RLS `lua/ge/extensions/gameplay/phone.lua` exposes `togglePhone` and `isPhoneOpen`. Opening currently emits `guihooks.trigger('ChangeState', {state = 'phone-main'})` or `phone-taxi`; closing emits `guihooks.trigger('closePhone')`. Phone visibility is tied to vehicle speed and cab state.

The existing 0.39 builder applies a guard for RLS's unavailable `gameplay_taxi.isTaxiJobActive()`. Preserve that compatibility fix.

## Proposed migration

1. **Inventory CareerMP UI endpoints first.** Identify each shipped app (including optional add-ons such as Banking/Party/Tablet) and separate UI controls from their Lua/BeamMP network handlers.
2. **Add a CareerMP tile on `phone-main`.** Use RLS's existing phone view/state registration, not a new fullscreen router or an override of BeamNG's `play` route.
3. **Create a phone-specific CareerMP screen.** Render player list and status first, then banking, parties, and shared-vehicle actions only when the corresponding extension exists. Call the existing CareerMP handlers; do not duplicate network events or persistence.
4. **Keep legacy UI apps enabled during testing.** Add an opt-in flag for phone-first UI only after the new screen has been tested, and retain an escape path to exit the phone.
5. **Do not load the phone on behalf of CareerMP.** RLS must own its lifecycle. A missing phone or unavailable CEF view must fail gracefully, leaving CareerMP's old UI functional.

## Compatibility boundaries

- All original CareerMP gameplay and networking stays intact.
- RLS's `phone-taxi` behaviour takes precedence while a taxi job is active.
- Avoid global `ChangeState` event hijacks and global CEF boot hooks.
- Avoid touching the main compatibility branch until the phone path is confirmed functional.

## First implementation milestone

Open RLS phone normally -> CareerMP tile visible -> select tile -> read-only connected-player/status view -> Back -> phone-main -> close phone. Then migrate transactional features individually after validating callbacks and server authority.

## Pending source inspection

Inspect original RLS phone UI route/view files and the extracted `CareerMP-0.39` client UI assets in the actual input ZIP archives before shipping any UI replacement. The compatibility repo is an overlay/builder and does not contain the complete original mod UI bundles.
