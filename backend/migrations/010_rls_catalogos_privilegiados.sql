-- =============================================================================
-- 010_rls_catalogos_privilegiados.sql
-- Cierra la escritura de los catalogos y del muro de mantenimiento.
--
-- QUE PASABA (auditoria 2026-10-22, sobre el estado real de produccion)
-- ---------------------------------------------------------------------------
-- Las tablas de apoyo tenian la politica original "Autenticados todo X", que
-- es `cmd=ALL` con `TO public`. Eso no era solo una lectura generosa: era
-- escritura para CUALQUIER usuario autenticado. Verificado con el JWT de un
-- funcionario (cargo 'user'):
--
--   INSERT dependencias   -> PERMITIDO
--   UPDATE dependencias   -> PERMITIDO
--   DELETE dependencias   -> PERMITIDO
--   UPDATE ubicaciones    -> PERMITIDO
--   INSERT estructuras    -> PERMITIDO
--   DELETE estructuras    -> PERMITIDO
--   UPDATE app_config     -> PERMITIDO   <-- el muro de mantenimiento
--
-- El ultimo es el mas grave: `app_config` guarda `en_mantenamiento`, el
-- `mensaje` global y las `mejoras`. Un funcionario cualquiera podia dejar el
-- sistema en mantenimiento o cambiar el mensaje que ve toda la universidad.
--
-- `app_config` tenia ademas la politica "Lectura publica app_config"
-- (`TO public`, `USING true`): el anonimo leia la configuracion global.
--
-- QUE SE MANTIENE Y POR QUE
-- ---------------------------------------------------------------------------
-- * LECTURA: se mantiene amplia a proposito. Son catalogos transversales sin
--   datos personales:
--     - `dependencias` (8 filas): el selector de dependencia, el sidebar.
--     - `estructuras` (48 filas): el organigrama oficial.
--     - `ubicaciones` (76 filas): el catalogo de ubicaciones. Se acota por
--       dependencia porque la columna existe, pero hoy las 76 son de
--       "Rectorado" y la UI ya las filtraba en cliente (App.jsx:338), asi que
--       no cambia lo que se ve.
--     - `app_config`: la lectura publica se mantiene A PROPOSITO. El muro de
--       mantenimiento se consulta ANTES del login (useAuthSession.js:45), con
--       la anon key: si se cerrara, un visitante sin sesion no veria el aviso
--       de mantenimiento. No contiene datos sensibles: solo el estado, el
--       mensaje y las notas de version.
--
-- * ESCRITURA: se cierra a los roles privilegiados, que son los unicos que
--   la UI habilita (el boton "Ubicaciones" esta guardado con `isAdmin &&` en
--   FuncionariosView.jsx:64 y el de dependencias, con `isAdmin` en AppSidebar).
--
-- * EXCEPCION - `estructuras`: el INSERT se deja abierto. Al guardar un FC-10
--   el sistema agrega solo las unidades que faltan del organigrama
--   (useFcModals.js:761, dentro de un `catch {}` silencioso). Cerrarlo no
--   romperia el FC-10, pero dejaria de crecer el catalogo. Lo que si se
--   cierra es UPDATE y DELETE, que si alteran el organigrama.
--
-- Idempotente. Aplicar con el rol `postgres`:
--   psql "$DATABASE_URL" -f backend/migrations/010_rls_catalogos_privilegiados.sql
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 1) dependencias: catalogo maestro de la universidad.
-- -----------------------------------------------------------------------------
DROP POLICY IF EXISTS "Autenticados todo dependencias" ON public.dependencias;

DROP POLICY IF EXISTS "Dependencias: lectura para los autenticados" ON public.dependencias;
CREATE POLICY "Dependencias: lectura para los autenticados"
  ON public.dependencias
  FOR SELECT TO authenticated
  USING (true);

DROP POLICY IF EXISTS "Dependencias: solo privileged agregan" ON public.dependencias;
CREATE POLICY "Dependencias: solo privileged agregan"
  ON public.dependencias
  FOR INSERT TO authenticated
  WITH CHECK (public.es_privilegiado_actual());

DROP POLICY IF EXISTS "Dependencias: solo privileged modifican" ON public.dependencias;
CREATE POLICY "Dependencias: solo privileged modifican"
  ON public.dependencias
  FOR UPDATE TO authenticated
  USING (public.es_privilegiado_actual())
  WITH CHECK (public.es_privilegiado_actual());

DROP POLICY IF EXISTS "Dependencias: solo privileged borran" ON public.dependencias;
CREATE POLICY "Dependencias: solo privileged borran"
  ON public.dependencias
  FOR DELETE TO authenticated
  USING (public.es_privilegiado_actual());

-- -----------------------------------------------------------------------------
-- 2) ubicaciones: el catalogo tiene columna `dependencia`, asi que la lectura
--    se acota con el mismo criterio del resto del sistema.
-- -----------------------------------------------------------------------------
DROP POLICY IF EXISTS "Autenticados todo ubicaciones" ON public.ubicaciones;

DROP POLICY IF EXISTS "Ubicaciones: privileged leen todo, el resto su dependencia" ON public.ubicaciones;
CREATE POLICY "Ubicaciones: privileged leen todo, el resto su dependencia"
  ON public.ubicaciones
  FOR SELECT TO authenticated
  USING (
    public.es_privilegiado_actual()
    OR lower(coalesce(ubicaciones.dependencia, '')) = lower(coalesce(public.dependencia_actual(), ''))
  );

DROP POLICY IF EXISTS "Ubicaciones: solo privileged agregan" ON public.ubicaciones;
CREATE POLICY "Ubicaciones: solo privileged agregan"
  ON public.ubicaciones
  FOR INSERT TO authenticated
  WITH CHECK (public.es_privilegiado_actual());

DROP POLICY IF EXISTS "Ubicaciones: solo privileged modifican" ON public.ubicaciones;
CREATE POLICY "Ubicaciones: solo privileged modifican"
  ON public.ubicaciones
  FOR UPDATE TO authenticated
  USING (public.es_privilegiado_actual())
  WITH CHECK (public.es_privilegiado_actual());

DROP POLICY IF EXISTS "Ubicaciones: solo privileged borran" ON public.ubicaciones;
CREATE POLICY "Ubicaciones: solo privileged borran"
  ON public.ubicaciones
  FOR DELETE TO authenticated
  USING (public.es_privilegiado_actual());

-- -----------------------------------------------------------------------------
-- 3) estructuras: organigrama oficial.
--    INSERT abierto (compatibilidad con el alta automatica al guardar un
--    FC-10). UPDATE y DELETE solo para privilegiados.
-- -----------------------------------------------------------------------------
DROP POLICY IF EXISTS "Autenticados todo estructuras" ON public.estructuras;

DROP POLICY IF EXISTS "Estructuras: lectura para los autenticados" ON public.estructuras;
CREATE POLICY "Estructuras: lectura para los autenticados"
  ON public.estructuras
  FOR SELECT TO authenticated
  USING (true);

DROP POLICY IF EXISTS "Estructuras: cualquiera puede proponer una unidad" ON public.estructuras;
CREATE POLICY "Estructuras: cualquiera puede proponer una unidad"
  ON public.estructuras
  FOR INSERT TO authenticated
  WITH CHECK (true);

DROP POLICY IF EXISTS "Estructuras: solo privileged modifican" ON public.estructuras;
CREATE POLICY "Estructuras: solo privileged modifican"
  ON public.estructuras
  FOR UPDATE TO authenticated
  USING (public.es_privilegiado_actual())
  WITH CHECK (public.es_privilegiado_actual());

DROP POLICY IF EXISTS "Estructuras: solo privileged borran" ON public.estructuras;
CREATE POLICY "Estructuras: solo privileged borran"
  ON public.estructuras
  FOR DELETE TO authenticated
  USING (public.es_privilegiado_actual());

-- -----------------------------------------------------------------------------
-- 4) app_config: el muro de mantenimiento.
--
--    Se retira "Autenticados todo app_config" (cmd=ALL: escritura para
--    cualquiera) y se reescribe la lectura publica con un nombre que diga
--    que es a proposito.
-- -----------------------------------------------------------------------------
DROP POLICY IF EXISTS "Autenticados todo app_config" ON public.app_config;
DROP POLICY IF EXISTS "Lectura publica app_config" ON public.app_config;

DROP POLICY IF EXISTS "App config: lectura publica (muro de mantenimiento)" ON public.app_config;
CREATE POLICY "App config: lectura publica (muro de mantenimiento)"
  ON public.app_config
  FOR SELECT TO public
  USING (true);

DROP POLICY IF EXISTS "App config: solo privileged agregan" ON public.app_config;
CREATE POLICY "App config: solo privileged agregan"
  ON public.app_config
  FOR INSERT TO authenticated
  WITH CHECK (public.es_privilegiado_actual());

DROP POLICY IF EXISTS "App config: solo privileged modifican" ON public.app_config;
CREATE POLICY "App config: solo privileged modifican"
  ON public.app_config
  FOR UPDATE TO authenticated
  USING (public.es_privilegiado_actual())
  WITH CHECK (public.es_privilegiado_actual());

DROP POLICY IF EXISTS "App config: solo privileged borran" ON public.app_config;
CREATE POLICY "App config: solo privileged borran"
  ON public.app_config
  FOR DELETE TO authenticated
  USING (public.es_privilegiado_actual());

COMMIT;

-- =============================================================================
-- COMO VERIFICAR (sin tocar nada):
--
--   BEGIN;
--   SET LOCAL role authenticated;
--   SET LOCAL request.jwt.claims = '{"role":"authenticated","email":"biomedicas@unp.edu.py"}';
--
--   -- el muro de mantenimiento ya no se puede tocar
--   UPDATE public.app_config SET en_mantenimiento = true WHERE id = 'global';
--   --   => ERROR: new row violates row-level security policy
--
--   -- el catalogo de dependencias ya no se puede tocar
--   DELETE FROM public.dependencias WHERE id = (SELECT id FROM public.dependencias LIMIT 1);
--   --   => ERROR: new row violates row-level security policy
--
--   -- pero las estructuras se pueden seguir proponiendo (compatibilidad FC-10)
--   -- y el admin sigue viendo todo
--   SET LOCAL request.jwt.claims = '{"role":"authenticated","email":"lsanchez@unp.edu.py"}';
--   SELECT count(*) FROM public.dependencias;  -- 8
--   SELECT count(*) FROM public.ubicaciones;   -- 76
--   ROLLBACK;
--
-- ROLLBACK (si hay que revertir):
--
--   BEGIN;
--   DROP POLICY IF EXISTS "Dependencias: lectura para los autenticados" ON public.dependencias;
--   DROP POLICY IF EXISTS "Dependencias: solo privileged agregan" ON public.dependencias;
--   DROP POLICY IF EXISTS "Dependencias: solo privileged modifican" ON public.dependencias;
--   DROP POLICY IF EXISTS "Dependencias: solo privileged borran" ON public.dependencias;
--   DROP POLICY IF EXISTS "Ubicaciones: privileged leen todo, el resto su dependencia" ON public.ubicaciones;
--   DROP POLICY IF EXISTS "Ubicaciones: solo privileged agregan" ON public.ubicaciones;
--   DROP POLICY IF EXISTS "Ubicaciones: solo privileged modifican" ON public.ubicaciones;
--   DROP POLICY IF EXISTS "Ubicaciones: solo privileged borran" ON public.ubicaciones;
--   DROP POLICY IF EXISTS "Estructuras: lectura para los autenticados" ON public.estructuras;
--   DROP POLICY IF EXISTS "Estructuras: cualquiera puede proponer una unidad" ON public.estructuras;
--   DROP POLICY IF EXISTS "Estructuras: solo privileged modifican" ON public.estructuras;
--   DROP POLICY IF EXISTS "Estructuras: solo privileged borran" ON public.estructuras;
--   DROP POLICY IF EXISTS "App config: lectura publica (muro de mantenimiento)" ON public.app_config;
--   DROP POLICY IF EXISTS "App config: solo privileged agregan" ON public.app_config;
--   DROP POLICY IF EXISTS "App config: solo privileged modifican" ON public.app_config;
--   DROP POLICY IF EXISTS "App config: solo privileged borran" ON public.app_config;
--   CREATE POLICY "Autenticados todo dependencias" ON public.dependencias
--     FOR ALL TO public USING (auth.role() = 'authenticated');
--   CREATE POLICY "Autenticados todo ubicaciones" ON public.ubicaciones
--     FOR ALL TO public USING (auth.role() = 'authenticated');
--   CREATE POLICY "Autenticados todo estructuras" ON public.estructuras
--     FOR ALL TO public USING (auth.role() = 'authenticated');
--   CREATE POLICY "Autenticados todo app_config" ON public.app_config
--     FOR ALL TO public USING (auth.role() = 'authenticated');
--   COMMIT;
-- =============================================================================
