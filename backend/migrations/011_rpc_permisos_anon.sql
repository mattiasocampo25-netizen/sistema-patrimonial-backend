-- =============================================================================
-- 011_rpc_permisos_anon.sql
-- Quita el EXECUTE sobre anon de las funciones SECURITY DEFINER.
--
-- QUE PASABA (auditoria 2026-10-22, sobre el estado real de produccion)
-- ---------------------------------------------------------------------------
-- Las migraciones 003, 005, 006 y 007 crean funciones `SECURITY DEFINER` y
-- hacen `REVOKE ALL ... FROM PUBLIC` + `GRANT EXECUTE ... TO authenticated`.
-- Pero el `proacl` real de la base mostraba esto:
--
--   cargo_actual             {=X/postgres, postgres=X, anon=X, authenticated=X, service_role=X}
--   dependencia_actual       {=X/postgres, postgres=X, anon=X, authenticated=X, service_role=X}
--   es_privilegiado_actual   {=X/postgres, postgres=X, anon=X, authenticated=X, service_role=X}
--   usuario_actual           {=X/postgres, postgres=X, anon=X, authenticated=X, service_role=X}
--   resumen_por_dependencia  {postgres=X, anon=X, authenticated=X, service_role=X}
--   admin_guardar_usuario    {postgres=X, anon=X, authenticated=X, service_role=X}
--
-- O sea: `anon` puede ejecutarlas, y tres de ellas siguen con el permiso
-- abierto a PUBLIC (`=X/postgres`).
--
-- Por que paso: los `ALTER DEFAULT PRIVILEGES` de Supabase en el esquema
-- `public` otorgan EXECUTE sobre las funciones nuevas a `anon`,
-- `authenticated` y `service_role`. Esos defaults se aplican DESPUES del
-- `CREATE OR REPLACE FUNCTION` de cada migracion, en el mismo despliegue, y
-- por eso el `REVOKE` de la migracion se queda corto: hay que revocar de
-- nuevo, contra el rol concreto, DESPUES de que la funcion exista.
--
-- IMPACTO REAL (verificado, no teorico)
-- ---------------------------------------------------------------------------
-- Ninguno directo: las funciones se auto-protegen.
--   - `admin_guardar_usuario` -> `es_privilegiado_actual()` devuelve false
--     sin sesion y la funcion lanza 42501 ("solo un administrador puede
--     guardar usuarios").
--   - `resumen_por_dependencia` -> sin sesion devuelve `[]`.
--   - las cuatro funciones de contexto devuelven NULL sin sesion.
--
-- Pero "se auto-protegen" no es lo mismo que "no se pueda llamar": la
-- superficie queda abierta para un atacante que encuentre otra combinacion
-- (un `search_path` manipulado, un cambio futuro en el cuerpo de la funcion,
-- o simplemente una llamada que sí devuelva datos). Lo que hace esta
-- migracion es dejar la superficie en cero en vez de confiar en el codigo.
--
-- EXCEPCION INTENCIONAL
-- ---------------------------------------------------------------------------
-- `obtener_bien_publico` SI debe quedar ejecutable por `anon`: es la que
-- atiende la vista publica del QR, que existe justamente para visitantes sin
-- sesion. Se le deja EXECUTE para anon y authenticated.
--
-- Idempotente. Aplicar con el rol `postgres`:
--   psql "$DATABASE_URL" -f backend/migrations/011_rpc_permisos_anon.sql
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 1) Funciones de contexto.
--    `authenticated` las necesita: lasPolicies RLS las invocan al evaluar
--    cada fila (migraciones 003 y 005).
-- -----------------------------------------------------------------------------
REVOKE EXECUTE ON FUNCTION public.cargo_actual() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.cargo_actual() FROM anon;
GRANT  EXECUTE ON FUNCTION public.cargo_actual() TO authenticated;

REVOKE EXECUTE ON FUNCTION public.dependencia_actual() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.dependencia_actual() FROM anon;
GRANT  EXECUTE ON FUNCTION public.dependencia_actual() TO authenticated;

REVOKE EXECUTE ON FUNCTION public.es_privilegiado_actual() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.es_privilegiado_actual() FROM anon;
GRANT  EXECUTE ON FUNCTION public.es_privilegiado_actual() TO authenticated;

REVOKE EXECUTE ON FUNCTION public.usuario_actual() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.usuario_actual() FROM anon;
GRANT  EXECUTE ON FUNCTION public.usuario_actual() TO authenticated;

-- -----------------------------------------------------------------------------
-- 2) RPC de resumen y de alta de usuarios: solo para quien tiene sesion.
-- -----------------------------------------------------------------------------
REVOKE EXECUTE ON FUNCTION public.resumen_por_dependencia() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.resumen_por_dependencia() FROM anon;
GRANT  EXECUTE ON FUNCTION public.resumen_por_dependencia() TO authenticated;

REVOKE EXECUTE ON FUNCTION public.admin_guardar_usuario(text, text, text, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.admin_guardar_usuario(text, text, text, text) FROM anon;
GRANT  EXECUTE ON FUNCTION public.admin_guardar_usuario(text, text, text, text) TO authenticated;

-- -----------------------------------------------------------------------------
-- 3) La vista publica del QR: EXECUTE para anon, a proposito.
-- -----------------------------------------------------------------------------
REVOKE EXECUTE ON FUNCTION public.obtener_bien_publico(text) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.obtener_bien_publico(text) TO anon, authenticated;

-- -----------------------------------------------------------------------------
-- 4) `verificar_login` quedo revocada para PUBLIC y anon en la migracion 002
--    (proacl: {postgres=X, authenticated=X, service_role=X}). Se deja como
--    esta: no se usa desde la app y no se le abre nada.
-- -----------------------------------------------------------------------------

COMMIT;

-- =============================================================================
-- COMO VERIFICAR (sin tocar nada):
--
--   SELECT p.proname, p.proacl::text
--   FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
--   WHERE n.nspname = 'public' ORDER BY p.proname;
--
--   -> en ninguna proacl debe aparecer `anon=X` salvo en obtener_bien_publico,
--      ni `=X/postgres` (PUBLIC) en ninguna.
--
-- ROLLBACK:
--
--   BEGIN;
--   GRANT EXECUTE ON FUNCTION public.cargo_actual() TO anon, PUBLIC;
--   GRANT EXECUTE ON FUNCTION public.dependencia_actual() TO anon, PUBLIC;
--   GRANT EXECUTE ON FUNCTION public.es_privilegiado_actual() TO anon, PUBLIC;
--   GRANT EXECUTE ON FUNCTION public.usuario_actual() TO anon, PUBLIC;
--   GRANT EXECUTE ON FUNCTION public.resumen_por_dependencia() TO anon;
--   GRANT EXECUTE ON FUNCTION public.admin_guardar_usuario(text, text, text, text) TO anon;
--   COMMIT;
-- =============================================================================
