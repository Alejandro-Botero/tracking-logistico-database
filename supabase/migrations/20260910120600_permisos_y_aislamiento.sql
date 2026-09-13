-- =============================================================================
-- 07 · Permisos, y la prueba de que la frontera existe
--
-- La tabla de permisos del README del modelo completo decía:
--
--   | Schema    | MS-Envíos | MS-Eventos                    |
--   | catalogo  | RW        | solo lectura   <- el problema |
--   | envios    | RW        | sin acceso (vista puente)     |
--   | eventos   | sin acceso| RW                            |
--
-- Aquí no hay casilla gris. Cada servicio ve su schema y nada más:
--
--   | Schema   | MS-Envíos  | MS-Eventos |
--   | envios   | RW         | NADA       |
--   | eventos  | NADA       | RW         |
--
-- `verificar_aislamiento()` lo comprueba en siete frentes y las pruebas lo
-- corren, así que un GRANT de más en una migración futura sale en rojo y no en
-- el diccionario seis meses después.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- MS-Envíos sobre su schema, y solo sobre su schema.
-- -----------------------------------------------------------------------------
grant usage on schema envios to svc_envios;
grant select, insert, update on all tables    in schema envios to svc_envios;
grant usage, select           on all sequences in schema envios to svc_envios;
grant execute                 on all functions in schema envios to svc_envios;

alter default privileges in schema envios
  grant select, insert, update on tables to svc_envios;
alter default privileges in schema envios
  grant usage, select on sequences to svc_envios;
alter default privileges in schema envios
  grant execute on functions to svc_envios;

-- El catálogo es de MS-Envíos, pero cambiarlo es una operación de
-- administración, no de la API: el borrado queda fuera del rol de servicio.
revoke delete on all tables in schema envios from svc_envios;

-- -----------------------------------------------------------------------------
-- MS-Eventos sobre su schema, y solo sobre su schema.
-- -----------------------------------------------------------------------------
grant usage on schema eventos to svc_eventos;
grant select, insert, update on all tables    in schema eventos to svc_eventos;
grant usage, select           on all sequences in schema eventos to svc_eventos;
grant execute                 on all functions in schema eventos to svc_eventos;

alter default privileges in schema eventos
  grant select, insert, update on tables to svc_eventos;
alter default privileges in schema eventos
  grant usage, select on sequences to svc_eventos;
alter default privileges in schema eventos
  grant execute on functions to svc_eventos;

-- El historial no se borra ni se reescribe: el trigger de NFR-06 lo impide, y
-- el permiso tampoco está.
revoke delete          on all tables in schema eventos from svc_eventos;
revoke update, delete  on eventos.evento               from svc_eventos;

-- -----------------------------------------------------------------------------
-- Y nada más. Estas líneas no existen a propósito, y la verificación de abajo
-- se encarga de que sigan sin existir:
--
--   grant usage on schema eventos to svc_envios;    <- NO
--   grant usage on schema envios  to svc_eventos;   <- NO
-- -----------------------------------------------------------------------------

-- =============================================================================
-- La verificación
-- =============================================================================
create or replace function public.verificar_aislamiento()
returns table (control text, detalle text, ok boolean)
language sql stable as $$
  -- 1 y 2 · ninguno de los dos usuarios puede siquiera abrir el schema del otro
  select
    'schema ajeno cerrado a svc_eventos'::text,
    'has_schema_privilege(svc_eventos, envios, USAGE)'::text,
    not has_schema_privilege('svc_eventos', 'envios', 'USAGE')

  union all
  select
    'schema ajeno cerrado a svc_envios',
    'has_schema_privilege(svc_envios, eventos, USAGE)',
    not has_schema_privilege('svc_envios', 'eventos', 'USAGE')

  -- 3 y 4 · ni una tabla ni una vista del otro lado con algún privilegio suelto.
  -- Se pregunta por OID y no por nombre: has_table_privilege() con texto resuelve
  -- contra el search_path, y el planificador puede evaluar ese predicado antes
  -- del filtro de schema.
  union all
  select
    'sin privilegios de svc_eventos sobre objetos de envios',
    coalesce(string_agg(c.relname, ', '), 'ninguno'),
    count(*) = 0
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'envios'
    and c.relkind in ('r','p','v','m')
    and (   has_table_privilege('svc_eventos', c.oid, 'SELECT')
         or has_table_privilege('svc_eventos', c.oid, 'INSERT')
         or has_table_privilege('svc_eventos', c.oid, 'UPDATE')
         or has_table_privilege('svc_eventos', c.oid, 'DELETE'))

  union all
  select
    'sin privilegios de svc_envios sobre objetos de eventos',
    coalesce(string_agg(c.relname, ', '), 'ninguno'),
    count(*) = 0
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'eventos'
    and c.relkind in ('r','p','v','m')
    and (   has_table_privilege('svc_envios', c.oid, 'SELECT')
         or has_table_privilege('svc_envios', c.oid, 'INSERT')
         or has_table_privilege('svc_envios', c.oid, 'UPDATE')
         or has_table_privilege('svc_envios', c.oid, 'DELETE'))

  -- 5 · ninguna FK cruza la frontera: la prueba estructural, no de permisos
  union all
  select
    'ninguna FK cruza entre schemas',
    coalesce(string_agg(tn.nspname || '.' || t.relname || ' -> ' || fn.nspname || '.' || f.relname, ', '),
             'ninguna'),
    count(*) = 0
  from pg_constraint c
  join pg_class     t  on t.oid  = c.conrelid
  join pg_namespace tn on tn.oid = t.relnamespace
  join pg_class     f  on f.oid  = c.confrelid
  join pg_namespace fn on fn.oid = f.relnamespace
  where c.contype = 'f'
    and tn.nspname in ('envios','eventos')
    and fn.nspname in ('envios','eventos')
    and tn.nspname <> fn.nspname

  -- 6 · ninguna vista de un servicio lee tablas del otro
  union all
  select
    'ninguna vista cruza entre schemas',
    coalesce(string_agg(distinct vn.nspname || '.' || v.relname, ', '), 'ninguna'),
    count(*) = 0
  from pg_depend d
  join pg_rewrite   r  on r.oid  = d.objid
  join pg_class     v  on v.oid  = r.ev_class
  join pg_namespace vn on vn.oid = v.relnamespace
  join pg_class     t  on t.oid  = d.refobjid
  join pg_namespace tn on tn.oid = t.relnamespace
  where d.classid = 'pg_rewrite'::regclass
    and v.relkind = 'v'
    and vn.nspname in ('envios','eventos')
    and tn.nspname in ('envios','eventos')
    and vn.nspname <> tn.nspname

  -- 7 · ningún cuerpo de función de un servicio nombra al otro schema
  union all
  select
    'ninguna función cruza entre schemas',
    coalesce(string_agg(n.nspname || '.' || p.proname, ', '), 'ninguna'),
    count(*) = 0
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname in ('envios','eventos')
    and p.prosrc ~ ('\m' || case n.nspname when 'envios' then 'eventos' else 'envios' end || '\.');
$$;

comment on function public.verificar_aislamiento() is
  'Siete controles de la frontera entre microservicios. Cualquier fila con ok = false es un GRANT o una dependencia de más.';

grant execute on function public.verificar_aislamiento() to public;
grant usage on schema public to public;
