# FIX CCTV ROAD COLORING — FINAL PROMPT

Read first:
- LOGS.md
- SPEC.md
- RULES.md
- `lib/screens/map_screen.dart`
- `lib/services/road_segment_service.dart`
- `lib/services/route_planner.dart`
- `lib/services/geo_utils.dart`
- existing CCTV/API/database code

## Main Problem

The current app displays CCTV markers correctly, but it does NOT display the colored road segments.

Current logs show:

```text
[Map] Displaying 21 CCTV markers on map
[RoadSegment] Overpass query failed ...
TimeoutException after 0:00:10

Therefore the current RoadSegmentService is failing before it can return road geometry.

Fix this actual problem.

WHAT I WANT
I do NOT want the CCTV point to be colored.

I want the actual road covered/affected by the CCTV to be colored, similar to Google Maps traffic visualization.

Example:

Normal road ================================

              🟠 CCTV
        =========================
             ORANGE ROAD


For DANGER:

Normal road ================================

              🔴 CCTV
        =========================
                RED ROAD

The colored line must follow the real road geometry.

Do NOT use:

circles
radius indicators
straight lines
a colored dot
arbitrary lines between coordinates
manually stored road points
DATABASE MUST NOT CHANGE
The CCTV database only has one coordinate.

Example:

latitude: 8.487
longitude: 124.651
status: ALERT

Keep this structure.

Do NOT add:

road_points[]
coverage_points[]

The system must determine the road automatically from the CCTV coordinate using available OSM/map road geometry.

ROAD SEGMENT LOGIC
Use the CCTV coordinate to:

Find the appropriate nearby vehicle road.
Project the CCTV coordinate onto that road.
Obtain the real OSM road geometry.
Determine the road segment associated with the CCTV.
Prefer logical road boundaries such as intersections/junctions.
Return the actual road polyline.
The desired result is approximately:

intersection                         intersection
     |                                    |
=====+====================================+=====
                 🔴 CCTV
             DANGER SEGMENT

The segment should normally stop at reasonable intersections/junctions.

If there is a long straight road without an intersection, use the available OSM geometry to create a reasonable affected section.

Do NOT make 200m before + 200m after the normal behavior.

The existing 200m clipping may remain ONLY as a clearly documented fallback when topology cannot be determined.

FIX OVERPASS
The current implementation makes many Overpass requests and they are timing out.

Do NOT simply increase the timeout.

Do NOT launch 20+ independent Overpass requests simultaneously.

Instead:

limit request concurrency
cache road geometry
prevent duplicate requests
retry temporary failures
use a reliable Overpass endpoint
preferably move road lookup/caching to the existing backend if that fits the current architecture
The mobile app should not overload Overpass.

If the backend can safely provide:

CCTV coordinate
      ↓
Backend
      ↓
Overpass / OSM
      ↓
Road geometry
      ↓
Mobile Map

prefer this architecture.

But preserve the existing development workflow unless a change is necessary.

MAP
Keep the CCTV marker at its original database coordinate.

Additionally render the actual road segment.

Colors:

NORMAL → normal road / green according to existing design
ALERT  → orange
DANGER → red

The road geometry must follow the real road.

Example:

          /
         /
========/================
       /
      🔴 CCTV


The red/orange polyline must curve with the road.

Multiple cameras must work independently.

If two cameras affect the same road:

DANGER > ALERT > NORMAL

DANGER must always win.

STATUS UPDATES
Road geometry should be cached.

Do NOT query OSM again every time status changes.

For:

NORMAL → ALERT → DANGER → NORMAL

reuse the same road geometry and only change:

road color
flood severity
routing behavior
ROUTING
Map and Routing must use the SAME resolved road segment.

Do not let Routing treat the CCTV as only a point.

Bad:

==================🔴==================
                  CCTV

Good:

========== RED AFFECTED ROAD ==========
                 CCTV

DANGER:

treat the affected road segment as unsafe/blocked
avoid it when an alternative exists
ALERT:

use the existing routing penalty/safety logic
NORMAL:

no flood penalty
This must prevent unnecessary turns immediately before a dangerous CCTV coordinate on a long straight road.

INTERSECTIONS
Use OSM topology where possible.

If a CCTV is between two intersections:

       intersection
             +
             |
=============+================
        🔴 CCTV
=============+================
             |
             +
       intersection

Color the road section associated with that CCTV.

Do not accidentally color connected side roads.

PARALLEL ROADS
If two roads are close together:

choose the best road based on actual geometry/proximity
do not randomly select a road
document the limitation if the coordinate alone cannot distinguish them
Do NOT add camera direction/orientation to the database unless absolutely necessary.

If it is technically impossible to determine the correct road from one coordinate, STOP and explain why before changing the database schema.

FALLBACK
If Overpass temporarily fails:

Do not fabricate road geometry.

Do not draw a fake line or circle.

Log:

[RoadSegment] Overpass failed
[RoadSegment] retrying
[RoadSegment] no road geometry available

A fallback to the previous point-based routing behavior is acceptable for temporary failure, but successful operation must use real road geometry.

BACKEND CONNECTIVITY
Check the existing BACKEND_URL configuration.

The physical phone must NOT use:

localhost

because localhost on the phone means the phone itself.

For physical-device development, use the desktop's LAN IP, for example:

BACKEND_URL=http://192.168.x.x:3000

Do not expose MongoDB credentials to Flutter.

Preserve:

cd backend
npm run dev

unless there is a clear reason to change it.

IMPORTANT IMPLEMENTATION RULE
Do not rewrite the whole application.

Reuse the existing:

RoadSegmentService
GeoUtils
RoutePlanner
CCTV model
flood status
Map rendering
backend API
Fix the broken road-segment pipeline.

Before editing:

Find why Overpass requests are timing out.
Find where road geometry is lost.
Check whether RoadSegmentService actually returns geometry.
Check whether map_screen.dart actually renders the returned geometry.
Check whether route_planner.dart actually uses the returned geometry.
Then make the smallest necessary changes.
FINAL ACCEPTANCE TEST
The task is complete only when a test CCTV produces:

CCTV coordinate
      ↓
OSM road matched
      ↓
actual road polyline
      ↓
Map displays colored road
      ↓
Routing uses same road segment

For example:

CCTV #13 = DANGER

        intersection
             +
             |
=============+========================
          🔴
       CCTV #13

ROAD SEGMENT = RED

And:

CCTV #5 = ALERT

=======================================
             🟠
          CCTV #5

ROAD SEGMENT = ORANGE

The important result is:

COLOR THE ROAD, NOT THE CAMERA POINT.

Do not report "implemented" if the logs still show that all RoadSegmentService requests are timing out and no road polylines appear on the Map.