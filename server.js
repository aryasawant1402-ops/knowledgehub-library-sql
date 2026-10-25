// =====================================================================
//  KnowledgeHub Public Library - API server
//
//  This file holds NO library logic. Every rule (stock checks, due
//  dates, rent, validation) lives in MySQL as stored procedures,
//  triggers and views. This server only:
//    1. checks the admin is logged in,
//    2. calls the right procedure / view,
//    3. sends the rows back to the browser as JSON.
// =====================================================================
const express = require('express');
const mysql = require('mysql2/promise');
const crypto = require('crypto');
const path = require('path');
const config = require('./config');

const app = express();
app.use(express.json());
app.use(express.static(path.join(__dirname, 'public')));

const pool = mysql.createPool({
  ...config.db,
  waitForConnections: true,
  connectionLimit: config.poolSize,
  dateStrings: true,          // return DATE columns as 'YYYY-MM-DD'
  decimalNumbers: true,       // return DECIMAL columns as numbers
});

// ---------- helpers ----------

// CALL a stored procedure and return its first result set
async function callProc(name, params = []) {
  const placeholders = params.map(() => '?').join(', ');
  const [results] = await pool.query(`CALL ${name}(${placeholders})`, params);
  return Array.isArray(results[0]) ? results[0] : [];
}

async function query(sql, params = []) {
  const [rows] = await pool.query(sql, params);
  return rows;
}

const emptyToNull = (v) => (v === undefined || v === null || String(v).trim() === '' ? null : v);

// Wrap a route so errors raised by SIGNAL in MySQL reach the UI as messages
const route = (fn) => async (req, res) => {
  try {
    res.json(await fn(req, res));
  } catch (err) {
    if (err.sqlState === '45000') {
      return res.status(400).json({ error: err.sqlMessage });       // our own rule
    }
    if (err.code === 'ER_CHECK_CONSTRAINT_VIOLATED' || err.errno === 3819 || err.errno === 4025) {
      return res.status(400).json({ error: 'Value rejected by a database CHECK constraint.' });
    }
    if (['ER_TRUNCATED_WRONG_VALUE', 'ER_TRUNCATED_WRONG_VALUE_FOR_FIELD',
         'ER_WRONG_VALUE_FOR_TYPE', 'ER_WARN_DATA_OUT_OF_RANGE', 'ER_DATA_TOO_LONG'].includes(err.code)) {
      return res.status(400).json({ error: 'Please enter valid details.' });
    }
    console.error(err);
    res.status(500).json({ error: 'Database error: ' + (err.sqlMessage || err.message) });
  }
};

// ---------- login sessions (kept in memory) ----------
const sessions = new Map();   // token -> { adminId, fullName }

function requireLogin(req, res, next) {
  const token = (req.headers.authorization || '').replace('Bearer ', '');
  const session = sessions.get(token);
  if (!session) return res.status(401).json({ error: 'Please log in again.' });
  req.admin = session;
  next();
}

// ---------- routes ----------

app.post('/api/login', route(async (req, res) => {
  const { adminId, password } = req.body;
  const rows = await callProc('sp_admin_login', [adminId || '', password || '']);
  if (rows.length === 0) {
    res.status(401);
    return { error: 'Invalid Admin ID or Password!' };
  }
  const token = crypto.randomBytes(24).toString('hex');
  sessions.set(token, { adminId: rows[0].admin_id, fullName: rows[0].full_name });
  return { token, adminId: rows[0].admin_id, fullName: rows[0].full_name };
}));

app.get('/api/health', async (_req, res) => {
  try {
    await pool.query('SELECT 1');
    res.json({ ok: true });
  } catch (err) {
    res.status(503).json({ ok: false, error: err.message });
  }
});

app.use('/api', requireLogin);

app.post('/api/logout', route(async (req) => {
  sessions.delete((req.headers.authorization || '').replace('Bearer ', ''));
  return { ok: true };
}));

app.post('/api/change-password', route(async (req) => {
  const { oldPassword, newPassword } = req.body;
  const rows = await callProc('sp_change_password', [req.admin.adminId, oldPassword || '', newPassword || '']);
  return rows[0];
}));

// Dashboard
app.get('/api/dashboard', route(async () => {
  const [summary] = await query('SELECT * FROM v_dashboard');
  const categories = await query('SELECT * FROM v_category_summary ORDER BY total_copies DESC');
  const popular = await query('SELECT * FROM v_popular_books ORDER BY times_issued DESC, rent_earned DESC LIMIT 5');
  const overdue = await query(
    "SELECT * FROM v_transactions WHERE display_status = 'Overdue' ORDER BY days_late DESC");
  const activity = await query('SELECT * FROM activity_log ORDER BY log_id DESC LIMIT 8');
  return { summary, categories, popular, overdue, activity };
}));

// Books
app.get('/api/books', route(async (req) => {
  const search = `%${req.query.search || ''}%`;
  const category = req.query.category || '';
  return query(
    `SELECT * FROM v_books
     WHERE (book_id LIKE ? OR book_name LIKE ? OR author LIKE ?)
       AND (? = '' OR category = ?)
     ORDER BY book_id`,
    [search, search, search, category, category]);
}));

app.get('/api/books/:id', route(async (req, res) => {
  const rows = await query('SELECT * FROM v_books WHERE book_id = ?', [req.params.id]);
  if (!rows.length) { res.status(404); return { error: 'Book ID not found!' }; }
  return rows[0];
}));

app.get('/api/categories', route(async () =>
  query('SELECT category_name FROM categories ORDER BY category_name')));

app.post('/api/books', route(async (req) => {
  const b = req.body;
  const rows = await callProc('sp_add_book', [
    b.bookId || '', b.bookName || '', b.author || '', b.category || '',
    emptyToNull(b.quantity), emptyToNull(b.weeklyRent)]);
  return rows[0];
}));

app.put('/api/books/:id', route(async (req) => {
  const b = req.body;
  const rows = await callProc('sp_update_book', [
    req.params.id, emptyToNull(b.totalCopies), emptyToNull(b.weeklyRent),
    emptyToNull(b.author), emptyToNull(b.category)]);
  return rows[0];
}));

app.delete('/api/books/:id', route(async (req) => {
  const rows = await callProc('sp_delete_book', [req.params.id]);
  return rows[0];
}));

// Issue / return
app.post('/api/issue', route(async (req) => {
  const b = req.body;
  const rows = await callProc('sp_issue_book', [
    b.studentName || '', b.bookId || '', emptyToNull(b.issueDate), req.admin.adminId]);
  return rows[0];
}));

app.post('/api/return', route(async (req) => {
  const b = req.body;
  const rows = await callProc('sp_return_book', [
    b.bookId || '', b.studentName || '', emptyToNull(b.returnDate)]);
  return rows[0];
}));

// Transactions
app.get('/api/transactions', route(async (req) => {
  const status = req.query.status || '';            // '', Issued, Returned, Overdue
  const search = `%${req.query.search || ''}%`;
  return query(
    `SELECT * FROM v_transactions
     WHERE (? = '' OR display_status = ? OR (? = 'Issued' AND status = 'Issued'))
       AND (student_name LIKE ? OR book_id LIKE ? OR book_name LIKE ?)
     ORDER BY txn_id DESC`,
    [status, status, status, search, search, search]);
}));

app.get('/api/active-issues', route(async () =>
  query("SELECT * FROM v_transactions WHERE status = 'Issued' ORDER BY student_name, book_id")));

// ---------- start ----------
async function waitForDatabase() {
  const attempts = 8;
  for (let attempt = 1; attempt <= attempts; attempt++) {
    try {
      await pool.query('SELECT 1');
      return;
    } catch (err) {
      console.error(`MySQL not ready (${attempt}/${attempts}): ${err.message}`);
      if (attempt === attempts) {
        console.error('-> Check DB_* settings and that the schema has been imported (npm run db:init).');
        process.exit(1);
      }
      await new Promise((resolve) => setTimeout(resolve, 3000));
    }
  }
}

waitForDatabase().then(() => {
  app.listen(config.port, '0.0.0.0', () => {
    console.log(`KnowledgeHub Public Library listening on port ${config.port}`);
    console.log('Login: libraryadmin / admin123');
  });
});
