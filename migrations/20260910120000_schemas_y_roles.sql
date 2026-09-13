-- =============================================================================
-- 01 · Dos schemas, dos dueños, ninguna frontera porosa
--
-- Variante "catálogo replicado" (opción D). Frente a ../supabase/, la
-- diferencia de fondo cabe en una línea: aquí NO existe el schema `catalogo`.
-- Los datos de referencia viven completos en `envios` (su dueño) y replicados
-- en `eventos` bajo el prefijo ref_.
--
-- Con eso se cumple al pie de la letra lo que pidió Oliver —cada microservicio
-- con su propio schema y su propio usuario, sin compartir nada— sin pagarlo
-- con llamadas HTTP por validación ni con borrar las reglas de la base.
--
-- Las tres únicas costuras entre servicios son procesos externos, no GRANT:
--   1. sync de catálogo         → scripts/sincronizar_catalogo.sh
--   2. resolución de un envío   → eventos.resolver_envio(...)  (el GET)
--   3. propagación del estado   → scripts/consumir_outbox.sh   (el PATCH)
-- =============================================================================

create extension if not exists pgcrypto;

create schema if not exists envios;
create schema if not exists eventos;

comment on schema envios  is 'MS-Envíos: catálogo maestro + envío, parte, paquete.';
comment on schema eventos is 'MS-Eventos: réplica ref_* + evento, envio_seguido, outbox.';

-- -----------------------------------------------------------------------------
-- Un rol por microservicio. La contraseña no va en git: se pone aparte con
-- ../scripts/crear_usuarios_servicio.sql. En el contenedor local basta LOGIN,
-- porque la conexión entra por el socket con autenticación trust.
-- -----------------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'svc_envios') then
    create role svc_envios login nosuperuser nocreatedb nocreaterole noinherit;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'svc_eventos') then
    create role svc_eventos login nosuperuser nocreatedb nocreaterole noinherit;
  end if;
end $$;

comment on role svc_envios  is 'Usuario de conexión de MS-Envíos. Sin ningún privilegio sobre el schema eventos.';
comment on role svc_eventos is 'Usuario de conexión de MS-Eventos. Sin ningún privilegio sobre el schema envios.';

-- El rol de administración se hace miembro de los dos, con NOINHERIT: no gana
-- ningún privilegio por herencia, solo la capacidad de hacer SET ROLE. Es lo
-- que permite que las pruebas ejerzan la frontera de verdad —intentando leer
-- el schema ajeno y recibiendo un 42501— en vez de limitarse a consultar el
-- catálogo del sistema. En la imagen de Supabase `postgres` no es superusuario
-- y sin esto no podría impersonar a los servicios.
do $$
begin
  execute format('grant svc_envios, svc_eventos to %I', current_user);
end $$;

-- -----------------------------------------------------------------------------
-- Nadie entra por defecto. Los GRANT se dan uno a uno en la migración 07, para
-- que el permiso sea una decisión escrita y no una herencia.
-- -----------------------------------------------------------------------------
revoke all on schema envios  from public;
revoke all on schema eventos from public;
revoke all on schema public  from public;

-- El search_path de cada servicio apunta solo a lo suyo: si una consulta de
-- MS-Eventos nombra `envio` a secas, no debe resolver por accidente contra la
-- tabla del otro servicio, debe fallar.
alter role svc_envios  set search_path = envios;
alter role svc_eventos set search_path = eventos;
