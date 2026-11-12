-- Permite que cada usuario confirme individualmente la lectura de anuncios
-- globales sin conceder permiso para editar el contenido del anuncio.
BEGIN;

CREATE OR REPLACE FUNCTION public.marcar_anuncio_leido(p_id TEXT)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_usuario TEXT;
  v_data JSONB;
  v_destino TEXT;
  v_leidos JSONB;
  v_solicitante TEXT;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Se requiere una sesión autenticada';
  END IF;

  v_usuario := public.usuario_actual();
  IF coalesce(v_usuario, '') = '' THEN
    RAISE EXCEPTION 'No se pudo validar el usuario actual';
  END IF;

  SELECT data INTO v_data
  FROM public.notificaciones
  WHERE id::TEXT = p_id
  FOR UPDATE;

  IF NOT FOUND OR coalesce(v_data->>'accion', '') <> 'anuncio'
     OR coalesce(v_data->>'tipoRegistro', '') <> 'NOTIFICACION' THEN
    RAISE EXCEPTION 'Anuncio no disponible';
  END IF;

  v_destino := lower(coalesce(v_data->>'usuarioDestino', ''));
  IF v_destino NOT IN ('todos', lower(v_usuario)) THEN
    RAISE EXCEPTION 'El anuncio no está dirigido a este usuario';
  END IF;

  v_leidos := CASE
    WHEN jsonb_typeof(v_data->'leidos') = 'array' THEN v_data->'leidos'
    ELSE '[]'::JSONB
  END;

  IF EXISTS (SELECT 1 FROM jsonb_array_elements_text(v_leidos) AS x(valor)
             WHERE lower(x.valor) = lower(v_usuario)) THEN
    RETURN TRUE;
  END IF;

  UPDATE public.notificaciones
  SET data = jsonb_set(
    coalesce(v_data, '{}'::JSONB),
    '{leidos}',
    v_leidos || to_jsonb(v_usuario),
    TRUE
  ), updated_at = now()
  WHERE id::TEXT = p_id;

  RETURN TRUE;
END;
$$;

REVOKE ALL ON FUNCTION public.marcar_anuncio_leido(TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.marcar_anuncio_leido(TEXT) TO authenticated;

NOTIFY pgrst, 'reload schema';
COMMIT;
