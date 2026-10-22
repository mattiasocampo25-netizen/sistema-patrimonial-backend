/**
 * backend/scripts/simulador-ataque.js
 * ============================================================================
 * Simulador de ataques contra el SIGEP UNP. Pensado para responder una
 * pregunta concreta: "si alguien quisiera robar datos o entrar sin permiso,
 * ¿por dónde lo haría y qué se lo impide?".
 *
 * GARANTÍAS (esto es lo importante)
 * ---------------------------------
 * 1. NO SE TOCAN LOS DATOS REALES. Todo lo que el simulador escriba (y solo
 *    escribe en las pruebas marcadas como "escritura") se borra al final y se
 *    verifica con un conteo antes/después. Si algo queda, el script lo dice.
 * 2. NO SE TOCAN LAS CUENTAS DE LOS USUARIOS. La fuerza bruta se hace con
 *    contraseñas genéricas contra UNA cuenta. Nunca con la contraseña real de
 *    nadie, y nunca se cambia una contraseña ni se borra una cuenta de Auth.
 * 3. NO SE CAMBIA NADA DE LA CONFIGURACIÓN de Supabase ni de Vercel.
 *
 * El simulador NO explota vulnerabilidades por su cuenta: comprueba las que
 * un atacante intentaría de verdad contra esta arquitectura, que es "la anon
 * key va en el bundle y el RLS decide".
 *
 * USO
 * ---
 *   npm run seguridad:simular              # todas las pruebas
 *   npm run seguridad:simular -- --json    # salida en JSON
 *   npm run seguridad:simular -- --solo=rls,auth
 * ============================================================================
 */
require('dotenv').config({ path: require('path').join(__dirname, '..', '..', 'frontend', '.env') });
const fs = require('fs');
const path = require('path');

const RAIZ = path.join(__dirname, '..');
const FRONTEND = path.join(RAIZ, '..', 'frontend');

// La conexión a la base solo se usa para CONTAR filas (verificar que el
// simulador no dejó nada atrás). Se lee únicamente el `DATABASE_URL` del
// .env del backend: el resto de sus variables (SECRET_KEY, etc.) no se
// cargan en este proceso.
try {
  const env = fs.readFileSync(path.join(RAIZ, '.env'), 'utf8');
  const m = env.match(/^\s*DATABASE_URL\s*=\s*(.+)\s*$/m);
  if (m && !process.env.DATABASE_URL) process.env.DATABASE_URL = m[1].replace(/^["']|["']$/g, '');
} catch (e) { /* sin .env: la verificacion de integridad se omite */ }

const SUPABASE_URL = (process.env.VITE_SUPABASE_URL || '').replace(/\/$/, '');
const ANON_KEY = (process.env.VITE_SUPABASE_ANON_KEY || '').trim();

const argv = process.argv.slice(2);
const solo = (argv.find(a => a.startsWith('--solo=')) || '').split('=')[1];
const comoJson = argv.includes('--json');

// --- Presentación -------------------------------------------------------------
const C = {
  ok: '\x1b[32m', mal: '\x1b[31m', aviso: '\x1b[33m', info: '\x1b[36m',
  gris: '\x1b[90m', fin: '\x1b[0m', neg: '\x1b[1m'
};
const verde = (s) => C.ok + s + C.fin;
const rojo = (s) => C.mal + s + C.fin;
const amarillo = (s) => C.aviso + s + C.fin;
const gris = (s) => C.gris + s + C.fin;

const resultados = [];

/** Registra el resultado de una prueba. */
function registrar({ id, grupo, nombre, objetivo, veredicto, detalle, evidencia }) {
  const v = veredicto === 'BLOQUEADO' ? 'BLOQUEADO'
    : veredicto === 'EXPUESTO' ? 'EXPUESTO'
    : veredicto === 'PARCIAL' ? 'PARCIAL' : 'INFO';
  resultados.push({ id, grupo, nombre, objetivo, veredicto: v, detalle, evidencia });
  if (comoJson) return;
  const etiqueta = v === 'BLOQUEADO' ? verde('BLOQUEADO') : v === 'EXPUESTO' ? rojo('EXPUESTO') : v === 'PARCIAL' ? amarillo('PARCIAL') : gris('INFO    ');
  console.log('  ' + etiqueta + '  ' + C.neg + nombre + C.fin);
  if (detalle) console.log('        ' + gris(detalle));
  if (evidencia) console.log('        ' + gris('→ ' + evidencia));
}

const grupos = new Map();
async function enGrupo(id, titulo, fn) {
  if (solo && !solo.split(',').map(s => s.trim()).includes(id)) return;
  grupos.set(id, titulo);
  if (!comoJson) console.log('\n' + C.neg + titulo + C.fin);
  await fn();
}
// --- Utilidades de red --------------------------------------------------------
const H = (extra = {}) => ({
  apikey: ANON_KEY,
  Authorization: 'Bearer ' + ANON_KEY,
  'Content-Type': 'application/json',
  ...extra
});

async function rest(ruta, { metodo = 'GET', cuerpo, cabeceras, anon = true } = {}) {
  const url = SUPABASE_URL + '/rest/v1/' + ruta;
  const r = await fetch(url, {
    method: metodo,
    headers: anon ? H(cabeceras) : (cabeceras || {}),
    body: cuerpo ? JSON.stringify(cuerpo) : undefined
  });
  const texto = await r.text();
  let datos = null;
  try { datos = JSON.parse(texto); } catch (e) { datos = texto; }
  return { status: r.status, datos, texto, rango: r.headers.get('content-range') };
}

async function rpc(nombre, args = {}, { metodo = 'POST', anon = true } = {}) {
  const r = await fetch(SUPABASE_URL + '/rest/v1/rpc/' + nombre, {
    method: metodo,
    headers: anon ? H() : { 'Content-Type': 'application/json' },
    body: metodo === 'POST' ? JSON.stringify(args) : undefined
  });
  const texto = await r.text();
  let datos = null;
  try { datos = JSON.parse(texto); } catch (e) { datos = texto; }
  return { status: r.status, datos, texto };
}

// Cuenta filas de una respuesta de PostgREST. Un objeto de error (cuando
// la peticion es rechazada) NO cuenta como fila: si no, un HTTP 401 con
// cuerpo de error se leeria como "1 fila filtrada".
const filas = (d) => {
  if (Array.isArray(d)) return d.length;
  if (d && typeof d === 'object' && (d.code || d.message || d.error)) return 0;
  if (d && typeof d === 'object') return 1;
  return 0;
};

// --- Pruebas ------------------------------------------------------------------

/**
 * 1) ROBO DE DATOS CON LA ANON KEY.
 *    Es el vector real: la anon key va en el bundle, cualquiera la tiene.
 *    Se intenta leer cada tabla sensible sin sesión.
 */
async function pruebaRoboDeDatos() {
  const objetivo = 'Leer datos del inventario, el padrón o la auditoría sin iniciar sesión';
  const sensitive = [
    ['bens', 'inventario (valor, responsable, fotos)'],
    ['funcionarios', 'padrón con cédulas'],
    ['usuarios', 'perfiles y roles'],
    ['auditoria', 'traza de auditoría'],
    ['notificaciones', 'solicitudes de baja'],
    ['fc10', 'actas de responsabilidad'],
    ['fc11', 'traslados'],
    ['fc04', 'expedientes'],
    ['ubicaciones', 'catálogo de ubicaciones'],
    ['dependencias', 'catálogo de dependencias'],
    ['estructuras', 'organigrama']
  ];
  let filtradas = 0;
  for (const [tabla, que] of sensitive) {
    const r = await rest(tabla + '?select=*');
    if (r.status === 200 && filas(r.datos) > 0) {
      filtradas++;
      registrar({
        id: 'robo', grupo: 'robo', nombre: 'lectura sin sesión: ' + tabla,
        objetivo, veredicto: 'EXPUESTO',
        detalle: 'La tabla ' + que + ' devolvió filas sin sesión.',
        evidencia: filas(r.datos) + ' fila(s)'
      });
    } else {
      registrar({
        id: 'robo', grupo: 'robo', nombre: 'lectura sin sesión: ' + tabla,
        objetivo, veredicto: 'BLOQUEADO',
        detalle: 'RLS responde ' + (r.status === 200 ? '0 filas' : 'HTTP ' + r.status),
        evidencia: String(r.texto).slice(0, 70)
      });
    }
  }
  if (!filtradas) {
    registrar({
      id: 'robo', grupo: 'robo', nombre: 'resumen del robo de datos',
      objetivo, veredicto: 'BLOQUEADO',
      detalle: 'Ninguna tabla sensible devolvió datos sin sesión.'
    });
  }
}

/**
 * 2) IDOR: cambiar el filtro de dependencia a mano.
 *    El frontend filtra por `data->>dependencia`; un atacante puede cambiarlo.
 *    Si el RLS no estuviera puesto, saldrían los bienes de otra dependencia.
 */
async function pruebaIdor() {
  const objetivo = 'Leer los bienes de una dependencia que no es la propia';
  const DEP = 'Facultad de Ciencias Contables, Administrativas y Económicas';

  const r = await rest("bens?select=id,data&data->>dependencia=eq." + encodeURIComponent(DEP));
  registrar({
    id: 'idor', grupo: 'idor', nombre: 'filtro de dependencia cambiado a mano',
    objetivo,
    veredicto: (r.status === 200 && filas(r.datos) > 0) ? 'EXPUESTO' : 'BLOQUEADO',
    detalle: (r.status === 200 && filas(r.datos) > 0)
      ? 'Se devolvieron bienes de otra dependencia sin sesión.'
      : 'El RLS ignora el filtro del cliente.',
    evidencia: 'HTTP ' + r.status + ', ' + filas(r.datos) + ' fila(s)'
  });

  // Truco clásico de PostgREST: usar .or() para saltarse el filtro.
  const r2 = await rest("bens?select=id&or=(data->>dependencia.eq." + encodeURIComponent(DEP) + ",id.not.is.null)");
  registrar({
    id: 'idor', grupo: 'idor', nombre: 'filtro con .or() para evadir la dependencia',
    objetivo,
    veredicto: (r2.status === 200 && filas(r2.datos) > 0) ? 'EXPUESTO' : 'BLOQUEADO',
    detalle: 'Se intentó ampliar el alcance con un .or() sobre la columna JSONB.',
    evidencia: 'HTTP ' + r2.status + ', ' + filas(r2.datos) + ' fila(s)'
  });

  // Y con la cabecera Prefer: count=exact para saber cuántos hay sin leerlos.
  // PostgREST devuelve el total en la cabecera content-range.
  const r3 = await rest('bens?select=id', { cabeceras: { Prefer: 'count=exact' } });
  const rango = r3.rango || '';
  const total = /\/(\d+)$/.exec(rango) ? Number(/\/(\d+)$/.exec(rango)[1]) : 0;
  registrar({
    id: 'idor', grupo: 'idor', nombre: 'conteo de filas sin sesión (Prefer: count=exact)',
    objetivo: 'Saber cuántos bienes hay sin leerlos',
    veredicto: total > 0 ? 'PARCIAL' : 'BLOQUEADO',
    detalle: total > 0
      ? 'El conteo total se revela, pero no las filas. Es una fuga de metadatos, no de datos.'
      : 'Ni el conteo se revela.',
    evidencia: 'HTTP ' + r3.status + (rango ? ' | content-range: ' + rango : ' | sin content-range')
  });
}

/**
 * 1b) ESCRITURA sin sesión.
 *     Es el vector más grave: si el RLS estuviera mal, cualquiera podría
 *     escribir en el inventario o crear un administrador. Se intenta y, si
 *     llegara a escribir, se borra en el acto y se reporta (además, la
 *     verificación de integridad final compara los conteos).
 */
async function pruebaEscritura() {
  const objetivo = 'Escribir en la base sin iniciar sesión';
  const sell = Date.now();
  const cab = { Prefer: 'return=representation' };
  const afectadas = (r) => (Array.isArray(r.datos) ? r.datos.length : filas(r.datos));

  // a) Crear un bien
  const idBien = 'probe_seguridad_' + sell;
  const r1 = await rest('bens', {
    metodo: 'POST',
    cabeceras: cab,
    cuerpo: { id: idBien, data: { rotulo: 'PROBE-' + sell, dependencia: 'Rectorado', descripcion: 'prueba del simulador' } }
  });
  const escribioBien = afectadas(r1) > 0;
  if (escribioBien) {
    await rest('bens?id=eq.' + idBien, { metodo: 'DELETE' });
  }
  registrar({
    id: 'escritura', grupo: 'escritura', nombre: 'crear un bien sin sesión',
    objetivo,
    veredicto: escribioBien ? 'EXPUESTO' : 'BLOQUEADO',
    detalle: escribioBien
      ? '¡Se pudo insertar un bien sin sesión! Se borró en el acto, pero el RLS está roto.'
      : 'El RLS rechaza la inserción sin sesión.',
    evidencia: 'HTTP ' + r1.status + ' ' + String(r1.texto).slice(0, 70)
  });

  // b) Crear un usuario con cargo admin (el vector más peligroso)
  const r2 = await rest('usuarios', {
    metodo: 'POST',
    cabeceras: cab,
    cuerpo: { username: 'probe_seguridad_' + sell, nombre: 'PROBE', cargo: 'admin', dependencia: 'Rectorado' }
  });
  const escribioUsuario = afectadas(r2) > 0;
  if (escribioUsuario) {
    await rest('usuarios?username=eq.probe_seguridad_' + sell, { metodo: 'DELETE' });
  }
  registrar({
    id: 'escritura', grupo: 'escritura', nombre: 'crear un usuario con cargo admin sin sesión',
    objetivo,
    veredicto: escribioUsuario ? 'EXPUESTO' : 'BLOQUEADO',
    detalle: escribioUsuario
      ? '¡Se pudo crear un administrador sin sesión! Se borró en el acto.'
      : 'El RLS rechaza la alta de usuarios sin sesión.',
    evidencia: 'HTTP ' + r2.status + ' ' + String(r2.texto).slice(0, 70)
  });

  // c) Mover el muro de mantenimiento (afecta a todos los usuarios)
  const r3 = await rest('app_config?id=eq.global', {
    metodo: 'PATCH',
    cabeceras: cab,
    cuerpo: { en_mantenimiento: true }
  });
  const estadoDespues = await rest('app_config?id=eq.global&select=en_mantenimiento');
  const muroReal = Array.isArray(estadoDespues.datos) && estadoDespues.datos[0]
    ? estadoDespues.datos[0].en_mantenimiento
    : null;
  const tocoMuro = muroReal === true;
  if (tocoMuro) {
    await rest('app_config?id=eq.global', { metodo: 'PATCH', cabeceras: cab, cuerpo: { en_mantenimiento: false } });
  }
  registrar({
    id: 'escritura', grupo: 'escritura', nombre: 'activar el modo mantenimiento sin sesión',
    objetivo,
    veredicto: tocoMuro ? 'EXPUESTO' : 'BLOQUEADO',
    detalle: tocoMuro
      ? '¡Se pudo tocar el muro de mantenimiento sin sesión! Se restauró en el acto.'
      : 'El RLS rechaza la escritura en app_config sin sesión.',
    evidencia: 'HTTP ' + r3.status + ' ' + String(r3.texto).slice(0, 70)
  });
}

/**
 * 3) RPC: enumerar y llamar a las funciones de la base.
 *    Las funciones son SECURITY DEFINER: si `anon` puede llamarlas, se salta el RLS.
 */
async function pruebaRpc() {
  const objetivo = 'Ejecutar funciones de la base sin sesión (saltarse el RLS)';
  const peligrosas = ['admin_guardar_usuario', 'resumen_por_dependencia', 'cargo_actual', 'dependencia_actual', 'es_privilegiado_actual', 'usuario_actual', 'verificar_login'];

  for (const fn of peligrosas) {
    const r = await rpc(fn, fn === 'admin_guardar_usuario'
      ? { p_username: 'probe', p_nombre: 'probe', p_cargo: 'admin', p_dependencia: 'Rectorado' }
      : {});
    const permitido = r.status === 200;
    registrar({
      id: 'rpc', grupo: 'rpc', nombre: 'RPC sin sesión: ' + fn,
      objetivo,
      veredicto: permitido ? 'EXPUESTO' : 'BLOQUEADO',
      detalle: permitido
        ? 'La función responde sin sesión.'
        : 'La función está revocada para el rol anon.',
      evidencia: 'HTTP ' + r.status + ' ' + String(r.texto).slice(0, 60)
    });
  }

  // La RPC pública del QR: tiene que funcionar, pero devolver solo campos públicos.
  const r = await rpc('obtener_bien_publico', { p_id: '__inexistente__' });
  registrar({
    id: 'rpc', grupo: 'rpc', nombre: 'RPC pública del QR (obtener_bien_publico)',
    objetivo: 'La vista pública del QR debe funcionar para visitantes sin sesión',
    veredicto: r.status === 200 ? 'INFO' : 'EXPUESTO',
    detalle: 'Es la única RPC que debe estar abierta: atiende el QR público.',
    evidencia: 'HTTP ' + r.status
  });
}

/**
 * 4) FUERZA BRUTA contra el login real (Supabase Auth).
 *    Se usa un conjunto de contraseñas genéricas contra UNA cuenta y se mide
 *    cuándo kicks el rate limit. Nunca con la contraseña real de nadie.
 */
async function pruebaFuerzaBruta() {
  const objetivo = 'Adivinar una contraseña de acceso al sistema';
  const usuario = process.env.SIM_USER || 'biomedicas';
  const contrasenas = ['password', 'password123', '123456', 'admin', 'admin123', 'unp2024', '12345678', 'qwerty'];
  const url = SUPABASE_URL + '/auth/v1/token?grant_type=password';
  let exitos = 0;
  let limiteEn = null;
  let ultimoStatus = null;

  for (const clave of contrasenas) {
    const r = await fetch(url, {
      method: 'POST',
      headers: H(),
      body: JSON.stringify({ email: usuario + '@unp.edu.py', password: clave })
    });
    ultimoStatus = r.status;
    if (r.status === 200) exitos++;
    if (r.status === 429 && limiteEn === null) limiteEn = contrasenas.indexOf(clave) + 1;
    if (r.status === 429) break;
    await new Promise(res => setTimeout(res, 350));
  }

  registrar({
    id: 'fuerza', grupo: 'fuerza', nombre: 'fuerza bruta contra el login (' + contrasenas.length + ' contraseñas genéricas)',
    objetivo,
    veredicto: exitos > 0 ? 'EXPUESTO' : (limiteEn ? 'BLOQUEADO' : 'BLOQUEADO'),
    detalle: exitos > 0
      ? '¡ALGUNA CONTRASEÑA FUNCIONÓ! Revisar de inmediato.'
      : (limiteEn
        ? 'El rate limit de Supabase corta el ataque en el intento ' + limiteEn + '.'
        : 'Ninguna de las contraseñas genéricas funcionó y no hubo bloqueo (Supabase no limitó los ' + contrasenas.length + ' intentos).'),
    evidencia: 'último HTTP ' + ultimoStatus + ', ' + exitos + ' éxito(es)'
  });

  // Enumeración de usuarios: ¿la respuesta distingue email existente de inexistente?
  const conEmail = await fetch(url, {
    method: 'POST', headers: H(),
    body: JSON.stringify({ email: usuario + '@unp.edu.py', password: 'x' })
  });
  const c1 = await conEmail.text();
  const sinEmail = await fetch(url, {
    method: 'POST', headers: H(),
    body: JSON.stringify({ email: 'noexiste-este-usuario@unp.edu.py', password: 'x' })
  });
  const c2 = await sinEmail.text();
  registrar({
    id: 'fuerza', grupo: 'fuerza', nombre: 'enumeración de cuentas existentes',
    objetivo: 'Descubrir qué correos tienen cuenta',
    veredicto: c1 === c2 ? 'BLOQUEADO' : 'PARCIAL',
    detalle: c1 === c2
      ? 'La respuesta es idéntica para un correo existente y uno inexistente: no se pueden enumerar cuentas.'
      : 'Las respuestas difieren: se pueden enumerar las cuentas existentes.',
    evidencia: JSON.stringify({ con_cuenta: c1.slice(0, 60), sin_cuenta: c2.slice(0, 60) })
  });

  // ¿El registro de usuarios está abierto al público?
  const s = await fetch(SUPABASE_URL + '/auth/v1/settings', { headers: { apikey: ANON_KEY } });
  let signup = 'desconocido';
  try {
    const j = JSON.parse(await s.text());
    signup = j.disable_signup === true ? 'deshabilitado' : (j.mailer_autoconfirm ? 'habilitado con confirmación automática' : 'habilitado con confirmación por correo');
  } catch (e) { /* ignore */ }
  registrar({
    id: 'fuerza', grupo: 'fuerza', nombre: 'registro de cuentas abierto al público',
    objetivo: 'Que cualquiera pueda crear su propia cuenta y entrar',
    veredicto: signup === 'deshabilitado' ? 'BLOQUEADO' : 'PARCIAL',
    detalle: 'Estado del signup en Supabase Auth: ' + signup + '.',
    evidencia: '/auth/v1/settings'
  });
}

/**
 * 5) ROBO DE ARCHIVOS (Storage).
 *    Las fotos de los bienes están en un bucket. ¿Es público?
 */
async function pruebaStorage() {
  const objetivo = 'Descargar las fotos de los bienes sin iniciar sesión';
  for (const bucket of ['fotos-bienes']) {
    const r = await rest('/storage/v1/object/list/' + bucket, { metodo: 'POST', cuerpo: { prefix: '', limit: 50 } });
    const permitio = r.status === 200 && r.datos && r.datos.length > 0;
    registrar({
      id: 'storage', grupo: 'storage', nombre: 'listado de archivos del bucket "' + bucket + '"',
      objetivo,
      veredicto: permitio ? 'EXPUESTO' : 'BLOQUEADO',
      detalle: permitio
        ? 'Se pudo listar el contenido del bucket sin sesión.'
        : 'El bucket no se puede listar sin sesión.',
      evidencia: 'HTTP ' + r.status + ' ' + String(r.texto).slice(0, 60)
    });
  }
}

/**
 * 6) CABECERAS DE SEGURIDAD de la app publicada (lo que ve un atacante en el
 *    navegador: CSP, HSTS, protección contra framing).
 */
async function pruebaCabeceras() {
  const objetivo = 'Explotar el navegador de un usuario (XSS, clickjacking, MIME sniffing)';
  // Las URLs candidatas de la app publicada. La del repo puede no ser la de
  // produccion (Vercel genera un dominio por despliegue).
  const candidatas = (process.env.SIM_URL_APP ? [process.env.SIM_URL_APP] : [])
    .concat([
      'https://sistema-patrimonial-frontend.vercel.app',
      'https://sigep-inventario.vercel.app'
    ]);

  for (const urlApp of candidatas) {
    let r;
    try {
      r = await fetch(urlApp, { redirect: 'follow' });
    } catch (e) {
      registrar({
        id: 'cabeceras', grupo: 'cabeceras', nombre: 'cabeceras de seguridad: ' + urlApp,
        objetivo, veredicto: 'INFO', detalle: 'No se pudo alcanzar: ' + e.message
      });
      continue;
    }
    if (r.status === 404) {
      registrar({
        id: 'cabeceras', grupo: 'cabeceras', nombre: 'cabeceras de seguridad: ' + urlApp,
        objetivo, veredicto: 'INFO',
        detalle: 'Esa URL no existe (404). Se prueban las demás.'
      });
      continue;
    }
    const h = r.headers;
    const falta = [];
    if (!h.get('content-security-policy')) falta.push('Content-Security-Policy');
    if (!h.get('strict-transport-security')) falta.push('Strict-Transport-Security');
    if (!h.get('x-frame-options') && !(h.get('content-security-policy') || '').includes('frame-ancestors')) falta.push('X-Frame-Options');
    if (!h.get('x-content-type-options')) falta.push('X-Content-Type-Options');
    if (!h.get('referrer-policy')) falta.push('Referrer-Policy');
    registrar({
      id: 'cabeceras', grupo: 'cabeceras', nombre: 'cabeceras de seguridad: ' + urlApp,
      objetivo,
      veredicto: falta.length ? 'PARCIAL' : 'BLOQUEADO',
      detalle: falta.length
        ? 'Faltan: ' + falta.join(', ') + '. (El CSP acorta en particular el riesgo de XSS con los scripts de CDN.)'
        : 'Todas las cabeceras de refuerzo están.',
      evidencia: 'HTTP ' + r.status
    });
  }
}

/**
 * 7) BÚSQUEDA DE SECRETOS en el bundle de producción.
 *    El bundle es público por naturaleza: se revisa que no haya nada
 *    sensible (service_role, la URL de la base con contraseña, etc).
 */
async function pruebaSecretosEnBundle() {
  const objetivo = 'Encontrar una credencial de servicio en el código que se publica';
  const dir = path.join(FRONTEND, 'dist', 'assets');
  if (!fs.existsSync(dir)) {
    registrar({
      id: 'bundle', grupo: 'bundle', nombre: 'secretos en el bundle de producción',
      objetivo, veredicto: 'INFO',
      detalle: 'No hay build local (frontend/dist). Correr `npm run build` en frontend/.'
    });
    return;
  }
  const patrones = [
    ['service_role', /service_role/i],
    ['contraseña de la base de datos', /postgres(?:ql)?:\/\/[^\s'"]+:[^\s'"]+@/i],
    ['SUPABASE_SERVICE_ROLE_KEY', /SUPABASE_SERVICE_ROLE_KEY\s*[:=]/],
    ['SECRET_KEY', /SECRET_KEY\s*[:=]\s*['"][A-Za-z0-9]{16,}/]
  ];
  let encontrados = 0;
  for (const archivo of fs.readdirSync(dir).filter(f => /\.(js|css)$/.test(f))) {
    const texto = fs.readFileSync(path.join(dir, archivo), 'utf8');
    for (const [nombre, re] of patrones) {
      if (re.test(texto)) {
        encontrados++;
        registrar({
          id: 'bundle', grupo: 'bundle', nombre: 'patrón "' + nombre + '" en ' + archivo,
          objetivo, veredicto: 'EXPUESTO', detalle: 'Aparece en el bundle público.'
        });
      }
    }
  }
  if (!encontrados) {
    registrar({
      id: 'bundle', grupo: 'bundle', nombre: 'secretos en el bundle de producción',
      objetivo, veredicto: 'BLOQUEADO',
      detalle: 'El bundle publicado no contiene service_role, ni URLs con contraseña, ni SECRET_KEY.'
    });
  }
}

/**
 * 8) EL BACKEND EXPRESS RETIRADO: ¿sigue respondiendo en su URL?
 */
async function pruebaBackendRetirado() {
  const objetivo = 'Usar la API vieja, que conectaba con la base como superusuario';
  const url = process.env.SIM_URL_BACKEND;
  if (!url) {
    registrar({
      id: 'backend', grupo: 'backend', nombre: 'la API Express retirada',
      objetivo, veredicto: 'INFO',
      detalle: 'Sin SIM_URL_BACKEND no se prueba. Dejalo así si ya borraste el proyecto de Vercel.'
    });
    return;
  }
  try {
    const r = await fetch(url + '/api/health');
    registrar({
      id: 'backend', grupo: 'backend', nombre: 'la API Express retirada',
      objetivo,
      veredicto: r.status === 200 ? 'EXPUESTO' : 'BLOQUEADO',
      detalle: r.status === 200 ? 'La API vieja sigue respondiendo.' : 'La URL ya no responde.',
      evidencia: 'HTTP ' + r.status
    });
  } catch (e) {
    registrar({
      id: 'backend', grupo: 'backend', nombre: 'la API Express retirada',
      objetivo, veredicto: 'BLOQUEADO',
      detalle: 'La URL ya no resuelve: el proyecto se borró de Vercel.',
      evidencia: e.message.slice(0, 60)
    });
  }
}

// --- Integridad ---------------------------------------------------------------

/**
 * Verificación final: comprueba que el simulador no dejó nada atrás.
 * Compara los conteos de antes y después de cada tabla.
 */
async function verificarIntegridad(antes) {
  const { Pool } = require('pg');
  const url = process.env.DATABASE_URL;
  if (!url) return null;
  const pool = new Pool({ connectionString: url, ssl: { rejectUnauthorized: false }, connectionTimeoutMillis: 20000 });
  try {
    const despues = {};
    for (const t of Object.keys(antes)) {
      const r = await pool.query('SELECT count(*)::int n FROM public.' + t);
      despues[t] = r.rows[0].n;
    }
    const diferencias = Object.keys(antes).filter(t => antes[t] !== despues[t]);
    return { antes, despues, diferencias };
  } finally {
    await pool.end().catch(() => {});
  }
}

async function tomarFoto() {
  const { Pool } = require('pg');
  const url = process.env.DATABASE_URL;
  if (!url) return null;
  const pool = new Pool({ connectionString: url, ssl: { rejectUnauthorized: false }, connectionTimeoutMillis: 20000 });
  try {
    const foto = {};
    for (const t of ['bens', 'funcionarios', 'usuarios', 'auditoria', 'notificaciones', 'ubicaciones', 'dependencias', 'estructuras']) {
      const r = await pool.query('SELECT count(*)::int n FROM public.' + t);
      foto[t] = r.rows[0].n;
    }
    return foto;
  } finally {
    await pool.end().catch(() => {});
  }
}

// --- Ejecución ----------------------------------------------------------------

(async () => {
  if (!SUPABASE_URL || !ANON_KEY) {
    console.error('❌ Faltan VITE_SUPABASE_URL y VITE_SUPABASE_ANON_KEY.');
    console.error('   Se leen de frontend/.env. No se pone la service_role: el simulador');
    console.error('   tiene que atacar con lo mismo que tiene un visitante cualquiera.');
    process.exit(1);
  }

  console.log('\n' + C.neg + 'SIMULADOR DE ATAQUES — SIGEP UNP' + C.fin);
  console.log(gris('Objetivo: ' + SUPABASE_URL));
  console.log(gris('El simulador solo lee. Cualquier escritura se limpia al final y se verifica.'));

  const fotoAntes = await tomarFoto();

  await enGrupo('robo', '1. ROBO DE DATOS con la anon key (el vector real)', pruebaRoboDeDatos);
  await enGrupo('escritura', '1b. ESCRITURA sin sesión (crear, modificar, tocar el muro)', pruebaEscritura);
  await enGrupo('idor', '2. IDOR: saltarse el filtro por dependencia', pruebaIdor);
  await enGrupo('rpc', '3. RPC de la base sin sesión', pruebaRpc);
  await enGrupo('fuerza', '4. FUERZA BRUTA y enumeración de cuentas', pruebaFuerzaBruta);
  await enGrupo('storage', '5. ROBO de archivos (Storage)', pruebaStorage);
  await enGrupo('cabeceras', '6. CABECERAS de seguridad de la app publicada', pruebaCabeceras);
  await enGrupo('bundle', '7. SECRETOS en el bundle de producción', pruebaSecretosEnBundle);
  await enGrupo('backend', '8. La API Express retirada', pruebaBackendRetirado);

  const integridad = await verificarIntegridad(fotoAntes);

  // --- Informe ---
  const expuestos = resultados.filter(r => r.veredicto === 'EXPUESTO');
  const parciales = resultados.filter(r => r.veredicto === 'PARCIAL');

  if (comoJson) {
    console.log(JSON.stringify({ resultados, integridad }, null, 2));
  } else {
    console.log('\n' + C.neg + 'RESUMEN' + C.fin);
    console.log('  ' + resultados.length + ' pruebas · ' +
      verde(resultados.filter(r => r.veredicto === 'BLOQUEADO').length + ' bloqueadas') + ' · ' +
      (parciales.length ? amarillo(parciales.length + ' parciales') : '0 parciales') + ' · ' +
      (expuestos.length ? rojo(expuestos.length + ' EXPUESTAS') : '0 expuestas'));

    if (expuestos.length) {
      console.log('\n  ' + rojo('HALLAZGOS QUE REQUIEREN ACCIÓN:'));
      for (const e of expuestos) console.log('    - ' + e.nombre + ': ' + e.detalle);
    }
    if (parciales.length) {
      console.log('\n  ' + amarillo('PARCIALES (revisar):'));
      for (const p of parciales) console.log('    - ' + p.nombre + ': ' + p.detalle);
    }

    console.log('\n' + C.neg + 'INTEGRIDAD DE LOS DATOS' + C.fin);
    if (!integridad) {
      console.log(gris('  Sin DATABASE_URL: no se pudo verificar (los datos no se tocan sin sesión).'));
    } else if (integridad.diferencias.length) {
      console.log(rojo('  ¡DIFERENCIAS! ' + integridad.diferencias.join(', ')));
      console.log('  antes : ' + JSON.stringify(integridad.antes));
      console.log('  despues: ' + JSON.stringify(integridad.despues));
    } else {
      console.log(verde('  Sin cambios: ' + JSON.stringify(integridad.antes)));
    }
  }

  process.exit(expuestos.length ? 1 : 0);
})().catch(e => {
  console.error('\n❌ El simulador falló: ' + e.message);
  process.exit(2);
});
