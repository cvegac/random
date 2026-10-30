### 1. % error real del adaptador

2xx y 412 no son error; minutos con 10 respuestas o menos cuentan como 0. Estático, ABOVE, umbral 5 %.

Plantilla del evento. Título:
```
Nexus: % error real del adaptador sobre 5 % en {dims:cluster}
```
Descripción:
```
Más del 5 % de las respuestas de los adaptadores de {dims:cluster} fueron error (código HTTP fuera de 2xx y 412;
el 412 es respuesta de negocio) en 3 de los últimos 5 minutos. Los minutos con 10 respuestas o menos no cuentan.
Revisar en el tablero Nexus V2: "RESPUESTAS POR CÓDIGO HTTP" y "RESPUESTAS POR SERVICIO Y CANAL" para ver qué código,
servicio y canal; los rquid están en "RQUIDS CON ERROR (respuesta del adaptador)".
Tablero con la alerta (Nexus V2, sección 3. Alertas en el rango, "1. % ERROR REAL DEL ADAPTADOR"):
<url-nexus-v2>
```
