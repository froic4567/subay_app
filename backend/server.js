const express = require('express');
const cors = require('cors');
const { MongoClient } = require('mongodb');

const app = express();
const PORT = process.env.PORT || 3000;

// ── MongoDB connection ──────────────────────────────────────────────────────
const uri = 'mongodb+srv://langgamencarlsyker_db_user:jXWU3wKwkMgHxqpH@cluster0.0fpztcp.mongodb.net/';

// Connection options with generous timeouts to handle slow networks
const client = new MongoClient(uri, {
  serverSelectionTimeoutMS: 30000,   // 30s to find a server
  connectTimeoutMS: 30000,           // 30s to establish connection
  socketTimeoutMS: 45000,            // 45s for socket operations
  retryWrites: true,
  maxPoolSize: 10,
});

// Explicitly target your database and collection names
const DB_NAME = 'CCTVs';
const COLLECTION_NAME = 'cctv data';

let dbCollection = null;
let isConnecting = false;

// Fallback sample data (matches MongoDB document structure)
const fallbackData = [
  {
    status: 'danger',
    water_level: 1.345,
    location: { type: 'Point', coordinates: [124.6433, 8.4822] },
    timestamp: '2026-07-15T07:30:00Z',
  },
  {
    status: 'alert',
    water_level: 0.42,
    location: { type: 'Point', coordinates: [124.6493, 8.4857] },
    timestamp: '2026-07-15T07:31:00Z',
  },
  {
    status: 'safe',
    water_level: 0.08,
    location: { type: 'Point', coordinates: [124.6476, 8.4872] },
    timestamp: '2026-07-15T07:32:00Z',
  },
  {
    status: 'danger',
    water_level: 0.95,
    location: { type: 'Point', coordinates: [124.6530, 8.4838] },
    timestamp: '2026-07-15T07:33:00Z',
  },
  {
    status: 'safe',
    water_level: 0.05,
    location: { type: 'Point', coordinates: [124.6501, 8.4818] },
    timestamp: '2026-07-15T07:34:00Z',
  },
  {
    status: 'alert',
    water_level: 0.3,
    location: { type: 'Point', coordinates: [124.6512, 8.4900] },
    timestamp: '2026-07-15T07:35:00Z',
  },
];

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
    console.error('   The server will start with fallback data.');
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
      console.log('⚠️  DB not connected, returning fallback data');
      return res.json(fallbackData);
    }

    const documents = await dbCollection.find({}).toArray();
    if (documents.length === 0) {
      return res.json(fallbackData);
    }
    res.json(documents);
  } catch (err) {
    console.error('Error fetching CCTV data:', err.message);
    // Return fallback instead of error so the app still works
    res.json(fallbackData);
  }
});

// GET CCTV data filtered by status (danger, alert, safe)
app.get('/api/cctv/:status', async (req, res) => {
  try {
    if (!dbCollection) {
      const status = req.params.status.toLowerCase();
      return res.json(fallbackData.filter(d => d.status === status));
    }

    const status = req.params.status.toLowerCase();
    const documents = await dbCollection.find({ status: status }).toArray();
    res.json(documents);
  } catch (err) {
    console.error('Error fetching CCTV data by status:', err.message);
    const status = req.params.status.toLowerCase();
    res.json(fallbackData.filter(d => d.status === status));
  }
});

// GET alerts only — returns documents with status 'alert' or 'danger'
// Used by the Notification screen
app.get('/api/alerts', async (req, res) => {
  try {
    if (!dbCollection) {
      return res.json(fallbackData.filter(d =>
        d.status === 'alert' || d.status === 'danger'
      ));
    }

    const documents = await dbCollection.find({
      status: { $in: ['alert', 'danger'] }
    }).toArray();

    // Sort by timestamp descending (newest first)
    documents.sort((a, b) => {
      const ta = new Date(a.timestamp || 0).getTime();
      const tb = new Date(b.timestamp || 0).getTime();
      return tb - ta;
    });

    res.json(documents);
  } catch (err) {
    console.error('Error fetching alerts:', err.message);
    res.json(fallbackData.filter(d =>
      d.status === 'alert' || d.status === 'danger'
    ));
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
