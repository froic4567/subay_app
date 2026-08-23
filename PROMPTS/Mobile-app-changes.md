Mobile Map Location Tracking and Routing Improvements

Task: Improve Mobile Map Location Tracking and Routing

Description
The mobile app is currently working, but there are issues with continuous user location tracking and route generation in the Map tab. User location only updates when the Current Location button is pressed, instead of continuously tracking the user's position. This tracking should work regardless of whether the user is currently navigating or using the routing feature.

The rerouting algorithm is generally working correctly, but the generated routes sometimes contain unnecessary turns or detours. There are also cases where a long straight road passes through or alongside a flooded zone without the routing system properly avoiding the flooded area.

Task
Update the mobile app's location tracking and routing behavior to improve real-time location updates and route generation.

For the Map tab:

Make the user's location continuously track and update while the user is using the map.
The user's location tracking must work even when the user is not in Navigation Mode.
The user's location tracking must work even when the user is not currently in the Routing tab or actively requesting a route.
The Current Location button should still function, but it should no longer be required to manually trigger location updates.
Make sure continuous tracking does not interfere with the existing map interactions, routing, or navigation functionality.
Check how location permissions, background/foreground location updates, map markers, and location listeners are currently implemented before making changes.

For routing:

Keep the existing rerouting algorithm and behavior that is already working correctly.
Investigate unnecessary turns in generated routes.
Prevent routing from making unnecessary turns or short detours when the road continues in a more direct direction.
Investigate cases where a route travels along a long straight road but does not properly avoid a flooded zone located on that road.
Improve the routing logic so flooded areas are properly considered even when they occur along long straight sections of a road.
Make sure flooded zones are treated as obstacles that the route must avoid rather than only checking certain portions or intersections of the route.
Ensure the improved routing behavior does not break the existing rerouting functionality.
Test routes containing straight roads, flooded sections, intersections, turns, and alternative roads to verify that the generated route is both safe and reasonably direct.

Acceptance Criteria

The user's location continuously updates while viewing the Map tab without requiring the Current Location button to be pressed.
Location tracking continues to work when the user is not navigating.
Location tracking continues to work when the user is not in the Routing tab.
The Current Location button continues to work as an immediate/manual location-centering action.
The user's map marker correctly reflects the user's latest available position.
Existing location permission handling continues to work correctly.
Existing navigation and routing functionality remains functional after the location tracking changes.
Routes no longer contain unnecessary turns where a direct and valid road connection exists.
The routing system properly detects and avoids flooded zones located along long straight roads.
Flooded zones are consistently considered when calculating both the initial route and subsequent reroutes.
Rerouting continues to function correctly when the user encounters a flooded area or when flood information changes.
The routing system should prefer a reasonable direct route when it is safe, while still prioritizing avoidance of flooded areas.
Test all relevant routing scenarios and confirm that the changes do not introduce regressions.

Prerequisites

Read LOGS.md, this is where you will see the recent changes made in the project.
Read SPEC.md, this is the entire identity of the project.
Read RULES.md, this is the guidelines you will follow when working or editing the project.
Read the existing mobile application's Map tab implementation and identify how the current user location is obtained, updated, displayed, and stored.
Read the existing navigation and routing implementation before modifying the routing algorithm.
Read the existing rerouting implementation and preserve the parts that are already working correctly.
Identify how flooded zones are currently passed into or considered by the routing system.
Investigate why flooded zones may be skipped when they occur along long straight road segments.
Always ask when implementing major changes.
Do not remove existing working functionality unless it is necessary for the new implementation.