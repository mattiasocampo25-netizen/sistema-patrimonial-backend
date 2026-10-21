-- =============================================================================
-- 006_rpc_resumen_dependencias.sql
-- Resumen por dependencia para los tiles del panel.
--
-- Por que un RPC y no una consulta desde el frontend: para pintar los tiles por
-- dependencia hace falta el inventario COMPLETO, y traer 13.673 filas al
-- navegador para sacar 8 numeros es tirar la parte de datos de la base
-- gratuita. Con un RPC el calculo se hace en el servidor y vuelve una fila
-- por dependencia.
--
-- Respeta el mismo criterio que el RLS (migracion 003): un funcionario solo
-- ve el resumen de SU dependencia; los roles privilegiados (admin y
-- desarrollador) ven el de todas. No se expone ningun dato de bien, solo
-- conteos y la suma del valor.
--
-- Idempotente. Aplicar con el rol `postgres`:
--   psql "$DATABASE_URL" -f backend/migrations/006_rpc_resumen_dependencias.sql
-- =============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.resumen_por_dependencia()
RETURNS TABLE (
  dependencia text,
  total bigint,
  buenos bigint,
  valor numeric
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  WITH visibles AS (
    SELECT
      b.data ->> 'dependencia' AS dep,
      b.data ->> 'estadoConservacion' AS estado,
      COALESCE(
        NULLIF(regexp_replace(COALESCE(b.data ->> 'valorUnitario', ''), '[^0-9]', '', 'g'), '')::numeric,
        0
      ) AS valor
    FROM public.bens b
    WHERE
      public.es_privilegiado_actual()
      OR lower(coalesce(b.data ->> 'dependencia', ''))
         = lower(coalesce(public.dependencia_actual(), ''))
  )
  SELECT
    v.dep,
    count(*)::bigint,
    count(*) FILTER (WHERE v.estado IN ('Bueno', 'Muy bueno'))::bigint,
    COALESCE(sum(v.valor), 0)::numeric
  FROM visibles v
  WHERE v.dep IS NOT NULL AND btrim(v.dep) <> ''
  GROUP BY v.dep
  ORDER BY count(*) DESC, v.dep;
$$;

REVOKE ALL ON FUNCTION public.resumen_por_dependencia() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.resumen_por_dependencia() TO authenticated;

COMMIT;
