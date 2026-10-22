/**
 * backend/test/aviso.test.js
 * ============================================================================
 * El sincronizador de versión es lo que evita que la app muestre una versión
 * distinta de la que dice el changelog: cuando se subía a mano en un solo
 * lado, el pie y la ayuda decían "v2.11.0" mientras el changelog decía
 * "v2.13.0".
 *
 * Se prueba sobre un directorio temporal: no toca los archivos reales.
 * ============================================================================
 */
const { test, describe } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const { sincronizarVersionEnArchivos } = require('../scripts/aviso-mantenimiento');

/** Arma un repositorio de mentira con los archivos que declara la versión. */
const armarRepo = () => {
  const raiz = fs.mkdtempSync(path.join(os.tmpdir(), 'sigep-ver-'));
  fs.mkdirSync(path.join(raiz, 'backend'), { recursive: true });
  fs.mkdirSync(path.join(raiz, 'frontend', 'src', 'utils'), { recursive: true });

  fs.writeFileSync(
    path.join(raiz, 'backend', 'package.json'),
    JSON.stringify({ name: 'backend', version: '2.11.0' }, null, 2) + '\n'
  );
  fs.writeFileSync(
    path.join(raiz, 'backend', 'package-lock.json'),
    JSON.stringify({ name: 'backend', version: '2.11.0', lockfileVersion: 3, packages: { '': { name: 'backend', version: '2.11.0' } } }, null, 2) + '\n'
  );
  fs.writeFileSync(
    path.join(raiz, 'frontend', 'package.json'),
    JSON.stringify({ name: 'frontend', private: true, version: '0.0.0' }, null, 2) + '\n'
  );
  fs.writeFileSync(
    path.join(raiz, 'frontend', 'package-lock.json'),
    JSON.stringify({ name: 'frontend', version: '0.0.0', lockfileVersion: 3, packages: { '': { name: 'frontend', version: '0.0.0' } } }, null, 2) + '\n'
  );
  fs.writeFileSync(
    path.join(raiz, 'frontend', 'src', 'utils', 'helpers.js'),
    "export const APP_VERSION = '2.11.0';\n"
  );
  return raiz;
};

const leerJson = (p) => JSON.parse(fs.readFileSync(p, 'utf8'));

describe('sincronizador de versión', () => {
  test('propaga la versión a los package.json, a los locks y a APP_VERSION', () => {
    const raiz = armarRepo();
    const cambios = sincronizarVersionEnArchivos('2.13.1', raiz);

    assert.equal(leerJson(path.join(raiz, 'backend', 'package.json')).version, '2.13.1');
    assert.equal(leerJson(path.join(raiz, 'frontend', 'package.json')).version, '2.13.1');

    // El lock declara la versión en la raiz y en el paquete raiz: si alguno
    // queda viejo, `npm ci` falla y el build de Vercel no arranca.
    const lockBack = leerJson(path.join(raiz, 'backend', 'package-lock.json'));
    assert.equal(lockBack.version, '2.13.1');
    assert.equal(lockBack.packages[''].version, '2.13.1');
    const lockFront = leerJson(path.join(raiz, 'frontend', 'package-lock.json'));
    assert.equal(lockFront.version, '2.13.1');
    assert.equal(lockFront.packages[''].version, '2.13.1');

    const helpers = fs.readFileSync(path.join(raiz, 'frontend', 'src', 'utils', 'helpers.js'), 'utf8');
    assert.match(helpers, /export const APP_VERSION = '2\.13\.1';/);

    assert.equal(cambios.length, 5, 'debería reportar los 5 archivos que toco');
    fs.rmSync(raiz, { recursive: true, force: true });
  });

  test('no toca nada cuando la versión ya esta puesta', () => {
    const raiz = armarRepo();
    sincronizarVersionEnArchivos('2.13.1', raiz);
    const antes = fs.readFileSync(path.join(raiz, 'backend', 'package.json'), 'utf8');

    const cambios = sincronizarVersionEnArchivos('2.13.1', raiz);

    assert.deepEqual(cambios, [], 'no debería reportar cambios');
    assert.equal(
      fs.readFileSync(path.join(raiz, 'backend', 'package.json'), 'utf8'),
      antes,
      'el archivo no debería haber cambiado'
    );
    fs.rmSync(raiz, { recursive: true, force: true });
  });

  test('el lock se escribe con el mismo formato que usa npm', () => {
    const raiz = armarRepo();
    sincronizarVersionEnArchivos('2.13.1', raiz);
    const lock = fs.readFileSync(path.join(raiz, 'frontend', 'package-lock.json'), 'utf8');
    assert.equal(lock, JSON.stringify(JSON.parse(lock), null, 2) + '\n');
    fs.rmSync(raiz, { recursive: true, force: true });
  });

  test('no falla si falta el repositorio del frontend', () => {
    const raiz = fs.mkdtempSync(path.join(os.tmpdir(), 'sigep-ver-'));
    fs.mkdirSync(path.join(raiz, 'backend'), { recursive: true });
    fs.writeFileSync(
      path.join(raiz, 'backend', 'package.json'),
      JSON.stringify({ name: 'backend', version: '2.11.0' }, null, 2) + '\n'
    );
    const cambios = sincronizarVersionEnArchivos('2.13.1', raiz);
    assert.equal(leerJson(path.join(raiz, 'backend', 'package.json')).version, '2.13.1');
    assert.ok(cambios.length >= 1);
    fs.rmSync(raiz, { recursive: true, force: true });
  });
});
