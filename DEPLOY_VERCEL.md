# Despliegue en Vercel — Sistema Patrimonial UNP

Este repositorio está listo para desplegarse en **Vercel** con dos proyectos separados:
1. **Frontend** (React + Vite) — sitio estático
2. **Backend** (Node.js + Express) — función serverless

---

## Paso 1: Subir el código a un repositorio Git

```bash
# Desde la carpeta del proyecto
git remote add origin https://github.com/TU_USUARIO/sistema-patrimonial.git
git branch -M main
git push -u origin main
```

---

## Paso 2: Desplegar el Frontend en Vercel

1. Ve a [vercel.com](https://vercel.com) e inicia sesión.
2. Haz clic en **"Add New Project"**.
3. Importa tu repositorio `sistema-patrimonial`.
4. En la configuración del proyecto:
   - **Root Directory**: `frontend`
   - **Build Command**: `npm run build`
   - **Output Directory**: `dist`
   - **Framework**: Vite (detectado automáticamente)
5. Agrega las **Variables de Entorno**:
   - `VITE_API_URL` = `https://tu-backend.vercel.app` (la URL de tu backend, ver Paso 3)
6. Haz clic en **Deploy**.

El archivo `frontend/vercel.json` ya está configurado con los rewrites para SPA (historial de rutas).

---

## Paso 3: Desplegar el Backend en Vercel

1. Crea un **nuevo proyecto** en Vercel (otro "Add New Project").
2. Importa el mismo repositorio.
3. En la configuración:
   - **Root Directory**: `backend`
   - **Build Command**: (dejar vacío, no es necesario para Node)
   - **Output Directory**: (dejar vacío)
4. Vercel detectará `backend/api/index.js` como la función serverless y expone
   todo `/api/*` automáticamente. **No hace falta `vercel.json`**: se eliminó
   porque el bloque `functions` pedía un runtime en formato `nodejs20.x` y el
   schema actual de Vercel exige `<runtime>@<version>` (`invalid_function_runtime`).
   - **Verificá la versión de Node en** Settings → General → Node.js version
     (18 está en fin de vida; usá 20 o superior).
   - **Si el proyecto tiene el Root Directory en `backend`**, las variables de
     entorno del proyecto llegan tal cual a la función. El backend acepta
     `DATABASE_URL` o `SUPABASE_DB_URL`, y `SECRET_KEY` o `JWT_SECRET`.
   - **No definás `PORT`**: lo asigna Vercel.
   - `DATABASE_SSL` no hace falta: sin esa variable el servidor usa
     `{ rejectUnauthorized: false }`, que es SSL activo y es lo que exige
     Supabase.
5. Agrega las **Variables de Entorno** obligatorias en
   *Settings → Environment Variables*. El nombre debe ser **exacto**: son las
   que lee el código (`process.env.X`).

   | Nombre | Valor |
   |---|---|
   | `DATABASE_URL` | `postgresql://postgres.<ref>:<clave>@aws-0-<regiona>.pooler.supabase.com:5432/postgres` |
   | `SECRET_KEY` | `node -e "console.log(require('crypto').randomBytes(48).toString('hex'))"` |
   | `CORS_ORIGIN` | `https://tu-frontend.vercel.app` |

   > **Usa el pooler de Supabase** (`aws-0-<regiona>.pooler.supabase.com`, usuario
   > `postgres.<ref>`), no el host directo `db.<ref>.supabase.co`: el host
   > directo es **IPv6-only** y no resuelve en la mayoría de las redes.
   >
   > `SECRET_KEY` **no** puede ser el secreto JWT de Supabase: si lo fuera,
   > cualquiera con la `service_role` podría firmar un token de administrador
   > y la API lo aceptaría. Es una clave propia de esta API.
   >
   > `ADMIN_INITIAL_PASSWORD` ya no hace falta: el alta de usuarios se hace
   > contra Supabase Auth.
6. Haz clic en **Deploy**.
7. **Redeploy** después de cambiar variables: no se aplican a despliegues ya
   hechos (Deployments → ⋯ → Redeploy).

### Comprobar que quedó bien

```bash
curl -s https://tu-backend.vercel.app/api/health
```

| Respuesta | Significado |
|---|---|
| `{"ok":true,...,"db":"ok"}` | Todo bien |
| `{"ok":false,"faltan":["DATABASE_URL","SECRET_KEY"],...}` | Faltan variables: el mensaje dice cuáles |
| `FUNCTION_INVOCATION_FAILED` (500 sin cuerpo) | La función crashea: mirá los logs del deployment |

El backend queda expuesto en `https://tu-backend.vercel.app/api/...`

---

## Paso 4: Ejecutar la migración de base de datos

Una vez desplegado el backend, ejecuta el SQL en el SQL Editor de Supabase:

```bash
# O ejecuta directamente en el SQL Editor de Supabase Dashboard:
cat backend/migrations/001_esquema_inicial.sql
```

Esto crea:
- Tabla `app_config` (configuración global, modo mantenimiento)
- Índices en columnas JSONB para rendimiento
- Documentación de sugerencias de encriptación

---

## Paso 5: Ejecutar los tests

En tu máquina local, antes de desplegar:

```bash
# Backend
cd backend
npm test

# Frontend
cd frontend
npm test
```

Todos los tests deben pasar (tests de respaldo y autorización incluidos).

---

## Estructura de despliegue

```
sistema-patrimonial/
├── backend/
│   ├── api/index.js          # Handler serverless para Vercel
│   ├── server.js             # App Express (exportada)
│   ├── lib/respaldo.js       # Backup/restore con schema validation
│   ├── lib/authz.js          # Middleware de autorización (exigirAdmin)
│   ├── lib/security.js       # Rate limiting, sanitización, CSP
│   ├── migrations/           # SQL de base de datos
│   ├── test/                 # Tests unitarios (respaldo, authz)
│   └── vercel.json           # Configuración Vercel backend
├── frontend/
│   ├── vercel.json           # Configuración Vercel frontend
│   └── ...
├── DEPLOY_VERCEL.md          # Este archivo
└── README.md
```

---

## Endpoints clave del backend

| Método | Ruta | Protección | Descripción |
|--------|------|------------|-------------|
| GET | `/api/respaldo/exportar` | `exigirAdmin` | Descarga JSON completo de respaldo |
| POST | `/api/respaldo/restaurar` | `exigirAdmin` | Valida esquema y restaura BD |
| PATCH | `/api/fc10/:id/firma-estado` | `exigirAdmin` | Cambia estado de firma FC-10 (solo admin) |
| GET | `/api/app_config` | `exigirPrivilegio` | Configuración global (mantenimiento) |
| PATCH | `/api/app_config` | `exigirPrivilegio` | Actualizar configuración global |

---

## Notas importantes

- **Socket.io**: En Vercel serverless, WebSockets no están disponibles. El frontend seguirá funcionando para operaciones REST, pero el tiempo real via Socket.io requeriría un backend en un entorno persistente (Railway, Render, DigitalOcean App Platform).
- **Rate limiting**: El limitador general es en memoria (120 req/min por IP). En Vercel serverless, cada invocación es isolada, por lo que el rate limiting funciona por instancia, no globalmente. Para producción de alto tráfico, considera Redis o un WAF.
- **Variables de entorno**: Nunca commitees el archivo `.env`. Usa el panel de Vercel para configurarlas.

---

## Soporte

Contacto: patrimonio@unp.edu.py
Desarrollador: Matias Ocampo
