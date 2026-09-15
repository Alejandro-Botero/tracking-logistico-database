-- =============================================================
-- Base de datos unica - Monolito modular
-- Proyecto: Fabrica Escuela - Sprint 1
-- HU-01 (Registrar envio), HU-02 (Registrar evento), HU-03 (Consultar estado)
-- =============================================================

CREATE SCHEMA IF NOT EXISTS envios;
CREATE SCHEMA IF NOT EXISTS eventos;

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
    estado                      VARCHAR(30)  NOT NULL
                                 CHECK (estado IN ('REGISTRADO', 'EN_TRANSITO', 'ENTREGADO')),
    fecha_registro              TIMESTAMP NOT NULL DEFAULT now()
);

-- Row-Level Security viene activado por defecto en Supabase, pensado
-- para clientes finales autenticados directo. Este schema lo consume
-- un backend con su propio usuario de base de datos, se desactiva aqui.
ALTER TABLE envios.envio DISABLE ROW LEVEL SECURITY;

CREATE TABLE eventos.evento (
    id              BIGSERIAL PRIMARY KEY,
    envio_id        BIGINT NOT NULL REFERENCES envios.envio(id),
    tipo_evento     VARCHAR(30) NOT NULL
                    CHECK (tipo_evento IN ('RECOGIDO', 'EN_TRANSITO', 'EN_CENTRO_DISTRIBUCION', 'ENTREGADO')),
    punto           VARCHAR(150),
    fecha_hora      TIMESTAMP NOT NULL DEFAULT now(),
    receptor        VARCHAR(150),
    -- HU-02: la entrega exige constancia de quien recibio.
    CHECK (tipo_evento <> 'ENTREGADO' OR receptor IS NOT NULL)
);

CREATE INDEX idx_evento_envio_id ON eventos.evento (envio_id);

ALTER TABLE eventos.evento DISABLE ROW LEVEL SECURITY;

CREATE USER app_user WITH PASSWORD 'CAMBIAR_POR_UNA_CONTRASENA_SEGURA';

GRANT USAGE ON SCHEMA envios, eventos TO app_user;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA envios, eventos TO app_user;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA envios, eventos TO app_user;

ALTER DEFAULT PRIVILEGES IN SCHEMA envios GRANT ALL ON TABLES TO app_user;
ALTER DEFAULT PRIVILEGES IN SCHEMA envios GRANT ALL ON SEQUENCES TO app_user;
ALTER DEFAULT PRIVILEGES IN SCHEMA eventos GRANT ALL ON TABLES TO app_user;
ALTER DEFAULT PRIVILEGES IN SCHEMA eventos GRANT ALL ON SEQUENCES TO app_user;
