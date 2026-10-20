/**
 * ============================================================================
 * SERVIDOR BACKEND (API REST) - SISTEMA DE GESTIÓN PATRIMONIAL UNP (SUPABASE)
 * ============================================================================
 * API auxiliar sobre PostgreSQL (columna JSONB `data`). La SPA en producción
 * habla con Supabase Auth + RLS; este servidor no debe quedar abierto.
 */

require('dotenv').config();

const express = require('express');
const cors = require('cors');
const http = require('http');
const { Server } = require('socket.io');
const { Pool } = require('pg');
const bcrypt = require('bcryptjs');
const jwt = require('jsonwebtoken');
const { parseRowData, idValido, esPrivilegiado } = require('./lib/helpers');
const { cabecerasSeguras, cabecerasCSP, crearLimitadorLogin, tablaEnBlanco, crearLimitadorGeneral, sanitizarObjeto } = require('./lib/security');
const { validarEntradaLogin, autenticarUsuario } = require('./lib/auth');
const { exigirAdmin } = require('./lib/authz');
const {
  validarEsquemaRespaldo,
  armarRespaldo,
  ORDEN_RESTAURACION,
  TABLAS_CONOCIDAS,
  normalizarFilaParaEscribir
} = require('./lib/respaldo');

const BCRYPT_ROUNDS = 12;
const MAX_BULK = 2000;
const PORT = process.env.PORT || 3001;
const SECRET_KEY = process.env.SECRET_KEY;
const CORS_ORIGIN = (process.env.CORS_ORIGIN || 'http://localhost:5173')
  .split(',')
  .map((s) => s.trim())
  .filter(Boolean);

const app = express();
const server = http.createServer(app);
const corsOpts = { origin: CORS_ORIGIN, methods: ['GET', 'POST', 'PUT', 'DELETE'] };
const io = new Server(server, { cors: corsOpts });

app.use(cabecerasSeguras);
app.use(cabecerasCSP);
app.use(cors(corsOpts));
app.use(express.json({ limit: '2mb' }));

const databaseUrl = process.env.DATABASE_URL;
if (!databaseUrl) {
  console.error('❌ Falta la variable de entorno DATABASE_URL. Copia .env.example a .env y completa la URL de conexión.');
  process.exit(1);
}

if (!SECRET_KEY) {
  console.error('❌ Falta la variable de entorno SECRET_KEY. Genera una con: node -e "console.log(require(\'crypto\').randomBytes(48).toString(\'hex\'))"');
  process.exit(1);
}

// Ya no se usa para crear el usuario 'admin' (ver inicializarTablas): la
// app autentica con Supabase Auth y la tabla `usuarios` solo guarda el
// perfil. Se mantiene como aviso por compatibilidad con despliegues viejos.
const ADMIN_INITIAL_PASSWORD = process.env.ADMIN_INITIAL_PASSWORD;
if (!ADMIN_INITIAL_PASSWORD) {
  console.warn('⚠️  ADMIN_INITIAL_PASSWORD no está definida. Ya no se usa (el alta de usuarios se hace contra Supabase Auth).');
}

const ssl = process.env.DATABASE_SSL === 'disable'
  ? false
  : { rejectUnauthorized: process.env.PGSSL_REJECT_UNAUTHORIZED === 'true' };

const pool = new Pool({
  connectionString: databaseUrl,
  ssl
});

// Sin este listener, un error en un cliente idle de 'pg' se lanza como
// excepcion no capturada y MATA el proceso (ver doc de node-postgres).
pool.on('error', (err) => {
  console.error('❌ Error inesperado en el pool de PostgreSQL:', err.message);
});

pool.connect((err, client, release) => {
  if (err) {
    return console.error('❌ Error al conectar con Supabase (PostgreSQL):', err.message);
  }
  console.log('✅ Conectado exitosamente a Supabase (Cloud)');
  release();
  inicializarTablas();
});

function enviarError(res, err) {
  console.error(err);
  if (!res.headersSent) res.status(500).json({ error: 'Error interno' });
}

function autenticar(req, res, next) {
  const header = req.headers.authorization || '';
  const token = header.startsWith('Bearer ') ? header.slice(7) : '';
  if (!token) return res.status(401).json({ error: 'No autorizado' });
  try {
    req.user = jwt.verify(token, SECRET_KEY);
    next();
  } catch (e) {
    return res.status(401).json({ error: 'No autorizado' });
  }
}

function exigirPrivilegio(req, res, next) {
  if (!esPrivilegiado(req.user?.role)) {
    return res.status(403).json({ error: 'Permiso denegado' });
  }
  next();
}

io.use((socket, next) => {
  const token = socket.handshake.auth?.token || socket.handshake.query?.token;
  if (!token) return next(new Error('No autorizado'));
  try {
    jwt.verify(token, SECRET_KEY);
    next();
  } catch (e) {
    next(new Error('No autorizado'));
  }
});

function inicializarTablas() {
  const queries = [
    `CREATE TABLE IF NOT EXISTS bens (id TEXT PRIMARY KEY, data JSONB)`,
    `CREATE TABLE IF NOT EXISTS fc10 (id TEXT PRIMARY KEY, data JSONB)`,
    `CREATE TABLE IF NOT EXISTS fc11 (id TEXT PRIMARY KEY, data JSONB)`,
    `CREATE TABLE IF NOT EXISTS fc04 (id TEXT PRIMARY KEY, data JSONB)`,
    `CREATE TABLE IF NOT EXISTS estructuras (id TEXT PRIMARY KEY, data JSONB)`,
    `CREATE TABLE IF NOT EXISTS usuarios (username TEXT PRIMARY KEY, nombre TEXT, password TEXT, cargo TEXT)`,
    `CREATE TABLE IF NOT EXISTS auditoria (
      id TEXT PRIMARY KEY, tipoRegistro TEXT, usuarioDestino TEXT, titulo TEXT,
      mensaje TEXT, leido INTEGER, fecha TEXT, bienId TEXT, accion TEXT
    )`
  ];

  (async () => {
    try {
      for (const q of queries) {
        await pool.query(q);
      }
      // NO se crea un usuario 'admin' acá a propósito.
      //
      // La app autentica con Supabase Auth, no con la tabla `usuarios`: esa
      // tabla solo guarda el perfil (username, nombre, cargo, dependencia).
      // Un usuario 'admin' creado desde acá queda como perfil huérfano, sin
      // cuenta de Auth, y no puede iniciar sesión nunca. Peor: se insertaba
      // su contraseña con bcrypt en `usuarios.password`, que es una columna
      // legacy que la app ya no usa (y que la migración 002 dejó en bcrypt
      // para que al menos no quede en texto plano).
      console.log('✅ Tablas verificadas/inicializadas en Supabase.');
    } catch (e) {
      console.error('❌ Error al inicializar tablas:', e.message);
    }
  })();
}

async function upsertJson(tabla, id, cuerpo) {
  // Lista blanca: `tabla` se interpola en el SQL, así que no puede venir del
  // pedido. Los llamados actuales pasan literales conocidos, pero el chequeo
  // evita que un refactor futuro abra una inyección por interpolación.
  if (!tablaEnBlanco(tabla)) {
    throw new Error(`Tabla no permitida: ${String(tabla)}`);
  }
  await pool.query(
    `INSERT INTO ${tabla} (id, data) VALUES ($1, $2) ON CONFLICT (id) DO UPDATE SET data = $2`,
    [id, JSON.stringify(cuerpo)]
  );
}

app.get('/api/health', (_req, res) => {
  res.json({ ok: true });
});

// Limita intentos de login por IP: sin esto, la API auxiliar queda abierta a
// fuerza bruta. Es en memoria (una sola instancia); ver lib/security.js.
const limitadorLogin = crearLimitadorLogin();

// Limitador general para todos los endpoints protegidos (anti-abuso, DoS ligero).
const limitadorGeneral = crearLimitadorGeneral({ ventanaMs: 60 * 1000, maxIntentos: 120, bloqueoMs: 60 * 1000 });

app.post('/api/login', limitadorLogin, async (req, res) => {
  const entrada = validarEntradaLogin(req.body);
  if (!entrada.ok) {
    return res.status(401).json({ error: 'Credenciales incorrectas' });
  }
  try {
    const resultado = await autenticarUsuario(pool, entrada, SECRET_KEY);
    if (!resultado.ok) {
      return res.status(401).json({ error: resultado.error });
    }
    res.json({ token: resultado.token, user: resultado.user });
  } catch (err) {
    enviarError(res, err);
  }
});

app.use('/api', autenticar);
app.use('/api', limitadorGeneral);
// Sanitización ligera de cuerpos JSON entrantes (previene claves '__proto__',
// 'constructor', 'prototype' y elimina claves nulas vacías).
app.use('/api', (req, res, next) => {
  if (req.body && typeof req.body === 'object' && !Array.isArray(req.body)) {
    req.body = sanitizarObjeto(req.body);
  }
  next();
});

app.get('/api/bens', async (_req, res) => {
  try {
    const result = await pool.query('SELECT * FROM bens');
    const bienes = result.rows.map((r) => {
      const item = parseRowData(r);
      return {
        ...item,
        hasFC10: Boolean(item.hasFC10),
        hasQR: Boolean(item.hasQR),
        solicitudBaja: Boolean(item.solicitudBaja)
      };
    });
    res.json(bienes);
  } catch (err) {
    enviarError(res, err);
  }
});

app.post('/api/bens', async (req, res) => {
  const b = req.body;
  if (!idValido(b?.id)) return res.status(400).json({ error: 'Id inválido' });
  try {
    await upsertJson('bens', b.id, b);
    io.emit('data_updated');
    res.status(201).json({ message: 'Bien creado exitosamente', id: b.id });
  } catch (err) {
    enviarError(res, err);
  }
});

app.post('/api/bens/bulk', async (req, res) => {
  const bienesArray = req.body;
  if (!Array.isArray(bienesArray)) return res.status(400).json({ error: 'Arreglo inválido' });
  if (bienesArray.length > MAX_BULK) return res.status(400).json({ error: 'Demasiados registros' });

  let client;
  try {
    // El connect va DENTRO del try: si el pool no entrega cliente, la promesa
    // rechazaria fuera del try y Express 4 no captura ese rejection -> proceso muerto.
    client = await pool.connect();
    await client.query('BEGIN');
    for (const b of bienesArray) {
      if (!idValido(b?.id)) {
        await client.query('ROLLBACK');
        return res.status(400).json({ error: 'Id inválido en la carga masiva' });
      }
      await client.query(
        'INSERT INTO bens (id, data) VALUES ($1, $2) ON CONFLICT (id) DO UPDATE SET data = $2',
        [b.id, JSON.stringify(b)]
      );
    }
    await client.query('COMMIT');
    io.emit('data_updated');
    res.status(201).json({ message: `${bienesArray.length} bienes importados` });
  } catch (err) {
    try { if (client) await client.query('ROLLBACK'); } catch (e) { /* rollback ya falló */ }
    enviarError(res, err);
  } finally {
    if (client) client.release();
  }
});

app.put('/api/bens/:id', async (req, res) => {
  if (!idValido(req.params.id)) return res.status(400).json({ error: 'Id inválido' });
  try {
    const result = await pool.query('UPDATE bens SET data = $1 WHERE id = $2', [JSON.stringify(req.body), req.params.id]);
    if (result.rowCount === 0) return res.status(404).json({ error: 'No encontrado' });
    io.emit('data_updated');
    res.json({ message: 'Bien actualizado' });
  } catch (err) {
    enviarError(res, err);
  }
});

app.delete('/api/bens/:id', async (req, res) => {
  if (!idValido(req.params.id)) return res.status(400).json({ error: 'Id inválido' });
  try {
    const result = await pool.query('DELETE FROM bens WHERE id = $1', [req.params.id]);
    if (result.rowCount === 0) return res.status(404).json({ error: 'No encontrado' });
    io.emit('data_updated');
    res.json({ message: 'Bien eliminado' });
  } catch (err) {
    enviarError(res, err);
  }
});

app.get('/api/fc10', async (_req, res) => {
  try {
    const result = await pool.query('SELECT * FROM fc10');
    res.json(result.rows.map((r) => parseRowData(r)));
  } catch (err) {
    enviarError(res, err);
  }
});

app.post('/api/fc10', async (req, res) => {
  const f = req.body;
  if (!idValido(f?.id)) return res.status(400).json({ error: 'Id inválido' });
  try {
    await upsertJson('fc10', f.id, f);
    io.emit('data_updated');
    res.status(201).json({ message: 'FC-10 registrado' });
  } catch (err) {
    enviarError(res, err);
  }
});

app.put('/api/fc10/:id', async (req, res) => {
  if (!idValido(req.params.id)) return res.status(400).json({ error: 'Id inválido' });
  try {
    const result = await pool.query('UPDATE fc10 SET data = $1 WHERE id = $2', [JSON.stringify(req.body), req.params.id]);
    if (result.rowCount === 0) return res.status(404).json({ error: 'No encontrado' });
    io.emit('data_updated');
    res.json({ message: 'FC-10 actualizado' });
  } catch (err) {
    enviarError(res, err);
  }
});

app.delete('/api/fc10/:id', async (req, res) => {
  if (!idValido(req.params.id)) return res.status(400).json({ error: 'Id inválido' });
  try {
    const result = await pool.query('DELETE FROM fc10 WHERE id = $1', [req.params.id]);
    if (result.rowCount === 0) return res.status(404).json({ error: 'No encontrado' });
    io.emit('data_updated');
    res.json({ message: 'FC-10 eliminado' });
  } catch (err) {
    enviarError(res, err);
  }
});

app.get('/api/fc11', async (_req, res) => {
  try {
    const result = await pool.query('SELECT * FROM fc11');
    res.json(result.rows.map((r) => parseRowData(r)));
  } catch (err) {
    enviarError(res, err);
  }
});

app.post('/api/fc11', async (req, res) => {
  const f = req.body;
  if (!idValido(f?.id)) return res.status(400).json({ error: 'Id inválido' });
  try {
    await upsertJson('fc11', f.id, f);
    io.emit('data_updated');
    res.status(201).json({ message: 'FC-11 registrado' });
  } catch (err) {
    enviarError(res, err);
  }
});

app.get('/api/fc04', async (_req, res) => {
  try {
    const result = await pool.query('SELECT * FROM fc04');
    res.json(result.rows.map((r) => parseRowData(r)));
  } catch (err) {
    enviarError(res, err);
  }
});

app.post('/api/fc04', async (req, res) => {
  const f = req.body;
  if (!idValido(f?.id)) return res.status(400).json({ error: 'Id inválido' });
  try {
    await upsertJson('fc04', f.id, f);
    io.emit('data_updated');
    res.status(201).json({ message: 'FC-04 registrado' });
  } catch (err) {
    enviarError(res, err);
  }
});

app.get('/api/estructuras', async (_req, res) => {
  try {
    const result = await pool.query('SELECT * FROM estructuras');
    res.json(result.rows.map((r) => parseRowData(r)));
  } catch (err) {
    enviarError(res, err);
  }
});

app.post('/api/estructuras', async (req, res) => {
  const e = req.body;
  if (!idValido(e?.id)) return res.status(400).json({ error: 'Id inválido' });
  try {
    await upsertJson('estructuras', e.id, e);
    res.status(201).json({ message: 'Estructura guardada' });
  } catch (err) {
    enviarError(res, err);
  }
});

app.get('/api/usuarios', exigirPrivilegio, async (_req, res) => {
  try {
    const result = await pool.query('SELECT username, nombre, cargo FROM usuarios');
    res.json(result.rows);
  } catch (err) {
    enviarError(res, err);
  }
});

app.post('/api/usuarios', exigirPrivilegio, async (req, res) => {
  const username = typeof req.body?.username === 'string' ? req.body.username.trim() : '';
  const nombre = typeof req.body?.nombre === 'string' ? req.body.nombre.trim() : '';
  const password = typeof req.body?.password === 'string' ? req.body.password : '';
  const cargo = typeof req.body?.cargo === 'string' ? req.body.cargo.trim() : 'funcionario';
  if (!idValido(username) || !nombre || password.length < 8) {
    return res.status(400).json({ error: 'Datos de usuario inválidos' });
  }
  try {
    const hashedPassword = await bcrypt.hash(password, BCRYPT_ROUNDS);
    await pool.query(
      'INSERT INTO usuarios (username, nombre, password, cargo) VALUES ($1, $2, $3, $4)',
      [username, nombre, hashedPassword, cargo]
    );
    res.status(201).json({ message: 'Usuario creado exitosamente' });
  } catch (err) {
    enviarError(res, err);
  }
});

app.delete('/api/usuarios/:username', exigirPrivilegio, async (req, res) => {
  const username = req.params.username;
  if (!idValido(username)) return res.status(400).json({ error: 'Usuario inválido' });
  if (req.user?.username === username) {
    return res.status(400).json({ error: 'No podés eliminar tu propia cuenta' });
  }
  try {
    const result = await pool.query('DELETE FROM usuarios WHERE username = $1', [username]);
    if (result.rowCount === 0) return res.status(404).json({ error: 'No encontrado' });
    res.json({ message: 'Usuario eliminado' });
  } catch (err) {
    enviarError(res, err);
  }
});

app.get('/api/auditoria', async (_req, res) => {
  try {
    const result = await pool.query('SELECT * FROM auditoria');
    res.json(result.rows.map((r) => ({ ...r, leido: Boolean(r.leido) })));
  } catch (err) {
    enviarError(res, err);
  }
});

app.post('/api/auditoria', async (req, res) => {
  const a = req.body;
  if (!idValido(a?.id)) return res.status(400).json({ error: 'Id inválido' });
  try {
    await pool.query(
      `INSERT INTO auditoria (id, tipoRegistro, usuarioDestino, titulo, mensaje, leido, fecha, bienId, accion)
       VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)`,
      [a.id, a.tipoRegistro, a.usuarioDestino, a.titulo, a.mensaje, a.leido ? 1 : 0, a.fecha, a.bienId || '', a.accion || '']
    );
    res.status(201).json({ message: 'Notificación creada' });
  } catch (err) {
    enviarError(res, err);
  }
});

// ============================================================================
// RUTAS DE RESPALDO Y RESTAURACIÓN (solo admin/desarrollador)
// ============================================================================

/**
 * GET /api/respaldo/exportar
 * Genera y devuelve un JSON completo de todas las tablas para descargar.
 */
app.get('/api/respaldo/exportar', exigirAdmin, async (_req, res) => {
  try {
    const filasPorTabla = {};
    for (const clave of ORDEN_RESTAURACION) {
      const pk = TABLAS_CONOCIDAS[clave];
      let result;
      if (clave === 'usuarios') {
        result = await pool.query(`SELECT username, nombre, cargo, dependencia FROM ${clave}`);
        filasPorTabla[clave] = result.rows;
      } else if (clave === 'app_config') {
        result = await pool.query(`SELECT * FROM ${clave}`);
        filasPorTabla[clave] = result.rows;
      } else {
        // tablas JSONB: devolver { id, data } para conservar envoltura esperada.
        result = await pool.query(`SELECT id, data FROM ${clave}`);
        filasPorTabla[clave] = result.rows.map((r) => {
          const data = typeof r.data === 'string' ? JSON.parse(r.data) : (r.data || {});
          return { id: r.id, data };
        });
      }
    }

    const respaldo = armarRespaldo(filasPorTabla, (req.user && req.user.username) || 'sistema');
    res.setHeader('Content-Type', 'application/json');
    res.setHeader('Content-Disposition', `attachment; filename="respaldo_${new Date().toISOString().slice(0,10)}.json"`);
    res.json(respaldo);
  } catch (err) {
    enviarError(res, err);
  }
});

/**
 * POST /api/respaldo/restaurar
 * Recibe un JSON de respaldo, valida esquema y escribe en la BD por lotes.
 * Transacción por tabla: si falla una tabla, se hace rollback de esa tabla.
 */
app.post('/api/respaldo/restaurar', exigirAdmin, async (req, res) => {
  let cliente;
  try {
    // El connect va DENTRO del try: si el pool no entrega cliente, la promesa
    // rechazaria fuera del try y Express 4 no captura ese rejection -> proceso muerto.
    cliente = await pool.connect();
    const crudo = req.body;
    const validacion = validarEsquemaRespaldo(crudo);

    if (!validacion.ok) {
      return res.status(400).json({ error: 'Validación de respaldo fallida', errores: validacion.errores, avisos: validacion.avisos });
    }

    const { tablas, metadata } = validacion;
    const resultados = [];
    const errores = [];

    // Restaurar en orden de dependencias.
    for (const clave of ORDEN_RESTAURACION) {
      const filas = tablas[clave] || [];
      if (filas.length === 0) {
        resultados.push({ clave, etiqueta: clave, escritas: 0, ok: true });
        continue;
      }

      const pk = TABLAS_CONOCIDAS[clave];
      const ahora = new Date().toISOString();
      let escritas = 0;
      let falloTabla = null;

      await cliente.query('BEGIN');
      try {
        // Escribir por lotes de 500.
        for (let i = 0; i < filas.length; i += 500) {
          const lote = filas.slice(i, i + 500);
          if (clave === 'usuarios') {
            // Usuarios: columnas sueltas (no JSONB). Se omite password del respaldo.
            for (const f of lote) {
              await cliente.query(
                `INSERT INTO usuarios (username, nombre, cargo, dependencia)
                 VALUES ($1, $2, $3, $4)
                 ON CONFLICT (username) DO UPDATE SET nombre = EXCLUDED.nombre, cargo = EXCLUDED.cargo, dependencia = EXCLUDED.dependencia`,
                [f.username, f.nombre || '', f.cargo || 'funcionario', f.dependencia || '']
              );
              escritas++;
            }
          } else if (clave === 'app_config') {
            for (const f of lote) {
              await cliente.query(
                `INSERT INTO app_config (id, data) VALUES ($1, $2)
                 ON CONFLICT (id) DO UPDATE SET data = EXCLUDED.data`,
                [f.id, JSON.stringify(f)]
              );
              escritas++;
            }
          } else {
            // Tablas JSONB: { id, data }.
            for (const f of lote) {
              const cuerpo = normalizarFilaParaEscribir(f, pk);
              await cliente.query(
                `INSERT INTO ${clave} (id, data) VALUES ($1, $2)
                 ON CONFLICT (id) DO UPDATE SET data = EXCLUDED.data`,
                [cuerpo.id || cuerpo[pk], JSON.stringify(cuerpo)]
              );
              escritas++;
            }
          }
        }
        await cliente.query('COMMIT');
      } catch (e) {
        await cliente.query('ROLLBACK');
        falloTabla = e.message;
        errores.push(`${clave}: ${falloTabla}`);
      }

      resultados.push({
        clave,
        etiqueta: clave,
        escritas,
        ok: !falloTabla,
        error: falloTabla
      });
    }

    // Auditoría de la restauración.
    try {
      await pool.query(
        `INSERT INTO auditoria (id, tipoRegistro, usuarioDestino, titulo, mensaje, leido, fecha, bienId, accion)
         VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)`,
        [
          require('crypto').randomBytes(16).toString('hex'),
          'sistema',
          (req.user && req.user.username) || 'sistema',
          'Restauración de respaldo',
          `Restaurado archivo "${metadata.fechaGeneracion}" con ${metadata.totalFilas} filas`,
          0,
          new Date().toISOString(),
          '',
          'RESTAURAR_RESPALDO'
        ]
      );
    } catch (e) {
      // No bloquear la respuesta si la auditoría falla.
      console.error('Auditoría de restauración no se pudo registrar:', e.message);
    }

    const fallos = resultados.filter((r) => !r.ok).length;
    if (fallos === 0) {
      res.json({ message: 'Restauración completada exitosamente', resultados, totalFilas: metadata.totalFilas });
    } else {
      res.status(207).json({ message: `Restauración con ${fallos} error(es)`, resultados, errores });
    }
  } catch (err) {
    try { if (cliente) await cliente.query('ROLLBACK'); } catch (_) {}
    enviarError(res, err);
  } finally {
    if (cliente) cliente.release();
  }
});

/**
 * PATCH /api/fc10/:id/firma-estado
 * Cambia manualmente el estado de firma de un acta FC-10.
 * SOLO rol admin/desarrollador (protegido por exigirAdmin).
 * Cuerpo: { estadoFirma: 'BORRADOR'|'ESPERA_FIRMA_1'|'ESPERA_FIRMA_2'|'CERRADO', registradoPor?: string }
 */
app.patch('/api/fc10/:id/firma-estado', exigirAdmin, async (req, res) => {
  if (!idValido(req.params.id)) {
    return res.status(400).json({ error: 'Id inválido' });
  }
  const { estadoFirma, registradoPor } = req.body;
  const validos = ['BORRADOR', 'ESPERA_FIRMA_1', 'ESPERA_FIRMA_2', 'CERRADO'];
  if (!estadoFirma || !validos.includes(estadoFirma)) {
    return res.status(400).json({ error: 'estadoFirma inválido' });
  }

  try {
    // Leer el acta actual.
    const actual = await pool.query('SELECT data FROM fc10 WHERE id = $1', [req.params.id]);
    if (actual.rowCount === 0) {
      return res.status(404).json({ error: 'Acta FC-10 no encontrada' });
    }

    const data = typeof actual.rows[0].data === 'string' ? JSON.parse(actual.rows[0].data) : actual.rows[0].data;
    const ahora = new Date().toISOString();
    const usuario = registradoPor || (req.user && req.user.username) || 'admin';

    const actualizado = {
      ...data,
      estadoFirma,
      firmaEstadoManual: true,
      firmaEstadoActualizadoPor: usuario,
      firmaEstadoActualizadoEn: ahora
    };

    if (estadoFirma === 'CERRADO') {
      actualizado.fechaCierreFirmaManual = ahora;
    }

    const result = await pool.query('UPDATE fc10 SET data = $1 WHERE id = $2', [JSON.stringify(actualizado), req.params.id]);
    if (result.rowCount === 0) {
      return res.status(404).json({ error: 'Acta FC-10 no encontrada' });
    }

    io.emit('data_updated');
    res.json({ message: 'Estado de firma actualizado', id: req.params.id, estadoFirma });
  } catch (err) {
    enviarError(res, err);
  }
});

// ============================================================================
// RUTAS DE CONFIGURACIÓN GLOBAL (mantenimiento, etc.)
// ============================================================================

app.get('/api/app_config', exigirPrivilegio, async (_req, res) => {
  try {
    const result = await pool.query("SELECT * FROM app_config WHERE id = 'global'");
    if (result.rowCount === 0) {
      return res.json({ id: 'global', en_mantenimiento: false, mensaje: '', mejoras: [], ultima_version: '' });
    }
    res.json(result.rows[0]);
  } catch (err) {
    // Solo se tolera el error "la tabla no existe todavia" (42P01). Cualquier
    // otro fallo (permisos, red, BD caida) antes se disfrazaba de "sin
    // mantenimiento" y hacia creer que todo estaba bien.
    if (err && err.code === '42P01') {
      return res.json({ id: 'global', en_mantenimiento: false, mensaje: '', mejoras: [], ultima_version: '' });
    }
    return enviarError(res, err);
  }
});

app.patch('/api/app_config', exigirPrivilegio, async (req, res) => {
  try {
    const payload = { id: 'global', ...req.body };
    await pool.query(
      `INSERT INTO app_config (id, data) VALUES ($1, $2)
       ON CONFLICT (id) DO UPDATE SET data = EXCLUDED.data`,
      ['global', JSON.stringify(payload)]
    );
    io.emit('data_updated');
    res.json({ message: 'Configuración actualizada', config: payload });
  } catch (err) {
    enviarError(res, err);
  }
});

server.on('error', (err) => {
  if (err.code === 'EADDRINUSE') {
    console.error(`❌ El puerto ${PORT} está ocupado. Cierra los otros procesos node de tu sistema.`);
    // Sin salir, el proceso queda vivo SIN socket escuchando: parece sano y no lo esta.
    process.exit(1);
  }
  console.error('❌ Error del servidor HTTP:', err.message);
  process.exit(1);
});

// Solo escuchar si se ejecuta directamente (desarrollo local).
// En Vercel se usa el handler en api/index.js que importa esta app.
if (require.main === module) {
  server.listen(PORT, () => {
    console.log(`🚀 Servidor Backend corriendo en http://localhost:${PORT}`);
  });
}

module.exports = { app, io, pool };
