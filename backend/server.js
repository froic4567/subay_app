require('dotenv').config();

const express = require('express');
const cors = require('cors');
const { MongoClient } = require('mongodb');

const app = express();
const PORT = process.env.PORT || 3000;

// ── MongoDB connection ──────────────────────────────────────────────────────
const uri = process.env.MONGODB_URI || '';
if (!uri) {
  console.error('❌ MONGODB_URI is not defined. Set it in backend/.env or the environment.');
}

// Connection options with generous timeouts to handle slow networks
const client = new MongoClient(uri, {
  serverSelectionTimeoutMS: 30000,   // 30s to find a server
  connectTimeoutMS: 30000,           // 30s to establish connection
  socketTimeoutMS: 45000,            // 45s for socket operations
  retryWrites: true,
  maxPoolSize: 10,
});

// Explicitly target your database and collection names
const DB_NAME = process.env.MONGODB_DB || 'CCTVs';
const COLLECTION_NAME = process.env.MONGODB_COLLECTION || 'cctv data';
const METRICS_COLLECTION_NAME =
  process.env.MONGODB_METRICS_COLLECTION || 'routing metrics';
const MOBILE_CCTV_PROJECTION = {
  _id: 1,
  status: 1,
  water_level: 1,
  location: 1,
  timestamp: 1,
  location_label: 1,
  location_name: 1,
};

let dbCollection = null;
let metricsCollection = null;
let isConnecting = false;

// This backend is fully database-driven. When MongoDB is unavailable or has no
// documents, endpoints return an empty array so the app never shows phantom
// (hardcoded) flood hazards — routing depends solely on real database markers.

async function connectDB() {
  if (isConnecting) return;
  isConnecting = true;

  try {
    await client.connect();
    const database = client.db(DB_NAME);
    dbCollection = database.collection(COLLECTION_NAME);
    metricsCollection = database.collection(METRICS_COLLECTION_NAME);
    console.log('✅ Connected to MongoDB Atlas');
    console.log(`   Database: ${DB_NAME} | Collection: ${COLLECTION_NAME}`);
    console.log(`   Metrics collection: ${METRICS_COLLECTION_NAME}`);
  } catch (err) {
    console.error('❌ MongoDB connection error:', err.message);
    console.error('   The server will start and return empty data until connected.');
    console.error('   Make sure your IP is whitelisted in MongoDB Atlas:');
    console.error('   Atlas → Network Access → Add IP → 0.0.0.0/0 (for testing)');
    dbCollection = null;
    metricsCollection = null;
  } finally {
    isConnecting = false;
  }
}

// Attempt reconnection every 30 seconds if DB is down
function scheduleReconnect() {
  setInterval(async () => {
    if (!dbCollection && !isConnecting) {
      console.log('🔄 Attempting to reconnect to MongoDB...');
      await connectDB();
    }
  }, 30000);
}

// ── Middleware ───────────────────────────────────────────────────────────────
app.use(cors());
app.use(express.json());

// Ensure documents are JSON-safe for clients: convert ObjectId to string
function sanitizeDocs(docs) {
  return docs.map((d) => {
    // shallow copy so we don't mutate the DB result
    const copy = { ...d };
    if (copy._id && typeof copy._id.toString === 'function') {
      copy._id = copy._id.toString();
    }
    return copy;
  });
}

// Map/routing clients index directly into `location.coordinates`, so a single
// document missing that field would make the whole response unusable on the
// client. Only return geolocated records from the map-facing endpoints.
// (The notification screen uses /api/cctv too and handles missing coordinates,
// but map and routing must only ever receive points.)
const VALID_LOCATION_FILTER = {
  'location.coordinates.0': { $exists: true },
  'location.coordinates.1': { $exists: true },
};

// ── Routes ─────────────────────────────────────────────────────────────────

// Friendly root page (the API itself lives under /api).
app.get('/', (req, res) => {
  res.json({
    service: 'FloodSight backend',
    status: 'ok',
    dbConnected: dbCollection !== null,
    endpoints: [
      '/api/health',
      '/api/cctv',
      '/api/alerts',
      '/api/routing-metrics',
    ],
  });
});

// Health check
app.get('/api/health', (req, res) => {
  res.json({ status: 'ok', dbConnected: dbCollection !== null });
});

// GET all CCTV data from MongoDB
// Returns array of documents matching the schema:
// { status, water_level, location: { type: "Point", coordinates: [lng, lat] }, timestamp }
app.get('/api/cctv', async (req, res) => {
  try {
    if (!dbCollection) {
      console.log('⚠️  DB not connected, returning empty list');
      return res.json([]);
    }

    // Map/routing clients index straight into `location.coordinates`, so by
    // default only geolocated records are returned. A single locationless
    // document used to break the app's entire flood-data load. The notification
    // screen (which tolerates missing coordinates) opts out with
    // ?includeWithoutLocation=true.
    const includeLocationless =
      req.query.includeWithoutLocation === 'true' ||
      req.query.includeWithoutLocation === '1';

    const documents = await dbCollection
      .find(includeLocationless ? {} : VALID_LOCATION_FILTER, {
        projection: MOBILE_CCTV_PROJECTION,
      })
      .toArray();
    res.json(sanitizeDocs(documents));
  } catch (err) {
    console.error('Error fetching CCTV data:', err.message);
    res.json([]);
  }
});

// GET CCTV data filtered by status (danger, alert, safe), regardless of case
app.get('/api/cctv/:status', async (req, res) => {
  try {
    if (!dbCollection) {
      return res.json([]);
    }

    const status = req.params.status.toLowerCase();
    const documents = await dbCollection
      .find(
        {
          status: { $in: [status, status.toUpperCase()] },
          ...VALID_LOCATION_FILTER,
        },
        { projection: MOBILE_CCTV_PROJECTION }
      )
      .toArray();
    res.json(sanitizeDocs(documents));
  } catch (err) {
    console.error('Error fetching CCTV data by status:', err.message);
    res.json([]);
  }
});

// GET alerts only — returns documents with status 'alert' or 'danger'
// Used by the Notification screen
app.get('/api/alerts', async (req, res) => {
  try {
    if (!dbCollection) {
      return res.json([]);
    }

    const documents = await dbCollection
      .find(
        { status: { $in: ['alert', 'danger', 'ALERT', 'DANGER'] } },
        { projection: MOBILE_CCTV_PROJECTION }
      )
      .toArray();

    // Sort by timestamp descending (newest first)
    documents.sort((a, b) => {
      const ta = new Date(a.timestamp || 0).getTime();
      const tb = new Date(b.timestamp || 0).getTime();
      return tb - ta;
    });

    res.json(sanitizeDocs(documents));
  } catch (err) {
    console.error('Error fetching alerts:', err.message);
    res.json([]);
  }
});

// POST routing performance metrics from the Flutter app.
// Stored in the `routing metrics` collection (configurable via
// MONGODB_METRICS_COLLECTION) so mobile runs can be inspected in MongoDB
// without needing a browser DevTools console.
app.post('/api/routing-metrics', async (req, res) => {
  try {
    if (!metricsCollection) {
      return res.status(503).json({
        error: 'Metrics storage unavailable: MongoDB is not connected.',
      });
    }

    const payload = req.body;
    if (!payload || typeof payload !== 'object' || Array.isArray(payload)) {
      return res.status(400).json({ error: 'Invalid metrics payload.' });
    }

    const document = {
      ...payload,
      receivedAt: new Date(),
      receivedBy: 'floodsight-backend',
    };

    const result = await metricsCollection.insertOne(document);
    return res.status(201).json({
      ok: true,
      id: result.insertedId.toString(),
    });
  } catch (err) {
    console.error('Error storing routing metrics:', err.message);
    return res.status(500).json({ error: 'Failed to store routing metrics.' });
  }
});

// GET recent routing metrics (newest first) for inspection/export.
app.get('/api/routing-metrics', async (req, res) => {
  try {
    if (!metricsCollection) {
      return res.json([]);
    }

    const requested = Number.parseInt(req.query.limit, 10);
    const limit = Number.isFinite(requested)
      ? Math.min(Math.max(requested, 1), 500)
      : 100;

    const documents = await metricsCollection
      .find({})
      .sort({ receivedAt: -1 })
      .limit(limit)
      .toArray();

    res.json(sanitizeDocs(documents));
  } catch (err) {
    console.error('Error fetching routing metrics:', err.message);
    res.json([]);
  }
});

// ── Start server ─────────────────────────────────────────────────────────────
// Start the server immediately, attempt DB connection in the background
app.listen(PORT, () => {
  console.log(`🚀 SUBAY backend running on http://localhost:${PORT}`);
  console.log(`   CCTV endpoint:  http://localhost:${PORT}/api/cctv`);
  console.log(`   Alerts endpoint: http://localhost:${PORT}/api/alerts`);
  console.log(`   Metrics endpoint: http://localhost:${PORT}/api/routing-metrics`);
});

connectDB();
scheduleReconnect();

// ── Free-tier keep-alive ─────────────────────────────────────────────────────
// Render's free instances sleep after ~15 minutes without inbound traffic.
// Pinging our own public URL counts as inbound traffic and keeps the service
// warm, so phone users do not hit a 30-60s cold start on first request.
const SELF_URL = process.env.RENDER_EXTERNAL_URL;
if (SELF_URL) {
  const ping = () => {
    fetch(`${SELF_URL}/api/health`).catch(() => {});
  };
  setInterval(ping, 10 * 60 * 1000);
  console.log(`   Keep-alive enabled for ${SELF_URL}`);
}
