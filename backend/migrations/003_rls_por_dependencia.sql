-- =============================================================================
-- 003_rls_por_dependencia.sql
-- Un funcionario solo ve los bienes de SU dependencia. Los roles privilegiados
-- (admin / desarrollador) siguen viendo todo, porque el panel de administración
-- permite cambiar de dependencia de trabajo.
--
-- Contexto (auditoria 2026-10-20):
--   El frontend SIEMPRE filtra por dependencia al pedir datos
--   (.eq('data->>dependencia', dependenciaActual)), pero eso es solo del lado
--   del cliente: cualquier usuario autenticado podia cambiar el filtro a mano
--   y leer los 13.673 bienes de las 8 dependencias.
--   Esta migracion lo cierra en el servidor.
--
--   Mapeo verificado en produccion: el email de Supabase Auth es exactamente
--   <username>@unp.edu.py y `usuarios.username` coincide. Hay 6 usuarios en
--   auth.users y 7 filas en `usuarios` (jsanchez no tiene cuenta de Auth, asi
--   que nunca puede entrar).
--
--   Verificado tambien que las 8 dependencias del catalogo coinciden
--   exactamente con `bens.data->>'dependencia'`, asi que un funcionario
--   siempre ve los bienes de su dependencia.
--
-- Idempotente. Aplicar con el rol `postgres`:
--   psql "$DATABASE_URL" -f backend/migrations/003_rls_por_dependencia.sql
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 1) Funciones de contexto.
--    SECURITY DEFINER: leen `usuarios`, que tiene RLS propio (solo
--    autenticados), asi que sin esto un funcionario no podria leerse a si
--    mismo dentro de la politica.
--    STABLE: PostgreSQL las evalua una vez por sentencia, no una vez por fila.
--    SET search_path: evita que alguienNoblexecute un objeto malicioso desde
--    otro esquema.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.cargo_actual() RETURNS text
  LANGUAGE sql STABLE SECURITY DEFINER
  SET search_path = public, pg_temp
AS $$
  SELECT u.cargo
  FROM public.usuarios u
  WHERE lower(u.username) = lower(split_part(coalesce(auth.jwt() ->> 'email', ''), '@', 1))
  LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION public.dependencia_actual() RETURNS text
  LANGUAGE sql STABLE SECURITY DEFINER
  SET search_path = public, pg_temp
AS $$
  SELECT u.dependencia
  FROM public.usuarios u
  WHERE lower(u.username) = lower(split_part(coalesce(auth.jwt() ->> 'email', ''), '@', 1))
  LIMIT 1;
$$;

-- Los mismos roles que el backend (lib/helpers.js -> esPrivilegiado) y que el
-- frontend (utils/postgrest.js -> rolEsPrivilegiado).
CREATE OR REPLACE FUNCTION public.es_privilegiado_actual() RETURNS boolean
  LANGUAGE sql STABLE SECURITY DEFINER
  SET search_path = public, pg_temp
AS $$
  SELECT coalesce(public.cargo_actual() IN ('admin', 'desarrollador', 'dev'), false);
$$;

-- -----------------------------------------------------------------------------
-- 2) bens
--
-- IMPORTANTE: la politica de lectura publica estaba como `TO public`, y las
-- politicas permisivas del mismo comando se combinan con OR. Eso hacia que
-- "Lectura publica bens" (USING true) le abriera TODAS las filas a los
-- autenticados y anulase por completo la restriccion por dependencia.
-- Hay que dejarla solo para `anon`: los autenticados pasan por la politica
-- de dependencia.
-- -----------------------------------------------------------------------------
DROP POLICY IF EXISTS "Lectura publica bens" ON public.bens;
CREATE POLICY "Lectura publica bens" ON public.bens
  FOR SELECT TO anon
  USING (true);

DROP POLICY IF EXISTS "Autenticados todo bens" ON public.bens;
DROP POLICY IF EXISTS "Bienes: admin ve todo, funcionario solo su dependencia" ON public.bens;

CREATE POLICY "Bienes: admin ve todo, funcionario solo su dependencia"
  ON public.bens
  FOR ALL TO authenticated
  USING (
    public.es_privilegiado_actual()
    OR lower(coalesce(bens.data ->> 'dependencia', ''))
       = lower(coalesce(public.dependencia_actual(), ''))
  )
  WITH CHECK (
    public.es_privilegiado_actual()
    OR lower(coalesce(bens.data ->> 'dependencia', ''))
       = lower(coalesce(public.dependencia_actual(), ''))
  );

-- -----------------------------------------------------------------------------
-- 3) fc10 y fc04: misma dependencia en `data->>'dependencia'`.
-- -----------------------------------------------------------------------------
DROP POLICY IF EXISTS "Autenticados todo fc10" ON public.fc10;
DROP POLICY IF EXISTS "FC-10: admin ve todo, funcionario solo su dependencia" ON public.fc10;

CREATE POLICY "FC-10: admin ve todo, funcionario solo su dependencia"
  ON public.fc10
  FOR ALL TO authenticated
  USING (
    public.es_privilegiado_actual()
    OR lower(coalesce(fc10.data ->> 'dependencia', ''))
       = lower(coalesce(public.dependencia_actual(), ''))
  )
  WITH CHECK (
    public.es_privilegiado_actual()
    OR lower(coalesce(fc10.data ->> 'dependencia', ''))
       = lower(coalesce(public.dependencia_actual(), ''))
  );

DROP POLICY IF EXISTS "Autenticados todo fc04" ON public.fc04;
DROP POLICY IF EXISTS "FC-04: admin ve todo, funcionario solo su dependencia" ON public.fc04;

CREATE POLICY "FC-04: admin ve todo, funcionario solo su dependencia"
  ON public.fc04
  FOR ALL TO authenticated
  USING (
    public.es_privilegiado_actual()
    OR lower(coalesce(fc04.data ->> 'dependencia', ''))
       = lower(coalesce(public.dependencia_actual(), ''))
  )
  WITH CHECK (
    public.es_privilegiado_actual()
    OR lower(coalesce(fc04.data ->> 'dependencia', ''))
       = lower(coalesce(public.dependencia_actual(), ''))
  );

-- -----------------------------------------------------------------------------
-- 4) fc11: la dependencia puede estar en el origen o en el destino.
--    El frontend la pide con
--    .or('data->>dependenciaRemitente.eq.X,data->>dependenciaDestinataria.eq.X')
-- -----------------------------------------------------------------------------
DROP POLICY IF EXISTS "Autenticados todo fc11" ON public.fc11;
DROP POLICY IF EXISTS "FC-11: admin ve todo, funcionario solo su dependencia (origen o destino)" ON public.fc11;

CREATE POLICY "FC-11: admin ve todo, funcionario solo su dependencia (origen o destino)"
  ON public.fc11
  FOR ALL TO authenticated
  USING (
    public.es_privilegiado_actual()
    OR lower(coalesce(fc11.data ->> 'dependenciaRemitente', ''))
       = lower(coalesce(public.dependencia_actual(), ''))
    OR lower(coalesce(fc11.data ->> 'dependenciaDestinataria', ''))
       = lower(coalesce(public.dependencia_actual(), ''))
  )
  WITH CHECK (
    public.es_privilegiado_actual()
    OR lower(coalesce(fc11.data ->> 'dependenciaRemitente', ''))
       = lower(coalesce(public.dependencia_actual(), ''))
    OR lower(coalesce(fc11.data ->> 'dependenciaDestinataria', ''))
       = lower(coalesce(public.dependencia_actual(), ''))
  );

COMMIT;

-- =============================================================================
-- COMO VERIFICAR (sin tocar nada):
--
--   BEGIN;
--   SET LOCAL role authenticated;
--   SET LOCAL request.jwt.claims = '{"role":"authenticated","email":"biomedicas@unp.edu.py"}';
--   SELECT count(*) FROM bens;   -- solo su dependencia
--   SET LOCAL request.jwt.claims = '{"role":"authenticated","email":"lsanchez@unp.edu.py"}';
--   SELECT count(*) FROM bens;   -- admin: todas
--   ROLLBACK;
--
-- ROLLBACK: el usuario con cargo 'user' queda limitado a su dependencia.
-- Para revertir del todo, volver a crear las politicas originales:
--
--   DROP POLICY IF EXISTS "Bienes: admin ve todo, funcionario solo su dependencia" ON public.bens;
--   CREATE POLICY "Autenticados todo bens" ON public.bens
--     FOR ALL TO public USING (auth.role() = 'authenticated');
--   (idem para fc10, fc11, fc04)
-- =============================================================================
