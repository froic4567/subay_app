Task: Add Camera Road Coverage and Flooded Road Visualization to Map and Routing

Description
The mobile app can currently be installed and accessed by connecting the mobile device through USB, but the backend still needs to be manually started on the desktop through the terminal using cd backend followed by npm run dev. This limits the mobile application's ability to operate with the backend when the app is being used outside the development setup.

The current database stores flood information using camera locations, status, water level, coordinates, ROI configuration, HSV thresholds, and camera stream configuration. The Map and Routing tabs currently use the camera's database location as a plotted camera icon.

We want to improve this system so that the map does not only display the camera location. It should also determine and visualize the road segment covered or monitored by each CCTV camera. The road covered by a camera should be represented on the map according to the current flood status of that camera.

The camera currently uses a single coordinate point in the database. Do not immediately change this into a list of manually configured points. Investigate whether the existing map or routing provider can use the camera's coordinate to automatically identify the associated road segment and obtain its road geometry.

If the camera's single coordinate is sufficient to identify the appropriate road segment, keep the existing database structure unchanged. If additional information such as camera direction, coverage distance, field of view, or road association is required, determine this through investigation before making a database or configuration change.

This road-based visualization should also improve routing behavior. Instead of treating a flood as only a point at the camera's coordinates, the routing system should recognize the affected road segment. This should help prevent unnecessary turns near danger zones and improve flood avoidance on long or straight roads.

Task
Update the mobile application's backend connectivity, Map tab, Routing tab, and flood visualization system to support camera-covered road segments.

For backend connectivity:

Investigate the current backend architecture and how the mobile application connects to the backend.

Identify why the mobile application currently depends on manually running cd backend and npm run dev on the development desktop.

Determine the appropriate way for the mobile application to communicate with the backend when running on a physical mobile device.

Make sure the mobile application can access the backend using a reachable backend address rather than relying on localhost from the mobile device.

Do not simply hardcode localhost for mobile backend communication, since localhost on the mobile device refers to the mobile device itself.

Check the existing API configuration, environment variables, network configuration, and backend startup process before making changes.

Preserve the existing development workflow where possible.

For the Map tab:

Keep the existing camera icon/marker showing the camera's database location.

Add visualization of the road segment covered or affected by each camera.

Investigate how the camera's location can be associated with the actual road segment visible, monitored, or affected by the CCTV camera.

Use existing map/routing road geometry where possible instead of manually storing a list of road coordinates.

The camera's database coordinate should be used as the starting point for determining the associated road segment.

If the mapping or routing provider supports nearest-road, road matching, road geometry, or similar functionality, investigate and use the appropriate existing capability.

Display the affected road segment using the camera's current flood status.

DANGER should display the affected road segment in red.

ALERT should display the affected road segment in orange.

NORMAL should display the road as normal, green, or without a flood warning color depending on the existing map design.

The visualization must represent the actual road segment rather than only displaying a colored point around the camera marker.

Make sure multiple cameras can display their affected road segments independently.

Update the road visualization automatically when the camera's flood status changes.

Do not require the admin or database to manually enter multiple points just to color a road segment unless investigation proves that this is technically necessary.

For the Routing tab:

Integrate the affected road segments into the routing system.

Flooded road segments must be treated as actual affected areas during route calculation rather than only using the camera's coordinate as a single danger point.

The routing system should avoid road segments marked as DANGER.

The routing system should appropriately account for ALERT road segments according to the existing routing safety logic.

Ensure a route does not unnecessarily turn immediately before or near a dangerous road segment simply because the camera's coordinate is being treated as a point obstacle.

On long straight roads, the routing system must be able to recognize that the affected road segment continues beyond the camera's exact coordinates.

The routing system should select a safe alternative road when the affected segment is actually flooded.

Preserve the existing rerouting algorithm where it is already functioning correctly.

When flood status changes while a user is navigating, ensure the affected road segment and routing decision can be updated accordingly.

For road coverage and road association:

Investigate how the current mapping/routing provider represents road geometry.

Determine whether the existing camera coordinate can automatically be matched to the nearest or appropriate road segment.

Determine whether the route geometry already available in the application can be reused to identify the affected road.

Consider GPS inaccuracies and nearby or parallel roads when determining the associated road segment.

Do not assume that the nearest road is always the correct road if there are multiple roads close to the camera.

Determine whether the single camera coordinate is enough to identify the road being monitored.

If the camera coordinate alone is sufficient, keep the existing database structure unchanged.

If the camera's direction, field of view, coverage distance, or another value is required to accurately determine the monitored road, explain the requirement and ask for clarification before implementing a major configuration or database change.

Do not create a manually maintained list of road points unless investigation proves that there is no reliable way to determine the road geometry automatically.

For database integration:

Use the existing flood information stored in the database as the source for the camera's status and location.

The current document structure includes fields such as status, water_level, coordinates, hsv_thresholds, roi_config, and stream_config.

Do not unnecessarily change or remove existing database fields.

Investigate whether additional information is required to accurately identify the road segment covered by a camera.

If additional database fields or a new data structure are required, determine the cleanest approach before implementing it.

Consider whether camera orientation, road association, coverage distance, or road-segment geometry needs to be stored to accurately represent the CCTV's monitored road.

Do not assume that the camera's Point coordinates alone are sufficient to determine its road coverage without investigating the existing map and routing implementation.

Acceptance Criteria

The mobile application can communicate with the backend from a physical mobile device without incorrectly attempting to connect to the mobile device's own localhost.

The existing backend development workflow remains functional.

The Map tab continues to display the camera icon at its database coordinates.

The Map tab additionally displays the road segment monitored or affected by each camera.

The road segment follows actual road geometry and is not represented only by a radius, circle, or colored point.

A DANGER camera causes its associated road segment to be visually represented in red.

An ALERT camera causes its associated road segment to be visually represented in orange.

A NORMAL camera does not display the road as dangerous and uses the appropriate normal/green/no-warning representation.

All three cameras can independently display their corresponding road segments.

Changes in camera flood status are reflected in the road visualization.

The Routing tab uses the affected road segments when calculating routes.

A dangerous road segment is avoided instead of treating only the camera coordinate as a single point obstacle.

Long straight roads affected by flooding are properly recognized as blocked/unsafe where applicable.

The routing system does not create unnecessary turns simply because a camera danger point exists near a straight road.

Routes remain reasonably direct while still avoiding affected road segments.

Existing rerouting functionality continues to work.

The camera does not need to have a manually maintained list of road points unless the existing mapping/routing technology cannot determine the road geometry automatically.

The system uses the existing camera coordinate and available road geometry wherever possible.

The system is tested with multiple cameras, different flood statuses, straight roads, intersections, nearby roads, and alternative routes.

No existing working Map, Routing, camera, or flood-monitoring functionality is removed without a clear technical reason.

Prerequisites

Read LOGS.md, this is where you will see the recent changes made in the project.

Read SPEC.md, this is the entire identity of the project.

Read RULES.md, this is the guidelines you will follow when working or editing the project.

Read the entire existing mobile Map tab implementation.

Read the entire existing mobile Routing tab implementation.

Read the existing backend API and networking configuration.

Read the existing database models, queries, and flood-status handling.

Read the existing routing and rerouting algorithms before modifying them.

Investigate how map roads and road segments are currently obtained or rendered.

Investigate how the camera coordinates from the database are currently converted into map markers.

Investigate whether the existing routing provider/API exposes road geometry that can be used to identify the affected road segment.

Investigate whether the existing mapping/routing provider supports nearest-road, road matching, map matching, or road-segment identification.

Determine how the camera's field of view and road coverage can realistically be represented using the information currently available.

Do not assume the camera's GPS point represents the entire flooded road.

Do not immediately modify the database to store multiple road points.

First determine whether the existing camera coordinate and available road geometry are sufficient.

If the current database does not contain enough information to determine the camera-covered road segment accurately, ask for clarification before making a major database/schema change.

Always ask when implementing major changes.

Test the implementation on an actual mobile device where possible, not only through the desktop development environment.