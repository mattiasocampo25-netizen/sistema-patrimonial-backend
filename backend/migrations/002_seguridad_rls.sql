-- =============================================================================
-- 002_seguridad_rls.sql
-- Cierra la exposicion anonima de datos personales y credenciales.
--
-- Contexto (auditoria 2026-10-20):
--   La app NO usa el backend Express: el frontend va directo a Supabase con
--   la anon key. El unico limite de seguridad real es el RLS de Postgres.
--
--   Hallazgos con la anon key (sin sesion):
--     - public.funcionarios : 583 filas legibles, INCLUYENDO la columna
--                               `cedula` (dato personal, Ley 19.628 PY).
--                               Ningun flujo pre-login lee esta tabla: la vista
--                               publica de QR usa `bens` + la RPC
--                               `obtener_bien_publico`, que NO la consulta.
--     - public.verificar_login : RPC SECURITY DEFINER ejecutable por `anon`.
--                               Bypasea el RLS de `usuarios` y acepta
--                               `u.password = p_password` (texto plano).
--                               El frontend usa supabase.auth.signInWithPassword
--                               y BORRA el password antes de insertar
--                               (useFcModals.js:586), o sea que es residuo
--                               del esquema de auth anterior.
--     - public.usuarios : 2 de 7 filas con la contrasena en TEXTO PLANO.
--     - public.audit_logs : tabla vacia y no usada; con politicas para `anon`.
--
-- Idempotente. Aplicar con el rol `postgres` (service_role NO alcanza para
-- REVOKE/GRANT sobre tablas):
--   psql "$DATABASE_URL" -f backend/migrations/002_seguridad_rls.sql
-- o pegarlo en Supabase > SQL Editor.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 1) funcionarios: eliminar la lectura anonima.
--    La politica "Autenticados todo funcionarios" (auth.role()='authenticated')
--    queda intacta -> la app autenticada no cambia de comportamiento.
-- -----------------------------------------------------------------------------
DROP POLICY IF EXISTS "Lectura publica funcionarios" ON public.funcionarios;

-- Cinturon de seguridad: aunque alguien vuelva a crear la politica, `anon`
-- no tiene permiso de tabla. `authenticated` conserva acceso completo.
REVOKE ALL ON TABLE public.funcionarios FROM anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.funcionarios TO authenticated;

-- -----------------------------------------------------------------------------
-- 2) verificar_login: dejar de ser un oraculo de credenciales sin sesion.
--    Primero se corrige el cuerpo (se elimina la rama de texto plano) y luego
--    se revoca EXECUTE. CREATE OR REPLACE conserva el ACL, por eso el orden.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.verificar_login(p_username text, p_password text)
 RETURNS TABLE(username text, nombre text, cargo text, dependencia text)
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
BEGIN
  RETURN QUERY
  SELECT u.username, u.nombre, u.cargo, u.dependencia
  FROM usuarios u
  WHERE lower(trim(u.username)) = lower(trim(p_username))
    AND u.password = crypt(p_password, u.password);
END;
$function$;

REVOKE ALL ON FUNCTION public.verificar_login(text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.verificar_login(text, text) FROM anon;

-- -----------------------------------------------------------------------------
-- 3) Contrasenas en texto plano -> bcrypt, sin cambiar la credencial.
--    crypt() re-hashea el valor ya almacenado: la contrasena sigue siendo la
--    misma para quien la conoce, pero deja de estar legible en la BD.
--    (La app no usa esta columna: la clave vive en Supabase Auth.)
-- -----------------------------------------------------------------------------
UPDATE public.usuarios
   SET password = crypt(password, gen_salt('bf', 12))
 WHERE password IS NOT NULL
   AND password NOT LIKE '$2%';

-- -----------------------------------------------------------------------------
-- 4) audit_logs: tabla vacia, no usada por la app. Se retiran sus politicas
--    para `anon` (leer + insertar) y su permiso de tabla.
-- -----------------------------------------------------------------------------
DROP POLICY IF EXISTS "Permitir lectura a usuarios autenticados" ON public.audit_logs;
DROP POLICY IF EXISTS "Permitir insercion a usuarios autenticados" ON public.audit_logs;
REVOKE ALL ON TABLE public.audit_logs FROM anon;

COMMIT;

-- =============================================================================
-- ROLLBACK (ejecutar solo si hay que revertir):
--
--   BEGIN;
--   CREATE POLICY "Lectura publica funcionarios" ON public.funcionarios
--     FOR SELECT TO public USING (true);
--   GRANT ALL ON TABLE public.funcionarios TO anon;
--   GRANT EXECUTE ON FUNCTION public.verificar_login(text, text) TO PUBLIC;
--   GRANT EXECUTE ON FUNCTION public.verificar_login(text, text) TO anon;
--   CREATE POLICY "Permitir lectura a usuarios autenticados" ON public.audit_logs
--     FOR SELECT TO anon, authenticated USING (true);
--   CREATE POLICY "Permitir insercion a usuarios autenticados" ON public.audit_logs
--     FOR INSERT TO anon, authenticated WITH CHECK (true);
--   GRANT ALL ON TABLE public.audit_logs TO anon;
--   COMMIT;
--
-- Nota: el rollback NO restaura las contrasenas en texto plano (no se guardan
-- el valor original). Si habia que volver atrás, habria que pedir a cada
-- usuario que restablezca su clave en Supabase Auth.
-- =============================================================================
