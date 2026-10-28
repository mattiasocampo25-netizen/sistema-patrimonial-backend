-- Métricas reales de base de datos y Storage para el panel de salud.
-- La RPC solo devuelve totales y exige una sesión administrativa.
BEGIN;

CREATE OR REPLACE FUNCTION public.admin_obtener_uso_recursos()
RETURNS JSONB
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_db_bytes BIGINT;
  v_storage_bytes BIGINT := 0;
  v_storage_objetos BIGINT := 0;
BEGIN
  IF auth.uid() IS NULL OR NOT public.es_privilegiado_actual() THEN
    RAISE EXCEPTION 'Solo un administrador puede consultar el uso de recursos'
      USING ERRCODE = '42501';
  END IF;

  SELECT pg_database_size(current_database()) INTO v_db_bytes;

  IF to_regclass('storage.objects') IS NOT NULL THEN
    EXECUTE $query$
      SELECT
        COALESCE(SUM(CASE WHEN metadata->>'size' ~ '^[0-9]+$'
          THEN (metadata->>'size')::BIGINT ELSE 0 END), 0),
        COUNT(*)
      FROM storage.objects
    $query$ INTO v_storage_bytes, v_storage_objetos;
  END IF;

  RETURN jsonb_build_object(
    'dbBytes', v_db_bytes,
    'storageBytes', v_storage_bytes,
    'storageObjetos', v_storage_objetos,
    'medidoEn', now()
  );
END;
$$;

REVOKE ALL ON FUNCTION public.admin_obtener_uso_recursos() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_obtener_uso_recursos() TO authenticated;

DO $$
BEGIN
  IF to_regclass('public.schema_migrations') IS NOT NULL THEN
    EXECUTE $register$
      INSERT INTO public.schema_migrations (nombre)
      VALUES ('013_uso_recursos_admin.sql')
      ON CONFLICT (nombre) DO NOTHING
    $register$;
  END IF;
END;
$$;

COMMIT;
