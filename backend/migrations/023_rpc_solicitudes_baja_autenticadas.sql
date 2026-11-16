-- Crea solicitudes de baja usando la identidad autenticada del JWT y valida
-- que la entidad pertenezca a la dependencia del solicitante. Evita que una
-- diferencia entre el perfil local y el JWT bloquee legítimas solicitudes.
BEGIN;

CREATE OR REPLACE FUNCTION public.crear_solicitud_baja(
  p_solicitud_id text,
  p_tipo text,
  p_entidad_id text,
  p_motivo text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_usuario text;
  v_dependencia_usuario text;
  v_dependencia_objetivo text;
  v_bien jsonb;
  v_funcionario record;
  v_solicitud jsonb;
BEGIN
  v_usuario := public.usuario_actual();
  v_dependencia_usuario := public.dependencia_actual();

  IF v_usuario IS NULL OR btrim(v_usuario) = '' THEN
    RAISE EXCEPTION 'No se pudo verificar al usuario autenticado. Cierra sesión y vuelve a ingresar.';
  END IF;
  IF p_solicitud_id IS NULL OR btrim(p_solicitud_id) = '' THEN
    RAISE EXCEPTION 'Falta el identificador de la solicitud.';
  END IF;
  IF p_tipo IS NULL OR p_tipo NOT IN ('BAJA_BIEN', 'BAJA_FUNCIONARIO') THEN
    RAISE EXCEPTION 'El tipo de solicitud de baja no es válido.';
  END IF;
  IF p_entidad_id IS NULL OR btrim(p_entidad_id) = '' THEN
    RAISE EXCEPTION 'No se indicó el bien o funcionario relacionado.';
  END IF;
  IF p_motivo IS NULL OR btrim(p_motivo) = '' THEN
    RAISE EXCEPTION 'Indica el motivo de la solicitud.';
  END IF;

  IF p_tipo = 'BAJA_BIEN' THEN
    SELECT b.data INTO v_bien
      FROM public.bens b
      WHERE b.id = p_entidad_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'El bien ya no existe o no está disponible.';
    END IF;
    v_dependencia_objetivo := v_bien ->> 'dependencia';
    IF NOT public.es_privilegiado_actual()
       AND (coalesce(btrim(v_dependencia_objetivo), '') = ''
         OR coalesce(btrim(v_dependencia_usuario), '') = ''
         OR lower(btrim(v_dependencia_objetivo)) <> lower(btrim(v_dependencia_usuario))) THEN
      RAISE EXCEPTION 'El bien no pertenece a tu dependencia actual. Actualiza el inventario y vuelve a intentarlo.';
    END IF;

    v_solicitud := jsonb_build_object(
      'id', p_solicitud_id,
      'bienId', p_entidad_id,
      'rotulo', v_bien ->> 'rotulo',
      'descripcion', v_bien ->> 'descripcion',
      'ubicacion', v_bien ->> 'ubicacion',
      'funcionario', v_bien ->> 'funcionario',
      'solicitante', v_usuario,
      'dependencia', v_dependencia_objetivo,
      'tipo', p_tipo,
      'estado', 'PENDIENTE',
      'motivo', btrim(p_motivo),
      'created_at', now()
    );
  ELSE
    SELECT f.id::text AS id, f.nombre, f.cedula, f.dependencia
      INTO v_funcionario
      FROM public.funcionarios f
      WHERE f.id::text = p_entidad_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'El funcionario ya no existe o no está disponible.';
    END IF;
    v_dependencia_objetivo := v_funcionario.dependencia;
    IF NOT public.es_privilegiado_actual()
       AND (coalesce(btrim(v_dependencia_objetivo), '') = ''
         OR coalesce(btrim(v_dependencia_usuario), '') = ''
         OR lower(btrim(v_dependencia_objetivo)) <> lower(btrim(v_dependencia_usuario))) THEN
      RAISE EXCEPTION 'El funcionario no pertenece a tu dependencia actual. Actualiza el padrón y vuelve a intentarlo.';
    END IF;

    v_solicitud := jsonb_build_object(
      'id', p_solicitud_id,
      'funcionarioId', v_funcionario.id,
      'nombre', v_funcionario.nombre,
      'cedula', v_funcionario.cedula,
      'solicitante', v_usuario,
      'dependencia', v_dependencia_objetivo,
      'tipo', p_tipo,
      'estado', 'PENDIENTE',
      'motivo', btrim(p_motivo),
      'created_at', now()
    );
  END IF;

  INSERT INTO public.notificaciones (id, data)
    VALUES (p_solicitud_id, v_solicitud);

  RETURN v_solicitud;
END;
$$;

REVOKE ALL ON FUNCTION public.crear_solicitud_baja(text, text, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.crear_solicitud_baja(text, text, text, text) FROM anon;
GRANT EXECUTE ON FUNCTION public.crear_solicitud_baja(text, text, text, text) TO authenticated;

COMMIT;
