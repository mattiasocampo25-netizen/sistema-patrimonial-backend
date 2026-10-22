# Despliegue — Sistema Patrimonial UNP

> **Cambio importante (v2.13.0):** este proyecto ya no tiene backend que
> desplegar. La API REST en Express fue retirada: la aplicación web habla
> directo con Supabase desde el navegador. **Solo se publica el frontend.**
> El repositorio raíz queda con las migraciones y los scripts de base de
> datos, que se aplican contra Supabase (no se despliegan).

---

## Qué se despliega

| Qué | Dónde | Desde qué repositorio |
|---|---|---|
| La aplicación web (SPA) | Vercel, como sitio estático | `frontend/` (repo propio) |
| La base de datos | Supabase (PostgreSQL) | — |
| Las migraciones y scripts | No se despliegan: se aplican con `npm run db:setup` | `backend/` (repo raíz) |

---

## Paso 1: Publicar el frontend

1. Andá a [vercel.com](https://vercel.com) e iniciá sesión.
2. **Add New Project** → importá el repositorio **`sistema-patrimonial-frontend`**
   (el del frontend; el de la raíz es el de la base de datos).
3. Configuración:
   - **Root Directory**: `frontend` (o dejalo vacío si el repositorio ya es el
     del frontend).
   - **Build Command**: `npm run build`
   - **Output Directory**: `dist`
   - **Framework**: Vite (detectado automáticamente)
4. Variables de entorno:
   - `VITE_SUPABASE_URL` → `https://TU-PROYECTO.supabase.co`
   - `VITE_SUPABASE_ANON_KEY` → la clave pública (anon) de Supabase

   Son claves **públicas**: van embebidas en el bundle. La seguridad no
   depende de ellas sino de las políticas RLS de la base.

5. Deploy.

`frontend/vercel.json` ya tiene el rewrite de SPA (para que las rutas
profundas como `/inventario` no den 404 al recargar).

---

## Paso 2: Aplicar las migraciones

Contra la base de Supabase, desde el repositorio raíz:

```bash
cd backend
cp .env.example .env        # en Windows: copy .env.example .env
# completar DATABASE_URL
npm install
npm run db:setup
```

`db:setup` es **idempotente**: aplica solo las migraciones pendientes y
anota las aplicadas en `public.schema_migrations`. Se puede volver a correr
las veces que haga falta.

Para ver el estado final de la base:

```bash
npm test    # 11 pruebas del RLS contra la base real
```

---

## Paso 3: Crear la cuenta de Auth de un usuario

Un usuario necesita **dos** cosas: el perfil en `public.usuarios` (con su rol
y su dependencia) y la cuenta de Supabase Auth. El alta del perfil la hace
la aplicación; la cuenta de Auth se crea con el script:

```bash
npm run db:crear-cuenta jsanchez
```

Imprime una clave temporal: hay que comunicársela al usuario para que entre
y la cambie. La clave **nunca** se guarda en `public.usuarios` (esa columna es
un residuo del esquema anterior y no se usa).

---

## Paso 4: Avisar a los usuarios

Si el cambio afecta la base o la interfaz, se avisa con el procedimiento de
mantenimiento (ver el README):

```bash
npm run aviso:iniciar -- --mensaje "..." --mejoras "a;b"
# ... se hace el trabajo ...
npm run aviso:cerrar -- --mensaje "..." --mejoras "a;b" --version 2.13.0
```

El frontend detecta el cambio de `ultima_version` y abre solo, para todos los
usuarios, el modal "Novedades de la vX".

---

## Paso 5: Retirar el proyecto viejo de Vercel (backend)

Hasta la v2.12.1 hubo un segundo proyecto en Vercel con el Root Directory
`backend` que publicaba la API Express. **Ya no hay nada que publicar**, así
que hay que desactivarlo:

1. En Vercel, abrí el proyecto del backend.
2. **Settings → Git → Disconnect** (o **Deployments → … → Remove**).
3. Opcionalmente, borrá el proyecto entero.

Mientras siga conectado, cada push a la raíz dispara un despliegue que falla
por falta de `api/index.js`. No rompe nada, pero ensucia los logs.

---

## Comprobar que quedó bien

| Qué | Cómo |
|---|---|
| La app carga | Abrir la URL de Vercel: debe verse el login |
| El muro de mantenimiento | Con el muro activo, cualquier visitante ve el aviso sin iniciar sesión |
| La base | `cd backend && npm test` — las 11 pruebas del RLS con los roles reales |
| El changelog | Tras un `aviso:cerrar` con versión nueva, entra un usuario: debe abrirse solo el modal "Novedades de la vX" |

---

## Solución de problemas

| Síntoma | Causa probable |
|---|---|
| La app carga pero no entra nadie | Las políticas RLS no están aplicadas: correr `npm run db:setup` |
| "Usuario sin perfil en el sistema" | El usuario tiene cuenta de Auth pero no fila en `public.usuarios` |
| El QR público no carga | La RPC `obtener_bien_publico` no existe: correr `npm run db:setup` |
| El despliegue de Vercel falla | Se está publicada la raíz: el proyecto de Vercel del backend hay que desconectarlo (Paso 5) |
| Un funcionario ve datos de otra dependencia | El RLS no está aplicado o la sesión quedó cacheada en el navegador: recargar con `Ctrl+F5` |
