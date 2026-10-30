### 4. 5xx del backend

Estático, ABOVE, umbral 1 por minuto.

Plantilla del evento. Título:
```
Nexus: respuestas 5xx del backend en {dims:cluster}
```
Descripción:
```
Más de 1 respuesta 5xx por minuto en los adaptadores de {dims:cluster} en 3 de los últimos 5 minutos: el backend
o el adaptador fallaron por un error técnico.
Revisar en el tablero Nexus V2: "RESPUESTAS POR CÓDIGO HTTP" para ver el código (si son 504, seguir con la alerta de timeouts) y
"RESPUESTAS POR SERVICIO Y CANAL" para ver el servicio; los rquid están en "RQUIDS CON ERROR (respuesta del adaptador)".
Tablero con la alerta (Nexus V2, sección 3. Alertas en el rango, "4. 5XX DEL BACKEND"):
<url-nexus-v2>
```
