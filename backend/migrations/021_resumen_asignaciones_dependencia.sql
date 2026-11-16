-- Conteo compacto de bienes con responsable principal para el panel.
-- No usa FC-10: mide la asignación operativa ya guardada en el inventario.
BEGIN;

CREATE OR REPLACE FUNCTION public.resumen_asignaciones_por_dependencia()
RETURNS TABLE (dependencia text, total bigint, asignados bigint)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  WITH visibles AS (
    SELECT
      b.data ->> 'dependencia' AS dep,
      upper(btrim(coalesce(b.data ->> 'funcionario', ''))) AS responsable
    FROM public.bens b
    WHERE public.es_privilegiado_actual()
      OR lower(coalesce(b.data ->> 'dependencia', ''))
         = lower(coalesce(public.dependencia_actual(), ''))
  )
  SELECT
    v.dep,
    count(*)::bigint,
    count(*) FILTER (WHERE v.responsable <> '' AND v.responsable NOT IN (
      '-', '—', 'S/A', 'S/C', 'N/A', 'NA', 'PENDIENTE', 'POR ASIGNAR',
      'SIN ASIGNAR', 'SIN ASIGNACION', 'SIN RESPONSABLE', 'SIN FUNCIONARIO',
      'NO ASIGNADO', 'NO ASIGNADA', 'LIBRE PARA ASIGNAR',
      'LIBRES PARA ASIGNAR', 'DISPONIBLE PARA ASIGNAR'
    ))::bigint
  FROM visibles v
  WHERE v.dep IS NOT NULL AND btrim(v.dep) <> ''
  GROUP BY v.dep
  ORDER BY count(*) DESC, v.dep;
$$;

REVOKE ALL ON FUNCTION public.resumen_asignaciones_por_dependencia() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.resumen_asignaciones_por_dependencia() TO authenticated;

COMMIT;
