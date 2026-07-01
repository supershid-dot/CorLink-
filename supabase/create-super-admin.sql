-- ============================================================
-- CorLink — Create Super Admin User
-- Run in Supabase SQL editor AFTER schema.sql, rls.sql, seed.sql.
-- Updated for the user_assignments (multi-role/multi-section) model.
-- ============================================================

DO $$
DECLARE
  v_user_id UUID := gen_random_uuid();
BEGIN

  -- Create Supabase Auth user (login: 10108@corlink.internal)
  INSERT INTO auth.users (
    id, instance_id, aud, role,
    email, encrypted_password,
    email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data,
    created_at, updated_at,
    confirmation_token, recovery_token,
    email_change_token_new, email_change
  ) VALUES (
    v_user_id,
    '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated',
    '10108@corlink.internal',
    crypt('Nilandhoo@1236', gen_salt('bf')),
    NOW(),
    '{"provider":"email","providers":["email"]}', '{}',
    NOW(), NOW(),
    '', '', '', ''
  );

  -- Auth identity record (required for sign-in)
  INSERT INTO auth.identities (
    id, provider_id, user_id,
    identity_data, provider,
    last_sign_in_at, created_at, updated_at
  ) VALUES (
    gen_random_uuid(),
    '10108@corlink.internal',
    v_user_id,
    jsonb_build_object('sub', v_user_id::text, 'email', '10108@corlink.internal'),
    'email',
    NOW(), NOW(), NOW()
  );

  -- CorLink user profile — super admin is a system-wide flag,
  -- NOT a section-scoped assignment. No user_assignments row needed.
  INSERT INTO public.users (
    id, org_id,
    service_number, full_name, email, is_super_admin
  ) VALUES (
    v_user_id,
    '00000000-0000-0000-0000-000000000001',  -- MCS org
    '10108',
    'Ibrahim Nashid',
    'supershid@gmail.com',
    TRUE
  );

  RAISE NOTICE 'Super admin created. User ID: %', v_user_id;
END $$;
