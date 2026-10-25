// =====================================================================
//  KnowledgeHub Public Library - browser side
//  Talks to server.js, which calls the MySQL procedures and views.
// =====================================================================

const $ = (sel, root = document) => root.querySelector(sel);
const $$ = (sel, root = document) => [...root.querySelectorAll(sel)];

let token = sessionStorageGet('kh_token');
let booksCache = [];

// ---------- small utilities ----------
function sessionStorageGet(k) { try { return sessionStorage.getItem(k); } catch { return null; } }
function sessionStorageSet(k, v) { try { v == null ? sessionStorage.removeItem(k) : sessionStorage.setItem(k, v); } catch { /* ignore */ } }

const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) =>
  ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const rupee = (n) => '₹' + Number(n || 0).toLocaleString('en-IN', { maximumFractionDigits: 2 });
const today = () => {
  const d = new Date();
  return new Date(d.getTime() - d.getTimezoneOffset() * 60000).toISOString().slice(0, 10);
};
const fmtDate = (s) => {
  if (!s) return '—';
  const [y, m, d] = s.split('-');
  return `${d}-${m}-${y}`;
};
const formData = (form) => Object.fromEntries(new FormData(form).entries());

let toastTimer;
function toast(msg, kind = 'ok') {
  const t = $('#toast');
  t.textContent = msg;
  t.className = `toast show ${kind}`;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => (t.className = 'toast'), 3200);
}

async function api(path, { method = 'GET', body } = {}) {
  const res = await fetch('/api' + path, {
    method,
    headers: { 'Content-Type': 'application/json', ...(token ? { Authorization: 'Bearer ' + token } : {}) },
    body: body ? JSON.stringify(body) : undefined,
  });
  const data = await res.json().catch(() => ({}));
  if (res.status === 401 && path !== '/login') { logout(false); }
  if (!res.ok) throw new Error(data.error || 'Something went wrong.');
  return data;
}

// ---------- login / logout ----------
$('#login-form').addEventListener('submit', async (e) => {
  e.preventDefault();
  $('#login-error').textContent = '';
  try {
    const data = await api('/login', { method: 'POST', body: formData(e.target) });
    token = data.token;
    sessionStorageSet('kh_token', token);
    sessionStorageSet('kh_name', data.fullName);
    e.target.reset();
    showApp();
    toast('Login Successful!');
  } catch (err) {
    $('#login-error').textContent = err.message;
  }
});

function logout(callServer = true) {
  if (callServer && token) api('/logout', { method: 'POST' }).catch(() => {});
  token = null;
  sessionStorageSet('kh_token', null);
  $('#app-view').hidden = true;
  $('#login-view').hidden = false;
}
$('#btn-logout').addEventListener('click', () => logout());

function showApp() {
  const name = sessionStorageGet('kh_name') || 'Library Administrator';
  $('#admin-name').textContent = name;
  $('#welcome-name').textContent = name;
  $('#login-view').hidden = true;
  $('#app-view').hidden = false;
  openTab('dashboard');
  loadLookups();
}

// ---------- password dialog ----------
$('#btn-password').addEventListener('click', () => {
  $('#password-form').reset();
  $('#password-error').textContent = '';
  $('#password-dialog').showModal();
});
$('#password-form').addEventListener('submit', async (e) => {
  if (e.submitter?.value !== 'save') return;
  e.preventDefault();
  try {
    await api('/change-password', { method: 'POST', body: formData(e.target) });
    $('#password-dialog').close();
    toast('Password changed.');
  } catch (err) {
    $('#password-error').textContent = err.message;
  }
});

// ---------- tabs ----------
const loaders = {
  dashboard: loadDashboard,
  books: loadBooks,
  update: () => refreshUpdatePreview(),
  issue: () => { if (!$('#issue-form').issueDate.value) $('#issue-form').issueDate.value = today(); },
  return: loadActiveIssues,
  transactions: loadTransactions,
};

function openTab(name) {
  $$('#tabs button').forEach((b) => b.classList.toggle('active', b.dataset.tab === name));
  $$('[data-panel]').forEach((p) => (p.hidden = p.dataset.panel !== name));
  (loaders[name] || (() => {}))();
  window.scrollTo({ top: 0 });
}
$('#tabs').addEventListener('click', (e) => {
  const b = e.target.closest('button[data-tab]');
  if (b) openTab(b.dataset.tab);
});

// ---------- lookups for the dropdowns ----------
async function loadLookups() {
  try {
    const [cats, books, txns] = await Promise.all([
      api('/categories'), api('/books'), api('/transactions'),
    ]);
    booksCache = books;
    $('#category-options').innerHTML = cats.map((c) => `<option value="${esc(c.category_name)}">`).join('');
    const sel = $('#book-category');
    const current = sel.value;
    sel.innerHTML = '<option value="">All categories</option>' +
      cats.map((c) => `<option>${esc(c.category_name)}</option>`).join('');
    sel.value = current;
    $('#book-options').innerHTML = books.map((b) =>
      `<option value="${esc(b.book_id)}">${esc(b.book_name)}</option>`).join('');
    $('#available-options').innerHTML = books.filter((b) => b.available_copies > 0).map((b) =>
      `<option value="${esc(b.book_id)}">${esc(b.book_name)} — ${b.available_copies} left</option>`).join('');
    const students = [...new Set(txns.map((t) => t.student_name))].sort();
    $('#student-options').innerHTML = students.map((s) => `<option value="${esc(s)}">`).join('');
  } catch (err) { toast(err.message, 'err'); }
}

// ---------- dashboard ----------
async function loadDashboard() {
  try {
    const { summary: s, categories, popular, overdue, activity } = await api('/dashboard');

    const cards = [
      ['Total Books', s.total_books, `${s.total_copies} copies · ${s.total_categories} categories`],
      ['Available Books', s.available_books, `${s.available_copies} copies on shelf`, 'good'],
      ['Issued Books', s.issued_books, 'currently with students'],
      ['Returned Books', s.returned_books, 'completed transactions'],
      ['Overdue', s.overdue_books, 'past 7-day due date', s.overdue_books > 0 ? 'warn' : ''],
      ['Rent Collected', rupee(s.rent_collected), 'from returned books'],
    ];
    $('#stat-cards').innerHTML = cards.map(([label, value, sub, cls = '']) => `
      <div class="card ${cls}">
        <div class="label">${label}</div>
        <div class="value">${esc(value)}</div>
        <div class="sub">${esc(sub)}</div>
      </div>`).join('');

    const max = Math.max(1, ...categories.map((c) => c.total_copies));
    $('#category-bars').innerHTML = categories.map((c) => `
      <div class="bar-row">
        <span>${esc(c.category)}</span>
        <div class="bar-track" title="${c.issued_copies} of ${c.total_copies} copies issued">
          <div class="bar-fill" style="width:${(c.total_copies / max) * 100}%"></div>
          <div class="bar-issued" style="width:${(c.issued_copies / max) * 100}%"></div>
        </div>
        <span class="bar-num">${c.issued_copies}/${c.total_copies}</span>
      </div>`).join('') +
      '<div class="legend"><span><i style="background:var(--navy)"></i>copies</span><span><i style="background:#d98b2b"></i>issued now</span></div>';

    $('#overdue-list').innerHTML = overdue.length
      ? `<ul class="mini-list">${overdue.map((t) => `
          <li><span><strong>${esc(t.student_name)}</strong><br><span class="meta">${esc(t.book_id)} · ${esc(t.book_name)}</span></span>
              <span class="pill Overdue">${t.days_late} day${t.days_late == 1 ? '' : 's'} late</span></li>`).join('')}</ul>`
      : '<p class="empty">No overdue books. </p>';

    $('#popular-list').innerHTML = popular.length
      ? `<ul class="mini-list">${popular.map((p) => `
          <li><span>${esc(p.book_name)}<br><span class="meta">${esc(p.author)}</span></span>
              <span class="meta">${p.times_issued}× · ${rupee(p.rent_earned)}</span></li>`).join('')}</ul>`
      : '<p class="empty">No books issued yet.</p>';

    $('#activity-list').innerHTML = activity.length
      ? activity.map((a) => `<li><span class="act ${esc(a.action)}">${esc(a.action.replace('BOOK_', ''))}</span>
          <span>${esc(a.details)}<br><span class="muted small">${esc(a.logged_at)}</span></span></li>`).join('')
      : '<li class="empty">Nothing yet.</li>';
  } catch (err) { toast(err.message, 'err'); }
}

// ---------- books ----------
let searchTimer;
$('#book-search').addEventListener('input', () => { clearTimeout(searchTimer); searchTimer = setTimeout(loadBooks, 250); });
$('#book-category').addEventListener('change', loadBooks);

async function loadBooks() {
  try {
    const q = new URLSearchParams({ search: $('#book-search').value, category: $('#book-category').value });
    const books = await api('/books?' + q);
    $('#books-body').innerHTML = books.length ? books.map((b) => `
      <tr>
        <td class="mono">${esc(b.book_id)}</td>
        <td class="title">${esc(b.book_name)}</td>
        <td>${esc(b.author)}</td>
        <td>${esc(b.category)}</td>
        <td class="num">${b.total_copies}</td>
        <td class="num">${b.available_copies}</td>
        <td class="num">${rupee(b.weekly_rent)}</td>
        <td><span class="pill ${b.status === 'Available' ? 'Available' : 'Out'}">${esc(b.status)}</span></td>
        <td>
          <button class="btn link" data-edit="${esc(b.book_id)}">Edit</button>
          ${b.available_copies > 0 ? `<button class="btn link" data-issue="${esc(b.book_id)}">Issue</button>` : ''}
        </td>
      </tr>`).join('')
      : '<tr><td colspan="9" class="empty">No books match.</td></tr>';
  } catch (err) { toast(err.message, 'err'); }
}

$('#books-body').addEventListener('click', (e) => {
  const edit = e.target.closest('[data-edit]');
  const issue = e.target.closest('[data-issue]');
  if (edit) { $('#update-form').bookId.value = edit.dataset.edit; openTab('update'); }
  if (issue) { $('#issue-form').bookId.value = issue.dataset.issue; openTab('issue'); refreshIssuePreview(); }
});

// ---------- add book ----------
$('#add-form').addEventListener('submit', async (e) => {
  e.preventDefault();
  try {
    const book = await api('/books', { method: 'POST', body: formData(e.target) });
    toast(`Book Added Successfully! (${book.book_id})`);
    e.target.reset();
    loadLookups();
  } catch (err) { toast(err.message, 'err'); }
});

// ---------- update / delete book ----------
const updateForm = $('#update-form');
updateForm.bookId.addEventListener('input', refreshUpdatePreview);

function findBook(id) {
  id = String(id || '').trim().toUpperCase();
  return booksCache.find((b) => b.book_id === id);
}

function refreshUpdatePreview() {
  const box = $('#update-current');
  const id = updateForm.bookId.value.trim();
  if (!id) { box.hidden = true; return; }
  const b = findBook(id);
  box.hidden = false;
  box.classList.toggle('bad', !b);
  box.innerHTML = b
    ? `<strong>${esc(b.book_name)}</strong>
       <span>Author: ${esc(b.author)} · Category: ${esc(b.category)}</span>
       <span>Copies: ${b.total_copies} total, ${b.issued_copies} issued, ${b.available_copies} available · Rent ${rupee(b.weekly_rent)}/week</span>`
    : 'Book ID not found!';
}

updateForm.addEventListener('submit', async (e) => {
  e.preventDefault();
  const d = formData(e.target);
  try {
    await api('/books/' + encodeURIComponent(d.bookId.trim()), { method: 'PUT', body: d });
    toast('Book Updated Successfully!');
    const id = d.bookId;
    e.target.reset();
    e.target.bookId.value = id;
    await loadLookups();
    refreshUpdatePreview();
  } catch (err) { toast(err.message, 'err'); }
});

$('#btn-delete').addEventListener('click', async () => {
  const id = updateForm.bookId.value.trim();
  if (!id) return toast('Enter a Book ID first.', 'err');
  const b = findBook(id);
  if (!window.confirm(`Delete ${id}${b ? ' – ' + b.book_name : ''}? This cannot be undone.`)) return;
  try {
    await api('/books/' + encodeURIComponent(id), { method: 'DELETE' });
    toast('Book deleted.');
    updateForm.reset();
    await loadLookups();
    refreshUpdatePreview();
  } catch (err) { toast(err.message, 'err'); }
});

// ---------- issue ----------
const issueForm = $('#issue-form');
issueForm.bookId.addEventListener('input', refreshIssuePreview);
issueForm.issueDate.addEventListener('input', refreshIssuePreview);

function refreshIssuePreview() {
  const box = $('#issue-preview');
  const id = issueForm.bookId.value.trim();
  if (!id) { box.hidden = true; return; }
  const b = findBook(id);
  box.hidden = false;
  if (!b) { box.classList.add('bad'); box.textContent = 'Book Not Found!'; return; }
  box.classList.toggle('bad', b.available_copies <= 0);
  let due = '';
  if (issueForm.issueDate.value) {
    const d = new Date(issueForm.issueDate.value + 'T00:00:00');
    d.setDate(d.getDate() + 7);
    due = d.toLocaleDateString('en-GB').replace(/\//g, '-');
  }
  box.innerHTML = b.available_copies > 0
    ? `<strong>${esc(b.book_name)}</strong>
       <span>${esc(b.author)} · ${b.available_copies} of ${b.total_copies} available · ${rupee(b.weekly_rent)}/week</span>
       ${due ? `<span>Due back by <strong>${due}</strong></span>` : ''}`
    : `<strong>${esc(b.book_name)}</strong><span>Book Out Of Stock!</span>`;
}

issueForm.addEventListener('submit', async (e) => {
  e.preventDefault();
  try {
    const t = await api('/issue', { method: 'POST', body: formData(e.target) });
    toast(`Book Issued Successfully! Due ${fmtDate(t.due_date)}`);
    e.target.reset();
    e.target.issueDate.value = today();
    $('#issue-preview').hidden = true;
    loadLookups();
  } catch (err) { toast(err.message, 'err'); }
});

// ---------- return ----------
const returnForm = $('#return-form');

async function loadActiveIssues() {
  if (!returnForm.returnDate.value) returnForm.returnDate.value = today();
  try {
    const rows = await api('/active-issues');
    $('#return-pick').innerHTML = '<option value="">— select —</option>' + rows.map((t) =>
      `<option value="${esc(t.book_id)}|${esc(t.student_name)}">${esc(t.student_name)} — ${esc(t.book_id)} ${esc(t.book_name)} (issued ${fmtDate(t.issue_date)}${t.display_status === 'Overdue' ? ', OVERDUE' : ''})</option>`).join('');
  } catch (err) { toast(err.message, 'err'); }
}

$('#return-pick').addEventListener('change', (e) => {
  if (!e.target.value) return;
  const [bookId, student] = e.target.value.split('|');
  returnForm.bookId.value = bookId;
  returnForm.studentName.value = student;
});

returnForm.addEventListener('submit', async (e) => {
  e.preventDefault();
  try {
    const t = await api('/return', { method: 'POST', body: formData(e.target) });
    toast('Book Returned Successfully!');
    $('#return-receipt').hidden = false;
    $('#return-receipt').innerHTML = `
      <strong>Returned: ${esc(t.book_name)} (${esc(t.book_id)})</strong>
      <span>Student: ${esc(t.student_name)}</span>
      <span>Issued ${fmtDate(t.issue_date)} · Due ${fmtDate(t.due_date)} · Returned ${fmtDate(t.return_date)}${t.days_late > 0 ? ` · ${t.days_late} day(s) late` : ''}</span>
      <span>Rent to collect: <strong>${rupee(t.rent_charged)}</strong></span>`;
    e.target.bookId.value = '';
    e.target.studentName.value = '';
    loadActiveIssues();
    loadLookups();
  } catch (err) { toast(err.message, 'err'); $('#return-receipt').hidden = true; }
});

// ---------- transactions ----------
let txnStatus = '';
$('#txn-filter').addEventListener('click', (e) => {
  const b = e.target.closest('button');
  if (!b) return;
  txnStatus = b.dataset.status;
  $$('#txn-filter button').forEach((x) => x.classList.toggle('active', x === b));
  loadTransactions();
});
let txnTimer;
$('#txn-search').addEventListener('input', () => { clearTimeout(txnTimer); txnTimer = setTimeout(loadTransactions, 250); });

async function loadTransactions() {
  try {
    const q = new URLSearchParams({ status: txnStatus, search: $('#txn-search').value });
    const rows = await api('/transactions?' + q);
    $('#txn-body').innerHTML = rows.length ? rows.map((t) => `
      <tr>
        <td class="mono">${t.txn_id}</td>
        <td>${esc(t.student_name)}</td>
        <td class="mono">${esc(t.book_id)}</td>
        <td class="title">${esc(t.book_name)}</td>
        <td>${fmtDate(t.issue_date)}</td>
        <td>${fmtDate(t.due_date)}</td>
        <td>${fmtDate(t.return_date)}</td>
        <td><span class="pill ${esc(t.display_status)}">${esc(t.display_status)}${t.display_status === 'Overdue' ? ` · ${t.days_late}d` : ''}</span></td>
        <td class="num">${t.rent_charged == null ? '—' : rupee(t.rent_charged)}</td>
      </tr>`).join('')
      : '<tr><td colspan="9" class="empty">No transactions.</td></tr>';
  } catch (err) { toast(err.message, 'err'); }
}

// ---------- start ----------
if (token) {
  api('/dashboard').then(showApp).catch(() => logout(false));
}
