-- =============================================================================
-- 009_rls_funcionarios_dependencia.sql
-- Cierra el padrón de funcionarios y el roster de usuarios.
--
-- QUÉ PASABA (auditoría 2026-10-22, sobre el estado real de producción)
-- ---------------------------------------------------------------------------
-- Las migraciones 003 y 005 acotaron por dependencia `bens`, `fc10`, `fc11`,
-- `fc04`, `auditoria` y `notificaciones`. Pero `funcionarios` y `usuarios`
-- quedaron con las políticas laxas del esquema original:
--
--   funcionarios | Autenticados todo funcionarios | to={public} | cmd=ALL
--       USING: (auth.role() = 'authenticated')
--
-- Esa política es `cmd=ALL`: no solo deja LEER, deja ESCRIBIR y BORRAR. Y como
-- `funcionarios` no tenía columna `dependencia` en su filtro, cualquier
-- funcionario autenticado podía:
--
--   - leer las 583 filas del padrón COMPLETO, con la columna `cedula` en las
--     583 (dato personal, Ley 19.628 PY). Un funcionario de Biomédicas leía
--     518 cédulas de otras dependencias.
--   - MODIFICAR y BORRAR funcionarios de otras dependencias (verificado:
--     UPDATE ... RETURNING id -> 1 fila; DELETE ... RETURNING id -> 1 fila).
--
-- En `usuarios`, la política "Lectura usuarios autenticados" (008) era
-- `USING (true)`: cualquier autenticado leía los 7 perfiles con `cargo`, o
-- sea, quién es administrador y quién es desarrollador.
--
-- EL ARREGLO
-- ---------------------------------------------------------------------------
-- 1) `funcionarios`: el mismo criterio que ya funciona en el resto del
--    sistema (003/005). Los privilegiados (admin / desarrollador) ven y
--    escriben todo; el resto, solo su dependencia.
--
--    El frontend YA filtraba por dependencia del lado del cliente
--    (useRealtimeSync.js -> useFuncionarios.jsx:35 y App.jsx:324), así que
--    esto no cambia lo que se ve en pantalla: deja de filtrar el servidor.
--
--    La columna `cedula` NO se quita del alcance: el padrón de la propia
--    dependencia la necesita (deduplicación en el import CSV, match por
--    cédula al asignar un custodio). Lo que se cierra es el acceso al padrón
--    AJENO.
--
-- 2) `usuarios`: lectura acotada. El admin y el desarrollador (los únicos que
--    usan la lista completa: UsuariosView y AnunciosView) son privilegiados y
--    siguen viendo los 7 perfiles. Un funcionario ve el suyo y los de su
--    dependencia.
--
-- Idempotente. Aplicar con el rol `postgres`:
--   psql "$DATABASE_URL" -f backend/migrations/009_rls_funcionarios_dependencia.sql
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 1) funcionarios
--
--    Se dropea la política original (que era `cmd=ALL`, o sea que cubría
--    escritura y borrado) y se reemplaza por una por comando, con el mismo
--    criterio de dependencia que usan las migraciones 003 y 005.
-- -----------------------------------------------------------------------------
DROP POLICY IF EXISTS "Autenticados todo funcionarios" ON public.funcionarios;

DROP POLICY IF EXISTS "Funcionarios: privileged leen todo, el resto su dependencia" ON public.funcionarios;
CREATE POLICY "Funcionarios: privileged leen todo, el resto su dependencia"
  ON public.funcionarios
  FOR SELECT TO authenticated
  USING (
    public.es_privilegiado_actual()
    OR lower(coalesce(funcionarios.dependencia, '')) = lower(coalesce(public.dependencia_actual(), ''))
  );

-- El alta del padrón es legítima para cualquiera, pero solo en SU dependencia:
-- el formulario de funcionario (FuncionariosView) y el import de CSV graban con
-- `dependencia: dependenciaActual`.
DROP POLICY IF EXISTS "Funcionarios: cada quien registra en su dependencia" ON public.funcionarios;
CREATE POLICY "Funcionarios: cada quien registra en su dependencia"
  ON public.funcionarios
  FOR INSERT TO authenticated
  WITH CHECK (
    public.es_privilegiado_actual()
    OR lower(coalesce(funcionarios.dependencia, '')) = lower(coalesce(public.dependencia_actual(), ''))
  );

-- La edición no puede cambiar la fila de dependencia: si pudiera, un
-- funcionario movería un funcionario de otra dependencia a la suya y luego
-- podría borrarlo. WITH CHECK vuelve a validar la fila RESULTANTE.
DROP POLICY IF EXISTS "Funcionarios: privileged modifican, el resto los suyos" ON public.funcionarios;
CREATE POLICY "Funcionarios: privileged modifican, el resto los suyos"
  ON public.funcionarios
  FOR UPDATE TO authenticated
  USING (
    public.es_privilegiado_actual()
    OR lower(coalesce(funcionarios.dependencia, '')) = lower(coalesce(public.dependencia_actual(), ''))
  )
  WITH CHECK (
    public.es_privilegiado_actual()
    OR lower(coalesce(funcionarios.dependencia, '')) = lower(coalesce(public.dependencia_actual(), ''))
  );

DROP POLICY IF EXISTS "Funcionarios: privileged borran, el resto los suyos" ON public.funcionarios;
CREATE POLICY "Funcionarios: privileged borran, el resto los suyos"
  ON public.funcionarios
  FOR DELETE TO authenticated
  USING (
    public.es_privilegiado_actual()
    OR lower(coalesce(funcionarios.dependencia, '')) = lower(coalesce(public.dependencia_actual(), ''))
  );

-- -----------------------------------------------------------------------------
-- 2) usuarios: lectura acotada al propio perfil y al de la dependencia.
--
--    Se dropea también "Autenticados todo usuarios" a propósito: era `FOR ALL`
--    y, si alguien aplicara esta migración sin la 008, anularía el recorte.
-- -----------------------------------------------------------------------------
DROP POLICY IF EXISTS "Autenticados todo usuarios" ON public.usuarios;
DROP POLICY IF EXISTS "Lectura usuarios autenticados" ON public.usuarios;

-- El nombre va corto a propósito: PostgreSQL trunca los identificadores a 63
-- caracteres, y el nombre largo ("... los suyos y su dependencia") quedaba
-- guardado truncado. Con el nombre corto, el DROP y el CREATE apuntan al
-- mismo objeto y la migración se puede volver a aplicar.
DROP POLICY IF EXISTS "Usuarios: privileged leen todo, el resto por dependencia" ON public.usuarios;
-- Por si quedó una política con el nombre viejo: el literal de abajo es más
-- largo de 63 caracteres, así que PostgreSQL lo trunca al guardarlo y matchea
-- con la política que quedó truncada en la base.
DROP POLICY IF EXISTS "Usuarios: privileged leen todo, el resto los suyos y su dependencia" ON public.usuarios;

CREATE POLICY "Usuarios: privileged leen todo, el resto por dependencia"
  ON public.usuarios
  FOR SELECT TO authenticated
  USING (
    public.es_privilegiado_actual()
    OR lower(coalesce(usuarios.username, '')) = lower(coalesce(public.usuario_actual(), ''))
    OR lower(coalesce(usuarios.dependencia, '')) = lower(coalesce(public.dependencia_actual(), ''))
  );

-- Las políticas de escritura de la migración 008 (alta, edición y borrado solo
-- para privilegiados) se dejan intactas: son correctas.

-- Cinturón extra: `authenticated` todavía tiene TRUNCATE sobre `usuarios` de
-- un GRANT por defecto de Supabase. Truncar la tabla de usuarios desde una
-- sesión autenticada no es un vector que la app use, pero no cuesta cerrarlo.
REVOKE TRUNCATE ON TABLE public.usuarios FROM authenticated;

COMMIT;

-- =============================================================================
-- CÓMO VERIFICAR (sin tocar nada):
--
--   BEGIN;
--   SET LOCAL role authenticated;
--   SET LOCAL request.jwt.claims = '{"role":"authenticated","email":"biomedicas@unp.edu.py"}';
--
--   -- padrón: solo su dependencia, con cédula
--   SELECT dependencia, count(*) FROM public.funcionarios GROUP BY 1;
--   --   => 1 fila (Facultad de Ciencias Biomédicas), 65 filas
--
--   -- no puede tocar el padrón de otra dependencia
--   UPDATE public.funcionarios SET cargo = 'X'
--     WHERE id = (SELECT id FROM public.funcionarios
--                  WHERE dependencia <> 'Facultad de Ciencias Biomédicas' LIMIT 1);
--   --   => ERROR: new row violates row-level security policy
--
--   -- no puede leer el roster completo
--   SELECT count(*) FROM public.usuarios;
--   --   => 2 filas (el suyo + los de su dependencia), no 7
--
--   SET LOCAL request.jwt.claims = '{"role":"authenticated","email":"lsanchez@unp.edu.py"}';
--   SELECT count(*) FROM public.funcionarios;  -- 583 (admin ve todo)
--   SELECT count(*) FROM public.usuarios;      --   7 (admin ve todo)
--   ROLLBACK;
--
-- ROLLBACK (si hay que revertir):
--
--   BEGIN;
--   DROP POLICY IF EXISTS "Funcionarios: privileged leen todo, el resto su dependencia" ON public.funcionarios;
--   DROP POLICY IF EXISTS "Funcionarios: cada quien registra en su dependencia" ON public.funcionarios;
--   DROP POLICY IF EXISTS "Funcionarios: privileged modifican, el resto los suyos" ON public.funcionarios;
--   DROP POLICY IF EXISTS "Funcionarios: privileged borran, el resto los suyos" ON public.funcionarios;
--   DROP POLICY IF EXISTS "Usuarios: privileged leen todo, el resto los suyos y su dependencia" ON public.usuarios;
--   CREATE POLICY "Autenticados todo funcionarios" ON public.funcionarios
--     FOR ALL TO public USING (auth.role() = 'authenticated');
--   CREATE POLICY "Lectura usuarios autenticados" ON public.usuarios
--     FOR SELECT TO authenticated USING (true);
--   COMMIT;
-- =============================================================================
