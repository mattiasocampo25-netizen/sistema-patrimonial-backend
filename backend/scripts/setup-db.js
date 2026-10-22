/**
 * backend/scripts/setup-db.js
 * ============================================================================
 * Aplica las migraciones en orden sobre la base pointed by DATABASE_URL.
 * Es idempotente: se puede volver a correr sin romper nada.
 *
 *   npm run db:setup
 *
 * Para un entorno limpio, en este orden:
 *   1) 001_esquema_inicial.sql    -> tablas + índices + deltas de columnas
 *   2) 002_seguridad_rls.sql      -> cierra cédulas y el oráculo de credenciales
 *   3) 003_rls_por_dependencia.sql-> un funcionario solo ve su dependencia
 *   4) 004_rls_bens_publico.sql   -> cierra el acceso anónimo a la tabla bens
 *   5) 005_rls_cierre_total.sql   -> cierra usuarios.password, auditoría y
 *                                     notificaciones para los autenticados
 *   6) 006_rpc_resumen_dependencias.sql -> RPC de conteos por dependencia
 *   7) 007_rpc_guardar_usuario.sql      -> RPC de alta/edición de usuarios
 *   8) 008_rls_usuarios_escritura.sql   -> escritura de usuarios solo admin
 *   9) 009_rls_funcionarios_dependencia.sql -> cierra el padrón de funcionarios
 *  10) 010_rls_catalogos_privilegiados.sql  -> cierra los catálogos y el
 *                                                muro de mantenimiento
 *  11) 011_rpc_permisos_anon.sql     -> quita EXECUTE a anon de las RPC
 *
 * OJO: 004 presupone que el frontend ya deployed usa la RPC
 * `obtener_bien_publico` (si no, la vista pública del QR deja de funcionar).
 *
 * REGISTRO
 * --------
 * Cada migración aplicada se anota en `public.schema_migrations`. Al volver a
 * correr el script, las ya registradas se saltan. Como TODAS las migraciones
 * son idempotentes (IF NOT EXISTS / DROP POLICY IF EXISTS / CREATE OR
 * REPLACE), aplicar una que ya se aplicó a mano tampoco rompe nada: el
 * registro sirve para saber el estado, no para impedir nada.
 * ============================================================================
 */
require('dotenv').config({ path: require('path').join(__dirname, '..', '.env') });
const fs = require('fs');
const path = require('path');
const { Pool } = require('pg');

if (!process.env.DATABASE_URL) {
  console.error('❌ Falta DATABASE_URL (revisá backend/.env)');
  process.exit(1);
}

const url = new URL(process.env.DATABASE_URL);
const cs = 'postgresql://' + url.username + ':' + encodeURIComponent(decodeURIComponent(url.password))
  + '@' + url.hostname + ':' + (url.port || 5432) + (url.pathname || '/postgres');
const pool = new Pool({ connectionString: cs, ssl: { rejectUnauthorized: false }, connectionTimeoutMillis: 30000 });

const MIGRACIONES = [
  '001_esquema_inicial.sql',
  '002_seguridad_rls.sql',
  '003_rls_por_dependencia.sql',
  '004_rls_bens_publico.sql',
  '005_rls_cierre_total.sql',
  '006_rpc_resumen_dependencias.sql',
  '007_rpc_guardar_usuario.sql',
  '008_rls_usuarios_escritura.sql',
  '009_rls_funcionarios_dependencia.sql',
  '010_rls_catalogos_privilegiados.sql',
  '011_rpc_permisos_anon.sql'
];

// Tabla de registro. Se crea acá (no en una migración) para que el script
// pueda anotarse a si mismo desde la primera vez que corre.
// RLS activado y sin políticas: solo el owner (postgres) la puede leer.
const CREAR_REGISTRO = `
  CREATE TABLE IF NOT EXISTS public.schema_migrations (
    nombre      TEXT PRIMARY KEY,
    aplicada_en TIMESTAMPTZ NOT NULL DEFAULT now()
  );
  ALTER TABLE public.schema_migrations ENABLE ROW LEVEL SECURITY;`;

(async () => {
  const dir = path.join(__dirname, '..', 'migrations');

  for (const m of MIGRACIONES) {
    const archivo = path.join(dir, m);
    if (!fs.existsSync(archivo)) {
      console.error('❌ No existe ' + m);
      process.exitCode = 1;
      return;
    }
  }

  await pool.query(CREAR_REGISTRO);
  const aplicadas = await pool.query('SELECT nombre FROM public.schema_migrations');
  const yaAplicadas = new Set(aplicadas.rows.map(r => r.nombre));

  for (const m of MIGRACIONES) {
    if (yaAplicadas.has(m)) {
      console.log('  ⏭  ' + m + '  (ya registrada)');
      continue;
    }
    const sql = fs.readFileSync(path.join(dir, m), 'utf8');
    const t0 = Date.now();
    try {
      await pool.query(sql);
      await pool.query(
        'INSERT INTO public.schema_migrations (nombre) VALUES ($1) ON CONFLICT (nombre) DO NOTHING',
        [m]
      );
      console.log('  ✅ ' + m + '  (' + (Date.now() - t0) + 'ms)');
    } catch (e) {
      console.error('  ❌ ' + m + ': ' + e.message);
      console.error('     La migración NO se aplicó: cada una va en su propia transacción.');
      process.exitCode = 1;
      return;
    }
  }

  // Resumen del estado final.
  const t = await pool.query(`SELECT count(*)::int AS n FROM information_schema.tables WHERE table_schema='public' AND table_type='BASE TABLE'`);
  const i = await pool.query(`SELECT count(*)::int AS n FROM pg_indexes WHERE schemaname='public'`);
  const p = await pool.query(`SELECT count(*)::int AS n FROM pg_policies WHERE schemaname='public'`);
  const f = await pool.query(`SELECT count(*)::int AS n FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.prosecdef`);
  const r = await pool.query(`SELECT count(*)::int AS n FROM public.schema_migrations`);

  console.log('\n  Tablas en public      : ' + t.rows[0].n);
  console.log('  Índices               : ' + i.rows[0].n);
  console.log('  Políticas RLS         : ' + p.rows[0].n);
  console.log('  Funciones SECURITY DEFINER : ' + f.rows[0].n);
  console.log('  Migraciones registradas: ' + r.rows[0].n + ' / ' + MIGRACIONES.length);
  console.log('\n  Base lista ✅');
})()
  .catch((e) => { console.error('❌ ' + e.message); process.exitCode = 1; })
  .finally(() => pool.end());
