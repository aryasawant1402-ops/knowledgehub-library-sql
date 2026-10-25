// Load database/library.sql into the MySQL named by DB_* / .env.
//
// The mysql CLI understands DELIMITER; the Node driver does not, so this
// script splits the file itself. It also skips DROP DATABASE / CREATE
// DATABASE / USE. On Aiven you do not own the server, and the connection
// is already pointed at one database (knowledgehub_library or defaultdb).
//
//   npm run db:init           apply the schema
//   npm run db:init -- --dry-run
const fs = require('fs');
const path = require('path');
const mysql = require('mysql2/promise');
const config = require('../config');

const dryRun = process.argv.includes('--dry-run');
const sqlPath = path.join(__dirname, '..', 'database', 'library.sql');

function splitStatements(script) {
  let delimiter = ';';
  let current = '';
  const statements = [];

  for (const line of script.split(/\r?\n/)) {
    const trimmed = line.trim();
    const delim = trimmed.match(/^DELIMITER\s+(\S+)\s*$/i);
    if (delim) {
      delimiter = delim[1];
      continue;
    }
    current += line + '\n';
    if (trimmed.endsWith(delimiter)) {
      let stmt = current.trim();
      if (stmt.endsWith(delimiter)) stmt = stmt.slice(0, -delimiter.length).trim();
      current = '';
      if (stmt && !isSkippable(stmt)) statements.push(stmt);
    }
  }

  const tail = current.trim();
  if (tail && !isSkippable(tail)) statements.push(tail);
  return statements;
}

function isSkippable(stmt) {
  const body = stmt.replace(/^\s*(--[^\n]*\n\s*)*/g, '').trim();
  if (!body) return true;
  return /^(DROP\s+DATABASE|CREATE\s+DATABASE|USE)\b/i.test(body);
}

async function openConnection() {
  const { database, ...base } = config.db;
  try {
    return await mysql.createConnection({ ...config.db, multipleStatements: false });
  } catch (err) {
    if (err.code !== 'ER_BAD_DB_ERROR' && err.errno !== 1049) throw err;
    const name = String(database).replace(/[^A-Za-z0-9_]/g, '');
    const conn = await mysql.createConnection(base);
    await conn.query(
      `CREATE DATABASE \`${name}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci`
    );
    await conn.query(`USE \`${name}\``);
    return conn;
  }
}

async function main() {
  const script = fs.readFileSync(sqlPath, 'utf8');
  const statements = splitStatements(script);
  console.log(`${statements.length} statements from ${path.basename(sqlPath)}`);
  if (dryRun) {
    statements.forEach((stmt, i) => {
      const preview = stmt.replace(/\s+/g, ' ').slice(0, 80);
      console.log(`${String(i + 1).padStart(3, ' ')}  ${preview}`);
    });
    return;
  }

  console.log(`Connecting to ${config.db.host}:${config.db.port}/${config.db.database} as ${config.db.user}`);
  const conn = await openConnection();
  try {
    for (let i = 0; i < statements.length; i++) {
      const stmt = statements[i];
      try {
        await conn.query(stmt);
      } catch (err) {
        const preview = stmt.replace(/\s+/g, ' ').slice(0, 160);
        console.error(`\nFailed on statement ${i + 1}: ${preview}`);
        console.error(err.sqlMessage || err.message);
        process.exitCode = 1;
        return;
      }
    }
    const [rows] = await conn.query('SELECT COUNT(*) AS books FROM books');
    console.log(`Schema loaded. Books in database: ${rows[0].books}`);
  } finally {
    await conn.end();
  }
}

main().catch((err) => {
  console.error(err.message);
  process.exit(1);
});
