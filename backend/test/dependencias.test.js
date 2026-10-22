/**
 * backend/test/dependencias.test.js
 * ============================================================================
 * Los scripts del toolkit tienen que seguir siendo ejecutables.
 *
 * QUE PASÓ
 * ---------
 * Cuando se retiró la API REST en Express (commit 4b3cc7d) se borraron sus
 * dependencias (`express`, `cors`, `socket.io`, `jsonwebtoken`, `bcryptjs`).
 * Pero `bcryptjs` la usa también `scripts/crear-cuenta-auth.js`, que es la
 * herramienta documentada para dar de alta las cuentas de acceso de los
 * usuarios. El script quedó roto: `npm run db:crear-cuenta` fallaba con
 * "Cannot find module 'bcryptjs'" y no había forma de crear una cuenta.
 *
 * El fallo era silencioso porque nada comprobaba que los `require()` de los
 * scripts estuvieran declarados en el `package.json`.
 *
 * QUE COMPRUEBA ESTE ARCHIVO
 * --------------------------
 * Que todo módulo que los scripts del toolkit requieren con `require()` esté
 * declarado en las dependencias del `package.json` (las que se instalaron
 * durante el retiro de Express, sin las que quedaban)).
 * ============================================================================
 */
const { test, describe } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const RAIZ = path.join(__dirname, '..');

const SCRIPTS = fs.readdirSync(path.join(RAIZ, 'scripts'))
  .filter((f) => f.endsWith('.js'));

// Módulos que no son paquetes: son de Node o son relativos del propio repo.
const NO_ES_PAQUETE = new Set([
  'fs', 'path', 'crypto', 'url', 'http', 'https', 'os', 'zlib', 'stream',
  'buffer', 'util', 'events', 'child_process', 'worker_threads', 'assert',
  'node:test', 'node:assert', 'node:fs', 'node:path', 'node:crypto',
  'node:url', 'node:http', 'node:https', 'node:os', 'node:zlib', 'node:stream',
  'node:util', 'node:events', 'node:child_process', 'node:worker_threads',
  'node:timers', 'node:net', 'node:tls', 'node:querystring', 'node:string_decoder'
]);

const esRelativo = (mod) => mod.startsWith('.') || mod.startsWith('/') || mod.startsWith('node:');

describe('dependencias de los scripts', () => {
  test('todo lo que los scripts requieren está declarado en el package.json', () => {
    const pkg = JSON.parse(fs.readFileSync(path.join(RAIZ, 'package.json'), 'utf8'));
    const declaradas = new Set([
      ...Object.keys(pkg.dependencies || {}),
      ...Object.keys(pkg.devDependencies || {})
    ]);

    const faltantes = [];
    for (const archivo of SCRIPTS) {
      const codigo = fs.readFileSync(path.join(RAIZ, 'scripts', archivo), 'utf8');
      const re = /require\(\s*['"]([^'"]+)['"]\s*\)/g;
      let m;
      while ((m = re.exec(codigo)) !== null) {
        const mod = m[1];
        if (esRelativo(mod) || NO_ES_PAQUETE.has(mod)) continue;
        // Los subpaquetes ("pg/native") los cubre el paquete raiz ("pg").
        const raiz = mod.startsWith('@') ? mod.split('/').slice(0, 2).join('/') : mod.split('/')[0];
        if (!declaradas.has(raiz)) faltantes.push(archivo + ' -> ' + mod);
      }
    }

    assert.deepEqual(
      faltantes,
      [],
      'estos modulos se requieren pero no estan declarados en package.json: ' +
        faltantes.join(', ') +
        '. Se agregan con: npm install <modulo> --save'
    );
  });

  test('los scripts del toolkit se pueden cargar sin error de modulo', () => {
    // Se cargan con un entorno falso: los que piden variables de entorno
    // avisan y salen con codigo 1, pero ninguno debe fallar por un require.
    const { spawnSync } = require('node:child_process');
    for (const archivo of SCRIPTS) {
      const r = spawnSync(process.execPath, [path.join(RAIZ, 'scripts', archivo)], {
        env: { PATH: process.env.PATH, NODE_ENV: 'test' },
        encoding: 'utf8',
        timeout: 20000
      });
      const salida = (r.stdout || '') + (r.stderr || '');
      assert.ok(
        !/Cannot find module/.test(salida),
        'scripts/' + archivo + ' falla por un modulo que no esta instalado: ' +
          (salida.match(/Cannot find module '[^']+'/g) || []).join(', ')
      );
    }
  });
});
