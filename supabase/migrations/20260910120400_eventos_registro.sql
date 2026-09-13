-- =============================================================================
-- 05 · Evento, proyección del envío y outbox · HU-02, HU-04, NFR-06
--
-- Aquí se ve el resultado de la propuesta: la validación completa de un evento
-- —tipo, punto, operador, estado de partida y transición— se resuelve con FK y
-- JOIN dentro de este schema. Cero llamadas HTTP en el camino de la respuesta.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Proyección local del envío.
--
-- Esta es la pieza que convierte `evento.envio_id` de referencia colgando en el
-- aire a FK física contra una tabla local. Se llena con la costura nº 2
-- (GET /envios/{tracking}) la primera vez que MS-Eventos ve ese envío; del
-- segundo evento en adelante ya está en casa.
--
-- MS-Eventos es dueño de la transición: resuelve a qué estado lleva el evento y
-- lo escribe aquí. `envios.envio.estado_actual` es la copia para rastreo, que
-- llega por el outbox. Un solo escritor de transiciones, ninguna carrera.
-- -----------------------------------------------------------------------------
create table eventos.envio_seguido (
  envio_id          uuid primary key,           -- referencia lógica: vive en MS-Envíos
  tracking_number   text not null unique,
  estado_actual     text not null references eventos.ref_estado_envio(codigo),
  version           integer not null default 0, -- última versión conocida de MS-Envíos
  admitido_en       timestamptz,
  ultimo_evento_en  timestamptz,
  ultimo_punto_id   uuid references eventos.ref_punto_red(id),
  cerrado           boolean not null default false,
  resuelto_en       timestamptz not null default now()
);

comment on table  eventos.envio_seguido is 'Lo que MS-Eventos sabe de un envío. Una llamada por envío, no por evento.';
comment on column eventos.envio_seguido.envio_id is 'Sin FK: el envío vive en la base del otro servicio. Es la única referencia lógica del modelo.';
comment on column eventos.envio_seguido.version is 'Versión que MS-Envíos tenía la última vez. La usa el consumidor del outbox como expectativa del PATCH.';

-- Costura nº 2: la respuesta del GET entra por aquí.
create or replace function eventos.resolver_envio(
  p_envio_id         uuid,
  p_tracking         text,
  p_estado_actual    text,
  p_version          integer,
  p_admitido_en      timestamptz,
  p_ultimo_evento_en timestamptz,
  p_ultimo_punto_id  uuid,
  p_cerrado          boolean
) returns void
language sql as $$
  insert into eventos.envio_seguido
    (envio_id, tracking_number, estado_actual, version,
     admitido_en, ultimo_evento_en, ultimo_punto_id, cerrado, resuelto_en)
  values
    (p_envio_id, p_tracking, p_estado_actual, p_version,
     p_admitido_en, p_ultimo_evento_en, p_ultimo_punto_id, p_cerrado, now())
  on conflict (envio_id) do update set
    estado_actual    = excluded.estado_actual,
    version          = excluded.version,
    admitido_en      = excluded.admitido_en,
    ultimo_evento_en = excluded.ultimo_evento_en,
    ultimo_punto_id  = excluded.ultimo_punto_id,
    cerrado          = excluded.cerrado,
    resuelto_en      = now();
$$;

comment on function eventos.resolver_envio(uuid, text, text, integer, timestamptz, timestamptz, uuid, boolean) is
  'Ingesta de GET /envios/{tracking}. También es el camino de recuperación tras un 409.';

-- -----------------------------------------------------------------------------
-- El historial. Un libro de contabilidad: solo se le agregan renglones.
-- Todas sus FK apuntan dentro de este schema.
-- -----------------------------------------------------------------------------
create table eventos.evento (
  id                 uuid primary key default gen_random_uuid(),
  secuencia          bigint generated always as identity,   -- desempata mismo ocurrido_en
  envio_id           uuid not null references eventos.envio_seguido(envio_id),
  tracking_number    text not null,                          -- lo llena el trigger
  tipo_evento        text not null references eventos.ref_tipo_evento(codigo),
  estado_resultante  text not null references eventos.ref_estado_envio(codigo),
  cierra_envio       boolean not null default false,
  punto_red_id       uuid not null references eventos.ref_punto_red(id),
  ocurrido_en        timestamptz not null default now(),
  registrado_en      timestamptz not null default now(),
  registrado_por     text not null references eventos.ref_operador(codigo),
  recibido_por       text,
  observaciones      text,
  clave_idempotencia text,
  constraint ck_evento_no_futuro check (ocurrido_en <= registrado_en + interval '5 minutes')
);

comment on table  eventos.evento is 'Cada paso del envío por un punto de la red. Append-only (NFR-06).';
comment on column eventos.evento.envio_id is 'FK real contra la proyección local: un evento sobre un envío no resuelto es imposible.';
comment on column eventos.evento.estado_resultante is 'Estado en que quedó el envío por este evento. El historial dice lo que pasó, no lo que hoy pasaría.';
comment on column eventos.evento.clave_idempotencia is 'La manda el cliente para que un reintento no registre el mismo hecho dos veces (23505 = tratar como éxito).';

create index idx_evento_envio    on eventos.evento (envio_id, ocurrido_en desc, secuencia desc);
create index idx_evento_tracking on eventos.evento (tracking_number);
create index idx_evento_punto    on eventos.evento (punto_red_id, ocurrido_en);

create unique index uq_evento_cierre on eventos.evento (envio_id) where cierra_envio;
create unique index uq_evento_idem   on eventos.evento (clave_idempotencia) where clave_idempotencia is not null;

-- -----------------------------------------------------------------------------
-- Inmutabilidad del historial (NFR-06).
-- -----------------------------------------------------------------------------
create or replace function eventos.bloquear_modificacion() returns trigger
language plpgsql as $$
begin
  raise exception 'El historial de eventos es de solo inserción (NFR-06): % no permitido', tg_op
    using errcode = '0A000',
          hint    = 'Para corregir un evento se registra un evento de ajuste.';
end $$;

create trigger trg_evento_inmutable before update or delete on eventos.evento
  for each row execute function eventos.bloquear_modificacion();

-- -----------------------------------------------------------------------------
-- Validación completa del evento, incluida la máquina de estados.
-- Todo contra tablas de este schema: ref_* y envio_seguido. Cero HTTP.
-- -----------------------------------------------------------------------------
create or replace function eventos.validar_evento() returns trigger
language plpgsql as $$
declare
  v_tipo    eventos.ref_tipo_evento%rowtype;
  v_envio   eventos.envio_seguido%rowtype;
  v_actual  eventos.ref_estado_envio%rowtype;
  v_destino eventos.ref_estado_envio%rowtype;
begin
  select * into v_tipo from eventos.ref_tipo_evento where codigo = new.tipo_evento;
  if not found then
    raise exception 'No existe el tipo de evento % en la réplica', new.tipo_evento
      using errcode = '23503',
            hint    = 'Si el catálogo cambió hace poco, correr scripts/sincronizar_catalogo.sh.';
  end if;

  -- Se bloquea la proyección y sigue bloqueada para el trigger AFTER: dos
  -- eventos simultáneos del mismo envío, en esta instancia, se serializan.
  -- Entre instancias distintas el que corta la carrera es envio.version.
  select * into v_envio from eventos.envio_seguido where envio_id = new.envio_id for update;
  if not found then
    raise exception 'El envío % no ha sido resuelto por MS-Eventos', new.envio_id
      using errcode = '23503',
            hint    = 'Llamar antes a eventos.resolver_envio() con la respuesta de GET /envios/{tracking}.';
  end if;
  new.tracking_number := v_envio.tracking_number;

  if v_tipo.requiere_receptor and coalesce(btrim(new.recibido_por), '') = '' then
    raise exception 'El evento % exige constancia de quién recibió', new.tipo_evento using errcode = '23514';
  end if;
  if v_tipo.requiere_observaciones and coalesce(btrim(new.observaciones), '') = '' then
    raise exception 'El evento % exige una observación que explique el motivo', new.tipo_evento using errcode = '23514';
  end if;
  if v_envio.ultimo_evento_en is not null and new.ocurrido_en < v_envio.ultimo_evento_en then
    raise exception 'El evento ocurre antes del último movimiento del envío % (% < %)',
      v_envio.tracking_number, new.ocurrido_en, v_envio.ultimo_evento_en
      using errcode = '22007', hint = 'El historial se registra en orden cronológico.';
  end if;
  if not exists (select 1 from eventos.ref_punto_red p where p.id = new.punto_red_id and p.activo) then
    raise exception 'El punto de la red % no está activo en la réplica', new.punto_red_id
      using errcode = '23514',
            hint    = 'Si el punto es nuevo, correr scripts/sincronizar_catalogo.sh.';
  end if;

  select * into v_actual from eventos.ref_estado_envio where codigo = v_envio.estado_actual;
  if v_actual.es_final then
    raise exception 'El envío % ya está en estado final (%) y no admite más eventos',
      v_envio.tracking_number, v_envio.estado_actual using errcode = '23514';
  end if;

  -- origen + evento -> destino, resuelto localmente
  select d.* into v_destino
    from eventos.ref_transicion_valida t
    join eventos.ref_estado_envio d on d.codigo = t.estado_destino
   where t.estado_origen = v_envio.estado_actual
     and t.tipo_evento   = new.tipo_evento;
  if not found then
    raise exception 'Transición no permitida: un envío en estado % no admite el evento %',
      v_envio.estado_actual, new.tipo_evento
      using errcode = '23514',
            hint    = 'Un evento por sentencia: en un INSERT de varias filas los triggers AFTER corren al final.';
  end if;

  new.estado_resultante := v_destino.codigo;
  new.cierra_envio      := v_destino.es_final;
  return new;
end $$;

create trigger trg_evento_validar before insert on eventos.evento
  for each row execute function eventos.validar_evento();

-- =============================================================================
-- Outbox · la costura nº 3 vista desde este lado
--
-- En ../supabase/ el trigger escribía directamente sobre envios.envio. Aquí se
-- limita a dejar constancia de que hay algo que publicar, en la misma
-- transacción que el evento: no existe el estado "evento registrado pero nunca
-- propagado", y el cliente no espera a MS-Envíos para recibir su 201.
-- =============================================================================
create table eventos.outbox (
  id                 bigint generated always as identity primary key,
  evento_id          uuid not null unique references eventos.evento(id),
  envio_id           uuid not null,
  estado_resultante  text not null,
  ocurrido_en        timestamptz not null,
  punto_red_id       uuid not null,
  intentos           smallint not null default 0,
  creado_en          timestamptz not null default now(),
  publicado_en       timestamptz,
  ultimo_error       text
);

comment on table eventos.outbox is 'Cola de publicación hacia MS-Envíos. La drena scripts/consumir_outbox.sh.';

create index idx_outbox_pendiente on eventos.outbox (id) where publicado_en is null;

-- -----------------------------------------------------------------------------
-- El evento avanza la proyección local y encola su publicación, atómicamente.
-- -----------------------------------------------------------------------------
create or replace function eventos.aplicar_evento() returns trigger
language plpgsql as $$
begin
  update eventos.envio_seguido set
    estado_actual    = new.estado_resultante,
    ultimo_evento_en = new.ocurrido_en,
    ultimo_punto_id  = new.punto_red_id,
    admitido_en      = coalesce(admitido_en, new.ocurrido_en),
    cerrado          = cerrado or new.cierra_envio
  where envio_id = new.envio_id;

  insert into eventos.outbox (evento_id, envio_id, estado_resultante, ocurrido_en, punto_red_id)
  values (new.id, new.envio_id, new.estado_resultante, new.ocurrido_en, new.punto_red_id);

  return null;
end $$;

create trigger trg_evento_aplicar after insert on eventos.evento
  for each row execute function eventos.aplicar_evento();

-- -----------------------------------------------------------------------------
-- Lo que llama el consumidor cuando el PATCH salió bien.
-- -----------------------------------------------------------------------------
create or replace function eventos.confirmar_publicacion(p_outbox_id bigint, p_version_nueva integer)
returns void
language plpgsql as $$
begin
  update eventos.envio_seguido s set version = p_version_nueva
    from eventos.outbox o
   where o.id = p_outbox_id and s.envio_id = o.envio_id;

  update eventos.outbox
     set publicado_en = now(), intentos = intentos + 1, ultimo_error = null
   where id = p_outbox_id;
end $$;

create or replace function eventos.fallo_publicacion(p_outbox_id bigint, p_error text)
returns void
language sql as $$
  update eventos.outbox
     set intentos = intentos + 1, ultimo_error = p_error
   where id = p_outbox_id;
$$;

comment on function eventos.confirmar_publicacion(bigint, integer) is
  'Marca la fila publicada y guarda la versión que devolvió MS-Envíos, para el siguiente PATCH.';

-- -----------------------------------------------------------------------------
-- Recuperación tras un 409: lo que quedó viejo es el número de versión, no el
-- estado. MS-Eventos ya aplicó el evento en su proyección y sigue teniendo la
-- razón sobre la transición; solo necesita volver a saber por qué versión va
-- MS-Envíos para que el siguiente PATCH acierte. Sobrescribir la proyección
-- entera aquí sería hacerla retroceder.
-- -----------------------------------------------------------------------------
create or replace function eventos.refrescar_version(p_envio_id uuid, p_version integer)
returns void
language sql as $$
  update eventos.envio_seguido set version = p_version where envio_id = p_envio_id;
$$;

comment on function eventos.refrescar_version(uuid, integer) is
  'Camino de recuperación del 409: actualiza solo la versión conocida, no el estado.';
