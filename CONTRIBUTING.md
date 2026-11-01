# Cómo trabajar en este repositorio

1. Leer AGENTS.md y docs/FOLDER_STANDARD.md.
2. Revisar dev y cambios locales. Conservar archivos existentes.
3. Identificar módulo y propietario antes de implementar. RDS, migrador, SQL, seeds, pruebas y workflows de base de datos pertenecen aquí. No introducir Lambdas funcionales ni API Gateway.
4. Al crear submódulos o pantallas, replicar ruta y README en frontend, backend, database e infrastructure. Documentar las correspondencias pendientes si no se dispone de todos los repositorios.
5. Definir recursos compartidos una sola vez en el padre común. Completar plantillas vacías solo cuando existan recursos reales.
6. Ejecutar `python scripts/validate_structure.py` y las pruebas de la implementación.
7. Revisar el diff y solicitar revisión. Publicar o desplegar solo dentro de la autorización del propietario.

Las IA deben mostrar advertencia, consecuencia y recomendación ante desviaciones. El README explica; AGENTS.md orienta; el workflow detecta errores básicos. La revisión humana sigue siendo necesaria.
