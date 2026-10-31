# DEV database migrator

Esta Lambda se ejecuta dentro de la VPC de la RDS y solo inicia una conexión dentro de `lambda_handler` tras una invocación explícita. Lee `DB_SECRET_ARN`, obtiene las credenciales del secreto administrado por RDS, usa SSL y un advisory lock PostgreSQL. No registra credenciales, endpoints, SQL ni contenido de Uonify.
