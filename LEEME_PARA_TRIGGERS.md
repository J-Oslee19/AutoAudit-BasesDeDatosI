# AutoAudit – Notas de entrega para el módulo de triggers

Para la instalación integrada y las pruebas, consulta el [README principal](README.md) y la [guía de validación](docs/REVISION_FINAL.md). Este archivo conserva el contexto de la entrega de configuración.

## Estado
- Parte 1: modelo y tablas (01, docs/02)
- Parte 2: configuración de auditoría (03-06) – probada, ver docs/resultado_pruebas_config.txt

## Contrato de integración con los triggers
- Leer `v_configuracion_actual WHERE activo AND tabla_habilitada`
- Llamar antes a `fn_validar_configuracion()` (detecta tablas/columnas eliminadas)
- Un trigger por tabla origen (restricción de la especificación), AFTER INSERT/UPDATE/DELETE
- Escribir en `bitacora` (id_configuracion, id_usuario, id_estacion, valor_anterior, valor_nuevo, id_registro)
- El registrador de `07` resuelve el usuario y la estación usando `session_user` e `inet_client_addr()` y los registra cuando faltan.
- La bitácora debe bloquear escritura directa (requisito de seguridad) y conservar datos si se borra el registro origen.
