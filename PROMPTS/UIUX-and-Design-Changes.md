UI/UX and Design Requirements

The mobile application is built using Flutter and should have a polished, modern, and professional user interface.

A CSS file from the FloodSight web application will be provided in the project folder for reference. The CSS belongs to the same FloodSight project and may contain the existing visual identity, including colors, status colors, typography, spacing, borders, shadows, component styling, and other design decisions.

Before modifying the UI:

Locate and inspect the provided web application CSS file.
Identify the primary FloodSight color palette and visual design language.
Identify the colors used for flood statuses such as DANGER, ALERT, and NORMAL.
Identify any typography, spacing, border radius, shadows, buttons, cards, navigation, and other reusable design patterns that can reasonably be translated into the Flutter application.
Inspect the existing Flutter application's UI and determine which parts of its current design should be preserved.
Do not directly copy CSS into Flutter.
Translate the relevant design language into appropriate Flutter widgets, themes, styles, and reusable components.
Keep the mobile application visually consistent with the FloodSight web application while still following good mobile UI/UX practices.
Do not make the mobile interface look like a desktop web application.
Use Flutter's appropriate layout, theming, animation, and responsive design capabilities.

For the Map and Routing tabs:

Make the map the primary visual focus of the interface.
Ensure camera markers, road-status colors, route lines, flood indicators, and user-location indicators are visually distinguishable.
Use the FloodSight status colors consistently throughout the Map and Routing interfaces.
Make DANGER, ALERT, and NORMAL states immediately understandable without relying only on text.
Ensure road colors remain visible against the underlying map tiles.
Avoid excessive colors, unnecessary borders, or visually distracting elements.
Use appropriate visual hierarchy for map controls, status information, route information, and navigation controls.
Make buttons and interactive controls easy to identify and use on a mobile device.
Use appropriate loading, error, empty, and unavailable states.
Use smooth and subtle animations where they improve usability, especially for location updates, route changes, flood-status changes, and map overlays.
Ensure UI changes do not negatively affect map performance or routing performance.

For the overall Flutter application:

Follow the existing Flutter project's architecture and coding conventions.
Prefer reusable widgets and centralized theme/design values rather than duplicating styles throughout the application.
Use responsive layouts so the interface works correctly across different mobile screen sizes.
Maintain consistent spacing, typography, iconography, and component sizing.
Ensure sufficient contrast and readability.
Avoid overly complex UI elements that make the map difficult to use.
Preserve existing functionality while improving the visual presentation.
Do not redesign unrelated screens unnecessarily unless required for visual consistency.
The final result should feel like a polished production mobile application rather than a basic development prototype.

Acceptance Criteria for UI/UX

The Flutter application's visual design is consistent with the FloodSight web application's existing visual identity.
The provided CSS has been inspected and its relevant design characteristics have been translated into Flutter appropriately.
The Map and Routing tabs have a polished and consistent visual design.
Flood status colors are consistent between the mobile application and the existing FloodSight design.
Camera markers, affected road segments, routes, and the user's location are visually distinguishable.
Map controls are easy to use on a physical mobile device.
The UI remains responsive and usable on different screen sizes.
Loading, error, and empty states have appropriate visual treatments.
UI animations are smooth and do not interfere with map interaction or routing.
The implementation does not simply copy the web interface; it adapts the FloodSight design language appropriately for mobile.
Existing functionality is preserved while the overall application becomes more polished and professional.