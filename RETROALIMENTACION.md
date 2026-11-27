# Retroalimentación – Bases de Datos

Calificación por sprint según la rúbrica de cada entrega. Los scripts se ejecutaron en PostgreSQL 16 vacío. Lo que venía de un sprint anterior aparece como sugerencia y no descuenta.

## Sprint 1 — 4.8 / 5.0

| Criterio | Nivel | Puntos |
|---|---|---|
| C1 Entidades y relaciones | Excelente | 1.25 / 1.25 |
| C2 Preguntas clave | Excelente | 0.75 / 0.75 |
| C3 Modelo lógico | Excelente | 1.00 / 1.00 |
| C4 Modelo físico | Excelente | 1.25 / 1.25 |
| C5 Repositorio y documentación | Aceptable | 0.55 / 0.75 |

- C5: `preguntas.sql` no es ejecutable (los enunciados no están comentados con `--`).
- C5: mensajes de commit poco descriptivos ("empty repo"); `ms-eventos` sin consultas. El historial muestra 2 autores para 6 integrantes.
- Sugerencias: decidir si `envio.estado` es dato derivado o fuente de verdad; hacer idempotente el `CREATE USER`.

## Sprint 2 — 4.8 / 5.0

| Criterio | Nivel | Puntos |
|---|---|---|
| C1 MER refinado | Excelente | 0.60 / 0.60 |
| C2 Modelo físico | Aceptable | 0.60 / 0.80 |
| C3 schema.sql | Excelente | 0.80 / 0.80 |
| C4 Consultas | Excelente | 0.70 / 0.70 |
| C5 Volumen | Excelente | 0.50 / 0.50 |
| C6 Roles y seguridad | Excelente | 0.60 / 0.60 |
| C7 Almacenamiento e índices | Excelente | 0.40 / 0.40 |
| C8 Costo de una consulta | Excelente | 0.30 / 0.30 |
| C9 Optimización algebraica | Excelente | 0.30 / 0.30 |

- C1: 19 relaciones = 19 FK. La tabla de cambios frente al Sprint 1 es muy clara.
- C2: `eventos.evento` queda en 2FN (`tracking_number` y `cierra_envio`); la rúbrica pide mínimo 3FN. Está bien documentado, pero no cumple.
- C4: sin datos de prueba, 13 de 15 consultas devuelven 0 filas.
- C8: en el plan B no se suma la altura del índice de `punto_red` por tupla externa (no cambia la conclusión).

## Sprint 3 — 5.0 / 5.0

| Criterio | Nivel | Puntos |
|---|---|---|
| C1 MER refinado | Excelente | 0.70 / 0.70 |
| C2 Script refinado | Excelente | 0.80 / 0.80 |
| C3 Triggers | Excelente | 1.10 / 1.10 |
| C4 Procedimientos | Excelente | 1.10 / 1.10 |
| C5 Consultas | Excelente | 0.60 / 0.60 |
| C6 Roles y seguridad | Excelente | 0.70 / 0.70 |

- C1: 24 relaciones = 24 FK, con la opcionalidad correcta.
- C3: `pruebas.sql` falla en una base nueva en la línea 49: `SET CONSTRAINTS trg_envio_completo` necesita el esquema (`envios.trg_envio_completo`). Con eso corregido pasan las 18 pruebas.
- C4: 7 funciones documentadas con ejemplo. La lógica de sesiones de HU-08 no tiene función ni trigger.
- C5: 18 de 20 consultas devuelven 0 filas por falta de seed; se puede reutilizar el envío que arma `pruebas.sql`.
- C6: buen hallazgo de las 16 funciones abiertas a PUBLIC; ahora ninguna lo está.

## Nota final: 4.9

Promedio simple de los tres sprints.
