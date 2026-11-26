// Storefront SPA. All calls go to same-origin /api/*; the Istio Gateway
// (HTTPRoute) fans them out to the right microservice, so the browser never
// needs CORS or to know internal service names.
const userId = localStorage.getItem('uid') ?? crypto.randomUUID();
localStorage.setItem('uid', userId);

const $ = (id) => document.getElementById(id);
const money = (cents, cur = 'EUR') => new Intl.NumberFormat('en', { style: 'currency', currency: cur }).format(cents / 100);

async function api(path, opts = {}) {
  const res = await fetch(path, { headers: { 'content-type': 'application/json' }, ...opts });
  if (!res.ok) throw new Error(`${path} -> ${res.status}`);
  return res.status === 204 ? null : res.json();
}

async function renderProducts(q = '') {
  const products = await api(`/api/products${q ? `?q=${encodeURIComponent(q)}` : ''}`);
  $('products').replaceChildren(...products.map((p) => {
    const card = document.createElement('article');
    card.className = 'card';
    card.innerHTML = `<h3></h3><p class="desc"></p><p class="price"></p><button type="button">Add to cart</button>`;
    card.querySelector('h3').textContent = p.name;
    card.querySelector('.desc').textContent = p.description;
    card.querySelector('.price').textContent = money(p.priceCents, p.currency);
    card.querySelector('button').onclick = () => addToCart(p.id);
    return card;
  }));
}

async function renderCart() {
  const cart = await api(`/api/cart/${userId}`);
  $('cart-count').textContent = cart.items.reduce((n, i) => n + i.quantity, 0);
  $('cart-items').replaceChildren(...cart.items.map((i) => {
    const li = document.createElement('li');
    li.textContent = `${i.productId} × ${i.quantity}`;
    return li;
  }));
}

async function addToCart(productId) {
  await api(`/api/cart/${userId}/items`, { method: 'POST', body: JSON.stringify({ productId, quantity: 1 }) });
  await renderCart();
}

async function checkout() {
  $('checkout-result').textContent = 'Placing order…';
  try {
    const order = await api('/api/orders', {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'idempotency-key': crypto.randomUUID() },
      body: JSON.stringify({ userId, country: 'PL', cardToken: 'tok_visa' }),
    });
    $('checkout-result').textContent = `Order ${order.orderId}: ${order.status} (total ${money(order.totalCents)})`;
    await renderCart();
  } catch (e) {
    $('checkout-result').textContent = `Checkout failed: ${e.message}`;
  }
}

let t;
$('search').addEventListener('input', (e) => { clearTimeout(t); t = setTimeout(() => renderProducts(e.target.value), 250); });
$('cart-button').addEventListener('click', () => { $('cart').hidden = !$('cart').hidden; });
$('checkout').addEventListener('click', checkout);
$('build').textContent = __APP_VERSION__; // eslint-disable-line no-undef

renderProducts().catch(console.error);
renderCart().catch(console.error);
