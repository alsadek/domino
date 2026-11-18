const http = require('http');
const fs = require('fs');
const path = require('path');
const zlib = require('zlib');
const crypto = require('crypto');

const PORT = process.env.PORT || 8085;
const BASE = path.join(__dirname, 'build/web');

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'application/javascript; charset=utf-8',
  '.mjs': 'application/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.png': 'image/png',
  '.wasm': 'application/wasm',
  '.otf': 'font/otf',
  '.ttf': 'font/ttf',
};

const COMPRESSIBLE = new Set(['.html', '.js', '.mjs', '.css', '.json', '.wasm', '.otf', '.ttf']);

const ROOMS_FILE = path.join(__dirname, 'rooms.json');
const ROOMS_TMP = path.join(__dirname, 'rooms.json.tmp');
const USERS_FILE = path.join(__dirname, 'users.json');
const USERS_TMP = path.join(__dirname, 'users.json.tmp');
const HISTORY_FILE = path.join(__dirname, 'history.json');
const HISTORY_TMP = path.join(__dirname, 'history.json.tmp');
const ROOM_TTL_MS = 7 * 24 * 60 * 60 * 1000;
const TURN_TIMEOUT_MS = 60000;
const WATCHER_STALE_MS = 45000;
const PLAYER_ONLINE_MS = 15000;

function ensureRoomShape(room, now = Date.now()) {
  if (!room.initialDeal && room.deal) room.initialDeal = room.deal;
  if (!room.targetScore) room.targetScore = 31;
  if (!room.matchSeq) room.matchSeq = 1;
  if (!Array.isArray(room.watchers)) room.watchers = [];
  if (!room.nextRoundVotes || typeof room.nextRoundVotes !== 'object') room.nextRoundVotes = {};
  if (!room.kickedTokens || typeof room.kickedTokens !== 'object') room.kickedTokens = {};
  if (!room.creatorToken && room.players && room.players[0] && room.players[0].token) {
    room.creatorToken = room.players[0].token;
  }
  if (typeof room.started !== 'boolean') {
    room.started = (room.joinedCount >= room.playerCount) || (room.actions && room.actions.length > 0);
  }
  if (room.started && !room.turnStartedAt) room.turnStartedAt = now;
  return room;
}

function pruneWatchers(room, now = Date.now()) {
  if (!Array.isArray(room.watchers)) room.watchers = [];
  room.watchers = room.watchers.filter(w => w && (now - (w.lastSeen || w.joinedAt || now)) <= WATCHER_STALE_MS);
}

function buildPublicPlayers(room, now = Date.now()) {
  return (room.players || []).map((p, idx) => ({
    index: idx,
    name: p.name,
    userId: p.userId || null,
    isBot: Boolean(p.isBot),
    joined: Boolean(p.joined),
    online: Boolean(p.isBot || (p.joined && p.lastSeen && (now - p.lastSeen) <= PLAYER_ONLINE_MS)),
    idleSeconds: (p.joined && p.lastSeen && !p.isBot) ? Math.max(0, Math.floor((now - p.lastSeen) / 1000)) : null,
  }));
}

function buildPublicWatchers(room, now = Date.now()) {
  pruneWatchers(room, now);
  return room.watchers.map(w => ({ id: w.id, name: w.name }));
}

function computeTurnRemainingMs(room, now = Date.now()) {
  if (!room.started || !room.turnStartedAt) return TURN_TIMEOUT_MS;
  return Math.max(0, TURN_TIMEOUT_MS - (now - room.turnStartedAt));
}

function loadRooms() {
  try {
    if (!fs.existsSync(ROOMS_FILE)) return {};
    const raw = fs.readFileSync(ROOMS_FILE, 'utf8');
    const parsed = JSON.parse(raw || '{}');
    const now = Date.now();
    const active = {};
    for (const [code, room] of Object.entries(parsed)) {
      if (room && now - (room.updatedAt || room.created || now) < ROOM_TTL_MS) {
        active[code] = ensureRoomShape(room, now);
      }
    }
    return active;
  } catch (e) {
    console.warn('Could not load rooms.json:', e.message);
    return {};
  }
}

function saveRooms() {
  try {
    fs.writeFileSync(ROOMS_TMP, JSON.stringify(rooms));
    fs.renameSync(ROOMS_TMP, ROOMS_FILE);
  } catch (e) {
    console.warn('Could not save rooms.json:', e.message);
  }
}

// Persistent multiplayer rooms, users, and match history
const rooms = loadRooms();

function loadJsonFile(file, fallback) {
  try {
    if (!fs.existsSync(file)) return fallback;
    const raw = fs.readFileSync(file, 'utf8');
    return JSON.parse(raw || JSON.stringify(fallback));
  } catch (e) {
    console.warn(`Could not load ${path.basename(file)}:`, e.message);
    return fallback;
  }
}

function saveJsonFile(file, tmpFile, data) {
  try {
    fs.writeFileSync(tmpFile, JSON.stringify(data));
    fs.renameSync(tmpFile, file);
  } catch (e) {
    console.warn(`Could not save ${path.basename(file)}:`, e.message);
  }
}

const users = loadJsonFile(USERS_FILE, {});
const matchHistory = loadJsonFile(HISTORY_FILE, []);
const matchHistoryKeys = new Set(matchHistory.map(m => m.matchKey).filter(Boolean));

function saveUsers() {
  saveJsonFile(USERS_FILE, USERS_TMP, users);
}

function saveHistory() {
  saveJsonFile(HISTORY_FILE, HISTORY_TMP, matchHistory);
}

function hashPin(pin, salt) {
  return crypto.scryptSync(String(pin), salt, 32).toString('hex');
}

function verifyPin(pin, salt, expectedHex) {
  const actual = Buffer.from(hashPin(pin, salt), 'hex');
  const expected = Buffer.from(expectedHex, 'hex');
  if (actual.length !== expected.length) return false;
  return crypto.timingSafeEqual(actual, expected);
}

function resolveAuthUser(authToken) {
  if (!authToken || typeof authToken !== 'string') return null;
  for (const user of Object.values(users)) {
    if (Array.isArray(user.sessions) && user.sessions.includes(authToken)) {
      return user;
    }
  }
  return null;
}

function publicUser(user) {
  return {
    userId: user.userId,
    username: user.username,
    displayName: user.displayName || user.username,
  };
}

function buildLeaderboard(records) {
  const stats = {};
  for (const u of Object.values(users)) {
    stats[u.userId] = {
      userId: u.userId,
      displayName: u.displayName || u.username,
      gamesPlayed: 0,
      wins: 0,
      totalScore: 0,
    };
  }
  for (const rec of records) {
    for (const p of (rec.players || [])) {
      const uid = p.userId || null;
      if (!uid) continue;
      if (!stats[uid]) {
        stats[uid] = {
          userId: uid,
          displayName: p.name || uid,
          gamesPlayed: 0,
          wins: 0,
          totalScore: 0,
        };
      }
      stats[uid].gamesPlayed += 1;
      if (p.isWinner) stats[uid].wins += 1;
      stats[uid].totalScore += Number(p.score || 0);
    }
  }
  return Object.values(stats)
    .map(s => ({
      ...s,
      winRate: s.gamesPlayed > 0 ? Math.round((s.wins / s.gamesPlayed) * 100) : 0,
    }))
    .sort((a, b) => (b.wins - a.wins) || (b.totalScore - a.totalScore) || (b.gamesPlayed - a.gamesPlayed));
}

// Standard 28 domino tiles dealt to 4 players (7 tiles each, 0 boneyard)
function generateAndDealTiles(playerCount = 4) {
  const allTiles = [];
  let id = 0;
  for (let i = 0; i <= 6; i++) {
    for (let j = i; j <= 6; j++) {
      allTiles.push({ id: id++, head: i, tail: j });
    }
  }

  // Fisher-Yates shuffle
  for (let i = allTiles.length - 1; i > 0; i--) {
    const j = Math.floor(Math.random() * (i + 1));
    [allTiles[i], allTiles[j]] = [allTiles[j], allTiles[i]];
  }

  const hands = [];
  for (let p = 0; p < playerCount; p++) {
    hands.push(allTiles.slice(p * 7, (p + 1) * 7));
  }
  const boneyard = allTiles.slice(playerCount * 7);

  // Highest double starts round 1
  let starter = 0;
  let highestDouble = -1;
  for (let p = 0; p < playerCount; p++) {
    for (const t of hands[p]) {
      if (t.head === t.tail && t.head > highestDouble) {
        highestDouble = t.head;
        starter = p;
      }
    }
  }

  return { hands, boneyard, starter, playerCount };
}

function generateRoomCode() {
  let code;
  do {
    code = Math.floor(1000 + Math.random() * 9000).toString();
  } while (rooms[code]);
  return code;
}

const server = http.createServer((req, res) => {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type');

  if (req.method === 'OPTIONS') {
    res.writeHead(204);
    res.end();
    return;
  }

  const parsedUrl = new URL(req.url, `http://${req.headers.host || 'localhost'}`);
  let pathname = parsedUrl.pathname;
  if (pathname === '/domino') pathname = '/';
  else if (pathname.startsWith('/domino/')) pathname = pathname.slice('/domino'.length);
  if (pathname !== '/api/room/sync') {
    const startMs = Date.now();
    const clientIp = req.headers['x-forwarded-for'] || req.socket.remoteAddress || 'unknown';
    const ua = (req.headers['user-agent'] || '').slice(0, 60);
    let logged = false;
    res.on('finish', () => {
      logged = true;
      console.log(`[${new Date().toISOString()}] ${clientIp} ${req.method} ${pathname} -> ${res.statusCode} (${Date.now() - startMs}ms) ${ua}`);
    });
    res.on('close', () => {
      if (!logged && !res.writableEnded) {
        console.log(`[${new Date().toISOString()}] ${clientIp} ${req.method} ${pathname} -> ABORTED (${Date.now() - startMs}ms) ${ua}`);
      }
    });
  }

  const readJsonBody = (onParsed) => {
    let body = '';
    req.on('data', chunk => (body += chunk));
    req.on('end', () => {
      try {
        onParsed(JSON.parse(body || '{}'));
      } catch (_) {
        res.writeHead(400, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ ok: false, message: 'طلب غير صالح' }));
      }
    });
  };

  // --- API: Register (Username + 4-digit PIN) ---
  if (pathname === '/api/auth/register' && req.method === 'POST') {
    readJsonBody((data) => {
      const rawUsername = (data.username || '').trim();
      const userId = rawUsername.toLowerCase();
      const displayName = (data.displayName || rawUsername).trim();
      const pin = (data.pin || '').toString().trim();

      if (userId.length < 2) {
        res.writeHead(400, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ ok: false, message: 'اسم المستخدم لازم يكون حرفين على الأقل' }));
        return;
      }
      if (pin.length < 4) {
        res.writeHead(400, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ ok: false, message: 'الرقم السري (PIN) لازم يكون ٤ أرقام على الأقل' }));
        return;
      }
      if (users[userId]) {
        res.writeHead(409, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ ok: false, message: 'اسم المستخدم مسجل بالفعل — جرّب تسجيل الدخول' }));
        return;
      }

      const salt = crypto.randomBytes(16).toString('hex');
      const authToken = 'usr_' + crypto.randomBytes(24).toString('hex');
      users[userId] = {
        userId,
        username: rawUsername,
        displayName,
        salt,
        pinHash: hashPin(pin, salt),
        sessions: [authToken],
        createdAt: Date.now(),
      };
      saveUsers();

      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ ok: true, user: publicUser(users[userId]), authToken }));
    });
    return;
  }

  // --- API: Login (Username + PIN) ---
  if (pathname === '/api/auth/login' && req.method === 'POST') {
    readJsonBody((data) => {
      const rawUsername = (data.username || '').trim();
      const userId = rawUsername.toLowerCase();
      const pin = (data.pin || '').toString().trim();
      const user = users[userId];

      if (!user || !verifyPin(pin, user.salt, user.pinHash)) {
        res.writeHead(401, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ ok: false, message: 'اسم المستخدم أو الرقم السري غير صحيح' }));
        return;
      }

      const authToken = 'usr_' + crypto.randomBytes(24).toString('hex');
      if (!Array.isArray(user.sessions)) user.sessions = [];
      user.sessions.push(authToken);
      if (user.sessions.length > 8) user.sessions = user.sessions.slice(-8);
      saveUsers();

      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ ok: true, user: publicUser(user), authToken }));
    });
    return;
  }

  // --- API: Current Session Check ---
  if (pathname === '/api/auth/me' && req.method === 'GET') {
    const token = (parsedUrl.searchParams.get('token') || '').trim();
    const user = resolveAuthUser(token);
    if (!user) {
      res.writeHead(401, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ ok: false, message: 'الجلسة منتهية' }));
      return;
    }
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ ok: true, user: publicUser(user) }));
    return;
  }

  // --- API: Logout ---
  if (pathname === '/api/auth/logout' && req.method === 'POST') {
    readJsonBody((data) => {
      const token = (data.authToken || '').trim();
      const user = resolveAuthUser(token);
      if (user && Array.isArray(user.sessions)) {
        user.sessions = user.sessions.filter(t => t !== token);
        saveUsers();
      }
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ ok: true }));
    });
    return;
  }

  // --- API: Save Completed Bola Match to Shared Server History ---
  if (pathname === '/api/history/save' && req.method === 'POST') {
    readJsonBody((data) => {
      const matchKey = (data.matchKey || '').trim() || null;
      if (matchKey && matchHistoryKeys.has(matchKey)) {
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ ok: true, duplicate: true }));
        return;
      }

      const record = {
        id: (data.id || `${Date.now()}_${Math.random().toString(36).substring(2, 7)}`).toString(),
        matchKey,
        date: data.date || new Date().toISOString(),
        roomCode: data.roomCode || null,
        targetScore: Number(data.targetScore) || 31,
        roundsPlayed: Number(data.roundsPlayed) || 1,
        winnerName: data.winnerName || 'فائز',
        players: Array.isArray(data.players)
          ? data.players.map(p => ({
              userId: p.userId || null,
              name: p.name || 'لاعب',
              score: Number(p.score) || 0,
              isWinner: Boolean(p.isWinner),
            }))
          : [],
      };

      if (matchKey) matchHistoryKeys.add(matchKey);
      matchHistory.unshift(record);
      if (matchHistory.length > 500) matchHistory.length = 500;
      saveHistory();

      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ ok: true, id: record.id }));
    });
    return;
  }

  // --- API: Get Shared History & Friends Leaderboard ---
  if (pathname === '/api/history' && req.method === 'GET') {
    const filterUserId = (parsedUrl.searchParams.get('userId') || '').trim().toLowerCase();
    const filtered = filterUserId
      ? matchHistory.filter(r => (r.players || []).some(p => (p.userId || '').toLowerCase() === filterUserId))
      : matchHistory;

    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({
      ok: true,
      history: filtered.slice(0, 100),
      leaderboard: buildLeaderboard(matchHistory),
    }));
    return;
  }

  // --- API: Create Room ---
  if (pathname === '/api/room/create' && req.method === 'POST') {
    let body = '';
    req.on('data', chunk => (body += chunk));
    req.on('end', () => {
      try {
        const parsed = JSON.parse(body || '{}');
        const requestedPlayers = parsed.playerCount || 4;
        const parsedTarget = parseInt(parsed.targetScore, 10);
        const targetScore = (!Number.isNaN(parsedTarget) && parsedTarget >= 1) ? parsedTarget : 31;
        const authUser = resolveAuthUser(parsed.authToken);
        const nickname = (parsed.nickname || '').trim() || (authUser ? authUser.displayName : 'لاعب 1');
        const token = parsed.playerToken || ('tok_' + Math.random().toString(36).substring(2));
        const code = generateRoomCode();
        const deal = generateAndDealTiles(requestedPlayers);
        const now = Date.now();

        const playersList = [];
        for (let i = 0; i < requestedPlayers; i++) {
          playersList.push({
            name: i === 0 ? nickname : `لاعب ${i + 1}`,
            userId: i === 0 && authUser ? authUser.userId : null,
            token: i === 0 ? token : null,
            joined: i === 0,
            lastSeen: i === 0 ? now : null,
          });
        }

        rooms[code] = {
          code,
          creatorToken: token,
          creatorUserId: authUser ? authUser.userId : null,
          created: now,
          updatedAt: now,
          playerCount: requestedPlayers,
          joinedCount: 1,
          targetScore,
          round: 1,
          matchSeq: 1,
          version: 1,
          started: false,
          turnStartedAt: null,
          initialDeal: deal,
          deal,
          players: playersList,
          watchers: [],
          actions: [],
          nextRoundVotes: {},
          kickedTokens: {},
        };
        saveRooms();

        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({
          ok: true,
          role: 'player',
          roomCode: code,
          playerIndex: 0,
          playerToken: token,
          targetScore: rooms[code].targetScore,
          matchSeq: rooms[code].matchSeq,
          started: rooms[code].started,
          turnRemainingMs: TURN_TIMEOUT_MS,
          turnTimeoutSeconds: 60,
          players: buildPublicPlayers(rooms[code], now),
          watchers: [],
          initialDeal: rooms[code].initialDeal,
          deal: rooms[code].deal,
          actions: [],
        }));
      } catch (e) {
        res.writeHead(400, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ ok: false, message: 'طلب غير صالح' }));
      }
    });
    return;
  }

  // --- API: Join Room (supports player reconnect, open seat claim, AND watcher mode) ---
  if (pathname === '/api/room/join' && req.method === 'POST') {
    let body = '';
    req.on('data', chunk => (body += chunk));
    req.on('end', () => {
      try {
        const data = JSON.parse(body || '{}');
        const code = (data.roomCode || '').trim();
        const authUser = resolveAuthUser(data.authToken);
        const nickname = (data.nickname || '').trim() || (authUser ? authUser.displayName : '');
        const preferWatcher = Boolean(data.preferWatcher);
        const token = data.playerToken || ('tok_' + Math.random().toString(36).substring(2));
        const room = rooms[code];
        const now = Date.now();

        if (!room) {
          res.writeHead(404, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ ok: false, message: 'الغرفة غير موجودة' }));
          return;
        }
        ensureRoomShape(room, now);
        pruneWatchers(room, now);

        // 1. Check if token already matches a seated player in this room (RECONNECT / REFRESH)
        let assignedIdx = -1;
        let assignedRole = 'player';
        if (data.playerToken && !preferWatcher) {
          for (let i = 0; i < room.players.length; i++) {
            if (room.players[i].token === data.playerToken && room.players[i].joined) {
              assignedIdx = i;
              if (nickname) room.players[i].name = nickname;
              if (authUser) room.players[i].userId = authUser.userId;
              room.players[i].lastSeen = now;
              break;
            }
          }
        }

        // 2. If not reconnecting as player and not preferring watcher, find an open/vacated seat OR take over a BOT seat!
        if (assignedIdx === -1 && !preferWatcher) {
          // Priority A: Unjoined / vacant seat
          for (let i = 0; i < room.players.length; i++) {
            if (!room.players[i].joined) {
              assignedIdx = i;
              break;
            }
          }
          // Priority B: Replace an existing BOT seat!
          if (assignedIdx === -1) {
            for (let i = 0; i < room.players.length; i++) {
              if (room.players[i].isBot) {
                assignedIdx = i;
                break;
              }
            }
          }

          if (assignedIdx !== -1) {
            room.players[assignedIdx].joined = true;
            room.players[assignedIdx].isBot = false;
            room.players[assignedIdx].token = token;
            room.players[assignedIdx].name = nickname || `لاعب ${assignedIdx + 1}`;
            room.players[assignedIdx].userId = authUser ? authUser.userId : null;
            room.players[assignedIdx].lastSeen = now;
            // Remove from watchers if they were previously watching
            room.watchers = room.watchers.filter(w => w.token !== token);
          }
        }

        // 3. If all 4 seats are occupied (or preferWatcher), join as Watcher!
        if (assignedIdx === -1) {
          assignedRole = 'watcher';
          let watcher = room.watchers.find(w => w.token === token);
          if (watcher) {
            if (nickname) watcher.name = nickname;
            if (authUser) watcher.userId = authUser.userId;
            watcher.lastSeen = now;
          } else {
            watcher = {
              id: 'w_' + Math.random().toString(36).substring(2, 10),
              token,
              userId: authUser ? authUser.userId : null,
              name: nickname || `مشاهد ${room.watchers.length + 1}`,
              joinedAt: now,
              lastSeen: now,
            };
            room.watchers.push(watcher);
          }
        }

        room.joinedCount = room.players.filter(p => p.joined).length;
        if (!room.started && room.joinedCount >= room.playerCount) {
          room.started = true;
          room.turnStartedAt = now;
        }
        room.updatedAt = now;
        room.version++;
        saveRooms();

        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({
          ok: true,
          role: assignedRole,
          roomCode: code,
          playerIndex: assignedIdx,
          playerToken: token,
          targetScore: room.targetScore || 31,
          matchSeq: room.matchSeq || 1,
          started: room.started,
          turnRemainingMs: computeTurnRemainingMs(room, now),
          turnTimeoutSeconds: 60,
          joinedCount: room.joinedCount,
          players: buildPublicPlayers(room, now),
          watchers: buildPublicWatchers(room, now),
          initialDeal: room.initialDeal || room.deal,
          deal: room.deal,
          actions: room.actions,
        }));
      } catch (e) {
        res.writeHead(400, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ ok: false, message: 'طلب غير صالح' }));
      }
    });
    return;
  }

  // --- API: Start Game Early (fills remaining seats with Bots) ---
  if (pathname === '/api/room/start-game' && req.method === 'POST') {
    let body = '';
    req.on('data', chunk => (body += chunk));
    req.on('end', () => {
      try {
        const data = JSON.parse(body || '{}');
        const code = (data.roomCode || '').trim();
        const room = rooms[code];
        if (!room) {
          res.writeHead(404, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ ok: false, message: 'الغرفة غير موجودة' }));
          return;
        }
        const now = Date.now();
        ensureRoomShape(room, now);

        // Fill all unjoined seats with Bots so the game can start immediately
        for (let i = 0; i < room.players.length; i++) {
          if (!room.players[i].joined) {
            room.players[i].joined = true;
            room.players[i].isBot = true;
            room.players[i].name = `بوت 🤖 (${i + 1})`;
            room.players[i].token = 'bot_' + i + '_' + code;
            room.players[i].lastSeen = now;
          }
        }

        room.joinedCount = room.players.length;
        room.started = true;
        if (!room.turnStartedAt) room.turnStartedAt = now;
        room.updatedAt = now;
        room.version++;

        // If starter is a bot, play opening tile immediately (must be a double, else pass)!
        if (room.actions.length === 0 && room.deal && room.players[room.deal.starter] && room.players[room.deal.starter].isBot) {
          const starterIdx = room.deal.starter;
          const botHand = room.deal.hands[starterIdx] || [];
          let bestTile = null;
          let bestDoublePip = -1;
          for (const t of botHand) {
            if (t.head === t.tail && (t.head + t.tail) > bestDoublePip) {
              bestDoublePip = t.head + t.tail;
              bestTile = t;
            }
          }
          if (bestTile) {
            room.actions.push({
              id: 0,
              actionType: 'play',
              playerIndex: starterIdx,
              tileId: bestTile.id,
              head: bestTile.head,
              tail: bestTile.tail,
              targetDirection: null,
              autoPlayed: true,
              timestamp: now,
            });
          } else {
            room.actions.push({
              id: 0,
              actionType: 'pass',
              playerIndex: starterIdx,
              autoPlayed: true,
              timestamp: now,
            });
          }
        }
        saveRooms();
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({
          ok: true,
          started: true,
          players: buildPublicPlayers(room, now),
        }));
      } catch (e) {
        res.writeHead(400, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ ok: false, message: 'طلب غير صالح' }));
      }
    });
    return;
  }

  // --- API: Promote a Watcher into a Seat (replace bot, left player, or claim open seat) ---
  if (pathname === '/api/room/promote-watcher' && req.method === 'POST') {
    let body = '';
    req.on('data', chunk => (body += chunk));
    req.on('end', () => {
      try {
        const data = JSON.parse(body || '{}');
        const code = (data.roomCode || '').trim();
        const room = rooms[code];
        const now = Date.now();
        if (!room) {
          res.writeHead(404, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ ok: false, message: 'الغرفة غير موجودة' }));
          return;
        }
        ensureRoomShape(room, now);
        pruneWatchers(room, now);

        let watcherIdx = -1;
        if (data.watcherId) {
          watcherIdx = room.watchers.findIndex(w => w.id === data.watcherId);
        } else if (data.watcherToken) {
          watcherIdx = room.watchers.findIndex(w => w.token === data.watcherToken);
        }
        if (watcherIdx === -1) {
          res.writeHead(404, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ ok: false, message: 'المشاهد غير موجود أو غادر' }));
          return;
        }

        let slotIdx = (typeof data.slotIndex === 'number' && data.slotIndex >= 0 && data.slotIndex < room.players.length)
          ? data.slotIndex
          : room.players.findIndex(p => !p.joined || p.isBot);
        if (slotIdx === -1) {
          res.writeHead(400, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ ok: false, message: 'لا يوجد مقعد متاح للاستبدال' }));
          return;
        }

        const watcher = room.watchers.splice(watcherIdx, 1)[0];
        room.players[slotIdx] = {
          name: watcher.name || `لاعب ${slotIdx + 1}`,
          userId: watcher.userId || null,
          token: watcher.token,
          isBot: false,
          joined: true,
          lastSeen: now,
        };
        room.joinedCount = room.players.filter(p => p.joined).length;
        room.updatedAt = now;
        room.version++;
        saveRooms();

        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({
          ok: true,
          slotIndex: slotIdx,
          joinedCount: room.joinedCount,
          players: buildPublicPlayers(room, now),
          watchers: buildPublicWatchers(room, now),
        }));
      } catch (e) {
        res.writeHead(400, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ ok: false, message: 'طلب غير صالح' }));
      }
    });
    return;
  }

  // --- API: Leave / Vacate Seat or Leave Watchers ---
  if (pathname === '/api/room/leave' && req.method === 'POST') {
    let body = '';
    req.on('data', chunk => (body += chunk));
    req.on('end', () => {
      try {
        const data = JSON.parse(body || '{}');
        const code = (data.roomCode || '').trim();
        const room = rooms[code];
        const now = Date.now();
        if (!room) {
          res.writeHead(404, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ ok: false, message: 'الغرفة غير موجودة' }));
          return;
        }
        ensureRoomShape(room, now);

        if (data.playerToken) {
          room.watchers = room.watchers.filter(w => w.token !== data.playerToken);
        }

        let targetIdx = -1;
        if (typeof data.slotIndex === 'number' && data.slotIndex >= 0 && data.slotIndex < room.players.length) {
          targetIdx = data.slotIndex;
        } else if (data.playerToken) {
          targetIdx = room.players.findIndex(p => p.token === data.playerToken);
        } else if (typeof data.playerIndex === 'number' && data.playerIndex >= 0 && data.playerIndex < room.players.length) {
          targetIdx = data.playerIndex;
        }

        if (targetIdx !== -1) {
          room.players[targetIdx].joined = false;
          room.players[targetIdx].token = null;
          room.players[targetIdx].lastSeen = null;
          room.players[targetIdx].name = `مقعد متاح ${targetIdx + 1}`;
          room.joinedCount = room.players.filter(p => p.joined).length;
        }
        room.updatedAt = now;
        room.version++;
        saveRooms();

        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({
          ok: true,
          joinedCount: room.joinedCount,
          players: buildPublicPlayers(room, now),
          watchers: buildPublicWatchers(room, now),
        }));
      } catch (e) {
        res.writeHead(400, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ ok: false, message: 'طلب غير صالح' }));
      }
    });
    return;
  }

  // --- API: Dispatch Move / Action ---
  if (pathname === '/api/room/action' && req.method === 'POST') {
    let body = '';
    req.on('data', chunk => (body += chunk));
    req.on('end', () => {
      try {
        const data = JSON.parse(body || '{}');
        const code = (data.roomCode || '').trim();
        const room = rooms[code];
        const now = Date.now();

        if (!room) {
          res.writeHead(404, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ ok: false, message: 'الغرفة غير موجودة' }));
          return;
        }
        ensureRoomShape(room, now);

        if (typeof data.expectedActionId === 'number' && data.expectedActionId !== room.actions.length) {
          res.writeHead(200, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ ok: false, duplicate: true, actionId: room.actions.length }));
          return;
        }

        room.started = true;
        room.turnStartedAt = now;
        room.updatedAt = now;
        room.version++;
        const action = {
          id: room.actions.length,
          actionType: data.actionType,
          playerIndex: data.playerIndex,
          tileId: data.tileId,
          targetDirection: data.targetDirection,
          autoPlayed: Boolean(data.autoPlayed),
          payload: data.payload,
          timestamp: now,
        };
        room.actions.push(action);

        // If next round starter is a bot, play opening tile immediately (must be double, else pass)!
        if (room.players[winnerIndex] && room.players[winnerIndex].isBot) {
          const botHand = newDeal.hands[winnerIndex] || [];
          let bestTile = null;
          let bestDoublePip = -1;
          for (const t of botHand) {
            if (t.head === t.tail && (t.head + t.tail) > bestDoublePip) {
              bestDoublePip = t.head + t.tail;
              bestTile = t;
            }
          }
          if (bestTile) {
            room.actions.push({
              id: room.actions.length,
              actionType: 'play',
              playerIndex: winnerIndex,
              tileId: bestTile.id,
              head: bestTile.head,
              tail: bestTile.tail,
              targetDirection: null,
              autoPlayed: true,
              timestamp: now,
            });
          } else {
            room.actions.push({
              id: room.actions.length,
              actionType: 'pass',
              playerIndex: winnerIndex,
              autoPlayed: true,
              timestamp: now,
            });
          }
        }

        saveRooms();

        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ ok: true, version: room.version, actionId: action.id }));
      } catch (e) {
        res.writeHead(400, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ ok: false, message: 'خطأ في معالجة الحركة' }));
      }
    });
    return;
  }

  // --- API: Next Round (Idempotent Authoritative Deal for Next Round) ---
  if (pathname === '/api/room/next-round' && req.method === 'POST') {
    let body = '';
    req.on('data', chunk => (body += chunk));
    req.on('end', () => {
      try {
        const data = JSON.parse(body || '{}');
        const code = (data.roomCode || '').trim();
        const room = rooms[code];
        if (!room) {
          res.writeHead(404, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ ok: false, message: 'الغرفة غير موجودة' }));
          return;
        }

        const currentRound = room.round || 1;
        if (typeof data.expectedRound === 'number' && data.expectedRound !== currentRound) {
          res.writeHead(200, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({
            ok: true,
            alreadyAdvanced: true,
            roundNumber: currentRound,
            deal: room.deal,
            starter: room.deal.starter,
          }));
          return;
        }

        const winnerIndex = (typeof data.winnerIndex === 'number') ? data.winnerIndex : 0;
        const newDeal = generateAndDealTiles(room.playerCount);
        // The winner of the previous round leads the next round!
        newDeal.starter = winnerIndex;

        room.round = currentRound + 1;
        room.deal = newDeal;
        room.started = true;
        room.turnStartedAt = Date.now();
        room.updatedAt = room.turnStartedAt;
        room.version++;

        const action = {
          id: room.actions.length,
          actionType: 'next_round',
          playerIndex: winnerIndex,
          roundNumber: room.round,
          deal: newDeal,
          timestamp: Date.now(),
        };
        room.actions.push(action);

        // If next round starter is a bot, play opening tile immediately (must be double, else pass)!
        if (room.players[winnerIndex] && room.players[winnerIndex].isBot) {
          const botHand = newDeal.hands[winnerIndex] || [];
          let bestTile = null;
          let bestDoublePip = -1;
          for (const t of botHand) {
            if (t.head === t.tail && (t.head + t.tail) > bestDoublePip) {
              bestDoublePip = t.head + t.tail;
              bestTile = t;
            }
          }
          if (bestTile) {
            room.actions.push({
              id: room.actions.length,
              actionType: 'play',
              playerIndex: winnerIndex,
              tileId: bestTile.id,
              head: bestTile.head,
              tail: bestTile.tail,
              targetDirection: null,
              autoPlayed: true,
              timestamp: now,
            });
          } else {
            room.actions.push({
              id: room.actions.length,
              actionType: 'pass',
              playerIndex: winnerIndex,
              autoPlayed: true,
              timestamp: now,
            });
          }
        }

        saveRooms();

        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({
          ok: true,
          roundNumber: room.round,
          deal: newDeal,
          starter: winnerIndex,
        }));
      } catch (e) {
        res.writeHead(400, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ ok: false, message: 'خطأ في بدء الدور التالي' }));
      }
    });
    return;
  }

  // --- API: Start New Bola (Match) in Existing Room ---
  if (pathname === '/api/room/new-match' && req.method === 'POST') {
    let body = '';
    req.on('data', chunk => (body += chunk));
    req.on('end', () => {
      try {
        const data = JSON.parse(body || '{}');
        const code = (data.roomCode || '').trim();
        const room = rooms[code];
        if (!room) {
          res.writeHead(404, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ ok: false, message: 'الغرفة غير موجودة' }));
          return;
        }

        const parsedTarget = parseInt(data.targetScore, 10);
        if (!Number.isNaN(parsedTarget) && parsedTarget >= 1) {
          room.targetScore = parsedTarget;
        }

        const newDeal = generateAndDealTiles(room.playerCount);
        const now = Date.now();
        room.round = 1;
        room.matchSeq = (room.matchSeq || 1) + 1;
        room.initialDeal = newDeal;
        room.deal = newDeal;
        room.actions = [];
        room.turnStartedAt = room.started ? now : null;
        room.updatedAt = now;
        room.version++;
        saveRooms();

        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({
          ok: true,
          targetScore: room.targetScore,
          matchSeq: room.matchSeq,
          initialDeal: room.initialDeal,
          deal: room.deal,
        }));
      } catch (e) {
        res.writeHead(400, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ ok: false, message: 'خطأ في بدء بولة جديدة' }));
      }
    });
    return;
  }

  // --- API: Update Target Score (البولة) ---
  if (pathname === '/api/room/target-score' && req.method === 'POST') {
    let body = '';
    req.on('data', chunk => (body += chunk));
    req.on('end', () => {
      try {
        const data = JSON.parse(body || '{}');
        const code = (data.roomCode || '').trim();
        const room = rooms[code];
        if (!room) {
          res.writeHead(404, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ ok: false, message: 'الغرفة غير موجودة' }));
          return;
        }
        const parsedTarget = parseInt(data.targetScore, 10);
        if (!Number.isNaN(parsedTarget) && parsedTarget >= 1) {
          room.targetScore = parsedTarget;
          room.updatedAt = Date.now();
          room.version++;
          saveRooms();
        }
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ ok: true, targetScore: room.targetScore }));
      } catch (e) {
        res.writeHead(400, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ ok: false, message: 'طلب غير صالح' }));
      }
    });
    return;
  }

  // --- API: Vote Ready for Next Round (requires all human players; bots auto-approved) ---
  if (pathname === '/api/room/ready-next-round' && req.method === 'POST') {
    readJsonBody((data) => {
      const code = (data.roomCode || '').trim();
      const token = (data.playerToken || '').trim();
      const room = rooms[code];
      const now = Date.now();
      if (!room) {
        res.writeHead(404, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ ok: false, message: 'الغرفة غير موجودة' }));
        return;
      }
      ensureRoomShape(room, now);

      let voterIdx = (typeof data.playerIndex === 'number') ? data.playerIndex : -1;
      if (voterIdx === -1 && token) {
        voterIdx = room.players.findIndex(p => p.token === token);
      }
      if (voterIdx >= 0 && voterIdx < room.players.length) {
        room.nextRoundVotes[voterIdx] = true;
      }

      // Bots are always auto-approved by default!
      for (let i = 0; i < room.players.length; i++) {
        if (room.players[i].isBot) {
          room.nextRoundVotes[i] = true;
        }
      }

      // Check if all joined seated players have approved
      const joinedPlayers = room.players.filter(p => p.joined);
      const allApproved = joinedPlayers.length > 0 && joinedPlayers.every((p) => {
        const idx = room.players.indexOf(p);
        return Boolean(room.nextRoundVotes[idx]);
      });

      if (allApproved) {
        // Authoritative automatic next round deal!
        const currentRound = room.round || 1;
        const winnerIndex = (typeof data.winnerIndex === 'number') ? data.winnerIndex : 0;
        const newDeal = generateAndDealTiles(room.playerCount);
        newDeal.starter = winnerIndex;

        room.round = currentRound + 1;
        room.deal = newDeal;
        room.started = true;
        room.turnStartedAt = now;
        room.updatedAt = now;
        room.version++;
        room.nextRoundVotes = {}; // reset votes for future rounds

        const action = {
          id: room.actions.length,
          actionType: 'next_round',
          playerIndex: winnerIndex,
          roundNumber: room.round,
          deal: newDeal,
          timestamp: now,
        };
        room.actions.push(action);

        // If next round starter is a bot, play opening tile immediately (must be double, else pass)!
        if (room.players[winnerIndex] && room.players[winnerIndex].isBot) {
          const botHand = newDeal.hands[winnerIndex] || [];
          let bestTile = null;
          let bestDoublePip = -1;
          for (const t of botHand) {
            if (t.head === t.tail && (t.head + t.tail) > bestDoublePip) {
              bestDoublePip = t.head + t.tail;
              bestTile = t;
            }
          }
          if (bestTile) {
            room.actions.push({
              id: room.actions.length,
              actionType: 'play',
              playerIndex: winnerIndex,
              tileId: bestTile.id,
              head: bestTile.head,
              tail: bestTile.tail,
              targetDirection: null,
              autoPlayed: true,
              timestamp: now,
            });
          } else {
            room.actions.push({
              id: room.actions.length,
              actionType: 'pass',
              playerIndex: winnerIndex,
              autoPlayed: true,
              timestamp: now,
            });
          }
        }

        saveRooms();

        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({
          ok: true,
          allApproved: true,
          advanced: true,
          roundNumber: room.round,
          deal: newDeal,
          starter: winnerIndex,
          nextRoundVotes: {},
        }));
        return;
      }

      room.updatedAt = now;
      room.version++;
      saveRooms();
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({
        ok: true,
        allApproved: false,
        nextRoundVotes: room.nextRoundVotes,
      }));
    });
    return;
  }

  // --- API: Admin (Room Creator) Kick Any Player Without Reasons ---
  if (pathname === '/api/room/kick' && req.method === 'POST') {
    readJsonBody((data) => {
      const code = (data.roomCode || '').trim();
      const adminToken = (data.adminToken || '').trim();
      const room = rooms[code];
      const now = Date.now();
      if (!room) {
        res.writeHead(404, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ ok: false, message: 'الغرفة غير موجودة' }));
        return;
      }
      ensureRoomShape(room, now);

      // Check admin authorization: must be creator or seat 0 token
      const isAuthorized = (adminToken && room.creatorToken && room.creatorToken === adminToken) ||
                           (adminToken && room.players[0] && room.players[0].token === adminToken);
      if (!isAuthorized) {
        res.writeHead(403, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ ok: false, message: 'غير مصرح: المنشئ فقط يمكنه طرد اللاعبين' }));
        return;
      }

      const targetSlot = (typeof data.targetIndex === 'number') ? data.targetIndex : -1;
      const targetToken = (data.targetToken || '').trim();

      // Cannot kick self (Admin / seat 0)
      if (targetSlot === 0 || (targetToken && room.creatorToken === targetToken)) {
        res.writeHead(400, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ ok: false, message: 'لا يمكن طرد منشئ الغرفة' }));
        return;
      }

      let kickedName = '';
      // 1. Kick seated player
      if (targetSlot > 0 && targetSlot < room.players.length) {
        const p = room.players[targetSlot];
        kickedName = p.name;
        if (p.token) room.kickedTokens[p.token] = true;

        if (room.started) {
          // Replace with Bot so game continues smoothly!
          room.players[targetSlot] = {
            name: `بوت 🤖 (${targetSlot + 1})`,
            userId: null,
            token: 'bot_' + targetSlot + '_' + code,
            isBot: true,
            joined: true,
            lastSeen: now,
          };
        } else {
          // Vacate seat before game starts
          room.players[targetSlot] = {
            name: `لاعب ${targetSlot + 1}`,
            userId: null,
            token: null,
            isBot: false,
            joined: false,
            lastSeen: null,
          };
          room.joinedCount = room.players.filter(x => x.joined).length;
        }
      } else if (targetToken) {
        // Kick watcher
        const wIdx = room.watchers.findIndex(w => w.token === targetToken);
        if (wIdx !== -1) {
          kickedName = room.watchers[wIdx].name;
          room.kickedTokens[targetToken] = true;
          room.watchers.splice(wIdx, 1);
        }
      }

      room.updatedAt = now;
      room.version++;
      saveRooms();

      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({
        ok: true,
        kickedName,
        players: buildPublicPlayers(room, now),
        watchers: buildPublicWatchers(room, now),
      }));
    });
    return;
  }

  // --- API: Sync / Poll Room State ---
  if (pathname === '/api/room/sync' && req.method === 'GET') {
    const code = parsedUrl.searchParams.get('room') || '';
    const token = parsedUrl.searchParams.get('token') || '';
    const room = rooms[code];
    const now = Date.now();
    if (!room) {
      res.writeHead(404, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ ok: false, message: 'الغرفة غير موجودة' }));
      return;
    }
    ensureRoomShape(room, now);

    let myRole = 'none';
    let myPlayerIndex = -1;
    if (token) {
      const pIdx = room.players.findIndex(p => p.token === token && p.joined);
      if (pIdx !== -1) {
        room.players[pIdx].lastSeen = now;
        myRole = 'player';
        myPlayerIndex = pIdx;
      } else {
        const w = room.watchers.find(w => w.token === token);
        if (w) {
          w.lastSeen = now;
          myRole = 'watcher';
        }
      }
    }

    const isKicked = Boolean(token && room.kickedTokens && room.kickedTokens[token]);
    const isCreator = Boolean(
      (token && room.creatorToken && room.creatorToken === token) ||
      (myPlayerIndex === 0)
    );

    const publicWatchers = buildPublicWatchers(room, now);

    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({
      ok: true,
      roomCode: room.code,
      version: room.version,
      myRole,
      myPlayerIndex,
      isKicked,
      isCreator,
      creatorIndex: 0,
      nextRoundVotes: room.nextRoundVotes || {},
      targetScore: room.targetScore || 31,
      matchSeq: room.matchSeq || 1,
      started: room.started,
      turnRemainingMs: computeTurnRemainingMs(room, now),
      turnTimeoutSeconds: 60,
      playerCount: room.playerCount,
      joinedCount: room.joinedCount,
      watcherCount: publicWatchers.length,
      players: buildPublicPlayers(room, now),
      watchers: publicWatchers,
      initialDeal: room.initialDeal || room.deal,
      deal: room.deal,
      actions: room.actions,
    }));
    return;
  }

  // --- Static Flutter Web Server ---
  let reqPath = pathname;
  if (reqPath === '/' || reqPath === '') reqPath = '/index.html';
  const safePath = path.normalize(reqPath).replace(/^(\.\.[/\\])+/, '');
  const filePath = path.join(BASE, safePath);

  const sendStatic = (targetPath, data) => {
    const ext = path.extname(targetPath);
    const baseName = path.basename(targetPath);
    const contentType = MIME[ext] || 'application/octet-stream';
    const isImmutableish = targetPath.includes(`${path.sep}canvaskit${path.sep}`)
      || targetPath.includes(`${path.sep}assets${path.sep}`)
      || targetPath.includes(`${path.sep}icons${path.sep}`);
    const isEntryFile = baseName === 'index.html'
      || baseName === 'flutter_bootstrap.js'
      || baseName === 'flutter_service_worker.js';
    const cacheControl = isEntryFile
      ? 'no-store, no-cache, must-revalidate'
      : (isImmutableish ? 'public, max-age=86400' : 'no-cache');
    const acceptEncoding = req.headers['accept-encoding'] || '';

    const writePayload = (payload, isGzip) => {
      const headers = {
        'Content-Type': contentType,
        'Content-Length': payload.length,
        'Cache-Control': cacheControl,
      };
      if (isGzip) {
        headers['Content-Encoding'] = 'gzip';
        headers['Vary'] = 'Accept-Encoding';
      }
      res.writeHead(200, headers);
      res.end(req.method === 'HEAD' ? undefined : payload);
    };

    if (COMPRESSIBLE.has(ext) && acceptEncoding.includes('gzip')) {
      zlib.gzip(data, (zipErr, zipped) => {
        if (zipErr) {
          writePayload(data, false);
          return;
        }
        writePayload(zipped, true);
      });
      return;
    }

    writePayload(data, false);
  };

  fs.readFile(filePath, (err, data) => {
    if (err) {
      if (path.extname(filePath)) {
        res.writeHead(404, { 'Content-Type': 'text/plain; charset=utf-8' });
        res.end('Not found');
        return;
      }
      const indexPath = path.join(BASE, 'index.html');
      fs.readFile(indexPath, (err2, data2) => {
        if (err2) {
          res.writeHead(404, { 'Content-Type': 'text/plain; charset=utf-8' });
          res.end('Not found');
        } else {
          sendStatic(indexPath, data2);
        }
      });
      return;
    }
    sendStatic(filePath, data);
  });
});

server.listen(PORT, '0.0.0.0', () => {
  console.log(`Server running on all network interfaces at port ${PORT}`);
});
