-- Crear la cuenta de Supabase Auth de un usuario que tiene perfil en
-- public.usuarios pero todavia no tiene cuenta de Auth.
--
-- Parametros (los mismos para las dos sentencias, sin huecos: PostgreSQL no
-- acepta parametros sin usar):
--   Sentencia 1 (auth.users):      $1 = id uuid, $2 = email, $3 = hash, $4 = timestamp
--   Sentencia 2 (auth.identities): $1 = id uuid, $2 = email, $3 = timestamp, $4 = id uuid
--
-- TRAMPA IMPORTANTE: las columnas de token (confirmation_token,
-- recovery_token, email_change_token_new, email_change) tienen que quedar como
-- CADENA VACIA. Si se dejan en NULL, GoTrue responde 500 "Database error
-- querying schema" al intentar autenticar con esa cuenta.
--
-- OJO: `confirmed_at` (en auth.users) y `email` (en auth.identities) son
-- columnas GENERATED: no se pueden insertar.
INSERT INTO auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
  confirmation_token, recovery_token, email_change_token_new, email_change
) VALUES (
  '00000000-0000-0000-0000-000000000000'::uuid, $1::uuid, 'authenticated', 'authenticated',
  $2::text, $3::text, $4::timestamptz,
  '{"provider":"email","providers":["email"]}'::jsonb,
  '{"email_verified":true}'::jsonb, $4::timestamptz, $4::timestamptz,
  '', '', '', ''
);

-- @@SPLIT@@

INSERT INTO auth.identities (
  id, user_id, provider_id, provider, identity_data,
  last_sign_in_at, created_at, updated_at
) VALUES (
  $4::uuid, $1::uuid, $1::uuid, 'email',
  jsonb_build_object('sub', $1::uuid, 'email', $2::text, 'email_verified', true, 'phone_verified', false),
  $3::timestamptz, $3::timestamptz, $3::timestamptz
);
