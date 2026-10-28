-- Enlaces temporales de solo lectura para compartir bienes concretos.
-- Los datos quedan como snapshot minimizado; anon no recibe SELECT directo.
BEGIN;

CREATE TABLE IF NOT EXISTS public.enlaces_inventario (
  token UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  creado_por UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  dependencia TEXT NOT NULL,
  titulo TEXT NOT NULL,
  bienes JSONB NOT NULL CHECK (jsonb_typeof(bienes) = 'array'),
  creado_en TIMESTAMPTZ NOT NULL DEFAULT now(),
  vence_en TIMESTAMPTZ NOT NULL DEFAULT (now() + interval '1 day')
);

ALTER TABLE public.enlaces_inventario
  ALTER COLUMN vence_en SET DEFAULT (now() + interval '1 day');
UPDATE public.enlaces_inventario
SET vence_en = LEAST(vence_en, creado_en + interval '1 day')
WHERE vence_en > creado_en + interval '1 day';

ALTER TABLE public.enlaces_inventario ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.enlaces_inventario FROM PUBLIC, anon, authenticated;

-- bens.id es TEXT en el esquema de la aplicación; mantener UUID[] aquí provoca
-- el error PostgreSQL `operator does not exist: text = uuid` al validar bienes.
-- Eliminar la firma anterior para que PostgREST no conserve una RPC ambigua.
DROP FUNCTION IF EXISTS public.crear_enlace_inventario(UUID[], TEXT, TEXT);

CREATE OR REPLACE FUNCTION public.crear_enlace_inventario(
  p_bien_ids TEXT[],
  p_dependencia TEXT,
  p_funcionario TEXT DEFAULT NULL
) RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_ids TEXT[];
  v_bienes JSONB;
  v_total INTEGER;
  v_titulo TEXT;
  v_token UUID;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Se requiere una sesión para crear un enlace' USING ERRCODE = '42501';
  END IF;
  IF p_dependencia IS NULL OR btrim(p_dependencia) = '' THEN
    RAISE EXCEPTION 'Dependencia requerida' USING ERRCODE = '22023';
  END IF;
  IF NOT public.es_privilegiado_actual()
     AND lower(p_dependencia) <> lower(coalesce(public.dependencia_actual(), '')) THEN
    RAISE EXCEPTION 'No puedes compartir bienes de otra dependencia' USING ERRCODE = '42501';
  END IF;

  SELECT array_agg(DISTINCT bien_id) INTO v_ids
  FROM unnest(coalesce(p_bien_ids, ARRAY[]::TEXT[])) AS ids(bien_id);
  IF coalesce(cardinality(v_ids), 0) = 0 OR cardinality(v_ids) > 500 THEN
    RAISE EXCEPTION 'Selecciona entre 1 y 500 bienes' USING ERRCODE = '22023';
  END IF;

  SELECT count(*)::INTEGER INTO v_total
  FROM public.bens b
  WHERE b.id = ANY(v_ids)
    AND lower(coalesce(b.data->>'dependencia', '')) = lower(p_dependencia)
    AND (
      p_funcionario IS NULL
      OR lower(btrim(coalesce(b.data->>'funcionario', ''))) = lower(btrim(p_funcionario))
      OR EXISTS (
        SELECT 1 FROM public.fc10 f
        WHERE f.data->>'bienId' = b.id::TEXT
          AND lower(btrim(coalesce(f.data->>'funcionarioNombre', ''))) = lower(btrim(p_funcionario))
          AND coalesce(f.data->>'devolucionFecha', '') = ''
      )
    );
  IF v_total <> cardinality(v_ids) THEN
    RAISE EXCEPTION 'Uno o más bienes no están disponibles para compartir' USING ERRCODE = '42501';
  END IF;

  SELECT jsonb_agg(jsonb_build_object(
    'rotulo', coalesce(b.data->>'rotulo', ''),
    'descripcion', coalesce(b.data->>'descripcion', ''),
    'dependencia', coalesce(b.data->>'dependencia', ''),
    'ubicacion', coalesce(b.data->>'ubicacion', ''),
    'estado', coalesce(b.data->>'estadoConservacion', ''),
    'funcionario', coalesce(
      nullif(b.data->>'funcionario', ''),
      (SELECT f.data->>'funcionarioNombre' FROM public.fc10 f
       WHERE f.data->>'bienId' = b.id::TEXT
         AND coalesce(f.data->>'devolucionFecha', '') = ''
       ORDER BY coalesce(f.data->>'entregadoFecha', f.data->>'fechaGeneracion', '') DESC
       LIMIT 1),
      ''
    ),
    'fechaAsignacion', coalesce(
      (SELECT max(coalesce(f.data->>'entregadoFecha', f.data->>'fechaGeneracion'))
       FROM public.fc10 f
       WHERE f.data->>'bienId' = b.id::TEXT
         AND coalesce(f.data->>'devolucionFecha', '') = ''),
      ''
    )
  ) ORDER BY b.data->>'rotulo') INTO v_bienes
  FROM public.bens b
  WHERE b.id = ANY(v_ids)
    AND lower(coalesce(b.data->>'dependencia', '')) = lower(p_dependencia);

  v_titulo := CASE
    WHEN nullif(btrim(p_funcionario), '') IS NOT NULL THEN 'Bienes asignados a ' || btrim(p_funcionario)
    ELSE 'Bienes seleccionados'
  END;
  INSERT INTO public.enlaces_inventario (creado_por, dependencia, titulo, bienes)
  VALUES (auth.uid(), btrim(p_dependencia), v_titulo, coalesce(v_bienes, '[]'::JSONB))
  RETURNING token INTO v_token;
  RETURN v_token;
END;
$$;

CREATE OR REPLACE FUNCTION public.obtener_inventario_compartido(p_token UUID)
RETURNS JSONB
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT jsonb_build_object(
    'titulo', e.titulo,
    'dependencia', e.dependencia,
    'bienes', e.bienes,
    'creadoEn', e.creado_en,
    'venceEn', e.vence_en
  )
  FROM public.enlaces_inventario e
  WHERE e.token = p_token AND e.vence_en > now();
$$;

REVOKE EXECUTE ON FUNCTION public.crear_enlace_inventario(TEXT[], TEXT, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.crear_enlace_inventario(TEXT[], TEXT, TEXT) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.obtener_inventario_compartido(UUID) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.obtener_inventario_compartido(UUID) TO anon, authenticated;

COMMIT;
