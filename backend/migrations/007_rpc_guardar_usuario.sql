-- =============================================================================
-- 007_rpc_guardar_usuario.sql
-- El alta y la edicion de usuarios desde la app.
--
-- POR QUE HACE FALTA
-- -----------------
-- La tabla `usuarios` guarda las cuentas con su contrasena, y por eso desde
-- la migracion 005 `authenticated` solo tiene permiso de lectura sobre
-- cuatro columnas:
--
--   REVOKE SELECT ON public.usuarios FROM authenticated;
--   GRANT SELECT (username, nombre, cargo, dependencia) ON public.usuarios TO authenticated;
--
-- Eso deja la tabla sin SELECT a nivel de tabla, y el cliente de Supabase
-- (supabase-js) hace un HEAD a /rest/v1/usuarios?select=* ANTES de insertar
-- (para conocer las columnas por defecto). Ese HEAD pide la tabla entera,
-- que el rol no tiene -> 403 Forbidden -> y el alta de usuarios falla.
--
-- No se puede simplemente dar SELECT a la tabla: expondría la contrasena de
-- todos los usuarios a cualquiera que inicie sesion.
--
-- LA SOLUCION
-- -----------
-- Una funcion con SECURITY DEFINER que hace el INSERT/UPDATE por dentro (a
--hi, donde si hay permiso), comprueba que quien llama sea administrador o
-- desarrollador, y nunca toca la columna de contrasena (esa vive en
-- Supabase Auth).
--
-- Con esto la app deja de hacer insert/update directos y el 403 desaparece.
-- Idempotente. Aplicar con el rol `postgres`:
--   psql "$DATABASE_URL" -f backend/migrations/007_rpc_guardar_usuario.sql
-- =============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.admin_guardar_usuario(
  p_username    text,
  p_nombre      text,
  p_cargo       text,
  p_dependencia text
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_ya_existe  boolean;
  v_cargo_actual text;
BEGIN
  -- Solo un administrador (o el desarrollador) puede escribir usuarios.
  IF NOT public.es_privilegiado_actual() THEN
    RAISE EXCEPTION 'solo un administrador puede guardar usuarios' USING ERRCODE = '42501';
  END IF;

  IF p_username IS NULL OR btrim(p_username) = '' THEN
    RAISE EXCEPTION 'el nombre de usuario es obligatorio' USING ERRCODE = '22023';
  END IF;

  v_cargo_actual := public.cargo_actual();

  -- El rol de desarrollador solo lo otorga o lo quita quien ya lo tiene.
  -- (La app tambien lo comprueba, pero ahi es solo de interfaz: esta es la
  --  comprobacion de verdad.)
  IF p_cargo IN ('desarrollador', 'dev') AND v_cargo_actual NOT IN ('desarrollador', 'dev') THEN
    RAISE EXCEPTION 'solo el desarrollador del sistema puede otorgar ese rol' USING ERRCODE = '42501';
  END IF;

  SELECT EXISTS (SELECT 1 FROM public.usuarios WHERE username = p_username) INTO v_ya_existe;

  IF v_ya_existe THEN
    -- Y una cuenta de desarrollador tampoco se degrada desde un admin.
    IF (SELECT cargo FROM public.usuarios WHERE username = p_username) IN ('desarrollador', 'dev')
       AND v_cargo_actual NOT IN ('desarrollador', 'dev') THEN
      RAISE EXCEPTION 'solo el desarrollador del sistema gestiona esa cuenta' USING ERRCODE = '42501';
    END IF;

    UPDATE public.usuarios
       SET nombre      = p_nombre,
           cargo       = p_cargo,
           dependencia = p_dependencia
     WHERE username = p_username;
    RETURN 'actualizado';
  END IF;

  -- La contrasena no se escribe: la clave vive en Supabase Auth. La columna
  -- queda a NULL y no se expone en ninguna lectura.
  INSERT INTO public.usuarios (username, nombre, cargo, dependencia)
  VALUES (p_username, p_nombre, p_cargo, p_dependencia);
  RETURN 'creado';
END;
$$;

REVOKE ALL ON FUNCTION public.admin_guardar_usuario(text, text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_guardar_usuario(text, text, text, text) TO authenticated;

COMMENT ON FUNCTION public.admin_guardar_usuario(text, text, text, text) IS
  'Alta o edicion de un usuario. Solo administradores y el desarrollador. No toca la contrasena (vive en Supabase Auth).';

COMMIT;
