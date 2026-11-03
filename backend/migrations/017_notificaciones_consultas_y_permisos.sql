-- Ajusta el esquema y RLS de notificaciones para las consultas actuales.
-- Aplicar una sola vez en Supabase SQL Editor como postgres.
BEGIN;

ALTER TABLE public.notificaciones
  ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ NOT NULL DEFAULT now();
CREATE INDEX IF NOT EXISTS idx_notificaciones_updated_at
  ON public.notificaciones (updated_at);
CREATE INDEX IF NOT EXISTS idx_notificaciones_destino
  ON public.notificaciones ((data ->> 'usuarioDestino'));
CREATE INDEX IF NOT EXISTS idx_notificaciones_tipo_estado
  ON public.notificaciones ((data ->> 'tipo'), (data ->> 'estado'));

DROP POLICY IF EXISTS "Notificaciones: lectura por dependencia" ON public.notificaciones;
CREATE POLICY "Notificaciones: lectura por dependencia"
  ON public.notificaciones FOR SELECT TO authenticated
  USING (
    public.es_privilegiado_actual()
    OR lower(coalesce(data ->> 'dependencia', ''))
       = lower(coalesce(public.dependencia_actual(), ''))
    OR (
      data ->> 'tipoRegistro' = 'NOTIFICACION'
      AND lower(coalesce(data ->> 'usuarioDestino', '')) IN (
        lower(coalesce(public.usuario_actual(), '')),
        'todos'
      )
    )
  );

DROP POLICY IF EXISTS "Notificaciones: actualiza administración o avisos propios" ON public.notificaciones;
CREATE POLICY "Notificaciones: actualiza administración o avisos propios"
  ON public.notificaciones FOR UPDATE TO authenticated
  USING (
    public.es_privilegiado_actual()
    OR (
      coalesce(data ->> 'tipo', '') NOT IN ('BAJA_BIEN', 'BAJA_FUNCIONARIO')
      AND (
        (
          lower(coalesce(data ->> 'dependencia', ''))
            = lower(coalesce(public.dependencia_actual(), ''))
          AND lower(coalesce(data ->> 'usuarioDestino', 'todos')) IN (
            lower(coalesce(public.usuario_actual(), '')),
            'todos'
          )
        )
        OR (
          data ->> 'tipoRegistro' = 'NOTIFICACION'
          AND lower(coalesce(data ->> 'usuarioDestino', ''))
            = lower(coalesce(public.usuario_actual(), ''))
        )
      )
    )
  )
  WITH CHECK (
    public.es_privilegiado_actual()
    OR (
      coalesce(data ->> 'tipo', '') NOT IN ('BAJA_BIEN', 'BAJA_FUNCIONARIO')
      AND (
        (
          lower(coalesce(data ->> 'dependencia', ''))
            = lower(coalesce(public.dependencia_actual(), ''))
          AND lower(coalesce(data ->> 'usuarioDestino', 'todos')) IN (
            lower(coalesce(public.usuario_actual(), '')),
            'todos'
          )
        )
        OR (
          data ->> 'tipoRegistro' = 'NOTIFICACION'
          AND lower(coalesce(data ->> 'usuarioDestino', ''))
            = lower(coalesce(public.usuario_actual(), ''))
        )
      )
    )
  );

COMMIT;
