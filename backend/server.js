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
    console.log('✅ Connected to MongoDB Atlas');
    console.log(`   Database: ${DB_NAME} | Collection: ${COLLECTION_NAME}`);
  } catch (err) {
    console.error('❌ MongoDB connection error:', err.message);
    console.error('   The server will start and return empty data until connected.');
    console.error('   Make sure your IP is whitelisted in MongoDB Atlas:');
    console.error('   Atlas → Network Access → Add IP → 0.0.0.0/0 (for testing)');
    dbCollection = null;
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

// ── Routes ─────────────────────────────────────────────────────────────────

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

    const documents = await dbCollection
      .find({}, { projection: MOBILE_CCTV_PROJECTION })
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
        { status: { $in: [status, status.toUpperCase()] } },
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

// ── Start server ─────────────────────────────────────────────────────────────
// Start the server immediately, attempt DB connection in the background
app.listen(PORT, () => {
  console.log(`🚀 SUBAY backend running on http://localhost:${PORT}`);
  console.log(`   CCTV endpoint:  http://localhost:${PORT}/api/cctv`);
  console.log(`   Alerts endpoint: http://localhost:${PORT}/api/alerts`);
});

connectDB();
scheduleReconnect();
