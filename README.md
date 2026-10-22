# Sistema de Gestion Patrimonial UNP

Monorepo con dos piezas independientes: una **API REST** (Node.js/Express) y un
**frontend** (React + Vite), ambos sobre **Supabase (PostgreSQL)**.

## Estructura

```
SistemaPatrimonial/
├── backend/              API REST + WebSocket (repo raiz)
│   ├── server.js         Servidor Express, JWT, Socket.io
│   ├── migrar.js         Migracion SQLite -> Supabase
│   ├── inspector.js      Inspeccion del SQLite local
│   ├── inspect_db.js     Listado rapido de tablas
│   ├── install_deps.js   Instala dependencias del backend
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

## Dos repositorios, dos propositos

`frontend/` es un repositorio git **anidado** con su propio remoto en GitHub
(228+ commits). Su historial no debe mezclarse con el de la raiz, asi que el
`.gitignore` de la raiz lo excluye. El repositorio raiz cubre unicamente
`backend/` y la documentacion.

Esto significa que los cambios en el frontend se versionan y despliegan por
separado del resto.

## Puesta en marcha

### Backend

```bash
cd backend
cp .env.example .env      # en Windows: copy .env.example .env
```

Completar en `.env`:

| Variable | Descripcion |
|---|---|
| `DATABASE_URL` | Cadena de conexion de PostgreSQL (Supabase) |
| `SECRET_KEY` | Clave de firma de los JWT (generar con `node -e "console.log(require('crypto').randomBytes(48).toString('hex'))"`) |
| `ADMIN_INITIAL_PASSWORD` | Contrasena del usuario `admin` en el primer despliegue |
| `PORT` | Puerto del servidor (por defecto 3001) |

El servidor **sale con error claro si falta cualquiera de las tres primeras**:
no hay valores por defecto escritos en el codigo.

```bash
npm install
npm start        # o: npm run dev  (con nodemon)
```

### Frontend

```bash
cd frontend
cp .env.example .env
```

Completar `VITE_SUPABASE_URL` y `VITE_SUPABASE_ANON_KEY`. Son claves publicas
(van embebidas en el bundle); la seguridad real depende de las politicas RLS de
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

### Backend

| Comando | Que hace |
|---|---|
| `npm start` | Levanta la API (Express + Socket.io) |
| `npm test` | Pruebas unitarias **y de autorizacion** (24 tests) |
| `npm run db:setup` | Aplica las migraciones 001→011 en orden. Es idempotente: se puede re-correr. Las ya aplicadas se anotan en `public.schema_migrations` |
| `npm run db:crear-cuenta <usuario>` | Crea la cuenta de Supabase Auth de un usuario que ya tiene perfil en `public.usuarios` e imprime una clave temporal |
| `npm run aviso:iniciar -- --mensaje "..." --mejoras "a;b"` | **Activa el modo mantenimiento** con la lista de mejoras en curso (ver "Procedimiento de aviso") |
| `npm run aviso:cerrar -- --mensaje "..." --mejoras "a;b" --version 2.12.0` | **Desactiva el mantenimiento** y publica el aviso de mejoras hechas + la version nueva |

```bash
cd backend
npm run db:setup
npm run db:crear-cuenta jsanchez
```

## Procedimiento de aviso (modo mantenimiento)

Toda vez que se toque la base de datos o el codigo, el sistema tiene que avisar
a los usuarios. El script `backend/scripts/aviso-mantenimiento.js` deja el
estado en `app_config` alineado con lo que la interfaz muestra:

**1. Al empezar el trabajo** (el muro se levanta, lo ve cualquiera sin sesion):

```bash
npm run aviso:iniciar -- --mensaje "El acceso esta pausado mientras se corrigen las politicas de seguridad." \
  --mejoras "Cerrando la exposicion del padron de funcionarios;Restringiendo la escritura de catalogos"
```

**2. Al terminar** (se baja el muro y se publica el aviso de mejoras hechas):
el frontend detecta el cambio de `ultima_version` y abre solo, para todos los
usuarios, el modal "Novedades de la vX" (`App.jsx:161`).

```bash
npm run aviso:cerrar -- --mensaje "Las mejoras ya estan aplicadas." \
  --mejoras "El padron de funcionarios quedo acotado por dependencia;La escritura de catalogos quedo restringida a administradores" \
  --version 2.12.0
```

Los campos que se tocan en `app_config`:

| Campo | Que muestra |
|---|---|
| `en_mantenimiento` | El muro (`MaintenanceScreen`), sin sesion |
| `mensaje` | El texto del muro |
| `mejoras` | La lista de **mejoras en curso** (se ve en el muro) |
| `ultima_version` | La version; al cambiarla se abre el changelog |
| `notas_version` | El **aviso de mejoras hechas** de esa version (el changelog) |

## Esquema de base de datos

El esquema real vive en Supabase, no en este repositorio, pero las
migraciones si estan versionadas en `backend/migrations/` y son la fuente de
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
| `009_rls_funcionarios_dependencia.sql` | Cierra el padron de funcionarios por dependencia (cedulas) y acota la lectura de `usuarios` |
| `010_rls_catalogos_privilegiados.sql` | La escritura de `dependencias`, `ubicaciones`, `estructuras` y `app_config` solo para privilegiados |
| `011_rpc_permisos_anon.sql` | Quita el `EXECUTE` sobre `anon` de las funciones `SECURITY DEFINER` (la del QR publico queda) |

`respaldo_esquema.sql` esta vacio a proposito y documenta como regenerarlo con
`pg_dump`. Las tablas son `bens`, `fc10`, `fc11`, `fc04`, `estructuras`,
`usuarios`, `auditoria`, `notificaciones`, `funcionarios`, `dependencias`,
`ubicaciones` y `app_config`; salvo `usuarios`, `funcionarios`, `dependencias`
y `ubicaciones`, cada una guarda el registro completo dentro de una columna
JSONB `data`.

## Notas de seguridad

- `.env`, `*.sqlite`, `node_modules` y `dist` estan ignorados por git. Nunca
  commitear credenciales.
- `backend/patrimonio.sqlite` es un residuo de la migracion SQLite -> Supabase y
  puede contener datos reales de bienes: esta en el `.gitignore` por eso.