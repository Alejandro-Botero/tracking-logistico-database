-- =====================================================================
-- Tracking logístico — Fábrica Escuela, Sprint 2
-- Script de estructuras: roles, schemas, tablas, claves, restricciones,
-- índices, funciones/triggers de integridad, vistas de reporte, RLS y
-- privilegios. Ejecutable de punta a punta en un PostgreSQL / Supabase
-- vacío:
--     psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f schema.sql
-- Orden: roles -> schemas -> funciones -> tablas (padres antes que hijos)
-- -> vistas -> índices -> triggers -> FK -> RLS -> privilegios -> semilla.
-- Los roles son NOLOGIN: la contraseña y el LOGIN se asignan fuera del
-- repositorio (ver README, sección "Roles y seguridad").
-- =====================================================================

SET check_function_bodies = false;
SET client_min_messages = warning;

-- ---------------------------------------------------------------------
-- 0. Roles (mínimo privilegio; matriz completa en el README)
-- ---------------------------------------------------------------------
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'rol_admin')   THEN CREATE ROLE rol_admin   NOLOGIN; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ms_envios')   THEN CREATE ROLE ms_envios   NOLOGIN; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ms_eventos')  THEN CREATE ROLE ms_eventos  NOLOGIN; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'rol_lectura') THEN CREATE ROLE rol_lectura NOLOGIN; END IF;
END $$;

-- Nadie crea objetos en public salvo el dueño del esquema.
REVOKE CREATE ON SCHEMA public FROM PUBLIC;

-- ---------------------------------------------------------------------
-- 1. Schemas, funciones, tablas, vistas, índices, triggers, FK
-- ---------------------------------------------------------------------
CREATE SCHEMA catalogo;

COMMENT ON SCHEMA catalogo IS 'Datos de referencia compartidos: puntos de la red, estados, tipos de evento, transiciones y SLA. Dueño: MS-Envíos.';

CREATE SCHEMA envios;

COMMENT ON SCHEMA envios IS 'Ciclo de vida del envío: alta, partes, paquetes y estado vigente. Dueño: MS-Envíos.';

CREATE SCHEMA eventos;

COMMENT ON SCHEMA eventos IS 'Historial logístico inmutable y vistas de reporte. Dueño: MS-Eventos.';

CREATE FUNCTION catalogo.estado_inicial() RETURNS text
    LANGUAGE sql STABLE
    AS $$
  select codigo from catalogo.estado_envio where es_inicial;
$$;

COMMENT ON FUNCTION catalogo.estado_inicial() IS 'Estado con el que nace un envío. Usada como DEFAULT en envios.envio.';

CREATE FUNCTION catalogo.registrar_operador(p_codigo text, p_nombre text DEFAULT NULL::text) RETURNS text
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'catalogo', 'pg_temp'
    AS $$
begin
  insert into catalogo.operador (codigo, nombre)
  values (p_codigo, p_nombre)
  on conflict (codigo) do update
    set nombre = coalesce(excluded.nombre, catalogo.operador.nombre);
  return p_codigo;
end
$$;

COMMENT ON FUNCTION catalogo.registrar_operador(p_codigo text, p_nombre text) IS 'Alta idempotente del operador que viene en el token. SECURITY DEFINER: presta el permiso de escritura sobre el catálogo sin concedérselo al microservicio.';

CREATE FUNCTION catalogo.sla_horas(p_tipo_servicio text, p_momento timestamp with time zone DEFAULT now()) RETURNS integer
    LANGUAGE sql STABLE
    AS $$
  select s.horas_max
    from catalogo.sla_servicio s
   where s.tipo_servicio = p_tipo_servicio
     and s.vigente_desde <= (p_momento at time zone 'America/Bogota')::date
   order by s.vigente_desde desc
   limit 1;
$$;

COMMENT ON FUNCTION catalogo.sla_horas(p_tipo_servicio text, p_momento timestamp with time zone) IS 'SLA vigente para un servicio en un momento dado. La zona horaria es la de la operación: una vigencia que arranca el día 1 arranca a medianoche en Colombia, no en UTC.';

CREATE FUNCTION catalogo.verificar_rls() RETURNS TABLE(schema_tabla text, problema text)
    LANGUAGE sql STABLE
    AS $$
  select format('%s.%s', n.nspname, c.relname)::text,
         case when not c.relrowsecurity then 'RLS desactivado'
              else 'RLS activo pero sin ninguna política' end
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
   where c.relkind = 'r'
     and n.nspname in ('catalogo','envios','eventos')
     and (not c.relrowsecurity
          or not exists (select 1 from pg_policy p where p.polrelid = c.oid))
   union all
  select format('%s.%s', table_schema, table_name)::text,
         format('privilegio %s concedido a PUBLIC', privilege_type)::text
    from information_schema.role_table_grants
   where table_schema in ('catalogo','envios','eventos')
     and grantee = 'PUBLIC';
$$;

COMMENT ON FUNCTION catalogo.verificar_rls() IS 'Devuelve cero filas si toda tabla de los tres schemas tiene RLS con política y nada quedó abierto a PUBLIC. Cualquier fila es un agujero de seguridad por corregir.';

CREATE FUNCTION catalogo.verificar_transicion() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
begin
  if exists (select 1 from catalogo.estado_envio
              where codigo = new.estado_destino and es_inicial) then
    raise exception 'El estado inicial % no puede ser destino de una transición', new.estado_destino
      using errcode = '23514';
  end if;
  if exists (select 1 from catalogo.estado_envio
              where codigo = new.estado_origen and es_final) then
    raise exception 'El estado final % no admite transiciones de salida', new.estado_origen
      using errcode = '23514';
  end if;
  return new;
end
$$;

CREATE FUNCTION envios.digito_verificador(p_base text) RETURNS text
    LANGUAGE sql IMMUTABLE STRICT
    AS $$
  select lpad(((98 - (p_base::numeric % 97))::int)::text, 2, '0');
$$;

CREATE FUNCTION envios.fijar_sla() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
begin
  if new.horas_sla is null then
    new.horas_sla := catalogo.sla_horas(new.tipo_servicio, new.registrado_en);
  end if;
  if new.horas_sla is null then
    raise exception 'El servicio % no tiene SLA vigente al %', new.tipo_servicio, new.registrado_en
      using errcode = '23502',
            hint    = 'Insertar la vigencia en catalogo.sla_servicio antes de vender el servicio.';
  end if;
  return new;
end
$$;

CREATE FUNCTION envios.gen_tracking_number() RETURNS text
    LANGUAGE sql
    AS $$
  select 'FDX' || base || envios.digito_verificador(base)
  from (
    select lpad(envios.mezclar_secuencia(nextval('envios.tracking_seq'))::text, 10, '0') as base
  ) s;
$$;

COMMENT ON FUNCTION envios.gen_tracking_number() IS 'Número único y no correlativo. La unicidad la da la secuencia; la mezcla de Feistel es biyectiva, así que no la pierde.';

CREATE FUNCTION envios.mezclar_secuencia(p_n bigint) RETURNS bigint
    LANGUAGE plpgsql IMMUTABLE STRICT
    AS $$
declare
  l int := (p_n / 100000)::int;   -- mitad alta, 0..99999
  r int := (p_n % 100000)::int;   -- mitad baja, 0..99999
  t int;
  i int;
begin
  for i in 1..4 loop
    t := r;
    r := (l + (('x' || substr(md5(i::text || ':' || r::text || ':tracking'), 1, 7))::bit(28)::int % 100000)) % 100000;
    l := t;
  end loop;
  return l::bigint * 100000 + r;
end
$$;

COMMENT ON FUNCTION envios.mezclar_secuencia(p_n bigint) IS 'Permutación de los diez dígitos del contador. Sin ella los números serían correlativos y el rastreo público, enumerable.';

CREATE FUNCTION envios.tracking_valido(p_tracking text) RETURNS boolean
    LANGUAGE sql IMMUTABLE
    AS $_$
  select p_tracking ~ '^FDX[0-9]{12}$'
     and substring(p_tracking from 14 for 2)
       = envios.digito_verificador(substring(p_tracking from 4 for 10));
$_$;

COMMENT ON FUNCTION envios.tracking_valido(p_tracking text) IS 'Valida formato y dígito verificador. MS-Eventos la usa para descartar números mal dictados antes de ir a la base (HU-02, HU-03).';

SET default_tablespace = '';

SET default_table_access_method = heap;

CREATE TABLE catalogo.ciudad (
    codigo text NOT NULL,
    nombre text NOT NULL,
    departamento text,
    pais text DEFAULT 'CO'::text NOT NULL,
    activa boolean DEFAULT true NOT NULL,
    CONSTRAINT ciudad_pais_check CHECK ((length(pais) = 2))
);

COMMENT ON TABLE catalogo.ciudad IS 'Ciudades de la red. Normaliza el agrupamiento geográfico de HU-07 y evita duplicados por tildes o mayúsculas.';

COMMENT ON COLUMN catalogo.ciudad.codigo IS 'DIVIPOLA (DANE) en Colombia. Es la llave que usan punto_red y parte.';

CREATE TABLE catalogo.estado_envio (
    codigo text NOT NULL,
    nombre text NOT NULL,
    descripcion text,
    es_inicial boolean DEFAULT false NOT NULL,
    es_final boolean DEFAULT false NOT NULL,
    es_excepcion boolean DEFAULT false NOT NULL,
    resultado text,
    orden smallint,
    CONSTRAINT ck_estado_orden CHECK ((es_excepcion OR (orden IS NOT NULL))),
    CONSTRAINT ck_estado_resultado CHECK (((resultado IS NOT NULL) = es_final)),
    CONSTRAINT estado_envio_check CHECK ((NOT (es_inicial AND es_final))),
    CONSTRAINT estado_envio_resultado_check CHECK ((resultado = ANY (ARRAY['EXITOSO'::text, 'FALLIDO'::text])))
);

COMMENT ON TABLE catalogo.estado_envio IS 'Estados válidos de un envío. `orden` da la barra de progreso del rastreo público (HU-03); es nulo en los estados de excepción, que no están sobre esa línea.';

COMMENT ON COLUMN catalogo.estado_envio.es_excepcion IS 'TRUE en retenido, devolución, extravío y anulación: el envío se salió del camino esperado.';

COMMENT ON COLUMN catalogo.estado_envio.resultado IS 'Solo en estados finales. Distingue el cierre exitoso (entregado) del fallido (devuelto, extraviado, anulado), que `es_final` por sí solo confunde.';

CREATE TABLE catalogo.punto_red (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    codigo text NOT NULL,
    nombre text NOT NULL,
    tipo text NOT NULL,
    ciudad_codigo text NOT NULL,
    latitud numeric(9,6),
    longitud numeric(9,6),
    activo boolean DEFAULT true NOT NULL,
    creado_en timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT punto_red_latitud_check CHECK (((latitud >= ('-90'::integer)::numeric) AND (latitud <= (90)::numeric))),
    CONSTRAINT punto_red_longitud_check CHECK (((longitud >= ('-180'::integer)::numeric) AND (longitud <= (180)::numeric))),
    CONSTRAINT punto_red_tipo_check CHECK ((tipo = ANY (ARRAY['CENTRO_DISTRIBUCION'::text, 'PUNTO_VENTA'::text, 'VEHICULO'::text, 'DESTINO'::text])))
);

COMMENT ON TABLE catalogo.punto_red IS 'Puntos físicos por los que pasa un envío. Alimenta HU-02 y el desglose de HU-07.';

COMMENT ON COLUMN catalogo.punto_red.ciudad_codigo IS 'FK a catalogo.ciudad. El país sale de la ciudad, no se repite aquí.';

COMMENT ON COLUMN catalogo.punto_red.latitud IS 'Opcional: el mapa del recorrido está fuera del alcance del sprint, pero la columna evita rehacer la tabla después.';

CREATE TABLE envios.envio (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tracking_number text DEFAULT envios.gen_tracking_number() NOT NULL,
    tipo_servicio text NOT NULL,
    horas_sla integer NOT NULL,
    estado_actual text DEFAULT catalogo.estado_inicial() NOT NULL,
    punto_origen_id uuid NOT NULL,
    punto_destino_id uuid,
    registrado_en timestamp with time zone DEFAULT now() NOT NULL,
    registrado_por text NOT NULL,
    admitido_en timestamp with time zone,
    ultimo_evento_en timestamp with time zone,
    ultimo_punto_id uuid,
    cerrado_en timestamp with time zone,
    entregado_en timestamp with time zone,
    actualizado_en timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ck_envio_cierre CHECK (((entregado_en IS NULL) OR (cerrado_en IS NOT NULL))),
    CONSTRAINT ck_envio_tracking_valido CHECK (envios.tracking_valido(tracking_number)),
    CONSTRAINT envio_horas_sla_check CHECK ((horas_sla > 0))
);

COMMENT ON TABLE envios.envio IS 'Un envío registrado en la red. Fuente única de trazabilidad (objetivo 1 del proyecto).';

COMMENT ON COLUMN envios.envio.horas_sla IS 'SLA congelado en el momento del alta. Sin esta copia, subir el SLA hoy convertiría en cumplidos los envíos que ayer llegaron tarde: el reporte de HU-05/HU-06 cambiaría el pasado.';

COMMENT ON COLUMN envios.envio.punto_destino_id IS 'Centro de destino previsto. La dirección de entrega real vive en envios.parte, rol DESTINATARIO.';

COMMENT ON COLUMN envios.envio.registrado_por IS 'Operador que dio el alta, tomado del token por el microservicio (NFR-04).';

COMMENT ON COLUMN envios.envio.admitido_en IS 'Primer evento del envío: la entrada real a la red. El reloj del SLA arranca aquí y no en `registrado_en`, porque un envío dado de alta a las 5 p.m. en el mostrador no está en tránsito hasta que alguien lo recoge.';

COMMENT ON COLUMN envios.envio.ultimo_evento_en IS 'Caché del último movimiento, mantenido por el trigger trg_evento_aplicar_estado. Permite que HU-03 responda estado + punto + fecha en una sola lectura (NFR-09).';

COMMENT ON COLUMN envios.envio.cerrado_en IS 'Momento en que el envío llegó a un estado final, terminara como terminara. `entregado_en` solo se llena si ese final fue exitoso.';

CREATE VIEW envios.v_envio_publico WITH (security_invoker='false') AS
 SELECT e.tracking_number,
    e.estado_actual AS estado_codigo,
    est.nombre AS estado_nombre,
    est.orden AS estado_orden,
    est.es_final AS cerrado,
    est.es_excepcion AS en_excepcion,
    est.resultado,
    COALESCE((est.resultado = 'EXITOSO'::text), false) AS entregado,
    e.registrado_en,
    e.admitido_en,
    e.ultimo_evento_en,
        CASE
            WHEN (p.tipo = 'VEHICULO'::text) THEN NULL::text
            ELSE p.nombre
        END AS ultimo_punto,
    c.nombre AS ultimo_punto_ciudad,
    (e.ultimo_evento_en IS NULL) AS sin_movimientos,
    ( SELECT count(*) AS count
           FROM catalogo.estado_envio x
          WHERE ((x.orden IS NOT NULL) AND (NOT x.es_inicial))) AS etapas_totales
   FROM (((envios.envio e
     JOIN catalogo.estado_envio est ON ((est.codigo = e.estado_actual)))
     LEFT JOIN catalogo.punto_red p ON ((p.id = e.ultimo_punto_id)))
     LEFT JOIN catalogo.ciudad c ON ((c.codigo = p.ciudad_codigo)));

COMMENT ON VIEW envios.v_envio_publico IS 'HU-03. `sin_movimientos` distingue el envío recién registrado del que ya circuló, que es el segundo escenario de la historia. `etapas_totales` cuenta solo los estados del camino feliz: los de excepción no están sobre la barra de progreso.';

CREATE FUNCTION envios.rastrear(p_tracking text, p_verificacion text) RETURNS SETOF envios.v_envio_publico
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'envios', 'catalogo', 'pg_temp'
    AS $$
  select v.*
    from envios.v_envio_publico v
    join envios.envio e on e.tracking_number = v.tracking_number
    join envios.parte d on d.envio_id = e.id and d.rol = 'DESTINATARIO'
   where v.tracking_number = p_tracking
     and length(coalesce(p_verificacion, '')) = 4
     and (
          right(regexp_replace(d.telefono,  '\D', '', 'g'), 4) = p_verificacion
       or right(regexp_replace(coalesce(d.documento, ''), '\D', '', 'g'), 4) = p_verificacion
     );
$$;

COMMENT ON FUNCTION envios.rastrear(p_tracking text, p_verificacion text) IS 'HU-03 con segundo factor: número + últimos 4 dígitos del teléfono o documento del destinatario. Devuelve cero filas si no coinciden, sin decir cuál de los dos falló.';

CREATE FUNCTION envios.sellar_actualizacion() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
begin
  new.actualizado_en := now();
  return new;
end
$$;

CREATE FUNCTION envios.verificar_envio_completo() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
declare
  v_partes   int;
  v_paquetes int;
begin
  select count(*) into v_partes   from envios.parte   where envio_id = new.id;
  select count(*) into v_paquetes from envios.paquete where envio_id = new.id;
  if v_partes <> 2 then
    raise exception 'El envío % requiere remitente y destinatario (encontrados: %)', new.tracking_number, v_partes
      using errcode = '23514';
  end if;
  if v_paquetes < 1 then
    raise exception 'El envío % requiere al menos un paquete', new.tracking_number
      using errcode = '23514';
  end if;
  return null;
end
$$;

CREATE FUNCTION eventos.aplicar_estado_envio() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'catalogo', 'envios', 'eventos', 'pg_temp'
    AS $$
declare
  v_destino catalogo.estado_envio%rowtype;
begin
  select * into v_destino from catalogo.estado_envio where codigo = new.estado_resultante;
  update envios.envio
     set estado_actual    = v_destino.codigo,
         ultimo_evento_en = new.ocurrido_en,
         ultimo_punto_id  = new.punto_red_id,
         admitido_en      = coalesce(admitido_en, new.ocurrido_en),
         cerrado_en       = case when v_destino.es_final then new.ocurrido_en else cerrado_en end,
         entregado_en     = case when v_destino.resultado = 'EXITOSO' then new.ocurrido_en else entregado_en end
   where id = new.envio_id;
  return null;
end
$$;

COMMENT ON FUNCTION eventos.aplicar_estado_envio() IS 'Propaga el evento al estado del envío en la misma transacción. SECURITY DEFINER: el permiso de UPDATE sobre envios.envio lo aporta la función, no el rol ms_eventos.';

CREATE FUNCTION eventos.bloquear_modificacion() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
begin
  raise exception 'El historial de eventos es de solo inserción (NFR-06): operación % no permitida', tg_op
    using errcode = '0A000',
          hint    = 'Para corregir un evento se registra un evento de ajuste; la corrección directa está fuera del alcance del sprint (HU-10).';
end
$$;

CREATE FUNCTION eventos.refrescar_reportes() RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'eventos', 'envios', 'catalogo', 'pg_temp'
    AS $$
begin
  refresh materialized view concurrently eventos.mv_volumen_registro;
  refresh materialized view concurrently eventos.mv_volumen_movimiento;
end
$$;

COMMENT ON FUNCTION eventos.refrescar_reportes() IS 'Refresca el volumen de HU-07. CONCURRENTLY: los reportes se pueden seguir leyendo mientras corre. Programar cada hora (pg_cron) o al cierre del día, según lo que el negocio acepte de retraso.';

CREATE FUNCTION eventos.validar_evento() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'catalogo', 'envios', 'eventos', 'pg_temp'
    AS $$
declare
  v_tipo    catalogo.tipo_evento%rowtype;
  v_envio   envios.envio%rowtype;
  v_actual  catalogo.estado_envio%rowtype;
  v_destino catalogo.estado_envio%rowtype;
begin
  select * into v_tipo from catalogo.tipo_evento where codigo = new.tipo_evento;
  if not found then
    raise exception 'No existe el tipo de evento %', new.tipo_evento using errcode = '23503';
  end if;
  select * into v_envio from envios.envio where id = new.envio_id for update;
  if not found then
    raise exception 'No existe un envío con id %', new.envio_id using errcode = '23503';
  end if;
  new.tracking_number := v_envio.tracking_number;
  if v_tipo.requiere_receptor and coalesce(btrim(new.recibido_por), '') = '' then
    raise exception 'El evento % exige constancia de quién recibió', new.tipo_evento
      using errcode = '23514';
  end if;
  if v_tipo.requiere_observaciones and coalesce(btrim(new.observaciones), '') = '' then
    raise exception 'El evento % exige una observación que explique el motivo', new.tipo_evento
      using errcode = '23514';
  end if;
  if v_envio.ultimo_evento_en is not null and new.ocurrido_en < v_envio.ultimo_evento_en then
    raise exception 'El evento ocurre antes del último movimiento del envío % (% < %)',
      v_envio.tracking_number, new.ocurrido_en, v_envio.ultimo_evento_en
      using errcode = '22007',
            hint    = 'El historial se registra en orden cronológico. Regla provisional: pendiente de confirmar con el cliente si se admiten eventos con fecha retroactiva.';
  end if;
  if not exists (
    select 1 from catalogo.punto_red p where p.id = new.punto_red_id and p.activo
  ) then
    raise exception 'El punto de la red % no está activo', new.punto_red_id
      using errcode = '23514';
  end if;
  select * into v_actual from catalogo.estado_envio where codigo = v_envio.estado_actual;
  if v_actual.es_final then
    raise exception 'El envío % ya está en estado final (%) y no admite más eventos',
      v_envio.tracking_number, v_envio.estado_actual
      using errcode = '23514';
  end if;
  select d.* into v_destino
    from catalogo.transicion_valida t
    join catalogo.estado_envio d on d.codigo = t.estado_destino
   where t.estado_origen = v_envio.estado_actual
     and t.tipo_evento   = new.tipo_evento;
  if not found then
    raise exception 'Transición no permitida: un envío en estado % no admite el evento %',
      v_envio.estado_actual, new.tipo_evento
      using errcode = '23514',
            hint    = 'Las transiciones legales se consultan en catalogo.transicion_valida. Un evento por sentencia: en un INSERT de varias filas los triggers AFTER corren al final y la segunda fila se validaría contra el estado anterior.';
  end if;
  new.estado_resultante := v_destino.codigo;
  new.cierra_envio      := v_destino.es_final;
  return new;
end
$$;

COMMENT ON FUNCTION eventos.validar_evento() IS 'SECURITY DEFINER: MS-Eventos no tiene permiso directo sobre envios.envio, pero necesita leerlo y bloquearlo para validar. El permiso lo presta la función, con search_path fijo.';

CREATE TABLE catalogo.operador (
    codigo text NOT NULL,
    nombre text,
    activo boolean DEFAULT true NOT NULL,
    creado_en timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT operador_codigo_check CHECK ((length(btrim(codigo)) > 0))
);

COMMENT ON TABLE catalogo.operador IS 'Directorio mínimo de quienes registran envíos y eventos (NFR-04). No reemplaza al proveedor de identidad: guarda lo justo para auditar y unir.';

COMMENT ON COLUMN catalogo.operador.codigo IS 'Subject del token (claim `sub`). Estable aunque cambie el correo de la persona.';

CREATE TABLE catalogo.sla_servicio (
    tipo_servicio text NOT NULL,
    vigente_desde date DEFAULT CURRENT_DATE NOT NULL,
    horas_max integer NOT NULL,
    CONSTRAINT sla_servicio_horas_max_check CHECK ((horas_max > 0))
);

COMMENT ON TABLE catalogo.sla_servicio IS 'Horas máximas esperadas en la red, por servicio y por vigencia. Cambiar el SLA de hoy no reescribe el juicio sobre los envíos de ayer: cada envío se lleva su copia (envios.envio.horas_sla).';

CREATE TABLE catalogo.tipo_evento (
    codigo text NOT NULL,
    nombre text NOT NULL,
    descripcion text,
    requiere_receptor boolean DEFAULT false NOT NULL,
    requiere_observaciones boolean DEFAULT false NOT NULL,
    visible_cliente boolean DEFAULT true NOT NULL,
    orden smallint DEFAULT 0 NOT NULL
);

COMMENT ON COLUMN catalogo.tipo_evento.requiere_receptor IS 'TRUE en la entrega: obliga a registrar quién recibió (HU-02).';

COMMENT ON COLUMN catalogo.tipo_evento.requiere_observaciones IS 'TRUE en los eventos de excepción: un intento fallido sin motivo escrito no sirve para nada.';

COMMENT ON COLUMN catalogo.tipo_evento.visible_cliente IS 'FALSE en eventos internos que no se muestran en el historial público (HU-04).';

CREATE TABLE catalogo.tipo_servicio (
    codigo text NOT NULL,
    nombre text NOT NULL,
    descripcion text,
    activo boolean DEFAULT true NOT NULL
);

COMMENT ON TABLE catalogo.tipo_servicio IS 'Servicios comerciales que se pueden vender. Es lo que referencia envios.envio.';

CREATE TABLE catalogo.transicion_valida (
    estado_origen text NOT NULL,
    tipo_evento text NOT NULL,
    estado_destino text NOT NULL
);

COMMENT ON TABLE catalogo.transicion_valida IS 'Máquina de estados de la operación, como terna completa. Editarla cambia las reglas sin desplegar código.';

COMMENT ON COLUMN catalogo.transicion_valida.estado_destino IS 'A dónde queda el envío. Depende del origen, no solo del evento: el mismo INTENTO_FALLIDO reintenta o abre devolución según de dónde venga.';

CREATE TABLE envios.paquete (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    envio_id uuid NOT NULL,
    consecutivo smallint NOT NULL,
    peso_kg numeric(8,3) NOT NULL,
    alto_cm numeric(7,2),
    ancho_cm numeric(7,2),
    largo_cm numeric(7,2),
    contenido text NOT NULL,
    valor_declarado numeric(14,2),
    CONSTRAINT paquete_alto_cm_check CHECK ((alto_cm > (0)::numeric)),
    CONSTRAINT paquete_ancho_cm_check CHECK ((ancho_cm > (0)::numeric)),
    CONSTRAINT paquete_consecutivo_check CHECK ((consecutivo > 0)),
    CONSTRAINT paquete_largo_cm_check CHECK ((largo_cm > (0)::numeric)),
    CONSTRAINT paquete_peso_kg_check CHECK ((peso_kg > (0)::numeric)),
    CONSTRAINT paquete_valor_declarado_check CHECK ((valor_declarado >= (0)::numeric))
);

COMMENT ON TABLE envios.paquete IS 'Bultos que componen el envío. La cotización y el cobro están fuera de alcance: `valor_declarado` es solo descriptivo.';

CREATE TABLE envios.parte (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    envio_id uuid NOT NULL,
    rol text NOT NULL,
    nombre text NOT NULL,
    tipo_documento text,
    documento text,
    telefono text NOT NULL,
    email text,
    direccion text NOT NULL,
    ciudad_codigo text NOT NULL,
    CONSTRAINT ck_parte_documento CHECK (((tipo_documento IS NULL) = (documento IS NULL))),
    CONSTRAINT parte_direccion_check CHECK ((length(btrim(direccion)) > 0)),
    CONSTRAINT parte_email_check CHECK (((email IS NULL) OR (email ~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'::text))),
    CONSTRAINT parte_nombre_check CHECK ((length(btrim(nombre)) > 0)),
    CONSTRAINT parte_rol_check CHECK ((rol = ANY (ARRAY['REMITENTE'::text, 'DESTINATARIO'::text]))),
    CONSTRAINT parte_telefono_check CHECK ((length(btrim(telefono)) > 0)),
    CONSTRAINT parte_tipo_documento_check CHECK ((tipo_documento = ANY (ARRAY['CC'::text, 'CE'::text, 'NIT'::text, 'PAS'::text])))
);

COMMENT ON TABLE envios.parte IS 'Remitente y destinatario. Los NOT NULL son la lista de datos obligatorios de HU-01: al faltar uno la transacción falla y el envío no queda registrado.';

CREATE SEQUENCE envios.tracking_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    MAXVALUE 9999999999
    CACHE 1;

CREATE TABLE eventos.evento (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    secuencia bigint NOT NULL,
    envio_id uuid NOT NULL,
    tracking_number text NOT NULL,
    tipo_evento text NOT NULL,
    estado_resultante text NOT NULL,
    cierra_envio boolean DEFAULT false NOT NULL,
    punto_red_id uuid NOT NULL,
    ocurrido_en timestamp with time zone DEFAULT now() NOT NULL,
    registrado_en timestamp with time zone DEFAULT now() NOT NULL,
    registrado_por text NOT NULL,
    recibido_por text,
    observaciones text,
    clave_idempotencia text,
    CONSTRAINT ck_evento_no_futuro CHECK ((ocurrido_en <= (registrado_en + '00:05:00'::interval)))
);

COMMENT ON TABLE eventos.evento IS 'Cada paso del envío por un punto de la red. Append-only: el estado de un envío es el resultado de reproducir sus eventos.';

COMMENT ON COLUMN eventos.evento.secuencia IS 'Orden de llegada al sistema. Desempata dos eventos con el mismo `ocurrido_en`.';

COMMENT ON COLUMN eventos.evento.envio_id IS 'FK contra envios.envio. Es lo que hace que un evento sobre un número inexistente no se registre (HU-02, escenario 3) sin depender de una consulta previa del servicio.';

COMMENT ON COLUMN eventos.evento.tracking_number IS 'Denormalizado a propósito: MS-Eventos resuelve la consulta por número sin cruzar al schema del otro servicio. Lo mantiene sincronizado el trigger trg_evento_validar.';

COMMENT ON COLUMN eventos.evento.estado_resultante IS 'Estado en que quedó el envío por este evento, resuelto contra catalogo.transicion_valida y guardado aquí. El historial queda legible aunque mañana cambien las reglas: dice lo que pasó, no lo que hoy pasaría.';

COMMENT ON COLUMN eventos.evento.cierra_envio IS 'TRUE si el estado resultante es final. Permite el índice único de cierre sin cablear el código del evento de entrega.';

COMMENT ON COLUMN eventos.evento.ocurrido_en IS 'Momento real del hecho en el punto. Distinto de `registrado_en`, que es cuando el operador lo capturó (NFR-04).';

COMMENT ON COLUMN eventos.evento.clave_idempotencia IS 'Clave que manda el cliente (escáner, app móvil) para que un reintento no registre el mismo hecho dos veces. Un reintento devuelve unique_violation (23505) y MS-Eventos debe tratarlo como éxito, no como error.';

ALTER TABLE eventos.evento ALTER COLUMN secuencia ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME eventos.evento_secuencia_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);

CREATE MATERIALIZED VIEW eventos.mv_volumen_movimiento AS
 SELECT (date_trunc('day'::text, ev.ocurrido_en))::date AS dia,
    pr.codigo AS punto_codigo,
    pr.nombre AS punto,
    ci.nombre AS ciudad,
    count(*) AS eventos,
    count(DISTINCT ev.envio_id) AS envios_distintos
   FROM ((eventos.evento ev
     JOIN catalogo.punto_red pr ON ((pr.id = ev.punto_red_id)))
     JOIN catalogo.ciudad ci ON ((ci.codigo = pr.ciudad_codigo)))
  GROUP BY ((date_trunc('day'::text, ev.ocurrido_en))::date), pr.codigo, pr.nombre, ci.nombre
  WITH NO DATA;

CREATE MATERIALIZED VIEW eventos.mv_volumen_registro AS
 SELECT (date_trunc('day'::text, e.registrado_en))::date AS dia,
    pr.codigo AS punto_codigo,
    pr.nombre AS punto,
    ci.nombre AS ciudad,
    count(*) AS envios_registrados
   FROM ((envios.envio e
     JOIN catalogo.punto_red pr ON ((pr.id = e.punto_origen_id)))
     JOIN catalogo.ciudad ci ON ((ci.codigo = pr.ciudad_codigo)))
  GROUP BY ((date_trunc('day'::text, e.registrado_en))::date), pr.codigo, pr.nombre, ci.nombre
  WITH NO DATA;

CREATE VIEW eventos.v_envio_incoherente WITH (security_invoker='false') AS
 WITH ultimo AS (
         SELECT DISTINCT ON (ev.envio_id) ev.envio_id,
            ev.estado_resultante,
            ev.ocurrido_en,
            ev.punto_red_id
           FROM eventos.evento ev
          ORDER BY ev.envio_id, ev.ocurrido_en DESC, ev.secuencia DESC
        ), primero AS (
         SELECT ev.envio_id,
            min(ev.ocurrido_en) AS admitido_en
           FROM eventos.evento ev
          GROUP BY ev.envio_id
        )
 SELECT e.tracking_number,
    e.estado_actual,
    u.estado_resultante AS estado_segun_eventos,
    e.ultimo_evento_en,
    u.ocurrido_en AS ultimo_evento_segun_eventos,
    e.admitido_en,
    p.admitido_en AS admitido_segun_eventos
   FROM ((envios.envio e
     LEFT JOIN ultimo u ON ((u.envio_id = e.id)))
     LEFT JOIN primero p ON ((p.envio_id = e.id)))
  WHERE ((u.envio_id IS NOT NULL) AND ((e.estado_actual IS DISTINCT FROM u.estado_resultante) OR (e.ultimo_evento_en IS DISTINCT FROM u.ocurrido_en) OR (e.ultimo_punto_id IS DISTINCT FROM u.punto_red_id) OR (e.admitido_en IS DISTINCT FROM p.admitido_en)));

COMMENT ON VIEW eventos.v_envio_incoherente IS 'Detector de deriva entre el caché de envios.envio y el historial. Cero filas es el estado sano; se comprueba en las pruebas y conviene monitorearla.';

CREATE VIEW eventos.v_envio_referencia WITH (security_invoker='false') AS
 SELECT e.id AS envio_id,
    e.tracking_number,
    e.tipo_servicio,
    e.horas_sla,
    e.estado_actual,
    est.nombre AS estado_nombre,
    est.es_final AS cerrado,
    est.resultado,
    e.registrado_en,
    e.admitido_en,
    e.ultimo_evento_en,
    e.ultimo_punto_id,
    e.cerrado_en
   FROM (envios.envio e
     JOIN catalogo.estado_envio est ON ((est.codigo = e.estado_actual)));

COMMENT ON VIEW eventos.v_envio_referencia IS 'Única puerta de MS-Eventos hacia los datos de MS-Envíos. Al partir las bases, esta vista se reemplaza por una llamada HTTP sin tocar el resto del esquema.';

CREATE VIEW eventos.v_envio_retrasado WITH (security_invoker='false') AS
 SELECT e.tracking_number,
    e.estado_actual,
    est.nombre AS estado,
    est.es_excepcion AS en_excepcion,
    e.tipo_servicio,
    e.registrado_en,
    e.admitido_en,
    e.ultimo_evento_en,
    pr.codigo AS punto_actual,
    pr.nombre AS punto_actual_nombre,
    ci.nombre AS punto_actual_ciudad,
    e.horas_sla AS horas_esperadas,
    round((EXTRACT(epoch FROM (now() - COALESCE(e.admitido_en, e.registrado_en))) / 3600.0), 2) AS horas_en_red,
    round(((EXTRACT(epoch FROM (now() - COALESCE(e.admitido_en, e.registrado_en))) / 3600.0) - (e.horas_sla)::numeric), 2) AS horas_de_exceso,
    round((EXTRACT(epoch FROM (now() - COALESCE(e.ultimo_evento_en, e.registrado_en))) / 3600.0), 2) AS horas_sin_moverse
   FROM (((envios.envio e
     JOIN catalogo.estado_envio est ON ((est.codigo = e.estado_actual)))
     LEFT JOIN catalogo.punto_red pr ON ((pr.id = e.ultimo_punto_id)))
     LEFT JOIN catalogo.ciudad ci ON ((ci.codigo = pr.ciudad_codigo)))
  WHERE ((e.cerrado_en IS NULL) AND ((now() - COALESCE(e.admitido_en, e.registrado_en)) > make_interval(hours => e.horas_sla)));

COMMENT ON VIEW eventos.v_envio_retrasado IS 'HU-06. Solo retrasos activos: el envío ya cerrado tarde se mide en v_tiempo_transito_envio.fuera_de_sla. `horas_sin_moverse` cubre el escenario del envío detenido en un punto, y `en_excepcion` distingue el que está retenido o en devolución del que simplemente va lento.';

CREATE VIEW eventos.v_historial_envio WITH (security_invoker='false') AS
 SELECT ev.envio_id,
    ev.tracking_number,
    ev.secuencia,
    ev.ocurrido_en,
    te.codigo AS tipo_evento,
    te.nombre AS evento,
    ev.estado_resultante AS estado_codigo,
    est.nombre AS estado,
    est.es_excepcion AS estado_excepcion,
    pr.codigo AS punto_codigo,
    pr.nombre AS punto,
    ci.nombre AS punto_ciudad,
    te.visible_cliente,
    ev.recibido_por,
    ev.observaciones
   FROM ((((eventos.evento ev
     JOIN catalogo.tipo_evento te ON ((te.codigo = ev.tipo_evento)))
     JOIN catalogo.estado_envio est ON ((est.codigo = ev.estado_resultante)))
     JOIN catalogo.punto_red pr ON ((pr.id = ev.punto_red_id)))
     JOIN catalogo.ciudad ci ON ((ci.codigo = pr.ciudad_codigo)))
  ORDER BY ev.envio_id, ev.ocurrido_en, ev.secuencia;

COMMENT ON VIEW eventos.v_historial_envio IS 'HU-04. Filtrar por visible_cliente = true para la vista pública; sin filtrar, es el historial interno de la operación.';

CREATE VIEW eventos.v_tiempo_transito_envio WITH (security_invoker='false') AS
 SELECT tracking_number,
    tipo_servicio,
    registrado_en,
    admitido_en,
    entregado_en,
    round((EXTRACT(epoch FROM (admitido_en - registrado_en)) / 3600.0), 2) AS horas_mostrador,
    round((EXTRACT(epoch FROM (entregado_en - admitido_en)) / 3600.0), 2) AS horas_en_red,
    round((EXTRACT(epoch FROM (entregado_en - registrado_en)) / 3600.0), 2) AS horas_totales,
    horas_sla,
    ((EXTRACT(epoch FROM (entregado_en - admitido_en)) / 3600.0) > (horas_sla)::numeric) AS fuera_de_sla
   FROM envios.envio e
  WHERE ((entregado_en IS NOT NULL) AND (admitido_en IS NOT NULL));

COMMENT ON VIEW eventos.v_tiempo_transito_envio IS 'HU-05, tiempo de cada envío entregado contra el SLA que tenía al registrarse. `horas_mostrador` separa la espera previa a la admisión del tiempo de transporte.';

CREATE VIEW eventos.v_tramo WITH (security_invoker='false') AS
 SELECT ev.envio_id,
    ev.tracking_number,
    lag(pr.codigo) OVER w AS punto_origen,
    pr.codigo AS punto_destino,
    lag(ev.ocurrido_en) OVER w AS salida_en,
    ev.ocurrido_en AS llegada_en,
    (EXTRACT(epoch FROM (ev.ocurrido_en - lag(ev.ocurrido_en) OVER w)) / 3600.0) AS horas,
        CASE
            WHEN (lag(pr.codigo) OVER w IS NULL) THEN NULL::text
            WHEN (lag(pr.codigo) OVER w = pr.codigo) THEN 'PERMANENCIA'::text
            ELSE 'TRANSITO'::text
        END AS tipo_tramo
   FROM (eventos.evento ev
     JOIN catalogo.punto_red pr ON ((pr.id = ev.punto_red_id)))
  WINDOW w AS (PARTITION BY ev.envio_id ORDER BY ev.ocurrido_en, ev.secuencia);

COMMENT ON VIEW eventos.v_tramo IS 'Un renglón por salto entre dos eventos consecutivos. TRANSITO = tiempo entre dos puntos distintos; PERMANENCIA = tiempo que el envío estuvo detenido en el mismo punto. Distinguirlos es lo que responde "en qué tramos se pierde tiempo" (HU-05). La primera fila de cada envío tiene punto_origen nulo y se descarta en los agregados.';

CREATE VIEW eventos.v_tiempo_transito_tramo WITH (security_invoker='false') AS
 SELECT t.tipo_tramo,
    t.punto_origen,
    t.punto_destino,
    count(*) AS envios,
    round(avg(t.horas), 2) AS horas_promedio,
    round(min(t.horas), 2) AS horas_min,
    round(max(t.horas), 2) AS horas_max,
    round((percentile_cont((0.5)::double precision) WITHIN GROUP (ORDER BY ((t.horas)::double precision)))::numeric, 2) AS horas_mediana
   FROM (eventos.v_tramo t
     JOIN envios.envio e ON ((e.id = t.envio_id)))
  WHERE ((t.punto_origen IS NOT NULL) AND (e.entregado_en IS NOT NULL))
  GROUP BY t.tipo_tramo, t.punto_origen, t.punto_destino;

COMMENT ON VIEW eventos.v_tiempo_transito_tramo IS 'HU-05, tiempo promedio por tramo. Considera únicamente envíos entregados; los que siguen en tránsito, o los que terminaron devueltos, distorsionarían el promedio.';

CREATE VIEW eventos.v_volumen_movimiento WITH (security_invoker='false') AS
 SELECT dia,
    punto_codigo,
    punto,
    ciudad,
    eventos,
    envios_distintos
   FROM eventos.mv_volumen_movimiento;

COMMENT ON VIEW eventos.v_volumen_movimiento IS 'HU-07, carga real de trabajo de cada punto: cuántos envíos pasaron por él.';

CREATE VIEW eventos.v_volumen_registro WITH (security_invoker='false') AS
 SELECT dia,
    punto_codigo,
    punto,
    ciudad,
    envios_registrados
   FROM eventos.mv_volumen_registro;

COMMENT ON VIEW eventos.v_volumen_registro IS 'HU-07, volumen dado de alta por punto de origen y día. Lee la vista materializada; la frescura es la del último refresco.';

ALTER TABLE ONLY catalogo.ciudad
    ADD CONSTRAINT ciudad_pkey PRIMARY KEY (codigo);

ALTER TABLE ONLY catalogo.estado_envio
    ADD CONSTRAINT estado_envio_pkey PRIMARY KEY (codigo);

ALTER TABLE ONLY catalogo.operador
    ADD CONSTRAINT operador_pkey PRIMARY KEY (codigo);

ALTER TABLE ONLY catalogo.punto_red
    ADD CONSTRAINT punto_red_codigo_key UNIQUE (codigo);

ALTER TABLE ONLY catalogo.punto_red
    ADD CONSTRAINT punto_red_pkey PRIMARY KEY (id);

ALTER TABLE ONLY catalogo.sla_servicio
    ADD CONSTRAINT sla_servicio_pkey PRIMARY KEY (tipo_servicio, vigente_desde);

ALTER TABLE ONLY catalogo.tipo_evento
    ADD CONSTRAINT tipo_evento_pkey PRIMARY KEY (codigo);

ALTER TABLE ONLY catalogo.tipo_servicio
    ADD CONSTRAINT tipo_servicio_pkey PRIMARY KEY (codigo);

ALTER TABLE ONLY catalogo.transicion_valida
    ADD CONSTRAINT transicion_valida_pkey PRIMARY KEY (estado_origen, tipo_evento);

ALTER TABLE ONLY envios.envio
    ADD CONSTRAINT envio_pkey PRIMARY KEY (id);

ALTER TABLE ONLY envios.envio
    ADD CONSTRAINT envio_tracking_number_key UNIQUE (tracking_number);

ALTER TABLE ONLY envios.paquete
    ADD CONSTRAINT paquete_envio_id_consecutivo_key UNIQUE (envio_id, consecutivo);

ALTER TABLE ONLY envios.paquete
    ADD CONSTRAINT paquete_pkey PRIMARY KEY (id);

ALTER TABLE ONLY envios.parte
    ADD CONSTRAINT parte_envio_id_rol_key UNIQUE (envio_id, rol);

ALTER TABLE ONLY envios.parte
    ADD CONSTRAINT parte_pkey PRIMARY KEY (id);

ALTER TABLE ONLY eventos.evento
    ADD CONSTRAINT evento_pkey PRIMARY KEY (id);

CREATE INDEX idx_punto_red_activo ON catalogo.punto_red USING btree (activo) WHERE activo;

CREATE INDEX idx_punto_red_ciudad ON catalogo.punto_red USING btree (ciudad_codigo);

CREATE UNIQUE INDEX uq_ciudad_nombre ON catalogo.ciudad USING btree (pais, lower(nombre));

CREATE UNIQUE INDEX uq_estado_inicial ON catalogo.estado_envio USING btree (es_inicial) WHERE es_inicial;

CREATE UNIQUE INDEX uq_estado_orden ON catalogo.estado_envio USING btree (orden) WHERE (orden IS NOT NULL);

CREATE INDEX idx_envio_destino ON envios.envio USING btree (punto_destino_id);

CREATE INDEX idx_envio_en_red ON envios.envio USING btree (ultimo_evento_en) WHERE (cerrado_en IS NULL);

CREATE INDEX idx_envio_estado ON envios.envio USING btree (estado_actual);

CREATE INDEX idx_envio_operador ON envios.envio USING btree (registrado_por);

CREATE INDEX idx_envio_origen ON envios.envio USING btree (punto_origen_id, registrado_en);

CREATE INDEX idx_envio_registrado_en ON envios.envio USING btree (registrado_en);

CREATE INDEX idx_envio_tipo_servicio ON envios.envio USING btree (tipo_servicio);

CREATE INDEX idx_envio_ultimo_punto ON envios.envio USING btree (ultimo_punto_id);

CREATE INDEX idx_paquete_envio ON envios.paquete USING btree (envio_id);

CREATE INDEX idx_parte_ciudad ON envios.parte USING btree (ciudad_codigo);

CREATE INDEX idx_parte_documento ON envios.parte USING btree (tipo_documento, documento) WHERE (documento IS NOT NULL);

CREATE INDEX idx_parte_envio ON envios.parte USING btree (envio_id);

CREATE INDEX idx_evento_envio ON eventos.evento USING btree (envio_id, ocurrido_en DESC, secuencia DESC);

CREATE INDEX idx_evento_ocurrido_brin ON eventos.evento USING brin (ocurrido_en);

CREATE INDEX idx_evento_operador ON eventos.evento USING btree (registrado_por);

CREATE INDEX idx_evento_punto ON eventos.evento USING btree (punto_red_id, ocurrido_en);

CREATE INDEX idx_evento_tipo ON eventos.evento USING btree (tipo_evento, ocurrido_en);

CREATE INDEX idx_evento_tracking ON eventos.evento USING btree (tracking_number);

CREATE UNIQUE INDEX uq_evento_cierre ON eventos.evento USING btree (envio_id) WHERE cierra_envio;

CREATE UNIQUE INDEX uq_evento_idempotencia ON eventos.evento USING btree (clave_idempotencia) WHERE (clave_idempotencia IS NOT NULL);

CREATE UNIQUE INDEX uq_mv_volumen_movimiento ON eventos.mv_volumen_movimiento USING btree (dia, punto_codigo);

CREATE UNIQUE INDEX uq_mv_volumen_registro ON eventos.mv_volumen_registro USING btree (dia, punto_codigo);

CREATE TRIGGER trg_transicion_coherente BEFORE INSERT OR UPDATE ON catalogo.transicion_valida FOR EACH ROW EXECUTE FUNCTION catalogo.verificar_transicion();

CREATE TRIGGER trg_envio_actualizado BEFORE UPDATE ON envios.envio FOR EACH ROW EXECUTE FUNCTION envios.sellar_actualizacion();

CREATE CONSTRAINT TRIGGER trg_envio_completo AFTER INSERT ON envios.envio DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION envios.verificar_envio_completo();

CREATE TRIGGER trg_envio_sla BEFORE INSERT ON envios.envio FOR EACH ROW EXECUTE FUNCTION envios.fijar_sla();

CREATE TRIGGER trg_evento_aplicar_estado AFTER INSERT ON eventos.evento FOR EACH ROW EXECUTE FUNCTION eventos.aplicar_estado_envio();

CREATE TRIGGER trg_evento_inmutable BEFORE DELETE OR UPDATE ON eventos.evento FOR EACH ROW EXECUTE FUNCTION eventos.bloquear_modificacion();

CREATE TRIGGER trg_evento_validar BEFORE INSERT ON eventos.evento FOR EACH ROW EXECUTE FUNCTION eventos.validar_evento();

ALTER TABLE ONLY catalogo.punto_red
    ADD CONSTRAINT punto_red_ciudad_codigo_fkey FOREIGN KEY (ciudad_codigo) REFERENCES catalogo.ciudad(codigo);

ALTER TABLE ONLY catalogo.sla_servicio
    ADD CONSTRAINT sla_servicio_tipo_servicio_fkey FOREIGN KEY (tipo_servicio) REFERENCES catalogo.tipo_servicio(codigo);

ALTER TABLE ONLY catalogo.transicion_valida
    ADD CONSTRAINT transicion_valida_estado_destino_fkey FOREIGN KEY (estado_destino) REFERENCES catalogo.estado_envio(codigo);

ALTER TABLE ONLY catalogo.transicion_valida
    ADD CONSTRAINT transicion_valida_estado_origen_fkey FOREIGN KEY (estado_origen) REFERENCES catalogo.estado_envio(codigo);

ALTER TABLE ONLY catalogo.transicion_valida
    ADD CONSTRAINT transicion_valida_tipo_evento_fkey FOREIGN KEY (tipo_evento) REFERENCES catalogo.tipo_evento(codigo);

ALTER TABLE ONLY envios.envio
    ADD CONSTRAINT envio_estado_actual_fkey FOREIGN KEY (estado_actual) REFERENCES catalogo.estado_envio(codigo);

ALTER TABLE ONLY envios.envio
    ADD CONSTRAINT envio_punto_destino_id_fkey FOREIGN KEY (punto_destino_id) REFERENCES catalogo.punto_red(id);

ALTER TABLE ONLY envios.envio
    ADD CONSTRAINT envio_punto_origen_id_fkey FOREIGN KEY (punto_origen_id) REFERENCES catalogo.punto_red(id);

ALTER TABLE ONLY envios.envio
    ADD CONSTRAINT envio_registrado_por_fkey FOREIGN KEY (registrado_por) REFERENCES catalogo.operador(codigo);

ALTER TABLE ONLY envios.envio
    ADD CONSTRAINT envio_tipo_servicio_fkey FOREIGN KEY (tipo_servicio) REFERENCES catalogo.tipo_servicio(codigo);

ALTER TABLE ONLY envios.envio
    ADD CONSTRAINT envio_ultimo_punto_id_fkey FOREIGN KEY (ultimo_punto_id) REFERENCES catalogo.punto_red(id);

ALTER TABLE ONLY envios.paquete
    ADD CONSTRAINT paquete_envio_id_fkey FOREIGN KEY (envio_id) REFERENCES envios.envio(id) ON DELETE RESTRICT;

ALTER TABLE ONLY envios.parte
    ADD CONSTRAINT parte_ciudad_codigo_fkey FOREIGN KEY (ciudad_codigo) REFERENCES catalogo.ciudad(codigo);

ALTER TABLE ONLY envios.parte
    ADD CONSTRAINT parte_envio_id_fkey FOREIGN KEY (envio_id) REFERENCES envios.envio(id) ON DELETE RESTRICT;

ALTER TABLE ONLY eventos.evento
    ADD CONSTRAINT evento_envio_id_fkey FOREIGN KEY (envio_id) REFERENCES envios.envio(id) ON DELETE RESTRICT;

ALTER TABLE ONLY eventos.evento
    ADD CONSTRAINT evento_estado_resultante_fkey FOREIGN KEY (estado_resultante) REFERENCES catalogo.estado_envio(codigo);

ALTER TABLE ONLY eventos.evento
    ADD CONSTRAINT evento_punto_red_id_fkey FOREIGN KEY (punto_red_id) REFERENCES catalogo.punto_red(id);

ALTER TABLE ONLY eventos.evento
    ADD CONSTRAINT evento_registrado_por_fkey FOREIGN KEY (registrado_por) REFERENCES catalogo.operador(codigo);

ALTER TABLE ONLY eventos.evento
    ADD CONSTRAINT evento_tipo_evento_fkey FOREIGN KEY (tipo_evento) REFERENCES catalogo.tipo_evento(codigo);

ALTER TABLE catalogo.ciudad ENABLE ROW LEVEL SECURITY;

ALTER TABLE catalogo.estado_envio ENABLE ROW LEVEL SECURITY;

ALTER TABLE catalogo.operador ENABLE ROW LEVEL SECURITY;

CREATE POLICY p_catalogo_escritura ON catalogo.punto_red TO ms_envios USING (true) WITH CHECK (true);

CREATE POLICY p_catalogo_lectura ON catalogo.punto_red FOR SELECT TO ms_envios, ms_eventos USING (true);

CREATE POLICY p_ciudad_escritura ON catalogo.ciudad TO ms_envios USING (true) WITH CHECK (true);

CREATE POLICY p_ciudad_lectura ON catalogo.ciudad FOR SELECT TO ms_envios, ms_eventos USING (true);

CREATE POLICY p_estado_lectura ON catalogo.estado_envio FOR SELECT TO ms_envios, ms_eventos USING (true);

CREATE POLICY p_operador_lectura ON catalogo.operador FOR SELECT TO ms_envios, ms_eventos USING (true);

CREATE POLICY p_servicio_lectura ON catalogo.tipo_servicio FOR SELECT TO ms_envios, ms_eventos USING (true);

CREATE POLICY p_sla_lectura ON catalogo.sla_servicio FOR SELECT TO ms_envios, ms_eventos USING (true);

CREATE POLICY p_tipo_lectura ON catalogo.tipo_evento FOR SELECT TO ms_envios, ms_eventos USING (true);

CREATE POLICY p_transicion_lectura ON catalogo.transicion_valida FOR SELECT TO ms_envios, ms_eventos USING (true);

ALTER TABLE catalogo.punto_red ENABLE ROW LEVEL SECURITY;

ALTER TABLE catalogo.sla_servicio ENABLE ROW LEVEL SECURITY;

ALTER TABLE catalogo.tipo_evento ENABLE ROW LEVEL SECURITY;

ALTER TABLE catalogo.tipo_servicio ENABLE ROW LEVEL SECURITY;

ALTER TABLE catalogo.transicion_valida ENABLE ROW LEVEL SECURITY;

ALTER TABLE envios.envio ENABLE ROW LEVEL SECURITY;

CREATE POLICY p_envio ON envios.envio TO ms_envios USING (true) WITH CHECK (true);

CREATE POLICY p_paquete ON envios.paquete TO ms_envios USING (true) WITH CHECK (true);

CREATE POLICY p_parte ON envios.parte TO ms_envios USING (true) WITH CHECK (true);

ALTER TABLE envios.paquete ENABLE ROW LEVEL SECURITY;

ALTER TABLE envios.parte ENABLE ROW LEVEL SECURITY;

ALTER TABLE eventos.evento ENABLE ROW LEVEL SECURITY;

CREATE POLICY p_evento_escritura ON eventos.evento FOR INSERT TO ms_eventos WITH CHECK (true);

CREATE POLICY p_evento_lectura ON eventos.evento FOR SELECT TO ms_eventos USING (true);


-- ---------------------------------------------------------------------
-- 2. Privilegios (GRANT / REVOKE). RLS ya quedó activado arriba; las
--    políticas p_* limitan además por rol qué filas ve / escribe cada uno.
-- ---------------------------------------------------------------------
REVOKE ALL ON SCHEMA catalogo, envios, eventos FROM PUBLIC;
GRANT USAGE ON SCHEMA catalogo TO ms_envios, ms_eventos;
GRANT USAGE ON SCHEMA envios   TO ms_envios;
GRANT USAGE ON SCHEMA eventos  TO ms_eventos, rol_lectura;

-- rol_admin: administración de datos (catálogos que definen reglas: estados,
-- tipos de evento, transiciones, servicios y SLA; correcciones). Todos los
-- privilegios sobre las tablas, pero el historial sigue inmutable: el trigger
-- trg_evento_inmutable bloquea UPDATE/DELETE también para este rol. Los
-- cambios de esquema (DDL) los hace el dueño de los objetos, no este rol.
GRANT USAGE ON SCHEMA catalogo, envios, eventos TO rol_admin;
GRANT ALL ON ALL TABLES    IN SCHEMA catalogo, envios, eventos TO rol_admin;
GRANT ALL ON ALL SEQUENCES IN SCHEMA catalogo, envios, eventos TO rol_admin;
GRANT EXECUTE ON FUNCTION eventos.refrescar_reportes() TO rol_admin;

-- ms_envios: dueño del ciclo de vida del envío. Catálogos: solo lectura, salvo
-- la red física (punto_red, ciudad). Las reglas del negocio (estados, tipos de
-- evento, transiciones, servicios, SLA) no las puede reescribir un microservicio
-- comprometido; el operador se da de alta por registrar_operador (SECURITY
-- DEFINER). Sin DELETE en ninguna tabla: un envío se anula y un catálogo se
-- desactiva (columna activo).
GRANT SELECT ON ALL TABLES IN SCHEMA catalogo TO ms_envios;
GRANT INSERT, UPDATE ON catalogo.punto_red, catalogo.ciudad TO ms_envios;
GRANT SELECT, INSERT, UPDATE ON envios.envio, envios.parte, envios.paquete TO ms_envios;
GRANT SELECT ON envios.v_envio_publico TO ms_envios;
GRANT USAGE ON SEQUENCE envios.tracking_seq TO ms_envios;  -- DEFAULT gen_tracking_number()

-- ms_eventos: historial append-only. INSERT + SELECT, jamás UPDATE/DELETE.
GRANT SELECT ON ALL TABLES IN SCHEMA catalogo TO ms_eventos;
GRANT SELECT, INSERT ON eventos.evento TO ms_eventos;
GRANT SELECT ON eventos.v_envio_incoherente, eventos.v_envio_referencia,
                eventos.v_envio_retrasado,   eventos.v_historial_envio,
                eventos.v_tiempo_transito_envio, eventos.v_tiempo_transito_tramo,
                eventos.v_tramo, eventos.v_volumen_movimiento,
                eventos.v_volumen_registro TO ms_eventos;

-- rol_lectura (reportes HU-04..HU-07): solo vistas de reporte, ninguna tabla base.
GRANT SELECT ON eventos.v_envio_retrasado, eventos.v_historial_envio,
                eventos.v_tiempo_transito_envio, eventos.v_tiempo_transito_tramo,
                eventos.v_tramo, eventos.v_volumen_movimiento,
                eventos.v_volumen_registro TO rol_lectura;

-- Funciones que los microservicios llaman directamente.
REVOKE ALL ON FUNCTION eventos.refrescar_reportes() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION eventos.refrescar_reportes() TO ms_eventos;
GRANT EXECUTE ON FUNCTION envios.gen_tracking_number() TO ms_envios;
GRANT EXECUTE ON FUNCTION envios.rastrear(text, text)   TO ms_envios;
GRANT EXECUTE ON FUNCTION catalogo.registrar_operador(text, text) TO ms_envios, ms_eventos;

-- RLS: el dueño la omite; rol_admin necesita su propia política en cada tabla.
DO $$
DECLARE t record;
BEGIN
    FOR t IN SELECT schemaname, tablename FROM pg_tables
              WHERE schemaname IN ('catalogo', 'envios', 'eventos')
    LOOP
        EXECUTE format('CREATE POLICY p_admin ON %I.%I TO rol_admin USING (true) WITH CHECK (true)',
                       t.schemaname, t.tablename);
    END LOOP;
END $$;

-- Objetos futuros heredan el mismo criterio.
ALTER DEFAULT PRIVILEGES IN SCHEMA catalogo, envios, eventos GRANT ALL ON TABLES TO rol_admin;
ALTER DEFAULT PRIVILEGES IN SCHEMA catalogo GRANT SELECT ON TABLES TO ms_envios, ms_eventos;
ALTER DEFAULT PRIVILEGES IN SCHEMA eventos  GRANT SELECT ON TABLES TO ms_eventos;

-- ---------------------------------------------------------------------
-- 3. Datos de referencia (catálogos). Sin ellos los triggers rechazan todo.
-- ---------------------------------------------------------------------
INSERT INTO catalogo.ciudad (codigo, nombre, departamento, pais, activa) VALUES
	('05001', 'Medellín', 'Antioquia', 'CO', true),
	('11001', 'Bogotá', 'Bogotá D.C.', 'CO', true),
	('76001', 'Cali', 'Valle del Cauca', 'CO', true),
	('08001', 'Barranquilla', 'Atlántico', 'CO', true);
INSERT INTO catalogo.estado_envio (codigo, nombre, descripcion, es_inicial, es_final, es_excepcion, resultado, orden) VALUES
	('REGISTRADO', 'Registrado', 'El envío fue dado de alta y aún no se ha movido.', true, false, false, NULL, 0),
	('EN_TRANSITO', 'En tránsito', 'El envío circula entre puntos de la red.', false, false, false, NULL, 1),
	('EN_REPARTO', 'En reparto', 'El envío salió hacia la dirección del destinatario.', false, false, false, NULL, 2),
	('ENTREGADO', 'Entregado', 'El envío fue entregado al destinatario.', false, true, false, 'EXITOSO', 3),
	('RETENIDO', 'Retenido', 'Detenido por una causa que impide seguir (aduana, pago, dirección errada).', false, false, true, NULL, NULL),
	('EN_DEVOLUCION', 'En devolución', 'El envío vuelve hacia el remitente.', false, false, true, NULL, NULL),
	('DEVUELTO', 'Devuelto', 'El envío regresó al remitente y se le entregó.', false, true, true, 'FALLIDO', NULL),
	('EXTRAVIADO', 'Extraviado', 'El envío se perdió en la red.', false, true, true, 'FALLIDO', NULL),
	('ANULADO', 'Anulado', 'El envío se canceló antes de completarse.', false, true, true, 'FALLIDO', NULL);
INSERT INTO catalogo.punto_red (id, codigo, nombre, tipo, ciudad_codigo, latitud, longitud, activo, creado_en) VALUES
	('e3421f4c-300f-4fb7-bd2c-d343bb750b7c', 'PV-MED-01', 'Punto de venta Poblado', 'PUNTO_VENTA', '05001', 6.208800, -75.567200, true, '2026-09-08 20:51:12.248701+00'),
	('d10b3237-5d5b-45d7-8710-b42c05bcd977', 'CD-MED', 'Centro de distribución Medellín', 'CENTRO_DISTRIBUCION', '05001', 6.253800, -75.567200, true, '2026-09-08 20:51:12.248701+00'),
	('0bfe05ed-202a-415e-bbc4-d0740dd49441', 'CD-BOG', 'Centro de distribución Bogotá', 'CENTRO_DISTRIBUCION', '11001', 4.710000, -74.072100, true, '2026-09-08 20:51:12.248701+00'),
	('096048c0-bd63-4c3e-bbea-feb71eb75c81', 'CD-CLI', 'Centro de distribución Cali', 'CENTRO_DISTRIBUCION', '76001', 3.451600, -76.531900, true, '2026-09-08 20:51:12.248701+00'),
	('61fee172-c853-457b-9430-b11780bce67e', 'CD-BAQ', 'Centro de distribución Barranquilla', 'CENTRO_DISTRIBUCION', '08001', 10.968500, -74.781300, true, '2026-09-08 20:51:12.248701+00'),
	('54888f38-f020-4999-8028-d1a16c2f45fd', 'VEH-101', 'Vehículo de reparto 101', 'VEHICULO', '11001', NULL, NULL, true, '2026-09-08 20:51:12.248701+00'),
	('53c4e046-551f-45d8-b879-f4a6ef72d4eb', 'VEH-202', 'Vehículo de reparto 202', 'VEHICULO', '76001', NULL, NULL, true, '2026-09-08 20:51:12.248701+00');
INSERT INTO catalogo.tipo_servicio (codigo, nombre, descripcion, activo) VALUES
	('EXPRESS', 'Express', 'Entrega al día siguiente entre ciudades principales.', true),
	('ESTANDAR', 'Estándar', 'Servicio corriente.', true),
	('ECONOMICO', 'Económico', 'Servicio de menor costo y mayor plazo.', true);
INSERT INTO catalogo.sla_servicio (tipo_servicio, vigente_desde, horas_max) VALUES
	('EXPRESS', '2026-01-01', 24),
	('ESTANDAR', '2026-01-01', 96),
	('ESTANDAR', '2026-07-01', 72),
	('ECONOMICO', '2026-01-01', 120);
INSERT INTO catalogo.tipo_evento (codigo, nombre, descripcion, requiere_receptor, requiere_observaciones, visible_cliente, orden) VALUES
	('ADMISION', 'Admitido en origen', 'El paquete entra físicamente a la red.', false, false, true, 1),
	('SALIDA_CENTRO', 'Salida de centro', 'El paquete sale de un centro de distribución.', false, false, true, 2),
	('LLEGADA_CENTRO', 'Llegada a centro', 'El paquete llega a un centro de distribución.', false, false, true, 3),
	('SALIDA_REPARTO', 'En reparto', 'El paquete sale hacia la dirección de entrega.', false, false, true, 4),
	('ENTREGA', 'Entregado', 'El paquete se entrega a quien corresponde.', true, false, true, 5),
	('INTENTO_FALLIDO', 'Intento de entrega fallido', 'Nadie recibió; el paquete vuelve al centro.', false, true, true, 6),
	('RETENCION', 'Retención', 'El paquete queda detenido por una causa.', false, true, true, 7),
	('LIBERACION', 'Liberación', 'Se resolvió la causa de la retención.', false, true, true, 8),
	('DEVOLUCION_INICIADA', 'Devolución iniciada', 'Se ordena el regreso del paquete al remitente.', false, true, true, 9),
	('EXTRAVIO', 'Extravío', 'El paquete se declara perdido.', false, true, true, 10),
	('ANULACION', 'Anulación', 'El envío se cancela.', false, true, true, 11);
INSERT INTO catalogo.transicion_valida (estado_origen, tipo_evento, estado_destino) VALUES
	('REGISTRADO', 'ADMISION', 'EN_TRANSITO'),
	('REGISTRADO', 'ANULACION', 'ANULADO'),
	('EN_TRANSITO', 'SALIDA_CENTRO', 'EN_TRANSITO'),
	('EN_TRANSITO', 'LLEGADA_CENTRO', 'EN_TRANSITO'),
	('EN_TRANSITO', 'SALIDA_REPARTO', 'EN_REPARTO'),
	('EN_TRANSITO', 'RETENCION', 'RETENIDO'),
	('EN_TRANSITO', 'DEVOLUCION_INICIADA', 'EN_DEVOLUCION'),
	('EN_TRANSITO', 'EXTRAVIO', 'EXTRAVIADO'),
	('EN_TRANSITO', 'ANULACION', 'ANULADO'),
	('EN_REPARTO', 'ENTREGA', 'ENTREGADO'),
	('EN_REPARTO', 'INTENTO_FALLIDO', 'EN_TRANSITO'),
	('EN_REPARTO', 'RETENCION', 'RETENIDO'),
	('EN_REPARTO', 'DEVOLUCION_INICIADA', 'EN_DEVOLUCION'),
	('RETENIDO', 'LIBERACION', 'EN_TRANSITO'),
	('RETENIDO', 'DEVOLUCION_INICIADA', 'EN_DEVOLUCION'),
	('RETENIDO', 'EXTRAVIO', 'EXTRAVIADO'),
	('EN_DEVOLUCION', 'SALIDA_CENTRO', 'EN_DEVOLUCION'),
	('EN_DEVOLUCION', 'LLEGADA_CENTRO', 'EN_DEVOLUCION'),
	('EN_DEVOLUCION', 'ENTREGA', 'DEVUELTO'),
	('EN_DEVOLUCION', 'EXTRAVIO', 'EXTRAVIADO');

-- Las vistas materializadas se crean WITH NO DATA; sin esto v_volumen_* falla
-- al consultarse en una base recién creada.
REFRESH MATERIALIZED VIEW eventos.mv_volumen_movimiento;
REFRESH MATERIALIZED VIEW eventos.mv_volumen_registro;
