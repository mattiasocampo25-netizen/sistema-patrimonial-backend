/**
 * backend/test/rls_acotado.test.js
 * ============================================================================
 * Pruebas de las politicas RLS que acotan el padron de funcionarios, la
 * escritura de los catalogos y el permiso de ejecucion de las funciones.
 *
 * Estas pruebas NO pasan por la API: el backend se conecta con el rol
 * `postgres`, que salta el RLS. Para verificar el RLS hay que consultar la
 * base con el rol del usuario final (`anon` / `authenticated`) y las
 * afirmaciones del JWT.
 *
 * Cada prueba corre dentro de una transaccion que se revierte: la base real
 * no se toca nunca.
 *
 * Si no hay base de datos disponible, la suite se salta.
 * ============================================================================
 */
const { test, describe, before, after } = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');

require('dotenv').config({ path: path.join(__dirname, '..', '.env') });

let Pool = null;
let pool = null;
let hayBD = false;

describe('RLS: acotado por dependencia y permisos por rol', () => {
  before(async () => {
    if (!process.env.DATABASE_URL) return;
    const pg = require('pg');
    Pool = pg.Pool;
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

  // Corre una consulta como el rol indicado, con las afirmaciones del JWT.
  // Todo dentro de una transaccion que se revierte.
  const comoRol = async (role, email, fn) => {
    const c = await pool.connect();
    try {
      await c.query('BEGIN');
      await c.query('SET LOCAL ROLE ' + role);
      await c.query('SELECT set_config($1, $2, true)', [
        'request.jwt.claims',
        JSON.stringify({ role, email, sub: 'test' })
      ]);
      const out = await fn(c);
      await c.query('ROLLBACK');
      return out;
    } catch (e) {
      await c.query('ROLLBACK').catch(() => {});
      return { error: e.message };
    } finally {
      c.release();
    }
  };

  const t = (nombre, fn) => test(nombre, async (ctx) => {
    if (!hayBD) {
      ctx.skip('sin base de datos disponible');
      return;
    }
    await fn();
  });

  // --- El padron de funcionarios -------------------------------------------

  t('un funcionario solo ve los funcionarios de su dependencia', async () => {
    const r = await comoRol('authenticated', 'biomedicas@unp.edu.py', async (c) => {
      const total = await c.query('SELECT count(*)::int n FROM public.funcionarios');
      const deps = await c.query('SELECT count(DISTINCT dependencia)::int n FROM public.funcionarios');
      const propias = await c.query(
        "SELECT count(*)::int n FROM public.funcionarios " +
        "WHERE dependencia <> 'Facultad de Ciencias Biomédicas'"
      );
      return { total: total.rows[0].n, dependencias: deps.rows[0].n, ajenos: propias.rows[0].n };
    });
    assert.ok(!r.error, r.error);
    assert.ok(r.total > 0, 'debe ver al menos los suyos');
    assert.ok(r.dependencias <= 1, 'no debe ver funcionarios de mas de una dependencia');
    assert.equal(r.ajenos, 0, 'no debe ver ningun funcionario de otra dependencia');
  });

  t('un funcionario no puede modificar ni borrar funcionarios de otra dependencia', async () => {
    const upd = await comoRol('authenticated', 'biomedicas@unp.edu.py', async (c) => {
      const r = await c.query(
        "UPDATE public.funcionarios SET cargo = 'PROBE' " +
        "WHERE id = (SELECT id FROM public.funcionarios " +
        "           WHERE dependencia <> 'Facultad de Ciencias Biomédicas' LIMIT 1) " +
        'RETURNING id'
      );
      return r.rowCount;
    });
    assert.ok(!upd.error, upd.error);
    assert.equal(upd, 0, 'no debe poder modificar a otro');

    const del = await comoRol('authenticated', 'biomedicas@unp.edu.py', async (c) => {
      const r = await c.query(
        "DELETE FROM public.funcionarios " +
        "WHERE id = (SELECT id FROM public.funcionarios " +
        "           WHERE dependencia <> 'Facultad de Ciencias Biomédicas' LIMIT 1) " +
        'RETURNING id'
      );
      return r.rowCount;
    });
    assert.ok(!del.error, del.error);
    assert.equal(del, 0, 'no debe poder borrar a otro');
  });

  t('un funcionario no puede insertar un funcionario en otra dependencia', async () => {
    const r = await comoRol('authenticated', 'biomedicas@unp.edu.py', async (c) => {
      await c.query(
        "INSERT INTO public.funcionarios (nombre, cedula, dependencia) " +
        "VALUES ('probe_rls', '1', 'Facultad de Derecho, Ciencias Políticas y Sociales')"
      );
      return 'ok';
    });
    assert.ok(r.error, 'la insercion deberia haber sido rechazada por el RLS');
  });

  t('un funcionario si puede registrar funcionarios en su propia dependencia', async () => {
    const r = await comoRol('authenticated', 'biomedicas@unp.edu.py', async (c) => {
      const x = await c.query(
        "INSERT INTO public.funcionarios (nombre, cedula, dependencia) " +
        "VALUES ('probe_rls', '1', 'Facultad de Ciencias Biomédicas') RETURNING id"
      );
      return x.rowCount;
    });
    assert.ok(!r.error, r.error);
    assert.equal(r, 1);
  });

  // --- Los catalogos y el muro de mantenimiento -----------------------------

  t('un funcionario no puede escribir en los catalogos', async () => {
    // El RLS se comporta distinto segun el comando:
    //   - INSERT: viola el WITH CHECK y Postgres lanza el error.
    //   - UPDATE / DELETE: el USING deja la fila fuera del alcance, asi que
    //     la sentencia termina sin error pero sin afectar NINGUNA fila.
    // Por eso INSERT se comprueba por el error y el resto por el conteo.
    const casos = [
      { sql: "INSERT INTO public.dependencias (id, nombre) VALUES ('probe_rls', 'probe')", espera: 'error' },
      { sql: "DELETE FROM public.dependencias WHERE id = (SELECT id FROM public.dependencias LIMIT 1)", espera: 'cero' },
      { sql: "UPDATE public.dependencias SET nombre = 'probe' WHERE id = (SELECT id FROM public.dependencias LIMIT 1)", espera: 'cero' },
      { sql: "DELETE FROM public.ubicaciones WHERE id = (SELECT id FROM public.ubicaciones LIMIT 1)", espera: 'cero' },
      { sql: "UPDATE public.ubicaciones SET nombre = 'probe' WHERE id = (SELECT id FROM public.ubicaciones LIMIT 1)", espera: 'cero' },
      { sql: "DELETE FROM public.estructuras WHERE id = (SELECT id FROM public.estructuras LIMIT 1)", espera: 'cero' },
      { sql: "UPDATE public.estructuras SET data = '{}'::jsonb WHERE id = (SELECT id FROM public.estructuras LIMIT 1)", espera: 'cero' },
      { sql: "UPDATE public.app_config SET en_mantenimiento = true WHERE id = 'global'", espera: 'cero' }
    ];
    for (const { sql, espera } of casos) {
      const r = await comoRol('authenticated', 'biomedicas@unp.edu.py', async (c) => {
        const x = await c.query(sql);
        return x.rowCount;
      });
      if (espera === 'error') {
        assert.ok(r.error, 'el RLS deberia haber rechazado el INSERT: ' + sql);
      } else {
        assert.ok(!r.error, 'no deberia dar error (deberia afectar 0 filas): ' + sql);
        assert.equal(r, 0, 'no deberia afectar ninguna fila: ' + sql);
      }
    }
  });

  t('un funcionario no puede tocar el muro de mantenimiento', async () => {
    const r = await comoRol('authenticated', 'biomedicas@unp.edu.py', async (c) => {
      const x = await c.query(
        "UPDATE public.app_config SET en_mantenimiento = true WHERE id = 'global' RETURNING id"
      );
      return x.rowCount;
    });
    assert.ok(!r.error, r.error);
    assert.equal(r, 0, 'no debe poder activar ni desactivar el mantenimiento');
  });

  // --- El administrador ------------------------------------------------------

  t('el administrador ve y puede escribir en todo', async () => {
    const r = await comoRol('authenticated', 'lsanchez@unp.edu.py', async (c) => {
      const o = {};
      const f = await c.query('SELECT count(*)::int n FROM public.funcionarios');
      const u = await c.query('SELECT count(*)::int n FROM public.usuarios');
      const up = await c.query(
        "UPDATE public.funcionarios SET cargo = cargo " +
        "WHERE id = (SELECT id FROM public.funcionarios LIMIT 1) RETURNING id"
      );
      const ac = await c.query(
        "UPDATE public.app_config SET en_mantenimiento = en_mantenimiento WHERE id = 'global' RETURNING id"
      );
      o.funcionarios = f.rows[0].n;
      o.usuarios = u.rows[0].n;
      o.update_funcionario = up.rowCount;
      o.update_app_config = ac.rowCount;
      return o;
    });
    assert.ok(!r.error, r.error);
    assert.equal(r.update_funcionario, 1, 'el admin debe poder modificar a cualquiera');
    assert.equal(r.update_app_config, 1, 'el admin debe poder tocar el mantenimiento');
  });

  // --- El anonimo -----------------------------------------------------------

  t('el anonimo no puede leer el padron ni el inventario', async () => {
    for (const tabla of ['funcionarios', 'usuarios', 'bens']) {
      const r = await comoRol('anon', '', async (c) => {
        await c.query('SELECT count(*) FROM public.' + tabla);
        return 'ok';
      });
      assert.ok(r.error, 'el anonimo no deberia poder leer ' + tabla);
    }
  });

  t('el anonimo si puede leer la configuracion global (es el muro de mantenimiento)', async () => {
    const r = await comoRol('anon', '', async (c) => {
      const x = await c.query("SELECT en_mantenimiento FROM public.app_config WHERE id = 'global'");
      return x.rows.length;
    });
    assert.ok(!r.error, r.error);
    assert.equal(r, 1);
  });

  t('las funciones de la base no son ejecutables por el anonimo', async () => {
    for (const fn of [
      'public.cargo_actual()',
      'public.dependencia_actual()',
      'public.es_privilegiado_actual()',
      'public.usuario_actual()',
      'public.resumen_por_dependencia()',
      "public.admin_guardar_usuario('x', 'x', 'admin', 'Rectorado')"
    ]) {
      const r = await comoRol('anon', '', async (c) => {
        await c.query('SELECT * FROM ' + fn);
        return 'ok';
      });
      assert.ok(r.error, 'el anonimo no deberia poder ejecutar ' + fn);
    }
  });

  t('el anonimo si puede ejecutar la RPC de la vista publica del QR', async () => {
    const r = await comoRol('anon', '', async (c) => {
      const x = await c.query("SELECT * FROM public.obtener_bien_publico('__no_existe__')");
      return x.rows.length;
    });
    assert.ok(!r.error, r.error);
  });
});
