BEGIN;

-- Los rótulos suelen ser secuenciales; solo se permite consultar mediante el
-- identificador UUID que ya está codificado en los QR impresos por el sistema.
-- Los QR existentes mantienen su URL y sus UUID quedaron verificados en la BD.
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
  WHERE b.id = btrim(p_id)
    AND btrim(p_id) ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
  LIMIT 1;
$$;
REVOKE ALL ON FUNCTION public.obtener_bien_publico(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.obtener_bien_publico(text) TO anon, authenticated;

-- Una persona solo puede insertar auditoría atribuida a sí misma y a su
-- dependencia efectiva. El OR anterior permitía elegir otra dependencia con
-- tal de escribir el propio nombre en la columna usuario.
DROP POLICY IF EXISTS "Auditoria: cada quien registra lo suyo" ON public.auditoria;
CREATE POLICY "Auditoria: cada quien registra lo suyo"
  ON public.auditoria
  FOR INSERT TO authenticated
  WITH CHECK (
    public.es_privilegiado_actual()
    OR (
      lower(coalesce(auditoria.usuario, '')) = lower(coalesce(public.usuario_actual(), ''))
      AND lower(coalesce(auditoria.dependencia, '')) = lower(coalesce(public.dependencia_actual(), ''))
    )
  );

-- La limpieza solo puede borrar avisos privados propios; una lectura individual
-- jamás puede borrar un aviso compartido ni un anuncio del sistema.
DROP POLICY IF EXISTS "Notificaciones: cada quien purga las de su dependencia" ON public.notificaciones;
DROP POLICY IF EXISTS "Notificaciones: elimina administración o avisos comunes" ON public.notificaciones;
CREATE POLICY "Notificaciones: elimina administración o avisos comunes"
  ON public.notificaciones
  FOR DELETE TO authenticated
  USING (
    public.es_privilegiado_actual()
    OR (
      coalesce(data ->> 'tipo', '') NOT IN ('BAJA_BIEN', 'BAJA_FUNCIONARIO')
      AND coalesce(data ->> 'accion', '') <> 'anuncio'
      AND data ->> 'tipoRegistro' = 'NOTIFICACION'
      AND lower(coalesce(data ->> 'usuarioDestino', '')) = lower(coalesce(public.usuario_actual(), ''))
    )
  );

-- Índice de soporte para el historial administrativo (se consulta solo al abrir Anuncios).
CREATE INDEX IF NOT EXISTS idx_notificaciones_historial_anuncios
  ON public.notificaciones ((data ->> 'accion'), (data ->> 'tipoRegistro'), id DESC);

NOTIFY pgrst, 'reload schema';
COMMIT;
