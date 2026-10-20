/**
 * backend/scripts/crear-cuenta-auth.js
 * ============================================================================
 * Crea la cuenta de Supabase Auth de un usuario que ya tiene perfil en
 * public.usuarios pero que nunca recibio cuenta (por ejemplo, un usuario del
 * esquema anterior a Supabase Auth).
 *
 *   node scripts/crear-cuenta-auth.js <usuario> [clave]
 *
 *   <usuario>  el username de public.usuarios (jsanchez, no el email)
 *   [clave]    clave temporal; si se omite, se genera una
 *
 * Imprime la clave temporal: hay que comunicarsela al usuario para que entre
 * y la cambie. La clave NUNCA se guarda en el perfil: la autenticacion vive
 * en Supabase Auth, no en la tabla public.usuarios.
 *
 * El hash se calcula con bcryptjs y no con pgcrypto a proposito: en SQL,
 * crypt($3, gen_salt(...)) es ambiguo (gen_salt tiene dos sobrecargas) y deja
 * el tipo del parametro sin determinar.
 * ============================================================================
 */
require('dotenv').config({ path: require('path').join(__dirname, '..', '.env') });
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const bcrypt = require('bcryptjs');
const { Pool } = require('pg');

const USUARIO = process.argv[2];
const CLAVE = process.argv[3] || ('Tmp-' + crypto.randomBytes(9).toString('base64url') + '-UNP');
const DOMINIO = process.env.AUTH_DOMINIO || 'unp.edu.py';

if (!USUARIO) {
  console.log('uso: node scripts/crear-cuenta-auth.js <usuario> [clave temporal]');
  process.exit(1);
}
if (!process.env.DATABASE_URL) {
  console.error('❌ Falta DATABASE_URL (revisá backend/.env)');
  process.exit(1);
}

const url = new URL(process.env.DATABASE_URL);
const cs = 'postgresql://' + url.username + ':' + encodeURIComponent(decodeURIComponent(url.password))
  + '@' + url.hostname + ':' + (url.port || 5432) + (url.pathname || '/postgres');
const pool = new Pool({ connectionString: cs, ssl: { rejectUnauthorized: false }, connectionTimeoutMillis: 20000 });

(async () => {
  const email = USUARIO.includes('@') ? USUARIO : USUARIO + '@' + DOMINIO;
  const client = await pool.connect();
  try {
    // 1) El perfil tiene que existir: sin el, el login no serviria de nada.
    const perfil = await client.query('SELECT username, nombre, cargo FROM usuarios WHERE lower(username) = lower($1)', [USUARIO]);
    if (!perfil.rows.length) {
      console.error('❌ No hay perfil en public.usuarios para "' + USUARIO + '". Creá el perfil primero.');
      process.exitCode = 1;
      return;
    }

    // 2) Si ya tiene cuenta, no se toca.
    const ya = await client.query('SELECT id FROM auth.users WHERE email = $1', [email]);
    if (ya.rows.length) {
      console.log('ℹ️  La cuenta ya existe (' + email + '). No se modifica.');
      return;
    }

    const uid = crypto.randomUUID();
    const iid = crypto.randomUUID();
    const ahora = new Date().toISOString();
    const hash = bcrypt.hashSync(CLAVE, 10);

    const sql = fs.readFileSync(path.join(__dirname, '..', 'migrations', 'crear_cuenta_auth.sql'), 'utf8');
    const sentencias = sql.split('-- @@SPLIT@@').map(s => s.trim()).filter(Boolean);
    const params = [
      [uid, email, hash, ahora],
      [uid, email, ahora, iid]
    ];

    await client.query('BEGIN');
    for (let i = 0; i < sentencias.length; i++) {
      await client.query(sentencias[i], params[i] || params[params.length - 1]);
    }
    await client.query('COMMIT');

    console.log('✅ Cuenta creada');
    console.log('   usuario         : ' + email);
    console.log('   clave temporal  : ' + CLAVE);
    console.log('   (comunicásela para que la cambie al entrar)');
  } catch (e) {
    await client.query('ROLLBACK').catch(() => {});
    console.error('❌ ' + e.message);
    process.exitCode = 1;
  } finally {
    client.release();
    await pool.end();
  }
})();
