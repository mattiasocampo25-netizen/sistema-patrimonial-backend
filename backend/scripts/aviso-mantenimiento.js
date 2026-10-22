/**
 * backend/scripts/aviso-mantenimiento.js
 * ============================================================================
 * Procedimiento de aviso al usuario: modo mantenimiento, mejoras en curso y
 * aviso de mejoras hechas al terminar.
 *
 * POR QUE EXISTE
 * --------------
 * El sistema se publica en una Vercel y la base es Supabase. Cuando se toca
 * la base (migraciones, correcciones) o el codigo, los usuarios pueden estar
 * usando la app mientras los datos cambian debajo. Este script deja el estado
 * en la base alineado con lo que la interfaz muestra:
 *
 *   `iniciar`  -> deja el MURO: en_mantenimiento = true, con el mensaje y la
 *                 lista de MEJORAS EN CURSO (los que la ven son
 *                 MaintenanceScreen, sin iniciar sesion).
 *   `cerrar`   -> desactiva el muro y deja el AVISO DE MEJORAS HECHAS: la
 *                 version nueva (`ultima_version`) y las notas de esa version
 *                 (`notas_version`). El frontend las muestra solo, sin
 *                 sesion, con el modal "Novedades de la vX" que se abre
 *                 automaticamente cuando la version cambia (App.jsx:161).
 *
 * USO
 * ---
 *   node scripts/aviso-mantenimiento.js iniciar \
 *     --mensaje "El acceso esta pausado mientras se aplican mejoras." \
 *     --mejoras "Cerrando la exposicion del padron de funcionarios" \
 *              "Restringiendo la escritura de los catalogos"
 *
 *   node scripts/aviso-mantenimiento.js cerrar \
 *     --mensaje "Las mejoras ya estan aplicadas." \
 *     --mejoras "El padron de funcionarios quedo acotado por dependencia" \
 *              "La escritura de catalogos quedo restringida a administradores" \
 *     --version 2.12.0
 *
 *   --mejoras acepta varias lineas (una por linea, o separadas por ";")
 *   --version es opcional en `cerrar`: si no se pasa, no se toca la version.
 *
 * La escritura va por un UPDATE de la fila 'global' de app_config. La tabla
 * tiene columnas planas Y una columna `data` JSONB (la usa el backend
 * Express). Se actualizan las dos para que no queden desincronizadas.
 * ============================================================================
 */
require('dotenv').config({ path: require('path').join(__dirname, '..', '.env') });
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

// --- Parseo de argumentos -----------------------------------------------------
const argv = process.argv.slice(2);
const accion = argv[0];
const opcion = (nombre, defecto = '') => {
  const i = argv.indexOf('--' + nombre);
  return i >= 0 && argv[i + 1] && !argv[i + 1].startsWith('--') ? argv[i + 1] : defecto;
};
const lista = (nombre) => opcion(nombre).split(/[\r\n;]+/).map(s => s.trim()).filter(Boolean);

if (!['iniciar', 'cerrar'].includes(accion)) {
  console.error('Uso:');
  console.error('  node scripts/aviso-mantenimiento.js iniciar --mensaje "..." --mejoras "a;b"');
  console.error('  node scripts/aviso-mantenimiento.js cerrar   --mensaje "..." --mejoras "a;b" [--version 2.12.0]');
  process.exit(1);
}

const mensaje = opcion('mensaje');
const mejoras = lista('mejoras');
const version = opcion('version');

const TITULO_EN_CURSO = 'Estamos ejecutando mejoras de urgencia';
const TITULO_FINALIZADO = 'Novedades de la ultima actualizacion';

(async () => {
  const c = await pool.connect();
  try {
    await c.query('BEGIN');

    const actual = await c.query("SELECT * FROM public.app_config WHERE id = 'global'");
    const previo = actual.rows[0] || {};
    const ahora = new Date().toISOString();

    const enMantenimiento = accion === 'iniciar';
    const titulo = opcion('titulo', enMantenimiento ? TITULO_EN_CURSO : TITULO_FINALIZADO);

    // `mejoras` se ve en el muro (MaintenanceScreen). `notas_version` es el
    // changelog "Novedades de la vX": se escribe al cerrar, para que quede
    // el aviso de lo que se hizo y se abra solo al cambiar la version.
    const payload = {
      en_mantenimiento: enMantenimiento,
      titulo,
      mensaje,
      mejoras,
      actualizado_en: ahora
    };

    const sets = [
      'en_mantenimiento = $1::boolean',
      'titulo = $2::text',
      'mensaje = $3::text',
      'mejoras = $4::jsonb',
      'actualizado_en = $5::timestamptz'
    ];
    const vals = [enMantenimiento, titulo, mensaje, JSON.stringify(mejoras), ahora];

    if (accion === 'cerrar') {
      if (version) {
        sets.push('ultima_version = $6::text');
        vals.push(version);
      }
      if (mejoras.length) {
        sets.push('notas_version = $' + (vals.length + 1) + '::jsonb');
        vals.push(JSON.stringify(mejoras));
      }
    }

    const upd = await c.query(
      'UPDATE public.app_config SET ' + sets.join(', ') + " WHERE id = 'global'",
      vals
    );
    if (upd.rowCount === 0) {
      // La fila 'global' no existe todavia: se crea con el estado pedido.
      await c.query(
        'INSERT INTO public.app_config (id, en_mantenimiento, titulo, mensaje, mejoras, actualizado_en, data) ' +
        "VALUES ('global', $1, $2, $3, $4::jsonb, $5, '{}'::jsonb)",
        vals.slice(0, 5)
      );
    }

    // La columna `data` JSONB la usa el backend Express: se mantiene espejo.
    await c.query(
      "UPDATE public.app_config SET data = data || $1::jsonb WHERE id = 'global'",
      [JSON.stringify({
        en_mantenimiento: enMantenimiento,
        titulo,
        mensaje,
        mejoras,
        actualizado_en: ahora,
        ...(accion === 'cerrar' && version ? { ultima_version: version } : {})
      })]
    );

    await c.query('COMMIT');

    const fin = await pool.query("SELECT en_mantenimiento, titulo, mensaje, mejoras, ultima_version, notas_version, actualizado_en FROM public.app_config WHERE id = 'global'");
    console.log('\n✅ app_config actualizado (' + accion + '):');
    console.log(JSON.stringify(fin.rows[0], null, 1));
    if (accion === 'iniciar') {
      console.log('\n   Muro ACTIVO. Recordá cerrarlo con `cerrar` al terminar.');
    } else {
      console.log('\n   Muro desactivado. La version ' + (version || '(sin cambio)') + ' queda publicada en el changelog.');
    }
  } catch (e) {
    await c.query('ROLLBACK').catch(() => {});
    console.error('❌ ' + e.message);
    process.exitCode = 1;
  } finally {
    // Sin liberar el cliente, pool.end() espera para siempre y el proceso no
    // termina nunca.
    c.release();
    await pool.end().catch(() => {});
  }
})();
