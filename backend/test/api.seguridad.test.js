/**
 * backend/test/api.seguridad.test.js
 * ============================================================================
 * Pruebas de autorizacion de la API: IDOR, falsificacion de la auditoria y
 * acotado por dependencia.
 *
 * Antes no habia NINGUN test de rutas (la suite solo cubria funciones
 * puras de lib/), asi que un fallo de autorizacion podia llegar a produccion
 * sin que nadie lo notara. Estas pruebas levantan el server real y lo
 * consultan con tokens JWT firmados de verdad.
 *
 * Si no hay base de datos disponible, la suite se salta: en CI sin
 * PostgreSQL no tiene sentido fallar.
 * ============================================================================
 */
const { test, describe, before, after } = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const { spawn } = require('node:child_process');

const PUERTO = Number(process.env.TEST_API_PORT || 3211);
const BASE = 'http://127.0.0.1:' + PUERTO;

let srv = null;
let jwt = null;
let hayBD = false;

const firmados = (username, role) =>
  jwt.sign({ username, role }, process.env.SECRET_KEY, { expiresIn: '1h' });

const pedir = async (ruta, token, metodo = 'GET', cuerpo) => {
  const r = await fetch(BASE + ruta, {
    method: metodo,
    headers: {
      'Content-Type': 'application/json',
      ...(token ? { Authorization: 'Bearer ' + token } : {})
    },
    ...(cuerpo ? { body: JSON.stringify(cuerpo) } : {})
  });
  let datos = null;
  try { datos = await r.json(); } catch (e) { datos = null; }
  return { status: r.status, datos };
};

describe('autorizacion de la API', () => {
  before(async () => {
    require('dotenv').config({ path: path.join(__dirname, '..', '.env') });
    if (!process.env.DATABASE_URL || !process.env.SECRET_KEY) return;
    jwt = require('jsonwebtoken');
    srv = spawn('node', [path.join(__dirname, '..', 'server.js')], {
      cwd: path.join(__dirname, '..'),
      env: { ...process.env, PORT: String(PUERTO) },
      stdio: ['ignore', 'pipe', 'pipe']
    });
    srv.stdout.on('data', () => {});
    srv.stderr.on('data', () => {});
    // Se espera a que el server responda; si no arranca, no hay BD.
    for (let i = 0; i < 20; i++) {
      await new Promise(r => setTimeout(r, 500));
      try {
        const r = await fetch(BASE + '/api/health');
        if (r.ok || r.status === 503) { hayBD = true; break; }
      } catch (e) { /* todavia no levanta */ }
    }
  });

  after(() => {
    if (srv) srv.kill();
  });

  // OJO: la opcion `skip` de node:test se evalua al REGISTRAR el test, o sea
  // antes de que corra el `before`. Por eso el salto va dentro del cuerpo,
  // con t.skip(), y no como opcion.
  const t = (nombre, fn) => test(nombre, async (ctx) => {
    if (!hayBD) {
      ctx.skip('sin base de datos disponible');
      return;
    }
    await fn(ctx);
  });

  t('sin token, las rutas de datos responden 401', async () => {
    const r = await pedir('/api/bens', null);
    assert.equal(r.status, 401);
  });

  t('un funcionario no ve los bienes de otras dependencias', async () => {
    const token = firmados('biomedicas', 'user');
    const r = await pedir('/api/bens', token);
    assert.equal(r.status, 200);
    const total = await pedir('/api/bens', firmados('lsanchez', 'admin'));
    assert.ok(Array.isArray(r.datos), 'debe devolver un arreglo');
    assert.ok(
      r.datos.length < total.datos.length,
      'el funcionario tiene que ver menos bienes que el admin'
    );
  });

  t('un funcionario no puede crear, modificar ni borrar bienes', async () => {
    const token = firmados('biomedicas', 'user');
    assert.equal((await pedir('/api/bens', token, 'POST', { id: 'x' })).status, 403);
    assert.equal((await pedir('/api/bens/x', token, 'PUT', { id: 'x' })).status, 403);
    assert.equal((await pedir('/api/bens/x', token, 'DELETE')).status, 403);
  });

  t('un funcionario no puede crear actas ni estructuras', async () => {
    const token = firmados('biomedicas', 'user');
    assert.equal((await pedir('/api/fc10', token, 'POST', { id: 'x' })).status, 403);
    assert.equal((await pedir('/api/fc11', token, 'POST', { id: 'x' })).status, 403);
    assert.equal((await pedir('/api/fc04', token, 'POST', { id: 'x' })).status, 403);
    assert.equal((await pedir('/api/estructuras', token, 'POST', { id: 'x' })).status, 403);
  });

  t('el administrador si puede escribir', async () => {
    const token = firmados('lsanchez', 'admin');
    const id = 'test-admin-' + Date.now();
    const creado = await pedir('/api/bens', token, 'POST', { id, rotulo: 'prueba' });
    assert.equal(creado.status, 201);
    const borrado = await pedir('/api/bens/' + id, token, 'DELETE');
    assert.equal(borrado.status, 200);
  });

  t('la auditoria no se puede falsificar a nombre de otro usuario', async () => {
    const token = firmados('biomedicas', 'user');
    const r = await pedir('/api/auditoria', token, 'POST', {
      id: 'forja-' + Date.now(),
      usuarioDestino: 'lsanchez',
      accion: 'BAJA_APROBADA'
    });
    assert.equal(r.status, 201);
    // Se relee con el token de admin para ver a quien quedo attributed.
    const leido = await pedir('/api/auditoria', firmados('lsanchez', 'admin'));
    const fila = (leido.datos || []).find(f => String(f.id).startsWith('forja-'));
    assert.ok(fila, 'la fila deberia haberse creado');
    // OJO: en Postgres los identificadores sin comillas van en minuscula, asi
    // que la columna es `usuariodestino` (no `usuarioDestino`).
    assert.equal(
      fila.usuariodestino,
      'biomedicas',
      'el destinatario debe salir del token, no del cuerpo de la peticion'
    );
    assert.notEqual(
      fila.usuariodestino,
      'lsanchez',
      'no se puede escribir una traza a nombre de otro usuario'
    );
  });
});
