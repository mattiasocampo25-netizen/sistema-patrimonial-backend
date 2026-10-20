-- =============================================================================
-- 005_rls_cierre_total.sql
-- Cierra las tres ultimas fugas de datos entre usuarios autenticados.
--
-- Contexto (auditoria 2026-10-20, sobre el estado real de produccion):
--   Con la migracion 003, un funcionario ya solo ve los bienes de SU
--   dependencia. Pero las tablas de apoyo seguian abiertas para cualquier
--   usuario autenticado:
--
--     - usuarios.password : los 7 hashes bcrypt de las cuentas (incluida la
--       del admin). La columna es un residuo del esquema de auth anterior:
--       la app autentica con Supabase Auth y NUNCA la lee (solo pide
--       username, nombre, cargo y dependencia).
--     - auditoria : las 289 filas de la traza (quien hizo que y cuando).
--       La vista es admin-only, pero los datos no lo eran.
--     - notificaciones : las 12 filas, con solicitudes de baja de terceros.
--
-- Todas tienen la columna `dependencia` poblada (verificado: 289/289 y
-- 12/12), asi que se aplica el mismo criterio que ya funciona en bens,
-- fc10, fc11 y fc04: los privilegiados (admin / desarrollador) ven todo y
-- el resto, solo su dependencia.
--
-- Idempotente. Aplicar con el rol `postgres`:
--   psql "$DATABASE_URL" -f backend/migrations/005_rls_cierre_total.sql
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 0) Funcion auxiliar: el username del usuario autenticado.
--    (La migracion 003 creo cargo_actual, dependencia_actual y
--     es_privilegiado_actual; esta falta para las politicas de escritura.)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.usuario_actual() RETURNS text
  LANGUAGE sql STABLE SECURITY DEFINER
  SET search_path = public, pg_temp
AS $$
  SELECT u.username
  FROM public.usuarios u
  WHERE lower(u.username) = lower(split_part(coalesce(auth.jwt() ->> 'email', ''), '@', 1))
  LIMIT 1;
$$;

-- -----------------------------------------------------------------------------
-- 1) usuarios: la columna `password` queda fuera del alcance de los
--    autenticados.
--
--    No alcanza con REVOKE SELECT (password): en PostgreSQL, si el rol tiene
--    SELECT a nivel de TABLA, laColumna es accesible igual y el revoke por
--    columna no tiene efecto. Por eso se revoca el SELECT de tabla y se
--    concede por columna, solo para las 4 que la app usa:
--      useRealtimeSync.js  -> 'username, cargo, dependencia'
--      useRealtimeSync.js  -> 'username, nombre, cargo,dependencia'
--      useAuthSession.js   -> 'username, nombre, cargo, dependencia'
--      useAuthSession.js   -> 'cargo'
--    INSERT/UPDATE/DELETE no se tocan: el alta de usuarios sigue igual.
-- -----------------------------------------------------------------------------
REVOKE SELECT ON public.usuarios FROM authenticated;
GRANT SELECT (username, nombre, cargo, dependencia) ON public.usuarios TO authenticated;

-- El rol anónimo no necesita leer usuarios en ningun momento.
REVOKE SELECT ON public.usuarios FROM anon;

-- -----------------------------------------------------------------------------
-- 2) auditoria: lectura por dependencia, escritura acotada y borrado solo
--    para privilegiados.
--    - INSERT: el que registra es el propio usuario (columna `usuario`) o
--      la fila es de su dependencia.asi no se pueden falsificar trazas de
--      otras dependencias.
--    - DELETE: solo los privilegiados (la purga de la vista de auditoria).
-- -----------------------------------------------------------------------------
DROP POLICY IF EXISTS "Autenticados todo auditoria" ON public.auditoria;

CREATE POLICY "Auditoria: privileged leen todo, el resto su dependencia"
  ON public.auditoria
  FOR SELECT TO authenticated
  USING (
    public.es_privilegiado_actual()
    OR lower(coalesce(auditoria.dependencia, '')) = lower(coalesce(public.dependencia_actual(), ''))
  );

CREATE POLICY "Auditoria: cada quien registra lo suyo"
  ON public.auditoria
  FOR INSERT TO authenticated
  WITH CHECK (
    public.es_privilegiado_actual()
    OR lower(coalesce(auditoria.dependencia, '')) = lower(coalesce(public.dependencia_actual(), ''))
    OR lower(coalesce(auditoria.usuario, '')) = lower(coalesce(public.usuario_actual(), ''))
  );

CREATE POLICY "Auditoria: privileged modifican"
  ON public.auditoria
  FOR UPDATE TO authenticated
  USING (public.es_privilegiado_actual())
  WITH CHECK (public.es_privilegiado_actual());

CREATE POLICY "Auditoria: privileged borran"
  ON public.auditoria
  FOR DELETE TO authenticated
  USING (public.es_privilegiado_actual());

-- -----------------------------------------------------------------------------
-- 3) notificaciones: lectura por dependencia.
--    INSERT/UPDATE/DELETE siguen abiertos para los autenticados, pero
--    acotados a su propia dependencia: el alta de una solicitud de baja la
--    hace el funcionario sobre su dependencia, y marcar como leida o purgar
--    una notificacion afecta a la que le corresponde.
-- -----------------------------------------------------------------------------
DROP POLICY IF EXISTS "Autenticados todo notificaciones" ON public.notificaciones;

CREATE POLICY "Notificaciones: privileged leen todo, el resto su dependencia"
  ON public.notificaciones
  FOR SELECT TO authenticated
  USING (
    public.es_privilegiado_actual()
    OR lower(coalesce(notificaciones.data->>'dependencia', '')) = lower(coalesce(public.dependencia_actual(), ''))
  );

CREATE POLICY "Notificaciones: cada quien registra en su dependencia"
  ON public.notificaciones
  FOR INSERT TO authenticated
  WITH CHECK (
    public.es_privilegiado_actual()
    OR lower(coalesce(notificaciones.data->>'dependencia', '')) = lower(coalesce(public.dependencia_actual(), ''))
    OR lower(coalesce(notificaciones.data->>'solicitante', '')) = lower(coalesce(public.usuario_actual(), ''))
  );

CREATE POLICY "Notificaciones: cada quien gestiona las de su dependencia"
  ON public.notificaciones
  FOR UPDATE TO authenticated
  USING (
    public.es_privilegiado_actual()
    OR lower(coalesce(notificaciones.data->>'dependencia', '')) = lower(coalesce(public.dependencia_actual(), ''))
  )
  WITH CHECK (
    public.es_privilegiado_actual()
    OR lower(coalesce(notificaciones.data->>'dependencia', '')) = lower(coalesce(public.dependencia_actual(), ''))
  );

CREATE POLICY "Notificaciones: cada quien purga las de su dependencia"
  ON public.notificaciones
  FOR DELETE TO authenticated
  USING (
    public.es_privilegiado_actual()
    OR lower(coalesce(notificaciones.data->>'dependencia', '')) = lower(coalesce(public.dependencia_actual(), ''))
  );

COMMIT;

-- =============================================================================
-- COMO VERIFICAR (sin tocar nada):
--
--   BEGIN;
--   SET LOCAL role authenticated;
--   SET LOCAL request.jwt.claims = '{"role":"authenticated","email":"biomedicas@unp.edu.py"}';
--   SELECT count(*) FROM public.usuarios;         -- 7 (solo las 4 columnas)
--   SELECT count(*) FROM public.auditoria;         -- solo su dependencia
--   SELECT count(*) FROM public.notificaciones;   -- solo su dependencia
--   SET LOCAL request.jwt.claims = '{"role":"authenticated","email":"lsanchez@unp.edu.py"}';
--   SELECT count(*) FROM public.auditoria;         -- todo (es admin)
--   ROLLBACK;
-- =============================================================================
