-- Reemplaza permisos de escritura amplios y reduce los datos del QR público.
-- Aplicar después de 014. Requiere rol postgres/owner.
BEGIN;

-- Bienes y formularios: lectura por dependencia; modificaciones solo por
-- administración. Los funcionarios conservan su flujo de solicitud de baja
-- en notificaciones, pero no alteran directamente el inventario ni actas.
DO $$
DECLARE p RECORD;
BEGIN
  FOR p IN
    SELECT schemaname, tablename, policyname
    FROM pg_policies
    WHERE schemaname = 'public' AND tablename IN ('bens', 'fc10', 'fc04')
  LOOP
    EXECUTE format('DROP POLICY %I ON %I.%I', p.policyname, p.schemaname, p.tablename);
  END LOOP;
END;
$$;

CREATE POLICY "Bienes: lectura por dependencia"
  ON public.bens FOR SELECT TO authenticated
  USING (public.es_privilegiado_actual()
    OR lower(coalesce(data ->> 'dependencia', '')) = lower(coalesce(public.dependencia_actual(), '')));
CREATE POLICY "Bienes: alta privilegiada"
  ON public.bens FOR INSERT TO authenticated
  WITH CHECK (public.es_privilegiado_actual());
CREATE POLICY "Bienes: edición privilegiada"
  ON public.bens FOR UPDATE TO authenticated
  USING (public.es_privilegiado_actual()) WITH CHECK (public.es_privilegiado_actual());
CREATE POLICY "Bienes: borrado privilegiado"
  ON public.bens FOR DELETE TO authenticated USING (public.es_privilegiado_actual());

CREATE POLICY "FC10: lectura por dependencia"
  ON public.fc10 FOR SELECT TO authenticated
  USING (public.es_privilegiado_actual()
    OR lower(coalesce(data ->> 'dependencia', '')) = lower(coalesce(public.dependencia_actual(), '')));
CREATE POLICY "FC10: alta privilegiada"
  ON public.fc10 FOR INSERT TO authenticated WITH CHECK (public.es_privilegiado_actual());
CREATE POLICY "FC10: edición privilegiada"
  ON public.fc10 FOR UPDATE TO authenticated
  USING (public.es_privilegiado_actual()) WITH CHECK (public.es_privilegiado_actual());
CREATE POLICY "FC10: borrado privilegiado"
  ON public.fc10 FOR DELETE TO authenticated USING (public.es_privilegiado_actual());

CREATE POLICY "FC04: lectura por dependencia"
  ON public.fc04 FOR SELECT TO authenticated
  USING (public.es_privilegiado_actual()
    OR lower(coalesce(data ->> 'dependencia', '')) = lower(coalesce(public.dependencia_actual(), '')));
CREATE POLICY "FC04: alta privilegiada"
  ON public.fc04 FOR INSERT TO authenticated WITH CHECK (public.es_privilegiado_actual());
CREATE POLICY "FC04: edición privilegiada"
  ON public.fc04 FOR UPDATE TO authenticated
  USING (public.es_privilegiado_actual()) WITH CHECK (public.es_privilegiado_actual());
CREATE POLICY "FC04: borrado privilegiado"
  ON public.fc04 FOR DELETE TO authenticated USING (public.es_privilegiado_actual());

REVOKE TRUNCATE ON public.bens, public.fc10, public.fc04 FROM authenticated;

-- Solicitudes de baja: el solicitante puede crear solo su propia solicitud;
-- solo administración puede cambiar estado/historial o borrarla. Avisos
-- comunes siguen siendo visibles y gestionables dentro de su dependencia.
DO $$
DECLARE p RECORD;
BEGIN
  FOR p IN
    SELECT policyname FROM pg_policies
    WHERE schemaname = 'public' AND tablename = 'notificaciones'
  LOOP
    EXECUTE format('DROP POLICY %I ON public.notificaciones', p.policyname);
  END LOOP;
END;
$$;

CREATE POLICY "Notificaciones: lectura por dependencia"
  ON public.notificaciones FOR SELECT TO authenticated
  USING (public.es_privilegiado_actual()
    OR lower(coalesce(data ->> 'dependencia', '')) = lower(coalesce(public.dependencia_actual(), '')));

CREATE POLICY "Notificaciones: alta propia o privilegiada"
  ON public.notificaciones FOR INSERT TO authenticated
  WITH CHECK (
    public.es_privilegiado_actual()
    OR (
      lower(coalesce(data ->> 'dependencia', '')) = lower(coalesce(public.dependencia_actual(), ''))
      AND lower(coalesce(data ->> 'solicitante', '')) = lower(coalesce(public.usuario_actual(), ''))
      AND (
        coalesce(data ->> 'tipo', '') NOT IN ('BAJA_BIEN', 'BAJA_FUNCIONARIO')
        OR (
          coalesce(data ->> 'estado', 'PENDIENTE') = 'PENDIENTE'
          AND (
            (data ->> 'tipo' = 'BAJA_BIEN' AND EXISTS (
              SELECT 1 FROM public.bens b
              WHERE b.id = coalesce(data ->> 'bienId', data ->> 'bien_id')
                AND lower(coalesce(b.data ->> 'dependencia', '')) = lower(coalesce(public.dependencia_actual(), ''))
            ))
            OR (data ->> 'tipo' = 'BAJA_FUNCIONARIO' AND EXISTS (
              SELECT 1 FROM public.funcionarios f
              WHERE f.id::text = coalesce(data ->> 'funcionarioId', data ->> 'funcionario_id')
                AND lower(coalesce(f.dependencia, '')) = lower(coalesce(public.dependencia_actual(), ''))
            ))
          )
        )
      )
    )
  );

CREATE POLICY "Notificaciones: actualiza administración o avisos propios"
  ON public.notificaciones FOR UPDATE TO authenticated
  USING (
    public.es_privilegiado_actual()
    OR (
      coalesce(data ->> 'tipo', '') NOT IN ('BAJA_BIEN', 'BAJA_FUNCIONARIO')
      AND lower(coalesce(data ->> 'dependencia', '')) = lower(coalesce(public.dependencia_actual(), ''))
      AND lower(coalesce(data ->> 'usuarioDestino', 'TODOS')) IN (lower(coalesce(public.usuario_actual(), '')), 'todos')
    )
  )
  WITH CHECK (
    public.es_privilegiado_actual()
    OR (
      coalesce(data ->> 'tipo', '') NOT IN ('BAJA_BIEN', 'BAJA_FUNCIONARIO')
      AND lower(coalesce(data ->> 'dependencia', '')) = lower(coalesce(public.dependencia_actual(), ''))
      AND lower(coalesce(data ->> 'usuarioDestino', 'TODOS')) IN (lower(coalesce(public.usuario_actual(), '')), 'todos')
    )
  );

CREATE POLICY "Notificaciones: elimina administración o avisos comunes"
  ON public.notificaciones FOR DELETE TO authenticated
  USING (
    public.es_privilegiado_actual()
    OR (
      coalesce(data ->> 'tipo', '') NOT IN ('BAJA_BIEN', 'BAJA_FUNCIONARIO')
      AND lower(coalesce(data ->> 'dependencia', '')) = lower(coalesce(public.dependencia_actual(), ''))
    )
  );
REVOKE TRUNCATE ON public.notificaciones FROM authenticated;

-- QR: expone solamente identificador, rótulo, descripción y estado físico.
-- No entrega precio, responsable, cargo, dependencia, ubicación ni fotografías.
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
    'estadoConservacion', coalesce(b.data ->> 'estadoConservacion', '')
  )
  FROM public.bens b
  WHERE b.id = btrim(p_id) OR b.data ->> 'rotulo' = btrim(p_id)
  ORDER BY (b.id = btrim(p_id)) DESC
  LIMIT 1;
$$;
REVOKE ALL ON FUNCTION public.obtener_bien_publico(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.obtener_bien_publico(text) TO anon, authenticated;

-- Fotos privadas. El cliente solo puede leer/subir/borrar fotos de bienes de
-- su dependencia; el rol privilegiado conserva acceso total.
UPDATE storage.buckets
SET public = false,
    file_size_limit = 5242880,
    allowed_mime_types = ARRAY['image/jpeg']::text[]
WHERE id = 'fotos-bienes';
-- Restrictive policies also cap any older permissive storage policies without
-- removing access rules for unrelated buckets.
DROP POLICY IF EXISTS "Fotos de bienes: limitar lectura por dependencia" ON storage.objects;
CREATE POLICY "Fotos de bienes: limitar lectura por dependencia"
  ON storage.objects AS RESTRICTIVE FOR SELECT TO authenticated
  USING (bucket_id <> 'fotos-bienes' OR EXISTS (
    SELECT 1 FROM public.bens b
    WHERE b.id = split_part(name, '/', 1)
      AND (public.es_privilegiado_actual()
        OR lower(coalesce(b.data ->> 'dependencia', '')) = lower(coalesce(public.dependencia_actual(), '')))
  ));
DROP POLICY IF EXISTS "Fotos de bienes: bloquear lectura pública" ON storage.objects;
CREATE POLICY "Fotos de bienes: bloquear lectura pública"
  ON storage.objects AS RESTRICTIVE FOR SELECT TO anon
  USING (bucket_id <> 'fotos-bienes');
DROP POLICY IF EXISTS "Fotos de bienes: bloquear alta pública" ON storage.objects;
CREATE POLICY "Fotos de bienes: bloquear alta pública"
  ON storage.objects AS RESTRICTIVE FOR INSERT TO anon
  WITH CHECK (bucket_id <> 'fotos-bienes');
DROP POLICY IF EXISTS "Fotos de bienes: bloquear edición pública" ON storage.objects;
CREATE POLICY "Fotos de bienes: bloquear edición pública"
  ON storage.objects AS RESTRICTIVE FOR UPDATE TO anon
  USING (bucket_id <> 'fotos-bienes') WITH CHECK (bucket_id <> 'fotos-bienes');
DROP POLICY IF EXISTS "Fotos de bienes: limitar edición privilegiada" ON storage.objects;
CREATE POLICY "Fotos de bienes: limitar edición privilegiada"
  ON storage.objects AS RESTRICTIVE FOR UPDATE TO authenticated
  USING (bucket_id <> 'fotos-bienes' OR public.es_privilegiado_actual())
  WITH CHECK (bucket_id <> 'fotos-bienes' OR public.es_privilegiado_actual());
DROP POLICY IF EXISTS "Fotos de bienes: bloquear borrado público" ON storage.objects;
CREATE POLICY "Fotos de bienes: bloquear borrado público"
  ON storage.objects AS RESTRICTIVE FOR DELETE TO anon
  USING (bucket_id <> 'fotos-bienes');
DROP POLICY IF EXISTS "Fotos de bienes: limitar alta por dependencia" ON storage.objects;
DROP POLICY IF EXISTS "Fotos de bienes: limitar alta privilegiada" ON storage.objects;
CREATE POLICY "Fotos de bienes: limitar alta privilegiada"
  ON storage.objects AS RESTRICTIVE FOR INSERT TO authenticated
  WITH CHECK (bucket_id <> 'fotos-bienes' OR public.es_privilegiado_actual());
DROP POLICY IF EXISTS "Fotos de bienes: limitar borrado por dependencia" ON storage.objects;
CREATE POLICY "Fotos de bienes: limitar borrado por dependencia"
  ON storage.objects AS RESTRICTIVE FOR DELETE TO authenticated
  USING (bucket_id <> 'fotos-bienes' OR public.es_privilegiado_actual());

DROP POLICY IF EXISTS "Fotos de bienes: lectura autenticada por dependencia" ON storage.objects;
CREATE POLICY "Fotos de bienes: lectura autenticada por dependencia"
  ON storage.objects FOR SELECT TO authenticated
  USING (bucket_id = 'fotos-bienes' AND EXISTS (
    SELECT 1 FROM public.bens b
    WHERE b.id = split_part(name, '/', 1)
      AND (public.es_privilegiado_actual()
        OR lower(coalesce(b.data ->> 'dependencia', '')) = lower(coalesce(public.dependencia_actual(), '')))
  ));
DROP POLICY IF EXISTS "Fotos de bienes: alta solo administración" ON storage.objects;
CREATE POLICY "Fotos de bienes: alta solo administración"
  ON storage.objects FOR INSERT TO authenticated
  WITH CHECK (bucket_id = 'fotos-bienes' AND public.es_privilegiado_actual());
DROP POLICY IF EXISTS "Fotos de bienes: borrado privilegiado" ON storage.objects;
CREATE POLICY "Fotos de bienes: borrado privilegiado"
  ON storage.objects FOR DELETE TO authenticated
  USING (bucket_id = 'fotos-bienes' AND public.es_privilegiado_actual());

DO $$
BEGIN
  IF to_regclass('public.schema_migrations') IS NOT NULL THEN
    EXECUTE $register$
      INSERT INTO public.schema_migrations (nombre)
      VALUES ('015_rls_escritura_aprobaciones_qr_storage.sql')
      ON CONFLICT (nombre) DO NOTHING
    $register$;
  END IF;
END;
$$;

NOTIFY pgrst, 'reload schema';
COMMIT;
