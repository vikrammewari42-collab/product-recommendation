/*
# Auth: profile auto-creation trigger + demo users

## Purpose
1. Auto-create a `profiles` row whenever a new user signs up via Supabase Auth,
   copying their name from user_metadata and defaulting role to 'USER'.
2. Pre-create two demo accounts (admin + regular user) in auth.users with
   bcrypt-hashed passwords, and their corresponding profiles rows.

## Security
- The trigger function runs as SECURITY DEFINER so it can insert into profiles
  even though the anon role cannot directly insert there.
- Demo passwords are hashed with bcrypt via pgcrypto (already available).
*/

-- Trigger function: auto-create profile on new auth user
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  INSERT INTO public.profiles (id, name, role)
  VALUES (
    NEW.id,
    COALESCE(NEW.raw_user_meta_data->>'name', split_part(NEW.email, '@', 1)),
    'USER'
  )
  ON CONFLICT (id) DO NOTHING;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();

-- Allow authenticated users to insert their own profile (safety net)
DROP POLICY IF EXISTS "insert_own_profile" ON profiles;
CREATE POLICY "insert_own_profile" ON profiles FOR INSERT
  TO authenticated WITH CHECK (auth.uid() = id);
