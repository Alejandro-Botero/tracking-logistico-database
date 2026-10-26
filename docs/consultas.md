# Consultas de los dos primeros sprints

[← Volver al README](../README.md)

Las consultas se ejecutan sobre los objetos que crea `schema.sql` y cada una responde una pregunta de negocio. Las del Sprint 1 comprueban lo que registran HU-01, HU-02 y HU-03; las del Sprint 2 cubren HU-04 a HU-07. HU-08 (inicio y cierre de sesión) no tiene consultas porque la autenticación la resuelve el proveedor de identidad y la base solo guarda al operador en `catalogo.operador`.

El SQL de todas está en [`consultas.sql`](../consultas.sql), en el mismo orden. Los ejemplos usan el número de seguimiento `FDX000000012345` y periodos de octubre de 2026, así que hay que cambiarlos por datos que existan.

## Sprint 1

### S1-1 · HU-03 · ¿En qué estado está un envío y cuál fue su último movimiento?

Une tres tablas y filtra por número de seguimiento. Usa `LEFT JOIN` para que aparezca también el envío recién registrado, que todavía no tiene movimientos.

### S1-2 · HU-01 · ¿Quiénes son el remitente y el destinatario de un envío y en qué ciudad está cada uno?

Une tres tablas. Muestra los datos obligatorios que se piden al registrar el envío.

### S1-3 · HU-01 · ¿Cuántos paquetes y cuánto peso tiene cada envío registrado en un periodo?

Filtra por rango de fechas, agrupa y calcula `COUNT` y `SUM`.

### S1-4 · HU-02 · ¿Qué envíos se entregaron, quién los recibió y en qué punto?

Filtra por tipo de evento y une tres tablas. Sirve para comprobar que toda entrega quedó con constancia de quién recibió.

### S1-5 · HU-03 · ¿Cuántos envíos hay en cada estado?

Agrega con `LEFT JOIN` desde el catálogo de estados, para que también salgan los estados sin envíos, con cero.

## Sprint 2

### S2-1 · HU-04 · ¿Por qué puntos pasó mi envío, en qué orden y qué estado dejó cada movimiento?

Une cuatro tablas, ordena cronológicamente y deja solo los eventos visibles para el cliente. Es la misma lógica de la vista `eventos.v_historial_envio`. Si el envío no tiene movimientos, o el número no existe, devuelve cero filas; para distinguir los dos casos se mira si el número está en `envios.envio`.

### S2-2 · HU-05 · ¿Cuál es el tiempo promedio de tránsito de los envíos entregados en un periodo?

Promedia sobre la vista `v_tiempo_transito_envio`, que ya cuenta solo los envíos entregados. Si el periodo no tiene entregas, `COUNT` da 0 y los promedios dan `NULL`, que es el caso «no hay datos para ese periodo» de la historia.

### S2-3 · HU-05 · ¿En qué tramos de la red se pierde más tiempo?

Une la vista de tramos con los envíos y filtra por periodo de entrega. `TRANSITO` es el tiempo entre dos puntos distintos y `PERMANENCIA` el tiempo detenido en el mismo punto. Solo cuenta envíos entregados.

### S2-4 · HU-06 · ¿Qué envíos van retrasados, dónde están detenidos y cuánto exceden el tiempo esperado?

Lee la vista `v_envio_retrasado`, que compara el tiempo en la red con el SLA que quedó guardado en cada envío (`horas_sla`). Si no hay retrasos, devuelve cero filas.

### S2-5 · HU-06 · ¿En qué puntos se concentran los retrasos?

Agrupa por punto la misma vista de retrasos.

### S2-6 · HU-07 · ¿Cuántos envíos se registraron en un periodo y cómo se reparten por punto de la red?

Filtra por periodo, agrupa por punto y ordena, sobre `v_volumen_registro`. Antes hay que ejecutar `SELECT eventos.refrescar_reportes();` para que la vista tenga los datos recientes.

### S2-7 · HU-07 · ¿Cuántos envíos se han registrado hoy en cada punto?

La vista materializada solo está tan fresca como su último refresco; para contar lo registrado hasta el momento de la consulta se usa la tabla base.

### S2-8 · HU-07 · ¿Cuánta carga de trabajo tuvo cada punto?

Eventos y envíos distintos por punto, desde `v_volumen_movimiento`.

## Verificaciones de integridad

### V-1 · ¿El estado guardado en cada envío coincide con su historial de eventos?

`envios.envio` guarda un caché del último movimiento que mantiene un trigger. La vista `v_envio_incoherente` lista los envíos donde ese caché y los eventos no coinciden. Lo esperado es cero filas.

### V-2 · ¿Alguna tabla quedó sin RLS, sin política o abierta a PUBLIC?

Función que revisa la seguridad del esquema. Lo esperado es cero filas.
