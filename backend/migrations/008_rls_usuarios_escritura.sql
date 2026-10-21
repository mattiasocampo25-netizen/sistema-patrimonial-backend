-- =============================================================================
-- 008_rls_usuarios_escritura.sql
-- La escritura en `usuarios` solo para administradores.
--
-- QUE PASABA
-- ----------
-- La migracion 005 dejo una sola politica para toda la tabla:
--
--   CREATE POLICY "Autenticados todo usuarios" ON public.usuarios
--     FOR ALL USING (auth.role() = 'authenticated');
--
-- Con FOR ALL, la politica tambien cubria INSERT, UPDATE y DELETE: cualquier
-- usuario autenticado (un funcionario normal) podia:
--
--   - cambiar el cargo de otro usuario a 'admin'  -> escalada de privilegios
--   - borrar cuentas
--   - insertar un usuario con cargo 'admin'
--
-- Comprobado contra la base: un funcionario podia hacer las tres cosas.
--
-- EL ARREGLO
-- ----------
-- Una politica por comando:
--   - LECTURA: para cualquier autenticado. No hay datos sensibles: la
--     contrasena no se expone porque el permiso de SELECT es por columna
--     (username, nombre, cargo, dependencia) y el resto de columnas no se
--     pueden pedir.
--   - ESCRITURA: solo administradores y el desarrollador.
--
-- Idempotente. Aplicar con el rol `postgres`:
--   psql "$DATABASE_URL" -f backend/migrations/008_rls_usuarios_escritura.sql
-- =============================================================================

BEGIN;

DROP POLICY IF EXISTS "Autenticados todo usuarios" ON public.usuarios;

-- Lectura: cualquiera autenticado (el perfil propio y las listas de
-- selectores). El SELECT por columna sigue impidiendo ver la contrasena.
DROP POLICY IF EXISTS "Lectura usuarios autenticados" ON public.usuarios;
CREATE POLICY "Lectura usuarios autenticados" ON public.usuarios
  FOR SELECT TO authenticated
  USING (true);

-- Alta: solo administradores y el desarrollador.
DROP POLICY IF EXISTS "Alta usuarios solo administradores" ON public.usuarios;
CREATE POLICY "Alta usuarios solo administradores" ON public.usuarios
  FOR INSERT TO authenticated
  WITH CHECK (public.es_privilegiado_actual());

-- Edicion: solo administradores y el desarrollador.
DROP POLICY IF EXISTS "Edicion usuarios solo administradores" ON public.usuarios;
CREATE POLICY "Edicion usuarios solo administradores" ON public.usuarios
  FOR UPDATE TO authenticated
  USING (public.es_privilegiado_actual())
  WITH CHECK (public.es_privilegiado_actual());

-- Borrado: solo administradores y el desarrollador.
DROP POLICY IF EXISTS "Borrado usuarios solo administradores" ON public.usuarios;
CREATE POLICY "Borrado usuarios solo administradores" ON public.usuarios
  FOR DELETE TO authenticated
  USING (public.es_privilegiado_actual());

COMMIT;
