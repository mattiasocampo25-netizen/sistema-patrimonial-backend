-- ============================================================================
-- MIGRACIÓN 001: Esquema inicial + índices + deltas de columnas
-- Ejecutar en el SQL Editor de Supabase (PostgreSQL).
--
-- IMPORTANTE (revisado 2026-10-20):
--   Esta migración NUNCA se había aplicado en producción: 0 de los 19 índices
--   existían. Y tal como estaba escrita, el script ABORTABA en el último
--   bloque (`COMMENT ON COLUMN app_config.data`): la tabla `app_config` real
--   tiene columnas planas, no una columna `data` JSONB. En el SQL Editor de
--   Supabase todo el script es una única transacción, así que ese error
--   revertía los índices que se hubieran creado justo antes.
--
--   Ahora:
--   - Es idempotente (todo con IF NOT EXISTS).
--   - Los COMMENT van dentro de bloques DO que solo se aplican si la columna
--     existe, así que el script no puede abortar.
--   - Incluye los deltas de columnas que el código del frontend y del backend
--     esperan pero que faltaban en la base (ver sección 2).
-- ============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 1) Tabla de configuración global (modo mantenimiento, versión, avisos)
--    La tabla ya existe en producción con columnas planas; se completa con
--    `data` JSONB para que el backend pueda escribir en ella.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS app_config (
  id TEXT PRIMARY KEY,
  data JSONB NOT NULL DEFAULT '{}'::jsonb,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE app_config ADD COLUMN IF NOT EXISTS data JSONB NOT NULL DEFAULT '{}'::jsonb;
ALTER TABLE app_config ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ NOT NULL DEFAULT now();

-- -----------------------------------------------------------------------------
-- 2) Deltas de columnas que el código ya usa y la base no tenía.
--
--    dependencias.codigo: App.jsx inserta y actualiza
--      { id, nombre, codigo, activa } y el modal muestra `d.codigo`.
--      Sin la columna, PostgREST responde 400
--      ("column dependencias.codigo does not exist") y crear o renombrar una
--      dependencia falla en la interfaz.
--
--    notificaciones.updated_at: el frontend consulta
--      .order('updated_at', { ascending: false }) para el panel de avisos.
-- -----------------------------------------------------------------------------
ALTER TABLE dependencias ADD COLUMN IF NOT EXISTS codigo TEXT;
ALTER TABLE notificaciones ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ NOT NULL DEFAULT now();

-- -----------------------------------------------------------------------------
-- 3) Índices para búsquedas frecuentes y rendimiento
-- -----------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_bens_dependencia ON bens ((data->>'dependencia'));
CREATE INDEX IF NOT EXISTS idx_bens_estado ON bens ((data->>'estadoConservacion'));
CREATE INDEX IF NOT EXISTS idx_bens_rotulo ON bens ((data->>'rotulo'));
CREATE INDEX IF NOT EXISTS idx_bens_funcionario ON bens ((data->>'funcionario'));

-- `bens.updated_at` es una COLUMNA real (no va dentro del JSONB). Es la que
-- usa la sincronización delta del frontend (.gt('updated_at', ...)), así que el
-- índice tiene que ir sobre la columna, no sobre data->>'updated_at'.
CREATE INDEX IF NOT EXISTS idx_bens_updated_at ON bens (updated_at);

CREATE INDEX IF NOT EXISTS idx_fc10_bienid ON fc10 ((data->>'bienId'));
CREATE INDEX IF NOT EXISTS idx_fc10_estadofirma ON fc10 ((data->>'estadoFirma'));
CREATE INDEX IF NOT EXISTS idx_fc10_fecha ON fc10 ((data->>'entregadoFecha'));

CREATE INDEX IF NOT EXISTS idx_fc11_bienid ON fc11 ((data->>'bienId'));
CREATE INDEX IF NOT EXISTS idx_fc11_fecha ON fc11 ((data->>'fecha'));

CREATE INDEX IF NOT EXISTS idx_fc04_bienid ON fc04 ((data->>'bienId'));

CREATE INDEX IF NOT EXISTS idx_usuarios_cargo ON usuarios (cargo);
CREATE INDEX IF NOT EXISTS idx_usuarios_dependencia ON usuarios (dependencia);

CREATE INDEX IF NOT EXISTS idx_notificaciones_usuario ON notificaciones ((data->>'usuarioDestino'));
CREATE INDEX IF NOT EXISTS idx_notificaciones_leido ON notificaciones ((data->>'leido'));
CREATE INDEX IF NOT EXISTS idx_notificaciones_fecha ON notificaciones ((data->>'fecha'));
CREATE INDEX IF NOT EXISTS idx_notificaciones_updated_at ON notificaciones (updated_at);

CREATE INDEX IF NOT EXISTS idx_auditoria_accion ON auditoria (accion);
CREATE INDEX IF NOT EXISTS idx_auditoria_fecha ON auditoria (fecha);
CREATE INDEX IF NOT EXISTS idx_auditoria_usuario ON auditoria (usuarioDestino);

-- -----------------------------------------------------------------------------
-- 4) Comentarios de documentación.
--    Van en bloques DO: si la columna no existe, se avisa por NOTICE y el
--    script NO aborta (que era el bug que hacia fallar toda la migracion).
-- -----------------------------------------------------------------------------
DO $$
BEGIN
  COMMENT ON TABLE app_config IS 'Configuración global del sistema (modo mantenimiento, versión, avisos).';
EXCEPTION WHEN undefined_object THEN
  RAISE NOTICE 'app_config: la tabla no existe todavia, se omite el comentario.';
END $$;

DO $$
BEGIN
  COMMENT ON COLUMN app_config.data IS 'Contenido JSON de la configuración.';
EXCEPTION WHEN undefined_object THEN
  RAISE NOTICE 'app_config.data: la columna no existe todavia, se omite el comentario.';
END $$;

DO $$
BEGIN
  COMMENT ON TABLE dependencias IS 'Catálogo de dependencias y departamentos de la UNP.';
EXCEPTION WHEN undefined_object THEN
  RAISE NOTICE 'dependencias: la tabla no existe todavia, se omite el comentario.';
END $$;

COMMIT;

-- ============================================================================
-- SUGERENCIAS DE ENCRITACIÓN DE DATOS SENSIBLES
-- ============================================================================
-- 1. Contraseñas: se almacenan hasheadas con bcrypt en `usuarios.password`.
--    Nunca almacenar contraseñas en texto plano.
--    OJO: la app autentica con Supabase Auth, no con esta tabla. La columna
--    `usuarios.password` es un residuo del esquema anterior; la migración
--    002_seguridad_rls.sql la deja 100% en bcrypt.
-- 2. Datos sensibles (CI, nombres, cargos): considerar pgcrypto para cifrar a nivel
--    de columna si la normativa lo exige:
--      CREATE EXTENSION IF NOT EXISTS pgcrypto;
--      ALTER TABLE usuarios ADD COLUMN nombre_cifrado bytea;
--      UPDATE usuarios SET nombre_cifrado = encrypt(nombre::bytea, 'clave', 'aes');
--    Nota: el cifrado a nivel de aplicación (antes de enviar a Supabase) es preferible
--    para no exponer claves de cifrado en la base de datos.
-- 3. Columnas JSONB (`data`) no se cifran nativamente por Supabase en el plan free;
--    si se requiere cifrado de campos sensibles dentro de JSON, cifrar antes de serializar
--    en el frontend/backend con una clave gestionada por KMS o variable de entorno.
