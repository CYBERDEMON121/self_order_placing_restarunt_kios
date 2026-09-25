# Mila's Restaurant Kiosk

A self-order restaurant kiosk built with Ruby and Sinatra. Customers can browse the menu, build a cart, complete a simulated payment, and receive a QR code for live order tracking. Staff can manage the menu, review orders and sales, export accounting data, and mark kitchen orders ready.

## Features

- Responsive customer kiosk with menu categories, search, cart controls, and guest name capture.
- Simulated approved or declined checkout flow. No real card or bank credentials are collected.
- Receipt pages with order QR codes.
- Public order status pages with live polling, ready-state sound, toast messages, and optional browser notifications.
- SQLite persistence with automatic schema setup and legacy JSON import.
- Synchronized JSON order ledger for order code, timestamp, customer, items, totals, payment state, status, and ready time.
- Protected admin dashboard for menu management, order history, sales totals, CSV export, and scoped order reset.
- Protected kitchen queue for marking paid orders ready.
- Optional Linux systemd deployment through `install.sh`.

## Requirements

- Linux for the automated installer.
- Ruby 3.2 or newer for the current dependency set.
- Bundler and a C toolchain for native gems such as `sqlite3`.
- A modern browser for the kiosk and admin dashboard.
- A phone on the same network as the server when scanning QR codes over the local network.

The application defaults to `http://localhost:4567`.

## Quick Start on Linux

From the project directory, install the application as a systemd service:

```bash
sudo ./install.sh --service \
  --service-user appuser \
  --public-url http://192.168.1.20:4567
```

Replace `appuser` with an existing operating-system user that can read the application and write its runtime data. Replace the example IP with the server address reachable from the phone. The installer prompts for the admin password when `ADMIN_PASSWORD` is not already set.

The installer can install packages with `apt`, `dnf`, `yum`, `pacman`, `apk`, or `zypper`. It installs Bundler, installs gems into `vendor/bundle`, validates the application, writes the protected environment file, and starts the service.

Useful installer options:

```text
--app-dir PATH       Application directory; defaults to the script directory
--host ADDRESS       Bind address; defaults to 0.0.0.0
--port PORT          Bind port; defaults to 4567
--public-url URL     Base URL encoded in QR codes
--admin-user NAME    Admin username; defaults to admin
--service-name NAME  systemd service name; defaults to mila-restaurant
--service-user USER  Existing user that runs the service
--config-dir PATH    Environment-file directory
--service            Require systemd installation and startup
--no-service         Install dependencies without creating a service
--skip-packages      Do not install operating-system packages
```

Use `sudo ./install.sh --no-service` when systemd is not available or when the application should be started manually. In that mode, export the runtime environment yourself before starting the app.

## Manual Setup

Install the Ruby dependencies:

```bash
bundle install
```

Set the required environment variables and start the server:

```bash
export ADMIN_USERNAME=admin
export ADMIN_PASSWORD='choose-a-password'
export SESSION_SECRET="$(ruby -rsecurerandom -e 'print SecureRandom.hex(64)')"
export PUBLIC_BASE_URL='http://192.168.1.20:4567'
bundle exec ruby app.rb -o 0.0.0.0 -p 4567
```

There is intentionally no default admin password. If `SESSION_SECRET` is omitted, the application creates a temporary secret at process startup, which means sessions will be invalidated whenever the process restarts.

If Bundler is not installed:

```bash
gem install bundler
```

## Configuration

| Variable | Default | Purpose |
| --- | --- | --- |
| `ADMIN_USERNAME` | `admin` | Administrator login name. |
| `ADMIN_PASSWORD` | none | Administrator password; required for admin access. |
| `SESSION_SECRET` | generated at startup | Secret used to protect session cookies. Set a persistent value in production. |
| `PUBLIC_BASE_URL` | request URL | Phone-reachable base URL encoded in order QR codes. |
| `DATABASE_FILE` | `restaurant.sqlite3` | SQLite database path. |
| `ORDER_RECORDS_FILE` | `order_records.json` | Synchronized JSON order ledger path. |
| `PRODUCTS_FILE` | `products.json` | Legacy product import file, read during initial database setup. |
| `ORDERS_FILE` | `order_placed.json` | Legacy order import file, read during initial database setup. |
| `RACK_ENV` | development | Rack environment; the systemd installer sets it to `production`. |

`HOST` and `PORT` are installer settings used to build the systemd command and local start command. They are not required when passing `-o` and `-p` directly to Ruby.

### QR reachability

A QR code containing `localhost` can only be opened by the device running the kiosk. Set `PUBLIC_BASE_URL` to an address reachable from the customer's phone, for example:

```bash
export PUBLIC_BASE_URL='http://192.168.1.20:4567'
```

The phone and server must be able to reach each other, and the port must be allowed through the host firewall. For an internet-facing deployment, put the app behind an HTTPS reverse proxy and use its HTTPS URL as `PUBLIC_BASE_URL`.

## Using the Kiosk

1. Open `/kiosk` on the ordering device.
2. Browse or search the menu and add items to the cart.
3. Open checkout, optionally enter a guest name, and choose the simulated payment outcome.
4. Show the receipt QR code to the customer.
5. The customer opens the QR link to view the live order status.
6. Staff open `/kitchen`, authenticate, and mark the order ready when it is handed off.

The status page polls the order API while it is open. Browser notifications require permission and may require a user interaction depending on the browser. The ready sound is played only after the status changes to ready.

## Administration

Open `/admin/login` and sign in with `ADMIN_USERNAME` and `ADMIN_PASSWORD`.

The admin area includes:

- `/admin/orders`: order history, payment state, totals, and sales accounting.
- `/admin/orders.csv`: download all orders as CSV.
- `/admin/products`: add, edit, hide, and restore menu products.
- `/admin/reset`: clear order history and the synchronized JSON ledger while preserving products and administrator credentials.

The reset action is intentionally limited to order and sales history. Back up the SQLite database and JSON ledger before resetting in a production environment.

## Kitchen

Open `/kitchen` while authenticated. Paid, active orders appear in the queue. Marking an order ready updates both SQLite and the JSON ledger, and public status pages reflect the change automatically.

## systemd Operations

The default service name is `mila-restaurant`. The installer writes:

- Environment file: `/etc/mila-restaurant/environment` with mode `0600`.
- Service unit: `/etc/systemd/system/mila-restaurant.service`.

Common commands:

```bash
sudo systemctl status mila-restaurant
sudo systemctl restart mila-restaurant
sudo journalctl -u mila-restaurant -f
```

The service user must have write access to the application directory and runtime data files. The installer checks the application directory and existing database/ledger files before starting the service.

To remove the service while retaining installed dependencies:

```bash
sudo systemctl disable --now mila-restaurant
sudo rm /etc/systemd/system/mila-restaurant.service
sudo systemctl daemon-reload
```

Remove the protected environment file separately if it is no longer needed.

## Data and Files

Runtime SQLite tables are `products`, `orders`, `order_items`, and `app_meta`. The application creates missing tables and migrates older databases automatically.

`order_records.json` is generated from SQLite and contains a customer-facing order history representation. It is safe to delete only when the database is available; the application recreates it on startup. Runtime SQLite files, the JSON ledger, `.bundle/`, and `vendor/bundle/` are ignored by Git.

Legacy files used during first-time setup are `products.json`, `order_placed.json`, and `order_placed`. They are not the normal runtime source of truth after migration.

## Routes

The complete route inventory is in [`routes.txt`](routes.txt). The main entry points are:

- `GET /kiosk` — customer menu and cart.
- `POST /kiosk/pay` — simulated payment.
- `GET /receipt/:id` — receipt and QR code.
- `GET /orders/:token` — public order status.
- `GET /api/orders/:token/status` — JSON status endpoint.
- `GET /admin/orders` — accounting dashboard.
- `GET /kitchen` — kitchen queue.
- `GET /health` — health check.

All mutating browser forms use CSRF protection. Admin and kitchen pages require an authenticated session.

## Development Checks

Run these checks after changes:

```bash
bundle check
bundle exec ruby -c app.rb
bundle exec ruby -w -c app.rb
bash -n install.sh
./install.sh --help
git diff --check
```

There is no separate automated test suite in this repository. Exercise the kiosk, admin, kitchen, QR, CSV, and reset flows manually after changing order or accounting behavior.

## Troubleshooting

### The phone cannot open the QR link

Set `PUBLIC_BASE_URL` to the server's LAN address, confirm both devices are on the same network, and allow TCP port `4567` through the firewall. Do not use `localhost` for a customer phone.

### The service will not start

Inspect the unit and journal:

```bash
sudo systemctl status mila-restaurant
sudo journalctl -u mila-restaurant -n 100 --no-pager
```

Confirm the service user exists and can write the application directory, database, and order ledger. Also confirm that the configured port is not already in use.

### Bundler cannot find the application gems

Run the installer without `--skip-packages`, or run `bundle install` from the project directory. The installer uses a project-local Bundler path at `vendor/bundle`.

### The port is already in use

Choose another port for both the server and QR URL:

```bash
sudo ./install.sh --service --port 8080 --public-url http://192.168.1.20:8080
```

## Project Layout

```text
app.rb                 Sinatra application and route handlers
Gemfile                Runtime dependencies
Gemfile.lock           Resolved dependency versions
install.sh             Linux dependency and systemd installer
credentials.txt        Environment and credential reference
routes.txt             Route inventory
products.json          Legacy product import data
static/                Kiosk images and assets
```

The payment flow is a simulator for demonstration and testing. It does not process real payments and does not accept or store card numbers, CVV values, bank credentials, or payment API secrets.
