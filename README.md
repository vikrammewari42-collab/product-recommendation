# Luma Market

A polished e-commerce recommendation engine built with React, TypeScript, Vite, Tailwind CSS, Lucide, and Supabase. It works without OpenAI, Gemini, Stripe, Firebase, or any paid API.

## Features

- Responsive storefront with home, catalog, categories, search, filters, sorting, product detail, reviews, wishlist, cart, checkout, account, recommendations, and admin overview.
- Supabase email/password authentication with user and admin profiles.
- Products and categories seeded into the database with realistic sample catalog data.
- Cart, wishlist, reviews, orders, and product-view/cart/wishlist/rating/purchase interaction tracking.
- Simulated card checkout with no real payment processing.
- Local hybrid recommendation logic using interaction weights, category affinity, ratings, reviews, discounts, and popularity signals.
- No external AI or payment credentials required.

## Run locally

```bash
npm install
npm run dev
```

The project uses the Supabase environment values supplied by the Bolt workspace. For another environment, copy `.env.example` and provide the public project URL and anon key.

## Demo accounts

- Admin: `admin@demo.com` / `Admin@123`
- User: `user@demo.com` / `User@123`

## Recommendation approach

Every interaction is stored in `user_interactions` with a weight: view 1, cart 3, wishlist 4, purchase 5, and rating 3. For a signed-in shopper, the app scores products by category affinity, rating quality, review momentum, discount value, and recent activity, then removes products already interacted with. New shoppers receive the highest-rated community products.

## Data model

The database contains categories, products, profiles, reviews, cart items, wishlist items, orders, order items, user interactions, and recommendation logs. Row-level security protects user-owned records while products and categories remain publicly readable.

## Useful commands

```bash
npm run build
npm run typecheck
npm run lint
```

## Future improvements

A production deployment could move checkout stock validation into a database function, add server-side admin mutations, add order-history views, add recommendation click logging, and add scheduled analytics snapshots.
