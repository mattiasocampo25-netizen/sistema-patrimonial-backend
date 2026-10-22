/**
 * backend/test/versión.test.js
 * ============================================================================
 * La versión del sistema tiene que ser la misma en todos lados.
 *
 * La que ve el usuario sale de `app_config.ultima_version` (esta base). El
 * script `npm run aviso:cerrar -- --version X` la publica y actualiza además
 * el `package.json` de cada repositorio y la constante `APP_VERSION` del
 * frontend.
 *
 * Antes la versión se subia a mano en un solo lado y la app terminaba
 * mostrando "v2.11.0" en el pie y en la ayuda mientras el changelog de la
 * versión 2.13.0 decia otra cosa.
 *
 * Si no hay base de datos disponible, la parte que la consulta se salta.
 * ============================================================================
 */
const { test, describe, before, after } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const RAIZ = path.join(__dirname, '..');
const REPO = path.join(RAIZ, '..');

const leerPkg = (archivo) => {
  if (!fs.existsSync(archivo)) return null;
  return JSON.parse(fs.readFileSync(archivo, 'utf8'));
};

describe('versión del sistema', () => {
  let pool = null;
  let hayBD = false;

  before(async () => {
    require('dotenv').config({ path: path.join(RAIZ, '.env') });
    if (!process.env.DATABASE_URL) return;
    const { Pool } = require('pg');
    pool = new Pool({
      connectionString: process.env.DATABASE_URL,
      ssl: { rejectUnauthorized: false },
      connectionTimeoutMillis: 20000
    });
    try {
      await pool.query('SELECT 1');
      hayBD = true;
    } catch (e) {
      hayBD = false;
    }
  });

  after(async () => {
    if (pool) await pool.end();
  });

  test('los package.json de los dos repositorios declaran la misma versión', () => {
    const backend = leerPkg(path.join(RAIZ, 'package.json'));
    const frontend = leerPkg(path.join(REPO, 'frontend', 'package.json'));
    assert.ok(backend, 'no se encontro backend/package.json');
    if (!frontend) return; // el frontend puede no estar clonado (repo anidado)
    assert.equal(
      frontend.version,
      backend.version,
      'las versiones de los dos repositorios no coinciden. ' +
      'Se actualizan juntas con: npm run aviso:cerrar -- --version X'
    );
  });

  test('la versión tiene forma de versión semantica', () => {
    const v = leerPkg(path.join(RAIZ, 'package.json')).version;
    assert.match(v, /^\d+\.\d+\.\d+$/, 'la versión debería ser X.Y.Z, no "' + v + '"');
  });

  test('app_config.ultima_version coincide con el package.json', async (ctx) => {
    if (!hayBD) {
      ctx.skip('sin base de datos disponible');
      return;
    }
    const r = await pool.query("SELECT ultima_version FROM public.app_config WHERE id = 'global'");
    const enBase = r.rows[0] && r.rows[0].ultima_version;
    const enPkg = leerPkg(path.join(RAIZ, 'package.json')).version;
    assert.equal(
      enBase,
      enPkg,
      'la versión publicada en la base no coincide con el package.json. ' +
      'Se actualizan juntas con: npm run aviso:cerrar -- --version X'
    );
  });
});
