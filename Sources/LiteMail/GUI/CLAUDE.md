## AppKit / Core Animation Rules

- **Never mutate shared state during framework callbacks.** Drawing, layout, and CA commit callbacks are called by the system at precise moments — mutating other objects' state inside them (e.g. another view's layer in `updateLayer()`) causes corruption. Scope side effects to the object being updated.
- **Set state where it changes, not where it renders.** Data-driven properties (colors, text, images) belong in update/configure methods, not in draw/layer callbacks. Renderers should read state, not write it.
- **Avoid redundant setup that duplicates framework behavior.** When a framework property implies another (e.g. `wantsUpdateLayer` implies `wantsLayer`), setting both causes subtle ordering bugs. Know what each API controls.
- **Retain any token-based registration.** APIs that return an opaque object to represent a registration (event monitors, observers, notification tokens) require that object to be stored; releasing it silently unregisters — often causing crashes or missed events later.
- **All UI work on the main thread.** Never update views, layers, or window state from a background thread or unconfined `actor`. Use `MainActor` for all GUI callbacks.
