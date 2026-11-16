-- La ficha QR puede identificar al custodio y mostrar dónde se encuentra
-- físicamente el bien. Se mantiene una proyección explícita: nunca se devuelve
-- el JSON completo, documentos personales, valores, fotos ni observaciones.
CREATE OR REPLACE FUNCTION public.obtener_bien_publico(p_id text)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT jsonb_build_object(
    'id', b.id,
    'rotulo', coalesce(b.data ->> 'rotulo', ''),
    'descripcion', coalesce(b.data ->> 'descripcion', ''),
    'estadoConservacion', coalesce(b.data ->> 'estadoConservacion', ''),
    'funcionario', coalesce(b.data ->> 'funcionario', ''),
    'ubicacion', coalesce(b.data ->> 'ubicacion', ''),
    'cuenta', coalesce(b.data ->> 'cuenta', ''),
    'subcuenta', coalesce(b.data ->> 'subcuenta', ''),
    'analitico1', coalesce(b.data ->> 'analitico1', ''),
    'analitico2', coalesce(b.data ->> 'analitico2', ''),
    'fechaAdquisicion', coalesce(b.data ->> 'fechaAdquisicion', '')
  )
  FROM public.bens b
  WHERE b.id = btrim(p_id) OR b.data ->> 'rotulo' = btrim(p_id)
  ORDER BY (b.id = btrim(p_id)) DESC
  LIMIT 1;
$$;

REVOKE ALL ON FUNCTION public.obtener_bien_publico(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.obtener_bien_publico(text) TO anon, authenticated;
