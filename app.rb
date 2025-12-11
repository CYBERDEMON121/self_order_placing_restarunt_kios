require 'sinatra'
require 'json'
enable :sessions

DB_FILE = 'order_placed.json'

set :public_folder, File.dirname(__FILE__) + '/static'

# Predefined menu with prices
MENU = [
    {name: "Veg Rice", price: 50},
    {name: "Veg Soup", price: 30},
    {name: "Veg Salad", price: 40},
    {name: "Chicken Curry", price: 120},
    {name: "Fish Fry", price: 150}
]

MENU_PRICES = MENU.map { |m| [m[:name], m[:price]] }.to_h

# Home page
get '/' do
    <<-HTML
    <html>
    <head>
    <title>Mila's Restaurant</title>
    <style>
    body { margin:0; height:100vh; display:flex; justify-content:center; align-items:center; text-align:center; font-family:Arial,sans-serif; background:url('/home.jpeg') no-repeat center center fixed; background-size:cover; color:white; }
    .container { background:rgba(0,0,0,0.6); padding:40px; border-radius:15px; }
    .logo { width:100px; height:100px; border-radius:50%; margin-bottom:20px; }
    h1 { margin:0 0 20px; font-size:2.5em; letter-spacing:2px; }
    a.button { display:inline-block; padding:12px 24px; margin:10px; text-decoration:none; border-radius:8px; background:#ff9800; color:white; font-weight:bold; transition:0.3s; }
    a.button:hover { background:#e68900; }
    </style>
    </head>
    <body>
    <div class="container">
    <img class="logo" src="/mila.jpeg" alt="Mila's Logo">
    <h1>Welcome to Mila's Restaurant</h1>
    <a class="button" href="/order">Place an Order</a>
    <a class="button" href="/summary">View Final Orders</a>
    </div>
    </body>
    </html>
    HTML
end

# Step 1: Ask Name
get '/order' do
    <<-HTML
    <html>
    <head>
    <title>Enter Your Name - Mila's Restaurant</title>
    <style>
    body { margin:0; height:100vh; display:flex; justify-content:center; align-items:center; text-align:center; font-family:Arial,sans-serif; background:url('/home.jpeg') no-repeat center center fixed; background-size:cover; color:white; }
    .container { background:rgba(0,0,0,0.6); padding:40px; border-radius:15px; }
    input[type="text"] { padding:10px; width:250px; border-radius:8px; border:none; margin-bottom:20px; font-size:16px; }
    input[type="submit"] { padding:12px 24px; border:none; border-radius:8px; background:#ff9800; color:white; font-weight:bold; cursor:pointer; transition:0.3s; }
    input[type="submit"]:hover { background:#e68900; }
    </style>
    </head>
    <body>
    <div class="container">
    <h1>Welcome to Mila's Restaurant!</h1>
    <form action="/menu" method="post">
    <input type="text" name="name" placeholder="Enter Your Name" required><br>
    <input type="submit" value="Continue">
    </form>
    </div>
    </body>
    </html>
    HTML
end

# Step 2: Save name and redirect to menu
post '/menu' do
    session[:name] = params[:name]
    redirect '/menu'
end

# Step 2: Show Menu
get '/menu' do
    name = session[:name]
    halt "<h3>No user found. Please start a new order.</h3><a href='/order'>Back</a>" unless name

    previous_order = session[:order]&.find { |o| o[:name] == name }
    previous_dishes = previous_order ? previous_order[:dishes] : {}

    menu_html = MENU.each_with_index.map do |item, index|
        checked = previous_dishes.key?(item[:name]) ? 'checked' : ''
        qty_value = previous_dishes[item[:name]] ? previous_dishes[item[:name]][:qty] : 1
        <<-ITEM
        <div class="menu-item">
        <input type="checkbox" name="dishes[#{item[:name]}]" id="chk#{index}" value="1" onclick="toggleQty(#{index})" #{checked}>
        <label for="chk#{index}">#{item[:name]} - ₹#{item[:price]}</label>
        Qty: <input type="number" name="qty[#{item[:name]}]" id="qty#{index}" value="#{qty_value}" min="1" class="qty-field" style="display:#{checked.empty? ? 'none' : 'inline-block'};">
        </div>
        ITEM
    end.join

    <<-HTML
    <html>
    <head>
    <title>Menu - Mila's Restaurant</title>
    <style>
    body { margin:0; font-family:Arial,sans-serif; background:url('/home.jpeg') no-repeat center center fixed; background-size:cover; color:white; text-align:center; padding:40px;}
    .container { background:rgba(0,0,0,0.7); padding:30px; border-radius:15px; display:inline-block; text-align:left; }
    h2 { text-align:center; margin-bottom:20px; }
    .menu-item { margin-bottom:15px; font-size:18px; }
    .qty-field { width:60px; margin-left:10px; border-radius:6px; padding:5px; border:1px solid #ccc; }
    input[type="submit"] { padding:10px 20px; border:none; border-radius:8px; background:#ff9800; color:white; font-weight:bold; cursor:pointer; transition:0.3s; display:block; margin:20px auto 0 auto; }
    input[type="submit"]:hover { background:#e68900; }
    </style>
    </head>
    <body>
    <div class="container">
    <h2>Hello #{name}, select your dishes</h2>
    <form action="/confirm" method="post">
    #{menu_html}
    <input type="submit" value="Place Order">
    </form>
    </div>
    <script>
    function toggleQty(index) {
    var checkbox = document.getElementById("chk" + index);
    var qtyInput = document.getElementById("qty" + index);
    qtyInput.style.display = checkbox.checked ? "inline-block" : "none";
    }
    </script>
    </body>
    </html>
    HTML
end

# Step 3: Confirm order (store only qty, no price)
post '/confirm' do
    name = session[:name]
    dishes_checked = params[:dishes] || {}
    quantities = params[:qty] || {}

    ordered_items = {}
    dishes_checked.each do |dish_name, _|
        qty = quantities[dish_name].to_i
        ordered_items[dish_name] = { qty: qty } if qty > 0
    end

    return "<h3>No dishes selected for #{name}!</h3><a href='/order'>Try again</a>" if ordered_items.empty?

    session[:order] ||= []

    existing_order = session[:order].find { |o| o[:name] == name }
    if existing_order
        existing_order[:dishes] = ordered_items
    else
        session[:order] << { name: name, dishes: ordered_items }
    end

    redirect '/summary'
end

# Summary page
get '/summary' do
    orders = session[:order] || []

    list = if orders.empty?
    "<h3>No orders yet.</h3>"
else
    orders.each_with_index.map do |o, i|
        items = o[:dishes].map do |dish, data|
            price = MENU_PRICES[dish]
            "#{dish} (x#{data[:qty]}) - ₹#{data[:qty] * price}"
        end.join("<br>")
        "#{i+1}. <b>#{o[:name]}</b><br>#{items}"
    end.join("<br><br>")
end

<<-HTML
<html>
<head>
<title>Final Orders - Mila's Restaurant</title>
<style>
body { margin:0; font-family:Arial,sans-serif; background:url('/home.jpeg') no-repeat center center fixed; background-size:cover; text-align:center; padding:40px; color:white;}
.container { background:rgba(0,0,0,0.7); display:inline-block; padding:30px; border-radius:15px; box-shadow:0 0 10px rgba(0,0,0,0.3);}
h2 { margin-bottom:20px; }
.order-list { text-align:left; margin-bottom:20px; }
a.button { display:inline-block; padding:10px 20px; margin:10px; text-decoration:none; border-radius:8px; background:#ff9800; color:white; font-weight:bold; transition:0.3s; }
a.button:hover { background:#e68900; }
</style>
</head>
<body>
<div class="container">
<h2>📋 Final Orders List</h2>
<div class="order-list">#{list}</div>
<a class="button" href="/menu">Continue Order</a>
<a class="button" href="/finalize">Finalize Orders</a>
</div>
</body>
</html>
HTML
end

# Finalize orders and save without price
get '/finalize' do
    orders = session[:order] || []

    if orders.empty?
        return "<h3>No orders to finalize!</h3><a class='button' href='/'>Home</a>"
    end

    existing_orders = File.exist?(DB_FILE) ? JSON.parse(File.read(DB_FILE)) : []
    # Save orders without price
    orders_to_save = orders.map do |o|
        { "name" => o[:name], "dishes" => o[:dishes].transform_values { |v| { "qty" => v[:qty] } } }
    end
    existing_orders += orders_to_save
    File.write(DB_FILE, JSON.pretty_generate(existing_orders))

    total_amount = orders.sum { |o| o[:dishes].sum { |dish, data| data[:qty] * MENU_PRICES[dish] } }

    list = orders.map.with_index(1) do |o, i|
        items = o[:dishes].map { |dish, data| "• #{dish} (x#{data[:qty]}) - ₹#{data[:qty] * MENU_PRICES[dish]}" }.join("<br>")
        "<b>#{i}. #{o[:name]}</b><br>#{items}"
    end.join("<br><br>")

    session[:order] = []

    <<-HTML
    <html>
    <head>
    <title>Order Finalized - Mila's Restaurant</title>
    <style>
    body { margin:0; font-family:Arial,sans-serif; background:url('/home.jpeg') no-repeat center center fixed; background-size:cover; text-align:center; color:white; padding:40px;}
    .container { background:rgba(0,0,0,0.7); padding:40px; border-radius:15px; display:inline-block; }
    a.button { display:inline-block; padding:12px 24px; margin-top:20px; text-decoration:none; border-radius:8px; background:#ff9800; color:white; font-weight:bold; transition:0.3s;}
    a.button:hover { background:#e68900; }
    h3 { margin-top:20px; }
    </style>
    </head>
    <body>
    <div class="container">
    <h2>✅ Orders finalized and saved!</h2>
    <div class="order-list">#{list}</div>
    <h3>Total Amount: ₹#{total_amount}</h3>
    <a class="button" href="/">Home</a>
    </div>
    </body>
    </html>
    HTML
end

# Kitchen page (no prices)
get '/kitchen' do
    orders = File.exist?(DB_FILE) ? JSON.parse(File.read(DB_FILE)) : []

    rows = if orders.empty?
    "<tr><td colspan='3'>No orders yet.</td></tr>"
else
    orders.each_with_index.map do |o, i|
        items = o["dishes"].map { |dish, data| "#{dish} (x#{data['qty']})" }.join("<br>")
        <<-ROW
        <tr>
        <td>#{i+1}</td>
        <td>#{o["name"]}</td>
        <td>#{items}</td>
        <td>
        <form method="post" action="/complete/#{i}" style="display:inline;">
        <button type="submit" class="btn-orange">✅ Completed</button>
        </form>
        </td>
        </tr>
        ROW
    end.join
end

<<-HTML
<html>
<head>
<title>Kitchen Orders - Mila's Restaurant</title>
<style>
body { margin:0; font-family:Arial,sans-serif; background:url('/home.jpeg') no-repeat center center fixed; background-size:cover; text-align:center; padding:40px; color:white;}
.container { background:rgba(0,0,0,0.7); display:inline-block; padding:30px; border-radius:15px; box-shadow:0 0 10px rgba(0,0,0,0.3);}
h2 { margin-bottom:20px; }
table { width:100%; border-collapse:collapse; margin:20px 0; }
th, td { border:1px solid #ddd; padding:10px; }
th { background:#ff9800; color:white; }
.btn-orange { background:#ff9800; color:white; border:none; padding:10px 20px; border-radius:8px; font-weight:bold; cursor:pointer; transition:all 0.3s ease-in-out; text-decoration:none; display:inline-block; }
.btn-orange:hover { background:#e68900; transform: scale(1.05); }
</style>
</head>
<body>
<div class="container">
<h2>👨‍🍳 Kitchen Orders</h2>
<table>
<tr>
<th>#</th>
<th>Customer</th>
<th>Order</th>
<th>Action</th>
</tr>
#{rows}
</table>
<a class="btn-orange" href="/">🏠 Home</a>
</div>
</body>
</html>
HTML
end

# Mark order completed
post '/complete/:id' do
    id = params[:id].to_i
    orders = File.exist?(DB_FILE) ? JSON.parse(File.read(DB_FILE)) : []

    if id >= 0 && id < orders.size
        orders.delete_at(id)
        File.write(DB_FILE, JSON.pretty_generate(orders))
    end

    redirect '/kitchen'
end
