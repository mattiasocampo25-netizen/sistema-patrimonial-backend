/**
 * backend/scripts/setup-db.js
 * ============================================================================
 * Aplica las migraciones en orden sobre la base pointed por DATABASE_URL.
 * Es idempotente: se puede volver a correr sin romper nada.
 *
 *   npm run db:setup
 *
 * Para un entorno limpio, en este orden:
 *   1) 001_esquema_inicial.sql   -> tablas + índices + deltas de columnas
 *   2) 002_seguridad_rls.sql     -> cierra cédulas y el oráculo de credenciales
 *   3) 003_rls_por_dependencia.sql-> un funcionario solo ve su dependencia
 *   4) 004_rls_bens_publico.sql  -> cierra el acceso anónimo a la tabla bens
 *   5) 005_rls_cierre_total.sql  -> cierra usuarios.password, auditoría y
 *                                    notificaciones para los autenticados
 *
 * OJO: 004 presupone que el frontend ya deployed usa la RPC
 * `obtener_bien_publico` (si no, la vista pública del QR deja de funcionar).
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
  '005_rls_cierre_total.sql'
];

(async () => {
  const dir = path.join(__dirname, '..', 'migrations');
  for (const m of MIGRACIONES) {
    const archivo = path.join(dir, m);
    if (!fs.existsSync(archivo)) {
      console.error('❌ No existe ' + m);
      process.exitCode = 1;
      return;
    }
    const sql = fs.readFileSync(archivo, 'utf8');
    const t0 = Date.now();
    try {
      await pool.query(sql);
      console.log('  ✅ ' + m + '  (' + (Date.now() - t0) + 'ms)');
    } catch (e) {
      console.error('  ❌ ' + m + ': ' + e.message);
      process.exitCode = 1;
      return;
    }
  }

  // Resumen del estado final.
  const t = await pool.query(`SELECT count(*)::int AS n FROM information_schema.tables WHERE table_schema='public' AND table_type='BASE TABLE'`);
  const i = await pool.query(`SELECT count(*)::int AS n FROM pg_indexes WHERE schemaname='public'`);
  const p = await pool.query(`SELECT count(*)::int AS n FROM pg_policies WHERE schemaname='public'`);
  const f = await pool.query(`SELECT count(*)::int AS n FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.prosecdef`);

  console.log('\n  Tablas en public      : ' + t.rows[0].n);
  console.log('  Índices               : ' + i.rows[0].n);
  console.log('  Políticas RLS         : ' + p.rows[0].n);
  console.log('  Funciones SECURITY DEFINER : ' + f.rows[0].n);
  console.log('\n  Base lista ✅');
})()
  .catch((e) => { console.error('❌ ' + e.message); process.exitCode = 1; })
  .finally(() => pool.end());
