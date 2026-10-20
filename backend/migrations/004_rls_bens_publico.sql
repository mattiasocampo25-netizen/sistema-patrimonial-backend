-- =============================================================================
-- 004_rls_bens_publico.sql
-- Cierra el acceso ANONIMO a la tabla `bens`.
--
-- ESTADO: APLICADA EN PRODUCCION el 2026-10-20, despues de verificar que el
-- frontend desplegado ya usaba la RPC (se comprobo en el sitio en
-- produccion: la vista publica llama a /rest/v1/rpc/obtener_bien_publico y
-- NO a /rest/v1/bens).
--
-- =============================================================================
-- ORDEN DE APLICACIÓN (importante)
-- =============================================================================
-- Esta migración SOLO se puede aplicar DESPUÉS de desplegar el frontend con
-- el cambio de la vista pública (App.jsx -> cargarBienPublico usa ahora la RPC
-- `obtener_bien_publico` en vez de leer la tabla `bens`).
--
-- Si se aplica antes, la vista pública de QR deja de funcionar: el visitante
-- sin sesión ya no puede leer `bens` y el frontend desplegado todavía lo
-- hace.
--
-- Pasos:
--   1. Desplegar el frontend (el cambio ya está en el repositorio).
--   2. Verificar que la RPC responde con la anon key:
--        curl -s -X POST "$SUPABASE_URL/rest/v1/rpc/obtener_bien_publico" \
--          -H "apikey: $ANON_KEY" -H "Authorization: Bearer $ANON_KEY" \
--          -H "Content-Type: application/json" \
--          -d '{"p_id":"<rotulo-de-algun-bien>"}'
--      -> debe devolver el bien con todos sus campos.
--   3. Aplicar esta migración.
--   4. Verificar que la tabla ya no es accesible de forma anónima:
--        curl -s -o /dev/null -w "%{http_code}" \
--          "$SUPABASE_URL/rest/v1/bens?select=id&limit=1" \
--          -H "apikey: $ANON_KEY" -H "Authorization: Bearer $ANON_KEY"
--      -> debe devolver 401/403 (antes 200 con 13.673 filas).
--
-- =============================================================================
-- QUÉ HACE
-- =============================================================================
-- Con la política "Lectura publica bens" (FOR SELECT TO anon USING true) un
-- visitante sin sesión podía pedir:
--     GET /rest/v1/bens?select=id,data
-- y obtener las 13.673 filas del inventario con TODOS los campos (valor
-- monetario, responsable, ubicación, fotos). Es decir, el QR público de un
-- bien abría la puerta a volcar la base entera.
--
-- Lo que se conserva: la vista pública de QR sigue funcionando, porque pasa
-- por la RPC `obtener_bien_publico`, que es SECURITY DEFINER (ignora el RLS)
-- y devuelve UN bien, con una proyección de los campos públicos.
--
-- Idempotente. Aplicar con el rol `postgres`:
--   psql "$DATABASE_URL" -f backend/migrations/004_rls_bens_publico.sql
-- =============================================================================

BEGIN;

-- 1) Se retira la politica de lectura anonima de la tabla.
DROP POLICY IF EXISTS "Lectura publica bens" ON public.bens;

-- 2) Se retira el permiso de tabla al rol anon.
--    Con esto, aunque alguien volviera a crear la politica, `anon` no tendria
--    permiso de tabla y no podria leer nada.
REVOKE ALL ON TABLE public.bens FROM anon;

-- 3) Se deja el acceso de los autenticados intacto (la politica por
--    dependencia de la migracion 003).
--    service_role y postgres no se ven afectados: saltan el RLS.

COMMIT;

-- =============================================================================
-- ROLLBACK
--
--   BEGIN;
--   CREATE POLICY "Lectura publica bens" ON public.bens
--     FOR SELECT TO anon USING (true);
--   GRANT ALL ON TABLE public.bens TO anon;
--   COMMIT;
-- =============================================================================
