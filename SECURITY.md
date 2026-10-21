# Seguridad

Airy borra archivos, así que un fallo de seguridad puede costar datos. Si encuentras algo que permita
borrar o mover a la Papelera una ruta protegida, saltarse la confirmación o hacer que un agente MCP
ejecute más de lo permitido, **no abras un issue público**. Escribe directamente al propietario del
repositorio.

Incluye:
- versión de Airy y de macOS;
- pasos para reproducirlo (sin datos personales);
- qué esperabas que pasara y qué pasó.

## Modelo de amenazas

- **Fuera del alcance:** un usuario con permisos de administrador que decide borrar algo él mismo.
- **Dentro del alcance:** cualquier camino por el que Airy, sus fuentes de detección, el catálogo, la IA
  o un agente MCP marquen como seguro, o ejecuten, algo que las protecciones duras prohíben.
