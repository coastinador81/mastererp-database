-- Login simple de admin (correo + contraseña) SOLO para local/desarrollo, detrás de flag de entorno
-- (UONIFY_ADMIN_DEV_SIMPLE_LOGIN=1); por defecto el acceso sigue siendo correo+código+2FA (prod).
-- Aditiva y nullable: no toca datos existentes. La contraseña se guarda HASHEADA (PBKDF2), nunca en claro.
-- MUST-REVERT antes de producción: re-activar 2FA (quitar el flag); la columna puede quedarse vacía.
ALTER TABLE admin_users ADD COLUMN IF NOT EXISTS password_hash text;
