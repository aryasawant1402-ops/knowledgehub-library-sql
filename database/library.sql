-- =====================================================================
--  KnowledgeHub Public Library  -  SQL Backend
--  Target: MySQL 8.0+  (also works on MariaDB 10.4+)
--
--  Run this whole file once. It (re)creates the database with:
--    1. Tables + constraints
--    2. A rent-calculation function
--    3. Triggers   (stock control, rent, audit log)
--    4. Stored procedures (every operation the app performs)
--    5. Views      (dashboard, book list, transactions, reports)
--    6. Seed data  (admin login + 25 books + a few sample transactions)
--
--  MySQL Workbench : File > Open SQL Script > run with the lightning icon
--  Command line    : mysql -u root -p < library.sql
-- =====================================================================

SET NAMES utf8mb4;
DROP DATABASE IF EXISTS knowledgehub_library;
CREATE DATABASE knowledgehub_library
    CHARACTER SET utf8mb4
    COLLATE utf8mb4_unicode_ci;
USE knowledgehub_library;


-- =====================================================================
-- 1. TABLES
-- =====================================================================

-- Library administrators (replaces the hard-coded login in LoginFrame.java)
CREATE TABLE admins (
    admin_id       VARCHAR(30)  PRIMARY KEY,
    full_name      VARCHAR(100) NOT NULL,
    password_hash  CHAR(64)     NOT NULL,          -- SHA-256 of the password
    last_login     DATETIME     NULL,
    created_at     TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- Book categories (normalised out of the books table)
CREATE TABLE categories (
    category_id    INT          AUTO_INCREMENT PRIMARY KEY,
    category_name  VARCHAR(50)  NOT NULL UNIQUE
);

-- Books (replaces Book.java + the ArrayList in Library.java)
CREATE TABLE books (
    book_id           VARCHAR(10)   PRIMARY KEY,
    book_name         VARCHAR(200)  NOT NULL,
    author            VARCHAR(100)  NOT NULL,
    category_id       INT           NOT NULL,
    total_copies      INT           NOT NULL,
    available_copies  INT           NOT NULL,
    weekly_rent       DECIMAL(8,2)  NOT NULL,
    added_on          TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT fk_books_category FOREIGN KEY (category_id)
        REFERENCES categories(category_id),
    CONSTRAINT chk_books_copies CHECK (total_copies >= 0
                                       AND available_copies >= 0
                                       AND available_copies <= total_copies),
    CONSTRAINT chk_books_rent   CHECK (weekly_rent >= 0)
);

-- Issue / return records (replaces Transaction.java)
CREATE TABLE transactions (
    txn_id        INT           AUTO_INCREMENT PRIMARY KEY,
    student_name  VARCHAR(100)  NOT NULL,
    book_id       VARCHAR(10)   NOT NULL,
    issue_date    DATE          NOT NULL,
    due_date      DATE          NOT NULL,          -- set by trigger: issue + 7 days
    return_date   DATE          NULL,
    status        ENUM('Issued','Returned') NOT NULL DEFAULT 'Issued',
    rent_charged  DECIMAL(8,2)  NULL,              -- set by trigger on return
    issued_by     VARCHAR(30)   NULL,

    CONSTRAINT fk_txn_book  FOREIGN KEY (book_id)   REFERENCES books(book_id),
    CONSTRAINT fk_txn_admin FOREIGN KEY (issued_by) REFERENCES admins(admin_id)
        ON DELETE SET NULL,
    CONSTRAINT chk_txn_dates CHECK (return_date IS NULL OR return_date >= issue_date),

    INDEX idx_txn_status  (status),
    INDEX idx_txn_student (student_name)
);

-- Audit trail, filled automatically by triggers
CREATE TABLE activity_log (
    log_id     INT           AUTO_INCREMENT PRIMARY KEY,
    action     VARCHAR(30)   NOT NULL,
    details    VARCHAR(255)  NOT NULL,
    logged_at  TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP
);


-- =====================================================================
-- 2. FUNCTION
-- =====================================================================
DELIMITER $$

-- Rent = weekly rent x number of weeks kept (any part of a week counts,
-- minimum 1 week).  0-7 days -> 1 week, 8-14 days -> 2 weeks, ...
CREATE FUNCTION fn_calculate_rent(p_weekly_rent DECIMAL(8,2),
                                  p_issue_date  DATE,
                                  p_return_date DATE)
RETURNS DECIMAL(8,2)
DETERMINISTIC
NO SQL
BEGIN
    DECLARE v_weeks INT;
    SET v_weeks = GREATEST(1, CEIL(DATEDIFF(p_return_date, p_issue_date) / 7));
    RETURN v_weeks * p_weekly_rent;
END$$


-- =====================================================================
-- 3. TRIGGERS
-- =====================================================================

-- Clean up book IDs before saving
CREATE TRIGGER trg_books_before_insert
BEFORE INSERT ON books
FOR EACH ROW
BEGIN
    SET NEW.book_id = UPPER(TRIM(NEW.book_id));
END$$

CREATE TRIGGER trg_books_after_insert
AFTER INSERT ON books
FOR EACH ROW
BEGIN
    INSERT INTO activity_log(action, details)
    VALUES ('BOOK_ADDED', CONCAT(NEW.book_id, ' - ', NEW.book_name,
                                 ' (', NEW.total_copies, ' copies)'));
END$$

-- Log edits made by the admin (not the stock changes made by issue/return)
CREATE TRIGGER trg_books_after_update
AFTER UPDATE ON books
FOR EACH ROW
BEGIN
    IF OLD.total_copies <> NEW.total_copies
       OR OLD.weekly_rent <> NEW.weekly_rent
       OR OLD.author      <> NEW.author
       OR OLD.category_id <> NEW.category_id THEN
        INSERT INTO activity_log(action, details)
        VALUES ('BOOK_UPDATED', CONCAT(NEW.book_id,
                ': copies ', OLD.total_copies, '->', NEW.total_copies,
                ', rent ', OLD.weekly_rent, '->', NEW.weekly_rent,
                ', author ', OLD.author, '->', NEW.author));
    END IF;
END$$

CREATE TRIGGER trg_books_after_delete
AFTER DELETE ON books
FOR EACH ROW
BEGIN
    INSERT INTO activity_log(action, details)
    VALUES ('BOOK_DELETED', CONCAT(OLD.book_id, ' - ', OLD.book_name));
END$$

-- Before an issue: make sure a copy is available, set the due date
CREATE TRIGGER trg_txn_before_insert
BEFORE INSERT ON transactions
FOR EACH ROW
BEGIN
    DECLARE v_available INT;

    SELECT available_copies INTO v_available
    FROM books WHERE book_id = NEW.book_id
    FOR UPDATE;

    IF v_available IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Book Not Found!';
    END IF;

    IF v_available <= 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Book Out Of Stock!';
    END IF;

    SET NEW.status       = 'Issued';
    SET NEW.return_date  = NULL;
    SET NEW.rent_charged = NULL;
    SET NEW.due_date     = DATE_ADD(NEW.issue_date, INTERVAL 7 DAY);
END$$

-- After an issue: take one copy off the shelf
CREATE TRIGGER trg_txn_after_insert
AFTER INSERT ON transactions
FOR EACH ROW
BEGIN
    UPDATE books
    SET available_copies = available_copies - 1
    WHERE book_id = NEW.book_id;

    INSERT INTO activity_log(action, details)
    VALUES ('BOOK_ISSUED', CONCAT(NEW.book_id, ' to ', NEW.student_name,
                                  ' on ', NEW.issue_date, ', due ', NEW.due_date));
END$$

-- Before a return: work out the rent
CREATE TRIGGER trg_txn_before_update
BEFORE UPDATE ON transactions
FOR EACH ROW
BEGIN
    DECLARE v_rent DECIMAL(8,2);

    IF OLD.status = 'Returned' AND NEW.status = 'Issued' THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'A returned transaction cannot be re-opened.';
    END IF;

    IF OLD.status = 'Issued' AND NEW.status = 'Returned' THEN
        SELECT weekly_rent INTO v_rent FROM books WHERE book_id = NEW.book_id;
        SET NEW.rent_charged = fn_calculate_rent(v_rent, NEW.issue_date, NEW.return_date);
    END IF;
END$$

-- After a return: put the copy back on the shelf
CREATE TRIGGER trg_txn_after_update
AFTER UPDATE ON transactions
FOR EACH ROW
BEGIN
    IF OLD.status = 'Issued' AND NEW.status = 'Returned' THEN
        UPDATE books
        SET available_copies = available_copies + 1
        WHERE book_id = NEW.book_id;

        INSERT INTO activity_log(action, details)
        VALUES ('BOOK_RETURNED', CONCAT(NEW.book_id, ' by ', NEW.student_name,
                                        ' on ', NEW.return_date,
                                        ', rent Rs ', NEW.rent_charged));
    END IF;
END$$


-- =====================================================================
-- 4. STORED PROCEDURES  (the app calls only these + the views)
-- =====================================================================

-- Login: returns one row on success, no rows on failure
CREATE PROCEDURE sp_admin_login(IN p_admin_id VARCHAR(30),
                                IN p_password VARCHAR(100))
BEGIN
    UPDATE admins
    SET last_login = NOW()
    WHERE admin_id = p_admin_id
      AND password_hash = SHA2(p_password, 256);

    SELECT admin_id, full_name, last_login
    FROM admins
    WHERE admin_id = p_admin_id
      AND password_hash = SHA2(p_password, 256);
END$$

-- Add a new book (category is created automatically if it is new)
CREATE PROCEDURE sp_add_book(IN p_book_id   VARCHAR(10),
                             IN p_book_name VARCHAR(200),
                             IN p_author    VARCHAR(100),
                             IN p_category  VARCHAR(50),
                             IN p_quantity  INT,
                             IN p_rent      DECIMAL(8,2))
BEGIN
    DECLARE v_cat_id INT;

    SET p_book_id  = UPPER(TRIM(p_book_id));
    SET p_category = TRIM(p_category);

    IF p_book_id = '' OR TRIM(p_book_name) = '' OR TRIM(p_author) = ''
       OR p_category = '' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Please fill in all the fields.';
    END IF;
    IF p_quantity IS NULL OR p_quantity < 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Quantity must be 0 or more.';
    END IF;
    IF p_rent IS NULL OR p_rent < 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Weekly rent must be 0 or more.';
    END IF;
    IF EXISTS (SELECT 1 FROM books WHERE book_id = p_book_id) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'A book with this Book ID already exists.';
    END IF;

    INSERT IGNORE INTO categories(category_name) VALUES (p_category);
    SELECT category_id INTO v_cat_id FROM categories WHERE category_name = p_category;

    INSERT INTO books(book_id, book_name, author, category_id,
                      total_copies, available_copies, weekly_rent)
    VALUES (p_book_id, TRIM(p_book_name), TRIM(p_author), v_cat_id,
            p_quantity, p_quantity, p_rent);

    SELECT * FROM v_books WHERE book_id = p_book_id;
END$$

-- Update a book. Pass NULL for anything you do not want to change.
-- p_total_copies is the new TOTAL; copies already issued stay issued.
CREATE PROCEDURE sp_update_book(IN p_book_id      VARCHAR(10),
                                IN p_total_copies INT,
                                IN p_rent         DECIMAL(8,2),
                                IN p_author       VARCHAR(100),
                                IN p_category     VARCHAR(50))
BEGIN
    DECLARE v_issued INT;
    DECLARE v_cat_id INT;

    SET p_book_id = UPPER(TRIM(p_book_id));

    SELECT total_copies - available_copies INTO v_issued
    FROM books WHERE book_id = p_book_id
    FOR UPDATE;

    IF v_issued IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Book ID not found!';
    END IF;
    IF p_total_copies IS NOT NULL AND p_total_copies < v_issued THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Total copies cannot be less than the copies currently issued.';
    END IF;
    IF p_rent IS NOT NULL AND p_rent < 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Weekly rent must be 0 or more.';
    END IF;

    IF p_category IS NOT NULL AND TRIM(p_category) <> '' THEN
        INSERT IGNORE INTO categories(category_name) VALUES (TRIM(p_category));
        SELECT category_id INTO v_cat_id FROM categories
        WHERE category_name = TRIM(p_category);
    END IF;

    UPDATE books
    SET total_copies     = COALESCE(p_total_copies, total_copies),
        available_copies = COALESCE(p_total_copies, total_copies) - v_issued,
        weekly_rent      = COALESCE(p_rent, weekly_rent),
        author           = COALESCE(NULLIF(TRIM(p_author), ''), author),
        category_id      = COALESCE(v_cat_id, category_id)
    WHERE book_id = p_book_id;

    SELECT * FROM v_books WHERE book_id = p_book_id;
END$$

-- Delete a book that has never been issued
CREATE PROCEDURE sp_delete_book(IN p_book_id VARCHAR(10))
BEGIN
    SET p_book_id = UPPER(TRIM(p_book_id));

    IF NOT EXISTS (SELECT 1 FROM books WHERE book_id = p_book_id) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Book ID not found!';
    END IF;
    IF EXISTS (SELECT 1 FROM transactions WHERE book_id = p_book_id) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'This book has issue history, so it cannot be deleted. Set its copies to 0 instead.';
    END IF;

    DELETE FROM books WHERE book_id = p_book_id;
    SELECT p_book_id AS deleted_book_id;
END$$

-- Issue a book to a student
CREATE PROCEDURE sp_issue_book(IN p_student    VARCHAR(100),
                               IN p_book_id    VARCHAR(10),
                               IN p_issue_date DATE,
                               IN p_admin_id   VARCHAR(30))
BEGIN
    DECLARE v_txn_id INT;

    SET p_book_id = UPPER(TRIM(p_book_id));
    SET p_student = TRIM(p_student);

    IF p_student IS NULL OR p_student = '' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Please enter the student name.';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM books WHERE book_id = p_book_id) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Book Not Found!';
    END IF;
    IF EXISTS (SELECT 1 FROM transactions
               WHERE book_id = p_book_id AND student_name = p_student
                 AND status = 'Issued') THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'This student already has a copy of this book.';
    END IF;

    -- The BEFORE INSERT trigger checks stock and sets the due date;
    -- the AFTER INSERT trigger reduces available copies.
    INSERT INTO transactions(student_name, book_id, issue_date, due_date, issued_by)
    VALUES (p_student, p_book_id, COALESCE(p_issue_date, CURDATE()),
            COALESCE(p_issue_date, CURDATE()), p_admin_id);

    SET v_txn_id = LAST_INSERT_ID();
    SELECT * FROM v_transactions WHERE txn_id = v_txn_id;
END$$

-- Return a book (oldest open issue for that student + book)
CREATE PROCEDURE sp_return_book(IN p_book_id     VARCHAR(10),
                                IN p_student     VARCHAR(100),
                                IN p_return_date DATE)
BEGIN
    DECLARE v_txn_id     INT;
    DECLARE v_issue_date DATE;

    SET p_book_id     = UPPER(TRIM(p_book_id));
    SET p_student     = TRIM(p_student);
    SET p_return_date = COALESCE(p_return_date, CURDATE());

    IF NOT EXISTS (SELECT 1 FROM books WHERE book_id = p_book_id) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Book Not Found!';
    END IF;

    SELECT txn_id, issue_date INTO v_txn_id, v_issue_date
    FROM transactions
    WHERE book_id = p_book_id AND student_name = p_student AND status = 'Issued'
    ORDER BY issue_date, txn_id
    LIMIT 1
    FOR UPDATE;

    IF v_txn_id IS NULL THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'No issued book found for this student!';
    END IF;
    IF p_return_date < v_issue_date THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Return date cannot be before the issue date.';
    END IF;

    -- BEFORE UPDATE trigger computes rent; AFTER UPDATE trigger restocks.
    UPDATE transactions
    SET return_date = p_return_date,
        status      = 'Returned'
    WHERE txn_id = v_txn_id;

    SELECT * FROM v_transactions WHERE txn_id = v_txn_id;
END$$

-- Change an admin's password
CREATE PROCEDURE sp_change_password(IN p_admin_id VARCHAR(30),
                                    IN p_old_pass VARCHAR(100),
                                    IN p_new_pass VARCHAR(100))
BEGIN
    IF CHAR_LENGTH(p_new_pass) < 6 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'New password must be at least 6 characters.';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM admins
                   WHERE admin_id = p_admin_id
                     AND password_hash = SHA2(p_old_pass, 256)) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Current password is incorrect.';
    END IF;

    UPDATE admins SET password_hash = SHA2(p_new_pass, 256)
    WHERE admin_id = p_admin_id;

    SELECT 'Password changed' AS message;
END$$

DELIMITER ;


-- =====================================================================
-- 5. VIEWS
-- =====================================================================

-- Book list as shown in the "Books" tab
CREATE VIEW v_books AS
SELECT b.book_id,
       b.book_name,
       b.author,
       c.category_name                          AS category,
       b.total_copies,
       b.available_copies,
       b.total_copies - b.available_copies      AS issued_copies,
       b.weekly_rent,
       CASE WHEN b.available_copies > 0 THEN 'Available'
            ELSE 'Out Of Stock' END             AS status
FROM books b
JOIN categories c ON c.category_id = b.category_id;

-- Transactions as shown in the "Transactions" tab
CREATE VIEW v_transactions AS
SELECT t.txn_id,
       t.student_name,
       t.book_id,
       b.book_name,
       t.issue_date,
       t.due_date,
       t.return_date,
       t.status,
       CASE WHEN t.status = 'Issued' AND CURDATE() > t.due_date
            THEN 'Overdue' ELSE t.status END    AS display_status,
       CASE WHEN t.status = 'Issued'
            THEN GREATEST(0, DATEDIFF(CURDATE(), t.due_date))
            ELSE GREATEST(0, DATEDIFF(t.return_date, t.due_date)) END AS days_late,
       t.rent_charged,
       t.issued_by
FROM transactions t
JOIN books b ON b.book_id = t.book_id;

-- One-row summary for the dashboard cards
CREATE VIEW v_dashboard AS
SELECT
    (SELECT COUNT(*) FROM books)                                   AS total_books,
    (SELECT COALESCE(SUM(total_copies), 0) FROM books)             AS total_copies,
    (SELECT COUNT(*) FROM books WHERE available_copies > 0)        AS available_books,
    (SELECT COALESCE(SUM(available_copies), 0) FROM books)         AS available_copies,
    (SELECT COUNT(*) FROM transactions WHERE status = 'Issued')    AS issued_books,
    (SELECT COUNT(*) FROM transactions WHERE status = 'Returned')  AS returned_books,
    (SELECT COUNT(*) FROM transactions
      WHERE status = 'Issued' AND CURDATE() > due_date)            AS overdue_books,
    (SELECT COALESCE(SUM(rent_charged), 0) FROM transactions)      AS rent_collected,
    (SELECT COUNT(*) FROM categories)                              AS total_categories;

-- Per-category totals
CREATE VIEW v_category_summary AS
SELECT c.category_name                          AS category,
       COUNT(b.book_id)                         AS titles,
       COALESCE(SUM(b.total_copies), 0)         AS total_copies,
       COALESCE(SUM(b.total_copies - b.available_copies), 0) AS issued_copies
FROM categories c
LEFT JOIN books b ON b.category_id = c.category_id
GROUP BY c.category_id, c.category_name;

-- Most issued books
CREATE VIEW v_popular_books AS
SELECT b.book_id,
       b.book_name,
       b.author,
       COUNT(t.txn_id)                          AS times_issued,
       COALESCE(SUM(t.rent_charged), 0)         AS rent_earned
FROM books b
JOIN transactions t ON t.book_id = b.book_id
GROUP BY b.book_id, b.book_name, b.author;


-- =====================================================================
-- 6. SEED DATA
-- =====================================================================

-- Same login as the Java version:  libraryadmin / admin123
INSERT INTO admins(admin_id, full_name, password_hash)
VALUES ('libraryadmin', 'Library Administrator', SHA2('admin123', 256));

-- Same 25 books as Library.java -> loadBooks()
INSERT INTO categories(category_name) VALUES
('Fantasy'),
('Thriller'),
('Mystery'),
('Horror'),
('Coding'),
('Study'),
('Self Help'),
('Finance'),
('History'),
('Novel'),
('Biography');

INSERT INTO books(book_id, book_name, author, category_id, total_copies, available_copies, weekly_rent) VALUES
('BK101', 'Harry Potter and the Philosopher''s Stone', 'J.K. Rowling', (SELECT category_id FROM categories WHERE category_name = 'Fantasy'), 8, 8, 50),
('BK102', 'Harry Potter and the Chamber of Secrets', 'J.K. Rowling', (SELECT category_id FROM categories WHERE category_name = 'Fantasy'), 6, 6, 50),
('BK103', 'The Hobbit', 'J.R.R. Tolkien', (SELECT category_id FROM categories WHERE category_name = 'Fantasy'), 7, 7, 45),
('BK104', 'The Lord of the Rings', 'J.R.R. Tolkien', (SELECT category_id FROM categories WHERE category_name = 'Fantasy'), 5, 5, 60),
('BK105', 'The Silent Patient', 'Alex Michaelides', (SELECT category_id FROM categories WHERE category_name = 'Thriller'), 5, 5, 55),
('BK106', 'Gone Girl', 'Gillian Flynn', (SELECT category_id FROM categories WHERE category_name = 'Thriller'), 4, 4, 50),
('BK107', 'Sherlock Holmes', 'Arthur Conan Doyle', (SELECT category_id FROM categories WHERE category_name = 'Mystery'), 6, 6, 45),
('BK108', 'Dracula', 'Bram Stoker', (SELECT category_id FROM categories WHERE category_name = 'Horror'), 5, 5, 55),
('BK109', 'The Shining', 'Stephen King', (SELECT category_id FROM categories WHERE category_name = 'Horror'), 4, 4, 60),
('BK110', 'IT', 'Stephen King', (SELECT category_id FROM categories WHERE category_name = 'Horror'), 4, 4, 65),
('BK111', 'Java The Complete Reference', 'Herbert Schildt', (SELECT category_id FROM categories WHERE category_name = 'Coding'), 10, 10, 70),
('BK112', 'Head First Java', 'Kathy Sierra', (SELECT category_id FROM categories WHERE category_name = 'Coding'), 8, 8, 65),
('BK113', 'Clean Code', 'Robert C. Martin', (SELECT category_id FROM categories WHERE category_name = 'Coding'), 6, 6, 80),
('BK114', 'Effective Java', 'Joshua Bloch', (SELECT category_id FROM categories WHERE category_name = 'Coding'), 5, 5, 85),
('BK115', 'Operating System Concepts', 'Silberschatz', (SELECT category_id FROM categories WHERE category_name = 'Study'), 8, 8, 60),
('BK116', 'Computer Networks', 'Andrew Tanenbaum', (SELECT category_id FROM categories WHERE category_name = 'Study'), 7, 7, 55),
('BK117', 'Database System Concepts', 'Korth', (SELECT category_id FROM categories WHERE category_name = 'Study'), 6, 6, 60),
('BK118', 'Data Structures Using Java', 'Narasimha Karumanchi', (SELECT category_id FROM categories WHERE category_name = 'Study'), 8, 8, 55),
('BK119', 'Atomic Habits', 'James Clear', (SELECT category_id FROM categories WHERE category_name = 'Self Help'), 9, 9, 40),
('BK120', 'Rich Dad Poor Dad', 'Robert Kiyosaki', (SELECT category_id FROM categories WHERE category_name = 'Finance'), 8, 8, 45),
('BK121', 'Think Like a Monk', 'Jay Shetty', (SELECT category_id FROM categories WHERE category_name = 'Self Help'), 7, 7, 45),
('BK122', 'Ikigai', 'Hector Garcia', (SELECT category_id FROM categories WHERE category_name = 'Self Help'), 6, 6, 40),
('BK123', 'Sapiens', 'Yuval Noah Harari', (SELECT category_id FROM categories WHERE category_name = 'History'), 5, 5, 60),
('BK124', 'The Alchemist', 'Paulo Coelho', (SELECT category_id FROM categories WHERE category_name = 'Novel'), 9, 9, 35),
('BK125', 'Wings of Fire', 'A.P.J. Abdul Kalam', (SELECT category_id FROM categories WHERE category_name = 'Biography'), 8, 8, 40);

-- A few sample transactions so the dashboard is not empty.
-- Inserting into transactions fires the triggers: stock goes down, due date is set.
-- (Delete this block if you want to start with no history.)
INSERT INTO transactions(student_name, book_id, issue_date, due_date, issued_by) VALUES
('Riya Shah',   'BK113', CURDATE() - INTERVAL 20 DAY, CURDATE(), 'libraryadmin'),
('Aman Verma',  'BK101', CURDATE() - INTERVAL 15 DAY, CURDATE(), 'libraryadmin'),
('Sneha Patil', 'BK117', CURDATE() - INTERVAL 10 DAY, CURDATE(), 'libraryadmin'),
('Karan Mehta', 'BK119', CURDATE() - INTERVAL 3 DAY,  CURDATE(), 'libraryadmin'),
('Riya Shah',   'BK124', CURDATE() - INTERVAL 2 DAY,  CURDATE(), 'libraryadmin');

-- Returning = setting status to 'Returned': triggers compute rent and restock.
UPDATE transactions SET return_date = CURDATE() - INTERVAL 5 DAY, status = 'Returned'
WHERE student_name = 'Aman Verma' AND book_id = 'BK101';
UPDATE transactions SET return_date = CURDATE(), status = 'Returned'
WHERE student_name = 'Sneha Patil' AND book_id = 'BK117';

-- Quick check
SELECT * FROM v_dashboard;
