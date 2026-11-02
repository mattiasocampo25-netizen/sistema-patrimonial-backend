-- Habilita la edición de bienes existentes a usuarios autenticados de su
-- dependencia. La creación y el borrado siguen reservados a administración.
BEGIN;

DROP POLICY IF EXISTS "Bienes: edición privilegiada" ON public.bens;
DROP POLICY IF EXISTS "Bienes: edición por dependencia" ON public.bens;
CREATE POLICY "Bienes: edición por dependencia"
  ON public.bens FOR UPDATE TO authenticated
  USING (
    public.es_privilegiado_actual()
    OR lower(coalesce(data ->> 'dependencia', '')) = lower(coalesce(public.dependencia_actual(), ''))
  )
  WITH CHECK (
    public.es_privilegiado_actual()
    OR lower(coalesce(data ->> 'dependencia', '')) = lower(coalesce(public.dependencia_actual(), ''))
  );

DO $$
BEGIN
  IF to_regclass('public.schema_migrations') IS NOT NULL THEN
    INSERT INTO public.schema_migrations (nombre)
    VALUES ('016_bienes_edicion_por_dependencia.sql')
    ON CONFLICT (nombre) DO NOTHING;
  END IF;
END;
$$;

NOTIFY pgrst, 'reload schema';
COMMIT;
