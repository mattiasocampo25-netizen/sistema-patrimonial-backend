-- Endurece permisos y datos sin cambiar el acceso público del QR.
BEGIN;

-- Auditoría: historial append-only para clientes normales y administradores.
DROP POLICY IF EXISTS "Auditoria: privileged modifican" ON public.auditoria;
DROP POLICY IF EXISTS "Auditoria: privileged borran" ON public.auditoria;
DROP POLICY IF EXISTS "Auditoria: administradores modifican" ON public.auditoria;
DROP POLICY IF EXISTS "Auditoria: administradores borran" ON public.auditoria;
REVOKE UPDATE, DELETE ON TABLE public.auditoria FROM PUBLIC, anon, authenticated;

-- La RPC resumen es exclusivamente para sesiones autenticadas.
REVOKE EXECUTE ON FUNCTION public.resumen_asignaciones_por_dependencia() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.resumen_asignaciones_por_dependencia() TO authenticated;

-- Revocación anticipada de enlaces temporales: solo quien lo creó puede
-- invalidarlo; el token no concede permiso para revocar enlaces ajenos.
CREATE OR REPLACE FUNCTION public.revocar_enlace_inventario(p_token UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_revocados INTEGER;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Se requiere una sesión para revocar un enlace' USING ERRCODE = '42501';
  END IF;
  UPDATE public.enlaces_inventario
  SET vence_en = now()
  WHERE token = p_token AND creado_por = auth.uid() AND vence_en > now();
  GET DIAGNOSTICS v_revocados = ROW_COUNT;
  RETURN v_revocados = 1;
END;
$$;
REVOKE ALL ON FUNCTION public.revocar_enlace_inventario(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.revocar_enlace_inventario(UUID) TO authenticated;

-- Quita privilegios de lectura anónima que RLS ya bloquea. app_config se deja
-- intacta porque el frontend consulta su aviso público de mantenimiento.
REVOKE SELECT ON TABLE public.auditoria, public.dependencias, public.estructuras,
  public.fc04, public.fc10, public.fc11, public.notificaciones, public.ubicaciones
  FROM anon;

-- FC-10 puede proponer unidades del organigrama, pero solo con la estructura
-- esperada, datos acotados y tipos conocidos; lecturas y flujos legítimos siguen.
DROP POLICY IF EXISTS "Estructuras: cualquiera puede proponer una unidad" ON public.estructuras;
DROP POLICY IF EXISTS "Estructuras: propuesta validada por autenticados" ON public.estructuras;
CREATE POLICY "Estructuras: propuesta validada por autenticados"
  ON public.estructuras
  FOR INSERT TO authenticated
  WITH CHECK (
    coalesce(data ->> 'tipoRegistro', '') = 'ESTRUCTURA'
    AND lower(coalesce(data ->> 'tipoEstructura', '')) IN ('unidad', 'reparticion', 'dependencia', 'area')
    AND length(btrim(coalesce(data ->> 'nombre', ''))) BETWEEN 1 AND 200
    AND length(btrim(coalesce(data ->> 'codigo', ''))) BETWEEN 1 AND 40
  );

NOTIFY pgrst, 'reload schema';
COMMIT;
