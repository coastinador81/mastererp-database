-- Esquemas de la base mastererp. Una sola instancia; el aislamiento por tenant
-- vive en las tablas, no en una base por cliente ni por modulo.
CREATE SCHEMA IF NOT EXISTS plataforma;
CREATE SCHEMA IF NOT EXISTS catalogo;
CREATE SCHEMA IF NOT EXISTS operaciones;
CREATE SCHEMA IF NOT EXISTS finanzas;
CREATE SCHEMA IF NOT EXISTS servicios;
CREATE SCHEMA IF NOT EXISTS personas;
CREATE SCHEMA IF NOT EXISTS comercio;
CREATE SCHEMA IF NOT EXISTS logistica;
CREATE SCHEMA IF NOT EXISTS agentes;
