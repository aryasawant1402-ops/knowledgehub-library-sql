// ================================================================
//  Database connection settings.
//  Local defaults work with MySQL on this machine.
//  Render / Aiven: set the DB_* variables (see .env.example).
//  Do not put the Aiven password in this file.
// ================================================================
const fs = require('fs');
const path = require('path');

// Optional local secrets. Existing environment variables win.
const envFile = path.join(__dirname, '.env');
if (fs.existsSync(envFile)) {
  for (const line of fs.readFileSync(envFile, 'utf8').split(/\r?\n/)) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith('#')) continue;
    const eq = trimmed.indexOf('=');
    if (eq === -1) continue;
    const key = trimmed.slice(0, eq).trim();
    let value = trimmed.slice(eq + 1).trim();
    if (
      (value.startsWith('"') && value.endsWith('"')) ||
      (value.startsWith("'") && value.endsWith("'"))
    ) {
      value = value.slice(1, -1);
    }
    if (process.env[key] === undefined) process.env[key] = value;
  }
}

const db = {
  host:     process.env.DB_HOST     || 'localhost',
  port:     Number(process.env.DB_PORT || 3306),
  user:     process.env.DB_USER     || 'root',
  password: process.env.DB_PASSWORD || 'root123',        // local MySQL only
  database: process.env.DB_NAME     || 'knowledgehub_library',
};

// Aiven requires TLS. Set DB_SSL=true and DB_SSL_CA to the CA file path
// or to the PEM text (newlines may be written as \n).
if (process.env.DB_SSL === 'true' || process.env.DB_SSL === '1') {
  const ssl = { rejectUnauthorized: process.env.DB_SSL_REJECT_UNAUTHORIZED !== 'false' };
  const caRaw = process.env.DB_SSL_CA || '';
  if (caRaw) {
    ssl.ca = caRaw.includes('BEGIN CERTIFICATE')
      ? caRaw.replace(/\\n/g, '\n')
      : fs.readFileSync(caRaw, 'utf8');
  }
  db.ssl = ssl;
}

module.exports = {
  db,
  port: Number(process.env.PORT || 3000),
  poolSize: Number(process.env.DB_POOL_SIZE || 5),
};
