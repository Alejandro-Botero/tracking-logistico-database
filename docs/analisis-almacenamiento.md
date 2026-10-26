# Análisis de almacenamiento, costo y optimización

[← Volver al README](../README.md)

En este documento analizamos la tabla `eventos.evento`, el costo de una consulta que une `evento` con `punto_red` y la optimización algebraica de una consulta del proyecto. Las fórmulas son las de referencia del sprint.

Como no hay datos reales de la operación, todas las estadísticas son estimadas y salen de la sección de estimación de volumen del README (360.000 envíos y 2.160.000 eventos al cabo de un año). Además suponemos páginas de 8.192 bytes (el tamaño por defecto de PostgreSQL), 10 páginas de memoria para los joins y 8 bytes por puntero en los índices.

## 1. Almacenamiento e índices de `eventos.evento`

### Por qué esta tabla

Es la que más crece (unos 6 eventos por envío, seis veces más filas que `envio`) y la que leen casi todas las historias: HU-02, HU-03, HU-04, HU-05, HU-06 y HU-07.

### Organización del archivo

La tabla es un archivo de montículo sin ordenar, que es lo que usa PostgreSQL (`default_table_access_method = heap` en `schema.sql`). Como solo se insertan eventos (un trigger bloquea el `UPDATE` y el `DELETE`), los registros se agregan al final y nunca se mueven, así que no hace falta mantener ningún orden físico.

Pensamos en un cluster multitabla de `envio` con sus eventos, que acelera el historial de HU-04 porque deja juntos al envío y sus eventos. Lo descartamos porque PostgreSQL no lo ofrece, y el índice compuesto `idx_evento_envio` consigue algo parecido.

### Índices

Además de la llave primaria, la tabla tiene estos índices:

- `idx_evento_envio` (`envio_id`, `ocurrido_en`, `secuencia`): historial de un envío en orden cronológico (HU-04), búsqueda del último evento al validar uno nuevo y ventana de tramos (HU-05). Es el que calculamos en 1.3 y 1.4.
- `idx_evento_tracking` (`tracking_number`): consulta por número de seguimiento sin cruzar al schema de envíos. Lo usamos en la sección 2.
- `idx_evento_punto` (`punto_red_id`, `ocurrido_en`): volumen y carga por punto (HU-07).
- `idx_evento_tipo` (`tipo_evento`, `ocurrido_en`): por ejemplo, las entregas de un periodo.
- `idx_evento_operador` (`registrado_por`): auditoría por operador.
- Un índice BRIN sobre `ocurrido_en`: sirve para rangos de fechas y ocupa muy poco, porque los eventos entran casi en orden de tiempo.
- Dos índices únicos parciales: uno asegura un solo evento de cierre por envío y el otro evita que un reintento del escáner duplique un evento (`clave_idempotencia`).

Cada índice hace más lenta la inserción, pero lo aceptamos: la tabla solo recibe inserciones y los reportes se leen mucho más de lo que se escribe.

### 1.1 Longitud del registro (L)

Usamos $L = 4 \cdot \#\text{campos var.} + \sum \text{size(campos fijos)} + \text{size(mapa de bits)} + \sum \text{tamaño estimado(campos var.)}$.

Campos de tamaño fijo:

| Campo | Tipo | Bytes |
|---|---|---|
| `id` | uuid | 16 |
| `secuencia` | bigint | 8 |
| `envio_id` | uuid | 16 |
| `cierra_envio` | boolean | 1 |
| `punto_red_id` | uuid | 16 |
| `ocurrido_en` | timestamptz | 8 |
| `registrado_en` | timestamptz | 8 |
| Total | | 73 |

Campos de tamaño variable (todos `text`), con el tamaño promedio que estimamos:

| Campo | Bytes | De dónde sale |
|---|---|---|
| `tracking_number` | 15 | `FDX` más 12 dígitos |
| `tipo_evento` | 12 | los códigos miden entre 7 y 19 caracteres |
| `estado_resultante` | 10 | códigos de estado |
| `registrado_por` | 36 | subject del token escrito como UUID |
| `recibido_por` | 4 | unos 25 bytes, pero solo en las entregas (1 de cada 6 eventos) |
| `observaciones` | 6 | unos 60 bytes, en cerca del 10 % de los eventos |
| `clave_idempotencia` | 18 | 36 bytes, en cerca de la mitad de los eventos |
| Total | 101 | 7 campos |

La tabla tiene 14 campos, así que el mapa de bits ocupa $\lceil 14/8 \rceil = 2$ bytes. Entonces:

$$L = 4 \cdot 7 + 73 + 2 + 101 = 204 \text{ bytes}$$

### 1.2 Registros por bloque y páginas de la tabla

$$FR = \left\lfloor \frac{P-2}{4+L} \right\rfloor = \left\lfloor \frac{8192-2}{4+204} \right\rfloor = \left\lfloor \frac{8190}{208} \right\rfloor = 39$$

Comprobamos con $P = 2 + 4 \cdot FR + FR \cdot L = 2 + 156 + 7956 = 8114$, que cabe en 8.192 bytes. Con 40 registros ya no cabría (8.322).

$$BR = \left\lceil \frac{TR}{FR} \right\rceil = \left\lceil \frac{2160000}{39} \right\rceil = 55385 \text{ páginas}$$

La tabla ocupa $55385 \times 8192 = 453\,713\,920$ bytes, unos 432,7 MiB.

### 1.3 Orden del árbol y altura del índice `idx_evento_envio`

Cada entrada tiene la clave (`envio_id` 16 + `ocurrido_en` 8 + `secuencia` 8 = 32 bytes) más el puntero de 8, es decir, $L_{idx} = 40$ bytes. Entonces:

$$FR_{idx} = \left\lfloor \frac{B}{L_{idx}} \right\rfloor = \left\lfloor \frac{8192}{40} \right\rfloor = 204$$

De $2d - 1 = 204$ sale $d = 102{,}5$; tomamos $d = 102$, con lo que el nodo admite 203 entradas.

La clave incluye `secuencia`, que es única, así que $V(a,R) = TR = 2160000$. La altura cumple:

$$H \le \log_{102} 2160000 = \frac{\ln 2160000}{\ln 102} = \frac{14{,}586}{4{,}625} = 3{,}15 \;\Rightarrow\; H = 4$$

### 1.4 Nodos y espacio del índice

Contamos el nivel 1 como las hojas, y en cada nivel dividimos entre $d$ de nuevo (redondeando hacia arriba):

| Nivel | Cálculo | Nodos |
|---|---|---|
| 1 (hojas) | 2160000 / 102 | 21.177 |
| 2 | 2160000 / 102² | 208 |
| 3 | 2160000 / 102³ | 3 |
| 4 (raíz) | 2160000 / 102⁴ | 1 |
| Total | | 21.389 |

El espacio del índice es $21389 \times 8192 = 175\,218\,688$ bytes, unos 167,1 MiB, cerca del 39 % de lo que ocupa la tabla. Es una estimación por arriba: la fórmula supone nodos con el mínimo de entradas, y un B+tree real de PostgreSQL llena sus páginas cerca del 90 %, así que ocupará algo menos.

## 2. Costo de una consulta

### 2.1 La consulta

Historial de un envío con el nombre del punto de cada evento (HU-04). Tiene una reunión entre `evento` y `punto_red`.

```sql
SELECT ev.ocurrido_en, ev.tipo_evento, pr.nombre AS punto
FROM eventos.evento ev
JOIN catalogo.punto_red pr ON pr.id = ev.punto_red_id
WHERE ev.tracking_number = 'FDX000000012345';
```

En álgebra relacional: $\pi_{ocurrido\_en,\,tipo\_evento,\,nombre}\big(\sigma_{tracking\_number = X}(\text{evento}) \bowtie_{punto\_red\_id = id} \text{punto\_red}\big)$

### 2.2 Estadísticas

- $TR_{evento} = 2160000$ y $BR_{evento} = 55385$, de la sección 1.
- $V(tracking\_number, evento) = 360000$: hay un número de seguimiento por envío.
- $S(tracking\_number, evento) = TR / V = 2160000 / 360000 = 6$ eventos por envío.
- $TS_{punto\_red} = 25$ puntos al cabo de un año, según la estimación de volumen.
- $M = 10$ páginas de memoria.

Altura del índice `idx_evento_tracking`: la entrada mide 15 + 8 = 23 bytes, entonces $FR = \lfloor 8192/23 \rfloor = 356$ y $d = \lfloor 357/2 \rfloor = 178$. Como $\log_{178} 360000 = 2{,}47$, la altura es $HI = 3$.

Páginas de `punto_red`: los campos fijos suman 25 bytes (`id` 16, `activo` 1, `creado_en` 8) y los 6 variables (`codigo`, `nombre`, `tipo`, `ciudad_codigo`, `latitud`, `longitud`) suman 77. Con un mapa de bits de $\lceil 9/8 \rceil = 2$ bytes: $L = 4 \cdot 6 + 25 + 2 + 77 = 128$. Entonces $FR = \lfloor 8190/132 \rfloor = 62$ y $BS = \lceil 25/62 \rceil = 1$: la tabla cabe en una página.

### 2.3 Plan elegido

Primero se hace la selección con el índice y después la reunión por bucles anidados.

La selección usa un índice secundario, porque `tracking_number` se repite en varios eventos:

$$\text{Costo} = HI + S(a,R) = 3 + 6 = 9 \text{ páginas}$$

Quedan 6 tuplas, que caben en una página. Para la reunión, esa página es la tabla externa ($BR = 1$) y `punto_red` es la interna ($BS = 1$):

$$\text{Costo} = BR + BS \cdot \left\lceil \frac{BR}{M-2} \right\rceil = 1 + 1 \cdot \left\lceil \frac{1}{8} \right\rceil = 2 \text{ páginas}$$

Como `id` es llave de `punto_red`, el resultado tiene a lo sumo 6 tuplas. El costo total es 9 + 2 = 11 páginas de E/S.

### 2.4 Alternativas

| Plan | Cálculo | Páginas |
|---|---|---|
| A. Selección con índice y bucles anidados (el elegido) | $9 + 2$ | 11 |
| B. Selección con índice y bucles anidados con índice sobre `punto_red.id` | $9 + (BT + TT \cdot S(b,R)) = 9 + (1 + 6 \cdot 1)$ | 16 |
| C. Reunión sin selección previa, con `punto_red` como externa | $1 + 55385 \cdot \lceil 1/8 \rceil$ | 55.386 |
| D. Reunión sin selección previa, con `evento` como externa | $55385 + \lceil 55385/8 \rceil = 55385 + 6924$ | 62.309 |

En el plan B, $S(id, punto\_red) = TS/V = 25/25 = 1$ porque `id` es llave.

El plan A cuesta unas 5.000 veces menos que recorrer la tabla (55.386 / 11 ≈ 5.035). La diferencia está en aplicar primero la selección con `idx_evento_tracking`, que baja `evento` de 2.160.000 tuplas a 6 antes de la reunión. Entre A y B gana A porque `punto_red` cabe en una página y leerla entera cuesta menos que buscar cada tupla por el índice. No consideramos la reunión por mezcla ni la hash: con una relación de una página y otra de 6 tuplas no aportan nada.

## 3. Optimización algebraica

### 3.1 La consulta

Eventos de un envío ocurridos en centros de distribución, con el nombre del punto. Tiene un predicado sobre cada relación, así que permite aplicar varias leyes.

```sql
SELECT ev.ocurrido_en, ev.tipo_evento, pr.nombre AS punto
FROM eventos.evento ev
JOIN catalogo.punto_red pr ON pr.id = ev.punto_red_id
WHERE ev.tracking_number = 'FDX000000012345'
  AND pr.tipo = 'CENTRO_DISTRIBUCION';
```

Expresión inicial, que primero reúne las dos tablas completas y filtra al final:

$$\pi_{ocurrido\_en,\,tipo\_evento,\,nombre}\Big(\sigma_{tracking\_number = X \,\wedge\, tipo = CD}\big(\text{evento} \bowtie_{punto\_red\_id = id} \text{punto\_red}\big)\Big)$$

### 3.2 Transformaciones

1. Ley 2 (selección conjunta), $\sigma_{p_1 \wedge p_2}(E) \equiv \sigma_{p_1}(\sigma_{p_2}(E))$: separamos la conjunción en dos selecciones, una por predicado.

2. Leyes 4 y 5 (selección sobre una reunión), $\sigma_p(E_1 \bowtie E_2) \equiv \sigma_{p_1}(E_1) \bowtie \sigma_{p_2}(E_2)$: `tracking_number` pertenece solo a `evento` y `tipo` solo a `punto_red`, así que cada selección baja a su relación:

$$\pi_{\ldots}\Big(\sigma_{tracking\_number = X}(\text{evento}) \bowtie \sigma_{tipo = CD}(\text{punto\_red})\Big)$$

3. Ley 9 (proyección sobre una reunión) y Ley 8 (proyecciones en cascada): proyectamos antes de la reunión solo lo que hace falta, conservando los atributos de la reunión (`punto_red_id` e `id`). La proyección final descarta esos atributos de enlace.

La Ley 3 no la usamos, porque `tracking_number` no está en la proyección final y la selección tiene que ir antes. Las Leyes 11 y 12 tampoco dan margen con solo dos relaciones.

### 3.3 Expresión optimizada

$$\pi_{ocurrido\_en,\,tipo\_evento,\,nombre}\Big(\pi_{ocurrido\_en,\,tipo\_evento,\,punto\_red\_id}\big(\sigma_{tracking\_number = X}(\text{evento})\big) \bowtie \pi_{id,\,nombre}\big(\sigma_{tipo = CD}(\text{punto\_red})\big)\Big)$$

### 3.4 Por qué es más barata

Con las estadísticas de la sección 2, y suponiendo 8 centros de distribución entre los 25 puntos del primer año:

| | Expresión inicial | Expresión optimizada |
|---|---|---|
| Tuplas que entran a la reunión | 2.160.000 de `evento` y 25 de `punto_red` | 6 de `evento` y 8 de `punto_red` |
| Tuplas que produce la reunión | 2.160.000 (cada evento coincide con un punto) | 6 como máximo |
| Atributos por tupla | 14 + 9 = 23 | 3 y 2 |

La expresión inicial genera más de dos millones de tuplas intermedias de 23 atributos para quedarse al final con unas pocas. En la optimizada, la reunión trabaja con 6 y 8 tuplas de 3 y 2 atributos. En páginas de E/S es la misma diferencia de la sección 2: de más de 55.000 páginas a 11.

## Notas

Las cifras de volumen son estimaciones y no mediciones. Con datos reales se pueden contrastar con `pg_relation_size` y `EXPLAIN (ANALYZE, BUFFERS)`, que además puede elegir un plan distinto al que usamos aquí, porque el optimizador de PostgreSQL tiene su propio modelo de costo.
