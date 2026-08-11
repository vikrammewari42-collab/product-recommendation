/**
 * Hybrid Product Recommendation Engine
 *
 * Combines four strategies without any external AI API:
 *   A. Popularity-based   — weighted interaction scores across all users
 *   B. Content-based       — TF-IDF over product tags/brand/category + cosine similarity
 *   C. Collaborative filtering — user-item interaction matrix, cosine user similarity
 *   D. Recent interaction   — recency-weighted score from the user's own history
 *
 * Final hybrid score (weights configurable below):
 *   0.40 × Content + 0.30 × Collaborative + 0.20 × Popularity + 0.10 × Recent
 */

import { supabase } from './supabase';

export type Product = {
  id: string;
  name: string;
  description: string;
  price: number;
  discount: number;
  brand: string;
  image_url: string;
  stock: number;
  rating: number;
  review_count: number;
  tags: string[];
  category_id: string;
  created_at?: string;
  category?: { name: string; slug: string };
};

export type Interaction = {
  id: string;
  user_id: string;
  product_id: string;
  interaction_type: string;
  weight: number;
  created_at: string;
};

export type RecommendedProduct = Product & {
  recommendationScore: number;
  recommendationReason: string;
};

/** Interaction type weights — purchase 5, wishlist 4, cart 3, rating 3, view 1 */
export const INTERACTION_WEIGHTS: Record<string, number> = {
  VIEW: 1,
  CART: 3,
  WISHLIST: 4,
  PURCHASE: 5,
  RATING: 3,
};

/** Hybrid score weights — adjust here to tune the engine */
export const HYBRID_WEIGHTS = {
  content: 0.4,
  collaborative: 0.3,
  popularity: 0.2,
  recent: 0.1,
};

/** TF-IDF tokenization: extract keywords from a product's text fields */
function tokenize(product: Product): string[] {
  const text = [
    product.name,
    product.description ?? '',
    product.brand ?? '',
    ...(product.tags ?? []),
    product.category?.name ?? '',
  ]
    .join(' ')
    .toLowerCase();
  return text
    .split(/[^a-z0-9]+/)
    .filter((t) => t.length > 2);
}

/** Build a TF-IDF vector for each product and compute cosine similarity */
function buildContentModel(products: Product[]) {
  const documents = products.map((p) => tokenize(p));
  const vocab = new Map<string, number>();
  for (const tokens of documents) {
    for (const token of new Set(tokens)) {
      vocab.set(token, (vocab.get(token) ?? 0) + 1);
    }
  }
  const N = products.length;
  const idf = new Map<string, number>();
  for (const [token, df] of vocab) {
    idf.set(token, Math.log(N / (df + 1)) + 1);
  }

  const vectors = documents.map((tokens) => {
    const vec = new Map<string, number>();
    for (const token of tokens) {
      vec.set(token, (vec.get(token) ?? 0) + 1);
    }
    let norm = 0;
    for (const [token, tf] of vec) {
      const weight = tf * (idf.get(token) ?? 0);
      vec.set(token, weight);
      norm += weight * weight;
    }
    norm = Math.sqrt(norm) || 1;
    for (const [token, weight] of vec) {
      vec.set(token, weight / norm);
    }
    return vec;
  });

  return { vectors };
}

/** Cosine similarity between two sparse vectors */
function cosineSimilarity(a: Map<string, number>, b: Map<string, number>): number {
  let dot = 0;
  const smaller = a.size < b.size ? a : b;
  const larger = a.size < b.size ? b : a;
  for (const [key, val] of smaller) {
    const other = larger.get(key);
    if (other !== undefined) dot += val * other;
  }
  return dot;
}

/** Build a user-item interaction matrix for collaborative filtering */
function buildCollaborativeModel(interactions: Interaction[], products: Product[]) {
  const productIds = new Set(products.map((p) => p.id));
  const userVectors = new Map<string, Map<string, number>>();

  for (const interaction of interactions) {
    if (!productIds.has(interaction.product_id)) continue;
    const weight = INTERACTION_WEIGHTS[interaction.interaction_type] ?? 1;
    const userVec = userVectors.get(interaction.user_id) ?? new Map<string, number>();
    userVec.set(
      interaction.product_id,
      (userVec.get(interaction.product_id) ?? 0) + weight,
    );
    userVectors.set(interaction.user_id, userVec);
  }

  return { userVectors };
}

/** Find similar users via cosine similarity on their interaction vectors */
function findSimilarUsers(
  targetUserId: string,
  userVectors: Map<string, Map<string, number>>,
  maxNeighbors = 5,
): string[] {
  const target = userVectors.get(targetUserId);
  if (!target || target.size === 0) return [];

  const similarities: Array<{ userId: string; score: number }> = [];
  for (const [userId, vec] of userVectors) {
    if (userId === targetUserId) continue;
    const sim = cosineSimilarity(target, vec);
    if (sim > 0) similarities.push({ userId, score: sim });
  }
  similarities.sort((a, b) => b.score - a.score);
  return similarities.slice(0, maxNeighbors).map((s) => s.userId);
}

/** Main entry: get personalized recommendations for a user */
export async function getRecommendations(
  userId: string,
  limit = 8,
): Promise<RecommendedProduct[]> {
  const [{ data: productsData }, { data: interactionsData }] = await Promise.all([
    supabase.from('products').select('*, category:categories(name, slug)'),
    supabase.from('user_interactions').select('*').order('created_at', { ascending: false }),
  ]);

  const products = (productsData ?? []) as Product[];
  const allInteractions = (interactionsData ?? []) as Interaction[];
  const userInteractions = allInteractions.filter((i) => i.user_id === userId);

  // Cold start: no interaction history → return top-rated + popular
  if (userInteractions.length === 0) {
    return products
      .slice()
      .sort((a, b) => b.rating - a.rating || b.review_count - a.review_count)
      .slice(0, limit)
      .map((p) => ({
        ...p,
        recommendationScore: p.rating / 5,
        recommendationReason: 'Trending now',
      }));
  }

  const contentModel = buildContentModel(products);
  const collabModel = buildCollaborativeModel(allInteractions, products);

  // Products the user has already interacted with
  const interactedIds = new Set(userInteractions.map((i) => i.product_id));

  // Category affinity from user's own interactions
  const categoryScores: Record<string, number> = {};
  for (const interaction of userInteractions) {
    const product = products.find((p) => p.id === interaction.product_id);
    if (product) {
      const w = INTERACTION_WEIGHTS[interaction.interaction_type] ?? 1;
      categoryScores[product.category_id] =
        (categoryScores[product.category_id] ?? 0) + w;
    }
  }
  const topCategory = Object.entries(categoryScores).sort(([, a], [, b]) => b - a)[0]?.[0];
  const topCategoryName = products.find((p) => p.category_id === topCategory)?.category?.name;

  // Collaborative: find similar users, collect their interacted products
  const similarUserIds = findSimilarUsers(userId, collabModel.userVectors);
  const collabProductScores: Record<string, number> = {};
  for (const simUserId of similarUserIds) {
    const simVec = collabModel.userVectors.get(simUserId);
    if (!simVec) continue;
    for (const [productId, score] of simVec) {
      if (!interactedIds.has(productId)) {
        collabProductScores[productId] = (collabProductScores[productId] ?? 0) + score;
      }
    }
  }
  const maxCollab = Math.max(...Object.values(collabProductScores), 1);

  // Popularity: aggregate all interactions
  const popularityScores: Record<string, number> = {};
  for (const interaction of allInteractions) {
    const w = INTERACTION_WEIGHTS[interaction.interaction_type] ?? 1;
    popularityScores[interaction.product_id] =
      (popularityScores[interaction.product_id] ?? 0) + w;
  }
  const maxPopularity = Math.max(...Object.values(popularityScores), 1);

  // Recent interaction: recency-weighted score from user's own history
  const now = Date.now();
  const recentScores: Record<string, number> = {};
  for (const interaction of userInteractions) {
    const age = (now - new Date(interaction.created_at).getTime()) / (1000 * 60 * 60 * 24);
    const recencyWeight = 1 / (1 + age);
    const w = INTERACTION_WEIGHTS[interaction.interaction_type] ?? 1;
    // Score products in the same category as recently interacted products
    const product = products.find((p) => p.id === interaction.product_id);
    if (product) {
      for (const candidate of products) {
        if (candidate.category_id === product.category_id && !interactedIds.has(candidate.id)) {
          recentScores[candidate.id] = (recentScores[candidate.id] ?? 0) + w * recencyWeight;
        }
      }
    }
  }
  const maxRecent = Math.max(...Object.values(recentScores), 1);

  // Content: build a user profile vector from interacted products, then compare
  const userProfile = new Map<string, number>();
  for (const interaction of userInteractions) {
    const productIdx = products.findIndex((p) => p.id === interaction.product_id);
    if (productIdx === -1) continue;
    const w = INTERACTION_WEIGHTS[interaction.interaction_type] ?? 1;
    const vec = contentModel.vectors[productIdx];
    for (const [token, weight] of vec) {
      userProfile.set(token, (userProfile.get(token) ?? 0) + weight * w);
    }
  }
  // Normalize user profile
  let profileNorm = 0;
  for (const weight of userProfile.values()) profileNorm += weight * weight;
  profileNorm = Math.sqrt(profileNorm) || 1;
  for (const [token, weight] of userProfile) {
    userProfile.set(token, weight / profileNorm);
  }

  // Compute hybrid score for each candidate product
  const scored = products
    .filter((p) => !interactedIds.has(p.id) && p.stock > 0)
    .map((p) => {
      const idx = products.findIndex((x) => x.id === p.id);

      // Content score: cosine similarity between user profile and product vector
      let contentScore = 0;
      if (userProfile.size > 0) {
        contentScore = cosineSimilarity(userProfile, contentModel.vectors[idx]);
      }

      // Collaborative score
      const collaborativeScore = (collabProductScores[p.id] ?? 0) / maxCollab;

      // Popularity score (normalized + rating boost)
      const popularityScore =
        (popularityScores[p.id] ?? 0) / maxPopularity * 0.7 + (p.rating / 5) * 0.3;

      // Recent score
      const recentScore = (recentScores[p.id] ?? 0) / maxRecent;

      const hybrid =
        HYBRID_WEIGHTS.content * contentScore +
        HYBRID_WEIGHTS.collaborative * collaborativeScore +
        HYBRID_WEIGHTS.popularity * popularityScore +
        HYBRID_WEIGHTS.recent * recentScore;

      // Generate human-readable reason
      let reason = 'Based on your recent activity';
      if (collaborativeScore > 0.5) reason = 'Popular among similar users';
      else if (p.category_id === topCategory && topCategoryName) reason = `Because you viewed ${topCategoryName}`;
      else if (contentScore > 0.3) reason = 'Similar to products you liked';
      else if (popularityScore > 0.6) reason = 'Trending now';

      return {
        ...p,
        recommendationScore: hybrid,
        recommendationReason: reason,
      };
    })
    .sort((a, b) => b.recommendationScore - a.recommendationScore)
    .slice(0, limit);

  return scored;
}

/** Get trending products based on recent interaction volume */
export async function getTrending(limit = 8): Promise<Product[]> {
  const { data: interactions } = await supabase
    .from('user_interactions')
    .select('product_id, interaction_type, created_at')
    .gte('created_at', new Date(Date.now() - 30 * 24 * 60 * 60 * 1000).toISOString());

  const scores: Record<string, number> = {};
  for (const interaction of interactions ?? []) {
    const w = INTERACTION_WEIGHTS[interaction.interaction_type] ?? 1;
    scores[interaction.product_id] = (scores[interaction.product_id] ?? 0) + w;
  }

  const { data: products } = await supabase
    .from('products')
    .select('*, category:categories(name, slug)')
    .order('rating', { ascending: false });

  return (products as Product[] ?? [])
    .sort((a, b) => (scores[b.id] ?? 0) - (scores[a.id] ?? 0))
    .slice(0, limit);
}

/** Get similar products (same category, similar tags) */
export async function getSimilarProducts(productId: string, limit = 4): Promise<Product[]> {
  const { data: product } = await supabase
    .from('products')
    .select('*, category:categories(name, slug)')
    .eq('id', productId)
    .maybeSingle();

  if (!product) return [];

  const { data: products } = await supabase
    .from('products')
    .select('*, category:categories(name, slug)')
    .eq('category_id', (product as Product).category_id)
    .neq('id', productId)
    .limit(limit);

  return (products as Product[] ?? []).slice(0, limit);
}
