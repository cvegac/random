### 3. Errores de mapeo

Estático, ABOVE, umbral 2 por minuto.

Plantilla del evento. Título:
```
Nexus: errores de mapeo en {dims:cluster}
```
Descripción:
```
Más de 2 errores de mapeo por minuto (GenericExceptionMapper, sin los 504) en los adaptadores de {dims:cluster}
en 3 de los últimos 5 minutos: un request o una respuesta trae un campo que no cumple la regla del mapeo.
Suele ser un canal que manda datos nuevos o un cambio en lo que devuelve el backend.
Revisar en el tablero Nexus V2: "ERRORES DE MAPEO POR SERVICIO Y CAMPO" y "ERRORES DE MAPEO CON EJEMPLO" (dirección REQUEST o
RESPONSE, campo y regla).
Tablero con la alerta (Nexus V2, sección 3. Alertas en el rango, "3. ERRORES DE MAPEO"):
<url-nexus-v2>
```
