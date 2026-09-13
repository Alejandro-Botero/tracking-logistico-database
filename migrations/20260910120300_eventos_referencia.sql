-- =============================================================================
-- 04 · La réplica de referencia · el corazón de la propuesta
--
-- Estas tablas son de MS-Eventos. Las crea su migración, las escribe su proceso
-- de sync y ningún otro servicio las toca: no hay un solo GRANT hacia `envios`.
-- Eso es exactamente lo que pidió Oliver.
--
-- A cambio de duplicar 54 filas de datos casi estáticos, MS-Eventos:
--   · valida tipo, punto, operador y transición con FK y JOIN, no con HTTP
--   · pinta el historial de HU-04 con un join local en vez de N lookups
--   · sigue funcionando aunque MS-Envíos esté caído
--
-- El costo honesto está en la consistencia eventual: entre que se abre un
-- centro de distribución y que MS-Eventos lo conoce hay una ventana. Durante
-- esa ventana un evento en ese punto se rechaza con un error claro, y el
-- arreglo es correr el sync. Los catálogos cambian cuando se abre una sede;
-- no es un evento de todos los días.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Puntos de la red. La ciudad viaja aplanada: replicar el catálogo DIVIPOLA
-- entero no aportaría nada porque el historial solo muestra el nombre.
-- -----------------------------------------------------------------------------
create table eventos.ref_punto_red (
  id               uuid primary key,
  codigo           text not null unique,
  nombre           text not null,
  tipo             text not null,
  ciudad_nombre    text not null,
  activo           boolean not null default true,
  sincronizado_en  timestamptz not null default now()
);

comment on table eventos.ref_punto_red is 'Réplica de envios.punto_red. Sostiene HU-04 (nombre del punto) y HU-07 sin salir de la base.';

-- -----------------------------------------------------------------------------
-- Operadores (NFR-04).
-- -----------------------------------------------------------------------------
create table eventos.ref_operador (
  codigo           text primary key,
  nombre           text,
  activo           boolean not null default true,
  sincronizado_en  timestamptz not null default now()
);

comment on table eventos.ref_operador is 'Réplica de envios.operador. Hace que registrado_por sea una FK y no un texto suelto.';

-- -----------------------------------------------------------------------------
-- Estados y tipos de evento.
-- -----------------------------------------------------------------------------
create table eventos.ref_estado_envio (
  codigo           text primary key,
  nombre           text not null,
  es_final         boolean not null default false,
  es_excepcion     boolean not null default false,
  resultado        text check (resultado in ('EXITOSO','FALLIDO')),
  orden            smallint,
  sincronizado_en  timestamptz not null default now()
);

create table eventos.ref_tipo_evento (
  codigo                  text primary key,
  nombre                  text not null,
  requiere_receptor       boolean not null default false,
  requiere_observaciones  boolean not null default false,
  visible_cliente         boolean not null default true,
  sincronizado_en         timestamptz not null default now()
);

-- -----------------------------------------------------------------------------
-- La máquina de estados, replicada. Una sola definición (la de MS-Envíos) y
-- una sola copia: no hay dos implementaciones en código que puedan divergir.
-- -----------------------------------------------------------------------------
create table eventos.ref_transicion_valida (
  estado_origen    text not null references eventos.ref_estado_envio(codigo),
  tipo_evento      text not null references eventos.ref_tipo_evento(codigo),
  estado_destino   text not null references eventos.ref_estado_envio(codigo),
  sincronizado_en  timestamptz not null default now(),
  primary key (estado_origen, tipo_evento)
);

comment on table eventos.ref_transicion_valida is 'Aquí se resuelve a qué estado lleva un evento, con un JOIN local. Cero HTTP.';

-- -----------------------------------------------------------------------------
-- Estado del sync: deja ver si la réplica quedó atrás en vez de adivinarlo.
-- -----------------------------------------------------------------------------
create table eventos.ref_sync (
  recurso          text primary key,
  version          bigint not null,
  filas            integer not null check (filas >= 0),
  sincronizado_en  timestamptz not null default now()
);

comment on table eventos.ref_sync is 'Versión y conteo de cada catálogo replicado, como los reportó MS-Envíos en el último sync.';

-- -----------------------------------------------------------------------------
-- Ingesta del sync. El proceso externo entrega filas; estas funciones las
-- aplican de forma idempotente, así que correr el sync de más nunca hace daño.
-- -----------------------------------------------------------------------------
create or replace function eventos.sync_punto_red(
  p_id uuid, p_codigo text, p_nombre text, p_tipo text, p_ciudad text, p_activo boolean
) returns void language sql as $$
  insert into eventos.ref_punto_red (id, codigo, nombre, tipo, ciudad_nombre, activo, sincronizado_en)
  values (p_id, p_codigo, p_nombre, p_tipo, p_ciudad, p_activo, now())
  on conflict (id) do update set
    codigo = excluded.codigo, nombre = excluded.nombre, tipo = excluded.tipo,
    ciudad_nombre = excluded.ciudad_nombre, activo = excluded.activo,
    sincronizado_en = now();
$$;

create or replace function eventos.sync_operador(
  p_codigo text, p_nombre text, p_activo boolean
) returns void language sql as $$
  insert into eventos.ref_operador (codigo, nombre, activo, sincronizado_en)
  values (p_codigo, p_nombre, p_activo, now())
  on conflict (codigo) do update set
    nombre = excluded.nombre, activo = excluded.activo, sincronizado_en = now();
$$;

create or replace function eventos.sync_estado_envio(
  p_codigo text, p_nombre text, p_es_final boolean, p_es_excepcion boolean,
  p_resultado text, p_orden smallint
) returns void language sql as $$
  insert into eventos.ref_estado_envio (codigo, nombre, es_final, es_excepcion, resultado, orden, sincronizado_en)
  values (p_codigo, p_nombre, p_es_final, p_es_excepcion, p_resultado, p_orden, now())
  on conflict (codigo) do update set
    nombre = excluded.nombre, es_final = excluded.es_final, es_excepcion = excluded.es_excepcion,
    resultado = excluded.resultado, orden = excluded.orden, sincronizado_en = now();
$$;

create or replace function eventos.sync_tipo_evento(
  p_codigo text, p_nombre text, p_req_receptor boolean,
  p_req_observaciones boolean, p_visible boolean
) returns void language sql as $$
  insert into eventos.ref_tipo_evento
    (codigo, nombre, requiere_receptor, requiere_observaciones, visible_cliente, sincronizado_en)
  values (p_codigo, p_nombre, p_req_receptor, p_req_observaciones, p_visible, now())
  on conflict (codigo) do update set
    nombre = excluded.nombre, requiere_receptor = excluded.requiere_receptor,
    requiere_observaciones = excluded.requiere_observaciones,
    visible_cliente = excluded.visible_cliente, sincronizado_en = now();
$$;

create or replace function eventos.sync_transicion(
  p_origen text, p_tipo text, p_destino text
) returns void language sql as $$
  insert into eventos.ref_transicion_valida (estado_origen, tipo_evento, estado_destino, sincronizado_en)
  values (p_origen, p_tipo, p_destino, now())
  on conflict (estado_origen, tipo_evento) do update set
    estado_destino = excluded.estado_destino, sincronizado_en = now();
$$;

create or replace function eventos.sync_marcar(
  p_recurso text, p_version bigint, p_filas integer
) returns void language sql as $$
  insert into eventos.ref_sync (recurso, version, filas, sincronizado_en)
  values (p_recurso, p_version, p_filas, now())
  on conflict (recurso) do update set
    version = excluded.version, filas = excluded.filas, sincronizado_en = now();
$$;

comment on function eventos.sync_marcar(text, bigint, integer) is
  'Cierra un ciclo de sync anotando qué versión del catálogo quedó aplicada.';
