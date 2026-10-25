# KnowledgeHub Public Library — SQL Edition

The same library management system as the Java Swing version, rebuilt so that
**MySQL is the backend**: every book, transaction and login is stored in the
database, and every rule (stock checks, due dates, rent calculation,
validation) is written in SQL as stored procedures, triggers, views and a
function. The browser frontend is plain HTML/CSS/JavaScript, and a tiny
Node.js server passes requests from the browser to MySQL.

```
Browser (HTML/CSS/JS)  ──►  server.js (Node, ~150 lines, no logic)  ──►  MySQL
                                                                          ├─ tables
                                                                          ├─ stored procedures
                                                                          ├─ triggers
                                                                          ├─ views
                                                                          └─ function
```

## Features (same as the Java version, plus a few extras)

| Java tab        | SQL edition                                                      | SQL object used                    |
|-----------------|------------------------------------------------------------------|------------------------------------|
| Login           | Admin login, password stored as SHA-256 hash, change password    | `sp_admin_login`, `sp_change_password` |
| Dashboard       | Total / available / issued / returned + overdue, rent collected, category chart, most-issued, activity log | `v_dashboard`, `v_category_summary`, `v_popular_books`, `activity_log` |
| Books           | Searchable, filter by category, Edit / Issue shortcuts           | `v_books`                          |
| Add Book        | Validation, duplicate ID check, new categories auto-created      | `sp_add_book`                      |
| Update Book     | Change copies, rent, author, category; delete unused books       | `sp_update_book`, `sp_delete_book` |
| Issue Book      | Stock check, 7-day due date, one copy per student per title      | `sp_issue_book` + triggers         |
| Return Book     | Pick from issued list, rent calculated per week kept             | `sp_return_book` + `fn_calculate_rent` + triggers |
| Transactions    | Filter All / Issued / Overdue / Returned, search                 | `v_transactions`                   |

Login is the same as before: **libraryadmin / admin123**

## What you need

1. **MySQL 8.0+** (MySQL Community Server + MySQL Workbench) — XAMPP's MariaDB also works
2. **Node.js 18+** — https://nodejs.org

## Setup (about 5 minutes)

**1. Create the database**

- MySQL Workbench: *File → Open SQL Script →* `database/library.sql`, then click the ⚡ (Execute) button.
- Or from a terminal: `mysql -u root -p < database/library.sql`

This creates the `knowledgehub_library` database with all 25 books from the Java
version and a few sample transactions. Running it again resets everything.

**2. Put your MySQL password in `config.js`**

```js
user:     'root',
password: 'your-mysql-password',
```

**3. Install and run**

```
npm install
npm start
```

Then open **http://localhost:3000**. On Windows you can just double-click `start.bat`.

## Project structure

```
knowledgehub-library-sql/
├── database/
│   ├── library.sql            ← the whole backend: tables, procedures, triggers, views, seed data
│   └── practice_queries.sql   ← example queries for practice / viva
├── public/
│   ├── index.html             ← all screens
│   ├── style.css
│   └── app.js                 ← browser logic, calls the API
├── server.js                  ← Express: login check + CALL procedure / SELECT view
├── config.js                  ← MySQL connection settings
├── package.json
└── start.bat                  ← Windows one-click start
```

## Database design

**Tables**

| Table          | Key columns                                                                  |
|----------------|------------------------------------------------------------------------------|
| `admins`       | `admin_id` PK, `full_name`, `password_hash` (SHA-256), `last_login`          |
| `categories`   | `category_id` PK, `category_name` UNIQUE                                     |
| `books`        | `book_id` PK, `book_name`, `author`, `category_id` FK, `total_copies`, `available_copies`, `weekly_rent` |
| `transactions` | `txn_id` PK, `student_name`, `book_id` FK, `issue_date`, `due_date`, `return_date`, `status` ENUM, `rent_charged`, `issued_by` FK |
| `activity_log` | `log_id` PK, `action`, `details`, `logged_at` — written only by triggers     |

Relationships: `categories 1─∞ books 1─∞ transactions ∞─1 admins`

**Constraints:** `CHECK (available_copies <= total_copies)`, no negative stock or
rent, `return_date >= issue_date`, foreign keys on every reference.

**Triggers**

| Trigger                    | When                    | Does                                         |
|----------------------------|-------------------------|----------------------------------------------|
| `trg_txn_before_insert`    | before a book is issued | rejects if out of stock, sets due date = issue + 7 days |
| `trg_txn_after_insert`     | after a book is issued  | `available_copies - 1`, writes to log        |
| `trg_txn_before_update`    | before a return         | calculates `rent_charged`, blocks re-opening a returned record |
| `trg_txn_after_update`     | after a return          | `available_copies + 1`, writes to log        |
| `trg_books_*`              | book added/edited/deleted | uppercase IDs, writes to log               |

**Rent rule** (`fn_calculate_rent`): weekly rent × weeks kept, any part of a
week counts as a full week, minimum one week. 0–7 days = 1 week, 8–14 = 2 weeks…

**Errors** are raised in SQL with `SIGNAL SQLSTATE '45000'` and shown to the user
exactly as written there (e.g. *"Book Out Of Stock!"*, *"No issued book found for
this student!"*).

## Trying it straight from SQL

Everything the app does can be done from Workbench without the frontend:

```sql
USE knowledgehub_library;
CALL sp_issue_book('Parth', 'BK111', CURDATE(), 'libraryadmin');
CALL sp_return_book('BK111', 'Parth', CURDATE() + INTERVAL 10 DAY);
SELECT * FROM v_dashboard;
SELECT * FROM activity_log ORDER BY log_id DESC;
```

See `database/practice_queries.sql` for more (joins, GROUP BY, subqueries, etc.).

## Host online (Render Singapore + Aiven MySQL)

The browser calls `/api/...` on the same host that serves the pages, so one Render web service is enough. Business rules stay in MySQL. Aiven’s free MySQL is a normal MySQL 8 service, which this schema needs (procedures, triggers, the rent function).

Render’s free service sleeps after about 15 minutes without a visit and takes about a minute to wake. Aiven powers off a free database that stays idle; turn it back on from the Aiven console. Logging in again is required after a restart, because sessions are kept in memory.

**1. Aiven (you do this)**

1. Create a free account at [https://aiven.io](https://aiven.io). No card.
2. Create a **MySQL** service on the **Free** plan. Leave the region as assigned (the free plan does not let you pick one). Wait until the status is **Running**.
3. Create a logical database named `knowledgehub_library` if the console offers that. Otherwise use the default database name shown on the overview (`defaultdb`).
4. Download the **CA certificate** and save it in this project as `ca.pem`. That file is gitignored.
5. Copy `.env.example` to `.env` and fill `DB_HOST`, `DB_PORT`, `DB_USER`, `DB_PASSWORD`, and `DB_NAME` from the Aiven overview. Keep `DB_SSL=true` and `DB_SSL_CA=./ca.pem`.

**2. Load the schema (from this machine, after `.env` exists)**

```
npm run db:init
```

That connects with TLS and runs `database/library.sql`. It does not drop the server’s other databases. Aiven already selects the database from `DB_NAME`.

**3. Render (you do this)**

The service is described in `render.yaml` (free plan, Singapore).

1. Push this project to GitHub or GitLab. Render deploys from a git repository.
2. In the Render dashboard: **New → Blueprint**, pick the repo, and apply `render.yaml`.
3. When Render asks for the secret values, copy them from `.env`. For `DB_SSL_CA`, paste the full PEM text from `ca.pem` (including the `BEGIN CERTIFICATE` and `END CERTIFICATE` lines). Do not commit `.env` or `ca.pem`.
4. Open the `onrender.com` URL Render prints. First load can take a minute while the free instance wakes. Sign in with `libraryadmin` / `admin123`.

## Troubleshooting

| Problem                                   | Fix                                                              |
|-------------------------------------------|------------------------------------------------------------------|
| `Could not connect to MySQL`              | MySQL service not running, or wrong password in `config.js`      |
| `Unknown database 'knowledgehub_library'` | Run `database/library.sql` first                                 |
| `Access denied for user 'root'`           | The password in `config.js` doesn't match your MySQL root password |
| Port 3000 already in use                  | Change `port` in `config.js`                                     |
| `npm` not recognised                      | Install Node.js and reopen the terminal                          |
| Aiven: certificate error                  | `DB_SSL=true` and `DB_SSL_CA` must be the CA downloaded for that service |
| Render spins for a minute, then the page loads | Free instances sleep after 15 minutes of no traffic            |
