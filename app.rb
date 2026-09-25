require 'sinatra'
require 'csv'
require 'json'
require 'rqrcode'
require 'securerandom'
require 'sqlite3'
require 'time'
require 'uri'
require 'fileutils'
require 'rack/utils'

enable :sessions
set :session_secret, ENV.fetch('SESSION_SECRET') { SecureRandom.hex(64) }
set :public_folder, File.join(__dir__, 'static')

APP_ROOT = File.expand_path(__dir__)
DATABASE_FILE = ENV.fetch('DATABASE_FILE', File.join(APP_ROOT, 'restaurant.sqlite3'))
LEGACY_PRODUCTS_FILE = ENV.fetch('PRODUCTS_FILE', File.join(APP_ROOT, 'products.json'))
LEGACY_ORDERS_FILE = ENV.fetch('ORDERS_FILE', File.join(APP_ROOT, 'order_placed.json'))
ORDER_RECORDS_FILE = ENV.fetch('ORDER_RECORDS_FILE', File.join(APP_ROOT, 'order_records.json'))
ORDER_RECORDS_VERSION = '2'
PRODUCT_CATEGORIES = ['General', 'Starters', 'Vegetables', 'Chicken', 'Seafood', 'Beverages', 'Desserts'].freeze
DEFAULT_PRODUCTS = [
  { 'id' => 'veg-rice', 'name' => 'Veg Rice', 'price' => 50, 'category' => 'Vegetables', 'description' => 'Fragrant rice with seasonal vegetables and herbs.', 'available' => true },
  { 'id' => 'veg-soup', 'name' => 'Veg Soup', 'price' => 30, 'category' => 'Starters', 'description' => 'Warm vegetable broth with a comforting finish.', 'available' => true },
  { 'id' => 'veg-salad', 'name' => 'Veg Salad', 'price' => 40, 'category' => 'Starters', 'description' => 'Crisp greens, cucumber, tomato, and house dressing.', 'available' => true },
  { 'id' => 'chicken-curry', 'name' => 'Chicken Curry', 'price' => 120, 'category' => 'Chicken', 'description' => 'Slow-cooked chicken in a rich aromatic gravy.', 'available' => true },
  { 'id' => 'fish-fry', 'name' => 'Fish Fry', 'price' => 150, 'category' => 'Seafood', 'description' => 'Crisp fried fish with lemon and herbs.', 'available' => true }
].freeze

FileUtils.mkdir_p(File.dirname(DATABASE_FILE)) unless DATABASE_FILE == ':memory:'
DATABASE = SQLite3::Database.new(DATABASE_FILE)
DATABASE.results_as_hash = true
DATABASE.busy_timeout(5000)
DATABASE.execute('PRAGMA foreign_keys = ON')
DATABASE.execute('PRAGMA journal_mode = WAL')
DATABASE.execute_batch(<<~SQL)
  CREATE TABLE IF NOT EXISTS app_meta (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL
  );

  CREATE TABLE IF NOT EXISTS products (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    price INTEGER NOT NULL CHECK (price > 0),
    category TEXT NOT NULL,
    description TEXT NOT NULL DEFAULT '',
    available INTEGER NOT NULL DEFAULT 1 CHECK (available IN (0, 1)),
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
  );

  CREATE TABLE IF NOT EXISTS orders (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL DEFAULT 'Guest',
    total INTEGER NOT NULL DEFAULT 0,
    status TEXT NOT NULL DEFAULT 'pending',
    payment_method TEXT NOT NULL DEFAULT 'simulated',
    payment_status TEXT NOT NULL DEFAULT 'pending',
    payment_reference TEXT NOT NULL DEFAULT '',
    created_at TEXT NOT NULL,
    completed_at TEXT,
    source TEXT NOT NULL DEFAULT 'kiosk',
    public_token TEXT
  );

  CREATE TABLE IF NOT EXISTS order_items (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    order_id TEXT NOT NULL,
    product_id TEXT NOT NULL DEFAULT '',
    name TEXT NOT NULL,
    quantity INTEGER NOT NULL CHECK (quantity > 0),
    unit_price INTEGER NOT NULL DEFAULT 0,
    FOREIGN KEY (order_id) REFERENCES orders(id) ON DELETE CASCADE
  );

  CREATE INDEX IF NOT EXISTS idx_orders_created_at ON orders(created_at);
  CREATE INDEX IF NOT EXISTS idx_order_items_order_id ON order_items(order_id);
SQL

order_columns = DATABASE.execute('PRAGMA table_info(orders)').map { |column| column['name'] }
DATABASE.execute('ALTER TABLE orders ADD COLUMN public_token TEXT') unless order_columns.include?('public_token')
DATABASE.execute('CREATE UNIQUE INDEX IF NOT EXISTS idx_orders_public_token ON orders(public_token)')

STYLES = <<~'CSS'
  :root {
    --ink: #f8fafc;
    --muted: #aab6ca;
    --panel: rgba(14, 23, 42, 0.82);
    --panel-strong: rgba(10, 17, 32, 0.96);
    --line: rgba(255, 255, 255, 0.12);
    --orange: #ff9f43;
    --orange-deep: #f47721;
    --mint: #46e0ad;
    --red: #ff6b7a;
    --shadow: 0 24px 70px rgba(0, 0, 0, 0.35);
  }

  * { box-sizing: border-box; }
  html { min-height: 100%; }
  body {
    min-height: 100vh;
    margin: 0;
    color: var(--ink);
    font-family: Inter, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
    background: #080d1b url('/home.jpeg') center / cover fixed;
  }
  body::before {
    position: fixed;
    inset: 0;
    z-index: -1;
    content: "";
    background: linear-gradient(135deg, rgba(5, 10, 24, 0.94), rgba(18, 30, 55, 0.76) 52%, rgba(5, 10, 24, 0.95));
  }
  a { color: inherit; }
  button, input, select, textarea { font: inherit; }
  button, a { -webkit-tap-highlight-color: transparent; }
  button { cursor: pointer; }
  button:disabled, .disabled { cursor: not-allowed; opacity: 0.48; }
  :focus-visible { outline: 3px solid rgba(255, 159, 67, 0.9); outline-offset: 3px; }

  .topbar {
    position: sticky;
    top: 0;
    z-index: 20;
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 20px;
    min-height: 78px;
    padding: 14px clamp(18px, 4vw, 64px);
    border-bottom: 1px solid var(--line);
    background: rgba(6, 12, 26, 0.78);
    backdrop-filter: blur(20px);
  }
  .brand { display: inline-flex; align-items: center; gap: 12px; min-width: max-content; text-decoration: none; }
  .brand-mark {
    display: grid;
    width: 46px;
    height: 46px;
    place-items: center;
    border-radius: 15px;
    background: linear-gradient(135deg, var(--orange), var(--orange-deep));
    box-shadow: 0 10px 24px rgba(244, 119, 33, 0.3);
    font-size: 24px;
  }
  .brand-copy { display: grid; gap: 2px; }
  .brand-copy strong { letter-spacing: 0.02em; }
  .brand-copy span { color: var(--muted); font-size: 12px; letter-spacing: 0.12em; text-transform: uppercase; }
  .nav-links { display: flex; align-items: center; gap: 6px; flex-wrap: wrap; justify-content: flex-end; }
  .nav-link {
    padding: 10px 14px;
    border: 1px solid transparent;
    border-radius: 12px;
    color: var(--muted);
    text-decoration: none;
    transition: 180ms ease;
  }
  .nav-link:hover, .nav-link.active { border-color: var(--line); color: var(--ink); background: rgba(255, 255, 255, 0.08); }
  .mode-pill, .status-pill, .payment-pill {
    display: inline-flex;
    align-items: center;
    gap: 7px;
    padding: 7px 11px;
    border: 1px solid rgba(70, 224, 173, 0.28);
    border-radius: 999px;
    color: var(--mint);
    background: rgba(70, 224, 173, 0.1);
    font-size: 12px;
    font-weight: 700;
    letter-spacing: 0.06em;
    text-transform: uppercase;
  }
  .status-pill::before, .payment-pill::before, .mode-pill::before { width: 7px; height: 7px; border-radius: 50%; background: currentColor; content: ""; box-shadow: 0 0 12px currentColor; }

  .page-shell { width: min(1440px, 100%); margin: 0 auto; padding: clamp(22px, 4vw, 56px); }
  .flash-stack { display: grid; gap: 10px; margin-bottom: 20px; }
  .flash { padding: 13px 16px; border: 1px solid var(--line); border-radius: 14px; background: var(--panel); box-shadow: var(--shadow); animation: rise 280ms ease both; }
  .flash.success { border-color: rgba(70, 224, 173, 0.35); color: var(--mint); }
  .flash.error { border-color: rgba(255, 107, 122, 0.38); color: #ffabb4; }

  .hero-panel, .panel, .product-card, .cart-panel, .admin-card, .kitchen-panel {
    border: 1px solid var(--line);
    background: var(--panel);
    box-shadow: var(--shadow);
    backdrop-filter: blur(18px);
  }
  .hero-panel { position: relative; overflow: hidden; display: grid; grid-template-columns: minmax(0, 1.5fr) minmax(250px, 0.75fr); gap: 30px; padding: clamp(26px, 5vw, 58px); border-radius: 30px; }
  .hero-panel::after { position: absolute; right: -100px; bottom: -140px; width: 360px; height: 360px; border-radius: 50%; background: radial-gradient(circle, rgba(255, 159, 67, 0.28), transparent 68%); content: ""; pointer-events: none; }
  .eyebrow { display: inline-flex; align-items: center; gap: 9px; margin: 0 0 14px; color: var(--orange); font-size: 12px; font-weight: 800; letter-spacing: 0.14em; text-transform: uppercase; }
  .eyebrow::before { width: 28px; height: 2px; background: currentColor; content: ""; }
  h1, h2, h3, p { margin-top: 0; }
  h1 { max-width: 780px; margin-bottom: 16px; font-size: clamp(2.5rem, 6vw, 5.8rem); line-height: 0.98; letter-spacing: -0.06em; }
  .hero-copy { max-width: 680px; color: var(--muted); font-size: clamp(1rem, 1.5vw, 1.2rem); line-height: 1.65; }
  .hero-actions { display: flex; align-items: center; gap: 12px; flex-wrap: wrap; margin-top: 28px; }
  .hero-note { align-self: end; padding: 20px; border: 1px solid rgba(255, 255, 255, 0.1); border-radius: 22px; background: rgba(255, 255, 255, 0.06); }
  .hero-note strong { display: block; margin-bottom: 8px; font-size: 18px; }
  .hero-note span { color: var(--muted); line-height: 1.5; }
  .hero-metrics { display: grid; grid-template-columns: repeat(3, 1fr); gap: 10px; margin-top: 22px; }
  .metric { padding: 12px; border: 1px solid var(--line); border-radius: 16px; background: rgba(255, 255, 255, 0.05); }
  .metric strong { display: block; font-size: 20px; }
  .metric span { color: var(--muted); font-size: 11px; text-transform: uppercase; letter-spacing: 0.08em; }

  .button, .button-secondary, .button-danger, .button-ghost, .icon-button {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    gap: 8px;
    min-height: 46px;
    padding: 11px 18px;
    border: 1px solid transparent;
    border-radius: 14px;
    color: #111827;
    background: linear-gradient(135deg, var(--orange), var(--orange-deep));
    box-shadow: 0 10px 22px rgba(244, 119, 33, 0.2);
    font-weight: 800;
    text-decoration: none;
    transition: transform 180ms ease, box-shadow 180ms ease, background 180ms ease;
  }
  .button:hover, .icon-button:hover { transform: translateY(-2px); box-shadow: 0 14px 28px rgba(244, 119, 33, 0.3); }
  .button-secondary { color: var(--ink); background: rgba(255, 255, 255, 0.1); border-color: var(--line); box-shadow: none; }
  .button-secondary:hover { background: rgba(255, 255, 255, 0.16); }
  .button-ghost { color: var(--muted); background: transparent; border-color: var(--line); box-shadow: none; }
  .button-ghost:hover { color: var(--ink); background: rgba(255, 255, 255, 0.08); }
  .button-danger { color: #fff; background: linear-gradient(135deg, #e85368, #bd354e); box-shadow: none; }
  .button-small { min-height: 38px; padding: 8px 12px; border-radius: 11px; font-size: 13px; }
  .icon-button { width: 44px; padding: 0; color: var(--ink); background: rgba(255, 255, 255, 0.1); border-color: var(--line); box-shadow: none; }

  .kiosk-toolbar { display: flex; align-items: end; justify-content: space-between; gap: 18px; margin: 34px 0 20px; }
  .section-heading { display: flex; align-items: end; justify-content: space-between; gap: 18px; margin-bottom: 18px; }
  .section-heading h2 { margin-bottom: 4px; font-size: clamp(1.55rem, 3vw, 2.35rem); letter-spacing: -0.04em; }
  .section-heading p { margin-bottom: 0; color: var(--muted); }
  .search-box { position: relative; width: min(360px, 100%); }
  .search-box input { width: 100%; padding: 13px 14px 13px 42px; border: 1px solid var(--line); border-radius: 14px; color: var(--ink); background: rgba(255, 255, 255, 0.08); }
  .search-box span { position: absolute; top: 50%; left: 15px; color: var(--muted); transform: translateY(-50%); }
  .visitor-form { display: flex; align-items: end; gap: 10px; }
  .field { display: grid; gap: 7px; }
  .field label { color: var(--muted); font-size: 12px; font-weight: 700; letter-spacing: 0.06em; text-transform: uppercase; }
  .field input, .field select, .field textarea { width: 100%; border: 1px solid var(--line); border-radius: 13px; color: var(--ink); background: rgba(255, 255, 255, 0.08); padding: 12px 13px; }
  .field textarea { min-height: 92px; resize: vertical; }
  .field input::placeholder, .field textarea::placeholder { color: #7f8ba1; }
  .field-check { display: flex; align-items: center; gap: 9px; color: var(--muted); }
  .field-check input { width: 18px; height: 18px; accent-color: var(--orange); }
  .category-tabs { display: flex; gap: 8px; overflow-x: auto; padding: 2px 2px 10px; scrollbar-width: thin; }
  .category-tab { flex: 0 0 auto; padding: 10px 14px; border: 1px solid var(--line); border-radius: 999px; color: var(--muted); background: rgba(255, 255, 255, 0.05); text-decoration: none; transition: 180ms ease; }
  .category-tab:hover, .category-tab.active { border-color: rgba(255, 159, 67, 0.55); color: #111827; background: var(--orange); }

  .menu-layout { display: grid; grid-template-columns: minmax(0, 1fr) minmax(300px, 390px); gap: 24px; align-items: start; }
  .product-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(220px, 1fr)); gap: 16px; }
  .product-card { position: relative; display: flex; min-height: 270px; flex-direction: column; padding: 20px; border-radius: 22px; overflow: hidden; transition: transform 180ms ease, border-color 180ms ease, box-shadow 180ms ease; }
  .product-card::before { position: absolute; right: -45px; top: -45px; width: 130px; height: 130px; border-radius: 50%; background: radial-gradient(circle, rgba(255, 159, 67, 0.23), transparent 70%); content: ""; }
  .product-card:hover { border-color: rgba(255, 159, 67, 0.45); transform: translateY(-5px); box-shadow: 0 28px 56px rgba(0, 0, 0, 0.42); }
  .product-top { display: flex; align-items: start; justify-content: space-between; gap: 12px; }
  .product-emoji { display: grid; width: 52px; height: 52px; place-items: center; border-radius: 16px; background: linear-gradient(135deg, rgba(255, 159, 67, 0.25), rgba(255, 159, 67, 0.07)); font-size: 27px; }
  .product-price { color: var(--orange); font-size: 20px; font-weight: 900; white-space: nowrap; }
  .product-card h3 { margin: 18px 0 7px; font-size: 20px; letter-spacing: -0.03em; }
  .product-card p { min-height: 45px; margin-bottom: 16px; color: var(--muted); font-size: 14px; line-height: 1.5; }
  .product-meta { display: flex; align-items: center; justify-content: space-between; gap: 8px; margin-top: auto; }
  .category-label { color: var(--muted); font-size: 11px; font-weight: 800; letter-spacing: 0.09em; text-transform: uppercase; }
  .product-add { width: 100%; margin-top: 15px; }
  .quantity-label { color: var(--muted); font-size: 12px; }

  .cart-panel { position: sticky; top: 102px; padding: 22px; border-radius: 24px; }
  .cart-header { display: flex; align-items: start; justify-content: space-between; gap: 12px; margin-bottom: 16px; }
  .cart-header h2 { margin-bottom: 4px; font-size: 24px; letter-spacing: -0.04em; }
  .cart-header p { margin-bottom: 0; color: var(--muted); font-size: 13px; }
  .cart-count { display: grid; min-width: 36px; height: 36px; place-items: center; border-radius: 12px; color: #111827; background: var(--orange); font-weight: 900; }
  .cart-items { display: grid; gap: 10px; max-height: 390px; overflow: auto; padding-right: 3px; }
  .cart-line { display: grid; gap: 9px; padding: 12px; border: 1px solid var(--line); border-radius: 16px; background: rgba(255, 255, 255, 0.05); animation: pop 220ms ease both; }
  .cart-line-main { display: flex; align-items: start; justify-content: space-between; gap: 8px; }
  .cart-line strong { font-size: 14px; }
  .cart-line-price { color: var(--orange); font-size: 14px; font-weight: 800; white-space: nowrap; }
  .cart-line-controls { display: flex; align-items: center; justify-content: space-between; gap: 8px; }
  .quantity-control { display: inline-flex; align-items: center; gap: 8px; }
  .quantity-control button { display: grid; width: 31px; height: 31px; place-items: center; border: 1px solid var(--line); border-radius: 10px; color: var(--ink); background: rgba(255, 255, 255, 0.09); }
  .quantity-control span { min-width: 20px; text-align: center; font-weight: 800; }
  .remove-link { border: 0; color: var(--muted); background: transparent; font-size: 12px; }
  .remove-link:hover { color: var(--red); }
  .empty-cart { display: grid; place-items: center; gap: 8px; min-height: 150px; padding: 20px; border: 1px dashed var(--line); border-radius: 16px; color: var(--muted); text-align: center; }
  .empty-cart strong { color: var(--ink); }
  .cart-footer { display: grid; gap: 12px; margin-top: 18px; padding-top: 18px; border-top: 1px solid var(--line); }
  .total-row { display: flex; align-items: center; justify-content: space-between; gap: 12px; }
  .total-row span { color: var(--muted); }
  .total-row strong { font-size: 25px; letter-spacing: -0.04em; }
  .cart-footer .button { width: 100%; }
  .cart-footer .button-secondary { width: 100%; }

  .page-card { padding: clamp(22px, 4vw, 42px); border-radius: 28px; }
  .page-card h1 { font-size: clamp(2.1rem, 5vw, 4.4rem); }
  .page-card > p { color: var(--muted); line-height: 1.6; }
  .checkout-grid { display: grid; grid-template-columns: minmax(0, 1.1fr) minmax(300px, 0.9fr); gap: 20px; margin-top: 24px; }
  .checkout-list { display: grid; gap: 10px; }
  .checkout-line { display: flex; align-items: center; justify-content: space-between; gap: 12px; padding: 15px; border: 1px solid var(--line); border-radius: 16px; background: rgba(255, 255, 255, 0.05); }
  .checkout-line small { display: block; margin-top: 4px; color: var(--muted); }
  .payment-card { position: relative; overflow: hidden; }
  .payment-card::after { position: absolute; right: -65px; top: -70px; width: 190px; height: 190px; border-radius: 50%; background: radial-gradient(circle, rgba(70, 224, 173, 0.2), transparent 70%); content: ""; pointer-events: none; }
  .payment-options { display: grid; gap: 10px; margin: 20px 0; }
  .payment-option { display: flex; align-items: center; gap: 12px; padding: 14px; border: 1px solid var(--line); border-radius: 16px; background: rgba(255, 255, 255, 0.05); }
  .payment-option input { width: 18px; height: 18px; accent-color: var(--mint); }
  .payment-option strong { display: block; }
  .payment-option span { display: block; margin-top: 3px; color: var(--muted); font-size: 12px; }
  .payment-actions { display: grid; gap: 10px; }
  .demo-note { margin: 18px 0 0; padding: 12px; border-radius: 14px; color: #ffe0b6; background: rgba(255, 159, 67, 0.1); font-size: 13px; line-height: 1.5; }

  .receipt-card { max-width: 780px; margin: 0 auto; text-align: center; }
  .success-mark { display: grid; width: 86px; height: 86px; margin: 0 auto 20px; place-items: center; border-radius: 50%; color: #06251d; background: var(--mint); box-shadow: 0 0 0 12px rgba(70, 224, 173, 0.12), 0 18px 40px rgba(70, 224, 173, 0.28); font-size: 42px; animation: breathe 1.8s ease-in-out infinite; }
  .receipt-id { display: inline-flex; margin-bottom: 20px; padding: 8px 12px; border-radius: 999px; color: var(--mint); background: rgba(70, 224, 173, 0.1); font-size: 13px; font-weight: 800; letter-spacing: 0.1em; }
  .receipt-lines { display: grid; gap: 9px; margin: 24px 0; text-align: left; }
  .receipt-line { display: flex; justify-content: space-between; gap: 12px; padding: 12px 0; border-bottom: 1px solid var(--line); }
  .receipt-total { display: flex; justify-content: space-between; margin-top: 18px; font-size: 24px; font-weight: 900; }
  .receipt-actions { display: flex; justify-content: center; gap: 10px; flex-wrap: wrap; margin-top: 26px; }
  .receipt-qr-layout { display: grid; grid-template-columns: minmax(180px, 240px) minmax(0, 1fr); gap: 24px; align-items: center; margin: 26px 0; text-align: left; }
  .qr-frame { display: grid; padding: 14px; place-items: center; border: 1px solid var(--line); border-radius: 20px; background: #fff; }
  .qr-frame img { display: block; width: min(210px, 100%); height: auto; }
  .qr-copy h2 { margin-bottom: 8px; }
  .qr-copy p { margin-bottom: 14px; color: var(--muted); line-height: 1.55; }
  .status-link { display: inline-flex; overflow-wrap: anywhere; color: var(--mint); font-size: 13px; font-weight: 800; }
  .status-card { width: min(720px, 100%); margin: 5vh auto 0; padding: clamp(22px, 5vw, 44px); text-align: center; }
  .status-card h1 { font-size: clamp(2.2rem, 6vw, 4.8rem); }
  .status-card > p { color: var(--muted); line-height: 1.6; }
  .status-badge { display: inline-flex; align-items: center; gap: 8px; margin: 18px 0; padding: 10px 15px; border: 1px solid rgba(255, 210, 138, 0.3); border-radius: 999px; color: #ffd28a; background: rgba(255, 210, 138, 0.1); font-weight: 900; }
  .status-badge.ready { border-color: rgba(70, 224, 173, 0.35); color: var(--mint); background: rgba(70, 224, 173, 0.1); }
  .status-badge.cancelled { border-color: rgba(255, 107, 122, 0.35); color: #ffabb4; background: rgba(255, 107, 122, 0.1); }
  .status-details { display: grid; gap: 10px; margin: 24px 0; text-align: left; }
  .status-detail-row { display: flex; justify-content: space-between; gap: 12px; padding: 13px 0; border-bottom: 1px solid var(--line); }
  .status-detail-row span { color: var(--muted); }
  .status-detail-row strong { text-align: right; }
  .status-actions { display: flex; justify-content: center; gap: 10px; flex-wrap: wrap; margin-top: 24px; }
  .status-live-note { margin-top: 16px; color: var(--muted); font-size: 12px; }
  .admin-order-panel { overflow: hidden; }
  .accounting-grid { display: grid; grid-template-columns: repeat(4, 1fr); gap: 12px; margin-bottom: 20px; }
  .accounting-card { padding: 18px; border: 1px solid var(--line); border-radius: 18px; background: var(--panel); }
  .accounting-card strong { display: block; font-size: 28px; }
  .accounting-card span { color: var(--muted); font-size: 12px; text-transform: uppercase; letter-spacing: 0.08em; }
  .admin-order-actions { display: flex; align-items: center; gap: 10px; flex-wrap: wrap; }
  .order-table-wrap { overflow-x: auto; }
  .order-table { width: 100%; min-width: 900px; border-collapse: collapse; }
  .order-table th, .order-table td { padding: 14px 16px; border-bottom: 1px solid var(--line); text-align: left; vertical-align: top; }
  .order-table th { color: var(--muted); font-size: 11px; letter-spacing: 0.1em; text-transform: uppercase; }
  .order-table tr:last-child td { border-bottom: 0; }
  .order-table .order-items { color: var(--muted); font-size: 13px; line-height: 1.5; }
  .reset-panel { display: flex; align-items: center; justify-content: space-between; gap: 16px; margin-top: 20px; padding: 20px; border: 1px solid rgba(255, 107, 122, 0.25); border-radius: 20px; background: rgba(255, 107, 122, 0.06); }
  .reset-panel h2 { margin-bottom: 5px; }
  .reset-panel p { margin-bottom: 0; color: var(--muted); line-height: 1.5; }

  .auth-card { width: min(500px, 100%); margin: 5vh auto 0; padding: clamp(24px, 5vw, 44px); }
  .auth-card h1 { font-size: clamp(2rem, 5vw, 3.5rem); }
  .auth-form { display: grid; gap: 16px; margin-top: 24px; }
  .auth-form .button { width: 100%; margin-top: 6px; }

  .admin-header { display: flex; align-items: end; justify-content: space-between; gap: 20px; margin-bottom: 24px; }
  .admin-header h1 { margin-bottom: 8px; font-size: clamp(2rem, 5vw, 4rem); }
  .admin-header p { margin-bottom: 0; color: var(--muted); }
  .stats-grid { display: grid; grid-template-columns: repeat(3, 1fr); gap: 12px; margin-bottom: 20px; }
  .stat-card { padding: 18px; border: 1px solid var(--line); border-radius: 18px; background: var(--panel); }
  .stat-card strong { display: block; font-size: 28px; }
  .stat-card span { color: var(--muted); font-size: 12px; text-transform: uppercase; letter-spacing: 0.08em; }
  .admin-layout { display: grid; grid-template-columns: minmax(270px, 0.65fr) minmax(0, 1.35fr); gap: 20px; align-items: start; }
  .admin-card { padding: 22px; border-radius: 24px; }
  .admin-card h2 { margin-bottom: 6px; font-size: 24px; letter-spacing: -0.04em; }
  .admin-card > p { color: var(--muted); line-height: 1.5; }
  .form-grid { display: grid; gap: 14px; margin-top: 20px; }
  .form-grid.two { grid-template-columns: 1fr 1fr; }
  .form-actions { display: flex; gap: 10px; flex-wrap: wrap; }
  .inventory-list { display: grid; gap: 14px; }
  .inventory-item { padding: 18px; border: 1px solid var(--line); border-radius: 19px; background: rgba(255, 255, 255, 0.04); }
  .inventory-item.unavailable { opacity: 0.68; }
  .inventory-top { display: flex; align-items: start; justify-content: space-between; gap: 12px; margin-bottom: 12px; }
  .inventory-top h3 { margin-bottom: 4px; }
  .inventory-top p { margin-bottom: 0; color: var(--muted); font-size: 13px; }
  .inventory-item .form-grid { margin-top: 0; }
  .inventory-actions { display: flex; align-items: center; justify-content: space-between; gap: 12px; flex-wrap: wrap; margin-top: 14px; }
  .available-label { display: inline-flex; align-items: center; gap: 8px; color: var(--muted); font-size: 13px; }

  .kitchen-panel { overflow: hidden; border-radius: 26px; }
  .kitchen-head { display: flex; align-items: center; justify-content: space-between; gap: 16px; padding: 22px; border-bottom: 1px solid var(--line); }
  .kitchen-head h1 { margin-bottom: 5px; font-size: clamp(1.8rem, 4vw, 3rem); }
  .kitchen-head p { margin-bottom: 0; color: var(--muted); }
  .kitchen-table-wrap { overflow-x: auto; }
  .kitchen-table { width: 100%; border-collapse: collapse; min-width: 720px; }
  .kitchen-table th, .kitchen-table td { padding: 16px 20px; border-bottom: 1px solid var(--line); text-align: left; vertical-align: top; }
  .kitchen-table th { color: var(--muted); font-size: 11px; letter-spacing: 0.1em; text-transform: uppercase; }
  .kitchen-table td { font-size: 14px; }
  .kitchen-table tr:last-child td { border-bottom: 0; }
  .order-number { color: var(--orange); font-weight: 900; letter-spacing: 0.06em; }
  .kitchen-items { display: grid; gap: 5px; }
  .kitchen-empty { padding: 55px 22px; color: var(--muted); text-align: center; }
  .kitchen-empty strong { display: block; margin-bottom: 7px; color: var(--ink); font-size: 20px; }
  .payment-pill.pending { color: #ffd28a; border-color: rgba(255, 210, 138, 0.3); background: rgba(255, 210, 138, 0.1); }
  .payment-pill.failed { color: #ffabb4; border-color: rgba(255, 107, 122, 0.3); background: rgba(255, 107, 122, 0.1); }

  .reveal { animation: rise 560ms cubic-bezier(0.2, 0.8, 0.2, 1) both; animation-delay: calc(var(--i, 0) * 55ms); }
  .toast { position: fixed; right: 22px; bottom: 22px; z-index: 50; max-width: min(360px, calc(100vw - 44px)); padding: 14px 17px; border: 1px solid rgba(70, 224, 173, 0.35); border-radius: 14px; color: var(--ink); background: var(--panel-strong); box-shadow: var(--shadow); opacity: 0; pointer-events: none; transform: translateY(12px); transition: 220ms ease; }
  .toast.show { opacity: 1; transform: translateY(0); }
  .toast.error { border-color: rgba(255, 107, 122, 0.45); }
  .is-loading { opacity: 0.6; pointer-events: none; }

  @keyframes rise { from { opacity: 0; transform: translateY(16px); } to { opacity: 1; transform: translateY(0); } }
  @keyframes pop { from { opacity: 0; transform: scale(0.96); } to { opacity: 1; transform: scale(1); } }
  @keyframes breathe { 0%, 100% { transform: scale(1); } 50% { transform: scale(1.05); } }
  @media (prefers-reduced-motion: reduce) { *, *::before, *::after { scroll-behavior: auto !important; animation-duration: 1ms !important; transition-duration: 1ms !important; } }
  @media (max-width: 980px) {
    .hero-panel, .checkout-grid, .admin-layout { grid-template-columns: 1fr; }
    .menu-layout { grid-template-columns: 1fr; }
    .cart-panel { position: static; }
    .hero-note { max-width: 480px; }
  }
  @media (max-width: 700px) {
    .topbar { align-items: start; flex-direction: column; gap: 12px; }
    .nav-links { justify-content: flex-start; }
    .hero-panel { padding: 25px 20px; border-radius: 24px; }
    .kiosk-toolbar, .section-heading, .admin-header, .kitchen-head { align-items: stretch; flex-direction: column; }
    .search-box { width: 100%; }
    .visitor-form { align-items: stretch; flex-direction: column; }
    .visitor-form .button { width: 100%; }
    .product-grid { grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 10px; }
    .product-card { min-height: 245px; padding: 15px; border-radius: 18px; }
    .product-card h3 { font-size: 16px; }
    .product-card p { font-size: 12px; }
    .product-emoji { width: 44px; height: 44px; font-size: 22px; }
    .product-price { font-size: 16px; }
    .form-grid.two, .stats-grid, .accounting-grid { grid-template-columns: 1fr; }
    .receipt-actions .button, .status-actions .button { width: 100%; }
    .receipt-qr-layout { grid-template-columns: 1fr; justify-items: center; text-align: center; }
    .qr-copy .button { width: 100%; }
    .reset-panel { align-items: stretch; flex-direction: column; }
    .reset-panel .button { width: 100%; }
  }
CSS

CLIENT_SCRIPT = <<~'JS'
  (() => {
    const toast = document.getElementById('toast');
    const showToast = (message, error = false) => {
      if (!toast || !message) return;
      toast.textContent = message;
      toast.classList.toggle('error', error);
      toast.classList.add('show');
      window.clearTimeout(window.__toastTimer);
      window.__toastTimer = window.setTimeout(() => toast.classList.remove('show'), 2800);
    };

    const updateCart = (data) => {
      const items = document.getElementById('cart-items');
      const count = document.getElementById('cart-count');
      const total = document.getElementById('cart-total');
      const checkout = document.getElementById('checkout-button');
      if (items && data.cart_html) items.innerHTML = data.cart_html;
      if (count && typeof data.count === 'number') count.textContent = data.count;
      if (total && typeof data.total === 'string') total.textContent = data.total;
      if (checkout) {
        const empty = data.count === 0;
        checkout.classList.toggle('disabled', empty);
        checkout.setAttribute('aria-disabled', empty ? 'true' : 'false');
        checkout.style.pointerEvents = empty ? 'none' : '';
      }
    };

    document.addEventListener('submit', async (event) => {
      const form = event.target.closest('[data-cart-form]');
      if (!form) return;
      event.preventDefault();
      const submitter = event.submitter;
      const data = new FormData(form);
      if (submitter && submitter.name) data.set(submitter.name, submitter.value);
      data.set('format', 'json');
      form.classList.add('is-loading');
      try {
        const response = await fetch('/kiosk/cart', {
          method: 'POST',
          body: data,
          headers: { 'Accept': 'application/json', 'X-Requested-With': 'fetch' }
        });
        const result = await response.json();
        if (!response.ok) throw new Error(result.message || 'Unable to update the cart');
        updateCart(result);
        showToast(result.message || 'Cart updated');
      } catch (error) {
        showToast(error.message || 'Unable to update the cart', true);
      } finally {
        form.classList.remove('is-loading');
      }
    });

    const search = document.getElementById('menu-search');
    const cards = Array.from(document.querySelectorAll('[data-product-card]'));
    const noProducts = document.getElementById('no-products');
    const filterProducts = () => {
      const query = (search?.value || '').trim().toLowerCase();
      cards.forEach((card) => {
        card.hidden = Boolean(query) && !card.dataset.search.includes(query);
      });
      if (noProducts) noProducts.hidden = cards.some((card) => !card.hidden);
    };
    search?.addEventListener('input', filterProducts);
    filterProducts();

    document.querySelectorAll('form[data-confirm]').forEach((form) => {
      form.addEventListener('submit', (event) => {
        if (!window.confirm(form.dataset.confirm || 'Are you sure?')) event.preventDefault();
      });
    });

    document.querySelectorAll('[data-payment-form]').forEach((form) => {
      form.addEventListener('submit', () => {
        form.classList.add('is-loading');
        const button = form.querySelector('button[type="submit"]');
        if (button) button.textContent = 'Processing…';
      });
    });

    document.querySelectorAll('[data-print]').forEach((button) => {
      button.addEventListener('click', () => window.print());
    });

    const orderStatusPage = document.querySelector('[data-order-status-page]');
    if (orderStatusPage) {
      const token = orderStatusPage.dataset.orderToken;
      const statusBadge = document.getElementById('order-status-badge');
      const statusMessage = document.getElementById('order-status-message');
      const alertButton = document.getElementById('order-alert-button');
      let lastStatus = orderStatusPage.dataset.initialStatus || '';
      let audioContext = null;

      const playReadyAlert = () => {
        const AudioContextClass = window.AudioContext || window.webkitAudioContext;
        if (!AudioContextClass) return;
        audioContext ||= new AudioContextClass();
        audioContext.resume();
        const oscillator = audioContext.createOscillator();
        const gain = audioContext.createGain();
        oscillator.type = 'sine';
        oscillator.frequency.setValueAtTime(740, audioContext.currentTime);
        oscillator.frequency.exponentialRampToValueAtTime(1040, audioContext.currentTime + 0.22);
        gain.gain.setValueAtTime(0.0001, audioContext.currentTime);
        gain.gain.exponentialRampToValueAtTime(0.22, audioContext.currentTime + 0.03);
        gain.gain.exponentialRampToValueAtTime(0.0001, audioContext.currentTime + 0.55);
        oscillator.connect(gain);
        gain.connect(audioContext.destination);
        oscillator.start();
        oscillator.stop(audioContext.currentTime + 0.58);
      };

      const enableAlerts = async () => {
        const AudioContextClass = window.AudioContext || window.webkitAudioContext;
        if (AudioContextClass) {
          audioContext ||= new AudioContextClass();
          await audioContext.resume();
        }
        if ('Notification' in window && Notification.permission === 'default') await Notification.requestPermission();
        if (alertButton) {
          const enabled = 'Notification' in window && Notification.permission === 'granted';
          alertButton.textContent = enabled ? 'Alerts enabled' : 'Alerts unavailable in this browser';
          alertButton.disabled = !enabled && !AudioContextClass;
        }
      };

      const updateOrderStatus = (data) => {
        const nextStatus = data.status || '';
        if (statusBadge) {
          statusBadge.textContent = data.status_label || nextStatus;
          statusBadge.className = `status-badge ${nextStatus}`;
        }
        if (statusMessage) statusMessage.textContent = data.message || 'We will update this page when the kitchen marks your order ready.';
        if (nextStatus === 'ready' && lastStatus !== 'ready') {
          playReadyAlert();
          showToast('Your order is ready for pickup!', false);
          if ('Notification' in window && Notification.permission === 'granted') new Notification('Mila\'s Restaurant', { body: `Order ${data.code || ''} is ready for pickup.` });
        }
        lastStatus = nextStatus;
      };

      const pollOrderStatus = async () => {
        if (!token) return;
        try {
          const response = await fetch(`/api/orders/${encodeURIComponent(token)}/status`, { headers: { 'Accept': 'application/json' } });
          if (response.ok) updateOrderStatus(await response.json());
        } catch (error) {
          return;
        }
      };

      alertButton?.addEventListener('click', enableAlerts);
      window.setInterval(pollOrderStatus, 5000);
      pollOrderStatus();
    }
  })();
JS

helpers do
  def h(value)
    Rack::Utils.escape_html(value.to_s)
  end

  def money(amount)
    "₹#{format('%.2f', amount.to_f)}"
  end

  def query_value(value)
    URI.encode_www_form_component(value.to_s)
  end

  def database
    DATABASE
  end

  def read_json(path)
    return nil unless File.exist?(path)
    JSON.parse(File.read(path))
  rescue JSON::ParserError, Errno::EACCES, Errno::ENOENT
    nil
  end

  def write_json(path, value)
    FileUtils.mkdir_p(File.dirname(path))
    temporary = "#{path}.tmp-#{Process.pid}-#{SecureRandom.hex(4)}"
    File.write(temporary, JSON.pretty_generate(value))
    FileUtils.mv(temporary, path, force: true)
  ensure
    File.delete(temporary) if temporary && File.exist?(temporary)
  end

  def read_order_records
    data = read_json(ORDER_RECORDS_FILE)
    data.is_a?(Array) ? data : []
  end

  def order_record(order)
    placed_at = order['created_at'].to_s
    {
      'code' => order['id'].to_s,
      'order_code' => order['id'].to_s,
      'public_token' => order['public_token'].to_s,
      'placed_at' => placed_at,
      'date' => placed_at[0, 10],
      'time' => placed_at[11, 8],
      'customer' => order['name'].to_s.empty? ? 'Guest' : order['name'].to_s,
      'items' => order_lines(order).map { |line| { 'name' => line['name'], 'quantity' => line['quantity'].to_i, 'unit_price' => line['unit_price'].to_i } },
      'total' => order_total(order).to_i,
      'currency' => 'INR',
      'status' => order_status(order),
      'payment' => { 'method' => order_payment_method(order), 'status' => order_payment_status(order) },
      'ready_at' => hash_value(order, 'completed_at', nil)
    }.compact
  end

  def sync_order_records
    write_json(ORDER_RECORDS_FILE, read_orders.map { |order| order_record(order) })
  end

  def initialize_order_records!
    return if database_meta('order_records_initialized') == ORDER_RECORDS_VERSION && File.exist?(ORDER_RECORDS_FILE)
    sync_order_records
    set_database_meta('order_records_initialized', ORDER_RECORDS_VERSION)
  end

  def database_meta(key)
    database.get_first_value('SELECT value FROM app_meta WHERE key = ?', [key])
  end

  def set_database_meta(key, value = Time.now.utc.iso8601)
    database.execute('INSERT OR REPLACE INTO app_meta (key, value) VALUES (?, ?)', [key, value])
  end

  def boolean_value(value)
    value == true || %w[1 true yes].include?(value.to_s.downcase)
  end

  def product_record_values(product)
    source = product.respond_to?(:[]) ? product : {}
    name = hash_value(source, 'name', '').to_s.strip
    id = hash_value(source, 'id', '').to_s.strip
    if id.empty?
      id = name.downcase.gsub(/[^a-z0-9]+/, '-').sub(/\A-+|-+\z/, '')
      id = "product-#{SecureRandom.hex(4)}" if id.empty?
    end
    category = hash_value(source, 'category', 'General').to_s.strip
    category = 'General' if category.empty?
    now = Time.now.utc.iso8601
    [id, name, hash_value(source, 'price', 0).to_i, category, hash_value(source, 'description', '').to_s, boolean_value(hash_value(source, 'available', true)) ? 1 : 0, now, now]
  end

  def insert_product(product)
    values = product_record_values(product)
    return if values[1].empty? || values[2] < 1
    database.execute(<<~SQL, values)
      INSERT INTO products (id, name, price, category, description, available, created_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET
        name = excluded.name,
        price = excluded.price,
        category = excluded.category,
        description = excluded.description,
        available = excluded.available,
        updated_at = excluded.updated_at
    SQL
  end

  def legacy_order_records
    paths = [LEGACY_ORDERS_FILE]
    paths << File.join(APP_ROOT, 'order_placed') unless ENV['ORDERS_FILE']
    paths.flat_map do |path|
      data = read_json(path)
      data.is_a?(Array) ? data : []
    end
  end

  def unique_order_token
    loop do
      token = SecureRandom.hex(16)
      return token unless database.get_first_value('SELECT 1 FROM orders WHERE public_token = ?', [token])
    end
  end

  def ensure_order_tokens!
    rows = database.execute("SELECT id FROM orders WHERE public_token IS NULL OR public_token = ''")
    return if rows.empty?
    database.transaction do
      rows.each do |row|
        database.execute('UPDATE orders SET public_token = ? WHERE id = ?', [unique_order_token, row['id']])
      end
    end
  end

  def initialize_database!
    ensure_order_tokens!
    unless database_meta('products_initialized') && database_meta('orders_initialized')
      database.transaction do
        unless database_meta('products_initialized')
          legacy_products = read_json(LEGACY_PRODUCTS_FILE)
          source_products = legacy_products.is_a?(Array) && !legacy_products.empty? ? legacy_products : DEFAULT_PRODUCTS
          source_products.each { |product| insert_product(product) if product.is_a?(Hash) }
          set_database_meta('products_initialized')
        end
        unless database_meta('orders_initialized')
          legacy_order_records.each_with_index { |order, index| import_legacy_order(order, index) }
          set_database_meta('orders_initialized')
        end
      end
    end
    initialize_order_records!
  end

  def import_legacy_order(order, index)
    return unless order.is_a?(Hash)
    identifier = hash_value(order, 'id', '').to_s
    identifier = "legacy-#{index + 1}" if identifier.empty?
    identifier = "#{identifier}-#{index + 1}" if database.get_first_value('SELECT 1 FROM orders WHERE id = ?', [identifier])
    insert_order(order, identifier)
  end

  def products
    database.execute(<<~SQL).map do |row|
      SELECT id, name, price, category, description, available
      FROM products
      ORDER BY rowid ASC
    SQL
      {
        'id' => row['id'],
        'name' => row['name'],
        'price' => row['price'].to_i,
        'category' => row['category'],
        'description' => row['description'],
        'available' => row['available'].to_i == 1
      }
    end
  end

  def write_products(value)
    database.transaction do
      value.each { |product| insert_product(product) }
    end
  end

  def available_products
    products.select { |product| product['available'] != false }
  end

  def find_product(id)
    products.find { |product| product['id'].to_s == id.to_s }
  end

  def order_items_for(order_id)
    database.execute(<<~SQL, [order_id]).map do |row|
      SELECT product_id, name, quantity, unit_price
      FROM order_items
      WHERE order_id = ?
      ORDER BY id ASC
    SQL
      {
        'product_id' => row['product_id'],
        'name' => row['name'],
        'quantity' => row['quantity'].to_i,
        'unit_price' => row['unit_price'].to_i
      }
    end
  end

  def read_orders
    database.execute(<<~SQL).map do |row|
      SELECT id, name, total, status, payment_method, payment_status, payment_reference, created_at, completed_at, source, public_token
      FROM orders
      ORDER BY rowid ASC
    SQL
      order = {
        'id' => row['id'],
        'name' => row['name'],
        'items' => order_items_for(row['id']),
        'total' => row['total'].to_i,
        'status' => row['status'],
        'payment' => {
          'method' => row['payment_method'],
          'status' => row['payment_status'],
          'reference' => row['payment_reference']
        },
        'created_at' => row['created_at'],
        'source' => row['source'],
        'public_token' => row['public_token']
      }
      order['completed_at'] = row['completed_at'] if row['completed_at']
      order
    end
  end

  def find_order_by_token(token)
    read_orders.find { |order| order['public_token'].to_s == token.to_s }
  end

  def insert_order(order, identifier = nil)
    values = order_record_values(order, identifier)
    database.execute(<<~SQL, values)
      INSERT OR IGNORE INTO orders (id, name, total, status, payment_method, payment_status, payment_reference, created_at, completed_at, source, public_token)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    SQL
    return false unless database.changes == 1
    order_lines(order).each do |line|
      database.execute(<<~SQL, [values[0], line['product_id'].to_s, line['name'].to_s, line['quantity'].to_i, line['unit_price'].to_i])
        INSERT INTO order_items (order_id, product_id, name, quantity, unit_price)
        VALUES (?, ?, ?, ?, ?)
      SQL
    end
    true
  end

  def order_record_values(order, identifier = nil)
    id = (identifier || hash_value(order, 'id', '')).to_s
    id = "order-#{SecureRandom.hex(6)}" if id.empty?
    public_token = hash_value(order, 'public_token', '').to_s
    public_token = unique_order_token if public_token.empty?
    payment = hash_value(order, 'payment', {})
    payment = {} unless payment.is_a?(Hash)
    name = hash_value(order, 'name', 'Guest').to_s
    name = 'Guest' if name.empty?
    [id, name, order_total(order).to_i, order_status(order), order_payment_method(order), order_payment_status(order), hash_value(payment, 'reference', '').to_s, hash_value(order, 'created_at', Time.now.utc.iso8601).to_s, hash_value(order, 'completed_at', nil), hash_value(order, 'source', 'kiosk').to_s, public_token]
  end

  def append_order(order)
    inserted = database.transaction { insert_order(order) }
    sync_order_records if inserted
    inserted
  end

  def complete_order(identifier)
    completed = false
    database.transaction do
      row = database.get_first_row('SELECT id FROM orders WHERE id = ? LIMIT 1', [identifier.to_s])
      if row
        database.execute("UPDATE orders SET status = 'ready', completed_at = ? WHERE id = ? AND status NOT IN ('ready', 'completed')", [Time.now.utc.iso8601, identifier.to_s])
        completed = database.changes == 1
      end
    end
    sync_order_records if completed
    completed
  end

  def reset_order_history!
    database.transaction { database.execute('DELETE FROM orders') }
    sync_order_records
  end

  def hash_value(hash, key, default = nil)
    return default unless hash.respond_to?(:key?)
    return hash[key] if hash.key?(key)
    symbol = key.to_sym
    return hash[symbol] if hash.key?(symbol)
    default
  end

  def product_price(name)
    product = products.find { |item| item['name'].to_s.casecmp?(name.to_s) }
    product ? product['price'].to_i : 0
  end

  def order_lines(order)
    if order['items'].is_a?(Array)
      order['items'].map do |item|
        quantity = hash_value(item, 'quantity', 0).to_i
        next unless quantity > 0
        { 'product_id' => hash_value(item, 'product_id', '').to_s, 'name' => hash_value(item, 'name', 'Item').to_s, 'quantity' => quantity, 'unit_price' => hash_value(item, 'unit_price', 0).to_i }
      end.compact
    elsif order['dishes'].is_a?(Hash)
      order['dishes'].map do |name, data|
        quantity = data.is_a?(Hash) ? hash_value(data, 'qty', 1).to_i : data.to_i
        next unless quantity > 0
        unit_price = data.is_a?(Hash) ? hash_value(data, 'price', nil) : nil
        { 'product_id' => data.is_a?(Hash) ? hash_value(data, 'product_id', '').to_s : '', 'name' => name.to_s, 'quantity' => quantity, 'unit_price' => unit_price.nil? ? product_price(name) : unit_price.to_i }
      end.compact
    else
      []
    end
  end

  def order_total(order)
    stored_total = hash_value(order, 'total', nil)
    return stored_total.to_i unless stored_total.nil?
    order_lines(order).sum { |line| line['quantity'].to_i * line['unit_price'].to_i }
  end

  def order_reference(order, index)
    order['id'] || order['order_id'] || "legacy-#{index}"
  end

  def order_status(order)
    status = hash_value(order, 'status', 'pending').to_s.downcase
    %w[completed ready].include?(status) ? 'ready' : status
  end

  def order_ready?(order)
    order_status(order) == 'ready'
  end

  def order_paid?(order)
    %w[approved paid successful].include?(order_payment_status(order).downcase)
  end

  def order_status_label(order)
    case order_status(order)
    when 'ready' then 'Ready for pickup'
    when 'paid' then 'In the kitchen'
    when 'pending' then 'Waiting for payment'
    when 'cancelled' then 'Cancelled'
    else order_status(order).capitalize
    end
  end

  def format_order_time(value)
    Time.parse(value.to_s).localtime.strftime('%d %b %Y, %I:%M %p')
  rescue ArgumentError, TypeError
    value.to_s
  end

  def public_base_url
    configured = ENV['PUBLIC_BASE_URL'].to_s.sub(%r{/$}, '')
    configured.empty? ? request.base_url : configured
  end

  def order_public_token(order)
    token = order['public_token'].to_s
    return token unless token.empty?
    return '' if order['id'].to_s.empty?
    token = unique_order_token
    database.execute('UPDATE orders SET public_token = ? WHERE id = ?', [token, order['id']])
    token
  end

  def order_status_url(order)
    token = order_public_token(order)
    "#{public_base_url}/orders/#{URI.encode_www_form_component(token)}"
  end

  def order_qr_svg(order)
    RQRCode::QRCode.new(order_status_url(order), level: :m).as_svg(module_size: 8, offset: 4, color: '111827', fill: 'ffffff', use_path: true)
  end

  def order_payment_status(order)
    payment = hash_value(order, 'payment', {})
    payment.is_a?(Hash) ? hash_value(payment, 'status', 'pending').to_s : 'pending'
  end

  def order_payment_method(order)
    payment = hash_value(order, 'payment', {})
    payment.is_a?(Hash) ? hash_value(payment, 'method', 'simulated').to_s : 'simulated'
  end

  def kiosk_cart
    value = session[:kiosk_cart]
    value.is_a?(Hash) ? value : {}
  end

  def set_kiosk_cart(value)
    session[:kiosk_cart] = value
  end

  def cart_items
    kiosk_cart.each_with_object([]) do |(id, quantity), result|
      product = find_product(id)
      next unless product && product['available'] != false
      count = quantity.to_i.clamp(1, 20)
      next unless count.positive?
      result << { product: product, quantity: count }
    end
  end

  def cart_quantity(id)
    kiosk_cart[id.to_s].to_i
  end

  def cart_count
    cart_items.sum { |item| item[:quantity].to_i }
  end

  def cart_total
    cart_items.sum { |item| item[:quantity].to_i * item[:product]['price'].to_i }
  end

  def payment_token
    session[:kiosk_payment_token] ||= SecureRandom.hex(18)
  end

  def csrf_token
    session[:csrf_token] ||= SecureRandom.hex(32)
  end

  def csrf_field
    %(<input type="hidden" name="csrf_token" value="#{h(csrf_token)}">)
  end

  def csrf_valid?
    expected = session[:csrf_token].to_s
    actual = params['csrf_token'].to_s
    expected.length.positive? && expected.length == actual.length && Rack::Utils.secure_compare(expected, actual)
  end

  def require_csrf!
    halt 403, 'Invalid request token' unless csrf_valid?
  end

  def json_request?
    request.xhr? || params['format'].to_s == 'json'
  end

  def admin_configured?
    !ENV['ADMIN_PASSWORD'].to_s.empty?
  end

  def admin_logged_in?
    session[:admin] == true
  end

  def admin_required!
    redirect '/admin/login' unless admin_logged_in?
  end

  def secure_equal?(actual, expected)
    return false unless actual.is_a?(String) && expected.is_a?(String)
    return false unless actual.bytesize == expected.bytesize
    Rack::Utils.secure_compare(actual, expected)
  rescue NoMethodError
    false
  end

  def flash_messages
    messages = []
    notice = session.delete(:notice)
    error = session.delete(:error)
    messages << { type: 'success', text: notice } unless notice.to_s.empty?
    messages << { type: 'error', text: error } unless error.to_s.empty?
    messages
  end

  def flash_html
    flash_messages.map { |message| %(<div class="flash #{message[:type]}">#{h(message[:text])}</div>) }.join
  end

  def page_shell(title, content, active = 'kiosk')
    nav_class = lambda do |key|
      active == key ? 'nav-link active' : 'nav-link'
    end
    account_html = if admin_logged_in?
                     %(<form method="post" action="/admin/logout" class="logout-form">#{csrf_field}<button class="button-ghost button-small" type="submit">Sign out</button></form>)
                   else
                     %(<a class="#{nav_class.call('admin')}" href="/admin/login">Admin</a>)
                   end
    orders_html = if admin_logged_in?
                    %(<a class="#{nav_class.call('orders')}" href="/admin/orders">Orders</a>)
                  else
                    ''
                  end
    <<~HTML
      <!doctype html>
      <html lang="en">
      <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="theme-color" content="#080d1b">
        <title>#{h(title)} · Mila's Restaurant</title>
        <style>#{STYLES}</style>
      </head>
      <body>
        <header class="topbar">
          <a class="brand" href="/kiosk" aria-label="Mila's Restaurant kiosk home">
            <span class="brand-mark">✦</span>
            <span class="brand-copy"><strong>Mila's Restaurant</strong><span>Self-order kiosk</span></span>
          </a>
          <nav class="nav-links" aria-label="Primary navigation">
            <span class="mode-pill">Kiosk mode</span>
            <a class="#{nav_class.call('kiosk')}" href="/kiosk">Order</a>
            <a class="#{nav_class.call('kitchen')}" href="/kitchen">Kitchen</a>
            #{orders_html}
            #{account_html}
          </nav>
        </header>
        <main class="page-shell">
          <div class="flash-stack">#{flash_html}</div>
          #{content}
        </main>
        <div id="toast" class="toast" role="status" aria-live="polite"></div>
        <script>#{CLIENT_SCRIPT}</script>
      </body>
      </html>
    HTML
  end

  def cart_line_html(item)
    product = item[:product]
    id = h(product['id'])
    quantity = item[:quantity]
    price = quantity * product['price'].to_i
    <<~HTML
      <div class="cart-line" data-line-id="#{id}">
        <div class="cart-line-main">
          <strong>#{h(product['name'])}</strong>
          <span class="cart-line-price">#{money(price)}</span>
        </div>
        <div class="cart-line-controls">
          <form class="quantity-control" method="post" action="/kiosk/cart" data-cart-form>
            #{csrf_field}
            <input type="hidden" name="product_id" value="#{id}">
            <input type="hidden" name="action" value="adjust">
            <button type="submit" name="delta" value="-1" aria-label="Decrease #{h(product['name'])}">−</button>
            <span>#{quantity}</span>
            <button type="submit" name="delta" value="1" aria-label="Increase #{h(product['name'])}">+</button>
          </form>
          <form method="post" action="/kiosk/cart" data-cart-form>
            #{csrf_field}
            <input type="hidden" name="product_id" value="#{id}">
            <input type="hidden" name="action" value="remove">
            <button class="remove-link" type="submit">Remove</button>
          </form>
        </div>
      </div>
    HTML
  end

  def cart_html
    items = cart_items
    return %(<div class="empty-cart" id="empty-cart"><span>🛒</span><strong>Your order is empty</strong><span>Tap a menu item to get started.</span></div>) if items.empty?
    items.map { |item| cart_line_html(item) }.join
  end

  def product_card(product, index)
    quantity = cart_quantity(product['id'])
    search_text = [product['name'], product['description'], product['category']].join(' ').downcase
    <<~HTML
      <article class="product-card reveal" style="--i: #{index + 2}" data-product-card data-category="#{h(product['category'])}" data-search="#{h(search_text)}">
        <div class="product-top"><span class="product-emoji" aria-hidden="true">#{product['category'].to_s == 'Seafood' ? '🐟' : product['category'].to_s == 'Chicken' ? '🍗' : product['category'].to_s == 'Starters' ? '🥣' : '🥗'}</span><span class="product-price">#{money(product['price'])}</span></div>
        <h3>#{h(product['name'])}</h3>
        <p>#{h(product['description'])}</p>
        <div class="product-meta"><span class="category-label">#{h(product['category'])}</span><span class="quantity-label">#{quantity.positive? ? "#{quantity} in order" : 'Ready to order'}</span></div>
        <form class="cart-form product-add" method="post" action="/kiosk/cart" data-cart-form>
          #{csrf_field}
          <input type="hidden" name="product_id" value="#{h(product['id'])}">
          <input type="hidden" name="action" value="add">
          <button class="button" type="submit">Add to order <span aria-hidden="true">＋</span></button>
        </form>
      </article>
    HTML
  end

  def checkout_lines_html
    cart_items.map do |item|
      product = item[:product]
      <<~HTML
        <div class="checkout-line"><div><strong>#{h(product['name'])}</strong><small>#{item[:quantity]} × #{money(product['price'])}</small></div><strong>#{money(item[:quantity] * product['price'].to_i)}</strong></div>
      HTML
    end.join
  end

  def order_items_html(order)
    lines = order_lines(order)
    return '<span class="muted">No items recorded</span>' if lines.empty?
    lines.map { |line| %(<div><strong>#{h(line['name'])}</strong> × #{line['quantity'].to_i} <span class="muted">· #{money(line['unit_price'])} each</span></div>) }.join
  end

  def render_kiosk
    selected_category = params['category'].to_s
    search_query = params['q'].to_s.strip
    all_products = available_products
    categories = ['All'] + all_products.map { |product| product['category'].to_s }.reject(&:empty?).uniq
    display_products = if selected_category.empty? || selected_category == 'All'
                         all_products
                       else
                         all_products.select { |product| product['category'].to_s == selected_category }
                       end
    display_products = display_products.select { |product| [product['name'], product['description'], product['category']].join(' ').downcase.include?(search_query.downcase) } unless search_query.empty?
    category_tabs = categories.map do |category|
      active = category == selected_category || (selected_category.empty? && category == 'All')
      href = category == 'All' ? '/kiosk' : "/kiosk?category=#{query_value(category)}"
      %(<a class="category-tab #{active ? 'active' : ''}" href="#{href}">#{h(category)}</a>)
    end.join
    customer_name = session[:kiosk_name].to_s
    total = cart_total
    count = cart_count
    content = <<~HTML
      <section class="hero-panel reveal" style="--i: 0">
        <div>
          <p class="eyebrow">Fast, friendly, contactless</p>
          <h1>Tap. Order. Enjoy.</h1>
          <p class="hero-copy">Welcome to Mila's self-order kiosk. Browse the menu, customize your order, and check out in a few taps.</p>
          <div class="hero-actions">
            <a class="button" href="#menu">Start ordering <span aria-hidden="true">↓</span></a>
            <a class="button-secondary" href="/kiosk/checkout">Review order</a>
          </div>
        </div>
        <div class="hero-note">
          <strong>Made for quick service</strong>
          <span>Use the name field if you would like your order labeled. Everything else is optional.</span>
          <div class="hero-metrics"><div class="metric"><strong>#{all_products.length}</strong><span>Menu items</span></div><div class="metric"><strong>₹</strong><span>Secure totals</span></div><div class="metric"><strong>24/7</strong><span>Demo service</span></div></div>
        </div>
      </section>
      <section id="menu" class="kiosk-toolbar reveal" style="--i: 1">
        <div class="section-heading"><div><h2>Choose your favorites</h2><p>Every item is prepared fresh when you place the order.</p></div><form class="search-box" method="get" action="/kiosk"><span aria-hidden="true">⌕</span><label class="sr-only" for="menu-search">Search menu</label><input id="menu-search" name="q" value="#{h(search_query)}" placeholder="Search the menu" autocomplete="off"></form></div>
        <form class="visitor-form" method="post" action="/kiosk/customer"><div class="field"><label for="customer-name">Your name <span>(optional)</span></label><input id="customer-name" name="name" maxlength="40" value="#{h(customer_name)}" placeholder="e.g. Alex" autocomplete="name"></div>#{csrf_field}<button class="button-secondary" type="submit">Save name</button></form>
      </section>
      <div class="category-tabs reveal" style="--i: 2" aria-label="Menu categories">#{category_tabs}</div>
      <section class="menu-layout">
        <div><div class="product-grid" id="product-grid">#{display_products.each_with_index.map { |product, index| product_card(product, index) }.join}</div><div id="no-products" class="empty-cart" hidden><strong>No matching dishes</strong><span>Try another search or category.</span></div></div>
        <aside class="cart-panel reveal" id="cart-panel" style="--i: 3" aria-label="Current order">
          <div class="cart-header"><div><h2>Your order</h2><p>Tap + or − to adjust quantities.</p></div><span class="cart-count" id="cart-count">#{count}</span></div>
          <div class="cart-items" id="cart-items">#{cart_html}</div>
          <div class="cart-footer"><div class="total-row"><span>Estimated total</span><strong id="cart-total">#{money(total)}</strong></div><a id="checkout-button" class="button #{count.zero? ? 'disabled' : ''}" href="/kiosk/checkout" aria-disabled="#{count.zero? ? 'true' : 'false'}">Review &amp; pay <span aria-hidden="true">→</span></a><form method="post" action="/kiosk/cart" data-cart-form>#{csrf_field}<input type="hidden" name="action" value="clear"><button class="button-secondary" type="submit">Clear order</button></form></div>
        </aside>
      </section>
    HTML
    page_shell('Order kiosk', content, 'kiosk')
  end

  def render_checkout
    return redirect('/kiosk') if cart_items.empty?
    total = cart_total
    token = payment_token
    content = <<~HTML
      <section class="page-card panel reveal">
        <p class="eyebrow">Almost there</p>
        <h1>Review &amp; pay</h1>
        <p>Confirm your items, choose a payment method, and use the simulator to preview a successful transaction.</p>
        <div class="checkout-grid">
          <div><h2>Order summary</h2><div class="checkout-list">#{checkout_lines_html}</div><div class="total-row"><span>Total due</span><strong>#{money(total)}</strong></div></div>
          <div class="payment-card"><h2>Payment simulator</h2><p>Demo mode only. No real card details are collected or stored.</p><form method="post" action="/kiosk/pay" data-payment-form>#{csrf_field}<input type="hidden" name="payment_token" value="#{h(token)}"><div class="payment-options"><label class="payment-option"><input type="radio" name="method" value="card" checked><span><strong>Card payment</strong><span>Simulated test transaction</span></span></label><label class="payment-option"><input type="radio" name="method" value="cash"><span><strong>Pay at counter</strong><span>Mark as paid for kitchen display</span></span></label></div><div class="payment-actions"><button class="button" type="submit" name="outcome" value="approved">Approve payment <span aria-hidden="true">✓</span></button><button class="button-secondary" type="submit" name="outcome" value="declined">Simulate decline</button></div></form><p class="demo-note">Tip: choose <strong>Approve payment</strong> to create a paid order, or choose <strong>Simulate decline</strong> to retry without sending it to the kitchen.</p></div>
        </div>
        <div class="receipt-actions"><a class="button-ghost" href="/kiosk">← Back to menu</a></div>
      </section>
    HTML
    page_shell('Review and pay', content, 'kiosk')
  end

  def render_receipt(order)
    lines = order_lines(order)
    payment = hash_value(order, 'payment', {})
    reference = payment.is_a?(Hash) ? hash_value(payment, 'reference', 'MOCK-REFERENCE') : 'MOCK-REFERENCE'
    method = payment.is_a?(Hash) ? hash_value(payment, 'method', 'simulated') : 'simulated'
    token = order_public_token(order)
    qr_path = "/orders/#{URI.encode_www_form_component(token)}/qrcode.svg"
    status_url = order_status_url(order)
    content = <<~HTML
      <section class="page-card panel receipt-card reveal"><div class="success-mark" aria-hidden="true">✓</div><span class="receipt-id">#{h(order['id'] || 'ORDER')}</span><h1>Payment approved</h1><p>Your simulated payment is complete. The kitchen has received the order.</p><div class="receipt-qr-layout"><div class="qr-frame"><img src="#{h(qr_path)}" alt="QR code for order #{h(order['id'])}"></div><div class="qr-copy"><h2>Scan to track your order</h2><p>Scan the QR code with your phone to open the live status page. We will play a sound and show an alert when the kitchen marks it ready.</p><a class="status-link" href="#{h(status_url)}">#{h(status_url)}</a></div></div><div class="receipt-lines">#{lines.map { |line| %(<div class="receipt-line"><span>#{h(line['name'])} × #{line['quantity'].to_i}</span><strong>#{money(line['quantity'].to_i * line['unit_price'].to_i)}</strong></div>) }.join}</div><div class="receipt-total"><span>Total paid</span><span>#{money(order_total(order))}</span></div><p class="demo-note">Placed #{h(format_order_time(order['created_at']))} · Payment method: #{h(method)} · Reference: #{h(reference)}</p><div class="receipt-actions"><a class="button" href="/kiosk">Start a new order</a><button class="button-secondary" type="button" data-print>Print receipt</button></div></section>
    HTML
    page_shell('Payment receipt', content, 'kiosk')
  end

  def render_order_status(order)
    token = order_public_token(order)
    status = order_status(order)
    status_class = status == 'ready' ? 'ready' : status == 'cancelled' ? 'cancelled' : ''
    ready_at = hash_value(order, 'completed_at', nil)
    message = if status == 'ready'
                'Your order is ready. Please collect it from the pickup counter.'
              else
                'The kitchen is preparing your order. This page updates automatically.'
              end
    content = <<~HTML
      <section class="page-card panel status-card reveal" data-order-status-page data-order-token="#{h(token)}" data-initial-status="#{h(status)}"><p class="eyebrow">Live order tracking</p><span class="receipt-id">#{h(order['id'])}</span><h1>#{h(order_status_label(order))}</h1><span id="order-status-badge" class="status-badge #{status_class}">#{h(order_status_label(order))}</span><p id="order-status-message">#{h(message)}</p><div class="status-details"><div class="status-detail-row"><span>Customer</span><strong>#{h(order['name'].to_s.empty? ? 'Guest' : order['name'])}</strong></div><div class="status-detail-row"><span>Placed</span><strong>#{h(format_order_time(order['created_at']))}</strong></div><div class="status-detail-row"><span>Items</span><strong>#{order_lines(order).sum { |line| line['quantity'].to_i }}</strong></div><div class="status-detail-row"><span>Total</span><strong>#{money(order_total(order))}</strong></div><div class="status-detail-row"><span>Ready at</span><strong>#{ready_at ? h(format_order_time(ready_at)) : 'Waiting for kitchen'}</strong></div></div><div class="status-actions"><button id="order-alert-button" class="button-secondary" type="button">Enable sound &amp; alerts</button><a class="button" href="#{h(order_status_url(order))}">Refresh status</a></div><p class="status-live-note">Keep this page open for automatic sound and browser notifications when your order is ready.</p></section>
    HTML
    page_shell('Order status', content, 'kiosk')
  end

  def product_admin_card(product, index)
    available = product['available'] != false
    checked = available ? ' checked' : ''
    remove_form = if available
                    %(<form method="post" action="/admin/products/#{query_value(product['id'])}/remove" data-confirm="Remove this product from the kiosk?">#{csrf_field}<button class="button-danger button-small" type="submit">Remove from kiosk</button></form>)
                  else
                    %(<form method="post" action="/admin/products/#{query_value(product['id'])}/restore">#{csrf_field}<button class="button-secondary button-small" type="submit">Restore product</button></form>)
                  end
    <<~HTML
      <article class="inventory-item reveal #{available ? '' : 'unavailable'}" style="--i: #{index}">
        <div class="inventory-top"><div><h3>#{h(product['name'])}</h3><p>#{h(product['category'])} · #{h(product['description'])}</p></div><span class="product-price">#{money(product['price'])}</span></div>
        <form method="post" action="/admin/products/#{query_value(product['id'])}">#{csrf_field}<div class="form-grid two"><div class="field"><label>Name</label><input name="name" maxlength="60" value="#{h(product['name'])}" required></div><div class="field"><label>Price (₹)</label><input name="price" type="number" min="1" max="100000" step="1" value="#{product['price']}" required></div><div class="field"><label>Category</label><select name="category">#{PRODUCT_CATEGORIES.map { |category| %(<option value="#{h(category)}" #{category == product['category'] ? 'selected' : ''}>#{h(category)}</option>) }.join}</select></div><div class="field"><label>Description</label><textarea name="description" maxlength="180">#{h(product['description'])}</textarea></div></div><div class="inventory-actions"><label class="available-label field-check"><input type="checkbox" name="available" value="1"#{checked}> Available for ordering</label><div class="form-actions"><button class="button button-small" type="submit">Save changes</button></div></div></form>
        <div class="inventory-actions"><span class="category-label">ID: #{h(product['id'])}</span>#{remove_form}</div>
      </article>
    HTML
  end

  def render_admin_login
    configured = admin_configured?
    content = <<~HTML
      <section class="page-card panel auth-card"><p class="eyebrow">Staff access</p><h1>Admin sign in</h1><p>Manage the live menu and monitor kitchen orders from one protected workspace.</p>#{configured ? '' : '<div class="flash error">Set the ADMIN_PASSWORD environment variable before signing in. The app never stores a default password.</div>'}<form class="auth-form" method="post" action="/admin/login">#{csrf_field}<div class="field"><label for="admin-username">Username</label><input id="admin-username" name="username" value="#{h(ENV.fetch('ADMIN_USERNAME', 'admin'))}" autocomplete="username" required></div><div class="field"><label for="admin-password">Password</label><input id="admin-password" name="password" type="password" autocomplete="current-password" required></div><button class="button" type="submit">Sign in securely →</button></form><a class="button-ghost button-small" href="/kiosk">← Return to kiosk</a></section>
    HTML
    page_shell('Admin sign in', content, 'admin')
  end

  def render_admin_products
    inventory = products
    active_count = inventory.count { |product| product['available'] != false }
    category_count = inventory.map { |product| product['category'].to_s }.reject(&:empty?).uniq.length
    content = <<~HTML
      <section class="admin-header"><div><p class="eyebrow">Control room</p><h1>Menu manager</h1><p>Changes appear immediately on the kiosk. New prices are used for new orders only.</p></div><div class="admin-order-actions"><a class="button-secondary" href="/admin/orders">Orders &amp; accounting</a><a class="button-secondary" href="/kiosk">Open kiosk →</a></div></section>
      <div class="stats-grid"><div class="stat-card"><strong>#{active_count}</strong><span>Active products</span></div><div class="stat-card"><strong>#{inventory.length}</strong><span>Total products</span></div><div class="stat-card"><strong>#{category_count}</strong><span>Categories</span></div></div>
      <section class="admin-layout"><div class="admin-card"><h2>Add a product</h2><p>Create a new item for the self-order menu.</p><form method="post" action="/admin/products"><div class="form-grid">#{csrf_field}<div class="field"><label>Name</label><input name="name" maxlength="60" placeholder="e.g. Paneer Tikka" required></div><div class="form-grid two"><div class="field"><label>Price (₹)</label><input name="price" type="number" min="1" max="100000" step="1" placeholder="90" required></div><div class="field"><label>Category</label><select name="category">#{PRODUCT_CATEGORIES.map { |category| %(<option value="#{h(category)}">#{h(category)}</option>) }.join}</select></div></div><div class="field"><label>Description</label><textarea name="description" maxlength="180" placeholder="A short, tasty description"></textarea></div><label class="field-check"><input type="checkbox" name="available" value="1" checked> Available immediately</label><button class="button" type="submit">Add product ＋</button></div></form></div><div class="admin-card"><h2>Live inventory</h2><p>Soft-removing an item hides it from customers without breaking past orders.</p><div class="inventory-list">#{inventory.each_with_index.map { |product, index| product_admin_card(product, index + 2) }.join}</div></div></section>
    HTML
    page_shell('Menu manager', content, 'admin')
  end

  def orders_csv
    CSV.generate do |csv|
      csv << ['Order code', 'Placed at', 'Ready at', 'Customer', 'Status', 'Payment status', 'Payment method', 'Total INR', 'Items']
      read_orders.reverse_each do |order|
        items = order_lines(order).map { |line| "#{line['name']} x#{line['quantity']}" }.join('; ')
        csv << [order['id'], order['created_at'], hash_value(order, 'completed_at', ''), order['name'], order_status_label(order), order_payment_status(order), order_payment_method(order), order_total(order), items]
      end
    end
  end

  def render_admin_orders
    orders = read_orders.reverse
    paid_orders = orders.select { |order| order_paid?(order) }
    ready_orders = orders.select { |order| order_ready?(order) }
    sales_total = paid_orders.sum { |order| order_total(order) }
    average_order = paid_orders.empty? ? 0 : sales_total.to_f / paid_orders.length
    rows = orders.map do |order|
      status = order_status(order)
      status_class = status == 'ready' ? 'ready' : status == 'cancelled' ? 'cancelled' : ''
      payment_status = order_payment_status(order)
      payment_class = order_paid?(order) ? '' : payment_status
      item_text = order_lines(order).map { |line| "#{h(line['name'])} × #{line['quantity'].to_i}" }.join('<br>')
      token = order['public_token'].to_s
      status_link = token.empty? ? h(order['id']) : %(<a class="status-link" href="/orders/#{h(token)}">#{h(order['id'])}</a>)
      <<~HTML
        <tr><td>#{status_link}<br><span class="muted">#{h(format_order_time(order['created_at']))}</span></td><td>#{h(order['name'].to_s.empty? ? 'Guest' : order['name'])}</td><td class="order-items">#{item_text.empty? ? '—' : item_text}</td><td><span class="status-badge #{status_class}">#{h(order_status_label(order))}</span></td><td><span class="payment-pill #{h(payment_class)}">#{h(payment_status)}</span></td><td><strong>#{money(order_total(order))}</strong></td></tr>
      HTML
    end.join
    content = <<~HTML
      <section class="admin-header"><div><p class="eyebrow">Control room</p><h1>Orders &amp; accounting</h1><p>Review every order, payment, and sales total from one protected dashboard.</p></div><div class="admin-order-actions"><a class="button-secondary" href="/admin/products">Manage menu</a><a class="button" href="/admin/orders.csv">Export CSV ↓</a></div></section>
      <div class="accounting-grid"><div class="accounting-card"><strong>#{orders.length}</strong><span>All orders</span></div><div class="accounting-card"><strong>#{money(sales_total)}</strong><span>Paid sales</span></div><div class="accounting-card"><strong>#{ready_orders.length}</strong><span>Ready orders</span></div><div class="accounting-card"><strong>#{money(average_order)}</strong><span>Average paid order</span></div></div>
      <section class="admin-card admin-order-panel"><div class="kitchen-head"><div><h2>Order history</h2><p>Newest orders appear first. Sales totals include approved or paid checkouts.</p></div><span class="mode-pill">#{orders.length} records</span></div><div class="order-table-wrap">#{orders.empty? ? '<div class="kitchen-empty"><strong>No orders yet</strong><span>Completed checkouts will appear here.</span></div>' : "<table class=\"order-table\"><thead><tr><th>Order</th><th>Customer</th><th>Items</th><th>Status</th><th>Payment</th><th>Total</th></tr></thead><tbody>#{rows}</tbody></table>"}</div></section>
      <section class="reset-panel"><div><h2>Reset sales &amp; orders</h2><p>Delete order history and the JSON order ledger. Products and admin access are preserved.</p></div><form method="post" action="/admin/reset" data-confirm="Reset all order history and sales records? This cannot be undone.">#{csrf_field}<button class="button-danger" type="submit">Reset order history</button></form></section>
    HTML
    page_shell('Orders and accounting', content, 'orders')
  end

  def render_kitchen
    all_orders = read_orders
    active_orders = all_orders.reject { |order| order_ready?(order) }
    rows = active_orders.map do |order|
      original_index = all_orders.index(order)
      identifier = order_reference(order, original_index || 0)
      payment_status = order_payment_status(order)
      payment_class = payment_status == 'approved' || payment_status == 'paid' ? '' : payment_status
      <<~HTML
        <tr><td><span class="order-number">#{h(order['id'] || "Legacy ##{original_index.to_i + 1}")}</span><br><span class="muted">#{h(order['created_at'] || 'Imported order')}</span></td><td><strong>#{h(order['name'] || 'Guest')}</strong></td><td><div class="kitchen-items">#{order_items_html(order)}</div></td><td><span class="payment-pill #{h(payment_class)}">#{h(payment_status)}</span></td><td><strong>#{money(order_total(order))}</strong></td><td><form method="post" action="/kitchen/#{query_value(identifier)}/complete">#{csrf_field}<button class="button button-small" type="submit">Mark ready ✓</button></form></td></tr>
      HTML
    end.join
    total = active_orders.sum { |order| order_total(order) }
    content = <<~HTML
      <section class="admin-header"><div><p class="eyebrow">Live operations</p><h1>Kitchen queue</h1><p>Paid orders appear here automatically. Mark items ready when the counter hands them off.</p></div><div class="admin-order-actions"><a class="button-secondary" href="/admin/orders">All orders</a><a class="button-secondary" href="/admin/products">Manage menu</a></div></section>
      <section class="kitchen-panel"><div class="kitchen-head"><div><h2>#{active_orders.length} active order#{active_orders.length == 1 ? '' : 's'}</h2><p>Estimated queue value: #{money(total)}</p></div><span class="mode-pill">Live</span></div><div class="kitchen-table-wrap">#{active_orders.empty? ? '<div class="kitchen-empty"><strong>Queue is clear</strong><span>New approved orders will appear here.</span></div>' : "<table class=\"kitchen-table\"><thead><tr><th>Order</th><th>Guest</th><th>Items</th><th>Payment</th><th>Total</th><th>Action</th></tr></thead><tbody>#{rows}</tbody></table>"}</div></section>
    HTML
    page_shell('Kitchen queue', content, 'kitchen')
  end
end

before do
  initialize_database!
end

get '/' do
  redirect '/kiosk'
end

get '/health' do
  content_type :json
  JSON.generate(status: 'ok', products: available_products.length)
end

get '/kiosk' do
  render_kiosk
end

get '/order' do
  redirect '/kiosk'
end

get '/menu' do
  redirect '/kiosk'
end

get '/summary' do
  cart_items.empty? ? redirect('/kiosk') : redirect('/kiosk/checkout')
end

get '/finalize' do
  cart_items.empty? ? redirect('/kiosk') : redirect('/kiosk/checkout')
end

post '/menu' do
  redirect '/kiosk'
end

post '/confirm' do
  redirect '/kiosk'
end

post '/kiosk/customer' do
  require_csrf!
  name = params['name'].to_s.strip
  if name.empty?
    session[:error] = 'Enter a name or leave the field blank for a guest order.'
  elsif name.length > 40
    session[:error] = 'Names must be 40 characters or fewer.'
  else
    session[:kiosk_name] = name
    session[:notice] = 'Your order label is ready.'
  end
  redirect '/kiosk'
end

post '/kiosk/cart' do
  require_csrf!
  action = params['action'].to_s
  if action == 'clear'
    set_kiosk_cart({})
    message = 'Order cleared'
  else
    product = find_product(params['product_id'])
    halt 404, 'That product is not available' unless product && product['available'] != false
    current = kiosk_cart[product['id']].to_i
    quantity = case action
               when 'add' then current + 1
               when 'adjust' then current + (params['delta'].to_s == '-1' ? -1 : 1)
               when 'set' then params['quantity'].to_s.to_i
               else current + 1
               end
    quantity = quantity.clamp(0, 20)
    cart = kiosk_cart.dup
    if quantity.zero?
      cart.delete(product['id'])
      message = "#{product['name']} removed"
    else
      cart[product['id']] = quantity
      message = "#{product['name']} updated"
    end
    set_kiosk_cart(cart)
  end
  if json_request?
    content_type :json
    JSON.generate(cart_html: cart_html, count: cart_count, total: money(cart_total), message: message)
  else
    redirect '/kiosk'
  end
end

get '/kiosk/checkout' do
  if cart_items.empty?
    session[:error] = 'Add something delicious before checking out.'
    redirect '/kiosk'
  else
    render_checkout
  end
end

post '/kiosk/pay' do
  require_csrf!
  halt 403, 'Payment session expired. Please review your order again.' unless params['payment_token'].to_s == payment_token.to_s
  halt 400, 'Your cart is empty.' if cart_items.empty?
  outcome = params['outcome'].to_s
  if outcome != 'approved'
    session[:error] = 'Payment was declined by the simulator. Your order is still here to try again.'
    redirect '/kiosk/checkout'
  end
  method = %w[card cash].include?(params['method'].to_s) ? params['method'].to_s : 'card'
  items = cart_items.map do |item|
    product = item[:product]
    { 'product_id' => product['id'], 'name' => product['name'], 'quantity' => item[:quantity], 'unit_price' => product['price'].to_i }
  end
  order = {
    'id' => "ORD-#{Time.now.utc.strftime('%y%m%d')}-#{SecureRandom.hex(3).upcase}",
    'name' => session[:kiosk_name].to_s.empty? ? 'Guest' : session[:kiosk_name].to_s,
    'items' => items,
    'total' => cart_total,
    'status' => 'paid',
    'payment' => { 'method' => method, 'status' => 'approved', 'reference' => "MOCK-#{SecureRandom.hex(5).upcase}" },
    'created_at' => Time.now.utc.iso8601,
    'source' => 'kiosk'
  }
  append_order(order)
  session[:kiosk_receipt_id] = order['id']
  session[:kiosk_cart] = {}
  session[:kiosk_name] = nil
  session[:kiosk_payment_token] = nil
  redirect "/receipt/#{order['id']}"
end

get '/receipt/:id' do
  order = read_orders.find { |item| item['id'].to_s == params['id'].to_s }
  halt 404, 'Receipt not found' unless order
  halt 404, 'Receipt not found' unless admin_logged_in? || session[:kiosk_receipt_id].to_s == params['id'].to_s
  render_receipt(order)
end

get '/api/orders/:token/status' do
  order = find_order_by_token(params['token'])
  halt 404, JSON.generate(error: 'Order not found') unless order
  content_type :json
  status = order_status(order)
  message = status == 'ready' ? 'Your order is ready for pickup.' : 'The kitchen is preparing your order.'
  JSON.generate(code: order['id'], status: status, status_label: order_status_label(order), message: message, placed_at: order['created_at'], ready_at: hash_value(order, 'completed_at', nil), total: order_total(order))
end

get '/orders/:token/qrcode.svg' do
  order = find_order_by_token(params['token'])
  halt 404, 'Order not found' unless order
  content_type 'image/svg+xml'
  order_qr_svg(order)
end

get '/orders/:token' do
  order = find_order_by_token(params['token'])
  halt 404, 'Order not found' unless order
  render_order_status(order)
end

get '/admin' do
  redirect '/admin/orders'
end

get '/admin/login' do
  render_admin_login
end

post '/admin/login' do
  require_csrf!
  configured = admin_configured?
  username = params['username'].to_s
  password = params['password'].to_s
  expected_username = ENV.fetch('ADMIN_USERNAME', 'admin')
  if configured && secure_equal?(username, expected_username) && secure_equal?(password, ENV['ADMIN_PASSWORD'])
    session[:admin] = true
    session.delete(:csrf_token)
    redirect '/admin/orders'
  else
    session[:error] = configured ? 'Invalid admin credentials.' : 'Admin access is not configured yet.'
    redirect '/admin/login'
  end
end

post '/admin/logout' do
  require_csrf!
  session.delete(:admin)
  redirect '/admin/login'
end

before '/admin/*' do
  next if request.path_info == '/admin/login'
  admin_required!
end

get '/admin/orders' do
  render_admin_orders
end

get '/admin/orders.csv' do
  content_type 'text/csv'
  headers 'Content-Disposition' => %(attachment; filename="restaurant-orders-#{Time.now.utc.strftime('%Y%m%d')}.csv")
  orders_csv
end

post '/admin/reset' do
  require_csrf!
  reset_order_history!
  session[:notice] = 'Order history and sales records were reset.'
  redirect '/admin/orders'
end

get '/admin/products' do
  render_admin_products
end

post '/admin/products' do
  require_csrf!
  name = params['name'].to_s.strip
  price = begin
    Integer(params['price'].to_s, 10)
  rescue ArgumentError, TypeError
    nil
  end
  category = params['category'].to_s.strip
  category = 'General' if category.empty?
  description = params['description'].to_s.strip
  errors = []
  errors << 'Product name must be between 2 and 60 characters.' unless name.length.between?(2, 60)
  errors << 'Price must be a whole number between ₹1 and ₹100,000.' unless price && price.between?(1, 100_000)
  errors << 'Description must be 180 characters or fewer.' if description.length > 180
  errors << 'That category is not supported.' unless PRODUCT_CATEGORIES.include?(category)
  errors << 'A product with that name already exists.' if products.any? { |product| product['name'].to_s.casecmp?(name) }
  if errors.empty?
    base = name.downcase.gsub(/[^a-z0-9]+/, '-').sub(/\A-+|-+\z/, '')
    base = 'product' if base.empty?
    candidate = base
    index = 2
    while products.any? { |product| product['id'].to_s == candidate }
      candidate = "#{base}-#{index}"
      index += 1
    end
    product = { 'id' => candidate, 'name' => name, 'price' => price, 'category' => category, 'description' => (description.empty? ? "A new favorite from Mila's kitchen." : description), 'available' => params['available'] == '1' }
    write_products(products + [product])
    session[:notice] = "#{name} was added to the menu."
  else
    session[:error] = errors.join(' ')
  end
  redirect '/admin/products'
end

get '/admin/products/:id/edit' do
  redirect '/admin/products'
end

post '/admin/products/:id' do
  require_csrf!
  inventory = products
  product = inventory.find { |item| item['id'].to_s == params['id'].to_s }
  halt 404, 'Product not found' unless product
  name = params['name'].to_s.strip
  price = begin
    Integer(params['price'].to_s, 10)
  rescue ArgumentError, TypeError
    nil
  end
  category = params['category'].to_s.strip
  category = 'General' if category.empty?
  description = params['description'].to_s.strip
  errors = []
  errors << 'Product name must be between 2 and 60 characters.' unless name.length.between?(2, 60)
  errors << 'Price must be a whole number between ₹1 and ₹100,000.' unless price && price.between?(1, 100_000)
  errors << 'Description must be 180 characters or fewer.' if description.length > 180
  errors << 'That category is not supported.' unless PRODUCT_CATEGORIES.include?(category)
  errors << 'A product with that name already exists.' if inventory.any? { |item| item['id'] != product['id'] && item['name'].to_s.casecmp?(name) }
  if errors.empty?
    product['name'] = name
    product['price'] = price
    product['category'] = category
    product['description'] = description.empty? ? "A new favorite from Mila's kitchen." : description
    product['available'] = params['available'] == '1'
    write_products(inventory)
    session[:notice] = "#{name} was updated."
  else
    session[:error] = errors.join(' ')
  end
  redirect '/admin/products'
end

post '/admin/products/:id/remove' do
  require_csrf!
  inventory = products
  product = inventory.find { |item| item['id'].to_s == params['id'].to_s }
  halt 404, 'Product not found' unless product
  product['available'] = false
  write_products(inventory)
  session[:notice] = "#{product['name']} is hidden from the kiosk."
  redirect '/admin/products'
end

post '/admin/products/:id/restore' do
  require_csrf!
  inventory = products
  product = inventory.find { |item| item['id'].to_s == params['id'].to_s }
  halt 404, 'Product not found' unless product
  product['available'] = true
  write_products(inventory)
  session[:notice] = "#{product['name']} is available again."
  redirect '/admin/products'
end

get '/kitchen' do
  admin_required!
  render_kitchen
end

get '/menu/kitchen' do
  redirect '/kitchen'
end

post '/kitchen/:id/complete' do
  admin_required!
  require_csrf!
  if complete_order(params['id'])
    session[:notice] = 'Order marked ready and removed from the active queue.'
  else
    session[:error] = 'That order is no longer available in the queue.'
  end
  redirect '/kitchen'
end

post '/complete/:id' do
  admin_required!
  require_csrf!
  complete_order(params['id'])
  redirect '/kitchen'
end
