-- Cierre trazable del FC-11 después de la firma externa del receptor y el archivo.
-- La aplicación registra los datos declarados; no valida certificados ni firma PDFs.
BEGIN;

CREATE OR REPLACE FUNCTION public.confirmar_fc11_firmado(
  p_fc11_id TEXT,
  p_firmas JSONB,
  p_referencia_archivo TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_fc11_data JSONB;
  v_fc11_result JSONB;
  v_bien_id TEXT;
  v_bien_data JSONB;
  v_bien_result JSONB;
  v_bienes_result JSONB := '[]'::jsonb;
  v_bienes_snapshot JSONB;
  v_item JSONB;
  v_fc10_id TEXT;
  v_fc10_data JSONB;
  v_fc10_result JSONB;
  v_fc10_results JSONB := '[]'::jsonb;
  v_destino TEXT;
  v_area_destino TEXT;
  v_fecha_recepcion TEXT;
  v_receptor TEXT;
  v_now TIMESTAMPTZ := now();
BEGIN
  IF auth.uid() IS NULL OR NOT public.es_privilegiado_actual() THEN
    RAISE EXCEPTION 'Solo Patrimonio puede registrar el cierre del FC-11'
      USING ERRCODE = '42501';
  END IF;

  IF jsonb_typeof(p_firmas) <> 'object'
     OR NULLIF(BTRIM(p_firmas #>> '{receptor,nombre}'), '') IS NULL
     OR NULLIF(BTRIM(p_firmas #>> '{receptor,documento}'), '') IS NULL
     OR NULLIF(BTRIM(p_firmas #>> '{receptor,cargo}'), '') IS NULL
     OR COALESCE(p_firmas #>> '{receptor,fecha}', '') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
     OR NULLIF(BTRIM(p_referencia_archivo), '') IS NULL THEN
    RAISE EXCEPTION 'Se requieren los datos y la fecha de firma del responsable receptor, junto con la referencia del archivo'
      USING ERRCODE = '22023';
  END IF;
  BEGIN
    PERFORM (p_firmas #>> '{receptor,fecha}')::DATE;
  EXCEPTION WHEN others THEN
    RAISE EXCEPTION 'La fecha de firma del receptor no es válida' USING ERRCODE = '22007';
  END;

  SELECT data INTO v_fc11_data
  FROM public.fc11
  WHERE id = p_fc11_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'No se encontró el FC-11 indicado' USING ERRCODE = 'P0002';
  END IF;
  IF COALESCE(v_fc11_data ->> 'estado', 'PENDIENTE_FIRMAS') <> 'PENDIENTE_FIRMAS' THEN
    RAISE EXCEPTION 'El FC-11 ya no está pendiente de firmas' USING ERRCODE = '55000';
  END IF;

  v_destino := COALESCE(NULLIF(BTRIM(v_fc11_data ->> 'dependenciaDestinataria'), ''), '');
  v_area_destino := COALESCE(NULLIF(BTRIM(v_fc11_data ->> 'areaDestinataria'), ''), '');
  IF v_destino = '' OR NULLIF(BTRIM(v_fc11_data ->> 'dependenciaRemitente'), '') IS NULL THEN
    RAISE EXCEPTION 'El FC-11 debe indicar las dependencias remitente y destinataria' USING ERRCODE = '22023';
  END IF;
  v_fecha_recepcion := p_firmas #>> '{receptor,fecha}';
  v_receptor := BTRIM(p_firmas #>> '{receptor,nombre}');
  IF UPPER(BTRIM(COALESCE(v_fc11_data ->> 'receptorNombre', ''))) <> UPPER(v_receptor)
     OR BTRIM(COALESCE(v_fc11_data ->> 'receptorDocumento', '')) <> BTRIM(p_firmas #>> '{receptor,documento}')
     OR UPPER(BTRIM(COALESCE(v_fc11_data ->> 'receptorCargo', ''))) <> UPPER(BTRIM(p_firmas #>> '{receptor,cargo}')) THEN
    RAISE EXCEPTION 'Los datos del firmante deben coincidir con el responsable que figura en el FC-11'
      USING ERRCODE = '22023';
  END IF;

  v_bienes_snapshot := v_fc11_data -> 'bienesSnapshot';
  IF jsonb_typeof(v_bienes_snapshot) IS DISTINCT FROM 'array' THEN
    v_bienes_snapshot := '[]'::jsonb;
  END IF;
  IF jsonb_array_length(v_bienes_snapshot) = 0 THEN
    IF jsonb_typeof(v_fc11_data -> 'bienSnapshot') = 'object' THEN
      v_bienes_snapshot := jsonb_build_array(v_fc11_data -> 'bienSnapshot');
    ELSIF NULLIF(v_fc11_data ->> 'bienId', '') IS NOT NULL THEN
      v_bienes_snapshot := jsonb_build_array(jsonb_build_object('id', v_fc11_data ->> 'bienId'));
    ELSE
      RAISE EXCEPTION 'El FC-11 no tiene bienes asociados' USING ERRCODE = '22023';
    END IF;
  END IF;

  FOR v_item IN SELECT value FROM jsonb_array_elements(v_bienes_snapshot)
  LOOP
    v_bien_id := COALESCE(v_item ->> 'id', v_item ->> 'bienId');
    IF NULLIF(v_bien_id, '') IS NULL THEN
      RAISE EXCEPTION 'Uno de los bienes del FC-11 no tiene identificador' USING ERRCODE = '22023';
    END IF;
    SELECT data INTO v_bien_data FROM public.bens WHERE id = v_bien_id FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'El bien % ya no existe en el inventario', v_bien_id USING ERRCODE = 'P0002';
    END IF;
    IF LOWER(COALESCE(v_bien_data ->> 'dependencia', ''))
       <> LOWER(BTRIM(v_fc11_data ->> 'dependenciaRemitente')) THEN
      RAISE EXCEPTION 'El bien % ya no pertenece a la dependencia remitente', v_bien_id USING ERRCODE = '55000';
    END IF;

    v_bien_data := COALESCE(v_bien_data, '{}'::jsonb) || jsonb_build_object(
      'dependencia', v_destino,
      'estadoConservacion', COALESCE(v_item ->> 'estadoConservacion', v_bien_data ->> 'estadoConservacion'),
      'hasFC10', false,
      'funcionario', '',
      'ubicacion', CASE
        WHEN v_area_destino <> '' THEN v_area_destino
        WHEN v_devuelve_a_patimonio THEN ''
        ELSE COALESCE(v_bien_data ->> 'ubicacion', '') END
    );
    UPDATE public.bens SET data = v_bien_data, updated_at = v_now WHERE id = v_bien_id;
    SELECT jsonb_build_object('id', id, 'data', data, 'updated_at', updated_at)
      INTO v_bien_result FROM public.bens WHERE id = v_bien_id;
    v_bienes_result := v_bienes_result || jsonb_build_array(v_bien_result);

    SELECT id, data INTO v_fc10_id, v_fc10_data
    FROM public.fc10
    WHERE data ->> 'bienId' = v_bien_id
      AND COALESCE(data ->> 'devolucionFecha', '') = ''
    ORDER BY data ->> 'fechaGeneracion' DESC NULLS LAST
    LIMIT 1
    FOR UPDATE;
    IF FOUND THEN
      v_fc10_data := v_fc10_data || jsonb_build_object(
        'devolucionFecha', v_fecha_recepcion,
        'devolucionLugar', COALESCE(NULLIF(v_area_destino, ''), v_destino),
        'devolucionReceptor', v_receptor,
        'devolucionCargoReceptor', BTRIM(p_firmas #>> '{receptor,cargo}'),
        'devolucionFc11Id', p_fc11_id
      );
      UPDATE public.fc10 SET data = v_fc10_data, updated_at = v_now WHERE id = v_fc10_id;
      v_fc10_result := jsonb_build_object('id', v_fc10_id, 'data', v_fc10_data);
      v_fc10_results := v_fc10_results || jsonb_build_array(v_fc10_result);
    END IF;
  END LOOP;

  v_fc11_data := v_fc11_data || jsonb_build_object(
    'estado', 'COMPLETADO',
    'firmasExternas', p_firmas,
    'referenciaArchivo', BTRIM(p_referencia_archivo),
    'registradoPor', split_part(COALESCE(auth.jwt() ->> 'email', ''), '@', 1),
    'registradoEn', v_now
  );
  UPDATE public.fc11 SET data = v_fc11_data, updated_at = v_now WHERE id = p_fc11_id;
  v_fc11_result := jsonb_build_object('id', p_fc11_id, 'data', v_fc11_data);

  RETURN jsonb_build_object('fc11', v_fc11_result, 'bienes', v_bienes_result, 'fc10', v_fc10_results);
END;
$$;

REVOKE ALL ON FUNCTION public.confirmar_fc11_firmado(TEXT, JSONB, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.confirmar_fc11_firmado(TEXT, JSONB, TEXT) TO authenticated;

-- La app permite al usuario crear un FC-11 de su dependencia, pero solo un
-- privilegiado puede editar, borrar o cerrar un expediente ya creado.
DROP POLICY IF EXISTS "FC-11: admin ve todo, funcionario solo su dependencia (origen o destino)" ON public.fc11;
DROP POLICY IF EXISTS "FC-11: lectura por dependencia" ON public.fc11;
DROP POLICY IF EXISTS "FC-11: alta por dependencia remitente" ON public.fc11;
DROP POLICY IF EXISTS "FC-11: edicion privilegiada" ON public.fc11;
DROP POLICY IF EXISTS "FC-11: borrado privilegiado" ON public.fc11;

CREATE POLICY "FC-11: lectura por dependencia"
  ON public.fc11 FOR SELECT TO authenticated
  USING (
    public.es_privilegiado_actual()
    OR LOWER(COALESCE(data ->> 'dependenciaRemitente', '')) = LOWER(COALESCE(public.dependencia_actual(), ''))
    OR LOWER(COALESCE(data ->> 'dependenciaDestinataria', '')) = LOWER(COALESCE(public.dependencia_actual(), ''))
  );

CREATE POLICY "FC-11: alta por dependencia remitente"
  ON public.fc11 FOR INSERT TO authenticated
  WITH CHECK (
    (public.es_privilegiado_actual()
      OR LOWER(COALESCE(data ->> 'dependenciaRemitente', '')) = LOWER(COALESCE(public.dependencia_actual(), '')))
    AND COALESCE(data ->> 'estado', 'PENDIENTE_FIRMAS') = 'PENDIENTE_FIRMAS'
  );

CREATE POLICY "FC-11: edicion privilegiada"
  ON public.fc11 FOR UPDATE TO authenticated
  USING (public.es_privilegiado_actual())
  WITH CHECK (public.es_privilegiado_actual());

CREATE POLICY "FC-11: borrado privilegiado"
  ON public.fc11 FOR DELETE TO authenticated
  USING (public.es_privilegiado_actual() AND COALESCE(data ->> 'estado', '') <> 'COMPLETADO');

DO $$
BEGIN
  IF to_regclass('public.schema_migrations') IS NOT NULL THEN
    EXECUTE $register$
      INSERT INTO public.schema_migrations (nombre)
      VALUES ('014_cierre_fc11_con_registro_firmas.sql')
      ON CONFLICT (nombre) DO NOTHING
    $register$;
  END IF;
END;
$$;

NOTIFY pgrst, 'reload schema';
COMMIT;
