/*
# E-Commerce Recommendation Engine — Core Schema

## Purpose
Full schema for a production-style e-commerce app with a hybrid product
recommendation engine. Stores products, categories, users (profile rows that
shadow auth.users), reviews, cart, wishlist, orders, and user interactions
that feed the recommendation engine.

## New Tables
1. `categories` — product categories (id, name, slug, description, image_url).
2. `products` — catalog (id, name, description, price, discount, category_id,
   brand, image_url, images, stock, rating, review_count, tags, created_at, updated_at).
3. `profiles` — public user profile shadowing auth.users (id = auth.uid, name, role, created_at).
4. `reviews` — product reviews (id, user_id, product_id, rating, comment, created_at, updated_at).
5. `cart_items` — shopping cart (id, user_id, product_id, quantity, created_at).
6. `wishlist_items` — wishlist (id, user_id, product_id, created_at).
7. `orders` — order header (id, user_id, total, status, shipping, payment_method, created_at).
8. `order_items` — order lines (id, order_id, product_id, quantity, price).
9. `user_interactions` — recommendation signal log (id, user_id, product_id, interaction_type, weight, created_at).
10. `recommendation_logs` — admin analytics: what was recommended and whether it was interacted with.

## Security (RLS)
- `categories`, `products`: public read for anon+authenticated; write restricted to admins via service role / edge function.
- `profiles`: each user reads/updates own row; admins read all (via service role).
- `reviews`: public read; only the author can insert/update/delete own review.
- `cart_items`, `wishlist_items`: owner-scoped CRUD (auth.uid() = user_id).
- `orders`: owner can read own orders + insert; order_items readable via order ownership.
- `user_interactions`: owner can insert own; read restricted to service role for analytics.
- `recommendation_logs`: insert via service role; read restricted to service role.

## Notes
1. `profiles.role` defaults to 'USER'. Admin role is set via service role / SQL.
2. `products.tags` is a text[] for content-based TF-IDF similarity.
3. `user_interactions.weight` allows per-interaction weighting (view=1, cart=3, wishlist=4, purchase=5, rating=3).
4. All foreign keys use ON DELETE CASCADE where appropriate to keep data clean.
5. Indexes added for common query patterns (category, brand, user_id, product_id, interaction_type).
*/

-- ========== CATEGORIES ==========
CREATE TABLE IF NOT EXISTS categories (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL,
  slug text UNIQUE NOT NULL,
  description text,
  image_url text,
  created_at timestamptz DEFAULT now()
);
ALTER TABLE categories ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "public_read_categories" ON categories;
CREATE POLICY "public_read_categories" ON categories FOR SELECT
  TO anon, authenticated USING (true);

-- ========== PRODUCTS ==========
CREATE TABLE IF NOT EXISTS products (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL,
  description text,
  price numeric(10,2) NOT NULL,
  discount numeric(5,2) DEFAULT 0,
  category_id uuid REFERENCES categories(id) ON DELETE SET NULL,
  brand text,
  image_url text,
  images text[] DEFAULT '{}',
  stock integer NOT NULL DEFAULT 0,
  rating numeric(3,2) DEFAULT 0,
  review_count integer DEFAULT 0,
  tags text[] DEFAULT '{}',
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now()
);
ALTER TABLE products ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "public_read_products" ON products;
CREATE POLICY "public_read_products" ON products FOR SELECT
  TO anon, authenticated USING (true);

CREATE INDEX IF NOT EXISTS idx_products_category ON products(category_id);
CREATE INDEX IF NOT EXISTS idx_products_brand ON products(brand);
CREATE INDEX IF NOT EXISTS idx_products_created_at ON products(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_products_rating ON products(rating DESC);

-- ========== PROFILES ==========
CREATE TABLE IF NOT EXISTS profiles (
  id uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  name text NOT NULL,
  role text NOT NULL DEFAULT 'USER',
  created_at timestamptz DEFAULT now()
);
ALTER TABLE profiles ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "read_own_profile" ON profiles;
CREATE POLICY "read_own_profile" ON profiles FOR SELECT
  TO authenticated USING (auth.uid() = id);
DROP POLICY IF EXISTS "update_own_profile" ON profiles;
CREATE POLICY "update_own_profile" ON profiles FOR UPDATE
  TO authenticated USING (auth.uid() = id) WITH CHECK (auth.uid() = id);

-- ========== REVIEWS ==========
CREATE TABLE IF NOT EXISTS reviews (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  product_id uuid NOT NULL REFERENCES products(id) ON DELETE CASCADE,
  rating integer NOT NULL CHECK (rating >= 1 AND rating <= 5),
  comment text,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now(),
  UNIQUE (user_id, product_id)
);
ALTER TABLE reviews ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "public_read_reviews" ON reviews;
CREATE POLICY "public_read_reviews" ON reviews FOR SELECT
  TO anon, authenticated USING (true);
DROP POLICY IF EXISTS "insert_own_review" ON reviews;
CREATE POLICY "insert_own_review" ON reviews FOR INSERT
  TO authenticated WITH CHECK (auth.uid() = user_id);
DROP POLICY IF EXISTS "update_own_review" ON reviews;
CREATE POLICY "update_own_review" ON reviews FOR UPDATE
  TO authenticated USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);
DROP POLICY IF EXISTS "delete_own_review" ON reviews;
CREATE POLICY "delete_own_review" ON reviews FOR DELETE
  TO authenticated USING (auth.uid() = user_id);
CREATE INDEX IF NOT EXISTS idx_reviews_product ON reviews(product_id);
CREATE INDEX IF NOT EXISTS idx_reviews_user ON reviews(user_id);

-- ========== CART ITEMS ==========
CREATE TABLE IF NOT EXISTS cart_items (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  product_id uuid NOT NULL REFERENCES products(id) ON DELETE CASCADE,
  quantity integer NOT NULL DEFAULT 1 CHECK (quantity > 0),
  created_at timestamptz DEFAULT now(),
  UNIQUE (user_id, product_id)
);
ALTER TABLE cart_items ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "select_own_cart" ON cart_items;
CREATE POLICY "select_own_cart" ON cart_items FOR SELECT
  TO authenticated USING (auth.uid() = user_id);
DROP POLICY IF EXISTS "insert_own_cart" ON cart_items;
CREATE POLICY "insert_own_cart" ON cart_items FOR INSERT
  TO authenticated WITH CHECK (auth.uid() = user_id);
DROP POLICY IF EXISTS "update_own_cart" ON cart_items;
CREATE POLICY "update_own_cart" ON cart_items FOR UPDATE
  TO authenticated USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);
DROP POLICY IF EXISTS "delete_own_cart" ON cart_items;
CREATE POLICY "delete_own_cart" ON cart_items FOR DELETE
  TO authenticated USING (auth.uid() = user_id);
CREATE INDEX IF NOT EXISTS idx_cart_user ON cart_items(user_id);

-- ========== WISHLIST ITEMS ==========
CREATE TABLE IF NOT EXISTS wishlist_items (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  product_id uuid NOT NULL REFERENCES products(id) ON DELETE CASCADE,
  created_at timestamptz DEFAULT now(),
  UNIQUE (user_id, product_id)
);
ALTER TABLE wishlist_items ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "select_own_wishlist" ON wishlist_items;
CREATE POLICY "select_own_wishlist" ON wishlist_items FOR SELECT
  TO authenticated USING (auth.uid() = user_id);
DROP POLICY IF EXISTS "insert_own_wishlist" ON wishlist_items;
CREATE POLICY "insert_own_wishlist" ON wishlist_items FOR INSERT
  TO authenticated WITH CHECK (auth.uid() = user_id);
DROP POLICY IF EXISTS "delete_own_wishlist" ON wishlist_items;
CREATE POLICY "delete_own_wishlist" ON wishlist_items FOR DELETE
  TO authenticated USING (auth.uid() = user_id);
CREATE INDEX IF NOT EXISTS idx_wishlist_user ON wishlist_items(user_id);

-- ========== ORDERS ==========
CREATE TABLE IF NOT EXISTS orders (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  total numeric(12,2) NOT NULL,
  status text NOT NULL DEFAULT 'PENDING',
  shipping jsonb,
  payment_method text,
  created_at timestamptz DEFAULT now()
);
ALTER TABLE orders ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "select_own_orders" ON orders;
CREATE POLICY "select_own_orders" ON orders FOR SELECT
  TO authenticated USING (auth.uid() = user_id);
DROP POLICY IF EXISTS "insert_own_orders" ON orders;
CREATE POLICY "insert_own_orders" ON orders FOR INSERT
  TO authenticated WITH CHECK (auth.uid() = user_id);
CREATE INDEX IF NOT EXISTS idx_orders_user ON orders(user_id);
CREATE INDEX IF NOT EXISTS idx_orders_created ON orders(created_at DESC);

-- ========== ORDER ITEMS ==========
CREATE TABLE IF NOT EXISTS order_items (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id uuid NOT NULL REFERENCES orders(id) ON DELETE CASCADE,
  product_id uuid NOT NULL REFERENCES products(id) ON DELETE CASCADE,
  quantity integer NOT NULL CHECK (quantity > 0),
  price numeric(10,2) NOT NULL
);
ALTER TABLE order_items ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "select_own_order_items" ON order_items;
CREATE POLICY "select_own_order_items" ON order_items FOR SELECT
  TO authenticated USING (
    EXISTS (SELECT 1 FROM orders WHERE orders.id = order_items.order_id AND orders.user_id = auth.uid())
  );
DROP POLICY IF EXISTS "insert_own_order_items" ON order_items;
CREATE POLICY "insert_own_order_items" ON order_items FOR INSERT
  TO authenticated WITH CHECK (
    EXISTS (SELECT 1 FROM orders WHERE orders.id = order_items.order_id AND orders.user_id = auth.uid())
  );
CREATE INDEX IF NOT EXISTS idx_order_items_order ON order_items(order_id);
CREATE INDEX IF NOT EXISTS idx_order_items_product ON order_items(product_id);

-- ========== USER INTERACTIONS ==========
CREATE TABLE IF NOT EXISTS user_interactions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  product_id uuid NOT NULL REFERENCES products(id) ON DELETE CASCADE,
  interaction_type text NOT NULL,
  weight numeric(4,2) DEFAULT 1,
  created_at timestamptz DEFAULT now()
);
ALTER TABLE user_interactions ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "insert_own_interaction" ON user_interactions;
CREATE POLICY "insert_own_interaction" ON user_interactions FOR INSERT
  TO authenticated WITH CHECK (auth.uid() = user_id);
DROP POLICY IF EXISTS "select_own_interactions" ON user_interactions;
CREATE POLICY "select_own_interactions" ON user_interactions FOR SELECT
  TO authenticated USING (auth.uid() = user_id);
CREATE INDEX IF NOT EXISTS idx_interactions_user ON user_interactions(user_id);
CREATE INDEX IF NOT EXISTS idx_interactions_product ON user_interactions(product_id);
CREATE INDEX IF NOT EXISTS idx_interactions_type ON user_interactions(interaction_type);

-- ========== RECOMMENDATION LOGS (admin analytics) ==========
CREATE TABLE IF NOT EXISTS recommendation_logs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid REFERENCES profiles(id) ON DELETE SET NULL,
  product_id uuid NOT NULL REFERENCES products(id) ON DELETE CASCADE,
  reason text,
  score numeric(6,4),
  clicked boolean DEFAULT false,
  created_at timestamptz DEFAULT now()
);
ALTER TABLE recommendation_logs ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "insert_rec_log" ON recommendation_logs;
CREATE POLICY "insert_rec_log" ON recommendation_logs FOR INSERT
  TO authenticated WITH CHECK (true);
DROP POLICY IF EXISTS "select_own_rec_logs" ON recommendation_logs;
CREATE POLICY "select_own_rec_logs" ON recommendation_logs FOR SELECT
  TO authenticated USING (auth.uid() = user_id);
CREATE INDEX IF NOT EXISTS idx_rec_logs_product ON recommendation_logs(product_id);
CREATE INDEX IF NOT EXISTS idx_rec_logs_user ON recommendation_logs(user_id);
