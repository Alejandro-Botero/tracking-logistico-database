# tracking-logistico-database — Sprint 2

Base de datos del sistema de tracking logístico — Fábrica Escuela, Bases de Datos.
Monolito modular sobre un solo PostgreSQL (Supabase): tres schemas —
`catalogo` (datos de referencia), `envios` (ciclo de vida del envío) y
`eventos` (historial logístico) — y cuatro roles de base de datos con privilegios
mínimos. Cubre HU-01 a HU-07 (registrar envío, registrar evento, rastreo público,
historial, tiempos de tránsito, envíos retrasados y volumen por punto).

### Integrantes

* Alejandro Botero Arbeláez
* Eyner Gomez Quintero
* Jose Manuel Londoño Castaño
* Ivan Dario López Cuadrado
* Oliver Andres Quiroz Mora
* Juan Daniel Rincon Bedoya

---

## 1. Cambios frente al Sprint 1

El Sprint 1 tenía 2 tablas (`envios.envio`, `eventos.evento`) y un solo usuario
`app_user` con `GRANT ALL`. El Sprint 2 pasa a 12 tablas. Cada cambio responde a
una historia de usuario o a una debilidad que el Sprint 1 dejó anotada.

| # | Cambio | Sprint 1 | Sprint 2 | Motivo |
|---|---|---|---|---|
| 1 | **Entidad nueva `PARTE`** | Columnas `remitente_*` y `destinatario_*` planas en `envio` (8 columnas) | Tabla `envios.parte` 1:N con `envio`, con `rol` ∈ {REMITENTE, DESTINATARIO}, `tipo_documento`, `documento` y `ciudad_codigo` | El Sprint 1 lo dejó escrito: "si esa necesidad aparece en otro sprint, ahí se normaliza". HU-03 verifica al destinatario por teléfono o documento y HU-07 agrupa por ciudad. |
| 2 | **Entidad nueva `PAQUETE`** | No existía | `envios.paquete` 1:N con `envio` (peso, dimensiones, contenido, valor declarado) | Un envío puede tener varios bultos. |
| 3 | **Catálogo `CIUDAD`** | Ciudad no existía | `catalogo.ciudad` (código DIVIPOLA) referenciada por `punto_red` y `parte` | Evitar "Bogotá" / "Bogota" duplicadas al agrupar por ciudad (HU-07). |
| 4 | **Catálogo `PUNTO_RED`** | `evento.punto` era `varchar(150)` libre | `catalogo.punto_red` (centros, puntos de venta, vehículos) y `evento.punto_red_id` FK | Texto libre impedía agrupar por punto y calcular tramos (HU-05, HU-07). |
| 5 | **Catálogos `ESTADO_ENVIO`, `TIPO_EVENTO` y `TRANSICION_VALIDA`** | `CHECK (estado IN (3 valores))` y `CHECK (tipo_evento IN (4 valores))` | Tres tablas: 9 estados, 11 tipos de evento y la máquina de estados como terna (estado origen, tipo de evento, estado destino) | Aparecen excepciones (retención, devolución, extravío, anulación); cambiar las reglas no debe requerir `ALTER TABLE`. |
| 6 | **Catálogos `TIPO_SERVICIO` y `SLA_SERVICIO`** | No existían | `envio.tipo_servicio` FK; `sla_servicio` con vigencia (PK compuesta) | HU-05 y HU-06 comparan el tiempo en red contra el SLA del servicio. |
| 7 | **Catálogo `OPERADOR`** | No existía | `catalogo.operador`; `envio.registrado_por` y `evento.registrado_por` son FK | Trazabilidad de quién registró cada cosa. |
| 8 | **`ENVIO` cambia de llaves y atributos** | PK `bigserial`; `numero_seguimiento`; `estado`; `fecha_registro` | PK `uuid`; `tracking_number` con formato y dígito verificador; `estado_actual` FK; `horas_sla`, `punto_origen_id`, `punto_destino_id`, `registrado_por`, `admitido_en`, `ultimo_evento_en`, `ultimo_punto_id`, `cerrado_en`, `entregado_en`, `actualizado_en` | HU-03 responde estado + último punto + fecha en una sola lectura; el SLA se congela al alta. |
| 9 | **`EVENTO` cambia de llaves y atributos** | `id bigserial`, `envio_id`, `tipo_evento`, `punto`, `fecha_hora`, `receptor` | PK `uuid` + `secuencia` (identity); `estado_resultante`, `cierra_envio`, `ocurrido_en` ≠ `registrado_en`, `registrado_por`, `recibido_por` (antes `receptor`), `observaciones`, `clave_idempotencia`, `tracking_number` | Un lector sin señal reporta horas tarde: el hecho (`ocurrido_en`) se separa de la captura (`registrado_en`). Un reintento no duplica el evento (idempotencia). |
| 10 | **Seguridad** | Un usuario `app_user` con `GRANT ALL`, RLS desactivado | Cuatro roles (`rol_admin`, `ms_envios`, `ms_eventos`, `rol_lectura`) con `GRANT` por tabla/vista, RLS activado en las 12 tablas y `REVOKE` al público | Criterio de mínimo privilegio. |
| 11 | **Reglas en la base** | Un `CHECK` (receptor obligatorio en ENTREGADO) | Triggers: transición válida, evento inmutable, SLA congelado, envío completo (2 partes + ≥1 paquete) | La integridad no depende de que cada microservicio la recuerde. |

Las referencias de Sprint 1 que se conservan: `envio` 1:N `evento`, FK directa entre
schemas (monolito), `tracking_number` único, y la regla de que una entrega exige
constancia de quién recibió (ahora declarada como `tipo_evento.requiere_receptor`).

## 2. Modelo entidad-relación refinado

```mermaid
erDiagram
    CIUDAD        ||--o{ PUNTO_RED : "ubica"
    CIUDAD        ||--o{ PARTE : "domicilia"
    PUNTO_RED     ||--o{ ENVIO : "origen"
    PUNTO_RED     |o--o{ ENVIO : "destino previsto"
    PUNTO_RED     |o--o{ ENVIO : "último punto"
    PUNTO_RED     ||--o{ EVENTO : "ocurre en"
    TIPO_SERVICIO ||--o{ SLA_SERVICIO : "define"
    TIPO_SERVICIO ||--o{ ENVIO : "se vende como"
    OPERADOR      ||--o{ ENVIO : "registra"
    OPERADOR      ||--o{ EVENTO : "registra"
    ESTADO_ENVIO  ||--o{ ENVIO : "estado actual"
    ESTADO_ENVIO  ||--o{ EVENTO : "estado resultante"
    ESTADO_ENVIO  ||--o{ TRANSICION_VALIDA : "origen"
    ESTADO_ENVIO  ||--o{ TRANSICION_VALIDA : "destino"
    TIPO_EVENTO   ||--o{ TRANSICION_VALIDA : "dispara"
    TIPO_EVENTO   ||--o{ EVENTO : "clasifica"
    ENVIO         ||--|{ PARTE : "tiene (remitente y destinatario)"
    ENVIO         ||--|{ PAQUETE : "contiene"
    ENVIO         ||--o{ EVENTO : "tiene"

    CIUDAD {
        text codigo PK
        text nombre
        text departamento
        text pais
        boolean activa
    }
    PUNTO_RED {
        uuid id PK
        text codigo UK
        text nombre
        text tipo
        text ciudad_codigo FK
        numeric latitud
        numeric longitud
        boolean activo
        timestamptz creado_en
    }
    TIPO_SERVICIO {
        text codigo PK
        text nombre
        text descripcion
        boolean activo
    }
    SLA_SERVICIO {
        text tipo_servicio PK, FK
        date vigente_desde PK
        integer horas_max
    }
    OPERADOR {
        text codigo PK
        text nombre
        boolean activo
        timestamptz creado_en
    }
    ESTADO_ENVIO {
        text codigo PK
        text nombre
        text descripcion
        boolean es_inicial
        boolean es_final
        boolean es_excepcion
        text resultado
        smallint orden
    }
    TIPO_EVENTO {
        text codigo PK
        text nombre
        text descripcion
        boolean requiere_receptor
        boolean requiere_observaciones
        boolean visible_cliente
        smallint orden
    }
    TRANSICION_VALIDA {
        text estado_origen PK, FK
        text tipo_evento PK, FK
        text estado_destino FK
    }
    ENVIO {
        uuid id PK
        text tracking_number UK
        text tipo_servicio FK
        integer horas_sla
        text estado_actual FK
        uuid punto_origen_id FK
        uuid punto_destino_id FK
        timestamptz registrado_en
        text registrado_por FK
        timestamptz admitido_en
        timestamptz ultimo_evento_en
        uuid ultimo_punto_id FK
        timestamptz cerrado_en
        timestamptz entregado_en
        timestamptz actualizado_en
    }
    PARTE {
        uuid id PK
        uuid envio_id FK
        text rol
        text nombre
        text tipo_documento
        text documento
        text telefono
        text email
        text direccion
        text ciudad_codigo FK
    }
    PAQUETE {
        uuid id PK
        uuid envio_id FK
        smallint consecutivo
        numeric peso_kg
        numeric alto_cm
        numeric ancho_cm
        numeric largo_cm
        text contenido
        numeric valor_declarado
    }
    EVENTO {
        uuid id PK
        bigint secuencia
        uuid envio_id FK
        text tracking_number
        text tipo_evento FK
        text estado_resultante FK
        boolean cierra_envio
        uuid punto_red_id FK
        timestamptz ocurrido_en
        timestamptz registrado_en
        text registrado_por FK
        text recibido_por
        text observaciones
        text clave_idempotencia UK
    }
```

**Cardinalidades.** Un envío tiene exactamente dos partes (remitente y destinatario,
`UNIQUE (envio_id, rol)` + trigger), uno o más paquetes (`UNIQUE (envio_id, consecutivo)`)
y cero o más eventos. `punto_destino_id` y `ultimo_punto_id` son opcionales
(`|o`): un envío recién registrado no ha pasado por ningún punto. `TRANSICION_VALIDA`
resuelve la relación ternaria estado × evento → estado.

---

## 3. Modelo físico

[`schema.sql`](schema.sql) es el script único (tres schemas, 12 tablas, índices,
triggers, vistas, RLS y roles), ejecutable de punta a punta contra un proyecto
Postgres/Supabase vacío:

```bash
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f schema.sql
```

Lo que sigue documenta las 12 tablas tal como las crea el script. Los roles son
`NOLOGIN`: la contraseña y el `LOGIN` se asignan fuera del repo.

**Convenciones.** `PK` llave primaria, `FK →` llave foránea, `UK` única, `NN` `NOT NULL`.
Toda FK sin `ON DELETE` explícito es `NO ACTION`; las de `parte`, `paquete` y `evento`
hacia `envio` son `ON DELETE RESTRICT`. Nada se borra en cascada.

### Schema `catalogo` (datos de referencia)

**`catalogo.ciudad`**

| Columna | Tipo | Restricciones |
|---|---|---|
| `codigo` | text | **PK** (DIVIPOLA) |
| `nombre` | text | NN |
| `departamento` | text | |
| `pais` | text | NN, DEFAULT `'CO'`, CHECK `length(pais) = 2` |
| `activa` | boolean | NN, DEFAULT `true` |

UK: `(pais, lower(nombre))` (`uq_ciudad_nombre`), evita "Bogotá" / "bogotá" duplicadas.

**`catalogo.estado_envio`**

| Columna | Tipo | Restricciones |
|---|---|---|
| `codigo` | text | **PK** |
| `nombre` | text | NN |
| `descripcion` | text | |
| `es_inicial` | boolean | NN, DEFAULT `false` |
| `es_final` | boolean | NN, DEFAULT `false` |
| `es_excepcion` | boolean | NN, DEFAULT `false` |
| `resultado` | text | CHECK `IN ('EXITOSO','FALLIDO')` |
| `orden` | smallint | |

CHECK de tabla: `NOT (es_inicial AND es_final)`; `(resultado IS NOT NULL) = es_final`
(solo los estados finales llevan resultado); `es_excepcion OR orden IS NOT NULL`
(los estados de excepción no están sobre la barra de progreso). Únicos parciales:
`uq_estado_inicial` (un solo estado inicial) y `uq_estado_orden` (`orden` no se repite).

**`catalogo.tipo_evento`**

| Columna | Tipo | Restricciones |
|---|---|---|
| `codigo` | text | **PK** |
| `nombre` | text | NN |
| `descripcion` | text | |
| `requiere_receptor` | boolean | NN, DEFAULT `false` |
| `requiere_observaciones` | boolean | NN, DEFAULT `false` |
| `visible_cliente` | boolean | NN, DEFAULT `true` |
| `orden` | smallint | NN, DEFAULT `0` |

**`catalogo.tipo_servicio`**

| Columna | Tipo | Restricciones |
|---|---|---|
| `codigo` | text | **PK** |
| `nombre` | text | NN |
| `descripcion` | text | |
| `activo` | boolean | NN, DEFAULT `true` |

**`catalogo.operador`**

| Columna | Tipo | Restricciones |
|---|---|---|
| `codigo` | text | **PK**, CHECK `length(btrim(codigo)) > 0` (claim `sub` del token) |
| `nombre` | text | |
| `activo` | boolean | NN, DEFAULT `true` |
| `creado_en` | timestamptz | NN, DEFAULT `now()` |

**`catalogo.punto_red`**

| Columna | Tipo | Restricciones |
|---|---|---|
| `id` | uuid | **PK**, DEFAULT `gen_random_uuid()` |
| `codigo` | text | **UK**, NN |
| `nombre` | text | NN |
| `tipo` | text | NN, CHECK `IN ('CENTRO_DISTRIBUCION','PUNTO_VENTA','VEHICULO','DESTINO')` |
| `ciudad_codigo` | text | **FK →** `catalogo.ciudad(codigo)`, NN |
| `latitud` | numeric(9,6) | CHECK entre −90 y 90 |
| `longitud` | numeric(9,6) | CHECK entre −180 y 180 |
| `activo` | boolean | NN, DEFAULT `true` |
| `creado_en` | timestamptz | NN, DEFAULT `now()` |

Índices: `idx_punto_red_ciudad (ciudad_codigo)`, `idx_punto_red_activo (activo) WHERE activo`.

**`catalogo.sla_servicio`**

| Columna | Tipo | Restricciones |
|---|---|---|
| `tipo_servicio` | text | **PK** (1/2), **FK →** `catalogo.tipo_servicio(codigo)` |
| `vigente_desde` | date | **PK** (2/2), DEFAULT `CURRENT_DATE` |
| `horas_max` | integer | NN, CHECK `horas_max > 0` |

**`catalogo.transicion_valida`** (máquina de estados: estado origen × evento → estado destino)

| Columna | Tipo | Restricciones |
|---|---|---|
| `estado_origen` | text | **PK** (1/2), **FK →** `catalogo.estado_envio(codigo)` |
| `tipo_evento` | text | **PK** (2/2), **FK →** `catalogo.tipo_evento(codigo)` |
| `estado_destino` | text | **FK →** `catalogo.estado_envio(codigo)`, NN |

Trigger `trg_transicion_coherente`: el estado inicial no puede ser destino y un
estado final no puede ser origen.

### Schema `envios` (ciclo de vida del envío)

**`envios.envio`** (HU-01, HU-03, HU-05, HU-06)

| Columna | Tipo | Restricciones |
|---|---|---|
| `id` | uuid | **PK**, DEFAULT `gen_random_uuid()` |
| `tracking_number` | text | **UK**, NN, DEFAULT `envios.gen_tracking_number()`, CHECK `envios.tracking_valido(tracking_number)` (formato `FDX` + 12 dígitos, los 2 últimos de verificación) |
| `tipo_servicio` | text | **FK →** `catalogo.tipo_servicio(codigo)`, NN |
| `horas_sla` | integer | NN, CHECK `horas_sla > 0`; lo fija el trigger `trg_envio_sla` desde `sla_servicio` al alta |
| `estado_actual` | text | **FK →** `catalogo.estado_envio(codigo)`, NN, DEFAULT `catalogo.estado_inicial()` |
| `punto_origen_id` | uuid | **FK →** `catalogo.punto_red(id)`, NN |
| `punto_destino_id` | uuid | **FK →** `catalogo.punto_red(id)` |
| `registrado_en` | timestamptz | NN, DEFAULT `now()` |
| `registrado_por` | text | **FK →** `catalogo.operador(codigo)`, NN |
| `admitido_en` | timestamptz | |
| `ultimo_evento_en` | timestamptz | |
| `ultimo_punto_id` | uuid | **FK →** `catalogo.punto_red(id)` |
| `cerrado_en` | timestamptz | |
| `entregado_en` | timestamptz | CHECK de tabla `ck_envio_cierre`: `entregado_en IS NULL OR cerrado_en IS NOT NULL` |
| `actualizado_en` | timestamptz | NN, DEFAULT `now()`; lo sella `trg_envio_actualizado` en cada `UPDATE` |

Índices: `idx_envio_registrado_en`, `idx_envio_origen (punto_origen_id, registrado_en)`,
`idx_envio_destino`, `idx_envio_estado`, `idx_envio_tipo_servicio`, `idx_envio_operador`,
`idx_envio_ultimo_punto`, `idx_envio_en_red (ultimo_evento_en) WHERE cerrado_en IS NULL`.
Trigger diferido `trg_envio_completo`: al hacer `COMMIT` el envío debe tener 2 partes y ≥ 1 paquete.

**`envios.parte`** (remitente y destinatario)

| Columna | Tipo | Restricciones |
|---|---|---|
| `id` | uuid | **PK**, DEFAULT `gen_random_uuid()` |
| `envio_id` | uuid | **FK →** `envios.envio(id)` `ON DELETE RESTRICT`, NN |
| `rol` | text | NN, CHECK `IN ('REMITENTE','DESTINATARIO')` |
| `nombre` | text | NN, CHECK `length(btrim(nombre)) > 0` |
| `tipo_documento` | text | CHECK `IN ('CC','CE','NIT','PAS')` |
| `documento` | text | CHECK de tabla: `(tipo_documento IS NULL) = (documento IS NULL)` |
| `telefono` | text | NN, CHECK `length(btrim(telefono)) > 0` |
| `email` | text | CHECK formato `x@y.z` si no es nulo |
| `direccion` | text | NN, CHECK `length(btrim(direccion)) > 0` |
| `ciudad_codigo` | text | **FK →** `catalogo.ciudad(codigo)`, NN |

UK: `(envio_id, rol)` — un envío no repite remitente ni destinatario. Índices:
`idx_parte_envio`, `idx_parte_ciudad`, `idx_parte_documento (tipo_documento, documento) WHERE documento IS NOT NULL`.

**`envios.paquete`**

| Columna | Tipo | Restricciones |
|---|---|---|
| `id` | uuid | **PK**, DEFAULT `gen_random_uuid()` |
| `envio_id` | uuid | **FK →** `envios.envio(id)` `ON DELETE RESTRICT`, NN |
| `consecutivo` | smallint | NN, CHECK `consecutivo > 0` |
| `peso_kg` | numeric(8,3) | NN, CHECK `peso_kg > 0` |
| `alto_cm` | numeric(7,2) | CHECK `> 0` |
| `ancho_cm` | numeric(7,2) | CHECK `> 0` |
| `largo_cm` | numeric(7,2) | CHECK `> 0` |
| `contenido` | text | NN |
| `valor_declarado` | numeric(14,2) | CHECK `>= 0` |

UK: `(envio_id, consecutivo)`. Índice: `idx_paquete_envio`.

### Schema `eventos` (historial logístico)

**`eventos.evento`** (HU-02, HU-04, HU-05, HU-07)

| Columna | Tipo | Restricciones |
|---|---|---|
| `id` | uuid | **PK**, DEFAULT `gen_random_uuid()` |
| `secuencia` | bigint | NN, `GENERATED ALWAYS AS IDENTITY` (orden de llegada; desempata `ocurrido_en`) |
| `envio_id` | uuid | **FK →** `envios.envio(id)` `ON DELETE RESTRICT`, NN |
| `tracking_number` | text | NN; copia del número del envío, la fija `trg_evento_validar` |
| `tipo_evento` | text | **FK →** `catalogo.tipo_evento(codigo)`, NN |
| `estado_resultante` | text | **FK →** `catalogo.estado_envio(codigo)`, NN; la resuelve `trg_evento_validar` contra `transicion_valida` |
| `cierra_envio` | boolean | NN, DEFAULT `false`; `true` si el estado resultante es final |
| `punto_red_id` | uuid | **FK →** `catalogo.punto_red(id)`, NN |
| `ocurrido_en` | timestamptz | NN, DEFAULT `now()`, CHECK `ocurrido_en <= registrado_en + interval '5 minutes'` |
| `registrado_en` | timestamptz | NN, DEFAULT `now()` |
| `registrado_por` | text | **FK →** `catalogo.operador(codigo)`, NN |
| `recibido_por` | text | obligatorio si `tipo_evento.requiere_receptor` (trigger) |
| `observaciones` | text | obligatorio si `tipo_evento.requiere_observaciones` (trigger) |
| `clave_idempotencia` | text | |

Únicos parciales: `uq_evento_idempotencia (clave_idempotencia) WHERE clave_idempotencia IS NOT NULL`
(un reintento no duplica el evento) y `uq_evento_cierre (envio_id) WHERE cierra_envio`
(un envío se cierra una sola vez). Índices: `idx_evento_envio (envio_id, ocurrido_en DESC, secuencia DESC)`,
`idx_evento_tracking`, `idx_evento_punto (punto_red_id, ocurrido_en)`,
`idx_evento_tipo (tipo_evento, ocurrido_en)`, `idx_evento_operador`, `idx_evento_ocurrido_brin` (BRIN sobre `ocurrido_en`).
Triggers: `trg_evento_validar` (BEFORE INSERT: transición legal, orden cronológico, punto activo, receptor y observaciones),
`trg_evento_aplicar_estado` (AFTER INSERT: actualiza `envio`) y `trg_evento_inmutable` (bloquea `UPDATE` y `DELETE`).

### Normalización

Once de las 12 tablas cumplen BCNF: todo determinante es llave candidata. `eventos.evento` queda en 2FN por dos desnormalizaciones deliberadas:

- `tracking_number` depende de `envio_id` y no de la llave `id`: dependencia transitiva, así que `evento` no está en 3FN. Se copia a propósito para que MS-Eventos consulte por número sin cruzar al schema de MS-Envíos. No puede divergir: `trg_evento_validar` la sobrescribe en cada `INSERT` con el valor del envío y el historial es inmutable.
- `cierra_envio` depende de `estado_resultante` (`es_final`). Se guarda para poder declarar el único parcial `uq_evento_cierre` sin cablear el código del evento de entrega. También la fija el trigger.

Otras decisiones que conviene dejar explícitas:

- `envio.horas_sla` y las columnas de caché (`estado_actual`, `ultimo_evento_en`, `ultimo_punto_id`, `admitido_en`, `cerrado_en`, `entregado_en`) repiten información derivable de `sla_servicio` y de `evento`, pero dentro de la relación `envio` ninguna determina a otra: todas dependen solo de `id`, por lo que `envio` cumple BCNF. `horas_sla` es una foto del SLA vigente al alta (cambiar el SLA no debe reescribir el pasado). La caché la mantiene `trg_evento_aplicar_estado` y la vista `eventos.v_envio_incoherente` detecta cualquier deriva.
- `parte` conserva nombre, teléfono y documento por envío, sin tabla `persona`. `documento → nombre` no se declara como dependencia: es la foto de lo que se declaró en ese envío, y ninguna HU pide reutilizar contactos. Si aparece esa necesidad, ahí se normaliza.
- Las tablas con dos llaves candidatas (`envio`, `punto_red`, `parte`, `paquete`, `ciudad`) las tienen disjuntas, así que ahí la diferencia entre 3FN y BCNF no aparece.

## 4. Roles y seguridad

El Sprint 1 tenía un solo usuario (`app_user`) con `GRANT ALL` y RLS desactivado: quien tuviera
la contraseña podía borrar el historial. El Sprint 2 separa los roles según lo que hace cada
actor del sistema y le da a cada uno solo lo que necesita (mínimo privilegio). La seguridad
tiene cuatro capas: **roles + `GRANT`/`REVOKE`**, **Row Level Security**, **triggers** que
protegen las reglas aunque el rol tenga permiso, y **funciones `SECURITY DEFINER`** para los
pocos casos en que un servicio necesita algo que no se le puede conceder directamente.

### Roles

| Rol | Quién lo usa | Para qué |
|---|---|---|
| `rol_admin` | Personas del equipo (administración de datos) | Mantener los catálogos que definen las reglas (estados, tipos de evento, transiciones, servicios, SLA) y corregir datos |
| `ms_envios` | **La aplicación**: microservicio MS-Envíos | Registrar envíos, partes y paquetes (HU-01), rastreo público (HU-03), alta de puntos y ciudades de la red |
| `ms_eventos` | **La aplicación**: microservicio MS-Eventos | Registrar eventos (HU-02) y consultar historial, tiempos, retrasos y volumen (HU-04 a HU-07) |
| `rol_lectura` | Analistas y reportes | Consultar únicamente las vistas de reporte (HU-04 a HU-07) |

Los cuatro son `NOLOGIN`: la contraseña y el `LOGIN` se asignan fuera del repo
(`ALTER ROLE ms_envios WITH LOGIN PASSWORD '<secreto>'`). Los cambios de esquema (DDL) los hace
el dueño de los objetos, es decir, quien ejecuta `schema.sql`; ningún rol de la aplicación puede
crear ni alterar tablas.

### Matriz rol × tabla

`S` SELECT · `I` INSERT · `U` UPDATE · `D` DELETE · `—` sin acceso. Generada consultando
`has_table_privilege` sobre una base creada con `schema.sql`.

| Tabla | `rol_admin` | `ms_envios` | `ms_eventos` | `rol_lectura` |
|---|---|---|---|---|
| `catalogo.ciudad` | S I U D | S I U | S | — |
| `catalogo.punto_red` | S I U D | S I U | S | — |
| `catalogo.operador` | S I U D | S | S | — |
| `catalogo.estado_envio` | S I U D | S | S | — |
| `catalogo.tipo_evento` | S I U D | S | S | — |
| `catalogo.transicion_valida` | S I U D | S | S | — |
| `catalogo.tipo_servicio` | S I U D | S | S | — |
| `catalogo.sla_servicio` | S I U D | S | S | — |
| `envios.envio` | S I U D | S I U | — | — |
| `envios.parte` | S I U D | S I U | — | — |
| `envios.paquete` | S I U D | S I U | — | — |
| `eventos.evento` | S I U D (*) | — | S I | — |

(*) `rol_admin` tiene el privilegio, pero el trigger `trg_evento_inmutable` rechaza `UPDATE` y
`DELETE` sobre `evento` para cualquier rol: el historial es de solo inserción.

**Vistas y funciones.** Las vistas de `eventos` se crean con `security_invoker = false`, es decir,
leen con los permisos del dueño. Así un rol de reporte consulta el resultado sin tener acceso a
las tablas base.

| Objeto | `ms_envios` | `ms_eventos` | `rol_lectura` |
|---|---|---|---|
| `envios.v_envio_publico`, `envios.rastrear()` (HU-03) | SELECT / EXECUTE | — | — |
| `eventos.v_historial_envio`, `v_tramo`, `v_tiempo_transito_envio`, `v_tiempo_transito_tramo`, `v_envio_retrasado`, `v_volumen_registro`, `v_volumen_movimiento` | — | SELECT | SELECT |
| `eventos.v_envio_referencia`, `eventos.v_envio_incoherente` | — | SELECT | — |
| `eventos.refrescar_reportes()` | — | EXECUTE | — |
| `catalogo.registrar_operador()` | EXECUTE | EXECUTE | — |
| `envios.gen_tracking_number()` | EXECUTE | — | — |

### Decisiones de diseño

- **`ms_envios` no escribe las reglas del negocio.** Solo lee `estado_envio`, `tipo_evento`,
  `transicion_valida`, `tipo_servicio` y `sla_servicio`. Si pudiera modificarlas, un servicio
  comprometido reescribiría la máquina de estados o los SLA. Esas tablas las cambia `rol_admin`.
  Tampoco inserta en `operador`: lo hace `registrar_operador()`, que es `SECURITY DEFINER`.
- **Nadie de la aplicación borra.** Ningún rol de servicio tiene `DELETE`: un envío se anula con un
  evento y un catálogo se desactiva con la columna `activo`. Las FK hacia `envio` son `ON DELETE RESTRICT`.
- **`ms_eventos` no ve `envios.envio`.** Valida y propaga el estado a través de funciones
  `SECURITY DEFINER` (`validar_evento`, `aplicar_estado_envio`) con `search_path` fijo, y lee
  el envío solo mediante la vista `v_envio_referencia`. Al separar las bases, esa vista se
  reemplaza por una llamada HTTP sin tocar el resto.
- **`rol_lectura` no toca tablas.** Solo vistas de reporte; no ve datos personales de `parte`.
- **Rastreo público con segundo factor.** `rastrear(tracking, verificación)` exige el número más los
  últimos 4 dígitos del teléfono o documento del destinatario, y devuelve cero filas si no
  coinciden, sin decir cuál de los dos falló.

### Row Level Security

RLS está activado en las 12 tablas y `REVOKE ALL ... FROM PUBLIC` en los tres schemas. Una tabla con RLS
y sin política para un rol niega todo a ese rol; los roles `anon` y `authenticated` de Supabase no
tienen `GRANT` ni política sobre estos schemas, así que no ven nada. Políticas:

| Tabla(s) | Política | Rol | Comando |
|---|---|---|---|
| `punto_red`, `ciudad` | `p_catalogo_escritura`, `p_ciudad_escritura` | `ms_envios` | ALL |
| 8 tablas de `catalogo` | `p_*_lectura` | `ms_envios`, `ms_eventos` | SELECT |
| `envio`, `parte`, `paquete` | `p_envio`, `p_parte`, `p_paquete` | `ms_envios` | ALL |
| `evento` | `p_evento_lectura` | `ms_eventos` | SELECT |
| `evento` | `p_evento_escritura` | `ms_eventos` | INSERT |
| las 12 tablas | `p_admin` | `rol_admin` | ALL |

Las políticas usan `USING (true)`: la separación es por rol y por tabla, no por fila, porque este
modelo no tiene inquilinos ni dueños de fila. La función `catalogo.verificar_rls()` devuelve cero filas
cuando todas las tablas tienen RLS con política y nada quedó abierto a `PUBLIC`; cualquier fila es un agujero.

### Script

Está en la sección 2 de [`schema.sql`](schema.sql); estos son los fragmentos esenciales.

```sql
-- 1. Crear los roles
CREATE ROLE rol_admin   NOLOGIN;
CREATE ROLE ms_envios   NOLOGIN;
CREATE ROLE ms_eventos  NOLOGIN;
CREATE ROLE rol_lectura NOLOGIN;

-- 2. Quitar acceso al público y permitir uso de cada schema solo a quien lo necesita
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
REVOKE ALL ON SCHEMA catalogo, envios, eventos FROM PUBLIC;
GRANT USAGE ON SCHEMA catalogo TO ms_envios, ms_eventos;
GRANT USAGE ON SCHEMA envios   TO ms_envios;
GRANT USAGE ON SCHEMA eventos  TO ms_eventos, rol_lectura;
GRANT USAGE ON SCHEMA catalogo, envios, eventos TO rol_admin;

-- 3. Privilegios mínimos
GRANT ALL ON ALL TABLES    IN SCHEMA catalogo, envios, eventos TO rol_admin;
GRANT ALL ON ALL SEQUENCES IN SCHEMA catalogo, envios, eventos TO rol_admin;

GRANT SELECT ON ALL TABLES IN SCHEMA catalogo TO ms_envios;
GRANT INSERT, UPDATE ON catalogo.punto_red, catalogo.ciudad TO ms_envios;
GRANT SELECT, INSERT, UPDATE ON envios.envio, envios.parte, envios.paquete TO ms_envios;
GRANT USAGE ON SEQUENCE envios.tracking_seq TO ms_envios;      -- DEFAULT gen_tracking_number()

GRANT SELECT ON ALL TABLES IN SCHEMA catalogo TO ms_eventos;
GRANT SELECT, INSERT ON eventos.evento TO ms_eventos;          -- append-only

GRANT SELECT ON eventos.v_historial_envio, eventos.v_tramo, eventos.v_volumen_registro,
                eventos.v_volumen_movimiento, eventos.v_tiempo_transito_envio,
                eventos.v_tiempo_transito_tramo, eventos.v_envio_retrasado TO rol_lectura;

-- 4. RLS (una política por rol y tabla; rol_admin con un bucle sobre las 12 tablas)
ALTER TABLE eventos.evento ENABLE ROW LEVEL SECURITY;
CREATE POLICY p_evento_lectura   ON eventos.evento FOR SELECT TO ms_eventos USING (true);
CREATE POLICY p_evento_escritura ON eventos.evento FOR INSERT TO ms_eventos WITH CHECK (true);
```

### Verificación

Con `schema.sql` ejecutado en una base vacía se comprobó con cada rol (`SET ROLE`):

- `ms_envios` registra un envío completo, pero `UPDATE transicion_valida`, `INSERT tipo_servicio`,
  `UPDATE sla_servicio` y `DELETE envio` fallan con `permission denied`.
- `ms_eventos` inserta un evento y lee el historial, pero no puede leer `envios.envio`, escribir
  `catalogo.ciudad` ni hacer `UPDATE`/`DELETE` sobre `evento`.
- `rol_lectura` lee `v_volumen_registro`, pero `SELECT` sobre `evento` y sobre `catalogo` falla.
- `rol_admin` inserta en catálogos, pero `UPDATE`/`DELETE` sobre `evento` los rechaza el trigger.
- `SELECT * FROM catalogo.verificar_rls()` devuelve cero filas.

---

> **Pendiente (Sprint 2):** consultas y estimación de volumen.

## Consultas
 
Hay 15 consultas sobre `schema.sql`: 5 de las historias del Sprint 1 (HU-01 a HU-03), 8 del Sprint 2 (HU-04 a HU-07) y 2 de verificación de integridad. Usan filtros, agregaciones y joins, y cada una indica la pregunta de negocio que responde. El SQL está en [consultas.sql](consultas.sql) y la descripción de cada consulta en [docs/consultas.md](docs/consultas.md).
 
---

## Estimación de volumen
 
No hay datos históricos de la operación, así que partimos de supuestos: 1.000 envíos por día (30.000 al mes y 360.000 al año), sin picos de temporada ni crecimiento del negocio. El resto sale de las reglas del esquema: cada envío tiene exactamente 2 partes (lo exige un trigger), en promedio 1,2 paquetes y 6 eventos (los 5 del recorrido normal más uno por tránsito extra o intento fallido).
 
| Tabla | Cálculo | Crecimiento por mes | A 1 año | A 3 años |
|---|---|---|---|---|
| `envios.envio` | 1.000 × 30 | 30.000 | 360.000 | 1.080.000 |
| `envios.parte` | 30.000 × 2 | 60.000 | 720.000 | 2.160.000 |
| `envios.paquete` | 30.000 × 1,2 | 36.000 | 432.000 | 1.296.000 |
| `eventos.evento` | 30.000 × 6 | 180.000 | 2.160.000 | 6.480.000 |
 
Las dos vistas materializadas guardan una fila por día y punto, así que son pequeñas: unas 3.600 y 7.200 filas al año (con 10 y 20 puntos activos por día). Los catálogos crecen por decisiones de la operación y no por volumen: pasan de 4 ciudades y 7 puntos de la red a unas 12 y 25 en un año, y los que definen la máquina de estados (9 estados, 11 tipos de evento y 20 transiciones) no cambian.
 
Si se duplicaran los envíos diarios, las cuatro tablas de arriba se duplican. `eventos.evento` es la más grande y es la que analizamos en el documento de almacenamiento.
 
---

## Análisis de almacenamiento, costo y optimización
 
Calculamos el almacenamiento y los índices de `eventos.evento`, el costo en páginas de E/S de una consulta con reunión y su optimización algebraica. El detalle paso a paso está en [docs/analisis-almacenamiento.md](docs/analisis-almacenamiento.md).
 
---

## Estructura del repo
 
```
.
├── README.md
├── schema.sql
├── consultas.sql
└── docs/
    ├── consultas.md
    └── analisis-almacenamiento.md
```
