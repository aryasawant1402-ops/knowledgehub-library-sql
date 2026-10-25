-- =====================================================================
--  KnowledgeHub Public Library - practice / viva queries
--  Run after library.sql. Each one works directly in MySQL Workbench.
-- =====================================================================
USE knowledgehub_library;

-- ---------- Using the views ----------
SELECT * FROM v_dashboard;
SELECT * FROM v_books ORDER BY category, book_name;
SELECT * FROM v_transactions ORDER BY issue_date DESC;
SELECT * FROM v_category_summary ORDER BY titles DESC;
SELECT * FROM v_popular_books ORDER BY times_issued DESC LIMIT 5;

-- ---------- Using the stored procedures ----------
CALL sp_admin_login('libraryadmin', 'admin123');
CALL sp_add_book('BK126', 'Let Us C', 'Yashavant Kanetkar', 'Coding', 5, 40);
CALL sp_update_book('BK126', 7, 45, NULL, NULL);      -- 7 copies, Rs 45/week
CALL sp_issue_book('Parth', 'BK126', CURDATE(), 'libraryadmin');
CALL sp_return_book('BK126', 'Parth', CURDATE() + INTERVAL 9 DAY);   -- 2 weeks rent
SELECT fn_calculate_rent(50, '2026-01-01', '2026-01-20') AS rent;    -- 3 weeks = 150

-- ---------- These are rejected by the database ----------
-- CALL sp_issue_book('Parth', 'BK999', CURDATE(), 'libraryadmin');  -- Book Not Found!
-- CALL sp_return_book('BK101', 'Nobody', CURDATE());                -- No issued book found
-- UPDATE books SET available_copies = 999 WHERE book_id = 'BK101';  -- CHECK constraint fails

-- ---------- Plain SQL practice ----------

-- 1. Books currently out of stock
SELECT book_id, book_name FROM books WHERE available_copies = 0;

-- 2. Students who currently hold books, with how many
SELECT student_name, COUNT(*) AS books_held
FROM transactions WHERE status = 'Issued'
GROUP BY student_name ORDER BY books_held DESC;

-- 3. Overdue books with the number of days late
SELECT student_name, book_id, due_date, DATEDIFF(CURDATE(), due_date) AS days_late
FROM transactions
WHERE status = 'Issued' AND due_date < CURDATE()
ORDER BY days_late DESC;

-- 4. Rent collected per category (JOIN across three tables)
SELECT c.category_name, COALESCE(SUM(t.rent_charged), 0) AS rent
FROM categories c
JOIN books b             ON b.category_id = c.category_id
LEFT JOIN transactions t ON t.book_id = b.book_id
GROUP BY c.category_name
ORDER BY rent DESC;

-- 5. Books that have never been issued (subquery)
SELECT book_id, book_name FROM books
WHERE book_id NOT IN (SELECT DISTINCT book_id FROM transactions);

-- 6. Authors with more than one title
SELECT author, COUNT(*) AS titles FROM books
GROUP BY author HAVING COUNT(*) > 1;

-- 7. The most expensive book in each category (correlated subquery)
SELECT b.book_name, c.category_name, b.weekly_rent
FROM books b JOIN categories c ON c.category_id = b.category_id
WHERE b.weekly_rent = (SELECT MAX(weekly_rent) FROM books b2
                       WHERE b2.category_id = b.category_id);

-- 8. What the triggers have recorded
SELECT * FROM activity_log ORDER BY log_id DESC LIMIT 20;

-- 9. See every trigger, procedure and view in the database
SHOW TRIGGERS;
SHOW PROCEDURE STATUS WHERE Db = 'knowledgehub_library';
SHOW FULL TABLES WHERE Table_type = 'VIEW';
