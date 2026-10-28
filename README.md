# Sistema de Gestion Patrimonial UNP

Aplicación web (SPA React + Vite) sobre **Supabase (PostgreSQL)**, con las
migraciones y los scripts de base de datos versionados en este repositorio.

La app habla **directo con Supabase** desde el navegador (PostgREST, RPC y
Realtime) con la `anon` key. **No hay servidor propio**: la seguridad la
resuelve el RLS de Postgres (ver "Notas de seguridad").

## Estructura

```
SistemaPatrimonial/
├── backend/              Toolkit de base de datos (repo raiz)
│   ├── migrations/       Migraciones SQL: esquema, RLS, RPC e índices
│   ├── scripts/          setup-db, crear cuenta de Auth, aviso de mantenimiento
│   ├── test/             Pruebas del RLS contra la base real
│   ├── migrar.js         Migración SQLite -> Supabase (herramienta de una vez)
│   ├── inspector.js      Inspección del SQLite local
│   ├── inspect_db.js     Listado rápido de tablas
│   └── .env.example      Plantilla de variables (copiar a .env)
├── frontend/             SPA React 19 + Vite (REPO SEPARADO, con remoto propio)
│   ├── src/views/        Vistas por modulo
│   ├── src/components/   Componentes de UI
│   ├── src/hooks/        Logica extraida de App.jsx
│   ├── src/services/     Sincronizacion, auditoria, cola offline
│   └── vercel.json       Rewrite SPA (debe vivir junto al package.json)
├── respaldo_esquema.sql  Notas del esquema y como regenerarlo
└── run_frontend.bat      Atajo para `npm run dev` del frontend
```

> **Nota:** hasta la versión 2.12.1 este repositorio tenía también una API REST
> en Express (`backend/server.js`) con WebSocket. Se retiró porque la app dejó
> de usarla en `b3e4b72`, cuando la autenticación pasó a Supabase Auth: su
> único mecanismo de emisión de tokens (`POST /api/login`) quedó retirado y
> no quedó forma de obtener un JWT para esa API. Todo lo que hacía falta
> (respaldo, restauración, firma de actas) ya lo hace el frontend contra
> Supabase.

## Dos repositorios, dos propositos

`frontend/` es un repositorio git **anidado** con su propio remoto en GitHub
(228+ commits). Su historial no debe mezclarse con el de la raiz, así que el
`.gitignore` de la raiz lo excluye. El repositorio raiz cubre unicamente
`backend/` y la documentacion.

Esto significa que los cambios en el frontend se versionan y despliegan por
separado del resto.

## Puesta en marcha

### Base de datos (este repositorio)

```bash
cd backend
cp .env.example .env      # en Windows: copy .env.example .env
```

Completar en `.env`:

| Variable | Descripcion |
|---|---|
| `DATABASE_URL` | Cadena de conexion de PostgreSQL (Supabase). Usar el POOLER, no el host directo |
| `AUTH_DOMINIO` | Sufijo del email de acceso (por defecto `unp.edu.py`) |

```bash
npm install
npm run db:setup          # aplica las migraciones pendientes
```

### Frontend

```bash
cd frontend
cp .env.example .env
```

Completar `VITE_SUPABASE_URL` y `VITE_SUPABASE_ANON_KEY`. Son claves publicas
(van embebidas en el bundle); la seguridad real depende de las políticas RLS de
Supabase.

```bash
npm install
npm run dev
```

Desde la raiz tambien funciona `run_frontend.bat` en Windows.

## Scripts utiles

### Frontend

| Comando | Que hace |
|---|---|
| `npm run lint` | oxlint sobre el frontend |
| `npm test` | Pruebas unitarias (node:test) |
| `npm run build` | Build de produccion en `frontend/dist` |

### Base de datos (backend/)

| Comando | Que hace |
|---|---|
| `npm test` | Pruebas del RLS contra la base real (11 tests) + versión + dependencias de los scripts |
| `npm run db:setup` | Aplica las migraciones 001→014 en orden. Es idempotente: se puede re-correr. Las ya aplicadas se anotan en `public.schema_migrations` |
| `npm run db:crear-cuenta <usuario>` | Crea la cuenta de Supabase Auth de un usuario que ya tiene perfil en `public.usuarios` e imprime una clave temporal |
| `npm run aviso:iniciar -- --mensaje "..." --mejoras "a;b"` | **Activa el modo mantenimiento** con la lista de mejoras en curso (ver "Procedimiento de aviso") |
| `npm run aviso:cerrar -- --mensaje "..." --mejoras "a;b" --version 2.13.0` | **Desactiva el mantenimiento** y publica el aviso de mejoras hechas + la versión nueva |
| `npm run seguridad:simular` | Simulador de ataques: prueba por dónde intentaría robar datos o entrar un atacante (ver abajo) |

```bash
cd backend
npm run db:setup
npm run db:crear-cuenta jsanchez
```

## Procedimiento de aviso (modo mantenimiento)

Toda vez que se toque la base de datos o el código, el sistema tiene que avisar
a los usuarios. El script `backend/scripts/aviso-mantenimiento.js` deja el
estado en `app_config` alineado con lo que la interfaz muestra:

**1. Al empezar el trabajo** (el muro se levanta, lo ve cualquiera sin sesión):

```bash
npm run aviso:iniciar -- --mensaje "El acceso está pausado mientras se corrigen las políticas de seguridad." \
  --mejoras "Cerrando la exposición del padrón de funcionarios;Restringiendo la escritura de catálogos"
```

**2. Al terminar** (se baja el muro y se publica el aviso de mejoras hechas):
el frontend detecta el cambio de `ultima_version` y abre solo, para todos los
usuarios, el modal "Novedades de la vX" (`App.jsx:161`).

```bash
npm run aviso:cerrar -- --mensaje "Las mejoras ya están aplicadas." \
  --mejoras "El padrón de funcionarios quedó acotado por dependencia;La escritura de catálogos quedó restringida a administradores" \
  --version 2.13.0
```

Los campos que se tocan en `app_config`:

| Campo | Que muestra |
|---|---|
| `en_mantenimiento` | El muro (`MaintenanceScreen`), sin sesión |
| `mensaje` | El texto del muro |
| `mejoras` | La lista de **mejoras en curso** (se ve en el muro) |
| `ultima_version` | La versión; al cambiarla se abre el changelog |
| `notas_version` | El **aviso de mejoras hechas** de esa versión (el changelog) |

## Esquema de base de datos

El esquema real vive en Supabase, no en este repositorio, pero las
migraciones si están versionadas en `backend/migrations/` y son la fuente de
verdad de como se arma:

| Migracion | Que hace |
|---|---|
| `001_esquema_inicial.sql` | Tablas, indices y deltas de columnas |
| `002_seguridad_rls.sql` | Cierra el acceso anonimo a `funcionarios` y a la RPC `verificar_login` |
| `003_rls_por_dependencia.sql` | Un funcionario solo ve los bienes, actas y auditoria de SU dependencia |
| `004_rls_bens_publico.sql` | Cierra el acceso anonimo a la tabla `bens` (la vista publica del QR sigue por la RPC `obtener_bien_publico`) |
| `005_rls_cierre_total.sql` | Cierra `usuarios.password`, la auditoria y las notificaciones para los autenticados |
| `006_rpc_resumen_dependencias.sql` | RPC con los conteos por dependencia (evita traer 13.000 filas al navegador) |
| `007_rpc_guardar_usuario.sql` | RPC de alta y edicion de usuarios (la tabla tiene SELECT por columna) |
| `008_rls_usuarios_escritura.sql` | La escritura de `usuarios` solo para administradores (evita la escalada de privilegios) |
| `009_rls_funcionarios_dependencia.sql` | Cierra el padrón de funcionarios por dependencia (cédulas) y acota la lectura de `usuarios` |
| `010_rls_catalogos_privilegiados.sql` | La escritura de `dependencias`, `ubicaciones`, `estructuras` y `app_config` solo para privilegiados |
| `011_rpc_permisos_anon.sql` | Quita el `EXECUTE` sobre `anon` de las funciones `SECURITY DEFINER` (la del QR público queda) |
| `012_enlaces_inventario_lectura.sql` | Crea enlaces temporales de solo lectura con una proyección mínima de bienes compartidos |
| `013_uso_recursos_admin.sql` | Expone al administrador el tamaño real de la base y Storage para el panel de salud |
| `014_cierre_fc11_con_registro_firmas.sql` | Registra la firma externa del receptor y la referencia de archivo; actualiza FC-10 e inventario en una transacción |

`respaldo_esquema.sql` esta vacio a proposito y documenta como regenerarlo con
`pg_dump`. Las tablas son `bens`, `fc10`, `fc11`, `fc04`, `estructuras`,
`usuarios`, `auditoria`, `notificaciones`, `funcionarios`, `dependencias`,
`ubicaciones` y `app_config`; salvo `usuarios`, `funcionarios`, `dependencias`
y `ubicaciones`, cada una guarda el registro completo dentro de una columna
JSONB `data`.

## Notas de seguridad

- `.env`, `*.sqlite`, `node_modules` y `dist` están ignorados por git. Nunca
  commitear credenciales.
- `backend/patrimonio.sqlite` es un residuo de la migración SQLite -> Supabase y
  puede contener datos reales de bienes: esta en el `.gitignore` por eso.
- **El RLS es la frontera de seguridad**, no la interfaz: el frontend manda
  la `anon` key en el bundle, así que cualquiera puede pedirle a Supabase
  cualquier dato. Lo que decide qué se ve es cada política de Postgres. Por
  eso `backend/test/rls_acotado.test.js` prueba el comportamiento con los
  roles reales (`anon`, `funcionario`, `administrador`) contra la base de
  verdad: `npm test` en `backend/`.
- Al publicar cambios de migraciones, hay que **desactivar el proyecto de
  Vercel del backend** (ya no hay nada que desplegar ahí) y aplicar
  `npm run db:setup`.
- La **Content-Security-Policy** va en modo **estricto** (`Content-Security-Policy`,
  no `Report-Only`): el navegador **bloquea** lo que no esté permitido. Vive en
  `frontend/vercel.json` y se aplicó primero en modo aviso para no romper nada.
  Para cambiarla hay que probarla contra el build real (ver "Probar la CSP
  antes de publicarla").
- `npm run db:crear-cuenta` necesita `bcryptjs`: sin esa dependencia el script
  no arranca. `backend/test/dependencias.test.js` comprueba que todo lo que los
  scripts del toolkit requieren esté declarado en el `package.json`.

### Probar la CSP antes de publicarla

La CSP bloquea de verdad: si algo que la app necesita no está permitido, la
aplicación se rompe en el navegador del usuario, no en el servidor. Antes de
cambiarla, se prueba contra el build real:

```bash
cd frontend
npm run build
node ../ruta/al/servidor-de-prueba.js dist 4175 "default-src 'self'; ..."
```

El servidor de prueba tiene que servir `dist/` y mandar la cabecera
`Content-Security-Policy` con la política nueva. Con la app abierta en
`http://localhost:4175` hay que comprobar en la consola que **no** hay
violaciones, y que funcionan las cuatro operaciones que dependen de la CSP:

| Que probar | Por que |
|---|---|
| La app carga y se ve el login | Que el bundle y las hojas de estilo cargan |
| Generar un PDF (con imagen y tabla) | `jsPDF` + `autotable` vienen del CDN y agregan imagenes |
| Exportar a Excel | `XLSX` viene del CDN |
| Generar el ZIP de respaldo | `JSZip` viene del CDN |
| Descargar un archivo | Las descargas se hacen con `blob:` (`URL.createObjectURL`) |
| Abrir el escaner de QR | Usa la camara: `media-src` tiene que permitir `mediastream:` |

### Simulador de ataques

`npm run seguridad:simular` (en `backend/`) hace las preguntas que haría un
atacante contra esta arquitectura, que es "la `anon` key va en el bundle y el
RLS decide":

| Grupo | Que intenta |
|---|---|
| Robo de datos | Leer cada tabla sensible sin iniciar sesión |
| Escritura | Crear un bien, crear un administrador, activar el modo mantenimiento |
| IDOR | Cambiar el filtro por dependencia a mano y usar `.or()` para evadirlo |
| RPC | Ejecutar cada función `SECURITY DEFINER` sin sesión |
| Fuerza bruta | Probar contraseñas genéricas contra el login y enumerar cuentas |
| Storage | Listar el bucket de fotos de los bienes |
| Cabeceras | Ver si falta CSP, HSTS o protección contra framing |
| Bundle | Buscar `service_role` u otras credenciales en el código publicado |
| API retirada | Ver si la API Express vieja sigue respondiendo |

**Garantías**: solo lee; lo que escribe lo borra en el acto; nunca usa la
contraseña real de nadie; y al terminar **verifica que los conteos de todas
las tablas sigan siendo los mismos** (si algo queda, lo dice).

Sale con código 1 si encuentra algo expuesto, para poder usarlo en un
pipeline.
