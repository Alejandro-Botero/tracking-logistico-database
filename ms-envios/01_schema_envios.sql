-- =============================================================
-- Schema y tabla del microservicio ms-envios
-- Proyecto: Fabrica Escuela - Sprint 1
-- Historias de usuario cubiertas: HU-01 (Registrar un envio),
--                                  HU-03 (Consultar estado de un envio)
-- =============================================================

-- Cada microservicio de la arquitectura tiene su propio schema
-- aislado dentro del mismo proyecto de base de datos, de forma
-- que ningun otro microservicio pueda leer ni modificar sus tablas
-- directamente.
CREATE SCHEMA IF NOT EXISTS envios;

-- Tabla principal: representa un envio logistico registrado en
-- el sistema, con los datos de remitente y destinatario.
CREATE TABLE envios.envio (
    id                          BIGSERIAL PRIMARY KEY,
    numero_seguimiento          VARCHAR(30) NOT NULL UNIQUE,
    remitente_nombre            VARCHAR(150) NOT NULL,
    remitente_telefono          VARCHAR(30)  NOT NULL,
    remitente_direccion         VARCHAR(250) NOT NULL,
    remitente_email             VARCHAR(150),
    destinatario_nombre         VARCHAR(150) NOT NULL,
    destinatario_telefono       VARCHAR(30)  NOT NULL,
    destinatario_direccion      VARCHAR(250) NOT NULL,
    destinatario_email          VARCHAR(150),
    estado                      VARCHAR(30)  NOT NULL,
    fecha_registro              TIMESTAMP NOT NULL DEFAULT now()
);

-- El numero de seguimiento es la via principal de consulta (HU-03),
-- asi que se indexa para que esas busquedas sean eficientes.
CREATE INDEX idx_envio_numero_seguimiento ON envios.envio (numero_seguimiento);

-- Row-Level Security viene activado por defecto en Supabase, pensado
-- para clientes finales que se conectan directo con autenticacion de
-- usuario. Como este esquema lo consume un backend con su propio
-- usuario de base de datos (ms_envios_user), se desactiva aqui.
ALTER TABLE envios.envio DISABLE ROW LEVEL SECURITY;

-- Usuario de base de datos exclusivo del microservicio ms-envios,
-- con permisos limitados solo a este schema.
CREATE USER ms_envios_user WITH PASSWORD 'CAMBIAR_POR_UNA_CONTRASENA_SEGURA';

GRANT USAGE ON SCHEMA envios TO ms_envios_user;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA envios TO ms_envios_user;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA envios TO ms_envios_user;

ALTER DEFAULT PRIVILEGES IN SCHEMA envios GRANT ALL ON TABLES TO ms_envios_user;
ALTER DEFAULT PRIVILEGES IN SCHEMA envios GRANT ALL ON SEQUENCES TO ms_envios_user;
